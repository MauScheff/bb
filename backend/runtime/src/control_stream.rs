use std::io::{BufRead, Write};

use serde_json::Value;

use crate::control_protocol::{
    RUNTIME_CONTROL_PROTOCOL_VERSION, RuntimeControlCommandFrame, RuntimeControlPeerIdentity,
    RuntimeControlProtocolError, RuntimeControlTransport, decode_runtime_control_frame,
    identity_for_runtime_control_frame, require_matching_identity, runtime_control_response_frame,
};

#[derive(Debug, thiserror::Error)]
pub enum RuntimeControlStreamError {
    #[error("io failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("runtime control response serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimeControlIdentityBinding {
    identity: Option<RuntimeControlPeerIdentity>,
}

impl RuntimeControlIdentityBinding {
    pub fn identity(&self) -> Option<&RuntimeControlPeerIdentity> {
        self.identity.as_ref()
    }

    fn bind_or_verify(
        &mut self,
        frame: &RuntimeControlCommandFrame,
    ) -> Result<RuntimeControlPeerIdentity, RuntimeControlProtocolError> {
        if let Some(identity) = &self.identity {
            require_matching_identity(identity, frame)?;
            Ok(identity.clone())
        } else {
            let identity = identity_for_runtime_control_frame(frame)?;
            self.identity = Some(identity.clone());
            Ok(identity)
        }
    }
}

pub fn serve_runtime_control_stream<R, W, F>(
    reader: &mut R,
    writer: &mut W,
    transport: RuntimeControlTransport,
    mut handle: F,
) -> Result<(), RuntimeControlStreamError>
where
    R: BufRead,
    W: Write,
    F: FnMut(&RuntimeControlCommandFrame) -> Result<Value, String>,
{
    let mut line = String::new();
    loop {
        line.clear();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            writer.flush()?;
            return Ok(());
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = runtime_control_response_for_line(trimmed, transport, &mut handle);
        serde_json::to_writer(&mut *writer, &response)?;
        writer.write_all(b"\n")?;
        writer.flush()?;
    }
}

pub fn serve_runtime_control_stream_with_identity_binding<R, W, F>(
    reader: &mut R,
    writer: &mut W,
    transport: RuntimeControlTransport,
    mut handle: F,
) -> Result<(), RuntimeControlStreamError>
where
    R: BufRead,
    W: Write,
    F: FnMut(&RuntimeControlPeerIdentity, &RuntimeControlCommandFrame) -> Result<Value, String>,
{
    let mut binding = RuntimeControlIdentityBinding::default();
    let mut line = String::new();
    loop {
        line.clear();
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            writer.flush()?;
            return Ok(());
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let response = runtime_control_response_for_line_with_identity_binding(
            trimmed,
            transport,
            &mut binding,
            &mut handle,
        );
        serde_json::to_writer(&mut *writer, &response)?;
        writer.write_all(b"\n")?;
        writer.flush()?;
    }
}

pub fn runtime_control_response_for_line<F>(
    line: &str,
    transport: RuntimeControlTransport,
    handle: &mut F,
) -> Value
where
    F: FnMut(&RuntimeControlCommandFrame) -> Result<Value, String>,
{
    match serde_json::from_str::<Value>(line) {
        Ok(value) => match decode_runtime_control_frame(&value) {
            Ok(frame) => match handle(&frame) {
                Ok(body) => runtime_control_response_frame(&frame, "ok", body, transport),
                Err(error) => runtime_control_response_frame(
                    &frame,
                    "error",
                    serde_json::json!({ "error": error }),
                    transport,
                ),
            },
            Err(error) => runtime_control_error_frame(error, transport),
        },
        Err(error) => runtime_control_error_frame(
            RuntimeControlProtocolError::MalformedFrame(error.to_string()),
            transport,
        ),
    }
}

pub fn runtime_control_response_for_line_with_identity_binding<F>(
    line: &str,
    transport: RuntimeControlTransport,
    binding: &mut RuntimeControlIdentityBinding,
    handle: &mut F,
) -> Value
where
    F: FnMut(&RuntimeControlPeerIdentity, &RuntimeControlCommandFrame) -> Result<Value, String>,
{
    match serde_json::from_str::<Value>(line) {
        Ok(value) => match decode_runtime_control_frame(&value) {
            Ok(frame) => match binding.bind_or_verify(&frame) {
                Ok(identity) => match handle(&identity, &frame) {
                    Ok(body) => runtime_control_response_frame(&frame, "ok", body, transport),
                    Err(error) => runtime_control_response_frame(
                        &frame,
                        "error",
                        serde_json::json!({ "error": error }),
                        transport,
                    ),
                },
                Err(error) => runtime_control_error_frame(error, transport),
            },
            Err(error) => runtime_control_error_frame(error, transport),
        },
        Err(error) => runtime_control_error_frame(
            RuntimeControlProtocolError::MalformedFrame(error.to_string()),
            transport,
        ),
    }
}

pub fn runtime_control_error_frame(
    error: RuntimeControlProtocolError,
    transport: RuntimeControlTransport,
) -> Value {
    serde_json::json!({
        "type": "runtime-control-error",
        "protocolVersion": RUNTIME_CONTROL_PROTOCOL_VERSION,
        "status": "error",
        "transport": transport.label(),
        "persistentTransport": transport.is_runtime_persistent(),
        "error": error.to_string()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufReader, Cursor};

    #[test]
    fn runtime_tls_stream_processes_multiple_control_commands() {
        let input = [
            serde_json::json!({
                "type": "control-command",
                "requestId": "request-1",
                "commandKind": "join-channel",
                "deviceId": "device-a",
                "operationId": "join-1",
                "channelId": "channel-1",
                "generation": 3
            })
            .to_string(),
            serde_json::json!({
                "type": "presence-command",
                "requestId": "request-2",
                "commandKind": "presence-keepalive",
                "deviceId": "device-a",
                "operationId": "presence-1",
                "generation": 4
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut reader = BufReader::new(Cursor::new(input.into_bytes()));
        let mut output = Vec::new();

        serve_runtime_control_stream(
            &mut reader,
            &mut output,
            RuntimeControlTransport::RuntimeTlsControl,
            |frame| Ok(serde_json::json!({ "accepted": frame.envelope.command_kind })),
        )
        .expect("stream should serve");

        let lines = String::from_utf8(output).expect("output should be UTF-8");
        let responses = lines
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("response should decode"))
            .collect::<Vec<_>>();

        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "control-command-response");
        assert_eq!(responses[0]["transport"], "runtime-tls-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert_eq!(responses[0]["operationId"], "join-1");
        assert_eq!(responses[0]["generation"], 3);
        assert_eq!(responses[1]["type"], "presence-command-response");
        assert_eq!(responses[1]["body"]["accepted"], "presence-keepalive");
    }

    #[test]
    fn runtime_tls_stream_rejects_live_audio_without_closing_protocol() {
        let input = [
            serde_json::json!({
                "type": "audio-chunk",
                "requestId": "request-audio",
                "commandKind": "audio-chunk",
                "deviceId": "device-a"
            })
            .to_string(),
            serde_json::json!({
                "type": "control-command",
                "requestId": "request-2",
                "commandKind": "leave-channel",
                "deviceId": "device-a",
                "operationId": "leave-1"
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut reader = BufReader::new(Cursor::new(input.into_bytes()));
        let mut output = Vec::new();

        serve_runtime_control_stream(
            &mut reader,
            &mut output,
            RuntimeControlTransport::RuntimeTlsControl,
            |_| Ok(serde_json::json!({ "status": "accepted" })),
        )
        .expect("stream should continue after rejected frame");

        let lines = String::from_utf8(output).expect("output should be UTF-8");
        let responses = lines
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("response should decode"))
            .collect::<Vec<_>>();

        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "runtime-control-error");
        assert_eq!(responses[0]["transport"], "runtime-tls-control");
        assert_eq!(responses[0]["persistentTransport"], true);
        assert!(
            responses[0]["error"]
                .as_str()
                .expect("error should be string")
                .contains("live media")
        );
        assert_eq!(responses[1]["type"], "control-command-response");
        assert_eq!(responses[1]["operationId"], "leave-1");
    }

    #[test]
    fn runtime_tls_stream_command_error_preserves_stream_and_idempotency_fields() {
        let input = [
            serde_json::json!({
                "type": "control-command",
                "requestId": "request-1",
                "commandKind": "join-channel",
                "deviceId": "device-other",
                "operationId": "join-1",
                "channelId": "channel-1",
                "generation": 11
            })
            .to_string(),
            serde_json::json!({
                "type": "control-command",
                "requestId": "request-2",
                "commandKind": "join-channel",
                "deviceId": "device-a",
                "operationId": "join-2",
                "channelId": "channel-1",
                "generation": 12
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut reader = BufReader::new(Cursor::new(input.into_bytes()));
        let mut output = Vec::new();

        serve_runtime_control_stream(
            &mut reader,
            &mut output,
            RuntimeControlTransport::RuntimeTlsControl,
            |frame| {
                if frame.envelope.device_id == "device-a" {
                    Ok(serde_json::json!({ "status": "accepted" }))
                } else {
                    Err("command-device-mismatch".to_owned())
                }
            },
        )
        .expect("stream should continue after command error");

        let lines = String::from_utf8(output).expect("output should be UTF-8");
        let responses = lines
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).expect("response should decode"))
            .collect::<Vec<_>>();

        assert_eq!(responses.len(), 2);
        assert_eq!(responses[0]["type"], "control-command-response");
        assert_eq!(responses[0]["status"], "error");
        assert_eq!(responses[0]["operationId"], "join-1");
        assert_eq!(responses[0]["generation"], 11);
        assert_eq!(responses[0]["body"]["error"], "command-device-mismatch");
        assert_eq!(responses[1]["status"], "ok");
        assert_eq!(responses[1]["operationId"], "join-2");
    }

    #[test]
    fn persistent_control_stream_binds_identity_from_first_frame() {
        let input = [
            serde_json::json!({
                "type": "presence-command",
                "requestId": "request-1",
                "commandKind": "presence-foreground",
                "userId": "user-avery",
                "deviceId": "device-a",
                "operationId": "presence-1"
            })
            .to_string(),
            serde_json::json!({
                "type": "control-command",
                "requestId": "request-2",
                "commandKind": "join-channel",
                "userId": "user-avery",
                "deviceId": "device-a",
                "operationId": "join-1"
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        let mut binding = RuntimeControlIdentityBinding::default();
        let mut output = Vec::new();
        for line in input.lines() {
            let response = runtime_control_response_for_line_with_identity_binding(
                line,
                RuntimeControlTransport::RuntimeTlsControl,
                &mut binding,
                &mut |identity, frame| {
                    Ok(serde_json::json!({
                        "userId": identity.participant_id,
                        "deviceId": identity.device_id,
                        "accepted": frame.envelope.command_kind
                    }))
                },
            );
            output.push(response);
        }

        assert_eq!(output.len(), 2);
        assert_eq!(output[0]["status"], "ok");
        assert_eq!(output[1]["status"], "ok");
        assert_eq!(output[1]["body"]["userId"], "user-avery");
        assert_eq!(
            binding.identity(),
            Some(&RuntimeControlPeerIdentity {
                participant_id: "user-avery".to_owned(),
                device_id: "device-a".to_owned()
            })
        );
    }

    #[test]
    fn persistent_control_stream_rejects_later_identity_mismatch() {
        let mut binding = RuntimeControlIdentityBinding::default();
        let mut handle = |_: &RuntimeControlPeerIdentity, _: &RuntimeControlCommandFrame| {
            Ok(serde_json::json!({ "status": "accepted" }))
        };
        let first = runtime_control_response_for_line_with_identity_binding(
            &serde_json::json!({
                "type": "presence-command",
                "requestId": "request-1",
                "commandKind": "presence-foreground",
                "userId": "user-avery",
                "deviceId": "device-a"
            })
            .to_string(),
            RuntimeControlTransport::RuntimeTlsControl,
            &mut binding,
            &mut handle,
        );
        let second = runtime_control_response_for_line_with_identity_binding(
            &serde_json::json!({
                "type": "presence-command",
                "requestId": "request-2",
                "commandKind": "presence-foreground",
                "userId": "user-blake",
                "deviceId": "device-a"
            })
            .to_string(),
            RuntimeControlTransport::RuntimeTlsControl,
            &mut binding,
            &mut handle,
        );

        assert_eq!(first["status"], "ok");
        assert_eq!(second["type"], "runtime-control-error");
        assert!(
            second["error"]
                .as_str()
                .expect("error should be string")
                .contains("identity")
        );
    }
}
