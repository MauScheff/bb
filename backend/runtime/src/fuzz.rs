use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    KernelCommandKind, KernelCorpus, KernelCorpusCase,
    multi_node_routing::{
        OwnerRecord, OwnerRecordExchange, OwnerRecordWireExchange, OwnerRoutePlan,
        OwnerRoutingError, OwnerRoutingPubSub, OwnerRoutingRegistry, ReconnectReason,
    },
    owner_record_transport::{
        InMemoryOwnerRecordTransport, OwnerRecordTransport, RedisOwnerRecordWritePlan,
    },
    postgres::{
        CorpusKernelDecisionWorker, DurableConversationStore, DurablePostgresError,
        InMemoryRequestTalkTurnSnapshotLoader, KernelDecisionEnvelope,
    },
    quic_protocol::{
        MediaFrameAuthority, MediaFrameLedger, QuicProtocolError, parse_relay_frame_json,
        route_authorized_media_frame,
    },
    routes::{RuntimeRouteError, SelfHostedRouteService},
    shadow::{
        LegacyBeginTransmitInput, ShadowVerdict,
        compare_begin_transmit_response_to_request_talk_turn,
    },
    talk_turn_actor::{
        ActorPolicySnapshot, ConversationOwner, TalkTurnActor, TalkTurnActorError, TalkTurnRenewal,
        TalkTurnRequest,
    },
    websocket::AuthenticatedWebSocketDevice,
    websocket_cluster::{
        ClusterWebSocketAuthority, ClusterWebSocketConnectOutcome, ClusterWebSocketOutbound,
    },
    websocket_network::run_self_hosted_websocket_probe,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FuzzReport {
    pub gate: String,
    pub seed: u64,
    pub requested_count: u64,
    pub checks: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub observations: Vec<FuzzObservation>,
    pub status: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FuzzObservation {
    pub kind: String,
    pub iteration: u64,
    pub verdict: String,
    pub cloud_route: String,
    pub self_hosted_route: String,
    pub cloud_outcome: String,
    pub self_hosted_outcome: String,
}

impl FuzzReport {
    fn ok(gate: &str, seed: u64, requested_count: u64, checks: Vec<String>) -> Self {
        Self::ok_with_observations(gate, seed, requested_count, checks, Vec::new())
    }

    fn ok_with_observations(
        gate: &str,
        seed: u64,
        requested_count: u64,
        checks: Vec<String>,
        observations: Vec<FuzzObservation>,
    ) -> Self {
        Self {
            gate: gate.to_owned(),
            seed,
            requested_count,
            checks,
            observations,
            status: "ok".to_owned(),
        }
    }
}

#[derive(Clone, Debug)]
struct Lcg {
    state: u64,
}

impl Lcg {
    fn new(seed: u64) -> Self {
        Self {
            state: seed ^ 0x9E37_79B9_7F4A_7C15,
        }
    }

    fn next(&mut self) -> u64 {
        self.state = self
            .state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.state
    }

    fn range(&mut self, upper: u64) -> u64 {
        if upper == 0 { 0 } else { self.next() % upper }
    }
}

pub fn run_rust_runtime_fuzz(seed: u64, count: u64) -> Result<FuzzReport, String> {
    let mut rng = Lcg::new(seed);
    let iterations = count.max(1);
    let mut checks = Vec::new();
    let mut observations = Vec::new();

    for index in 0..iterations {
        fuzz_effect_interpreter(&mut rng, index)?;
        observations.push(runtime_fuzz_observation(
            "runtime-effect-plan-interpreter",
            index,
            "idempotent replay, current Talk Turn recording, and idempotency conflict detection passed",
        ));
        fuzz_actor_exclusivity(&mut rng, index)?;
        observations.push(runtime_fuzz_observation(
            "runtime-talk-turn-actor-exclusivity",
            index,
            "renewal extension, overlap denial, release, and stale renew/release rejection passed",
        ));
        fuzz_owner_routing(&mut rng, index)?;
        observations.push(runtime_fuzz_observation(
            "runtime-owner-routing",
            index,
            "single-owner routing, owner transfer, delayed pub/sub, drain, exchange, and transport checks passed",
        ));
        fuzz_websocket_cluster_authority(&mut rng, index)?;
        observations.push(runtime_fuzz_observation(
            "runtime-websocket-cluster-authority",
            index,
            "owner-local bind, forwarded connection, owner-routed payload, and stale binding purge passed",
        ));
        fuzz_quic_payload_boundary(&mut rng, index)?;
        observations.push(runtime_fuzz_observation(
            "runtime-quic-payload-boundary",
            index,
            "authorized packet routing plus duplicate, cross-session, oversized, and malformed frame rejection passed",
        ));
        checks.push(format!("rust-runtime iteration {index}"));
    }

    Ok(FuzzReport::ok_with_observations(
        "rust-runtime-fuzz",
        seed,
        count,
        checks,
        observations,
    ))
}

pub fn run_self_hosted_scenario_fuzz(seed: u64, count: u64) -> Result<FuzzReport, String> {
    let mut rng = Lcg::new(seed);
    let iterations = count.max(1);
    let mut checks = Vec::new();

    for index in 0..iterations {
        fuzz_self_hosted_route_scenario(&mut rng, index)?;
        let probe = run_self_hosted_websocket_probe().map_err(|error| error.to_string())?;
        if probe.status != "ok" {
            return Err(format!(
                "websocket probe failed during scenario iteration {index}"
            ));
        }
        checks.push(format!("self-hosted scenario iteration {index}"));
    }

    Ok(FuzzReport::ok(
        "self-hosted-scenario-fuzz-local",
        seed,
        count,
        checks,
    ))
}

pub fn run_shadow_backend_fuzz(seed: u64, count: u64) -> Result<FuzzReport, String> {
    let mut rng = Lcg::new(seed);
    let iterations = count.max(1);
    let mut checks = Vec::new();
    let mut observations = Vec::new();

    for index in 0..iterations {
        let conversation_id = format!("conversation-{}", rng.range(7));
        let target_device_id = format!("device-{}", rng.range(5));
        let talk_turn_epoch = rng.range(100) + 1;
        let decision = request_talk_turn_decision(
            &conversation_id,
            "participant-a",
            "device-a",
            "participant-b",
            &target_device_id,
            talk_turn_epoch,
            30_000 + index as i64,
        );
        let cloud_response = if rng.range(4) == 0 || index % 5 == 4 {
            serde_json::json!({
                "channelId": conversation_id,
                "status": "transmitting",
                "transmitId": talk_turn_epoch.to_string(),
                "targetDeviceId": format!("{target_device_id}-divergent")
            })
        } else {
            serde_json::json!({
                "channelId": conversation_id,
                "status": "transmitting",
                "transmitId": talk_turn_epoch.to_string(),
                "targetDeviceId": target_device_id
            })
        };
        let comparison =
            compare_begin_transmit_response_to_request_talk_turn(&cloud_response, &decision)
                .map_err(|error| error.to_string())?;
        match comparison.verdict {
            ShadowVerdict::Equivalent | ShadowVerdict::Divergent => {}
        }
        observations.push(FuzzObservation {
            kind: "shadow-begin-transmit-vs-request-talk-turn".to_owned(),
            iteration: index,
            verdict: shadow_verdict_label(comparison.verdict).to_owned(),
            cloud_route: comparison.cloud_route.to_owned(),
            self_hosted_route: comparison.self_hosted_route.to_owned(),
            cloud_outcome: shadow_outcome_label(&comparison.cloud),
            self_hosted_outcome: shadow_outcome_label(&comparison.self_hosted),
        });
        checks.push(format!("shadow comparison iteration {index}"));
    }

    Ok(FuzzReport::ok_with_observations(
        "shadow-backend-fuzz",
        seed,
        count,
        checks,
        observations,
    ))
}

pub fn run_reliability_fuzz_self_hosted_overnight(
    seed: u64,
    count: u64,
) -> Result<FuzzReport, String> {
    let rust = run_rust_runtime_fuzz(seed, count)?;
    let scenario = run_self_hosted_scenario_fuzz(seed ^ 0xA11C_E5CE, count)?;
    let shadow = run_shadow_backend_fuzz(seed ^ 0x5AAD_0BEE, count)?;
    let mut checks = Vec::new();
    let mut observations = Vec::new();
    checks.extend(rust.checks);
    checks.extend(scenario.checks);
    checks.extend(shadow.checks);
    observations.extend(rust.observations);
    observations.extend(shadow.observations);
    Ok(FuzzReport::ok_with_observations(
        "reliability-fuzz-self-hosted-overnight",
        seed,
        count,
        checks,
        observations,
    ))
}

fn runtime_fuzz_observation(kind: &str, iteration: u64, outcome: &str) -> FuzzObservation {
    FuzzObservation {
        kind: kind.to_owned(),
        iteration,
        verdict: "passed".to_owned(),
        cloud_route: "not-applicable".to_owned(),
        self_hosted_route: "rust-runtime-internal".to_owned(),
        cloud_outcome: "not-applicable".to_owned(),
        self_hosted_outcome: outcome.to_owned(),
    }
}

fn shadow_verdict_label(verdict: ShadowVerdict) -> &'static str {
    match verdict {
        ShadowVerdict::Equivalent => "equivalent",
        ShadowVerdict::Divergent => "divergent",
    }
}

fn shadow_outcome_label(outcome: &crate::shadow::ShadowTalkTurnOutcome) -> String {
    match outcome {
        crate::shadow::ShadowTalkTurnOutcome::Granted {
            conversation_id,
            target_device_id,
            talk_turn_epoch,
        } => format!(
            "granted conversation={conversation_id} targetDevice={target_device_id} epoch={}",
            talk_turn_epoch
                .map(|epoch| epoch.to_string())
                .unwrap_or_else(|| "missing".to_owned())
        ),
        crate::shadow::ShadowTalkTurnOutcome::Denied { reason } => {
            format!("denied reason={reason}")
        }
    }
}

fn fuzz_effect_interpreter(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let conversation_id = format!("conversation-{}", rng.range(11));
    let operation_id = format!("op-{index}-{}", rng.range(1_000_000));
    let case = request_talk_turn_case(
        &format!("effect-{index}"),
        &conversation_id,
        &operation_id,
        rng.range(100) + 1,
        40_000 + rng.range(10_000) as i64,
    );
    let mut store = DurableConversationStore::default();
    let first = store
        .execute_request_talk_turn_case(&case)
        .map_err(|error| error.to_string())?;
    let second = store
        .execute_request_talk_turn_case(&case)
        .map_err(|error| error.to_string())?;
    if first != second {
        return Err(format!("idempotent replay diverged for {operation_id}"));
    }
    if store.current_talk_turn(&conversation_id).is_none() {
        return Err(format!(
            "current Talk Turn was not recorded for {conversation_id}"
        ));
    }

    let mut conflicting = case.clone();
    conflicting.command["requestingDeviceId"]["value"] =
        Value::String(format!("device-conflict-{}", rng.range(100)));
    let conflict = store.execute_request_talk_turn_case(&conflicting);
    if !matches!(
        conflict,
        Err(DurablePostgresError::IdempotencyConflict { .. })
    ) {
        return Err(format!(
            "idempotency conflict was not detected for {operation_id}"
        ));
    }
    Ok(())
}

fn fuzz_actor_exclusivity(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let mut actor = TalkTurnActor::new(
        format!("conversation-{}", rng.range(9)),
        ConversationOwner {
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: rng.range(10) + 1,
            lease_expires_at_ms: 100_000,
        },
    );
    let policy = ActorPolicySnapshot {
        policy_version: "policy-v1".to_owned(),
        max_talk_turn_lease_ms: 1_000 + rng.range(20_000) as i64,
        grants_enabled: true,
    };
    let now_ms = 10_000 + rng.range(10_000) as i64;
    let grant = actor
        .request_talk_turn(&policy, actor_request(index, now_ms))
        .map_err(|error| error.to_string())?;
    let renewed = actor
        .renew_talk_turn(
            &policy,
            TalkTurnRenewal {
                operation_id: format!("renew-{index}"),
                talk_turn_epoch: grant.talk_turn_epoch,
                now_ms: now_ms + 2,
            },
        )
        .map_err(|error| error.to_string())?;
    if renewed.expires_at_ms <= grant.expires_at_ms {
        return Err("actor renewal did not extend active Talk Turn lease".to_owned());
    }
    if !matches!(
        actor.request_talk_turn(&policy, actor_request(index + 1, now_ms + 1)),
        Err(TalkTurnActorError::ActiveTalkTurn(_))
    ) {
        return Err("actor allowed overlapping Talk Turns".to_owned());
    }
    actor
        .release_talk_turn(grant.talk_turn_epoch, format!("release-{index}"))
        .map_err(|error| error.to_string())?;
    let next = actor
        .request_talk_turn(&policy, actor_request(index + 2, now_ms + 2))
        .map_err(|error| error.to_string())?;
    if !matches!(
        actor.release_talk_turn(grant.talk_turn_epoch, "stale-release"),
        Err(TalkTurnActorError::StaleRelease { active_epoch, .. }) if active_epoch == Some(next.talk_turn_epoch)
    ) {
        return Err("actor accepted stale release after newer grant".to_owned());
    }
    if !matches!(
        actor.renew_talk_turn(
            &policy,
            TalkTurnRenewal {
                operation_id: format!("stale-renew-{index}"),
                talk_turn_epoch: grant.talk_turn_epoch,
                now_ms: now_ms + 3,
            },
        ),
        Err(TalkTurnActorError::StaleRenewal { active_epoch, .. }) if active_epoch == Some(next.talk_turn_epoch)
    ) {
        return Err("actor accepted stale renewal after newer grant".to_owned());
    }
    Ok(())
}

fn fuzz_owner_routing(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let mut registry = OwnerRoutingRegistry::default();
    let mut bus = OwnerRoutingPubSub::default();
    let conversation_id = format!("conversation-{}", rng.range(17));
    let now_ms = 50_000 + index as i64;
    let ttl_ms = 1_000 + rng.range(10_000) as i64;
    let first = registry
        .claim(&conversation_id, "runtime-a", now_ms, ttl_ms)
        .map_err(|error| error.to_string())?;
    bus.publish(first.clone(), first.expires_at_ms + 1);
    let duplicate_route = registry.route_for_runtime(&conversation_id, "runtime-b", now_ms + 2);
    if duplicate_route
        != (OwnerRoutePlan::Forward {
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: first.owner_epoch,
        })
    {
        return Err("owner routing did not forward duplicate route to current owner".to_owned());
    }
    if !matches!(
        registry.claim(&conversation_id, "runtime-b", now_ms + 1, ttl_ms),
        Err(OwnerRoutingError::ConversationOwned { .. })
    ) {
        return Err("owner routing allowed split-brain claim before expiry".to_owned());
    }
    let transferred = registry
        .claim(&conversation_id, "runtime-b", first.expires_at_ms, ttl_ms)
        .map_err(|error| error.to_string())?;
    if transferred.owner_epoch <= first.owner_epoch {
        return Err("owner routing did not advance epoch on transfer".to_owned());
    }
    bus.publish(transferred.clone(), first.expires_at_ms + 1);
    let delivered = bus.deliver_due(&mut registry, first.expires_at_ms + 1);
    if delivered.len() != 2 || delivered[0].accepted || !delivered[1].accepted {
        return Err(
            "delayed pubsub owner records did not reject stale and accept fresh".to_owned(),
        );
    }
    if registry.accept_owner_record(&first, first.expires_at_ms + 1) {
        return Err("owner routing accepted stale owner record".to_owned());
    }
    let drained = registry.drain_runtime("runtime-b");
    if drained.len() != 1 {
        return Err("owner routing did not drain owned conversation".to_owned());
    }
    if registry.route_for_runtime(&conversation_id, "runtime-a", first.expires_at_ms + 2)
        != (OwnerRoutePlan::Reconnect {
            reason: ReconnectReason::Draining,
        })
    {
        return Err("drained conversation did not force reconnect".to_owned());
    }
    fuzz_owner_record_exchange(&conversation_id, first, transferred)?;
    Ok(())
}

fn fuzz_owner_record_exchange(
    conversation_id: &str,
    stale_owner: crate::multi_node_routing::OwnerLease,
    fresh_owner: crate::multi_node_routing::OwnerLease,
) -> Result<(), String> {
    let mut exchange = OwnerRecordExchange::default();
    let mut observer = OwnerRoutingRegistry::default();
    let stale_delivery_ms = stale_owner.expires_at_ms - 1;
    let fresh_delivery_ms = stale_owner.expires_at_ms + 1;
    if !exchange.publish_lease(
        stale_owner.clone(),
        stale_delivery_ms - 10,
        stale_delivery_ms,
    ) {
        return Err("owner record exchange rejected initial owner".to_owned());
    }
    if !exchange.publish_lease(
        fresh_owner.clone(),
        stale_delivery_ms - 8,
        fresh_delivery_ms,
    ) {
        return Err("owner record exchange rejected fresh owner".to_owned());
    }
    if exchange.publish_lease(stale_owner, fresh_delivery_ms + 1, fresh_delivery_ms + 2) {
        return Err("owner record exchange accepted stale owner".to_owned());
    }
    let delivered_stale = exchange.deliver_due(&mut observer, stale_delivery_ms);
    if delivered_stale.len() != 1 || !delivered_stale[0].accepted {
        return Err("owner record exchange did not deliver initial owner".to_owned());
    }
    let delivered_fresh = exchange.deliver_due(&mut observer, fresh_delivery_ms);
    if delivered_fresh.len() != 1 || !delivered_fresh[0].accepted {
        return Err("owner record exchange did not deliver fresh owner".to_owned());
    }
    if observer.route_for_runtime(conversation_id, &fresh_owner.runtime_id, fresh_delivery_ms)
        != (OwnerRoutePlan::HandleLocally {
            owner_epoch: fresh_owner.owner_epoch,
        })
    {
        return Err("owner record exchange observer did not route to fresh owner".to_owned());
    }
    if !exchange.publish_drain(
        fresh_owner.clone(),
        fresh_delivery_ms + 1,
        fresh_delivery_ms + 2,
    ) {
        return Err("owner record exchange rejected current drain".to_owned());
    }
    let drained = exchange.deliver_due(&mut observer, fresh_delivery_ms + 2);
    if drained.len() != 1 || drained[0].record != OwnerRecord::Drain(fresh_owner) {
        return Err("owner record exchange did not deliver drain record".to_owned());
    }
    if observer.route_for_runtime(conversation_id, "runtime-a", fresh_delivery_ms + 3)
        != (OwnerRoutePlan::Reconnect {
            reason: ReconnectReason::Draining,
        })
    {
        return Err("owner record exchange drain did not force reconnect".to_owned());
    }
    fuzz_owner_record_wire_exchange(conversation_id)?;
    Ok(())
}

fn fuzz_owner_record_wire_exchange(conversation_id: &str) -> Result<(), String> {
    let mut exchange = OwnerRecordWireExchange::default();
    let first = crate::multi_node_routing::OwnerLease {
        conversation_id: conversation_id.to_owned(),
        runtime_id: "runtime-a".to_owned(),
        owner_epoch: 1,
        expires_at_ms: 20_000,
    };
    let second = crate::multi_node_routing::OwnerLease {
        conversation_id: conversation_id.to_owned(),
        runtime_id: "runtime-b".to_owned(),
        owner_epoch: 2,
        expires_at_ms: 30_000,
    };
    if !exchange
        .publish_lease(first.clone(), 10_000, 10_100)
        .map_err(|error| error.to_string())?
    {
        return Err("wire owner exchange rejected initial lease".to_owned());
    }
    if !exchange
        .publish_lease(second.clone(), 20_000, 20_100)
        .map_err(|error| error.to_string())?
    {
        return Err("wire owner exchange rejected fresh lease".to_owned());
    }
    if exchange
        .publish_lease(first, 20_001, 20_200)
        .map_err(|error| error.to_string())?
    {
        return Err("wire owner exchange accepted stale encoded lease".to_owned());
    }
    let mut observer = OwnerRoutingRegistry::default();
    let initial = exchange
        .deliver_due(&mut observer, 10_100)
        .map_err(|error| error.to_string())?;
    let fresh = exchange
        .deliver_due(&mut observer, 20_100)
        .map_err(|error| error.to_string())?;
    if initial.len() != 1 || fresh.len() != 1 || !fresh[0].accepted {
        return Err("wire owner exchange did not deliver fresh lease".to_owned());
    }
    if !exchange
        .publish_drain(second.clone(), 20_200, 20_300)
        .map_err(|error| error.to_string())?
    {
        return Err("wire owner exchange rejected current drain".to_owned());
    }
    let drained = exchange
        .deliver_due(&mut observer, 20_300)
        .map_err(|error| error.to_string())?;
    if drained.len() != 1 || drained[0].record != OwnerRecord::Drain(second) {
        return Err("wire owner exchange did not deliver drain".to_owned());
    }
    fuzz_owner_record_transport(conversation_id)?;
    Ok(())
}

fn fuzz_owner_record_transport(conversation_id: &str) -> Result<(), String> {
    let mut transport = InMemoryOwnerRecordTransport::default();
    let lease = crate::multi_node_routing::OwnerLease {
        conversation_id: conversation_id.to_owned(),
        runtime_id: "runtime-a".to_owned(),
        owner_epoch: 1,
        expires_at_ms: 25_000,
    };
    if !transport
        .publish_lease(lease.clone(), 20_000, 20_100)
        .map_err(|error| error.to_string())?
    {
        return Err("owner record transport rejected initial lease".to_owned());
    }
    let plan = RedisOwnerRecordWritePlan::for_record(&OwnerRecord::Lease(lease.clone()), 20_000)
        .map_err(|error| error.to_string())?;
    if !plan.encoded_record.contains(r#""kind":"lease""#)
        || plan.key != format!("turbo:owner-record:{conversation_id}")
    {
        return Err("owner record transport produced invalid Redis write plan".to_owned());
    }
    let mut observer = OwnerRoutingRegistry::default();
    let delivered = transport
        .deliver_due(&mut observer, 20_100)
        .map_err(|error| error.to_string())?;
    if delivered.len() != 1 || !delivered[0].accepted {
        return Err("owner record transport did not deliver initial lease".to_owned());
    }
    Ok(())
}

fn fuzz_websocket_cluster_authority(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let mut cluster = ClusterWebSocketAuthority::default();
    let conversation_id = format!("conversation-{}", rng.range(13));
    let now_ms = 70_000 + index as i64;
    let ttl_ms = 1_000 + rng.range(10_000) as i64;
    let first_owner = cluster
        .claim_owner(&conversation_id, "runtime-a", now_ms, ttl_ms)
        .map_err(|error| error.to_string())?;
    let conn_a = format!("cluster-conn-a-{index}");
    let conn_b = format!("cluster-conn-b-{index}");
    let connected_a = cluster
        .connect(
            "runtime-a",
            &conn_a,
            cluster_device(&conversation_id, "participant-a", "device-a"),
            now_ms + 1,
        )
        .map_err(|error| error.to_string())?;
    if !matches!(
        connected_a,
        ClusterWebSocketConnectOutcome::ConnectedLocally {
            owner_epoch,
            ..
        } if owner_epoch == first_owner.owner_epoch
    ) {
        return Err("websocket cluster did not bind owner-local connection".to_owned());
    }
    let connected_b = cluster
        .connect(
            "runtime-b",
            &conn_b,
            cluster_device(&conversation_id, "participant-b", "device-b"),
            now_ms + 2,
        )
        .map_err(|error| error.to_string())?;
    if !matches!(
        connected_b,
        ClusterWebSocketConnectOutcome::ForwardedToOwner {
            owner_runtime_id,
            owner_epoch,
            ..
        } if owner_runtime_id == "runtime-a" && owner_epoch == first_owner.owner_epoch
    ) {
        return Err("websocket cluster did not forward non-owner connection".to_owned());
    }
    let routed = cluster
        .handle_text(
            &conn_a,
            &serde_json::json!({
                "type": "direct-quic-offer",
                "channelId": conversation_id,
                "fromUserId": "participant-a",
                "fromDeviceId": "device-a",
                "toUserId": "participant-b",
                "toDeviceId": "device-b",
                "payload": format!("cluster-fuzz-offer-{index}")
            })
            .to_string(),
        )
        .map_err(|error| error.to_string())?;
    if !routed.iter().any(|message: &ClusterWebSocketOutbound| {
        message.connection_id == conn_b && message.runtime_id == "runtime-a"
    }) {
        return Err("websocket cluster did not route through owner runtime".to_owned());
    }

    cluster
        .claim_owner(
            &conversation_id,
            "runtime-b",
            first_owner.expires_at_ms,
            ttl_ms,
        )
        .map_err(|error| error.to_string())?;
    if cluster.binding_runtime(&conn_a).is_some() || cluster.binding_runtime(&conn_b).is_some() {
        return Err("websocket cluster kept stale bindings after owner transfer".to_owned());
    }
    Ok(())
}

fn fuzz_quic_payload_boundary(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let session_id = format!("session-{index}");
    let authority = MediaFrameAuthority::new(&session_id, ["device-a", "device-b"]);
    let mut ledger = MediaFrameLedger::default();
    let allowed_payload = "x".repeat(rng.range(512) as usize);
    let sequence_number = rng.range(10_000) + 1;
    let routed = route_authorized_media_frame(
        &mut ledger,
        &authority,
        &relay_protocol::protocol::RelayFrame::PacketAudio {
            session_id: session_id.clone(),
            sender_device_id: "device-a".to_owned(),
            sequence_number,
            sent_at_ms: 10_000 + index as i64,
            payload: allowed_payload,
        },
    )
    .map_err(|error| error.to_string())?;
    if routed.is_none() {
        return Err("packet audio did not route".to_owned());
    }

    let duplicate = route_authorized_media_frame(
        &mut ledger,
        &authority,
        &relay_protocol::protocol::RelayFrame::PacketAudio {
            session_id: session_id.clone(),
            sender_device_id: "device-a".to_owned(),
            sequence_number,
            sent_at_ms: 10_001 + index as i64,
            payload: "duplicate".to_owned(),
        },
    );
    if !matches!(
        duplicate,
        Err(QuicProtocolError::DuplicateOrStaleSequence { .. })
    ) {
        return Err("duplicate QUIC packet sequence was not rejected".to_owned());
    }

    let cross_session = route_authorized_media_frame(
        &mut ledger,
        &authority,
        &relay_protocol::protocol::RelayFrame::PacketAudio {
            session_id: format!("{session_id}-other"),
            sender_device_id: "device-a".to_owned(),
            sequence_number: sequence_number + 1,
            sent_at_ms: 10_002 + index as i64,
            payload: "cross-session".to_owned(),
        },
    );
    if !matches!(cross_session, Err(QuicProtocolError::CrossSession { .. })) {
        return Err("cross-session QUIC packet was not rejected".to_owned());
    }

    let oversized_payload =
        "x".repeat(relay_protocol::transport_quic::QUIC_MAX_UDP_PAYLOAD_SIZE + 1);
    let oversized = route_authorized_media_frame(
        &mut ledger,
        &authority,
        &relay_protocol::protocol::RelayFrame::PacketAudio {
            session_id,
            sender_device_id: "device-a".to_owned(),
            sequence_number: sequence_number + 2,
            sent_at_ms: 10_003 + index as i64,
            payload: oversized_payload,
        },
    );
    if !matches!(oversized, Err(QuicProtocolError::OversizedPayload { .. })) {
        return Err("oversized QUIC payload was not rejected".to_owned());
    }
    if !matches!(
        parse_relay_frame_json(r#"{"type":"packet-audio","session_id":"missing-fields"}"#),
        Err(QuicProtocolError::MalformedFrame(_))
    ) {
        return Err("malformed relay frame JSON was not rejected".to_owned());
    }
    Ok(())
}

fn cluster_device(
    conversation_id: &str,
    participant_id: &str,
    device_id: &str,
) -> AuthenticatedWebSocketDevice {
    AuthenticatedWebSocketDevice {
        conversation_id: conversation_id.to_owned(),
        participant_id: participant_id.to_owned(),
        device_id: device_id.to_owned(),
    }
}

fn fuzz_self_hosted_route_scenario(rng: &mut Lcg, index: u64) -> Result<(), String> {
    let conversation_id = format!("conversation-{}", rng.range(13));
    let operation_id = format!("scenario-op-{index}-{}", rng.range(1_000_000));
    let case = request_talk_turn_case(
        &format!("scenario-{index}"),
        &conversation_id,
        &operation_id,
        rng.range(100) + 1,
        60_000 + index as i64,
    );
    let corpus = KernelCorpus {
        cases: vec![case.clone()],
    };
    let mut service = SelfHostedRouteService::new(
        InMemoryRequestTalkTurnSnapshotLoader::from_cases([&case]),
        CorpusKernelDecisionWorker::new(&corpus),
    );
    let response = service
        .handle_request_talk_turn(&conversation_id, case.command.clone())
        .map_err(|error| error.to_string())?;
    if response.body["status"] != "granted" {
        return Err("native self-hosted route did not grant generated scenario".to_owned());
    }
    let duplicate = service
        .handle_request_talk_turn(&conversation_id, case.command.clone())
        .map_err(|error| error.to_string())?;
    if duplicate.committed != response.committed {
        return Err("native self-hosted route duplicate was not idempotent".to_owned());
    }
    if !matches!(
        service.handle_request_talk_turn("wrong-conversation", case.command.clone()),
        Err(RuntimeRouteError::ConversationMismatch { .. })
    ) {
        return Err("native self-hosted route accepted mismatched path conversation".to_owned());
    }

    let legacy_input = LegacyBeginTransmitInput {
        channel_id: conversation_id.clone(),
        device_id: "device-a".to_owned(),
        requesting_participant_id: "participant-a".to_owned(),
        requesting_session_epoch: 0,
        target_participant_id: "participant-b".to_owned(),
        operation_id,
        policy_version: "policy-v1".to_owned(),
        kernel_version: "kernel-contract-v1".to_owned(),
    };
    let mut legacy_service = SelfHostedRouteService::new(
        InMemoryRequestTalkTurnSnapshotLoader::from_cases([&case]),
        CorpusKernelDecisionWorker::new(&corpus),
    );
    let legacy = legacy_service
        .handle_legacy_begin_transmit(legacy_input)
        .map_err(|error| error.to_string())?;
    if legacy.body["status"] != "transmitting" {
        return Err("legacy compatibility route did not map granted Talk Turn".to_owned());
    }
    Ok(())
}

fn actor_request(index: u64, now_ms: i64) -> TalkTurnRequest {
    TalkTurnRequest {
        operation_id: format!("actor-op-{index}"),
        requesting_participant_id: "participant-a".to_owned(),
        requesting_device_id: "device-a".to_owned(),
        target_participant_id: "participant-b".to_owned(),
        target_device_id: "device-b".to_owned(),
        now_ms,
    }
}

fn request_talk_turn_case(
    id: &str,
    conversation_id: &str,
    operation_id: &str,
    talk_turn_epoch: u64,
    expires_at_ms: i64,
) -> KernelCorpusCase {
    KernelCorpusCase {
        id: id.to_owned(),
        kind: KernelCommandKind::RequestTalkTurn,
        command: request_talk_turn_command(conversation_id, operation_id),
        snapshot: serde_json::json!({
            "conversationId": wrapped_text(conversation_id),
            "snapshotBuiltAtMs": 10_000
        }),
        policy: serde_json::json!({
            "policyVersion": wrapped_text("policy-v1")
        }),
        expected_decision: request_talk_turn_decision(
            conversation_id,
            "participant-a",
            "device-a",
            "participant-b",
            "device-b",
            talk_turn_epoch,
            expires_at_ms,
        )
        .decision,
    }
}

fn request_talk_turn_command(conversation_id: &str, operation_id: &str) -> Value {
    serde_json::json!({
        "kind": "request-talk-turn",
        "conversationId": wrapped_text(conversation_id),
        "requestingParticipantId": wrapped_text("participant-a"),
        "requestingDeviceId": wrapped_text("device-a"),
        "requestingSessionEpoch": wrapped_u64(0),
        "targetParticipantId": wrapped_text("participant-b"),
        "operationId": operation_id,
        "policyVersion": wrapped_text("policy-v1"),
        "kernelVersion": wrapped_text("kernel-contract-v1")
    })
}

fn request_talk_turn_decision(
    conversation_id: &str,
    requesting_participant_id: &str,
    requesting_device_id: &str,
    target_participant_id: &str,
    target_device_id: &str,
    talk_turn_epoch: u64,
    expires_at_ms: i64,
) -> KernelDecisionEnvelope {
    KernelDecisionEnvelope {
        case_id: "fuzz-generated".to_owned(),
        command: serde_json::json!({}),
        snapshot: serde_json::json!({}),
        decision: serde_json::json!({
            "kind": "granted",
            "grant": {
                "conversationId": wrapped_text(conversation_id),
                "requestingParticipantId": wrapped_text(requesting_participant_id),
                "requestingDeviceId": wrapped_text(requesting_device_id),
                "targetParticipantId": wrapped_text(target_participant_id),
                "targetDeviceId": wrapped_text(target_device_id),
                "talkTurnEpoch": wrapped_u64(talk_turn_epoch),
                "expiresAtMs": expires_at_ms
            },
            "effectPlan": {
                "transactionEffects": [
                    {
                        "kind": "record-talk-turn",
                        "conversationId": wrapped_text(conversation_id),
                        "requestingParticipantId": wrapped_text(requesting_participant_id),
                        "requestingDeviceId": wrapped_text(requesting_device_id),
                        "targetParticipantId": wrapped_text(target_participant_id),
                        "targetDeviceId": wrapped_text(target_device_id),
                        "talkTurnEpoch": wrapped_u64(talk_turn_epoch),
                        "expiresAtMs": expires_at_ms
                    }
                ],
                "postCommitEffects": [
                    {
                        "kind": "notify-talk-turn-granted",
                        "conversationId": wrapped_text(conversation_id),
                        "targetDeviceId": wrapped_text(target_device_id)
                    }
                ]
            }
        }),
    }
}

fn wrapped_text(value: &str) -> Value {
    serde_json::json!({ "value": value })
}

fn wrapped_u64(value: u64) -> Value {
    serde_json::json!({ "value": value })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_runtime_fuzz_replays_seed() {
        let report = run_rust_runtime_fuzz(123, 8).expect("rust runtime fuzz should pass");

        assert_eq!(report.status, "ok");
        assert_eq!(report.checks.len(), 8);
        assert_eq!(report.observations.len(), 40);
        for kind in [
            "runtime-effect-plan-interpreter",
            "runtime-talk-turn-actor-exclusivity",
            "runtime-owner-routing",
            "runtime-websocket-cluster-authority",
            "runtime-quic-payload-boundary",
        ] {
            assert!(
                report
                    .observations
                    .iter()
                    .any(|observation| observation.kind == kind)
            );
        }
    }

    #[test]
    fn self_hosted_scenario_fuzz_local_replays_seed() {
        let report =
            run_self_hosted_scenario_fuzz(123, 3).expect("self-hosted scenario fuzz should pass");

        assert_eq!(report.status, "ok");
        assert_eq!(report.checks.len(), 3);
    }

    #[test]
    fn shadow_backend_fuzz_replays_seed() {
        let report = run_shadow_backend_fuzz(123, 8).expect("shadow backend fuzz should pass");

        assert_eq!(report.status, "ok");
        assert_eq!(report.checks.len(), 8);
        assert_eq!(report.observations.len(), 8);
        assert!(
            report
                .observations
                .iter()
                .any(|observation| observation.verdict == "equivalent")
        );
        assert!(
            report
                .observations
                .iter()
                .any(|observation| observation.verdict == "divergent")
        );
    }

    #[test]
    fn reliability_fuzz_self_hosted_overnight_replays_seed() {
        let report = run_reliability_fuzz_self_hosted_overnight(123, 2)
            .expect("combined self-hosted fuzz should pass");

        assert_eq!(report.status, "ok");
        assert_eq!(report.checks.len(), 6);
        assert_eq!(report.observations.len(), 12);
    }
}
