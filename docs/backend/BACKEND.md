# Backend Guide

Status: active backend working guide.

Current backend: BeepBeep Rust runtime plus pure Unison kernel under [`backend`](/Users/mau/Development/bb/backend). Canonical hosted base URL:

```text
https://api.beepbeep.to
```

The old Unison Cloud backend remains available only through the archive checkout and [`docs/reference/backend-legacy`](/Users/mau/Development/bb/docs/reference/backend-legacy). Do not add new active backend behavior to the old `turbo.*` service path unless the task explicitly targets archaeology or maintenance.

## Ownership

| Surface | Owner | Path |
| --- | --- | --- |
| Runtime QUIC/TLS/HTTP control process, Postgres, Redis, deploy packaging, runtime effects | Rust runtime | [`backend/runtime`](/Users/mau/Development/bb/backend/runtime) |
| Control-plane meaning, command decisions, effect plans, fixtures, semantic tests | Unison kernel | `bb/main:.beepbeep` |
| Relay/media integration | Backend-owned Rust relay module | [`backend/relay`](/Users/mau/Development/bb/backend/relay) |
| App-visible backend contract | backend plus iOS client boundary | [`client/ios/Turbo/BackendClient.swift`](/Users/mau/Development/bb/client/ios/Turbo/BackendClient.swift) |

Backend scope remains control-plane-first unless explicitly changed: auth/dev identity, device registration, Conversation membership, readiness, wake target selection, Talk Turn authority, runtime QUIC/TLS/HTTP control, and runtime diagnostics.

## Required Docs

Start here for active backend work:

- [`backend/README.md`](/Users/mau/Development/bb/backend/README.md)
- [`backend/docs/ARCHITECTURE.md`](/Users/mau/Development/bb/backend/docs/ARCHITECTURE.md)
- [`UNISON.md`](/Users/mau/Development/bb/docs/backend/UNISON.md)
- [`UNISON_LANGUAGE.md`](/Users/mau/Development/bb/docs/backend/UNISON_LANGUAGE.md)
- [`TOOLING.md`](/Users/mau/Development/bb/TOOLING.md)

Use legacy backend docs only when reading old Cloud behavior or recovering old algebra.

## Proof Ladder

| Claim | First proof lane | Escalate when |
| --- | --- | --- |
| Kernel decision semantics | `just kernel-fuzz` | Rust runtime effect execution matters |
| Kernel/Rust contract | `just kernel-corpus-json`, then runtime tests | Postgres, Redis, or runtime transport behavior matters |
| Runtime behavior | `just rust-runtime-test`, `just runtime-postgres-integration` | deployed production behavior matters |
| App-compatible runtime-control surface | `just self-hosted-http-probe`, `just runtime-control-probe` | simulator app integration matters |
| Broad backend confidence | `just beepbeep-backend-gate` | hosted production must be proven |
| Hosted production confidence | `just beepbeep-backend-production-gate` | Apple/PTT/audio hardware remains the only unknown |

Promote failures downward whenever possible. A production failure should become a hosted probe, self-hosted probe, runtime test, kernel corpus case, or named invariant.

## Done Condition

A backend change is done when:

- the owner is clear: kernel, runtime, relay, client boundary, or Apple/PTT/audio boundary
- the lowest useful proof lane passes
- production-facing changes have `just beepbeep-backend-production-gate` or an explicit reason not to run it
- new impossible behavior is represented as an invariant, regression, corpus case, or scenario
- artifact paths and seeds are recorded when fuzzing or scenario tooling finds a failure
