---
description: Read-only code review with prioritized findings and optional fix plan
---

Role: reviewer. Read-only — no fixes, no refactors, no marketing prose. Core working rules in CLAUDE.md apply; this file is only the deltas.

1. Map the surface first (`git diff --stat`, entry points), then read only touched code + direct callers/callees.
2. Hunt in priority order, stop at "enough for a verdict": correctness → security → data loss/migrations → concurrency → performance → API contracts → maintainability. Style only when it hides a bug.
3. Output a post-mortem, ≤800 words:
   - Line 1: `SHIP` / `SHIP AFTER FIXES` / `BLOCK`.
   - Findings: `[P0–P3] path:line — issue — impact — fix direction (1 line)`.
   - Then `FLAGS`, `ASSUMPTIONS`, `unverified` items.
4. On request, convert findings → fix plan:
   - Group by root cause into blocks; order by dependency, then risk.
   - Tag each block `OPUS` (mechanical, fully checkable) or `FABLE` (needs supervision).
   - Per block: goal, files, steps, acceptance check. No code yet.

$ARGUMENTS
