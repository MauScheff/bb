use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const RUNTIME_CONTROL_PROTOCOL_VERSION: &str = "beep-runtime-control-v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeControlTransport {
    RuntimeQuicControl,
    RuntimeTlsControl,
    RuntimeHttpRequest,
    WebSocketCompatibility,
}

impl RuntimeControlTransport {
    pub fn label(self) -> &'static str {
        match self {
            Self::RuntimeQuicControl => "runtime-quic-control",
            Self::RuntimeTlsControl => "runtime-tls-control",
            Self::RuntimeHttpRequest => "runtime-http-request",
            Self::WebSocketCompatibility => "websocket-compatibility",
        }
    }

    pub fn is_runtime_persistent(self) -> bool {
        matches!(self, Self::RuntimeQuicControl | Self::RuntimeTlsControl)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeControlFrameType {
    ControlCommand,
    PresenceCommand,
}

impl RuntimeControlFrameType {
    pub fn response_type(self) -> &'static str {
        match self {
            Self::ControlCommand => "control-command-response",
            Self::PresenceCommand => "presence-command-response",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeControlCommandFrame {
    pub frame_type: RuntimeControlFrameType,
    pub request_id: String,
    pub session_id: Option<String>,
    pub envelope: RuntimeControlCommandEnvelope,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeControlCommandEnvelope {
    pub command_kind: String,
    pub user_id: Option<String>,
    pub user_handle: Option<String>,
    pub device_id: String,
    pub operation_id: Option<String>,
    pub channel_id: Option<String>,
    pub contact_id: Option<String>,
    pub friend_handle: Option<String>,
    pub friend_user_id: Option<String>,
    pub other_handle: Option<String>,
    pub other_user_id: Option<String>,
    pub transmit_id: Option<String>,
    pub subject: Option<String>,
    pub device_session_proof: Option<String>,
    pub generation: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeControlPeerIdentity {
    pub participant_id: String,
    pub device_id: String,
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum RuntimeControlProtocolError {
    #[error("runtime control frame was malformed: {0}")]
    MalformedFrame(String),
    #[error("runtime control frame type `{0}` is unsupported")]
    UnsupportedFrameType(String),
    #[error("runtime control frame is missing `{0}`")]
    MissingField(&'static str),
    #[error("runtime control frame cannot carry live media")]
    LiveMediaRejected,
    #[error("runtime control frame identity did not match the bound connection identity")]
    IdentityMismatch,
}

pub fn decode_runtime_control_frame(
    value: &Value,
) -> Result<RuntimeControlCommandFrame, RuntimeControlProtocolError> {
    let frame_type = match required_text(value, "type")? {
        "control-command" => RuntimeControlFrameType::ControlCommand,
        "presence-command" => RuntimeControlFrameType::PresenceCommand,
        "audio-chunk" => return Err(RuntimeControlProtocolError::LiveMediaRejected),
        other => {
            return Err(RuntimeControlProtocolError::UnsupportedFrameType(
                other.to_owned(),
            ));
        }
    };
    let request_id = required_text(value, "requestId")?.to_owned();
    let session_id = value
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let envelope: RuntimeControlCommandEnvelope = serde_json::from_value(value.clone())
        .map_err(|error| RuntimeControlProtocolError::MalformedFrame(error.to_string()))?;
    if envelope.command_kind.trim().is_empty() {
        return Err(RuntimeControlProtocolError::MissingField("commandKind"));
    }
    if envelope.device_id.trim().is_empty() {
        return Err(RuntimeControlProtocolError::MissingField("deviceId"));
    }
    Ok(RuntimeControlCommandFrame {
        frame_type,
        request_id,
        session_id,
        envelope,
    })
}

pub fn identity_for_runtime_control_frame(
    frame: &RuntimeControlCommandFrame,
) -> Result<RuntimeControlPeerIdentity, RuntimeControlProtocolError> {
    let participant_id = frame
        .envelope
        .user_id
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .map(str::to_owned)
        .or_else(|| {
            frame
                .envelope
                .user_handle
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .map(user_id_for_handle)
        })
        .ok_or(RuntimeControlProtocolError::MissingField("userId"))?;
    Ok(RuntimeControlPeerIdentity {
        participant_id,
        device_id: frame.envelope.device_id.clone(),
    })
}

pub fn require_matching_identity(
    expected: &RuntimeControlPeerIdentity,
    frame: &RuntimeControlCommandFrame,
) -> Result<(), RuntimeControlProtocolError> {
    let observed = identity_for_runtime_control_frame(frame)?;
    if observed == *expected {
        Ok(())
    } else {
        Err(RuntimeControlProtocolError::IdentityMismatch)
    }
}

pub fn runtime_control_response_frame(
    frame: &RuntimeControlCommandFrame,
    status: &str,
    body: Value,
    transport: RuntimeControlTransport,
) -> Value {
    serde_json::json!({
        "type": frame.frame_type.response_type(),
        "protocolVersion": RUNTIME_CONTROL_PROTOCOL_VERSION,
        "requestId": frame.request_id,
        "status": status,
        "transport": transport.label(),
        "persistentTransport": transport.is_runtime_persistent(),
        "commandId": frame.envelope.operation_id,
        "operationId": frame.envelope.operation_id,
        "deviceId": frame.envelope.device_id,
        "channelId": frame.envelope.channel_id,
        "generation": frame.envelope.generation,
        "body": body
    })
}

fn required_text<'a>(
    value: &'a Value,
    key: &'static str,
) -> Result<&'a str, RuntimeControlProtocolError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or(RuntimeControlProtocolError::MissingField(key))
}

fn user_id_for_handle(handle: &str) -> String {
    format!("user-{}", handle.trim_start_matches('@'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_control_decodes_swift_websocket_compatible_command_frame() {
        let value = serde_json::json!({
            "type": "control-command",
            "requestId": "request-1",
            "sessionId": "session-1",
            "commandKind": "join-channel",
            "userHandle": "@avery",
            "deviceId": "device-a",
            "operationId": "join-1",
            "channelId": "channel-1",
            "generation": 7
        });

        let frame = decode_runtime_control_frame(&value).expect("frame should decode");

        assert_eq!(frame.frame_type, RuntimeControlFrameType::ControlCommand);
        assert_eq!(frame.request_id, "request-1");
        assert_eq!(frame.session_id.as_deref(), Some("session-1"));
        assert_eq!(frame.envelope.command_kind, "join-channel");
        assert_eq!(frame.envelope.user_handle.as_deref(), Some("@avery"));
        assert_eq!(frame.envelope.operation_id.as_deref(), Some("join-1"));
        assert_eq!(frame.envelope.generation, Some(7));
    }

    #[test]
    fn runtime_control_rejects_live_media_frames() {
        let value = serde_json::json!({
            "type": "audio-chunk",
            "requestId": "request-1",
            "commandKind": "audio-chunk",
            "deviceId": "device-a"
        });

        assert_eq!(
            decode_runtime_control_frame(&value),
            Err(RuntimeControlProtocolError::LiveMediaRejected)
        );
    }

    #[test]
    fn runtime_control_response_preserves_idempotency_and_transport() {
        let frame = decode_runtime_control_frame(&serde_json::json!({
            "type": "control-command",
            "requestId": "request-1",
            "commandKind": "join-channel",
            "userId": "user-avery",
            "deviceId": "device-a",
            "operationId": "join-1",
            "channelId": "channel-1",
            "generation": 7
        }))
        .expect("frame should decode");

        let response = runtime_control_response_frame(
            &frame,
            "ok",
            serde_json::json!({ "status": "joined" }),
            RuntimeControlTransport::RuntimeQuicControl,
        );

        assert_eq!(response["type"], "control-command-response");
        assert_eq!(
            response["protocolVersion"],
            RUNTIME_CONTROL_PROTOCOL_VERSION
        );
        assert_eq!(response["transport"], "runtime-quic-control");
        assert_eq!(response["persistentTransport"], true);
        assert_eq!(response["operationId"], "join-1");
        assert_eq!(response["generation"], 7);
    }

    #[test]
    fn runtime_control_identity_binds_from_user_id_or_handle() {
        let user_id_frame = decode_runtime_control_frame(&serde_json::json!({
            "type": "presence-command",
            "requestId": "request-1",
            "commandKind": "presence-foreground",
            "userId": "user-avery",
            "deviceId": "device-a"
        }))
        .expect("frame should decode");
        assert_eq!(
            identity_for_runtime_control_frame(&user_id_frame),
            Ok(RuntimeControlPeerIdentity {
                participant_id: "user-avery".to_owned(),
                device_id: "device-a".to_owned()
            })
        );

        let handle_frame = decode_runtime_control_frame(&serde_json::json!({
            "type": "presence-command",
            "requestId": "request-2",
            "commandKind": "presence-foreground",
            "userHandle": "@blake",
            "deviceId": "device-b"
        }))
        .expect("frame should decode");
        assert_eq!(
            identity_for_runtime_control_frame(&handle_frame),
            Ok(RuntimeControlPeerIdentity {
                participant_id: "user-blake".to_owned(),
                device_id: "device-b".to_owned()
            })
        );
    }

    #[test]
    fn runtime_control_identity_rejects_connection_mismatch() {
        let frame = decode_runtime_control_frame(&serde_json::json!({
            "type": "control-command",
            "requestId": "request-1",
            "commandKind": "join-channel",
            "userId": "user-avery",
            "deviceId": "device-a"
        }))
        .expect("frame should decode");

        assert_eq!(
            require_matching_identity(
                &RuntimeControlPeerIdentity {
                    participant_id: "user-blake".to_owned(),
                    device_id: "device-a".to_owned()
                },
                &frame
            ),
            Err(RuntimeControlProtocolError::IdentityMismatch)
        );
    }
}
