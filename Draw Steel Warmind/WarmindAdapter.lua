local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindAdapter.lua
--
-- The engine seam. This is the ONLY Warmind file that mutates the world:
-- movement, ability casts, prompt-callback control state, line-of-sight rays,
-- and flavor speech all go through here.
--
-- Responsibilities:
--   * BeginControl/Release: install and tear down the _tmp_aicontrol /
--     _tmp_aipromptCallback prompt-interception seam (read by the engine in
--     DMHub Game Rules/AbilityInvokeAbility.lua before showing a manual
--     prompt UI). Release is idempotent and must run on every exit path.
--   * ExecuteAbilityAndWait: cast an ability and wait for completion with a
--     watchdog timeout, so a cast that never finishes can never hang the AI.
--   * MoveTo: move the token with conservative options.
--   * RecheckStrikeTargets: final legality pass just before casting.
--
-- Error rules:
--   * pcall is allowed here only around calls that do not yield
--     (cost queries, ray creation/destruction, document reads).
--   * Anything that can yield is NOT wrapped in pcall; errors in our own
--     yielding code are caught by Warmind.Guard at the activation level
--     (see WarmindCore.lua for why). The cast invocation itself runs in a
--     separate engine coroutine under a watchdog: if it errors or stalls
--     there, the watchdog converts the non-completion into a fail-closed
--     manual result.
-- ============================================================================

Warmind.Adapter = {}
local Adapter = Warmind.Adapter

-- ----------------------------------------------------------------------------
-- Control state (prompt interception).
-- ----------------------------------------------------------------------------

-- Installs AI control on the given tokens: increments _tmp_aicontrol and
-- installs the prompt callback. Returns a handle whose Release() must be
-- called when the activation ends, no matter how it ends. Release is
-- idempotent.
function Adapter.BeginControl(tokens, promptCallback)
    local controlled = {}
    for _,tok in ipairs(tokens) do
        if tok ~= nil and tok.valid and tok.properties ~= nil then
            tok.properties._tmp_aicontrol = tok.properties._tmp_aicontrol + 1
            tok.properties._tmp_aipromptCallback = promptCallback
            controlled[#controlled+1] = tok
        end
    end

    local released = false
    return {
        Release = function()
            if released then
                return
            end
            released = true
            for _,tok in ipairs(controlled) do
                if tok.valid and tok.properties ~= nil then
                    local count = tok.properties._tmp_aicontrol - 1
                    if count < 0 then
                        count = 0
                    end
                    tok.properties._tmp_aicontrol = count
                    if count == 0 then
                        tok.properties._tmp_aipromptCallback = nil
                    end
                end
            end
        end,
    }
end

-- Builds the prompt callback for an activation context. The engine calls
-- this when an ability being resolved needs a secondary choice (a shift
-- destination, a push direction, an invoked sub-ability's targets).
--
-- Return contract (consumed by AbilityInvokeAbility.lua):
--   "inherit" -> use the targets we wrote into options; no manual prompt
--   "prompt"  -> fall through to the normal manual prompt UI
--   any other string returned by a handler is passed through as-is
function Adapter.MakePromptCallback(ctx)
    return function(invokerToken, casterToken, abilityClone, symbols, options)
        -- 1) A spec pre-set the answer for an expected prompt (combo support).
        local expected = ctx.expectedPrompt
        if expected ~= nil and expected.casterid == invokerToken.charid then
            ctx.expectedPrompt = nil
            if expected.sleep then
                Warmind.Sleep(expected.sleep)
            end
            options.targets = expected.targets
            Warmind.Trace("Prompt '%s' answered from expected-prompt preset.", abilityClone.name)
            return "inherit"
        end

        -- 2) A registered prompt handler. Monster-qualified names win over
        -- generic ones.
        local monsterType = invokerToken.properties:try_get("monster_type", "")
        local qualified = string.format("%s:%s", monsterType, abilityClone.name)
        local handler = Warmind.prompts[qualified] or Warmind.prompts[abilityClone.name]

        if handler ~= nil then
            local result = handler.handler(ctx, invokerToken, casterToken, abilityClone, symbols, options)
            if type(result) == "string" then
                -- e.g. "skip": pass engine-understood strings through.
                Warmind.Trace("Prompt '%s' handler returned '%s'.", abilityClone.name, result)
                return result
            end
            if result ~= nil then
                for k,v in pairs(result) do
                    options[k] = v
                end
                Warmind.Trace("Prompt '%s' handled automatically.", abilityClone.name)
                return "inherit"
            end
            -- Handler declined; fall through to manual.
        end

        -- 3) Fail closed: hand the prompt to the DM and say why.
        Warmind.Trace("[%s] Prompt '%s' for %s -> manual.",
            Warmind.reason.UNSUPPORTED_COMPLEX_PROMPT, abilityClone.name, monsterType)
        return "prompt"
    end
end

-- ----------------------------------------------------------------------------
-- Movement.
-- ----------------------------------------------------------------------------

-- Moves the token to loc and paces so the table can follow the action.
-- Movement errors propagate to the activation guard (Warmind.Guard), which
-- ends the activation as held/EXECUTION_ERROR with control released.
function Adapter.MoveTo(token, loc, options)
    options = options or {}
    if loc == nil then
        return true
    end

    token:Move(loc, {
        maxCost = options.maxCost or 10000,
        ignoreFalling = options.ignoreFalling == true,
    })
    Warmind.Sleep(options.sleep or 0.5)
    return true
end

-- ----------------------------------------------------------------------------
-- Line-of-sight rays (visual feedback while the AI attacks).
-- ----------------------------------------------------------------------------

-- The LuaTargetingMarkers stub documents :Destroy() as the teardown for
-- dmhub.MarkLineOfSight, but the legacy baseline called :DestroyLineOfSight().
-- Try both so teardown works on either engine surface; a leaked marker is
-- visual-only.
local function DestroyRays(rays)
    for _,ray in ipairs(rays) do
        local ok = pcall(function()
            ray:Destroy()
        end)
        if not ok then
            pcall(function()
                ray:DestroyLineOfSight()
            end)
        end
    end
end

-- ----------------------------------------------------------------------------
-- Final legality recheck.
-- ----------------------------------------------------------------------------

-- Re-validates strike targets against the actor's CURRENT position, just
-- before casting. State can change between scoring and execution (a target
-- died to a triggered effect, moved, or we ended up on a different tile), so
-- execution never trusts scoring-time target lists.
-- Targets that are location-only (target.loc without target.token) pass
-- through untouched.
function Adapter.RecheckStrikeTargets(token, ability, targets)
    local range = ability:GetRange(token.properties)
    local result = {}
    for _,target in ipairs(targets) do
        if target.token == nil then
            result[#result+1] = target
        else
            local tok = target.token
            if tok.valid and tok.properties ~= nil and (not tok.properties:IsDead()) then
                local dist = token:Distance(tok)
                -- A charge target may be out of range from here: the charge
                -- moves us into range as part of execution.
                if dist <= range or target.charge ~= nil then
                    local los = token:GetLineOfSight(tok, token.properties:GetPierceWalls())
                    if los > 0 then
                        result[#result+1] = target
                    end
                end
            end
        end
    end
    return result
end

-- ----------------------------------------------------------------------------
-- Ability execution.
-- ----------------------------------------------------------------------------

-- Casts an ability on the given targets and waits for it to finish.
--
-- targets: array of { token = CharacterToken, charge = Loc|nil } and/or
--          { loc = Loc } entries. nil targets means: auto-fill for burst
--          ("all") abilities, otherwise cast untargeted.
-- options: {
--   symbols        extra cast symbols (e.g. targetPairs for squad strikes)
--   sleep          pause after the cast resolves (default 1.0)
--   timeoutSeconds watchdog override (default Warmind.ABILITY_TIMEOUT_SECONDS)
-- }
--
-- Returns a DecisionResult. Never hangs: a cast that does not report
-- completion within the watchdog window returns manual/EXECUTION_TIMEOUT.
function Adapter.ExecuteAbilityAndWait(ctx, casterToken, ability, targets, options)
    options = options or {}

    if not ability:CanAfford(casterToken) then
        return Warmind.ResultSkipped(Warmind.reason.CANNOT_AFFORD,
            string.format("Cannot afford %s", ability.name))
    end

    local symbols = options.symbols or {}
    symbols.mode = symbols.mode or 1

    if targets == nil then
        targets = {}
        if ability.targetType == "all" then
            -- Burst ability: auto-target everything that passes the
            -- ability's own filter within range.
            local range = ability:GetRange(casterToken.properties)
            for _,tok in ipairs(dmhub.allTokens) do
                if tok.valid and tok.properties ~= nil
                    and ability:TargetPassesFilter(casterToken, tok, symbols)
                    and tok:Distance(casterToken) <= range then
                    targets[#targets+1] = { token = tok }
                end
            end
        end
    else
        local numTargets = ability:GetNumTargets(casterToken)
        table.resize_array(targets, numTargets)
    end

    -- Melee-and-ranged abilities resolve to the proper variation based on
    -- whether every target is in melee range.
    if ability:try_get("meleeAndRanged") then
        local meleeRange = ability.meleeVariation:GetRange(casterToken.properties)
        local inMeleeRange = true
        for _,target in ipairs(targets) do
            if target.token ~= nil and casterToken:Distance(target.token) > meleeRange then
                inMeleeRange = false
                break
            end
        end

        if inMeleeRange then
            ability = ability.meleeVariation
        else
            ability = ability.rangedVariation
        end
    end

    -- Charges: move into contact along the precomputed charge line before
    -- the strike resolves.
    for _,target in ipairs(targets) do
        if target.charge ~= nil then
            local chargeToken = casterToken
            if symbols.targetPairs ~= nil then
                for _,pair in ipairs(symbols.targetPairs) do
                    chargeToken = dmhub.GetTokenById(pair.a)
                end
            end

            Warmind.Sleep(0.6)
            Adapter.Speech(ctx, chargeToken, "Charge!")
            Warmind.Sleep(0.3)
            chargeToken:Move(target.charge, {maxCost = 10000, ignoreFalling = false})
            Warmind.Sleep(0.6)
            target.charge = nil
        end
    end

    -- Visual feedback: mark attack rays unless a squad cast manages its own.
    local rays = {}
    if symbols.targetPairs == nil then
        for _,target in ipairs(targets) do
            if target.token ~= nil then
                local ok, ray = pcall(function()
                    return dmhub.MarkLineOfSight(casterToken, target.token, casterToken.properties:GetPierceWalls())
                end)
                if ok and ray ~= nil then
                    rays[#rays+1] = ray
                end
            end
        end
    end

    ability = ability:MakeTemporaryClone()

    options.symbols = symbols
    options.targets = targets
    options.countsAsCast = true

    local finished = false
    local baseFinishCast = ability:try_get("OnFinishCast")
    ability.OnFinishCast = function(ab, finishOptions)
        if baseFinishCast then
            baseFinishCast(ab, finishOptions)
        end
        finished = true
    end

    Warmind.Trace("Casting '%s' with %d target(s).", ability.name, #targets)

    -- Run the invoke in its OWN engine coroutine and watchdog it from this
    -- one. ExecuteInvoke blocks internally until the cast completes or is
    -- cancelled (it has its own wait loops that never check our stop flag),
    -- so invoking it inline would make a stuck cast hang the AI with no
    -- recourse. From here the watchdog genuinely bounds the wait.
    --
    -- ExecuteInvoke returns only on completion or cancel; if it has
    -- returned and OnFinishCast still has not fired, the cast was almost
    -- certainly cancelled by the DM, so we shrink the remaining wait to a
    -- short grace window instead of burning the full timeout.
    local invokeReturned = false
    dmhub.Coroutine(function()
        ActivatedAbilityInvokeAbilityBehavior.ExecuteInvoke(casterToken, ability, casterToken, "inherit", symbols, options)
        invokeReturned = true
    end)

    local deadline = dmhub.Time() + (options.timeoutSeconds or Warmind.ABILITY_TIMEOUT_SECONDS)
    local graceApplied = false
    local timedOut = false
    local stopped = false
    while not finished do
        if invokeReturned and not graceApplied then
            graceApplied = true
            local grace = dmhub.Time() + 2
            if grace < deadline then
                deadline = grace
            end
        end
        if dmhub.Time() >= deadline then
            timedOut = true
            break
        end
        if Warmind.stopRequested then
            stopped = true
            break
        end
        coroutine.yield(0.1)
    end

    DestroyRays(rays)

    if stopped and not finished then
        return Warmind.ResultManual(Warmind.reason.TAKEN_OVER_BY_DM,
            string.format("Stopped while '%s' was resolving; the DM has control.", ability.name),
            { ability = ability.name })
    end

    if timedOut then
        if invokeReturned then
            -- Cancelled cast: the engine finished its invoke without the
            -- cast ever completing.
            return Warmind.ResultManual(Warmind.reason.TAKEN_OVER_BY_DM,
                string.format("'%s' was cancelled or did not complete; the DM has control.", ability.name),
                { ability = ability.name })
        end
        return Warmind.ResultManual(Warmind.reason.EXECUTION_TIMEOUT,
            string.format("'%s' did not finish resolving within %ds; the DM should finish it manually.",
                ability.name, options.timeoutSeconds or Warmind.ABILITY_TIMEOUT_SECONDS),
            { ability = ability.name })
    end

    Warmind.Sleep(options.sleep or 1.0)

    return Warmind.ResultExecuted{ ability = ability.name, targets = #targets }
end

-- ----------------------------------------------------------------------------
-- Flavor speech.
-- ----------------------------------------------------------------------------

-- Makes the token say something. text may be a string or an array of strings
-- (one is picked at random). Speech is flavor only: it is never allowed to
-- fail an activation, so the lookup is guarded and a missing Speech ability
-- just no-ops.
function Adapter.Speech(ctx, token, text, options)
    if token == nil or (not token.valid) then
        return
    end
    if type(text) == "table" then
        text = text[math.random(1, #text)]
    end

    local ok, ability = pcall(function()
        return MCDMImporter.GetStandardAbility("Speech")
    end)
    if (not ok) or ability == nil then
        return
    end

    ability = ability:MakeTemporaryClone()
    MCDMUtils.DeepReplace(ability, "<<text>>", text)

    options = options or {}
    options.sleep = options.sleep or 0.2
    Adapter.ExecuteAbilityAndWait(ctx, token, ability, {}, options)
end

-- Pre-sets the answer for the next prompt raised by casterToken, so specs
-- can run multi-ability combos (cast A, auto-answer A's prompt, then cast B).
function Adapter.SetExpectedPrompt(ctx, casterToken, targets, options)
    options = options or {}
    ctx.expectedPrompt = {
        casterid = casterToken.charid,
        targets = targets,
        sleep = options.sleep,
    }
end
