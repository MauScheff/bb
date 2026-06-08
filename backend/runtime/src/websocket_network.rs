use std::{
    collections::{BTreeMap, VecDeque},
    io::ErrorKind,
    net::{TcpListener, TcpStream},
    sync::atomic::{AtomicU64, Ordering},
    sync::{Arc, Mutex, mpsc},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tungstenite::{
    Error as TungsteniteError, Message, accept, accept_hdr,
    client::IntoClientRequest,
    handshake::server::{Request as WebSocketRequest, Response as WebSocketResponse},
};

use crate::websocket::{
    APP_COMPATIBLE_CONVERSATION_ID, AuthenticatedWebSocketDevice, SingleInstanceWebSocketServer,
    WebSocketAuthorizationDecision, WebSocketAuthorizationFact, WebSocketSignalingError,
};
use crate::websocket_audit::{
    InMemoryWebSocketAuthorizationFactSink, NoopWebSocketAuthorizationFactSink,
    WebSocketAuthorizationFactSink, WebSocketAuthorizationFactSinkError,
};
use crate::websocket_cluster::{
    ClusterWebSocketAuthority, ClusterWebSocketConnectOutcome, ClusterWebSocketOutbound,
};

pub type SharedWebSocketServer = Arc<Mutex<SingleInstanceWebSocketServer>>;
pub type SharedClusterWebSocketAuthority = Arc<Mutex<ClusterWebSocketAuthority>>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebSocketPeerIdentity {
    pub connection_id: String,
    pub device: AuthenticatedWebSocketDevice,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AppCompatibleConnectionIdentity {
    peer: WebSocketPeerIdentity,
    ingress_runtime_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppCompatibleControlCommand {
    pub command_kind: String,
    pub participant_id: String,
    pub device_id: String,
    pub channel_id: Option<String>,
    pub payload: Option<String>,
}

pub trait AppCompatibleControlCommandObserver: Send + Sync {
    fn observe(&self, command: AppCompatibleControlCommand);
    fn observe_connected(&self, _participant_id: &str, _device_id: &str, _channel_id: &str) {}
    fn observe_disconnected(&self, _participant_id: &str, _device_id: &str, _channel_id: &str) {}
}

#[derive(Debug)]
struct NoopAppCompatibleControlCommandObserver;

impl AppCompatibleControlCommandObserver for NoopAppCompatibleControlCommandObserver {
    fn observe(&self, _command: AppCompatibleControlCommand) {}
}

static APP_COMPATIBLE_CONNECTION_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelfHostedWebSocketProbeReport {
    pub status: String,
    pub routed_initial_payload: bool,
    pub stale_connection_rejected: bool,
    pub routed_reconnected_payload: bool,
    pub reconnected_session_id: String,
    pub real_network_routed_payload: bool,
    pub real_network_stale_connection_rejected: bool,
    pub real_network_reconnected_session_id: String,
    pub app_compatible_handshake_ok: bool,
    pub app_compatible_cluster_owner_routed_payload: bool,
    pub app_compatible_authorization_facts_recorded: bool,
    pub observations: Vec<SelfHostedWebSocketProbeObservation>,
    pub steps: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SelfHostedWebSocketProbeObservation {
    pub mode: String,
    pub event: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connection_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payload: Option<String>,
    pub detail: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AppCompatibleWebSocketProbeReport {
    handshake_ok: bool,
    cluster_owner_routed_payload: bool,
    authorization_facts_recorded: bool,
    observations: Vec<SelfHostedWebSocketProbeObservation>,
    steps: Vec<String>,
}

fn websocket_observation(
    mode: &str,
    event: &str,
    ok: bool,
    connection_id: Option<&str>,
    session_id: Option<&str>,
    payload: Option<&str>,
    detail: &str,
) -> SelfHostedWebSocketProbeObservation {
    SelfHostedWebSocketProbeObservation {
        mode: mode.to_owned(),
        event: event.to_owned(),
        ok,
        connection_id: connection_id.map(str::to_owned),
        session_id: session_id.map(str::to_owned),
        payload: payload.map(str::to_owned),
        detail: detail.to_owned(),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum WebSocketNetworkError {
    #[error("websocket protocol failed: {0}")]
    Protocol(#[from] tungstenite::Error),
    #[error("websocket handshake failed: {0}")]
    Handshake(String),
    #[error("websocket signaling failed: {0}")]
    Signaling(#[from] WebSocketSignalingError),
    #[error("io failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("websocket authorization audit failed: {0}")]
    AuthorizationAudit(#[from] WebSocketAuthorizationFactSinkError),
    #[error("network probe failed: {0}")]
    Probe(String),
}

pub fn serve_one_websocket_connection(
    listener: &TcpListener,
    server: &SharedWebSocketServer,
    identity: WebSocketPeerIdentity,
) -> Result<(), WebSocketNetworkError> {
    let (stream, _) = listener.accept()?;
    let mut socket =
        accept(stream).map_err(|error| WebSocketNetworkError::Handshake(error.to_string()))?;
    let notice = server
        .lock()
        .expect("websocket server lock should not be poisoned")
        .connect(identity.connection_id.clone(), identity.device)?;
    socket.send(Message::Text(notice.payload.to_string()))?;
    let message = socket.read()?;
    if let Message::Text(text) = message {
        let outbound = server
            .lock()
            .expect("websocket server lock should not be poisoned")
            .handle_text(&identity.connection_id, &text)?;
        for message in outbound {
            if message.connection_id == identity.connection_id {
                socket.send(Message::Text(message.payload.to_string()))?;
            }
        }
    }
    server
        .lock()
        .expect("websocket server lock should not be poisoned")
        .disconnect(&identity.connection_id);
    socket.close(None)?;
    Ok(())
}

#[derive(Default)]
pub struct ThreadedWebSocketNetwork {
    server: SharedWebSocketServer,
    outbound_by_connection: Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
}

impl ThreadedWebSocketNetwork {
    pub fn new() -> Self {
        Self {
            server: Arc::new(Mutex::new(SingleInstanceWebSocketServer::default())),
            outbound_by_connection: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub fn serve_connections(
        &self,
        listener: TcpListener,
        identities: Vec<WebSocketPeerIdentity>,
    ) -> JoinHandle<Result<(), WebSocketNetworkError>> {
        let server = self.server.clone();
        let outbound_by_connection = self.outbound_by_connection.clone();
        thread::spawn(move || {
            let mut identities = VecDeque::from(identities);
            let mut connection_threads = Vec::new();
            while let Some(identity) = identities.pop_front() {
                let (stream, _) = listener.accept()?;
                stream.set_read_timeout(Some(Duration::from_millis(25)))?;
                stream.set_write_timeout(Some(Duration::from_secs(2)))?;
                let server = server.clone();
                let outbound_by_connection = outbound_by_connection.clone();
                connection_threads.push(thread::spawn(move || {
                    serve_threaded_connection(stream, server, outbound_by_connection, identity)
                }));
            }
            for connection_thread in connection_threads {
                connection_thread.join().map_err(|_| {
                    WebSocketNetworkError::Probe("connection thread panicked".to_owned())
                })??;
            }
            Ok(())
        })
    }
}

#[derive(Clone)]
pub struct AppCompatibleWebSocketHub {
    server: SharedWebSocketServer,
    cluster_authority: Option<SharedClusterWebSocketAuthority>,
    runtime_id: String,
    cluster_owner_ttl_ms: Option<i64>,
    outbound_by_connection: Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    authorization_fact_sink: Arc<dyn WebSocketAuthorizationFactSink>,
    control_command_observer: Arc<dyn AppCompatibleControlCommandObserver>,
}

impl Default for AppCompatibleWebSocketHub {
    fn default() -> Self {
        Self::new()
    }
}

impl AppCompatibleWebSocketHub {
    pub fn new() -> Self {
        Self {
            server: Arc::new(Mutex::new(SingleInstanceWebSocketServer::default())),
            cluster_authority: None,
            runtime_id: "runtime-single".to_owned(),
            cluster_owner_ttl_ms: None,
            outbound_by_connection: Arc::new(Mutex::new(BTreeMap::new())),
            authorization_fact_sink: Arc::new(NoopWebSocketAuthorizationFactSink),
            control_command_observer: Arc::new(NoopAppCompatibleControlCommandObserver),
        }
    }

    pub fn with_authorization_fact_sink(
        authorization_fact_sink: Arc<dyn WebSocketAuthorizationFactSink>,
    ) -> Self {
        Self {
            authorization_fact_sink,
            ..Self::new()
        }
    }

    pub fn with_control_command_observer(
        mut self,
        control_command_observer: Arc<dyn AppCompatibleControlCommandObserver>,
    ) -> Self {
        self.control_command_observer = control_command_observer;
        self
    }

    pub fn with_authorization_fact_sink_and_cluster_owner(
        authorization_fact_sink: Arc<dyn WebSocketAuthorizationFactSink>,
        runtime_id: impl Into<String>,
        cluster_authority: SharedClusterWebSocketAuthority,
        owner_ttl_ms: i64,
    ) -> Self {
        Self {
            server: Arc::new(Mutex::new(SingleInstanceWebSocketServer::default())),
            cluster_authority: Some(cluster_authority),
            runtime_id: runtime_id.into(),
            cluster_owner_ttl_ms: Some(owner_ttl_ms),
            outbound_by_connection: Arc::new(Mutex::new(BTreeMap::new())),
            authorization_fact_sink,
            control_command_observer: Arc::new(NoopAppCompatibleControlCommandObserver),
        }
    }

    pub fn with_cluster_authority(
        runtime_id: impl Into<String>,
        cluster_authority: SharedClusterWebSocketAuthority,
    ) -> Self {
        Self {
            runtime_id: runtime_id.into(),
            cluster_authority: Some(cluster_authority),
            ..Self::new()
        }
    }

    pub fn serve_stream(&self, stream: TcpStream) -> Result<(), WebSocketNetworkError> {
        stream.set_read_timeout(Some(Duration::from_millis(25)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        let identity = Arc::new(Mutex::new(None::<AppCompatibleConnectionIdentity>));
        let callback_identity = identity.clone();
        let runtime_id = self.runtime_id.clone();
        let socket = accept_hdr(
            stream,
            |request: &WebSocketRequest, response: WebSocketResponse| {
                let parsed_identity = app_compatible_identity(request, &runtime_id);
                *callback_identity
                    .lock()
                    .expect("websocket identity lock should not be poisoned") =
                    Some(parsed_identity);
                Ok(response)
            },
        )
        .map_err(|error| WebSocketNetworkError::Handshake(error.to_string()))?;
        let identity = identity
            .lock()
            .expect("websocket identity lock should not be poisoned")
            .clone()
            .ok_or_else(|| WebSocketNetworkError::Probe("missing websocket identity".to_owned()))?;
        if let Some(cluster_authority) = &self.cluster_authority {
            serve_app_compatible_cluster_socket(
                socket,
                cluster_authority.clone(),
                self.outbound_by_connection.clone(),
                self.authorization_fact_sink.clone(),
                self.control_command_observer.clone(),
                self.runtime_id.clone(),
                self.cluster_owner_ttl_ms,
                identity,
            )
        } else {
            serve_app_compatible_socket(
                socket,
                self.server.clone(),
                self.outbound_by_connection.clone(),
                self.authorization_fact_sink.clone(),
                self.control_command_observer.clone(),
                identity.peer,
            )
        }
    }
}

fn serve_threaded_connection(
    stream: std::net::TcpStream,
    server: SharedWebSocketServer,
    outbound_by_connection: Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    identity: WebSocketPeerIdentity,
) -> Result<(), WebSocketNetworkError> {
    let mut socket =
        accept(stream).map_err(|error| WebSocketNetworkError::Handshake(error.to_string()))?;
    let (tx, rx) = mpsc::channel::<String>();
    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .insert(identity.connection_id.clone(), tx);

    let notice = server
        .lock()
        .expect("websocket server lock should not be poisoned")
        .connect(identity.connection_id.clone(), identity.device)?;
    socket.send(Message::Text(notice.payload.to_string()))?;

    let idle_deadline = Duration::from_secs(5);
    let mut last_activity = Instant::now();
    loop {
        while let Ok(payload) = rx.try_recv() {
            socket.send(Message::Text(payload))?;
            last_activity = Instant::now();
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                last_activity = Instant::now();
                match server
                    .lock()
                    .expect("websocket server lock should not be poisoned")
                    .handle_text(&identity.connection_id, &text)
                {
                    Ok(outbound) => {
                        let registry = outbound_by_connection
                            .lock()
                            .expect("websocket outbound registry lock should not be poisoned");
                        for message in outbound {
                            if let Some(sender) = registry.get(&message.connection_id) {
                                let _ = sender.send(message.payload.to_string());
                            }
                        }
                    }
                    Err(error) => {
                        socket.send(Message::Text(
                            serde_json::json!({
                                "type": "error",
                                "reason": error.to_string()
                            })
                            .to_string(),
                        ))?;
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(TungsteniteError::Io(error))
                if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                if last_activity.elapsed() >= idle_deadline {
                    break;
                }
            }
            Err(TungsteniteError::ConnectionClosed | TungsteniteError::AlreadyClosed) => break,
            Err(error) => return Err(WebSocketNetworkError::Protocol(error)),
        }
    }

    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .remove(&identity.connection_id);
    server
        .lock()
        .expect("websocket server lock should not be poisoned")
        .disconnect(&identity.connection_id);
    let _ = socket.close(None);
    Ok(())
}

fn serve_app_compatible_cluster_socket(
    mut socket: tungstenite::WebSocket<TcpStream>,
    cluster_authority: SharedClusterWebSocketAuthority,
    outbound_by_connection: Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    authorization_fact_sink: Arc<dyn WebSocketAuthorizationFactSink>,
    control_command_observer: Arc<dyn AppCompatibleControlCommandObserver>,
    local_runtime_id: String,
    cluster_owner_ttl_ms: Option<i64>,
    identity: AppCompatibleConnectionIdentity,
) -> Result<(), WebSocketNetworkError> {
    let connection_id = identity.peer.connection_id.clone();
    let (tx, rx) = mpsc::channel::<String>();
    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .insert(connection_id.clone(), tx);

    let now_ms = current_time_ms();
    if let Some(owner_ttl_ms) = cluster_owner_ttl_ms
        && identity.ingress_runtime_id == local_runtime_id
    {
        let claim_result = cluster_authority
            .lock()
            .expect("websocket cluster authority lock should not be poisoned")
            .claim_owner(
                identity.peer.device.conversation_id.clone(),
                local_runtime_id.clone(),
                now_ms,
                owner_ttl_ms,
            );
        if let Err(error) = claim_result {
            socket.send(Message::Text(
                serde_json::json!({
                    "type": "reconnect-required",
                    "reason": error.to_string()
                })
                .to_string(),
            ))?;
            cleanup_app_compatible_cluster_connection(
                &cluster_authority,
                &outbound_by_connection,
                &connection_id,
            );
            let _ = socket.close(None);
            return Ok(());
        }
    }

    let device = identity.peer.device.clone();
    let participant_id = device.participant_id.clone();
    let device_id = device.device_id.clone();
    let channel_id = device.conversation_id.clone();
    let connect = cluster_authority
        .lock()
        .expect("websocket cluster authority lock should not be poisoned")
        .connect_with_facts(
            identity.ingress_runtime_id.clone(),
            connection_id.clone(),
            identity.peer.device,
            now_ms,
        )?;
    record_authorization_facts(&authorization_fact_sink, &connect.authorization_facts)?;
    let notice = match connect.outcome {
        ClusterWebSocketConnectOutcome::ConnectedLocally { notice, .. }
        | ClusterWebSocketConnectOutcome::ForwardedToOwner { notice, .. } => notice,
        ClusterWebSocketConnectOutcome::Reconnect { reason } => {
            socket.send(Message::Text(
                serde_json::json!({
                    "type": "reconnect-required",
                    "reason": format!("{reason:?}")
                })
                .to_string(),
            ))?;
            cleanup_app_compatible_cluster_connection(
                &cluster_authority,
                &outbound_by_connection,
                &connection_id,
            );
            let _ = socket.close(None);
            return Ok(());
        }
    };
    control_command_observer.observe_connected(&participant_id, &device_id, &channel_id);
    socket.send(Message::Text(notice.to_string()))?;

    let idle_deadline = Duration::from_secs(15);
    let mut last_activity = Instant::now();
    loop {
        while let Ok(payload) = rx.try_recv() {
            socket.send(Message::Text(payload))?;
            last_activity = Instant::now();
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                last_activity = Instant::now();
                let control_command = app_compatible_control_command(&text, &participant_id);
                let result = cluster_authority
                    .lock()
                    .expect("websocket cluster authority lock should not be poisoned")
                    .handle_text_with_facts(&connection_id, &text);
                match result {
                    Ok(result) => {
                        record_authorization_facts(
                            &authorization_fact_sink,
                            &result.authorization_facts,
                        )?;
                        if let Some(command) = control_command {
                            control_command_observer.observe(command);
                        }
                        route_cluster_outbound(&outbound_by_connection, result.outbound);
                    }
                    Err(error) => {
                        socket.send(Message::Text(
                            serde_json::json!({
                                "error": error.to_string()
                            })
                            .to_string(),
                        ))?;
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(TungsteniteError::Io(error))
                if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                if last_activity.elapsed() >= idle_deadline {
                    break;
                }
            }
            Err(TungsteniteError::ConnectionClosed | TungsteniteError::AlreadyClosed) => break,
            Err(error) => return Err(WebSocketNetworkError::Protocol(error)),
        }
    }

    cleanup_app_compatible_cluster_connection(
        &cluster_authority,
        &outbound_by_connection,
        &connection_id,
    );
    control_command_observer.observe_disconnected(&participant_id, &device_id, &channel_id);
    let _ = socket.close(None);
    Ok(())
}

fn serve_app_compatible_socket(
    mut socket: tungstenite::WebSocket<TcpStream>,
    server: SharedWebSocketServer,
    outbound_by_connection: Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    authorization_fact_sink: Arc<dyn WebSocketAuthorizationFactSink>,
    control_command_observer: Arc<dyn AppCompatibleControlCommandObserver>,
    identity: WebSocketPeerIdentity,
) -> Result<(), WebSocketNetworkError> {
    let (tx, rx) = mpsc::channel::<String>();
    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .insert(identity.connection_id.clone(), tx);

    let participant_id = identity.device.participant_id.clone();
    let device_id = identity.device.device_id.clone();
    let channel_id = identity.device.conversation_id.clone();
    let (notice, facts) = {
        let mut server = server
            .lock()
            .expect("websocket server lock should not be poisoned");
        let before = server.authorization_facts().len();
        let notice = server.connect(identity.connection_id.clone(), identity.device)?;
        let facts = server.authorization_facts()[before..].to_vec();
        (notice, facts)
    };
    if let Err(error) = record_authorization_facts(&authorization_fact_sink, &facts) {
        cleanup_app_compatible_connection(
            &server,
            &outbound_by_connection,
            &identity.connection_id,
        );
        let _ = socket.close(None);
        return Err(error.into());
    }
    control_command_observer.observe_connected(&participant_id, &device_id, &channel_id);
    socket.send(Message::Text(notice.payload.to_string()))?;

    let idle_deadline = Duration::from_secs(15);
    let mut last_activity = Instant::now();
    loop {
        while let Ok(payload) = rx.try_recv() {
            socket.send(Message::Text(payload))?;
            last_activity = Instant::now();
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                last_activity = Instant::now();
                let control_command = app_compatible_control_command(&text, &participant_id);
                let (result, facts) = {
                    let mut server = server
                        .lock()
                        .expect("websocket server lock should not be poisoned");
                    let before = server.authorization_facts().len();
                    let result = server.handle_text(&identity.connection_id, &text);
                    let facts = server.authorization_facts()[before..].to_vec();
                    (result, facts)
                };
                if let Err(error) = record_authorization_facts(&authorization_fact_sink, &facts) {
                    cleanup_app_compatible_connection(
                        &server,
                        &outbound_by_connection,
                        &identity.connection_id,
                    );
                    let _ = socket.close(None);
                    return Err(error.into());
                }
                match result {
                    Ok(outbound) => {
                        if let Some(command) = control_command {
                            control_command_observer.observe(command);
                        }
                        let registry = outbound_by_connection
                            .lock()
                            .expect("websocket outbound registry lock should not be poisoned");
                        for message in outbound {
                            if let Some(sender) = registry.get(&message.connection_id) {
                                let _ = sender.send(message.payload.to_string());
                            }
                        }
                    }
                    Err(error) => {
                        socket.send(Message::Text(
                            serde_json::json!({
                                "error": error.to_string()
                            })
                            .to_string(),
                        ))?;
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(TungsteniteError::Io(error))
                if matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) =>
            {
                if last_activity.elapsed() >= idle_deadline {
                    break;
                }
            }
            Err(TungsteniteError::ConnectionClosed | TungsteniteError::AlreadyClosed) => break,
            Err(error) => return Err(WebSocketNetworkError::Protocol(error)),
        }
    }

    cleanup_app_compatible_connection(&server, &outbound_by_connection, &identity.connection_id);
    control_command_observer.observe_disconnected(&participant_id, &device_id, &channel_id);
    let _ = socket.close(None);
    Ok(())
}

fn route_cluster_outbound(
    outbound_by_connection: &Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    outbound: Vec<ClusterWebSocketOutbound>,
) {
    let registry = outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned");
    for message in outbound {
        if let Some(sender) = registry.get(&message.connection_id) {
            let _ = sender.send(message.payload.to_string());
        }
    }
}

fn app_compatible_control_command(
    text: &str,
    participant_id: &str,
) -> Option<AppCompatibleControlCommand> {
    let message: Value = serde_json::from_str(text).ok()?;
    let message_type = message.get("type").and_then(Value::as_str)?;
    match message_type {
        "control-command" => {
            let command_kind = message.get("commandKind").and_then(Value::as_str)?;
            let device_id = message.get("deviceId").and_then(Value::as_str)?;
            Some(AppCompatibleControlCommand {
                command_kind: command_kind.to_owned(),
                participant_id: participant_id.to_owned(),
                device_id: device_id.to_owned(),
                channel_id: message
                    .get("channelId")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                payload: None,
            })
        }
        "receiver-ready" | "receiver-not-ready" => {
            let device_id = message.get("fromDeviceId").and_then(Value::as_str)?;
            Some(AppCompatibleControlCommand {
                command_kind: message_type.to_owned(),
                participant_id: participant_id.to_owned(),
                device_id: device_id.to_owned(),
                channel_id: message
                    .get("channelId")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                payload: message
                    .get("payload")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
            })
        }
        _ => None,
    }
}

fn cleanup_app_compatible_cluster_connection(
    cluster_authority: &SharedClusterWebSocketAuthority,
    outbound_by_connection: &Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    connection_id: &str,
) {
    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .remove(connection_id);
    cluster_authority
        .lock()
        .expect("websocket cluster authority lock should not be poisoned")
        .disconnect(connection_id);
}

fn cleanup_app_compatible_connection(
    server: &SharedWebSocketServer,
    outbound_by_connection: &Arc<Mutex<BTreeMap<String, mpsc::Sender<String>>>>,
    connection_id: &str,
) {
    outbound_by_connection
        .lock()
        .expect("websocket outbound registry lock should not be poisoned")
        .remove(connection_id);
    server
        .lock()
        .expect("websocket server lock should not be poisoned")
        .disconnect(connection_id);
}

fn record_authorization_facts(
    sink: &Arc<dyn WebSocketAuthorizationFactSink>,
    facts: &[WebSocketAuthorizationFact],
) -> Result<(), WebSocketAuthorizationFactSinkError> {
    for fact in facts {
        sink.record_authorization_fact(fact)?;
    }
    Ok(())
}

fn app_compatible_identity(
    request: &WebSocketRequest,
    default_runtime_id: &str,
) -> AppCompatibleConnectionIdentity {
    let query = request.uri().query();
    let device_id = request
        .uri()
        .query()
        .and_then(|query| query_parameter(query, "deviceId"))
        .unwrap_or_else(|| "device".to_owned());
    let conversation_id = query
        .and_then(|query| query_parameter(query, "conversationId"))
        .or_else(|| query.and_then(|query| query_parameter(query, "channelId")))
        .unwrap_or_else(|| APP_COMPATIBLE_CONVERSATION_ID.to_owned());
    let handle = request
        .headers()
        .get("x-turbo-user-handle")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .or_else(|| {
            request
                .headers()
                .get("authorization")
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.strip_prefix("Bearer "))
                .map(str::to_owned)
        })
        .unwrap_or_else(|| "@self".to_owned());
    let ingress_runtime_id = request
        .headers()
        .get("x-beepbeep-runtime-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty())
        .unwrap_or(default_runtime_id)
        .to_owned();
    let connection_number = APP_COMPATIBLE_CONNECTION_COUNTER.fetch_add(1, Ordering::Relaxed);
    AppCompatibleConnectionIdentity {
        peer: WebSocketPeerIdentity {
            connection_id: format!("app-ws-{connection_number}-{device_id}"),
            device: AuthenticatedWebSocketDevice {
                conversation_id,
                participant_id: user_id_for_handle(&handle),
                device_id,
            },
        },
        ingress_runtime_id,
    }
}

fn query_parameter(query: &str, name: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (key, value) = pair.split_once('=')?;
        (key == name).then(|| percent_decode(value))
    })
}

fn percent_decode(value: &str) -> String {
    value
        .replace("%40", "@")
        .replace("%2F", "/")
        .replace("%3A", ":")
}

fn user_id_for_handle(handle: &str) -> String {
    format!("user-{}", handle.trim_start_matches('@'))
}

fn current_time_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[derive(Default)]
pub struct InMemoryWebSocketNetwork {
    server: SingleInstanceWebSocketServer,
    inboxes: BTreeMap<String, Vec<String>>,
}

impl InMemoryWebSocketNetwork {
    pub fn connect(
        &mut self,
        identity: WebSocketPeerIdentity,
    ) -> Result<Vec<String>, WebSocketSignalingError> {
        let notice = self
            .server
            .connect(identity.connection_id.clone(), identity.device)?;
        self.inboxes
            .entry(identity.connection_id)
            .or_default()
            .push(notice.payload.to_string());
        Ok(self.inboxes.values().flatten().cloned().collect::<Vec<_>>())
    }

    pub fn send_text(
        &mut self,
        connection_id: &str,
        text: &str,
    ) -> Result<(), WebSocketSignalingError> {
        let outbound = self.server.handle_text(connection_id, text)?;
        for message in outbound {
            self.inboxes
                .entry(message.connection_id)
                .or_default()
                .push(message.payload.to_string());
        }
        Ok(())
    }

    pub fn disconnect(&mut self, connection_id: &str) {
        self.server.disconnect(connection_id);
    }

    pub fn inbox(&self, connection_id: &str) -> &[String] {
        self.inboxes
            .get(connection_id)
            .map(Vec::as_slice)
            .unwrap_or_default()
    }
}

pub fn run_self_hosted_websocket_probe()
-> Result<SelfHostedWebSocketProbeReport, WebSocketSignalingError> {
    let mut steps = Vec::new();
    let mut observations = Vec::new();
    let mut network = InMemoryWebSocketNetwork::default();

    network.connect(WebSocketPeerIdentity {
        connection_id: "conn-a".to_owned(),
        device: AuthenticatedWebSocketDevice {
            conversation_id: "conversation-1".to_owned(),
            participant_id: "participant-a".to_owned(),
            device_id: "device-a".to_owned(),
        },
    })?;
    observations.push(websocket_observation(
        "in-memory",
        "connect-source",
        true,
        Some("conn-a"),
        Some("0"),
        None,
        "participant-a/device-a connected",
    ));
    steps.push("connected participant-a/device-a".to_owned());

    network.connect(WebSocketPeerIdentity {
        connection_id: "conn-b-old".to_owned(),
        device: AuthenticatedWebSocketDevice {
            conversation_id: "conversation-1".to_owned(),
            participant_id: "participant-b".to_owned(),
            device_id: "device-b".to_owned(),
        },
    })?;
    observations.push(websocket_observation(
        "in-memory",
        "connect-target-initial",
        true,
        Some("conn-b-old"),
        Some("0"),
        None,
        "participant-b/device-b initial socket connected",
    ));
    steps.push("connected participant-b/device-b on initial socket".to_owned());

    network.send_text(
        "conn-a",
        &serde_json::json!({
            "type": "direct-quic-offer",
            "channelId": "conversation-1",
            "fromUserId": "participant-a",
            "fromDeviceId": "device-a",
            "toUserId": "participant-b",
            "toDeviceId": "device-b",
            "payload": "probe-initial-offer"
        })
        .to_string(),
    )?;
    let routed_initial_payload = network
        .inbox("conn-b-old")
        .iter()
        .any(|message| message.contains("probe-initial-offer"));
    observations.push(websocket_observation(
        "in-memory",
        "route-initial-direct-quic-offer",
        routed_initial_payload,
        Some("conn-b-old"),
        Some("0"),
        Some("probe-initial-offer"),
        "initial direct-quic offer delivered to connected target",
    ));
    steps.push("routed initial direct-quic-offer to connected target".to_owned());

    network.disconnect("conn-b-old");
    observations.push(websocket_observation(
        "in-memory",
        "disconnect-target-initial",
        true,
        Some("conn-b-old"),
        Some("0"),
        None,
        "initial target socket disconnected",
    ));
    steps.push("disconnected initial target socket".to_owned());

    network.connect(WebSocketPeerIdentity {
        connection_id: "conn-b-new".to_owned(),
        device: AuthenticatedWebSocketDevice {
            conversation_id: "conversation-1".to_owned(),
            participant_id: "participant-b".to_owned(),
            device_id: "device-b".to_owned(),
        },
    })?;
    let reconnected_notice = network.inbox("conn-b-new").join("\n");
    let reconnected_session_id = if reconnected_notice.contains("\"sessionId\":\"1\"") {
        "1".to_owned()
    } else {
        "unknown".to_owned()
    };
    observations.push(websocket_observation(
        "in-memory",
        "connect-target-replacement",
        reconnected_session_id == "1",
        Some("conn-b-new"),
        Some(&reconnected_session_id),
        None,
        "replacement target socket receives a fresh session",
    ));
    steps.push("reconnected target device on replacement socket".to_owned());

    let stale_connection_rejected = matches!(
        network.send_text(
            "conn-b-old",
            &serde_json::json!({
                "type": "control-command",
                "requestId": "stale-request",
                "deviceId": "device-b",
                "commandKind": "heartbeat"
            })
            .to_string()
        ),
        Err(WebSocketSignalingError::UnknownConnection(connection_id))
            if connection_id == "conn-b-old"
    );
    observations.push(websocket_observation(
        "in-memory",
        "reject-stale-target",
        stale_connection_rejected,
        Some("conn-b-old"),
        Some("0"),
        None,
        "stale target socket lost command authority",
    ));
    steps.push("verified stale socket lost command authority".to_owned());

    network.send_text(
        "conn-a",
        &serde_json::json!({
            "type": "direct-quic-offer",
            "channelId": "conversation-1",
            "fromUserId": "participant-a",
            "fromDeviceId": "device-a",
            "toUserId": "participant-b",
            "toDeviceId": "device-b",
            "payload": "probe-reconnected-offer"
        })
        .to_string(),
    )?;
    let routed_reconnected_payload = network
        .inbox("conn-b-new")
        .iter()
        .any(|message| message.contains("probe-reconnected-offer"));
    observations.push(websocket_observation(
        "in-memory",
        "route-reconnected-direct-quic-offer",
        routed_reconnected_payload,
        Some("conn-b-new"),
        Some(&reconnected_session_id),
        Some("probe-reconnected-offer"),
        "replacement direct-quic offer delivered to fresh target socket",
    ));
    steps.push("routed replacement direct-quic-offer to reconnected socket".to_owned());

    let status = if routed_initial_payload
        && stale_connection_rejected
        && routed_reconnected_payload
        && reconnected_session_id == "1"
    {
        "ok"
    } else {
        "failed"
    }
    .to_owned();

    let mut report = SelfHostedWebSocketProbeReport {
        status,
        routed_initial_payload,
        stale_connection_rejected,
        routed_reconnected_payload,
        reconnected_session_id: reconnected_session_id.clone(),
        real_network_routed_payload: false,
        real_network_stale_connection_rejected: false,
        real_network_reconnected_session_id: "not-run".to_owned(),
        app_compatible_handshake_ok: false,
        app_compatible_cluster_owner_routed_payload: false,
        app_compatible_authorization_facts_recorded: false,
        observations,
        steps,
    };
    if let Ok(network_report) = run_self_hosted_websocket_network_probe() {
        report.real_network_routed_payload = network_report.routed_initial_payload;
        report.real_network_stale_connection_rejected = network_report.stale_connection_rejected;
        report.real_network_reconnected_session_id = network_report.reconnected_session_id;
        report.steps.extend(
            network_report
                .steps
                .into_iter()
                .map(|step| format!("network: {step}")),
        );
        report.observations.extend(network_report.observations);
        if !(report.real_network_routed_payload
            && report.real_network_stale_connection_rejected
            && report.real_network_reconnected_session_id == "1")
        {
            report.status = "failed".to_owned();
        }
    } else {
        report.status = "failed".to_owned();
    }
    if let Ok(app_compatible_report) = run_app_compatible_cluster_websocket_probe() {
        report.app_compatible_handshake_ok = app_compatible_report.handshake_ok;
        report.app_compatible_cluster_owner_routed_payload =
            app_compatible_report.cluster_owner_routed_payload;
        report.app_compatible_authorization_facts_recorded =
            app_compatible_report.authorization_facts_recorded;
        report.steps.extend(
            app_compatible_report
                .steps
                .into_iter()
                .map(|step| format!("app-compatible-cluster: {step}")),
        );
        report
            .observations
            .extend(app_compatible_report.observations);
        if !(report.app_compatible_handshake_ok
            && report.app_compatible_cluster_owner_routed_payload
            && report.app_compatible_authorization_facts_recorded)
        {
            report.status = "failed".to_owned();
        }
    } else {
        report.status = "failed".to_owned();
    }
    Ok(report)
}

pub fn run_self_hosted_websocket_network_probe()
-> Result<SelfHostedWebSocketProbeReport, WebSocketNetworkError> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let network = ThreadedWebSocketNetwork::new();
    let server_thread = network.serve_connections(
        listener,
        vec![
            WebSocketPeerIdentity {
                connection_id: "conn-a".to_owned(),
                device: AuthenticatedWebSocketDevice {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-a".to_owned(),
                    device_id: "device-a".to_owned(),
                },
            },
            WebSocketPeerIdentity {
                connection_id: "conn-b-old".to_owned(),
                device: AuthenticatedWebSocketDevice {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-b".to_owned(),
                    device_id: "device-b".to_owned(),
                },
            },
            WebSocketPeerIdentity {
                connection_id: "conn-b-new".to_owned(),
                device: AuthenticatedWebSocketDevice {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-b".to_owned(),
                    device_id: "device-b".to_owned(),
                },
            },
        ],
    );

    let mut steps = Vec::new();
    let mut observations = Vec::new();
    let (mut client_a, _) = tungstenite::connect(format!("ws://{address}/v1/ws-a"))?;
    let notice_a = client_a.read()?.to_text()?.to_owned();
    if !notice_a.contains("\"status\":\"connected\"") {
        return Err(WebSocketNetworkError::Probe(
            "client-a did not receive connection notice".to_owned(),
        ));
    }
    observations.push(websocket_observation(
        "network",
        "connect-source",
        true,
        Some("conn-a"),
        Some("0"),
        None,
        "client-a connected over TCP/WebSocket",
    ));
    steps.push("client-a connected over TCP/WebSocket".to_owned());

    let (mut client_b_old, _) = tungstenite::connect(format!("ws://{address}/v1/ws-b-old"))?;
    let notice_b_old = client_b_old.read()?.to_text()?.to_owned();
    if !notice_b_old.contains("\"sessionId\":\"0\"") {
        return Err(WebSocketNetworkError::Probe(
            "initial client-b session was not epoch 0".to_owned(),
        ));
    }
    observations.push(websocket_observation(
        "network",
        "connect-target-initial",
        true,
        Some("conn-b-old"),
        Some("0"),
        None,
        "client-b initial socket connected over TCP/WebSocket",
    ));
    steps.push("client-b initial socket connected over TCP/WebSocket".to_owned());

    client_a.send(Message::Text(
        serde_json::json!({
            "type": "direct-quic-offer",
            "channelId": "conversation-1",
            "fromUserId": "participant-a",
            "fromDeviceId": "device-a",
            "toUserId": "participant-b",
            "toDeviceId": "device-b",
            "payload": "network-initial-offer"
        })
        .to_string(),
    ))?;
    let routed_initial_payload = client_b_old
        .read()?
        .to_text()?
        .contains("network-initial-offer");
    observations.push(websocket_observation(
        "network",
        "route-initial-signal",
        routed_initial_payload,
        Some("conn-b-old"),
        Some("0"),
        Some("network-initial-offer"),
        "initial signal delivered across real sockets",
    ));
    steps.push("routed initial signal between two real sockets".to_owned());

    let (mut client_b_new, _) = tungstenite::connect(format!("ws://{address}/v1/ws-b-new"))?;
    let notice_b_new = client_b_new.read()?.to_text()?.to_owned();
    let reconnected_session_id = if notice_b_new.contains("\"sessionId\":\"1\"") {
        "1".to_owned()
    } else {
        "unknown".to_owned()
    };
    observations.push(websocket_observation(
        "network",
        "connect-target-replacement",
        reconnected_session_id == "1",
        Some("conn-b-new"),
        Some(&reconnected_session_id),
        None,
        "client-b replacement socket connected with fresh session",
    ));
    steps.push("client-b replacement socket connected over TCP/WebSocket".to_owned());

    client_b_old.send(Message::Text(
        serde_json::json!({
            "type": "control-command",
            "requestId": "stale-network-request",
            "deviceId": "device-b",
            "commandKind": "heartbeat"
        })
        .to_string(),
    ))?;
    let stale_connection_rejected = client_b_old.read()?.to_text()?.contains("not bound");
    observations.push(websocket_observation(
        "network",
        "reject-stale-target",
        stale_connection_rejected,
        Some("conn-b-old"),
        Some("0"),
        None,
        "stale TCP/WebSocket client lost command authority",
    ));
    steps.push("stale client-b socket rejected after reconnect".to_owned());

    client_a.send(Message::Text(
        serde_json::json!({
            "type": "direct-quic-offer",
            "channelId": "conversation-1",
            "fromUserId": "participant-a",
            "fromDeviceId": "device-a",
            "toUserId": "participant-b",
            "toDeviceId": "device-b",
            "payload": "network-reconnected-offer"
        })
        .to_string(),
    ))?;
    let routed_reconnected_payload = client_b_new
        .read()?
        .to_text()?
        .contains("network-reconnected-offer");
    observations.push(websocket_observation(
        "network",
        "route-reconnected-signal",
        routed_reconnected_payload,
        Some("conn-b-new"),
        Some(&reconnected_session_id),
        Some("network-reconnected-offer"),
        "replacement signal delivered to fresh real socket",
    ));
    steps.push("routed replacement signal to reconnected real socket".to_owned());

    let _ = client_a.close(None);
    let _ = client_b_old.close(None);
    let _ = client_b_new.close(None);
    server_thread
        .join()
        .map_err(|_| WebSocketNetworkError::Probe("accept thread panicked".to_owned()))??;

    let status = if routed_initial_payload
        && stale_connection_rejected
        && routed_reconnected_payload
        && reconnected_session_id == "1"
    {
        "ok"
    } else {
        "failed"
    }
    .to_owned();
    Ok(SelfHostedWebSocketProbeReport {
        status,
        routed_initial_payload,
        stale_connection_rejected,
        routed_reconnected_payload,
        reconnected_session_id: reconnected_session_id.clone(),
        real_network_routed_payload: routed_initial_payload,
        real_network_stale_connection_rejected: stale_connection_rejected,
        real_network_reconnected_session_id: reconnected_session_id,
        app_compatible_handshake_ok: false,
        app_compatible_cluster_owner_routed_payload: false,
        app_compatible_authorization_facts_recorded: false,
        observations,
        steps,
    })
}

fn run_app_compatible_cluster_websocket_probe()
-> Result<AppCompatibleWebSocketProbeReport, WebSocketNetworkError> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let address = listener.local_addr()?;
    let sink = InMemoryWebSocketAuthorizationFactSink::default();
    let cluster = Arc::new(Mutex::new(ClusterWebSocketAuthority::default()));
    let hub = AppCompatibleWebSocketHub::with_authorization_fact_sink_and_cluster_owner(
        Arc::new(sink.clone()),
        "runtime-a",
        cluster,
        60_000,
    );
    let server_thread = thread::spawn(move || -> Result<(), WebSocketNetworkError> {
        let mut workers = Vec::new();
        for _ in 0..2 {
            let (stream, _) = listener.accept()?;
            let hub = hub.clone();
            workers.push(thread::spawn(move || hub.serve_stream(stream)));
        }
        for worker in workers {
            worker.join().map_err(|_| {
                WebSocketNetworkError::Probe("websocket worker panicked".to_owned())
            })??;
        }
        Ok(())
    });

    let mut steps = Vec::new();
    let mut observations = Vec::new();
    let conversation_id = "conversation-app-compatible-probe";
    let mut request_a =
        format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a&conversationId={conversation_id}")
            .into_client_request()
            .map_err(|error| WebSocketNetworkError::Probe(error.to_string()))?;
    request_a
        .headers_mut()
        .insert("x-turbo-user-handle", "@avery".parse().unwrap());
    let (mut client_a, _) = tungstenite::connect(request_a)?;
    let notice_a = client_a
        .read()?
        .to_text()
        .map_err(|error| WebSocketNetworkError::Probe(error.to_string()))?
        .to_owned();

    let mut request_b =
        format!("ws://{address}/s/turbo/v1/ws?deviceId=device-b&conversationId={conversation_id}")
            .into_client_request()
            .map_err(|error| WebSocketNetworkError::Probe(error.to_string()))?;
    request_b
        .headers_mut()
        .insert("x-turbo-user-handle", "@blake".parse().unwrap());
    request_b
        .headers_mut()
        .insert("x-beepbeep-runtime-id", "runtime-b".parse().unwrap());
    let (mut client_b, _) = tungstenite::connect(request_b)?;
    let notice_b = client_b
        .read()?
        .to_text()
        .map_err(|error| WebSocketNetworkError::Probe(error.to_string()))?
        .to_owned();
    let handshake_ok = notice_a.contains(conversation_id) && notice_b.contains(conversation_id);
    observations.push(websocket_observation(
        "app-compatible-cluster",
        "cluster-handshake",
        handshake_ok,
        None,
        None,
        None,
        "two Swift-compatible clients completed clustered handshakes",
    ));
    steps.push("two app-compatible clients completed clustered handshakes".to_owned());

    client_a.send(Message::Text(
        serde_json::json!({
            "type": "direct-quic-offer",
            "channelId": conversation_id,
            "fromUserId": "user-avery",
            "fromDeviceId": "device-a",
            "toUserId": "user-blake",
            "toDeviceId": "device-b",
            "payload": "app-compatible-cluster-probe-offer"
        })
        .to_string(),
    ))?;
    let routed_payload = client_b
        .read()?
        .to_text()
        .map_err(|error| WebSocketNetworkError::Probe(error.to_string()))?
        .contains("app-compatible-cluster-probe-offer");
    observations.push(websocket_observation(
        "app-compatible-cluster",
        "cluster-owner-routed-signal",
        routed_payload,
        None,
        None,
        Some("app-compatible-cluster-probe-offer"),
        "owner-routed clustered signal reached target socket",
    ));
    steps.push("owner-routed clustered signal reached the target socket".to_owned());

    let _ = client_a.close(None);
    let _ = client_b.close(None);
    server_thread
        .join()
        .map_err(|_| WebSocketNetworkError::Probe("websocket server panicked".to_owned()))??;

    let facts = sink.facts();
    let accepted_connection_facts = facts
        .iter()
        .filter(|fact| {
            fact.conversation_id == conversation_id
                && fact.decision == WebSocketAuthorizationDecision::Accepted
                && fact.reason == "connection-bound"
        })
        .count();
    let signal_fact_recorded = facts.iter().any(|fact| {
        fact.conversation_id == conversation_id
            && fact.participant_id == "user-avery"
            && fact.device_id == "device-a"
            && fact.decision == WebSocketAuthorizationDecision::Accepted
            && fact.reason == "signal-routed"
    });
    let authorization_facts_recorded = accepted_connection_facts >= 2 && signal_fact_recorded;
    observations.push(websocket_observation(
        "app-compatible-cluster",
        "authorization-facts-recorded",
        authorization_facts_recorded,
        None,
        None,
        None,
        "accepted connection and signal authorization facts were recorded",
    ));
    steps.push("clustered authorization facts were recorded to the configured sink".to_owned());

    Ok(AppCompatibleWebSocketProbeReport {
        handshake_ok,
        cluster_owner_routed_payload: routed_payload,
        authorization_facts_recorded,
        observations,
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::websocket_cluster::ClusterWebSocketAuthority;
    use std::{
        net::{TcpListener, TcpStream},
        sync::Arc,
        thread,
    };

    fn identity(
        connection_id: &str,
        participant_id: &str,
        device_id: &str,
    ) -> WebSocketPeerIdentity {
        WebSocketPeerIdentity {
            connection_id: connection_id.to_owned(),
            device: AuthenticatedWebSocketDevice {
                conversation_id: "conversation-1".to_owned(),
                participant_id: participant_id.to_owned(),
                device_id: device_id.to_owned(),
            },
        }
    }

    #[test]
    fn websocket_single_instance_network_in_memory_routes_opaque_signal() {
        let mut network = InMemoryWebSocketNetwork::default();
        network
            .connect(identity("conn-a", "participant-a", "device-a"))
            .expect("device a should connect");
        network
            .connect(identity("conn-b", "participant-b", "device-b"))
            .expect("device b should connect");

        network
            .send_text(
                "conn-a",
                &serde_json::json!({
                    "type": "direct-quic-offer",
                    "channelId": "conversation-1",
                    "fromUserId": "participant-a",
                    "fromDeviceId": "device-a",
                    "toUserId": "participant-b",
                    "toDeviceId": "device-b",
                    "payload": "opaque-offer"
                })
                .to_string(),
            )
            .expect("authorized signal should route");

        assert!(
            network
                .inbox("conn-b")
                .iter()
                .any(|message| message.contains("opaque-offer"))
        );
    }

    #[test]
    fn websocket_single_instance_network_accepts_real_websocket_upgrade() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let server = Arc::new(Mutex::new(SingleInstanceWebSocketServer::default()));
        let server_thread = {
            let server = server.clone();
            thread::spawn(move || {
                serve_one_websocket_connection(
                    &listener,
                    &server,
                    identity("conn-a", "participant-a", "device-a"),
                )
                .expect("websocket connection should be served");
            })
        };
        let stream = TcpStream::connect(address).expect("client should connect");
        let url = format!("ws://{address}/v1/ws");
        let (mut client, _) = tungstenite::client::client(url.as_str(), stream)
            .expect("client handshake should work");

        let notice = client.read().expect("notice should arrive");
        assert!(
            notice
                .to_text()
                .unwrap()
                .contains("\"status\":\"connected\"")
        );
        client
            .send(Message::Text(
                serde_json::json!({
                    "type": "control-command",
                    "requestId": "request-1",
                    "deviceId": "device-a",
                    "commandKind": "heartbeat"
                })
                .to_string(),
            ))
            .expect("command should send");
        let response = client.read().expect("response should arrive");
        assert!(
            response
                .to_text()
                .unwrap()
                .contains("\"type\":\"control-command-response\"")
        );
        server_thread.join().expect("server thread should join");
    }

    #[test]
    fn app_compatible_websocket_accepts_swift_client_path_and_headers() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let hub = AppCompatibleWebSocketHub::new();
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            hub.serve_stream(stream)
                .expect("app-compatible websocket should be served");
        });

        let mut request = format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a")
            .into_client_request()
            .expect("request should build");
        request
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        let (mut client, _) = tungstenite::connect(request).expect("client should connect");
        let notice = client.read().expect("notice should arrive");

        let notice = notice.to_text().unwrap();
        assert!(notice.contains("\"status\":\"connected\""));
        assert!(notice.contains("\"deviceId\":\"device-a\""));
        assert!(notice.contains("\"sessionId\":\"0\""));
        let _ = client.close(None);
        server_thread.join().expect("server thread should join");
    }

    #[test]
    fn app_compatible_websocket_routes_swift_signal_between_unbound_devices() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let hub = AppCompatibleWebSocketHub::new();
        let server_thread = thread::spawn(move || {
            let mut workers = Vec::new();
            for _ in 0..2 {
                let (stream, _) = listener.accept().expect("server should accept");
                let hub = hub.clone();
                workers.push(thread::spawn(move || {
                    hub.serve_stream(stream)
                        .expect("app-compatible websocket should be served");
                }));
            }
            for worker in workers {
                worker.join().expect("connection worker should join");
            }
        });

        let mut request_a = format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a")
            .into_client_request()
            .expect("request should build");
        request_a
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        let (mut client_a, _) = tungstenite::connect(request_a).expect("client a should connect");
        let _ = client_a.read().expect("client a notice should arrive");

        let mut request_b = format!("ws://{address}/s/turbo/v1/ws?deviceId=device-b")
            .into_client_request()
            .expect("request should build");
        request_b
            .headers_mut()
            .insert("x-turbo-user-handle", "@blake".parse().unwrap());
        let (mut client_b, _) = tungstenite::connect(request_b).expect("client b should connect");
        let _ = client_b.read().expect("client b notice should arrive");

        client_a
            .send(Message::Text(
                serde_json::json!({
                    "type": "receiver-ready",
                    "channelId": "direct-user-avery-user-blake",
                    "fromUserId": "user-avery",
                    "fromDeviceId": "device-a",
                    "toUserId": "user-blake",
                    "toDeviceId": "device-b",
                    "payload": "receiver-ready"
                })
                .to_string(),
            ))
            .expect("signal should send");

        assert!(
            client_b
                .read()
                .expect("routed signal should arrive")
                .to_text()
                .unwrap()
                .contains("\"receiver-ready\"")
        );
        let _ = client_a.close(None);
        let _ = client_b.close(None);
        server_thread.join().expect("server thread should join");
    }

    #[test]
    fn app_compatible_websocket_returns_presence_command_body_for_swift_decoder() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let hub = AppCompatibleWebSocketHub::new();
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            hub.serve_stream(stream)
                .expect("app-compatible websocket should be served");
        });

        let mut request = format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a")
            .into_client_request()
            .expect("request should build");
        request
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        let (mut client, _) = tungstenite::connect(request).expect("client should connect");
        let _ = client.read().expect("notice should arrive");

        client
            .send(Message::Text(
                serde_json::json!({
                    "type": "presence-command",
                    "requestId": "presence-1",
                    "sessionId": "0",
                    "commandKind": "presence-keepalive",
                    "deviceId": "device-a"
                })
                .to_string(),
            ))
            .expect("presence command should send");

        let response = client
            .read()
            .expect("presence response should arrive")
            .to_text()
            .unwrap()
            .to_owned();
        assert!(response.contains("\"type\":\"presence-command-response\""));
        assert!(response.contains("\"requestId\":\"presence-1\""));
        assert!(response.contains("\"deviceId\":\"device-a\""));
        assert!(response.contains("\"userId\":\"user-avery\""));
        assert!(response.contains("\"status\":\"online\""));
        let _ = client.close(None);
        server_thread.join().expect("server thread should join");
    }

    #[test]
    fn app_compatible_websocket_records_authorization_facts_to_sink() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let sink = InMemoryWebSocketAuthorizationFactSink::default();
        let hub = AppCompatibleWebSocketHub::with_authorization_fact_sink(Arc::new(sink.clone()));
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            hub.serve_stream(stream)
                .expect("app-compatible websocket should be served");
        });

        let mut request = format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a")
            .into_client_request()
            .expect("request should build");
        request
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        let (mut client, _) = tungstenite::connect(request).expect("client should connect");
        let _ = client.read().expect("notice should arrive");

        client
            .send(Message::Text(
                serde_json::json!({
                    "type": "presence-command",
                    "requestId": "presence-1",
                    "sessionId": "0",
                    "commandKind": "presence-keepalive",
                    "deviceId": "device-a"
                })
                .to_string(),
            ))
            .expect("presence command should send");
        let _ = client.read().expect("presence response should arrive");
        let _ = client.close(None);
        server_thread.join().expect("server thread should join");

        let facts = sink.facts();
        assert!(facts.iter().any(|fact| {
            fact.connection_id.contains("device-a")
                && fact.conversation_id == APP_COMPATIBLE_CONVERSATION_ID
                && fact.participant_id == "user-avery"
                && fact.device_id == "device-a"
                && fact.session_epoch == 0
                && fact.decision == WebSocketAuthorizationDecision::Accepted
                && fact.reason == "connection-bound"
        }));
        assert!(facts.iter().any(|fact| {
            fact.participant_id == "user-avery"
                && fact.device_id == "device-a"
                && fact.session_epoch == 0
                && fact.decision == WebSocketAuthorizationDecision::Accepted
                && fact.reason == "command-authorized"
        }));
    }

    #[test]
    fn app_compatible_websocket_can_use_owner_routed_cluster_authority() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let cluster = Arc::new(Mutex::new(ClusterWebSocketAuthority::default()));
        cluster
            .lock()
            .expect("cluster lock should not be poisoned")
            .claim_owner("conversation-1", "runtime-a", current_time_ms() - 1, 60_000)
            .expect("runtime-a should own conversation");
        let hub = AppCompatibleWebSocketHub::with_cluster_authority("runtime-a", cluster);
        let server_thread = thread::spawn(move || {
            let mut workers = Vec::new();
            for _ in 0..2 {
                let (stream, _) = listener.accept().expect("server should accept");
                let hub = hub.clone();
                workers.push(thread::spawn(move || {
                    hub.serve_stream(stream)
                        .expect("app-compatible clustered websocket should be served");
                }));
            }
            for worker in workers {
                worker.join().expect("connection worker should join");
            }
        });

        let mut request_a =
            format!("ws://{address}/s/turbo/v1/ws?deviceId=device-a&conversationId=conversation-1")
                .into_client_request()
                .expect("request should build");
        request_a
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        request_a
            .headers_mut()
            .insert("x-beepbeep-runtime-id", "runtime-a".parse().unwrap());
        let (mut client_a, _) = tungstenite::connect(request_a).expect("client a should connect");
        let notice_a = client_a.read().expect("client a notice should arrive");
        assert!(
            notice_a
                .to_text()
                .unwrap()
                .contains("\"channelId\":\"conversation-1\"")
        );

        let mut request_b =
            format!("ws://{address}/s/turbo/v1/ws?deviceId=device-b&conversationId=conversation-1")
                .into_client_request()
                .expect("request should build");
        request_b
            .headers_mut()
            .insert("x-turbo-user-handle", "@blake".parse().unwrap());
        request_b
            .headers_mut()
            .insert("x-beepbeep-runtime-id", "runtime-b".parse().unwrap());
        let (mut client_b, _) = tungstenite::connect(request_b).expect("client b should connect");
        let notice_b = client_b.read().expect("client b notice should arrive");
        assert!(
            notice_b
                .to_text()
                .unwrap()
                .contains("\"channelId\":\"conversation-1\"")
        );

        client_a
            .send(Message::Text(
                serde_json::json!({
                    "type": "direct-quic-offer",
                    "channelId": "conversation-1",
                    "fromUserId": "user-avery",
                    "fromDeviceId": "device-a",
                    "toUserId": "user-blake",
                    "toDeviceId": "device-b",
                    "payload": "owner-routed-cluster-offer"
                })
                .to_string(),
            ))
            .expect("signal should send");

        assert!(
            client_b
                .read()
                .expect("routed signal should arrive")
                .to_text()
                .unwrap()
                .contains("owner-routed-cluster-offer")
        );
        let _ = client_a.close(None);
        let _ = client_b.close(None);
        server_thread.join().expect("server thread should join");
    }

    #[test]
    fn app_compatible_websocket_cluster_can_claim_local_owner_on_connect() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener should bind");
        let address = listener
            .local_addr()
            .expect("listener address should exist");
        let sink = InMemoryWebSocketAuthorizationFactSink::default();
        let cluster = Arc::new(Mutex::new(ClusterWebSocketAuthority::default()));
        let hub = AppCompatibleWebSocketHub::with_authorization_fact_sink_and_cluster_owner(
            Arc::new(sink.clone()),
            "runtime-a",
            cluster.clone(),
            60_000,
        );
        let server_thread = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("server should accept");
            hub.serve_stream(stream)
                .expect("app-compatible clustered websocket should be served");
        });

        let mut request = format!(
            "ws://{address}/s/turbo/v1/ws?deviceId=device-a&conversationId=conversation-claim"
        )
        .into_client_request()
        .expect("request should build");
        request
            .headers_mut()
            .insert("x-turbo-user-handle", "@avery".parse().unwrap());
        let (mut client, _) = tungstenite::connect(request).expect("client should connect");
        let notice = client.read().expect("client notice should arrive");
        assert!(
            notice
                .to_text()
                .unwrap()
                .contains("\"channelId\":\"conversation-claim\"")
        );
        let _ = client.close(None);
        server_thread.join().expect("server thread should join");
        assert!(sink.facts().iter().any(|fact| {
            fact.conversation_id == "conversation-claim"
                && fact.participant_id == "user-avery"
                && fact.device_id == "device-a"
                && fact.reason == "connection-bound"
        }));
    }

    #[test]
    fn websocket_self_hosted_probe_connects_routes_reconnects_without_stale_authority() {
        let report =
            run_self_hosted_websocket_probe().expect("self-hosted websocket probe should run");

        assert_eq!(report.status, "ok");
        assert!(report.routed_initial_payload);
        assert!(report.stale_connection_rejected);
        assert!(report.routed_reconnected_payload);
        assert_eq!(report.reconnected_session_id, "1");
        assert!(report.app_compatible_handshake_ok);
        assert!(report.app_compatible_cluster_owner_routed_payload);
        assert!(report.app_compatible_authorization_facts_recorded);
        assert_eq!(report.observations.len(), 16);
        assert!(report.observations.iter().all(|observation| observation.ok));
        assert!(report.observations.iter().any(|observation| {
            observation.mode == "network"
                && observation.event == "reject-stale-target"
                && observation.connection_id.as_deref() == Some("conn-b-old")
        }));
        assert!(report.observations.iter().any(|observation| {
            observation.mode == "app-compatible-cluster"
                && observation.event == "authorization-facts-recorded"
        }));
    }
}
