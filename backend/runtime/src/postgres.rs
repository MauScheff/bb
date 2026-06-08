use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{BufRead, BufReader, Write},
    os::fd::FromRawFd,
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

use postgres::Client;
use serde_json::Value;

use crate::{
    KernelCommandKind, KernelCorpus, KernelCorpusCase, KernelHarnessError,
    run_kernel_command_with_deadline, sha256_hex,
    talk_turn_actor::{
        ActiveTalkTurn, ActorPolicySnapshot, ConversationOwner, DurableTalkTurnEvent,
        DurableTalkTurnEventKind, TalkTurnActor, TalkTurnRenewal,
    },
};

pub const REQUEST_TALK_TURN_ROUTE: &str = "/v1/conversations/{conversationId}/talk-turns/request";
pub const RENEW_TALK_TURN_ROUTE: &str = "/v1/conversations/{conversationId}/talk-turns/renew";
pub const RELEASE_TALK_TURN_ROUTE: &str = "/v1/conversations/{conversationId}/talk-turns/release";
pub const LEGACY_BEGIN_TRANSMIT_ROUTE: &str = "/v1/channels/{channelId}/begin-transmit";
pub const POSTGRES_SCHEMA_SQL: &str =
    include_str!("../../infra/self-hosted/sql/001_runtime_schema.sql");

pub const REQUEST_TALK_TURN_SNAPSHOT_SQL: &str = r#"
select
  c.conversation_id,
  c.conversation_seq,
  c.policy_version,
  p.participant_id,
  d.device_id,
  rs.session_epoch,
  rs.last_seen_ms,
  dp.observed_at_ms as presence_observed_at_ms,
  dar.session_epoch as readiness_session_epoch,
  dar.observed_at_ms as readiness_observed_at_ms,
  wt.observed_at_ms as wake_observed_at_ms,
  ctt.requesting_participant_id as current_requesting_participant_id,
  ctt.requesting_device_id as current_requesting_device_id,
  ctt.target_participant_id as current_target_participant_id,
  ctt.target_device_id as current_target_device_id,
  ctt.talk_turn_epoch,
  ctt.expires_at_ms
from runtime_conversations c
join runtime_participants p on p.conversation_id = c.conversation_id
left join runtime_participant_devices d on d.conversation_id = p.conversation_id
  and d.participant_id = p.participant_id
left join runtime_sessions rs on rs.conversation_id = d.conversation_id
  and rs.participant_id = d.participant_id
  and rs.device_id = d.device_id
left join runtime_device_presence dp on dp.conversation_id = d.conversation_id
  and dp.participant_id = d.participant_id
  and dp.device_id = d.device_id
left join runtime_device_audio_readiness dar on dar.conversation_id = d.conversation_id
  and dar.participant_id = d.participant_id
  and dar.device_id = d.device_id
left join runtime_wake_targets wt on wt.conversation_id = d.conversation_id
  and wt.participant_id = d.participant_id
  and wt.device_id = d.device_id
left join runtime_current_talk_turns ctt on ctt.conversation_id = c.conversation_id
where c.conversation_id = $1
order by p.participant_id, d.device_id
"#;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DurableConversationStore {
    current_talk_turns: BTreeMap<String, CurrentTalkTurnRow>,
    remembered_contacts_by_handle: BTreeMap<String, BTreeSet<String>>,
    profiles_by_handle: BTreeMap<String, String>,
    alert_push_tokens_by_handle: BTreeMap<String, DurableAlertPushToken>,
    beep_threads: BTreeMap<String, DurableBeepThread>,
    beep_aliases_by_id: BTreeMap<String, String>,
    next_beep_id: u64,
    replay_facts: Vec<KernelReplayFact>,
    post_commit_outbox: Vec<PostCommitOutboxRow>,
    operation_results: BTreeMap<(String, String), CommittedEffectPlan>,
    actor_operation_results: BTreeMap<(String, String), TalkTurnActorOperationResult>,
    talk_turn_actor_events: Vec<TalkTurnActorEventRecord>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DurableBeepThread {
    pub beep_id: String,
    pub from_handle: String,
    pub to_handle: String,
    pub channel_id: String,
    pub status: String,
    pub request_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DurableAlertPushToken {
    pub handle: String,
    pub device_id: String,
    pub token: String,
    pub apns_environment: Option<String>,
    pub status: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CurrentTalkTurnRow {
    pub conversation_id: String,
    pub requesting_participant_id: String,
    pub requesting_device_id: String,
    pub target_participant_id: String,
    pub target_device_id: String,
    pub talk_turn_epoch: u64,
    pub expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TalkTurnActorEventRecord {
    pub event_row_id: u64,
    pub conversation_id: String,
    pub owner_runtime_id: String,
    pub owner_epoch: u64,
    pub actor_event_id: u64,
    pub event_kind: String,
    pub talk_turn_epoch: Option<u64>,
    pub operation_id: Option<String>,
    pub event_json: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KernelReplayFact {
    pub replay_id: u64,
    pub case_id: String,
    pub route: &'static str,
    pub conversation_id: Option<String>,
    pub operation_id: Option<String>,
    pub command_hash: String,
    pub snapshot_hash: String,
    pub decision_hash: String,
    pub decision_kind: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommittedEffectPlan {
    pub replay_fact: KernelReplayFact,
    pub outbox_rows: Vec<PostCommitOutboxRow>,
    pub current_talk_turn: Option<CurrentTalkTurnRow>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RenewTalkTurnCommit {
    pub current_talk_turn: CurrentTalkTurnRow,
    pub actor_events: Vec<TalkTurnActorEventRecord>,
    pub side_effects: Vec<RuntimeSideEffect>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReleaseTalkTurnCommit {
    pub released_talk_turn: CurrentTalkTurnRow,
    pub actor_events: Vec<TalkTurnActorEventRecord>,
    pub side_effects: Vec<RuntimeSideEffect>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TalkTurnActorOperationResult {
    route: &'static str,
    operation_id: String,
    command_hash: String,
    commit: TalkTurnActorOperationCommit,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum TalkTurnActorOperationCommit {
    Renew(RenewTalkTurnCommit),
    Release(ReleaseTalkTurnCommit),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PostCommitOutboxRow {
    pub outbox_id: u64,
    pub replay_id: u64,
    pub effect_kind: String,
    pub effect_json: Value,
    pub delivered: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DeliveredPostCommitEffect {
    NotifyTalkTurnGranted {
        conversation_id: String,
        requesting_participant_id: String,
        requesting_device_id: String,
        target_participant_id: String,
        target_device_id: String,
        talk_turn_epoch: u64,
    },
    WakeTargetDevice {
        conversation_id: String,
        participant_id: String,
        device_id: String,
        talk_turn_epoch: u64,
    },
    NotifyTalkTurnReleased {
        conversation_id: String,
        participant_id: String,
        device_id: String,
        talk_turn_epoch: u64,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeSideEffect {
    WebSocketNotifyTalkTurnGranted {
        conversation_id: String,
        requesting_participant_id: String,
        requesting_device_id: String,
        target_participant_id: String,
        target_device_id: String,
        talk_turn_epoch: u64,
    },
    WebSocketNotifyTalkTurnReleased {
        conversation_id: String,
        participant_id: String,
        device_id: String,
        talk_turn_epoch: u64,
    },
    WebSocketNotifyTalkTurnRenewed {
        conversation_id: String,
        talk_turn_epoch: u64,
    },
    ApnsWakeTargetDevice {
        conversation_id: String,
        participant_id: String,
        device_id: String,
        talk_turn_epoch: u64,
    },
    DiagnosticEvent {
        conversation_id: String,
        event_kind: String,
        talk_turn_epoch: u64,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum DurablePostgresError {
    #[error("unsupported kernel command for route {route}: {kind:?}")]
    UnsupportedCommand {
        route: &'static str,
        kind: KernelCommandKind,
    },
    #[error("missing field `{0}`")]
    MissingField(&'static str),
    #[error("unsupported transaction effect `{0}`")]
    UnsupportedTransactionEffect(String),
    #[error("malformed transaction effect `{0}`")]
    MalformedTransactionEffect(String),
    #[error("transaction tried to record more than one current Talk Turn for `{0}`")]
    DuplicateCurrentTalkTurnWrite(String),
    #[error("unsupported post-commit effect `{0}`")]
    UnsupportedPostCommitEffect(String),
    #[error("post-commit effect delivery failed: {0}")]
    PostCommitEffectDeliveryFailed(String),
    #[error(
        "operation `{operation_id}` on route `{route}` was replayed with a different command hash"
    )]
    IdempotencyConflict {
        route: &'static str,
        operation_id: String,
    },
    #[error(
        "actor event `{actor_event_id}` for conversation `{conversation_id}` owner epoch `{owner_epoch}` conflicts with a committed event"
    )]
    ActorEventConflict {
        conversation_id: String,
        owner_epoch: u64,
        actor_event_id: u64,
    },
    #[error("talk-turn renewal rejected: {0}")]
    TalkTurnRenewalRejected(String),
    #[error("no request-talk-turn snapshot found for command")]
    SnapshotNotFound,
    #[error("kernel worker could not decide request-talk-turn input")]
    KernelDecisionNotFound,
    #[error("kernel worker failed: {0}")]
    KernelWorker(#[source] KernelHarnessError),
    #[error("kernel worker returned malformed decision JSON: {0}")]
    MalformedKernelDecision(#[source] serde_json::Error),
    #[error("Postgres query failed: {0}")]
    Postgres(#[from] postgres::Error),
    #[error("snapshot field `{field}` had negative value `{value}`")]
    NegativeSnapshotValue { field: &'static str, value: i64 },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestTalkTurnKernelInput {
    pub command: Value,
    pub snapshot: Value,
    pub policy: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KernelDecisionEnvelope {
    pub case_id: String,
    pub command: Value,
    pub snapshot: Value,
    pub decision: Value,
}

pub trait KernelDecisionCommitter {
    fn commit_kernel_decision_envelope(
        &mut self,
        envelope: &KernelDecisionEnvelope,
        route: &'static str,
    ) -> Result<CommittedEffectPlan, DurablePostgresError>;
}

pub trait TalkTurnRenewalCommitter {
    fn renew_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<RenewTalkTurnCommit, DurablePostgresError>;
}

pub trait TalkTurnReleaseCommitter {
    fn release_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<ReleaseTalkTurnCommit, DurablePostgresError>;
}

pub trait DurableContactStore {
    fn remember_contact_pair(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError>;

    fn forget_contact(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError>;

    fn remembered_contact_handles(
        &mut self,
        owner_handle: &str,
    ) -> Result<Vec<String>, DurablePostgresError>;

    fn clear_remembered_contacts(&mut self) -> Result<usize, DurablePostgresError>;

    fn upsert_profile(
        &mut self,
        handle: &str,
        profile_name: &str,
    ) -> Result<(), DurablePostgresError>;

    fn profile_name(&mut self, handle: &str) -> Result<Option<String>, DurablePostgresError>;

    fn clear_profiles(&mut self) -> Result<usize, DurablePostgresError>;
}

pub trait DurableAlertPushTokenStore {
    fn upsert_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        token: &str,
        apns_environment: Option<&str>,
    ) -> Result<DurableAlertPushToken, DurablePostgresError>;

    fn valid_alert_push_token(
        &mut self,
        handle: &str,
    ) -> Result<Option<DurableAlertPushToken>, DurablePostgresError>;

    fn invalidate_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        reason: &str,
    ) -> Result<(), DurablePostgresError>;

    fn clear_alert_push_tokens(&mut self) -> Result<usize, DurablePostgresError>;
}

pub trait DurableBeepThreadStore {
    fn create_or_refresh_beep_thread(
        &mut self,
        from_handle: &str,
        to_handle: &str,
        channel_id: &str,
    ) -> Result<DurableBeepThread, DurablePostgresError>;

    fn beep_thread(
        &mut self,
        beep_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError>;

    fn set_beep_thread_status(
        &mut self,
        beep_id: &str,
        status: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError>;

    fn alias_beep_thread(
        &mut self,
        alias_beep_id: &str,
        channel_id: &str,
    ) -> Result<(), DurablePostgresError>;

    fn alias_channel_for_beep_thread(
        &mut self,
        alias_beep_id: &str,
    ) -> Result<Option<String>, DurablePostgresError>;

    fn current_pending_beep_thread_id(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<String>, DurablePostgresError>;

    fn pending_beep_threads_for_handle(
        &mut self,
        handle: &str,
        direction: &str,
    ) -> Result<Vec<DurableBeepThread>, DurablePostgresError>;

    fn pending_beep_thread_for_channel(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError>;

    fn clear_beep_threads(&mut self) -> Result<usize, DurablePostgresError>;
}

pub trait PostCommitEffectSink {
    fn deliver_post_commit_effect(
        &mut self,
        row: &PostCommitOutboxRow,
    ) -> Result<(), DurablePostgresError>;
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RecordingPostCommitEffectSink {
    delivered: Vec<PostCommitOutboxRow>,
    actions: Vec<DeliveredPostCommitEffect>,
    side_effects: Vec<RuntimeSideEffect>,
}

impl RecordingPostCommitEffectSink {
    pub fn delivered(&self) -> &[PostCommitOutboxRow] {
        &self.delivered
    }

    pub fn actions(&self) -> &[DeliveredPostCommitEffect] {
        &self.actions
    }

    pub fn side_effects(&self) -> &[RuntimeSideEffect] {
        &self.side_effects
    }
}

impl PostCommitEffectSink for RecordingPostCommitEffectSink {
    fn deliver_post_commit_effect(
        &mut self,
        row: &PostCommitOutboxRow,
    ) -> Result<(), DurablePostgresError> {
        let action = decode_post_commit_effect(row)?;
        let side_effects = plan_runtime_side_effects(&action);
        self.delivered.push(row.clone());
        self.actions.push(action);
        self.side_effects.extend(side_effects);
        Ok(())
    }
}

pub fn plan_runtime_side_effects(action: &DeliveredPostCommitEffect) -> Vec<RuntimeSideEffect> {
    match action {
        DeliveredPostCommitEffect::NotifyTalkTurnGranted {
            conversation_id,
            requesting_participant_id,
            requesting_device_id,
            target_participant_id,
            target_device_id,
            talk_turn_epoch,
        } => vec![
            RuntimeSideEffect::WebSocketNotifyTalkTurnGranted {
                conversation_id: conversation_id.clone(),
                requesting_participant_id: requesting_participant_id.clone(),
                requesting_device_id: requesting_device_id.clone(),
                target_participant_id: target_participant_id.clone(),
                target_device_id: target_device_id.clone(),
                talk_turn_epoch: *talk_turn_epoch,
            },
            RuntimeSideEffect::DiagnosticEvent {
                conversation_id: conversation_id.clone(),
                event_kind: "talk-turn-granted".to_owned(),
                talk_turn_epoch: *talk_turn_epoch,
            },
        ],
        DeliveredPostCommitEffect::WakeTargetDevice {
            conversation_id,
            participant_id,
            device_id,
            talk_turn_epoch,
        } => vec![
            RuntimeSideEffect::ApnsWakeTargetDevice {
                conversation_id: conversation_id.clone(),
                participant_id: participant_id.clone(),
                device_id: device_id.clone(),
                talk_turn_epoch: *talk_turn_epoch,
            },
            RuntimeSideEffect::DiagnosticEvent {
                conversation_id: conversation_id.clone(),
                event_kind: "target-device-wake-requested".to_owned(),
                talk_turn_epoch: *talk_turn_epoch,
            },
        ],
        DeliveredPostCommitEffect::NotifyTalkTurnReleased {
            conversation_id,
            participant_id,
            device_id,
            talk_turn_epoch,
        } => vec![
            RuntimeSideEffect::WebSocketNotifyTalkTurnReleased {
                conversation_id: conversation_id.clone(),
                participant_id: participant_id.clone(),
                device_id: device_id.clone(),
                talk_turn_epoch: *talk_turn_epoch,
            },
            RuntimeSideEffect::DiagnosticEvent {
                conversation_id: conversation_id.clone(),
                event_kind: "talk-turn-released".to_owned(),
                talk_turn_epoch: *talk_turn_epoch,
            },
        ],
    }
}

pub fn plan_talk_turn_actor_event_side_effects(
    record: &TalkTurnActorEventRecord,
) -> Vec<RuntimeSideEffect> {
    let Some(talk_turn_epoch) = record.talk_turn_epoch else {
        return Vec::new();
    };
    let diagnostic = RuntimeSideEffect::DiagnosticEvent {
        conversation_id: record.conversation_id.clone(),
        event_kind: record.event_kind.clone(),
        talk_turn_epoch,
    };
    if record.event_kind == "talk-turn-renewed" {
        vec![
            RuntimeSideEffect::WebSocketNotifyTalkTurnRenewed {
                conversation_id: record.conversation_id.clone(),
                talk_turn_epoch,
            },
            diagnostic,
        ]
    } else {
        vec![diagnostic]
    }
}

pub fn plan_talk_turn_actor_release_side_effects(
    record: &TalkTurnActorEventRecord,
    released: &CurrentTalkTurnRow,
) -> Vec<RuntimeSideEffect> {
    if record.event_kind != "talk-turn-released" {
        return plan_talk_turn_actor_event_side_effects(record);
    }
    let Some(talk_turn_epoch) = record.talk_turn_epoch else {
        return Vec::new();
    };
    vec![
        RuntimeSideEffect::WebSocketNotifyTalkTurnReleased {
            conversation_id: record.conversation_id.clone(),
            participant_id: released.requesting_participant_id.clone(),
            device_id: released.requesting_device_id.clone(),
            talk_turn_epoch,
        },
        RuntimeSideEffect::DiagnosticEvent {
            conversation_id: record.conversation_id.clone(),
            event_kind: record.event_kind.clone(),
            talk_turn_epoch,
        },
    ]
}

pub fn talk_turn_actor_event_kind_text(kind: &DurableTalkTurnEventKind) -> &'static str {
    match kind {
        DurableTalkTurnEventKind::Granted => "talk-turn-granted",
        DurableTalkTurnEventKind::Renewed => "talk-turn-renewed",
        DurableTalkTurnEventKind::Released => "talk-turn-released",
        DurableTalkTurnEventKind::Expired => "talk-turn-expired",
        DurableTalkTurnEventKind::OwnerExpired => "talk-turn-owner-expired",
        DurableTalkTurnEventKind::RevokedByPolicy => "talk-turn-revoked-by-policy",
        DurableTalkTurnEventKind::DrainStarted => "talk-turn-drain-started",
    }
}

fn talk_turn_actor_event_json(
    conversation_id: &str,
    owner: &ConversationOwner,
    event: &DurableTalkTurnEvent,
) -> Value {
    let event_kind = talk_turn_actor_event_kind_text(&event.kind);
    let mut json = serde_json::json!({
        "kind": event_kind,
        "conversationId": { "value": conversation_id },
        "ownerRuntimeId": owner.runtime_id,
        "ownerEpoch": { "value": owner.owner_epoch },
        "actorEventId": { "value": event.event_id },
    });
    if let Some(talk_turn_epoch) = event.talk_turn_epoch {
        json["talkTurnEpoch"] = wrapped_u64(talk_turn_epoch);
    }
    if let Some(operation_id) = &event.operation_id {
        json["operationId"] = Value::String(operation_id.clone());
    }
    json
}

fn talk_turn_actor_event_record(
    event_row_id: u64,
    conversation_id: &str,
    owner: &ConversationOwner,
    event: &DurableTalkTurnEvent,
) -> TalkTurnActorEventRecord {
    TalkTurnActorEventRecord {
        event_row_id,
        conversation_id: conversation_id.to_owned(),
        owner_runtime_id: owner.runtime_id.clone(),
        owner_epoch: owner.owner_epoch,
        actor_event_id: event.event_id,
        event_kind: talk_turn_actor_event_kind_text(&event.kind).to_owned(),
        talk_turn_epoch: event.talk_turn_epoch,
        operation_id: event.operation_id.clone(),
        event_json: talk_turn_actor_event_json(conversation_id, owner, event),
    }
}

fn renumber_talk_turn_actor_events(
    events: &[DurableTalkTurnEvent],
    first_event_id: u64,
) -> Vec<DurableTalkTurnEvent> {
    events
        .iter()
        .enumerate()
        .map(|(index, event)| DurableTalkTurnEvent {
            event_id: first_event_id + index as u64,
            kind: event.kind.clone(),
            talk_turn_epoch: event.talk_turn_epoch,
            operation_id: event.operation_id.clone(),
        })
        .collect()
}

pub fn decode_post_commit_effect(
    row: &PostCommitOutboxRow,
) -> Result<DeliveredPostCommitEffect, DurablePostgresError> {
    let effect = &row.effect_json;
    let kind = required_string(effect, &["kind"], "postCommitEffect.kind")?;
    match kind {
        "notify-talk-turn-granted" => Ok(DeliveredPostCommitEffect::NotifyTalkTurnGranted {
            conversation_id: required_wrapped_string(
                effect,
                &["conversationId"],
                "conversationId",
            )?,
            requesting_participant_id: required_wrapped_string(
                effect,
                &["requestingParticipantId"],
                "requestingParticipantId",
            )?,
            requesting_device_id: required_wrapped_string(
                effect,
                &["requestingDeviceId"],
                "requestingDeviceId",
            )?,
            target_participant_id: required_wrapped_string(
                effect,
                &["targetParticipantId"],
                "targetParticipantId",
            )?,
            target_device_id: required_wrapped_string(
                effect,
                &["targetDeviceId"],
                "targetDeviceId",
            )?,
            talk_turn_epoch: required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?,
        }),
        "wake-target-device" => Ok(DeliveredPostCommitEffect::WakeTargetDevice {
            conversation_id: required_wrapped_string(
                effect,
                &["conversationId"],
                "conversationId",
            )?,
            participant_id: required_wrapped_string(effect, &["participantId"], "participantId")?,
            device_id: required_wrapped_string(effect, &["deviceId"], "deviceId")?,
            talk_turn_epoch: required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?,
        }),
        "notify-talk-turn-released" => Ok(DeliveredPostCommitEffect::NotifyTalkTurnReleased {
            conversation_id: required_wrapped_string(
                effect,
                &["conversationId"],
                "conversationId",
            )?,
            participant_id: required_wrapped_string(effect, &["participantId"], "participantId")?,
            device_id: required_wrapped_string(effect, &["deviceId"], "deviceId")?,
            talk_turn_epoch: required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?,
        }),
        other => Err(DurablePostgresError::UnsupportedPostCommitEffect(
            other.to_owned(),
        )),
    }
}

pub trait RequestTalkTurnSnapshotLoader {
    fn load_request_talk_turn_snapshot(
        &self,
        command: &Value,
    ) -> Result<RequestTalkTurnKernelInput, DurablePostgresError>;

    fn load_release_talk_turn_snapshot(
        &self,
        command: &Value,
    ) -> Result<RequestTalkTurnKernelInput, DurablePostgresError> {
        self.load_request_talk_turn_snapshot(command)
    }
}

pub trait RequestTalkTurnKernelWorker {
    fn decide_request_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError>;

    fn decide_release_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct KernelInvocationAudit {
    pub command_hash: String,
    pub snapshot_hash: String,
    pub policy_hash: String,
    pub request_hash: String,
    pub response_hash: Option<String>,
    pub decision_kind: Option<String>,
    pub elapsed_ms: u64,
    pub outcome: KernelInvocationOutcome,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum KernelInvocationOutcome {
    Success,
    WorkerFailed { status: String },
    HarnessError { kind: String },
    MalformedResponse,
    WorkerDeniedDecision,
}

pub struct RequestTalkTurnRuntime<S, W> {
    snapshot_loader: S,
    kernel_worker: W,
}

impl<S, W> RequestTalkTurnRuntime<S, W>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
{
    pub fn new(snapshot_loader: S, kernel_worker: W) -> Self {
        Self {
            snapshot_loader,
            kernel_worker,
        }
    }

    pub fn execute(
        &self,
        store: &mut DurableConversationStore,
        command: Value,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        if required_string(&command, &["kind"], "command.kind")? != "request-talk-turn" {
            return Err(DurablePostgresError::UnsupportedCommand {
                route: REQUEST_TALK_TURN_ROUTE,
                kind: KernelCommandKind::ReleaseTalkTurn,
            });
        }

        let input = self
            .snapshot_loader
            .load_request_talk_turn_snapshot(&command)?;
        let decision = self.kernel_worker.decide_request_talk_turn(&input)?;
        store.commit_kernel_decision_envelope(&decision, REQUEST_TALK_TURN_ROUTE)
    }
}

pub struct ReleaseTalkTurnRuntime<S, W> {
    snapshot_loader: S,
    kernel_worker: W,
}

impl<S, W> ReleaseTalkTurnRuntime<S, W>
where
    S: RequestTalkTurnSnapshotLoader,
    W: RequestTalkTurnKernelWorker,
{
    pub fn new(snapshot_loader: S, kernel_worker: W) -> Self {
        Self {
            snapshot_loader,
            kernel_worker,
        }
    }

    pub fn execute(
        &self,
        store: &mut DurableConversationStore,
        command: Value,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        if required_string(&command, &["kind"], "command.kind")? != "release-talk-turn" {
            return Err(DurablePostgresError::UnsupportedCommand {
                route: RELEASE_TALK_TURN_ROUTE,
                kind: KernelCommandKind::RequestTalkTurn,
            });
        }

        let input = self
            .snapshot_loader
            .load_release_talk_turn_snapshot(&command)?;
        let decision = self.kernel_worker.decide_release_talk_turn(&input)?;
        store.commit_kernel_decision_envelope(&decision, RELEASE_TALK_TURN_ROUTE)
    }
}

#[derive(Clone, Debug, Default)]
pub struct InMemoryRequestTalkTurnSnapshotLoader {
    inputs: Vec<RequestTalkTurnKernelInput>,
}

impl InMemoryRequestTalkTurnSnapshotLoader {
    pub fn from_cases<'a>(cases: impl IntoIterator<Item = &'a KernelCorpusCase>) -> Self {
        Self {
            inputs: cases
                .into_iter()
                .filter(|case| {
                    matches!(
                        case.kind,
                        KernelCommandKind::RequestTalkTurn | KernelCommandKind::ReleaseTalkTurn
                    )
                })
                .map(|case| RequestTalkTurnKernelInput {
                    command: case.command.clone(),
                    snapshot: case.snapshot.clone(),
                    policy: case.policy.clone(),
                })
                .collect(),
        }
    }
}

impl RequestTalkTurnSnapshotLoader for InMemoryRequestTalkTurnSnapshotLoader {
    fn load_request_talk_turn_snapshot(
        &self,
        command: &Value,
    ) -> Result<RequestTalkTurnKernelInput, DurablePostgresError> {
        self.inputs
            .iter()
            .find(|input| input.command == *command)
            .cloned()
            .ok_or(DurablePostgresError::SnapshotNotFound)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SnapshotPolicyConfig {
    pub max_talk_turn_lease_ms: u64,
    pub renew_window_ms: u64,
    pub presence_freshness_ms: u64,
    pub readiness_freshness_ms: u64,
    pub wake_freshness_ms: u64,
    pub wake_fallback_enabled: bool,
    pub require_current_session_for_ready_audio: bool,
}

impl Default for SnapshotPolicyConfig {
    fn default() -> Self {
        Self {
            max_talk_turn_lease_ms: 15_000,
            renew_window_ms: 3_000,
            presence_freshness_ms: 5_000,
            readiness_freshness_ms: 5_000,
            wake_freshness_ms: 60_000,
            wake_fallback_enabled: true,
            require_current_session_for_ready_audio: true,
        }
    }
}

pub struct PostgresRequestTalkTurnSnapshotLoader {
    client: Mutex<Client>,
    policy: SnapshotPolicyConfig,
    snapshot_built_at_ms: i64,
}

impl PostgresRequestTalkTurnSnapshotLoader {
    pub fn new(client: Client, policy: SnapshotPolicyConfig, snapshot_built_at_ms: i64) -> Self {
        Self {
            client: Mutex::new(client),
            policy,
            snapshot_built_at_ms,
        }
    }
}

impl RequestTalkTurnSnapshotLoader for PostgresRequestTalkTurnSnapshotLoader {
    fn load_request_talk_turn_snapshot(
        &self,
        command: &Value,
    ) -> Result<RequestTalkTurnKernelInput, DurablePostgresError> {
        let conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        let mut client = self
            .client
            .lock()
            .expect("Postgres snapshot loader lock should not be poisoned");
        let rows = client.query(REQUEST_TALK_TURN_SNAPSHOT_SQL, &[&conversation_id])?;
        build_request_talk_turn_input_from_snapshot_rows(
            command.clone(),
            self.snapshot_built_at_ms,
            &self.policy,
            rows.into_iter().map(SnapshotSqlRow::from).collect(),
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SnapshotSqlRow {
    conversation_id: String,
    conversation_seq: i64,
    policy_version: String,
    participant_id: String,
    device_id: Option<String>,
    session_epoch: Option<i64>,
    last_seen_ms: Option<i64>,
    presence_observed_at_ms: Option<i64>,
    readiness_session_epoch: Option<i64>,
    readiness_observed_at_ms: Option<i64>,
    wake_observed_at_ms: Option<i64>,
    current_requesting_participant_id: Option<String>,
    current_requesting_device_id: Option<String>,
    current_target_participant_id: Option<String>,
    current_target_device_id: Option<String>,
    talk_turn_epoch: Option<i64>,
    expires_at_ms: Option<i64>,
}

impl From<postgres::Row> for SnapshotSqlRow {
    fn from(row: postgres::Row) -> Self {
        Self {
            conversation_id: row.get("conversation_id"),
            conversation_seq: row.get("conversation_seq"),
            policy_version: row.get("policy_version"),
            participant_id: row.get("participant_id"),
            device_id: row.get("device_id"),
            session_epoch: row.get("session_epoch"),
            last_seen_ms: row.get("last_seen_ms"),
            presence_observed_at_ms: row.get("presence_observed_at_ms"),
            readiness_session_epoch: row.get("readiness_session_epoch"),
            readiness_observed_at_ms: row.get("readiness_observed_at_ms"),
            wake_observed_at_ms: row.get("wake_observed_at_ms"),
            current_requesting_participant_id: row.get("current_requesting_participant_id"),
            current_requesting_device_id: row.get("current_requesting_device_id"),
            current_target_participant_id: row.get("current_target_participant_id"),
            current_target_device_id: row.get("current_target_device_id"),
            talk_turn_epoch: row.get("talk_turn_epoch"),
            expires_at_ms: row.get("expires_at_ms"),
        }
    }
}

fn build_request_talk_turn_input_from_snapshot_rows(
    command: Value,
    snapshot_built_at_ms: i64,
    policy: &SnapshotPolicyConfig,
    rows: Vec<SnapshotSqlRow>,
) -> Result<RequestTalkTurnKernelInput, DurablePostgresError> {
    let first = rows.first().ok_or(DurablePostgresError::SnapshotNotFound)?;
    let conversation_id = first.conversation_id.clone();
    let mut participants = BTreeMap::<String, BTreeSet<String>>::new();
    let mut runtime_sessions = Vec::new();
    let mut device_presence = Vec::new();
    let mut readiness = Vec::new();
    let mut wake_targets = Vec::new();
    let mut current_talk_turn = serde_json::json!({ "kind": "none" });

    for row in &rows {
        if row.conversation_id != conversation_id {
            return Err(DurablePostgresError::MalformedTransactionEffect(
                "snapshot rows mixed conversations".to_owned(),
            ));
        }
        participants.entry(row.participant_id.clone()).or_default();
        if let Some(device_id) = &row.device_id {
            participants
                .entry(row.participant_id.clone())
                .or_default()
                .insert(device_id.clone());
            if let (Some(session_epoch), Some(last_seen_ms)) = (row.session_epoch, row.last_seen_ms)
            {
                runtime_sessions.push(serde_json::json!({
                    "participantId": wrapped_text(&row.participant_id),
                    "deviceId": wrapped_text(device_id),
                    "sessionEpoch": wrapped_u64(i64_to_u64("session_epoch", session_epoch)?),
                    "lastSeenMs": i64_to_u64("last_seen_ms", last_seen_ms)?,
                }));
            }
            if let Some(observed_at_ms) = row.presence_observed_at_ms {
                device_presence.push(serde_json::json!({
                    "kind": "present",
                    "participantId": wrapped_text(&row.participant_id),
                    "deviceId": wrapped_text(device_id),
                    "observedAtMs": i64_to_u64("presence_observed_at_ms", observed_at_ms)?,
                }));
            }
            if let (Some(session_epoch), Some(observed_at_ms)) =
                (row.readiness_session_epoch, row.readiness_observed_at_ms)
            {
                readiness.push(serde_json::json!({
                    "kind": "foreground-audio-ready",
                    "participantId": wrapped_text(&row.participant_id),
                    "deviceId": wrapped_text(device_id),
                    "sessionEpoch": wrapped_u64(i64_to_u64("readiness_session_epoch", session_epoch)?),
                    "observedAtMs": i64_to_u64("readiness_observed_at_ms", observed_at_ms)?,
                }));
            }
            if let Some(observed_at_ms) = row.wake_observed_at_ms {
                wake_targets.push(serde_json::json!({
                    "participantId": wrapped_text(&row.participant_id),
                    "deviceId": wrapped_text(device_id),
                    "observedAtMs": i64_to_u64("wake_observed_at_ms", observed_at_ms)?,
                }));
            }
        }
        if let (
            Some(requesting_participant_id),
            Some(requesting_device_id),
            Some(target_participant_id),
            Some(target_device_id),
            Some(talk_turn_epoch),
            Some(expires_at_ms),
        ) = (
            &row.current_requesting_participant_id,
            &row.current_requesting_device_id,
            &row.current_target_participant_id,
            &row.current_target_device_id,
            row.talk_turn_epoch,
            row.expires_at_ms,
        ) {
            current_talk_turn = serde_json::json!({
                "kind": "current",
                "speakerParticipantId": wrapped_text(requesting_participant_id),
                "speakerDeviceId": wrapped_text(requesting_device_id),
                "targetParticipantId": wrapped_text(target_participant_id),
                "targetDeviceId": wrapped_text(target_device_id),
                "talkTurnEpoch": wrapped_u64(i64_to_u64("talk_turn_epoch", talk_turn_epoch)?),
                "expiresAtMs": i64_to_u64("expires_at_ms", expires_at_ms)?,
            });
        }
    }

    let participants = participants
        .into_iter()
        .map(|(participant_id, devices)| {
            serde_json::json!({
                "participantId": wrapped_text(&participant_id),
                "devices": devices.into_iter().map(|device_id| wrapped_text(&device_id)).collect::<Vec<_>>(),
            })
        })
        .collect::<Vec<_>>();
    let snapshot = serde_json::json!({
        "conversationId": wrapped_text(&conversation_id),
        "participants": participants,
        "runtimeSessions": runtime_sessions,
        "devicePresence": device_presence,
        "targetDeviceAudioReadiness": readiness,
        "wakeTargets": wake_targets,
        "currentTalkTurn": current_talk_turn,
        "conversationSeq": wrapped_u64(i64_to_u64("conversation_seq", first.conversation_seq)?),
        "snapshotBuiltAtMs": i64_to_u64("snapshot_built_at_ms", snapshot_built_at_ms)?,
    });
    let policy = serde_json::json!({
        "policyVersion": wrapped_text(&first.policy_version),
        "maxTalkTurnLeaseMs": policy.max_talk_turn_lease_ms,
        "renewWindowMs": policy.renew_window_ms,
        "presenceFreshnessMs": policy.presence_freshness_ms,
        "readinessFreshnessMs": policy.readiness_freshness_ms,
        "wakeFreshnessMs": policy.wake_freshness_ms,
        "wakeFallbackEnabled": policy.wake_fallback_enabled,
        "requireCurrentSessionForReadyAudio": policy.require_current_session_for_ready_audio,
    });

    Ok(RequestTalkTurnKernelInput {
        command,
        snapshot,
        policy,
    })
}

fn wrapped_text(value: &str) -> Value {
    serde_json::json!({ "value": value })
}

fn wrapped_u64(value: u64) -> Value {
    serde_json::json!({ "value": value })
}

fn i64_to_u64(field: &'static str, value: i64) -> Result<u64, DurablePostgresError> {
    value
        .try_into()
        .map_err(|_| DurablePostgresError::NegativeSnapshotValue { field, value })
}

fn u64_to_i64(field: &'static str, value: u64) -> Result<i64, DurablePostgresError> {
    value.try_into().map_err(|_| {
        DurablePostgresError::MalformedTransactionEffect(format!("{field} exceeded i64"))
    })
}

fn current_talk_turn_row_from_sql(
    row: postgres::Row,
) -> Result<CurrentTalkTurnRow, DurablePostgresError> {
    let talk_turn_epoch: i64 = row.get("talk_turn_epoch");
    Ok(CurrentTalkTurnRow {
        conversation_id: row.get("conversation_id"),
        requesting_participant_id: row.get("requesting_participant_id"),
        requesting_device_id: row.get("requesting_device_id"),
        target_participant_id: row.get("target_participant_id"),
        target_device_id: row.get("target_device_id"),
        talk_turn_epoch: i64_to_u64("talk_turn_epoch", talk_turn_epoch)?,
        expires_at_ms: row.get("expires_at_ms"),
    })
}

fn current_talk_turn_row_json(row: &CurrentTalkTurnRow) -> Value {
    serde_json::json!({
        "conversationId": row.conversation_id,
        "requestingParticipantId": row.requesting_participant_id,
        "requestingDeviceId": row.requesting_device_id,
        "targetParticipantId": row.target_participant_id,
        "targetDeviceId": row.target_device_id,
        "talkTurnEpoch": row.talk_turn_epoch,
        "expiresAtMs": row.expires_at_ms,
    })
}

fn align_talk_turn_epoch(effect: &mut Value, conversation_id: &str, talk_turn_epoch: u64) {
    let Some(effect_conversation_id) = optional_wrapped_string(effect, &["conversationId"]) else {
        return;
    };
    if effect_conversation_id == conversation_id && path_value(effect, &["talkTurnEpoch"]).is_some()
    {
        effect["talkTurnEpoch"] = wrapped_u64(talk_turn_epoch);
    }
}

fn align_post_commit_effects(
    effects: &mut [Value],
    current_talk_turn: Option<&CurrentTalkTurnRow>,
) {
    let Some(current_talk_turn) = current_talk_turn else {
        return;
    };
    for effect in effects {
        align_talk_turn_epoch(
            effect,
            &current_talk_turn.conversation_id,
            current_talk_turn.talk_turn_epoch,
        );
    }
}

fn current_talk_turn_row_from_json(
    value: &Value,
) -> Result<CurrentTalkTurnRow, DurablePostgresError> {
    Ok(CurrentTalkTurnRow {
        conversation_id: required_string(value, &["conversationId"], "conversationId")?.to_owned(),
        requesting_participant_id: required_string(
            value,
            &["requestingParticipantId"],
            "requestingParticipantId",
        )?
        .to_owned(),
        requesting_device_id: required_string(
            value,
            &["requestingDeviceId"],
            "requestingDeviceId",
        )?
        .to_owned(),
        target_participant_id: required_string(
            value,
            &["targetParticipantId"],
            "targetParticipantId",
        )?
        .to_owned(),
        target_device_id: required_string(value, &["targetDeviceId"], "targetDeviceId")?.to_owned(),
        talk_turn_epoch: required_u64(value, &["talkTurnEpoch"], "talkTurnEpoch")?,
        expires_at_ms: required_i64(value, &["expiresAtMs"], "expiresAtMs")?,
    })
}

fn validate_renew_talk_turn_command(command: &Value) -> Result<(), DurablePostgresError> {
    let kind = required_string(command, &["kind"], "command.kind")?;
    if kind == "renew-talk-turn" {
        Ok(())
    } else {
        Err(DurablePostgresError::UnsupportedCommand {
            route: RENEW_TALK_TURN_ROUTE,
            kind: KernelCommandKind::RequestTalkTurn,
        })
    }
}

fn actor_policy_from_command(command: &Value) -> Result<ActorPolicySnapshot, DurablePostgresError> {
    Ok(ActorPolicySnapshot {
        policy_version: optional_wrapped_string(command, &["policyVersion"])
            .unwrap_or_else(|| "policy-v1".to_owned()),
        max_talk_turn_lease_ms: path_value(command, &["maxTalkTurnLeaseMs"])
            .and_then(Value::as_i64)
            .unwrap_or(15_000),
        grants_enabled: path_value(command, &["grantsEnabled"])
            .and_then(Value::as_bool)
            .unwrap_or(true),
    })
}

fn actor_owner_from_command(command: &Value) -> Result<ConversationOwner, DurablePostgresError> {
    Ok(ConversationOwner {
        runtime_id: path_value(command, &["ownerRuntimeId"])
            .and_then(Value::as_str)
            .unwrap_or("runtime-single")
            .to_owned(),
        owner_epoch: optional_wrapped_u64(command, &["ownerEpoch"]).unwrap_or(1),
        lease_expires_at_ms: path_value(command, &["ownerLeaseExpiresAtMs"])
            .and_then(Value::as_i64)
            .unwrap_or(i64::MAX / 4),
    })
}

fn actor_renewal_from_command(
    command: &Value,
    current: &CurrentTalkTurnRow,
    policy: &ActorPolicySnapshot,
) -> Result<TalkTurnRenewal, DurablePostgresError> {
    let talk_turn_epoch = optional_wrapped_u64(command, &["talkTurnEpoch"])
        .or_else(|| {
            path_value(command, &["transmitId"])
                .and_then(Value::as_str)
                .and_then(|value| value.parse::<u64>().ok())
        })
        .unwrap_or(current.talk_turn_epoch);
    let now_ms = path_value(command, &["nowMs"])
        .and_then(Value::as_i64)
        .unwrap_or_else(|| current.expires_at_ms - policy.max_talk_turn_lease_ms + 10_000);
    Ok(TalkTurnRenewal {
        operation_id: path_value(command, &["operationId"])
            .and_then(Value::as_str)
            .unwrap_or("renew-transmit")
            .to_owned(),
        talk_turn_epoch,
        now_ms,
    })
}

fn validate_renewal_participant_device(
    command: &Value,
    current: &CurrentTalkTurnRow,
) -> Result<(), DurablePostgresError> {
    let participant_id = optional_wrapped_string(command, &["participantId"]);
    let device_id = path_value(command, &["deviceId"])
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| optional_wrapped_string(command, &["deviceId"]));
    let Some(device_id) = device_id else {
        return Ok(());
    };
    let participant_matches = participant_id
        .as_ref()
        .is_none_or(|participant_id| participant_id == &current.requesting_participant_id);
    if !participant_matches || device_id != current.requesting_device_id {
        return Err(DurablePostgresError::TalkTurnRenewalRejected(
            "renewing participant/device does not own the current Talk Turn".to_owned(),
        ));
    }
    Ok(())
}

fn actor_release_from_command(command: &Value, current: &CurrentTalkTurnRow) -> TalkTurnRenewal {
    let talk_turn_epoch = optional_wrapped_u64(command, &["talkTurnEpoch"])
        .or_else(|| {
            path_value(command, &["transmitId"])
                .and_then(Value::as_str)
                .and_then(|value| value.parse::<u64>().ok())
        })
        .unwrap_or(current.talk_turn_epoch);
    TalkTurnRenewal {
        operation_id: path_value(command, &["operationId"])
            .and_then(Value::as_str)
            .unwrap_or("end-transmit")
            .to_owned(),
        talk_turn_epoch,
        now_ms: 0,
    }
}

fn validate_release_participant_device(
    command: &Value,
    current: &CurrentTalkTurnRow,
) -> Result<(), DurablePostgresError> {
    let participant_id = optional_wrapped_string(command, &["participantId"]);
    let device_id = path_value(command, &["deviceId"])
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| optional_wrapped_string(command, &["deviceId"]));
    let Some(device_id) = device_id else {
        return Err(DurablePostgresError::TalkTurnRenewalRejected(
            "releasing device is required".to_owned(),
        ));
    };
    let participant_matches = participant_id
        .as_ref()
        .is_none_or(|participant_id| participant_id == &current.requesting_participant_id);
    if !participant_matches || device_id != current.requesting_device_id {
        return Err(DurablePostgresError::TalkTurnRenewalRejected(
            "releasing participant/device does not own the current Talk Turn".to_owned(),
        ));
    }
    Ok(())
}

fn renew_actor_from_current(
    conversation_id: &str,
    owner: &ConversationOwner,
    policy: &ActorPolicySnapshot,
    current: &CurrentTalkTurnRow,
    renewal: TalkTurnRenewal,
) -> Result<(CurrentTalkTurnRow, Vec<DurableTalkTurnEvent>), DurablePostgresError> {
    let active = ActiveTalkTurn {
        talk_turn_epoch: current.talk_turn_epoch,
        requesting_participant_id: current.requesting_participant_id.clone(),
        requesting_device_id: current.requesting_device_id.clone(),
        target_participant_id: current.target_participant_id.clone(),
        target_device_id: current.target_device_id.clone(),
        expires_at_ms: current.expires_at_ms,
        policy_version: policy.policy_version.clone(),
    };
    let mut actor = TalkTurnActor::restore(
        conversation_id,
        owner.clone(),
        Some(active),
        current.talk_turn_epoch + 1,
        false,
    );
    let grant = actor
        .renew_talk_turn(policy, renewal)
        .map_err(|error| DurablePostgresError::TalkTurnRenewalRejected(error.to_string()))?;
    let mut renewed = current.clone();
    renewed.expires_at_ms = grant.expires_at_ms;
    Ok((renewed, actor.events().to_vec()))
}

fn release_actor_from_current(
    conversation_id: &str,
    owner: &ConversationOwner,
    current: &CurrentTalkTurnRow,
    release: TalkTurnRenewal,
) -> Result<Vec<DurableTalkTurnEvent>, DurablePostgresError> {
    let active = ActiveTalkTurn {
        talk_turn_epoch: current.talk_turn_epoch,
        requesting_participant_id: current.requesting_participant_id.clone(),
        requesting_device_id: current.requesting_device_id.clone(),
        target_participant_id: current.target_participant_id.clone(),
        target_device_id: current.target_device_id.clone(),
        expires_at_ms: current.expires_at_ms,
        policy_version: "policy-v1".to_owned(),
    };
    let mut actor = TalkTurnActor::restore(
        conversation_id,
        owner.clone(),
        Some(active),
        current.talk_turn_epoch + 1,
        false,
    );
    actor
        .release_talk_turn(release.talk_turn_epoch, release.operation_id)
        .map_err(|error| DurablePostgresError::TalkTurnRenewalRejected(error.to_string()))?;
    Ok(actor.events().to_vec())
}

#[derive(Clone, Debug)]
pub struct CorpusKernelDecisionWorker {
    request_cases: Vec<KernelCorpusCase>,
    release_cases: Vec<KernelCorpusCase>,
}

impl CorpusKernelDecisionWorker {
    pub fn new(corpus: &KernelCorpus) -> Self {
        Self {
            request_cases: corpus
                .cases
                .iter()
                .filter(|case| case.kind == KernelCommandKind::RequestTalkTurn)
                .cloned()
                .collect(),
            release_cases: corpus
                .cases
                .iter()
                .filter(|case| case.kind == KernelCommandKind::ReleaseTalkTurn)
                .cloned()
                .collect(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProcessRequestTalkTurnKernelWorker {
    repo_root: PathBuf,
    deadline: Duration,
    audits: Arc<Mutex<Vec<KernelInvocationAudit>>>,
    command_config: KernelProcessCommandConfig,
}

impl ProcessRequestTalkTurnKernelWorker {
    pub fn new(repo_root: impl Into<PathBuf>, deadline: Duration) -> Self {
        Self {
            repo_root: repo_root.into(),
            deadline,
            audits: Arc::new(Mutex::new(Vec::new())),
            command_config: KernelProcessCommandConfig::from_env(),
        }
    }

    pub fn invocation_audits(&self) -> Vec<KernelInvocationAudit> {
        self.audits
            .lock()
            .expect("kernel invocation audit lock should not be poisoned")
            .clone()
    }

    fn record_audit(&self, audit: KernelInvocationAudit) {
        self.audits
            .lock()
            .expect("kernel invocation audit lock should not be poisoned")
            .push(audit);
    }
}

#[derive(Clone, Debug)]
pub enum LiveRequestTalkTurnKernelWorker {
    PerCommand(ProcessRequestTalkTurnKernelWorker),
    Resident(ResidentRequestTalkTurnKernelWorker),
}

impl LiveRequestTalkTurnKernelWorker {
    pub fn from_env(repo_root: impl Into<PathBuf>, deadline: Duration) -> Self {
        let repo_root = repo_root.into();
        match std::env::var("TURBO_KERNEL_WORKER_MODE")
            .unwrap_or_else(|_| "per-command".to_owned())
            .as_str()
        {
            "resident" | "live" | "long-lived" => Self::Resident(
                ResidentRequestTalkTurnKernelWorker::new(repo_root, deadline),
            ),
            _ => Self::PerCommand(ProcessRequestTalkTurnKernelWorker::new(repo_root, deadline)),
        }
    }

    pub fn invocation_audits(&self) -> Vec<KernelInvocationAudit> {
        match self {
            Self::PerCommand(worker) => worker.invocation_audits(),
            Self::Resident(worker) => worker.invocation_audits(),
        }
    }
}

impl RequestTalkTurnKernelWorker for LiveRequestTalkTurnKernelWorker {
    fn decide_request_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        match self {
            Self::PerCommand(worker) => worker.decide_request_talk_turn(input),
            Self::Resident(worker) => worker.decide_request_talk_turn(input),
        }
    }

    fn decide_release_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        match self {
            Self::PerCommand(worker) => worker.decide_release_talk_turn(input),
            Self::Resident(worker) => worker.decide_release_talk_turn(input),
        }
    }
}

#[derive(Clone)]
pub struct ResidentRequestTalkTurnKernelWorker {
    repo_root: PathBuf,
    deadline: Duration,
    audits: Arc<Mutex<Vec<KernelInvocationAudit>>>,
    command_config: KernelProcessCommandConfig,
    state: Arc<Mutex<Option<ResidentKernelWorkerState>>>,
    next_request_id: Arc<AtomicU64>,
}

impl std::fmt::Debug for ResidentRequestTalkTurnKernelWorker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ResidentRequestTalkTurnKernelWorker")
            .field("repo_root", &self.repo_root)
            .field("deadline", &self.deadline)
            .field("command_config", &self.command_config)
            .finish_non_exhaustive()
    }
}

impl ResidentRequestTalkTurnKernelWorker {
    pub fn new(repo_root: impl Into<PathBuf>, deadline: Duration) -> Self {
        Self::with_command_config(repo_root, deadline, KernelProcessCommandConfig::from_env())
    }

    fn with_command_config(
        repo_root: impl Into<PathBuf>,
        deadline: Duration,
        command_config: KernelProcessCommandConfig,
    ) -> Self {
        Self {
            repo_root: repo_root.into(),
            deadline,
            audits: Arc::new(Mutex::new(Vec::new())),
            command_config,
            state: Arc::new(Mutex::new(None)),
            next_request_id: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn invocation_audits(&self) -> Vec<KernelInvocationAudit> {
        self.audits
            .lock()
            .expect("kernel invocation audit lock should not be poisoned")
            .clone()
    }

    fn record_audit(&self, audit: KernelInvocationAudit) {
        self.audits
            .lock()
            .expect("kernel invocation audit lock should not be poisoned")
            .push(audit);
    }
}

impl RequestTalkTurnKernelWorker for ResidentRequestTalkTurnKernelWorker {
    fn decide_request_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.decide_with_resident_worker(
            input,
            "request-talk-turn",
            "unison-resident-request-talk-turn-worker",
        )
    }

    fn decide_release_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.decide_with_resident_worker(
            input,
            "release-talk-turn",
            "unison-resident-release-talk-turn-worker",
        )
    }
}

impl ResidentRequestTalkTurnKernelWorker {
    fn decide_with_resident_worker(
        &self,
        input: &RequestTalkTurnKernelInput,
        command_kind: &str,
        case_id: &str,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        let input_value = serde_json::json!({
            "command": input.command,
            "snapshot": input.snapshot,
            "policy": input.policy,
        });
        let input_text = serde_json::to_string(&input_value)
            .map_err(DurablePostgresError::MalformedKernelDecision)?;
        let command_hash = json_hash(&input.command)?;
        let snapshot_hash = json_hash(&input.snapshot)?;
        let policy_hash = json_hash(&input.policy)?;
        let request_hash = sha256_hex(input_text.as_bytes());
        let request_id = format!(
            "kernel-request-{}",
            self.next_request_id.fetch_add(1, Ordering::Relaxed)
        );
        let worker_request = serde_json::json!({
            "requestId": request_id,
            "commandKind": command_kind,
            "input": input_value,
        });
        let worker_request_text = serde_json::to_string(&worker_request)
            .map_err(DurablePostgresError::MalformedKernelDecision)?;
        let started_at = Instant::now();
        let response_text = match self.request_resident_response(&worker_request_text) {
            Ok(response_text) => response_text,
            Err(error) => {
                self.record_audit(kernel_invocation_audit(
                    command_hash,
                    snapshot_hash,
                    policy_hash,
                    request_hash,
                    None,
                    None,
                    started_at.elapsed(),
                    KernelInvocationOutcome::HarnessError {
                        kind: kernel_harness_error_kind(&error).to_owned(),
                    },
                ));
                return Err(DurablePostgresError::KernelWorker(error));
            }
        };
        let response_hash = sha256_hex(response_text.as_bytes());
        let response: Value = match serde_json::from_str(response_text.trim()) {
            Ok(response) => response,
            Err(error) => {
                self.record_audit(kernel_invocation_audit(
                    command_hash,
                    snapshot_hash,
                    policy_hash,
                    request_hash,
                    Some(response_hash),
                    None,
                    started_at.elapsed(),
                    KernelInvocationOutcome::MalformedResponse,
                ));
                return Err(DurablePostgresError::MalformedKernelDecision(error));
            }
        };
        if response
            .get("requestId")
            .and_then(Value::as_str)
            .filter(|observed| *observed == request_id)
            .is_none()
        {
            let observed = response
                .get("requestId")
                .and_then(Value::as_str)
                .unwrap_or("<missing>");
            let error = KernelHarnessError::ProtocolError(format!(
                "resident response requestId mismatch: expected `{request_id}`, observed `{observed}`"
            ));
            self.record_audit(kernel_invocation_audit(
                command_hash,
                snapshot_hash,
                policy_hash,
                request_hash,
                Some(response_hash),
                None,
                started_at.elapsed(),
                KernelInvocationOutcome::HarnessError {
                    kind: kernel_harness_error_kind(&error).to_owned(),
                },
            ));
            return Err(DurablePostgresError::KernelWorker(error));
        }
        let decision = match response.get("decision") {
            Some(decision) => decision.clone(),
            None => {
                let error =
                    KernelHarnessError::ProtocolError("resident response missing decision".into());
                self.record_audit(kernel_invocation_audit(
                    command_hash,
                    snapshot_hash,
                    policy_hash,
                    request_hash,
                    Some(response_hash),
                    None,
                    started_at.elapsed(),
                    KernelInvocationOutcome::HarnessError {
                        kind: kernel_harness_error_kind(&error).to_owned(),
                    },
                ));
                return Err(DurablePostgresError::KernelWorker(error));
            }
        };
        let decision_kind = decision
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if decision["kind"] == "worker-error" {
            self.record_audit(kernel_invocation_audit(
                command_hash,
                snapshot_hash,
                policy_hash,
                request_hash,
                Some(response_hash),
                decision_kind,
                started_at.elapsed(),
                KernelInvocationOutcome::WorkerDeniedDecision,
            ));
            return Err(DurablePostgresError::KernelDecisionNotFound);
        }
        self.record_audit(kernel_invocation_audit(
            command_hash,
            snapshot_hash,
            policy_hash,
            request_hash,
            Some(response_hash),
            decision_kind,
            started_at.elapsed(),
            KernelInvocationOutcome::Success,
        ));
        Ok(KernelDecisionEnvelope {
            case_id: case_id.to_owned(),
            command: input.command.clone(),
            snapshot: input.snapshot.clone(),
            decision,
        })
    }

    fn request_resident_response(&self, request_text: &str) -> Result<String, KernelHarnessError> {
        let mut state_guard = self
            .state
            .lock()
            .expect("resident kernel worker lock should not be poisoned");
        if state_guard.is_none() {
            *state_guard = Some(self.start_resident_worker()?);
        }
        let state = state_guard
            .as_mut()
            .expect("resident worker state should have started");
        if let Err(error) =
            writeln!(state.stdin, "{request_text}").and_then(|_| state.stdin.flush())
        {
            *state_guard = None;
            return Err(KernelHarnessError::OutputFailed(error));
        }
        let response_deadline = Instant::now() + self.deadline;
        loop {
            let remaining = response_deadline
                .checked_duration_since(Instant::now())
                .unwrap_or(Duration::ZERO);
            if remaining.is_zero() {
                *state_guard = None;
                return Err(KernelHarnessError::DeadlineExceeded(self.deadline));
            }
            match state.stdout_rx.recv_timeout(remaining) {
                Ok(Ok(line)) => {
                    let trimmed = line.trim();
                    if trimmed.starts_with('{') {
                        return Ok(trimmed.to_owned());
                    }
                }
                Ok(Err(error)) => {
                    *state_guard = None;
                    return Err(KernelHarnessError::OutputFailed(error));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    *state_guard = None;
                    return Err(KernelHarnessError::DeadlineExceeded(self.deadline));
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    *state_guard = None;
                    return Err(KernelHarnessError::WorkerFailed {
                        status: "resident-worker-exited".to_owned(),
                        stderr: String::new(),
                    });
                }
            }
        }
    }

    fn start_resident_worker(&self) -> Result<ResidentKernelWorkerState, KernelHarnessError> {
        let mut command = self.command_config.command();
        self.command_config.append_resident_args(
            &mut command,
            "bb/main:.beepbeep.worker.resident.printDecisionJson",
            "resident-kernel-worker",
        );
        let (stdout_master, stdout_slave) =
            open_pty_pair().map_err(KernelHarnessError::StartFailed)?;
        command
            .current_dir(&self.repo_root)
            .stdin(Stdio::piped())
            .stdout(Stdio::from(stdout_slave))
            .stderr(Stdio::null());
        let mut child = command.spawn().map_err(KernelHarnessError::StartFailed)?;
        let stdin = child.stdin.take().ok_or_else(|| {
            KernelHarnessError::ProtocolError("resident worker stdin was unavailable".to_owned())
        })?;
        Ok(ResidentKernelWorkerState {
            child,
            stdin,
            stdout_rx: spawn_resident_stdout_reader(stdout_master),
        })
    }
}

struct ResidentKernelWorkerState {
    child: Child,
    stdin: ChildStdin,
    stdout_rx: mpsc::Receiver<Result<String, std::io::Error>>,
}

impl Drop for ResidentKernelWorkerState {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_resident_stdout_reader(stdout: File) -> mpsc::Receiver<Result<String, std::io::Error>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if tx.send(Ok(line)).is_err() {
                        break;
                    }
                }
                Err(error) => {
                    let _ = tx.send(Err(error));
                    break;
                }
            }
        }
    });
    rx
}

fn open_pty_pair() -> std::io::Result<(File, File)> {
    let mut master_fd = -1;
    let mut slave_fd = -1;
    let result = unsafe {
        libc::openpty(
            &mut master_fd,
            &mut slave_fd,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if result == -1 {
        return Err(std::io::Error::last_os_error());
    }
    let master = unsafe { File::from_raw_fd(master_fd) };
    let slave = unsafe { File::from_raw_fd(slave_fd) };
    Ok((master, slave))
}

impl RequestTalkTurnKernelWorker for ProcessRequestTalkTurnKernelWorker {
    fn decide_request_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.decide_with_unison_entrypoint(
            input,
            "bb/main:.beepbeep.worker.requestTalkTurn.printDecisionJson",
            "request-talk-turn",
            "unison-request-talk-turn-worker",
        )
    }

    fn decide_release_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.decide_with_unison_entrypoint(
            input,
            "bb/main:.beepbeep.worker.releaseTalkTurn.printDecisionJson",
            "release-talk-turn",
            "unison-release-talk-turn-worker",
        )
    }
}

impl ProcessRequestTalkTurnKernelWorker {
    fn decide_with_unison_entrypoint(
        &self,
        input: &RequestTalkTurnKernelInput,
        entrypoint: &str,
        compiled_artifact_name: &str,
        case_id: &str,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        let input_value = serde_json::json!({
            "command": input.command,
            "snapshot": input.snapshot,
            "policy": input.policy,
        });
        let input_text = serde_json::to_string(&input_value)
            .map_err(DurablePostgresError::MalformedKernelDecision)?;
        let command_hash = json_hash(&input.command)?;
        let snapshot_hash = json_hash(&input.snapshot)?;
        let policy_hash = json_hash(&input.policy)?;
        let request_hash = sha256_hex(input_text.as_bytes());
        let mut command = self.command_config.command();
        self.command_config.append_run_args(
            &mut command,
            entrypoint,
            compiled_artifact_name,
            &input_text,
        );
        command
            .current_dir(&self.repo_root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let started_at = Instant::now();
        let output = match run_kernel_command_with_deadline(command, self.deadline) {
            Ok(output) => output,
            Err(error) => {
                self.record_audit(kernel_invocation_audit(
                    command_hash,
                    snapshot_hash,
                    policy_hash,
                    request_hash,
                    None,
                    None,
                    started_at.elapsed(),
                    KernelInvocationOutcome::HarnessError {
                        kind: kernel_harness_error_kind(&error).to_owned(),
                    },
                ));
                return Err(DurablePostgresError::KernelWorker(error));
            }
        };
        let response_hash = sha256_hex(output.stdout.as_slice());
        if !output.status.success() {
            let status = output
                .status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "signal".to_owned());
            self.record_audit(kernel_invocation_audit(
                command_hash,
                snapshot_hash,
                policy_hash,
                request_hash,
                Some(response_hash),
                None,
                started_at.elapsed(),
                KernelInvocationOutcome::WorkerFailed {
                    status: status.clone(),
                },
            ));
            return Err(DurablePostgresError::KernelWorker(
                KernelHarnessError::WorkerFailed {
                    status,
                    stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
                },
            ));
        }
        let decision: Value = match serde_json::from_slice(output.stdout.as_slice()) {
            Ok(decision) => decision,
            Err(error) => {
                self.record_audit(kernel_invocation_audit(
                    command_hash,
                    snapshot_hash,
                    policy_hash,
                    request_hash,
                    Some(response_hash),
                    None,
                    started_at.elapsed(),
                    KernelInvocationOutcome::MalformedResponse,
                ));
                return Err(DurablePostgresError::MalformedKernelDecision(error));
            }
        };
        let decision_kind = decision
            .get("kind")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if decision["kind"] == "worker-error" {
            self.record_audit(kernel_invocation_audit(
                command_hash,
                snapshot_hash,
                policy_hash,
                request_hash,
                Some(response_hash),
                decision_kind,
                started_at.elapsed(),
                KernelInvocationOutcome::WorkerDeniedDecision,
            ));
            return Err(DurablePostgresError::KernelDecisionNotFound);
        }
        self.record_audit(kernel_invocation_audit(
            command_hash,
            snapshot_hash,
            policy_hash,
            request_hash,
            Some(response_hash),
            decision_kind,
            started_at.elapsed(),
            KernelInvocationOutcome::Success,
        ));
        Ok(KernelDecisionEnvelope {
            case_id: case_id.to_owned(),
            command: input.command.clone(),
            snapshot: input.snapshot.clone(),
            decision,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct KernelProcessCommandConfig {
    use_direnv: bool,
    ucm_command: String,
    run_mode: KernelProcessRunMode,
}

impl KernelProcessCommandConfig {
    fn from_env() -> Self {
        let use_direnv = std::env::var("TURBO_KERNEL_USE_DIRENV")
            .map(|value| !matches!(value.as_str(), "0" | "false" | "FALSE" | "no" | "NO"))
            .unwrap_or(true);
        let ucm_command = std::env::var("TURBO_KERNEL_UCM")
            .ok()
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| "ucm".to_owned());
        let run_mode = match std::env::var("TURBO_KERNEL_RUN_MODE")
            .unwrap_or_else(|_| "source".to_owned())
            .as_str()
        {
            "compiled" | "run.compiled" => KernelProcessRunMode::Compiled {
                artifact_dir: std::env::var("TURBO_KERNEL_COMPILED_DIR")
                    .ok()
                    .filter(|value| !value.is_empty())
                    .map(PathBuf::from)
                    .unwrap_or_else(|| PathBuf::from("backend/infra/vm/build/kernel")),
            },
            _ => KernelProcessRunMode::Source,
        };
        Self {
            use_direnv,
            ucm_command,
            run_mode,
        }
    }

    fn command(&self) -> Command {
        if self.use_direnv {
            Command::new("direnv")
        } else {
            Command::new(&self.ucm_command)
        }
    }

    fn append_run_args(
        &self,
        command: &mut Command,
        entrypoint: &str,
        compiled_artifact_name: &str,
        input_text: &str,
    ) {
        if self.use_direnv {
            command.arg("exec").arg(".").arg(&self.ucm_command);
        }
        match &self.run_mode {
            KernelProcessRunMode::Source => {
                command.arg("run").arg(entrypoint).arg(input_text);
            }
            KernelProcessRunMode::Compiled { artifact_dir } => {
                command
                    .arg("run.compiled")
                    .arg(artifact_dir.join(format!("{compiled_artifact_name}.uc")))
                    .arg(input_text);
            }
        }
    }

    fn append_resident_args(
        &self,
        command: &mut Command,
        entrypoint: &str,
        compiled_artifact_name: &str,
    ) {
        if self.use_direnv {
            command.arg("exec").arg(".").arg(&self.ucm_command);
        }
        match &self.run_mode {
            KernelProcessRunMode::Source => {
                command.arg("run").arg(entrypoint);
            }
            KernelProcessRunMode::Compiled { artifact_dir } => {
                command
                    .arg("run.compiled")
                    .arg(artifact_dir.join(format!("{compiled_artifact_name}.uc")));
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum KernelProcessRunMode {
    Source,
    Compiled { artifact_dir: PathBuf },
}

fn kernel_invocation_audit(
    command_hash: String,
    snapshot_hash: String,
    policy_hash: String,
    request_hash: String,
    response_hash: Option<String>,
    decision_kind: Option<String>,
    elapsed: Duration,
    outcome: KernelInvocationOutcome,
) -> KernelInvocationAudit {
    KernelInvocationAudit {
        command_hash,
        snapshot_hash,
        policy_hash,
        request_hash,
        response_hash,
        decision_kind,
        elapsed_ms: elapsed.as_millis().try_into().unwrap_or(u64::MAX),
        outcome,
    }
}

fn kernel_harness_error_kind(error: &KernelHarnessError) -> &'static str {
    match error {
        KernelHarnessError::DeadlineExceeded(_) => "deadline-exceeded",
        KernelHarnessError::WorkerFailed { .. } => "worker-failed",
        KernelHarnessError::StartFailed(_) => "start-failed",
        KernelHarnessError::PollFailed(_) => "poll-failed",
        KernelHarnessError::OutputFailed(_) => "output-failed",
        KernelHarnessError::MalformedResponse(_) => "malformed-response",
        KernelHarnessError::ProtocolError(_) => "protocol-error",
        KernelHarnessError::HashMismatch { .. } => "hash-mismatch",
    }
}

impl RequestTalkTurnKernelWorker for CorpusKernelDecisionWorker {
    fn decide_request_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.request_cases
            .iter()
            .find(|case| {
                case.command == input.command
                    && case.snapshot == input.snapshot
                    && case.policy == input.policy
            })
            .map(|case| KernelDecisionEnvelope {
                case_id: case.id.clone(),
                command: input.command.clone(),
                snapshot: input.snapshot.clone(),
                decision: case.expected_decision.clone(),
            })
            .ok_or(DurablePostgresError::KernelDecisionNotFound)
    }

    fn decide_release_talk_turn(
        &self,
        input: &RequestTalkTurnKernelInput,
    ) -> Result<KernelDecisionEnvelope, DurablePostgresError> {
        self.release_cases
            .iter()
            .find(|case| {
                case.command == input.command
                    && case.snapshot == input.snapshot
                    && case.policy == input.policy
            })
            .map(|case| KernelDecisionEnvelope {
                case_id: case.id.clone(),
                command: input.command.clone(),
                snapshot: input.snapshot.clone(),
                decision: case.expected_decision.clone(),
            })
            .ok_or(DurablePostgresError::KernelDecisionNotFound)
    }
}

pub struct PostgresDecisionCommitter {
    client: Mutex<Client>,
}

impl PostgresDecisionCommitter {
    pub fn new(client: Client) -> Self {
        Self {
            client: Mutex::new(client),
        }
    }

    pub fn deliver_pending_post_commit_effects(
        &mut self,
        limit: i64,
        sink: &mut impl PostCommitEffectSink,
    ) -> Result<Vec<PostCommitOutboxRow>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let rows = client
            .query(
                "select outbox_id, replay_id, effect_kind, effect_json
                 from runtime_post_commit_outbox
                 where delivered_at is null
                 order by outbox_id
                 limit $1",
                &[&limit],
            )?
            .into_iter()
            .map(|row| {
                let outbox_id: i64 = row.get("outbox_id");
                let replay_id: i64 = row.get("replay_id");
                Ok(PostCommitOutboxRow {
                    outbox_id: i64_to_u64("outbox_id", outbox_id)?,
                    replay_id: i64_to_u64("replay_id", replay_id)?,
                    effect_kind: row.get("effect_kind"),
                    effect_json: row.get("effect_json"),
                    delivered: false,
                })
            })
            .collect::<Result<Vec<_>, DurablePostgresError>>()?;
        let mut delivered = Vec::new();
        for row in rows {
            sink.deliver_post_commit_effect(&row)?;
            let outbox_id = u64_to_i64("outbox_id", row.outbox_id)?;
            client.execute(
                "update runtime_post_commit_outbox
                 set delivered_at = now()
                 where outbox_id = $1 and delivered_at is null",
                &[&outbox_id],
            )?;
            delivered.push(PostCommitOutboxRow {
                delivered: true,
                ..row
            });
        }
        Ok(delivered)
    }

    pub fn commit_talk_turn_actor_events(
        &mut self,
        conversation_id: &str,
        owner: &ConversationOwner,
        events: &[DurableTalkTurnEvent],
    ) -> Result<Vec<TalkTurnActorEventRecord>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        let mut records = Vec::new();
        for event in events {
            let candidate = talk_turn_actor_event_record(0, conversation_id, owner, event);
            let owner_epoch = u64_to_i64("owner_epoch", candidate.owner_epoch)?;
            let actor_event_id = u64_to_i64("actor_event_id", candidate.actor_event_id)?;
            let talk_turn_epoch = candidate
                .talk_turn_epoch
                .map(|epoch| u64_to_i64("talk_turn_epoch", epoch))
                .transpose()?;
            let inserted = tx.query_opt(
                "insert into runtime_talk_turn_actor_events (
                    conversation_id,
                    owner_runtime_id,
                    owner_epoch,
                    actor_event_id,
                    event_kind,
                    talk_turn_epoch,
                    operation_id,
                    event_json
                 ) values ($1, $2, $3, $4, $5, $6, $7, $8)
                 on conflict (conversation_id, owner_epoch, actor_event_id) do nothing
                 returning event_row_id, event_json",
                &[
                    &candidate.conversation_id,
                    &candidate.owner_runtime_id,
                    &owner_epoch,
                    &actor_event_id,
                    &candidate.event_kind,
                    &talk_turn_epoch,
                    &candidate.operation_id,
                    &candidate.event_json,
                ],
            )?;
            let record = if let Some(row) = inserted {
                TalkTurnActorEventRecord {
                    event_row_id: i64_to_u64("event_row_id", row.get("event_row_id"))?,
                    ..candidate
                }
            } else {
                let row = tx.query_one(
                    "select event_row_id, event_json
                     from runtime_talk_turn_actor_events
                     where conversation_id = $1
                       and owner_epoch = $2
                       and actor_event_id = $3",
                    &[&candidate.conversation_id, &owner_epoch, &actor_event_id],
                )?;
                let existing_json: Value = row.get("event_json");
                if existing_json != candidate.event_json {
                    return Err(DurablePostgresError::ActorEventConflict {
                        conversation_id: candidate.conversation_id,
                        owner_epoch: candidate.owner_epoch,
                        actor_event_id: candidate.actor_event_id,
                    });
                }
                TalkTurnActorEventRecord {
                    event_row_id: i64_to_u64("event_row_id", row.get("event_row_id"))?,
                    ..candidate
                }
            };
            records.push(record);
        }
        tx.commit()?;
        Ok(records)
    }
}

impl DurableContactStore for PostgresDecisionCommitter {
    fn remember_contact_pair(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError> {
        if owner_handle == peer_handle {
            return Ok(());
        }
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        tx.execute(
            "insert into runtime_remembered_contacts (owner_handle, peer_handle)
             values ($1, $2)
             on conflict (owner_handle, peer_handle)
             do update set remembered_at = now()",
            &[&owner_handle, &peer_handle],
        )?;
        tx.execute(
            "insert into runtime_remembered_contacts (owner_handle, peer_handle)
             values ($1, $2)
             on conflict (owner_handle, peer_handle)
             do update set remembered_at = now()",
            &[&peer_handle, &owner_handle],
        )?;
        tx.commit()?;
        Ok(())
    }

    fn forget_contact(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client.execute(
            "delete from runtime_remembered_contacts
             where owner_handle = $1 and peer_handle = $2",
            &[&owner_handle, &peer_handle],
        )?;
        Ok(())
    }

    fn remembered_contact_handles(
        &mut self,
        owner_handle: &str,
    ) -> Result<Vec<String>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let rows = client.query(
            "select peer_handle
             from runtime_remembered_contacts
             where owner_handle = $1
             order by peer_handle",
            &[&owner_handle],
        )?;
        Ok(rows
            .into_iter()
            .map(|row| row.get::<_, String>("peer_handle"))
            .collect())
    }

    fn clear_remembered_contacts(&mut self) -> Result<usize, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let removed = client.execute("delete from runtime_remembered_contacts", &[])?;
        Ok(removed as usize)
    }

    fn upsert_profile(
        &mut self,
        handle: &str,
        profile_name: &str,
    ) -> Result<(), DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client.execute(
            "insert into runtime_profiles (handle, profile_name)
             values ($1, $2)
             on conflict (handle)
             do update set profile_name = excluded.profile_name, updated_at = now()",
            &[&handle, &profile_name],
        )?;
        Ok(())
    }

    fn profile_name(&mut self, handle: &str) -> Result<Option<String>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        Ok(client
            .query_opt(
                "select profile_name from runtime_profiles where handle = $1",
                &[&handle],
            )?
            .map(|row| row.get::<_, String>("profile_name")))
    }

    fn clear_profiles(&mut self) -> Result<usize, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let removed = client.execute("delete from runtime_profiles", &[])?;
        Ok(removed as usize)
    }
}

impl DurableAlertPushTokenStore for PostgresDecisionCommitter {
    fn upsert_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        token: &str,
        apns_environment: Option<&str>,
    ) -> Result<DurableAlertPushToken, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let row = client.query_one(
            "insert into runtime_alert_push_tokens (
                handle,
                device_id,
                token,
                apns_environment,
                status,
                updated_at,
                invalidated_at,
                invalidation_reason
             ) values ($1, $2, $3, $4, 'valid', now(), null, null)
             on conflict (handle)
             do update set
                device_id = excluded.device_id,
                token = excluded.token,
                apns_environment = excluded.apns_environment,
                status = 'valid',
                updated_at = now(),
                invalidated_at = null,
                invalidation_reason = null
             returning handle, device_id, token, apns_environment, status",
            &[&handle, &device_id, &token, &apns_environment],
        )?;
        Ok(alert_push_token_from_sql(row))
    }

    fn valid_alert_push_token(
        &mut self,
        handle: &str,
    ) -> Result<Option<DurableAlertPushToken>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        Ok(client
            .query_opt(
                "select handle, device_id, token, apns_environment, status
                 from runtime_alert_push_tokens
                 where handle = $1 and status = 'valid'",
                &[&handle],
            )?
            .map(alert_push_token_from_sql))
    }

    fn invalidate_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        reason: &str,
    ) -> Result<(), DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client.execute(
            "update runtime_alert_push_tokens
             set status = 'invalid',
                 invalidated_at = now(),
                 invalidation_reason = $3,
                 updated_at = now()
             where handle = $1 and device_id = $2",
            &[&handle, &device_id, &reason],
        )?;
        Ok(())
    }

    fn clear_alert_push_tokens(&mut self) -> Result<usize, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let removed = client.execute("delete from runtime_alert_push_tokens", &[])?;
        Ok(removed as usize)
    }
}

impl DurableBeepThreadStore for PostgresDecisionCommitter {
    fn create_or_refresh_beep_thread(
        &mut self,
        from_handle: &str,
        to_handle: &str,
        channel_id: &str,
    ) -> Result<DurableBeepThread, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        if let Some(row) = tx.query_opt(
            "update runtime_beep_threads
             set from_handle = $1,
                 to_handle = $2,
                 request_count = request_count + 1,
                 updated_at = now()
             where channel_id = $3 and status = 'pending'
             returning beep_id, from_handle, to_handle, channel_id, status, request_count",
            &[&from_handle, &to_handle, &channel_id],
        )? {
            let thread = beep_thread_from_sql(row)?;
            tx.commit()?;
            return Ok(thread);
        }

        let seq: i64 = tx
            .query_one("select nextval('runtime_beep_thread_seq')", &[])?
            .get(0);
        let beep_id = format!("beep-{seq}");
        let row = tx.query_one(
            "insert into runtime_beep_threads (
                beep_id,
                channel_id,
                from_handle,
                to_handle,
                status,
                request_count
             ) values ($1, $2, $3, $4, 'pending', 1)
             returning beep_id, from_handle, to_handle, channel_id, status, request_count",
            &[&beep_id, &channel_id, &from_handle, &to_handle],
        )?;
        let thread = beep_thread_from_sql(row)?;
        tx.commit()?;
        Ok(thread)
    }

    fn beep_thread(
        &mut self,
        beep_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client
            .query_opt(
                "select beep_id, from_handle, to_handle, channel_id, status, request_count
                 from runtime_beep_threads
                 where beep_id = $1",
                &[&beep_id],
            )?
            .map(beep_thread_from_sql)
            .transpose()
    }

    fn set_beep_thread_status(
        &mut self,
        beep_id: &str,
        status: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client
            .query_opt(
                "update runtime_beep_threads
                 set status = $2, updated_at = now()
                 where beep_id = $1
                 returning beep_id, from_handle, to_handle, channel_id, status, request_count",
                &[&beep_id, &status],
            )?
            .map(beep_thread_from_sql)
            .transpose()
    }

    fn alias_beep_thread(
        &mut self,
        alias_beep_id: &str,
        channel_id: &str,
    ) -> Result<(), DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client.execute(
            "insert into runtime_beep_thread_aliases (alias_beep_id, channel_id)
             values ($1, $2)
             on conflict (alias_beep_id)
             do update set channel_id = excluded.channel_id, updated_at = now()",
            &[&alias_beep_id, &channel_id],
        )?;
        Ok(())
    }

    fn alias_channel_for_beep_thread(
        &mut self,
        alias_beep_id: &str,
    ) -> Result<Option<String>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        Ok(client
            .query_opt(
                "select channel_id
                 from runtime_beep_thread_aliases
                 where alias_beep_id = $1",
                &[&alias_beep_id],
            )?
            .map(|row| row.get::<_, String>("channel_id")))
    }

    fn current_pending_beep_thread_id(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<String>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        Ok(client
            .query_opt(
                "select beep_id
                 from runtime_beep_threads
                 where channel_id = $1 and status = 'pending'",
                &[&channel_id],
            )?
            .map(|row| row.get::<_, String>("beep_id")))
    }

    fn pending_beep_threads_for_handle(
        &mut self,
        handle: &str,
        direction: &str,
    ) -> Result<Vec<DurableBeepThread>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let sql = match direction {
            "incoming" => {
                "select beep_id, from_handle, to_handle, channel_id, status, request_count
                 from runtime_beep_threads
                 where status = 'pending' and to_handle = $1
                 order by updated_at, beep_id"
            }
            "outgoing" => {
                "select beep_id, from_handle, to_handle, channel_id, status, request_count
                 from runtime_beep_threads
                 where status = 'pending' and from_handle = $1
                 order by updated_at, beep_id"
            }
            _ => return Ok(Vec::new()),
        };
        client
            .query(sql, &[&handle])?
            .into_iter()
            .map(beep_thread_from_sql)
            .collect()
    }

    fn pending_beep_thread_for_channel(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        client
            .query_opt(
                "select beep_id, from_handle, to_handle, channel_id, status, request_count
                 from runtime_beep_threads
                 where status = 'pending' and channel_id = $1",
                &[&channel_id],
            )?
            .map(beep_thread_from_sql)
            .transpose()
    }

    fn clear_beep_threads(&mut self) -> Result<usize, DurablePostgresError> {
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        tx.execute("delete from runtime_beep_thread_aliases", &[])?;
        let removed = tx.execute("delete from runtime_beep_threads", &[])?;
        tx.commit()?;
        Ok(removed as usize)
    }
}

fn alert_push_token_from_sql(row: postgres::Row) -> DurableAlertPushToken {
    DurableAlertPushToken {
        handle: row.get("handle"),
        device_id: row.get("device_id"),
        token: row.get("token"),
        apns_environment: row.get("apns_environment"),
        status: row.get("status"),
    }
}

fn beep_thread_from_sql(row: postgres::Row) -> Result<DurableBeepThread, DurablePostgresError> {
    let request_count: i64 = row.get("request_count");
    Ok(DurableBeepThread {
        beep_id: row.get("beep_id"),
        from_handle: row.get("from_handle"),
        to_handle: row.get("to_handle"),
        channel_id: row.get("channel_id"),
        status: row.get("status"),
        request_count: i64_to_u64("request_count", request_count)?,
    })
}

fn actor_operation_id(command: &Value) -> Option<String> {
    path_value(command, &["operationId"])
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn load_existing_actor_operation_result(
    tx: &mut postgres::Transaction<'_>,
    route: &'static str,
    operation_id: &str,
) -> Result<Option<TalkTurnActorOperationResult>, DurablePostgresError> {
    let Some(row) = tx.query_opt(
        "select route, operation_id, command_hash, result_kind, talk_turn_json, actor_event_row_ids
             from runtime_talk_turn_actor_operation_results
             where route = $1 and operation_id = $2",
        &[&route, &operation_id],
    )?
    else {
        return Ok(None);
    };
    let result_kind: String = row.get("result_kind");
    let talk_turn_json: Value = row.get("talk_turn_json");
    let talk_turn = current_talk_turn_row_from_json(&talk_turn_json)?;
    let actor_event_row_ids: Vec<i64> = row.get("actor_event_row_ids");
    let actor_events = tx
        .query(
            "select event_row_id,
                    conversation_id,
                    owner_runtime_id,
                    owner_epoch,
                    actor_event_id,
                    event_kind,
                    talk_turn_epoch,
                    operation_id,
                    event_json
             from runtime_talk_turn_actor_events
             where event_row_id = any($1)
             order by event_row_id",
            &[&actor_event_row_ids],
        )?
        .into_iter()
        .map(talk_turn_actor_event_record_from_sql)
        .collect::<Result<Vec<_>, _>>()?;
    let commit = match result_kind.as_str() {
        "renewed" => TalkTurnActorOperationCommit::Renew(RenewTalkTurnCommit {
            current_talk_turn: talk_turn,
            side_effects: actor_events
                .iter()
                .flat_map(plan_talk_turn_actor_event_side_effects)
                .collect(),
            actor_events,
        }),
        "released" => TalkTurnActorOperationCommit::Release(ReleaseTalkTurnCommit {
            side_effects: actor_events
                .iter()
                .flat_map(|event| plan_talk_turn_actor_release_side_effects(event, &talk_turn))
                .collect(),
            released_talk_turn: talk_turn,
            actor_events,
        }),
        other => {
            return Err(DurablePostgresError::MalformedTransactionEffect(format!(
                "unsupported actor operation result kind {other}"
            )));
        }
    };
    Ok(Some(TalkTurnActorOperationResult {
        route,
        operation_id: row.get("operation_id"),
        command_hash: row.get("command_hash"),
        commit,
    }))
}

fn record_actor_operation_result(
    tx: &mut postgres::Transaction<'_>,
    route: &'static str,
    operation_id: Option<&str>,
    command_hash: &str,
    result_kind: &str,
    talk_turn: &CurrentTalkTurnRow,
    actor_events: &[TalkTurnActorEventRecord],
) -> Result<(), DurablePostgresError> {
    let Some(operation_id) = operation_id else {
        return Ok(());
    };
    let actor_event_row_ids = actor_events
        .iter()
        .map(|event| u64_to_i64("event_row_id", event.event_row_id))
        .collect::<Result<Vec<_>, _>>()?;
    let talk_turn_json = current_talk_turn_row_json(talk_turn);
    tx.execute(
        "insert into runtime_talk_turn_actor_operation_results (
            route,
            conversation_id,
            operation_id,
            command_hash,
            result_kind,
            talk_turn_json,
            actor_event_row_ids
         ) values ($1, $2, $3, $4, $5, $6, $7)",
        &[
            &route,
            &talk_turn.conversation_id,
            &operation_id,
            &command_hash,
            &result_kind,
            &talk_turn_json,
            &actor_event_row_ids,
        ],
    )?;
    Ok(())
}

fn talk_turn_actor_event_record_from_sql(
    row: postgres::Row,
) -> Result<TalkTurnActorEventRecord, DurablePostgresError> {
    let owner_epoch: i64 = row.get("owner_epoch");
    let actor_event_id: i64 = row.get("actor_event_id");
    let talk_turn_epoch: Option<i64> = row.get("talk_turn_epoch");
    Ok(TalkTurnActorEventRecord {
        event_row_id: i64_to_u64("event_row_id", row.get("event_row_id"))?,
        conversation_id: row.get("conversation_id"),
        owner_runtime_id: row.get("owner_runtime_id"),
        owner_epoch: i64_to_u64("owner_epoch", owner_epoch)?,
        actor_event_id: i64_to_u64("actor_event_id", actor_event_id)?,
        event_kind: row.get("event_kind"),
        talk_turn_epoch: talk_turn_epoch
            .map(|epoch| i64_to_u64("talk_turn_epoch", epoch))
            .transpose()?,
        operation_id: row.get("operation_id"),
        event_json: row.get("event_json"),
    })
}

impl TalkTurnRenewalCommitter for PostgresDecisionCommitter {
    fn renew_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<RenewTalkTurnCommit, DurablePostgresError> {
        validate_renew_talk_turn_command(command)?;
        let command_hash = json_hash(command)?;
        let operation_id = actor_operation_id(command);
        let conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        let policy = actor_policy_from_command(command)?;
        let owner = actor_owner_from_command(command)?;
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        if let Some(operation_id) = &operation_id {
            if let Some(existing) =
                load_existing_actor_operation_result(&mut tx, RENEW_TALK_TURN_ROUTE, operation_id)?
            {
                if existing.command_hash == command_hash {
                    tx.commit()?;
                    if let TalkTurnActorOperationCommit::Renew(commit) = existing.commit {
                        return Ok(commit);
                    }
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route: RENEW_TALK_TURN_ROUTE,
                    operation_id: operation_id.clone(),
                });
            }
        }
        let current = tx
            .query_opt(
                "select conversation_id,
                        requesting_participant_id,
                        requesting_device_id,
                        target_participant_id,
                        target_device_id,
                        talk_turn_epoch,
                        expires_at_ms
                 from runtime_current_talk_turns
                 where conversation_id = $1",
                &[&conversation_id],
            )?
            .map(current_talk_turn_row_from_sql)
            .transpose()?
            .ok_or_else(|| {
                DurablePostgresError::TalkTurnRenewalRejected(
                    "no current Talk Turn to renew".to_owned(),
                )
            })?;
        validate_renewal_participant_device(command, &current)?;
        let renewal = actor_renewal_from_command(command, &current, &policy)?;
        let (renewed, events) =
            renew_actor_from_current(&conversation_id, &owner, &policy, &current, renewal)?;
        let owner_epoch = u64_to_i64("owner_epoch", owner.owner_epoch)?;
        let next_actor_event_id = tx
            .query_one(
                "select coalesce(max(actor_event_id), 0) + 1
                 from runtime_talk_turn_actor_events
                 where conversation_id = $1 and owner_epoch = $2",
                &[&conversation_id, &owner_epoch],
            )?
            .get::<_, i64>(0);
        let events = renumber_talk_turn_actor_events(
            &events,
            i64_to_u64("actor_event_id", next_actor_event_id)?,
        );
        let renewed_epoch = u64_to_i64("talk_turn_epoch", renewed.talk_turn_epoch)?;
        let renewed_expires_at_ms = renewed.expires_at_ms;
        let renewed_rows = tx.execute(
            "update runtime_current_talk_turns
             set expires_at_ms = $1,
                 recorded_at = now()
             where conversation_id = $2 and talk_turn_epoch = $3",
            &[&renewed_expires_at_ms, &conversation_id, &renewed_epoch],
        )?;
        if renewed_rows != 1 {
            return Err(DurablePostgresError::TalkTurnRenewalRejected(
                "current Talk Turn changed before renewal commit".to_owned(),
            ));
        }
        let mut actor_events = Vec::new();
        for event in &events {
            let candidate = talk_turn_actor_event_record(0, &conversation_id, &owner, event);
            let actor_event_id = u64_to_i64("actor_event_id", candidate.actor_event_id)?;
            let talk_turn_epoch = candidate
                .talk_turn_epoch
                .map(|epoch| u64_to_i64("talk_turn_epoch", epoch))
                .transpose()?;
            let row = tx.query_one(
                "insert into runtime_talk_turn_actor_events (
                    conversation_id,
                    owner_runtime_id,
                    owner_epoch,
                    actor_event_id,
                    event_kind,
                    talk_turn_epoch,
                    operation_id,
                    event_json
                 ) values ($1, $2, $3, $4, $5, $6, $7, $8)
                 on conflict (conversation_id, owner_epoch, actor_event_id) do update set
                    event_json = runtime_talk_turn_actor_events.event_json
                 returning event_row_id, event_json",
                &[
                    &candidate.conversation_id,
                    &candidate.owner_runtime_id,
                    &owner_epoch,
                    &actor_event_id,
                    &candidate.event_kind,
                    &talk_turn_epoch,
                    &candidate.operation_id,
                    &candidate.event_json,
                ],
            )?;
            let existing_json: Value = row.get("event_json");
            if existing_json != candidate.event_json {
                return Err(DurablePostgresError::ActorEventConflict {
                    conversation_id: candidate.conversation_id,
                    owner_epoch: candidate.owner_epoch,
                    actor_event_id: candidate.actor_event_id,
                });
            }
            actor_events.push(TalkTurnActorEventRecord {
                event_row_id: i64_to_u64("event_row_id", row.get("event_row_id"))?,
                ..candidate
            });
        }
        record_actor_operation_result(
            &mut tx,
            RENEW_TALK_TURN_ROUTE,
            operation_id.as_deref(),
            &command_hash,
            "renewed",
            &renewed,
            &actor_events,
        )?;
        tx.commit()?;
        let side_effects = actor_events
            .iter()
            .flat_map(plan_talk_turn_actor_event_side_effects)
            .collect();
        Ok(RenewTalkTurnCommit {
            current_talk_turn: renewed,
            actor_events,
            side_effects,
        })
    }
}

impl TalkTurnReleaseCommitter for PostgresDecisionCommitter {
    fn release_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<ReleaseTalkTurnCommit, DurablePostgresError> {
        if required_string(command, &["kind"], "command.kind")? != "release-talk-turn" {
            return Err(DurablePostgresError::UnsupportedCommand {
                route: RELEASE_TALK_TURN_ROUTE,
                kind: KernelCommandKind::RequestTalkTurn,
            });
        }
        let command_hash = json_hash(command)?;
        let operation_id = actor_operation_id(command);
        let conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        let owner = actor_owner_from_command(command)?;
        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        if let Some(operation_id) = &operation_id {
            if let Some(existing) = load_existing_actor_operation_result(
                &mut tx,
                RELEASE_TALK_TURN_ROUTE,
                operation_id,
            )? {
                if existing.command_hash == command_hash {
                    tx.commit()?;
                    if let TalkTurnActorOperationCommit::Release(commit) = existing.commit {
                        return Ok(commit);
                    }
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route: RELEASE_TALK_TURN_ROUTE,
                    operation_id: operation_id.clone(),
                });
            }
        }
        let current = tx
            .query_opt(
                "select conversation_id,
                        requesting_participant_id,
                        requesting_device_id,
                        target_participant_id,
                        target_device_id,
                        talk_turn_epoch,
                        expires_at_ms
                 from runtime_current_talk_turns
                 where conversation_id = $1",
                &[&conversation_id],
            )?
            .map(current_talk_turn_row_from_sql)
            .transpose()?
            .ok_or_else(|| {
                DurablePostgresError::TalkTurnRenewalRejected(
                    "no current Talk Turn to release".to_owned(),
                )
            })?;
        validate_release_participant_device(command, &current)?;
        let release = actor_release_from_command(command, &current);
        let events = release_actor_from_current(&conversation_id, &owner, &current, release)?;
        let owner_epoch = u64_to_i64("owner_epoch", owner.owner_epoch)?;
        let next_actor_event_id = tx
            .query_one(
                "select coalesce(max(actor_event_id), 0) + 1
                 from runtime_talk_turn_actor_events
                 where conversation_id = $1 and owner_epoch = $2",
                &[&conversation_id, &owner_epoch],
            )?
            .get::<_, i64>(0);
        let events = renumber_talk_turn_actor_events(
            &events,
            i64_to_u64("actor_event_id", next_actor_event_id)?,
        );
        let talk_turn_epoch = u64_to_i64("talk_turn_epoch", current.talk_turn_epoch)?;
        let released_rows = tx.execute(
            "delete from runtime_current_talk_turns
             where conversation_id = $1
               and talk_turn_epoch = $2
               and requesting_device_id = $3",
            &[
                &conversation_id,
                &talk_turn_epoch,
                &current.requesting_device_id,
            ],
        )?;
        if released_rows != 1 {
            return Err(DurablePostgresError::TalkTurnRenewalRejected(
                "current Talk Turn changed before release commit".to_owned(),
            ));
        }
        let mut actor_events = Vec::new();
        for event in &events {
            let candidate = talk_turn_actor_event_record(0, &conversation_id, &owner, event);
            let actor_event_id = u64_to_i64("actor_event_id", candidate.actor_event_id)?;
            let talk_turn_epoch = candidate
                .talk_turn_epoch
                .map(|epoch| u64_to_i64("talk_turn_epoch", epoch))
                .transpose()?;
            let row = tx.query_one(
                "insert into runtime_talk_turn_actor_events (
                    conversation_id,
                    owner_runtime_id,
                    owner_epoch,
                    actor_event_id,
                    event_kind,
                    talk_turn_epoch,
                    operation_id,
                    event_json
                 ) values ($1, $2, $3, $4, $5, $6, $7, $8)
                 on conflict (conversation_id, owner_epoch, actor_event_id) do update set
                    event_json = runtime_talk_turn_actor_events.event_json
                 returning event_row_id, event_json",
                &[
                    &candidate.conversation_id,
                    &candidate.owner_runtime_id,
                    &owner_epoch,
                    &actor_event_id,
                    &candidate.event_kind,
                    &talk_turn_epoch,
                    &candidate.operation_id,
                    &candidate.event_json,
                ],
            )?;
            let existing_json: Value = row.get("event_json");
            if existing_json != candidate.event_json {
                return Err(DurablePostgresError::ActorEventConflict {
                    conversation_id: candidate.conversation_id,
                    owner_epoch: candidate.owner_epoch,
                    actor_event_id: candidate.actor_event_id,
                });
            }
            actor_events.push(TalkTurnActorEventRecord {
                event_row_id: i64_to_u64("event_row_id", row.get("event_row_id"))?,
                ..candidate
            });
        }
        record_actor_operation_result(
            &mut tx,
            RELEASE_TALK_TURN_ROUTE,
            operation_id.as_deref(),
            &command_hash,
            "released",
            &current,
            &actor_events,
        )?;
        tx.commit()?;
        let side_effects = actor_events
            .iter()
            .flat_map(|event| plan_talk_turn_actor_release_side_effects(event, &current))
            .collect();
        Ok(ReleaseTalkTurnCommit {
            released_talk_turn: current,
            actor_events,
            side_effects,
        })
    }
}

impl KernelDecisionCommitter for PostgresDecisionCommitter {
    fn commit_kernel_decision_envelope(
        &mut self,
        envelope: &KernelDecisionEnvelope,
        route: &'static str,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        let command_hash = json_hash(&envelope.command)?;
        let snapshot_hash = json_hash(&envelope.snapshot)?;
        let decision_hash = json_hash(&envelope.decision)?;
        let decision_kind = required_string(&envelope.decision, &["kind"], "decision.kind")?;
        let conversation_id = optional_wrapped_string(&envelope.command, &["conversationId"]);
        let operation_id = optional_string(&envelope.command, &["operationId"]).map(str::to_owned);
        let transaction_effects =
            optional_array(&envelope.decision, &["effectPlan", "transactionEffects"]);
        let mut post_commit_effects =
            optional_array(&envelope.decision, &["effectPlan", "postCommitEffects"])
                .into_iter()
                .cloned()
                .collect::<Vec<_>>();

        let mut client = self
            .client
            .lock()
            .expect("Postgres decision committer lock should not be poisoned");
        let mut tx = client.transaction()?;
        if let Some(operation_id) = &operation_id {
            if let Some(existing) =
                load_existing_committed_effect_plan(&mut tx, route, operation_id)?
            {
                if existing.replay_fact.command_hash == command_hash {
                    tx.commit()?;
                    return Ok(existing);
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route,
                    operation_id: operation_id.clone(),
                });
            }
        }

        let mut written_current_turns = BTreeSet::new();
        let mut current_talk_turn = None;
        for effect in transaction_effects {
            if let Some(row) =
                apply_transaction_effect_postgres(&mut tx, effect, &mut written_current_turns)?
            {
                current_talk_turn = Some(row);
            }
        }
        align_post_commit_effects(&mut post_commit_effects, current_talk_turn.as_ref());

        let replay_id: i64 = tx
            .query_one(
                "insert into runtime_kernel_replay_facts (
                    route,
                    conversation_id,
                    operation_id,
                    command_hash,
                    snapshot_hash,
                    decision_hash,
                    decision_kind
                ) values ($1, $2, $3, $4, $5, $6, $7)
                returning replay_id",
                &[
                    &route,
                    &conversation_id,
                    &operation_id,
                    &command_hash,
                    &snapshot_hash,
                    &decision_hash,
                    &decision_kind,
                ],
            )?
            .get(0);
        let replay_id_u64 = i64_to_u64("replay_id", replay_id)?;
        let mut outbox_rows = Vec::new();
        for effect in post_commit_effects {
            let effect_kind =
                required_string(&effect, &["kind"], "postCommitEffect.kind")?.to_owned();
            let outbox_id: i64 = tx
                .query_one(
                    "insert into runtime_post_commit_outbox (
                        replay_id,
                        effect_kind,
                        effect_json
                    ) values ($1, $2, $3)
                    returning outbox_id",
                    &[&replay_id, &effect_kind, &effect],
                )?
                .get(0);
            outbox_rows.push(PostCommitOutboxRow {
                outbox_id: i64_to_u64("outbox_id", outbox_id)?,
                replay_id: replay_id_u64,
                effect_kind,
                effect_json: effect,
                delivered: false,
            });
        }
        tx.commit()?;

        Ok(CommittedEffectPlan {
            replay_fact: KernelReplayFact {
                replay_id: replay_id_u64,
                case_id: envelope.case_id.clone(),
                route,
                conversation_id,
                operation_id,
                command_hash,
                snapshot_hash,
                decision_hash,
                decision_kind: decision_kind.to_owned(),
            },
            outbox_rows,
            current_talk_turn,
        })
    }
}

fn load_existing_committed_effect_plan(
    tx: &mut postgres::Transaction<'_>,
    route: &'static str,
    operation_id: &str,
) -> Result<Option<CommittedEffectPlan>, DurablePostgresError> {
    let Some(row) = tx
        .query_opt(
            "select replay_id, conversation_id, operation_id, command_hash, snapshot_hash, decision_hash, decision_kind
             from runtime_kernel_replay_facts
             where route = $1 and operation_id = $2",
            &[&route, &operation_id],
        )?
    else {
        return Ok(None);
    };
    let replay_id: i64 = row.get("replay_id");
    let replay_id_u64 = i64_to_u64("replay_id", replay_id)?;
    let outbox_rows = tx
        .query(
            "select outbox_id, effect_kind, effect_json, delivered_at is not null as delivered
             from runtime_post_commit_outbox
             where replay_id = $1
             order by outbox_id",
            &[&replay_id],
        )?
        .into_iter()
        .map(|row| {
            let outbox_id: i64 = row.get("outbox_id");
            Ok(PostCommitOutboxRow {
                outbox_id: i64_to_u64("outbox_id", outbox_id)?,
                replay_id: replay_id_u64,
                effect_kind: row.get("effect_kind"),
                effect_json: row.get("effect_json"),
                delivered: row.get("delivered"),
            })
        })
        .collect::<Result<Vec<_>, DurablePostgresError>>()?;
    Ok(Some(CommittedEffectPlan {
        replay_fact: KernelReplayFact {
            replay_id: replay_id_u64,
            case_id: "postgres-replay".to_owned(),
            route,
            conversation_id: row.get("conversation_id"),
            operation_id: row.get("operation_id"),
            command_hash: row.get("command_hash"),
            snapshot_hash: row.get("snapshot_hash"),
            decision_hash: row.get("decision_hash"),
            decision_kind: row.get("decision_kind"),
        },
        outbox_rows,
        current_talk_turn: None,
    }))
}

fn apply_transaction_effect_postgres(
    tx: &mut postgres::Transaction<'_>,
    effect: &Value,
    written_current_turns: &mut BTreeSet<String>,
) -> Result<Option<CurrentTalkTurnRow>, DurablePostgresError> {
    let kind = required_string(effect, &["kind"], "transactionEffect.kind")?;
    match kind {
        "record-talk-turn" => {
            let conversation_id =
                required_wrapped_string(effect, &["conversationId"], "conversationId")?;
            if !written_current_turns.insert(conversation_id.clone()) {
                return Err(DurablePostgresError::DuplicateCurrentTalkTurnWrite(
                    conversation_id,
                ));
            }
            let requesting_participant_id = required_wrapped_string(
                effect,
                &["requestingParticipantId"],
                "requestingParticipantId",
            )?;
            let requesting_device_id =
                required_wrapped_string(effect, &["requestingDeviceId"], "requestingDeviceId")?;
            let target_participant_id =
                required_wrapped_string(effect, &["targetParticipantId"], "targetParticipantId")?;
            let target_device_id =
                required_wrapped_string(effect, &["targetDeviceId"], "targetDeviceId")?;
            let requested_talk_turn_epoch = u64_to_i64(
                "talkTurnEpoch",
                required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?,
            )?;
            let max_recorded_talk_turn_epoch: i64 = tx
                .query_one(
                    "select greatest(
                        coalesce((
                            select max(talk_turn_epoch)
                            from runtime_current_talk_turns
                            where conversation_id = $1
                        ), 0),
                        coalesce((
                            select max(talk_turn_epoch)
                            from runtime_talk_turn_actor_events
                            where conversation_id = $1
                              and talk_turn_epoch is not null
                        ), 0)
                     )",
                    &[&conversation_id],
                )?
                .get(0);
            let talk_turn_epoch = requested_talk_turn_epoch.max(max_recorded_talk_turn_epoch + 1);
            let expires_at_ms = required_i64(effect, &["expiresAtMs"], "expiresAtMs")?;
            let active_rows: i64 = tx
                .query_one(
                    "select count(*) from runtime_current_talk_turns where conversation_id = $1",
                    &[&conversation_id],
                )?
                .get(0);
            if active_rows > 0 {
                return Err(DurablePostgresError::TalkTurnRenewalRejected(
                    "current Talk Turn already active".to_owned(),
                ));
            }
            tx.execute(
                "insert into runtime_current_talk_turns (
                    conversation_id,
                    requesting_participant_id,
                    requesting_device_id,
                    target_participant_id,
                    target_device_id,
                    talk_turn_epoch,
                    expires_at_ms
                ) values ($1, $2, $3, $4, $5, $6, $7)
                on conflict (conversation_id) do update set
                    requesting_participant_id = excluded.requesting_participant_id,
                    requesting_device_id = excluded.requesting_device_id,
                    target_participant_id = excluded.target_participant_id,
                    target_device_id = excluded.target_device_id,
                    talk_turn_epoch = excluded.talk_turn_epoch,
                    expires_at_ms = excluded.expires_at_ms,
                    recorded_at = now()",
                &[
                    &conversation_id,
                    &requesting_participant_id,
                    &requesting_device_id,
                    &target_participant_id,
                    &target_device_id,
                    &talk_turn_epoch,
                    &expires_at_ms,
                ],
            )?;
            Ok(Some(CurrentTalkTurnRow {
                conversation_id,
                requesting_participant_id,
                requesting_device_id,
                target_participant_id,
                target_device_id,
                talk_turn_epoch: i64_to_u64("talk_turn_epoch", talk_turn_epoch)?,
                expires_at_ms,
            }))
        }
        "clear-talk-turn" => {
            let conversation_id =
                required_wrapped_string(effect, &["conversationId"], "conversationId")?;
            let talk_turn_epoch = u64_to_i64(
                "talkTurnEpoch",
                required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?,
            )?;
            tx.execute(
                "delete from runtime_current_talk_turns
                 where conversation_id = $1 and talk_turn_epoch = $2",
                &[&conversation_id, &talk_turn_epoch],
            )?;
            Ok(None)
        }
        other => Err(DurablePostgresError::UnsupportedTransactionEffect(
            other.to_owned(),
        )),
    }
}

impl DurableConversationStore {
    pub fn current_talk_turn(&self, conversation_id: &str) -> Option<&CurrentTalkTurnRow> {
        self.current_talk_turns.get(conversation_id)
    }

    pub fn replay_facts(&self) -> &[KernelReplayFact] {
        &self.replay_facts
    }

    pub fn post_commit_outbox(&self) -> &[PostCommitOutboxRow] {
        &self.post_commit_outbox
    }

    pub fn talk_turn_actor_events(&self) -> &[TalkTurnActorEventRecord] {
        &self.talk_turn_actor_events
    }

    pub fn commit_talk_turn_actor_events(
        &mut self,
        conversation_id: &str,
        owner: &ConversationOwner,
        events: &[DurableTalkTurnEvent],
    ) -> Result<Vec<TalkTurnActorEventRecord>, DurablePostgresError> {
        let mut staged = self.clone();
        let mut committed = Vec::new();
        for event in events {
            let candidate = talk_turn_actor_event_record(
                staged.talk_turn_actor_events.len() as u64 + 1,
                conversation_id,
                owner,
                event,
            );
            if let Some(existing) = staged.talk_turn_actor_events.iter().find(|record| {
                record.conversation_id == candidate.conversation_id
                    && record.owner_epoch == candidate.owner_epoch
                    && record.actor_event_id == candidate.actor_event_id
            }) {
                if existing.event_json != candidate.event_json {
                    return Err(DurablePostgresError::ActorEventConflict {
                        conversation_id: candidate.conversation_id,
                        owner_epoch: candidate.owner_epoch,
                        actor_event_id: candidate.actor_event_id,
                    });
                }
                committed.push(existing.clone());
            } else {
                staged.talk_turn_actor_events.push(candidate.clone());
                committed.push(candidate);
            }
        }
        *self = staged;
        Ok(committed)
    }

    pub fn deliver_committed_post_commit_effects(
        &mut self,
        committed: &CommittedEffectPlan,
        sink: &mut impl PostCommitEffectSink,
    ) -> Result<Vec<PostCommitOutboxRow>, DurablePostgresError> {
        let mut delivered = Vec::new();
        for committed_row in &committed.outbox_rows {
            let Some(index) = self
                .post_commit_outbox
                .iter()
                .position(|row| row.outbox_id == committed_row.outbox_id)
            else {
                continue;
            };
            if self.post_commit_outbox[index].delivered {
                continue;
            }
            let row = self.post_commit_outbox[index].clone();
            sink.deliver_post_commit_effect(&row)?;
            self.post_commit_outbox[index].delivered = true;
            delivered.push(PostCommitOutboxRow {
                delivered: true,
                ..row
            });
        }
        for committed in self.operation_results.values_mut() {
            for row in &mut committed.outbox_rows {
                if delivered
                    .iter()
                    .any(|delivered_row| delivered_row.outbox_id == row.outbox_id)
                {
                    row.delivered = true;
                }
            }
        }
        Ok(delivered)
    }

    pub fn execute_request_talk_turn_case(
        &mut self,
        case: &KernelCorpusCase,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        if case.kind != KernelCommandKind::RequestTalkTurn {
            return Err(DurablePostgresError::UnsupportedCommand {
                route: REQUEST_TALK_TURN_ROUTE,
                kind: case.kind,
            });
        }

        self.commit_kernel_decision(case, REQUEST_TALK_TURN_ROUTE)
    }

    pub fn commit_kernel_decision(
        &mut self,
        case: &KernelCorpusCase,
        route: &'static str,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        self.commit_kernel_decision_envelope(
            &KernelDecisionEnvelope {
                case_id: case.id.clone(),
                command: case.command.clone(),
                snapshot: case.snapshot.clone(),
                decision: case.expected_decision.clone(),
            },
            route,
        )
    }

    pub fn commit_kernel_decision_envelope(
        &mut self,
        envelope: &KernelDecisionEnvelope,
        route: &'static str,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        let command_hash = json_hash(&envelope.command)?;
        let operation_id = optional_string(&envelope.command, &["operationId"]).map(str::to_owned);
        if let Some(operation_id) = &operation_id {
            let operation_key = (route.to_owned(), operation_id.clone());
            if let Some(existing) = self.operation_results.get(&operation_key) {
                if existing.replay_fact.command_hash == command_hash {
                    return Ok(existing.clone());
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route,
                    operation_id: operation_id.clone(),
                });
            }
        }

        let decision_kind = required_string(&envelope.decision, &["kind"], "decision.kind")?;
        let transaction_effects =
            optional_array(&envelope.decision, &["effectPlan", "transactionEffects"]);
        let mut post_commit_effects =
            optional_array(&envelope.decision, &["effectPlan", "postCommitEffects"])
                .into_iter()
                .cloned()
                .collect::<Vec<_>>();

        let mut staged = self.clone();
        let mut written_current_turns = BTreeSet::new();
        let mut current_talk_turn = None;
        for effect in transaction_effects {
            if let Some(row) =
                apply_transaction_effect(&mut staged, effect, &mut written_current_turns)?
            {
                current_talk_turn = Some(row);
            }
        }
        align_post_commit_effects(&mut post_commit_effects, current_talk_turn.as_ref());

        let replay_fact = replay_fact(
            envelope,
            route,
            decision_kind,
            command_hash,
            operation_id.clone(),
            staged.replay_facts.len() as u64 + 1,
        )?;
        let outbox_rows = post_commit_effects
            .into_iter()
            .enumerate()
            .map(|(index, effect)| {
                post_commit_outbox_row(
                    staged.post_commit_outbox.len() as u64 + index as u64 + 1,
                    replay_fact.replay_id,
                    effect,
                )
            })
            .collect::<Result<Vec<_>, _>>()?;
        staged.replay_facts.push(replay_fact.clone());
        staged.post_commit_outbox.extend(outbox_rows.clone());
        let committed = CommittedEffectPlan {
            replay_fact,
            outbox_rows,
            current_talk_turn,
        };
        if let Some(operation_id) = operation_id {
            staged
                .operation_results
                .insert((route.to_owned(), operation_id), committed.clone());
        }
        *self = staged;

        Ok(committed)
    }
}

impl KernelDecisionCommitter for DurableConversationStore {
    fn commit_kernel_decision_envelope(
        &mut self,
        envelope: &KernelDecisionEnvelope,
        route: &'static str,
    ) -> Result<CommittedEffectPlan, DurablePostgresError> {
        DurableConversationStore::commit_kernel_decision_envelope(self, envelope, route)
    }
}

impl DurableContactStore for DurableConversationStore {
    fn remember_contact_pair(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError> {
        if owner_handle == peer_handle {
            return Ok(());
        }
        self.remembered_contacts_by_handle
            .entry(owner_handle.to_owned())
            .or_default()
            .insert(peer_handle.to_owned());
        self.remembered_contacts_by_handle
            .entry(peer_handle.to_owned())
            .or_default()
            .insert(owner_handle.to_owned());
        Ok(())
    }

    fn forget_contact(
        &mut self,
        owner_handle: &str,
        peer_handle: &str,
    ) -> Result<(), DurablePostgresError> {
        if let Some(remembered_contacts) = self.remembered_contacts_by_handle.get_mut(owner_handle)
        {
            remembered_contacts.remove(peer_handle);
            if remembered_contacts.is_empty() {
                self.remembered_contacts_by_handle.remove(owner_handle);
            }
        }
        Ok(())
    }

    fn remembered_contact_handles(
        &mut self,
        owner_handle: &str,
    ) -> Result<Vec<String>, DurablePostgresError> {
        Ok(self
            .remembered_contacts_by_handle
            .get(owner_handle)
            .map(|contacts| contacts.iter().cloned().collect())
            .unwrap_or_default())
    }

    fn clear_remembered_contacts(&mut self) -> Result<usize, DurablePostgresError> {
        let removed = self
            .remembered_contacts_by_handle
            .values()
            .map(BTreeSet::len)
            .sum();
        self.remembered_contacts_by_handle.clear();
        Ok(removed)
    }

    fn upsert_profile(
        &mut self,
        handle: &str,
        profile_name: &str,
    ) -> Result<(), DurablePostgresError> {
        self.profiles_by_handle
            .insert(handle.to_owned(), profile_name.to_owned());
        Ok(())
    }

    fn profile_name(&mut self, handle: &str) -> Result<Option<String>, DurablePostgresError> {
        Ok(self.profiles_by_handle.get(handle).cloned())
    }

    fn clear_profiles(&mut self) -> Result<usize, DurablePostgresError> {
        let removed = self.profiles_by_handle.len();
        self.profiles_by_handle.clear();
        Ok(removed)
    }
}

impl DurableAlertPushTokenStore for DurableConversationStore {
    fn upsert_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        token: &str,
        apns_environment: Option<&str>,
    ) -> Result<DurableAlertPushToken, DurablePostgresError> {
        let row = DurableAlertPushToken {
            handle: handle.to_owned(),
            device_id: device_id.to_owned(),
            token: token.to_owned(),
            apns_environment: apns_environment.map(ToOwned::to_owned),
            status: "valid".to_owned(),
        };
        self.alert_push_tokens_by_handle
            .insert(handle.to_owned(), row.clone());
        Ok(row)
    }

    fn valid_alert_push_token(
        &mut self,
        handle: &str,
    ) -> Result<Option<DurableAlertPushToken>, DurablePostgresError> {
        Ok(self
            .alert_push_tokens_by_handle
            .get(handle)
            .filter(|token| token.status == "valid")
            .cloned())
    }

    fn invalidate_alert_push_token(
        &mut self,
        handle: &str,
        device_id: &str,
        _reason: &str,
    ) -> Result<(), DurablePostgresError> {
        if let Some(token) = self.alert_push_tokens_by_handle.get_mut(handle) {
            if token.device_id == device_id {
                token.status = "invalid".to_owned();
            }
        }
        Ok(())
    }

    fn clear_alert_push_tokens(&mut self) -> Result<usize, DurablePostgresError> {
        let removed = self.alert_push_tokens_by_handle.len();
        self.alert_push_tokens_by_handle.clear();
        Ok(removed)
    }
}

impl DurableBeepThreadStore for DurableConversationStore {
    fn create_or_refresh_beep_thread(
        &mut self,
        from_handle: &str,
        to_handle: &str,
        channel_id: &str,
    ) -> Result<DurableBeepThread, DurablePostgresError> {
        if let Some(beep_id) = self
            .beep_threads
            .values()
            .find(|thread| thread.channel_id == channel_id && thread.status == "pending")
            .map(|thread| thread.beep_id.clone())
        {
            let thread = self
                .beep_threads
                .get_mut(&beep_id)
                .expect("pending Beep Thread id should exist");
            thread.from_handle = from_handle.to_owned();
            thread.to_handle = to_handle.to_owned();
            thread.request_count += 1;
            return Ok(thread.clone());
        }

        self.next_beep_id += 1;
        let thread = DurableBeepThread {
            beep_id: format!("beep-{}", self.next_beep_id),
            from_handle: from_handle.to_owned(),
            to_handle: to_handle.to_owned(),
            channel_id: channel_id.to_owned(),
            status: "pending".to_owned(),
            request_count: 1,
        };
        self.beep_threads
            .insert(thread.beep_id.clone(), thread.clone());
        Ok(thread)
    }

    fn beep_thread(
        &mut self,
        beep_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        Ok(self.beep_threads.get(beep_id).cloned())
    }

    fn set_beep_thread_status(
        &mut self,
        beep_id: &str,
        status: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        let Some(thread) = self.beep_threads.get_mut(beep_id) else {
            return Ok(None);
        };
        thread.status = status.to_owned();
        Ok(Some(thread.clone()))
    }

    fn alias_beep_thread(
        &mut self,
        alias_beep_id: &str,
        channel_id: &str,
    ) -> Result<(), DurablePostgresError> {
        self.beep_aliases_by_id
            .insert(alias_beep_id.to_owned(), channel_id.to_owned());
        Ok(())
    }

    fn alias_channel_for_beep_thread(
        &mut self,
        alias_beep_id: &str,
    ) -> Result<Option<String>, DurablePostgresError> {
        Ok(self.beep_aliases_by_id.get(alias_beep_id).cloned())
    }

    fn current_pending_beep_thread_id(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<String>, DurablePostgresError> {
        Ok(self
            .beep_threads
            .values()
            .find(|thread| thread.channel_id == channel_id && thread.status == "pending")
            .map(|thread| thread.beep_id.clone()))
    }

    fn pending_beep_threads_for_handle(
        &mut self,
        handle: &str,
        direction: &str,
    ) -> Result<Vec<DurableBeepThread>, DurablePostgresError> {
        Ok(self
            .beep_threads
            .values()
            .filter(|thread| thread.status == "pending")
            .filter(|thread| match direction {
                "incoming" => thread.to_handle == handle,
                "outgoing" => thread.from_handle == handle,
                _ => false,
            })
            .cloned()
            .collect())
    }

    fn pending_beep_thread_for_channel(
        &mut self,
        channel_id: &str,
    ) -> Result<Option<DurableBeepThread>, DurablePostgresError> {
        Ok(self
            .beep_threads
            .values()
            .find(|thread| thread.channel_id == channel_id && thread.status == "pending")
            .cloned())
    }

    fn clear_beep_threads(&mut self) -> Result<usize, DurablePostgresError> {
        let removed = self.beep_threads.len();
        self.beep_threads.clear();
        self.beep_aliases_by_id.clear();
        self.next_beep_id = 0;
        Ok(removed)
    }
}

impl TalkTurnRenewalCommitter for DurableConversationStore {
    fn renew_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<RenewTalkTurnCommit, DurablePostgresError> {
        validate_renew_talk_turn_command(command)?;
        let command_hash = json_hash(command)?;
        let operation_id = actor_operation_id(command);
        if let Some(operation_id) = &operation_id {
            let operation_key = (RENEW_TALK_TURN_ROUTE.to_owned(), operation_id.clone());
            if let Some(existing) = self.actor_operation_results.get(&operation_key) {
                if existing.command_hash == command_hash {
                    if let TalkTurnActorOperationCommit::Renew(commit) = &existing.commit {
                        return Ok(commit.clone());
                    }
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route: RENEW_TALK_TURN_ROUTE,
                    operation_id: operation_id.clone(),
                });
            }
        }
        let conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        let policy = actor_policy_from_command(command)?;
        let owner = actor_owner_from_command(command)?;
        let mut staged = self.clone();
        let current = staged
            .current_talk_turns
            .get(&conversation_id)
            .cloned()
            .ok_or_else(|| {
                DurablePostgresError::TalkTurnRenewalRejected(
                    "no current Talk Turn to renew".to_owned(),
                )
            })?;
        validate_renewal_participant_device(command, &current)?;
        let renewal = actor_renewal_from_command(command, &current, &policy)?;
        let (renewed, events) =
            renew_actor_from_current(&conversation_id, &owner, &policy, &current, renewal)?;
        let next_actor_event_id = staged
            .talk_turn_actor_events
            .iter()
            .filter(|record| {
                record.conversation_id == conversation_id && record.owner_epoch == owner.owner_epoch
            })
            .map(|record| record.actor_event_id)
            .max()
            .unwrap_or(0)
            + 1;
        let events = renumber_talk_turn_actor_events(&events, next_actor_event_id);
        staged
            .current_talk_turns
            .insert(conversation_id.clone(), renewed.clone());
        let actor_events =
            staged.commit_talk_turn_actor_events(&conversation_id, &owner, &events)?;
        let side_effects = actor_events
            .iter()
            .flat_map(plan_talk_turn_actor_event_side_effects)
            .collect();
        let committed = RenewTalkTurnCommit {
            current_talk_turn: renewed,
            actor_events,
            side_effects,
        };
        if let Some(operation_id) = operation_id {
            staged.actor_operation_results.insert(
                (RENEW_TALK_TURN_ROUTE.to_owned(), operation_id.clone()),
                TalkTurnActorOperationResult {
                    route: RENEW_TALK_TURN_ROUTE,
                    operation_id,
                    command_hash,
                    commit: TalkTurnActorOperationCommit::Renew(committed.clone()),
                },
            );
        }
        *self = staged;
        Ok(committed)
    }
}

impl TalkTurnReleaseCommitter for DurableConversationStore {
    fn release_talk_turn(
        &mut self,
        command: &Value,
    ) -> Result<ReleaseTalkTurnCommit, DurablePostgresError> {
        if required_string(command, &["kind"], "command.kind")? != "release-talk-turn" {
            return Err(DurablePostgresError::UnsupportedCommand {
                route: RELEASE_TALK_TURN_ROUTE,
                kind: KernelCommandKind::RequestTalkTurn,
            });
        }
        let command_hash = json_hash(command)?;
        let operation_id = actor_operation_id(command);
        if let Some(operation_id) = &operation_id {
            let operation_key = (RELEASE_TALK_TURN_ROUTE.to_owned(), operation_id.clone());
            if let Some(existing) = self.actor_operation_results.get(&operation_key) {
                if existing.command_hash == command_hash {
                    if let TalkTurnActorOperationCommit::Release(commit) = &existing.commit {
                        return Ok(commit.clone());
                    }
                }
                return Err(DurablePostgresError::IdempotencyConflict {
                    route: RELEASE_TALK_TURN_ROUTE,
                    operation_id: operation_id.clone(),
                });
            }
        }
        let conversation_id =
            required_wrapped_string(command, &["conversationId"], "command.conversationId")?;
        let owner = actor_owner_from_command(command)?;
        let mut staged = self.clone();
        let current = staged
            .current_talk_turns
            .get(&conversation_id)
            .cloned()
            .ok_or_else(|| {
                DurablePostgresError::TalkTurnRenewalRejected(
                    "no current Talk Turn to release".to_owned(),
                )
            })?;
        validate_release_participant_device(command, &current)?;
        let release = actor_release_from_command(command, &current);
        let events = release_actor_from_current(&conversation_id, &owner, &current, release)?;
        let next_actor_event_id = staged
            .talk_turn_actor_events
            .iter()
            .filter(|record| {
                record.conversation_id == conversation_id && record.owner_epoch == owner.owner_epoch
            })
            .map(|record| record.actor_event_id)
            .max()
            .unwrap_or(0)
            + 1;
        let events = renumber_talk_turn_actor_events(&events, next_actor_event_id);
        staged.current_talk_turns.remove(&conversation_id);
        let actor_events =
            staged.commit_talk_turn_actor_events(&conversation_id, &owner, &events)?;
        let side_effects = actor_events
            .iter()
            .flat_map(|event| plan_talk_turn_actor_release_side_effects(event, &current))
            .collect();
        let committed = ReleaseTalkTurnCommit {
            released_talk_turn: current,
            actor_events,
            side_effects,
        };
        if let Some(operation_id) = operation_id {
            staged.actor_operation_results.insert(
                (RELEASE_TALK_TURN_ROUTE.to_owned(), operation_id.clone()),
                TalkTurnActorOperationResult {
                    route: RELEASE_TALK_TURN_ROUTE,
                    operation_id,
                    command_hash,
                    commit: TalkTurnActorOperationCommit::Release(committed.clone()),
                },
            );
        }
        *self = staged;
        Ok(committed)
    }
}

fn apply_transaction_effect(
    store: &mut DurableConversationStore,
    effect: &Value,
    written_current_turns: &mut BTreeSet<String>,
) -> Result<Option<CurrentTalkTurnRow>, DurablePostgresError> {
    let kind = required_string(effect, &["kind"], "transactionEffect.kind")?;
    match kind {
        "record-talk-turn" => {
            let conversation_id =
                required_wrapped_string(effect, &["conversationId"], "conversationId")?;
            let requested_talk_turn_epoch =
                required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?;
            let max_recorded_talk_turn_epoch = store
                .current_talk_turns
                .get(&conversation_id)
                .map(|row| row.talk_turn_epoch)
                .into_iter()
                .chain(
                    store
                        .talk_turn_actor_events
                        .iter()
                        .filter(|record| record.conversation_id == conversation_id)
                        .filter_map(|record| record.talk_turn_epoch),
                )
                .max()
                .unwrap_or(0);
            let row = CurrentTalkTurnRow {
                conversation_id,
                requesting_participant_id: required_wrapped_string(
                    effect,
                    &["requestingParticipantId"],
                    "requestingParticipantId",
                )?,
                requesting_device_id: required_wrapped_string(
                    effect,
                    &["requestingDeviceId"],
                    "requestingDeviceId",
                )?,
                target_participant_id: required_wrapped_string(
                    effect,
                    &["targetParticipantId"],
                    "targetParticipantId",
                )?,
                target_device_id: required_wrapped_string(
                    effect,
                    &["targetDeviceId"],
                    "targetDeviceId",
                )?,
                talk_turn_epoch: requested_talk_turn_epoch.max(max_recorded_talk_turn_epoch + 1),
                expires_at_ms: required_i64(effect, &["expiresAtMs"], "expiresAtMs")?,
            };
            if !written_current_turns.insert(row.conversation_id.clone()) {
                return Err(DurablePostgresError::DuplicateCurrentTalkTurnWrite(
                    row.conversation_id,
                ));
            }
            if store.current_talk_turns.contains_key(&row.conversation_id) {
                return Err(DurablePostgresError::TalkTurnRenewalRejected(
                    "current Talk Turn already active".to_owned(),
                ));
            }
            store
                .current_talk_turns
                .insert(row.conversation_id.clone(), row.clone());
            Ok(Some(row))
        }
        "clear-talk-turn" => {
            let conversation_id =
                required_wrapped_string(effect, &["conversationId"], "conversationId")?;
            let talk_turn_epoch =
                required_wrapped_u64(effect, &["talkTurnEpoch"], "talkTurnEpoch")?;
            if store
                .current_talk_turns
                .get(&conversation_id)
                .is_some_and(|row| row.talk_turn_epoch == talk_turn_epoch)
            {
                store.current_talk_turns.remove(&conversation_id);
            }
            Ok(None)
        }
        other => Err(DurablePostgresError::UnsupportedTransactionEffect(
            other.to_owned(),
        )),
    }
}

fn replay_fact(
    envelope: &KernelDecisionEnvelope,
    route: &'static str,
    decision_kind: &str,
    command_hash: String,
    operation_id: Option<String>,
    replay_id: u64,
) -> Result<KernelReplayFact, DurablePostgresError> {
    Ok(KernelReplayFact {
        replay_id,
        case_id: envelope.case_id.clone(),
        route,
        conversation_id: optional_wrapped_string(&envelope.command, &["conversationId"]),
        operation_id,
        command_hash,
        snapshot_hash: json_hash(&envelope.snapshot)?,
        decision_hash: json_hash(&envelope.decision)?,
        decision_kind: decision_kind.to_owned(),
    })
}

fn post_commit_outbox_row(
    outbox_id: u64,
    replay_id: u64,
    effect: Value,
) -> Result<PostCommitOutboxRow, DurablePostgresError> {
    Ok(PostCommitOutboxRow {
        outbox_id,
        replay_id,
        effect_kind: required_string(&effect, &["kind"], "postCommitEffect.kind")?.to_owned(),
        effect_json: effect,
        delivered: false,
    })
}

fn json_hash(value: &Value) -> Result<String, DurablePostgresError> {
    let bytes = serde_json::to_vec(value)
        .map_err(|_| DurablePostgresError::MalformedTransactionEffect("json-hash".to_owned()))?;
    Ok(sha256_hex(&bytes))
}

fn optional_array<'a>(value: &'a Value, path: &[&str]) -> Vec<&'a Value> {
    path_value(value, path)
        .and_then(Value::as_array)
        .map(|array| array.iter().collect())
        .unwrap_or_default()
}

fn required_string<'a>(
    value: &'a Value,
    path: &[&str],
    label: &'static str,
) -> Result<&'a str, DurablePostgresError> {
    path_value(value, path)
        .and_then(Value::as_str)
        .ok_or(DurablePostgresError::MissingField(label))
}

fn required_wrapped_string(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<String, DurablePostgresError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(DurablePostgresError::MissingField(label))
}

fn optional_string<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path_value(value, path).and_then(Value::as_str)
}

fn optional_wrapped_string(value: &Value, path: &[&str]) -> Option<String> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn optional_wrapped_u64(value: &Value, path: &[&str]) -> Option<u64> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_u64)
}

fn required_wrapped_u64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<u64, DurablePostgresError> {
    path_value(value, path)
        .and_then(|value| value.get("value"))
        .and_then(Value::as_u64)
        .ok_or(DurablePostgresError::MissingField(label))
}

fn required_u64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<u64, DurablePostgresError> {
    path_value(value, path)
        .and_then(Value::as_u64)
        .ok_or(DurablePostgresError::MissingField(label))
}

fn required_i64(
    value: &Value,
    path: &[&str],
    label: &'static str,
) -> Result<i64, DurablePostgresError> {
    path_value(value, path)
        .and_then(Value::as_i64)
        .ok_or(DurablePostgresError::MissingField(label))
}

fn path_value<'a>(value: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(value, |cursor, key| cursor.get(*key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProcessKernelWorker;
    use std::{path::PathBuf, sync::Mutex, time::Duration};

    static UCM_CORPUS_LOCK: Mutex<()> = Mutex::new(());

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|path| path.parent())
            .and_then(|path| path.parent())
            .expect("runtime crate should live under backend/runtime")
            .to_path_buf()
    }

    fn kernel_corpus() -> crate::KernelWorkerResponse {
        let _guard = UCM_CORPUS_LOCK
            .lock()
            .expect("UCM corpus test lock should not be poisoned");
        ProcessKernelWorker::unison_corpus_worker(repo_root())
            .request_corpus(Duration::from_secs(20))
            .expect("kernel corpus worker should return JSON")
    }

    #[test]
    fn kernel_process_command_config_can_skip_direnv_for_packaged_runtime() {
        let config = KernelProcessCommandConfig {
            use_direnv: false,
            ucm_command: "/usr/local/bin/ucm".to_owned(),
            run_mode: KernelProcessRunMode::Source,
        };
        let mut command = config.command();
        config.append_run_args(&mut command, "bb/main:.entry", "entry", "{}");

        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect();
        assert_eq!(
            command.get_program().to_string_lossy(),
            "/usr/local/bin/ucm"
        );
        assert_eq!(args, vec!["run", "bb/main:.entry", "{}"]);
    }

    #[test]
    fn kernel_process_command_config_defaults_to_direnv_wrapped_ucm() {
        let config = KernelProcessCommandConfig {
            use_direnv: true,
            ucm_command: "ucm".to_owned(),
            run_mode: KernelProcessRunMode::Source,
        };
        let mut command = config.command();
        config.append_run_args(&mut command, "bb/main:.entry", "entry", "{}");

        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect();
        assert_eq!(command.get_program().to_string_lossy(), "direnv");
        assert_eq!(
            args,
            vec!["exec", ".", "ucm", "run", "bb/main:.entry", "{}"]
        );
    }

    #[test]
    fn kernel_process_command_config_can_run_compiled_artifacts() {
        let config = KernelProcessCommandConfig {
            use_direnv: false,
            ucm_command: "/usr/local/bin/ucm".to_owned(),
            run_mode: KernelProcessRunMode::Compiled {
                artifact_dir: PathBuf::from("/app/kernel"),
            },
        };
        let mut command = config.command();
        config.append_run_args(&mut command, "bb/main:.entry", "request-talk-turn", "{}");

        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect();
        assert_eq!(
            command.get_program().to_string_lossy(),
            "/usr/local/bin/ucm"
        );
        assert_eq!(
            args,
            vec!["run.compiled", "/app/kernel/request-talk-turn.uc", "{}"]
        );
    }

    #[test]
    fn kernel_process_command_config_can_run_resident_compiled_artifact() {
        let config = KernelProcessCommandConfig {
            use_direnv: false,
            ucm_command: "/usr/local/bin/ucm".to_owned(),
            run_mode: KernelProcessRunMode::Compiled {
                artifact_dir: PathBuf::from("/app/kernel"),
            },
        };
        let mut command = config.command();
        config.append_resident_args(
            &mut command,
            "bb/main:.beepbeep.worker.resident.printDecisionJson",
            "resident-kernel-worker",
        );

        let args: Vec<String> = command
            .get_args()
            .map(|arg| arg.to_string_lossy().to_string())
            .collect();
        assert_eq!(
            command.get_program().to_string_lossy(),
            "/usr/local/bin/ucm"
        );
        assert_eq!(
            args,
            vec!["run.compiled", "/app/kernel/resident-kernel-worker.uc"]
        );
    }

    fn request_command() -> Value {
        serde_json::json!({
            "kind": "request-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "requestingParticipantId": { "value": "participant-a" },
            "requestingDeviceId": { "value": "device-a" },
            "requestingSessionEpoch": { "value": 0 },
            "targetParticipantId": { "value": "participant-b" },
            "operationId": "op-sql-snapshot",
            "policyVersion": { "value": "policy-v1" },
            "kernelVersion": { "value": "kernel-contract-v1" }
        })
    }

    fn snapshot_row(participant_id: &str, device_id: &str) -> SnapshotSqlRow {
        SnapshotSqlRow {
            conversation_id: "conversation-1".to_owned(),
            conversation_seq: 42,
            policy_version: "policy-v1".to_owned(),
            participant_id: participant_id.to_owned(),
            device_id: Some(device_id.to_owned()),
            session_epoch: Some(if participant_id == "participant-a" {
                0
            } else {
                7
            }),
            last_seen_ms: Some(10_000),
            presence_observed_at_ms: Some(10_000),
            readiness_session_epoch: (participant_id == "participant-b").then_some(7),
            readiness_observed_at_ms: (participant_id == "participant-b").then_some(10_000),
            wake_observed_at_ms: None,
            current_requesting_participant_id: None,
            current_requesting_device_id: None,
            current_target_participant_id: None,
            current_target_device_id: None,
            talk_turn_epoch: None,
            expires_at_ms: None,
        }
    }

    #[test]
    fn request_talk_turn_postgres_snapshot_loader_builds_kernel_input_from_sql_rows() {
        let input = build_request_talk_turn_input_from_snapshot_rows(
            request_command(),
            10_000,
            &SnapshotPolicyConfig::default(),
            vec![
                snapshot_row("participant-a", "device-a"),
                snapshot_row("participant-b", "device-b"),
            ],
        )
        .expect("SQL rows should build kernel input");

        assert_eq!(input.snapshot["conversationId"]["value"], "conversation-1");
        assert_eq!(input.snapshot["participants"].as_array().unwrap().len(), 2);
        assert_eq!(
            input.snapshot["runtimeSessions"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            input.snapshot["devicePresence"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            input.snapshot["targetDeviceAudioReadiness"][0]["kind"],
            "foreground-audio-ready"
        );
        assert_eq!(input.snapshot["currentTalkTurn"]["kind"], "none");
        assert_eq!(input.snapshot["conversationSeq"]["value"], 42);
        assert_eq!(input.snapshot["snapshotBuiltAtMs"], 10_000);
        assert_eq!(input.policy["policyVersion"]["value"], "policy-v1");
        assert_eq!(input.policy["maxTalkTurnLeaseMs"], 15_000);
    }

    #[test]
    fn request_talk_turn_postgres_snapshot_loader_includes_current_talk_turn() {
        let mut row_a = snapshot_row("participant-a", "device-a");
        row_a.current_requesting_participant_id = Some("participant-a".to_owned());
        row_a.current_requesting_device_id = Some("device-a".to_owned());
        row_a.current_target_participant_id = Some("participant-b".to_owned());
        row_a.current_target_device_id = Some("device-b".to_owned());
        row_a.talk_turn_epoch = Some(4);
        row_a.expires_at_ms = Some(25_000);

        let input = build_request_talk_turn_input_from_snapshot_rows(
            request_command(),
            10_000,
            &SnapshotPolicyConfig::default(),
            vec![row_a, snapshot_row("participant-b", "device-b")],
        )
        .expect("SQL rows should build current Talk Turn");

        assert_eq!(input.snapshot["currentTalkTurn"]["kind"], "current");
        assert_eq!(
            input.snapshot["currentTalkTurn"]["speakerParticipantId"]["value"],
            "participant-a"
        );
        assert_eq!(
            input.snapshot["currentTalkTurn"]["talkTurnEpoch"]["value"],
            4
        );
        assert_eq!(input.snapshot["currentTalkTurn"]["expiresAtMs"], 25_000);
    }

    #[test]
    fn request_talk_turn_postgres_snapshot_loader_rejects_negative_sql_values() {
        let mut row = snapshot_row("participant-a", "device-a");
        row.conversation_seq = -1;

        let err = build_request_talk_turn_input_from_snapshot_rows(
            request_command(),
            10_000,
            &SnapshotPolicyConfig::default(),
            vec![row],
        )
        .expect_err("negative SQL values should not enter kernel JSON");

        assert!(matches!(
            err,
            DurablePostgresError::NegativeSnapshotValue {
                field: "conversation_seq",
                value: -1
            }
        ));
    }

    #[test]
    fn request_talk_turn_postgres_replays_kernel_corpus_effects() {
        let response = kernel_corpus();
        let mut granted = 0;
        let mut denied = 0;
        let mut replayed = 0;

        for case in response
            .corpus
            .cases
            .iter()
            .filter(|case| case.kind == KernelCommandKind::RequestTalkTurn)
        {
            let mut store = DurableConversationStore::default();
            let committed = store
                .execute_request_talk_turn_case(case)
                .expect("request talk-turn corpus case should commit");
            if committed.replay_fact.decision_kind == "granted" {
                granted += 1;
                assert!(
                    committed
                        .outbox_rows
                        .iter()
                        .any(|row| row.effect_kind == "notify-talk-turn-granted"
                            || row.effect_kind == "wake-target-device")
                );
                let conversation_id =
                    required_wrapped_string(&case.command, &["conversationId"], "conversationId")
                        .expect("case should include conversation id");
                assert!(store.current_talk_turn(&conversation_id).is_some());
            } else {
                denied += 1;
                assert!(committed.outbox_rows.is_empty());
            }
            assert_eq!(store.replay_facts().len(), 1);
            assert_eq!(store.replay_facts()[0], committed.replay_fact);
            assert_eq!(store.post_commit_outbox(), committed.outbox_rows);
            replayed += 1;
        }

        assert!(granted >= 1);
        assert!(denied >= 1);
        assert_eq!(replayed, granted + denied);
    }

    #[test]
    fn request_talk_turn_postgres_runtime_loads_snapshot_calls_kernel_and_commits_effects() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let snapshot_loader = InMemoryRequestTalkTurnSnapshotLoader::from_cases([case]);
        let kernel_worker = CorpusKernelDecisionWorker::new(&response.corpus);
        let runtime = RequestTalkTurnRuntime::new(snapshot_loader, kernel_worker);
        let mut store = DurableConversationStore::default();

        let committed = runtime
            .execute(&mut store, case.command.clone())
            .expect("runtime request route should commit");

        assert_eq!(committed.replay_fact.case_id, case.id);
        assert_eq!(committed.replay_fact.route, REQUEST_TALK_TURN_ROUTE);
        assert_eq!(committed.replay_fact.decision_kind, "granted");
        assert_eq!(store.replay_facts(), &[committed.replay_fact]);
        assert_eq!(store.post_commit_outbox(), committed.outbox_rows);
        let conversation_id =
            required_wrapped_string(&case.command, &["conversationId"], "conversationId")
                .expect("case should include conversation id");
        assert!(store.current_talk_turn(&conversation_id).is_some());
    }

    #[test]
    fn request_talk_turn_postgres_process_worker_calls_unison_entrypoint() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let worker = ProcessRequestTalkTurnKernelWorker::new(repo_root(), Duration::from_secs(20));
        let decision = {
            let _guard = UCM_CORPUS_LOCK
                .lock()
                .expect("UCM worker test lock should not be poisoned");
            worker
                .decide_request_talk_turn(&RequestTalkTurnKernelInput {
                    command: case.command.clone(),
                    snapshot: case.snapshot.clone(),
                    policy: case.policy.clone(),
                })
                .expect("process worker should invoke Unison request-talk-turn worker")
        };

        assert_eq!(decision.command, case.command);
        assert_eq!(decision.snapshot, case.snapshot);
        assert_eq!(decision.decision, case.expected_decision);
        let audits = worker.invocation_audits();
        assert_eq!(audits.len(), 1);
        let audit = &audits[0];
        assert_eq!(audit.command_hash, json_hash(&case.command).unwrap());
        assert_eq!(audit.snapshot_hash, json_hash(&case.snapshot).unwrap());
        assert_eq!(audit.policy_hash, json_hash(&case.policy).unwrap());
        assert_eq!(audit.decision_kind.as_deref(), Some("granted"));
        assert_eq!(audit.outcome, KernelInvocationOutcome::Success);
        assert_eq!(
            audit
                .response_hash
                .as_ref()
                .expect("response hash exists")
                .len(),
            64
        );
        assert_eq!(audit.request_hash.len(), 64);
    }

    #[test]
    fn request_talk_turn_postgres_process_worker_decodes_non_fixture_operation_id() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let mut command = case.command.clone();
        command["operationId"] = serde_json::json!("op-decoded-outside-corpus");
        let worker = ProcessRequestTalkTurnKernelWorker::new(repo_root(), Duration::from_secs(20));
        let decision = {
            let _guard = UCM_CORPUS_LOCK
                .lock()
                .expect("UCM worker test lock should not be poisoned");
            worker
                .decide_request_talk_turn(&RequestTalkTurnKernelInput {
                    command: command.clone(),
                    snapshot: case.snapshot.clone(),
                    policy: case.policy.clone(),
                })
                .expect("process worker should decode arbitrary valid command JSON")
        };

        assert_eq!(decision.command, command);
        assert_eq!(decision.decision["kind"], "granted");
        assert_eq!(
            decision.decision["effectPlan"]["transactionEffects"][0]["kind"],
            "record-talk-turn"
        );
    }

    #[test]
    fn release_talk_turn_postgres_process_worker_calls_unison_entrypoint() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::ReleaseTalkTurn
                    && case.id == "stale-release-talk-turn-denies"
            })
            .expect("corpus should include stale release case");
        let worker = ProcessRequestTalkTurnKernelWorker::new(repo_root(), Duration::from_secs(20));
        let decision = {
            let _guard = UCM_CORPUS_LOCK
                .lock()
                .expect("UCM worker test lock should not be poisoned");
            worker
                .decide_release_talk_turn(&RequestTalkTurnKernelInput {
                    command: case.command.clone(),
                    snapshot: case.snapshot.clone(),
                    policy: case.policy.clone(),
                })
                .expect("process worker should invoke Unison release-talk-turn worker")
        };

        assert_eq!(decision.command, case.command);
        assert_eq!(decision.snapshot, case.snapshot);
        assert_eq!(decision.decision, case.expected_decision);
        assert_eq!(decision.case_id, "unison-release-talk-turn-worker");
    }

    #[test]
    fn request_talk_turn_postgres_resident_worker_handles_request_and_release() {
        let response = kernel_corpus();
        let request_case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let release_case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::ReleaseTalkTurn
                    && case.id == "stale-release-talk-turn-denies"
            })
            .expect("corpus should include stale release case");
        let _guard = UCM_CORPUS_LOCK
            .lock()
            .expect("UCM resident worker test lock should not be poisoned");
        let worker = ResidentRequestTalkTurnKernelWorker::with_command_config(
            repo_root(),
            Duration::from_secs(20),
            KernelProcessCommandConfig {
                use_direnv: true,
                ucm_command: "ucm".to_owned(),
                run_mode: KernelProcessRunMode::Source,
            },
        );

        let request_decision = worker
            .decide_request_talk_turn(&RequestTalkTurnKernelInput {
                command: request_case.command.clone(),
                snapshot: request_case.snapshot.clone(),
                policy: request_case.policy.clone(),
            })
            .expect("resident worker should invoke Unison request-talk-turn worker");
        let release_decision = worker
            .decide_release_talk_turn(&RequestTalkTurnKernelInput {
                command: release_case.command.clone(),
                snapshot: release_case.snapshot.clone(),
                policy: release_case.policy.clone(),
            })
            .expect("resident worker should invoke Unison release-talk-turn worker");

        assert_eq!(request_decision.decision, request_case.expected_decision);
        assert_eq!(
            request_decision.case_id,
            "unison-resident-request-talk-turn-worker"
        );
        assert_eq!(release_decision.decision, release_case.expected_decision);
        assert_eq!(
            release_decision.case_id,
            "unison-resident-release-talk-turn-worker"
        );
        let audits = worker.invocation_audits();
        assert_eq!(audits.len(), 2);
        assert_eq!(audits[0].outcome, KernelInvocationOutcome::Success);
        assert_eq!(audits[1].outcome, KernelInvocationOutcome::Success);
        assert_eq!(audits[0].decision_kind.as_deref(), Some("granted"));
        assert_eq!(audits[1].decision_kind.as_deref(), Some("denied"));
    }

    #[test]
    fn request_talk_turn_postgres_runtime_fails_closed_when_snapshot_is_missing() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| case.kind == KernelCommandKind::RequestTalkTurn)
            .expect("corpus should include request case");
        let runtime = RequestTalkTurnRuntime::new(
            InMemoryRequestTalkTurnSnapshotLoader::default(),
            CorpusKernelDecisionWorker::new(&response.corpus),
        );
        let mut store = DurableConversationStore::default();

        let err = runtime
            .execute(&mut store, case.command.clone())
            .expect_err("missing snapshot should fail closed");

        assert!(matches!(err, DurablePostgresError::SnapshotNotFound));
        assert!(store.replay_facts().is_empty());
        assert!(store.post_commit_outbox().is_empty());
    }

    #[test]
    fn request_talk_turn_postgres_runtime_fails_closed_when_kernel_worker_has_no_decision() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| case.kind == KernelCommandKind::RequestTalkTurn)
            .expect("corpus should include request case");
        let mut altered = case.clone();
        altered.snapshot["snapshotBuiltAtMs"] = serde_json::json!(123456789);
        let runtime = RequestTalkTurnRuntime::new(
            InMemoryRequestTalkTurnSnapshotLoader::from_cases([&altered]),
            CorpusKernelDecisionWorker::new(&response.corpus),
        );
        let mut store = DurableConversationStore::default();

        let err = runtime
            .execute(&mut store, altered.command.clone())
            .expect_err("unknown kernel input should fail closed");

        assert!(matches!(err, DurablePostgresError::KernelDecisionNotFound));
        assert!(store.replay_facts().is_empty());
        assert!(store.post_commit_outbox().is_empty());
    }

    #[test]
    fn request_talk_turn_postgres_rejects_non_request_command() {
        let response = kernel_corpus();
        let release = response
            .corpus
            .cases
            .iter()
            .find(|case| case.kind == KernelCommandKind::ReleaseTalkTurn)
            .expect("corpus should include release case");
        let mut store = DurableConversationStore::default();
        let err = store.execute_request_talk_turn_case(release).unwrap_err();

        assert!(matches!(
            err,
            DurablePostgresError::UnsupportedCommand {
                route: REQUEST_TALK_TURN_ROUTE,
                kind: KernelCommandKind::ReleaseTalkTurn
            }
        ));
        assert!(store.replay_facts().is_empty());
    }

    #[test]
    fn request_talk_turn_postgres_replays_same_operation_id_idempotently() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let mut store = DurableConversationStore::default();

        let first = store
            .execute_request_talk_turn_case(case)
            .expect("first request should commit");
        let second = store
            .execute_request_talk_turn_case(case)
            .expect("same operation should replay committed result");

        assert_eq!(first, second);
        assert_eq!(store.replay_facts().len(), 1);
        assert_eq!(store.post_commit_outbox().len(), first.outbox_rows.len());
    }

    #[test]
    fn request_talk_turn_postgres_rejects_same_operation_id_with_different_command() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
            })
            .expect("corpus should include granted request case");
        let mut conflicting = case.clone();
        conflicting.command["requestingDeviceId"]["value"] = serde_json::json!("device-conflict");
        let mut store = DurableConversationStore::default();

        store
            .execute_request_talk_turn_case(case)
            .expect("first request should commit");
        let err = store
            .execute_request_talk_turn_case(&conflicting)
            .expect_err("same operation id with a different command should fail");

        assert!(matches!(
            err,
            DurablePostgresError::IdempotencyConflict {
                route: REQUEST_TALK_TURN_ROUTE,
                operation_id
            } if operation_id == "op-1"
        ));
        assert_eq!(store.replay_facts().len(), 1);
    }

    #[test]
    fn request_talk_turn_postgres_keeps_post_commit_effects_after_transaction() {
        let case = KernelCorpusCase {
            id: "bad-effect".to_owned(),
            kind: KernelCommandKind::RequestTalkTurn,
            command: serde_json::json!({
                "kind": "request-talk-turn",
                "conversationId": { "value": "conversation-1" }
            }),
            snapshot: serde_json::json!({ "conversationId": { "value": "conversation-1" } }),
            policy: serde_json::json!({}),
            expected_decision: serde_json::json!({
                "kind": "granted",
                "effectPlan": {
                    "transactionEffects": [
                        { "kind": "unsupported-write", "conversationId": { "value": "conversation-1" } }
                    ],
                    "postCommitEffects": [
                        { "kind": "notify-talk-turn-granted" }
                    ]
                }
            }),
        };
        let mut store = DurableConversationStore::default();

        let err = store.execute_request_talk_turn_case(&case).unwrap_err();

        assert!(matches!(
            err,
            DurablePostgresError::UnsupportedTransactionEffect(kind) if kind == "unsupported-write"
        ));
        assert!(store.replay_facts().is_empty());
        assert!(store.post_commit_outbox().is_empty());
        assert!(store.current_talk_turn("conversation-1").is_none());
    }

    #[test]
    fn request_talk_turn_postgres_dispatches_post_commit_effects_after_commit() {
        let response = kernel_corpus();
        let case = response
            .corpus
            .cases
            .iter()
            .find(|case| {
                case.kind == KernelCommandKind::RequestTalkTurn
                    && case.expected_decision["kind"] == "granted"
                    && !optional_array(
                        &case.expected_decision,
                        &["effectPlan", "postCommitEffects"],
                    )
                    .is_empty()
            })
            .expect("corpus should include granted request case with post-commit effects");
        let mut store = DurableConversationStore::default();
        let committed = store
            .execute_request_talk_turn_case(case)
            .expect("request should commit before post-commit dispatch");
        let mut sink = RecordingPostCommitEffectSink::default();

        assert!(store.post_commit_outbox().iter().all(|row| !row.delivered));
        let delivered = store
            .deliver_committed_post_commit_effects(&committed, &mut sink)
            .expect("post-commit effects should dispatch after commit");

        assert_eq!(delivered.len(), committed.outbox_rows.len());
        assert_eq!(sink.delivered(), committed.outbox_rows.as_slice());
        assert!(sink.actions().iter().any(|action| matches!(
            action,
            DeliveredPostCommitEffect::NotifyTalkTurnGranted { .. }
                | DeliveredPostCommitEffect::WakeTargetDevice { .. }
        )));
        assert!(sink.side_effects().iter().any(|effect| matches!(
            effect,
            RuntimeSideEffect::WebSocketNotifyTalkTurnGranted { .. }
                | RuntimeSideEffect::ApnsWakeTargetDevice { .. }
        )));
        assert!(
            sink.side_effects()
                .iter()
                .any(|effect| matches!(effect, RuntimeSideEffect::DiagnosticEvent { .. }))
        );
        assert!(delivered.iter().all(|row| row.delivered));
        assert!(store.post_commit_outbox().iter().all(|row| row.delivered));
        let replay = store
            .execute_request_talk_turn_case(case)
            .expect("same operation should replay committed result");
        assert!(replay.outbox_rows.iter().all(|row| row.delivered));
    }

    #[test]
    fn request_talk_turn_postgres_decodes_known_post_commit_effects() {
        let rows = [
            PostCommitOutboxRow {
                outbox_id: 1,
                replay_id: 1,
                effect_kind: "notify-talk-turn-granted".to_owned(),
                effect_json: serde_json::json!({
                    "kind": "notify-talk-turn-granted",
                    "conversationId": { "value": "conversation-1" },
                    "requestingParticipantId": { "value": "participant-a" },
                    "requestingDeviceId": { "value": "device-a" },
                    "targetParticipantId": { "value": "participant-b" },
                    "targetDeviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 7 }
                }),
                delivered: false,
            },
            PostCommitOutboxRow {
                outbox_id: 2,
                replay_id: 1,
                effect_kind: "wake-target-device".to_owned(),
                effect_json: serde_json::json!({
                    "kind": "wake-target-device",
                    "conversationId": { "value": "conversation-1" },
                    "participantId": { "value": "participant-b" },
                    "deviceId": { "value": "device-b" },
                    "talkTurnEpoch": { "value": 7 }
                }),
                delivered: false,
            },
            PostCommitOutboxRow {
                outbox_id: 3,
                replay_id: 1,
                effect_kind: "notify-talk-turn-released".to_owned(),
                effect_json: serde_json::json!({
                    "kind": "notify-talk-turn-released",
                    "conversationId": { "value": "conversation-1" },
                    "participantId": { "value": "participant-a" },
                    "deviceId": { "value": "device-a" },
                    "talkTurnEpoch": { "value": 7 }
                }),
                delivered: false,
            },
        ];

        assert!(matches!(
            decode_post_commit_effect(&rows[0]).expect("grant notification should decode"),
            DeliveredPostCommitEffect::NotifyTalkTurnGranted {
                conversation_id,
                talk_turn_epoch: 7,
                ..
            } if conversation_id == "conversation-1"
        ));
        assert!(matches!(
            decode_post_commit_effect(&rows[1]).expect("wake target should decode"),
            DeliveredPostCommitEffect::WakeTargetDevice {
                participant_id,
                device_id,
                talk_turn_epoch: 7,
                ..
            } if participant_id == "participant-b" && device_id == "device-b"
        ));
        assert!(matches!(
            decode_post_commit_effect(&rows[2]).expect("release notification should decode"),
            DeliveredPostCommitEffect::NotifyTalkTurnReleased {
                participant_id,
                device_id,
                talk_turn_epoch: 7,
                ..
            } if participant_id == "participant-a" && device_id == "device-a"
        ));
    }

    #[test]
    fn request_talk_turn_postgres_plans_runtime_side_effects_from_typed_actions() {
        let grant = DeliveredPostCommitEffect::NotifyTalkTurnGranted {
            conversation_id: "conversation-1".to_owned(),
            requesting_participant_id: "participant-a".to_owned(),
            requesting_device_id: "device-a".to_owned(),
            target_participant_id: "participant-b".to_owned(),
            target_device_id: "device-b".to_owned(),
            talk_turn_epoch: 7,
        };
        let wake = DeliveredPostCommitEffect::WakeTargetDevice {
            conversation_id: "conversation-1".to_owned(),
            participant_id: "participant-b".to_owned(),
            device_id: "device-b".to_owned(),
            talk_turn_epoch: 7,
        };
        let release = DeliveredPostCommitEffect::NotifyTalkTurnReleased {
            conversation_id: "conversation-1".to_owned(),
            participant_id: "participant-a".to_owned(),
            device_id: "device-a".to_owned(),
            talk_turn_epoch: 7,
        };

        assert_eq!(
            plan_runtime_side_effects(&grant),
            vec![
                RuntimeSideEffect::WebSocketNotifyTalkTurnGranted {
                    conversation_id: "conversation-1".to_owned(),
                    requesting_participant_id: "participant-a".to_owned(),
                    requesting_device_id: "device-a".to_owned(),
                    target_participant_id: "participant-b".to_owned(),
                    target_device_id: "device-b".to_owned(),
                    talk_turn_epoch: 7,
                },
                RuntimeSideEffect::DiagnosticEvent {
                    conversation_id: "conversation-1".to_owned(),
                    event_kind: "talk-turn-granted".to_owned(),
                    talk_turn_epoch: 7,
                },
            ]
        );
        assert_eq!(
            plan_runtime_side_effects(&wake),
            vec![
                RuntimeSideEffect::ApnsWakeTargetDevice {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-b".to_owned(),
                    device_id: "device-b".to_owned(),
                    talk_turn_epoch: 7,
                },
                RuntimeSideEffect::DiagnosticEvent {
                    conversation_id: "conversation-1".to_owned(),
                    event_kind: "target-device-wake-requested".to_owned(),
                    talk_turn_epoch: 7,
                },
            ]
        );
        assert_eq!(
            plan_runtime_side_effects(&release),
            vec![
                RuntimeSideEffect::WebSocketNotifyTalkTurnReleased {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-a".to_owned(),
                    device_id: "device-a".to_owned(),
                    talk_turn_epoch: 7,
                },
                RuntimeSideEffect::DiagnosticEvent {
                    conversation_id: "conversation-1".to_owned(),
                    event_kind: "talk-turn-released".to_owned(),
                    talk_turn_epoch: 7,
                },
            ]
        );
    }

    #[test]
    fn talk_turn_actor_events_commit_idempotently_and_plan_renewal_side_effects() {
        let mut store = DurableConversationStore::default();
        let owner = ConversationOwner {
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 4,
            lease_expires_at_ms: 60_000,
        };
        let events = [DurableTalkTurnEvent {
            event_id: 1,
            kind: DurableTalkTurnEventKind::Renewed,
            talk_turn_epoch: Some(7),
            operation_id: Some("renew-1".to_owned()),
        }];

        let first = store
            .commit_talk_turn_actor_events("conversation-1", &owner, &events)
            .expect("actor event should commit");
        let second = store
            .commit_talk_turn_actor_events("conversation-1", &owner, &events)
            .expect("same actor event should replay idempotently");

        assert_eq!(first, second);
        assert_eq!(store.talk_turn_actor_events().len(), 1);
        assert_eq!(first[0].event_kind, "talk-turn-renewed");
        assert_eq!(first[0].event_json["operationId"], "renew-1");
        assert_eq!(
            plan_talk_turn_actor_event_side_effects(&first[0]),
            vec![
                RuntimeSideEffect::WebSocketNotifyTalkTurnRenewed {
                    conversation_id: "conversation-1".to_owned(),
                    talk_turn_epoch: 7,
                },
                RuntimeSideEffect::DiagnosticEvent {
                    conversation_id: "conversation-1".to_owned(),
                    event_kind: "talk-turn-renewed".to_owned(),
                    talk_turn_epoch: 7,
                },
            ]
        );
    }

    #[test]
    fn talk_turn_actor_release_committer_plans_release_side_effects() {
        let mut store = DurableConversationStore::default();
        store.current_talk_turns.insert(
            "conversation-1".to_owned(),
            CurrentTalkTurnRow {
                conversation_id: "conversation-1".to_owned(),
                requesting_participant_id: "participant-a".to_owned(),
                requesting_device_id: "device-a".to_owned(),
                target_participant_id: "participant-b".to_owned(),
                target_device_id: "device-b".to_owned(),
                talk_turn_epoch: 7,
                expires_at_ms: 25_000,
            },
        );
        let command = serde_json::json!({
            "kind": "release-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "participantId": { "value": "participant-a" },
            "deviceId": { "value": "device-a" },
            "talkTurnEpoch": { "value": 7 },
            "operationId": "release-7",
            "ownerRuntimeId": "runtime-a",
            "ownerEpoch": { "value": 4 },
            "ownerLeaseExpiresAtMs": 60_000
        });

        let committed = store
            .release_talk_turn(&command)
            .expect("actor release should commit");

        assert!(store.current_talk_turn("conversation-1").is_none());
        assert_eq!(committed.actor_events.len(), 1);
        assert_eq!(committed.actor_events[0].event_kind, "talk-turn-released");
        assert_eq!(
            committed.side_effects,
            vec![
                RuntimeSideEffect::WebSocketNotifyTalkTurnReleased {
                    conversation_id: "conversation-1".to_owned(),
                    participant_id: "participant-a".to_owned(),
                    device_id: "device-a".to_owned(),
                    talk_turn_epoch: 7,
                },
                RuntimeSideEffect::DiagnosticEvent {
                    conversation_id: "conversation-1".to_owned(),
                    event_kind: "talk-turn-released".to_owned(),
                    talk_turn_epoch: 7,
                },
            ]
        );
    }

    #[test]
    fn talk_turn_actor_release_replays_same_operation_id_idempotently() {
        let mut store = DurableConversationStore::default();
        store.current_talk_turns.insert(
            "conversation-1".to_owned(),
            CurrentTalkTurnRow {
                conversation_id: "conversation-1".to_owned(),
                requesting_participant_id: "participant-a".to_owned(),
                requesting_device_id: "device-a".to_owned(),
                target_participant_id: "participant-b".to_owned(),
                target_device_id: "device-b".to_owned(),
                talk_turn_epoch: 7,
                expires_at_ms: 25_000,
            },
        );
        let command = serde_json::json!({
            "kind": "release-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "participantId": { "value": "participant-a" },
            "deviceId": { "value": "device-a" },
            "talkTurnEpoch": { "value": 7 },
            "operationId": "release-7",
            "ownerRuntimeId": "runtime-a",
            "ownerEpoch": { "value": 4 },
            "ownerLeaseExpiresAtMs": 60_000
        });

        let first = store
            .release_talk_turn(&command)
            .expect("first release should commit");
        let second = store
            .release_talk_turn(&command)
            .expect("duplicate release should replay after current turn is gone");

        assert_eq!(first, second);
        assert!(store.current_talk_turn("conversation-1").is_none());
        assert_eq!(store.talk_turn_actor_events().len(), 1);
    }

    #[test]
    fn talk_turn_actor_renew_rejects_same_operation_id_with_different_command() {
        let mut store = DurableConversationStore::default();
        store.current_talk_turns.insert(
            "conversation-1".to_owned(),
            CurrentTalkTurnRow {
                conversation_id: "conversation-1".to_owned(),
                requesting_participant_id: "participant-a".to_owned(),
                requesting_device_id: "device-a".to_owned(),
                target_participant_id: "participant-b".to_owned(),
                target_device_id: "device-b".to_owned(),
                talk_turn_epoch: 7,
                expires_at_ms: 25_000,
            },
        );
        let command = serde_json::json!({
            "kind": "renew-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "participantId": { "value": "participant-a" },
            "deviceId": { "value": "device-a" },
            "talkTurnEpoch": { "value": 7 },
            "operationId": "renew-7",
            "nowMs": 20_000,
            "policyVersion": { "value": "policy-v1" },
            "maxTalkTurnLeaseMs": 15_000,
            "grantsEnabled": true,
            "ownerRuntimeId": "runtime-a",
            "ownerEpoch": { "value": 4 },
            "ownerLeaseExpiresAtMs": 60_000
        });
        let mut conflicting = command.clone();
        conflicting["nowMs"] = Value::from(21_000);

        store
            .renew_talk_turn(&command)
            .expect("first renewal should commit");
        let err = store
            .renew_talk_turn(&conflicting)
            .expect_err("same operation with different command should fail closed");

        assert!(matches!(
            err,
            DurablePostgresError::IdempotencyConflict {
                route: RENEW_TALK_TURN_ROUTE,
                operation_id
            } if operation_id == "renew-7"
        ));
        assert_eq!(store.talk_turn_actor_events().len(), 1);
    }

    #[test]
    fn talk_turn_actor_event_commit_rejects_conflicting_replay() {
        let mut store = DurableConversationStore::default();
        let owner = ConversationOwner {
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 4,
            lease_expires_at_ms: 60_000,
        };
        let original = [DurableTalkTurnEvent {
            event_id: 1,
            kind: DurableTalkTurnEventKind::Renewed,
            talk_turn_epoch: Some(7),
            operation_id: Some("renew-1".to_owned()),
        }];
        let conflicting = [DurableTalkTurnEvent {
            event_id: 1,
            kind: DurableTalkTurnEventKind::Released,
            talk_turn_epoch: Some(7),
            operation_id: Some("release-1".to_owned()),
        }];

        store
            .commit_talk_turn_actor_events("conversation-1", &owner, &original)
            .expect("original actor event should commit");
        let err = store
            .commit_talk_turn_actor_events("conversation-1", &owner, &conflicting)
            .expect_err("conflicting actor event replay should fail closed");

        assert!(matches!(
            err,
            DurablePostgresError::ActorEventConflict {
                conversation_id,
                owner_epoch: 4,
                actor_event_id: 1
            } if conversation_id == "conversation-1"
        ));
        assert_eq!(store.talk_turn_actor_events().len(), 1);
    }

    #[test]
    fn request_talk_turn_postgres_does_not_mark_unknown_post_commit_effect_delivered() {
        let case = KernelCorpusCase {
            id: "unknown-post-commit".to_owned(),
            kind: KernelCommandKind::RequestTalkTurn,
            command: serde_json::json!({
                "kind": "request-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "operationId": "unknown-post-commit"
            }),
            snapshot: serde_json::json!({ "conversationId": { "value": "conversation-1" } }),
            policy: serde_json::json!({}),
            expected_decision: serde_json::json!({
                "kind": "denied",
                "effectPlan": {
                    "transactionEffects": [],
                    "postCommitEffects": [
                        { "kind": "unknown-post-commit-effect" }
                    ]
                }
            }),
        };
        let mut store = DurableConversationStore::default();
        let committed = store
            .execute_request_talk_turn_case(&case)
            .expect("unknown post-commit effect should not block DB commit");
        let mut sink = RecordingPostCommitEffectSink::default();

        let err = store
            .deliver_committed_post_commit_effects(&committed, &mut sink)
            .expect_err("unknown post-commit effect should fail closed at delivery");

        assert!(matches!(
            err,
            DurablePostgresError::UnsupportedPostCommitEffect(kind)
                if kind == "unknown-post-commit-effect"
        ));
        assert!(sink.delivered().is_empty());
        assert!(store.post_commit_outbox().iter().all(|row| !row.delivered));
    }

    #[test]
    fn request_talk_turn_postgres_clear_talk_turn_is_epoch_fenced() {
        let mut store = DurableConversationStore::default();
        store.current_talk_turns.insert(
            "conversation-1".to_owned(),
            CurrentTalkTurnRow {
                conversation_id: "conversation-1".to_owned(),
                requesting_participant_id: "participant-a".to_owned(),
                requesting_device_id: "device-a".to_owned(),
                target_participant_id: "participant-b".to_owned(),
                target_device_id: "device-b".to_owned(),
                talk_turn_epoch: 9,
                expires_at_ms: 30_000,
            },
        );
        let stale_release = serde_json::json!({
            "kind": "clear-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "talkTurnEpoch": { "value": 8 }
        });
        let current_release = serde_json::json!({
            "kind": "clear-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "talkTurnEpoch": { "value": 9 }
        });
        let mut written_current_turns = BTreeSet::new();

        apply_transaction_effect(&mut store, &stale_release, &mut written_current_turns)
            .expect("stale clear effect should be a no-op");
        assert_eq!(
            store
                .current_talk_turn("conversation-1")
                .expect("current turn should remain after stale release")
                .talk_turn_epoch,
            9
        );

        apply_transaction_effect(&mut store, &current_release, &mut written_current_turns)
            .expect("matching clear effect should remove current turn");
        assert!(store.current_talk_turn("conversation-1").is_none());
    }

    #[test]
    fn request_talk_turn_postgres_rolls_back_duplicate_current_turn_writes() {
        let duplicate_record = serde_json::json!({
            "kind": "record-talk-turn",
            "conversationId": { "value": "conversation-1" },
            "requestingParticipantId": { "value": "participant-a" },
            "requestingDeviceId": { "value": "device-a" },
            "targetParticipantId": { "value": "participant-b" },
            "targetDeviceId": { "value": "device-b" },
            "talkTurnEpoch": { "value": 1 },
            "expiresAtMs": 25000
        });
        let case = KernelCorpusCase {
            id: "duplicate-current-write".to_owned(),
            kind: KernelCommandKind::RequestTalkTurn,
            command: serde_json::json!({
                "kind": "request-talk-turn",
                "conversationId": { "value": "conversation-1" },
                "operationId": "duplicate-current-write"
            }),
            snapshot: serde_json::json!({ "conversationId": { "value": "conversation-1" } }),
            policy: serde_json::json!({}),
            expected_decision: serde_json::json!({
                "kind": "granted",
                "effectPlan": {
                    "transactionEffects": [
                        duplicate_record.clone(),
                        duplicate_record
                    ],
                    "postCommitEffects": [
                        { "kind": "notify-talk-turn-granted" }
                    ]
                }
            }),
        };
        let mut store = DurableConversationStore::default();

        let err = store.execute_request_talk_turn_case(&case).unwrap_err();

        assert!(matches!(
            err,
            DurablePostgresError::DuplicateCurrentTalkTurnWrite(conversation_id)
                if conversation_id == "conversation-1"
        ));
        assert!(store.current_talk_turn("conversation-1").is_none());
        assert!(store.replay_facts().is_empty());
        assert!(store.post_commit_outbox().is_empty());
    }

    #[test]
    fn request_talk_turn_postgres_schema_documents_required_tables() {
        for table in [
            "runtime_conversations",
            "runtime_participants",
            "runtime_current_talk_turns",
            "runtime_talk_turn_actor_events",
            "runtime_talk_turn_actor_operation_results",
            "runtime_kernel_replay_facts",
            "runtime_websocket_authorization_facts",
            "runtime_post_commit_outbox",
        ] {
            assert!(
                POSTGRES_SCHEMA_SQL.contains(table),
                "schema should include {table}"
            );
        }
        assert!(REQUEST_TALK_TURN_SNAPSHOT_SQL.contains("runtime_current_talk_turns"));
        assert!(REQUEST_TALK_TURN_SNAPSHOT_SQL.contains("ctt.requesting_participant_id"));
        assert!(REQUEST_TALK_TURN_SNAPSHOT_SQL.contains("dar.session_epoch"));
        assert!(POSTGRES_SCHEMA_SQL.contains("runtime_kernel_replay_facts_route_operation_unique"));
        assert!(POSTGRES_SCHEMA_SQL.contains("actor_event_row_ids bigint[] not null"));
        assert!(POSTGRES_SCHEMA_SQL.contains("unique (route, operation_id)"));
    }
}
