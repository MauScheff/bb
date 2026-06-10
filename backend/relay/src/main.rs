use std::{
    collections::{HashMap, VecDeque},
    env,
    hash::{Hash, Hasher},
    net::SocketAddr,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use tokio::{
    net::{TcpListener, UdpSocket},
    sync::mpsc,
    time,
};
use tokio_rustls::TlsAcceptor;
use tokio_util::codec::Framed;
use tracing::{info, warn};

use relay::{
    auth::{validate_id, validate_join_token},
    protocol::{
        MAX_RELAY_LINE_LENGTH, RelayFrame, RelayTransport, parse_relay_datagram_frame,
        relay_lines_codec,
    },
    relay_state::{RelayPeer, RelaySession, RelayState as GenericRelayState},
    state::JoinedPeer,
    transport_quic,
    transport_quic::{QUIC_CONN_ID_LEN, QUIC_OUT_BUF_LENGTH, QUIC_STREAM_RECV_BUF_LENGTH},
    transport_tcp,
};

#[derive(Clone)]
struct Config {
    quic_addr: SocketAddr,
    tcp_addr: SocketAddr,
    cert_pem: PathBuf,
    key_pem: PathBuf,
    shared_token: String,
    session_ttl: Duration,
    quic_active_migration_enabled: bool,
}

type RelayState = GenericRelayState<RelayStreamPeer, RelayDatagramPeer>;

#[derive(Clone)]
struct RelayStreamPeer {
    connection_id: u64,
    tx: mpsc::Sender<String>,
    last_seen: Instant,
}

#[derive(Clone)]
struct RelayDatagramPeer {
    connection_id: u64,
    endpoint: RelayDatagramEndpoint,
    last_seen: Instant,
}

#[derive(Clone)]
enum RelayDatagramEndpoint {
    Quiche(QuicheDatagramEndpoint),
    #[cfg(test)]
    Test,
    #[cfg(test)]
    Failing,
}

impl RelayDatagramEndpoint {
    fn max_datagram_size(&self) -> Option<usize> {
        match self {
            RelayDatagramEndpoint::Quiche(endpoint) => endpoint.max_datagram_size,
            #[cfg(test)]
            RelayDatagramEndpoint::Test => Some(transport_quic::MAX_RELAY_DATAGRAM_BUFFER_LENGTH),
            #[cfg(test)]
            RelayDatagramEndpoint::Failing => {
                Some(transport_quic::MAX_RELAY_DATAGRAM_BUFFER_LENGTH)
            }
        }
    }

    fn send_datagram(&self, data: Bytes) -> Result<()> {
        match self {
            RelayDatagramEndpoint::Quiche(endpoint) => endpoint.send_datagram(data),
            #[cfg(test)]
            RelayDatagramEndpoint::Test => Ok(()),
            #[cfg(test)]
            RelayDatagramEndpoint::Failing => Err(anyhow!("test datagram send failure")),
        }
    }
}

#[derive(Clone)]
struct QuicheDatagramEndpoint {
    connection_key: Vec<u8>,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
    max_datagram_size: Option<usize>,
}

impl QuicheDatagramEndpoint {
    fn send_datagram(&self, data: Bytes) -> Result<()> {
        if self.max_datagram_size.is_none() {
            return Err(anyhow!("peer does not support QUIC datagrams"));
        }
        self.command_tx
            .send(QuicheCommand::SendDatagram {
                connection_key: self.connection_key.clone(),
                data,
            })
            .context("failed to enqueue QUIC datagram")
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "turbo_relay=info,relay=info".into()),
        )
        .init();

    let config = Config::from_env()?;
    let state = RelayState::new();

    let cleanup_state = state.clone();
    tokio::spawn(async move {
        cleanup_loop(cleanup_state).await;
    });

    let quic = serve_quic(config.clone(), state.clone());
    let tcp = serve_tcp_tls(config.clone(), state);

    tokio::select! {
        result = quic => result?,
        result = tcp => result?,
        _ = tokio::signal::ctrl_c() => {
            info!("shutdown requested");
        }
    }

    Ok(())
}

impl Config {
    fn from_env() -> Result<Self> {
        let quic_addr = env::var("TURBO_RELAY_QUIC_ADDR")
            .unwrap_or_else(|_| "0.0.0.0:443".to_string())
            .parse()
            .context("invalid TURBO_RELAY_QUIC_ADDR")?;
        let tcp_addr = env::var("TURBO_RELAY_TCP_ADDR")
            .unwrap_or_else(|_| "0.0.0.0:443".to_string())
            .parse()
            .context("invalid TURBO_RELAY_TCP_ADDR")?;
        let cert_pem = env::var("TURBO_RELAY_CERT_PEM")
            .map(PathBuf::from)
            .context("TURBO_RELAY_CERT_PEM is required")?;
        let key_pem = env::var("TURBO_RELAY_KEY_PEM")
            .map(PathBuf::from)
            .context("TURBO_RELAY_KEY_PEM is required")?;
        let shared_token =
            env::var("TURBO_RELAY_SHARED_TOKEN").context("TURBO_RELAY_SHARED_TOKEN is required")?;
        let session_ttl_seconds = env::var("TURBO_RELAY_SESSION_TTL_SECONDS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(180);
        let quic_active_migration_enabled =
            parse_env_bool("TURBO_RELAY_QUIC_ACTIVE_MIGRATION_ENABLED", true)?;

        Ok(Self {
            quic_addr,
            tcp_addr,
            cert_pem,
            key_pem,
            shared_token,
            session_ttl: Duration::from_secs(session_ttl_seconds),
            quic_active_migration_enabled,
        })
    }
}

fn parse_env_bool(name: &str, default: bool) -> Result<bool> {
    let Some(value) = env::var(name).ok() else {
        return Ok(default);
    };
    parse_bool_value(name, &value)
}

fn parse_bool_value(name: &str, value: &str) -> Result<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(true),
        "0" | "false" | "no" | "off" => Ok(false),
        _ => Err(anyhow!("{name} must be true/false, yes/no, on/off, or 1/0")),
    }
}

async fn serve_quic(config: Config, state: RelayState) -> Result<()> {
    let mut quic_config = transport_quic::server_config(
        &config.cert_pem,
        &config.key_pem,
        config.quic_active_migration_enabled,
    )?;
    let socket = UdpSocket::bind(config.quic_addr)
        .await
        .context("failed to bind QUIC endpoint")?;
    let local_addr = socket
        .local_addr()
        .context("failed to read QUIC endpoint address")?;
    let (command_tx, mut command_rx) = mpsc::unbounded_channel::<QuicheCommand>();
    let mut connections: HashMap<Vec<u8>, QuicheConnection> = HashMap::new();
    let mut recv_buf = vec![0u8; 65_535];
    let mut out_buf = vec![0u8; QUIC_OUT_BUF_LENGTH];

    info!(
        addr = %config.quic_addr,
        active_migration_enabled = config.quic_active_migration_enabled,
        "QUIC relay listening"
    );

    loop {
        let timeout = connections
            .values()
            .filter_map(|connection| connection.conn.timeout())
            .min()
            .unwrap_or_else(|| Duration::from_secs(60));

        tokio::select! {
            packet = socket.recv_from(&mut recv_buf) => {
                let (len, from) = packet.context("failed to read QUIC UDP packet")?;
                if let Err(error) = process_quiche_packet(
                    &socket,
                    &mut connections,
                    &mut quic_config,
                    &config,
                    &state,
                    command_tx.clone(),
                    local_addr,
                    from,
                    &mut recv_buf[..len],
                    &mut out_buf,
                ).await {
                    warn!(remote = %from, error = %error, "QUIC packet processing failed");
                }
            }
            command = command_rx.recv() => {
                if let Some(command) = command {
                    handle_quiche_command(&mut connections, command);
                }
            }
            _ = time::sleep(timeout) => {
                for connection in connections.values_mut() {
                    connection.conn.on_timeout();
                }
            }
        }

        process_quiche_connections(&mut connections, &config, &state, command_tx.clone()).await;
        flush_quiche_connections(&socket, &mut connections, &mut out_buf).await?;
        remove_closed_quiche_connections(&mut connections, &state).await;
    }
}

struct QuicheConnection {
    conn: quiche::Connection,
    key: Vec<u8>,
    remote: SocketAddr,
    streams: HashMap<u64, QuicheStream>,
    datagram_joined: Option<JoinedPeer>,
}

impl QuicheConnection {
    fn new(conn: quiche::Connection, key: Vec<u8>, remote: SocketAddr) -> Self {
        Self {
            conn,
            key,
            remote,
            streams: HashMap::new(),
            datagram_joined: None,
        }
    }

    fn datagram_endpoint(
        &self,
        command_tx: mpsc::UnboundedSender<QuicheCommand>,
    ) -> RelayDatagramEndpoint {
        RelayDatagramEndpoint::Quiche(QuicheDatagramEndpoint {
            connection_key: self.key.clone(),
            command_tx,
            max_datagram_size: self.conn.dgram_max_writable_len(),
        })
    }
}

#[derive(Default)]
struct QuicheStream {
    input: Vec<u8>,
    joined: Option<JoinedPeer>,
    pending: VecDeque<PendingStreamWrite>,
}

struct PendingStreamWrite {
    bytes: Vec<u8>,
    offset: usize,
}

enum QuicheCommand {
    SendStream {
        connection_key: Vec<u8>,
        stream_id: u64,
        line: String,
    },
    SendDatagram {
        connection_key: Vec<u8>,
        data: Bytes,
    },
}

async fn process_quiche_packet(
    socket: &UdpSocket,
    connections: &mut HashMap<Vec<u8>, QuicheConnection>,
    quic_config: &mut quiche::Config,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
    local_addr: SocketAddr,
    from: SocketAddr,
    packet: &mut [u8],
    out_buf: &mut [u8],
) -> Result<()> {
    let hdr = quiche::Header::from_slice(packet, quiche::MAX_CONN_ID_LEN)
        .context("failed to parse QUIC packet header")?;

    let key = if connections.contains_key(hdr.dcid.as_ref()) {
        hdr.dcid.to_vec()
    } else if let Some(existing_key) = connections
        .values()
        .find(|connection| connection.remote == from)
        .map(|connection| connection.key.clone())
    {
        existing_key
    } else {
        if hdr.ty != quiche::Type::Initial {
            return Err(anyhow!(
                "received non-initial packet for unknown QUIC connection"
            ));
        }

        if !quiche::version_is_supported(hdr.version) {
            let written = quiche::negotiate_version(&hdr.scid, &hdr.dcid, out_buf)
                .context("failed to write QUIC version negotiation")?;
            socket
                .send_to(&out_buf[..written], from)
                .await
                .context("failed to send QUIC version negotiation")?;
            return Ok(());
        }

        let scid_bytes = make_quiche_connection_id(&hdr, from, state.allocate_connection_id());
        let scid = quiche::ConnectionId::from_ref(&scid_bytes);
        let conn = quiche::accept(&scid, None, local_addr, from, quic_config)
            .context("failed to accept QUIC connection")?;
        info!(remote = %from, "QUIC client connected");
        connections.insert(
            scid_bytes.clone(),
            QuicheConnection::new(conn, scid_bytes.clone(), from),
        );
        scid_bytes
    };

    let Some(connection) = connections.get_mut(&key) else {
        return Err(anyhow!(
            "QUIC connection disappeared during packet processing"
        ));
    };

    let recv_info = quiche::RecvInfo {
        to: local_addr,
        from,
    };
    connection
        .conn
        .recv(packet, recv_info)
        .context("QUIC receive failed")?;

    process_quiche_connection(connection, config, state, command_tx).await;
    Ok(())
}

fn make_quiche_connection_id(
    hdr: &quiche::Header<'_>,
    from: SocketAddr,
    connection_id: u64,
) -> Vec<u8> {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    hdr.scid.hash(&mut hasher);
    hdr.dcid.hash(&mut hasher);
    from.hash(&mut hasher);
    connection_id.hash(&mut hasher);
    let hash = hasher.finish();

    let mut scid = [0u8; QUIC_CONN_ID_LEN];
    scid[..8].copy_from_slice(&connection_id.to_be_bytes());
    scid[8..].copy_from_slice(&hash.to_be_bytes());
    scid.to_vec()
}

async fn process_quiche_connections(
    connections: &mut HashMap<Vec<u8>, QuicheConnection>,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) {
    let keys: Vec<Vec<u8>> = connections.keys().cloned().collect();
    for key in keys {
        let Some(connection) = connections.get_mut(&key) else {
            continue;
        };
        process_quiche_connection(connection, config, state, command_tx.clone()).await;
    }
}

async fn process_quiche_connection(
    connection: &mut QuicheConnection,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) {
    if !(connection.conn.is_established() || connection.conn.is_in_early_data()) {
        return;
    }

    if let Err(error) =
        process_quiche_datagrams(connection, config, state, command_tx.clone()).await
    {
        warn!(remote = %connection.remote, error = %error, "QUIC datagram path failed");
    }

    if let Err(error) = process_quiche_streams(connection, config, state, command_tx).await {
        warn!(remote = %connection.remote, error = %error, "QUIC stream processing failed");
    }
}

async fn process_quiche_datagrams(
    connection: &mut QuicheConnection,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) -> Result<()> {
    while let Ok(datagram) = connection.conn.dgram_recv_buf() {
        let datagram = Bytes::copy_from_slice(datagram.as_ref());
        let frame: RelayFrame =
            parse_relay_datagram_frame(datagram.as_ref()).map_err(anyhow::Error::msg)?;

        if let Some(joined) = connection.datagram_joined.clone() {
            if joined.matches_datagram_join(&frame) {
                let endpoint = connection.datagram_endpoint(command_tx.clone());
                send_datagram_join_ack(&endpoint, &joined)?;
                continue;
            }
            handle_datagram_frame(frame, &datagram, state, &joined).await?;
            continue;
        }

        let endpoint = connection.datagram_endpoint(command_tx.clone());
        let datagram_join = handle_datagram_join(frame, config, state, endpoint).await?;
        let ack_endpoint = connection.datagram_endpoint(command_tx.clone());
        if let Err(error) = send_datagram_join_ack(&ack_endpoint, &datagram_join) {
            remove_datagram_peer(state, &datagram_join).await;
            return Err(error);
        }
        connection.datagram_joined = Some(datagram_join);
    }

    Ok(())
}

async fn process_quiche_streams(
    connection: &mut QuicheConnection,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) -> Result<()> {
    let readable: Vec<u64> = connection.conn.readable().collect();
    let mut stream_buf = [0u8; QUIC_STREAM_RECV_BUF_LENGTH];

    for stream_id in readable {
        loop {
            match connection.conn.stream_recv(stream_id, &mut stream_buf) {
                Ok((read, _fin)) => {
                    if read == 0 {
                        break;
                    }
                    let lines = collect_quiche_stream_lines(
                        connection
                            .streams
                            .entry(stream_id)
                            .or_insert_with(QuicheStream::default),
                        &stream_buf[..read],
                    )?;
                    for line in lines {
                        process_quiche_stream_line(
                            connection,
                            stream_id,
                            line,
                            config,
                            state,
                            command_tx.clone(),
                        )
                        .await?;
                    }
                }
                Err(quiche::Error::Done) => break,
                Err(error) => return Err(anyhow!("stream {stream_id} receive failed: {error}")),
            }
        }
    }

    Ok(())
}

fn collect_quiche_stream_lines(stream: &mut QuicheStream, bytes: &[u8]) -> Result<Vec<String>> {
    stream.input.extend_from_slice(bytes);
    if stream.input.len() > MAX_RELAY_LINE_LENGTH {
        return Err(anyhow!("QUIC stream line exceeded relay line limit"));
    }

    let mut lines = Vec::new();
    while let Some(index) = stream.input.iter().position(|byte| *byte == b'\n') {
        let mut line = stream.input.drain(..=index).collect::<Vec<_>>();
        if line.last() == Some(&b'\n') {
            line.pop();
        }
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        lines.push(String::from_utf8(line).context("QUIC stream line was not UTF-8")?);
    }
    Ok(lines)
}

async fn process_quiche_stream_line(
    connection: &mut QuicheConnection,
    stream_id: u64,
    line: String,
    config: &Config,
    state: &RelayState,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) -> Result<()> {
    let joined = connection
        .streams
        .get(&stream_id)
        .and_then(|stream| stream.joined.clone());

    if let Some(joined) = joined {
        handle_inbound_frame(&line, state, &joined).await?;
        return Ok(());
    }

    let (tx, rx) = mpsc::channel::<String>(128);
    spawn_quiche_stream_forwarder(connection.key.clone(), stream_id, rx, command_tx);
    let joined = handle_join(&line, config, state, RelayTransport::Quic, tx).await?;
    let stream = connection
        .streams
        .entry(stream_id)
        .or_insert_with(QuicheStream::default);
    stream.joined = Some(joined.clone());
    queue_quiche_stream_line(
        stream,
        serde_json::to_string(&RelayFrame::JoinAck {
            session_id: joined.session_id,
            device_id: joined.device_id,
            transport: RelayTransport::Quic,
        })?,
    );

    Ok(())
}

fn spawn_quiche_stream_forwarder(
    connection_key: Vec<u8>,
    stream_id: u64,
    mut rx: mpsc::Receiver<String>,
    command_tx: mpsc::UnboundedSender<QuicheCommand>,
) {
    tokio::spawn(async move {
        while let Some(line) = rx.recv().await {
            if command_tx
                .send(QuicheCommand::SendStream {
                    connection_key: connection_key.clone(),
                    stream_id,
                    line,
                })
                .is_err()
            {
                break;
            }
        }
    });
}

fn handle_quiche_command(
    connections: &mut HashMap<Vec<u8>, QuicheConnection>,
    command: QuicheCommand,
) {
    match command {
        QuicheCommand::SendStream {
            connection_key,
            stream_id,
            line,
        } => {
            let Some(connection) = connections.get_mut(&connection_key) else {
                return;
            };
            let stream = connection
                .streams
                .entry(stream_id)
                .or_insert_with(QuicheStream::default);
            queue_quiche_stream_line(stream, line);
        }
        QuicheCommand::SendDatagram {
            connection_key,
            data,
        } => {
            let Some(connection) = connections.get_mut(&connection_key) else {
                return;
            };
            if let Err(error) = connection.conn.dgram_send(data.as_ref()) {
                warn!(
                    remote = %connection.remote,
                    error = %error,
                    "failed to enqueue QUIC datagram"
                );
            }
        }
    }
}

fn queue_quiche_stream_line(stream: &mut QuicheStream, line: String) {
    let mut bytes = line.into_bytes();
    bytes.push(b'\n');
    stream
        .pending
        .push_back(PendingStreamWrite { bytes, offset: 0 });
}

async fn flush_quiche_connections(
    socket: &UdpSocket,
    connections: &mut HashMap<Vec<u8>, QuicheConnection>,
    out_buf: &mut [u8],
) -> Result<()> {
    for connection in connections.values_mut() {
        flush_quiche_streams(connection);
        loop {
            let (written, send_info) = match connection.conn.send(out_buf) {
                Ok(value) => value,
                Err(quiche::Error::Done) => break,
                Err(error) => {
                    warn!(
                        remote = %connection.remote,
                        error = %error,
                        "QUIC send failed"
                    );
                    let _ = connection.conn.close(false, 0x1, b"send failed");
                    break;
                }
            };
            socket
                .send_to(&out_buf[..written], send_info.to)
                .await
                .context("failed to send QUIC UDP packet")?;
        }
    }
    Ok(())
}

fn flush_quiche_streams(connection: &mut QuicheConnection) {
    let stream_ids: Vec<u64> = connection.streams.keys().copied().collect();
    for stream_id in stream_ids {
        let Some(stream) = connection.streams.get_mut(&stream_id) else {
            continue;
        };
        while let Some(pending) = stream.pending.front_mut() {
            let remaining = &pending.bytes[pending.offset..];
            match connection.conn.stream_send(stream_id, remaining, false) {
                Ok(written) => {
                    pending.offset += written;
                    if pending.offset >= pending.bytes.len() {
                        stream.pending.pop_front();
                    } else {
                        break;
                    }
                }
                Err(quiche::Error::Done) => break,
                Err(error) => {
                    warn!(
                        remote = %connection.remote,
                        stream_id,
                        error = %error,
                        "failed to write QUIC stream frame"
                    );
                    stream.pending.pop_front();
                    break;
                }
            }
        }
    }
}

async fn remove_closed_quiche_connections(
    connections: &mut HashMap<Vec<u8>, QuicheConnection>,
    state: &RelayState,
) {
    let closed_keys: Vec<Vec<u8>> = connections
        .iter()
        .filter_map(|(key, connection)| connection.conn.is_closed().then_some(key.clone()))
        .collect();

    for key in closed_keys {
        let Some(connection) = connections.remove(&key) else {
            continue;
        };
        for stream in connection.streams.values() {
            if let Some(joined) = &stream.joined {
                remove_peer(state, joined).await;
            }
        }
        if let Some(joined) = &connection.datagram_joined {
            remove_datagram_peer(state, joined).await;
        }
        info!(remote = %connection.remote, "QUIC client disconnected");
    }
}

async fn serve_tcp_tls(config: Config, state: RelayState) -> Result<()> {
    let tls_config = transport_tcp::server_config(&config.cert_pem, &config.key_pem)?;
    let acceptor = TlsAcceptor::from(Arc::new(tls_config));
    let listener = TcpListener::bind(config.tcp_addr)
        .await
        .context("failed to bind TCP/TLS endpoint")?;
    info!(addr = %config.tcp_addr, "TCP/TLS relay listening");

    loop {
        let (stream, remote) = listener.accept().await?;
        let acceptor = acceptor.clone();
        let config = config.clone();
        let state = state.clone();
        tokio::spawn(async move {
            match acceptor.accept(stream).await {
                Ok(stream) => {
                    info!(remote = %remote, "TCP/TLS client connected");
                    if let Err(error) = handle_tcp_tls_stream(stream, config, state).await {
                        warn!(remote = %remote, error = %error, "TCP/TLS client closed");
                    }
                }
                Err(error) => warn!(remote = %remote, error = %error, "TCP/TLS handshake failed"),
            }
        });
    }
}

async fn handle_tcp_tls_stream<S>(stream: S, config: Config, state: RelayState) -> Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (tx, mut rx) = mpsc::channel::<String>(128);
    let mut framed = Framed::new(stream, relay_lines_codec());

    let first = framed
        .next()
        .await
        .ok_or_else(|| anyhow!("stream closed before join"))?
        .context("invalid join line")?;
    let joined = handle_join(&first, &config, &state, RelayTransport::TcpTls, tx).await?;
    framed
        .send(serde_json::to_string(&RelayFrame::JoinAck {
            session_id: joined.session_id.clone(),
            device_id: joined.device_id.clone(),
            transport: RelayTransport::TcpTls,
        })?)
        .await
        .context("failed to write TCP/TLS join ack")?;

    loop {
        tokio::select! {
            outbound = rx.recv() => {
                let Some(outbound) = outbound else { break; };
                framed.send(outbound).await.context("failed to write TCP/TLS frame")?;
            }
            inbound = framed.next() => {
                let Some(inbound) = inbound else { break; };
                let inbound = inbound.context("invalid TCP/TLS line")?;
                handle_inbound_frame(&inbound, &state, &joined).await?;
            }
        }
    }

    remove_peer(&state, &joined).await;
    Ok(())
}

async fn handle_join(
    line: &str,
    config: &Config,
    state: &RelayState,
    transport: RelayTransport,
    tx: mpsc::Sender<String>,
) -> Result<JoinedPeer> {
    let frame: RelayFrame = serde_json::from_str(line).context("join frame was not JSON")?;
    let RelayFrame::Join {
        session_id,
        device_id,
        peer_device_id,
        token,
    } = frame
    else {
        return Err(anyhow!("first frame must be join"));
    };
    validate_join_token(&config.shared_token, &token)?;
    validate_id("session_id", &session_id)?;
    validate_id("device_id", &device_id)?;
    validate_id("peer_device_id", &peer_device_id)?;

    let joined = JoinedPeer::new(
        session_id,
        device_id,
        peer_device_id,
        state.allocate_connection_id(),
    );

    let mut sessions = state.sessions.lock().await;
    let session = sessions
        .entry(joined.session_id.clone())
        .or_insert_with(|| RelaySession {
            peers: HashMap::new(),
            expires_at: Instant::now() + config.session_ttl,
        });
    session.expires_at = Instant::now() + config.session_ttl;
    let now = Instant::now();
    let peer = session
        .peers
        .entry(joined.device_id.clone())
        .or_insert_with(|| RelayPeer {
            peer_device_id: joined.peer_device_id.clone(),
            stream: None,
            datagram: None,
            last_seen: now,
        });
    peer.peer_device_id = joined.peer_device_id.clone();
    peer.last_seen = now;
    peer.stream = Some(RelayStreamPeer {
        connection_id: joined.connection_id,
        tx,
        last_seen: now,
    });
    info!(
        session_id = %joined.session_id,
        device_id = %joined.device_id,
        peer_device_id = %joined.peer_device_id,
        connection_id = joined.connection_id,
        transport = ?transport,
        "peer joined relay session"
    );

    Ok(joined)
}

async fn handle_inbound_frame(line: &str, state: &RelayState, joined: &JoinedPeer) -> Result<()> {
    let frame: RelayFrame = serde_json::from_str(line).context("frame was not JSON")?;
    let (session_id, sender_device_id, frame_kind) = match &frame {
        RelayFrame::TcpAudio {
            session_id,
            sender_device_id,
            sequence_number: _,
            sent_at_ms: _,
            payload: _,
        } => (session_id, sender_device_id, "tcp-audio"),
        RelayFrame::Control {
            session_id,
            sender_device_id,
            kind: _,
            payload: _,
        } => (session_id, sender_device_id, "control"),
        _ => return Ok(()),
    };

    if !joined.matches_sender(session_id, sender_device_id) {
        return Err(anyhow!(
            "{frame_kind} frame identity did not match joined peer"
        ));
    }

    let encoded = serde_json::to_string(&frame)?;
    let (peer_sender, local_sender) = {
        let mut sessions = state.sessions.lock().await;
        let Some(session) = sessions.get_mut(&joined.session_id) else {
            return Ok(());
        };
        let Some(local_peer) = session.peers.get_mut(&joined.device_id) else {
            return Ok(());
        };
        local_peer.last_seen = Instant::now();
        if let Some(stream) = local_peer.stream.as_mut() {
            stream.last_seen = Instant::now();
        }
        let peer_device_id = local_peer.peer_device_id.clone();
        let local_sender = local_peer.stream.as_ref().map(|stream| stream.tx.clone());
        let peer_sender = session
            .peers
            .get(&peer_device_id)
            .and_then(|peer| peer.stream.as_ref())
            .map(|stream| stream.tx.clone());
        (peer_sender, local_sender)
    };

    match peer_sender {
        Some(tx) => {
            if tx.try_send(encoded).is_err() {
                warn!(
                    session_id = %joined.session_id,
                    device_id = %joined.device_id,
                    frame_kind,
                    "dropped relay frame because peer queue was full or closed"
                );
            }
        }
        None => {
            let notice = RelayFrame::PeerUnavailable {
                session_id: joined.session_id.clone(),
                device_id: joined.peer_device_id.clone(),
            };
            if let Some(local_sender) = local_sender {
                let _ = local_sender.try_send(serde_json::to_string(&notice)?);
            }
            warn!(
                session_id = %joined.session_id,
                device_id = %joined.device_id,
                peer_device_id = %joined.peer_device_id,
                frame_kind,
                "dropped relay frame because peer is unavailable"
            );
        }
    }

    Ok(())
}

fn send_datagram_join_ack(endpoint: &RelayDatagramEndpoint, joined: &JoinedPeer) -> Result<()> {
    let ack = RelayFrame::DatagramJoinAck {
        session_id: joined.session_id.clone(),
        device_id: joined.device_id.clone(),
        transport: RelayTransport::QuicDatagram,
    };
    send_datagram_frame(endpoint, &ack, "datagram join ack")
}

async fn handle_datagram_join(
    frame: RelayFrame,
    config: &Config,
    state: &RelayState,
    endpoint: RelayDatagramEndpoint,
) -> Result<JoinedPeer> {
    let RelayFrame::DatagramJoin {
        session_id,
        device_id,
        peer_device_id,
        token,
    } = frame
    else {
        return Err(anyhow!("first datagram frame must be datagram-join"));
    };
    validate_join_token(&config.shared_token, &token)?;
    validate_id("session_id", &session_id)?;
    validate_id("device_id", &device_id)?;
    validate_id("peer_device_id", &peer_device_id)?;

    let joined = JoinedPeer::new(
        session_id,
        device_id,
        peer_device_id,
        state.allocate_connection_id(),
    );
    let now = Instant::now();

    let mut sessions = state.sessions.lock().await;
    let session = sessions
        .entry(joined.session_id.clone())
        .or_insert_with(|| RelaySession {
            peers: HashMap::new(),
            expires_at: now + config.session_ttl,
        });
    session.expires_at = now + config.session_ttl;
    let peer = session
        .peers
        .entry(joined.device_id.clone())
        .or_insert_with(|| RelayPeer {
            peer_device_id: joined.peer_device_id.clone(),
            stream: None,
            datagram: None,
            last_seen: now,
        });
    peer.peer_device_id = joined.peer_device_id.clone();
    peer.last_seen = now;
    peer.datagram = Some(RelayDatagramPeer {
        connection_id: joined.connection_id,
        endpoint,
        last_seen: now,
    });
    info!(
        session_id = %joined.session_id,
        device_id = %joined.device_id,
        peer_device_id = %joined.peer_device_id,
        connection_id = joined.connection_id,
        "peer joined relay datagram path"
    );

    Ok(joined)
}

async fn handle_datagram_frame(
    frame: RelayFrame,
    datagram: &Bytes,
    state: &RelayState,
    joined: &JoinedPeer,
) -> Result<()> {
    let (session_id, sender_device_id) = match &frame {
        RelayFrame::PacketAudio {
            session_id,
            sender_device_id,
            sequence_number: _,
            sent_at_ms: _,
            payload: _,
        }
        | RelayFrame::BinaryPacketAudio {
            session_id,
            sender_device_id,
            sequence_number: _,
            sent_at_ms: _,
            payload: _,
        } => (session_id, sender_device_id),
        _ => return Ok(()),
    };

    if !joined.matches_sender(session_id, sender_device_id) {
        return Err(anyhow!(
            "packet-audio frame identity did not match joined peer"
        ));
    }

    let (peer_endpoint, local_endpoint) = {
        let mut sessions = state.sessions.lock().await;
        let Some(session) = sessions.get_mut(&joined.session_id) else {
            return Ok(());
        };
        let Some(local_peer) = session.peers.get_mut(&joined.device_id) else {
            return Ok(());
        };
        let now = Instant::now();
        local_peer.last_seen = now;
        if let Some(datagram) = local_peer.datagram.as_mut() {
            datagram.last_seen = now;
        }
        let peer_device_id = local_peer.peer_device_id.clone();
        let local_endpoint = local_peer
            .datagram
            .as_ref()
            .map(|datagram| datagram.endpoint.clone());
        let peer_endpoint = session
            .peers
            .get(&peer_device_id)
            .and_then(|peer| peer.datagram.as_ref())
            .map(|datagram| datagram.endpoint.clone());
        (peer_endpoint, local_endpoint)
    };

    match peer_endpoint {
        Some(endpoint) => {
            if let Some(max_size) = endpoint.max_datagram_size() {
                if datagram.len() > max_size {
                    warn!(
                        session_id = %joined.session_id,
                        device_id = %joined.device_id,
                        datagram_size = datagram.len(),
                        max_size,
                        "dropped relay datagram because peer datagram size limit was exceeded"
                    );
                    return Ok(());
                }
            }
            if let Err(error) = endpoint.send_datagram(datagram.clone()) {
                warn!(
                    session_id = %joined.session_id,
                    device_id = %joined.device_id,
                    error = %error,
                    "dropped relay datagram because peer send failed"
                );
            }
        }
        None => {
            if let Some(local_endpoint) = local_endpoint {
                let notice = RelayFrame::PeerUnavailable {
                    session_id: joined.session_id.clone(),
                    device_id: joined.peer_device_id.clone(),
                };
                let _ = send_datagram_frame(&local_endpoint, &notice, "peer unavailable");
            }
            warn!(
                session_id = %joined.session_id,
                device_id = %joined.device_id,
                peer_device_id = %joined.peer_device_id,
                "dropped relay datagram because peer datagram path is unavailable"
            );
        }
    }

    Ok(())
}

fn send_datagram_frame(
    endpoint: &RelayDatagramEndpoint,
    frame: &RelayFrame,
    context: &str,
) -> Result<()> {
    let encoded = serde_json::to_vec(frame)?;
    let max_size = endpoint.max_datagram_size();
    if let Some(max_size) = max_size {
        if encoded.len() > max_size {
            return Err(anyhow!(
                "{context} exceeded datagram size limit: {} > {}",
                encoded.len(),
                max_size
            ));
        }
    }
    endpoint
        .send_datagram(Bytes::from(encoded.clone()))
        .with_context(|| {
            format!(
                "{context} send failed: encoded_size={} max_datagram_size={}",
                encoded.len(),
                max_size
                    .map(|size| size.to_string())
                    .unwrap_or_else(|| "unsupported".to_string())
            )
        })
}

async fn remove_peer(state: &RelayState, joined: &JoinedPeer) {
    let mut sessions = state.sessions.lock().await;
    if let Some(session) = sessions.get_mut(&joined.session_id) {
        let should_remove = session
            .peers
            .get(&joined.device_id)
            .and_then(|peer| peer.stream.as_ref())
            .is_some_and(|stream| joined.owns_connection(stream.connection_id));
        if !should_remove {
            info!(
                session_id = %joined.session_id,
                device_id = %joined.device_id,
                connection_id = joined.connection_id,
                "ignored stale peer removal"
            );
            return;
        }
        let remove_entry = if let Some(peer) = session.peers.get_mut(&joined.device_id) {
            peer.stream = None;
            peer.is_empty()
        } else {
            false
        };
        if remove_entry {
            session.peers.remove(&joined.device_id);
        }
        info!(
            session_id = %joined.session_id,
            device_id = %joined.device_id,
            connection_id = joined.connection_id,
            "peer left relay session"
        );
    }
}

async fn remove_datagram_peer(state: &RelayState, joined: &JoinedPeer) {
    let mut sessions = state.sessions.lock().await;
    if let Some(session) = sessions.get_mut(&joined.session_id) {
        let should_remove = session
            .peers
            .get(&joined.device_id)
            .and_then(|peer| peer.datagram.as_ref())
            .is_some_and(|datagram| joined.owns_connection(datagram.connection_id));
        if !should_remove {
            info!(
                session_id = %joined.session_id,
                device_id = %joined.device_id,
                connection_id = joined.connection_id,
                "ignored stale datagram peer removal"
            );
            return;
        }
        let remove_entry = if let Some(peer) = session.peers.get_mut(&joined.device_id) {
            peer.datagram = None;
            peer.is_empty()
        } else {
            false
        };
        if remove_entry {
            session.peers.remove(&joined.device_id);
        }
        info!(
            session_id = %joined.session_id,
            device_id = %joined.device_id,
            connection_id = joined.connection_id,
            "peer left relay datagram path"
        );
    }
}

async fn cleanup_loop(state: RelayState) {
    let mut interval = time::interval(Duration::from_secs(15));
    loop {
        interval.tick().await;
        let now = Instant::now();
        let mut sessions = state.sessions.lock().await;
        sessions.retain(|session_id, session| {
            let is_alive = session.expires_at > now && !session.peers.is_empty();
            if !is_alive {
                info!(session_id = %session_id, "expired relay session");
            }
            is_alive
        });
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Config, RelayDatagramEndpoint, RelayFrame, RelayState, RelayTransport,
        handle_datagram_join, handle_inbound_frame, handle_join, parse_bool_value,
        relay_lines_codec, remove_datagram_peer, remove_peer, send_datagram_frame,
    };
    use anyhow::Result;
    use std::{net::SocketAddr, path::PathBuf, time::Duration};
    use tokio::{sync::mpsc, time};
    use tokio_util::{bytes::BytesMut, codec::Decoder};

    #[test]
    fn relay_lines_codec_accepts_large_control_frames() -> Result<()> {
        let mut codec = relay_lines_codec();
        let payload = "a".repeat(12_000);
        let line = format!(
            "{{\"type\":\"control\",\"session_id\":\"session\",\"sender_device_id\":\"device\",\"kind\":\"receiver-prewarm-request\",\"payload\":\"{payload}\"}}\n"
        );
        let mut buffer = BytesMut::from(line.as_bytes());

        let decoded = codec
            .decode(&mut buffer)?
            .expect("expected one decoded line");

        assert_eq!(decoded, line.trim_end());
        assert!(buffer.is_empty());
        Ok(())
    }

    #[test]
    fn relay_quic_active_migration_env_bool_accepts_operator_values() -> Result<()> {
        assert!(parse_bool_value(
            "TURBO_RELAY_QUIC_ACTIVE_MIGRATION_ENABLED",
            "true"
        )?);
        assert!(parse_bool_value(
            "TURBO_RELAY_QUIC_ACTIVE_MIGRATION_ENABLED",
            "1"
        )?);
        assert!(!parse_bool_value(
            "TURBO_RELAY_QUIC_ACTIVE_MIGRATION_ENABLED",
            "off"
        )?);
        assert!(parse_bool_value("TURBO_RELAY_QUIC_ACTIVE_MIGRATION_ENABLED", "maybe").is_err());
        Ok(())
    }

    #[tokio::test]
    async fn stale_peer_removal_does_not_remove_newer_connection() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let join_line = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (old_tx, _old_rx) = mpsc::channel(1);
        let old_join =
            handle_join(&join_line, &config, &state, RelayTransport::Quic, old_tx).await?;
        let (new_tx, _new_rx) = mpsc::channel(1);
        let new_join =
            handle_join(&join_line, &config, &state, RelayTransport::Quic, new_tx).await?;

        remove_peer(&state, &old_join).await;

        let sessions = state.sessions.lock().await;
        let peer = sessions
            .get("session")
            .and_then(|session| session.peers.get("device-a"))
            .expect("newer peer should remain after stale removal");
        assert_eq!(
            peer.stream
                .as_ref()
                .expect("stream peer should remain")
                .connection_id,
            new_join.connection_id
        );
        Ok(())
    }

    #[tokio::test]
    async fn datagram_join_does_not_clobber_stream_peer() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let stream_join_line = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (stream_tx, _stream_rx) = mpsc::channel(1);
        let stream_join = handle_join(
            &stream_join_line,
            &config,
            &state,
            RelayTransport::Quic,
            stream_tx,
        )
        .await?;
        let datagram_join = handle_datagram_join(
            RelayFrame::DatagramJoin {
                session_id: "session".to_owned(),
                device_id: "device-a".to_owned(),
                peer_device_id: "device-b".to_owned(),
                token: "secret".to_owned(),
            },
            &config,
            &state,
            RelayDatagramEndpoint::Test,
        )
        .await?;

        let sessions = state.sessions.lock().await;
        let peer = sessions
            .get("session")
            .and_then(|session| session.peers.get("device-a"))
            .expect("peer should remain after both joins");
        assert_eq!(
            peer.stream
                .as_ref()
                .expect("stream peer should remain")
                .connection_id,
            stream_join.connection_id
        );
        assert_eq!(
            peer.datagram
                .as_ref()
                .expect("datagram peer should be installed")
                .connection_id,
            datagram_join.connection_id
        );
        Ok(())
    }

    #[test]
    fn datagram_send_failure_reports_context_and_limits() -> Result<()> {
        let frame = RelayFrame::DatagramJoinAck {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            transport: RelayTransport::QuicDatagram,
        };

        let error =
            send_datagram_frame(&RelayDatagramEndpoint::Failing, &frame, "datagram join ack")
                .expect_err("failing endpoint should report datagram send failure");
        let message = format!("{error:#}");

        assert!(message.contains("datagram join ack send failed"));
        assert!(message.contains("encoded_size="));
        assert!(message.contains("max_datagram_size=262144"));
        assert!(message.contains("test datagram send failure"));
        Ok(())
    }

    #[tokio::test]
    async fn tcp_audio_forwards_to_tcp_stream_peer() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let join_a = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let join_b = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-b".to_owned(),
            peer_device_id: "device-a".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (a_tx, _a_rx) = mpsc::channel(4);
        let (b_tx, mut b_rx) = mpsc::channel(4);
        let joined_a = handle_join(&join_a, &config, &state, RelayTransport::TcpTls, a_tx).await?;
        let _joined_b = handle_join(&join_b, &config, &state, RelayTransport::TcpTls, b_tx).await?;
        let audio = RelayFrame::TcpAudio {
            session_id: "session".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 7,
            sent_at_ms: 123_456,
            payload: "encrypted-payload".to_owned(),
        };

        handle_inbound_frame(&serde_json::to_string(&audio)?, &state, &joined_a).await?;

        let forwarded = time::timeout(Duration::from_secs(1), b_rx.recv())
            .await?
            .expect("peer should receive TCP audio frame");
        let forwarded: RelayFrame = serde_json::from_str(&forwarded)?;
        assert!(matches!(
            forwarded,
            RelayFrame::TcpAudio {
                sequence_number: 7,
                ..
            }
        ));
        Ok(())
    }

    #[tokio::test]
    async fn tcp_audio_forwards_to_quic_stream_peer() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let join_a = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let join_b = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-b".to_owned(),
            peer_device_id: "device-a".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (a_tx, _a_rx) = mpsc::channel(4);
        let (b_tx, mut b_rx) = mpsc::channel(4);
        let joined_a = handle_join(&join_a, &config, &state, RelayTransport::TcpTls, a_tx).await?;
        let _joined_b = handle_join(&join_b, &config, &state, RelayTransport::Quic, b_tx).await?;
        let audio = RelayFrame::TcpAudio {
            session_id: "session".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 7,
            sent_at_ms: 123_456,
            payload: "encrypted-payload".to_owned(),
        };

        handle_inbound_frame(&serde_json::to_string(&audio)?, &state, &joined_a).await?;

        let forwarded = time::timeout(Duration::from_secs(1), b_rx.recv())
            .await?
            .expect("QUIC stream peer should receive ordered audio frame");
        let forwarded: RelayFrame = serde_json::from_str(&forwarded)?;
        assert!(matches!(
            forwarded,
            RelayFrame::TcpAudio {
                sequence_number: 7,
                ..
            }
        ));
        Ok(())
    }

    #[tokio::test]
    async fn tcp_audio_can_originate_on_quic_stream() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let join_line = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let join_b = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-b".to_owned(),
            peer_device_id: "device-a".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (a_tx, _a_rx) = mpsc::channel(4);
        let (b_tx, mut b_rx) = mpsc::channel(4);
        let joined = handle_join(&join_line, &config, &state, RelayTransport::Quic, a_tx).await?;
        let _joined_b = handle_join(&join_b, &config, &state, RelayTransport::Quic, b_tx).await?;
        let audio = RelayFrame::TcpAudio {
            session_id: "session".to_owned(),
            sender_device_id: "device-a".to_owned(),
            sequence_number: 7,
            sent_at_ms: 123_456,
            payload: "encrypted-payload".to_owned(),
        };

        handle_inbound_frame(&serde_json::to_string(&audio)?, &state, &joined).await?;

        let forwarded = time::timeout(Duration::from_secs(1), b_rx.recv())
            .await?
            .expect("QUIC stream peer should receive ordered audio frame");
        let forwarded: RelayFrame = serde_json::from_str(&forwarded)?;
        assert!(matches!(
            forwarded,
            RelayFrame::TcpAudio {
                sequence_number: 7,
                ..
            }
        ));
        Ok(())
    }

    #[tokio::test]
    async fn stale_datagram_removal_preserves_newer_datagram_and_stream() -> Result<()> {
        let config = Config {
            quic_addr: SocketAddr::from(([127, 0, 0, 1], 9443)),
            tcp_addr: SocketAddr::from(([127, 0, 0, 1], 9444)),
            cert_pem: PathBuf::from("unused-cert.pem"),
            key_pem: PathBuf::from("unused-key.pem"),
            shared_token: "secret".to_owned(),
            session_ttl: Duration::from_secs(60),
            quic_active_migration_enabled: true,
        };
        let state = RelayState::new();
        let join_line = serde_json::to_string(&RelayFrame::Join {
            session_id: "session".to_owned(),
            device_id: "device-a".to_owned(),
            peer_device_id: "device-b".to_owned(),
            token: "secret".to_owned(),
        })?;
        let (stream_tx, _stream_rx) = mpsc::channel(1);
        let stream_join =
            handle_join(&join_line, &config, &state, RelayTransport::Quic, stream_tx).await?;
        let old_datagram_join = handle_datagram_join(
            RelayFrame::DatagramJoin {
                session_id: "session".to_owned(),
                device_id: "device-a".to_owned(),
                peer_device_id: "device-b".to_owned(),
                token: "secret".to_owned(),
            },
            &config,
            &state,
            RelayDatagramEndpoint::Test,
        )
        .await?;
        let new_datagram_join = handle_datagram_join(
            RelayFrame::DatagramJoin {
                session_id: "session".to_owned(),
                device_id: "device-a".to_owned(),
                peer_device_id: "device-b".to_owned(),
                token: "secret".to_owned(),
            },
            &config,
            &state,
            RelayDatagramEndpoint::Test,
        )
        .await?;

        remove_datagram_peer(&state, &old_datagram_join).await;

        let sessions = state.sessions.lock().await;
        let peer = sessions
            .get("session")
            .and_then(|session| session.peers.get("device-a"))
            .expect("peer should remain after stale datagram removal");
        assert_eq!(
            peer.stream
                .as_ref()
                .expect("stream peer should remain")
                .connection_id,
            stream_join.connection_id
        );
        assert_eq!(
            peer.datagram
                .as_ref()
                .expect("newer datagram peer should remain")
                .connection_id,
            new_datagram_join.connection_id
        );
        Ok(())
    }
}
