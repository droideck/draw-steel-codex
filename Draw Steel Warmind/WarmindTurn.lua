local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindTurn.lua
--
-- The activation loop: the single decision path for a monster turn.
--
--   PlayCurrentTurn
--     for each token in the current initiative entry:
--       minions -> WarmindSquads (dedicated subsystem)
--       others  -> PlayActivation:
--           install prompt control (adapter)
--           loop: build snapshot -> enumerate legal candidates for the
--                 remaining budget -> pick best -> execute -> record result
--           release control (always)
--     advance initiative (unless the DM took over)
--
-- There is no phase bus and no pipeline: this file IS the control flow.
--
-- Error containment is two-tier:
--   * Each activation body runs inside Warmind.Guard, so a Lua error in a
--     spec ends that activation as held/EXECUTION_ERROR with control state
--     released, and the other tokens in the entry still get their turns.
--   * The panel thread guards PlayCurrentTurn itself and auto-stops the AI
--     if the scaffolding errors, so a bug can never error-loop.
-- ============================================================================

Warmind.Turn = {}
local Turn = Warmind.Turn

-- ----------------------------------------------------------------------------
-- Budget gating.
-- ----------------------------------------------------------------------------

-- Decides whether a spec of the given category may still be used this
-- activation. The engine's CanAfford remains the authority on resources;
-- this gate encodes turn-shape intent: one main action, one maneuver,
-- and the Draw Steel dazed rule (one of main action / maneuver / move).
function Turn.CategoryAllowed(ctx, snapshot, category)
    local budget = snapshot.budget

    if budget.dazed then
        if next(ctx.usedCategories) ~= nil then
            return false
        end
    end

    if category == "main" then
        return budget.hasMainAction and (not ctx.usedCategories.main)
    elseif category == "maneuver" then
        return budget.hasManeuver and (not ctx.usedCategories.maneuver)
    elseif category == "move" then
        return not ctx.usedCategories.move
    end

    -- "free" specs are always allowed.
    return true
end

-- ----------------------------------------------------------------------------
-- Candidate selection.
-- ----------------------------------------------------------------------------

-- Enumerates every applicable spec, scores it, and returns the best
-- candidate: { spec, candidate, abilities } or nil if nothing applies.
function Turn.ChooseCandidate(ctx, snapshot)
    local token = ctx.token
    local best = nil

    for _,spec in ipairs(Warmind.specList) do
        local applicable = (not ctx.skipSpecs[spec.id])
            and Warmind.SpecMatchesMonster(token, spec)
            and Turn.CategoryAllowed(ctx, snapshot, spec.category)

        local abilities = nil
        if applicable and spec.abilities ~= nil then
            abilities = {}
            for i=1,#spec.abilities do
                local entry = Warmind.Snapshot.FindAbility(snapshot, spec.abilities[i])
                if entry == nil then
                    applicable = false
                    break
                end
                if not entry.ability:CanAfford(token) then
                    applicable = false
                    break
                end
                abilities[#abilities+1] = entry.ability
            end
        end

        if applicable then
            local candidate = spec.score(spec, ctx, snapshot, abilities or {})
            if candidate ~= nil and (candidate.score or 0) > 0 then
                Warmind.Trace("  considered %s: score %.2f", spec.id, candidate.score)
                if best == nil or candidate.score > best.candidate.score then
                    best = { spec = spec, candidate = candidate, abilities = abilities or {} }
                end
            end
        end
    end

    return best
end

-- ----------------------------------------------------------------------------
-- The activation loop.
-- ----------------------------------------------------------------------------

-- Runs the decision loop for one token. Assumes control state is installed;
-- runs inside Warmind.Guard. Appends DecisionResults to ctx.results.
function Turn.ActivationLoop(ctx)
    local token = ctx.token

    for iteration = 1, Warmind.MAX_DECISIONS_PER_ACTIVATION do
        if Warmind.stopRequested then
            ctx.results[#ctx.results+1] = Warmind.ResultManual(Warmind.reason.TAKEN_OVER_BY_DM,
                "Stopped between actions; the DM has control.")
            return
        end

        if (not token.valid) or token.properties == nil or token.properties:IsDead() then
            return
        end

        local snapshot = Warmind.Snapshot.Build(token)
        ctx.snapshot = snapshot

        local choice = Turn.ChooseCandidate(ctx, snapshot)
        if choice == nil then
            local executedAny = false
            for _,result in ipairs(ctx.results) do
                if result.status == "executed" then
                    executedAny = true
                    break
                end
            end

            if executedAny then
                ctx.results[#ctx.results+1] = Warmind.ResultHeld(Warmind.reason.BUDGET_EXHAUSTED,
                    "No further actions available; ending activation.")
            else
                ctx.results[#ctx.results+1] = Warmind.ResultHeld(Warmind.reason.NO_SUPPORTED_ACTION,
                    string.format("%s: no supported action applied this turn.", ctx.monsterType))
            end
            return
        end

        Warmind.Trace("%s uses %s (score %.2f).", ctx.monsterType, choice.spec.id, choice.candidate.score)

        local result = choice.spec.execute(choice.spec, ctx, choice.candidate, choice.abilities)
        if result == nil then
            result = Warmind.ResultExecuted{ spec = choice.spec.id }
        end
        result.spec = choice.spec.id
        ctx.results[#ctx.results+1] = result

        if result.status == "executed" then
            ctx.usedCategories[choice.spec.category] = true
        else
            -- The spec did not go through; do not pick it again this
            -- activation, but let other specs try.
            ctx.skipSpecs[choice.spec.id] = true
            Warmind.Trace("  %s -> %s", choice.spec.id, Warmind.DescribeResult(result))
        end

        if result.status == "manual" then
            -- Manual outcomes (timeout, takeover) end the activation: the
            -- DM has the table now.
            return
        end
    end

    -- Fell off the decision cap: end the activation with an explicit
    -- terminal result rather than silently.
    local result = Warmind.ResultHeld(Warmind.reason.BUDGET_EXHAUSTED,
        string.format("Activation reached the decision cap (%d); ending turn.",
            Warmind.MAX_DECISIONS_PER_ACTIVATION))
    ctx.results[#ctx.results+1] = result
    Warmind.Trace("%s", Warmind.DescribeResult(result))
end

-- Plays one token's activation with full setup/teardown. Returns the ctx
-- with its results list.
function Turn.PlayActivation(token)
    local ctx = {
        token = token,
        monsterType = token.properties:try_get("monster_type", ""),
        usedCategories = {},
        skipSpecs = {},
        results = {},
        activeTactics = {},
        expectedPrompt = nil,
    }

    for id,tactic in pairs(Warmind.tactics) do
        if Warmind.SpecMatchesMonster(token, tactic) then
            ctx.activeTactics[id] = tactic
        end
    end

    Warmind.Trace("Activation: %s", ctx.monsterType)

    local control = Warmind.Adapter.BeginControl({token}, Warmind.Adapter.MakePromptCallback(ctx))

    local ok, err = Warmind.Guard(function()
        Turn.ActivationLoop(ctx)
    end)

    control.Release()

    if not ok then
        local result = Warmind.ResultHeld(Warmind.reason.EXECUTION_ERROR,
            string.format("Lua error during activation: %s", tostring(err)))
        ctx.results[#ctx.results+1] = result
        Warmind.Trace("%s", Warmind.DescribeResult(result))
    end

    return ctx
end

-- ----------------------------------------------------------------------------
-- Turn driver.
-- ----------------------------------------------------------------------------

-- Plays the current initiative entry: every token in it activates, then
-- initiative advances. Safe to call only from a coroutine.
--
-- Returns { manualPending = boolean }. manualPending means an activation
-- ended with a manual outcome (watchdog timeout, cancelled cast): the DM
-- must finish that action and advance initiative themselves, so this
-- function does NOT advance and the caller should pause the AI.
function Turn.PlayCurrentTurn()
    local summary = { manualPending = false }

    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        return summary
    end

    local initiativeid = queue:CurrentInitiativeId()
    if initiativeid == nil then
        return summary
    end

    local tokens = InitiativeQueue.GetTokensForInitiativeId(initiativeid) or {}

    for i=1,#tokens do
        local token = tokens[i]

        if Warmind.stopRequested then
            Warmind.Trace("[%s] Turn interrupted; not advancing initiative.", Warmind.reason.TAKEN_OVER_BY_DM)
            return summary
        end

        if token.valid and token.properties ~= nil and (not token.properties:IsDead())
            and Warmind.IsControllableMonster(token) then

            if token.properties.minion then
                local squadMembers, captain, alreadyProcessed = Warmind.Squads.CollectSquad(tokens, i)
                if not alreadyProcessed then
                    Warmind.Squads.PlayActivation(squadMembers, captain)
                end
            else
                local ctx = Turn.PlayActivation(token)
                for _,result in ipairs(ctx.results) do
                    if result.status == "manual" then
                        summary.manualPending = true
                    end
                end

                if summary.manualPending then
                    -- The DM has the table: do not act with the remaining
                    -- tokens in this entry and do not advance initiative.
                    Warmind.Trace("Manual outcome pending; leaving initiative untouched for the DM.")
                    return summary
                end
            end
        end
    end

    if Warmind.stopRequested then
        Warmind.Trace("[%s] Turn finished but stop was requested; not advancing initiative.", Warmind.reason.TAKEN_OVER_BY_DM)
        return summary
    end

    -- Verify the turn is still ours to advance: the DM may have advanced or
    -- changed initiative while we were acting.
    if dmhub.initiativeQueue ~= nil and dmhub.initiativeQueue:CurrentInitiativeId() == initiativeid then
        GameHud.instance:NextInitiative(function()
            dmhub:UploadInitiativeQueue()
        end)
        coroutine.yield(0.5)
    end

    return summary
end
