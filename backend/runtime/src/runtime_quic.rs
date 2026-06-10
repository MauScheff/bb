use std::{
    collections::{BTreeMap, VecDeque, hash_map::DefaultHasher},
    hash::{Hash, Hasher},
    net::{SocketAddr, UdpSocket},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use crate::{
    control_protocol::{
        RuntimeControlCommandFrame, RuntimeControlPeerIdentity, RuntimeControlTransport,
    },
    control_stream::{
        RuntimeControlIdentityBinding, runtime_control_response_for_line,
        runtime_control_response_for_line_with_identity_binding,
    },
    http::RuntimeHttpService,
    postgres::{
        DurableAlertPushTokenStore, DurableBeepThreadStore, DurableContactStore,
        KernelDecisionCommitter, RequestTalkTurnKernelWorker, RequestTalkTurnSnapshotLoader,
        TalkTurnReleaseCommitter, TalkTurnRenewalCommitter,
    },
    quic_protocol::runtime_quic_alpn,
    server::handle_authenticated_runtime_control_frame,
};

pub const RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE: usize = 1350;
pub const RUNTIME_QUIC_STREAM_RECV_BUF_LENGTH: usize = 4096;
pub const RUNTIME_QUIC_MAX_CONTROL_LINE_LENGTH: usize = 64 * 1024;
pub const RUNTIME_QUIC_CONN_ID_LEN: usize = 16;
pub const RUNTIME_QUIC_OUT_BUF_LENGTH: usize = 65_535;

#[derive(Debug, thiserror::Error)]
pub enum RuntimeQuicError {
    #[error("runtime QUIC config failed: {0}")]
    Config(String),
    #[error("runtime QUIC certificate failed: {0}")]
    Certificate(String),
    #[error("runtime QUIC stream failed: {0}")]
    Stream(String),
    #[error("runtime QUIC peer was not authenticated")]
    UnauthenticatedPeer,
    #[error("runtime QUIC packet was rejected: {0}")]
    Packet(String),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct RuntimeQuicServerConfig {
    pub active_migration_enabled: bool,
    pub max_idle_timeout: Duration,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeQuicOutboundPacket {
    pub destination: SocketAddr,
    pub bytes: Vec<u8>,
}

impl Default for RuntimeQuicServerConfig {
    fn default() -> Self {
        Self {
            active_migration_enabled: true,
            max_idle_timeout: Duration::from_secs(120),
        }
    }
}

pub fn server_config(
    cert_pem: &Path,
    key_pem: &Path,
    config: RuntimeQuicServerConfig,
) -> Result<quiche::Config, RuntimeQuicError> {
    let mut quic_config = quiche::Config::new(quiche::PROTOCOL_VERSION)
        .map_err(|error| RuntimeQuicError::Config(error.to_string()))?;
    quic_config
        .load_cert_chain_from_pem_file(path_as_utf8(cert_pem, "runtime QUIC cert")?)
        .map_err(|error| RuntimeQuicError::Certificate(error.to_string()))?;
    quic_config
        .load_priv_key_from_pem_file(path_as_utf8(key_pem, "runtime QUIC key")?)
        .map_err(|error| RuntimeQuicError::Certificate(error.to_string()))?;
    quic_config
        .set_application_protos(&[runtime_quic_alpn()])
        .map_err(|error| RuntimeQuicError::Config(error.to_string()))?;
    quic_config.set_max_idle_timeout(config.max_idle_timeout.as_millis() as u64);
    quic_config.set_max_recv_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
    quic_config.set_max_send_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
    quic_config.set_initial_max_data(1_000_000);
    quic_config.set_initial_max_stream_data_bidi_local(256_000);
    quic_config.set_initial_max_stream_data_bidi_remote(256_000);
    quic_config.set_initial_max_stream_data_uni(256_000);
    quic_config.set_initial_max_streams_bidi(32);
    quic_config.set_initial_max_streams_uni(32);
    quic_config
        .set_disable_active_migration(disable_active_migration(config.active_migration_enabled));
    Ok(quic_config)
}

pub fn disable_active_migration(active_migration_enabled: bool) -> bool {
    !active_migration_enabled
}

pub fn serve_forever_runtime_quic_control<S, W, C>(
    socket: UdpSocket,
    mut quic_config: quiche::Config,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeQuicError>
where
    S: RequestTalkTurnSnapshotLoader + Send + 'static,
    W: RequestTalkTurnKernelWorker + Send + 'static,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableAlertPushTokenStore
        + DurableBeepThreadStore
        + Send
        + 'static,
{
    let local_addr = socket
        .local_addr()
        .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
    let mut endpoint = RuntimeQuicControlEndpoint::default();
    let mut buffer = [0_u8; 65_535];

    loop {
        let (read, from) = socket
            .recv_from(&mut buffer)
            .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
        let outbound = endpoint.receive_packet_with_identity_binding(
            &mut buffer[..read],
            local_addr,
            from,
            &mut quic_config,
            service.clone(),
        )?;
        for packet in outbound {
            socket
                .send_to(&packet.bytes, packet.destination)
                .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
        }
    }
}

#[derive(Debug, Default)]
pub struct RuntimeQuicControlStreams {
    streams: BTreeMap<u64, RuntimeQuicControlStream>,
}

#[derive(Default)]
pub struct RuntimeQuicControlEndpoint {
    connections: BTreeMap<Vec<u8>, RuntimeQuicControlConnection>,
    next_connection_id: u64,
}

struct RuntimeQuicControlConnection {
    conn: quiche::Connection,
    streams: RuntimeQuicControlStreams,
    remote: SocketAddr,
}

#[derive(Debug, Default)]
struct RuntimeQuicControlStream {
    input: Vec<u8>,
    identity_binding: RuntimeControlIdentityBinding,
    pending: VecDeque<PendingStreamWrite>,
}

#[derive(Debug)]
struct PendingStreamWrite {
    bytes: Vec<u8>,
    offset: usize,
}

impl RuntimeQuicControlStreams {
    pub fn process_readable<F>(
        &mut self,
        connection: &mut quiche::Connection,
        mut handle: F,
    ) -> Result<usize, RuntimeQuicError>
    where
        F: FnMut(&RuntimeControlCommandFrame) -> Result<serde_json::Value, String>,
    {
        let readable = connection.readable().collect::<Vec<_>>();
        let mut processed_count = 0;
        let mut stream_buf = [0_u8; RUNTIME_QUIC_STREAM_RECV_BUF_LENGTH];

        for stream_id in readable {
            loop {
                match connection.stream_recv(stream_id, &mut stream_buf) {
                    Ok((read, _fin)) => {
                        if read == 0 {
                            break;
                        }
                        let lines = self.collect_stream_lines(stream_id, &stream_buf[..read])?;
                        for line in lines {
                            let response = runtime_control_response_for_line(
                                &line,
                                RuntimeControlTransport::RuntimeQuicControl,
                                &mut handle,
                            );
                            let encoded = serde_json::to_string(&response)
                                .map_err(|error| RuntimeQuicError::Stream(error.to_string()))?;
                            self.queue_stream_line(stream_id, encoded);
                            processed_count += 1;
                        }
                    }
                    Err(quiche::Error::Done) => break,
                    Err(error) => {
                        return Err(RuntimeQuicError::Stream(format!(
                            "stream {stream_id} receive failed: {error}"
                        )));
                    }
                }
            }
        }

        Ok(processed_count)
    }

    pub fn process_readable_with_identity_binding<F>(
        &mut self,
        connection: &mut quiche::Connection,
        mut handle: F,
    ) -> Result<usize, RuntimeQuicError>
    where
        F: FnMut(
            &RuntimeControlPeerIdentity,
            &RuntimeControlCommandFrame,
        ) -> Result<serde_json::Value, String>,
    {
        let readable = connection.readable().collect::<Vec<_>>();
        let mut processed_count = 0;
        let mut stream_buf = [0_u8; RUNTIME_QUIC_STREAM_RECV_BUF_LENGTH];

        for stream_id in readable {
            loop {
                match connection.stream_recv(stream_id, &mut stream_buf) {
                    Ok((read, _fin)) => {
                        if read == 0 {
                            break;
                        }
                        let lines = self.collect_stream_lines(stream_id, &stream_buf[..read])?;
                        for line in lines {
                            let stream = self.streams.entry(stream_id).or_default();
                            let response = runtime_control_response_for_line_with_identity_binding(
                                &line,
                                RuntimeControlTransport::RuntimeQuicControl,
                                &mut stream.identity_binding,
                                &mut handle,
                            );
                            let encoded = serde_json::to_string(&response)
                                .map_err(|error| RuntimeQuicError::Stream(error.to_string()))?;
                            self.queue_stream_line(stream_id, encoded);
                            processed_count += 1;
                        }
                    }
                    Err(quiche::Error::Done) => break,
                    Err(error) => {
                        return Err(RuntimeQuicError::Stream(format!(
                            "stream {stream_id} receive failed: {error}"
                        )));
                    }
                }
            }
        }

        Ok(processed_count)
    }

    pub fn flush_pending(
        &mut self,
        connection: &mut quiche::Connection,
    ) -> Result<(), RuntimeQuicError> {
        let stream_ids = self.streams.keys().copied().collect::<Vec<_>>();
        for stream_id in stream_ids {
            let Some(stream) = self.streams.get_mut(&stream_id) else {
                continue;
            };
            while let Some(pending) = stream.pending.front_mut() {
                let remaining = &pending.bytes[pending.offset..];
                match connection.stream_send(stream_id, remaining, false) {
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
                        return Err(RuntimeQuicError::Stream(format!(
                            "stream {stream_id} send failed: {error}"
                        )));
                    }
                }
            }
        }
        Ok(())
    }

    fn collect_stream_lines(
        &mut self,
        stream_id: u64,
        bytes: &[u8],
    ) -> Result<Vec<String>, RuntimeQuicError> {
        let stream = self.streams.entry(stream_id).or_default();
        stream.input.extend_from_slice(bytes);
        if stream.input.len() > RUNTIME_QUIC_MAX_CONTROL_LINE_LENGTH {
            return Err(RuntimeQuicError::Stream(
                "runtime QUIC control line exceeded maximum length".to_owned(),
            ));
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
            lines.push(
                String::from_utf8(line)
                    .map_err(|error| RuntimeQuicError::Stream(error.to_string()))?,
            );
        }
        Ok(lines)
    }

    fn queue_stream_line(&mut self, stream_id: u64, line: String) {
        let mut bytes = line.into_bytes();
        bytes.push(b'\n');
        self.streams
            .entry(stream_id)
            .or_default()
            .pending
            .push_back(PendingStreamWrite { bytes, offset: 0 });
    }
}

impl RuntimeQuicControlEndpoint {
    pub fn receive_packet_with_identity_binding<S, W, C>(
        &mut self,
        packet: &mut [u8],
        local_addr: SocketAddr,
        from: SocketAddr,
        quic_config: &mut quiche::Config,
        service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
    ) -> Result<Vec<RuntimeQuicOutboundPacket>, RuntimeQuicError>
    where
        S: RequestTalkTurnSnapshotLoader + Send + 'static,
        W: RequestTalkTurnKernelWorker + Send + 'static,
        C: KernelDecisionCommitter
            + TalkTurnRenewalCommitter
            + TalkTurnReleaseCommitter
            + DurableContactStore
            + DurableAlertPushTokenStore
            + DurableBeepThreadStore
            + Send
            + 'static,
    {
        let header = quiche::Header::from_slice(packet, quiche::MAX_CONN_ID_LEN)
            .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
        let key = if self.connections.contains_key(header.dcid.as_ref()) {
            header.dcid.to_vec()
        } else if let Some(existing_key) = self
            .connections
            .iter()
            .find_map(|(key, connection)| (connection.remote == from).then_some(key.clone()))
        {
            existing_key
        } else {
            if header.ty != quiche::Type::Initial {
                return Err(RuntimeQuicError::Packet(
                    "received non-initial packet for unknown runtime QUIC connection".to_owned(),
                ));
            }

            if !quiche::version_is_supported(header.version) {
                let mut out = [0_u8; RUNTIME_QUIC_OUT_BUF_LENGTH];
                let written = quiche::negotiate_version(&header.scid, &header.dcid, &mut out)
                    .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
                return Ok(vec![RuntimeQuicOutboundPacket {
                    destination: from,
                    bytes: out[..written].to_vec(),
                }]);
            }

            let scid_bytes = self.make_connection_id(&header, from);
            let scid = quiche::ConnectionId::from_ref(&scid_bytes);
            let conn = quiche::accept(&scid, None, local_addr, from, quic_config)
                .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
            self.connections.insert(
                scid_bytes.clone(),
                RuntimeQuicControlConnection {
                    conn,
                    streams: RuntimeQuicControlStreams::default(),
                    remote: from,
                },
            );
            scid_bytes
        };

        let Some(connection) = self.connections.get_mut(&key) else {
            return Err(RuntimeQuicError::Packet(
                "runtime QUIC connection disappeared during packet processing".to_owned(),
            ));
        };
        connection
            .conn
            .recv(
                packet,
                quiche::RecvInfo {
                    to: local_addr,
                    from,
                },
            )
            .map_err(|error| RuntimeQuicError::Packet(error.to_string()))?;
        connection.remote = from;

        if connection.conn.is_established() || connection.conn.is_in_early_data() {
            process_runtime_quic_control_streams_with_identity_binding(
                &mut connection.streams,
                &mut connection.conn,
                service,
            )?;
            connection.streams.flush_pending(&mut connection.conn)?;
        }

        self.flush_outbound()
    }

    pub fn flush_outbound(&mut self) -> Result<Vec<RuntimeQuicOutboundPacket>, RuntimeQuicError> {
        let mut output = Vec::new();
        let keys = self.connections.keys().cloned().collect::<Vec<_>>();
        let mut out = [0_u8; RUNTIME_QUIC_OUT_BUF_LENGTH];

        for key in keys {
            let Some(connection) = self.connections.get_mut(&key) else {
                continue;
            };
            connection.streams.flush_pending(&mut connection.conn)?;
            loop {
                match connection.conn.send(&mut out) {
                    Ok((written, send_info)) => output.push(RuntimeQuicOutboundPacket {
                        destination: send_info.to,
                        bytes: out[..written].to_vec(),
                    }),
                    Err(quiche::Error::Done) => break,
                    Err(error) => {
                        let _ = connection
                            .conn
                            .close(false, 0x1, b"runtime quic send failed");
                        return Err(RuntimeQuicError::Packet(error.to_string()));
                    }
                }
            }
        }

        self.remove_closed();
        Ok(output)
    }

    fn make_connection_id(&mut self, header: &quiche::Header<'_>, from: SocketAddr) -> Vec<u8> {
        self.next_connection_id += 1;
        let connection_id = self.next_connection_id;
        let mut hasher = DefaultHasher::new();
        header.scid.hash(&mut hasher);
        header.dcid.hash(&mut hasher);
        from.hash(&mut hasher);
        connection_id.hash(&mut hasher);
        let hash = hasher.finish();

        let mut scid = [0_u8; RUNTIME_QUIC_CONN_ID_LEN];
        scid[..8].copy_from_slice(&connection_id.to_be_bytes());
        scid[8..].copy_from_slice(&hash.to_be_bytes());
        scid.to_vec()
    }

    fn remove_closed(&mut self) {
        let closed = self
            .connections
            .iter()
            .filter_map(|(key, connection)| connection.conn.is_closed().then_some(key.clone()))
            .collect::<Vec<_>>();
        for key in closed {
            self.connections.remove(&key);
        }
    }
}

pub fn process_runtime_quic_control_streams_with_identity_binding<S, W, C>(
    streams: &mut RuntimeQuicControlStreams,
    connection: &mut quiche::Connection,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<usize, RuntimeQuicError>
where
    S: RequestTalkTurnSnapshotLoader + Send + 'static,
    W: RequestTalkTurnKernelWorker + Send + 'static,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableAlertPushTokenStore
        + DurableBeepThreadStore
        + Send
        + 'static,
{
    streams.process_readable_with_identity_binding(connection, |identity, frame| {
        handle_authenticated_runtime_control_frame(
            &service,
            &identity.participant_id,
            &identity.device_id,
            frame,
        )
    })
}

pub fn process_authenticated_runtime_quic_control_streams<S, W, C>(
    streams: &mut RuntimeQuicControlStreams,
    connection: &mut quiche::Connection,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
    identity: RuntimeControlPeerIdentity,
) -> Result<usize, RuntimeQuicError>
where
    S: RequestTalkTurnSnapshotLoader + Send + 'static,
    W: RequestTalkTurnKernelWorker + Send + 'static,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableAlertPushTokenStore
        + DurableBeepThreadStore
        + Send
        + 'static,
{
    streams.process_readable(connection, |frame| {
        handle_authenticated_runtime_control_frame(
            &service,
            &identity.participant_id,
            &identity.device_id,
            frame,
        )
    })
}

fn path_as_utf8<'a>(path: &'a Path, label: &str) -> Result<&'a str, RuntimeQuicError> {
    path.to_str().ok_or_else(|| {
        RuntimeQuicError::Certificate(format!(
            "{label} path was not valid UTF-8: {}",
            PathBuf::from(path).display()
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        KernelCorpus,
        http::HttpRequest,
        postgres::{CorpusKernelDecisionWorker, InMemoryRequestTalkTurnSnapshotLoader},
        routes::SelfHostedRouteService,
    };
    use std::{
        net::SocketAddr,
        sync::atomic::{AtomicU64, Ordering},
        time::{SystemTime, UNIX_EPOCH},
    };

    static TEMP_CERT_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn runtime_service() -> Arc<
        Mutex<
            RuntimeHttpService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker>,
        >,
    > {
        let corpus = KernelCorpus { cases: Vec::new() };
        let loader = InMemoryRequestTalkTurnSnapshotLoader::default();
        let worker = CorpusKernelDecisionWorker::new(&corpus);
        Arc::new(Mutex::new(RuntimeHttpService::new(
            SelfHostedRouteService::new(loader, worker),
        )))
    }

    #[test]
    fn runtime_quic_control_uses_distinct_runtime_alpn() {
        assert_eq!(runtime_quic_alpn(), b"beep-runtime-control-v1");
        assert_ne!(
            runtime_quic_alpn(),
            relay_protocol::transport_quic::QUIC_ALPN
        );
    }

    #[test]
    fn runtime_quic_active_migration_config_maps_to_quiche_disable_flag() {
        assert!(!disable_active_migration(true));
        assert!(disable_active_migration(false));
    }

    #[test]
    fn runtime_quic_server_config_accepts_pem_cert_and_key() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);

        server_config(
            &cert_path,
            &key_path,
            RuntimeQuicServerConfig {
                active_migration_enabled: true,
                max_idle_timeout: Duration::from_secs(30),
            },
        )
        .expect("runtime QUIC config should build");

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    #[test]
    fn runtime_quic_control_stream_processes_command_over_real_quiche_connection() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let mut server_config =
            server_config(&cert_path, &key_path, RuntimeQuicServerConfig::default())
                .expect("server config should build");
        let mut client_config = client_config();
        let client_addr: SocketAddr = "127.0.0.1:44000".parse().expect("client addr");
        let server_addr: SocketAddr = "127.0.0.1:44300".parse().expect("server addr");
        let scid = quiche::ConnectionId::from_ref(&[0xba; 16]);
        let mut client = quiche::connect(
            Some("localhost"),
            &scid,
            client_addr,
            server_addr,
            &mut client_config,
        )
        .expect("client should connect");
        let mut out = [0_u8; 4096];
        let (written, _) = client.send(&mut out).expect("client initial");
        let mut initial = out[..written].to_vec();
        let _header = quiche::Header::from_slice(&mut initial, quiche::MAX_CONN_ID_LEN)
            .expect("initial header should parse");
        let server_scid = quiche::ConnectionId::from_ref(&[0xcd; 16]);
        let mut server = quiche::accept(
            &server_scid,
            None,
            server_addr,
            client_addr,
            &mut server_config,
        )
        .expect("server should accept");
        server
            .recv(
                &mut initial,
                quiche::RecvInfo {
                    to: server_addr,
                    from: client_addr,
                },
            )
            .expect("server should receive initial");

        complete_handshake(&mut client, client_addr, &mut server, server_addr);
        assert!(client.is_established());
        assert!(server.is_established());

        let request = serde_json::json!({
            "type": "control-command",
            "requestId": "quic-command-1",
            "commandKind": "join-channel",
            "deviceId": "device-a",
            "operationId": "join-op-1",
            "channelId": "channel-1",
            "generation": 9
        })
        .to_string()
            + "\n";
        client
            .stream_send(0, request.as_bytes(), false)
            .expect("client should write command stream");
        pump_packets(&mut client, client_addr, &mut server, server_addr);

        let mut streams = RuntimeQuicControlStreams::default();
        let processed = streams
            .process_readable(&mut server, |frame| {
                Ok(serde_json::json!({
                    "accepted": frame.envelope.command_kind,
                    "channelId": frame.envelope.channel_id
                }))
            })
            .expect("server should process readable stream");
        assert_eq!(processed, 1);
        streams
            .flush_pending(&mut server)
            .expect("server should queue response");
        pump_packets(&mut server, server_addr, &mut client, client_addr);

        let mut response_buf = [0_u8; 4096];
        let (read, _) = client
            .stream_recv(0, &mut response_buf)
            .expect("client should receive response stream");
        let response_line =
            std::str::from_utf8(&response_buf[..read]).expect("response should be UTF-8");
        let response = serde_json::from_str::<serde_json::Value>(response_line.trim())
            .expect("response should be JSON");

        assert_eq!(response["type"], "control-command-response");
        assert_eq!(response["transport"], "runtime-quic-control");
        assert_eq!(response["persistentTransport"], true);
        assert_eq!(response["operationId"], "join-op-1");
        assert_eq!(response["generation"], 9);
        assert_eq!(response["body"]["accepted"], "join-channel");

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    #[test]
    fn runtime_quic_control_stream_rejects_live_audio_and_keeps_stream_usable() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let mut server_config =
            server_config(&cert_path, &key_path, RuntimeQuicServerConfig::default())
                .expect("server config should build");
        let mut client_config = client_config();
        let client_addr: SocketAddr = "127.0.0.1:44001".parse().expect("client addr");
        let server_addr: SocketAddr = "127.0.0.1:44301".parse().expect("server addr");
        let (mut client, mut server) = connected_quiche_pair(
            &mut client_config,
            &mut server_config,
            client_addr,
            server_addr,
        );
        let audio_frame = serde_json::json!({
            "type": "audio-chunk",
            "requestId": "audio-1",
            "commandKind": "audio-chunk",
            "deviceId": "device-a"
        })
        .to_string();
        let command_frame = serde_json::json!({
            "type": "presence-command",
            "requestId": "presence-1",
            "commandKind": "presence-keepalive",
            "deviceId": "device-a",
            "operationId": "presence-op-1",
            "generation": 10
        })
        .to_string();
        let request = format!("{audio_frame}\n{command_frame}\n");
        client
            .stream_send(0, request.as_bytes(), false)
            .expect("client should write command stream");
        pump_packets(&mut client, client_addr, &mut server, server_addr);

        let mut streams = RuntimeQuicControlStreams::default();
        let processed = streams
            .process_readable(&mut server, |_| {
                Ok(serde_json::json!({ "status": "accepted" }))
            })
            .expect("server should process readable stream");
        assert_eq!(processed, 2);
        streams
            .flush_pending(&mut server)
            .expect("server should queue response");
        pump_packets(&mut server, server_addr, &mut client, client_addr);

        let responses = read_available_stream_lines(&mut client, 0);
        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "runtime-control-error");
        assert_eq!(responses[0]["transport"], "runtime-quic-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert!(
            responses[0]["error"]
                .as_str()
                .expect("error should be string")
                .contains("live media")
        );
        assert_eq!(responses[1]["type"], "presence-command-response");
        assert_eq!(responses[1]["operationId"], "presence-op-1");
        assert_eq!(responses[1]["generation"], 10);

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    #[test]
    fn authenticated_runtime_quic_control_stream_updates_runtime_state() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let mut server_config =
            server_config(&cert_path, &key_path, RuntimeQuicServerConfig::default())
                .expect("server config should build");
        let mut client_config = client_config();
        let client_addr: SocketAddr = "127.0.0.1:44002".parse().expect("client addr");
        let server_addr: SocketAddr = "127.0.0.1:44302".parse().expect("server addr");
        let (mut client, mut server) = connected_quiche_pair(
            &mut client_config,
            &mut server_config,
            client_addr,
            server_addr,
        );
        let service = runtime_service();
        let request = serde_json::json!({
            "type": "presence-command",
            "requestId": "presence-quic-1",
            "commandKind": "presence-foreground",
            "deviceId": "device-a",
            "operationId": "presence-op-1",
            "generation": 11
        })
        .to_string()
            + "\n";
        client
            .stream_send(0, request.as_bytes(), false)
            .expect("client should write presence command stream");
        pump_packets(&mut client, client_addr, &mut server, server_addr);

        let mut streams = RuntimeQuicControlStreams::default();
        let processed = process_authenticated_runtime_quic_control_streams(
            &mut streams,
            &mut server,
            service.clone(),
            RuntimeControlPeerIdentity {
                participant_id: "user-avery".to_owned(),
                device_id: "device-a".to_owned(),
            },
        )
        .expect("server should process authenticated runtime QUIC stream");
        assert_eq!(processed, 1);
        streams
            .flush_pending(&mut server)
            .expect("server should queue response");
        pump_packets(&mut server, server_addr, &mut client, client_addr);

        let responses = read_available_stream_lines(&mut client, 0);
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0]["type"], "presence-command-response");
        assert_eq!(responses[0]["transport"], "runtime-quic-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert_eq!(responses[0]["operationId"], "presence-op-1");
        assert_eq!(responses[0]["body"]["userId"], "user-avery");
        assert_eq!(responses[0]["body"]["deviceId"], "device-a");

        let presence = service
            .lock()
            .expect("runtime service lock should not be poisoned")
            .handle(HttpRequest {
                method: "GET".to_owned(),
                path: "/v1/users/by-handle/@avery/presence".to_owned(),
                headers: vec![("host".to_owned(), "api.beepbeep.to".to_owned())],
                body: Vec::new(),
            });

        assert_eq!(presence.status, 200);
        assert_eq!(presence.body["isOnline"], true);

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    #[test]
    fn runtime_quic_endpoint_accepts_authenticated_udp_packets_and_updates_state() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let mut server_config =
            server_config(&cert_path, &key_path, RuntimeQuicServerConfig::default())
                .expect("server config should build");
        let mut client_config = client_config();
        let client_addr: SocketAddr = "127.0.0.1:44003".parse().expect("client addr");
        let server_addr: SocketAddr = "127.0.0.1:44303".parse().expect("server addr");
        let scid = quiche::ConnectionId::from_ref(&[0xab; 16]);
        let mut client = quiche::connect(
            Some("localhost"),
            &scid,
            client_addr,
            server_addr,
            &mut client_config,
        )
        .expect("client should connect");
        let mut endpoint = RuntimeQuicControlEndpoint::default();
        let service = runtime_service();
        complete_endpoint_handshake(
            &mut client,
            client_addr,
            server_addr,
            &mut endpoint,
            &mut server_config,
            service.clone(),
        );
        assert!(client.is_established());

        let request = serde_json::json!({
            "type": "presence-command",
            "requestId": "endpoint-presence-quic-1",
            "commandKind": "presence-foreground",
            "userHandle": "@avery",
            "deviceId": "device-a",
            "operationId": "endpoint-presence-op-1",
            "generation": 12
        })
        .to_string()
            + "\n";
        client
            .stream_send(0, request.as_bytes(), false)
            .expect("client should write presence command stream");
        exchange_client_with_endpoint(
            &mut client,
            client_addr,
            server_addr,
            &mut endpoint,
            &mut server_config,
            service.clone(),
        );

        let responses = read_available_stream_lines(&mut client, 0);
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0]["type"], "presence-command-response");
        assert_eq!(responses[0]["transport"], "runtime-quic-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert_eq!(responses[0]["operationId"], "endpoint-presence-op-1");
        assert_eq!(responses[0]["body"]["userId"], "user-avery");

        let presence = service
            .lock()
            .expect("runtime service lock should not be poisoned")
            .handle(HttpRequest {
                method: "GET".to_owned(),
                path: "/v1/users/by-handle/@avery/presence".to_owned(),
                headers: vec![("host".to_owned(), "api.beepbeep.to".to_owned())],
                body: Vec::new(),
            });

        assert_eq!(presence.status, 200);
        assert_eq!(presence.body["isOnline"], true);

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    #[test]
    fn runtime_quic_endpoint_binds_identity_per_control_stream() {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let mut server_config =
            server_config(&cert_path, &key_path, RuntimeQuicServerConfig::default())
                .expect("server config should build");
        let mut client_config = client_config();
        let client_addr: SocketAddr = "127.0.0.1:44004".parse().expect("client addr");
        let server_addr: SocketAddr = "127.0.0.1:44304".parse().expect("server addr");
        let scid = quiche::ConnectionId::from_ref(&[0xac; 16]);
        let mut client = quiche::connect(
            Some("localhost"),
            &scid,
            client_addr,
            server_addr,
            &mut client_config,
        )
        .expect("client should connect");
        let mut endpoint = RuntimeQuicControlEndpoint::default();
        let service = runtime_service();
        complete_endpoint_handshake(
            &mut client,
            client_addr,
            server_addr,
            &mut endpoint,
            &mut server_config,
            service,
        );
        assert!(client.is_established());

        let avery = serde_json::json!({
            "type": "presence-command",
            "requestId": "stream-0-avery",
            "commandKind": "presence-foreground",
            "userHandle": "@avery",
            "deviceId": "device-a",
            "operationId": "stream-0-avery-op",
            "generation": 1
        })
        .to_string()
            + "\n";
        let blake = serde_json::json!({
            "type": "presence-command",
            "requestId": "stream-4-blake",
            "commandKind": "presence-foreground",
            "userHandle": "@blake",
            "deviceId": "device-b",
            "operationId": "stream-4-blake-op",
            "generation": 1
        })
        .to_string()
            + "\n";
        client
            .stream_send(0, avery.as_bytes(), false)
            .expect("client should write first identity stream");
        client
            .stream_send(4, blake.as_bytes(), false)
            .expect("client should write second identity stream");
        exchange_client_with_endpoint(
            &mut client,
            client_addr,
            server_addr,
            &mut endpoint,
            &mut server_config,
            runtime_service(),
        );

        let stream_0_responses = read_available_stream_lines(&mut client, 0);
        let stream_4_responses = read_available_stream_lines(&mut client, 4);
        assert_eq!(stream_0_responses[0]["type"], "presence-command-response");
        assert_eq!(stream_0_responses[0]["body"]["userId"], "user-avery");
        assert_eq!(stream_4_responses[0]["type"], "presence-command-response");
        assert_eq!(stream_4_responses[0]["body"]["userId"], "user-blake");

        let stream_0_mismatch = serde_json::json!({
            "type": "presence-command",
            "requestId": "stream-0-blake-mismatch",
            "commandKind": "presence-foreground",
            "userHandle": "@blake",
            "deviceId": "device-b",
            "operationId": "stream-0-blake-mismatch-op",
            "generation": 2
        })
        .to_string()
            + "\n";
        client
            .stream_send(0, stream_0_mismatch.as_bytes(), false)
            .expect("client should write mismatched identity on first stream");
        exchange_client_with_endpoint(
            &mut client,
            client_addr,
            server_addr,
            &mut endpoint,
            &mut server_config,
            runtime_service(),
        );

        let mismatch_responses = read_available_stream_lines(&mut client, 0);
        assert_eq!(mismatch_responses[0]["type"], "runtime-control-error");
        assert!(
            mismatch_responses[0]["error"]
                .as_str()
                .expect("error should be string")
                .contains("identity did not match")
        );

        let _ = std::fs::remove_file(cert_path);
        let _ = std::fs::remove_file(key_path);
    }

    fn client_config() -> quiche::Config {
        let mut config =
            quiche::Config::new(quiche::PROTOCOL_VERSION).expect("client config should build");
        config
            .set_application_protos(&[runtime_quic_alpn()])
            .expect("client ALPN should configure");
        config.verify_peer(false);
        config.set_max_idle_timeout(30_000);
        config.set_max_recv_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
        config.set_max_send_udp_payload_size(RUNTIME_QUIC_MAX_UDP_PAYLOAD_SIZE);
        config.set_initial_max_data(1_000_000);
        config.set_initial_max_stream_data_bidi_local(256_000);
        config.set_initial_max_stream_data_bidi_remote(256_000);
        config.set_initial_max_streams_bidi(32);
        config
    }

    fn connected_quiche_pair(
        client_config: &mut quiche::Config,
        server_config: &mut quiche::Config,
        client_addr: SocketAddr,
        server_addr: SocketAddr,
    ) -> (quiche::Connection, quiche::Connection) {
        let scid = quiche::ConnectionId::from_ref(&[0xba; 16]);
        let mut client = quiche::connect(
            Some("localhost"),
            &scid,
            client_addr,
            server_addr,
            client_config,
        )
        .expect("client should connect");
        let mut out = [0_u8; 4096];
        let (written, _) = client.send(&mut out).expect("client initial");
        let mut initial = out[..written].to_vec();
        let _header = quiche::Header::from_slice(&mut initial, quiche::MAX_CONN_ID_LEN)
            .expect("initial header should parse");
        let server_scid = quiche::ConnectionId::from_ref(&[0xcd; 16]);
        let mut server =
            quiche::accept(&server_scid, None, server_addr, client_addr, server_config)
                .expect("server should accept");
        server
            .recv(
                &mut initial,
                quiche::RecvInfo {
                    to: server_addr,
                    from: client_addr,
                },
            )
            .expect("server should receive initial");
        complete_handshake(&mut client, client_addr, &mut server, server_addr);
        assert!(client.is_established());
        assert!(server.is_established());
        (client, server)
    }

    fn complete_endpoint_handshake(
        client: &mut quiche::Connection,
        client_addr: SocketAddr,
        server_addr: SocketAddr,
        endpoint: &mut RuntimeQuicControlEndpoint,
        server_config: &mut quiche::Config,
        service: Arc<
            Mutex<
                RuntimeHttpService<
                    InMemoryRequestTalkTurnSnapshotLoader,
                    CorpusKernelDecisionWorker,
                >,
            >,
        >,
    ) {
        for _ in 0..16 {
            exchange_client_with_endpoint(
                client,
                client_addr,
                server_addr,
                endpoint,
                server_config,
                service.clone(),
            );
            if client.is_established() {
                return;
            }
        }
        panic!("runtime QUIC endpoint handshake did not complete");
    }

    fn exchange_client_with_endpoint(
        client: &mut quiche::Connection,
        client_addr: SocketAddr,
        server_addr: SocketAddr,
        endpoint: &mut RuntimeQuicControlEndpoint,
        server_config: &mut quiche::Config,
        service: Arc<
            Mutex<
                RuntimeHttpService<
                    InMemoryRequestTalkTurnSnapshotLoader,
                    CorpusKernelDecisionWorker,
                >,
            >,
        >,
    ) {
        let mut out = [0_u8; RUNTIME_QUIC_OUT_BUF_LENGTH];
        loop {
            let (written, send_info) = match client.send(&mut out) {
                Ok(value) => value,
                Err(quiche::Error::Done) => break,
                Err(error) => panic!("client QUIC send failed: {error}"),
            };
            let mut packet = out[..written].to_vec();
            let responses = endpoint
                .receive_packet_with_identity_binding(
                    &mut packet,
                    server_addr,
                    send_info.from,
                    server_config,
                    service.clone(),
                )
                .expect("endpoint should receive authenticated packet");
            deliver_endpoint_packets_to_client(client, client_addr, server_addr, responses);
        }
        let responses = endpoint
            .flush_outbound()
            .expect("endpoint should flush outbound packets");
        deliver_endpoint_packets_to_client(client, client_addr, server_addr, responses);
    }

    fn deliver_endpoint_packets_to_client(
        client: &mut quiche::Connection,
        client_addr: SocketAddr,
        server_addr: SocketAddr,
        packets: Vec<RuntimeQuicOutboundPacket>,
    ) {
        for mut packet in packets {
            assert_eq!(packet.destination, client_addr);
            match client.recv(
                &mut packet.bytes,
                quiche::RecvInfo {
                    to: client_addr,
                    from: server_addr,
                },
            ) {
                Ok(_) | Err(quiche::Error::Done) => {}
                Err(error) => panic!("client QUIC receive failed: {error}"),
            }
        }
    }

    fn read_available_stream_lines(
        connection: &mut quiche::Connection,
        stream_id: u64,
    ) -> Vec<serde_json::Value> {
        let mut received = Vec::new();
        let mut buffer = [0_u8; 4096];
        loop {
            match connection.stream_recv(stream_id, &mut buffer) {
                Ok((read, _fin)) if read > 0 => received.extend_from_slice(&buffer[..read]),
                Ok(_) | Err(quiche::Error::Done) => break,
                Err(error) => panic!("stream receive failed: {error}"),
            }
        }
        std::str::from_utf8(&received)
            .expect("stream response should be UTF-8")
            .lines()
            .map(|line| serde_json::from_str(line).expect("response line should be JSON"))
            .collect()
    }

    fn complete_handshake(
        client: &mut quiche::Connection,
        client_addr: SocketAddr,
        server: &mut quiche::Connection,
        server_addr: SocketAddr,
    ) {
        for _ in 0..16 {
            pump_packets(server, server_addr, client, client_addr);
            pump_packets(client, client_addr, server, server_addr);
            if client.is_established() && server.is_established() {
                return;
            }
        }
        panic!("QUIC handshake did not complete");
    }

    fn pump_packets(
        source: &mut quiche::Connection,
        source_addr: SocketAddr,
        destination: &mut quiche::Connection,
        destination_addr: SocketAddr,
    ) {
        let mut out = [0_u8; 4096];
        loop {
            let (written, _) = match source.send(&mut out) {
                Ok(value) => value,
                Err(quiche::Error::Done) => break,
                Err(error) => panic!("QUIC send failed: {error}"),
            };
            let mut packet = out[..written].to_vec();
            match destination.recv(
                &mut packet,
                quiche::RecvInfo {
                    to: destination_addr,
                    from: source_addr,
                },
            ) {
                Ok(_) | Err(quiche::Error::Done) => {}
                Err(error) => panic!("QUIC receive failed: {error}"),
            }
        }
    }

    fn write_temp_cert_pair(cert_pem: &str, key_pem: &str) -> (PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time should be valid")
            .as_nanos();
        let counter = TEMP_CERT_COUNTER.fetch_add(1, Ordering::Relaxed);
        let process_id = std::process::id();
        let dir = std::env::temp_dir();
        let cert_path = dir.join(format!(
            "bb-runtime-quic-{process_id}-{counter}-{nonce}.cert.pem"
        ));
        let key_path = dir.join(format!(
            "bb-runtime-quic-{process_id}-{counter}-{nonce}.key.pem"
        ));
        std::fs::write(&cert_path, cert_pem).expect("cert should write");
        std::fs::write(&key_path, key_pem).expect("key should write");
        (cert_path, key_path)
    }
}
