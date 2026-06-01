# Unison Guide

Status: active BeepBeep kernel workflow.

Active Unison project: `bb/main`.
Active namespace: `beepbeep.*`.
Language reference: [`UNISON_LANGUAGE.md`](/Users/mau/Development/bb/docs/backend/UNISON_LANGUAGE.md).

The Rust runtime calls the pure kernel from [`backend/runtime`](/Users/mau/Development/bb/backend/runtime). The old `turbo.*` Cloud service path is archive/reference only.

## Rules

- Put new active backend kernel definitions under `beepbeep.*`.
- Use Unison MCP/UCM as source of truth for kernel code; repo-root `.u` files are scratch only.
- Keep effects out of the kernel. The kernel returns decisions, snapshots, policies, and effect plans; Rust owns HTTP, WebSocket, Postgres, Redis, APNs handoff, relay integration, metrics, and process lifecycle.
- Model invalid states out with domain types before adding runtime compensation.
- Add or update corpus cases when changing kernel behavior.

## Proofs

| Need | Command |
| --- | --- |
| Run kernel tests | `just kernel-test` |
| Run kernel fuzz/tests | `just kernel-fuzz` |
| Export corpus JSON for Rust/runtime proof | `just kernel-corpus-json /tmp/turbo-kernel-corpus.json` |
| Run the backend gate that consumes kernel evidence | `just beepbeep-backend-gate` |

Kernel behavior is not trusted in staging until the Rust runtime gate has exercised the exported corpus or equivalent runtime proof.

## Scratch Files

When iterating on Unison code, use a small scratch `.u` file outside source control or in a temporary workspace. Typecheck it through MCP/UCM, then update `bb/main:.beepbeep` through the Unison toolchain.

Do not preserve repo-root scratch files as active documentation. If a scratch file contains useful history, move the explanation into a doc or handoff and keep the active definition in `bb/main`.

## Naming

Use [`GLOSSARY.md`](/Users/mau/Development/bb/GLOSSARY.md) before introducing or renaming domain concepts. Keep Apple/PTT, transport, relay, runtime, and kernel terms separated at their real boundaries.
