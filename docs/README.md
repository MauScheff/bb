# Docs

This directory keeps BeepBeep's larger memory without making every historical note part of the active working surface.

| Area | Path | Use |
| --- | --- | --- |
| Architecture | `docs/architecture/` | Agent-native structure doctrine, module boundaries, effect surfaces, and verification strategy. |
| Client | `docs/client/` | iOS, Swift, PushToTalk, audio, simulator, and device notes. |
| Backend | `docs/backend/` | Runtime, kernel, infra, storage, deploy, and backend reliability notes. |
| Reliability | `docs/reliability/` | Invariants, fuzzing, telemetry, TLA+, repair, and incident workflows. |
| Product | `docs/product/` | Brand, thesis, product brief, demo, and design notes. |
| Reference | `docs/reference/` | Historical or broad docs kept for search and archaeology. |
| Assets | `docs/assets/` | Diagrams and visual references. |

Active implementation should route through root docs first: `AGENTS.md`, `README.md`, `WORKFLOW.md`, `TOOLING.md`, `TESTING.md`, and `GLOSSARY.md`.

Reliability work should route through [`WORKFLOW.md`](/Users/mau/Development/bb/WORKFLOW.md) for the canonical proof model and [`docs/reliability/fuzz.md`](/Users/mau/Development/bb/docs/reliability/fuzz.md) for the operator loop:

```text
invariant -> generated interleavings -> replay/shrink -> owner -> narrow regression -> fix -> gate
```
