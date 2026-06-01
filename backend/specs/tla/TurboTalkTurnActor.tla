------------------------- MODULE TurboTalkTurnActor -------------------------
EXTENDS Naturals, FiniteSets, TLC

\* Focused model for the self-hosted Rust Conversation Talk Turn actor.
\*
\* It models runtime ownership, one active Talk Turn per Conversation,
\* renewals, stale releases, lease expiry, policy downgrade, disconnect/reconnect, and
\* drain behavior. It intentionally abstracts over HTTP, Postgres, WebSocket
\* serialization, QUIC media packets, APNs, and Unison kernel evaluation.

CONSTANTS
  Conversations,
  Participants,
  Runtimes,
  NoParticipant,
  NoRuntime,
  MaxTime,
  MaxEpoch,
  LeaseMs

ASSUME NoParticipant \notin Participants
ASSUME NoRuntime \notin Runtimes
ASSUME MaxTime \in Nat
ASSUME MaxEpoch \in Nat \ {0}
ASSUME LeaseMs \in Nat \ {0}

VARIABLES
  now,
  owner,
  ownerEpoch,
  ownerLeaseExpiresAt,
  activeSpeaker,
  activeTarget,
  talkTurnEpoch,
  nextTalkTurnEpoch,
  talkTurnExpiresAt,
  policyEnabled,
  draining,
  reconnectRequired,
  durableConversationPreserved,
  connected,
  staleReleaseCleared,
  grantWhileDraining

vars ==
  << now,
     owner,
     ownerEpoch,
     ownerLeaseExpiresAt,
     activeSpeaker,
     activeTarget,
     talkTurnEpoch,
     nextTalkTurnEpoch,
     talkTurnExpiresAt,
     policyEnabled,
     draining,
     reconnectRequired,
     durableConversationPreserved,
     connected,
     staleReleaseCleared,
     grantWhileDraining >>

ParticipantValue == Participants \cup {NoParticipant}
RuntimeValue == Runtimes \cup {NoRuntime}

HasOwner(c) ==
  /\ owner[c] # NoRuntime
  /\ ownerLeaseExpiresAt[c] > now

HasActiveTalkTurn(c) ==
  activeSpeaker[c] # NoParticipant

ClearTalkTurnFor(c) ==
  /\ activeSpeaker' = [activeSpeaker EXCEPT ![c] = NoParticipant]
  /\ activeTarget' = [activeTarget EXCEPT ![c] = NoParticipant]
  /\ talkTurnEpoch' = [talkTurnEpoch EXCEPT ![c] = 0]
  /\ talkTurnExpiresAt' = [talkTurnExpiresAt EXCEPT ![c] = 0]

PreserveTalkTurn ==
  UNCHANGED << activeSpeaker, activeTarget, talkTurnEpoch, talkTurnExpiresAt >>

Init ==
  /\ now = 0
  /\ owner = [c \in Conversations |-> NoRuntime]
  /\ ownerEpoch = [c \in Conversations |-> 0]
  /\ ownerLeaseExpiresAt = [c \in Conversations |-> 0]
  /\ activeSpeaker = [c \in Conversations |-> NoParticipant]
  /\ activeTarget = [c \in Conversations |-> NoParticipant]
  /\ talkTurnEpoch = [c \in Conversations |-> 0]
  /\ nextTalkTurnEpoch = [c \in Conversations |-> 1]
  /\ talkTurnExpiresAt = [c \in Conversations |-> 0]
  /\ policyEnabled = [c \in Conversations |-> TRUE]
  /\ draining = [c \in Conversations |-> FALSE]
  /\ reconnectRequired = [c \in Conversations |-> FALSE]
  /\ durableConversationPreserved = [c \in Conversations |-> TRUE]
  /\ connected = [p \in Participants |-> TRUE]
  /\ staleReleaseCleared = FALSE
  /\ grantWhileDraining = FALSE

ClaimOwner(c, r) ==
  /\ r \in Runtimes
  /\ ownerEpoch[c] < MaxEpoch
  /\ \/ ~HasOwner(c)
     \/ owner[c] = r
  /\ owner' = [owner EXCEPT ![c] = r]
  /\ ownerEpoch' =
       [ownerEpoch EXCEPT ![c] =
         IF HasOwner(c) /\ owner[c] = r THEN @ ELSE @ + 1]
  /\ ownerLeaseExpiresAt' =
       [ownerLeaseExpiresAt EXCEPT ![c] = now + LeaseMs]
  /\ UNCHANGED << now,
                  activeSpeaker,
                  activeTarget,
                  talkTurnEpoch,
                  nextTalkTurnEpoch,
                  talkTurnExpiresAt,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

RequestTalkTurn(c, speaker, target) ==
  /\ speaker \in Participants
  /\ target \in Participants
  /\ speaker # target
  /\ HasOwner(c)
  /\ connected[speaker]
  /\ connected[target]
  /\ policyEnabled[c]
  /\ ~draining[c]
  /\ ~HasActiveTalkTurn(c)
  /\ nextTalkTurnEpoch[c] <= MaxEpoch
  /\ activeSpeaker' = [activeSpeaker EXCEPT ![c] = speaker]
  /\ activeTarget' = [activeTarget EXCEPT ![c] = target]
  /\ talkTurnEpoch' = [talkTurnEpoch EXCEPT ![c] = nextTalkTurnEpoch[c]]
  /\ nextTalkTurnEpoch' = [nextTalkTurnEpoch EXCEPT ![c] = @ + 1]
  /\ talkTurnExpiresAt' = [talkTurnExpiresAt EXCEPT ![c] = now + LeaseMs]
  /\ grantWhileDraining' = grantWhileDraining \/ draining[c]
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared >>

RenewTalkTurn(c) ==
  /\ HasOwner(c)
  /\ HasActiveTalkTurn(c)
  /\ connected[activeSpeaker[c]]
  /\ connected[activeTarget[c]]
  /\ policyEnabled[c]
  /\ ~draining[c]
  /\ talkTurnExpiresAt[c] < now + LeaseMs
  /\ talkTurnExpiresAt' = [talkTurnExpiresAt EXCEPT ![c] = now + LeaseMs]
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  activeSpeaker,
                  activeTarget,
                  talkTurnEpoch,
                  nextTalkTurnEpoch,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

ReleaseMatchingTalkTurn(c) ==
  /\ HasActiveTalkTurn(c)
  /\ ClearTalkTurnFor(c)
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  nextTalkTurnEpoch,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

StaleRelease(c, staleEpoch) ==
  /\ HasActiveTalkTurn(c)
  /\ staleEpoch \in 0..MaxTime
  /\ staleEpoch # talkTurnEpoch[c]
  /\ PreserveTalkTurn
  /\ staleReleaseCleared' = staleReleaseCleared
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  nextTalkTurnEpoch,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  grantWhileDraining >>

Tick ==
  /\ now < MaxTime
  /\ now' = now + 1
  /\ ownerLeaseExpiresAt' = ownerLeaseExpiresAt
  /\ owner' =
       [c \in Conversations |->
         IF ownerLeaseExpiresAt[c] <= now + 1 THEN NoRuntime ELSE owner[c]]
  /\ ownerEpoch' = ownerEpoch
  /\ activeSpeaker' =
       [c \in Conversations |->
         IF HasActiveTalkTurn(c)
              /\ (talkTurnExpiresAt[c] <= now + 1
                  \/ ownerLeaseExpiresAt[c] <= now + 1)
         THEN NoParticipant ELSE activeSpeaker[c]]
  /\ activeTarget' =
       [c \in Conversations |->
         IF HasActiveTalkTurn(c)
              /\ (talkTurnExpiresAt[c] <= now + 1
                  \/ ownerLeaseExpiresAt[c] <= now + 1)
         THEN NoParticipant ELSE activeTarget[c]]
  /\ talkTurnEpoch' =
       [c \in Conversations |->
         IF HasActiveTalkTurn(c)
              /\ (talkTurnExpiresAt[c] <= now + 1
                  \/ ownerLeaseExpiresAt[c] <= now + 1)
         THEN 0 ELSE talkTurnEpoch[c]]
  /\ talkTurnExpiresAt' =
       [c \in Conversations |->
         IF HasActiveTalkTurn(c)
              /\ (talkTurnExpiresAt[c] <= now + 1
                  \/ ownerLeaseExpiresAt[c] <= now + 1)
         THEN 0 ELSE talkTurnExpiresAt[c]]
  /\ UNCHANGED << nextTalkTurnEpoch,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

PolicyDowngrade(c) ==
  /\ policyEnabled[c]
  /\ policyEnabled' = [policyEnabled EXCEPT ![c] = FALSE]
  /\ ClearTalkTurnFor(c)
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  nextTalkTurnEpoch,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

BeginDrain(c) ==
  /\ ~draining[c]
  /\ draining' = [draining EXCEPT ![c] = TRUE]
  /\ reconnectRequired' = [reconnectRequired EXCEPT ![c] = TRUE]
  /\ durableConversationPreserved' =
       [durableConversationPreserved EXCEPT ![c] = TRUE]
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  activeSpeaker,
                  activeTarget,
                  talkTurnEpoch,
                  nextTalkTurnEpoch,
                  talkTurnExpiresAt,
                  policyEnabled,
                  connected,
                  staleReleaseCleared,
                  grantWhileDraining >>

DisconnectParticipant(p) ==
  /\ connected[p]
  /\ connected' = [connected EXCEPT ![p] = FALSE]
  /\ activeSpeaker' =
       [c \in Conversations |->
         IF activeSpeaker[c] = p \/ activeTarget[c] = p
         THEN NoParticipant ELSE activeSpeaker[c]]
  /\ activeTarget' =
       [c \in Conversations |->
         IF activeSpeaker[c] = p \/ activeTarget[c] = p
         THEN NoParticipant ELSE activeTarget[c]]
  /\ talkTurnEpoch' =
       [c \in Conversations |->
         IF activeSpeaker[c] = p \/ activeTarget[c] = p
         THEN 0 ELSE talkTurnEpoch[c]]
  /\ talkTurnExpiresAt' =
       [c \in Conversations |->
         IF activeSpeaker[c] = p \/ activeTarget[c] = p
         THEN 0 ELSE talkTurnExpiresAt[c]]
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  nextTalkTurnEpoch,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  staleReleaseCleared,
                  grantWhileDraining >>

ReconnectParticipant(p) ==
  /\ ~connected[p]
  /\ connected' = [connected EXCEPT ![p] = TRUE]
  /\ UNCHANGED << now,
                  owner,
                  ownerEpoch,
                  ownerLeaseExpiresAt,
                  activeSpeaker,
                  activeTarget,
                  talkTurnEpoch,
                  nextTalkTurnEpoch,
                  talkTurnExpiresAt,
                  policyEnabled,
                  draining,
                  reconnectRequired,
                  durableConversationPreserved,
                  staleReleaseCleared,
                  grantWhileDraining >>

Next ==
  \/ \E c \in Conversations, r \in Runtimes :
       ClaimOwner(c, r)
  \/ \E c \in Conversations, speaker \in Participants, target \in Participants :
       RequestTalkTurn(c, speaker, target)
  \/ \E c \in Conversations :
       RenewTalkTurn(c)
  \/ \E c \in Conversations :
       ReleaseMatchingTalkTurn(c)
  \/ \E c \in Conversations, staleEpoch \in 0..MaxTime :
       StaleRelease(c, staleEpoch)
  \/ Tick
  \/ \E c \in Conversations :
       PolicyDowngrade(c)
  \/ \E c \in Conversations :
       BeginDrain(c)
  \/ \E p \in Participants :
       DisconnectParticipant(p)
  \/ \E p \in Participants :
       ReconnectParticipant(p)

Spec ==
  Init /\ [][Next]_vars

TypeOK ==
  /\ now \in 0..MaxTime
  /\ owner \in [Conversations -> RuntimeValue]
  /\ ownerEpoch \in [Conversations -> Nat]
  /\ ownerLeaseExpiresAt \in [Conversations -> Nat]
  /\ activeSpeaker \in [Conversations -> ParticipantValue]
  /\ activeTarget \in [Conversations -> ParticipantValue]
  /\ talkTurnEpoch \in [Conversations -> Nat]
  /\ nextTalkTurnEpoch \in [Conversations -> Nat]
  /\ talkTurnExpiresAt \in [Conversations -> Nat]
  /\ policyEnabled \in [Conversations -> BOOLEAN]
  /\ draining \in [Conversations -> BOOLEAN]
  /\ reconnectRequired \in [Conversations -> BOOLEAN]
  /\ durableConversationPreserved \in [Conversations -> BOOLEAN]
  /\ connected \in [Participants -> BOOLEAN]
  /\ staleReleaseCleared \in BOOLEAN
  /\ grantWhileDraining \in BOOLEAN

OneRuntimeOwnerPerConversation ==
  \A c \in Conversations :
    owner[c] \in RuntimeValue

AtMostOneActiveTalkTurn ==
  \A c \in Conversations :
    \/ /\ activeSpeaker[c] = NoParticipant
       /\ activeTarget[c] = NoParticipant
       /\ talkTurnEpoch[c] = 0
    \/ /\ activeSpeaker[c] \in Participants
       /\ activeTarget[c] \in Participants
       /\ activeSpeaker[c] # activeTarget[c]
       /\ talkTurnEpoch[c] > 0

StaleReleaseCannotClearNewerGrant ==
  ~staleReleaseCleared

ActiveTalkTurnLeaseIsCurrent ==
  \A c \in Conversations :
    HasActiveTalkTurn(c) => talkTurnExpiresAt[c] > now

PolicyDowngradeRevokesActiveGrant ==
  \A c \in Conversations :
    ~policyEnabled[c] => ~HasActiveTalkTurn(c)

DrainRequiresReconnectWithoutDurableLoss ==
  \A c \in Conversations :
    draining[c] =>
      /\ reconnectRequired[c]
      /\ durableConversationPreserved[c]

DrainingDoesNotGrant ==
  ~grantWhileDraining

ActiveTalkTurnHasOwner ==
  \A c \in Conversations :
    HasActiveTalkTurn(c) => HasOwner(c)

ActiveTalkTurnParticipantsConnected ==
  \A c \in Conversations :
    HasActiveTalkTurn(c) =>
      /\ connected[activeSpeaker[c]]
      /\ connected[activeTarget[c]]

=============================================================================
