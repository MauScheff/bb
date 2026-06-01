# Handoffs

This directory is the operational memory for the repo.

For changelog-style design notes, rejected approaches, and durable debugging lessons, use [`journal/`](/Users/mau/Development/Turbo/journal). Handoffs are for resuming active work; journal entries are for preserving why a design or debugging conclusion matters.

Each handoff is a timestamped markdown file that records:

- where the repo currently is
- what was proven
- what is not working
- what changed recently
- the recommended next debugging or implementation path

Use this instead of maintaining a single mutable handoff document.

## Read order

When starting fresh:

1. Read [`README.md`](/Users/mau/Development/Turbo/README.md)
2. Read [`AGENTS.md`](/Users/mau/Development/Turbo/AGENTS.md)
3. Read the latest timestamped handoff in this directory
4. Read older handoffs only if you need historical context for the same bug or subsystem

## File naming

Use this format:

- `YYYY-MM-DD-HHMM.md`

Example:

- `2026-04-12-1329.md`

Use local repo time for the timestamp.

## When to create a new handoff

Create a new handoff when:

- the user explicitly asks for a handoff
- you are ending a substantial debugging or implementation session
- the current blocker changed materially
- the recommended next step changed materially

Do not overwrite old handoffs. Add a new one.

## What a good handoff includes

Keep it concise but decisive.

Recommended sections:

- `Summary`
- `Current truth`
- `What changed this session`
- `What is not working`
- `Recommended next step`
- `Commands that matter`
- `Files that matter`

## Best practices

- Prefer concrete facts over speculation.
- Distinguish between what is proven and what is still a hypothesis.
- Include exact commands when they are part of the next-step loop.
- Name the actual current blocker, not the historical one.
- If the source of truth moved, say what is authoritative now.
- Link the most relevant files directly.
- If there are multiple active threads, say which one should be picked up first.
