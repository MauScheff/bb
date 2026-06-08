use std::{
    io::ErrorKind,
    net::{TcpListener, TcpStream},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

use crate::{
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
    use std::io::Write;

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
}
