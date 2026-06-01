use std::time::Duration;

use crate::multi_node_routing::{
    OwnerLease, OwnerRecord, OwnerRecordCodecError, OwnerRecordDelivery, OwnerRecordWireExchange,
    OwnerRoutingRegistry, decode_owner_record_json, encode_owner_record_json,
};

pub const REDIS_OWNER_RECORD_CHANNEL: &str = "turbo:owner-records";

pub const REDIS_OWNER_RECORD_CAS_SCRIPT: &str = r#"
local current = redis.call('GET', KEYS[1])
local candidate = cjson.decode(ARGV[1])
local now_ms = tonumber(ARGV[2])
local ttl_ms = tonumber(ARGV[3])

local function lease(record)
  return record['lease']
end

local function expired(record)
  return tonumber(lease(record)['expiresAtMs']) <= now_ms
end

local function accepts(current_record, next_record)
  if expired(next_record) then
    return false
  end
  if current_record == false or expired(current_record) then
    return true
  end
  local current_lease = lease(current_record)
  local next_lease = lease(next_record)
  local current_kind = current_record['kind']
  local next_kind = next_record['kind']
  local current_epoch = tonumber(current_lease['ownerEpoch'])
  local next_epoch = tonumber(next_lease['ownerEpoch'])
  if current_kind == 'drain' and next_kind == 'lease' then
    return next_epoch > current_epoch
  end
  if current_kind == 'lease' and next_kind == 'lease' then
    return next_epoch > current_epoch
      or (
        next_epoch == current_epoch
        and next_lease['runtimeId'] == current_lease['runtimeId']
        and tonumber(next_lease['expiresAtMs']) >= tonumber(current_lease['expiresAtMs'])
      )
  end
  if current_kind == 'lease' and next_kind == 'drain' then
    return next_epoch == current_epoch and next_lease['runtimeId'] == current_lease['runtimeId']
  end
  if current_kind == 'drain' and next_kind == 'drain' then
    return next_epoch >= current_epoch and next_lease['runtimeId'] == current_lease['runtimeId']
  end
  return false
end

local current_record = false
if current then
  current_record = cjson.decode(current)
end

if not accepts(current_record, candidate) then
  return 0
end

redis.call('SET', KEYS[1], ARGV[1], 'PX', ttl_ms)
redis.call('PUBLISH', ARGV[4], ARGV[1])
return 1
"#;

pub trait OwnerRecordTransport {
    fn publish_lease(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError>;

    fn publish_drain(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError>;

    fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Result<Vec<OwnerRecordDelivery>, OwnerRecordTransportError>;
}

#[derive(Debug, thiserror::Error)]
pub enum OwnerRecordTransportError {
    #[error("owner record codec failed: {0}")]
    Codec(#[from] OwnerRecordCodecError),
    #[error("redis owner record command failed: {0}")]
    Redis(#[from] redis::RedisError),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InMemoryOwnerRecordTransport {
    exchange: OwnerRecordWireExchange,
}

impl InMemoryOwnerRecordTransport {
    pub fn pending_len(&self) -> usize {
        self.exchange.pending_len()
    }
}

impl OwnerRecordTransport for InMemoryOwnerRecordTransport {
    fn publish_lease(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError> {
        self.exchange
            .publish_lease(lease, now_ms, deliver_at_ms)
            .map_err(OwnerRecordTransportError::from)
    }

    fn publish_drain(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError> {
        self.exchange
            .publish_drain(lease, now_ms, deliver_at_ms)
            .map_err(OwnerRecordTransportError::from)
    }

    fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Result<Vec<OwnerRecordDelivery>, OwnerRecordTransportError> {
        self.exchange
            .deliver_due(registry, now_ms)
            .map_err(OwnerRecordTransportError::from)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RedisOwnerRecordWritePlan {
    pub key: String,
    pub channel: String,
    pub encoded_record: String,
    pub now_ms: i64,
    pub ttl_ms: i64,
}

pub struct RedisOwnerRecordTransport {
    command_connection: redis::Connection,
    subscription_connection: redis::Connection,
    subscribed: bool,
}

impl RedisOwnerRecordTransport {
    pub fn connect(redis_url: &str) -> Result<Self, OwnerRecordTransportError> {
        let client = redis::Client::open(redis_url)?;
        let command_connection = client.get_connection()?;
        let subscription_connection = client.get_connection()?;
        subscription_connection.set_read_timeout(Some(Duration::from_millis(1)))?;
        let mut transport = Self {
            command_connection,
            subscription_connection,
            subscribed: false,
        };
        transport.ensure_subscription()?;
        Ok(transport)
    }

    pub fn current_record(
        &mut self,
        conversation_id: &str,
    ) -> Result<Option<OwnerRecord>, OwnerRecordTransportError> {
        let encoded: Option<String> = redis::cmd("GET")
            .arg(redis_owner_record_key(conversation_id))
            .query(&mut self.command_connection)?;
        encoded
            .map(|record| {
                decode_owner_record_json(&record).map_err(OwnerRecordTransportError::from)
            })
            .transpose()
    }

    pub fn delete_record(
        &mut self,
        conversation_id: &str,
    ) -> Result<(), OwnerRecordTransportError> {
        redis::cmd("DEL")
            .arg(redis_owner_record_key(conversation_id))
            .query::<()>(&mut self.command_connection)?;
        Ok(())
    }

    fn publish_record(
        &mut self,
        record: OwnerRecord,
        now_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError> {
        let plan = RedisOwnerRecordWritePlan::for_record(&record, now_ms)?;
        let accepted: i64 = redis::Script::new(REDIS_OWNER_RECORD_CAS_SCRIPT)
            .key(&plan.key)
            .arg(&plan.encoded_record)
            .arg(plan.now_ms)
            .arg(plan.ttl_ms)
            .arg(&plan.channel)
            .invoke(&mut self.command_connection)?;
        Ok(accepted == 1)
    }

    fn ensure_subscription(&mut self) -> Result<(), OwnerRecordTransportError> {
        if !self.subscribed {
            let mut pubsub = self.subscription_connection.as_pubsub();
            pubsub.subscribe(REDIS_OWNER_RECORD_CHANNEL)?;
            self.subscribed = true;
        }
        Ok(())
    }
}

impl OwnerRecordTransport for RedisOwnerRecordTransport {
    fn publish_lease(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        _deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError> {
        self.publish_record(OwnerRecord::Lease(lease), now_ms)
    }

    fn publish_drain(
        &mut self,
        lease: OwnerLease,
        now_ms: i64,
        _deliver_at_ms: i64,
    ) -> Result<bool, OwnerRecordTransportError> {
        self.publish_record(OwnerRecord::Drain(lease), now_ms)
    }

    fn deliver_due(
        &mut self,
        registry: &mut OwnerRoutingRegistry,
        now_ms: i64,
    ) -> Result<Vec<OwnerRecordDelivery>, OwnerRecordTransportError> {
        self.ensure_subscription()?;
        let mut delivered = Vec::new();
        let mut pubsub = self.subscription_connection.as_pubsub();
        loop {
            match pubsub.get_message() {
                Ok(message) => {
                    let encoded: String = message.get_payload()?;
                    let record = decode_owner_record_json(&encoded)?;
                    let accepted = match &record {
                        OwnerRecord::Lease(lease) => {
                            registry.observe_owner_record(lease.clone(), now_ms)
                        }
                        OwnerRecord::Drain(lease) => registry.observe_drain_record(lease, now_ms),
                    };
                    delivered.push(OwnerRecordDelivery { record, accepted });
                }
                Err(error) if error.kind() == redis::ErrorKind::IoError => return Ok(delivered),
                Err(error) => return Err(OwnerRecordTransportError::Redis(error)),
            }
        }
    }
}

impl RedisOwnerRecordWritePlan {
    pub fn for_record(
        record: &OwnerRecord,
        now_ms: i64,
    ) -> Result<Self, OwnerRecordTransportError> {
        let ttl_ms = (record.expires_at_ms() - now_ms).max(1);
        Ok(Self {
            key: redis_owner_record_key(record.conversation_id()),
            channel: REDIS_OWNER_RECORD_CHANNEL.to_owned(),
            encoded_record: encode_owner_record_json(record)?,
            now_ms,
            ttl_ms,
        })
    }

    pub fn evalsha_args(&self, script_sha: &str) -> Vec<String> {
        vec![
            "EVALSHA".to_owned(),
            script_sha.to_owned(),
            "1".to_owned(),
            self.key.clone(),
            self.encoded_record.clone(),
            self.now_ms.to_string(),
            self.ttl_ms.to_string(),
            self.channel.clone(),
        ]
    }
}

pub fn redis_owner_record_key(conversation_id: &str) -> String {
    format!("turbo:owner-record:{conversation_id}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::multi_node_routing::{OwnerRoutePlan, ReconnectReason};

    fn lease(runtime_id: &str, owner_epoch: u64, expires_at_ms: i64) -> OwnerLease {
        OwnerLease {
            conversation_id: "conversation-1".to_owned(),
            runtime_id: runtime_id.to_owned(),
            owner_epoch,
            expires_at_ms,
        }
    }

    #[test]
    fn in_memory_owner_record_transport_delivers_encoded_lease_and_drain() {
        let mut transport = InMemoryOwnerRecordTransport::default();
        let first = lease("runtime-a", 1, 15_000);
        let second = lease("runtime-b", 2, 20_000);

        assert!(
            transport
                .publish_lease(first.clone(), 10_000, 10_100)
                .expect("initial lease publish should encode")
        );
        assert!(
            transport
                .publish_lease(second.clone(), 15_000, 15_100)
                .expect("fresh lease publish should encode")
        );
        assert!(
            !transport
                .publish_lease(first, 15_001, 15_200)
                .expect("stale lease publish should be classified")
        );

        let mut observer = OwnerRoutingRegistry::default();
        assert_eq!(
            transport
                .deliver_due(&mut observer, 10_100)
                .expect("initial lease should decode")
                .len(),
            1
        );
        let fresh = transport
            .deliver_due(&mut observer, 15_100)
            .expect("fresh lease should decode");
        assert_eq!(fresh.len(), 1);
        assert!(fresh[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-b", 15_101),
            OwnerRoutePlan::HandleLocally { owner_epoch: 2 }
        );

        assert!(
            transport
                .publish_drain(second.clone(), 15_200, 15_300)
                .expect("drain publish should encode")
        );
        let drained = transport
            .deliver_due(&mut observer, 15_300)
            .expect("drain should decode");
        assert_eq!(drained.len(), 1);
        assert!(drained[0].accepted);
        assert_eq!(
            observer.route_for_runtime("conversation-1", "runtime-a", 15_301),
            OwnerRoutePlan::Reconnect {
                reason: ReconnectReason::Draining
            }
        );
    }

    #[test]
    fn redis_owner_record_write_plan_uses_checked_wire_payload_and_cas_script() {
        let record = OwnerRecord::Lease(lease("runtime-a", 3, 25_000));

        let plan =
            RedisOwnerRecordWritePlan::for_record(&record, 20_000).expect("plan should encode");

        assert_eq!(plan.key, "turbo:owner-record:conversation-1");
        assert_eq!(plan.channel, REDIS_OWNER_RECORD_CHANNEL);
        assert_eq!(plan.ttl_ms, 5_000);
        assert!(plan.encoded_record.contains(r#""kind":"lease""#));
        assert!(plan.encoded_record.contains(r#""ownerEpoch":3"#));
        assert!(REDIS_OWNER_RECORD_CAS_SCRIPT.contains("cjson.decode"));
        assert!(REDIS_OWNER_RECORD_CAS_SCRIPT.contains("PUBLISH"));
        assert_eq!(
            plan.evalsha_args("script-sha"),
            vec![
                "EVALSHA",
                "script-sha",
                "1",
                "turbo:owner-record:conversation-1",
                &plan.encoded_record,
                "20000",
                "5000",
                REDIS_OWNER_RECORD_CHANNEL,
            ]
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>()
        );
    }
}
