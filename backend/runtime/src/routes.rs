use serde_json::Value;

use crate::{
    postgres::{
        CommittedEffectPlan, DurableConversationStore, DurablePostgresError,
        KernelDecisionCommitter, KernelDecisionEnvelope, LEGACY_BEGIN_TRANSMIT_ROUTE,
        RELEASE_TALK_TURN_ROUTE, RENEW_TALK_TURN_ROUTE, REQUEST_TALK_TURN_ROUTE,
        ReleaseTalkTurnCommit, RenewTalkTurnCommit, RequestTalkTurnKernelWorker,
        RequestTalkTurnSnapshotLoader, TalkTurnReleaseCommitter, TalkTurnRenewalCommitter,
    },
    shadow::LegacyBeginTransmitInput,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRouteResponse {
    pub route: &'static str,
    pub status_code: u16,
    pub body: Value,
    pub committed: CommittedEffectPlan,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeRenewTalkTurnResponse {
    pub route: &'static str,
    pub status_code: u16,
    pub body: Value,
    pub committed: RenewTalkTurnCommit,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RuntimeReleaseTalkTurnResponse {
    pub route: &'static str,
    pub status_code: u16,
    pub body: Value,
    pub committed: ReleaseTalkTurnCommit,
}

#[derive(Debug, thiserror::Error)]
pub enum RuntimeRouteError {
    #[error(
        "path conversation `{path_conversation_id}` did not match command conversation `{command_conversation_id}`"
    )]
    ConversationMismatch {
        path_conversation_id: String,
        command_conversation_id: String,
    },
    #[error("command kind `{0}` is not supported by this route")]
    UnsupportedCommandKind(String),
    #[error("missing field `{0}`")]
    MissingField(&'static str),
    #[error("durable route execution failed: {0}")]
    Durable(#[from] DurablePostgresError),
}

#[derive(Clone, Debug)]
pub struct SelfHostedRouteService<S, W, C = DurableConversationStore> {
    snapshot_loader: S,
    kernel_worker: W,
    committer: C,
}

impl<S, W> SelfHostedRouteService<S, W>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
{
    pub fn new(snapshot_loader: S, kernel_worker: W) -> Self {
        Self::with_committer(
            snapshot_loader,
            kernel_worker,
            DurableConversationStore::default(),
        )
    }
}

impl<S, W, C> SelfHostedRouteService<S, W, C>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter,
{
    pub fn with_committer(snapshot_loader: S, kernel_worker: W, committer: C) -> Self {
        Self {
            snapshot_loader,
            kernel_worker,
            committer,
        }
    }

    pub fn committer(&self) -> &C {
        &self.committer
    }
}

impl<S, W> SelfHostedRouteService<S, W, DurableConversationStore>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
{
    pub fn store(&self) -> &DurableConversationStore {
        &self.committer
    }
}

impl<S, W, C> SelfHostedRouteService<S, W, C>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter,
{
    pub fn handle_request_talk_turn(
        &mut self,
        conversation_id: &str,
        command: Value,
    ) -> Result<RuntimeRouteResponse, RuntimeRouteError> {
        self.validate_native_request(conversation_id, &command)?;
        let envelope = self.decide(command)?;
        let committed = self
            .committer
            .commit_kernel_decision_envelope(&envelope, REQUEST_TALK_TURN_ROUTE)?;

        Ok(RuntimeRouteResponse {
            route: REQUEST_TALK_TURN_ROUTE,
            status_code: 200,
            body: native_request_talk_turn_response(&envelope)?,
            committed,
        })
    }

    pub fn handle_release_talk_turn(
        &mut self,
        conversation_id: &str,
        command: Value,
    ) -> Result<RuntimeRouteResponse, RuntimeRouteError> {
        self.validate_native_release(conversation_id, &command)?;
        let envelope = self.decide_release(command)?;
        let committed = self
            .committer
            .commit_kernel_decision_envelope(&envelope, RELEASE_TALK_TURN_ROUTE)?;

        Ok(RuntimeRouteResponse {
            route: RELEASE_TALK_TURN_ROUTE,
            status_code: 200,
            body: native_release_talk_turn_response(&envelope)?,
            committed,
        })
    }

    pub fn handle_legacy_begin_transmit(
        &mut self,
        input: LegacyBeginTransmitInput,
    ) -> Result<RuntimeRouteResponse, RuntimeRouteError> {
        let command = input.to_request_talk_turn_command();
        let envelope = self.decide(command)?;
        let committed = self
            .committer
            .commit_kernel_decision_envelope(&envelope, LEGACY_BEGIN_TRANSMIT_ROUTE)?;

        Ok(RuntimeRouteResponse {
            route: LEGACY_BEGIN_TRANSMIT_ROUTE,
            status_code: 200,
            body: legacy_begin_transmit_response(&envelope)?,
            committed,
        })
    }

    fn decide(&self, command: Value) -> Result<KernelDecisionEnvelope, RuntimeRouteError> {
        let input = self
            .snapshot_loader
            .load_request_talk_turn_snapshot(&command)?;
        Ok(self.kernel_worker.decide_request_talk_turn(&input)?)
    }

    fn decide_release(&self, command: Value) -> Result<KernelDecisionEnvelope, RuntimeRouteError> {
        let input = self
            .snapshot_loader
            .load_release_talk_turn_snapshot(&command)?;
        Ok(self.kernel_worker.decide_release_talk_turn(&input)?)
    }

    fn validate_native_request(
        &self,
        conversation_id: &str,
        command: &Value,
    ) -> Result<(), RuntimeRouteError> {
        let kind = required_string(command, &["kind"], "command.kind")?;
        if kind != "request-talk-turn" {
            return Err(RuntimeRouteError::UnsupportedCommandKind(kind.to_owned()));
        }
        let command_conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        if command_conversation_id != conversation_id {
            return Err(RuntimeRouteError::ConversationMismatch {
                path_conversation_id: conversation_id.to_owned(),
                command_conversation_id,
            });
        }
        Ok(())
    }

    fn validate_native_release(
        &self,
        conversation_id: &str,
        command: &Value,
    ) -> Result<(), RuntimeRouteError> {
        let kind = required_string(command, &["kind"], "command.kind")?;
        if kind != "release-talk-turn" {
            return Err(RuntimeRouteError::UnsupportedCommandKind(kind.to_owned()));
        }
        let command_conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        if command_conversation_id != conversation_id {
            return Err(RuntimeRouteError::ConversationMismatch {
                path_conversation_id: conversation_id.to_owned(),
                command_conversation_id,
            });
        }
        Ok(())
    }
}

impl<S, W, C> SelfHostedRouteService<S, W, C>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
    C: KernelDecisionCommitter + TalkTurnRenewalCommitter + TalkTurnReleaseCommitter,
{
    pub fn handle_renew_talk_turn(
        &mut self,
        conversation_id: &str,
        command: Value,
    ) -> Result<RuntimeRenewTalkTurnResponse, RuntimeRouteError> {
        self.validate_native_renew(conversation_id, &command)?;
        let committed = self.committer.renew_talk_turn(&command)?;

        Ok(RuntimeRenewTalkTurnResponse {
            route: RENEW_TALK_TURN_ROUTE,
            status_code: 200,
            body: native_renew_talk_turn_response(&committed),
            committed,
        })
    }

    pub fn handle_actor_release_talk_turn(
        &mut self,
        conversation_id: &str,
        command: Value,
    ) -> Result<RuntimeReleaseTalkTurnResponse, RuntimeRouteError> {
        self.validate_native_release(conversation_id, &command)?;
        let committed = self.committer.release_talk_turn(&command)?;

        Ok(RuntimeReleaseTalkTurnResponse {
            route: RELEASE_TALK_TURN_ROUTE,
            status_code: 200,
            body: actor_release_talk_turn_response(&committed),
            committed,
        })
    }

    fn validate_native_renew(
        &self,
        conversation_id: &str,
        command: &Value,
    ) -> Result<(), RuntimeRouteError> {
        let kind = required_string(command, &["kind"], "command.kind")?;
        if kind != "renew-talk-turn" {
            return Err(RuntimeRouteError::UnsupportedCommandKind(kind.to_owned()));
        }
        let command_conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        if command_conversation_id != conversation_id {
            return Err(RuntimeRouteError::ConversationMismatch {
                path_conversation_id: conversation_id.to_owned(),
                command_conversation_id,
            });
        }
        Ok(())
    }
}

pub fn native_request_talk_turn_response(
    envelope: &KernelDecisionEnvelope,
) -> Result<Value, RuntimeRouteError> {
    match required_string(&envelope.decision, &["kind"], "decision.kind")? {
        "granted" => Ok(serde_json::json!({
            "status": "granted",
            "conversationId": required_wrapped_string(&envelope.decision, &["grant", "conversationId"], "grant.conversationId")?,
            "requestingParticipantId": required_wrapped_string(&envelope.decision, &["grant", "requestingParticipantId"], "grant.requestingParticipantId")?,
            "requestingDeviceId": required_wrapped_string(&envelope.decision, &["grant", "requestingDeviceId"], "grant.requestingDeviceId")?,
            "targetParticipantId": required_wrapped_string(&envelope.decision, &["grant", "targetParticipantId"], "grant.targetParticipantId")?,
            "targetDeviceId": required_wrapped_string(&envelope.decision, &["grant", "targetDeviceId"], "grant.targetDeviceId")?,
            "talkTurnEpoch": required_wrapped_u64(&envelope.decision, &["grant", "talkTurnEpoch"], "grant.talkTurnEpoch")?,
            "expiresAtMs": required_i64(&envelope.decision, &["grant", "expiresAtMs"], "grant.expiresAtMs")?,
        })),
        "denied" => Ok(serde_json::json!({
            "status": "denied",
            "reason": required_string(&envelope.decision, &["reason"], "decision.reason")?,
        })),
        other => Err(RuntimeRouteError::UnsupportedCommandKind(other.to_owned())),
    }
}

pub fn native_renew_talk_turn_response(committed: &RenewTalkTurnCommit) -> Value {
    serde_json::json!({
        "status": "renewed",
        "conversationId": committed.current_talk_turn.conversation_id,
        "talkTurnEpoch": committed.current_talk_turn.talk_turn_epoch,
        "expiresAtMs": committed.current_talk_turn.expires_at_ms,
    })
}

pub fn actor_release_talk_turn_response(committed: &ReleaseTalkTurnCommit) -> Value {
    serde_json::json!({
        "status": "released",
        "conversationId": committed.released_talk_turn.conversation_id,
        "talkTurnEpoch": committed.released_talk_turn.talk_turn_epoch,
    })
}

pub fn native_release_talk_turn_response(
    envelope: &KernelDecisionEnvelope,
) -> Result<Value, RuntimeRouteError> {
    match required_string(&envelope.decision, &["kind"], "decision.kind")? {
        "released" => Ok(serde_json::json!({
            "status": "released",
        })),
        "denied" => Ok(serde_json::json!({
            "status": "denied",
            "reason": required_string(&envelope.decision, &["reason"], "decision.reason")?,
        })),
        other => Err(RuntimeRouteError::UnsupportedCommandKind(other.to_owned())),
    }
}

pub fn legacy_begin_transmit_response(
    envelope: &KernelDecisionEnvelope,
) -> Result<Value, RuntimeRouteError> {
    match required_string(&envelope.decision, &["kind"], "decision.kind")? {
        "granted" => {
            let talk_turn_epoch = required_wrapped_u64(
                &envelope.decision,
                &["grant", "talkTurnEpoch"],
                "grant.talkTurnEpoch",
            )?;
            Ok(serde_json::json!({
                "channelId": required_wrapped_string(&envelope.decision, &["grant", "conversationId"], "grant.conversationId")?,
                "status": "transmitting",
                "transmitId": talk_turn_epoch.to_string(),
                "targetUserId": required_wrapped_string(&envelope.decision, &["grant", "targetParticipantId"], "grant.targetParticipantId")?,
                "targetDeviceId": required_wrapped_string(&envelope.decision, &["grant", "targetDeviceId"], "grant.targetDeviceId")?,
                "expiresAtMs": required_i64(&envelope.decision, &["grant", "expiresAtMs"], "grant.expiresAtMs")?,
            }))
        }
        "denied" => Ok(serde_json::json!({
            "status": "denied",
            "reason": required_string(&envelope.decision, &["reason"], "decision.reason")?,
        })),
        other => Err(RuntimeRouteError::UnsupportedCommandKind(other.to_owned())),
    }
}

fn required_string<'a>(
    value: &'a Value,
    path: &[&str],
    label: &'static str,
) -> Result<&'a str, RuntimeRouteError> {
    path_value(value, path)
        .and_then(Value::as_str)
        .ok_or(RuntimeRouteError::MissingField(label))
}

fn required_wrapped_string(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<String, RuntimeRouteError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(RuntimeRouteError::MissingField(label))
}

fn required_wrapped_u64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<u64, RuntimeRouteError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_u64)
        .ok_or(RuntimeRouteError::MissingField(label))
}

fn required_i64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<i64, RuntimeRouteError> {
    path_value(value, path)
        .and_then(Value::as_i64)
        .ok_or(RuntimeRouteError::MissingField(label))
}

fn path_value<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(value, |cursor, key| cursor.get(*key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        KernelCommandKind, KernelCorpus, KernelCorpusCase,
        postgres::{CorpusKernelDecisionWorker, InMemoryRequestTalkTurnSnapshotLoader},
    };

    fn corpus() -> KernelCorpus {
        KernelCorpus {
            cases: vec![granted_case(), denied_case(), released_case()],
        }
    }

    fn granted_case() -> KernelCorpusCase {
        KernelCorpusCase {
            id: "route-grant".to_owned(),
            kind: KernelCommandKind::RequestTalkTurn,
            command: serde_json::json!({
                "kind": "request-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "requestingParticipantId": { "value": "participant-a" },
                "requestingDeviceId": { "value": "device-a" },
                "requestingSessionEpoch": { "value": 0 },
                "targetParticipantId": { "value": "participant-b" },
                "operationId": "op-route-1",
                "policyVersion": { "value": "policy-v1" },
                "kernelVersion": { "value": "kernel-contract-v1" }
            }),
            snapshot: serde_json::json!({
                "conversationId": { "value": "conversation-1" },
                "snapshotBuiltAtMs": 10000
            }),
            policy: serde_json::json!({ "policyVersion": { "value": "policy-v1" } }),
            expected_decision: serde_json::json!({
                "kind": "granted",
                "grant": {
                    "conversationId": { "value": "conversation-1" },
                    "requestingParticipantId": { "value": "participant-a" },
                    "requestingDeviceId": { "value": "device-a" },
                    "targetParticipantId": { "value": "participant-b" },
                    "targetDeviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 1 },
                    "expiresAtMs": 25000
                },
                "effectPlan": {
                    "transactionEffects": [
                        {
                            "kind": "record-talk-turn",
                            "conversationId": { "value": "conversation-1" },
                            "requestingParticipantId": { "value": "participant-a" },
                            "requestingDeviceId": { "value": "device-a" },
                            "targetParticipantId": { "value": "participant-b" },
                            "targetDeviceId": { "value": "device-b" },
                            "talkTurnEpoch": { "value": 1 },
                            "expiresAtMs": 25000
                        }
                    ],
                    "postCommitEffects": [
                        { "kind": "notify-talk-turn-granted" }
                    ]
                }
            }),
        }
    }

    fn denied_case() -> KernelCorpusCase {
        let mut case = granted_case();
        case.id = "route-denied".to_owned();
        case.command["operationId"] = serde_json::json!("op-route-2");
        case.expected_decision = serde_json::json!({
            "kind": "denied",
            "reason": "current-talk-turn-active",
            "effectPlan": {
                "transactionEffects": [],
                "postCommitEffects": []
            }
        });
        case
    }

    fn released_case() -> KernelCorpusCase {
        KernelCorpusCase {
            id: "route-release".to_owned(),
            kind: KernelCommandKind::ReleaseTalkTurn,
            command: serde_json::json!({
                "kind": "release-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "participantId": { "value": "participant-a" },
                "deviceId": { "value": "device-a" },
                "sessionEpoch": { "value": 0 },
                "talkTurnEpoch": { "value": 1 },
                "operationId": "op-release-1",
                "policyVersion": { "value": "policy-v1" },
                "kernelVersion": { "value": "kernel-contract-v1" }
            }),
            snapshot: serde_json::json!({
                "conversationId": { "value": "conversation-1" },
                "snapshotBuiltAtMs": 10000
            }),
            policy: serde_json::json!({ "policyVersion": { "value": "policy-v1" } }),
            expected_decision: serde_json::json!({
                "kind": "released",
                "effectPlan": {
                    "transactionEffects": [
                        {
                            "kind": "clear-talk-turn",
                            "conversationId": { "value": "conversation-1" },
                            "talkTurnEpoch": { "value": 1 }
                        }
                    ],
                    "postCommitEffects": [
                        {
                            "kind": "notify-talk-turn-released",
                            "conversationId": { "value": "conversation-1" },
                            "participantId": { "value": "participant-a" },
                            "deviceId": { "value": "device-a" },
                            "talkTurnEpoch": { "value": 1 }
                        }
                    ]
                }
            }),
        }
    }

    fn service()
    -> SelfHostedRouteService<InMemoryRequestTalkTurnSnapshotLoader, CorpusKernelDecisionWorker>
    {
        let corpus = corpus();
        let loader = InMemoryRequestTalkTurnSnapshotLoader::from_cases(corpus.cases.iter());
        let worker = CorpusKernelDecisionWorker::new(&corpus);
        SelfHostedRouteService::new(loader, worker)
    }

    fn renew_command() -> Value {
        serde_json::json!({
            "kind": "renew-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "participantId": { "value": "participant-a" },
            "deviceId": { "value": "device-a" },
            "talkTurnEpoch": { "value": 1 },
            "operationId": "op-renew-1",
            "nowMs": 20_000,
            "policyVersion": { "value": "policy-v1" },
            "maxTalkTurnLeaseMs": 15_000,
            "grantsEnabled": true,
            "ownerRuntimeId": "runtime-a",
            "ownerEpoch": { "value": 1 },
            "ownerLeaseExpiresAtMs": 60_000
        })
    }

    #[test]
    fn self_hosted_route_probe_commits_native_request_talk_turn() {
        let mut service = service();
        let command = granted_case().command;

        let response = service
            .handle_request_talk_turn("conversation-1", command)
            .expect("native request route should commit");

        assert_eq!(response.route, REQUEST_TALK_TURN_ROUTE);
        assert_eq!(response.status_code, 200);
        assert_eq!(response.body["status"], "granted");
        assert_eq!(response.body["talkTurnEpoch"], 1);
        assert_eq!(
            service
                .store()
                .current_talk_turn("conversation-1")
                .map(|turn| turn.target_device_id.as_str()),
            Some("device-b")
        );
        assert_eq!(service.store().replay_facts().len(), 1);
        assert_eq!(service.store().post_commit_outbox().len(), 1);
    }

    #[test]
    fn self_hosted_route_probe_rejects_mismatched_path_conversation() {
        let mut service = service();
        let command = granted_case().command;

        let err = service
            .handle_request_talk_turn("conversation-other", command)
            .expect_err("route path should fence the command conversation");

        assert!(matches!(
            err,
            RuntimeRouteError::ConversationMismatch {
                path_conversation_id,
                command_conversation_id
            } if path_conversation_id == "conversation-other"
                && command_conversation_id == "conversation-1"
        ));
        assert!(service.store().replay_facts().is_empty());
    }

    #[test]
    fn self_hosted_route_probe_maps_denial_to_route_response_without_db_write() {
        let mut service = service();
        let command = denied_case().command;

        let response = service
            .handle_request_talk_turn("conversation-1", command)
            .expect("denial should still persist replay fact");

        assert_eq!(response.body["status"], "denied");
        assert_eq!(response.body["reason"], "current-talk-turn-active");
        assert!(
            service
                .store()
                .current_talk_turn("conversation-1")
                .is_none()
        );
        assert_eq!(service.store().replay_facts().len(), 1);
        assert!(service.store().post_commit_outbox().is_empty());
    }

    #[test]
    fn self_hosted_route_probe_accepts_legacy_begin_transmit_boundary() {
        let mut service = service();
        let response = service
            .handle_legacy_begin_transmit(LegacyBeginTransmitInput {
                channel_id: "conversation-1".to_owned(),
                device_id: "device-a".to_owned(),
                requesting_participant_id: "participant-a".to_owned(),
                requesting_session_epoch: 0,
                target_participant_id: "participant-b".to_owned(),
                operation_id: "op-route-1".to_owned(),
                policy_version: "policy-v1".to_owned(),
                kernel_version: "kernel-contract-v1".to_owned(),
            })
            .expect("legacy begin-transmit route should translate to request-talk-turn");

        assert_eq!(response.route, LEGACY_BEGIN_TRANSMIT_ROUTE);
        assert_eq!(response.body["channelId"], "conversation-1");
        assert_eq!(response.body["status"], "transmitting");
        assert_eq!(response.body["transmitId"], "1");
        assert_eq!(
            response.committed.replay_fact.route,
            LEGACY_BEGIN_TRANSMIT_ROUTE
        );
    }

    #[test]
    fn self_hosted_route_probe_commits_native_release_talk_turn() {
        let mut service = service();
        let grant = service
            .handle_request_talk_turn("conversation-1", granted_case().command)
            .expect("grant should create current Talk Turn");
        assert_eq!(grant.body["status"], "granted");
        let release = service
            .handle_release_talk_turn("conversation-1", released_case().command)
            .expect("release should clear current Talk Turn");

        assert_eq!(release.route, RELEASE_TALK_TURN_ROUTE);
        assert_eq!(release.status_code, 200);
        assert_eq!(release.body["status"], "released");
        assert!(
            service
                .store()
                .current_talk_turn("conversation-1")
                .is_none()
        );
        assert_eq!(service.store().replay_facts().len(), 2);
        assert_eq!(service.store().post_commit_outbox().len(), 2);
    }

    #[test]
    fn self_hosted_route_probe_releases_talk_turn_through_actor() {
        let mut service = service();
        service
            .handle_request_talk_turn("conversation-1", granted_case().command)
            .expect("grant should create current Talk Turn");

        let release = service
            .handle_actor_release_talk_turn("conversation-1", released_case().command)
            .expect("actor release should clear current Talk Turn");

        assert_eq!(release.route, RELEASE_TALK_TURN_ROUTE);
        assert_eq!(release.status_code, 200);
        assert_eq!(release.body["status"], "released");
        assert_eq!(release.body["talkTurnEpoch"], 1);
        assert!(
            service
                .store()
                .current_talk_turn("conversation-1")
                .is_none()
        );
        assert_eq!(service.store().replay_facts().len(), 1);
        assert_eq!(service.store().talk_turn_actor_events().len(), 1);
        assert_eq!(
            service.store().talk_turn_actor_events()[0].event_kind,
            "talk-turn-released"
        );
    }

    #[test]
    fn self_hosted_route_probe_renews_talk_turn_without_kernel_decision() {
        let mut service = service();
        service
            .handle_request_talk_turn("conversation-1", granted_case().command)
            .expect("grant should create current Talk Turn");

        let renew = service
            .handle_renew_talk_turn("conversation-1", renew_command())
            .expect("renew should extend current Talk Turn");

        assert_eq!(renew.route, RENEW_TALK_TURN_ROUTE);
        assert_eq!(renew.status_code, 200);
        assert_eq!(renew.body["status"], "renewed");
        assert_eq!(renew.body["talkTurnEpoch"], 1);
        assert_eq!(renew.body["expiresAtMs"], 35_000);
        assert_eq!(
            service
                .store()
                .current_talk_turn("conversation-1")
                .map(|turn| turn.expires_at_ms),
            Some(35_000)
        );
        assert_eq!(service.store().talk_turn_actor_events().len(), 1);
    }

    #[test]
    fn self_hosted_route_probe_replays_same_operation_id_idempotently() {
        let mut service = service();
        let command = granted_case().command;

        let first = service
            .handle_request_talk_turn("conversation-1", command.clone())
            .expect("first request should commit");
        let second = service
            .handle_request_talk_turn("conversation-1", command)
            .expect("same request should replay idempotently");

        assert_eq!(
            first.committed.replay_fact.replay_id,
            second.committed.replay_fact.replay_id
        );
        assert_eq!(service.store().replay_facts().len(), 1);
    }
}
