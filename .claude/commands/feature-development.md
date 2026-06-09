---
description: Plan-first feature development with minimal reviewable diffs
---

Core working rules in CLAUDE.md apply; this file is only the deltas.

1. Plan before code, ≤10 lines: approach, files touched, risks, test plan. Wait for OK (unattended: proceed + `ASSUMPTIONS`).
2. Build exactly the plan. Newly discovered scope → `FLAGS`, don't build it.
3. Minimal reviewable diff. Match repo conventions; zero drive-by reformatting.
4. Tests cover changed behavior only. Run the narrowest target (single file/case), not the suite; paste failures only. (In this repo there is no command-line test runner — verification happens in the DMHub app; state what the user should exercise in-app instead.)
5. Verify the touched surface (lint, typecheck, targeted tests) → report `pass` or the failing lines.
6. Offload boilerplate, scaffolding, and mechanical edits per Core delegation rules.
7. Done = checks green + ≤10-line summary: what changed, how verified, `FLAGS`/`ASSUMPTIONS`.

$ARGUMENTS
