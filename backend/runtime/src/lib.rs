use std::{
    fmt,
    path::PathBuf,
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};

use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};

pub mod fuzz;
pub mod http;
pub mod http_probe;
pub mod live;
pub mod multi_node_routing;
pub mod owner_record_transport;
pub mod postgres;
pub mod quic_protocol;
pub mod routes;
pub mod server;
pub mod shadow;
pub mod talk_turn_actor;
pub mod websocket;
pub mod websocket_audit;
pub mod websocket_cluster;
pub mod websocket_network;

static KERNEL_WORKER_LOCK: Mutex<()> = Mutex::new(());

pub fn relay_protocol_is_linked() -> bool {
    let frame = relay::protocol::RelayFrame::DatagramJoinAck {
        session_id: "health-session".to_string(),
        device_id: "health-device".to_string(),
        transport: relay::protocol::RelayTransport::QuicDatagram,
    };
    serde_json::to_string(&frame)
        .map(|encoded| encoded.contains(r#""transport":"quic-datagram""#))
        .unwrap_or(false)
}

pub fn relay_metrics_are_linked() -> bool {
    let counters = relay::metrics::RelayCounters::default();
    counters.record_accepted_join();
    counters.record_forwarded_frame();
    let snapshot = counters.snapshot();
    snapshot.accepted_joins == 1 && snapshot.forwarded_frames == 1
}

pub fn relay_transport_modules_are_linked() -> bool {
    relay::transport_quic::QUIC_ALPN == b"turbo-relay-v2"
        && relay::transport_quic::QUIC_DGRAM_QUEUE_LENGTH > 0
        && relay::transport_tcp::TCP_TLS_TRANSPORT_NAME == "tcp-tls"
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeHealth {
    pub service: &'static str,
    pub kernel_harness: ComponentHealth,
    pub public_networking: ComponentHealth,
    pub durable_storage: ComponentHealth,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ComponentHealth {
    Ready,
    NotStarted,
}

impl RuntimeHealth {
    pub fn skeleton() -> Self {
        Self {
            service: "beepbeep-runtime",
            kernel_harness: ComponentHealth::Ready,
            public_networking: ComponentHealth::NotStarted,
            durable_storage: ComponentHealth::NotStarted,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum KernelHarnessError {
    #[error("kernel worker deadline exceeded after {0:?}")]
    DeadlineExceeded(Duration),
    #[error("kernel worker exited with status {status}: {stderr}")]
    WorkerFailed { status: String, stderr: String },
    #[error("failed to start kernel worker: {0}")]
    StartFailed(#[source] std::io::Error),
    #[error("failed to poll kernel worker: {0}")]
    PollFailed(#[source] std::io::Error),
    #[error("failed to collect kernel worker output: {0}")]
    OutputFailed(#[source] std::io::Error),
    #[error("kernel worker returned malformed JSON: {0}")]
    MalformedResponse(#[source] serde_json::Error),
    #[error("kernel corpus response hash mismatch: expected {expected}, observed {observed}")]
    HashMismatch { expected: String, observed: String },
}

#[derive(Clone, Debug, Deserialize)]
pub struct KernelCorpus {
    pub cases: Vec<KernelCorpusCase>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KernelCorpusCase {
    pub id: String,
    pub kind: KernelCommandKind,
    pub command: Value,
    pub snapshot: Value,
    pub policy: Value,
    pub expected_decision: Value,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum KernelCommandKind {
    RequestTalkTurn,
    ReleaseTalkTurn,
}

#[derive(Debug)]
pub struct KernelWorkerResponse {
    pub stdout: String,
    pub stderr: String,
    pub sha256: String,
    pub corpus: KernelCorpus,
}

pub struct ProcessKernelWorker {
    repo_root: PathBuf,
    shell_command: String,
}

impl fmt::Debug for ProcessKernelWorker {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProcessKernelWorker")
            .field("repo_root", &self.repo_root)
            .field("shell_command", &self.shell_command)
            .finish()
    }
}

impl ProcessKernelWorker {
    pub fn unison_corpus_worker(repo_root: impl Into<PathBuf>) -> Self {
        Self {
            repo_root: repo_root.into(),
            shell_command: "DIRENV_LOG_FORMAT= direnv exec . ucm run bb/main:.beepbeep.tests.corpus.printJson".to_string(),
        }
    }

    pub fn shell(repo_root: impl Into<PathBuf>, shell_command: impl Into<String>) -> Self {
        Self {
            repo_root: repo_root.into(),
            shell_command: shell_command.into(),
        }
    }

    pub fn request_corpus(
        &self,
        deadline: Duration,
    ) -> Result<KernelWorkerResponse, KernelHarnessError> {
        let mut command = Command::new("sh");
        command
            .arg("-c")
            .arg(&self.shell_command)
            .current_dir(&self.repo_root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let output = run_kernel_command_with_deadline(command, deadline)?;
        if !output.status.success() {
            return Err(KernelHarnessError::WorkerFailed {
                status: output
                    .status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "signal".to_string()),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
            });
        }

        parse_corpus_response(
            String::from_utf8_lossy(&output.stdout).trim().to_string(),
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        )
    }
}

pub fn run_kernel_command_with_deadline(
    command: Command,
    deadline: Duration,
) -> Result<std::process::Output, KernelHarnessError> {
    let _guard = KERNEL_WORKER_LOCK
        .lock()
        .expect("kernel worker lock should not be poisoned");
    run_with_deadline(command, deadline)
}

fn run_with_deadline(
    mut command: Command,
    deadline: Duration,
) -> Result<std::process::Output, KernelHarnessError> {
    let mut child = command.spawn().map_err(KernelHarnessError::StartFailed)?;

    let started = Instant::now();
    loop {
        match child.try_wait().map_err(KernelHarnessError::PollFailed)? {
            Some(_) => {
                return child
                    .wait_with_output()
                    .map_err(KernelHarnessError::OutputFailed);
            }
            None if started.elapsed() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(KernelHarnessError::DeadlineExceeded(deadline));
            }
            None => thread::sleep(Duration::from_millis(10)),
        }
    }
}

pub fn parse_corpus_response(
    stdout: String,
    stderr: String,
) -> Result<KernelWorkerResponse, KernelHarnessError> {
    let corpus: KernelCorpus =
        serde_json::from_str(&stdout).map_err(KernelHarnessError::MalformedResponse)?;
    let sha256 = sha256_hex(stdout.as_bytes());
    Ok(KernelWorkerResponse {
        stdout,
        stderr,
        sha256,
        corpus,
    })
}

pub fn verify_response_hash(
    response: &KernelWorkerResponse,
    expected: &str,
) -> Result<(), KernelHarnessError> {
    if response.sha256 == expected {
        Ok(())
    } else {
        Err(KernelHarnessError::HashMismatch {
            expected: expected.to_string(),
            observed: response.sha256.clone(),
        })
    }
}

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut text = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write;
        let _ = write!(&mut text, "{byte:02x}");
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|path| path.parent())
            .and_then(|path| path.parent())
            .expect("runtime crate should live under backend/runtime")
            .to_path_buf()
    }

    #[test]
    fn runtime_health_surface_reports_stage_2_skeleton() {
        let health = RuntimeHealth::skeleton();

        assert_eq!(health.service, "beepbeep-runtime");
        assert_eq!(health.kernel_harness, ComponentHealth::Ready);
        assert_eq!(health.public_networking, ComponentHealth::NotStarted);
        assert_eq!(health.durable_storage, ComponentHealth::NotStarted);
    }

    #[test]
    fn runtime_links_extracted_relay_protocol_module() {
        assert!(relay_protocol_is_linked());
    }

    #[test]
    fn runtime_links_extracted_relay_metrics_module() {
        assert!(relay_metrics_are_linked());
    }

    #[test]
    fn runtime_links_extracted_relay_transport_modules() {
        assert!(relay_transport_modules_are_linked());
    }

    #[test]
    fn kernel_harness_replays_stage_1a_corpus() {
        let worker = ProcessKernelWorker::unison_corpus_worker(repo_root());
        let response = worker
            .request_corpus(Duration::from_secs(20))
            .expect("kernel corpus worker should return JSON");

        assert_eq!(response.corpus.cases.len(), 10);
        assert!(
            response
                .corpus
                .cases
                .iter()
                .any(|case| case.kind == KernelCommandKind::RequestTalkTurn
                    && case.id == "valid-request-talk-turn-grant")
        );
        assert!(
            response
                .corpus
                .cases
                .iter()
                .any(|case| case.kind == KernelCommandKind::ReleaseTalkTurn
                    && case.id == "stale-release-talk-turn-denies")
        );
        verify_response_hash(&response, &response.sha256)
            .expect("matching response hash should verify");
    }

    #[test]
    fn kernel_harness_rejects_malformed_response() {
        let err = parse_corpus_response("not json".to_string(), String::new()).unwrap_err();
        assert!(matches!(err, KernelHarnessError::MalformedResponse(_)));
    }

    #[test]
    fn kernel_harness_detects_response_hash_mismatch() {
        let response = parse_corpus_response(r#"{"cases":[]}"#.to_string(), String::new())
            .expect("empty corpus JSON should parse");
        let err = verify_response_hash(&response, "not-the-observed-hash").unwrap_err();
        assert!(matches!(err, KernelHarnessError::HashMismatch { .. }));
    }

    #[test]
    fn kernel_harness_enforces_worker_deadline_and_can_restart() {
        let slow = ProcessKernelWorker::shell(repo_root(), "sleep 2 && printf '{\"cases\":[]}'");
        let err = slow.request_corpus(Duration::from_millis(20)).unwrap_err();
        assert!(matches!(err, KernelHarnessError::DeadlineExceeded(_)));

        let restarted = ProcessKernelWorker::shell(repo_root(), "printf '{\"cases\":[]}'");
        let response = restarted
            .request_corpus(Duration::from_secs(1))
            .expect("worker should recover after a killed process");
        assert!(response.corpus.cases.is_empty());
    }
}
