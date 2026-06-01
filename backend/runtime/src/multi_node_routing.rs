use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerLease {
    pub conversation_id: String,
    pub runtime_id: String,
    pub owner_epoch: u64,
    pub expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OwnerRoutePlan {
    HandleLocally {
        owner_epoch: u64,
    },
    Forward {
        runtime_id: String,
        owner_epoch: u64,
    },
    Reconnect {
        reason: ReconnectReason,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReconnectReason {
    NoOwner,
    Draining,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DelayedOwnerRecord {
    pub lease: OwnerLease,
    pub deliver_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnerRecordDelivery {
    pub record: OwnerRecord,
    pub accepted: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", content = "lease", rename_all = "kebab-case")]
pub enum OwnerRecord {
    Lease(OwnerLease),
    Drain(OwnerLease),
}

#[derive(Debug, thiserror::Error)]
pub enum OwnerRecordCodecError {
    #[error("owner record JSON was malformed: {0}")]
    MalformedJson(#[from] serde_json::Error),
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum OwnerRoutingError {
    #[error("conversation `{conversation_id}` is owned by `{runtime_id}` until {expires_at_ms}")]
    ConversationOwned {
        conversation_id: String,
        runtime_id: String,
        expires_at_ms: i64,
    },
    #[error("owner lease ttl must be positive")]
    InvalidTtl,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OwnerRoutingRegistry {
    leases: BTreeMap<String, OwnerLease>,
    next_epoch_by_conversation: BTreeMap<String, u64>,
    draining_conversations: BTreeMap<String, String>,
}

impl OwnerRoutingRegistry {
    pub fn claim(
        &mut self,
        conversation_id: impl Into<String>,
        runtime_id: impl Into<String>,
        now_ms: i64,
        ttl_ms: i64,
    ) -> Result<OwnerLease, OwnerRoutingError> {
        if ttl_ms <= 0 {
            return Err(OwnerRoutingError::InvalidTtl);
        }
        let conversation_id = conversation_id.into();
        let runtime_id = runtime_id.into();
        self.draining_conversations.remove(&conversation_id);
        if let Some(existing) = self.leases.get(&conversation_id) {
            if existing.expires_at_ms > now_ms && existing.runtime_id != runtime_id {
                return Err(OwnerRoutingError::ConversationOwned {
                    conversation_id,
                    runtime_id: existing.runtime_id.clone(),
                    expires_at_ms: existing.expires_at_ms,
                });
            }
        }

        let owner_epoch = if self
            .leases
            .get(&conversation_id)
            .is_some_and(|lease| lease.runtime_id == runtime_id && lease.expires_at_ms > now_ms)
        {
            self.leases
                .get(&conversation_id)
                .expect("lease should exist")
                .owner_epoch
        } else {
            self.next_owner_epoch(&conversation_id)
        };
        let lease = OwnerLease {
            conversation_id: conversation_id.clone(),
            runtime_id,
            owner_epoch,
            expires_at_ms: now_ms + ttl_ms,
        };
        self.leases.insert(conversation_id, lease.clone());
        Ok(lease)
    }

    pub fn route(&self, conversation_id: &str, now_ms: i64) -> Option<&OwnerLease> {
        self.leases
            .get(conversation_id)
            .filter(|lease| lease.expires_at_ms > now_ms)
    }

    pub fn route_for_runtime(
        &self,
        conversation_id: &str,
        runtime_id: &str,
        now_ms: i64,
    ) -> OwnerRoutePlan {
        if self.draining_conversations.contains_key(conversation_id) {
            return OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::Draining,
            };
        }
        match self.route(conversation_id, now_ms) {
            Some(lease) if lease.runtime_id == runtime_id => OwnerRoutePlan::HandleLocally {
                owner_epoch: lease.owner_epoch,
            },
            Some(lease) => OwnerRoutePlan::Forward {
                runtime_id: lease.runtime_id.clone(),
                owner_epoch: lease.owner_epoch,
            },
            None => OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::NoOwner,
            },
        }
    }

    pub fn drain_runtime(&mut self, runtime_id: &str) -> Vec<OwnerLease> {
        let drained = self
            .leases
            .values()
            .filter(|lease| lease.runtime_id == runtime_id)
            .cloned()
            .collect::<Vec<_>>();
        for lease in &drained {
            self.leases.remove(&lease.conversation_id);
            self.draining_conversations
                .insert(lease.conversation_id.clone(), runtime_id.to_owned());
        }
        drained
    }

    pub fn observe_drain_record(&mut self, record: &OwnerLease, now_ms: i64) -> bool {
        if record.expires_at_ms <= now_ms {
            return false;
        }
        let Some(current) = self.route(&record.conversation_id, now_ms) else {
            return false;
        };
        if current.runtime_id != record.runtime_id || current.owner_epoch != record.owner_epoch {
            return false;
        }
        self.leases.remove(&record.conversation_id);
        self.draining_conversations
            .insert(record.conversation_id.clone(), record.runtime_id.clone());
        true
    }

    pub fn accept_owner_record(&self, record: &OwnerLease, now_ms: i64) -> bool {
        self.route(&record.conversation_id, now_ms)
            .is_some_and(|current| {
                current.runtime_id == record.runtime_id
                    && current.owner_epoch == record.owner_epoch
                    && current.expires_at_ms == record.expires_at_ms
            })
    }

    pub fn observe_owner_record(&mut self, record: OwnerLease, now_ms: i64) -> bool {
        if record.expires_at_ms <= now_ms {
            return false;
        }
        if self
            .draining_conversations
            .contains_key(&record.conversation_id)
        {
            return false;
        }
        if let Some(current) = self.route(&record.conversation_id, now_ms) {
            if current.owner_epoch > record.owner_epoch {
                return false;
            }
            if current.owner_epoch == record.owner_epoch
                && (current.runtime_id != record.runtime_id
                    || current.expires_at_ms > record.expires_at_ms)
            {
                return false;
            }
        }
        self.next_epoch_by_conversation
            .entry(record.conversation_id.clone())
            .and_modify(|next| *next = (*next).max(record.owner_epoch + 1))
            .or_insert(record.owner_epoch + 1);
        self.leases.insert(record.conversation_id.clone(), record);
        true
    }

    fn next_owner_epoch(&mut self, conversation_id: &str) -> u64 {
        let epoch = self
            .next_epoch_by_conversation
            .entry(conversation_id.to_owned())
            .or_insert(1);
        let current = *epoch;
        *epoch += 1;
        current
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OwnerRoutingPubSub {
    pending: Vec<DelayedOwnerRecord>,
}

impl OwnerRoutingPubSub {
    pub fn publish(&mut self, lease: OwnerLease, deliver_at_ms: i64) {
        self.pending.push(DelayedOwnerRecord {
            lease,
            deliver_at_ms,
        });
    }

    pub fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Vec<OwnerRecordDelivery> {
        let mut pending = Vec::new();
        let mut delivered = Vec::new();
        for record in self.pending.drain(..) {
            if record.deliver_at_ms <= now_ms {
                let accepted = registry.observe_owner_record(record.lease.clone(), now_ms);
                delivered.push(OwnerRecordDelivery {
                    record: OwnerRecord::Lease(record.lease),
                    accepted,
                });
            } else {
                pending.push(record);
            }
        }
        self.pending = pending;
        delivered
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DelayedOwnerExchangeRecord {
    pub record: OwnerRecord,
    pub deliver_at_ms: i64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OwnerRecordExchange {
    records_by_conversation: BTreeMap<String, OwnerRecord>,
    pending: Vec<DelayedOwnerExchangeRecord>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DelayedOwnerWireRecord {
    pub encoded_record: String,
    pub deliver_at_ms: i64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct OwnerRecordWireExchange {
    records_by_conversation: BTreeMap<String, String>,
    pending: Vec<DelayedOwnerWireRecord>,
}

impl OwnerRecordExchange {
    pub fn publish_lease(&mut self, lease: OwnerLease, now_ms: i64, deliver_at_ms: i64) -> bool {
        if !self.accepts_record(&OwnerRecord::Lease(lease.clone()), now_ms) {
            return false;
        }
        let record = OwnerRecord::Lease(lease);
        self.records_by_conversation
            .insert(record.conversation_id().to_owned(), record.clone());
        self.pending.push(DelayedOwnerExchangeRecord {
            record,
            deliver_at_ms,
        });
        true
    }

    pub fn publish_drain(&mut self, lease: OwnerLease, now_ms: i64, deliver_at_ms: i64) -> bool {
        if !self.accepts_record(&OwnerRecord::Drain(lease.clone()), now_ms) {
            return false;
        }
        let record = OwnerRecord::Drain(lease);
        self.records_by_conversation
            .insert(record.conversation_id().to_owned(), record.clone());
        self.pending.push(DelayedOwnerExchangeRecord {
            record,
            deliver_at_ms,
        });
        true
    }

    pub fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Vec<OwnerRecordDelivery> {
        let mut pending = Vec::new();
        let mut delivered = Vec::new();
        for record in self.pending.drain(..) {
            if record.deliver_at_ms <= now_ms {
                let accepted = match &record.record {
                    OwnerRecord::Lease(lease) => {
                        registry.observe_owner_record(lease.clone(), now_ms)
                    }
                    OwnerRecord::Drain(lease) => registry.observe_drain_record(lease, now_ms),
                };
                delivered.push(OwnerRecordDelivery {
                    record: record.record,
                    accepted,
                });
            } else {
                pending.push(record);
            }
        }
        self.pending = pending;
        delivered
    }

    pub fn current_record(&self, conversation_id: &str) -> Option<&OwnerRecord> {
        self.records_by_conversation.get(conversation_id)
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    fn accepts_record(&self, record: &OwnerRecord, now_ms: i64) -> bool {
        let Some(current) = self.records_by_conversation.get(record.conversation_id()) else {
            return record.expires_at_ms() > now_ms;
        };
        Self::accepts_pair(current, record, now_ms)
    }

    fn accepts_pair(current: &OwnerRecord, record: &OwnerRecord, now_ms: i64) -> bool {
        if record.expires_at_ms() <= now_ms {
            return false;
        }
        if current.expires_at_ms() <= now_ms {
            return true;
        }
        match (current, record) {
            (OwnerRecord::Drain(current), OwnerRecord::Lease(next)) => {
                next.owner_epoch > current.owner_epoch
            }
            (OwnerRecord::Lease(current), OwnerRecord::Lease(next)) => {
                next.owner_epoch > current.owner_epoch
                    || (next.owner_epoch == current.owner_epoch
                        && next.runtime_id == current.runtime_id
                        && next.expires_at_ms >= current.expires_at_ms)
            }
            (OwnerRecord::Lease(current), OwnerRecord::Drain(next)) => {
                next.owner_epoch == current.owner_epoch && next.runtime_id == current.runtime_id
            }
            (OwnerRecord::Drain(current), OwnerRecord::Drain(next)) => {
                next.owner_epoch >= current.owner_epoch && next.runtime_id == current.runtime_id
            }
        }
    }
}

impl OwnerRecord {
    pub fn conversation_id(&self) -> &str {
        match self {
            OwnerRecord::Lease(lease) | OwnerRecord::Drain(lease) => &lease.conversation_id,
        }
    }

    pub fn expires_at_ms(&self) -> i64 {
        match self {
            OwnerRecord::Lease(lease) | OwnerRecord::Drain(lease) => lease.expires_at_ms,
        }
    }
}

impl OwnerRecordWireExchange {
    pub fn publish_lease(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordCodecError> {
        self.publish_record(OwnerRecord::Lease(lease), now_ms, deliver_at_ms)
    }

    pub fn publish_drain(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordCodecError> {
        self.publish_record(OwnerRecord::Drain(lease), now_ms, deliver_at_ms)
    }

    pub fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Result<Vec<OwnerRecordDelivery>, OwnerRecordCodecError> {
        let mut pending = Vec::new();
        let mut delivered = Vec::new();
        for record in self.pending.drain(..) {
            if record.deliver_at_ms <= now_ms {
                let owner_record = decode_owner_record_json(&record.encoded_record)?;
                let accepted = match &owner_record {
                    OwnerRecord::Lease(lease) => {
                        registry.observe_owner_record(lease.clone(), now_ms)
                    }
                    OwnerRecord::Drain(lease) => registry.observe_drain_record(lease, now_ms),
                };
                delivered.push(OwnerRecordDelivery {
                    record: owner_record,
                    accepted,
                });
            } else {
                pending.push(record);
            }
        }
        self.pending = pending;
        Ok(delivered)
    }

    pub fn current_encoded_record(&self, conversation_id: &str) -> Option<&str> {
        self.records_by_conversation
            .get(conversation_id)
            .map(String::as_str)
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    fn publish_record(
        &mut self,
        record: OwnerRecord,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordCodecError> {
        if !self.accepts_record(&record, now_ms)? {
            return Ok(false);
        }
        let encoded_record = encode_owner_record_json(&record)?;
        self.records_by_conversation
            .insert(record.conversation_id().to_owned(), encoded_record.clone());
        self.pending.push(DelayedOwnerWireRecord {
            encoded_record,
            deliver_at_ms,
        });
        Ok(true)
    }

    fn accepts_record(
        &self,
        record: &OwnerRecord,
        now_ms: i64,
    ) -> Result<bool, OwnerRecordCodecError> {
        let Some(current) = self.records_by_conversation.get(record.conversation_id()) else {
            return Ok(record.expires_at_ms() > now_ms);
        };
        let current = decode_owner_record_json(current)?;
        Ok(OwnerRecordExchange::accepts_pair(&current, record, now_ms))
    }
}

pub fn encode_owner_record_json(record: &OwnerRecord) -> Result<String, OwnerRecordCodecError> {
    serde_json::to_string(record).map_err(OwnerRecordCodecError::MalformedJson)
}

pub fn decode_owner_record_json(encoded: &str) -> Result<OwnerRecord, OwnerRecordCodecError> {
    serde_json::from_str(encoded).map_err(OwnerRecordCodecError::MalformedJson)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multi_node_routing_prevents_split_brain_owner_claims() {
        let mut registry = OwnerRoutingRegistry::default();
        let owner = registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("first runtime should claim conversation");

        let err = registry
            .claim("conversation-1", "runtime-b", 10_100, 5_000)
            .expect_err("second runtime should not claim before expiry");

        assert_eq!(owner.owner_epoch, 1);
        assert_eq!(
            err,
            OwnerRoutingError::ConversationOwned {
                conversation_id: "conversation-1".to_owned(),
                runtime_id: "runtime-a".to_owned(),
                expires_at_ms: 15_000
            }
        );
    }

    #[test]
    fn multi_node_routing_renews_same_runtime_without_epoch_change() {
        let mut registry = OwnerRoutingRegistry::default();
        let first = registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("first claim should succeed");
        let renewed = registry
            .claim("conversation-1", "runtime-a", 12_000, 5_000)
            .expect("same runtime should renew owner lease");

        assert_eq!(first.owner_epoch, renewed.owner_epoch);
        assert_eq!(renewed.expires_at_ms, 17_000);
    }

    #[test]
    fn multi_node_routing_transfers_after_expiry_with_new_epoch() {
        let mut registry = OwnerRoutingRegistry::default();
        registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("first claim should succeed");
        let transferred = registry
            .claim("conversation-1", "runtime-b", 15_000, 5_000)
            .expect("expired owner can transfer");

        assert_eq!(transferred.runtime_id, "runtime-b");
        assert_eq!(transferred.owner_epoch, 2);
        assert_eq!(
            registry
                .route("conversation-1", 15_001)
                .map(|lease| lease.runtime_id.as_str()),
            Some("runtime-b")
        );
    }

    #[test]
    fn multi_node_routing_rejects_stale_owner_records() {
        let mut registry = OwnerRoutingRegistry::default();
        let stale = registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("first claim should succeed");
        registry
            .claim("conversation-1", "runtime-b", 15_000, 5_000)
            .expect("expired owner can transfer");

        assert!(!registry.accept_owner_record(&stale, 15_001));
    }

    #[test]
    fn multi_node_routing_drain_releases_owned_conversations() {
        let mut registry = OwnerRoutingRegistry::default();
        registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("first claim should succeed");
        registry
            .claim("conversation-2", "runtime-a", 10_000, 5_000)
            .expect("second claim should succeed");

        let drained = registry.drain_runtime("runtime-a");

        assert_eq!(drained.len(), 2);
        assert!(registry.route("conversation-1", 10_001).is_none());
        assert!(registry.route("conversation-2", 10_001).is_none());
    }

    #[test]
    fn multi_node_routing_routes_local_forward_and_reconnect_plans() {
        let mut registry = OwnerRoutingRegistry::default();
        registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should own conversation");

        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-a", 10_001),
            OwnerRoutePlan::HandleLocally { owner_epoch: 1 }
        );
        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-b", 10_001),
            OwnerRoutePlan::Forward {
                runtime_id: "runtime-a".to_owned(),
                owner_epoch: 1
            }
        );
        assert_eq!(
            registry.route_for_runtime("conversation-unknown", "runtime-b", 10_001),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::NoOwner
            }
        );
    }

    #[test]
    fn multi_node_routing_duplicate_routing_is_stable_until_owner_changes() {
        let mut registry = OwnerRoutingRegistry::default();
        registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should own conversation");

        let first = registry.route_for_runtime("conversation-1", "runtime-b", 10_001);
        let duplicate = registry.route_for_runtime("conversation-1", "runtime-b", 10_002);

        assert_eq!(first, duplicate);
    }

    #[test]
    fn multi_node_routing_drain_forces_reconnect_until_reclaimed() {
        let mut registry = OwnerRoutingRegistry::default();
        registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should own conversation");

        let drained = registry.drain_runtime("runtime-a");

        assert_eq!(drained.len(), 1);
        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-b", 10_001),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
        registry
            .claim("conversation-1", "runtime-b", 10_100, 5_000)
            .expect("new runtime can reclaim drained conversation");
        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-b", 10_101),
            OwnerRoutePlan::HandleLocally { owner_epoch: 2 }
        );
    }

    #[test]
    fn multi_node_routing_delayed_pubsub_rejects_stale_owner_records() {
        let mut registry = OwnerRoutingRegistry::default();
        let mut bus = OwnerRoutingPubSub::default();
        let stale = registry
            .claim("conversation-1", "runtime-a", 10_000, 5_000)
            .expect("runtime-a should own conversation");
        bus.publish(stale.clone(), 16_000);
        let fresh = registry
            .claim("conversation-1", "runtime-b", 15_000, 5_000)
            .expect("runtime-b should own expired conversation");
        bus.publish(fresh.clone(), 16_000);

        let delivered = bus.deliver_due(&mut registry, 16_000);

        assert_eq!(delivered.len(), 2);
        assert_eq!(delivered[0].record, OwnerRecord::Lease(stale));
        assert!(!delivered[0].accepted);
        assert_eq!(delivered[1].record, OwnerRecord::Lease(fresh));
        assert!(delivered[1].accepted);
        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-b", 16_001),
            OwnerRoutePlan::HandleLocally { owner_epoch: 2 }
        );
    }

    #[test]
    fn multi_node_routing_delayed_pubsub_preserves_pending_future_records() {
        let mut registry = OwnerRoutingRegistry::default();
        let mut bus = OwnerRoutingPubSub::default();
        let lease = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 20_000,
        };
        bus.publish(lease, 12_000);

        let delivered = bus.deliver_due(&mut registry, 11_999);

        assert!(delivered.is_empty());
        assert_eq!(bus.pending_len(), 1);
        assert_eq!(
            registry.route_for_runtime("conversation-1", "runtime-b", 11_999),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::NoOwner
            }
        );
    }

    #[test]
    fn owner_record_exchange_rejects_stale_records_and_delivers_fresh_owner() {
        let mut exchange = OwnerRecordExchange::default();
        let stale = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 15_000,
        };
        let fresh = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-b".to_owned(),
            owner_epoch: 2,
            expires_at_ms: 20_000,
        };

        assert!(exchange.publish_lease(stale.clone(), 10_000, 12_000));
        assert!(exchange.publish_lease(fresh.clone(), 15_000, 16_000));
        assert!(!exchange.publish_lease(stale.clone(), 16_000, 17_000));
        assert_eq!(
            exchange.current_record("conversation-1"),
            Some(&OwnerRecord::Lease(fresh.clone()))
        );

        let mut observer = OwnerRoutingRegistry::default();
        let delivered_initial = exchange.deliver_due(&mut observer, 12_000);
        assert_eq!(delivered_initial.len(), 1);
        assert_eq!(
            delivered_initial[0].record,
            OwnerRecord::Lease(stale.clone())
        );
        assert!(delivered_initial[0].accepted);

        let delivered_fresh = exchange.deliver_due(&mut observer, 16_000);

        assert_eq!(delivered_fresh.len(), 1);
        assert_eq!(delivered_fresh[0].record, OwnerRecord::Lease(fresh));
        assert!(delivered_fresh[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-b", 16_001),
            OwnerRoutePlan::HandleLocally { owner_epoch: 2 }
        );
    }

    #[test]
    fn owner_record_exchange_delivers_drain_records_to_observers() {
        let mut exchange = OwnerRecordExchange::default();
        let owner = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 1,
            expires_at_ms: 20_000,
        };
        assert!(exchange.publish_lease(owner.clone(), 10_000, 10_100));
        assert!(exchange.publish_drain(owner.clone(), 10_200, 10_300));

        let mut observer = OwnerRoutingRegistry::default();
        let delivered_lease = exchange.deliver_due(&mut observer, 10_100);
        assert_eq!(delivered_lease.len(), 1);
        assert!(delivered_lease[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-a", 10_101),
            OwnerRoutePlan::HandleLocally { owner_epoch: 1 }
        );

        let delivered_drain = exchange.deliver_due(&mut observer, 10_300);
        assert_eq!(delivered_drain.len(), 1);
        assert_eq!(delivered_drain[0].record, OwnerRecord::Drain(owner));
        assert!(delivered_drain[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-b", 10_301),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
    }

    #[test]
    fn owner_record_json_codec_round_trips_lease_and_drain_records() {
        let lease = OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: "runtime-a".to_owned(),
            owner_epoch: 7,
            expires_at_ms: 42_000,
        };

        let encoded_lease =
            encode_owner_record_json(&OwnerRecord::Lease(lease.clone())).expect("lease encodes");
        let encoded_drain =
            encode_owner_record_json(&OwnerRecord::Drain(lease.clone())).expect("drain encodes");

        assert!(encoded_lease.contains(r#""kind":"lease""#));
        assert!(encoded_lease.contains(r#""conversationId":"conversation-1""#));
        assert_eq!(
            decode_owner_record_json(&encoded_lease).expect("lease decodes"),
            OwnerRecord::Lease(lease.clone())
        );
        assert_eq!(
            decode_owner_record_json(&encoded_drain).expect("drain decodes"),
            OwnerRecord::Drain(lease)
        );
    }

    #[test]
    fn owner_record_wire_exchange_rejects_stale_encoded_records_and_delivers_drain() {
        let mut exchange = OwnerRecordWireExchange::default();
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

        assert!(
            exchange
                .publish_lease(first.clone(), 10_000, 10_100)
                .expect("first wire publish succeeds")
        );
        assert!(
            exchange
                .publish_lease(second.clone(), 15_000, 15_100)
                .expect("fresh wire publish succeeds")
        );
        assert!(
            !exchange
                .publish_lease(first, 15_001, 15_200)
                .expect("stale wire publish is classified")
        );
        let current = exchange
            .current_encoded_record("conversation-1")
            .expect("current record should exist");
        assert_eq!(
            decode_owner_record_json(current).expect("current decodes"),
            OwnerRecord::Lease(second.clone())
        );

        let mut observer = OwnerRoutingRegistry::default();
        let initial = exchange
            .deliver_due(&mut observer, 10_100)
            .expect("initial delivery decodes");
        assert_eq!(initial.len(), 1);
        assert!(initial[0].accepted);
        let fresh = exchange
            .deliver_due(&mut observer, 15_100)
            .expect("fresh delivery decodes");
        assert_eq!(fresh.len(), 1);
        assert!(fresh[0].accepted);
        assert!(
            exchange
                .publish_drain(second.clone(), 15_200, 15_300)
                .expect("drain wire publish succeeds")
        );
        let drained = exchange
            .deliver_due(&mut observer, 15_300)
            .expect("drain delivery decodes");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].record, OwnerRecord::Drain(second));
        assert!(drained[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-a", 15_301),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
    }
}
