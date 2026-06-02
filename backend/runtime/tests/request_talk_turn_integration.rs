use std::time::{SystemTime, UNIX_EPOCH};

use postgres::{Client, NoTls};
use turbo_runtime::multi_node_routing::{OwnerLease, OwnerRecord};
use turbo_runtime::owner_record_transport::{
    OwnerRecordTransport, RedisOwnerRecordTransport, redis_owner_record_key,
};
use turbo_runtime::postgres::{
    DurableBeepThreadStore, DurableContactStore, KernelDecisionCommitter, KernelDecisionEnvelope,
    POSTGRES_SCHEMA_SQL, PostgresDecisionCommitter, PostgresRequestTalkTurnSnapshotLoader,
    RecordingPostCommitEffectSink, RequestTalkTurnSnapshotLoader, SnapshotPolicyConfig,
};
use turbo_runtime::websocket::{WebSocketAuthorizationDecision, WebSocketAuthorizationFact};
use turbo_runtime::websocket_audit::{
    PostgresWebSocketAuthorizationFactSink, WebSocketAuthorizationFactSink,
};

#[test]
#[ignore = "requires `just runtime-postgres-integration`"]
fn request_talk_turn_integration_applies_schema_and_enforces_one_current_turn() {
    let database_url = std::env::var("TURBO_RUNTIME_DATABASE_URL")
        .expect("TURBO_RUNTIME_DATABASE_URL must point at the self-hosted Postgres");
    let mut client =
        Client::connect(&database_url, NoTls).expect("self-hosted Postgres should accept clients");
    client
        .batch_execute(POSTGRES_SCHEMA_SQL)
        .expect("runtime schema should apply");
    client
        .batch_execute(
            "truncate table
                runtime_beep_thread_aliases,
                runtime_beep_threads,
                runtime_profiles,
                runtime_remembered_contacts,
                runtime_post_commit_outbox,
                runtime_websocket_authorization_facts,
                runtime_kernel_replay_facts,
                runtime_talk_turn_actor_operation_results,
                runtime_talk_turn_actor_events,
                runtime_current_talk_turns,
                runtime_wake_targets,
                runtime_device_audio_readiness,
                runtime_device_presence,
                runtime_sessions,
                runtime_participant_devices,
                runtime_participants,
                runtime_conversations
             restart identity cascade",
        )
        .expect("runtime integration test should start from a clean database");

    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after epoch")
        .as_nanos();
    let conversation_id = format!("conversation-{suffix}");
    let participant_a = format!("participant-a-{suffix}");
    let participant_b = format!("participant-b-{suffix}");
    let device_a = format!("device-a-{suffix}");
    let device_b = format!("device-b-{suffix}");
    let operation_id = format!("integration-op-{suffix}");

    client
        .execute(
            "insert into runtime_conversations (conversation_id, conversation_seq, policy_version) values ($1, 1, 'policy-v1')",
            &[&conversation_id],
        )
        .expect("conversation insert should succeed");
    client
        .execute(
            "insert into runtime_participants (conversation_id, participant_id, friend_id) values ($1, $2, 'friend-a'), ($1, $3, 'friend-b')",
            &[&conversation_id, &participant_a, &participant_b],
        )
        .expect("participants insert should succeed");
    client
        .execute(
            "insert into runtime_participant_devices (conversation_id, participant_id, device_id) values ($1, $2, $3), ($1, $4, $5)",
            &[&conversation_id, &participant_a, &device_a, &participant_b, &device_b],
        )
        .expect("devices insert should succeed");
    client
        .execute(
            "insert into runtime_sessions (
                conversation_id,
                participant_id,
                device_id,
                session_epoch,
                last_seen_ms
            ) values ($1, $2, $3, 0, 10000), ($1, $4, $5, 7, 10000)",
            &[
                &conversation_id,
                &participant_a,
                &device_a,
                &participant_b,
                &device_b,
            ],
        )
        .expect("sessions insert should succeed");
    client
        .execute(
            "insert into runtime_device_presence (
                conversation_id,
                participant_id,
                device_id,
                observed_at_ms
            ) values ($1, $2, $3, 10000), ($1, $4, $5, 10000)",
            &[
                &conversation_id,
                &participant_a,
                &device_a,
                &participant_b,
                &device_b,
            ],
        )
        .expect("presence insert should succeed");
    client
        .execute(
            "insert into runtime_device_audio_readiness (
                conversation_id,
                participant_id,
                device_id,
                session_epoch,
                observed_at_ms
            ) values ($1, $2, $3, 7, 10000)",
            &[&conversation_id, &participant_b, &device_b],
        )
        .expect("readiness insert should succeed");

    let loader_client =
        Client::connect(&database_url, NoTls).expect("snapshot loader should connect");
    let loader = PostgresRequestTalkTurnSnapshotLoader::new(
        loader_client,
        SnapshotPolicyConfig::default(),
        10000,
    );
    let kernel_input = loader
        .load_request_talk_turn_snapshot(&serde_json::json!({
            "kind": "request-talk-turn",
            "conversationId": { "value": &conversation_id },
            "requestingParticipantId": { "value": &participant_a },
            "requestingDeviceId": { "value": &device_a },
            "requestingSessionEpoch": { "value": 0 },
            "targetParticipantId": { "value": &participant_b },
            "operationId": &operation_id,
            "policyVersion": { "value": "policy-v1" },
            "kernelVersion": { "value": "kernel-contract-v1" }
        }))
        .expect("snapshot loader should build kernel input from Postgres rows");
    assert_eq!(
        kernel_input.snapshot["conversationId"]["value"],
        conversation_id
    );
    assert_eq!(
        kernel_input.snapshot["targetDeviceAudioReadiness"][0]["deviceId"]["value"],
        device_b
    );
    assert_eq!(kernel_input.snapshot["currentTalkTurn"]["kind"], "none");

    let commit_client =
        Client::connect(&database_url, NoTls).expect("decision committer should connect");
    let mut committer = PostgresDecisionCommitter::new(commit_client);
    committer
        .upsert_profile("@integration-b", "Integration B")
        .expect("Postgres committer should persist profile names");
    committer
        .remember_contact_pair("@integration-a", "@integration-b")
        .expect("Postgres committer should persist reciprocal remembered contacts");
    let mut restarted_contact_committer = PostgresDecisionCommitter::new(
        Client::connect(&database_url, NoTls).expect("restarted contact committer should connect"),
    );
    assert_eq!(
        restarted_contact_committer
            .remembered_contact_handles("@integration-a")
            .expect("remembered contacts should reload from Postgres"),
        vec!["@integration-b".to_owned()]
    );
    assert_eq!(
        restarted_contact_committer
            .remembered_contact_handles("@integration-b")
            .expect("reciprocal remembered contacts should reload from Postgres"),
        vec!["@integration-a".to_owned()]
    );
    assert_eq!(
        restarted_contact_committer
            .profile_name("@integration-b")
            .expect("profile name should reload from Postgres"),
        Some("Integration B".to_owned())
    );
    let direct_channel_id = "direct-user-integration-a-user-integration-b";
    let durable_beep = committer
        .create_or_refresh_beep_thread("@integration-a", "@integration-b", direct_channel_id)
        .expect("Postgres committer should persist Beep Threads");
    assert_eq!(durable_beep.request_count, 1);
    assert_eq!(durable_beep.status, "pending");
    committer
        .alias_beep_thread(&durable_beep.beep_id, &durable_beep.channel_id)
        .expect("Postgres committer should persist stale Beep Thread aliases");
    let mut restarted_beep_committer = PostgresDecisionCommitter::new(
        Client::connect(&database_url, NoTls).expect("restarted Beep committer should connect"),
    );
    assert_eq!(
        restarted_beep_committer
            .pending_beep_threads_for_handle("@integration-b", "incoming")
            .expect("incoming Beep Threads should reload from Postgres"),
        vec![durable_beep.clone()]
    );
    assert_eq!(
        restarted_beep_committer
            .pending_beep_threads_for_handle("@integration-a", "outgoing")
            .expect("outgoing Beep Threads should reload from Postgres"),
        vec![durable_beep.clone()]
    );
    assert_eq!(
        restarted_beep_committer
            .current_pending_beep_thread_id(direct_channel_id)
            .expect("current pending Beep Thread should reload from Postgres"),
        Some(durable_beep.beep_id.clone())
    );
    assert_eq!(
        restarted_beep_committer
            .alias_channel_for_beep_thread(&durable_beep.beep_id)
            .expect("stale Beep Thread alias should reload from Postgres"),
        Some(durable_beep.channel_id.clone())
    );
    let connected_beep = restarted_beep_committer
        .set_beep_thread_status(&durable_beep.beep_id, "connected")
        .expect("terminal Beep Thread status should persist")
        .expect("terminal Beep Thread should exist");
    assert_eq!(connected_beep.status, "connected");
    assert!(
        restarted_beep_committer
            .pending_beep_threads_for_handle("@integration-b", "incoming")
            .expect("terminal Beep Threads should not project as pending")
            .is_empty()
    );

    let committed = committer
        .commit_kernel_decision_envelope(
            &KernelDecisionEnvelope {
                case_id: "integration-grant".to_owned(),
                command: kernel_input.command.clone(),
                snapshot: kernel_input.snapshot.clone(),
                decision: serde_json::json!({
                    "kind": "granted",
                    "grant": {
                        "conversationId": { "value": &conversation_id },
                        "requestingParticipantId": { "value": &participant_a },
                        "requestingDeviceId": { "value": &device_a },
                        "targetParticipantId": { "value": &participant_b },
                        "targetDeviceId": { "value": &device_b },
                        "talkTurnEpoch": { "value": 1 },
                        "expiresAtMs": 25000
                    },
                    "effectPlan": {
                        "transactionEffects": [
                            {
                                "kind": "record-talk-turn",
                                "conversationId": { "value": &conversation_id },
                                "requestingParticipantId": { "value": &participant_a },
                                "requestingDeviceId": { "value": &device_a },
                                "targetParticipantId": { "value": &participant_b },
                                "targetDeviceId": { "value": &device_b },
                                "talkTurnEpoch": { "value": 1 },
                                "expiresAtMs": 25000
                            }
                        ],
                        "postCommitEffects": [
                            {
                                "kind": "notify-talk-turn-granted",
                                "conversationId": { "value": &conversation_id },
                                "requestingParticipantId": { "value": &participant_a },
                                "requestingDeviceId": { "value": &device_a },
                                "targetParticipantId": { "value": &participant_b },
                                "targetDeviceId": { "value": &device_b },
                                "talkTurnEpoch": { "value": 1 }
                            }
                        ]
                    }
                }),
            },
            "/v1/conversations/{conversationId}/talk-turns/request",
        )
        .expect("Postgres committer should persist decision effects");
    assert_eq!(committed.replay_fact.decision_kind, "granted");
    assert_eq!(committed.outbox_rows.len(), 1);
    let mut post_commit_sink = RecordingPostCommitEffectSink::default();
    let delivered_outbox_rows = committer
        .deliver_pending_post_commit_effects(10, &mut post_commit_sink)
        .expect("Postgres outbox dispatcher should mark delivered effects after sink success");
    assert_eq!(delivered_outbox_rows.len(), 1);
    assert!(delivered_outbox_rows[0].delivered);
    assert_eq!(post_commit_sink.delivered().len(), 1);
    let outbox_delivered_at = client
        .query_one(
            "select delivered_at is not null as delivered
             from runtime_post_commit_outbox
             where outbox_id = $1",
            &[&(committed.outbox_rows[0].outbox_id as i64)],
        )
        .expect("outbox row should be queryable")
        .get::<_, bool>("delivered");
    assert!(outbox_delivered_at);

    let duplicate = client.execute(
        "insert into runtime_current_talk_turns (
            conversation_id,
            requesting_participant_id,
            requesting_device_id,
            target_participant_id,
            target_device_id,
            talk_turn_epoch,
            expires_at_ms
        ) values ($1, $2, $3, $4, $5, 2, 26000)",
        &[
            &conversation_id,
            &participant_b,
            &device_b,
            &participant_a,
            &device_a,
        ],
    );

    assert!(
        duplicate.is_err(),
        "Postgres primary key should enforce one current Talk Turn per Conversation"
    );
    client
        .execute(
            "insert into runtime_kernel_replay_facts (
                route,
                conversation_id,
                operation_id,
                command_hash,
                snapshot_hash,
                decision_hash,
                decision_kind
            ) values (
                '/v1/conversations/{conversationId}/talk-turns/request',
                $1,
                'operation-1',
                'command-hash-1',
                'snapshot-hash-1',
                'decision-hash-1',
                'granted'
            )",
            &[&conversation_id],
        )
        .expect("manual replay fact insert with new operation should succeed");
    let duplicate_operation = client.execute(
        "insert into runtime_kernel_replay_facts (
            route,
            conversation_id,
            operation_id,
            command_hash,
            snapshot_hash,
            decision_hash,
            decision_kind
        ) values (
            '/v1/conversations/{conversationId}/talk-turns/request',
            $1,
            'operation-1',
            'command-hash-2',
            'snapshot-hash-2',
            'decision-hash-2',
            'granted'
        )",
        &[&conversation_id],
    );

    assert!(
        duplicate_operation.is_err(),
        "Postgres unique index should fence duplicate operation ids per route"
    );

    let audit_client =
        Client::connect(&database_url, NoTls).expect("websocket audit sink should connect");
    let audit_sink = PostgresWebSocketAuthorizationFactSink::new(audit_client);
    let audit_connection_id = format!("audit-connection-{suffix}");
    audit_sink
        .record_authorization_fact(&WebSocketAuthorizationFact {
            connection_id: audit_connection_id.clone(),
            conversation_id: conversation_id.clone(),
            participant_id: participant_a.clone(),
            device_id: device_a.clone(),
            session_epoch: 3,
            decision: WebSocketAuthorizationDecision::Accepted,
            reason: "integration-audit".to_owned(),
        })
        .expect("websocket authorization fact should persist");
    let audit_row = client
        .query_one(
            "select conversation_id, participant_id, device_id, session_epoch, decision, reason
             from runtime_websocket_authorization_facts
             where connection_id = $1",
            &[&audit_connection_id],
        )
        .expect("websocket authorization fact should be queryable");
    let session_epoch: i64 = audit_row.get("session_epoch");
    assert_eq!(
        audit_row.get::<_, String>("conversation_id"),
        conversation_id
    );
    assert_eq!(audit_row.get::<_, String>("participant_id"), participant_a);
    assert_eq!(audit_row.get::<_, String>("device_id"), device_a);
    assert_eq!(session_epoch, 3);
    assert_eq!(audit_row.get::<_, String>("decision"), "accepted");
    assert_eq!(audit_row.get::<_, String>("reason"), "integration-audit");

    client
        .execute(
            "delete from runtime_websocket_authorization_facts where connection_id = $1",
            &[&audit_connection_id],
        )
        .expect("websocket audit cleanup should succeed");

    let redis_url = std::env::var("TURBO_RUNTIME_REDIS_URL")
        .unwrap_or_else(|_| "redis://127.0.0.1:56379/".to_owned());
    let mut owner_record_transport = RedisOwnerRecordTransport::connect(&redis_url)
        .expect("self-hosted Redis should accept owner-record clients");
    let redis_conversation_id = format!("redis-conversation-{suffix}");
    owner_record_transport
        .delete_record(&redis_conversation_id)
        .expect("stale Redis owner record cleanup should succeed");
    let first_owner = OwnerLease {
        conversation_id: redis_conversation_id.clone(),
        runtime_id: "runtime-a".to_owned(),
        owner_epoch: 1,
        expires_at_ms: 30_000,
    };
    let stale_owner = OwnerLease {
        owner_epoch: 0,
        expires_at_ms: 31_000,
        ..first_owner.clone()
    };
    let drain_owner = OwnerLease {
        expires_at_ms: 32_000,
        ..first_owner.clone()
    };

    assert!(
        owner_record_transport
            .publish_lease(first_owner.clone(), 20_000, 20_000)
            .expect("Redis lease CAS script should execute"),
        "fresh Redis owner lease should be accepted"
    );
    assert!(
        !owner_record_transport
            .publish_lease(stale_owner, 20_001, 20_001)
            .expect("Redis stale lease CAS script should execute"),
        "stale Redis owner lease should be rejected"
    );
    assert_eq!(
        owner_record_transport
            .current_record(&redis_conversation_id)
            .expect("Redis owner record should decode"),
        Some(OwnerRecord::Lease(first_owner))
    );
    assert!(
        owner_record_transport
            .publish_drain(drain_owner.clone(), 20_002, 20_002)
            .expect("Redis drain CAS script should execute"),
        "matching Redis owner drain should be accepted"
    );
    assert_eq!(
        owner_record_transport
            .current_record(&redis_conversation_id)
            .expect("Redis drain record should decode"),
        Some(OwnerRecord::Drain(drain_owner))
    );
    owner_record_transport
        .delete_record(&redis_conversation_id)
        .expect("Redis owner record cleanup should succeed");
    let mut direct_redis = redis::Client::open(redis_url.as_str())
        .expect("Redis URL should parse")
        .get_connection()
        .expect("Redis cleanup probe should connect");
    let cleaned: Option<String> = redis::cmd("GET")
        .arg(redis_owner_record_key(&redis_conversation_id))
        .query(&mut direct_redis)
        .expect("Redis cleanup probe should run");
    assert_eq!(cleaned, None);

    client
        .execute(
            "delete from runtime_conversations where conversation_id = $1",
            &[&conversation_id],
        )
        .expect("test conversation cleanup should succeed");
}
