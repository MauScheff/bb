# Agent Collaboration Prompts

Use these as source material for starting high-signal Turbo debugging sessions. Keep prompts concise; agents should read `AGENTS.md` and the latest relevant handoff instead of relying on long pasted context.

## Reliability Session Prompt

```text
We are debugging Turbo end-to-end PushToTalk reliability on physical devices.
Goal: receiver hears first-press audio across foreground, background, lock-screen, and network-transition cases.

Use repo tooling before asking for device retests. Read AGENTS.md and the latest relevant handoff. Classify ownership before editing. Convert shared app/backend failures into engine, Swift, backend, simulator, fuzz, replay, or TLA+ proof. Ask me for physical-device steps only for Apple/PTT/audio boundaries.
```

## Style Instruction

```text
Be clear, concise, and specific. When you need me to do device work, give exact numbered steps and stop at the first serious failure.
```

## Useful Bug Report Shape

```text
Handles:
Devices:
Backend:
Build:
Cell:
Transport mode:
Starting app states:
Observed:
Expected:
Shake incident IDs:
Approximate timestamp:
```
