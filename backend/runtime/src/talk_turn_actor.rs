#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationOwner {
    pub runtime_id: String,
    pub owner_epoch: u64,
    pub lease_expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActorPolicySnapshot {
    pub policy_version: String,
    pub max_talk_turn_lease_ms: i64,
    pub grants_enabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TalkTurnRequest {
    pub operation_id: String,
    pub requesting_participant_id: String,
    pub requesting_device_id: String,
    pub target_participant_id: String,
    pub target_device_id: String,
    pub now_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActiveTalkTurn {
    pub talk_turn_epoch: u64,
    pub requesting_participant_id: String,
    pub requesting_device_id: String,
    pub target_participant_id: String,
    pub target_device_id: String,
    pub expires_at_ms: i64,
    pub policy_version: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TalkTurnGrant {
    pub talk_turn_epoch: u64,
    pub expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TalkTurnRenewal {
    pub operation_id: String,
    pub talk_turn_epoch: u64,
    pub now_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DrainInstruction {
    pub conversation_id: String,
    pub runtime_id: String,
    pub owner_epoch: u64,
    pub reconnect_required: bool,
    pub durable_conversation_preserved: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DurableTalkTurnEvent {
    pub event_id: u64,
    pub kind: DurableTalkTurnEventKind,
    pub talk_turn_epoch: Option<u64>,
    pub operation_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DurableTalkTurnEventKind {
    Granted,
    Renewed,
    Released,
    Expired,
    OwnerExpired,
    RevokedByPolicy,
    DrainStarted,
}

#[derive(Debug, thiserror::Error, Eq, PartialEq)]
pub enum TalkTurnActorError {
    #[error("actor is draining")]
    Draining,
    #[error("policy does not allow new Talk Turn grants")]
    PolicyDisabled,
    #[error("another Talk Turn is active at epoch {0}")]
    ActiveTalkTurn(u64),
    #[error("release epoch {release_epoch} does not match active epoch {active_epoch:?}")]
    StaleRelease {
        release_epoch: u64,
        active_epoch: Option<u64>,
    },
    #[error("renewal epoch {renewal_epoch} does not match active epoch {active_epoch:?}")]
    StaleRenewal {
        renewal_epoch: u64,
        active_epoch: Option<u64>,
    },
    #[error("policy lease must be positive")]
    InvalidPolicyLease,
    #[error("runtime owner lease expired at {lease_expires_at_ms}")]
    OwnerLeaseExpired { lease_expires_at_ms: i64 },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TalkTurnActor {
    conversation_id: String,
    owner: ConversationOwner,
    active: Option<ActiveTalkTurn>,
    next_talk_turn_epoch: u64,
    events: Vec<DurableTalkTurnEvent>,
    draining: bool,
}

impl TalkTurnActor {
    pub fn new(conversation_id: impl Into<String>, owner: ConversationOwner) -> Self {
        Self {
            conversation_id: conversation_id.into(),
            owner,
            active: None,
            next_talk_turn_epoch: 1,
            events: Vec::new(),
            draining: false,
        }
    }

    pub fn restore(
        conversation_id: impl Into<String>,
        owner: ConversationOwner,
        active: Option<ActiveTalkTurn>,
        next_talk_turn_epoch: u64,
        draining: bool,
    ) -> Self {
        Self {
            conversation_id: conversation_id.into(),
            owner,
            active,
            next_talk_turn_epoch,
            events: Vec::new(),
            draining,
        }
    }

    pub fn owner(&self) -> &ConversationOwner {
        &self.owner
    }

    pub fn active(&self) -> Option<&ActiveTalkTurn> {
        self.active.as_ref()
    }

    pub fn events(&self) -> &[DurableTalkTurnEvent] {
        &self.events
    }

    pub fn request_talk_turn(
        &mut self,
        policy: &ActorPolicySnapshot,
        request: TalkTurnRequest,
    ) -> Result<TalkTurnGrant, TalkTurnActorError> {
        self.expire_owner_if_needed(request.now_ms);
        self.expire_if_needed(request.now_ms);
        self.validate_owner_lease(request.now_ms)?;
        self.validate_grant_policy(policy)?;
        if self.draining {
            return Err(TalkTurnActorError::Draining);
        }
        if let Some(active) = &self.active {
            return Err(TalkTurnActorError::ActiveTalkTurn(active.talk_turn_epoch));
        }

        let talk_turn_epoch = self.next_talk_turn_epoch;
        self.next_talk_turn_epoch += 1;
        let expires_at_ms = request.now_ms + policy.max_talk_turn_lease_ms;
        self.active = Some(ActiveTalkTurn {
            talk_turn_epoch,
            requesting_participant_id: request.requesting_participant_id,
            requesting_device_id: request.requesting_device_id,
            target_participant_id: request.target_participant_id,
            target_device_id: request.target_device_id,
            expires_at_ms,
            policy_version: policy.policy_version.clone(),
        });
        self.record(
            DurableTalkTurnEventKind::Granted,
            Some(talk_turn_epoch),
            Some(request.operation_id),
        );

        Ok(TalkTurnGrant {
            talk_turn_epoch,
            expires_at_ms,
        })
    }

    pub fn release_talk_turn(
        &mut self,
        talk_turn_epoch: u64,
        operation_id: impl Into<String>,
    ) -> Result<(), TalkTurnActorError> {
        match &self.active {
            Some(active) if active.talk_turn_epoch == talk_turn_epoch => {
                self.active = None;
                self.record(
                    DurableTalkTurnEventKind::Released,
                    Some(talk_turn_epoch),
                    Some(operation_id.into()),
                );
                Ok(())
            }
            active => Err(TalkTurnActorError::StaleRelease {
                release_epoch: talk_turn_epoch,
                active_epoch: active.as_ref().map(|turn| turn.talk_turn_epoch),
            }),
        }
    }

    pub fn renew_talk_turn(
        &mut self,
        policy: &ActorPolicySnapshot,
        renewal: TalkTurnRenewal,
    ) -> Result<TalkTurnGrant, TalkTurnActorError> {
        self.expire_owner_if_needed(renewal.now_ms);
        self.expire_if_needed(renewal.now_ms);
        self.validate_owner_lease(renewal.now_ms)?;
        self.validate_grant_policy(policy)?;
        if self.draining {
            return Err(TalkTurnActorError::Draining);
        }

        let Some(active) = &mut self.active else {
            return Err(TalkTurnActorError::StaleRenewal {
                renewal_epoch: renewal.talk_turn_epoch,
                active_epoch: None,
            });
        };
        if active.talk_turn_epoch != renewal.talk_turn_epoch {
            return Err(TalkTurnActorError::StaleRenewal {
                renewal_epoch: renewal.talk_turn_epoch,
                active_epoch: Some(active.talk_turn_epoch),
            });
        }

        let expires_at_ms = renewal.now_ms + policy.max_talk_turn_lease_ms;
        active.expires_at_ms = expires_at_ms;
        active.policy_version = policy.policy_version.clone();
        self.record(
            DurableTalkTurnEventKind::Renewed,
            Some(renewal.talk_turn_epoch),
            Some(renewal.operation_id),
        );

        Ok(TalkTurnGrant {
            talk_turn_epoch: renewal.talk_turn_epoch,
            expires_at_ms,
        })
    }

    pub fn expire_if_needed(&mut self, now_ms: i64) -> bool {
        let Some(active) = &self.active else {
            return false;
        };
        if active.expires_at_ms > now_ms {
            return false;
        }
        let talk_turn_epoch = active.talk_turn_epoch;
        self.active = None;
        self.record(
            DurableTalkTurnEventKind::Expired,
            Some(talk_turn_epoch),
            None,
        );
        true
    }

    pub fn expire_owner_if_needed(&mut self, now_ms: i64) -> bool {
        if self.owner.lease_expires_at_ms > now_ms {
            return false;
        }
        if let Some(active) = self.active.take() {
            self.record(
                DurableTalkTurnEventKind::OwnerExpired,
                Some(active.talk_turn_epoch),
                None,
            );
        }
        true
    }

    pub fn apply_policy(&mut self, policy: &ActorPolicySnapshot) -> Result<(), TalkTurnActorError> {
        if policy.max_talk_turn_lease_ms <= 0 {
            return Err(TalkTurnActorError::InvalidPolicyLease);
        }
        if !policy.grants_enabled {
            if let Some(active) = self.active.take() {
                self.record(
                    DurableTalkTurnEventKind::RevokedByPolicy,
                    Some(active.talk_turn_epoch),
                    None,
                );
            }
        }
        Ok(())
    }

    pub fn begin_drain(&mut self) -> DrainInstruction {
        self.draining = true;
        self.record(DurableTalkTurnEventKind::DrainStarted, None, None);
        DrainInstruction {
            conversation_id: self.conversation_id.clone(),
            runtime_id: self.owner.runtime_id.clone(),
            owner_epoch: self.owner.owner_epoch,
            reconnect_required: true,
            durable_conversation_preserved: true,
        }
    }

    fn validate_grant_policy(
        &self,
        policy: &ActorPolicySnapshot,
    ) -> Result<(), TalkTurnActorError> {
        if policy.max_talk_turn_lease_ms <= 0 {
            return Err(TalkTurnActorError::InvalidPolicyLease);
        }
        if !policy.grants_enabled {
            return Err(TalkTurnActorError::PolicyDisabled);
        }
        Ok(())
    }

    fn validate_owner_lease(&self, now_ms: i64) -> Result<(), TalkTurnActorError> {
        if self.owner.lease_expires_at_ms <= now_ms {
            Err(TalkTurnActorError::OwnerLeaseExpired {
                lease_expires_at_ms: self.owner.lease_expires_at_ms,
            })
        } else {
            Ok(())
        }
    }

    fn record(
        &mut self,
        kind: DurableTalkTurnEventKind,
        talk_turn_epoch: Option<u64>,
        operation_id: Option<String>,
    ) {
        self.events.push(DurableTalkTurnEvent {
            event_id: self.events.len() as u64 + 1,
            kind,
            talk_turn_epoch,
            operation_id,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn actor() -> TalkTurnActor {
        TalkTurnActor::new(
            "conversation-1",
            ConversationOwner {
                runtime_id: "runtime-a".to_owned(),
                owner_epoch: 1,
                lease_expires_at_ms: 60_000,
            },
        )
    }

    fn policy() -> ActorPolicySnapshot {
        ActorPolicySnapshot {
            policy_version: "policy-v1".to_owned(),
            max_talk_turn_lease_ms: 15_000,
            grants_enabled: true,
        }
    }

    fn request(operation_id: &str, now_ms: i64) -> TalkTurnRequest {
        TalkTurnRequest {
            operation_id: operation_id.to_owned(),
            requesting_participant_id: "participant-a".to_owned(),
            requesting_device_id: "device-a".to_owned(),
            target_participant_id: "participant-b".to_owned(),
            target_device_id: "device-b".to_owned(),
            now_ms,
        }
    }

    fn renewal(operation_id: &str, talk_turn_epoch: u64, now_ms: i64) -> TalkTurnRenewal {
        TalkTurnRenewal {
            operation_id: operation_id.to_owned(),
            talk_turn_epoch,
            now_ms,
        }
    }

    #[test]
    fn talk_turn_actor_records_single_runtime_owner() {
        let actor = actor();

        assert_eq!(actor.owner().runtime_id, "runtime-a");
        assert_eq!(actor.owner().owner_epoch, 1);
        assert_eq!(actor.owner().lease_expires_at_ms, 60_000);
    }

    #[test]
    fn talk_turn_actor_allows_at_most_one_active_turn() {
        let mut actor = actor();
        let grant = actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("first request should grant");

        let err = actor
            .request_talk_turn(&policy(), request("op-2", 10_100))
            .expect_err("second overlapping request should deny");

        assert_eq!(grant.talk_turn_epoch, 1);
        assert_eq!(err, TalkTurnActorError::ActiveTalkTurn(1));
        assert_eq!(actor.active().map(|turn| turn.talk_turn_epoch), Some(1));
    }

    #[test]
    fn talk_turn_actor_stale_release_cannot_clear_newer_grant() {
        let mut actor = actor();
        actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("first request should grant");
        actor
            .release_talk_turn(1, "release-1")
            .expect("matching release should clear turn");
        actor
            .request_talk_turn(&policy(), request("op-2", 11_000))
            .expect("second request should grant");

        let err = actor
            .release_talk_turn(1, "stale-release")
            .expect_err("stale release should fail closed");

        assert_eq!(
            err,
            TalkTurnActorError::StaleRelease {
                release_epoch: 1,
                active_epoch: Some(2)
            }
        );
        assert_eq!(actor.active().map(|turn| turn.talk_turn_epoch), Some(2));
    }

    #[test]
    fn talk_turn_actor_lease_expires_without_renewal() {
        let mut actor = actor();
        let grant = actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("request should grant");

        assert!(actor.expire_if_needed(grant.expires_at_ms));
        assert!(actor.active().is_none());
        assert_eq!(
            actor.events().last().map(|event| &event.kind),
            Some(&DurableTalkTurnEventKind::Expired)
        );
    }

    #[test]
    fn talk_turn_actor_renewal_extends_matching_active_turn() {
        let mut actor = actor();
        let grant = actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("request should grant");

        let renewed = actor
            .renew_talk_turn(&policy(), renewal("renew-1", grant.talk_turn_epoch, 20_000))
            .expect("matching active epoch should renew");

        assert_eq!(renewed.talk_turn_epoch, grant.talk_turn_epoch);
        assert_eq!(renewed.expires_at_ms, 35_000);
        assert_eq!(actor.active().map(|turn| turn.expires_at_ms), Some(35_000));
        assert_eq!(
            actor.events().last().map(|event| &event.kind),
            Some(&DurableTalkTurnEventKind::Renewed)
        );
    }

    #[test]
    fn talk_turn_actor_stale_renewal_cannot_extend_newer_grant() {
        let mut actor = actor();
        actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("first request should grant");
        actor
            .release_talk_turn(1, "release-1")
            .expect("matching release should clear turn");
        actor
            .request_talk_turn(&policy(), request("op-2", 11_000))
            .expect("second request should grant");

        let err = actor
            .renew_talk_turn(&policy(), renewal("stale-renew", 1, 12_000))
            .expect_err("stale renewal should fail closed");

        assert_eq!(
            err,
            TalkTurnActorError::StaleRenewal {
                renewal_epoch: 1,
                active_epoch: Some(2)
            }
        );
        assert_eq!(actor.active().map(|turn| turn.expires_at_ms), Some(26_000));
    }

    #[test]
    fn talk_turn_actor_rejects_renewal_while_draining() {
        let mut actor = actor();
        let grant = actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("request should grant");
        actor.begin_drain();

        let err = actor
            .renew_talk_turn(&policy(), renewal("renew-1", grant.talk_turn_epoch, 11_000))
            .expect_err("draining actor should reject renewals");

        assert_eq!(err, TalkTurnActorError::Draining);
        assert_eq!(
            actor.active().map(|turn| turn.expires_at_ms),
            Some(grant.expires_at_ms)
        );
    }

    #[test]
    fn talk_turn_actor_owner_expiry_clears_active_turn_and_blocks_new_grants() {
        let mut actor = actor();
        actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("request should grant while owner lease is active");

        assert!(actor.expire_owner_if_needed(60_000));
        assert!(actor.active().is_none());
        assert_eq!(
            actor.events().last().map(|event| &event.kind),
            Some(&DurableTalkTurnEventKind::OwnerExpired)
        );

        let err = actor
            .request_talk_turn(&policy(), request("op-2", 60_000))
            .expect_err("expired owner should not grant new Talk Turns");
        assert_eq!(
            err,
            TalkTurnActorError::OwnerLeaseExpired {
                lease_expires_at_ms: 60_000
            }
        );
    }

    #[test]
    fn talk_turn_actor_policy_downgrade_revokes_active_grant() {
        let mut actor = actor();
        actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect("request should grant");
        let mut downgraded = policy();
        downgraded.grants_enabled = false;

        actor
            .apply_policy(&downgraded)
            .expect("policy should apply");

        assert!(actor.active().is_none());
        assert_eq!(
            actor.events().last().map(|event| &event.kind),
            Some(&DurableTalkTurnEventKind::RevokedByPolicy)
        );
    }

    #[test]
    fn talk_turn_actor_drain_requires_reconnect_without_losing_conversation() {
        let mut actor = actor();

        let instruction = actor.begin_drain();
        let err = actor
            .request_talk_turn(&policy(), request("op-1", 10_000))
            .expect_err("draining actor should reject new grants");

        assert_eq!(err, TalkTurnActorError::Draining);
        assert!(instruction.reconnect_required);
        assert!(instruction.durable_conversation_preserved);
        assert_eq!(instruction.conversation_id, "conversation-1");
        assert_eq!(
            actor.events().last().map(|event| &event.kind),
            Some(&DurableTalkTurnEventKind::DrainStarted)
        );
    }
}
