--------------------------- MODULE TurboCommunication ---------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

\* A small control-plane model for Turbo direct-channel communication.
\*
\* This is intentionally not a model of audio, APNs internals, HTTP, SwiftUI, or
\* Unison storage. It models the protocol facts that decide whether a device may
\* transmit, whether another device can be targeted, and how stale or unreliable
\* control messages interact with client projections.

CONSTANTS
  Devices,
  Channels,
  NoDevice,
  MaxInboxLength,
  MaxEpoch

ASSUME NoDevice \notin Devices
ASSUME MaxInboxLength \in Nat
ASSUME MaxEpoch \in Nat

VARIABLES
  request,
  localJoinIntent,
  members,
  presence,
  receiverReady,
  wakeToken,
  activeTransmit,
  transmitEpoch,
  inbox,
  knownTransmit,
  knownEpoch,
  clientPhase

vars ==
  << request,
     localJoinIntent,
     members,
     presence,
     receiverReady,
     wakeToken,
     activeTransmit,
     transmitEpoch,
     inbox,
     knownTransmit,
     knownEpoch,
     clientPhase >>

PresenceValues == {"offline", "joined"}
PhaseValues ==
  {"notJoined", "joining", "preparingAudio", "ready", "transmitting", "receiving"}
MessageKinds == {"TransmitStarted", "TransmitEnded"}
TransmitValue == Devices \cup {NoDevice}
RequestStatusValues == {"none", "requested"}
Request ==
  [status: RequestStatusValues,
   requester: TransmitValue,
   recipient: TransmitValue,
   channel: Channels]
Message ==
  [ kind: MessageKinds,
    channel: Channels,
    sender: TransmitValue,
    epoch: 0..MaxEpoch ]

NoTransmit == [c \in Channels |-> NoDevice]
ZeroEpoch == [c \in Channels |-> 0]
EmptyInbox == [d \in Devices |-> <<>>]
NoRequest == [status |-> "none", requester |-> NoDevice, recipient |-> NoDevice, channel |-> CHOOSE c \in Channels : TRUE]
NoLocalJoinIntent == [d \in Devices |-> [c \in Channels |-> FALSE]]

IsMember(d, c) == d \in members[c]
IsJoined(d, c) == IsMember(d, c) /\ presence[d][c] = "joined"
HasLocalJoinEvidence(d, c) == localJoinIntent[d][c] \/ IsJoined(d, c)
IsAddressable(d, c) == IsMember(d, c) /\ (IsJoined(d, c) \/ wakeToken[d][c])
HasAddressableReceiver(d, c) ==
  \E receiver \in Devices :
    receiver # d /\ IsAddressable(receiver, c)

CanReceiveTransmit(receiver, c) ==
  IsMember(receiver, c) /\
    ((IsJoined(receiver, c) /\ receiverReady[receiver][c]) \/ wakeToken[receiver][c])

CanBeginTransmit(sender, c) ==
  /\ activeTransmit[c] = NoDevice
  /\ IsJoined(sender, c)
  /\ \E receiver \in Devices :
       receiver # sender /\ CanReceiveTransmit(receiver, c)

AddressableAfterMembershipLoss(receiver, lostMember, c) ==
  receiver # lostMember /\
    IsMember(receiver, c) /\
    (IsJoined(receiver, c) \/ wakeToken[receiver][c])

ShouldClearTransmitAfterMembershipLoss(lostMember, c) ==
  activeTransmit[c] # NoDevice /\
    ( activeTransmit[c] = lostMember \/
      ~(\E receiver \in Devices :
          receiver # activeTransmit[c] /\
          AddressableAfterMembershipLoss(receiver, lostMember, c)) )

PhaseAfterNoTransmit(d, c) ==
  IF ~IsMember(d, c) THEN "notJoined"
  ELSE IF IsJoined(d, c) /\ receiverReady[d][c] THEN "ready"
  ELSE IF IsJoined(d, c) THEN "preparingAudio"
  ELSE IF localJoinIntent[d][c] THEN "joining"
  ELSE "notJoined"

PhaseFromBackend(d, c) ==
  IF ~IsMember(d, c) THEN "notJoined"
  ELSE IF activeTransmit[c] = d THEN "transmitting"
  ELSE IF activeTransmit[c] \in Devices
       /\ activeTransmit[c] # d
       /\ IsJoined(d, c)
       /\ IsMember(activeTransmit[c], c)
       THEN "receiving"
  ELSE PhaseAfterNoTransmit(d, c)

TransmitStarted(c, sender, epoch) ==
  [kind |-> "TransmitStarted", channel |-> c, sender |-> sender, epoch |-> epoch]

TransmitEnded(c, sender, epoch) ==
  [kind |-> "TransmitEnded", channel |-> c, sender |-> sender, epoch |-> epoch]

AppendIfSpace(queue, message) ==
  IF Len(queue) < MaxInboxLength THEN Append(queue, message) ELSE queue

NotifyPeers(c, sender, message) ==
  [d \in Devices |->
    IF d # sender /\ IsMember(d, c)
    THEN AppendIfSpace(inbox[d], message)
    ELSE inbox[d]]

NotifyMembers(c, message) ==
  [d \in Devices |->
    IF IsMember(d, c)
    THEN AppendIfSpace(inbox[d], message)
    ELSE inbox[d]]

Init ==
  /\ request = NoRequest
  /\ localJoinIntent = NoLocalJoinIntent
  /\ members = [c \in Channels |-> {}]
  /\ presence = [d \in Devices |-> [c \in Channels |-> "offline"]]
  /\ receiverReady = [d \in Devices |-> [c \in Channels |-> FALSE]]
  /\ wakeToken = [d \in Devices |-> [c \in Channels |-> FALSE]]
  /\ activeTransmit = NoTransmit
  /\ transmitEpoch = ZeroEpoch
  /\ inbox = EmptyInbox
  /\ knownTransmit = [d \in Devices |-> NoTransmit]
  /\ knownEpoch = [d \in Devices |-> ZeroEpoch]
  /\ clientPhase = [d \in Devices |-> [c \in Channels |-> "notJoined"]]

RequestConnection(requester, recipient, c) ==
  /\ requester # recipient
  /\ request.status = "none"
  /\ members[c] = {}
  /\ request' =
       [status |-> "requested",
        requester |-> requester,
        recipient |-> recipient,
        channel |-> c]
  /\ clientPhase' = [clientPhase EXCEPT ![requester][c] = "joining"]
  /\ UNCHANGED << localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch >>

DeclineRequest(recipient, c) ==
  /\ request.status = "requested"
  /\ request.recipient = recipient
  /\ request.channel = c
  /\ request' = NoRequest
  /\ clientPhase' =
       [clientPhase EXCEPT
         ![request.requester][c] = "notJoined",
         ![recipient][c] = "notJoined"]
  /\ UNCHANGED << localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch >>

AcceptRequest(recipient, c) ==
  /\ request.status = "requested"
  /\ request.recipient = recipient
  /\ request.channel = c
  /\ members[c] = {}
  /\ request' = NoRequest
  /\ members' = [members EXCEPT ![c] = {request.requester, recipient}]
  /\ localJoinIntent' =
       [localJoinIntent EXCEPT
         ![request.requester][c] = TRUE,
         ![recipient][c] = TRUE]
  /\ clientPhase' =
       [clientPhase EXCEPT
         ![request.requester][c] = "joining",
         ![recipient][c] = "joining"]
  /\ UNCHANGED << presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch >>

CompleteLocalJoin(d, c) ==
  /\ IsMember(d, c)
  /\ localJoinIntent[d][c]
  /\ presence' = [presence EXCEPT ![d][c] = "joined"]
  /\ localJoinIntent' = [localJoinIntent EXCEPT ![d][c] = FALSE]
  /\ clientPhase' = [clientPhase EXCEPT ![d][c] = PhaseAfterNoTransmit(d, c)]
  /\ UNCHANGED << request,
                  members,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch >>

FailLocalJoin(d, c) ==
  /\ IsMember(d, c)
  /\ localJoinIntent[d][c]
  /\ localJoinIntent' = [localJoinIntent EXCEPT ![d][c] = FALSE]
  /\ members' = [members EXCEPT ![c] = @ \ {d}]
  /\ presence' = [presence EXCEPT ![d][c] = "offline"]
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = FALSE]
  /\ wakeToken' = [wakeToken EXCEPT ![d][c] = FALSE]
  /\ request' =
       IF request.channel = c THEN NoRequest ELSE request
  /\ activeTransmit' =
       [activeTransmit EXCEPT ![c] =
         IF ShouldClearTransmitAfterMembershipLoss(d, c) THEN NoDevice ELSE @]
  /\ inbox' =
       IF ShouldClearTransmitAfterMembershipLoss(d, c)
       THEN NotifyMembers(c, TransmitEnded(c, activeTransmit[c], transmitEpoch[c]))
       ELSE inbox
  /\ knownTransmit' = [knownTransmit EXCEPT ![d][c] = NoDevice]
  /\ knownEpoch' = [knownEpoch EXCEPT ![d][c] = transmitEpoch[c]]
  /\ clientPhase' = [clientPhase EXCEPT ![d][c] = "notJoined"]
  /\ UNCHANGED transmitEpoch

JoinChannel(d, c) ==
  /\ ~IsMember(d, c)
  /\ request.status = "none"
  /\ members' = [members EXCEPT ![c] = @ \cup {d}]
  /\ presence' = [presence EXCEPT ![d][c] = "joined"]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

LeaveChannel(d, c) ==
  /\ IsMember(d, c)
  /\ members' = [members EXCEPT ![c] = @ \ {d}]
  /\ presence' = [presence EXCEPT ![d][c] = "offline"]
  /\ localJoinIntent' = [localJoinIntent EXCEPT ![d][c] = FALSE]
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = FALSE]
  /\ wakeToken' = [wakeToken EXCEPT ![d][c] = FALSE]
  /\ request' =
       IF request.channel = c THEN NoRequest ELSE request
  \* This initial model is for direct channels. If a member leaves while a
  \* transmit is active, the active transmit is no longer valid.
  /\ activeTransmit' =
       [activeTransmit EXCEPT ![c] =
         IF ShouldClearTransmitAfterMembershipLoss(d, c) THEN NoDevice ELSE @]
  /\ inbox' =
       IF ShouldClearTransmitAfterMembershipLoss(d, c)
       THEN NotifyMembers(c, TransmitEnded(c, activeTransmit[c], transmitEpoch[c]))
       ELSE inbox
  /\ knownTransmit' = [knownTransmit EXCEPT ![d][c] = NoDevice]
  /\ knownEpoch' = [knownEpoch EXCEPT ![d][c] = transmitEpoch[c]]
  /\ clientPhase' = [clientPhase EXCEPT ![d][c] = "notJoined"]
  /\ UNCHANGED transmitEpoch

UploadWakeToken(d, c) ==
  /\ IsMember(d, c)
  /\ wakeToken' = [wakeToken EXCEPT ![d][c] = TRUE]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

AddressableAfterTokenClear(receiver, tokenOwner, c) ==
  IsMember(receiver, c) /\
    (IF receiver = tokenOwner
    THEN IsJoined(receiver, c)
    ELSE IsJoined(receiver, c) \/ wakeToken[receiver][c])

ShouldClearTransmitAfterTokenClear(tokenOwner, c) ==
  activeTransmit[c] # NoDevice /\
    ~(\E receiver \in Devices :
        receiver # activeTransmit[c] /\
        AddressableAfterTokenClear(receiver, tokenOwner, c))

ClearWakeToken(d, c) ==
  /\ wakeToken[d][c]
  /\ wakeToken' = [wakeToken EXCEPT ![d][c] = FALSE]
  /\ activeTransmit' =
       [activeTransmit EXCEPT ![c] =
         IF ShouldClearTransmitAfterTokenClear(d, c) THEN NoDevice ELSE @]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

MarkReceiverReady(d, c) ==
  /\ IsJoined(d, c)
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = TRUE]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

MarkReceiverNotReady(d, c) ==
  /\ IsMember(d, c)
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = FALSE]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

AddressableAfterDisconnect(receiver, disconnected, c) ==
  IsMember(receiver, c) /\
    (IF receiver = disconnected
    THEN wakeToken[receiver][c]
    ELSE IsJoined(receiver, c) \/ wakeToken[receiver][c])

ShouldClearTransmitAfterDisconnect(disconnected, c) ==
  activeTransmit[c] # NoDevice /\
    ( activeTransmit[c] = disconnected \/
      ~(\E receiver \in Devices :
          receiver # activeTransmit[c] /\
          AddressableAfterDisconnect(receiver, disconnected, c)) )

Disconnect(d, c) ==
  /\ IsJoined(d, c)
  /\ presence' = [presence EXCEPT ![d][c] = "offline"]
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = FALSE]
  /\ activeTransmit' =
       [activeTransmit EXCEPT ![c] =
         IF ShouldClearTransmitAfterDisconnect(d, c) THEN NoDevice ELSE @]
  /\ inbox' =
       IF ShouldClearTransmitAfterDisconnect(d, c)
       THEN NotifyMembers(c, TransmitEnded(c, activeTransmit[c], transmitEpoch[c]))
       ELSE inbox
  /\ knownTransmit' = [knownTransmit EXCEPT ![d][c] = NoDevice]
  /\ knownEpoch' = [knownEpoch EXCEPT ![d][c] = transmitEpoch[c]]
  /\ clientPhase' = [clientPhase EXCEPT ![d][c] = PhaseAfterNoTransmit(d, c)]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  wakeToken,
                  transmitEpoch >>

Reconnect(d, c) ==
  /\ IsMember(d, c)
  /\ presence[d][c] = "offline"
  /\ presence' = [presence EXCEPT ![d][c] = "joined"]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

BeginTransmit(sender, c) ==
  /\ CanBeginTransmit(sender, c)
  /\ transmitEpoch[c] < MaxEpoch
  /\ activeTransmit' = [activeTransmit EXCEPT ![c] = sender]
  /\ transmitEpoch' = [transmitEpoch EXCEPT ![c] = @ + 1]
  /\ inbox' = NotifyPeers(c, sender, TransmitStarted(c, sender, transmitEpoch[c] + 1))
  /\ knownTransmit' = [knownTransmit EXCEPT ![sender][c] = sender]
  /\ knownEpoch' = [knownEpoch EXCEPT ![sender][c] = transmitEpoch[c] + 1]
  /\ clientPhase' = [clientPhase EXCEPT ![sender][c] = "transmitting"]
  /\ UNCHANGED << request, localJoinIntent, members, presence, receiverReady, wakeToken >>

EndTransmit(sender, c) ==
  /\ activeTransmit[c] = sender
  /\ activeTransmit' = [activeTransmit EXCEPT ![c] = NoDevice]
  /\ inbox' = NotifyPeers(c, sender, TransmitEnded(c, sender, transmitEpoch[c]))
  /\ knownTransmit' = [knownTransmit EXCEPT ![sender][c] = NoDevice]
  /\ knownEpoch' = [knownEpoch EXCEPT ![sender][c] = transmitEpoch[c]]
  /\ clientPhase' =
       [clientPhase EXCEPT ![sender][c] = PhaseAfterNoTransmit(sender, c)]
  /\ UNCHANGED << request, localJoinIntent, members, presence, receiverReady, wakeToken, transmitEpoch >>

ExpireTransmit(c) ==
  /\ activeTransmit[c] # NoDevice
  /\ activeTransmit' = [activeTransmit EXCEPT ![c] = NoDevice]
  /\ inbox' = NotifyMembers(c, TransmitEnded(c, activeTransmit[c], transmitEpoch[c]))
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  transmitEpoch,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

DeliverSignal(d) ==
  /\ Len(inbox[d]) > 0
  /\ LET message == Head(inbox[d]) IN
       /\ inbox' = [inbox EXCEPT ![d] = Tail(@)]
       /\ IF message.kind = "TransmitStarted"
             /\ message.sender \in Devices
             /\ message.sender # d
             /\ activeTransmit[message.channel] = message.sender
             /\ transmitEpoch[message.channel] = message.epoch
             /\ IsJoined(d, message.channel)
          THEN
            /\ knownTransmit' =
                 [knownTransmit EXCEPT ![d][message.channel] = message.sender]
            /\ knownEpoch' =
                 [knownEpoch EXCEPT ![d][message.channel] = message.epoch]
            /\ clientPhase' =
                 [clientPhase EXCEPT ![d][message.channel] = "receiving"]
          ELSE IF message.kind = "TransmitEnded"
               /\ message.sender \in Devices
               /\ knownTransmit[d][message.channel] = message.sender
               /\ knownEpoch[d][message.channel] = message.epoch
               /\ activeTransmit[message.channel] = NoDevice
               /\ transmitEpoch[message.channel] = message.epoch
          THEN
            /\ knownTransmit' =
                 [knownTransmit EXCEPT ![d][message.channel] = NoDevice]
            /\ knownEpoch' =
                 [knownEpoch EXCEPT ![d][message.channel] = message.epoch]
            /\ clientPhase' =
                 [clientPhase EXCEPT ![d][message.channel] =
                   PhaseAfterNoTransmit(d, message.channel)]
          ELSE
            /\ UNCHANGED << knownTransmit, knownEpoch, clientPhase >>
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch >>

DropSignal(d) ==
  /\ Len(inbox[d]) > 0
  /\ inbox' = [inbox EXCEPT ![d] = Tail(@)]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

DuplicateSignal(d) ==
  /\ Len(inbox[d]) > 0
  /\ Len(inbox[d]) < MaxInboxLength
  /\ inbox' = [inbox EXCEPT ![d] = Append(@, Head(@))]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  knownTransmit,
                  knownEpoch,
                  clientPhase >>

RefreshClient(d, c) ==
  /\ knownTransmit' = [knownTransmit EXCEPT ![d][c] = activeTransmit[c]]
  /\ knownEpoch' = [knownEpoch EXCEPT ![d][c] = transmitEpoch[c]]
  /\ clientPhase' = [clientPhase EXCEPT ![d][c] = PhaseFromBackend(d, c)]
  /\ UNCHANGED << request,
                  localJoinIntent,
                  members,
                  presence,
                  receiverReady,
                  wakeToken,
                  activeTransmit,
                  transmitEpoch,
                  inbox >>

Next ==
  \/ \E requester \in Devices, recipient \in Devices, c \in Channels :
       RequestConnection(requester, recipient, c)
  \/ \E recipient \in Devices, c \in Channels : DeclineRequest(recipient, c)
  \/ \E recipient \in Devices, c \in Channels : AcceptRequest(recipient, c)
  \/ \E d \in Devices, c \in Channels : CompleteLocalJoin(d, c)
  \/ \E d \in Devices, c \in Channels : FailLocalJoin(d, c)
  \/ \E d \in Devices, c \in Channels : JoinChannel(d, c)
  \/ \E d \in Devices, c \in Channels : LeaveChannel(d, c)
  \/ \E d \in Devices, c \in Channels : UploadWakeToken(d, c)
  \/ \E d \in Devices, c \in Channels : ClearWakeToken(d, c)
  \/ \E d \in Devices, c \in Channels : MarkReceiverReady(d, c)
  \/ \E d \in Devices, c \in Channels : MarkReceiverNotReady(d, c)
  \/ \E d \in Devices, c \in Channels : Disconnect(d, c)
  \/ \E d \in Devices, c \in Channels : Reconnect(d, c)
  \/ \E d \in Devices, c \in Channels : BeginTransmit(d, c)
  \/ \E d \in Devices, c \in Channels : EndTransmit(d, c)
  \/ \E c \in Channels : ExpireTransmit(c)
  \/ \E d \in Devices : DeliverSignal(d)
  \/ \E d \in Devices : DropSignal(d)
  \/ \E d \in Devices : DuplicateSignal(d)
  \/ \E d \in Devices, c \in Channels : RefreshClient(d, c)

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ request \in Request
  /\ localJoinIntent \in [Devices -> [Channels -> BOOLEAN]]
  /\ members \in [Channels -> SUBSET Devices]
  /\ presence \in [Devices -> [Channels -> PresenceValues]]
  /\ receiverReady \in [Devices -> [Channels -> BOOLEAN]]
  /\ wakeToken \in [Devices -> [Channels -> BOOLEAN]]
  /\ activeTransmit \in [Channels -> TransmitValue]
  /\ transmitEpoch \in [Channels -> 0..MaxEpoch]
  /\ inbox \in [Devices -> Seq(Message)]
  /\ knownTransmit \in [Devices -> [Channels -> TransmitValue]]
  /\ knownEpoch \in [Devices -> [Channels -> 0..MaxEpoch]]
  /\ clientPhase \in [Devices -> [Channels -> PhaseValues]]

DirectChannelCardinality ==
  \A c \in Channels : Cardinality(members[c]) <= 2

RequestEndpointsAreValid ==
  /\ request.status = "none" =>
       /\ request.requester = NoDevice
       /\ request.recipient = NoDevice
  /\ request.status = "requested" =>
       /\ request.requester \in Devices
       /\ request.recipient \in Devices
       /\ request.requester # request.recipient

PendingRequestHasNoMembership ==
  request.status = "requested" =>
    members[request.channel] = {}

LocalJoinIntentRequiresMembership ==
  \A d \in Devices, c \in Channels :
    localJoinIntent[d][c] => IsMember(d, c)

WakeTokenRequiresMembership ==
  \A d \in Devices, c \in Channels :
    wakeToken[d][c] => IsMember(d, c)

ReceiverReadyRequiresJoinedPresence ==
  \A d \in Devices, c \in Channels :
    receiverReady[d][c] => IsJoined(d, c)

ActiveTransmitterIsJoinedMember ==
  \A c \in Channels :
    activeTransmit[c] # NoDevice => IsJoined(activeTransmit[c], c)

ActiveTransmitHasAddressableReceiver ==
  \A c \in Channels :
    activeTransmit[c] # NoDevice =>
      HasAddressableReceiver(activeTransmit[c], c)

BeginTransmitRequiresAcceptedOrExplicitMembership ==
  \A c \in Channels :
    activeTransmit[c] # NoDevice =>
      request.status = "none"

ActiveTransmitRequiresBothDirectMembers ==
  \A c \in Channels :
    activeTransmit[c] # NoDevice =>
      Cardinality(members[c]) = 2

ReceivingHasLocalTransmitEvidence ==
  \A d \in Devices, c \in Channels :
    clientPhase[d][c] = "receiving" =>
      /\ knownTransmit[d][c] \in Devices
      /\ knownTransmit[d][c] # d
      /\ IsMember(d, c)

TransmittingHasLocalTransmitEvidence ==
  \A d \in Devices, c \in Channels :
    clientPhase[d][c] = "transmitting" =>
      knownTransmit[d][c] = d

LiveProjectionHasCurrentEpochEvidence ==
  \A d \in Devices, c \in Channels :
    clientPhase[d][c] \in {"transmitting", "receiving"} =>
      knownEpoch[d][c] = transmitEpoch[c]

DisconnectedClientIsNotLive ==
  \A d \in Devices, c \in Channels :
    ~IsJoined(d, c) =>
      clientPhase[d][c] \notin {"transmitting", "receiving"}

StaleMembershipWithoutLocalEvidenceIsNotJoining ==
  \A d \in Devices, c \in Channels :
    (/\ IsMember(d, c)
     /\ ~HasLocalJoinEvidence(d, c)
     /\ ~wakeToken[d][c]
     /\ activeTransmit[c] = NoDevice) =>
      clientPhase[d][c] # "joining"

NotJoinedProjectionHasNoLocalJoinIntent ==
  \A d \in Devices, c \in Channels :
    clientPhase[d][c] = "notJoined" =>
      ~localJoinIntent[d][c]

===============================================================================
