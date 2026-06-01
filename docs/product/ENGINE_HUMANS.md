# Turbo Engine Orientation

Status: agent-facing plain-language brief. Use this for context, then use [`ENGINE.md`](/Users/mau/Development/bb/ENGINE.md) as the exact contract.

Turbo Engine decides local talk-session truth:

- whether two people are connected
- whether local talk is allowed
- whether receive audio is idle, waiting for PushToTalk activation, receiving, draining, or failed
- whether transport is relayed, Fast Relay, Direct QUIC, recovering, or unavailable
- whether a callback belongs to the current attempt/epoch or is stale

## Model

The engine is a Foundation-only Swift package. It:

1. receives typed intents/events
2. updates one typed state machine
3. returns a snapshot for UI/tests
4. returns effects for adapters to execute
5. records diagnostics and invariant violations

It does not call Apple PushToTalk, play audio, make network requests, or draw UI. The app executes effects and reports typed results back.

## Algebraic Shape

Do not model truth as bundles like:

```text
isJoined = true
isReady = false
isTransmitting = true
status = "waiting"
activeChannelID = nil
```

Model the phase and evidence:

```text
session = joined(with evidence)
transmit = active(with transmit epoch)
receive = idle
transport = fastRelay(with evidence)
talkCapability = available(with evidence)
```

Readiness and capability must carry proof or typed absence:

- unavailable: no Friend, no session, unsupported capability
- pending: waiting for backend, Friend device, PTT, media, transport
- blocked: known reason prevents action
- failed: typed failure reason and recovery path

## Ownership

| Owner | Truth |
| --- | --- |
| Engine | selected Conversation, session phase, transmit phase, receive phase, transport phase, lifecycle effect on receive, PTT activation state, synthetic playback scheduling facts |
| Backend | identity, devices, Beeps, channel membership, transmit grants, wake targeting, shared readiness |
| Apple/platform | real PushToTalk UI, system audio activation, microphone permission, background and lock-screen behavior |
| App adapters | SwiftUI, `PTTViewModel`, AVAudio, Fast Relay, Direct QUIC, backend client execution of engine effects |

`PTTViewModel` publishes UI fields, but those fields must derive from `TurboEngineSnapshot` or typed app projections. Old-shaped booleans may exist only as derived external-boundary outputs; they must not feed back into the engine as evidence.

## Example Flow

1. Both participants join a backend channel.
2. Backend joined evidence enters each engine.
3. Sender presses hold-to-talk.
4. Engine checks talk capability and returns Apple/backend/media effects.
5. Backend accepts and returns a transmit ID.
6. Sender engine enters active transmit; app captures audio.
7. Receiver engine receives remote start and audio chunks.
8. If locked, receiver buffers chunks and requests PushToTalk activation.
9. On activation, receiver schedules buffered playback.
10. Sender releases; engine ends the matching epoch and rejects stale callbacks.

## Debug Questions

- Which session/transmit/receive/transport phase is active?
- What evidence proves readiness?
- If blocked or failed, what typed reason is present?
- What effect did the engine emit?
- Did the adapter report completion/failure back as a typed event?
- Which attempt, channel, transmit ID, device ID, or epoch fences this callback?

## Good Changes

Prefer changes that:

- remove contradictory booleans
- move data into the state that owns it
- add typed failure/recovery reasons
- fence stale work by attempt/channel/transmit/epoch identity
- make duplicate events idempotent
- add fast engine proof for impossible states
- make simulator/device testing unnecessary for lower-level rules

Avoid changes that:

- add source-of-truth booleans
- copy backend strings deeper into app logic
- let UI state decide session truth
- accept stale callbacks without identity checks
- hide two competing truths behind precedence rules

## Commands

```bash
just engine-test
just engine-scenario foreground_transmit_receive
just serve-local
just engine-scenario-local foreground_transmit_receive
just engine-fuzz-local 12345 500
```

Use simulator and physical-device tests for integration and Apple behavior, not basic engine correctness.
