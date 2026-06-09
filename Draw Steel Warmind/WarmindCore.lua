local mod = dmhub.GetModLoading()

-- ============================================================================
-- Warmind: Draw Steel monster AI.
--
-- WarmindCore.lua is the first file in the module load order. It defines the
-- Warmind global, the decision contracts (DecisionResult + reason codes), the
-- registries (action specs, prompt handlers, tactics, override packs), the
-- trace buffer the panel reads, and small shared utilities.
--
-- Design rules for the whole module:
--   * Utility selector, not a framework. One entry point per decision.
--     No phase bus, no pipeline flows, no resource ledger.
--   * Every decision produces a DecisionResult with a stable reason code.
--     Prose-only failure reasons are not allowed.
--   * Unsupported complexity fails closed (held/manual + reason code).
--     The AI never improvises through unverified behavior and never hangs.
--   * All world mutation goes through WarmindAdapter.
--   * Yielding code is never wrapped in pcall. Error isolation for yielding
--     code uses Warmind.Guard (a nested coroutine), because pcall cannot be
--     assumed to support yields in the DMHub runtime (see dmhub.canSafelyYield).
-- ============================================================================

---@class Warmind
Warmind = {
    version = "0.1.0",
}

-- Maximum decision iterations per activation. A monster turn is one main
-- action plus one maneuver plus movement, so this is a generous safety cap,
-- not the action economy (CategoryAllowed in WarmindTurn.lua is).
Warmind.MAX_DECISIONS_PER_ACTIVATION = 8

-- How long ExecuteAbilityAndWait waits for an ability to finish resolving
-- before giving up and handing the turn to the DM.
Warmind.ABILITY_TIMEOUT_SECONDS = 30

-- ----------------------------------------------------------------------------
-- Settings.
-- ----------------------------------------------------------------------------

setting{
    id = "warmindpacing",
    description = "Warmind: pacing multiplier for AI action delays",
    storage = "preference",
    default = 1,
}

-- Multiplies a delay by the pacing setting so the DM can speed up or slow
-- down how quickly the AI acts.
function Warmind.Pace(seconds)
    local multiplier = tonumber(dmhub.GetSettingValue("warmindpacing")) or 1
    if multiplier < 0 then
        multiplier = 0
    end
    return seconds * multiplier
end

-- ----------------------------------------------------------------------------
-- Reason codes.
--
-- Stable UPPER_SNAKE identifiers used in DecisionResults and traces. Add new
-- codes deliberately and document them here; never report a failure with
-- prose alone.
-- ----------------------------------------------------------------------------

Warmind.reason = {
    -- No registered action spec applied to the current snapshot at all.
    NO_SUPPORTED_ACTION = "NO_SUPPORTED_ACTION",
    -- A spec was chosen but had no legal target when execution rechecked.
    NO_LEGAL_TARGET = "NO_LEGAL_TARGET",
    -- A spec needed a position the actor could not reach.
    NO_REACHABLE_POSITION = "NO_REACHABLE_POSITION",
    -- An ability required a prompt shape Warmind does not automate.
    UNSUPPORTED_COMPLEX_PROMPT = "UNSUPPORTED_COMPLEX_PROMPT",
    -- Area targeting geometry was not safe or obvious enough to automate.
    UNSUPPORTED_AREA_GEOMETRY = "UNSUPPORTED_AREA_GEOMETRY",
    -- Minion squad behavior that is not implemented yet (Stage 2).
    UNSUPPORTED_SQUAD = "UNSUPPORTED_SQUAD",
    -- A final legality recheck failed just before execution.
    EXECUTION_RECHECK_FAILED = "EXECUTION_RECHECK_FAILED",
    -- An ability cast started but did not report completion in time.
    EXECUTION_TIMEOUT = "EXECUTION_TIMEOUT",
    -- A Lua error escaped from a spec or the turn loop. Always a bug.
    EXECUTION_ERROR = "EXECUTION_ERROR",
    -- The actor has actions left in principle but nothing it can still do.
    BUDGET_EXHAUSTED = "BUDGET_EXHAUSTED",
    -- The DM pressed stop; the AI released control cleanly.
    TAKEN_OVER_BY_DM = "TAKEN_OVER_BY_DM",
    -- The ability could not be paid for at execution time.
    CANNOT_AFFORD = "CANNOT_AFFORD",
}

-- ----------------------------------------------------------------------------
-- DecisionResult constructors.
--
-- Shape: { status, reasonCode, reason, detail }
--   status: "executed" | "held" | "manual" | "skipped"
--   reasonCode: one of Warmind.reason (nil only for executed)
--   reason: short prose for humans
--   detail: optional table with extra context (ability name, target count...)
-- ----------------------------------------------------------------------------

function Warmind.ResultExecuted(detail)
    return {
        status = "executed",
        reasonCode = nil,
        reason = nil,
        detail = detail,
    }
end

function Warmind.ResultHeld(reasonCode, reason, detail)
    return {
        status = "held",
        reasonCode = reasonCode,
        reason = reason,
        detail = detail,
    }
end

function Warmind.ResultManual(reasonCode, reason, detail)
    return {
        status = "manual",
        reasonCode = reasonCode,
        reason = reason,
        detail = detail,
    }
end

function Warmind.ResultSkipped(reasonCode, reason, detail)
    return {
        status = "skipped",
        reasonCode = reasonCode,
        reason = reason,
        detail = detail,
    }
end

function Warmind.DescribeResult(result)
    if result == nil then
        return "nil result"
    end
    if result.status == "executed" then
        return "executed"
    end
    return string.format("%s [%s] %s", result.status or "?", result.reasonCode or "?", result.reason or "")
end

-- ----------------------------------------------------------------------------
-- Trace buffer.
--
-- A bounded in-memory log of what the AI considered and why. The panel
-- renders it; everything also goes to the console with a Warmind:: prefix.
-- ----------------------------------------------------------------------------

Warmind.trace = {
    entries = {},
    serial = 0,
    maxEntries = 300,
}

function Warmind.Trace(fmt, ...)
    -- Trace must never throw, whatever it is handed.
    local text = tostring(fmt)
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        if ok then
            text = formatted
        else
            text = text .. " (trace format error)"
        end
    end

    print("Warmind:: " .. text)

    local t = Warmind.trace
    t.serial = t.serial + 1
    t.entries[#t.entries+1] = {
        serial = t.serial,
        time = dmhub.Time(),
        text = text,
    }
    while #t.entries > t.maxEntries do
        table.remove(t.entries, 1)
    end
end

function Warmind.ClearTrace()
    Warmind.trace.entries = {}
    Warmind.trace.serial = Warmind.trace.serial + 1
end

-- ----------------------------------------------------------------------------
-- Stop / takeover flag.
--
-- The panel sets this when the DM presses stop. Loops check it between steps
-- and exit cleanly with TAKEN_OVER_BY_DM, releasing all control state.
-- ----------------------------------------------------------------------------

Warmind.stopRequested = false

function Warmind.RequestStop()
    if not Warmind.stopRequested then
        Warmind.stopRequested = true
        Warmind.Trace("Stop requested; the AI will release control cleanly.")
    end
end

function Warmind.ClearStop()
    Warmind.stopRequested = false
end

-- ----------------------------------------------------------------------------
-- Coroutine utilities.
-- ----------------------------------------------------------------------------

-- Sleep for the given (pacing-adjusted) duration. Must be called from a
-- coroutine, like everything in the Warmind decision path.
function Warmind.Sleep(seconds)
    seconds = Warmind.Pace(seconds or 0)
    if seconds <= 0 then
        return
    end
    local endTime = dmhub.Time() + seconds
    while dmhub.Time() < endTime do
        coroutine.yield(0.1)
    end
end

-- Runs fn inside a nested coroutine, forwarding yields outward, and catches
-- any Lua error fn raises. Returns ok, errOrResultA, resultB.
--
-- This is the only sanctioned way to isolate errors in yielding code.
-- Do NOT use pcall around code that can yield: the DMHub runtime exposes
-- dmhub.canSafelyYield, which means non-yieldable contexts exist, and
-- coroutine.resume catches errors portably on every Lua implementation.
function Warmind.Guard(fn)
    local co = coroutine.create(fn)
    local passback = nil
    while true do
        local ok, a, b = coroutine.resume(co, passback)
        if not ok then
            return false, a
        end
        if coroutine.status(co) == "dead" then
            return true, a, b
        end
        passback = coroutine.yield(a)
    end
end

-- ----------------------------------------------------------------------------
-- Registries.
-- ----------------------------------------------------------------------------

-- Action specs: the things the AI can decide to do on a turn.
-- Registered with Warmind.RegisterSpec. Keyed by id; specList preserves
-- registration order so enumeration and traces are deterministic.
Warmind.specs = {}
Warmind.specList = {}

-- Prompt handlers: resolve secondary targeting choices during ability
-- resolution (shift destination, push direction, invoked sub-abilities).
-- Keyed by ability name or "Monster Type:Ability Name".
Warmind.prompts = {}

-- Tactics: passive scoring biases applied when evaluating strike targets
-- (flanking, high ground, ...). Keyed by id.
Warmind.tactics = {}

-- Override packs: per-monster bespoke behavior (Stage 6). Keyed by id.
Warmind.overrides = {}

local function AssertField(args, field, expectedType, context)
    local value = args[field]
    if value == nil then
        error(string.format("Warmind: %s requires field '%s'", context, field))
    end
    if expectedType ~= nil and type(value) ~= expectedType then
        error(string.format("Warmind: %s field '%s' must be a %s", context, field, expectedType))
    end
    return value
end

local g_validCategories = {
    main = true,
    maneuver = true,
    move = true,
    free = true,
}

-- Registers an action spec.
--
-- Required fields:
--   id          unique string
--   category    "main" | "maneuver" | "move" | "free"
--   description what this spec does and when the AI prefers it
--   score       function(spec, ctx, snapshot, abilities) -> candidate | nil
--               candidate = { score = number, loc = Loc|nil, ... }
--   execute     function(spec, ctx, candidate, abilities) -> DecisionResult|nil
--               (nil is treated as executed)
-- Optional fields:
--   abilities   array of ability names that must all exist on the actor and
--               be affordable for the spec to be considered
--   monsters    array of monster_type strings this spec is restricted to;
--               omitted means the spec is generic (applies to all monsters)
--   name        display name (defaults to id)
function Warmind.RegisterSpec(args)
    AssertField(args, "id", "string", "RegisterSpec")
    AssertField(args, "description", "string", "RegisterSpec")
    AssertField(args, "score", "function", "RegisterSpec")
    AssertField(args, "execute", "function", "RegisterSpec")
    local category = AssertField(args, "category", "string", "RegisterSpec")
    if not g_validCategories[category] then
        error(string.format("Warmind: RegisterSpec '%s' has invalid category '%s'", args.id, category))
    end

    args.name = args.name or args.id

    if Warmind.specs[args.id] == nil then
        Warmind.specList[#Warmind.specList+1] = args
    else
        -- Re-registration (e.g. while iterating on a file): replace in place.
        for i,existing in ipairs(Warmind.specList) do
            if existing.id == args.id then
                Warmind.specList[i] = args
                break
            end
        end
    end
    Warmind.specs[args.id] = args
end

-- Registers a prompt handler.
--
-- Required fields:
--   prompts  array of ability names this handler responds to. Entries may be
--            plain names ("Shift") or monster-qualified ("Goblin:Ability").
--   handler  function(ctx, invokerToken, casterToken, abilityClone, symbols,
--            options) -> table merged into options (handled) | nil (decline,
--            falls through to manual prompting)
function Warmind.RegisterPrompt(args)
    AssertField(args, "prompts", "table", "RegisterPrompt")
    AssertField(args, "handler", "function", "RegisterPrompt")
    for _,name in ipairs(args.prompts) do
        Warmind.prompts[name] = args
    end
end

-- Registers a tactic: a passive bias added to a target's edge count when
-- evaluating strikes.
--
-- Required fields:
--   id     unique string
--   score  function(tactic, ctx, token, tokenLoc, enemy, ability) -> number|nil
-- Optional fields:
--   description, monsters (same semantics as specs)
function Warmind.RegisterTactic(args)
    AssertField(args, "id", "string", "RegisterTactic")
    AssertField(args, "score", "function", "RegisterTactic")
    Warmind.tactics[args.id] = args
end

-- ----------------------------------------------------------------------------
-- Spec/tactic matching and per-monster enable state.
-- ----------------------------------------------------------------------------

-- Returns true if the spec (or tactic) applies to this token's monster type.
-- Specs without a monsters array are generic and match everything.
function Warmind.SpecMatchesMonster(token, spec, includeDisabled)
    local monsterType = token.properties:try_get("monster_type", "")

    if not includeDisabled then
        if spec.disabledForMonsters ~= nil and spec.disabledForMonsters[monsterType] then
            return false
        end
    end

    if spec.monsters ~= nil then
        for i=1,#spec.monsters do
            if spec.monsters[i] == monsterType then
                return true
            end
        end
        return false
    end

    return true
end

-- Session-local enable/disable for specs per monster type. Persisted
-- settings come with the Stage 5 panel work.
function Warmind.IsSpecEnabledForMonster(monsterType, specId)
    local spec = Warmind.specs[specId]
    if spec == nil then
        return false
    end
    if spec.disabledForMonsters ~= nil and spec.disabledForMonsters[monsterType] then
        return false
    end
    return true
end

function Warmind.SetSpecEnabledForMonster(monsterType, specId, enabled)
    local spec = Warmind.specs[specId]
    if spec == nil then
        return
    end
    spec.disabledForMonsters = spec.disabledForMonsters or {}
    spec.disabledForMonsters[monsterType] = not enabled
end

-- ----------------------------------------------------------------------------
-- Small shared helpers.
-- ----------------------------------------------------------------------------

-- Finds an ability by exact name in a snapshot abilities list
-- (array of { ability, traits }).
function Warmind.FindAbilityEntry(abilityEntries, name)
    for _,entry in ipairs(abilityEntries) do
        if entry.ability.name == name then
            return entry
        end
    end
    return nil
end

-- True if this token is a monster the AI should be willing to control.
function Warmind.IsControllableMonster(token)
    return token ~= nil
        and token.valid
        and token.properties ~= nil
        and token.properties:has_key("monster_type")
        and (not token.playerControlled)
end
