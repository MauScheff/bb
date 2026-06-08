use std::collections::BTreeMap;

use serde_json::Value;

use crate::{
    multi_node_routing::{
        OwnerLease, OwnerRecord, OwnerRoutePlan, OwnerRoutingError, OwnerRoutingRegistry,
        ReconnectReason,
    },
    websocket::{
        AuthenticatedWebSocketDevice, SingleInstanceWebSocketServer, WebSocketAuthorizationFact,
        WebSocketConnectionBinding, WebSocketOutboundMessage, WebSocketSignalingError,
    },
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ClusterWebSocketConnectOutcome {
    ConnectedLocally {
        runtime_id: String,
        owner_epoch: u64,
        notice: Value,
    },
    ForwardedToOwner {
        ingress_runtime_id: String,
        owner_runtime_id: String,
        owner_epoch: u64,
        notice: Value,
    },
    Reconnect {
        reason: ReconnectReason,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClusterWebSocketOutbound {
    pub runtime_id: String,
    pub connection_id: String,
    pub payload: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClusterWebSocketConnectResult {
    pub outcome: ClusterWebSocketConnectOutcome,
    pub authorization_facts: Vec<WebSocketAuthorizationFact>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClusterWebSocketHandleTextResult {
    pub outbound: Vec<ClusterWebSocketOutbound>,
    pub authorization_facts: Vec<WebSocketAuthorizationFact>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ClusterWebSocketAuthority {
    registry: OwnerRoutingRegistry,
    servers_by_runtime: BTreeMap<String, SingleInstanceWebSocketServer>,
    runtime_by_connection: BTreeMap<String, String>,
    conversation_by_connection: BTreeMap<String, String>,
    owner_by_conversation: BTreeMap<String, (String, u64)>,
}

impl ClusterWebSocketAuthority {
    pub fn claim_owner(
        &mut self,
        conversation_id: impl Into<String>,
        runtime_id: impl Into<String>,
        now_ms: i64,
        ttl_ms: i64,
    ) -> Result<OwnerLease, OwnerRoutingError> {
        let conversation_id = conversation_id.into();
        let runtime_id = runtime_id.into();
        let lease =
            self.registry
                .claim(conversation_id.clone(), runtime_id.clone(), now_ms, ttl_ms)?;
        let previous_owner = self
            .owner_by_conversation
            .insert(conversation_id.clone(), (runtime_id, lease.owner_epoch));
        if previous_owner
            .as_ref()
            .is_some_and(|previous| previous.0 != lease.runtime_id)
        {
            self.purge_conversation_bindings(&conversation_id);
        }
        Ok(lease)
    }

    pub fn connect(
        &mut self,
        ingress_runtime_id: impl Into<String>,
        connection_id: impl Into<String>,
        device: AuthenticatedWebSocketDevice,
        now_ms: i64,
    ) -> Result<ClusterWebSocketConnectOutcome, WebSocketSignalingError> {
        self.connect_with_facts(ingress_runtime_id, connection_id, device, now_ms)
            .map(|result| result.outcome)
    }

    pub fn connect_with_facts(
        &mut self,
        ingress_runtime_id: impl Into<String>,
        connection_id: impl Into<String>,
        device: AuthenticatedWebSocketDevice,
        now_ms: i64,
    ) -> Result<ClusterWebSocketConnectResult, WebSocketSignalingError> {
        let ingress_runtime_id = ingress_runtime_id.into();
        let connection_id = connection_id.into();
        let conversation_id = device.conversation_id.clone();
        match self
            .registry
            .route_for_runtime(&conversation_id, &ingress_runtime_id, now_ms)
        {
            OwnerRoutePlan::HandleLocally { owner_epoch } => {
                let (notice, authorization_facts) = self.connect_on_runtime(
                    &ingress_runtime_id,
                    &connection_id,
                    conversation_id,
                    device,
                )?;
                Ok(ClusterWebSocketConnectResult {
                    outcome: ClusterWebSocketConnectOutcome::ConnectedLocally {
                        runtime_id: ingress_runtime_id,
                        owner_epoch,
                        notice: notice.payload,
                    },
                    authorization_facts,
                })
            }
            OwnerRoutePlan::Forward {
                runtime_id,
                owner_epoch,
            } => {
                let (notice, authorization_facts) =
                    self.connect_on_runtime(&runtime_id, &connection_id, conversation_id, device)?;
                Ok(ClusterWebSocketConnectResult {
                    outcome: ClusterWebSocketConnectOutcome::ForwardedToOwner {
                        ingress_runtime_id,
                        owner_runtime_id: runtime_id,
                        owner_epoch,
                        notice: notice.payload,
                    },
                    authorization_facts,
                })
            }
            OwnerRoutePlan::Reconnect { reason } => Ok(ClusterWebSocketConnectResult {
                outcome: ClusterWebSocketConnectOutcome::Reconnect { reason },
                authorization_facts: Vec::new(),
            }),
        }
    }

    pub fn handle_text(
        &mut self,
        connection_id: &str,
        text: &str,
    ) -> Result<Vec<ClusterWebSocketOutbound>, WebSocketSignalingError> {
        self.handle_text_with_facts(connection_id, text)
            .map(|result| result.outbound)
    }

    pub fn handle_text_with_facts(
        &mut self,
        connection_id: &str,
        text: &str,
    ) -> Result<ClusterWebSocketHandleTextResult, WebSocketSignalingError> {
        let runtime_id = self
            .runtime_by_connection
            .get(connection_id)
            .ok_or_else(|| WebSocketSignalingError::UnknownConnection(connection_id.to_owned()))?
            .clone();
        let server = self
            .servers_by_runtime
            .get_mut(&runtime_id)
            .ok_or_else(|| WebSocketSignalingError::UnknownConnection(connection_id.to_owned()))?;
        let before = server.authorization_facts().len();
        let outbound = server.handle_text(connection_id, text)?;
        let authorization_facts = server.authorization_facts()[before..].to_vec();
        let outbound = outbound
            .into_iter()
            .map(|message| ClusterWebSocketOutbound {
                runtime_id: self
                    .runtime_by_connection
                    .get(&message.connection_id)
                    .cloned()
                    .unwrap_or_else(|| runtime_id.clone()),
                connection_id: message.connection_id,
                payload: message.payload,
            })
            .collect();
        Ok(ClusterWebSocketHandleTextResult {
            outbound,
            authorization_facts,
        })
    }

    pub fn disconnect(&mut self, connection_id: &str) -> Option<WebSocketConnectionBinding> {
        let runtime_id = self.runtime_by_connection.remove(connection_id)?;
        self.conversation_by_connection.remove(connection_id);
        self.servers_by_runtime
            .get_mut(&runtime_id)
            .and_then(|server| server.disconnect(connection_id))
    }

    pub fn drain_runtime(&mut self, runtime_id: &str) -> Vec<OwnerLease> {
        let drained = self.registry.drain_runtime(runtime_id);
        for lease in &drained {
            self.owner_by_conversation.remove(&lease.conversation_id);
            self.purge_conversation_bindings(&lease.conversation_id);
        }
        drained
    }

    pub fn observe_owner_record(&mut self, record: OwnerRecord, now_ms: i64) -> bool {
        match record {
            OwnerRecord::Lease(lease) => {
                let conversation_id = lease.conversation_id.clone();
                let previous_owner = self.owner_by_conversation.get(&conversation_id).cloned();
                let accepted = self.registry.observe_owner_record(lease.clone(), now_ms);
                if accepted {
                    self.owner_by_conversation.insert(
                        conversation_id.clone(),
                        (lease.runtime_id.clone(), lease.owner_epoch),
                    );
                }
                if accepted
                    && previous_owner
                        .as_ref()
                        .is_some_and(|previous| previous.0 != lease.runtime_id)
                {
                    self.purge_conversation_bindings(&conversation_id);
                }
                accepted
            }
            OwnerRecord::Drain(lease) => {
                let accepted = self.registry.observe_drain_record(&lease, now_ms);
                if accepted {
                    self.owner_by_conversation.remove(&lease.conversation_id);
                    self.purge_conversation_bindings(&lease.conversation_id);
                }
                accepted
            }
        }
    }

    pub fn binding_runtime(&self, connection_id: &str) -> Option<&str> {
        self.runtime_by_connection
            .get(connection_id)
            .map(String::as_str)
    }

    fn connect_on_runtime(
        &mut self,
        runtime_id: &str,
        connection_id: &str,
        conversation_id: String,
        device: AuthenticatedWebSocketDevice,
    ) -> Result<(WebSocketOutboundMessage, Vec<WebSocketAuthorizationFact>), WebSocketSignalingError>
    {
        let server = self
            .servers_by_runtime
            .entry(runtime_id.to_owned())
            .or_default();
        let before = server.authorization_facts().len();
        let notice = server.connect(connection_id.to_owned(), device)?;
        let authorization_facts = server.authorization_facts()[before..].to_vec();
        self.runtime_by_connection
            .insert(connection_id.to_owned(), runtime_id.to_owned());
        self.conversation_by_connection
            .insert(connection_id.to_owned(), conversation_id);
        Ok((notice, authorization_facts))
    }

    fn purge_conversation_bindings(&mut self, conversation_id: &str) {
        for server in self.servers_by_runtime.values_mut() {
            server.disconnect_conversation(conversation_id);
        }
        let stale_connections = self
            .conversation_by_connection
            .iter()
            .filter_map(|(connection_id, bound_conversation_id)| {
                (bound_conversation_id == conversation_id).then(|| connection_id.clone())
            })
            .collect::<Vec<_>>();
        for connection_id in stale_connections {
            self.runtime_by_connection.remove(&connection_id);
            self.conversation_by_connection.remove(&connection_id);
        }
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
    fn websocket_cluster_forwards_non_owner_connections_to_owner_runtime() {
        let mut cluster = ClusterWebSocketAuthority::default();
        cluster
            .claim_owner("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should claim the conversation");
        let connected_a = cluster
            .connect(
                "runtime-a",
                "conn-a",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("owner-local connection should bind");
        let connected_b = cluster
            .connect(
                "runtime-b",
                "conn-b",
                device("participant-b", "device-b"),
                10_002,
            )
            .expect("non-owner connection should forward to owner");

        assert!(matches!(
            connected_a,
            ClusterWebSocketConnectOutcome::ConnectedLocally {
                runtime_id,
                owner_epoch: 1,
                ..
            } if runtime_id == "runtime-a"
        ));
        assert!(matches!(
            connected_b,
            ClusterWebSocketConnectOutcome::ForwardedToOwner {
                ingress_runtime_id,
                owner_runtime_id,
                owner_epoch: 1,
                ..
            } if ingress_runtime_id == "runtime-b" && owner_runtime_id == "runtime-a"
        ));
        assert_eq!(cluster.binding_runtime("conn-b"), Some("runtime-a"));

        let outbound = cluster
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "direct-quic-offer",
                    "channelId": "conversation-1",
                    "fromUserId": "participant-a",
                    "fromDeviceId": "device-a",
                    "toUserId": "participant-b",
                    "toDeviceId": "device-b",
                    "payload": "cluster-offer"
                })
                .to_string(),
            )
            .expect("owner runtime should route to forwarded target binding");

        assert_eq!(outbound.len(), 1);
        assert_eq!(outbound[0].runtime_id, "runtime-a");
        assert_eq!(outbound[0].connection_id, "conn-b");
        assert_eq!(outbound[0].payload["payload"], "cluster-offer");
    }

    #[test]
    fn websocket_cluster_reconnects_when_no_owner_or_draining() {
        let mut cluster = ClusterWebSocketAuthority::default();
        let no_owner = cluster
            .connect(
                "runtime-a",
                "conn-a",
                device("participant-a", "device-a"),
                10_000,
            )
            .expect("missing owner should not fail protocol parsing");
        assert_eq!(
            no_owner,
            ClusterWebSocketConnectOutcome::Reconnect {
                reason: ReconnectReason::NoOwner
            }
        );

        cluster
            .claim_owner("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should claim");
        cluster.drain_runtime("runtime-a");
        let draining = cluster
            .connect(
                "runtime-b",
                "conn-b",
                device("participant-b", "device-b"),
                10_001,
            )
            .expect("drained conversation should request reconnect");
        assert_eq!(
            draining,
            ClusterWebSocketConnectOutcome::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
    }

    #[test]
    fn websocket_cluster_owner_transfer_purges_stale_connection_authority() {
        let mut cluster = ClusterWebSocketAuthority::default();
        cluster
            .claim_owner("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should claim");
        cluster
            .connect(
                "runtime-a",
                "conn-a-old",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("old owner should bind device");

        cluster
            .claim_owner("conversation-1", "runtime-b", 15_000, 5_000)
            .expect("runtime-b should claim after owner expiry");

        assert_eq!(cluster.binding_runtime("conn-a-old"), None);
        let err = cluster
            .handle_text(
                "conn-a-old",
                &serde_json::json!({
                    "type": "control-command",
                    "requestId": "stale-request",
                    "deviceId": "device-a",
                    "commandKind": "heartbeat"
                })
                .to_string(),
            )
            .expect_err("old owner connection must lose command authority");
        assert_eq!(
            err,
            WebSocketSignalingError::UnknownConnection("conn-a-old".to_owned())
        );

        let reconnected = cluster
            .connect(
                "runtime-a",
                "conn-a-new",
                device("participant-a", "device-a"),
                15_001,
            )
            .expect("new owner should accept forwarded reconnect");
        assert!(matches!(
            reconnected,
            ClusterWebSocketConnectOutcome::ForwardedToOwner {
                owner_runtime_id,
                owner_epoch: 2,
                ..
            } if owner_runtime_id == "runtime-b"
        ));
        assert_eq!(cluster.binding_runtime("conn-a-new"), Some("runtime-b"));
    }

    #[test]
    fn websocket_cluster_same_runtime_reclaim_preserves_connection_authority() {
        let mut cluster = ClusterWebSocketAuthority::default();
        cluster
            .claim_owner("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should claim");
        cluster
            .connect(
                "runtime-a",
                "conn-a",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("owner should bind device");
        cluster
            .claim_owner("conversation-1", "runtime-a", 15_001, 5_000)
            .expect("same runtime should reclaim after expiry");

        assert_eq!(cluster.binding_runtime("conn-a"), Some("runtime-a"));
        let response = cluster
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "control-command",
                    "requestId": "still-bound",
                    "deviceId": "device-a",
                    "commandKind": "presence-keepalive"
                })
                .to_string(),
            )
            .expect("same-runtime reclaim must preserve command authority");
        assert_eq!(response.len(), 1);
        assert_eq!(response[0].connection_id, "conn-a");
    }

    #[test]
    fn websocket_cluster_observed_owner_records_update_routing_and_purge_stale_bindings() {
        let mut cluster = ClusterWebSocketAuthority::default();
        let first = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 15_000,
        };
        let second = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-b".to_owned(),
            owner_epoch: 2,
            expires_at_ms: 20_000,
        };

        assert!(cluster.observe_owner_record(OwnerRecord::Lease(first.clone()), 10_000));
        cluster
            .connect(
                "runtime-a",
                "conn-a-old",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("first owner should bind connection");
        assert_eq!(cluster.binding_runtime("conn-a-old"), Some("runtime-a"));

        assert!(cluster.observe_owner_record(OwnerRecord::Lease(second), 15_000));

        assert_eq!(cluster.binding_runtime("conn-a-old"), None);
        let reconnected = cluster
            .connect(
                "runtime-a",
                "conn-a-new",
                device("participant-a", "device-a"),
                15_001,
            )
            .expect("new owner should receive forwarded reconnect");
        assert!(matches!(
            reconnected,
            ClusterWebSocketConnectOutcome::ForwardedToOwner {
                owner_runtime_id,
                owner_epoch: 2,
                ..
            } if owner_runtime_id == "runtime-b"
        ));
    }

    #[test]
    fn websocket_cluster_observed_same_runtime_owner_record_preserves_bindings() {
        let mut cluster = ClusterWebSocketAuthority::default();
        let first = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 15_000,
        };
        let second = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 2,
            expires_at_ms: 20_000,
        };

        assert!(cluster.observe_owner_record(OwnerRecord::Lease(first), 10_000));
        cluster
            .connect(
                "runtime-a",
                "conn-a",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("first owner should bind connection");
        assert!(cluster.observe_owner_record(OwnerRecord::Lease(second), 15_001));

        assert_eq!(cluster.binding_runtime("conn-a"), Some("runtime-a"));
        cluster
            .handle_text(
                "conn-a",
                &serde_json::json!({
                    "type": "control-command",
                    "requestId": "same-owner-record",
                    "deviceId": "device-a",
                    "commandKind": "presence-keepalive"
                })
                .to_string(),
            )
            .expect("same-runtime owner record must preserve command authority");
    }

    #[test]
    fn websocket_cluster_observed_drain_record_forces_reconnect() {
        let mut cluster = ClusterWebSocketAuthority::default();
        let owner = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 20_000,
        };
        assert!(cluster.observe_owner_record(OwnerRecord::Lease(owner.clone()), 10_000));
        cluster
            .connect(
                "runtime-a",
                "conn-a",
                device("participant-a", "device-a"),
                10_001,
            )
            .expect("owner should bind connection");

        assert!(cluster.observe_owner_record(OwnerRecord::Drain(owner), 10_100));

        assert_eq!(cluster.binding_runtime("conn-a"), None);
        let outcome = cluster
            .connect(
                "runtime-b",
                "conn-b",
                device("participant-b", "device-b"),
                10_101,
            )
            .expect("drained conversation should not fail protocol parsing");
        assert_eq!(
            outcome,
            ClusterWebSocketConnectOutcome::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
    }
}
