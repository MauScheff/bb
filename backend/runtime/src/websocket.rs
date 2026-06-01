use std::collections::BTreeMap;

use serde_json::Value;

pub const APP_COMPATIBLE_CONVERSATION_ID: &str = "__app_compatible_unbound__";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedWebSocketDevice {
    pub conversation_id: String,
    pub participant_id: String,
    pub device_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebSocketConnectionBinding {
    pub connection_id: String,
    pub conversation_id: String,
    pub participant_id: String,
    pub device_id: String,
    pub session_epoch: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RoutedSignal {
    pub from_connection_id: String,
    pub to_connection_id: String,
    pub conversation_id: String,
    pub payload: String,
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum WebSocketSignalingError {
    #[error("connection identity field `{0}` is empty")]
    EmptyIdentityField(&'static str),
    #[error("connection `{0}` is not bound")]
    UnknownConnection(String),
    #[error("target device is not connected")]
    TargetDisconnected,
    #[error("target device is outside the sender conversation")]
    CrossConversationTarget,
    #[error("signal envelope did not match authenticated connection")]
    UnauthorizedEnvelope,
    #[error("websocket message was malformed: {0}")]
    MalformedMessage(String),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SingleInstanceWebSocketState {
    bindings_by_connection: BTreeMap<String, WebSocketConnectionBinding>,
    current_connection_by_device: BTreeMap<DeviceKey, String>,
    next_epoch_by_device: BTreeMap<DeviceKey, u64>,
}

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
struct DeviceKey {
    conversation_id: String,
    device_id: String,
}

impl SingleInstanceWebSocketState {
    pub fn connect(
        &mut self,
        connection_id: impl Into<String>,
        device: AuthenticatedWebSocketDevice,
    ) -> Result<WebSocketConnectionBinding, WebSocketSignalingError> {
        let connection_id = connection_id.into();
        validate_non_empty("connection_id", &connection_id)?;
        validate_non_empty("conversation_id", &device.conversation_id)?;
        validate_non_empty("participant_id", &device.participant_id)?;
        validate_non_empty("device_id", &device.device_id)?;

        let key = DeviceKey {
            conversation_id: device.conversation_id.clone(),
            device_id: device.device_id.clone(),
        };
        if let Some(previous_connection_id) = self.current_connection_by_device.get(&key) {
            self.bindings_by_connection.remove(previous_connection_id);
        }

        let session_epoch = self.next_session_epoch(&key);
        let binding = WebSocketConnectionBinding {
            connection_id: connection_id.clone(),
            conversation_id: device.conversation_id,
            participant_id: device.participant_id,
            device_id: device.device_id,
            session_epoch,
        };
        self.bindings_by_connection
            .insert(connection_id.clone(), binding.clone());
        self.current_connection_by_device.insert(key, connection_id);
        Ok(binding)
    }

    pub fn disconnect(&mut self, connection_id: &str) -> Option<WebSocketConnectionBinding> {
        let binding = self.bindings_by_connection.remove(connection_id)?;
        let key = DeviceKey {
            conversation_id: binding.conversation_id.clone(),
            device_id: binding.device_id.clone(),
        };
        if self
            .current_connection_by_device
            .get(&key)
            .is_some_and(|current| current == connection_id)
        {
            self.current_connection_by_device.remove(&key);
        }
        Some(binding)
    }

    pub fn disconnect_conversation(
        &mut self,
        conversation_id: &str,
    ) -> Vec<WebSocketConnectionBinding> {
        let connection_ids = self
            .bindings_by_connection
            .iter()
            .filter_map(|(connection_id, binding)| {
                (binding.conversation_id == conversation_id).then(|| connection_id.clone())
            })
            .collect::<Vec<_>>();
        connection_ids
            .into_iter()
            .filter_map(|connection_id| self.disconnect(&connection_id))
            .collect()
    }

    pub fn binding(&self, connection_id: &str) -> Option<&WebSocketConnectionBinding> {
        self.bindings_by_connection.get(connection_id)
    }

    pub fn route_signal(
        &self,
        from_connection_id: &str,
        target_device_id: &str,
        payload: impl Into<String>,
    ) -> Result<RoutedSignal, WebSocketSignalingError> {
        let from = self.binding(from_connection_id).ok_or_else(|| {
            WebSocketSignalingError::UnknownConnection(from_connection_id.to_owned())
        })?;
        let target_key = DeviceKey {
            conversation_id: from.conversation_id.clone(),
            device_id: target_device_id.to_owned(),
        };
        let to_connection_id = self
            .current_connection_by_device
            .get(&target_key)
            .ok_or(WebSocketSignalingError::TargetDisconnected)?;
        let to = self
            .binding(to_connection_id)
            .ok_or(WebSocketSignalingError::TargetDisconnected)?;
        if to.conversation_id != from.conversation_id {
            return Err(WebSocketSignalingError::CrossConversationTarget);
        }

        Ok(RoutedSignal {
            from_connection_id: from_connection_id.to_owned(),
            to_connection_id: to_connection_id.clone(),
            conversation_id: from.conversation_id.clone(),
            payload: payload.into(),
        })
    }

    fn next_session_epoch(&mut self, key: &DeviceKey) -> u64 {
        let epoch = self.next_epoch_by_device.entry(key.clone()).or_insert(0);
        let current = *epoch;
        *epoch += 1;
        current
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebSocketAuthorizationFact {
    pub connection_id: String,
    pub conversation_id: String,
    pub participant_id: String,
    pub device_id: String,
    pub session_epoch: u64,
    pub decision: WebSocketAuthorizationDecision,
    pub reason: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WebSocketAuthorizationDecision {
    Accepted,
    Rejected,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebSocketOutboundMessage {
    pub connection_id: String,
    pub payload: Value,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SingleInstanceWebSocketServer {
    state: SingleInstanceWebSocketState,
    authorization_facts: Vec<WebSocketAuthorizationFact>,
}

impl SingleInstanceWebSocketServer {
    pub fn connect(
        &mut self,
        connection_id: impl Into<String>,
        device: AuthenticatedWebSocketDevice,
    ) -> Result<WebSocketOutboundMessage, WebSocketSignalingError> {
        let binding = self.state.connect(connection_id, device)?;
        self.authorization_facts.push(WebSocketAuthorizationFact {
            connection_id: binding.connection_id.clone(),
            conversation_id: binding.conversation_id.clone(),
            participant_id: binding.participant_id.clone(),
            device_id: binding.device_id.clone(),
            session_epoch: binding.session_epoch,
            decision: WebSocketAuthorizationDecision::Accepted,
            reason: "connection-bound".to_owned(),
        });
        Ok(WebSocketOutboundMessage {
            connection_id: binding.connection_id,
            payload: serde_json::json!({
                "status": "connected",
                "deviceId": binding.device_id,
                "sessionId": binding.session_epoch.to_string(),
                "channelId": binding.conversation_id,
                "reason": "self-hosted-runtime"
            }),
        })
    }

    pub fn disconnect(&mut self, connection_id: &str) -> Option<WebSocketConnectionBinding> {
        self.state.disconnect(connection_id)
    }

    pub fn disconnect_conversation(
        &mut self,
        conversation_id: &str,
    ) -> Vec<WebSocketConnectionBinding> {
        self.state.disconnect_conversation(conversation_id)
    }

    pub fn handle_text(
        &mut self,
        connection_id: &str,
        text: &str,
    ) -> Result<Vec<WebSocketOutboundMessage>, WebSocketSignalingError> {
        let message: Value = serde_json::from_str(text)
            .map_err(|err| WebSocketSignalingError::MalformedMessage(err.to_string()))?;
        let Some(message_type) = message.get("type").and_then(Value::as_str) else {
            return Err(WebSocketSignalingError::MalformedMessage(
                "missing type".to_owned(),
            ));
        };
        match message_type {
            "offer"
            | "answer"
            | "ice-candidate"
            | "hangup"
            | "transmit-start"
            | "transmit-stop"
            | "audio-chunk"
            | "receiver-ready"
            | "receiver-not-ready"
            | "audio-playback-started"
            | "direct-quic-upgrade-request"
            | "selected-friend-prewarm"
            | "conversation-participant-telemetry"
            | "direct-quic-offer"
            | "direct-quic-answer"
            | "control" => self.route_signal_message(connection_id, message),
            "control-command" => Ok(vec![self.command_response(
                connection_id,
                &message,
                "control-command-response",
            )?]),
            "presence-command" => Ok(vec![self.command_response(
                connection_id,
                &message,
                "presence-command-response",
            )?]),
            other => Err(WebSocketSignalingError::MalformedMessage(format!(
                "unsupported message type {other}"
            ))),
        }
    }

    pub fn authorization_facts(&self) -> &[WebSocketAuthorizationFact] {
        &self.authorization_facts
    }

    pub fn binding(&self, connection_id: &str) -> Option<&WebSocketConnectionBinding> {
        self.state.binding(connection_id)
    }

    fn route_signal_message(
        &mut self,
        connection_id: &str,
        message: Value,
    ) -> Result<Vec<WebSocketOutboundMessage>, WebSocketSignalingError> {
        let binding = self
            .state
            .binding(connection_id)
            .ok_or_else(|| WebSocketSignalingError::UnknownConnection(connection_id.to_owned()))?
            .clone();
        let conversation_id = required_text(&message, "channelId")?;
        let from_participant_id = required_text(&message, "fromUserId")?;
        let from_device_id = required_text(&message, "fromDeviceId")?;
        let to_device_id = required_text(&message, "toDeviceId")?;
        if binding.conversation_id != APP_COMPATIBLE_CONVERSATION_ID
            && conversation_id != binding.conversation_id
            || from_participant_id != binding.participant_id
            || from_device_id != binding.device_id
        {
            self.authorization_facts.push(WebSocketAuthorizationFact {
                connection_id: connection_id.to_owned(),
                conversation_id: binding.conversation_id,
                participant_id: binding.participant_id,
                device_id: binding.device_id,
                session_epoch: binding.session_epoch,
                decision: WebSocketAuthorizationDecision::Rejected,
                reason: "envelope-mismatch".to_owned(),
            });
            return Err(WebSocketSignalingError::UnauthorizedEnvelope);
        }
        let routed = self
            .state
            .route_signal(connection_id, to_device_id, message.to_string())?;
        self.authorization_facts.push(WebSocketAuthorizationFact {
            connection_id: connection_id.to_owned(),
            conversation_id: routed.conversation_id,
            participant_id: binding.participant_id,
            device_id: from_device_id.to_owned(),
            session_epoch: binding.session_epoch,
            decision: WebSocketAuthorizationDecision::Accepted,
            reason: "signal-routed".to_owned(),
        });
        Ok(vec![WebSocketOutboundMessage {
            connection_id: routed.to_connection_id,
            payload: message,
        }])
    }

    fn command_response(
        &mut self,
        connection_id: &str,
        message: &Value,
        response_type: &str,
    ) -> Result<WebSocketOutboundMessage, WebSocketSignalingError> {
        let binding = self
            .state
            .binding(connection_id)
            .ok_or_else(|| WebSocketSignalingError::UnknownConnection(connection_id.to_owned()))?
            .clone();
        let request_id = required_text(message, "requestId")?;
        let device_id = required_text(message, "deviceId")?;
        let command_kind = message
            .get("commandKind")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        if device_id != binding.device_id {
            self.authorization_facts.push(WebSocketAuthorizationFact {
                connection_id: connection_id.to_owned(),
                conversation_id: binding.conversation_id,
                participant_id: binding.participant_id,
                device_id: binding.device_id,
                session_epoch: binding.session_epoch,
                decision: WebSocketAuthorizationDecision::Rejected,
                reason: "command-device-mismatch".to_owned(),
            });
            return Err(WebSocketSignalingError::UnauthorizedEnvelope);
        }
        self.authorization_facts.push(WebSocketAuthorizationFact {
            connection_id: connection_id.to_owned(),
            conversation_id: binding.conversation_id.clone(),
            participant_id: binding.participant_id.clone(),
            device_id: binding.device_id.clone(),
            session_epoch: binding.session_epoch,
            decision: WebSocketAuthorizationDecision::Accepted,
            reason: "command-authorized".to_owned(),
        });
        Ok(WebSocketOutboundMessage {
            connection_id: connection_id.to_owned(),
            payload: serde_json::json!({
                "type": response_type,
                "requestId": request_id,
                "status": "ok",
                "body": command_response_body(&binding, command_kind, message)
            }),
        })
    }
}

fn command_response_body(
    binding: &WebSocketConnectionBinding,
    command_kind: &str,
    message: &Value,
) -> Value {
    match command_kind {
        "presence-heartbeat" => serde_json::json!({
            "deviceId": binding.device_id,
            "userId": binding.participant_id,
            "status": "online"
        }),
        "presence-offline" => serde_json::json!({
            "deviceId": binding.device_id,
            "userId": binding.participant_id,
            "status": "offline"
        }),
        "presence-background" => serde_json::json!({
            "deviceId": binding.device_id,
            "userId": binding.participant_id,
            "status": "background"
        }),
        "join-channel" => serde_json::json!({
            "channelId": message.get("channelId").and_then(Value::as_str).unwrap_or("conversation"),
            "userId": binding.participant_id,
            "deviceId": binding.device_id,
            "status": "joined"
        }),
        "leave-channel" => serde_json::json!({
            "channelId": message.get("channelId").and_then(Value::as_str).unwrap_or("conversation"),
            "deviceId": binding.device_id,
            "status": "left"
        }),
        _ => serde_json::json!({
            "status": "accepted"
        }),
    }
}

fn required_text<'a>(
    value: &'a Value,
    key: &'static str,
) -> Result<&'a str, WebSocketSignalingError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| WebSocketSignalingError::MalformedMessage(format!("missing {key}")))
}

fn validate_non_empty(field: &'static str, value: &str) -> Result<(), WebSocketSignalingError> {
    if value.is_empty() {
        Err(WebSocketSignalingError::EmptyIdentityField(field))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(participant_id: &str, device_id: &str) -> AuthenticatedWebSocketDevice {
        AuthenticatedWebSocketDevice {
            conversation_id: "conversation-1".to_owned(),
            participant_id: participant_id.to_owned(),
            device_id: device_id.to_owned(),
        }
    }

    #[test]
    fn websocket_single_instance_routes_authorized_signal_between_connected_devices() {
        let mut state = SingleInstanceWebSocketState::default();
        let a = state
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");
        let b = state
            .connect("conn-b", device("participant-b", "device-b"))
            .expect("device b should connect");

        let routed = state
            .route_signal(&a.connection_id, &b.device_id, "offer")
            .expect("connected devices in the same conversation should route");

        assert_eq!(routed.from_connection_id, "conn-a");
        assert_eq!(routed.to_connection_id, "conn-b");
        assert_eq!(routed.conversation_id, "conversation-1");
        assert_eq!(routed.payload, "offer");
    }

    #[test]
    fn websocket_single_instance_reconnect_replaces_stale_session_authority() {
        let mut state = SingleInstanceWebSocketState::default();
        state
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");
        let first = state
            .connect("conn-b-old", device("participant-b", "device-b"))
            .expect("device b should connect");
        let second = state
            .connect("conn-b-new", device("participant-b", "device-b"))
            .expect("device b should reconnect");

        assert_eq!(first.session_epoch, 0);
        assert_eq!(second.session_epoch, 1);
        assert!(state.binding("conn-b-old").is_none());
        assert!(state.disconnect("conn-b-old").is_none());

        let routed = state
            .route_signal("conn-a", "device-b", "answer")
            .expect("new connection should keep route authority");
        assert_eq!(routed.to_connection_id, "conn-b-new");
    }

    #[test]
    fn websocket_single_instance_disconnect_clears_current_device_route() {
        let mut state = SingleInstanceWebSocketState::default();
        state
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");
        state
            .connect("conn-b", device("participant-b", "device-b"))
            .expect("device b should connect");

        state.disconnect("conn-b");
        let err = state
            .route_signal("conn-a", "device-b", "offer")
            .expect_err("disconnected target should not route");

        assert_eq!(err, WebSocketSignalingError::TargetDisconnected);
    }

    #[test]
    fn websocket_single_instance_rejects_unknown_sender() {
        let state = SingleInstanceWebSocketState::default();

        let err = state
            .route_signal("missing", "device-b", "offer")
            .expect_err("unknown sender should fail closed");

        assert_eq!(
            err,
            WebSocketSignalingError::UnknownConnection("missing".to_owned())
        );
    }

    #[test]
    fn websocket_single_instance_rejects_empty_authenticated_identity() {
        let mut state = SingleInstanceWebSocketState::default();
        let err = state
            .connect(
                "conn-a",
                AuthenticatedWebSocketDevice {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: String::new(),
                    device_id: "device-a".to_owned(),
                },
            )
            .expect_err("empty participant identity should be rejected");

        assert_eq!(
            err,
            WebSocketSignalingError::EmptyIdentityField("participant_id")
        );
    }

    #[test]
    fn websocket_single_instance_server_connects_routes_disconnects_and_reconnects() {
        let mut server = SingleInstanceWebSocketServer::default();
        let notice_a = server
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");
        let notice_b = server
            .connect("conn-b", device("participant-b", "device-b"))
            .expect("device b should connect");

        assert_eq!(notice_a.payload["status"], "connected");
        assert_eq!(notice_b.payload["sessionId"], "0");

        let outbound = server
            .handle_text(
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

        assert_eq!(outbound.len(), 1);
        assert_eq!(outbound[0].connection_id, "conn-b");
        assert_eq!(outbound[0].payload["payload"], "opaque-offer");

        server.disconnect("conn-b");
        let err = server
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "direct-quic-offer",
                    "channelId": "conversation-1",
                    "fromUserId": "participant-a",
                    "fromDeviceId": "device-a",
                    "toUserId": "participant-b",
                    "toDeviceId": "device-b",
                    "payload": "after-disconnect"
                })
                .to_string(),
            )
            .expect_err("disconnected target should not receive signal");
        assert_eq!(err, WebSocketSignalingError::TargetDisconnected);

        let reconnect = server
            .connect("conn-b-new", device("participant-b", "device-b"))
            .expect("device b should reconnect");
        assert_eq!(reconnect.payload["sessionId"], "1");
        assert!(server.binding("conn-b").is_none());
        assert!(server.binding("conn-b-new").is_some());
    }

    #[test]
    fn websocket_single_instance_server_rejects_signal_envelope_mismatch() {
        let mut server = SingleInstanceWebSocketServer::default();
        server
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");
        server
            .connect("conn-b", device("participant-b", "device-b"))
            .expect("device b should connect");

        let err = server
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "direct-quic-offer",
                    "channelId": "conversation-1",
                    "fromUserId": "participant-a",
                    "fromDeviceId": "device-other",
                    "toUserId": "participant-b",
                    "toDeviceId": "device-b",
                    "payload": "spoof"
                })
                .to_string(),
            )
            .expect_err("spoofed device should be rejected");

        assert_eq!(err, WebSocketSignalingError::UnauthorizedEnvelope);
        assert!(server.authorization_facts().iter().any(|fact| fact.decision
            == WebSocketAuthorizationDecision::Rejected
            && fact.reason == "envelope-mismatch"));
    }

    #[test]
    fn websocket_single_instance_server_responds_to_authorized_control_commands() {
        let mut server = SingleInstanceWebSocketServer::default();
        server
            .connect("conn-a", device("participant-a", "device-a"))
            .expect("device a should connect");

        let outbound = server
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "control-command",
                    "requestId": "request-1",
                    "sessionId": "0",
                    "commandKind": "heartbeat",
                    "deviceId": "device-a",
                    "channelId": "conversation-1"
                })
                .to_string(),
            )
            .expect("authorized control command should respond");

        assert_eq!(outbound[0].connection_id, "conn-a");
        assert_eq!(outbound[0].payload["type"], "control-command-response");
        assert_eq!(outbound[0].payload["requestId"], "request-1");
        assert_eq!(outbound[0].payload["status"], "ok");
    }
}
