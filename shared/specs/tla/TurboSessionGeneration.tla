------------------------ MODULE TurboSessionGeneration ------------------------
EXTENDS Naturals, FiniteSets, TLC

\* A focused model for app/backend session identity generations.
\*
\* This deliberately leaves the full message-delivery state space to
\* TurboCommunication.tla. Here the question is narrower: can stale backend
\* membership, presence, active-channel, or receiver-ready facts survive an app
\* restart and be projected as current-session truth?

CONSTANTS
  Devices,
  Channels,
  NoDevice,
  NoChannel,
  MaxGeneration

ASSUME NoDevice \notin Devices
ASSUME NoChannel \notin Channels
ASSUME MaxGeneration \in Nat

VARIABLES
  sessionGeneration,
  connected,
  members,
  presence,
  presenceGeneration,
  activeChannel,
  activeChannelGeneration,
  receiverReady,
  receiverReadyGeneration,
  activeTransmit

vars ==
  << sessionGeneration,
     connected,
     members,
     presence,
     presenceGeneration,
     activeChannel,
     activeChannelGeneration,
     receiverReady,
     receiverReadyGeneration,
     activeTransmit >>

PresenceValues == {"offline", "joined"}
ChannelValue == Channels \cup {NoChannel}
TransmitValue == Devices \cup {NoDevice}

IsMember(d, c) == d \in members[c]
PresenceIsCurrent(d, c) == presenceGeneration[d][c] = sessionGeneration[d]
ActiveChannelIsCurrent(d) == activeChannelGeneration[d] = sessionGeneration[d]
ReceiverReadyIsCurrent(d, c) == receiverReadyGeneration[d][c] = sessionGeneration[d]

IsJoinedCurrent(d, c) ==
  /\ connected[d]
  /\ IsMember(d, c)
  /\ presence[d][c] = "joined"
  /\ PresenceIsCurrent(d, c)

IsReadyCurrent(d, c) ==
  /\ IsJoinedCurrent(d, c)
  /\ receiverReady[d][c]
  /\ ReceiverReadyIsCurrent(d, c)

NoPresence == [d \in Devices |-> [c \in Channels |-> "offline"]]
NoGenerationByChannel == [d \in Devices |-> [c \in Channels |-> 0]]
NoReady == [d \in Devices |-> [c \in Channels |-> FALSE]]

Init ==
  /\ sessionGeneration = [d \in Devices |-> 0]
  /\ connected = [d \in Devices |-> TRUE]
  /\ members = [c \in Channels |-> {}]
  /\ presence = NoPresence
  /\ presenceGeneration = NoGenerationByChannel
  /\ activeChannel = [d \in Devices |-> NoChannel]
  /\ activeChannelGeneration = [d \in Devices |-> 0]
  /\ receiverReady = NoReady
  /\ receiverReadyGeneration = NoGenerationByChannel
  /\ activeTransmit = [c \in Channels |-> NoDevice]

JoinChannel(d, c) ==
  /\ connected[d]
  /\ ~IsMember(d, c)
  /\ members' = [members EXCEPT ![c] = @ \cup {d}]
  /\ presence' = [presence EXCEPT ![d][c] = "joined"]
  /\ presenceGeneration' =
       [presenceGeneration EXCEPT ![d][c] = sessionGeneration[d]]
  /\ activeChannel' = [activeChannel EXCEPT ![d] = c]
  /\ activeChannelGeneration' =
       [activeChannelGeneration EXCEPT ![d] = sessionGeneration[d]]
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = FALSE]
  /\ receiverReadyGeneration' =
       [receiverReadyGeneration EXCEPT ![d][c] = sessionGeneration[d]]
  /\ UNCHANGED << sessionGeneration, connected, activeTransmit >>

MarkReceiverReady(d, c) ==
  /\ IsJoinedCurrent(d, c)
  /\ receiverReady' = [receiverReady EXCEPT ![d][c] = TRUE]
  /\ receiverReadyGeneration' =
       [receiverReadyGeneration EXCEPT ![d][c] = sessionGeneration[d]]
  /\ UNCHANGED << sessionGeneration,
                  connected,
                  members,
                  presence,
                  presenceGeneration,
                  activeChannel,
                  activeChannelGeneration,
                  activeTransmit >>

BeginTransmit(sender, c) ==
  /\ activeTransmit[c] = NoDevice
  /\ IsJoinedCurrent(sender, c)
  /\ \E receiver \in Devices :
       receiver # sender /\ IsReadyCurrent(receiver, c)
  /\ activeTransmit' = [activeTransmit EXCEPT ![c] = sender]
  /\ UNCHANGED << sessionGeneration,
                  connected,
                  members,
                  presence,
                  presenceGeneration,
                  activeChannel,
                  activeChannelGeneration,
                  receiverReady,
                  receiverReadyGeneration >>

EndTransmit(sender, c) ==
  /\ activeTransmit[c] = sender
  /\ activeTransmit' = [activeTransmit EXCEPT ![c] = NoDevice]
  /\ UNCHANGED << sessionGeneration,
                  connected,
                  members,
                  presence,
                  presenceGeneration,
                  activeChannel,
                  activeChannelGeneration,
                  receiverReady,
                  receiverReadyGeneration >>

RestartApp(d) ==
  /\ sessionGeneration[d] < MaxGeneration
  /\ sessionGeneration' = [sessionGeneration EXCEPT ![d] = @ + 1]
  /\ connected' = [connected EXCEPT ![d] = FALSE]
  /\ presence' =
       [presence EXCEPT ![d] = [c \in Channels |-> "offline"]]
  /\ presenceGeneration' =
       [presenceGeneration EXCEPT ![d] =
         [c \in Channels |-> sessionGeneration[d] + 1]]
  /\ activeChannel' = [activeChannel EXCEPT ![d] = NoChannel]
  /\ activeChannelGeneration' =
       [activeChannelGeneration EXCEPT ![d] = sessionGeneration[d] + 1]
  /\ receiverReady' =
       [receiverReady EXCEPT ![d] = [c \in Channels |-> FALSE]]
  /\ receiverReadyGeneration' =
       [receiverReadyGeneration EXCEPT ![d] =
         [c \in Channels |-> sessionGeneration[d] + 1]]
  /\ activeTransmit' =
       [c \in Channels |->
         IF activeTransmit[c] = d THEN NoDevice ELSE activeTransmit[c]]
  /\ UNCHANGED members

Reconnect(d) ==
  /\ ~connected[d]
  /\ connected' = [connected EXCEPT ![d] = TRUE]
  /\ UNCHANGED << sessionGeneration,
                  members,
                  presence,
                  presenceGeneration,
                  activeChannel,
                  activeChannelGeneration,
                  receiverReady,
                  receiverReadyGeneration,
                  activeTransmit >>

ApplyPresenceSnapshot(d, c, snapshotGeneration, snapshotPresence) ==
  /\ connected[d]
  /\ snapshotGeneration = sessionGeneration[d]
  /\ snapshotPresence \in PresenceValues
  /\ snapshotPresence = "joined" => IsMember(d, c)
  /\ presence' = [presence EXCEPT ![d][c] = snapshotPresence]
  /\ presenceGeneration' =
       [presenceGeneration EXCEPT ![d][c] = snapshotGeneration]
  /\ receiverReady' =
       [receiverReady EXCEPT ![d][c] =
         IF snapshotPresence = "joined" THEN @ ELSE FALSE]
  /\ receiverReadyGeneration' =
       [receiverReadyGeneration EXCEPT ![d][c] = snapshotGeneration]
  /\ activeChannel' =
       [activeChannel EXCEPT ![d] =
         IF snapshotPresence = "joined" THEN @
         ELSE IF activeChannel[d] = c THEN NoChannel ELSE @]
  /\ activeChannelGeneration' =
       [activeChannelGeneration EXCEPT ![d] =
         IF snapshotPresence = "joined" THEN @ ELSE snapshotGeneration]
  /\ activeTransmit' =
       [activeTransmit EXCEPT ![c] =
         IF snapshotPresence = "joined" THEN @
         ELSE IF activeTransmit[c] = d THEN NoDevice ELSE @]
  /\ UNCHANGED << sessionGeneration,
                  connected,
                  members >>

ApplyActiveChannelSnapshot(d, snapshotGeneration, snapshotChannel) ==
  /\ connected[d]
  /\ snapshotGeneration = sessionGeneration[d]
  /\ snapshotChannel \in ChannelValue
  /\ snapshotChannel # NoChannel =>
       /\ IsMember(d, snapshotChannel)
       /\ presence[d][snapshotChannel] = "joined"
       /\ presenceGeneration[d][snapshotChannel] = sessionGeneration[d]
  /\ activeChannel' = [activeChannel EXCEPT ![d] = snapshotChannel]
  /\ activeChannelGeneration' =
       [activeChannelGeneration EXCEPT ![d] = snapshotGeneration]
  /\ UNCHANGED << sessionGeneration,
                  connected,
                  members,
                  presence,
                  presenceGeneration,
                  receiverReady,
                  receiverReadyGeneration,
                  activeTransmit >>

Next ==
  \/ \E d \in Devices, c \in Channels : JoinChannel(d, c)
  \/ \E d \in Devices, c \in Channels : MarkReceiverReady(d, c)
  \/ \E d \in Devices, c \in Channels : BeginTransmit(d, c)
  \/ \E d \in Devices, c \in Channels : EndTransmit(d, c)
  \/ \E d \in Devices : RestartApp(d)
  \/ \E d \in Devices : Reconnect(d)
  \/ \E d \in Devices, c \in Channels,
        g \in 0..MaxGeneration,
        p \in PresenceValues :
       ApplyPresenceSnapshot(d, c, g, p)
  \/ \E d \in Devices,
        g \in 0..MaxGeneration,
        c \in ChannelValue :
       ApplyActiveChannelSnapshot(d, g, c)

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ sessionGeneration \in [Devices -> 0..MaxGeneration]
  /\ connected \in [Devices -> BOOLEAN]
  /\ members \in [Channels -> SUBSET Devices]
  /\ presence \in [Devices -> [Channels -> PresenceValues]]
  /\ presenceGeneration \in [Devices -> [Channels -> 0..MaxGeneration]]
  /\ activeChannel \in [Devices -> ChannelValue]
  /\ activeChannelGeneration \in [Devices -> 0..MaxGeneration]
  /\ receiverReady \in [Devices -> [Channels -> BOOLEAN]]
  /\ receiverReadyGeneration \in [Devices -> [Channels -> 0..MaxGeneration]]
  /\ activeTransmit \in [Channels -> TransmitValue]

JoinedPresenceUsesCurrentSession ==
  \A d \in Devices, c \in Channels :
    presence[d][c] = "joined" =>
      /\ connected[d]
      /\ PresenceIsCurrent(d, c)
      /\ IsMember(d, c)

ActiveChannelUsesCurrentSession ==
  \A d \in Devices :
    activeChannel[d] # NoChannel =>
      /\ connected[d]
      /\ ActiveChannelIsCurrent(d)
      /\ IsMember(d, activeChannel[d])
      /\ presence[d][activeChannel[d]] = "joined"

ReceiverReadyUsesCurrentSession ==
  \A d \in Devices, c \in Channels :
    receiverReady[d][c] =>
      /\ IsJoinedCurrent(d, c)
      /\ ReceiverReadyIsCurrent(d, c)

ActiveTransmitterUsesCurrentSession ==
  \A c \in Channels :
    activeTransmit[c] # NoDevice =>
      IsJoinedCurrent(activeTransmit[c], c)

===============================================================================
