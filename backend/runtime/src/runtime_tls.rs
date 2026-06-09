use std::{
    fs::File,
    io::{BufReader, Read, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
};

use rustls::{
    ServerConfig, ServerConnection, StreamOwned,
    pki_types::{CertificateDer, PrivateKeyDer},
};

use crate::{
    control_protocol::RuntimeControlTransport,
    control_stream::{
        RuntimeControlIdentityBinding, RuntimeControlStreamError,
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

#[derive(Debug, thiserror::Error)]
pub enum RuntimeTlsError {
    #[error("io failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("tls failed: {0}")]
    Tls(#[from] rustls::Error),
    #[error("runtime control stream failed: {0}")]
    ControlStream(#[from] RuntimeControlStreamError),
    #[error("certificate failed: {0}")]
    Certificate(String),
}

pub fn server_config(cert_pem: &Path, key_pem: &Path) -> Result<ServerConfig, RuntimeTlsError> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    let certs = load_certs(cert_pem)?;
    let key = load_key(key_pem)?;
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|error| RuntimeTlsError::Certificate(error.to_string()))?;
    config.alpn_protocols = vec![runtime_quic_alpn().to_vec()];
    Ok(config)
}

pub fn serve_next_runtime_tls_control_connection<S, W, C>(
    listener: &TcpListener,
    server_config: Arc<ServerConfig>,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeTlsError>
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
    let (stream, _) = listener.accept()?;
    serve_runtime_tls_control_io_with_identity_binding(stream, server_config, service)
}

pub fn serve_forever_runtime_tls_control<S, W, C>(
    listener: TcpListener,
    server_config: Arc<ServerConfig>,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeTlsError>
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
    loop {
        let (stream, _) = listener.accept()?;
        let connection_config = server_config.clone();
        let connection_service = service.clone();
        thread::spawn(move || {
            if let Err(error) = serve_runtime_tls_control_io_with_identity_binding(
                stream,
                connection_config,
                connection_service,
            ) {
                eprintln!("runtime TLS control connection failed: {error}");
            }
        });
    }
}

pub fn load_certs(path: &Path) -> Result<Vec<CertificateDer<'static>>, RuntimeTlsError> {
    let file = File::open(path).map_err(|error| {
        RuntimeTlsError::Certificate(format!(
            "failed to open cert PEM at {}: {error}",
            display_path(path)
        ))
    })?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::certs(&mut reader)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|error| RuntimeTlsError::Certificate(format!("failed to parse cert PEM: {error}")))
}

pub fn load_key(path: &Path) -> Result<PrivateKeyDer<'static>, RuntimeTlsError> {
    let file = File::open(path).map_err(|error| {
        RuntimeTlsError::Certificate(format!(
            "failed to open key PEM at {}: {error}",
            display_path(path)
        ))
    })?;
    let mut reader = BufReader::new(file);
    rustls_pemfile::private_key(&mut reader)
        .map_err(|error| RuntimeTlsError::Certificate(format!("failed to parse key PEM: {error}")))?
        .ok_or_else(|| RuntimeTlsError::Certificate("key PEM contained no private key".to_owned()))
}

pub fn serve_runtime_tls_control_io_with_identity_binding<IO, S, W, C>(
    io: IO,
    server_config: Arc<ServerConfig>,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeTlsError>
where
    IO: Read + Write,
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
    let connection = ServerConnection::new(server_config)?;
    let mut tls = StreamOwned::new(connection, io);
    let mut line = Vec::new();
    let mut binding = RuntimeControlIdentityBinding::default();
    let mut handle =
        |identity: &crate::control_protocol::RuntimeControlPeerIdentity,
         frame: &crate::control_protocol::RuntimeControlCommandFrame| {
            handle_authenticated_runtime_control_frame(
                &service,
                &identity.participant_id,
                &identity.device_id,
                frame,
            )
        };
    loop {
        line.clear();
        let read = read_line_from_stream(&mut tls, &mut line)?;
        if read == 0 {
            tls.flush()?;
            return Ok(());
        }
        let trimmed = trim_ascii_line(&line);
        if trimmed.is_empty() {
            continue;
        }
        let response = runtime_control_response_for_line_with_identity_binding(
            trimmed,
            RuntimeControlTransport::RuntimeTlsControl,
            &mut binding,
            &mut handle,
        );
        serde_json::to_writer(&mut tls, &response)
            .map_err(RuntimeControlStreamError::Serialization)?;
        tls.write_all(b"\n")?;
        tls.flush()?;
    }
}

fn display_path(path: &Path) -> String {
    PathBuf::from(path).display().to_string()
}

fn read_line_from_stream<R: Read>(reader: &mut R, buffer: &mut Vec<u8>) -> std::io::Result<usize> {
    let mut byte = [0_u8; 1];
    let mut read = 0;
    loop {
        match reader.read(&mut byte) {
            Ok(0) => return Ok(read),
            Ok(count) => {
                read += count;
                buffer.push(byte[0]);
                if byte[0] == b'\n' {
                    return Ok(read);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(read),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
}

fn trim_ascii_line(line: &[u8]) -> &str {
    let mut start = 0;
    let mut end = line.len();
    while start < end && matches!(line[start], b' ' | b'\t' | b'\r' | b'\n') {
        start += 1;
    }
    while end > start && matches!(line[end - 1], b' ' | b'\t' | b'\r' | b'\n') {
        end -= 1;
    }
    std::str::from_utf8(&line[start..end]).unwrap_or("")
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
    use rustls::{ClientConfig, ClientConnection, RootCertStore, pki_types::ServerName};
    use std::{
        io::{BufRead, BufReader, Write},
        net::{TcpListener, TcpStream},
        sync::atomic::{AtomicU64, Ordering},
        thread,
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
    fn runtime_tls_control_accepts_real_tls_stream_and_updates_state() {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let cert_der = load_certs(&cert_path)
            .expect("cert should load")
            .into_iter()
            .next()
            .expect("cert should exist");
        let server_config = Arc::new(server_config(&cert_path, &key_path).expect("server config"));
        let service = runtime_service();
        let server_service = service.clone();
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener.local_addr().expect("listener address");

        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            serve_runtime_tls_control_io_with_identity_binding(
                stream,
                server_config,
                server_service,
            )
            .expect("runtime TLS control should serve");
        });

        let mut root = RootCertStore::empty();
        root.add(cert_der).expect("root cert should add");
        let client_config = Arc::new(
            ClientConfig::builder()
                .with_root_certificates(root)
                .with_no_client_auth(),
        );
        let connection = ClientConnection::new(
            client_config,
            ServerName::try_from("localhost").expect("server name should parse"),
        )
        .expect("client connection should build");
        let tcp = TcpStream::connect(address).expect("client should connect");
        let mut tls = StreamOwned::new(connection, tcp);
        tls.write_all(
            serde_json::json!({
                "type": "presence-command",
                "requestId": "presence-1",
                "commandKind": "presence-foreground",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "presence-op-1",
                "generation": 1
            })
            .to_string()
            .as_bytes(),
        )
        .expect("request should write");
        tls.write_all(b"\n").expect("newline should write");
        tls.flush().expect("request should flush");

        let mut reader = BufReader::new(tls);
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .expect("response should read");
        let response =
            serde_json::from_str::<serde_json::Value>(&response_line).expect("response JSON");

        assert_eq!(response["type"], "presence-command-response");
        assert_eq!(response["transport"], "runtime-tls-control");
        assert_eq!(response["persistentTransport"], true);
        assert_eq!(response["operationId"], "presence-op-1");
        drop(reader);
        server.join().expect("server should finish");

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
    fn runtime_tls_listener_accepts_real_tls_control_connection() {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let cert_der = load_certs(&cert_path)
            .expect("cert should load")
            .into_iter()
            .next()
            .expect("cert should exist");
        let server_config = Arc::new(server_config(&cert_path, &key_path).expect("server config"));
        let service = runtime_service();
        let server_service = service.clone();
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener.local_addr().expect("listener address");

        let server = thread::spawn(move || {
            serve_next_runtime_tls_control_connection(&listener, server_config, server_service)
                .expect("runtime TLS listener should serve one connection");
        });

        let mut root = RootCertStore::empty();
        root.add(cert_der).expect("root cert should add");
        let client_config = Arc::new(
            ClientConfig::builder()
                .with_root_certificates(root)
                .with_no_client_auth(),
        );
        let connection = ClientConnection::new(
            client_config,
            ServerName::try_from("localhost").expect("server name should parse"),
        )
        .expect("client connection should build");
        let tcp = TcpStream::connect(address).expect("client should connect");
        let mut tls = StreamOwned::new(connection, tcp);
        tls.write_all(
            serde_json::json!({
                "type": "presence-command",
                "requestId": "listener-presence-1",
                "commandKind": "presence-foreground",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "listener-presence-op-1",
                "generation": 3
            })
            .to_string()
            .as_bytes(),
        )
        .expect("request should write");
        tls.write_all(b"\n").expect("newline should write");
        tls.flush().expect("request should flush");

        let mut reader = BufReader::new(tls);
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .expect("response should read");
        let response =
            serde_json::from_str::<serde_json::Value>(&response_line).expect("response JSON");

        assert_eq!(response["type"], "presence-command-response");
        assert_eq!(response["transport"], "runtime-tls-control");
        assert_eq!(response["persistentTransport"], true);
        assert_eq!(response["requestId"], "listener-presence-1");
        assert_eq!(response["operationId"], "listener-presence-op-1");
        drop(reader);
        server.join().expect("server should finish");

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
    fn runtime_tls_control_binds_identity_from_first_frame_and_updates_state() {
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])
            .expect("certificate should generate");
        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();
        let (cert_path, key_path) = write_temp_cert_pair(&cert_pem, &key_pem);
        let cert_der = load_certs(&cert_path)
            .expect("cert should load")
            .into_iter()
            .next()
            .expect("cert should exist");
        let server_config = Arc::new(server_config(&cert_path, &key_path).expect("server config"));
        let service = runtime_service();
        let server_service = service.clone();
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener.local_addr().expect("listener address");

        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            serve_runtime_tls_control_io_with_identity_binding(
                stream,
                server_config,
                server_service,
            )
            .expect("runtime TLS control should serve");
        });

        let mut root = RootCertStore::empty();
        root.add(cert_der).expect("root cert should add");
        let client_config = Arc::new(
            ClientConfig::builder()
                .with_root_certificates(root)
                .with_no_client_auth(),
        );
        let connection = ClientConnection::new(
            client_config,
            ServerName::try_from("localhost").expect("server name should parse"),
        )
        .expect("client connection should build");
        let tcp = TcpStream::connect(address).expect("client should connect");
        let mut tls = StreamOwned::new(connection, tcp);
        tls.write_all(
            serde_json::json!({
                "type": "presence-command",
                "requestId": "presence-bound-1",
                "commandKind": "presence-foreground",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "presence-bound-op-1",
                "generation": 21
            })
            .to_string()
            .as_bytes(),
        )
        .expect("request should write");
        tls.write_all(b"\n").expect("newline should write");
        tls.flush().expect("request should flush");

        let mut reader = BufReader::new(tls);
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .expect("response should read");
        let response =
            serde_json::from_str::<serde_json::Value>(&response_line).expect("response JSON");

        assert_eq!(response["type"], "presence-command-response");
        assert_eq!(response["transport"], "runtime-tls-control");
        assert_eq!(response["persistentTransport"], true);
        assert_eq!(response["operationId"], "presence-bound-op-1");
        assert_eq!(response["body"]["userId"], "user-avery");
        drop(reader);
        server.join().expect("server should finish");

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

    fn write_temp_cert_pair(cert_pem: &str, key_pem: &str) -> (PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time should be valid")
            .as_nanos();
        let counter = TEMP_CERT_COUNTER.fetch_add(1, Ordering::Relaxed);
        let process_id = std::process::id();
        let dir = std::env::temp_dir();
        let cert_path = dir.join(format!(
            "bb-runtime-tls-{process_id}-{counter}-{nonce}.cert.pem"
        ));
        let key_path = dir.join(format!(
            "bb-runtime-tls-{process_id}-{counter}-{nonce}.key.pem"
        ));
        std::fs::write(&cert_path, cert_pem).expect("cert should write");
        std::fs::write(&key_path, key_pem).expect("key should write");
        (cert_path, key_path)
    }
}
