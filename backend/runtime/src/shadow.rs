use serde_json::Value;

use crate::postgres::{
    KernelDecisionEnvelope, LEGACY_BEGIN_TRANSMIT_ROUTE, REQUEST_TALK_TURN_ROUTE,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LegacyBeginTransmitInput {
    pub channel_id: String,
    pub device_id: String,
    pub requesting_participant_id: String,
    pub requesting_session_epoch: u64,
    pub target_participant_id: String,
    pub operation_id: String,
    pub policy_version: String,
    pub kernel_version: String,
}

impl LegacyBeginTransmitInput {
    pub fn to_request_talk_turn_command(&self) -> Value {
        serde_json::json!({
            "kind": "request-talk-turn",
            "conversationId": wrapped_text(&self.channel_id),
            "requestingParticipantId": wrapped_text(&self.requesting_participant_id),
            "requestingDeviceId": wrapped_text(&self.device_id),
            "requestingSessionEpoch": wrapped_u64(self.requesting_session_epoch),
            "targetParticipantId": wrapped_text(&self.target_participant_id),
            "operationId": self.operation_id,
            "policyVersion": wrapped_text(&self.policy_version),
            "kernelVersion": wrapped_text(&self.kernel_version),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ShadowTalkTurnOutcome {
    Granted {
        conversation_id: String,
        target_device_id: String,
        talk_turn_epoch: Option<u64>,
    },
    Denied {
        reason: String,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ShadowVerdict {
    Equivalent,
    Divergent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ShadowComparison {
    pub cloud_route: &'static str,
    pub self_hosted_route: &'static str,
    pub cloud: ShadowTalkTurnOutcome,
    pub self_hosted: ShadowTalkTurnOutcome,
    pub verdict: ShadowVerdict,
}

#[derive(Debug, thiserror::Error)]
pub enum ShadowComparisonError {
    #[error("missing field `{0}`")]
    MissingField(&'static str),
    #[error("unsupported Cloud begin-transmit response status `{0}`")]
    UnsupportedCloudStatus(String),
    #[error("unsupported kernel decision kind `{0}`")]
    UnsupportedKernelDecision(String),
}

pub fn compare_begin_transmit_response_to_request_talk_turn(
    cloud_response: &Value,
    self_hosted_decision: &KernelDecisionEnvelope,
) -> Result<ShadowComparison, ShadowComparisonError> {
    let cloud = normalize_cloud_begin_transmit_response(cloud_response)?;
    let self_hosted = normalize_request_talk_turn_decision(&self_hosted_decision.decision)?;
    let verdict = if cloud == self_hosted {
        ShadowVerdict::Equivalent
    } else {
        ShadowVerdict::Divergent
    };

    Ok(ShadowComparison {
        cloud_route: LEGACY_BEGIN_TRANSMIT_ROUTE,
        self_hosted_route: REQUEST_TALK_TURN_ROUTE,
        cloud,
        self_hosted,
        verdict,
    })
}

pub fn normalize_cloud_begin_transmit_response(
    response: &Value,
) -> Result<ShadowTalkTurnOutcome, ShadowComparisonError> {
    match required_string(response, &["status"], "status")? {
        "transmitting" => Ok(ShadowTalkTurnOutcome::Granted {
            conversation_id: required_string(response, &["channelId"], "channelId")?.to_owned(),
            target_device_id: required_string(response, &["targetDeviceId"], "targetDeviceId")?
                .to_owned(),
            talk_turn_epoch: optional_string(response, &["transmitId"]).and_then(parse_u64),
        }),
        "denied" => Ok(ShadowTalkTurnOutcome::Denied {
            reason: required_string(response, &["reason"], "reason")?.to_owned(),
        }),
        other => Err(ShadowComparisonError::UnsupportedCloudStatus(
            other.to_owned(),
        )),
    }
}

pub fn normalize_request_talk_turn_decision(
    decision: &Value,
) -> Result<ShadowTalkTurnOutcome, ShadowComparisonError> {
    match required_string(decision, &["kind"], "decision.kind")? {
        "granted" => Ok(ShadowTalkTurnOutcome::Granted {
            conversation_id: required_wrapped_string(
                decision,
                &["grant", "conversationId"],
                "grant.conversationId",
            )?,
            target_device_id: required_wrapped_string(
                decision,
                &["grant", "targetDeviceId"],
                "grant.targetDeviceId",
            )?,
            talk_turn_epoch: Some(required_wrapped_u64(
                decision,
                &["grant", "talkTurnEpoch"],
                "grant.talkTurnEpoch",
            )?),
        }),
        "denied" => Ok(ShadowTalkTurnOutcome::Denied {
            reason: required_string(decision, &["reason"], "decision.reason")?.to_owned(),
        }),
        other => Err(ShadowComparisonError::UnsupportedKernelDecision(
            other.to_owned(),
        )),
    }
}

fn wrapped_text(value: &str) -> Value {
    serde_json::json!({ "value": value })
}

fn wrapped_u64(value: u64) -> Value {
    serde_json::json!({ "value": value })
}

fn required_string<'a>(
    value: &'a Value,
    path: &[&str],
    label: &'static str,
) -> Result<&'a str, ShadowComparisonError> {
    path_value(value, path)
        .and_then(Value::as_str)
        .ok_or(ShadowComparisonError::MissingField(label))
}

fn optional_string<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path_value(value, path).and_then(Value::as_str)
}

fn required_wrapped_string(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<String, ShadowComparisonError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(ShadowComparisonError::MissingField(label))
}

fn required_wrapped_u64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<u64, ShadowComparisonError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_u64)
        .ok_or(ShadowComparisonError::MissingField(label))
}

fn path_value<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(value, |cursor, key| cursor.get(*key))
}

fn parse_u64(value: &str) -> Option<u64> {
    value.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shadow_request_talk_turn_translates_legacy_begin_transmit_to_kernel_command() {
        let input = LegacyBeginTransmitInput {
            channel_id: "conversation-1".to_owned(),
            device_id: "device-a".to_owned(),
            requesting_participant_id: "participant-a".to_owned(),
            requesting_session_epoch: 3,
            target_participant_id: "participant-b".to_owned(),
            operation_id: "op-shadow-1".to_owned(),
            policy_version: "policy-v1".to_owned(),
            kernel_version: "kernel-contract-v1".to_owned(),
        };

        let command = input.to_request_talk_turn_command();

        assert_eq!(command["kind"], "request-talk-turn");
        assert_eq!(command["conversationId"]["value"], "conversation-1");
        assert_eq!(command["requestingDeviceId"]["value"], "device-a");
        assert_eq!(command["requestingSessionEpoch"]["value"], 3);
        assert_eq!(command["operationId"], "op-shadow-1");
    }

    #[test]
    fn shadow_request_talk_turn_matches_granted_cloud_response() {
        let decision = KernelDecisionEnvelope {
            case_id: "shadow-grant".to_owned(),
            command: serde_json::json!({ "kind": "request-talk-turn" }),
            snapshot: serde_json::json!({}),
            decision: serde_json::json!({
                "kind": "granted",
                "grant": {
                    "conversationId": { "value": "conversation-1" },
                    "targetDeviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 1 }
                }
            }),
        };
        let cloud_response = serde_json::json!({
            "channelId": "conversation-1",
            "status": "transmitting",
            "transmitId": "1",
            "startedAt": "2026-05-31T10:00:00Z",
            "expiresAt": "2026-05-31T10:00:15Z",
            "targetUserId": "participant-b",
            "targetDeviceId": "device-b"
        });

        let comparison =
            compare_begin_transmit_response_to_request_talk_turn(&cloud_response, &decision)
                .expect("shadow comparison should normalize grant responses");

        assert_eq!(comparison.cloud_route, LEGACY_BEGIN_TRANSMIT_ROUTE);
        assert_eq!(comparison.self_hosted_route, REQUEST_TALK_TURN_ROUTE);
        assert_eq!(comparison.verdict, ShadowVerdict::Equivalent);
    }

    #[test]
    fn shadow_request_talk_turn_detects_divergent_target_device() {
        let decision = KernelDecisionEnvelope {
            case_id: "shadow-grant".to_owned(),
            command: serde_json::json!({ "kind": "request-talk-turn" }),
            snapshot: serde_json::json!({}),
            decision: serde_json::json!({
                "kind": "granted",
                "grant": {
                    "conversationId": { "value": "conversation-1" },
                    "targetDeviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 1 }
                }
            }),
        };
        let cloud_response = serde_json::json!({
            "channelId": "conversation-1",
            "status": "transmitting",
            "transmitId": "1",
            "startedAt": "2026-05-31T10:00:00Z",
            "expiresAt": "2026-05-31T10:00:15Z",
            "targetUserId": "participant-b",
            "targetDeviceId": "device-c"
        });

        let comparison =
            compare_begin_transmit_response_to_request_talk_turn(&cloud_response, &decision)
                .expect("shadow comparison should normalize grant responses");

        assert_eq!(comparison.verdict, ShadowVerdict::Divergent);
    }

    #[test]
    fn shadow_request_talk_turn_matches_denied_responses() {
        let decision = KernelDecisionEnvelope {
            case_id: "shadow-denied".to_owned(),
            command: serde_json::json!({ "kind": "request-talk-turn" }),
            snapshot: serde_json::json!({}),
            decision: serde_json::json!({
                "kind": "denied",
                "reason": "current-talk-turn-active"
            }),
        };
        let cloud_response = serde_json::json!({
            "status": "denied",
            "reason": "current-talk-turn-active"
        });

        let comparison =
            compare_begin_transmit_response_to_request_talk_turn(&cloud_response, &decision)
                .expect("shadow comparison should normalize denial responses");

        assert_eq!(comparison.verdict, ShadowVerdict::Equivalent);
    }
}
