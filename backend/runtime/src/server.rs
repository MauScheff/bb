use std::{
    io::{BufRead, ErrorKind, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use crate::{
    control_protocol::{RuntimeControlCommandFrame, RuntimeControlTransport},
    control_stream::{
        RuntimeControlStreamError, serve_runtime_control_stream_with_identity_binding,
    },
    http::{RuntimeHttpError, RuntimeHttpService, serve_stream_with_committer},
    postgres::{
        DurableAlertPushTokenStore, DurableBeepThreadStore, DurableContactStore,
        KernelDecisionCommitter, RequestTalkTurnKernelWorker, RequestTalkTurnSnapshotLoader,
        TalkTurnReleaseCommitter, TalkTurnRenewalCommitter,
    },
    websocket_network::{
        AppCompatibleControlCommand, AppCompatibleControlCommandObserver,
        AppCompatibleWebSocketHub, WebSocketNetworkError,
    },
};

#[derive(Debug, thiserror::Error)]
pub enum RuntimeServerError {
    #[error("io failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("runtime control stream failed: {0}")]
    RuntimeControl(#[from] RuntimeControlStreamError),
}

pub fn serve_frame_bound_runtime_control_stream<R, W, S, K, C>(
    reader: &mut R,
    writer: &mut W,
    service: Arc<Mutex<RuntimeHttpService<S, K, C>>>,
    transport: RuntimeControlTransport,
) -> Result<(), RuntimeServerError>
where
    R: BufRead,
    W: Write,
    S: RequestTalkTurnSnapshotLoader + Send + 'static,
    K: RequestTalkTurnKernelWorker + Send + 'static,
    C: KernelDecisionCommitter
        + TalkTurnRenewalCommitter
        + TalkTurnReleaseCommitter
        + DurableContactStore
        + DurableAlertPushTokenStore
        + DurableBeepThreadStore
        + Send
        + 'static,
{
    serve_runtime_control_stream_with_identity_binding(
        reader,
        writer,
        transport,
        |identity, frame| {
            handle_authenticated_runtime_control_frame(
                &service,
                &identity.participant_id,
                &identity.device_id,
                frame,
            )
        },
    )?;
    Ok(())
}

pub fn serve_forever_with_websocket<S, W, C>(
    listener: &TcpListener,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
    websocket_hub: AppCompatibleWebSocketHub,
) -> Result<(), RuntimeServerError>
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
    let websocket_hub =
        websocket_hub.with_control_command_observer(Arc::new(RuntimeHttpControlCommandObserver {
            service: service.clone(),
        }));
    loop {
        serve_next_connection(listener, service.clone(), websocket_hub.clone())?;
    }
}

pub fn serve_forever_http<S, W, C>(
    listener: &TcpListener,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeServerError>
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
        serve_next_http_connection(listener, service.clone())?;
    }
}

pub fn serve_next_http_connection<S, W, C>(
    listener: &TcpListener,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
) -> Result<(), RuntimeServerError>
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
    let (mut stream, _) = listener.accept()?;
    thread::spawn(move || {
        if let Err(error) = serve_stream_with_committer(&mut stream, &service) {
            log_http_error(error);
        }
    });
    Ok(())
}

pub fn serve_next_connection<S, W, C>(
    listener: &TcpListener,
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
    websocket_hub: AppCompatibleWebSocketHub,
) -> Result<(), RuntimeServerError>
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
    thread::spawn(move || {
        if is_websocket_upgrade(&stream) {
            if let Err(error) = websocket_hub.serve_stream(stream) {
                log_websocket_error(error);
            }
        } else {
            let mut stream = stream;
            if let Err(error) = serve_stream_with_committer(&mut stream, &service) {
                log_http_error(error);
            }
        }
    });
    Ok(())
}

pub fn is_websocket_upgrade(stream: &TcpStream) -> bool {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let started_at = Instant::now();
    let mut buffer = [0_u8; 2048];
    let result = loop {
        match stream.peek(&mut buffer) {
            Ok(0) => break false,
            Ok(read) => {
                let request = String::from_utf8_lossy(&buffer[..read]).to_ascii_lowercase();
                break request.contains("upgrade: websocket")
                    && request.starts_with("get ")
                    && request.contains("/v1/ws");
            }
            Err(error) if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                if started_at.elapsed() >= Duration::from_millis(250) {
                    break false;
                }
            }
            Err(_) => break false,
        }
    };
    let _ = stream.set_read_timeout(None);
    result
}

fn log_http_error(error: RuntimeHttpError) {
    eprintln!("runtime HTTP connection failed: {error}");
}

fn log_websocket_error(error: WebSocketNetworkError) {
    eprintln!("runtime WebSocket connection failed: {error}");
}

pub(crate) fn handle_authenticated_runtime_control_frame<S, W, C>(
    service: &Arc<Mutex<RuntimeHttpService<S, W, C>>>,
    participant_id: &str,
    device_id: &str,
    frame: &RuntimeControlCommandFrame,
) -> Result<serde_json::Value, String>
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
    if frame.envelope.device_id != device_id {
        return Err("command-device-mismatch".to_owned());
    }
    service
        .lock()
        .map_err(|_| "runtime-service-lock-poisoned".to_owned())?
        .handle_app_compatible_runtime_control_command(
            &frame.envelope.command_kind,
            participant_id,
            device_id,
            frame.envelope.channel_id.as_deref(),
            frame.envelope.subject.as_deref(),
            frame.envelope.generation,
            frame.envelope.operation_id.as_deref(),
        )
        .map_err(|error| error.to_string())
}

struct RuntimeHttpControlCommandObserver<S, W, C> {
    service: Arc<Mutex<RuntimeHttpService<S, W, C>>>,
}

impl<S, W, C> AppCompatibleControlCommandObserver for RuntimeHttpControlCommandObserver<S, W, C>
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
    fn observe(&self, command: AppCompatibleControlCommand) {
        self.service
            .lock()
            .expect("runtime HTTP service lock should not be poisoned")
            .observe_app_compatible_control_command(
                &command.command_kind,
                &command.participant_id,
                &command.device_id,
                command.channel_id.as_deref(),
                command.payload.as_deref(),
            );
    }

    fn observe_connected(&self, participant_id: &str, device_id: &str, channel_id: &str) {
        self.service
            .lock()
            .expect("runtime HTTP service lock should not be poisoned")
            .observe_app_compatible_websocket_connected(participant_id, device_id, channel_id);
    }

    fn observe_disconnected(&self, participant_id: &str, device_id: &str, channel_id: &str) {
        self.service
            .lock()
            .expect("runtime HTTP service lock should not be poisoned")
            .observe_app_compatible_websocket_disconnected(participant_id, device_id, channel_id);
    }
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
    use std::io::{BufReader, Cursor, Write};

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
    fn websocket_upgrade_detector_accepts_app_path() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener.local_addr().expect("address should exist");
        let client = thread::spawn(move || {
            let mut stream = TcpStream::connect(address).expect("client should connect");
            stream
                .write_all(
                    b"GET /s/turbo/v1/ws?deviceId=device-a HTTP/1.1\r\n\
                      Host: 127.0.0.1\r\n\
                      Upgrade: websocket\r\n\
                      Connection: Upgrade\r\n\r\n",
                )
                .expect("request should write");
        });
        let (stream, _) = listener.accept().expect("server should accept");

        assert!(is_websocket_upgrade(&stream));
        client.join().expect("client should join");
    }

    #[test]
    fn websocket_upgrade_detector_rejects_http() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener.local_addr().expect("address should exist");
        let client = thread::spawn(move || {
            let mut stream = TcpStream::connect(address).expect("client should connect");
            stream
                .write_all(b"GET /s/turbo/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                .expect("request should write");
        });
        let (stream, _) = listener.accept().expect("server should accept");

        assert!(!is_websocket_upgrade(&stream));
        client.join().expect("client should join");
    }

    #[test]
    fn frame_bound_runtime_control_stream_updates_runtime_state() {
        let service = runtime_service();
        let input = [
            serde_json::json!({
                "type": "presence-command",
                "requestId": "presence-1",
                "commandKind": "presence-foreground",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "presence-op-1",
                "generation": 1
            })
            .to_string(),
            serde_json::json!({
                "type": "control-command",
                "requestId": "join-1",
                "commandKind": "join-channel",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "join-op-1",
                "channelId": "direct-user-avery-user-blake",
                "generation": 2
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut reader = BufReader::new(Cursor::new(input.into_bytes()));
        let mut output = Vec::new();

        serve_frame_bound_runtime_control_stream(
            &mut reader,
            &mut output,
            service.clone(),
            RuntimeControlTransport::RuntimeTlsControl,
        )
        .expect("runtime TLS control stream should serve");

        let responses = String::from_utf8(output)
            .expect("output should be UTF-8")
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).expect("valid response"))
            .collect::<Vec<_>>();
        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "presence-command-response");
        assert_eq!(responses[0]["transport"], "runtime-tls-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert_eq!(responses[0]["operationId"], "presence-op-1");
        assert_eq!(responses[1]["type"], "control-command-response");
        assert_eq!(responses[1]["operationId"], "join-op-1");
        assert_eq!(responses[1]["generation"], 2);

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
    }

    #[test]
    fn frame_bound_runtime_control_stream_rejects_later_identity_mismatch() {
        let service = runtime_service();
        let input = [
            serde_json::json!({
                "type": "presence-command",
                "requestId": "presence-1",
                "commandKind": "presence-foreground",
                "userHandle": "@avery",
                "deviceId": "device-a",
                "operationId": "presence-op-1",
                "generation": 1
            })
            .to_string(),
            serde_json::json!({
                "type": "presence-command",
                "requestId": "presence-2",
                "commandKind": "presence-keepalive",
                "userHandle": "@avery",
                "deviceId": "device-b",
                "operationId": "presence-op-2",
                "generation": 2
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut reader = BufReader::new(Cursor::new(input.into_bytes()));
        let mut output = Vec::new();

        serve_frame_bound_runtime_control_stream(
            &mut reader,
            &mut output,
            service.clone(),
            RuntimeControlTransport::RuntimeTlsControl,
        )
        .expect("runtime TLS control stream should serve");

        let responses = String::from_utf8(output)
            .expect("output should be UTF-8")
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).expect("valid response"))
            .collect::<Vec<_>>();
        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "presence-command-response");
        assert_eq!(responses[1]["type"], "runtime-control-error");
        assert!(
            responses[1]["error"]
                .as_str()
                .expect("error should be string")
                .contains("identity")
        );
    }
}
