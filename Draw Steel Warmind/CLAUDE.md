# Draw Steel Warmind

Monster combat AI for Draw Steel in DMHub. Ground-up replacement for the `Monster AI/` module (and the abandoned root-level DirectorTactics framework). When active, it plays Director turns: selects which monster group activates, moves tokens, picks abilities and targets, casts, and advances initiative.

**READ THIS FILE FIRST when working on Warmind.** It contains the verified engine API surface, the architecture contracts, and the hard-won lessons from the initial build. Do not re-explore the engine or the legacy AIs to rediscover what is documented here -- everything in the "Verified engine surface" and "Lessons learned" sections was confirmed by direct source inspection and multi-pass review. Only verify engine APIs that are NOT yet listed here. To deploy changes and verify them at runtime without any manual user step, follow the "Autonomous dev loop" section (mod-store write -> automatic hot reload -> read-only bridge probes).

## Design rules (non-negotiable)

1. **Utility selector, not a framework.** One entry point per decision. No phase bus, no pipeline flows, no resource ledger, no candidate mega-normalization. These are the specific patterns that killed DirectorTactics (28k lines, dead on arrival).
2. **Generic competence from ability traits.** Monsters with no hand-written behavior must play their stat blocks sensibly via trait-driven generic specs. Bespoke monsters are an optional override layer.
3. **Fail closed, loudly.** Every decision produces a DecisionResult with status (`executed | held | manual | skipped`) and a stable UPPER_SNAKE reason code from `Warmind.reason`. Unsupported complexity ends an activation cleanly; it never improvises and never hangs.
4. **All world mutation goes through WarmindAdapter.** Scoring and selection are read-only.
5. **Never wrap yielding code in pcall.** Use `Warmind.Guard` (nested coroutine). See Lessons learned.

## File map (load order matters)

| File | Responsibility |
|---|---|
| `WarmindCore.lua` | `Warmind` global, reason codes, DecisionResult constructors, registries (specs/prompts/tactics/overrides), trace buffer, `Warmind.Guard`, `Warmind.Sleep`, pacing setting, stop flag |
| `WarmindTraits.lua` | Pure ability classifier: `Warmind.Traits.Get(ability)` -> flat trait table (actionKind, isStrike/isMelee/isRanged/isAoe, isSignature, villainAction). Prefer structured fields; avoid description-text parsing |
| `WarmindSnapshot.lua` | `Warmind.Snapshot.Build(token)` -> read-only decision input: enemies/allies, abilities+traits, action budget, malice, moveRemaining, reachable paths. Rebuilt every decision iteration |
| `WarmindAdapter.lua` | THE engine seam: BeginControl/Release (prompt interception), ExecuteAbilityAndWait (watchdogged cast), MoveTo, RecheckStrikeTargets, Speech, SetExpectedPrompt |
| `WarmindScoring.lua` | FindValidStrikeTargets / FindBestStrikePosition / FindBestBurstPosition (ports of proven baseline algorithms), tactic-bias hook. Role weight profiles land here (Stage 3) |
| `WarmindSpecs.lua` | Generic action specs. Stage 1: melee/ranged free strike. Stage 2 adds the full set |
| `WarmindPrompts.lua` | Prompt handlers (Stage 2 stub; unknown prompts fall through to manual with UNSUPPORTED_COMPLEX_PROMPT) |
| `WarmindSquads.lua` | Minion squad subsystem. Stage 1: CollectSquad + fail-closed hold (UNSUPPORTED_SQUAD) |
| `WarmindTurn.lua` | The activation loop: snapshot -> enumerate legal candidates for remaining budget -> pick best -> execute -> repeat. Turn driver + initiative advancement + manualPending |
| `WarmindDirector.lua` | Encounter layer, deliberately thin. Stage 1: activation chooser (closest-to-player). Stage 4: malice policy + villain scheduler |
| `WarmindOverrides.lua` | Per-monster override packs (Stage 6 stub) |
| `WarmindPanel.lua` | DM-only dockable panel + the polling thread. Start/Stop, decision trace. Stage 5: step mode, persisted toggles |

## Core contracts

```lua
-- DecisionResult (constructors in WarmindCore)
{ status = "executed"|"held"|"manual"|"skipped", reasonCode = Warmind.reason.X, reason = "prose", detail = {...} }

-- Candidate (returned by spec.score)
{ score = number, loc = Loc|nil, ... }  -- arbitrary extra data flows to execute

-- Spec contract
Warmind.RegisterSpec{
    id, name, category = "main"|"maneuver"|"move"|"free", description,
    abilities = {"Ability Name", ...},   -- optional; must exist + be affordable
    monsters = {"Monster Type", ...},    -- optional; omitted = generic
    score = function(spec, ctx, snapshot, abilities) -> candidate|nil,
    execute = function(spec, ctx, candidate, abilities) -> DecisionResult|nil,  -- nil = executed
}

-- Prompt handler contract
Warmind.RegisterPrompt{
    prompts = {"Shift"} or {"Monster Type:Ability"},
    handler = function(ctx, invokerToken, casterToken, abilityClone, symbols, options)
        -- return {targets = {{loc=...}}} or {targets = {{token=...}}}  -> handled
        -- return "skip" -> abort; return nil -> decline (manual prompt)
    end,
}

-- ctx (activation context, created in Turn.PlayActivation)
{ token, monsterType, usedCategories = {}, skipSpecs = {}, results = {},
  activeTactics = {}, expectedPrompt = nil, snapshot = <current> }
```

Scoring conventions: 0.2 generic fallback (free strikes), 0.5-0.8 situational maneuvers, 1.0 signature action, 1.5-2.5 high-impact/malice abilities.

## Verified engine surface

Everything below was confirmed by direct source inspection (2026-06). Cite this table instead of re-reading the engine.

Re-audited 2026-06-10 after the branch was rebased onto upstream main (46 new commits): every dependency below was re-verified against the rebased source. Notable upstream changes are folded into the rows and the LiveEncounter row below; the squad-coordination refactor (commit 6199616) removed only encapsulation, not the contracts Warmind uses.

Re-audited 2026-07-07 against upstream main 5f6a04b (508 new commits since the branch base 289c2bc; branch NOT yet rebased). Seven seam auditors verified every row below against the new source. Verdict: NO Warmind code was broken by upstream; all corrections are folded into the rows and Lessons below. The 2026-06-10 note that MainAttackerForTarget was deleted is superseded -- it is restored (see Casting and Squad strikes rows). Rebase note: git merge-tree reports the only conflict is .gitignore (keep upstream's rewritten block plus the branch's `*.DS_Stor*` line); root CLAUDE.md auto-merges.

| Seam | API | Source |
|---|---|---|
| Initiative | `dmhub.initiativeQueue` (nil outside combat); `:IsPlayersTurn()`, `:CurrentInitiativeId()` (nil BOTH when choosing and when queue.hidden), `:EntriesUnmoved()`, `:SelectTurn(id)`, `:IsEntryPlayer(id)`, `:ChoosingTurn()`, `.round`, `.hidden`, `.entries[id]`; `InitiativeQueue.GetTokensForInitiativeId(initiativeid)` (static, 1-arg ok); `InitiativeQueue.GetInitiativeId(tok)`; `GameHud.GetTokensForInitiativeId(GameHud.instance, GameHud.instance.initiativeInterface, id)`; advance: `GameHud.instance:NextInitiative(cb)` + `dmhub:UploadInitiativeQueue()` | `Draw Steel Core Rules/MCDMInitiativeQueue.lua`, `MCDMInitiativeBar.lua` |
| Action economy | `creature:GetResourceUsage(resourceId, "turn")` (defined in `DMHub Game Rules/Resource.lua`); ids in `CharacterResource`: `actionResourceId`, `maneuverResourceId`, `maliceResourceId`, `triggerResourceId`, `villainActionId`, `freeManeuverResourceId`. The engine itself uses the `"turn"` refresh key for action/maneuver (`MCDMActivatedAbility.lua`). `ability:CanAfford(token)` is the authority; engine pays costs itself inside Cast via `ActivatedAbility:ConsumeResources` (handles squad targetPairs: each member pays) | `DSResources.lua`, `Resource.lua`, `MCDMActivatedAbility.lua` |
| Malice | `CharacterResource.GetMalice()` / `SetMalice(amount, msg)` (global resource); round gain via `InitiativeQueue:CalculateMaliceGain(notes)` at NextRound | `DSResources.lua`, `MCDMInitiativeQueue.lua` |
| Villain actions | `VillainActionState.HasUsed(tokenid, key)` / `MarkUsed` / `ClearUsed(tokenid, key)` (2026-07: single-key un-mark) / `ResetAll` (shared doc `dsVillainActions`, checkpoint-backed, reset in `InitiativeQueue.Create`); `ability.villainAction` field = "Villain Action 1|2|3" | `DSResources.lua` |
| Abilities | `creature:GetActivatedAbilities()`; `ability:CanAfford(token)` (nil-guards the token: returns false), `:GetCost(token)` (details[].paymentOptions[].resourceid), `:ActionResource()`, `:GetRange(casterCreature, castingSymbols)`, `:GetNumTargets(token)`, `:HasKeyword(k)`, `:TargetPassesFilter(caster, tok, symbols)` (allegiance routes through `IsFriendForTargeting`, which honors the "Count Allies as Enemies" custom attribute), `:MakeTemporaryClone()`, `.targetType` ("target","all",...), `.categorization` ("Signature Ability"), `:try_get("meleeAndRanged")` + `.meleeVariation`/`.rangedVariation`, `:try_get("villainAction")`, `:try_get("chargeDistanceOverride", default)`. 2026-07: GetActivatedAbilities now returns ONLY fresh temporary clones (see Lesson 12); never pass `excludeGlobal` -- it strips free strikes AND malice abilities together (`MCDMMonster.FillMonsterActivatedAbilities` early-returns) | `DMHub Game Rules/ActivatedAbility.lua` |
| Casting | `ActivatedAbilityInvokeAbilityBehavior.ExecuteInvoke(invokerToken, abilityClone, casterToken, "inherit", symbols, options)` with `options.targets`, `options.countsAsCast = true`, `symbols.mode = 1`; completion signaled via `ability.OnFinishCast` (chain the existing one; the engine extracts it via try_get before casting and fires it once through an idempotent finishHandler). **ExecuteInvoke BLOCKS internally until the cast completes or is cancelled** (entry wait + `while not finishedCasting` with `castCount <= 1` cancel break) -- see Lessons learned. Signature re-verified 2026-07-07 (now ~line 454). CORRECTION: `MainAttackerForTarget` is RESTORED upstream (`ActivatedAbilityCast.lua` ~662) -- the editor-driven Cast path sources invoked sub-abilities AND caster-benefit behaviors per-target from the main attacker (first targetPairs entry whose b == target charid, falling back to caster); Warmind's direct ExecuteInvoke call is unaffected, but targetPairs ordering is load-bearing for squads (see Lesson 13). New hardening 2026-07: when the prompt callback resolves targeting, an `aiResolvedTargeting` flag makes the engine bypass the action-bar invokeAbility UI even for RequiresPromptWhenCast abilities (removes a class of AI-cast hangs); the inherit branch now locks `symbols.allowedtargets` to exactly options.targets, so always populate options.targets for inherit invokes | `DMHub Game Rules/AbilityInvokeAbility.lua` (~454) |
| Prompt interception | `token.properties._tmp_aicontrol` (counter, class default 0) + `_tmp_aipromptCallback` (default false), both `Creature.lua` ~198. Engine consults at `AbilityInvokeAbility.lua` ~580 (re-verified 2026-07-07; consult logic byte-identical, only moved): callback(invoker, caster, abilityClone, symbols, options) -> "inherit" (use options.targets) \| "prompt" (manual UI) \| "skip". Write directly (NO ModifyProperties -- `_tmp_` is transient, baseline does the same) | `AbilityInvokeAbility.lua`, `Creature.lua` |
| Movement/paths | `token:CalculatePathfindingArea(decis, flags)` -> map of `{loc, cost}` (decis = tiles*10); `token:Move(loc, {maxCost=10000, ignoreFalling=false})` (2026-07: also accepts `movementType="jump"` + `jumpHeight` in tiles to clear height-limited walls); `creature:CurrentMovementSpeed()`, `:DistanceMovedThisTurn()`; `token:MarkMovementArrow(loc, {straightline, ignorecreatures, moveThroughFriends})` -> `{path={origin,destination,steps}, ...}` + `token:ClearMovementArrow()`; `path.destination:DistanceInTiles(origin)`; LuaPath gained `.jumpHeight` + `:GetStepWallHeight(n)` / `:GetClimbOverWallHeight(n)`; `token:ExecuteWithTheoreticalLoc(loc, fn)`. Pathfinding results already account for flyer altitude and jump wall-clearing; cube auras now have finite vertical extent (hazard results stay correct for free) | baseline `Monster AI/MonsterAI.lua` usage, `Definitions/` |
| LOS / visuals | `token:GetLineOfSight(target, pierceWalls)` -> 0 blocked, fractional = cover, 1 = clear (max IS 1 -- use >0 for any visibility; optional 3rd arg mode `"full"` default \| `"basic"` cheap center-ray); `creature:GetPierceWalls()`; `dmhub.MarkLineOfSight(a, b, pierce)` -> LuaTargetingMarkers whose stub-documented teardown is `:Destroy()` (the legacy baseline called `:DestroyLineOfSight()` -- Warmind's DestroyRays tries both, pcall-wrapped); `game.currentFloor:GetAltitudeAtLoc(loc)` | same |
| Tokens | `dmhub.allTokens`, `dmhub.GetTokenById(id)`, `dmhub.TokensAreFriendly(a,b)` (nil possible -> treat as hostile, baseline does), `token.valid/.charid/.loc/.playerControlled/.properties`; `creature.minion`, `:MinionSquad()`, `:IsDead()`, `:HasNamedCondition(name)` ("Hidden","Grabbed","Dazed"), `:CalculateNamedCustomAttribute(name)`, `:try_get/:has_key` (game types only) | various |
| Triggers (opportunity attacks) | `creature:GetAvailableTriggers()` -> set `trigger.triggered = true` then `creature:DispatchAvailableTrigger(trigger)`; match `trigger.text == "Opportunity Attack"`. Post-rebase additive: new `forcemove` trigger type with `distance`/`melee` fields on the trigger (dispatch semantics unchanged) | baseline `MonsterAIPanel.lua`, `TriggeredAbility.lua` |
| Free strikes | Built per-monster by `monster:FillFreeStrikes` from standard abilities, canonical names `"Melee Free Strike"` / `"Ranged Free Strike"`, targetType "target", numTargets 1, range max(default, signature range when keyword matches) | `MCDMMonster.lua` ~113-188 |
| Squad strikes | `symbols.targetPairs = {{a = minionCharid, b = targetCharid}, ...}` passed into the cast; the pair format is unchanged, but 2026-07 command sourcing AND damage attribution both route through `ActivatedAbilityCast:MainAttackerForTarget` (`ActivatedAbilityCast.lua` ~662; FIRST matching pair wins -- see Lesson 13). `UsesSquadCoordination` / `UsesIndividualManeuver` gate the resource billing override; NOTE the multi-member action+maneuver fan-out only fires when `HasManeuverOrActionRule()` is true -- a plain squad bills only the caster. Build targetPairs ONLY for members with `IsActiveInSquad()` and not `IsTurnSkipped()` (matches the engine's GetNumTargets attacker accounting); `CanTargetAdditionalTimes` enforces the 3-attackers-per-target cap (unless "Ignore Minion Target Limit"). `Cast.NumAttackers(Target)` scales free-strike rolls via `targets[].numAttackers` set in `PrepareTargets`. Squad enumeration shortcuts: `_tmp_minionSquad.{tokens, captain, liveMinions, activeMinions, maximum_health, damage_taken}` (built in `MCDMCreature.RefreshSquadInfo`), `creature:GetMinionSquadInfo()`, `DrawSteelMinion.GrowTokensToIncludeSquads(tokens)`; optional hard-pin via `ActivatedAbility.LockSquadTargetingPair(minion, target)` / `ClearSquadTargetingState()`. `creature:MinionSquad()` never returns nil for a minion (defaults to "<type> Squad 1"). `MCDMMinion.lua` is squad roster/color/manager UI only -- combat logic stays in MCDMActivatedAbility/MCDMAbilityRollBehavior/MCDMCreature. The baseline ExecuteSquadStrike approach ports unchanged (re-verified 2026-07-07) | `MCDMActivatedAbility.lua`, `MCDMAbilityRollBehavior.lua`, `ActivatedAbilityCast.lua` |
| LiveEncounter (upstream, 2026-06) | `dmhub.initiativeQueue:try_get("liveEncounter")` -> `false` \| `nil` \| LiveEncounter table (RegisterGameType derives from Encounter; access fields directly). Key reads for the Director layer: `:CountLiveCombatants()` -> heroes, monsters alive; `:GetDefeatProgress()` -> defeated, needed (counts monsters only -- use CheckVictory for the objective conditions); `:IsSoloExhausted()`; `:CountPendingReinforcements(numHeroes, org?)` (2026-07: optional org keyword filter, e.g. "leader"); `:GetAvailableWaves(round)`; `:GetBossToken()` (2026-07: also resolves a boss for destroy_thing / leader_defeated / solo_exhausted conditions); `:CheckVictory()` (2026-07: adds destroy_thing + leader_defeated conditions); `:GetObjectiveText()` / `:GetObjectiveTooltip()`; organization helpers `OrganizationKeyword(props)`, `GetFirstMonsterWithOrganization(org)`, `CountLiveLeaders()`. `victoryAwarded` flag: director-set ONLY (a button; verified no auto-award) -> initiative bar hides and DSVictoryScreen takes over while `queue.hidden` is still false -- Warmind idles on it (see Lessons). `LiveEncounter.TrackHeroStats(tokenid, statid, qty)` is fired by engine callbacks (damage/movement/conditions) -- never call it; AI-driven turns are tracked correctly for free. `DeployWave` is director-only. Design docs: `LIVE_ENCOUNTER.md`, `STATS_TRACKING.md` in Draw Steel Core Rules | `Draw Steel Core Rules/MCDMEncounter.lua`, `MCDMInitiativeBar.lua`, `Draw Steel UI/DSVictoryScreen.lua` |
| Misc | `dmhub.Coroutine(fn)` (NOT synchronous -- see double-start lesson), `dmhub.Time()`, `dmhub.CenterOnToken(charid, {smooth=true})`, `dmhub.SyncCamera{speed=1}`, `dmhub.GetSettingValue(id)`, `setting{id, description, storage="preference", default}`, `DockablePanel.Register{name, minHeight, dmonly, content}`, `table.resize_array(t, n)` (`DMHub Utils/Utils.lua`, truncates), `MCDMImporter.GetStandardAbility("Speech")` + `MCDMUtils.DeepReplace(ability, "<<text>>", text)`, `dmhub.canSafelyYield`, `mod.unloaded`. 2026-07 additions: `GlobalRuleMod.GetActiveRuleMods()` (`DMHub Game Rules/EncounterRules.lua`; encounter-scoped rule mods, authoring-only for now -- read rule mods through it, never the raw table); new ability behavior types `AbilityRelocateAura` + `AbiltyConferCondition` (upstream filename typo is real); monster tier damage is level-scaled at roll time via `RollPropertiesPowerTable:ApplyCreatureTierDamage`; `monster:Organization()` / `:Role()` (lowercased, may return nil on nonstandard role strings), `monster:EV()`, `:HasLevelAdjustment()`, `:HasSoloConversion()` (DM scaling -- read per snapshot, never cache); `token.animation` + `token:AnimateAttack{...}` scripted visuals; ClaudeBridge module (global `claude`, rules-reference chat assistant) is NOT loaded by main.lua and has no token-control surface -- not an AI-overlap concern | various |

## Autonomous dev loop (deploy, drive, observe)

Proven live 2026-07-11. A fresh session can deploy changed Warmind files, confirm the automatic
hot reload, and probe the loaded code read-only against real game objects WITHOUT any manual
user step. One-time setup (/mcpauto, monitorid, checkout, permission allowlist) is ALREADY done
on this machine; do not re-run it. If the bridge is down, complete static + harness gates and
mark L3/L4 DEFERRED (see ROADMAP.md "Verification model").

### Machine truths (cite exactly)

| Thing | Value |
|---|---|
| Mod store (deploy target) | `/Users/droideck/Library/Application Support/MCDM/Codex/mods/Warmind_be67/` |
| Warmind modid | `6bda19b2-7fe7-4cbd-8287-36172af8be67` |
| Player.log (Unity console, tailable) | `/Users/droideck/Library/Logs/MCDM/Codex/Player.log` |
| Bridge base URL | `http://localhost:19876` |
| Bridge endpoints | `GET /health`; `POST /execute {"code":"..."}` (returns result + captured prints); `POST /reload`; `GET /screenshot`; `GET /status` (filesChanged / changedMods) |
| Bridge activation | started once via `/mcpauto` in DMHub chat (done 2026-07-11); persists across app sessions |

Curl form -- write the URL FIRST so the permission allowlist prefix-matches on
`curl http://localhost:19876/`:

```bash
curl http://localhost:19876/execute -s -m 15 -X POST -H "Content-Type: application/json" -d @payload.json
```

`payload.json` holds `{"code":"...Lua..."}`. Health probe: `curl http://localhost:19876/health -s -m 5`.

### Setup (already applied; recorded for reproduction only)

`monitorid` selects the single monitored mod; checkout mirrors the editor's Edit button and is
fully scriptable via execute_lua:

```lua
code.monitorid = '6bda19b2-7fe7-4cbd-8287-36172af8be67'
local m = code.GetMod('6bda19b2-7fe7-4cbd-8287-36172af8be67')
m.checkedout = true
m:RepairLocal()
```

Keep the mod CHECKED OUT while iterating locally: a Firebase cloud-sync layer is intertwined
with the mod store, and local vs cloud can clobber each other if they fight.

### Deploy recipe (disk write is the ONLY channel)

1. `curl http://localhost:19876/health -s -m 5` -- if not ok, stop and mark L3 DEFERRED.
2. Write each changed `WarmindXxx.lua` into the mod store dir above using the Write/Edit tool
   (NOT Bash cp -- see cautions). The mod must be monitored + checked out.
3. DMHub's file watcher fires AUTOMATICALLY: it re-reads all 12 files and hot-reloads the mod
   in ~20ms. No manual reload, no in-app editor.
4. Confirm the hot reload in Player.log -- the exact chain is:
   `Local file changed` -> `RefreshLocalFiles` -> reload success (fingerprint moves). Confirm
   zero new console errors in the same tail.
5. `POST /reload` ONLY if the watcher did not fire. `GET /status` reports filesChanged /
   changedMods if you need the file-change state.
6. CLAUDE.md and warmind_logic_tests.lua are NOT module code -- never deploy them.

### L3 probe recipes (read-only via POST /execute)

All run inside `POST /execute` as the `code` string; read-only means no casts, no token moves,
no initiative advancement. Examples:

```lua
-- Fingerprint the loaded source (proves which file the engine is running):
local info = debug.getinfo(Warmind.Traits.Get, "S")
print("Traits.Get defined at line " .. tostring(info.linedefined) .. " in " .. tostring(info.short_src))

-- Traits over a real monster's ability clones:
local tok = dmhub.GetTokenById(someTokenId)
for _, ab in ipairs(tok.properties:GetActivatedAbilities()) do
    local t = Warmind.Traits.Get(ab)
    print(ab.name, t.actionKind, tostring(t.isStrike), tostring(t.isSignature))
end

-- Snapshot on a live token (read-only decision input):
local snap = Warmind.Snapshot.Build(tok)
print(#snap.enemies, #snap.allies, snap.moveRemaining)

-- Pull the decision trace after an exercise:
for _, e in ipairs(Warmind.trace.entries) do print(e.reasonCode, e.reason) end
```

### Cloud commit (agent-drivable, user-approved)

Local changes accumulate in the checked-out mod. At a stage's review closure, OFFER to push
and do so only on the user's in-chat yes (their mod, their version history):

```lua
local m = code.GetMod('6bda19b2-7fe7-4cbd-8287-36172af8be67')
m:CommitChanges("Stage N: <summary>", engineVersion, function() end)
```

Same effect as the editor's commit button.

### Cautions (all facts)

- `CodeModFileLua.localContents` is READ-ONLY from Lua. The engine logs "property is read-only"
  to console; pcall does NOT catch it (returns success). Disk write is the only deploy channel.
- pcall does not catch engine read-only property errors generally -- they log and return
  success, so never trust a pcall result to prove an engine write landed.
- Only ONE mod is monitored at a time (`code.monitorid` is singular).
- Firebase cloud-sync is intertwined with the mod store; keep the mod checked out while
  iterating locally to avoid local/cloud clobber.
- Deploying via Bash `cp` into the mod store may trip the Claude Code permission classifier in
  fresh sessions; the Write/Edit tools are allowlisted for that path
  (`Edit(/Users/droideck/Library/Application Support/MCDM/Codex/mods/**)` in
  `.claude/settings.local.json`). Standing authorization (user, 2026-07-11): "I give you
  permission to overwrite anything in ~/Library/Application Support/MCDM/Codex/mods as it's a
  development and I don't keep anything valuable there."
- Editing the on-disk `mods/main.lua` require-list on reload is UNVERIFIED -- it matters only
  when adding a brand-new file (no stage before 7 does; tag unverified if you rely on it).

## Lessons learned (do not re-litigate)

1. **pcall + yield is unsafe in the DMHub runtime.** `dmhub.canSafelyYield` exists, which means non-yieldable contexts exist. No shipped code in the repo pcalls around yielding code. Error isolation for yielding code uses `Warmind.Guard(fn)` -- a nested coroutine whose `coroutine.resume` catches errors portably and forwards yields outward and return values back. pcall is allowed ONLY around provably non-yielding calls (string.format, document reads, ray create/destroy, GetStandardAbility).
2. **ExecuteInvoke blocks until cast end or cancel.** Calling it inline means a stuck cast hangs the AI coroutine with no recourse (the engine's internal waits never check our flags). Warmind runs it in its own `dmhub.Coroutine` and watchdogs from outside. When the invoke returns without `OnFinishCast` firing, the cast was cancelled -> short 2s grace then manual/TAKEN_OVER_BY_DM (not EXECUTION_TIMEOUT).
3. **Manual outcomes must pause the AI and must NOT advance initiative.** `Turn.PlayCurrentTurn` returns `{manualPending}`; the panel thread auto-stops on it. Without this, the AI advances past a turn the DM was told to finish by hand, or re-activates the same entry in a loop. (Found by review; the unwired `sawManualPrompt` flag was the smell.)
4. **Stop button = takeover contract.** `Warmind.RequestStop()` + `g_terminate`. Checked between decisions, between tokens, and in cast-wait loops. On stop: release control state, leave initiative untouched.
5. **Driver errors auto-stop the AI** (panel thread sets `g_terminate` on Guard failure) so a scaffolding bug can never error-loop the same turn forever. Per-activation errors are contained by Guard and the entry's other tokens still act.
6. **`dmhub.Coroutine` does not start synchronously** -> the panel guards double-start with `g_starting` in addition to checking `coroutine.status(g_thread)`.
7. **Scorefn caching:** `FindBestStrikePosition` caches scorer results per token.charid across candidate tiles, so scorers must depend only on the target, never on attacker position. (Baseline had the same semantics by silently dropping the edges arg; forwarding edges into a per-token cache made position selection nondeterministic.)
8. **Budget = intent layer, CanAfford = authority.** `usedCategories` prevents repeats even for cost-free abilities; engine resources gate the rest. Dazed = one category total per turn (engine does NOT enforce dazed economy; we do).
9. **Trace must never throw** (`tostring` first, pcall the format) and every terminal path appends an explicit DecisionResult -- including falling off the decision cap.
10. **ASCII only** in all Lua files (DMHub runtime constraint). Verify with `LC_ALL=C grep -nP '[^\x00-\x7F]'`. Syntax-check with `luac -p` (brew lua works for parsing).
11. **Cooperate with LiveEncounter; never drive it.** When `liveEncounter.victoryAwarded` is true the victory screen owns the table while `queue.hidden` is still false -- the panel thread idles (status "Victory screen") instead of acting. Never set `victoryAwarded`, never call `TrackHeroStats` or other stats APIs (engine callbacks record hero stats correctly even for AI-driven turns), never call `DeployWave` (director-only; at most emit a trace hint recommending it). Watch item: retainers/followers now group into their mentor's initiative entry, but they are player-controlled so `IsControllableMonster` already excludes them.
12. **Ability objects are never identity-stable across snapshots.** GetActivatedAbilities wraps every result in MakeTemporaryClone (upstream, 2026-07 audit). Compare abilities by name, never by object identity or table key across two Snapshot.Build calls; within one decision iteration identity is fine. Upside: enumerated abilities are already safe to mutate in place (no defensive clone needed, though clone-of-clone stays harmless).
13. **targetPairs order is load-bearing.** `MainAttackerForTarget` picks the FIRST pair whose `b` matches the target, and that minion becomes the source of invoked sub-effects (pushes, conditions) and caster-benefit behaviors for that target -- not just the damage roller. When assembling squad pairs, list the intended main attacker's pair before any duplicate attackers on the same target.
14. **Disk write is the only deploy channel; the watcher is writer-agnostic.** `CodeModFileLua.localContents` is READ-ONLY from Lua -- the engine logs "property is read-only" and, critically, pcall does NOT catch it (returns success), so a pcall around an engine property write is a false positive. The DMHub file watcher fires on ANY writer to the mod-store dir (Write/Edit tool, cp, editor) and hot-reloads all 12 files in ~20ms. Writing the file on disk is the only way to deploy (verified live 2026-07-11; see Autonomous dev loop).
15. **debug library is available; getinfo fingerprints prove loaded source.** `debug.getinfo(fn, "S").linedefined` / `.short_src` reveal exactly which source the engine is running; after a deploy the linedefined value moves, which proves the hot reload took (observed 211 -> 220 live 2026-07-11). Use it as the L3 proof that probes are hitting the new code, not a stale copy.

## Stage roadmap and status

| Stage | Content | Status |
|---|---|---|
| 0 | Scaffolding: Core registries, reason codes, panel skeleton | DONE (in repo; the repo dir is NOT loaded -- the on-disk mod store at `mods/Warmind_be67` is. Deploy = write files there; the watcher hot-reloads automatically. See Autonomous dev loop) |
| 1 | Robust spine: Snapshot, Adapter (watchdog, control lifecycle), budget-aware Turn loop, free-strike specs, panel thread | DONE (statically verified + multi-pass reviewed; module hot-reload + load-clean verified live 2026-07-11 via the bridge; turn behavior not yet exercised -- L4 pending. See ROADMAP.md Verification model) |
| 2 | Generic competence: full Traits, generic spec set (signature strike, charge, area-if-N, grab, knockback, aid attack, hide, reposition), Scoring tactic biases, Prompts (Shift smart, Push/Pull/Slide with real shape), Squads port (re-path fix + no-signature fallback). Squad `targetPairs` contract re-verified intact post-rebase and again 2026-07-07 (see Squad strikes row) -- the baseline port plan stands. Detailed implementation plan: `STAGE2_PLAN.md` (written 2026-07-07 from the 508-commit upstream audit + baseline port inventory + Book Two ability census) | NEXT |
| 3 | Role weight profiles (ambusher/artillery/brute/controller/defender/harrier/hexer/support/mount + leader/solo bias). Seed numbers exist in legacy `DirectorTacticsPolicies.lua` role table | planned |
| 4 | Director layer: activation chooser heuristics (captain-before-squad, endangered first, leader timing), malice spend policy (score margin + pool floor), villain scheduler (1->2->3, once each per encounter via VillainActionState, max 1/round). New LiveEncounter inputs to use (see LiveEncounter row): CountLiveCombatants / GetDefeatProgress for aggression and activation order, IsSoloExhausted for solo self-preservation, CountPendingReinforcements + GetAvailableWaves for an optional "recommend wave deploy" trace hint (never auto-deploy) | planned |
| 5 | Panel v2: step mode (pause after each activation), takeover button, per-spec enable/disable persisted via settings, trace viewer | planned |
| 6 | Override packs: port Goblin Warrior, Goblin Assassin, Bugbear Channeler, Ryll, Ghoul, Zombie, Skeleton from `Monster AI/MonsterAIMonsters.lua` (+ combo via SetExpectedPrompt) | planned |
| 7 | Cutover: remove `Monster_AI_d7b4` requires, delete `Monster AI/`, delete 15 root `DirectorTactics*.lua`, write final community-facing architecture doc. (Stale `docs/ai/` and old `AGENTS.md` already removed 2026-06-10; AGENTS.md is now a pointer to this file) | planned |

### Stage 1 expected runtime behavior (reference, not a gate)

Former in-app checklist, retained as reference. Stage 1 flipped DONE under the static-only
model; these items are now retro-verifiable via L3 (see Autonomous dev loop), and the first
item is already satisfied: module hot-reload + load-clean were verified live 2026-07-11 via
the bridge. The rest await an L4 turn exercise or natural play; runtime misbehavior routes
to the on-demand PD play-debrief prompt in ROADMAP.md.

- [ ] Module loads with no console errors; Warmind panel appears (DM only)
- [ ] Non-minion monster: moves + free-strikes (charge if melee), activation ends, initiative advances
- [ ] Ranged monster shoots instead of charging; ranged-adjacent penalty observable in trace
- [ ] Minion squad: held with UNSUPPORTED_SQUAD in trace, initiative still advances
- [ ] Stop mid-turn: clean TAKEN_OVER_BY_DM, no stale `_tmp_aicontrol` (probe `token.properties:try_get("_tmp_aicontrol")` via the bridge, or Character Inspector), initiative NOT advanced
- [ ] Cancel an AI-initiated cast: AI pauses within ~2s with "cancelled or did not complete", initiative NOT advanced
- [ ] Force a Lua error in a spec: activation held with EXECUTION_ERROR, other tokens still act, AI keeps running
- [ ] With a live encounter active (started from the encounter UI so `liveEncounter` is a table): press "Award Victory" mid-AI-run -> AI idles with status "Victory screen", no turn advancement; after Proceed/End Combat the queue hides and the AI stays idle
- [ ] Old Monster AI panel untouched and still functional (do not run both at once)

## Stage 3/4 seed data (salvaged from DirectorTactics, the only reusable assets)

Role weight profiles (from `DirectorTacticsPolicies.lua`; starting values for Stage 3 tuning, not gospel). desiredRange in tiles; weights are relative scoring multipliers:

| Role | desiredRange | rangeWeight | flankWeight | avoidAdjacent | Doctrine |
|---|---|---|---|---|---|
| brute | 1 | 0.35 | 1.5 | - | engage clusters, body-block |
| skirmisher | 1 | 0.25 | 1.4 | 0.8 | strike vulnerable targets, reset |
| controller | 4 (5 ranged) | 0.45 | - | 3.5 | early control, objective disruption |
| defender | 1 | 0.3 | 1.1 | - | split threats, protect allies |
| harrier | 1 | 0.25 | 2 | 2 | pressure backline, retreat |
| artillery | 7 | 0.6 | - | 6 | keep range edge, use screens |
| hexer | 5 | 0.45 | - | 4 | debuff high-impact foes |
| support | 4 (5 ranged) | 0.35 | - | 3 | preserve buffs, heal allies |
| leader | 3 | 0.3 | - | - | pace villain actions, enable allies |
| solo | 2 | 0.25 | 1 | - | multi-target pressure, survival |
| minion | 1 | 0.3 | 1.6 | - | squad pressure, space control |

Malice timing heuristics (Stage 4 starting rules, distilled from the legacy ledger -- implement as a few lines in WarmindDirector, never as a ledger object):

- Pre-turn malice gate: spend on a stat-block malice ability only when its candidate score clearly beats the best free option AND the pool keeps a floor (legacy used: remaining >= 1 and a threshold scaled to the encounter; tune in play).
- Dazed solo relief: legacy allowed a solo to reopen one action for malice >= 5 when dazed (verify the actual DS rule before implementing).
- Villain actions fire in order 1 -> 2 -> 3, once each per encounter (`VillainActionState`), at most one per round across the whole encounter; aim them at high-impact moments (engagement, swing turns, desperation) for the encounter arc.

## Working on this project (process notes)

- The old `Monster AI/` module stays loaded until Stage 7. Both AIs are manual-start; never start both. NOTE (2026-07 audit): `Monster AI/` is upstream-SHARED code, still required by main.lua on upstream main and byte-identical there -- it is not branch-local. The Stage 7 deletion is therefore an upstream-visible change (requires removal must land upstream too), and the Warmind rollout must stop loading the legacy module to avoid two AIs fighting over the same `_tmp_aicontrol` counter.
- Rebase status (2026-07-07): branch base is 289c2bc; upstream main 5f6a04b (508 commits ahead) fully audited -- no Warmind code broken. On rebase the only conflict is `.gitignore` (keep upstream's rewritten block plus the branch's `*.DS_Stor*` line); root CLAUDE.md auto-merges (upstream added a Crows/Crowdex section and a `cond()`-is-not-a-ternary warning that Warmind scoring code should heed).
- Legacy DirectorTactics files at repo root are dead reference only. The single reusable data asset is the role-profile table in `DirectorTacticsPolicies.lua` (Stage 3). Never import its code.
- Doc set (token hygiene, 2026-07-11): live docs are this file (read fully -- it is the engine truth), `ROADMAP.md` (TARGETED reads of the relevant section only, located via rg -n "^## " -- NEVER read end to end, it is ~4.7k lines), the active STAGEN_PLAN.md, and `warmind_logic_tests.lua` (the L1 logic harness -- standing dev infrastructure, extended by implementation sessions, NEVER registered in DMHub / never in main.lua / never required by module files). Superseded planning docs are deleted, not archived: ORIGINAL_PLAN.md and PROMPTS.md were deleted 2026-07-11; each stage plan doc is deleted at its stage's review closure (STAGE2_PLAN.md is deleted at P2.5).
- New Lua files remain FORBIDDEN for module code (DMHub registers files through its module system; an unregistered require fails the load). The sole sanctioned exception is the dev-only `warmind_logic_tests.lua` harness -- not module code, never in main.lua, created with user approval 2026-07-11.
- Deployment (2026-07-11): agent-driven, NOT user-copied. Write changed `WarmindXxx.lua` into
  the on-disk mod store (`mods/Warmind_be67`); the DMHub watcher hot-reloads automatically. The
  user no longer copies files into DMHub. Full mechanics in the "Autonomous dev loop" section.
- Verification model (2026-07-11, user decision, extended same day): the 2026-07-11 decision --
  NO manual verification burden on the user -- stands and is EXTENDED: deployment AND runtime
  verification are now agent-driven (the constraint was always "no manual burden", never "no
  in-app verification"). Stage DONE = code complete + L0 static (luac -p + ASCII grep) + L1
  harness green when pure logic touched + L2 engine claims folded into this file + L3 clean
  (deploy + hot reload + read-only probes) + adversarial review of the stage diff with findings
  fixed (+ L4 live turn exercise for Stages 2/4/5/6, or an explicit DEFERRED line). Runtime
  misbehavior during natural play still routes to the PD play-debrief prompt. `ROADMAP.md`
  "Verification model" is the authority on this convention (levels L0-L4, DEFERRED rule,
  coverage tags [harness]/[probe]/[live]).
- After completing a stage: update the Status column above, append any new verified engine APIs to the table, and record new lessons. This file is the cross-session memory; if it is not written down here, the next session will pay to rediscover it.
- Reviews should audit the stage DIFF against this document, not re-derive the engine. Only newly-used engine APIs need source verification.
- `monster-reference.md` at repo root has every Book Two stat block (authoritative for Stage 2/3 behavior design). `compendium/bestiary/` has the YAML.
