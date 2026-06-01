# Journal

This directory is the engineering journal for the repo.

Use it for concise, dense, timestamped notes about what we learned, what design choice changed, and why a particular debugging path worked. A journal entry is closer to a changelog plus design log than a handoff.

Use [`handoffs/`](/Users/mau/Development/Turbo/handoffs) when the main purpose is to resume work later. Use `journal/` when the main purpose is to preserve the reasoning, invariant, or architectural lesson from a session.

## Read order

When investigating a recurring behavior:

1. Read the latest relevant handoff in [`handoffs/`](/Users/mau/Development/Turbo/handoffs) for current state.
2. Search this directory for the subsystem, invariant, or symptom.
3. Read journal entries only when they explain the design pressure behind current code.

## File naming

Use this format:

- `YYYY-MM-DD-HHMM.md`

Example:

- `2026-05-05-1359.md`

Use local repo time for the timestamp.

## When to create a journal entry

Create a new journal entry when:

- a bug reveals a better architectural formulation
- a fix works because of a specific invariant or ownership boundary
- a debugging session overturns a plausible but wrong approach
- a performance result depends on a subtle sequencing or concurrency decision
- the user explicitly asks for a journal/changelog-style record

Do not overwrite old journal entries. Add a new one.

## What a good journal entry includes

Keep it concise but information-dense.

Recommended sections:

- `Summary`
- `Problem`
- `Design formulation`
- `What changed`
- `What worked`
- `What not to repeat`
- `Verification`
- `Next`
- `Files`

## Best practices

- State the invariant or ownership boundary in plain language.
- Distinguish confirmed facts from hypotheses.
- Prefer cause and effect over chronology.
- Include the diagnostic phrases that proved the issue.
- Link the files that encode the design.
- Keep journal entries useful even after the immediate bug is fixed.
