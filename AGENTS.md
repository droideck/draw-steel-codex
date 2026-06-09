# AGENTS.md

## Project context

See [CLAUDE.md](CLAUDE.md) for the full repository guide (DMHub Lua mod for the Draw Steel game system: module loading, game types, data tables, UI framework, GoblinScript, Lua constraints).

## Monster AI (active project)

The monster combat AI is being rebuilt as the **Draw Steel Warmind** module. Before doing ANY work related to monster AI, read [Draw Steel Warmind/CLAUDE.md](Draw%20Steel%20Warmind/CLAUDE.md) -- it is the canonical knowledge store: verified engine API surface, architecture contracts, design rules, lessons learned, stage roadmap and status, and test checklists. Do not re-explore the engine for anything already documented there, and update that file when a stage completes.

Legacy systems, for reference only:

- `Monster AI/` -- the previous AI module. Still loaded and functional; stays until the Warmind Stage 7 cutover. Do not extend it.
- Root-level `DirectorTactics*.lua` -- an abandoned framework, not loaded by `main.lua`. Never use it as a foundation, never import its code, and never reintroduce its patterns (phase bus, multi-flow pipeline, candidate mega-normalization, resource ledger, manual-handoff runtime).
