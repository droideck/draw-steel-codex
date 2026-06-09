# AGENTS.md

## Project context

This repository is implementing a new tiny Draw Steel monster AI core.

The old DirectorTactics system is being deprecated. It must not be used as the runtime foundation for the new monster AI core. DirectorTactics may be inspected as legacy reference only.

The preferred direction is a small MonsterAI-derived Lua utility selector with explicit contracts, stable reason codes, conservative prompt handling, and optional monster override packs.

## Grounding rules

- Do not invent module names, test commands, load files, APIs, or repository structure.
- Before documenting architecture, inspect the repository and cite the actual files you inspected in the generated docs.
- If a fact is not present in the repository or in docs/ai/research, write `TBD` or `Needs verification`.
- Do not copy DirectorTactics code into the new core.
- Do not reintroduce a DirectorTactics-style pipeline, phase bus, resource ledger, or broad encounter-planning framework.
- Do not implement gameplay behavior during Stage 0.
- Documentation must separate:
  - confirmed repository facts
  - research-derived recommendations
  - chosen design decisions
  - open questions

## Stage 0 definition of done

Stage 0 is complete only when:
- docs/ai/source-facts.md exists.
- docs/ai/open-questions.md exists.
- docs/ai/architecture.md exists and is grounded in source-facts.md.
- docs/ai/migration-plan.md exists.
- docs/ai/reason-codes.md exists.
- docs/ai/legacy-directortactics-notes.md exists.
- No gameplay behavior has changed.
- No DirectorTactics code has been copied into the new core.
- Any placeholder Lua modules are syntactically minimal and clearly marked as stubs.

