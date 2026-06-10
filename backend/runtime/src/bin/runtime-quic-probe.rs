use std::{
    env, fs,
    net::{SocketAddr, ToSocketAddrs, UdpSocket},
    path::Path,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::Serialize;
use serde_json::Value;
use turbo_runtime::{
    quic_protocol::runtime_quic_alpn,
    runtime_quic::{RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE, RUNTIME_QUIC_OUT_BUF_LENGTH},
};

const DEFAULT_ENDPOINT: &str = "api.beepbeep.to:443";
const DEFAULT_TIMEOUT_MS: u64 = 5_000;
const STREAM_ID: u64 = 0;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeQuicProbeReport {
    status: String,
    endpoint: String,
    server_name: String,
    local_addr: Option<String>,
    remote_addr: Option<String>,
    established: bool,
    raw_response: Option<String>,
    response_type: Option<String>,
    response_transport: Option<String>,
    response_status: Option<String>,
    response_error: Option<String>,
    error: Option<String>,
    elapsed_ms: u128,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let endpoint = env::var("TURBO_RUNTIME_QUIC_PROBE_ENDPOINT")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| env::args().nth(1))
        .unwrap_or_else(|| DEFAULT_ENDPOINT.to_owned());
    let server_name = env::var("TURBO_RUNTIME_QUIC_PROBE_SERVER_NAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| server_name_from_endpoint(&endpoint));
    let timeout = Duration::from_millis(
        env::var("TURBO_RUNTIME_QUIC_PROBE_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(DEFAULT_TIMEOUT_MS),
    );
    let output_path = env::var("TURBO_RUNTIME_QUIC_PROBE_OUTPUT").ok();
    let started = Instant::now();

    let report = match run_probe(&endpoint, &server_name, timeout) {
        Ok(mut report) => {
            report.elapsed_ms = started.elapsed().as_millis();
            report
        }
        Err(error) => RuntimeQuicProbeReport {
            status: "fail".to_owned(),
            endpoint,
            server_name,
            local_addr: None,
            remote_addr: None,
            established: false,
            raw_response: None,
            response_type: None,
            response_transport: None,
            response_status: None,
            response_error: None,
            error: Some(error.to_string()),
            elapsed_ms: started.elapsed().as_millis(),
        },
    };

    let json = serde_json::to_string_pretty(&report)?;
    if let Some(output_path) = output_path {
        if let Some(parent) = Path::new(&output_path).parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(output_path, format!("{json}\n"))?;
    } else {
        println!("{json}");
    }

    if report.status == "ok" {
        Ok(())
    } else {
        Err("runtime QUIC probe failed".into())
    }
}

fn run_probe(
    endpoint: &str,
    server_name: &str,
    timeout: Duration,
) -> Result<RuntimeQuicProbeReport, Box<dyn std::error::Error>> {
    let remote_addr = resolve_endpoint(endpoint)?;
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.connect(remote_addr)?;
    socket.set_read_timeout(Some(Duration::from_millis(25)))?;
    socket.set_write_timeout(Some(Duration::from_millis(25)))?;
    let local_addr = socket.local_addr()?;
    let mut config = client_config()?;
    let scid_bytes = connection_id_seed();
    let scid = quiche::ConnectionId::from_ref(&scid_bytes);
    let mut connection = quiche::connect(
        Some(server_name),
        &scid,
        local_addr,
        remote_addr,
        &mut config,
    )?;

    drive_connection(
        &socket,
        &mut connection,
        local_addr,
        remote_addr,
        timeout,
        |connection| Ok(connection.is_established()),
    )?;

    let request = serde_json::json!({
        "type": "presence-command",
        "requestId": "runtime-quic-probe-1",
        "commandKind": "presence-foreground",
        "userHandle": "@runtime-quic-probe",
        "deviceId": "runtime-quic-probe-device",
        "operationId": "runtime-quic-probe-op",
        "generation": 1
    })
    .to_string()
        + "\n";
    connection.stream_send(STREAM_ID, request.as_bytes(), false)?;

    let mut received = Vec::new();
    drive_connection(
        &socket,
        &mut connection,
        local_addr,
        remote_addr,
        timeout,
        |connection| {
            read_stream_bytes(connection, &mut received)?;
            Ok(received.iter().any(|byte| *byte == b'\n'))
        },
    )?;
    read_stream_bytes(&mut connection, &mut received)?;

    let raw_response = String::from_utf8(received)?
        .lines()
        .next()
        .unwrap_or("")
        .to_owned();
    if raw_response.is_empty() {
        return Err("runtime QUIC response was empty".into());
    }
    let response = serde_json::from_str::<Value>(&raw_response)?;
    let response_type = response
        .get("type")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let response_transport = response
        .get("transport")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let response_status = response
        .get("status")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let response_error = response
        .get("error")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let ok = response_type.as_deref() == Some("presence-command-response")
        && response_transport.as_deref() == Some("runtime-quic-control")
        && response_status.as_deref() == Some("ok");

    Ok(RuntimeQuicProbeReport {
        status: if ok { "ok" } else { "fail" }.to_owned(),
        endpoint: endpoint.to_owned(),
        server_name: server_name.to_owned(),
        local_addr: Some(local_addr.to_string()),
        remote_addr: Some(remote_addr.to_string()),
        established: connection.is_established(),
        raw_response: Some(raw_response),
        response_type,
        response_transport,
        response_status,
        response_error,
        error: None,
        elapsed_ms: 0,
    })
}

fn client_config() -> Result<quiche::Config, quiche::Error> {
    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION)?;
    config.set_application_protos(&[runtime_quic_alpn()])?;
    config.verify_peer(false);
    config.set_max_idle_timeout(30_000);
    config.set_max_recv_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
    config.set_max_send_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
    config.set_initial_max_data(1_000_000);
    config.set_initial_max_stream_data_bidi_local(256_000);
    config.set_initial_max_stream_data_bidi_remote(256_000);
    config.set_initial_max_streams_bidi(32);
    Ok(config)
}

fn drive_connection<F>(
    socket: &UdpSocket,
    connection: &mut quiche::Connection,
    local_addr: SocketAddr,
    remote_addr: SocketAddr,
    timeout: Duration,
    mut done: F,
) -> Result<(), Box<dyn std::error::Error>>
where
    F: FnMut(&mut quiche::Connection) -> Result<bool, Box<dyn std::error::Error>>,
{
    let deadline = Instant::now() + timeout;
    let mut incoming = [0_u8; 65_535];
    loop {
        flush_connection(socket, connection)?;
        if done(connection)? {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("runtime QUIC probe timed out".into());
        }
        match socket.recv(&mut incoming) {
            Ok(read) => {
                let mut packet = incoming[..read].to_vec();
                match connection.recv(
                    &mut packet,
                    quiche::RecvInfo {
                        to: local_addr,
                        from: remote_addr,
                    },
                ) {
                    Ok(_) | Err(quiche::Error::Done) => {}
                    Err(error) => return Err(error.into()),
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                if connection
                    .timeout()
                    .is_some_and(|deadline| deadline.is_zero())
                {
                    connection.on_timeout();
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn flush_connection(
    socket: &UdpSocket,
    connection: &mut quiche::Connection,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut out = [0_u8; RUNTIME_QUIC_OUT_BUF_LENGTH];
    loop {
        match connection.send(&mut out) {
            Ok((written, _send_info)) => {
                socket.send(&out[..written])?;
            }
            Err(quiche::Error::Done) => return Ok(()),
            Err(error) => return Err(error.into()),
        }
    }
}

fn read_stream_bytes(
    connection: &mut quiche::Connection,
    received: &mut Vec<u8>,
) -> Result<(), Box<dyn std::error::Error>> {
    let readable = connection.readable().collect::<Vec<_>>();
    let mut buffer = [0_u8; 4096];
    for stream_id in readable {
        loop {
            match connection.stream_recv(stream_id, &mut buffer) {
                Ok((read, _fin)) if read > 0 => received.extend_from_slice(&buffer[..read]),
                Ok(_) | Err(quiche::Error::Done) => break,
                Err(error) => return Err(error.into()),
            }
        }
    }
    Ok(())
}

fn resolve_endpoint(endpoint: &str) -> Result<SocketAddr, Box<dyn std::error::Error>> {
    endpoint
        .to_socket_addrs()?
        .find(|addr| addr.is_ipv4())
        .ok_or_else(|| format!("no IPv4 address resolved for {endpoint}").into())
}

fn server_name_from_endpoint(endpoint: &str) -> String {
    endpoint
        .rsplit_once(':')
        .map(|(host, _port)| host)
        .unwrap_or(endpoint)
        .trim_matches(['[', ']'])
        .to_owned()
}

fn connection_id_seed() -> [u8; 16] {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or_default();
    let process = std::process::id() as u128;
    (now ^ (process << 64)).to_be_bytes()
}
