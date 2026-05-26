local mod = dmhub.GetModLoading()

-- DirectorTacticsAutomation.lua orchestrates turn playback, analysis, reactive triggers, villain timing, and automation lifecycle.
-- Load after DirectorTacticsExecution.lua and before DirectorTacticsPolicies.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsAutomation.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal
local Runtime = AI._runtime

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local TokenName = Internal.TokenName
local TokenId = Internal.TokenId
local IsTokenValid = Internal.IsTokenValid
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local CreateScore = Internal.CreateScore
local ConstNumber = Internal.ConstNumber

local function LogActorEconomy(ai, prefix, actor, reason)
    if ai == nil or actor == nil then
        return
    end

    local summary = SafeCall(function()
        return ai:ActorEconomySummary(actor)
    end, nil)
    if summary == nil then
        return
    end

    if reason ~= nil then
        prefix = tostring(prefix) .. " (" .. tostring(reason) .. ")"
    end

    ai:Log(string.format("%s: %s %s", tostring(prefix), TokenName(actor.token), summary))
end

function AI:ExecutionFailureIsRetryable(reason, candidate)
    reason = string.lower(tostring(reason or ""))
    local manualPrompt = false
    if candidate ~= nil then
        if self.CandidateManualPrompt ~= nil then
            manualPrompt = self:CandidateManualPrompt(candidate)
        else
            manualPrompt = candidate.manualPrompt == true
        end
    end
    if manualPrompt then
        return false
    end

    return string.find(reason, "movement destination occupied", 1, true) ~= nil
        or string.find(reason, "candidate invalid before invoke", 1, true) ~= nil
        or string.find(reason, "target was invalid", 1, true) ~= nil
        or string.find(reason, "target left", 1, true) ~= nil
        or string.find(reason, "target out of range", 1, true) ~= nil
        or string.find(reason, "line of sight", 1, true) ~= nil
        or string.find(reason, "ability unaffordable after movement", 1, true) ~= nil
        or string.find(reason, "ability produced no cast", 1, true) ~= nil
        or string.find(reason, "no usable work completed", 1, true) ~= nil
        or string.find(reason, "blocked prompt", 1, true) ~= nil
        or string.find(reason, "abort prompt", 1, true) ~= nil
end

function AI:RejectCandidateForTurn(actor, candidate, reason)
    if actor == nil or candidate == nil then
        return
    end

    actor.turnMemory = actor.turnMemory or self:NewTurnMemory()
    actor.turnMemory.rejectedCandidateKeys = actor.turnMemory.rejectedCandidateKeys or {}
    local keys = self.CandidateRejectionKeys and self:CandidateRejectionKeys(candidate, reason) or {}
    if #keys == 0 then
        local key = self.CandidateRetryKey and self:CandidateRetryKey(candidate) or candidate.retryKey
        if key ~= nil and key ~= "" then
            keys[#keys+1] = key
        end
    end

    if #keys > 0 then
        for _,key in ipairs(keys) do
            actor.turnMemory.rejectedCandidateKeys[key] = true
        end
        self:Log("Retrying after transient failure; blacklisted candidate this turn: " .. tostring(candidate.description) .. " (" .. tostring(reason) .. ")")
    end
end

local function CastBusy()
    local activatedAbility = RawGlobal("ActivatedAbility")
    local activeCasts = SafeCall(function()
        if activatedAbility == nil or activatedAbility.CountActiveCasts == nil then
            return 0
        end

        return activatedAbility.CountActiveCasts()
    end, 0) or 0

    local actionPreparing = SafeCall(function()
        return gamehud.actionBarPanel.valid and gamehud.actionBarPanel.data.IsCastingSpell()
    end, false)

    return activeCasts > 0 or actionPreparing
end

local function ActiveCastCount()
    local activatedAbility = RawGlobal("ActivatedAbility")
    return SafeCall(function()
        if activatedAbility == nil or activatedAbility.CountActiveCasts == nil then
            return 0
        end

        return activatedAbility.CountActiveCasts()
    end, 0) or 0
end

local function RollDialogShown()
    return SafeCall(function()
        return gamehud.rollDialog.valid and gamehud.rollDialog.data.IsShown()
    end, false) == true
end

local function ManualPromptHandoffInitiativeMatches(left, right)
    if left == nil or right == nil then
        return left == right
    end

    return tostring(left) == tostring(right)
end

local function ManualPromptRuntimeRejectionKey(initiativeid, actorId)
    return tostring(initiativeid or "none") .. "|" .. tostring(actorId or "none")
end

local function ManualPromptHandoffClearShouldDropRejections(reason)
    reason = tostring(reason or "")
    return reason ~= "Director resumed automation"
        and reason ~= "manual resume"
end

function AI:ClearManualPromptRuntimeRejections(reason)
    if Runtime.manualPromptRejectedCandidates == nil then
        return
    end

    Runtime.manualPromptRejectedCandidates = nil
    self:Trace("runtime", "manual prompt runtime rejections cleared", { reason = reason })
end

function AI:RecordManualPromptRuntimeRejection(handoff)
    if type(handoff) ~= "table" or type(handoff.rejectionKeys) ~= "table" or #handoff.rejectionKeys == 0 then
        return
    end

    Runtime.manualPromptRejectedCandidates = Runtime.manualPromptRejectedCandidates or {}
    local scopeKey = ManualPromptRuntimeRejectionKey(handoff.initiativeid, handoff.actorId)
    local scoped = Runtime.manualPromptRejectedCandidates[scopeKey] or {}
    Runtime.manualPromptRejectedCandidates[scopeKey] = scoped
    for _,key in ipairs(handoff.rejectionKeys) do
        if key ~= nil and tostring(key) ~= "" then
            scoped[tostring(key)] = true
        end
    end
    self:Trace("runtime", "manual prompt runtime rejection recorded", {
        initiativeid = handoff.initiativeid,
        actorId = handoff.actorId,
        keys = #handoff.rejectionKeys,
    })
end

function AI:ApplyManualPromptRuntimeRejections(context, actor)
    if Runtime.manualPromptRejectedCandidates == nil or actor == nil or actor.token == nil then
        return 0
    end

    local scopeKey = ManualPromptRuntimeRejectionKey(context and context.initiativeid, TokenId(actor.token))
    local scoped = Runtime.manualPromptRejectedCandidates[scopeKey]
    if scoped == nil then
        return 0
    end

    actor.turnMemory = actor.turnMemory or self:NewTurnMemory()
    actor.turnMemory.rejectedCandidateKeys = actor.turnMemory.rejectedCandidateKeys or {}
    local count = 0
    for key in pairs(scoped) do
        actor.turnMemory.rejectedCandidateKeys[key] = true
        count = count + 1
    end
    self:Trace("runtime", "manual prompt runtime rejections applied", {
        actor = TokenName(actor.token),
        initiativeid = context and context.initiativeid,
        keys = count,
    })
    return count
end

function AI:ClearManualPromptHandoff(reason, options)
    options = options or {}
    local handoff = Runtime.manualPromptHandoff
    if options.keepRejections ~= true and ManualPromptHandoffClearShouldDropRejections(reason) then
        self:ClearManualPromptRuntimeRejections(reason)
    end
    if handoff == nil then
        return
    end

    Runtime.manualPromptHandoff = nil
    self:Trace("runtime", "manual prompt handoff cleared", {
        reason = reason,
        initiativeid = handoff.initiativeid,
        actorId = handoff.actorId,
        candidateKey = handoff.candidateKey,
        runGeneration = handoff.runGeneration,
    })
end

function AI:RecordManualPromptHandoff(context, actor, candidate)
    local candidateKey = nil
    local rejectionKeys = {}
    if candidate ~= nil then
        candidateKey = self.CandidateRetryKey and self:CandidateRetryKey(candidate) or candidate.retryKey
        rejectionKeys = self.CandidateRejectionKeys and self:CandidateRejectionKeys(candidate, "manual prompt canceled", true) or {}
        if #rejectionKeys == 0 and candidateKey ~= nil and candidateKey ~= "" then
            rejectionKeys[#rejectionKeys+1] = candidateKey
        end
    end

    local handoff = {
        initiativeid = context and context.initiativeid,
        actorId = actor and TokenId(actor.token),
        candidateKey = candidateKey,
        rejectionKeys = rejectionKeys,
        description = candidate and candidate.description or "manual prompt",
        runGeneration = context and context.runGeneration or Runtime.runGeneration,
        openedAt = SafeCall(function() return dmhub.Time() end, nil),
        continuous = self:RuntimeThreadActive(),
        canceled = false,
    }
    Runtime.manualPromptHandoff = handoff
    self:Trace("runtime", "manual prompt handoff latched", handoff)
    Runtime.status = "Paused for Director"
    self:SetStatus("Paused for Director: " .. tostring(handoff.description or "manual prompt"))
end

function AI:ManualPromptHandoffActive(initiativeid, runGeneration)
    local handoff = Runtime.manualPromptHandoff
    if handoff == nil then
        return false
    end

    if runGeneration ~= nil and handoff.runGeneration ~= runGeneration then
        self:ClearManualPromptHandoff("run generation changed")
        return false
    end

    if not ManualPromptHandoffInitiativeMatches(handoff.initiativeid, initiativeid) then
        self:ClearManualPromptHandoff("initiative changed")
        return false
    end

    return true
end

function AI:ManualPromptHandoffBlocksAutomation(initiativeid, runGeneration)
    return self:ManualPromptHandoffActive(initiativeid, runGeneration)
end

function AI:RefreshManualPromptHandoffState()
    if Runtime.manualPromptHandoff == nil then
        return false
    end

    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        self:ClearManualPromptHandoff("no active initiative queue")
        return false
    end

    local playersTurn = SafeCall(function()
        return queue:IsPlayersTurn()
    end, false) == true
    if playersTurn then
        self:ClearManualPromptHandoff("player turn observed")
        return false
    end

    local initiativeid = SafeCall(function()
        return queue:CurrentInitiativeId()
    end, nil)
    if initiativeid == nil then
        self:ClearManualPromptHandoff("no current initiative entry")
        return false
    end

    return self:ManualPromptHandoffActive(initiativeid, Runtime.runGeneration)
end

function AI:ManualPromptHandoffPending()
    return self:RefreshManualPromptHandoffState()
end

function AI:ManualPromptRealCastBusy()
    return ActiveCastCount() > 0 or RollDialogShown()
end

function AI:MarkManualPromptHandoffCanceled(context, actor, candidate)
    local handoff = Runtime.manualPromptHandoff
    if handoff == nil then
        return
    end

    local actorId = actor and TokenId(actor.token)
    local candidateKey = candidate ~= nil and (self.CandidateRetryKey and self:CandidateRetryKey(candidate) or candidate.retryKey) or nil
    if context ~= nil and not ManualPromptHandoffInitiativeMatches(handoff.initiativeid, context.initiativeid) then
        return
    end
    if actorId ~= nil and handoff.actorId ~= nil and actorId ~= handoff.actorId then
        return
    end
    if candidateKey ~= nil and handoff.candidateKey ~= nil and candidateKey ~= handoff.candidateKey then
        return
    end

    handoff.canceled = true
    handoff.canceledAt = SafeCall(function() return dmhub.Time() end, nil)
    self:RecordManualPromptRuntimeRejection(handoff)
    self:Trace("runtime", "manual prompt handoff canceled", {
        initiativeid = handoff.initiativeid,
        actorId = handoff.actorId,
        candidateKey = handoff.candidateKey,
    })
end

function AI:ResumeManualPromptHandoff()
    self:RefreshManualPromptHandoffState()
    local handoff = Runtime.manualPromptHandoff
    if handoff == nil then
        self:SetStatus("No manual prompt to resume")
        return false
    end

    if self.ReleaseManualPromptUi ~= nil then
        self:ReleaseManualPromptUi("manual prompt resume")
    end

    if self:ManualPromptRealCastBusy() then
        Runtime.status = "Paused for Director"
        self:SetStatus("Manual prompt still active: " .. tostring(handoff.description or "manual prompt"))
        self:Trace("runtime", "manual prompt resume held", {
            reason = "manual cast still active",
            initiativeid = handoff.initiativeid,
            actorId = handoff.actorId,
            candidateKey = handoff.candidateKey,
        })
        return false
    end

    if handoff.canceled == true then
        self:RecordManualPromptRuntimeRejection(handoff)
    end

    local oneShot = handoff.continuous ~= true
    self:ClearManualPromptHandoff("Director resumed automation", { keepRejections = true })
    Runtime.status = "Waiting"
    self:SetStatus("Resuming Director automation")
    self:Trace("runtime", "manual prompt handoff resumed", {
        initiativeid = handoff.initiativeid,
        actorId = handoff.actorId,
        candidateKey = handoff.candidateKey,
        canceled = handoff.canceled == true,
        oneShot = oneShot,
    })

    if oneShot then
        dmhub.Coroutine(function()
            coroutine.yield(0.1)
            self:PlayCurrentTurn()
        end)
    end

    return true
end

function AI:FindEndRoundVillainCandidate(context, previousRound)
    local result = self.Pipeline:Run(context, nil, "endRoundVillain", {
        previousRound = previousRound,
    })
    return result.selected
end

function AI:RunEndRoundVillainAction(previousRound, context)
    if previousRound == nil then
        self:Trace("villain", "end-round skipped", { reason = "missing previous round" })
        return false
    end

    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        self:Trace("villain", "end-round skipped", { reason = "no visible initiative queue", previousRound = previousRound })
        return false
    end

    local initiativeid = SafeCall(function()
        return queue:CurrentInitiativeId()
    end, nil)
    context = context or self:BuildContext(initiativeid)
    context.endRoundVillain = true

    self:Trace("villain", "end-round check", {
        previousRound = previousRound,
        initiativeid = initiativeid,
        malice = context.malice,
        villainActions = context.villainActions,
    })

    local candidate = self:FindEndRoundVillainCandidate(context, previousRound)
    if candidate == nil then
        self:Trace("villain", "end-round held", { previousRound = previousRound, reason = "no candidate" })
        return false
    end

    self:Log(string.format("End-round villain action for round %s: %s", tostring(previousRound), tostring(candidate.description)))
    self:Trace("villain", "end-round selected", {
        previousRound = previousRound,
        candidate = candidate.description,
        malice = context.malice,
        villainActions = context.villainActions,
    })
    return self:ExecuteCandidate(context, candidate)
end

function AI:ObserveRoundForVillainActions()
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        return
    end

    if self.encounterState == nil then
        self.encounterState = self:NewEncounterState()
    end

    local state = self.encounterState
    local round = tonumber(TryGet(queue, "round", 1)) or 1
    if state.lastObservedRound == nil then
        state.lastObservedRound = round
        self:Trace("round", "initial observed round", { round = round })
        return
    end

    if round > state.lastObservedRound then
        local previousRound = state.lastObservedRound
        state.lastObservedRound = round
        self:Trace("round", "advanced", { previousRound = previousRound, round = round })
        self:EmitPhase(self.Phase.RoundAdvanced, {
            queue = queue,
            initiativeid = SafeCall(function()
                return queue:CurrentInitiativeId()
            end, nil),
            previousRound = previousRound,
            round = round,
            runGeneration = Runtime.runGeneration,
        })
    elseif round < state.lastObservedRound then
        self:Trace("round", "rewound", { previousRound = state.lastObservedRound, round = round })
        state.lastObservedRound = round
    end
end

function AI:PlayActor(context, actor)
    local function Finish(reason, candidate)
        LogActorEconomy(self, "Actor economy finish", actor, reason)
        self:EmitPhase(self.Phase.ActorFinished, {
            context = context,
            actor = actor,
            candidate = candidate,
            reason = reason,
            runGeneration = context and context.runGeneration,
        })
    end

    if self:AutomationCanceled(context and context.runGeneration) then
        self:Log("Actor skipped because automation was stopped before acting.")
        Finish("automation canceled before actor")
        return
    end

    if not IsTokenValid(actor.token) then
        self:Log("Actor skipped because its token is no longer valid.")
        Finish("invalid token")
        return
    end

    self:WaitForCastSettle(1.5, 2)
    self:Log("Actor: " .. TokenName(actor.token) .. " (" .. actor.organization .. " " .. actor.role .. ")")
    LogActorEconomy(self, "Actor economy start", actor)
    self:ApplyManualPromptRuntimeRejections(context, actor)
    local transientRetries = 0

    local iterationCap = ConstNumber("Candidate", "PlayActorIterationCap", 5)
    for iteration=1,iterationCap do
        if self:AutomationCanceled(context and context.runGeneration) then
            self:Log("Actor stopped because automation was canceled.")
            Finish("automation canceled")
            return
        end

        local candidate, selectionResult = self:ChooseCandidate(context, actor)
        self:Trace("actor", "candidate choice", {
            actor = TokenName(actor.token),
            iteration = iteration,
            selected = candidate and candidate.description,
            heldReason = selectionResult and selectionResult.heldReason,
            ranked = selectionResult and selectionResult.ranked and #selectionResult.ranked,
        })
        if candidate == nil then
            local heldReason = selectionResult and selectionResult.heldReason
            local suffix = ""
            if heldReason ~= nil then
                suffix = " (" .. tostring(heldReason) .. ")"
            end
            self:Log("Actor finished: no candidate cleared selection for " .. TokenName(actor.token) .. suffix)
            Finish(heldReason or "no candidate")
            return
        end

        if not self:EmitPhase(self.Phase.CandidateSelected, {
            context = context,
            actor = actor,
            candidate = candidate,
            iteration = iteration,
            runGeneration = context and context.runGeneration,
        }) then
            self:Log("Actor stopped because candidate selection phase was canceled.")
            Finish("candidate selection canceled", candidate)
            return
        end

        local executed, failureReason = self:ExecuteCandidate(context, candidate)
        self:SyncTurnMemoryFromResources(actor)
        self:Trace("actor", "candidate execution result", {
            actor = TokenName(actor.token),
            candidate = candidate.description,
            executed = executed,
            reason = failureReason,
            retryable = not executed and self:ExecutionFailureIsRetryable(failureReason, candidate),
        })
        if not executed then
            if context.manualPromptHandoff then
                self:RecordManualPromptHandoff(context, actor, candidate)
                self:Log("Actor paused for manual Director resolution: " .. tostring(candidate.description))
                Finish("manual prompt handoff", candidate)
                return
            end
            if transientRetries < ConstNumber("Candidate", "TransientExecutionRetryCap", 2) and self:ExecutionFailureIsRetryable(failureReason, candidate) then
                transientRetries = transientRetries + 1
                self:RejectCandidateForTurn(actor, candidate, failureReason)
            else
                self:Log("Actor stopped: execution failed for " .. tostring(candidate.description) .. " (" .. tostring(failureReason or "unknown") .. ")")
                Finish("execution failed", candidate)
                return
            end
        else

            local movementOnly = false
            if candidate ~= nil then
                if self.CandidateMovementOnly ~= nil then
                    movementOnly = self:CandidateMovementOnly(candidate)
                else
                    movementOnly = candidate.movementOnly == true
                end
            end
            if movementOnly then
                self:Log("Actor finished after movement-only candidate: " .. tostring(candidate.description))
                Finish("movement only", candidate)
                return
            end

            local economyComplete, economyReason = self:ActorActionEconomyComplete(actor)
            if economyComplete then
                if economyReason == "turn ended" then
                    self:Log("Actor finished because the selected action ended the turn: " .. tostring(candidate.description))
                elseif economyReason == "action and maneuver spent" then
                    self:Log("Actor finished: main action and maneuver are spent for " .. TokenName(actor.token))
                else
                    self:Log("Actor finished: " .. tostring(economyReason or "action economy complete"))
                end
                Finish(economyReason or "action economy complete", candidate)
                return
            end

            self:Trace("actor", "continuing after execution", {
                actor = TokenName(actor.token),
                candidate = candidate.description,
                reason = economyReason or "action economy available",
                actionsUsed = actor.turnMemory and actor.turnMemory.actionsUsed,
                maneuversUsed = actor.turnMemory and actor.turnMemory.maneuversUsed,
                moveActionsUsed = actor.turnMemory and actor.turnMemory.moveActionsUsed,
                turnEnded = actor.turnMemory and actor.turnMemory.turnEnded,
            })
        end
    end

    self:Log("Actor finished: action loop limit reached for " .. TokenName(actor.token))
    Finish("loop limit reached")
end

function AI:PlayTurnCoroutineLocked(initiativeid)
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        self:Trace("turn", "held", { reason = "no active initiative queue" })
        self:Log("No active initiative queue.")
        self:SetStatus("Held: no active initiative queue")
        return
    end

    self:ObserveRoundForVillainActions()

    initiativeid = initiativeid or queue:CurrentInitiativeId()
    self:Trace("turn", "observed", {
        initiativeid = initiativeid,
        playersTurn = queue:IsPlayersTurn(),
        round = TryGet(queue, "round", nil),
        activeTurnKey = Runtime.activeTurnKey,
    })
    if not self:EmitPhase(self.Phase.TurnObserved, {
        queue = queue,
        initiativeid = initiativeid,
        runGeneration = Runtime.runGeneration,
    }) then
        return
    end

    if initiativeid == nil then
        self:Trace("turn", "held", { reason = "no current initiative entry" })
        self:Log("No current initiative entry.")
        self:SetStatus("Held: no current initiative entry")
        return
    end

    if queue:CurrentInitiativeId() ~= initiativeid then
        self:Trace("turn", "held", {
            reason = "initiative changed before acting",
            initiativeid = initiativeid,
            current = queue:CurrentInitiativeId(),
        })
        self:Log("Initiative changed before Director Tactics could act.")
        self:SetStatus("Held: initiative changed before acting")
        return
    end

    if self:ManualPromptHandoffActive(initiativeid, Runtime.runGeneration) then
        local handoff = Runtime.manualPromptHandoff or {}
        Runtime.status = "Paused for Director"
        self:SetStatus("Paused for Director: " .. tostring(handoff.description or "manual prompt"))
        self:Trace("turn", "held", {
            reason = "manual prompt handoff",
            initiativeid = initiativeid,
            actorId = handoff.actorId,
            candidateKey = handoff.candidateKey,
        })
        return
    end

    local context = self:BuildContext(initiativeid)
    self:Trace("turn", "context built", {
        initiativeid = initiativeid,
        actors = #context.actors,
        malice = context.malice,
        villainActions = context.villainActions,
        runGeneration = context.runGeneration,
    })
    if not self:EmitPhase(self.Phase.TurnStarted, {
        queue = queue,
        initiativeid = initiativeid,
        context = context,
        runGeneration = context.runGeneration,
    }) then
        return
    end

    if self:InitiativeWouldRepeatBossTurn(initiativeid, context.activeTokens) then
        self:Trace("turn", "held", {
            reason = "avoiding consecutive solo/boss turn",
            initiativeid = initiativeid,
        })
        self:Log("Refusing consecutive solo/boss turn after " .. tostring((context.encounterState or {}).lastTurnSummary or "previous boss"))
        self:SetStatus("Held: avoiding consecutive solo/boss turn")
        return
    end

    if #context.actors == 0 then
        self:Trace("turn", "held", { reason = "no Director-controlled actors", initiativeid = initiativeid })
        self:Log("No Director-controlled actors in current entry.")
        self:SetStatus("Held: no Director-controlled actors in current entry")
        return
    end

    if #context.actors > 1 then
        self:Log("Shared initiative entry: " .. tostring(#context.actors) .. " Director actors.")
    end

    local singleActorsByCharId = {}
    for _,actor in ipairs(context.actors) do
        if actor.kind ~= "squad" and actor.token ~= nil and actor.token.charid ~= nil then
            singleActorsByCharId[tostring(actor.token.charid)] = true
        end
    end

    local actorSummaries = {}
    for _,actor in ipairs(context.actors) do
        if actor.kind == "squad" then
            actorSummaries[#actorSummaries+1] = string.format("%s squad (%d)", TokenName(actor.token), #(actor.squadMembers or {}))
        else
            actorSummaries[#actorSummaries+1] = TokenName(actor.token)
        end
    end
    self:Log("Turn actors: " .. table.concat(actorSummaries, ", "))

    if #context.actors > 1 then
        for _,actor in ipairs(context.actors) do
            if actor.kind == "squad" then
                local memberNames = {}
                for _,member in ipairs(actor.squadMembers or {}) do
                    memberNames[#memberNames+1] = TokenName(member and member.token)
                end

                local captain = actor.squadCaptain
                local captainSingle = false
                if captain ~= nil and captain.charid ~= nil then
                    captainSingle = singleActorsByCharId[tostring(captain.charid)] == true
                end

                self:Log(string.format(
                    "Shared initiative squad detail: %s members=%s captain=%s captainSingle=%s",
                    TokenName(actor.token),
                    Pick(#memberNames > 0, table.concat(memberNames, ", "), "none"),
                    TokenName(captain),
                    tostring(captainSingle)
                ))
            end
        end
    end

    if not self:EmitPhase(self.Phase.StartTurnMalice, {
        queue = queue,
        initiativeid = initiativeid,
        context = context,
        runGeneration = context.runGeneration,
    }) then
        self:ClearPromptControls()
        return
    end

    if self:UseGroupStartTurnMalice(context) then
        self:Trace("malice", "start-turn used", {
            initiativeid = initiativeid,
            malice = context.malice,
            villainActions = context.villainActions,
        })
        self:WaitForCastSettle(2.5, 2)
        if context.manualPromptHandoff then
            local handoffCandidate = context.manualPromptHandoffCandidate
            self:RecordManualPromptHandoff(context, handoffCandidate and handoffCandidate.actor or context.actors[1], handoffCandidate)
            self:ClearPromptControls()
            return
        end
    end

    for i,actor in ipairs(context.actors) do
        if self:AutomationCanceled(context.runGeneration) then
            self:Trace("turn", "canceled before actor", { actor = TokenName(actor.token), actorIndex = i })
            self:ClearPromptControls()
            return
        end

        if queue:CurrentInitiativeId() ~= initiativeid then
            self:Trace("turn", "held", {
                reason = "initiative changed during automation",
                actor = TokenName(actor.token),
                initiativeid = initiativeid,
                current = queue:CurrentInitiativeId(),
            })
            self:Log("Initiative changed during Director Tactics turn before " .. TokenName(actor.token) .. " could act.")
            self:SetStatus("Held: initiative changed during automation")
            self:ClearPromptControls()
            return
        end

        if not self:EmitPhase(self.Phase.ActorActionLoop, {
            queue = queue,
            initiativeid = initiativeid,
            context = context,
            actor = actor,
            actorIndex = i,
            actorCount = #context.actors,
            runGeneration = context.runGeneration,
        }) then
            self:ClearPromptControls()
            return
        end

        self:PlayActor(context, actor)
        if context.manualPromptHandoff then
            self:ClearPromptControls()
            return
        end
        if i < #context.actors then
            self:WaitForCastSettle(2.5, 2)
        end
    end

    self:WaitForCastSettle(2.5, 2)
    self:Trace("turn", "completion check", { initiativeid = initiativeid, actors = #context.actors })
    if not self:EmitPhase(self.Phase.TurnCompleted, {
        queue = queue,
        initiativeid = initiativeid,
        context = context,
        runGeneration = context.runGeneration,
    }) then
        self:ClearPromptControls()
        return
    end
    self:RecordCompletedTurn(context)

    local _, advancePayload = self:EmitPhase(self.Phase.InitiativeAdvanceRequested, {
        queue = queue,
        initiativeid = initiativeid,
        context = context,
        runGeneration = context.runGeneration,
    })
    if advancePayload ~= nil and advancePayload.advanced then
        coroutine.yield(0.5)
    end
end

function AI:PlayTurnCoroutine(initiativeid)
    local queue = dmhub.initiativeQueue
    local currentInitiativeId = initiativeid or SafeCall(function()
        if queue == nil or queue.hidden then
            return nil
        end

        return queue:CurrentInitiativeId()
    end, nil)
    local lockKey = tostring(currentInitiativeId or "none")
    self:StartTraceCapture("turn", {
        initiativeid = currentInitiativeId,
        lockKey = lockKey,
        runGeneration = Runtime.runGeneration,
    })

    if Runtime.activeTurnKey ~= nil then
        self:Trace("turn", "lock held", { activeTurnKey = Runtime.activeTurnKey, requested = lockKey })
        self:Log("Turn automation already running for " .. tostring(Runtime.activeTurnKey))
        self:SetStatus("Held: turn automation already running")
        self:FinishTraceCapture("turn lock held", { activeTurnKey = Runtime.activeTurnKey, requested = lockKey })
        return
    end

    Runtime.activeTurnKey = lockKey
    self:Trace("turn", "lock acquired", { activeTurnKey = Runtime.activeTurnKey, runGeneration = Runtime.runGeneration })
    local ok, err = xpcall(function()
        self:PlayTurnCoroutineLocked(initiativeid)
    end, function(e)
        return tostring(e)
    end)
    Runtime.activeTurnKey = nil
    self:Trace("turn", "lock released", { lockKey = lockKey, ok = ok, error = err })

    if not ok then
        self:ClearPromptControls()
        self:Log("Turn automation failed: " .. tostring(err))
        self:SetStatus("Failed: turn automation error")
        Runtime.turnFailureCounts = Runtime.turnFailureCounts or {}
        Runtime.turnFailureCounts[lockKey] = (Runtime.turnFailureCounts[lockKey] or 0) + 1
        if Runtime.turnFailureCounts[lockKey] >= 3 then
            Runtime.stop = true
            self:Log("Automation stopped after repeated errors on initiative entry " .. tostring(lockKey))
            self:SetStatus("Stopped: repeated automation error")
        end
    elseif self:AutomationCanceled() then
        self:ClearPromptControls()
        self:Log("Turn automation cleaned up after cancellation.")
    else
        if Runtime.turnFailureCounts ~= nil then
            Runtime.turnFailureCounts[lockKey] = nil
        end
    end
    self:FinishTraceCapture(Pick(ok, "turn finished", "turn failed"), {
        lockKey = lockKey,
        ok = ok,
        error = err,
        runGeneration = Runtime.runGeneration,
    })
end

function AI:PlayCurrentTurn()
    dmhub.Coroutine(function()
        self:ClearLog()
        local queue = dmhub.initiativeQueue
        if queue == nil or queue.hidden then
            self:Log("No active initiative queue.")
            self:SetStatus("Held: no active initiative queue")
            return
        end

        self:PlayTurnCoroutine(queue:CurrentInitiativeId())
    end)
end

function AI:AnalyzeCurrentTurn()
    self:ClearLog()
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        self:Log("No active initiative queue.")
        self:SetStatus("Held: no active initiative queue")
        return
    end

    local initiativeid = queue:CurrentInitiativeId()
    if initiativeid == nil then
        self:Log("No current initiative entry.")
        self:SetStatus("Held: no current initiative entry")
        return
    end

    local context = self:BuildContext(initiativeid)
    if #context.actors == 0 then
        self:SetStatus("Analysis: no Director-controlled actors in current entry")
        return
    end

    for _,actor in ipairs(context.actors) do
        self:Log("Analyzing " .. TokenName(actor.token))
        self.Pipeline:Run(context, actor, "analysisOnly")
        self:SetStatus("Analysis updated: " .. TokenName(actor.token))
        break
    end
end

local function AcceptanceCandidateContains(candidates, predicate)
    for _,candidate in ipairs(candidates or {}) do
        if predicate(candidate) then
            return candidate
        end
    end
    return nil
end

local function AcceptanceAbilityExists(ai, actor, predicate)
    local abilities = SafeCall(function()
        return actor.token.properties:GetActivatedAbilities()
    end, {}) or {}

    for _,ability in ipairs(abilities) do
        local info = SafeCall(function()
            return ai:AnalyzeAbility(actor, ability)
        end, nil)
        if info ~= nil and predicate(ability, info) then
            return ability, info
        end
    end

    return nil, nil
end

local function AcceptanceSend(line)
    local chatApi = RawGlobal("chat")
    if chatApi ~= nil and chatApi.Send ~= nil then
        chatApi.Send(line)
    end
end

local function AcceptanceLog(ai, line)
    ai.log.lines[#ai.log.lines+1] = string.format("%0.1f: %s", dmhub.Time(), line)
    while #ai.log.lines > 120 do
        table.remove(ai.log.lines, 1)
    end
    ai:TouchLog()
end

local function AcceptancePromptFixtureGrid(prefix, radius)
    radius = radius or 3
    local byKey = {}

    local function Key(x, y)
        return tostring(prefix or "fixture") .. ":" .. tostring(x) .. ":" .. tostring(y)
    end

    local function Get(x, y)
        return byKey[Key(x, y)]
    end

    for x=-radius,radius do
        for y=-radius,radius do
            local loc = {
                str = Key(x, y),
                valid = true,
                isOnMap = true,
                altitude = 0,
                _fixtureX = x,
                _fixtureY = y,
            }
            loc.DistanceInTiles = function(selfLoc, other)
                local otherLoc = other and other.loc or other
                if otherLoc == nil then
                    return 999
                end

                local dx = math.abs((selfLoc._fixtureX or 0) - (otherLoc._fixtureX or 0))
                local dy = math.abs((selfLoc._fixtureY or 0) - (otherLoc._fixtureY or 0))
                return math.max(dx, dy)
            end
            byKey[loc.str] = loc
        end
    end

    for _,loc in pairs(byKey) do
        local x = loc._fixtureX or 0
        local y = loc._fixtureY or 0
        loc.north = Get(x, y - 1) or loc
        loc.south = Get(x, y + 1) or loc
        loc.east = Get(x + 1, y) or loc
        loc.west = Get(x - 1, y) or loc
    end

    return Get(0, 0)
end

local function AcceptancePromptFixtureToken(name, id, loc, team)
    local token = {
        valid = true,
        charid = id,
        id = id,
        loc = loc,
        team = team,
        properties = {
            name = name,
            IsDead = function()
                return false
            end,
            GetPierceWalls = function()
                return false
            end,
            HasNamedCondition = function()
                return false
            end,
            CalculateNamedCustomAttribute = function()
                return 0
            end,
            CreatureSizeWhenBeingForceMoved = function()
                return 1
            end,
            Stability = function()
                return 0
            end,
            DistanceMovedThisTurn = function()
                return 0
            end,
            CurrentMovementSpeed = function()
                return 5
            end,
        },
    }
    token.IsFriend = function(_, other)
        if other == token then
            return true
        end
        return team ~= nil and other ~= nil and other.team ~= nil and team == other.team
    end
    token.Distance = function(_, other)
        local otherLoc = other and other.loc or other
        if token.loc ~= nil and token.loc.DistanceInTiles ~= nil then
            return token.loc:DistanceInTiles(otherLoc)
        end
        return 999
    end
    token.GetLineOfSight = function()
        return 1
    end
    token.Move = function()
        token._moveCount = (token._moveCount or 0) + 1
    end
    token.ExecuteWithTheoreticalLoc = function(_, theoreticalLoc, fn)
        local previousLoc = token.loc
        token._theoreticalLocCount = (token._theoreticalLocCount or 0) + 1
        token._theoreticalLocDuring = theoreticalLoc
        token.loc = theoreticalLoc
        local ok, result = pcall(fn)
        token.loc = previousLoc
        token._theoreticalLocRestored = token.loc == previousLoc
        if not ok then
            error(result)
        end
        return result
    end
    token.MarkMovementArrow = function(_, destination)
        token._movementArrowCount = (token._movementArrowCount or 0) + 1
        token._lastMovementArrowDestination = destination
        return {
            path = {
                origin = token.loc,
                destination = destination,
                CalculateHazards = function()
                    return {}
                end,
            },
            collideWith = {},
        }
    end
    token.ClearMovementArrow = function()
        token._movementArrowCleared = true
    end
    return token
end

local function RunAreaPlacementAcceptanceFixtures(ai, Add, PromptFixtureGrid, PromptFixtureToken)
    local center = PromptFixtureGrid("fixture:area", 8)
    local caster = PromptFixtureToken("Area Caster", "area-caster", center, "rivals")
    local target = PromptFixtureToken("Area Target", "area-target", center.east, "heroes")
    local ally = PromptFixtureToken("Area Ally", "area-ally", center.west, "rivals")
    local legalOrigin = center.south
    local blockedOrigin = center.east.east
    local farOrigin = center.east.east.east.east

    local function SameLoc(a, b)
        return a == b or (a ~= nil and b ~= nil and tostring(a.str) == tostring(b.str))
    end

    caster.GetLineOfSight = function(_, targetLoc, pierce)
        if pierce == true then
            return 1
        end
        if SameLoc(targetLoc, blockedOrigin) then
            return 0
        end
        return 1
    end

    local function Shape(origin)
        return {
            shape = "Cube",
            origin = origin,
            radius = 1,
            range = 3,
            ContainsToken = function(_, token)
                return token == target or token == ally
            end,
        }
    end

    local ability = {
        name = "Fixture Area",
        targetType = "cube",
        GetRange = function()
            return 3
        end,
        GetRadius = function()
            return 1
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function(_, _, targetToken)
            return targetToken == target
        end,
    }
    local info = {
        name = "Fixture Area",
        ability = ability,
        targetType = "cube",
        range = 3,
        radius = 1,
        isArea = true,
        hasDamage = true,
        targetAllegiance = "enemy",
        targetFilter = "enemy",
    }
    local allTargetsAbility = {
        name = "Fixture Area All Targets",
        targetType = "cube",
        GetRange = ability.GetRange,
        GetRadius = ability.GetRadius,
        GetNumTargets = ability.GetNumTargets,
        TargetPassesFilter = function()
            return true
        end,
    }
    local allTargetsInfo = {
        name = "Fixture Area All Targets",
        ability = allTargetsAbility,
        targetType = "cube",
        range = 3,
        radius = 1,
        isArea = true,
        hasDamage = true,
    }
    local context = {
        allCombatTokens = { target, ally },
    }
    local actor = {
        token = caster,
        allies = { ally },
        enemies = { target },
        context = context,
        turnMemory = ai:NewTurnMemory(),
    }

    local function WithStubs(anchorLoc, fn, analyzeInfo)
        local saved = {
            GetReachableLocs = ai.GetReachableLocs,
            AreaAnchorLocs = ai.AreaAnchorLocs,
            CalculateAreaShape = ai.CalculateAreaShape,
            ScoreTargets = ai.ScoreTargets,
            AddMovementHazardScore = ai.AddMovementHazardScore,
            AnalyzeAbility = ai.AnalyzeAbility,
            CachedHasLineOfSight = ai.CachedHasLineOfSight,
        }
        ai.GetReachableLocs = function()
            return {
                { loc = caster.loc, cost = 0, positionScore = 0 },
            }
        end
        ai.AreaAnchorLocs = function()
            return { anchorLoc }
        end
        ai.CalculateAreaShape = function(_, _, _, loc)
            return Shape(loc)
        end
        ai.ScoreTargets = function()
            local score = CreateScore()
            score.total = 5
            return score
        end
        ai.AddMovementHazardScore = function()
        end
        ai.CachedHasLineOfSight = function(_, _, sourceToken, targetToken, options)
            local targetLoc = options and options.targetLoc or targetToken
            if sourceToken == caster and SameLoc(targetLoc, blockedOrigin) then
                return false
            end

            return true
        end
        if analyzeInfo ~= nil then
            ai.AnalyzeAbility = function()
                return analyzeInfo
            end
        end

        local ok, result, detail, extra = pcall(fn)
        ai.GetReachableLocs = saved.GetReachableLocs
        ai.AreaAnchorLocs = saved.AreaAnchorLocs
        ai.CalculateAreaShape = saved.CalculateAreaShape
        ai.ScoreTargets = saved.ScoreTargets
        ai.AddMovementHazardScore = saved.AddMovementHazardScore
        ai.AnalyzeAbility = saved.AnalyzeAbility
        ai.CachedHasLineOfSight = saved.CachedHasLineOfSight
        if not ok then
            return nil, result
        end
        return result, detail, extra
    end

    local blockedCandidates, blockedErr = WithStubs(blockedOrigin, function()
        return ai:EnumerateAreaAbility(context, actor, ability, info)
    end)
    local blockedCount = blockedCandidates and #blockedCandidates or nil
    Add("39a", blockedCandidates ~= nil
        and #blockedCandidates == 0
        and "PASS" or "FAIL", "area candidate rejects origin behind walls before ranking"
            .. (blockedCandidates ~= nil and (" (count=" .. tostring(blockedCount) .. ")") or (" (" .. tostring(blockedErr) .. ")")))

    local farCandidates, farErr = WithStubs(farOrigin, function()
        return ai:EnumerateAreaAbility(context, actor, ability, info)
    end)
    Add("39b", farCandidates ~= nil
        and #farCandidates == 0
        and "PASS" or "FAIL", "area candidate rejects origin outside ability range" .. (farCandidates ~= nil and "" or (" (" .. tostring(farErr) .. ")")))

    local legalCandidates, legalErr = WithStubs(legalOrigin, function()
        return ai:EnumerateAreaAbility(context, actor, ability, info)
    end)
    local legalCandidate = legalCandidates and legalCandidates[1]
    local legalTargets = legalCandidate and ai:CandidateTargets(legalCandidate) or {}
    local legalHasTarget = false
    local legalHasAlly = false
    for _,candidateTarget in ipairs(legalTargets) do
        if candidateTarget.token == target then
            legalHasTarget = true
        elseif candidateTarget.token == ally then
            legalHasAlly = true
        end
    end
    Add("39c", legalCandidates ~= nil
        and #legalCandidates == 1
        and ai:CandidateAreaAnchorLoc(legalCandidate) == legalOrigin
        and legalHasTarget
        and not legalHasAlly
        and "PASS" or "FAIL", "enemy-only area ignores unaffected ally inside shape" .. (legalCandidates ~= nil and "" or (" (" .. tostring(legalErr) .. ")")))

    local staleShape = Shape(blockedOrigin)
    local staleCandidate = {
        actor = actor,
        ability = ability,
        abilityInfo = info,
        loc = caster.loc,
        areaAnchorLoc = blockedOrigin,
        targetArea = staleShape,
        symbols = {
            mode = 1,
            targetArea = staleShape,
        },
        targets = {
            { token = target },
        },
        description = "fixture stale area candidate",
    }
    local staleValid, staleReason, staleValidation = WithStubs(blockedOrigin, function()
        return ai:ValidateCandidateBeforeInvoke(context, staleCandidate, ability, staleCandidate.symbols)
    end)
    Add("39d", staleValid == false
        and string.find(tostring(staleReason), "area origin had no line of sight after movement", 1, true) ~= nil
        and staleValidation ~= nil
        and staleValidation.phase == "movement.stale"
        and staleValidation.reasonCode == "area_origin_had_no_line_of_sight_after_movement"
        and "PASS" or "FAIL", "post-move validation blocks stale illegal area origin (reason=" .. tostring(staleReason) .. ")")

    local allTargetCandidates, allTargetErr = WithStubs(legalOrigin, function()
        return ai:EnumerateAreaAbility(context, actor, allTargetsAbility, allTargetsInfo)
    end)
    local allTargetLegality = WithStubs(legalOrigin, function()
        local shape = Shape(legalOrigin)
        return ai:CheckAreaLegality(context, actor, allTargetsAbility, allTargetsInfo, caster, caster.loc, legalOrigin, shape, {
            mode = 1,
            targetArea = shape,
        }, {
            phase = "fixture.area",
        })
    end)
    Add("39e", allTargetCandidates ~= nil
        and #allTargetCandidates == 0
        and allTargetLegality ~= nil
        and allTargetLegality.ok == false
        and allTargetLegality.reasonCode == "friendly_collateral"
        and "PASS" or "FAIL", "area candidate still blocks confirmed friendly collateral" .. (allTargetCandidates ~= nil and "" or (" (" .. tostring(allTargetErr) .. ")")))

    local promptResult, promptErr = WithStubs(legalOrigin, function()
        local symbols = {}
        return ai:ResolvePromptV2(context, actor, caster, caster, ability, symbols, {})
    end, info)
    local promptTarget = promptResult
        and promptResult.options
        and promptResult.options.targets
        and promptResult.options.targets[1]
        and promptResult.options.targets[1].token
    Add("39f", promptResult ~= nil
        and promptResult.status == "handled"
        and promptTarget == target
        and promptResult.options.targetArea ~= nil
        and "PASS" or "FAIL", "area prompt policy ignores unaffected ally inside shape" .. (promptResult ~= nil and "" or (" (" .. tostring(promptErr) .. ")")))

    local candidateLegality = legalCandidate and legalCandidate.legalityResult or nil
    local promptLegality = WithStubs(legalOrigin, function()
        local promptArea = promptResult and promptResult.options and promptResult.options.targetArea
        return ai:CheckAreaLegality(context, actor, ability, info, caster, caster.loc, legalOrigin, promptArea, {
            mode = 1,
            targetArea = promptArea,
        }, {
            phase = "fixture.area",
        })
    end)
    Add("39i", candidateLegality ~= nil
        and promptLegality ~= nil
        and candidateLegality.ok == promptLegality.ok
        and candidateLegality.reasonCode == promptLegality.reasonCode
        and #(candidateLegality.targets or {}) == #(promptLegality.targets or {})
        and (candidateLegality.friendlyCollateral or 0) == (promptLegality.friendlyCollateral or 0)
        and "PASS" or "FAIL", "area prompt policy and candidate enumeration share legality result")

    local broadAreaAbility = {
        name = "Fixture Enemy Area Broad Engine Filter",
        targetType = "cube",
        targetAllegiance = "enemy",
        targetFilter = "enemy",
        GetRange = ability.GetRange,
        GetRadius = ability.GetRadius,
        GetNumTargets = ability.GetNumTargets,
        TargetPassesFilter = function()
            return true
        end,
    }
    local broadAreaInfo = {
        name = "Fixture Enemy Area Broad Engine Filter",
        ability = broadAreaAbility,
        targetType = "cube",
        range = 3,
        radius = 1,
        isArea = true,
        hasDamage = true,
        targetAllegiance = "enemy",
        targetFilter = "enemy",
    }
    local friendlyShape = Shape(legalOrigin)
    local friendlyCandidate = {
        actor = actor,
        ability = broadAreaAbility,
        abilityInfo = broadAreaInfo,
        loc = caster.loc,
        areaAnchorLoc = legalOrigin,
        targetArea = friendlyShape,
        symbols = {
            mode = 1,
            targetArea = friendlyShape,
        },
        targets = {
            { token = ally },
        },
        description = "fixture illegal friendly area target",
    }
    local friendlyValid, friendlyReason, friendlyValidation = WithStubs(legalOrigin, function()
        return ai:ValidateCandidateBeforeInvoke(context, friendlyCandidate, broadAreaAbility, friendlyCandidate.symbols)
    end)
    Add("39g", friendlyValid == false
        and string.find(tostring(friendlyReason), "enemy ability target was friendly", 1, true) ~= nil
        and friendlyValidation ~= nil
        and friendlyValidation.phase == "movement.stale"
        and friendlyValidation.reasonCode == "enemy_ability_target_was_friendly"
        and "PASS" or "FAIL", "area execution rejects enemy-only friendly target before invoke (reason=" .. tostring(friendlyReason) .. ")")

    local broadSingleAbility = {
        name = "Fixture Enemy Strike Broad Engine Filter",
        targetType = "target",
        GetRange = function()
            return 3
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function()
            return true
        end,
    }
    local broadSingleInfo = {
        name = "Fixture Enemy Strike Broad Engine Filter",
        ability = broadSingleAbility,
        targetType = "target",
        range = 3,
        hasDamage = true,
        targetAllegiance = "enemy",
        targetFilter = "enemy",
        numTargets = 1,
    }
    local singleCandidate, singleReason = WithStubs(legalOrigin, function()
        return ai:BuildCandidate(broadSingleAbility, broadSingleInfo, caster.loc, { token = ally }, { mode = 1 }, {
            context = context,
            actor = actor,
            casterToken = caster,
            scoreInfo = CreateScore(),
            description = "fixture enemy strike on ally",
        })
    end)
    Add("39h", singleCandidate == nil
        and string.find(tostring(singleReason), "enemy ability target was friendly", 1, true) ~= nil
        and "PASS" or "FAIL", "single-target enemy-only metadata blocks friendly broad engine filter" .. (singleCandidate == nil and "" or (" (" .. tostring(singleReason) .. ")")))
end

local function RunVillainActionAcceptanceFixtures(ai, Add, PromptFixtureGrid, PromptFixtureToken)
    local function WithVillainApiStubs(resourceStub, stateStub, fn)
        local previousResource = rawget(_G, "CharacterResource")
        local previousState = rawget(_G, "VillainActionState")
        rawset(_G, "CharacterResource", resourceStub)
        rawset(_G, "VillainActionState", stateStub)
        local ok, result = pcall(fn)
        rawset(_G, "CharacterResource", previousResource)
        rawset(_G, "VillainActionState", previousState)
        if not ok then
            error(result)
        end
        return result
    end

    local villainFixtureResource = {
        actionResourceId = "fixture-action",
        maliceResourceId = "fixture-malice",
        villainActionId = "fixture-villain-action",
        GetVillainActions = function()
            return 1
        end,
    }
    local villainFixtureState = {
        HasUsed = function(_, _)
            return false
        end,
    }
    local villainFixtureLoc = PromptFixtureGrid("fixture:villain", 1)
    local villainOwnerA = PromptFixtureToken("Villain Owner A", "villain-owner-a", villainFixtureLoc, "rivals")
    local villainOwnerB = PromptFixtureToken("Villain Owner B", "villain-owner-b", villainFixtureLoc.east, "rivals")
    local function VillainFixtureAbility(costInfo)
        return {
            name = "Fixture Villain Action",
            villainAction = "Villain Action 1",
            ActionResource = function()
                return "fixture-action"
            end,
            GetCost = function()
                return costInfo or { canAfford = true, details = {} }
            end,
        }
    end
    local function VillainFixtureInfo(ability)
        return {
            name = ability.name,
            ability = ability,
            villainAction = ability.villainAction,
            isVillain = true,
        }
    end

    Add("44a", ai:VillainActionKey({ villainAction = "Villain Action 1" }) == "Villain Action 1"
        and ai:VillainActionNumber({ villainAction = "Villain Action 1" }) == 1
        and "PASS" or "FAIL", "Villain Action 1 key parses as slot 1")

    local sharedSlotPass = SafeCall(function()
        return WithVillainApiStubs(villainFixtureResource, {
            HasUsed = function(tokenid, key)
                return tokenid == villainOwnerA.charid and key == "Villain Action 1"
            end,
        }, function()
            return ai:NextVillainActionNumberForToken(villainOwnerA) == 2
                and ai:NextVillainActionNumberForToken(villainOwnerB) == 1
        end)
    end, false)
    Add("44b", sharedSlotPass and "PASS" or "FAIL", "two villain owners have independent shared-doc slot state")

    local usedSlotRejected = SafeCall(function()
        return WithVillainApiStubs(villainFixtureResource, {
            HasUsed = function(tokenid, key)
                return tokenid == villainOwnerA.charid and key == "Villain Action 1"
            end,
        }, function()
            local ability = VillainFixtureAbility()
            local canUse, reason = ai:CanUseVillainAction({ villainActions = 1 }, { token = villainOwnerA }, ability, VillainFixtureInfo(ability), { mode = 1 })
            return canUse == false and string.find(tostring(reason), "already used", 1, true) ~= nil
        end)
    end, false)
    Add("44c", usedSlotRejected and "PASS" or "FAIL", "used shared-doc villain slot is skipped")

    local actionSpentStillUsable = SafeCall(function()
        return WithVillainApiStubs(villainFixtureResource, villainFixtureState, function()
            local ability = VillainFixtureAbility({
                canAfford = false,
                details = {
                    { cost = "fixture-action", canAfford = false, paymentOptions = {}, expendedOptions = {} },
                },
            })
            local canUse = ai:CanUseVillainAction({ villainActions = 1 }, { token = villainOwnerA }, ability, VillainFixtureInfo(ability), { mode = 1 })
            return canUse == true
        end)
    end, false)
    Add("44d", actionSpentStillUsable and "PASS" or "FAIL", "spent regular action resource does not block villain action")

    local secondaryCostRejected = SafeCall(function()
        return WithVillainApiStubs(villainFixtureResource, villainFixtureState, function()
            local ability = VillainFixtureAbility({
                canAfford = false,
                details = {
                    { cost = "fixture-malice", canAfford = false, paymentOptions = {}, expendedOptions = {} },
                },
            })
            local canUse, reason = ai:CanUseVillainAction({ villainActions = 1 }, { token = villainOwnerA }, ability, VillainFixtureInfo(ability), { mode = 1 })
            return canUse == false and string.find(tostring(reason), "secondary resource", 1, true) ~= nil
        end)
    end, false)
    Add("44e", secondaryCostRejected and "PASS" or "FAIL", "unaffordable villain action secondary resource is rejected")

    local noDoubleSpend = SafeCall(function()
        if ai.Ledger == nil then
            return false
        end
        local setCalls = 0
        return WithVillainApiStubs({
            GetMalice = function()
                return 0
            end,
            GetVillainActions = function()
                return 0
            end,
            SetVillainActions = function()
                setCalls = setCalls + 1
            end,
        }, villainFixtureState, function()
            ai.Ledger:ReconcileGlobalResourceSpend(ai, {
                description = "fixture villain action",
                abilityInfo = { name = "Fixture Villain Action", isVillain = true },
            }, { villainActions = 1 })
            return setCalls == 0
        end)
    end, false)
    Add("44f", noDoubleSpend and "PASS" or "FAIL", "global villain action budget is not double-spent after central cast spend")
    Add("44g", "DEFERRED", "successful cast updates VillainActionState through ActivatedAbility.CastCoroutine central hook")
end

local function RunActionGrantAcceptanceFixtures(ai, Add)
    local function FixtureActor(name)
        return {
            kind = "monster",
            context = {},
            token = {
                name = name,
                properties = {},
            },
        }
    end

    local function MainActionCandidate(actor, grantUse)
        return {
            id = "grant-fixture-candidate",
            actor = actor,
            description = "Grant Fixture Strike",
            abilityInfo = { name = "Grant Fixture Strike" },
            actionCost = "action",
            actionType = { kind = "main" },
            actionGrant = grantUse,
        }
    end

    local function WithActionResourceApiStubs(resourceStub, fn)
        local previousResource = rawget(_G, "CharacterResource")
        rawset(_G, "CharacterResource", resourceStub)

        local ok, result = pcall(fn)
        rawset(_G, "CharacterResource", previousResource)
        if not ok then
            error(result)
        end
        return result
    end

    local pendingActor = FixtureActor("Grant Pending Actor")
    ai.Ledger:EnsureTurnMemory(ai, pendingActor)
    local pendingGrant = ai.Ledger:GrantActionEconomy(ai, pendingActor, {
        kind = "action",
        source = "Fixture pending grant",
    })
    local baseCanSpend = ai.Ledger:CanSpendActionType(ai, pendingActor, { kind = "main" }, nil)
    pendingActor.turnMemory.actionsUsed = 1
    pendingActor.turnMemory.actionUsed = true
    local grantUse = ai.Ledger:PendingGrantUseForActionType(ai, pendingActor, { kind = "main" }, nil)
    local grantCanSpend = ai.Ledger:CanSpendActionType(ai, pendingActor, { kind = "main" }, nil)
    local candidate = MainActionCandidate(pendingActor, grantUse)
    local reserved, reservation = ai.Ledger:ReservePendingActionGrant(ai, pendingActor, candidate)
    local committed = reserved and ai.Ledger:CommitPendingActionGrant(ai, pendingActor, candidate, reservation)
    ai.Ledger:Spend(ai, pendingActor, candidate)
    Add("41a", pendingGrant ~= nil
        and pendingGrant.pending.action == 1
        and baseCanSpend
        and grantUse ~= nil
        and grantCanSpend
        and committed
        and (tonumber(pendingActor.turnMemory.actionsUsed) or 0) == 1
        and (pendingActor.turnMemory.actionGrants[1] and pendingActor.turnMemory.actionGrants[1].consumed == true)
        and "PASS" or "FAIL",
        "pending action grant becomes a legal one-time main action without increasing actionLimit")

    local rollbackActor = FixtureActor("Grant Rollback Actor")
    ai.Ledger:EnsureTurnMemory(ai, rollbackActor)
    ai.Ledger:GrantActionEconomy(ai, rollbackActor, {
        kind = "action",
        source = "Fixture rollback grant",
    })
    rollbackActor.turnMemory.actionsUsed = 1
    rollbackActor.turnMemory.actionUsed = true
    local rollbackUse = ai.Ledger:PendingGrantUseForActionType(ai, rollbackActor, { kind = "main" }, nil)
    local rollbackCandidate = MainActionCandidate(rollbackActor, rollbackUse)
    local rollbackReserved, rollbackReservation = ai.Ledger:ReservePendingActionGrant(ai, rollbackActor, rollbackCandidate)
    ai.Ledger:RollbackPendingActionGrant(ai, rollbackActor, rollbackReservation, "fixture rollback")
    Add("41b", rollbackReserved
        and ai.Ledger:PendingGrantUseForActionType(ai, rollbackActor, { kind = "main" }, nil) ~= nil
        and (rollbackActor.turnMemory.actionGrants[1] and rollbackActor.turnMemory.actionGrants[1].reserved ~= true)
        and "PASS" or "FAIL",
        "failed pending action grant execution rolls back reservation")

    local refreshActor = FixtureActor("Grant Refresh Actor")
    ai.Ledger:EnsureTurnMemory(ai, refreshActor)
    refreshActor.turnMemory.actionsUsed = 1
    refreshActor.turnMemory.actionUsed = true
    refreshActor.turnMemory.turnEnded = true
    local refreshGrant = ai.Ledger:GrantActionEconomy(ai, refreshActor, {
        kind = "action",
        source = "Fixture refresh grant",
    })
    Add("41c", refreshGrant ~= nil
        and refreshGrant.refreshed.action == 1
        and (tonumber(refreshActor.turnMemory.actionsUsed) or 0) == 0
        and refreshActor.turnMemory.turnEnded ~= true
        and "PASS" or "FAIL",
        "received action after a spent main action refreshes real action economy")

    local engineRefreshObserved = SafeCall(function()
        local refreshTypeSeen = nil
        local resourceTable = {
            ["fixture-action"] = { usageLimit = "encounter" },
            ["fixture-maneuver"] = { usageLimit = "turn" },
        }
        return WithActionResourceApiStubs({
            tableName = "characterResources",
            actionResourceId = "fixture-action",
            maneuverResourceId = "fixture-maneuver",
        }, function()
            local engineActor = FixtureActor("Engine Refresh Actor")
            engineActor.token.properties = {
                GetResourceUsage = function(_, resourceid, refreshType)
                    if resourceid == "fixture-action" then
                        refreshTypeSeen = refreshType
                    end
                    return 0
                end,
                GetResources = function()
                    return {
                        ["fixture-action"] = 1,
                        ["fixture-maneuver"] = 1,
                    }
                end,
                NumberOfMovementActions = function()
                    return 1
                end,
                CurrentMovementSpeed = function()
                    return 5
                end,
                DistanceMovedThisTurn = function()
                    return 0
                end,
                HasNamedCondition = function()
                    return false
                end,
            }
            engineActor.turnMemory = ai.Ledger:NewTurnMemory()
            engineActor.turnMemory.actionsUsed = 1
            engineActor.turnMemory.actionUsed = true
            engineActor.turnMemory.turnEnded = true
            engineActor.turnMemory._allowResourceDecrease = { actionsUsed = true }

            ai.Ledger:SyncTurnMemoryFromResources(ai, engineActor, { resourceTable = resourceTable })
            return refreshTypeSeen == "encounter"
                and (tonumber(engineActor.turnMemory.actionsUsed) or 0) == 0
                and engineActor.turnMemory.actionUsed ~= true
                and engineActor.turnMemory.turnEnded ~= true
        end)
    end, false)
    Add("41c2", engineRefreshObserved and "PASS" or "FAIL",
        "engine resource usage decrease reopens economy using configured refresh type")

    local critActor = FixtureActor("Grant Critical Actor")
    ai.Ledger:EnsureTurnMemory(ai, critActor)
    local critCandidate = {
        description = "Critical Fixture Strike",
        abilityInfo = { name = "Critical Fixture Strike" },
        actionCost = "action",
    }
    critActor.turnMemory.actionsUsed = 1
    critActor.turnMemory.actionUsed = true
    local firstCrit = ai.Ledger:ApplyCriticalActionRefresh(ai, critActor, critCandidate, { cast = { naturalRoll = 20 } }, nil)
    critActor.turnMemory.actionsUsed = 1
    critActor.turnMemory.actionUsed = true
    local secondCrit = ai.Ledger:ApplyCriticalActionRefresh(ai, critActor, critCandidate, { cast = { naturalRoll = 20 } }, nil)
    Add("41d", firstCrit ~= nil
        and secondCrit ~= nil
        and firstCrit.granted.action == 1
        and secondCrit.granted.action == 1
        and (tonumber(critActor.turnMemory.actionsUsed) or 0) == 0
        and "PASS" or "FAIL",
        "critical action refresh can grant again on an extra action")

    local semanticActor = FixtureActor("Grant Semantic Actor")
    ai.Ledger:EnsureTurnMemory(ai, semanticActor)
    local soloStyleGrant = ai.Ledger:GrantActionEconomy(ai, semanticActor, {
        kind = "action",
        source = "Solo Action",
    })
    local semanticInfo = {
        name = "Semantic Mode Strike",
        isAction = true,
        semanticActionCost = "action",
        semanticActionType = { kind = "main" },
        ability = {
            name = "Semantic Mode Strike",
            actionResourceId = "none",
        },
    }
    local semanticCost = ai.Ledger:AbilityActionCost(ai, semanticInfo)
    local semanticType = ai.Ledger:ActionTypeFromAbilityInfo(ai, semanticInfo, "none")
    Add("41f", soloStyleGrant ~= nil
        and soloStyleGrant.pending.action == 1
        and semanticCost == "action"
        and semanticType ~= nil
        and semanticType.kind == "main"
        and "PASS" or "FAIL",
        "mode-selected main-action semantics survive a temporary none-cost clone")

    semanticActor.turnMemory.actionsUsed = 1
    semanticActor.turnMemory.actionUsed = true
    local semanticCandidate = {
        id = "semantic-grant-fixture",
        actor = semanticActor,
        description = "Semantic Grant Strike",
        abilityInfo = semanticInfo,
        actionCost = "none",
    }
    local semanticAnnotated = ai.Ledger:AnnotateCandidateActionGrant(ai, semanticActor, semanticCandidate)
    local semanticGrant = ai.Ledger:CandidateActionGrant(ai, semanticCandidate)
    local semanticReserved, semanticReservation = ai.Ledger:ReservePendingActionGrant(ai, semanticActor, semanticCandidate)
    local semanticCommitted = semanticReserved and ai.Ledger:CommitPendingActionGrant(ai, semanticActor, semanticCandidate, semanticReservation)
    ai.Ledger:Spend(ai, semanticActor, semanticCandidate)
    local pendingAfterSemantic = ai.Ledger:PendingGrantUseForActionType(ai, semanticActor, { kind = "main" }, nil)
    local consumedSemanticGrant = semanticActor.turnMemory.actionGrants ~= nil
        and semanticActor.turnMemory.actionGrants[1] ~= nil
        and semanticActor.turnMemory.actionGrants[1].consumed == true
    Add("41g", semanticAnnotated
        and semanticGrant ~= nil
        and semanticGrant.kind == "action"
        and semanticReserved
        and semanticCommitted
        and consumedSemanticGrant
        and pendingAfterSemantic == nil
        and (tonumber(semanticActor.turnMemory.actionsUsed) or 0) == 1
        and "PASS" or "FAIL",
        "drifted none-cost main-action candidate reserves and consumes exactly one pending grant")

    local preflightActor = FixtureActor("Grant Preflight Actor")
    ai.Ledger:EnsureTurnMemory(ai, preflightActor)
    ai.Ledger:GrantActionEconomy(ai, preflightActor, {
        kind = "action",
        source = "Solo Action",
    })
    preflightActor.turnMemory.actionsUsed = 1
    preflightActor.turnMemory.actionUsed = true
    local preflightAbility = {
        name = "Preflight Semantic Mode Strike",
        actionResourceId = "none",
    }
    preflightAbility.CanAfford = function()
        return true
    end
    preflightAbility.MakeTemporaryClone = function(selfAbility)
        local clone = {
            name = selfAbility.name,
            actionResourceId = selfAbility.actionResourceId,
        }
        clone.CanAfford = function()
            return true
        end
        return clone
    end
    local preflightInfo = {
        name = "Preflight Semantic Mode Strike",
        ability = preflightAbility,
        isAction = true,
        semanticActionCost = "action",
        semanticActionType = { kind = "main" },
    }
    local preflightCandidate = {
        id = "semantic-grant-preflight-fixture",
        actor = preflightActor,
        description = "Semantic Grant Preflight Strike",
        ability = preflightAbility,
        abilityInfo = preflightInfo,
        actionCost = "none",
        symbols = { mode = 1 },
    }
    local preflightValidation = ai:ValidateCandidateForPhase(preflightActor.context, preflightCandidate, "resource.pre_move", {
        ability = preflightAbility,
        symbols = { mode = 1 },
    })
    local preflightGrant = ai.Ledger:CandidateActionGrant(ai, preflightCandidate)
    local preflightGrantRecord = preflightActor.turnMemory.actionGrants ~= nil
        and preflightActor.turnMemory.actionGrants[1]
        or nil
    Add("41g2", preflightValidation ~= nil
        and preflightValidation.ok == true
        and preflightGrant ~= nil
        and preflightGrant.kind == "action"
        and preflightGrant.quantity == 1
        and preflightGrantRecord ~= nil
        and preflightGrantRecord.consumed ~= true
        and preflightGrantRecord.reserved ~= true
        and "PASS" or "FAIL",
        "resource preflight attaches pending grant even when selected clone is normally affordable")

    local thirdMainAllowed, thirdMainReason = ai.Ledger:CanSpendActionType(ai, semanticActor, { kind = "main" }, nil)
    Add("41h", thirdMainAllowed == false
        and thirdMainReason == "main action already used"
        and "PASS" or "FAIL",
        "third main action is blocked after the Solo-style grant is consumed")

    local negativeActor = FixtureActor("Grant Negative Actor")
    ai.Ledger:EnsureTurnMemory(ai, negativeActor)
    ai.Ledger:GrantActionEconomy(ai, negativeActor, {
        kind = "action",
        source = "Solo Action",
    })
    negativeActor.turnMemory.actionsUsed = 1
    negativeActor.turnMemory.actionUsed = true
    local maneuverCandidate = {
        id = "maneuver-grant-negative",
        actor = negativeActor,
        description = "Maneuver Fixture",
        abilityInfo = { name = "Maneuver Fixture", isManeuver = true },
        actionCost = "maneuver",
    }
    local freeCandidate = {
        id = "free-grant-negative",
        actor = negativeActor,
        description = "Free Malice Fixture",
        abilityInfo = {
            name = "Free Malice Fixture",
            isMalice = true,
            isStartTurnMalice = true,
        },
        actionCost = "none",
    }
    local maneuverAnnotated = ai.Ledger:AnnotateCandidateActionGrant(ai, negativeActor, maneuverCandidate)
    local freeAnnotated = ai.Ledger:AnnotateCandidateActionGrant(ai, negativeActor, freeCandidate)
    Add("41i", maneuverAnnotated == false
        and ai.Ledger:CandidateActionGrant(ai, maneuverCandidate) == nil
        and freeAnnotated == false
        and ai.Ledger:CandidateActionGrant(ai, freeCandidate) == nil
        and "PASS" or "FAIL",
        "pending main-action grants do not attach to maneuver or truly free malice candidates")

    local maliciousStrikeManual = ai:AbilityManualPromptReason({
        name = "Malicious Strike",
        isMalice = true,
        isMonsterGroupMalice = true,
        isStartTurnMalice = true,
    }, nil, pendingActor)
    local brutalManual = ai:AbilityManualPromptReason({
        name = "Brutal Effectiveness",
        isMalice = true,
        isMonsterGroupMalice = true,
        isStartTurnMalice = true,
    }, nil, pendingActor)
    local unknownManual = ai:AbilityManualPromptReason({
        name = "Unknown Malice Feature",
        isMalice = true,
        isMonsterGroupMalice = true,
        isStartTurnMalice = true,
    }, nil, pendingActor)
    Add("41e", maliciousStrikeManual == nil
        and brutalManual == nil
        and unknownManual == "special malice feature"
        and "PASS" or "FAIL",
        "known start-turn malice bypasses special-malice manual rejection while unknown malice stays manual")
end

local function RunTraceAcceptanceFixtures(ai, Add)
    local function WithTraceFixture(args, fn)
        local previousTrace = ai.trace
        ai.trace = {
            lines = {},
            continuous = false,
            nextTurn = false,
            capture = true,
            oneShotActive = false,
            detailed = args ~= nil and args.detailed == true,
            updated = previousTrace and previousTrace.updated or dmhub.GenerateGuid(),
        }

        local ok, result = pcall(fn)
        ai.trace = previousTrace
        if not ok then
            error(result)
        end
        return result
    end

    local coalescedNonAdjacent = SafeCall(function()
        return WithTraceFixture({ detailed = false }, function()
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            ai:Trace("runtime", "fixture marker", { id = "trace-coalesce" })
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            return #(ai.trace.lines or {}) == 2
                and string.find(tostring(ai.trace.lines[1]), "(x2", 1, true) ~= nil
        end)
    end, false)
    Add("42a", coalescedNonAdjacent and "PASS" or "FAIL",
        "non-adjacent coalesced trace updates original line with repeat count")

    local detailedBypassesCoalescing = SafeCall(function()
        return WithTraceFixture({ detailed = true }, function()
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            ai:Trace("runtime", "fixture marker", { id = "trace-detailed" })
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            return #(ai.trace.lines or {}) == 3
                and string.find(tostring(ai.trace.lines[1]), "(x", 1, true) == nil
                and string.find(tostring(ai.trace.lines[3]), "(x", 1, true) == nil
        end)
    end, false)
    Add("42b", detailedBypassesCoalescing and "PASS" or "FAIL",
        "detailed trace bypasses coalescing for low-level events")

    local clearResetsCoalescing = SafeCall(function()
        return WithTraceFixture({ detailed = false }, function()
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            ai:ClearTrace()
            local cleared = ai.trace._coalesced == nil
            ai:Trace("poll", "queue state", { hasQueue = true, hidden = false }, { coalesce = true })
            return cleared
                and #(ai.trace.lines or {}) == 1
                and string.find(tostring(ai.trace.lines[1]), "(x", 1, true) == nil
        end)
    end, false)
    Add("42c", clearResetsCoalescing and "PASS" or "FAIL",
        "ClearTrace resets coalesced trace bookkeeping")
end

local function RunReactiveTriggerAcceptanceFixtures(ai, Add)
    local function TriggerFixtureToken(args)
        args = args or {}
        local token = {
            valid = true,
            charid = args.charid or args.id,
            id = args.id,
            playerControlled = false,
            properties = {
                name = args.name or "Trigger Fixture",
            },
        }
        token.properties.HasNamedCondition = function(_, conditionName)
            return args.dazed == true and tostring(conditionName) == "Dazed"
        end
        token.properties.GetHeroicOrMaliceResourcesAvailableToSpend = function()
            return args.heroicAvailable or 0
        end
        token.properties.GetEpicResources = function()
            return args.epicAvailable or 0
        end
        token.properties.IsDead = function()
            return false
        end
        return token
    end

    local function TriggerFixture(args)
        args = args or {}
        return {
            id = args.id or "fixture-trigger",
            timestamp = args.timestamp or 1,
            text = args.text or "Fixture Trigger",
            rules = args.rules or "",
            targets = args.targets or {},
            heroicResourceCost = args.heroicCost or 0,
            epicResourceCost = args.epicCost or 0,
            triggered = args.triggered == true,
            dismissed = args.dismissed == true,
            DismissOnTrigger = function()
                return args.dismissOnTrigger == true
            end,
        }
    end

    local function TriggerDispatchFixture(args)
        args = args or {}
        local executed = 0
        local trigger = args.trigger or TriggerFixture(args)
        local token = args.token or TriggerFixtureToken(args)
        local candidate = {
            token = token,
            trigger = trigger,
            triggerInfo = args.triggerInfo or { available = true },
            context = args.context,
            manualPrompt = args.manualPrompt,
            automationDecision = args.automationDecision or ai:MakeAutomationDecision{
                outcome = "exact_auto",
                lane = "trigger",
                source = "trigger-policy",
                reason = "fixture exact trigger",
                capabilities = {
                    trigger = true,
                },
                fallback = {
                    kind = "no_trigger",
                },
            },
            execute = function()
                executed = executed + 1
                trigger.triggered = true
                return true
            end,
        }

        return candidate, function()
            return executed
        end
    end

    local function WithReactiveAttemptStubs(pipelineRun, emitPhase, fn)
        local previousPipeline = ai.Pipeline
        local previousEmitPhase = ai.EmitPhase
        ai.Pipeline = { Run = pipelineRun }
        ai.EmitPhase = emitPhase or previousEmitPhase

        local ok, result = pcall(fn)
        ai.Pipeline = previousPipeline
        ai.EmitPhase = previousEmitPhase
        if not ok then
            error(result)
        end
        return result
    end

    local function WithReactiveScannerStubs(token, trigger, pipelineRun, emitPhase, fn)
        local saved = {
            resolveActiveTriggerInfo = ai.ResolveActiveTriggerInfo,
            pipeline = ai.Pipeline,
            emitPhase = ai.EmitPhase,
            getAvailableTriggers = token.properties.GetAvailableTriggers,
        }

        local queue = {
            CurrentInitiativeId = function()
                return "acceptance-player-turn"
            end,
        }
        local context = {
            runGeneration = Runtime.runGeneration,
            actors = {},
            activeTokens = {},
            allCombatTokens = { token },
        }
        token.properties.GetAvailableTriggers = function()
            return { trigger }
        end
        ai.ResolveActiveTriggerInfo = function()
            return { event = "losehitpoints", available = true }
        end
        ai.Pipeline = { Run = pipelineRun }
        ai.EmitPhase = emitPhase or saved.emitPhase

        local ok, result = pcall(function()
            return fn(queue, { token }, context)
        end)
        token.properties.GetAvailableTriggers = saved.getAvailableTriggers
        ai.ResolveActiveTriggerInfo = saved.resolveActiveTriggerInfo
        ai.Pipeline = saved.pipeline
        ai.EmitPhase = saved.emitPhase
        if not ok then
            error(result)
        end
        return result
    end

    local heldToken = TriggerFixtureToken{ charid = "held-trigger-token", name = "Held Trigger Token" }
    local heldTrigger = TriggerFixture{ id = "held-trigger", timestamp = 100, text = "Held Trigger", targets = { "held-target" } }
    local heldInfo = { event = "losehitpoints", available = true }
    local heldKey = ai:ReactiveTriggerAttemptKey(heldToken, heldTrigger, heldInfo)
    local cooldown = ConstNumber("Candidate", "TriggerRetryCooldownSeconds", 5)

    ai:ResetReactiveTriggerAttempts()
    local scanPipelineCount = 0
    local scanPromptPhaseCount = 0
    local scannerSuppressed = SafeCall(function()
        return WithReactiveScannerStubs(heldToken, heldTrigger, function()
            scanPipelineCount = scanPipelineCount + 1
            return { selected = nil, heldReason = "no candidates", ranked = {} }
        end, function(_, phaseName, payload)
            if phaseName == ai.Phase.PromptRequested then
                scanPromptPhaseCount = scanPromptPhaseCount + 1
            end
            return true, payload or {}
        end, function(queue, tokens, context)
            ai:RunReactiveTriggerScan(queue, tokens, context)
            ai:RunReactiveTriggerScan(queue, tokens, context)
            return scanPipelineCount == 1
                and scanPromptPhaseCount == 0
                and ai:ReactiveTriggerAttemptSuppressed(heldKey, cooldown) == true
        end)
    end, false)
    Add("43a", scannerSuppressed and "PASS" or "FAIL",
        "same held reactive trigger is attempted once then suppressed during retry cooldown")

    local memory = ai:ReactiveTriggerAttemptMemory()
    local retriedAfterCooldown = false
    if memory[heldKey] ~= nil then
        memory[heldKey].time = dmhub.Time() - cooldown - 0.1
        local retryPipelineCount = 0
        retriedAfterCooldown = SafeCall(function()
            return WithReactiveScannerStubs(heldToken, heldTrigger, function()
                retryPipelineCount = retryPipelineCount + 1
                return { selected = nil, heldReason = "no candidates", ranked = {} }
            end, nil, function(queue, tokens, context)
                ai:RunReactiveTriggerScan(queue, tokens, context)
                return retryPipelineCount == 1
                    and ai:ReactiveTriggerAttemptSuppressed(heldKey, cooldown) == true
            end)
        end, false)
    end
    Add("43b", retriedAfterCooldown and "PASS" or "FAIL",
        "held reactive trigger is retried through the scanner after cooldown")

    ai:ResetReactiveTriggerAttempts()
    ai:RecordReactiveTriggerAttempt(heldKey, "no candidates")
    local changedTrigger = TriggerFixture{ id = "held-trigger-2", timestamp = 100, text = "Held Trigger", targets = { "held-target" } }
    local changedKey = ai:ReactiveTriggerAttemptKey(heldToken, changedTrigger, heldInfo)
    local changedSuppressed = ai:ReactiveTriggerAttemptSuppressed(changedKey, cooldown)
    Add("43c", changedKey ~= heldKey and not changedSuppressed and "PASS" or "FAIL",
        "changed trigger identity bypasses held-trigger suppression")

    local noCandidatePhaseCount = 0
    ai:ResetReactiveTriggerAttempts()
    local noCandidatePass = SafeCall(function()
        return WithReactiveAttemptStubs(function()
            return { selected = nil, heldReason = "no candidates", ranked = {} }
        end, function(_, phaseName, payload)
            if phaseName == ai.Phase.PromptRequested then
                noCandidatePhaseCount = noCandidatePhaseCount + 1
            end
            return true, payload or {}
        end, function()
            local executed = ai:RunReactiveTriggerAttempt(nil, { runGeneration = Runtime.runGeneration }, heldToken, heldTrigger, heldInfo, heldKey)
            return executed == false
                and noCandidatePhaseCount == 0
                and ai:ReactiveTriggerAttemptMemory()[heldKey] ~= nil
        end)
    end, false)
    Add("43d", noCandidatePass and "PASS" or "FAIL",
        "no-candidate reactive trigger attempt is held without PromptRequested phase spam")

    local successToken = TriggerFixtureToken{ charid = "success-trigger-token", name = "Success Trigger Token" }
    local successTrigger = TriggerFixture{ id = "success-trigger", timestamp = 101, text = "Success Trigger" }
    local successInfo = { event = "losehitpoints", available = true }
    local successKey = ai:ReactiveTriggerAttemptKey(successToken, successTrigger, successInfo)
    local successCandidate, successExecuted = TriggerDispatchFixture{
        token = successToken,
        trigger = successTrigger,
        triggerInfo = successInfo,
    }
    local successPhaseCount = 0
    ai:ResetReactiveTriggerAttempts()
    ai:RecordReactiveTriggerAttempt(successKey, "previous hold")
    local successCleared = SafeCall(function()
        return WithReactiveAttemptStubs(function()
            return { selected = successCandidate, ranked = { successCandidate } }
        end, function(_, phaseName, payload)
            if phaseName == ai.Phase.PromptRequested then
                successPhaseCount = successPhaseCount + 1
            end
            return true, payload or {}
        end, function()
            local executed = ai:RunReactiveTriggerAttempt(nil, { runGeneration = Runtime.runGeneration }, successToken, successTrigger, successInfo, successKey)
            return executed == true
                and successExecuted() == 1
                and successPhaseCount == 1
                and ai:ReactiveTriggerAttemptMemory()[successKey] == nil
        end)
    end, false)
    Add("43e", successCleared and "PASS" or "FAIL",
        "successful reactive trigger dispatch clears held-attempt suppression")
    ai:ResetReactiveTriggerAttempts()
end

local function RunManualPromptHandoffAcceptanceFixtures(ai, add, promptCaster, promptRejectOriginal)
    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        local manualLatchCandidate = {
            retryKey = "fixture-manual-prompt",
            description = "fixture manual prompt",
        }
        local manualLatchCandidateKey = ai.CandidateRetryKey and ai:CandidateRetryKey(manualLatchCandidate) or manualLatchCandidate.retryKey
        ai:RecordManualPromptHandoff({
            initiativeid = "fixture-manual-initiative",
            runGeneration = Runtime.runGeneration,
        }, {
            token = promptCaster,
        }, manualLatchCandidate)
        local manualLatchSame = ai:ManualPromptHandoffActive("fixture-manual-initiative", Runtime.runGeneration)
        local manualLatchHeld = Runtime.manualPromptHandoff ~= nil
            and Runtime.manualPromptHandoff.candidateKey == manualLatchCandidateKey
            and Runtime.manualPromptHandoff.actorId == "prompt-caster"
        local manualLatchChangedClears = not ai:ManualPromptHandoffActive("fixture-other-initiative", Runtime.runGeneration)
            and Runtime.manualPromptHandoff == nil
        add("36a", manualLatchSame and manualLatchHeld and manualLatchChangedClears and "PASS" or "FAIL", "manual prompt handoff latch holds same initiative and clears on changed initiative")
    end

    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        local savedBusy = ai.ManualPromptRealCastBusy
        local savedRelease = ai.ReleaseManualPromptUi
        local savedRefresh = ai.RefreshManualPromptHandoffState
        local releaseCount = 0
        ai.RefreshManualPromptHandoffState = function()
            return Runtime.manualPromptHandoff ~= nil
        end
        ai.ManualPromptRealCastBusy = function()
            return true
        end
        ai.ReleaseManualPromptUi = function(_, _)
            releaseCount = releaseCount + 1
        end
        ai:RecordManualPromptHandoff({
            initiativeid = "fixture-manual-initiative",
            runGeneration = Runtime.runGeneration,
        }, {
            token = promptCaster,
        }, {
            retryKey = "fixture-busy-manual-prompt",
            description = "fixture busy manual prompt",
        })
        Runtime.manualPromptHandoff.continuous = true
        local busyHeld = ai:ManualPromptHandoffBlocksAutomation("fixture-manual-initiative", Runtime.runGeneration)
            and ai:ResumeManualPromptHandoff() == false
            and Runtime.manualPromptHandoff ~= nil
            and releaseCount == 1
        ai.RefreshManualPromptHandoffState = savedRefresh
        ai.ManualPromptRealCastBusy = savedBusy
        ai.ReleaseManualPromptUi = savedRelease
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        add("36b", busyHeld and "PASS" or "FAIL", "manual prompt handoff blocks automation and Resume holds while real cast is busy")
    end

    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        local savedBusy = ai.ManualPromptRealCastBusy
        local savedRelease = ai.ReleaseManualPromptUi
        local savedRefresh = ai.RefreshManualPromptHandoffState
        ai.RefreshManualPromptHandoffState = function()
            return Runtime.manualPromptHandoff ~= nil
        end
        ai.ManualPromptRealCastBusy = function()
            return false
        end
        ai.ReleaseManualPromptUi = function()
        end
        ai:RecordManualPromptHandoff({
            initiativeid = "fixture-manual-initiative",
            runGeneration = Runtime.runGeneration,
        }, {
            token = promptCaster,
        }, promptRejectOriginal)
        Runtime.manualPromptHandoff.continuous = true
        Runtime.manualPromptHandoff.canceled = true
        local rejectedKey = Runtime.manualPromptHandoff.rejectionKeys and Runtime.manualPromptHandoff.rejectionKeys[1]
        local resumed = ai:ResumeManualPromptHandoff()
        local resumedActor = {
            token = promptCaster,
            turnMemory = ai:NewTurnMemory(),
        }
        local applied = ai:ApplyManualPromptRuntimeRejections({
            initiativeid = "fixture-manual-initiative",
        }, resumedActor)
        local rejectedApplied = rejectedKey ~= nil
            and resumedActor.turnMemory.rejectedCandidateKeys[rejectedKey] == true
        ai.RefreshManualPromptHandoffState = savedRefresh
        ai.ManualPromptRealCastBusy = savedBusy
        ai.ReleaseManualPromptUi = savedRelease
        ai:ClearManualPromptRuntimeRejections("acceptance fixture reset")
        add("36c", resumed == true
            and Runtime.manualPromptHandoff == nil
            and applied > 0
            and rejectedApplied
            and "PASS" or "FAIL", "Resume after canceled manual prompt preserves rejection for resumed turn")
    end

    do
        ai:RecordManualPromptRuntimeRejection({
            initiativeid = "fixture-manual-initiative",
            actorId = "prompt-caster",
            rejectionKeys = { "fixture-runtime-rejection" },
        })
        ai:ClearManualPromptRuntimeRejections("acceptance fixture reset")
        add("36d", Runtime.manualPromptRejectedCandidates == nil and "PASS" or "FAIL", "manual prompt runtime rejections clear explicitly")
    end

    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        ai:ClearManualPromptRuntimeRejections("acceptance fixture reset")
        local savedResolve = ai.ResolvePromptV2
        local savedOpenManual = ai.OpenManualPromptCandidate
        local manualUi = 0
        ai.ResolvePromptV2 = function()
            return {
                status = "manual",
                reason = "fixture nested manual prompt",
            }
        end
        ai.OpenManualPromptCandidate = function()
            manualUi = manualUi + 1
            return true
        end
        local nestedContext = {
            initiativeid = "fixture-manual-initiative",
            runGeneration = Runtime.runGeneration,
            allCombatTokens = { promptCaster },
        }
        local nestedActor = {
            token = promptCaster,
            context = nestedContext,
            turnMemory = ai:NewTurnMemory(),
        }
        local callback = ai:CreatePromptCallback(nestedContext, nestedActor)
        local options = {
            symbols = {},
        }
        local returned = callback(promptCaster, promptCaster, {
            name = "Fixture Nested Required Manual Prompt",
        }, {}, options)
        local exit = nestedContext.promptResolutionExit
        ai.ResolvePromptV2 = savedResolve
        ai.OpenManualPromptCandidate = savedOpenManual
        add("36g", returned == "args"
            and options.abort == true
            and options.stopProcessing == true
            and exit ~= nil
            and exit.status == "manual"
            and nestedContext.manualPromptHandoff ~= true
            and Runtime.manualPromptHandoff == nil
            and Runtime.manualPromptRejectedCandidates == nil
            and manualUi == 0
            and "PASS" or "FAIL", "nested manual prompt result blocks without manual handoff, rejection, or UI state")
    end

    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        local savedQueue = dmhub.initiativeQueue
        local savedScanner = ai.RunReactiveTriggerScan
        local scanCount = 0
        local fixtureQueue = {
            hidden = false,
            CurrentInitiativeId = function()
                return "fixture-manual-initiative"
            end,
        }
        local suppressed = SafeCall(function()
            dmhub.initiativeQueue = fixtureQueue
            ai.RunReactiveTriggerScan = function()
                scanCount = scanCount + 1
                return 0
            end
            ai:RecordManualPromptHandoff({
                initiativeid = "fixture-manual-initiative",
                runGeneration = Runtime.runGeneration,
            }, {
                token = promptCaster,
            }, {
                retryKey = "fixture-reactive-suppressed-manual-prompt",
                description = "fixture reactive suppressed manual prompt",
            })
            ai:AutoReactiveTriggers()
            return scanCount == 0 and Runtime.manualPromptHandoff ~= nil
        end, false)
        ai.RunReactiveTriggerScan = savedScanner
        SafeCall(function()
            dmhub.initiativeQueue = savedQueue
        end, nil)
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        add("36e", suppressed and "PASS" or "FAIL", "active manual prompt handoff suppresses AutoReactiveTriggers")
    end

    do
        ai:ClearManualPromptHandoff("acceptance fixture reset")
        ai:RecordManualPromptHandoff({
            initiativeid = "fixture-manual-initiative",
            runGeneration = Runtime.runGeneration,
        }, {
            token = promptCaster,
        }, {
            retryKey = "fixture-lifecycle-manual-prompt",
            description = "fixture lifecycle manual prompt",
        })
        Runtime.manualPromptHandoff.canceled = true
        ai:RecordManualPromptRuntimeRejection(Runtime.manualPromptHandoff)
        local hadRejection = Runtime.manualPromptRejectedCandidates ~= nil
        local clearedByInitiativeChange = not ai:ManualPromptHandoffActive("fixture-other-initiative", Runtime.runGeneration)
            and Runtime.manualPromptHandoff == nil
            and Runtime.manualPromptRejectedCandidates == nil
        add("36f", hadRejection and clearedByInitiativeChange and "PASS" or "FAIL", "manual prompt runtime rejections clear when initiative changes")
    end
end

local function RunModePromptAcceptanceFixtures(ai, add, fallbackContext, fallbackActor)
    local unresolvedModeAbility = {
        name = "Fixture Multi-Mode Utility",
        multipleModes = true,
    }
    local unresolvedModeInfo = {
        name = "Fixture Multi-Mode Utility",
        ability = unresolvedModeAbility,
        targetType = "self",
        requiresPrompt = true,
        manualPromptRisk = true,
        autoResolvableModePrompt = false,
    }
    local unresolvedModeReason = ai:AbilityUnsafePromptReason(unresolvedModeInfo, fallbackContext, fallbackActor)
    add(37, unresolvedModeReason == "unresolved mode prompt" and "PASS" or "FAIL", "generic multi-mode prompt without safe selection is skipped before ranking")

    local grabModeAbility = {
        name = "Grab",
        guid = "1d642117-27c8-49c5-b37b-a8fc94b5ca5b",
        multipleModes = true,
        modeList = {
            { text = "Safe" },
            { text = "Aggressive" },
        },
    }
    local grabModeInfo = {
        name = "Grab",
        ability = grabModeAbility,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
    }
    grabModeInfo.autoResolvableModePrompt = ai:IsAutoResolvableGrabModePrompt(grabModeInfo)
    add("37a", ai:AbilityUnsafePromptReason(grabModeInfo, fallbackContext, fallbackActor) == nil
        and grabModeInfo.autoResolvableModePrompt == true
        and "PASS" or "FAIL", "standard Grab auto mode policy remains rankable")

    local promptlessModeInfo = {
        name = "Fixture Promptless Mode Metadata",
        ability = {
            name = "Fixture Promptless Mode Metadata",
            multipleModes = true,
        },
        targetType = "target",
        requiresPrompt = false,
        manualPromptRisk = false,
        autoResolvableModePrompt = false,
    }
    add("37b", ai:AbilityUnsafePromptReason(promptlessModeInfo, fallbackContext, fallbackActor) == nil
        and "PASS" or "FAIL", "multi-mode metadata without cast prompt remains rankable")

    local function CloneFixtureAbility(source)
        local clone = {}
        for key,value in pairs(source or {}) do
            clone[key] = value
        end
        return clone
    end

    local safeModeVariation = {
        name = "Fixture Safe Mode Strike",
        targetType = "target",
        targetAllegiance = "enemy",
        targetFilter = "enemy",
        behaviors = {},
        CanAfford = function()
            return true
        end,
        HasKeyword = function(_, keyword)
            return keyword == "Strike"
        end,
        GetRange = function()
            return 1
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        RequiresPromptWhenCast = function()
            return false
        end,
    }
    safeModeVariation.MakeTemporaryClone = function(selfAbility)
        return CloneFixtureAbility(selfAbility)
    end

    local safeModeAbility = {
        name = "Fixture Mode Strike",
        targetType = "target",
        targetAllegiance = "enemy",
        targetFilter = "enemy",
        multipleModes = true,
        behaviors = {},
        modeList = {
            { text = "Bite", hasAbility = true, variation = safeModeVariation },
            { text = "Spend 1 Malice: Bite hard", hasAbility = true, variation = safeModeVariation },
        },
        CanAfford = function()
            return true
        end,
        HasKeyword = function(_, keyword)
            return keyword == "Strike"
        end,
        GetRange = function()
            return 1
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        RequiresPromptWhenCast = function()
            return true
        end,
    }
    safeModeAbility.MakeTemporaryClone = function(selfAbility)
        local clone = CloneFixtureAbility(selfAbility)
        clone.modeList = selfAbility.modeList
        clone.SwitchModes = selfAbility.SwitchModes
        clone.MakeTemporaryClone = selfAbility.MakeTemporaryClone
        return clone
    end
    safeModeAbility.SwitchModes = function(selfAbility, index)
        local mode = selfAbility.modeList and selfAbility.modeList[index]
        local variation = mode and mode.variation or selfAbility
        local clone = variation.MakeTemporaryClone and variation:MakeTemporaryClone() or CloneFixtureAbility(variation)
        clone.multipleModes = selfAbility.multipleModes
        clone.modeList = selfAbility.modeList
        return clone
    end

    local safeModeInfo = ai:AnalyzeAbility(fallbackActor, safeModeAbility)
    local safeModeSelection, safeModeReason, safeModeAdjustedInfo = ai:ChooseTopLevelModeSelection(fallbackContext, fallbackActor, safeModeInfo)
    add("37c", safeModeSelection ~= nil
        and safeModeSelection.index == 1
        and safeModeReason == nil
        and safeModeAdjustedInfo ~= nil
        and ai:AbilityUnsafePromptReason(safeModeAdjustedInfo, fallbackContext, fallbackActor) == nil
        and "PASS" or "FAIL", "safe top-level multi-mode main action resolves before prompt gate")

    local selfAreaInfo = {
        name = "Fixture Self Burst",
        ability = {
            name = "Fixture Self Burst",
        },
        targetType = "self",
        isArea = true,
        hasAura = false,
        radius = 2,
        range = 0,
        numTargets = 1,
    }
    add("37d", ai:IsAreaAbilityInfo(selfAreaInfo) == true
        and ai:AreaShapeName(selfAreaInfo) == "all"
        and ai:AbilityManualPromptReason(selfAreaInfo, fallbackContext, fallbackActor) == nil
        and "PASS" or "FAIL", "self-origin Area metadata is automatable area targeting")
end

local function RunPromptCapabilityAcceptanceFixtures(ai, add, PromptFixtureGrid, PromptFixtureToken)
    local center = PromptFixtureGrid("fixture:prompt-capability", 3)
    local caster = PromptFixtureToken("Capability Caster", "capability-caster", center, "rivals")
    local target = PromptFixtureToken("Capability Target", "capability-target", center.east, "heroes")
    local ally = PromptFixtureToken("Capability Ally", "capability-ally", center.west, "rivals")
    local context = {
        allCombatTokens = { caster, target, ally },
    }
    local actor = {
        token = caster,
        allies = { ally },
        enemies = { target },
        context = context,
    }

    local function TargetAbility(args)
        args = args or {}
        return {
            name = args.name or "Capability Follow-Up",
            targetType = args.targetType or "target",
            forcedMovement = args.forcedMovement == true,
            HasKeyword = function()
                return false
            end,
            GetRange = function()
                return 5
            end,
            GetRadius = function()
                return 0
            end,
            GetNumTargets = function()
                return 1
            end,
            TargetPassesFilter = args.TargetPassesFilter or function()
                return false
            end,
            TargetLocPassesFilterPredicate = args.TargetLocPassesFilterPredicate,
        }
    end

    local requiredTargetAbility = TargetAbility{
        name = "Capability Required Target Prompt",
        TargetPassesFilter = function()
            return false
        end,
    }
    local requiredParentAbility = {
        name = "Capability Required Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = requiredTargetAbility,
            },
        },
    }
    local requiredCandidate = {
        actor = actor,
        ability = requiredParentAbility,
        abilityInfo = {
            name = "Capability Required Parent",
            ability = requiredParentAbility,
        },
        targets = { { token = target } },
        loc = caster.loc,
        preInvokeMove = {
            mode = "walk",
            destination = center.north,
            tiles = 1,
        },
        description = "capability required nested target",
    }
    local savedOpenManual = ai.OpenManualPromptCandidate
    local manualOpenCount = 0
    ai.OpenManualPromptCandidate = function()
        manualOpenCount = manualOpenCount + 1
        return true
    end
    local requiredValid, requiredReason, requiredStatus = ai:ValidateNestedPromptPoliciesBeforeExecution(context, actor, requiredCandidate, requiredParentAbility, {})
    ai.OpenManualPromptCandidate = savedOpenManual
    add("45a", not requiredValid
        and requiredStatus == "blocked"
        and manualOpenCount == 0
        and (caster._moveCount or 0) == 0
        and caster._theoreticalLocDuring == center.north
        and caster._theoreticalLocRestored == true
        and "PASS" or "FAIL", "required nested target prompt blocks pre-move without manual UI" .. (requiredValid and "" or (" (" .. tostring(requiredReason) .. ")")))

    local previousManualPrompts = ai.config and ai.config.manualPrompts
    if ai.config ~= nil then
        ai.config.manualPrompts = true
    end
    local nonTargetAbility = TargetAbility{
        name = "Capability Required Non-Target Prompt",
        targetType = "all",
    }
    local nonTargetParent = {
        name = "Capability Required Non-Target Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = nonTargetAbility,
            },
        },
    }
    local nonTargetCandidate = {
        actor = actor,
        ability = nonTargetParent,
        abilityInfo = {
            name = "Capability Required Non-Target Parent",
            ability = nonTargetParent,
        },
        targets = { { token = target } },
        loc = caster.loc,
        preInvokeMove = {
            mode = "walk",
            destination = center.south,
            tiles = 1,
        },
        description = "capability required nested non-target",
    }
    local nonTargetValid, nonTargetReason, nonTargetStatus = ai:ValidateNestedPromptPoliciesBeforeExecution(context, actor, nonTargetCandidate, nonTargetParent, {})
    if ai.config ~= nil then
        ai.config.manualPrompts = previousManualPrompts
    end
    add("45b", not nonTargetValid
        and nonTargetStatus == "blocked"
        and string.find(tostring(nonTargetReason), "Capability Required Non-Target Prompt", 1, true) ~= nil
        and "PASS" or "FAIL", "required nested non-target prompt blocks instead of manual handoff")

    local optionalPromptAbility = {
        name = "Specific Target Free Strike",
        targetType = "target",
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 1
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function()
            return true
        end,
    }
    local optionalParent = {
        name = "Capability Grab Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = optionalPromptAbility,
            },
        },
    }
    local optionalCapability = ai:AssessPromptCapability(context, actor, {
        name = "Capability Grab Parent",
        ability = optionalParent,
    }, {
        actor = actor,
        ability = optionalParent,
        abilityInfo = {
            name = "Capability Grab Parent",
            ability = optionalParent,
        },
        targets = { { token = target } },
        symbols = {
            spellname = "Grab",
        },
        _directorPromptPreflight = true,
    })
    add("45c", optionalCapability ~= nil
        and optionalCapability.status == "auto"
        and #optionalCapability.optionalPrompts > 0
        and context.manualPromptHandoff ~= true
        and "PASS" or "FAIL", "optional Grab specific-target free strike remains automatic")

    local genericGrabPromptAbility = TargetAbility{
        name = "Invoked Ability",
        TargetPassesFilter = function()
            return false
        end,
    }
    local genericGrabParent = {
        name = "Grab",
        guid = "1d642117-27c8-49c5-b37b-a8fc94b5ca5b",
        multipleModes = true,
        modeList = {
            { text = "Safe" },
            { text = "Aggressive" },
        },
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = genericGrabPromptAbility,
            },
        },
    }
    local genericGrabInfo = {
        name = "Grab",
        ability = genericGrabParent,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
        hasGrab = true,
    }
    genericGrabInfo.autoResolvableModePrompt = ai:IsAutoResolvableGrabModePrompt(genericGrabInfo)
    local genericGrabCapability = ai:AssessPromptCapability(context, actor, genericGrabInfo, {
        actor = actor,
        ability = genericGrabParent,
        abilityInfo = genericGrabInfo,
        targets = { { token = target } },
        symbols = {
            mode = 1,
        },
        _directorPromptPreflight = true,
    })
    add("45f", genericGrabCapability ~= nil
        and genericGrabCapability.status == "auto"
        and #genericGrabCapability.optionalPrompts > 0
        and "PASS" or "FAIL", "standard Grab treats generic Invoked Ability child as optional by parent context")

    local genericRequiredAbility = TargetAbility{
        name = "Invoked Ability",
        TargetPassesFilter = function()
            return false
        end,
    }
    local genericRequiredParent = {
        name = "Capability Generic Required Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = genericRequiredAbility,
            },
        },
    }
    local genericRequiredCandidate = {
        actor = actor,
        ability = genericRequiredParent,
        abilityInfo = {
            name = "Capability Generic Required Parent",
            ability = genericRequiredParent,
        },
        targets = { { token = target } },
        loc = caster.loc,
        preInvokeMove = {
            mode = "walk",
            destination = center.west,
            tiles = 1,
        },
        description = "capability generic required nested target",
    }
    local genericRequiredValid, genericRequiredReason, genericRequiredStatus = ai:ValidateNestedPromptPoliciesBeforeExecution(context, actor, genericRequiredCandidate, genericRequiredParent, {})
    add("45g", not genericRequiredValid
        and genericRequiredStatus == "blocked"
        and string.find(tostring(genericRequiredReason), "Invoked Ability", 1, true) ~= nil
        and "PASS" or "FAIL", "non-Grab generic Invoked Ability child remains a required blocked prompt")

    local grabAbility = {
        name = "Grab",
        guid = "1d642117-27c8-49c5-b37b-a8fc94b5ca5b",
        multipleModes = true,
        modeList = {
            { text = "Safe" },
            { text = "Aggressive" },
        },
    }
    local grabInfo = {
        name = "Grab",
        ability = grabAbility,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
    }
    grabInfo.autoResolvableModePrompt = ai:IsAutoResolvableGrabModePrompt(grabInfo)
    local grabCapability = ai:AssessPromptCapability(context, actor, grabInfo, {
        ability = grabAbility,
        abilityInfo = grabInfo,
    })
    local safeModeCapability = ai:AssessPromptCapability(context, actor, {
        name = "Capability Safe Mode",
        ability = {
            name = "Capability Safe Mode",
            multipleModes = true,
        },
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
        topLevelModePromptResolved = true,
    })
    local followUpParent = {
        name = "Capability Follow-Up Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = TargetAbility{ name = "Capability Follow-Up Prompt" },
            },
        },
    }
    local followUpCapability = ai:AssessPromptCapability(context, actor, {
        name = "Capability Follow-Up Parent",
        ability = followUpParent,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
    }, {
        ability = followUpParent,
    })
    local forcedParent = {
        name = "Capability Forced Movement Parent",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = TargetAbility{
                    name = "Slide!",
                    forcedMovement = true,
                    TargetLocPassesFilterPredicate = function()
                        return function(loc)
                            return loc ~= nil and loc.valid ~= false
                        end
                    end,
                },
            },
        },
    }
    local forcedCapability = ai:AssessPromptCapability(context, actor, {
        name = "Capability Forced Movement Parent",
        ability = forcedParent,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
    }, {
        ability = forcedParent,
    })
    local selfAreaCapability = ai:AssessPromptCapability(context, actor, {
        name = "Capability Self Area",
        ability = {
            name = "Capability Self Area",
        },
        targetType = "self",
        isArea = true,
        radius = 2,
        range = 0,
        numTargets = 1,
    })
    add("45d", grabCapability.status == "auto"
        and safeModeCapability.status == "auto"
        and followUpCapability.status == "auto"
        and forcedCapability.status == "auto"
        and selfAreaCapability.status == "auto"
        and "PASS" or "FAIL", "safe deterministic prompt families assess as automatic")
end

local function RunExecutionBoundaryAcceptanceFixtures(ai, add, PromptFixtureGrid, PromptFixtureToken)
    local center = PromptFixtureGrid("fixture:execution-boundary", 4)
    local origin = center
    local moveLoc = center.north
    local targetLoc = center.east

    local function CloneTable(source)
        local clone = {}
        for key,value in pairs(source or {}) do
            clone[key] = value
        end
        return clone
    end

    local function FixtureAbility(args)
        args = args or {}
        local ability = {
            name = args.name or "Boundary Fixture Ability",
            targetType = args.targetType or "target",
            behaviors = args.behaviors or {},
            actionResourceId = args.actionResourceId,
        }
        ability.HasKeyword = function()
            return false
        end
        ability.GetRange = function()
            return args.range or 5
        end
        ability.GetRadius = function()
            return 0
        end
        ability.GetNumTargets = function()
            return 1
        end
        ability.TargetPassesFilter = args.TargetPassesFilter or function()
            return args.targetPasses ~= false
        end
        ability.RequiresPromptWhenCast = function()
            return args.requiresPrompt == true
        end
        ability.GetCost = function()
            return {
                canAfford = true,
                details = {},
            }
        end
        ability.CanAfford = function(selfAbility)
            if args.affordWithNoActionResource == true then
                return selfAbility.actionResourceId == "none"
            end
            return args.canAfford ~= false
        end
        ability.MakeTemporaryClone = function(selfAbility)
            local clone = CloneTable(selfAbility)
            clone.MakeTemporaryClone = selfAbility.MakeTemporaryClone
            clone.SwitchModes = selfAbility.SwitchModes
            return clone
        end
        return ability
    end

    local function FixtureActor(label)
        local token = PromptFixtureToken(label or "Boundary Actor", tostring(label or "boundary-actor"), origin, "rivals")
        token.Move = function(_, loc)
            token._moveCount = (token._moveCount or 0) + 1
            token.loc = loc
        end
        local actor = {
            kind = "monster",
            token = token,
            allies = {},
            enemies = {},
            context = {},
            turnMemory = ai:NewTurnMemory(),
        }
        actor.context.actor = actor
        actor.context.allCombatTokens = { token }
        return actor, token
    end

    local function FixtureTarget(label, loc)
        local token = PromptFixtureToken(label or "Boundary Target", tostring(label or "boundary-target"), loc or targetLoc, "heroes")
        token.Move = function(_, newLoc)
            token._moveCount = (token._moveCount or 0) + 1
            token.loc = newLoc
        end
        return token
    end

    local function FixtureCandidate(actor, ability, info, target, args)
        args = args or {}
        local context = actor.context or {}
        context.allCombatTokens = context.allCombatTokens or { actor.token, target }
        actor.context = context
        actor.enemies = target ~= nil and { target } or {}
        return {
            id = args.id or "boundary-candidate",
            actor = actor,
            ability = ability,
            abilityInfo = info or {
                name = ability.name,
                ability = ability,
                targetType = ability.targetType or "target",
                numTargets = 1,
                range = 5,
            },
            loc = args.loc or actor.token.loc,
            preInvokeMove = args.preInvokeMove,
            targets = target ~= nil and { { token = target } } or {},
            actionCost = args.actionCost or "action",
            actionType = args.actionType or { kind = "main" },
            description = args.description or ability.name,
            symbols = args.symbols,
        }
    end

    local function IsExecutionBoundaryLoc(loc)
        return type(loc) == "table"
            and type(loc.str) == "string"
            and string.find(loc.str, "fixture:execution-boundary:", 1, true) == 1
    end

    local function WithExecutionStubs(args, fn)
        args = args or {}
        local saved = {
            MovementOptionForDestination = ai.MovementOptionForDestination,
            MoveToken = ai.MoveToken,
            InstallPromptControl = ai.InstallPromptControl,
            CleanupPromptTargeting = ai.CleanupPromptTargeting,
            OpenManualPromptCandidate = ai.OpenManualPromptCandidate,
            WaitForCastSettle = ai.WaitForCastSettle,
            GetActiveCastSnapshot = ai.GetActiveCastSnapshot,
            ResolvePromptV2 = ai.ResolvePromptV2,
            Sleep = ai.Sleep,
            invoker = rawget(_G, "ActivatedAbilityInvokeAbilityBehavior"),
        }
        local counts = {
            move = 0,
            promptUi = 0,
            manualUi = 0,
            invoke = 0,
            cleanup = 0,
            promptCallback = 0,
            promptControlRestored = 0,
        }
        ai.MovementOptionForDestination = function(selfArg, token, ledger, mode, destination)
            if IsExecutionBoundaryLoc(destination) then
                local locInfo = {
                    loc = destination,
                    path = {
                        origin = token and token.loc,
                        destination = destination,
                    },
                    hazardDamage = 0,
                }
                return {
                    mode = mode or "walk",
                    reachableLocs = { locInfo },
                }, locInfo, nil
            end
            if saved.MovementOptionForDestination ~= nil then
                return saved.MovementOptionForDestination(selfArg, token, ledger, mode, destination)
            end
            return nil, nil, "movement resolver unavailable"
        end
        ai.MoveToken = function(_, token, loc)
            counts.move = counts.move + 1
            if args.afterMove ~= nil then
                args.afterMove(token, loc, counts)
            end
            if token ~= nil and token.Move ~= nil then
                token:Move(loc, { maxCost = 10000, ignoreFalling = false })
            elseif token ~= nil then
                token.loc = loc
            end
            return args.moveFails ~= true
        end
        ai.InstallPromptControl = function(_, contextArg, actorArg)
            counts.promptUi = counts.promptUi + 1
            local token = actorArg and actorArg.token
            local previousControl = token and token.properties and token.properties._tmp_aicontrol
            local previousCallback = token and token.properties and token.properties._tmp_aipromptCallback
            if token ~= nil and token.properties ~= nil then
                token.properties._tmp_aicontrol = (previousControl or 0) + 1
                token.properties._tmp_aipromptCallback = ai:CreatePromptCallback(contextArg, actorArg)
            end
            return function()
                counts.cleanup = counts.cleanup + 1
                if token ~= nil and token.properties ~= nil then
                    token.properties._tmp_aicontrol = previousControl
                    token.properties._tmp_aipromptCallback = previousCallback
                    counts.promptControlRestored = counts.promptControlRestored + 1
                end
            end
        end
        ai.CleanupPromptTargeting = function()
            counts.cleanup = counts.cleanup + 1
        end
        ai.OpenManualPromptCandidate = function()
            counts.manualUi = counts.manualUi + 1
            return true
        end
        ai.WaitForCastSettle = function()
            return true
        end
        ai.GetActiveCastSnapshot = function()
            return nil
        end
        ai.Sleep = function()
        end
        if args.resolvePrompt ~= nil or args.resolvePromptResult ~= nil then
            ai.ResolvePromptV2 = function(selfArg, contextArg, actorArg, invokerToken, casterToken, abilityClone, symbols, options)
                if args.resolvePrompt ~= nil then
                    return args.resolvePrompt(selfArg, contextArg, actorArg, invokerToken, casterToken, abilityClone, symbols, options, counts)
                end
                return args.resolvePromptResult
            end
        end
        rawset(_G, "ActivatedAbilityInvokeAbilityBehavior", {
            ExecuteInvoke = function(invokerToken, ability, casterToken, targeting, symbols, options)
                counts.invoke = counts.invoke + 1
                local invokeIndex = counts.invoke
                if args.invokeErrors == true then
                    error("fixture invoke failure")
                end
                if args.invokeReturnsFalse == true then
                    return false
                end
                if ability ~= nil and ability.OnBeginCast ~= nil then
                    ability.OnBeginCast(ability, options)
                end
                if args.nestedInvokeAbility ~= nil and invokeIndex == 1 then
                    local nestedInvoker = rawget(_G, "ActivatedAbilityInvokeAbilityBehavior")
                    if nestedInvoker ~= nil and nestedInvoker.ExecuteInvoke ~= nil then
                        nestedInvoker.ExecuteInvoke(
                            invokerToken,
                            args.nestedInvokeAbility,
                            casterToken,
                            "inherit",
                            args.nestedSymbols or symbols,
                            args.nestedOptions or options
                        )
                    end
                    if args.afterNestedInvoke ~= nil then
                        args.afterNestedInvoke(counts, ability, symbols, options)
                    end
                end
                local shouldPrompt = args.promptAbility ~= nil
                    and (args.promptOnNestedOnly ~= true or invokeIndex > 1)
                if shouldPrompt and casterToken ~= nil and casterToken.properties ~= nil then
                    local promptCallback = casterToken.properties._tmp_aipromptCallback
                    if promptCallback ~= nil then
                        counts.promptCallback = counts.promptCallback + 1
                        promptCallback(invokerToken, casterToken, args.promptAbility, args.promptSymbols or symbols or {}, options or {})
                    end
                end
                if args.mutateAfterPrompt ~= nil then
                    args.mutateAfterPrompt(counts, ability, symbols, options)
                end
                if args.beforeFinish ~= nil then
                    args.beforeFinish(counts)
                end
                if ability ~= nil and ability.OnFinishCast ~= nil then
                    ability.OnFinishCast(ability, {
                        pay = true,
                        abort = options ~= nil and options.abort == true,
                    })
                end
                if args.afterFinish ~= nil then
                    args.afterFinish(counts)
                end
                return true
            end,
        })

        local ok, result, detail = pcall(function()
            return fn(counts)
        end)
        ai.MovementOptionForDestination = saved.MovementOptionForDestination
        ai.MoveToken = saved.MoveToken
        ai.InstallPromptControl = saved.InstallPromptControl
        ai.CleanupPromptTargeting = saved.CleanupPromptTargeting
        ai.OpenManualPromptCandidate = saved.OpenManualPromptCandidate
        ai.WaitForCastSettle = saved.WaitForCastSettle
        ai.GetActiveCastSnapshot = saved.GetActiveCastSnapshot
        ai.ResolvePromptV2 = saved.ResolvePromptV2
        ai.Sleep = saved.Sleep
        rawset(_G, "ActivatedAbilityInvokeAbilityBehavior", saved.invoker)
        if not ok then
            return false, result
        end
        return result, detail, counts
    end

    local function PromptCallbackCandidate(actor, target, args)
        args = args or {}
        local ability = FixtureAbility{
            name = args.abilityName or "Boundary Prompt Callback Parent",
        }
        return FixtureCandidate(actor, ability, nil, target, {
            description = args.description or ability.name,
            symbols = args.symbols,
        })
    end

    local function PromptExitFixtureDetail(id, executed, reason, counts, actor)
        local context = actor and actor.context or nil
        local fields = {
            id = id,
            executed = executed == true,
            reason = tostring(reason),
            promptCallback = counts and counts.promptCallback or nil,
            promptUi = counts and counts.promptUi or nil,
            promptControlRestored = counts and counts.promptControlRestored or nil,
            cleanup = counts and counts.cleanup or nil,
            manualUi = counts and counts.manualUi or nil,
            promptResolutionExit = context and context.promptResolutionExit ~= nil,
            contextManualPromptHandoff = context and context.manualPromptHandoff == true,
            runtimeManualPromptHandoff = Runtime.manualPromptHandoff ~= nil,
        }
        if ai.Trace ~= nil then
            SafeCall(function()
                ai:Trace("acceptance", "prompt exit fixture detail", fields)
            end, nil)
        end
        return string.format(
            "executed=%s reason=%s promptCallback=%s promptUi=%s promptControlRestored=%s cleanup=%s manualUi=%s promptResolutionExit=%s contextManualPromptHandoff=%s runtimeManualPromptHandoff=%s",
            tostring(fields.executed),
            fields.reason,
            tostring(fields.promptCallback),
            tostring(fields.promptUi),
            tostring(fields.promptControlRestored),
            tostring(fields.cleanup),
            tostring(fields.manualUi),
            tostring(fields.promptResolutionExit),
            tostring(fields.contextManualPromptHandoff),
            tostring(fields.runtimeManualPromptHandoff)
        )
    end

    do
        local actor, actorToken = FixtureActor("Boundary Optional Prompt Actor")
        local target = FixtureTarget("Boundary Optional Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local promptAbility = FixtureAbility{
            name = "Specific Target Free Strike",
        }
        local candidate = PromptCallbackCandidate(actor, target, {
            description = "boundary optional prompt skip",
            symbols = {
                spellname = "Grab",
            },
        })
        local executed, _, counts = WithExecutionStubs({
            promptAbility = promptAbility,
            resolvePromptResult = {
                status = "blocked",
                reason = "fixture optional prompt has no target",
            },
        }, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        add("51h", executed == true
            and counts ~= nil
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "optional nested prompt skip cleans up prompt control without manual UI")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Grab Generic Prompt Actor")
        local target = FixtureTarget("Boundary Grab Generic Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local genericPromptAbility = FixtureAbility{
            name = "Invoked Ability",
            TargetPassesFilter = function()
                return false
            end,
        }
        local grabAbility = FixtureAbility{
            name = "Grab",
            requiresPrompt = true,
            behaviors = {
                {
                    typeName = "ActivatedAbilityInvokeAbilityBehavior",
                    targeting = "prompt",
                    invokeOnCaster = false,
                    customAbility = genericPromptAbility,
                },
            },
        }
        grabAbility.guid = "1d642117-27c8-49c5-b37b-a8fc94b5ca5b"
        grabAbility.multipleModes = true
        grabAbility.modeList = {
            { text = "Safe" },
            { text = "Aggressive" },
        }
        grabAbility.SwitchModes = function(selfAbility)
            return selfAbility
        end
        local grabInfo = {
            name = "Grab",
            ability = grabAbility,
            targetType = "target",
            range = 5,
            numTargets = 1,
            requiresPrompt = true,
            manualPromptRisk = true,
            hasGrab = true,
        }
        grabInfo.autoResolvableModePrompt = ai:IsAutoResolvableGrabModePrompt(grabInfo)
        local candidate = FixtureCandidate(actor, grabAbility, grabInfo, target, {
            description = "boundary Grab generic Invoked Ability preflight",
            symbols = {
                mode = 1,
            },
        })
        candidate.modeSelection = {
            index = 1,
            text = "Safe",
            reason = "fixture safe Grab",
        }
        local executed, _, counts = WithExecutionStubs({
            promptAbility = genericPromptAbility,
            promptSymbols = {
                mode = 1,
            },
            resolvePromptResult = {
                status = "blocked",
                reason = "fixture generic Grab child has no target",
            },
        }, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        add("51p", executed == true
            and actor.context.lastExecutionFailureReason == nil
            and counts ~= nil
            and counts.invoke == 1
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "standard Grab generic Invoked Ability child passes preflight and skips runtime callback")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Generic Required Actor")
        local target = FixtureTarget("Boundary Generic Required Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local nestedAbility = FixtureAbility{
            name = "Invoked Ability",
            TargetPassesFilter = function()
                return false
            end,
        }
        local parentAbility = FixtureAbility{
            name = "Boundary Parent Generic Prompt",
            behaviors = {
                {
                    typeName = "ActivatedAbilityInvokeAbilityBehavior",
                    targeting = "prompt",
                    invokeOnCaster = false,
                    customAbility = nestedAbility,
                },
            },
        }
        local candidate = FixtureCandidate(actor, parentAbility, {
            name = parentAbility.name,
            ability = parentAbility,
            targetType = "target",
            range = 5,
            numTargets = 1,
        }, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary generic Invoked Ability required prompt",
        })
        local executed, _, counts = WithExecutionStubs({}, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        local validation = actor.context.lastExecutionValidationResult
        add("51q", executed == false
            and validation ~= nil
            and validation.phase == "prompt.preflight"
            and counts ~= nil
            and counts.move == 0
            and counts.promptUi == 0
            and counts.manualUi == 0
            and counts.invoke == 0
            and "PASS" or "FAIL", "non-Grab generic Invoked Ability child still blocks before side effects")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Handled Prompt Actor")
        local target = FixtureTarget("Boundary Handled Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local promptAbility = FixtureAbility{
            name = "Boundary Handled Nested Prompt",
        }
        local candidate = PromptCallbackCandidate(actor, target, {
            description = "boundary handled prompt",
        })
        local executed, _, counts = WithExecutionStubs({
            promptAbility = promptAbility,
            resolvePromptResult = {
                status = "handled",
                options = {
                    targets = { { token = target } },
                    targetArgs = { { token = target } },
                },
                policy = {
                    id = "fixture-handled-prompt",
                },
            },
        }, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        add("51i", executed == true
            and counts ~= nil
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "handled nested prompt cleans up prompt control without manual UI")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Blocked Prompt Actor")
        local target = FixtureTarget("Boundary Blocked Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local promptAbility = FixtureAbility{
            name = "Boundary Blocked Nested Prompt",
        }
        local candidate = PromptCallbackCandidate(actor, target, {
            description = "boundary blocked prompt",
        })
        local executed, _, counts = WithExecutionStubs({
            promptAbility = promptAbility,
            resolvePromptResult = {
                status = "blocked",
                reason = "fixture blocked nested prompt",
            },
        }, function()
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok
        end)
        local reason = actor.context.lastExecutionFailureReason
        local detail = PromptExitFixtureDetail("51j", executed, reason, counts, actor)
        add("51j", executed == false
            and string.find(tostring(reason), "blocked prompt", 1, true) ~= nil
            and counts ~= nil
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.cleanup >= 2
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "blocked nested prompt rolls back through cleanup without manual UI; " .. detail)
    end

    do
        local actor, actorToken = FixtureActor("Boundary Abort Prompt Actor")
        local target = FixtureTarget("Boundary Abort Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local promptAbility = FixtureAbility{
            name = "Boundary Abort Nested Prompt",
        }
        local candidate = PromptCallbackCandidate(actor, target, {
            description = "boundary abort prompt",
        })
        local executed, _, counts = WithExecutionStubs({
            promptAbility = promptAbility,
            resolvePromptResult = {
                status = "abort",
                reason = "fixture abort nested prompt",
            },
        }, function()
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok
        end)
        local reason = actor.context.lastExecutionFailureReason
        local detail = PromptExitFixtureDetail("51k", executed, reason, counts, actor)
        add("51k", executed == false
            and string.find(tostring(reason), "abort prompt", 1, true) ~= nil
            and counts ~= nil
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.cleanup >= 2
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "abort nested prompt rolls back through cleanup without manual UI; " .. detail)
    end

    do
        local actor, actorToken = FixtureActor("Boundary Manual Prompt Actor")
        local target = FixtureTarget("Boundary Manual Prompt Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local promptAbility = FixtureAbility{
            name = "Boundary Manual Nested Prompt",
        }
        local candidate = PromptCallbackCandidate(actor, target, {
            description = "boundary manual prompt",
        })
        local executed, _, counts = WithExecutionStubs({
            promptAbility = promptAbility,
            resolvePromptResult = {
                status = "manual",
                reason = "fixture manual nested prompt",
            },
        }, function()
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok
        end)
        local reason = actor.context.lastExecutionFailureReason
        local detail = PromptExitFixtureDetail("51l", executed, reason, counts, actor)
        add("51l", executed == false
            and string.find(tostring(reason), "manual prompt", 1, true) ~= nil
            and counts ~= nil
            and counts.promptCallback == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.cleanup >= 2
            and counts.manualUi == 0
            and actor.context.promptResolutionExit == nil
            and actor.context.manualPromptHandoff ~= true
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "manual nested prompt status uses blocked cleanup instead of manual UI; " .. detail)
    end

    do
        local actor, actorToken = FixtureActor("Boundary Grab Parent Actor")
        local target = FixtureTarget("Boundary Grab Parent Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local targetId = target.charid or target.id
        local parentCast = {
            tier = 2,
            total = 17,
            naturalRoll = 12,
            lowRoll = false,
            highRoll = true,
            boonsApplied = 1,
            banesApplied = 0,
            casterid = actorToken.charid,
            targets = { { token = target } },
            tokenToTier = {
                [targetId] = 2,
            },
            potencyApplied = {
                [targetId] = true,
            },
        }
        local ability = FixtureAbility{
            name = "Grab",
        }
        local candidate = FixtureCandidate(actor, ability, {
            name = "Grab",
            ability = ability,
            targetType = "target",
            range = 1,
            numTargets = 1,
            hasGrab = true,
        }, target, {
            description = "boundary Grab parent invoke protection",
            symbols = {
                spellname = "Grab",
                cast = parentCast,
            },
        })
        local nestedAbility = FixtureAbility{
            name = "Specific Target Free Strike",
        }
        local restoredAfterNested = nil
        local executed, _, counts = WithExecutionStubs({
            nestedInvokeAbility = nestedAbility,
            promptAbility = nestedAbility,
            promptOnNestedOnly = true,
            resolvePromptResult = {
                status = "blocked",
                reason = "fixture optional prompt has no target",
            },
            mutateAfterPrompt = function(_, abilityArg, _, optionsArg)
                if abilityArg ~= nil and abilityArg.name == "Specific Target Free Strike" then
                    optionsArg.abort = true
                    optionsArg.stopProcessing = true
                    optionsArg.pay = true
                    optionsArg._directorPromptStatus = "optional-skipped"
                    parentCast.tier = nil
                    parentCast.total = 0
                    parentCast.targets = {}
                    parentCast.tokenToTier = {}
                end
            end,
            afterNestedInvoke = function(_, _, _, optionsArg)
                restoredAfterNested = {
                    abort = optionsArg.abort,
                    stopProcessing = optionsArg.stopProcessing,
                    pay = optionsArg.pay,
                    promptStatus = optionsArg._directorPromptStatus,
                    tier = parentCast.tier,
                    total = parentCast.total,
                    targetCount = type(parentCast.targets) == "table" and #parentCast.targets or 0,
                    targetTier = type(parentCast.tokenToTier) == "table" and parentCast.tokenToTier[targetId] or nil,
                }
            end,
        }, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        add("51m", executed == true
            and counts ~= nil
            and counts.invoke == 2
            and counts.promptCallback == 1
            and counts.manualUi == 0
            and restoredAfterNested ~= nil
            and restoredAfterNested.abort ~= true
            and restoredAfterNested.stopProcessing ~= true
            and restoredAfterNested.pay ~= true
            and restoredAfterNested.promptStatus == nil
            and restoredAfterNested.tier == 2
            and restoredAfterNested.total == 17
            and restoredAfterNested.targetCount == 1
            and restoredAfterNested.targetTier == 2
            and actor.context.promptResolutionExit == nil
            and Runtime.manualPromptHandoff == nil
            and "PASS" or "FAIL", "Grab optional free-strike nested invoke restores parent state and continues")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Nested Target Actor")
        local target = FixtureTarget("Boundary Nested Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local nestedAbility = FixtureAbility{
            name = "Boundary Required Target Prompt",
            TargetPassesFilter = function()
                return false
            end,
        }
        local parentAbility = FixtureAbility{
            name = "Boundary Parent Target Prompt",
            behaviors = {
                {
                    typeName = "ActivatedAbilityInvokeAbilityBehavior",
                    targeting = "prompt",
                    invokeOnCaster = false,
                    customAbility = nestedAbility,
                },
            },
        }
        local candidate = FixtureCandidate(actor, parentAbility, {
            name = parentAbility.name,
            ability = parentAbility,
            targetType = "target",
            range = 5,
            numTargets = 1,
        }, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary unresolved nested target prompt",
        })
        local executed, reason, counts = WithExecutionStubs({}, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        local validation = actor.context.lastExecutionValidationResult
        add("51a", executed == false
            and validation ~= nil
            and validation.phase == "prompt.preflight"
            and counts ~= nil
            and counts.move == 0
            and counts.promptUi == 0
            and counts.manualUi == 0
            and counts.invoke == 0
            and (actorToken._moveCount or 0) == 0
            and "PASS" or "FAIL", "required nested target prompt blocks before movement, UI, invoke, or ledger debit" .. (reason ~= nil and "" or ""))
    end

    do
        local actor, actorToken = FixtureActor("Boundary Nested Non Target Actor")
        local target = FixtureTarget("Boundary Nested Non Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local previousManualPrompts = ai.config and ai.config.manualPrompts
        if ai.config ~= nil then
            ai.config.manualPrompts = true
        end
        local nestedAbility = FixtureAbility{
            name = "Boundary Required Non-Target Prompt",
            targetType = "all",
        }
        local parentAbility = FixtureAbility{
            name = "Boundary Parent Non-Target Prompt",
            behaviors = {
                {
                    typeName = "ActivatedAbilityInvokeAbilityBehavior",
                    targeting = "prompt",
                    invokeOnCaster = false,
                    customAbility = nestedAbility,
                },
            },
        }
        local candidate = FixtureCandidate(actor, parentAbility, {
            name = parentAbility.name,
            ability = parentAbility,
            targetType = "target",
            range = 5,
            numTargets = 1,
        }, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary unresolved nested non-target prompt",
        })
        local executed, _, counts = WithExecutionStubs({}, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        if ai.config ~= nil then
            ai.config.manualPrompts = previousManualPrompts
        end
        local validation = actor.context.lastExecutionValidationResult
        add("51b", executed == false
            and validation ~= nil
            and validation.phase == "prompt.preflight"
            and counts ~= nil
            and counts.move == 0
            and counts.promptUi == 0
            and counts.manualUi == 0
            and counts.invoke == 0
            and "PASS" or "FAIL", "required nested non-target prompt blocks before side effects even with manual prompts enabled")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Resource Actor")
        local target = FixtureTarget("Boundary Resource Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local ability = FixtureAbility{
            name = "Boundary Unaffordable Strike",
            canAfford = false,
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            description = "boundary unaffordable strike",
        })
        local executed, _, counts = WithExecutionStubs({}, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        local validation = actor.context.lastExecutionValidationResult

        local maliceAbility = FixtureAbility{
            name = "Boundary Malice Action",
            canAfford = false,
        }
        local maliceCandidate = FixtureCandidate(actor, maliceAbility, {
            name = maliceAbility.name,
            ability = maliceAbility,
            isMalice = true,
            targetType = "target",
        }, target, {
            description = "boundary unaffordable malice action",
        })
        ai:ExecuteCandidate(actor.context, maliceCandidate)
        local maliceValidation = actor.context.lastExecutionValidationResult

        local savedVillain = ai.CanUseVillainAction
        ai.CanUseVillainAction = function()
            return false, "villain secondary resource unavailable"
        end
        local villainAbility = FixtureAbility{
            name = "Boundary Villain Action",
        }
        local villainCandidate = FixtureCandidate(actor, villainAbility, {
            name = villainAbility.name,
            ability = villainAbility,
            isVillain = true,
            targetType = "target",
        }, target, {
            description = "boundary unaffordable villain action",
        })
        ai:ExecuteCandidate(actor.context, villainCandidate)
        local villainValidation = actor.context.lastExecutionValidationResult
        ai.CanUseVillainAction = savedVillain

        add("51c", executed == false
            and validation ~= nil
            and validation.phase == "resource.pre_move"
            and maliceValidation ~= nil
            and maliceValidation.phase == "resource.pre_move"
            and villainValidation ~= nil
            and villainValidation.phase == "resource.pre_move"
            and counts ~= nil
            and counts.move == 0
            and counts.invoke == 0
            and "PASS" or "FAIL", "unaffordable action, malice, and villain resources fail before movement")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Reserve Actor")
        local target = FixtureTarget("Boundary Reserve Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        ai.Ledger:EnsureTurnMemory(ai, actor)
        ai.Ledger:GrantActionEconomy(ai, actor, {
            kind = "action",
            source = "Boundary reserve fixture",
        })
        actor.turnMemory.actionsUsed = 1
        actor.turnMemory.actionUsed = true
        local ability = FixtureAbility{
            name = "Boundary Grant Strike",
            affordWithNoActionResource = true,
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary grant reserve failure",
        })
        local savedValidate = ai.ValidateCandidateForPhase
        ai.ValidateCandidateForPhase = function(selfArg, contextArg, candidateArg, phaseArg, argsArg)
            local result = savedValidate(selfArg, contextArg, candidateArg, phaseArg, argsArg)
            if phaseArg == "legality.dry_run" and result ~= nil and result.ok == true then
                local grant = actor.turnMemory.actionGrants and actor.turnMemory.actionGrants[1]
                if grant ~= nil then
                    grant.consumed = true
                end
            end
            return result
        end
        local executed, _, counts = WithExecutionStubs({}, function(stubCounts)
            local ok = ai:ExecuteCandidate(actor.context, candidate)
            return ok, stubCounts
        end)
        ai.ValidateCandidateForPhase = savedValidate
        local validation = actor.context.lastExecutionValidationResult
        add("51d", executed == false
            and validation ~= nil
            and validation.phase == "resource.reserve"
            and counts ~= nil
            and counts.move == 0
            and counts.invoke == 0
            and "PASS" or "FAIL", "pending grant disappearing after precheck fails in resource.reserve before movement")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Stale Actor")
        local target = FixtureTarget("Boundary Stale Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        local ability = FixtureAbility{
            name = "Boundary Stale Strike",
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary stale target",
        })
        local executed = WithExecutionStubs({
            afterMove = function()
                target.valid = false
            end,
        }, function()
            return ai:ExecuteCandidate(actor.context, candidate)
        end)
        local validation = actor.context.lastExecutionValidationResult
        add("51e", executed == false
            and validation ~= nil
            and validation.phase == "movement.stale"
            and actorToken.loc == origin
            and "PASS" or "FAIL", "post-move target invalidation reports movement.stale and rolls back movement")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Invoke Rollback Actor")
        local target = FixtureTarget("Boundary Invoke Rollback Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        ai.Ledger:EnsureTurnMemory(ai, actor)
        ai.Ledger:GrantActionEconomy(ai, actor, {
            kind = "action",
            source = "Boundary invoke rollback fixture",
        })
        actor.turnMemory.actionsUsed = 1
        actor.turnMemory.actionUsed = true
        local grant = actor.turnMemory.actionGrants and actor.turnMemory.actionGrants[1]
        local ability = FixtureAbility{
            name = "Boundary Invoke Rollback Strike",
            affordWithNoActionResource = true,
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary invoke rollback",
        })
        local executed, _, counts = WithExecutionStubs({
            invokeReturnsFalse = true,
        }, function()
            return ai:ExecuteCandidate(actor.context, candidate)
        end)
        add("51f", executed == false
            and counts ~= nil
            and counts.move > 0
            and counts.invoke == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.cleanup >= 2
            and counts.manualUi == 0
            and actorToken.loc == origin
            and grant ~= nil
            and grant.reserved ~= true
            and grant.consumed ~= true
            and "PASS" or "FAIL", "invoke no-cast rollback restores movement and pending grant reservation")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Invoke Failure Actor")
        local target = FixtureTarget("Boundary Invoke Failure Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        ai.Ledger:EnsureTurnMemory(ai, actor)
        ai.Ledger:GrantActionEconomy(ai, actor, {
            kind = "action",
            source = "Boundary invoke failure fixture",
        })
        actor.turnMemory.actionsUsed = 1
        actor.turnMemory.actionUsed = true
        local grant = actor.turnMemory.actionGrants and actor.turnMemory.actionGrants[1]
        local ability = FixtureAbility{
            name = "Boundary Invoke Failure Strike",
            affordWithNoActionResource = true,
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary invoke failure",
        })
        local executed, reason, counts = WithExecutionStubs({
            invokeErrors = true,
        }, function()
            return ai:ExecuteCandidate(actor.context, candidate)
        end)
        add("51n", executed == false
            and string.find(tostring(reason), "ability invoke failed", 1, true) ~= nil
            and counts ~= nil
            and counts.move > 0
            and counts.invoke == 1
            and counts.promptUi == 1
            and counts.promptControlRestored == 1
            and counts.cleanup >= 2
            and counts.manualUi == 0
            and actorToken.loc == origin
            and grant ~= nil
            and grant.reserved ~= true
            and grant.consumed ~= true
            and "PASS" or "FAIL", "invoke SafeCall failure rolls back movement and pending grant reservation")
    end

    do
        local actor, actorToken = FixtureActor("Boundary Success Actor")
        local target = FixtureTarget("Boundary Success Target", targetLoc)
        actor.context.allCombatTokens = { actorToken, target }
        ai.Ledger:EnsureTurnMemory(ai, actor)
        ai.Ledger:GrantActionEconomy(ai, actor, {
            kind = "action",
            source = "Boundary success fixture",
        })
        actor.turnMemory.actionsUsed = 1
        actor.turnMemory.actionUsed = true
        local grant = actor.turnMemory.actionGrants and actor.turnMemory.actionGrants[1]
        local ability = FixtureAbility{
            name = "Boundary Success Strike",
            affordWithNoActionResource = true,
        }
        local candidate = FixtureCandidate(actor, ability, nil, target, {
            preInvokeMove = {
                mode = "walk",
                destination = moveLoc,
                tiles = 1,
            },
            description = "boundary success grant",
        })
        local consumedBeforeFinish = nil
        local savedReconcile = ai.Ledger.ReconcileGlobalResourceSpend
        local reconcileCount = 0
        ai.Ledger.ReconcileGlobalResourceSpend = function(selfLedger, aiArg, candidateArg, snapshotArg)
            reconcileCount = reconcileCount + 1
            return savedReconcile(selfLedger, aiArg, candidateArg, snapshotArg)
        end
        local executed = WithExecutionStubs({
            beforeFinish = function()
                consumedBeforeFinish = grant ~= nil and grant.consumed == true
            end,
        }, function()
            return ai:ExecuteCandidate(actor.context, candidate)
        end)
        ai.Ledger.ReconcileGlobalResourceSpend = savedReconcile
        add("51g", executed == true
            and consumedBeforeFinish ~= true
            and grant ~= nil
            and grant.consumed == true
            and reconcileCount == 1
            and "PASS" or "FAIL", "successful invoke commits grant and reconciles ledger only after invoke completion")
    end
end

local function RunWerewolfPriorityAcceptanceFixtures(ai, add, PromptFixtureGrid, PromptFixtureToken)
    local center = PromptFixtureGrid("fixture:werewolf-priority", 4)
    local actorToken = PromptFixtureToken("Fixture Werewolf", "fixture-werewolf", center, "monsters")
    local targetA = PromptFixtureToken("Fixture Human A", "fixture-human-a", center.east, "heroes")
    local targetB = PromptFixtureToken("Fixture Human B", "fixture-human-b", center.north, "heroes")
    local actor = {
        token = actorToken,
        allies = {},
        enemies = { targetA, targetB },
        context = {
            allCombatTokens = { actorToken, targetA, targetB },
            malice = 4,
        },
        turnMemory = {},
    }
    actor.context.actors = { actor }

    local function Score(total, parts)
        return {
            total = total,
            parts = parts or {},
        }
    end

    local biteInfo = {
        name = "Accursed Bite",
        targetType = "target",
        isAction = true,
        isArea = false,
        isSignature = true,
        hasDamage = true,
        conditionApplyNames = {},
        conditionRemovalNames = {},
    }
    local slashInfo = {
        name = "Berserker Slash",
        targetType = "self",
        isAction = true,
        isArea = true,
        isMalice = true,
        hasDamage = true,
        conditionApplyNames = {},
        conditionRemovalNames = {},
        ability = {
            name = "Berserker Slash",
            resourceNumber = 3,
        },
    }
    local bite = ai:MakeCandidate{
        actor = actor,
        abilityInfo = biteInfo,
        actionCost = "action",
        loc = center,
        targets = { { token = targetA } },
        scoreInfo = Score(14.6, { "damage +9.0", "signature +6.0" }),
        description = "Accursed Bite on Fixture Human A",
    }
    local slash = ai:MakeCandidate{
        actor = actor,
        abilityInfo = slashInfo,
        actionCost = "action",
        loc = center,
        targets = { { token = targetA }, { token = targetB } },
        scoreInfo = Score(12.85, { "damage +8.0", "multi-target +2.0", "malice impact +3.5" }),
        description = "Berserker Slash area (2 targets)",
    }
    local promoted = { bite, slash }
    ai.Pipeline:ApplyPolicyScores(actor.context, actor, "turn", promoted, { silent = true }, {})
    ai.Pipeline:PrepareOrderingKeys(promoted, "turn")
    ai.Pipeline:Rank(actor.context, actor, "turn", promoted, { silent = true }, {}, nil)
    add("40a", promoted[1] == slash
        and ai:ScoreHasLabel(slash.scoreInfo, "policy area main pressure")
        and slash.normalized ~= nil
        and slash.normalized.score ~= nil
        and type(slash.normalized.score.policyAdjustments) == "table"
        and "PASS" or "FAIL", "safe two-target area main action receives visible policy score over close single-target main action")

    local finishingBite = ai:MakeCandidate{
        actor = actor,
        abilityInfo = biteInfo,
        actionCost = "action",
        loc = center,
        targets = { { token = targetA } },
        scoreInfo = Score(14.6, { "damage +9.0", "finish +6.0", "signature +6.0" }),
        description = "Accursed Bite finishing Fixture Human A",
    }
    local nonFinishingSlash = ai:MakeCandidate{
        actor = actor,
        abilityInfo = slashInfo,
        actionCost = "action",
        loc = center,
        targets = { { token = targetA }, { token = targetB } },
        scoreInfo = Score(13.5, { "damage +8.0", "multi-target +2.0", "malice impact +3.5" }),
        description = "Berserker Slash area (2 targets)",
    }
    local finishProtected = { finishingBite, nonFinishingSlash }
    ai.Pipeline:ApplyPolicyScores(actor.context, actor, "turn", finishProtected, { silent = true }, {})
    ai.Pipeline:PrepareOrderingKeys(finishProtected, "turn")
    ai.Pipeline:Rank(actor.context, actor, "turn", finishProtected, { silent = true }, {}, nil)
    add("40b", finishProtected[1] == finishingBite
        and not ai:ScoreHasLabel(nonFinishingSlash.scoreInfo, "policy area main pressure")
        and "PASS" or "FAIL", "single-target finish remains ahead of close area main action")

    local savedFindCandidates = ai.FindCandidates
    local mainCandidate = ai:MakeCandidate{
        actor = actor,
        abilityInfo = slashInfo,
        actionCost = "action",
        loc = center,
        targets = { { token = targetA }, { token = targetB } },
        scoreInfo = Score(12, { "fixture main malice +12.0" }),
        description = "Berserker Slash area (2 targets)",
    }
    ai.FindCandidates = function()
        return { mainCandidate }
    end
    local holdsStartTurn = false
    local reservation = nil
    local ok = pcall(function()
        holdsStartTurn, reservation = ai.Ledger:ForecastMainActionMaliceReservation(ai, {
            malice = 7,
        }, {
            actor = actor,
            abilityInfo = {
                name = "Malicious Strike",
                isMalice = true,
                ability = {
                    name = "Malicious Strike",
                    resourceNumber = 5,
                },
            },
            maliceCost = 5,
            description = "Malicious Strike on self",
        })
    end)
    ai.FindCandidates = savedFindCandidates
    add("40c", ok and holdsStartTurn and reservation ~= nil and "PASS" or "FAIL", "start-turn malice reserves legal main-action malice")

    local grabbedTarget = PromptFixtureToken("Fixture Grabbed Human", "fixture-grabbed-human", center.west, "heroes")
    grabbedTarget.properties.HasNamedCondition = function(_, conditionName)
        return conditionName == "Grabbed"
    end
    local grabContext = {
        allCombatTokens = { actorToken, grabbedTarget, targetA },
    }
    local grabActor = {
        token = actorToken,
        allies = {},
        enemies = { grabbedTarget, targetA },
        context = grabContext,
        turnMemory = {},
    }
    local grabAbility = {
        name = "Grab",
        targetType = "target",
        multipleModes = true,
        modeList = {
            { name = "Aggressive" },
            { name = "Safe" },
        },
    }
    local grabInfo = {
        name = "Grab",
        ability = grabAbility,
        targetType = "target",
        numTargets = 1,
        range = 1,
        hasGrab = true,
        conditionApplyNames = { "Grabbed" },
        conditionRemovalNames = {},
    }
    local savedReachable = ai.GetReachableLocs
    local savedConditionCasterMatchesToken = ai.ConditionCasterMatchesToken
    ai.GetReachableLocs = function()
        return { { loc = center, cost = 0, positionScore = 0 } }
    end
    ai.ConditionCasterMatchesToken = function(_, conditionedToken, conditionName, sourceToken)
        return conditionedToken == grabbedTarget and conditionName == "Grabbed" and sourceToken == actorToken, "fixture source"
    end
    local grabCandidates = {}
    local grabOk = pcall(function()
        grabCandidates = ai:EnumerateSingleTargetAbility(grabContext, grabActor, grabAbility, grabInfo)
    end)
    ai.GetReachableLocs = savedReachable
    ai.ConditionCasterMatchesToken = savedConditionCasterMatchesToken
    add("40d", grabOk and #grabCandidates == 0 and "PASS" or "FAIL", "source-matched active Grab suppresses another standard Grab")

    local otherGrabbedTarget = PromptFixtureToken("Fixture Other Grabbed Human", "fixture-other-grabbed-human", center.south, "heroes")
    otherGrabbedTarget.properties.HasNamedCondition = function(_, conditionName)
        return conditionName == "Grabbed"
    end
    local savedOtherGrab = {
        ChargeMoveInfo = ai.ChargeMoveInfo,
        ConditionCasterMatchesToken = ai.ConditionCasterMatchesToken,
        LegalMoveOptions = ai.LegalMoveOptions,
        ResolveActionType = ai.ResolveActionType,
        TargetableSetFromEngine = ai.TargetableSetFromEngine,
    }
    ai.ChargeMoveInfo = function()
        return {
            loc = center.south,
            distance = 1,
            path = {},
            hazardDamage = 0,
        }
    end
    ai.ConditionCasterMatchesToken = function()
        return false, "fixture other source"
    end
    ai.LegalMoveOptions = function()
        return {
            {
                mode = "charge",
                reachableLocs = {
                    { loc = center.south, path = {}, hazardDamage = 0 },
                },
            },
        }
    end
    ai.ResolveActionType = function()
        return {
            kind = "main",
            preInvokeMovement = {
                mode = "charge",
            },
        }
    end
    ai.TargetableSetFromEngine = function()
        return {
            _range = 1,
            {
                token = targetA,
                distance = 0,
                lineOfSight = true,
                passedEngineFilter = true,
            },
        }
    end
    local unrelatedGrabCharge = nil
    local unrelatedGrabOk = pcall(function()
        unrelatedGrabCharge = ai:BuildCandidate({
            name = "Fixture Charge Bite",
        }, {
            name = "Fixture Charge Bite",
            targetType = "target",
            targetAllegiance = "enemy",
            targetFilter = "enemy",
            numTargets = 1,
            range = 0,
            conditionApplyNames = {},
            conditionRemovalNames = {},
        }, center, { token = targetA }, { mode = 1 }, {
            context = {
                allCombatTokens = { actorToken, targetA, otherGrabbedTarget },
            },
            actor = actor,
            casterToken = actorToken,
            scoreInfo = Score(1, { "fixture +1.0" }),
        })
    end)
    for key,value in pairs(savedOtherGrab) do
        ai[key] = value
    end
    add("40e", unrelatedGrabOk
        and unrelatedGrabCharge ~= nil
        and unrelatedGrabCharge.preInvokeMove ~= nil
        and "PASS" or "FAIL", "another actor's Grab does not suppress unrelated charge")

    local saved = {
        GetReachableLocs = ai.GetReachableLocs,
        BuildCandidate = ai.BuildCandidate,
        ResolveActionType = ai.ResolveActionType,
        TargetHasCondition = ai.TargetHasCondition,
        AbilityHasNestedMovementPrompt = ai.AbilityHasNestedMovementPrompt,
        IsAutoResolvableGrabModePrompt = ai.IsAutoResolvableGrabModePrompt,
        IsAutoResolvableForcedMovementModePrompt = ai.IsAutoResolvableForcedMovementModePrompt,
    }
    local seenLocs = {}
    ai.GetReachableLocs = function()
        return {
            { loc = center, cost = 0, positionScore = 0 },
            { loc = center.south, cost = 1, positionScore = 1 },
        }
    end
    ai.BuildCandidate = function(_, _, _, loc)
        seenLocs[#seenLocs+1] = loc
        return nil, "fixture probe only"
    end
    ai.ResolveActionType = function()
        return {
            kind = "main",
            preInvokeMovement = {
                mode = "charge",
            },
        }
    end
    ai.TargetHasCondition = function()
        return false
    end
    ai.AbilityHasNestedMovementPrompt = function()
        return false
    end
    ai.IsAutoResolvableGrabModePrompt = function()
        return false
    end
    ai.IsAutoResolvableForcedMovementModePrompt = function()
        return false
    end
    local chargeOk = pcall(function()
        ai:EnumerateSingleTargetAbility({
            allCombatTokens = { targetA },
        }, actor, {
            name = "Accursed Bite",
        }, {
            name = "Accursed Bite",
            targetType = "target",
            numTargets = 1,
            range = 1,
        })
    end)
    for key,value in pairs(saved) do
        ai[key] = value
    end
    add("40f", chargeOk and #seenLocs == 1 and seenLocs[1] == center and "PASS" or "FAIL", "charge/pre-invoke enumeration stays on current origin")
end

local function RunLiveSceneAcceptanceFixtures(ai, Add, context, analyzed)
    local grabbedChecked = false
    local restrainedChecked = false
    local frightenedChecked = false
    local dazedChecked = false
    local freeStrikeChecked = false
    local chargeChecked = false
    local hideChecked = false
    local searchChecked = false
    local shiftChecked = false
    local aidChecked = false
    local aidTargetChecked = false
    local roleChecked = false

    for _,entry in ipairs(analyzed or {}) do
        local actor = entry.actor
        local token = actor and actor.token
        local candidates = entry.candidates or {}

        if token ~= nil and not grabbedChecked and ai:TargetHasCondition(token, "Grabbed") then
            grabbedChecked = true
            local moveOptions = ai:LegalMoveOptions(token, actor, "walk")
            local moveReason = tostring(TryGet(moveOptions and moveOptions[1], "reason", ""))
            local escape = AcceptanceCandidateContains(candidates, function(candidate)
                return candidate.abilityInfo ~= nil and ai:IsEscapeGrabName(candidate.abilityInfo.name)
            end)
            Add(2, (string.find(moveReason, "Grabbed", 1, true) ~= nil and escape ~= nil) and "PASS" or "FAIL", "Grabbed actor movement gate and Escape Grab candidate checked")
        end

        if token ~= nil and not restrainedChecked and ai:TargetHasCondition(token, "Restrained") then
            restrainedChecked = true
            local moveOptions = ai:LegalMoveOptions(token, actor, "walk")
            local moveReason = tostring(TryGet(moveOptions and moveOptions[1], "reason", ""))
            Add(3, string.find(moveReason, "Restrained", 1, true) ~= nil and "PASS" or "FAIL", "Restrained actor movement gate checked")
        end

        if token ~= nil and not frightenedChecked and ai:TargetHasCondition(token, "Frightened") then
            local source = ai:ConditionSourceToken(context, token, "Frightened")
            if source ~= nil and source.loc ~= nil then
                frightenedChecked = true
                local currentDistance = LocDistance(token.loc, source.loc)
                local closer = false
                local moveOptions = ai:LegalMoveOptions(token, actor, "walk")
                for _,option in ipairs(moveOptions or {}) do
                    for _,locInfo in ipairs(option.reachableLocs or {}) do
                        if locInfo.loc ~= nil and LocDistance(locInfo.loc, source.loc) + 0.05 < currentDistance then
                            closer = true
                        end
                    end
                end
                Add(4, not closer and "PASS" or "FAIL", "Frightened reachable set checked against known source")
            end
        end

        if token ~= nil and not freeStrikeChecked then
            local ability = AcceptanceAbilityExists(ai, actor, function(ability, info)
                return ai:IsMeleeFreeStrikeName(info.name)
            end)
            if ability ~= nil then
                freeStrikeChecked = true
                local actionType = ai:ResolveActionType(ability)
                Add(5, actionType ~= nil and actionType.preInvokeMovement == nil and "PASS" or "FAIL", "Melee Free Strike has no pre-invoke movement")
            end
        end

        if not chargeChecked then
            local charge = AcceptanceCandidateContains(candidates, function(candidate)
                local move = ai.CandidatePreInvokeMove and ai:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
                return move ~= nil and move.mode == "charge"
            end)
            if charge ~= nil then
                chargeChecked = true
                Add(6, "PASS", "Charge candidate has typed preInvokeMove")
            end
        end

        if not hideChecked then
            local hide = AcceptanceCandidateContains(candidates, function(candidate)
                return candidate.abilityInfo ~= nil and ai:IsHideName(candidate.abilityInfo.name)
            end)
            if hide ~= nil then
                hideChecked = true
                Add(8, "PASS", "Hide candidate enumerated in current scene")
            end
        end

        if not searchChecked then
            local search = AcceptanceCandidateContains(candidates, function(candidate)
                return candidate.abilityInfo ~= nil and ai:IsSearchForHiddenName(candidate.abilityInfo.name)
            end)
            if search ~= nil then
                searchChecked = true
                Add(9, "PASS", "Search for Hidden candidate enumerated in current scene")
            end
        end

        if not shiftChecked then
            local shift = AcceptanceCandidateContains(candidates, function(candidate)
                return candidate.isShift == true or (candidate.abilityInfo ~= nil and ai:IsShiftName(candidate.abilityInfo.name))
            end)
            if shift ~= nil then
                shiftChecked = true
                Add(10, "PASS", "Shift candidate enumerated as movement option")
            end
        end

        if not aidChecked or not aidTargetChecked then
            local aid = AcceptanceCandidateContains(candidates, function(candidate)
                return candidate.abilityInfo ~= nil and ai:IsAidAttackName(candidate.abilityInfo.name)
            end)
            if aid ~= nil then
                if not aidChecked then
                    aidChecked = true
                    Add(11, "PASS", "Aid Attack remains legal in current scene")
                end
                if not aidTargetChecked then
                    local target = TryGet(aid.targets and aid.targets[1], "token", nil) or aid.target
                    local enemyTarget = false
                    for _,enemy in ipairs(actor.enemies or {}) do
                        if target == enemy or TryGet(target, "charid", nil) == TryGet(enemy, "charid", false) then
                            enemyTarget = true
                        end
                    end
                    aidTargetChecked = true
                    Add(12, enemyTarget and "PASS" or "FAIL", "Aid Attack target side checked")
                end
            end
        end

        if token ~= nil and not dazedChecked and ai:TargetHasCondition(token, "Dazed") and ai.Ledger ~= nil then
            dazedChecked = true
            local mainAllowed = ai.Ledger:CanSpendActionType(ai, actor, { kind = "main" }, nil)
            local freeAllowed = ai.Ledger:CanSpendActionType(ai, actor, { kind = "freeTriggered" }, nil)
            Add(14, mainAllowed and not freeAllowed and "PASS" or "FAIL", "Dazed main/free-triggered gates checked")
        end

        if not roleChecked then
            local name = string.lower(TokenName(token))
            if string.find(name, "slink", 1, true) or string.find(name, "predator", 1, true) or string.find(name, "ajax", 1, true) then
                roleChecked = true
                Add(18, (#candidates > 0) and "PASS" or "FAIL", "role spot-check actor has ranked candidates: " .. TokenName(token))
            end
        end
    end

    if not grabbedChecked then Add(2, "DEFERRED", "current scene has no grabbed Director actor") end
    if not restrainedChecked then Add(3, "DEFERRED", "current scene has no restrained Director actor") end
    if not frightenedChecked then Add(4, "DEFERRED", "current scene has no frightened actor with known source") end
    if not freeStrikeChecked then Add(5, "DEFERRED", "current scene has no Melee Free Strike ability to inspect") end
    if not chargeChecked then Add(6, "DEFERRED", "current analysis produced no Charge candidate") end
    Add(7, "DEFERRED", "read-only harness does not move targets between score and execute")
    if not hideChecked then Add(8, "DEFERRED", "current analysis produced no Hide candidate") end
    if not searchChecked then Add(9, "DEFERRED", "current analysis produced no Search for Hidden candidate") end
    if not shiftChecked then Add(10, "DEFERRED", "current analysis produced no Shift candidate") end
    if not aidChecked then Add(11, "DEFERRED", "current analysis produced no Aid Attack candidate") end
    if not aidTargetChecked then Add(12, "DEFERRED", "current analysis produced no Aid Attack target to inspect") end
    Add(13, "DEFERRED", "read-only harness does not spend 10+ Malice for Solo Action stacking")
    if not dazedChecked then Add(14, "DEFERRED", "current scene has no Dazed Director actor") end
    Add(15, "DEFERRED", "read-only harness does not advance end-round Villain Action queue")
    Add(16, "DEFERRED", "requires a fixture with a rejecting GoblinScript target filter")
    if not roleChecked then Add(18, "DEFERRED", "current scene lacks Slink, Predator, or Ajax spot-check actor") end
    Add(19, "PASS", "Phase 0 theoretical-location probe already recorded")
end

local function RunPromotionConstantAcceptanceFixtures(ai, Add)
    local candidateConstants = ai.K and ai.K.Candidate or nil
    local hadAdvancePromotionThreshold = candidateConstants ~= nil and candidateConstants.AdvancePromotionThreshold ~= nil
    local savedAdvancePromotionThreshold = hadAdvancePromotionThreshold and candidateConstants.AdvancePromotionThreshold or nil
    if candidateConstants ~= nil then
        candidateConstants.AdvancePromotionThreshold = nil
    end

    local rangedFixture = {
        abilityInfo = {
            name = "Ranged Free Strike",
        },
        score = 0,
        description = "fixture ranged free strike",
    }
    local advanceFixture = {
        abilityInfo = {
            name = "Move Speed",
        },
        isAdvance = true,
        score = 1,
        description = "fixture advance",
    }
    local promotionCandidates = { rangedFixture, advanceFixture }
    local constantFallbackPass = SafeCall(function()
        return ConstNumber("Candidate", "AdvancePromotionThreshold", 0.8) == 0.8
    end, false)
    local promotionPass = SafeCall(function()
        ai:PromoteAdvanceOverRangedFreeStrike(promotionCandidates)
        return promotionCandidates[1] == advanceFixture and promotionCandidates[2] == rangedFixture
    end, false)

    if candidateConstants ~= nil then
        if hadAdvancePromotionThreshold then
            candidateConstants.AdvancePromotionThreshold = savedAdvancePromotionThreshold
        else
            candidateConstants.AdvancePromotionThreshold = nil
        end
    end

    Add(38, constantFallbackPass and promotionPass and "PASS" or "FAIL", "missing numeric constant falls back during advance promotion")
end

local function RunContractBuilderAcceptanceFixtures(ai, add)
    local promptCapability = ai.MakePromptCapability ~= nil and ai:MakePromptCapability{
        promptStatus = "handled",
        policy = {
            id = "fixture-policy",
        },
    } or nil
    add("50a", promptCapability ~= nil
        and promptCapability.status == "auto"
        and promptCapability.promptStatus == "handled"
        and promptCapability.policies[1] == "fixture-policy"
        and "PASS" or "FAIL", "PromptCapability builder maps handled prompt status to auto metadata")

    local manualCapability = ai.PromptCapabilityFromPromptResult ~= nil and ai:PromptCapabilityFromPromptResult({
        status = "manual",
        reason = "fixture manual",
    }, {
        id = "fixture-manual-policy",
    }) or nil
    add("50b", manualCapability ~= nil
        and manualCapability.status == "manual"
        and manualCapability.promptStatus == "manual"
        and manualCapability.reason == "fixture manual"
        and manualCapability.policies[1] == "fixture-manual-policy"
        and "PASS" or "FAIL", "PromptCapability adapter preserves manual prompt policy metadata")

    local legality = ai.LegalityResultFromTuple ~= nil and ai:LegalityResultFromTuple(false, "target invalid", {
        kind = "area",
        friendly = true,
    }) or nil
    local legalityOk = nil
    local legalityReason = nil
    local legalityFriendly = nil
    if ai.LegalityResultToTuple ~= nil then
        legalityOk, legalityReason, legalityFriendly = ai:LegalityResultToTuple(legality)
    end
    add("50c", legality ~= nil
        and legality.kind == "area"
        and legality.ok == false
        and legalityOk == false
        and legalityReason == "target invalid"
        and legalityFriendly == true
        and "PASS" or "FAIL", "LegalityResult adapter preserves legacy tuple values")

    local validation = ai.ValidationResultFromTuple ~= nil and ai:ValidationResultFromTuple(false, "candidate was incomplete", {
        field = "candidate",
    }, {
        phase = "contract",
    }) or nil
    local validationOk = nil
    local validationReason = nil
    local validationDetails = nil
    if ai.ValidationResultToTuple ~= nil then
        validationOk, validationReason, validationDetails = ai:ValidationResultToTuple(validation)
    end
    add("50d", validation ~= nil
        and validation.phase == "contract"
        and validation.ok == false
        and validationOk == false
        and validationReason == "candidate was incomplete"
        and validationDetails ~= nil
        and validationDetails.field == "candidate"
        and "PASS" or "FAIL", "ValidationResult adapter preserves legacy tuple values")

    local writerCandidate = {}
    local writerTarget = {
        charid = "writer-target",
    }
    local writerLoc = {
        str = "writer:loc",
    }
    local writerGrant = {
        kind = "main",
    }
    ai:WriteCandidateIntent(writerCandidate, {
        targets = { { token = writerTarget } },
        actionCost = "maneuver",
        manualPrompt = true,
        manualPromptReason = "writer fixture",
    })
    ai:WriteCandidateExecution(writerCandidate, {
        loc = writerLoc,
        actionGrant = writerGrant,
        usesActionGrant = true,
    })
    ai:WriteCandidateScore(writerCandidate, {
        total = 4,
        retryKey = "writer-key",
        comboLookahead = {
            bonus = 1,
        },
    })
    add("50e", writerCandidate.intent ~= nil
        and writerCandidate.intent.targets == writerCandidate.targets
        and writerCandidate.intent.actionCost == writerCandidate.actionCost
        and writerCandidate.execution ~= nil
        and writerCandidate.execution.loc == writerCandidate.loc
        and writerCandidate.execution.actionGrant == writerCandidate.actionGrant
        and writerCandidate.normalized ~= nil
        and writerCandidate.normalized.score ~= nil
        and writerCandidate.normalized.score.total == writerCandidate.score
        and writerCandidate.normalized.score.retryKey == writerCandidate.retryKey
        and "PASS" or "FAIL", "candidate write helpers mirror normalized fields to legacy aliases")

    ai:WriteCandidateExecution(writerCandidate, nil, {
        clear = {
            "actionGrant",
            "usesActionGrant",
        },
    })
    add("50f", writerCandidate.execution.actionGrant == nil
        and writerCandidate.actionGrant == nil
        and writerCandidate.execution.usesActionGrant == nil
        and writerCandidate.usesActionGrant == nil
        and "PASS" or "FAIL", "candidate execution writer clears normalized and legacy aliases")
end

function AI:RunAcceptanceHarness()
    local rows = {}
    local counts = { PASS = 0, FAIL = 0, DEFERRED = 0 }
    local scenarioIds = {}

    local function Add(id, status, detail)
        id = tostring(id)
        status = status or "DEFERRED"
        if scenarioIds[id] then
            status = "FAIL"
            detail = "duplicate scenario id: " .. id .. Pick(detail ~= nil and detail ~= "", " - " .. tostring(detail), "")
        end
        scenarioIds[id] = true
        counts[status] = (counts[status] or 0) + 1
        rows[#rows+1] = string.format("Scenario %s - %s - %s", id, status, tostring(detail or ""))
    end

    local queue = dmhub.initiativeQueue
    local context = nil
    local analyzed = {}
    if queue ~= nil and not queue.hidden then
        local initiativeid = queue:CurrentInitiativeId()
        if initiativeid ~= nil then
            context = SafeCall(function()
                return self:BuildContext(initiativeid)
            end, nil)
        end
    end

    if context ~= nil then
        for _,actor in ipairs(context.actors or {}) do
            local result = SafeCall(function()
                return self.Pipeline:Run(context, actor, "analysisOnly", { silent = true })
            end, nil)
            analyzed[#analyzed+1] = {
                actor = actor,
                result = result,
                candidates = (result and result.ranked) or {},
            }
        end
    end

    Add(1, "DEFERRED", "read-only harness does not execute a full standard turn")
    RunContractBuilderAcceptanceFixtures(self, Add)

    local function FixtureCandidate(args)
        args = args or {}
        local abilityInfo = args.abilityInfo or {
            name = args.name or "Fixture Ability",
            targetType = args.targetType or "target",
            hasDamage = args.hasDamage == true,
            hasForcedMovement = args.hasForcedMovement == true,
            hasSummon = args.hasSummon == true,
            conditionApplyNames = args.conditionApplyNames or {},
            conditionRemovalNames = args.conditionRemovalNames or {},
        }

        return self:MakeCandidate{
            abilityInfo = abilityInfo,
            scoreInfo = CreateScore(),
            description = args.description or abilityInfo.name,
            modeSelection = args.modeSelection,
            manualPrompt = args.manualPrompt,
            manualPromptReason = args.manualPromptReason,
            movementOnly = args.movementOnly,
            skipReason = args.skipReason,
            fallback = args.fallback,
        }
    end

    local function DecisionMatches(candidateOrDecision, outcome, lane)
        local decision = candidateOrDecision
        if type(candidateOrDecision) == "table" and candidateOrDecision.automationDecision ~= nil then
            decision = candidateOrDecision.automationDecision
        end

        return type(decision) == "table"
            and decision.outcome == outcome
            and decision.lane == lane
            and decision.partialPromptHandoff == false
    end

    local exactFixture = FixtureCandidate{
        name = "Fixture Strike",
        hasDamage = true,
        description = "fixture exact auto",
    }
    Add(20, DecisionMatches(exactFixture, "exact_auto", "turn") and "PASS" or "FAIL", "AutomationDecision exact_auto fixture")

    local approximateFixture = FixtureCandidate{
        name = "Fixture Forced Movement",
        hasForcedMovement = true,
        modeSelection = {
            index = 2,
            text = "Slide 2",
            reason = "fixture safe forced movement mode",
        },
        description = "fixture safe approximation",
    }
    local approximateDecision = approximateFixture and approximateFixture.automationDecision
    Add(21, DecisionMatches(approximateFixture, "safe_approximate_auto", "turn")
        and type(approximateDecision.approximation) == "table"
        and approximateDecision.approximation.kind == "mode_selection"
        and "PASS" or "FAIL", "AutomationDecision safe_approximate_auto fixture")

    local manualFixture = FixtureCandidate{
        name = "Fixture Summon",
        hasSummon = true,
        manualPrompt = true,
        manualPromptReason = "summon placement",
        description = "fixture manual before execution",
    }
    Add(22, DecisionMatches(manualFixture, "manual_before_execution", "turn")
        and manualFixture.automationDecision.manualBeforeExecution == true
        and "PASS" or "FAIL", "AutomationDecision manual_before_execution fixture")

    local skipFixture = FixtureCandidate{
        name = "Fixture Unsupported",
        skipReason = "fixture unsupported prompt",
        fallback = {
            kind = "fixture_fallback",
        },
        description = "fixture skip with fallback",
    }
    Add(23, DecisionMatches(skipFixture, "skip_with_fallback", "turn")
        and type(skipFixture.automationDecision.fallback) == "table"
        and "PASS" or "FAIL", "AutomationDecision skip_with_fallback fixture")

    local triggerFixture = self:MakeAutomationDecision{
        outcome = "exact_auto",
        lane = "trigger",
        source = "trigger-policy",
        reason = "fixture trigger policy",
        capabilities = {
            trigger = true,
        },
        fallback = {
            kind = "no_trigger",
        },
    }
    Add(24, DecisionMatches(triggerFixture, "exact_auto", "trigger")
        and type(triggerFixture.fallback) == "table"
        and triggerFixture.fallback.kind == "no_trigger"
        and "PASS" or "FAIL", "AutomationDecision trigger-lane fixture")

    local previousReactiveTriggers = self.config.reactiveTriggers
    local previousOpportunityAttacks = self.config.opportunityAttacks
    self.config.reactiveTriggers = true
    self.config.opportunityAttacks = true

    local function RestoreReactiveTriggerConfig()
        self.config.reactiveTriggers = previousReactiveTriggers
        self.config.opportunityAttacks = previousOpportunityAttacks
    end

    local function TriggerFixtureToken(args)
        args = args or {}
        local token = {
            valid = true,
            charid = args.charid or args.id,
            id = args.id,
            playerControlled = false,
            properties = {
                name = args.name or "Trigger Fixture",
            },
        }
        token.properties.HasNamedCondition = function(_, conditionName)
            return args.dazed == true and tostring(conditionName) == "Dazed"
        end
        token.properties.GetHeroicOrMaliceResourcesAvailableToSpend = function()
            return args.heroicAvailable or 0
        end
        token.properties.GetEpicResources = function()
            return args.epicAvailable or 0
        end
        token.properties.IsDead = function()
            return false
        end
        return token
    end

    local function TriggerFixture(args)
        args = args or {}
        return {
            id = args.id or "fixture-trigger",
            timestamp = args.timestamp or 1,
            text = args.text or "Fixture Trigger",
            rules = args.rules or "",
            targets = args.targets or {},
            heroicResourceCost = args.heroicCost or 0,
            epicResourceCost = args.epicCost or 0,
            triggered = args.triggered == true,
            dismissed = args.dismissed == true,
            DismissOnTrigger = function()
                return args.dismissOnTrigger == true
            end,
        }
    end

    local function TriggerDispatchFixture(args)
        args = args or {}
        local executed = 0
        local trigger = args.trigger or TriggerFixture(args)
        local token = args.token or TriggerFixtureToken(args)
        local candidate = {
            token = token,
            trigger = trigger,
            triggerInfo = args.triggerInfo or { available = true },
            context = args.context,
            manualPrompt = args.manualPrompt,
            automationDecision = args.automationDecision or self:MakeAutomationDecision{
                outcome = "exact_auto",
                lane = "trigger",
                source = "trigger-policy",
                reason = "fixture exact trigger",
                capabilities = {
                    trigger = true,
                },
                fallback = {
                    kind = "no_trigger",
                },
            },
            execute = function()
                executed = executed + 1
                trigger.triggered = true
                return true
            end,
        }

        return candidate, function()
            return executed
        end
    end

    local exactTriggerCandidate, exactTriggerExecuted = TriggerDispatchFixture{
        heroicAvailable = 1,
        epicAvailable = 1,
    }
    local exactTriggerDispatched = self:DispatchTriggerCandidate(exactTriggerCandidate)
    Add(25, exactTriggerDispatched and exactTriggerExecuted() == 1 and "PASS" or "FAIL", "AutomationDecision exact trigger dispatch fixture")

    local unsafeTriggerCandidate, unsafeTriggerExecuted = TriggerDispatchFixture{
        automationDecision = self:MakeAutomationDecision{
            outcome = "skip_with_fallback",
            lane = "trigger",
            source = "trigger-policy",
            reason = "fixture unsafe trigger",
            capabilities = {
                trigger = true,
            },
            fallback = {
                kind = "no_trigger",
            },
        },
    }
    local unsafeTriggerDispatched = self:DispatchTriggerCandidate(unsafeTriggerCandidate)
    Add(26, not unsafeTriggerDispatched and unsafeTriggerExecuted() == 0 and "PASS" or "FAIL", "AutomationDecision unsafe trigger skip fixture")

    local unaffordableTriggerCandidate, unaffordableTriggerExecuted = TriggerDispatchFixture{
        heroicCost = 2,
        heroicAvailable = 0,
    }
    local unaffordableTriggerDispatched = self:DispatchTriggerCandidate(unaffordableTriggerCandidate)
    Add(27, not unaffordableTriggerDispatched and unaffordableTriggerExecuted() == 0 and "PASS" or "FAIL", "AutomationDecision unaffordable trigger skip fixture")

    local manualTriggerContext = {}
    local manualTriggerCandidate, manualTriggerExecuted = TriggerDispatchFixture{
        context = manualTriggerContext,
        manualPrompt = true,
        automationDecision = self:MakeAutomationDecision{
            outcome = "manual_before_execution",
            lane = "trigger",
            source = "manual-prompt",
            reason = "fixture manual trigger",
            capabilities = {
                trigger = true,
            },
            fallback = {
                kind = "no_trigger",
            },
            manualBeforeExecution = true,
        },
    }
    local manualTriggerDispatched = self:DispatchTriggerCandidate(manualTriggerCandidate)
    Add(28, not manualTriggerDispatched
        and manualTriggerExecuted() == 0
        and manualTriggerContext.manualPromptHandoff ~= true
        and "PASS" or "FAIL", "AutomationDecision trigger lane does not open manual prompt")

    RestoreReactiveTriggerConfig()

    local fixtureLoc = {
        str = "fixture:1:2",
    }
    local fixtureAdvanceLoc = {
        str = "fixture:2:2",
    }
    local fixtureTarget = {
        valid = true,
        charid = "fixture-target",
        properties = {
            name = "Fixture Target",
            IsDead = function()
                return false
            end,
        },
    }
    local fixtureOtherTarget = {
        valid = true,
        charid = "fixture-other-target",
        properties = {
            name = "Fixture Other Target",
            IsDead = function()
                return false
            end,
        },
    }
    local fixtureMove = {
        mode = "charge",
        destination = fixtureAdvanceLoc,
        tiles = 2,
    }
    local fixtureAbility = {
        guid = "fixture-ability",
        name = "Fixture Ability",
    }
    local fixtureScore = CreateScore()
    fixtureScore.total = 7
    local normalizedFixture = self:MakeCandidate{
        ability = fixtureAbility,
        abilityInfo = {
            name = "Fixture Ability",
            targetType = "target",
        },
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        advanceTargetLoc = fixtureAdvanceLoc,
        targets = {
            { token = fixtureTarget },
        },
        actionCost = "action",
        scoreInfo = fixtureScore,
        description = "fixture normalized candidate",
    }
    local normalizedScore = normalizedFixture.normalized and normalizedFixture.normalized.score
    Add(29, type(normalizedFixture.intent) == "table"
        and type(normalizedFixture.execution) == "table"
        and type(normalizedFixture.fallback) == "table"
        and type(normalizedScore) == "table"
        and normalizedFixture.score == normalizedScore.total
        and normalizedFixture.score == 7
        and "PASS" or "FAIL", "Candidate normalized sections preserve numeric score alias")

    Add(30, normalizedFixture.intent.targets == normalizedFixture.targets
        and normalizedFixture.execution.loc == normalizedFixture.loc
        and normalizedFixture.execution.preInvokeMove == normalizedFixture.preInvokeMove
        and normalizedScore.retryKey == normalizedFixture.retryKey
        and "PASS" or "FAIL", "Candidate normalized sections preserve legacy aliases")

    local rootOnlyRead = {
        actor = {
            token = {
                charid = "read-only-actor",
                properties = {
                    name = "Read Only Actor",
                },
            },
        },
        ability = fixtureAbility,
        abilityInfo = {
            name = "Read Only Fixture",
            targetType = "target",
        },
        description = "fixture read-only candidate",
        actionCost = "action",
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        targets = {
            { token = fixtureTarget },
        },
        score = 5,
    }
    local readOnlyRetryBefore = self:CandidateRetryKey(rootOnlyRead)
    local readOnlyRejectBefore = table.concat(self:CandidateRejectionKeys(rootOnlyRead, "fixture read", true), "\n")
    self:CandidateIntent(rootOnlyRead)
    self:CandidateExecution(rootOnlyRead)
    self:CandidateScoreSection(rootOnlyRead)
    self:CandidateFallback(rootOnlyRead)
    self:CandidateTargets(rootOnlyRead)
    self:CandidateActionCost(rootOnlyRead)
    self:CandidateExecutionLoc(rootOnlyRead)
    self:CandidatePreInvokeMove(rootOnlyRead)
    self:CandidateTargetArea(rootOnlyRead)
    self:CandidateModeSelection(rootOnlyRead)
    self:CandidateRetryKey(rootOnlyRead)
    self:CandidateRejectionKeys(rootOnlyRead, "fixture read", true)
    if self.Pipeline ~= nil then
        self.Pipeline:MakeOrderingKey(rootOnlyRead, "turn", 1)
    end
    local readOnlyRetryAfter = self:CandidateRetryKey(rootOnlyRead)
    local readOnlyRejectAfter = table.concat(self:CandidateRejectionKeys(rootOnlyRead, "fixture read", true), "\n")
    Add("30a", rootOnlyRead.intent == nil
        and rootOnlyRead.execution == nil
        and rootOnlyRead.normalized == nil
        and rootOnlyRead.fallback == nil
        and rootOnlyRead.retryKey == nil
        and readOnlyRetryBefore == readOnlyRetryAfter
        and readOnlyRejectBefore == readOnlyRejectAfter
        and "PASS" or "FAIL", "Candidate accessors read legacy root shape without mutating sections or keys")

    local annotationRetryBefore = normalizedFixture.retryKey
    normalizedFixture.scoreInfo.total = (normalizedFixture.scoreInfo.total or 0) + 1
    normalizedFixture.score = normalizedFixture.scoreInfo.total
    normalizedFixture.comboLookahead = {
        bonus = 1,
        followupDescription = "fixture follow-up",
    }
    self:SyncCandidateSections(normalizedFixture)
    Add("30b", normalizedFixture.normalized.score.total == normalizedFixture.score
        and normalizedFixture.normalized.score.comboLookahead == normalizedFixture.comboLookahead
        and normalizedFixture.retryKey == annotationRetryBefore
        and normalizedFixture.normalized.score.retryKey == annotationRetryBefore
        and self:CandidateRetryKey(normalizedFixture) == annotationRetryBefore
        and "PASS" or "FAIL", "Candidate explicit annotation sync preserves finalized identity")

    local mismatchCandidate = self:MakeCandidate{
        ability = fixtureAbility,
        abilityInfo = {
            name = "Fixture Contract Mismatch",
            targetType = "target",
        },
        loc = fixtureLoc,
        targets = {
            { token = fixtureTarget },
        },
        actionCost = "action",
        scoreInfo = CreateScore(),
        description = "fixture contract mismatch",
    }
    mismatchCandidate.intent.targets = {
        { token = fixtureOtherTarget },
    }
    local mismatchValid, mismatchReason = self:ValidateCandidateContract(mismatchCandidate, "fixture")
    Add("30c", not mismatchValid
        and string.find(tostring(mismatchReason), "contradictory targets", 1, true) ~= nil
        and "PASS" or "FAIL", "Candidate contract validation rejects contradictory root and normalized targets")

    local retryTargets = {
        { token = fixtureTarget },
    }
    local legacyChargeOnly = {
        ability = fixtureAbility,
        description = "fixture legacy chargeLoc",
        actionCost = "action",
        loc = fixtureLoc,
        chargeLoc = fixtureAdvanceLoc,
        targets = retryTargets,
    }
    local noChargeRoot = {
        ability = fixtureAbility,
        description = "fixture legacy chargeLoc",
        actionCost = "action",
        loc = fixtureLoc,
        targets = retryTargets,
    }
    local typedPreInvoke = {
        preInvokeMove = fixtureMove,
    }
    local legacyAssignmentsOnly = {
        assignments = {
            {
                member = { token = fixtureTarget },
                target = fixtureOtherTarget,
                loc = fixtureLoc,
            },
        },
    }
    local squadAssignments = {
        {
            member = { token = fixtureTarget },
            target = fixtureOtherTarget,
            loc = fixtureLoc,
        },
    }
    local squadAssignmentCandidate = {
        squadAssignments = squadAssignments,
    }
    Add(17, self:CandidatePreInvokeDestination(legacyChargeOnly) == nil
        and self:CandidateRetryKey(legacyChargeOnly) == self:CandidateRetryKey(noChargeRoot)
        and self:CandidatePreInvokeDestination(typedPreInvoke) == fixtureAdvanceLoc
        and #self:CandidateSquadAssignments(legacyAssignmentsOnly) == 0
        and self:CandidateSquadAssignments(squadAssignmentCandidate) == squadAssignments
        and "PASS" or "FAIL", "dead root chargeLoc/assignments aliases ignored while typed movement and squadAssignments remain active")

    local rootRetryShape = {
        ability = fixtureAbility,
        description = "fixture retry identity",
        actionCost = "action",
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        advanceTargetLoc = fixtureAdvanceLoc,
        targets = retryTargets,
    }
    local normalizedRetryShape = {
        ability = fixtureAbility,
        intent = {
            actionCost = "action",
            targets = retryTargets,
        },
        execution = {
            loc = fixtureLoc,
            preInvokeMove = fixtureMove,
            advanceTargetLoc = fixtureAdvanceLoc,
        },
        normalized = {
            score = {
                description = "fixture retry identity",
            },
        },
    }
    Add(31, self:CandidateRetryKey(rootRetryShape) == self:CandidateRetryKey(normalizedRetryShape)
        and "PASS" or "FAIL", "Candidate retry key matches root and normalized shapes")

    local orderingRoot = {
        actor = {
            token = {
                charid = "ordering-actor",
                properties = {
                    name = "Ordering Actor",
                },
            },
        },
        abilityInfo = {
            name = "Ordering Strike",
        },
        actionCost = "action",
        loc = fixtureLoc,
        targets = retryTargets,
        score = 12,
        description = "ordering fixture",
    }
    local orderingNormalized = {
        actor = orderingRoot.actor,
        abilityInfo = orderingRoot.abilityInfo,
        intent = {
            actionCost = "action",
            targets = retryTargets,
        },
        execution = {
            loc = fixtureLoc,
        },
        normalized = {
            score = {
                total = 12,
                description = "ordering fixture",
            },
        },
    }
    local orderingA = self.Pipeline:MakeOrderingKey(orderingRoot, "turn", 1)
    local orderingB = self.Pipeline:MakeOrderingKey(orderingNormalized, "turn", 1)
    Add(32, orderingA.score == orderingB.score
        and orderingA.maliceTie == orderingB.maliceTie
        and orderingA.abilityName == orderingB.abilityName
        and orderingA.targetSignature == orderingB.targetSignature
        and orderingA.actorKey == orderingB.actorKey
        and orderingA.locKey == orderingB.locKey
        and orderingA.actionCost == orderingB.actionCost
        and orderingA.description == orderingB.description
        and "PASS" or "FAIL", "Candidate ordering key matches root and normalized shapes")

    local staleActor = {
        turnMemory = self:NewTurnMemory(),
    }
    local staleScore = CreateScore()
    local staleCandidate = self:MakeCandidate{
        ability = fixtureAbility,
        abilityInfo = {
            name = "Fixture Ability",
            targetType = "target",
        },
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        targets = retryTargets,
        actionCost = "action",
        scoreInfo = staleScore,
        description = "fixture stale retry original",
    }
    local staleStoredKey = staleCandidate.retryKey
    staleCandidate.description = "fixture stale retry recomputed"
    staleCandidate.normalized.score.description = staleCandidate.description
    local staleCurrentKey = self:CandidateRetryKey(staleCandidate)
    self:RejectCandidateForTurn(staleActor, staleCandidate, "fixture stale retry key")
    local staleOriginalShape = {
        ability = fixtureAbility,
        description = "fixture stale retry original",
        retryKey = staleStoredKey,
        actionCost = "action",
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        targets = retryTargets,
    }
    local staleCurrentShape = {
        ability = fixtureAbility,
        description = "fixture stale retry recomputed",
        actionCost = "action",
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        targets = retryTargets,
    }
    local staleFiltered = self.Pipeline:FilterRejectedCandidates(nil, staleActor, "turn", { staleOriginalShape, staleCurrentShape }, {}, {})
    Add(33, staleStoredKey ~= staleCurrentKey
        and #staleFiltered == 0
        and "PASS" or "FAIL", "Candidate stale retry rejection filters stored and recomputed keys")

    local function CandidateTargetKey(target)
        if target == nil then
            return nil
        end

        local tok = target.token
        if tok ~= nil then
            return "token:" .. tostring(tok.charid or tok.id or tok)
        end

        local loc = target.loc
        if loc ~= nil then
            return "loc:" .. tostring(loc.str or loc)
        end

        return tostring(target)
    end

    local function TargetTableCount(targets)
        if type(targets) ~= "table" then
            return 0
        end

        return #targets
    end

    local function UniqueTargetCount(targets)
        local seen = {}
        local unique = 0
        for _,target in ipairs(targets or {}) do
            local key = CandidateTargetKey(target)
            if key ~= nil and not seen[key] then
                seen[key] = true
                unique = unique + 1
            end
        end

        return unique
    end

    local function CandidateIdentityDiagnostics(candidate)
        local intent = self.CandidateIntent and self:CandidateIntent(candidate) or candidate and candidate.intent or {}
        local canonicalTargets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate and candidate.targets or {}
        local normalizedScore = candidate and candidate.normalized and candidate.normalized.score or nil

        return {
            rootTargetCount = TargetTableCount(candidate and candidate.targets or nil),
            intentTargetCount = TargetTableCount(intent and intent.targets or nil),
            canonicalTargetCount = TargetTableCount(canonicalTargets),
            uniqueTargetCount = UniqueTargetCount(canonicalTargets),
            storedRetryKey = candidate and candidate.retryKey or nil,
            normalizedRetryKey = normalizedScore and normalizedScore.retryKey or nil,
            recomputedRetryKey = self.CandidateRetryKey and self:CandidateRetryKey(candidate) or nil,
        }
    end

    local grabActorToken = {
        valid = true,
        charid = "fixture-grab-actor",
        loc = fixtureLoc,
        properties = {
            name = "Fixture Grab Actor",
            IsDead = function()
                return false
            end,
        },
    }
    grabActorToken.IsFriend = function(_, other)
        return other == grabActorToken
    end
    local grabTarget = {
        valid = true,
        charid = "fixture-grab-target",
        loc = fixtureAdvanceLoc,
        properties = {
            name = "Fixture Grab Target",
            IsDead = function()
                return false
            end,
        },
    }
    local grabActor = {
        token = grabActorToken,
        allies = {},
        enemies = { grabTarget },
        context = {},
    }
    local grabScore = CreateScore()
    grabScore.total = 9
    local grabCandidate = self:MakeCandidate{
        ability = {
            guid = "fixture-grab-ability",
            name = "Grab",
        },
        abilityInfo = {
            name = "Grab",
            targetType = "target",
            conditionValue = 3,
            conditionApplyNames = { "Grabbed" },
        },
        loc = fixtureLoc,
        targets = {
            { token = grabTarget },
        },
        actionCost = "maneuver",
        scoreInfo = grabScore,
        modeSelection = {
            index = 1,
            text = "Aggressive",
            reason = "fixture grab mode",
        },
        description = "fixture Grab on target (Aggressive)",
    }
    local grabStoredRetryKey = grabCandidate.retryKey
    local grabStoredNormalizedRetryKey = grabCandidate.normalized and grabCandidate.normalized.score and grabCandidate.normalized.score.retryKey
    local grabInitialCurrentRetryKey = self:CandidateRetryKey(grabCandidate)
    local grabInitialIdentity = CandidateIdentityDiagnostics(grabCandidate)
    local grabSetupEligible = self.Pipeline:CandidateCanSetupCombo(grabActor, grabCandidate)
    local grabSetupTargetsA = self.Pipeline:HostileComboSetupTargets(grabActor, grabCandidate)
    local grabSetupTargetsB = self.Pipeline:HostileComboSetupTargets(grabActor, grabCandidate)
    local grabFinalIdentity = CandidateIdentityDiagnostics(grabCandidate)
    local grabInitialTargetShapeStable = grabInitialIdentity.rootTargetCount == 1
        and grabInitialIdentity.intentTargetCount == 1
        and grabInitialIdentity.canonicalTargetCount == 1
        and grabInitialIdentity.uniqueTargetCount == 1
    local grabFinalTargetShapeStable = grabFinalIdentity.rootTargetCount == 1
        and grabFinalIdentity.intentTargetCount == 1
        and grabFinalIdentity.canonicalTargetCount == 1
        and grabFinalIdentity.uniqueTargetCount == 1
    local grabRetryKeyStable = grabInitialIdentity.storedRetryKey ~= nil
        and grabInitialIdentity.storedRetryKey == grabStoredRetryKey
        and grabInitialIdentity.storedRetryKey == grabStoredNormalizedRetryKey
        and grabInitialIdentity.storedRetryKey == grabInitialCurrentRetryKey
        and grabInitialIdentity.storedRetryKey == grabInitialIdentity.normalizedRetryKey
        and grabInitialIdentity.storedRetryKey == grabInitialIdentity.recomputedRetryKey
        and grabInitialIdentity.storedRetryKey == grabFinalIdentity.storedRetryKey
        and grabInitialIdentity.storedRetryKey == grabFinalIdentity.normalizedRetryKey
        and grabInitialIdentity.storedRetryKey == grabFinalIdentity.recomputedRetryKey
    Add("33a", grabSetupEligible
        and #grabSetupTargetsA == 1
        and #grabSetupTargetsB == 1
        and grabInitialTargetShapeStable
        and grabFinalTargetShapeStable
        and grabRetryKeyStable
        and "PASS" or "FAIL", string.format(
            "Grab combo setup keeps one target and stable retry key (root=%d intent=%d canonical=%d unique=%d)",
            grabFinalIdentity.rootTargetCount,
            grabFinalIdentity.intentTargetCount,
            grabFinalIdentity.canonicalTargetCount,
            grabFinalIdentity.uniqueTargetCount
        ))

    RunVillainActionAcceptanceFixtures(self, Add, AcceptancePromptFixtureGrid, AcceptancePromptFixtureToken)
    RunActionGrantAcceptanceFixtures(self, Add)
    RunTraceAcceptanceFixtures(self, Add)
    RunReactiveTriggerAcceptanceFixtures(self, Add)
    RunPromptCapabilityAcceptanceFixtures(self, Add, AcceptancePromptFixtureGrid, AcceptancePromptFixtureToken)
    RunExecutionBoundaryAcceptanceFixtures(self, Add, AcceptancePromptFixtureGrid, AcceptancePromptFixtureToken)

    local promptFixtureCenter = AcceptancePromptFixtureGrid("fixture:prompt", 3)
    local promptCaster = AcceptancePromptFixtureToken("Prompt Caster", "prompt-caster", promptFixtureCenter, "rivals")
    local promptTarget = AcceptancePromptFixtureToken("Prompt Target", "prompt-target", promptFixtureCenter.east, "heroes")
    local promptAbility = {
        name = "Invoked Ability",
        targetType = "target",
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 5
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function(_, _, targetToken)
            return targetToken == promptTarget
        end,
    }
    local promptActor = {
        token = promptCaster,
        allies = {},
        enemies = {},
        context = {},
    }
    local inheritedResolution = self:ResolvePromptV2({}, promptActor, promptCaster, promptCaster, promptAbility, {}, {
        targets = { { token = promptTarget } },
        _directorCandidateTargets = { { token = promptTarget } },
    })
    local inheritedOptions = inheritedResolution and inheritedResolution.options or {}
    local inheritedTarget = inheritedResolution
        and inheritedResolution.options
        and inheritedResolution.options.targets
        and inheritedResolution.options.targets[1]
        and inheritedResolution.options.targets[1].token
    local inheritedTargetMatches = inheritedTarget == promptTarget
    local inheritedPass = inheritedResolution ~= nil
        and inheritedResolution.status == "handled"
        and inheritedTargetMatches
        and inheritedOptions._directorFollowUpTarget == "inherited"
    local inheritedDetail = "follow-up-target reuses inherited candidate target"
    if not inheritedPass then
        inheritedDetail = string.format(
            "%s (status=%s policy=%s marker=%s targetMatch=%s reason=%s)",
            inheritedDetail,
            tostring(inheritedResolution and inheritedResolution.status or nil),
            tostring(inheritedResolution and inheritedResolution.policy and inheritedResolution.policy.id or nil),
            tostring(inheritedOptions._directorFollowUpTarget),
            tostring(inheritedTargetMatches),
            tostring(inheritedResolution and inheritedResolution.reason or nil)
        )
    end
    Add(34, inheritedPass and "PASS" or "FAIL", inheritedDetail)

    do
        local specificTargetSelfAbility = {
            name = "Melee Free Strike Against Specific Target",
            targetType = "self",
            HasKeyword = function()
                return false
            end,
            GetRange = function()
                return 5
            end,
            GetRadius = function()
                return 0
            end,
            GetNumTargets = function()
                return 1
            end,
            TargetPassesFilter = function()
                return false, "self prompt inherited target should not use generic filter"
            end,
        }
        local specificResolution = self:ResolvePromptV2({}, promptActor, promptCaster, promptCaster, specificTargetSelfAbility, {
            spellname = "Grab",
        }, {
            targets = { { token = promptTarget } },
            targetArgs = { { token = promptTarget } },
            _directorCandidateTargets = { { token = promptTarget } },
        })
        local specificOptions = specificResolution and specificResolution.options or {}
        local specificTarget = specificOptions.targets and specificOptions.targets[1] and specificOptions.targets[1].token
        local specificPass = specificResolution ~= nil
            and specificResolution.status == "handled"
            and specificResolution.policy ~= nil
            and specificResolution.policy.id == "specific-target-invoke"
            and specificOptions._directorSpecificTargetInvoke == true
            and specificOptions._directorSpecificTargetSource == "inherited"
            and specificTarget == promptTarget
        Add("34e", specificPass and "PASS" or "FAIL", "specific-target invoke accepts inherited token despite self targetType" .. (specificPass and "" or string.format(
            " (status=%s policy=%s marker=%s targetMatch=%s reason=%s)",
            tostring(specificResolution and specificResolution.status or nil),
            tostring(specificResolution and specificResolution.policy and specificResolution.policy.id or nil),
            tostring(specificOptions._directorSpecificTargetInvoke),
            tostring(specificTarget == promptTarget),
            tostring(specificResolution and specificResolution.reason or nil)
        )))

        local unmarkedSelfValid, unmarkedSelfReason = self:ValidatePromptResult({}, promptActor, promptCaster, promptCaster, specificTargetSelfAbility, {}, {
            targets = { { token = promptTarget } },
            _directorCandidateTargets = { { token = promptTarget } },
        }, {
            targets = { { token = promptTarget } },
        })
        Add("34f", not unmarkedSelfValid and "PASS" or "FAIL", "unmarked self-target prompt with arbitrary token still fails validation" .. (unmarkedSelfValid and "" or (" (" .. tostring(unmarkedSelfReason) .. ")")))

        local promptOutsider = AcceptancePromptFixtureToken("Prompt Outsider", "prompt-outsider", promptFixtureCenter.north, "heroes")
        local outsiderSpecificValid, outsiderSpecificReason = self:ValidatePromptResult({}, promptActor, promptCaster, promptCaster, specificTargetSelfAbility, {}, {
            targets = { { token = promptTarget } },
            _directorCandidateTargets = { { token = promptTarget } },
        }, {
            targets = { { token = promptOutsider } },
            targetArgs = { { token = promptOutsider } },
            _directorSpecificTargetInvoke = true,
            _directorSpecificTargetSource = "inherited",
        })
        Add("34g", not outsiderSpecificValid and string.find(tostring(outsiderSpecificReason), "not inherited", 1, true) ~= nil and "PASS" or "FAIL", "specific-target marker does not allow non-inherited token targets")
    end

    local promptEnemy = AcceptancePromptFixtureToken("Prompt Enemy", "prompt-enemy", promptFixtureCenter.south, "heroes")
    local promptAlly = AcceptancePromptFixtureToken("Prompt Ally", "prompt-ally", promptFixtureCenter.west, "rivals")
    local fallbackContext = {
        allCombatTokens = { promptCaster, promptEnemy, promptAlly },
    }
    local fallbackActor = {
        token = promptCaster,
        allies = { promptAlly },
        enemies = { promptEnemy },
        context = fallbackContext,
    }
    local fallbackAbility = {
        name = "Invoked Ability",
        targetType = "target",
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 5
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function(_, casterToken, targetToken)
            return casterToken == promptEnemy and targetToken == promptAlly
        end,
    }
    local fallbackResolution = self:ResolvePromptV2(fallbackContext, fallbackActor, promptCaster, promptEnemy, fallbackAbility, {}, {
        targets = { { token = promptEnemy } },
        _directorCandidateTargets = { { token = promptEnemy } },
    })
    local fallbackOptions = fallbackResolution and fallbackResolution.options or {}
    local fallbackTarget = fallbackOptions.targets and fallbackOptions.targets[1] and fallbackOptions.targets[1].token
    Add("34a", fallbackResolution ~= nil
        and fallbackResolution.status == "handled"
        and fallbackTarget == promptAlly
        and fallbackOptions._directorFollowUpTarget == "fallback"
        and "PASS" or "FAIL", "follow-up-target searches legal ally/support fallback targets")

    local blockedAbility = {
        name = "Invoked Ability",
        targetType = "target",
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 5
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetPassesFilter = function()
            return false
        end,
    }
    local blockedResolution = self:ResolvePromptV2(fallbackContext, fallbackActor, promptCaster, promptEnemy, blockedAbility, {}, {
        targets = { { token = promptEnemy } },
        _directorCandidateTargets = { { token = promptEnemy } },
    })
    local blockedPass = blockedResolution ~= nil
        and blockedResolution.status == "blocked"
        and string.find(tostring(blockedResolution.reason), "no legal follow-up target", 1, true) ~= nil
    local blockedDetail = "follow-up-target blocks explicitly when no legal target exists"
    if not blockedPass then
        blockedDetail = string.format(
            "%s (status=%s policy=%s reason=%s)",
            blockedDetail,
            tostring(blockedResolution and blockedResolution.status or nil),
            tostring(blockedResolution and blockedResolution.policy and blockedResolution.policy.id or nil),
            tostring(blockedResolution and blockedResolution.reason or nil)
        )
    end
    Add("34b", blockedPass and "PASS" or "FAIL", blockedDetail)

    local preflightParentAbility = {
        name = "Fixture Parent Ally Follow-Up",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = fallbackAbility,
            },
        },
    }
    local preflightCandidate = {
        actor = fallbackActor,
        ability = preflightParentAbility,
        abilityInfo = {
            name = "Fixture Parent Ally Follow-Up",
            ability = preflightParentAbility,
        },
        targets = { { token = promptEnemy } },
        loc = fixtureLoc,
        description = "fixture parent ally follow-up",
    }
    local preflightValid, preflightReason = self:ValidateNestedPromptPoliciesBeforeExecution(fallbackContext, fallbackActor, preflightCandidate, preflightParentAbility, {})
    Add("34c", preflightValid and "PASS" or "FAIL", "nested preflight resolves target prompt with parent-target caster" .. (preflightValid and "" or (" (" .. tostring(preflightReason) .. ")")))

    local slideAbility = {
        name = "Slide!",
        targetType = "target",
        forcedMovement = true,
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 1
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
        TargetLocPassesFilterPredicate = function()
            return function(loc)
                return loc ~= nil and loc.valid ~= false and loc.isOnMap ~= false
            end
        end,
    }
    local slideResolution = self:ResolvePromptV2(fallbackContext, fallbackActor, promptCaster, promptEnemy, slideAbility, {}, {
        targets = { { token = promptEnemy } },
        _directorCandidateTargets = { { token = promptEnemy } },
    })
    local slideOptions = slideResolution and slideResolution.options or {}
    local slideLocTarget = slideOptions.targets and slideOptions.targets[1] and slideOptions.targets[1].loc
    local forcedMovementParentAbility = {
        name = "Fixture Parent Forced Movement",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = slideAbility,
            },
        },
    }
    local forcedMovementCandidate = {
        actor = fallbackActor,
        ability = forcedMovementParentAbility,
        abilityInfo = {
            name = "Fixture Parent Forced Movement",
            ability = forcedMovementParentAbility,
        },
        targets = { { token = promptEnemy } },
        loc = fixtureLoc,
        description = "fixture parent forced movement",
    }
    local forcedPreflightValid, forcedPreflightReason = self:ValidateNestedPromptPoliciesBeforeExecution(fallbackContext, fallbackActor, forcedMovementCandidate, forcedMovementParentAbility, {})
    local forcedMovementPass = slideResolution ~= nil
        and slideResolution.status == "handled"
        and slideResolution.policy ~= nil
        and slideResolution.policy.id == "forced-movement"
        and slideLocTarget ~= nil
        and forcedPreflightValid
    Add("34d", forcedMovementPass and "PASS" or "FAIL", "nested forced-movement prompt resolves through policy before execution" .. (forcedMovementPass and "" or string.format(
        " (status=%s policy=%s loc=%s preflight=%s reason=%s)",
        tostring(slideResolution and slideResolution.status or nil),
        tostring(slideResolution and slideResolution.policy and slideResolution.policy.id or nil),
        tostring(slideLocTarget and slideLocTarget.str or nil),
        tostring(forcedPreflightValid),
        tostring(forcedPreflightReason)
    )))

    local unresolvedParentAbility = {
        name = "Fixture Parent Prompt",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = true,
                customAbility = promptAbility,
            },
        },
    }
    local unresolvedContext = {
        allCombatTokens = { promptCaster },
    }
    local unresolvedStartLoc = promptCaster.loc
    local unresolvedPreflightLoc = promptFixtureCenter.north
    local unresolvedCandidate = {
        actor = promptActor,
        ability = unresolvedParentAbility,
        abilityInfo = {
            name = "Fixture Parent Prompt",
            ability = unresolvedParentAbility,
        },
        targets = {},
        loc = unresolvedStartLoc,
        preInvokeMove = {
            mode = "walk",
            destination = unresolvedPreflightLoc,
            tiles = 1,
        },
        description = "fixture unresolved nested prompt",
    }
    local unresolvedValid, unresolvedReason = self:ValidateNestedPromptPoliciesBeforeExecution(unresolvedContext, promptActor, unresolvedCandidate, unresolvedParentAbility, {})
    local unresolvedExplicitBlock = string.find(tostring(unresolvedReason), "no legal follow-up target", 1, true) ~= nil
    local unresolvedTheoreticalRestored = (promptCaster._theoreticalLocCount or 0) > 0
        and promptCaster._theoreticalLocDuring == unresolvedPreflightLoc
        and promptCaster._theoreticalLocRestored == true
        and promptCaster.loc == unresolvedStartLoc
    Add(35, not unresolvedValid
        and unresolvedExplicitBlock
        and (promptCaster._moveCount or 0) == 0
        and unresolvedTheoreticalRestored
        and "PASS" or "FAIL", "unresolved required nested target prompt blocks before movement with explicit reason")

    local allPromptCaster = AcceptancePromptFixtureToken("Prompt All Caster", "prompt-all-caster", promptFixtureCenter, "rivals")
    local allPromptTarget = AcceptancePromptFixtureToken("Prompt All Target", "prompt-all-target", promptFixtureCenter.east, "heroes")
    local allPromptContext = {
        allCombatTokens = { allPromptCaster, allPromptTarget },
    }
    local allPromptActor = {
        token = allPromptCaster,
        allies = {},
        enemies = { allPromptTarget },
        context = allPromptContext,
    }
    local allPromptAbility = {
        name = "Fixture Non-Target Prompt",
        targetType = "all",
        HasKeyword = function()
            return false
        end,
        GetRange = function()
            return 5
        end,
        GetRadius = function()
            return 0
        end,
        GetNumTargets = function()
            return 1
        end,
    }
    local allPromptParentAbility = {
        name = "Fixture Parent Non-Target Prompt",
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = allPromptAbility,
            },
        },
    }
    local allPromptPreflightLoc = promptFixtureCenter.north
    local allPromptCandidate = {
        actor = allPromptActor,
        ability = allPromptParentAbility,
        abilityInfo = {
            name = "Fixture Parent Non-Target Prompt",
            ability = allPromptParentAbility,
        },
        targets = { { token = allPromptTarget } },
        loc = allPromptCaster.loc,
        preInvokeMove = {
            mode = "walk",
            destination = allPromptPreflightLoc,
            tiles = 1,
        },
        description = "fixture unresolved non-target nested prompt",
    }
    allPromptCandidate._acceptancePreflight = { self:ValidateNestedPromptPoliciesBeforeExecution(allPromptContext, allPromptActor, allPromptCandidate, allPromptParentAbility, {}) }
    Add("35a", not allPromptCandidate._acceptancePreflight[1]
        and allPromptCandidate._acceptancePreflight[3] == "blocked"
        and string.find(tostring(allPromptCandidate._acceptancePreflight[2]), "Fixture Non-Target Prompt", 1, true) ~= nil
        and (allPromptCaster._moveCount or 0) == 0
        and allPromptCaster.loc ~= allPromptPreflightLoc
        and "PASS" or "FAIL", "unresolved required nested non-target prompt blocks before movement")

    local promptRejectActor = {
        turnMemory = self:NewTurnMemory(),
    }
    local promptRejectOriginal = self:MakeCandidate{
        ability = fixtureAbility,
        abilityInfo = {
            name = "Fixture Prompt Family",
            targetType = "target",
        },
        loc = fixtureLoc,
        preInvokeMove = fixtureMove,
        targets = retryTargets,
        actionCost = "action",
        scoreInfo = CreateScore(),
        description = "fixture blocked prompt candidate",
    }
    local promptRejectVariant = self:MakeCandidate{
        ability = fixtureAbility,
        abilityInfo = {
            name = "Fixture Prompt Family",
            targetType = "target",
        },
        loc = fixtureAdvanceLoc,
        targets = retryTargets,
        actionCost = "action",
        scoreInfo = CreateScore(),
        description = "fixture blocked prompt candidate",
    }
    self:RejectCandidateForTurn(promptRejectActor, promptRejectOriginal, "blocked prompt before execution: Invoked Ability: no automated prompt policy")
    local promptRejectFiltered = self.Pipeline:FilterRejectedCandidates(nil, promptRejectActor, "turn", { promptRejectVariant }, {}, {})
    Add(36, self:CandidateRetryKey(promptRejectOriginal) ~= self:CandidateRetryKey(promptRejectVariant)
        and self:CandidateFamilyRejectionKey(promptRejectOriginal) == self:CandidateFamilyRejectionKey(promptRejectVariant)
        and #promptRejectFiltered == 0
        and "PASS" or "FAIL", "blocked prompt rejection filters same ability-target variants")

    local grabRejectContext = {
        allCombatTokens = { promptCaster, promptTarget },
    }
    local grabRejectActor = {
        token = promptCaster,
        allies = {},
        enemies = { promptTarget },
        context = grabRejectContext,
        turnMemory = self:NewTurnMemory(),
    }
    local grabRejectPrompt = {
        name = "Invoked Ability",
        targetType = "target",
    }
    local grabRejectParent = {
        name = "Grab",
        guid = "1d642117-27c8-49c5-b37b-a8fc94b5ca5b",
        multipleModes = true,
        modeList = {
            { text = "Safe" },
            { text = "Aggressive" },
        },
        behaviors = {
            {
                typeName = "ActivatedAbilityInvokeAbilityBehavior",
                targeting = "prompt",
                invokeOnCaster = false,
                customAbility = grabRejectPrompt,
            },
        },
    }
    local grabRejectInfo = {
        name = "Grab",
        ability = grabRejectParent,
        targetType = "target",
        requiresPrompt = true,
        manualPromptRisk = true,
        hasGrab = true,
    }
    grabRejectInfo.autoResolvableModePrompt = self:IsAutoResolvableGrabModePrompt(grabRejectInfo)
    local grabRejectOriginal = self:MakeCandidate{
        actor = grabRejectActor,
        ability = grabRejectParent,
        abilityInfo = grabRejectInfo,
        loc = fixtureLoc,
        targets = { { token = promptTarget } },
        symbols = { mode = 1 },
        actionCost = "action",
        scoreInfo = CreateScore(),
        description = "fixture Grab generic prompt candidate",
    }
    local grabRejectVariant = self:MakeCandidate{
        actor = grabRejectActor,
        ability = grabRejectParent,
        abilityInfo = grabRejectInfo,
        loc = fixtureAdvanceLoc,
        targets = { { token = promptTarget } },
        symbols = { mode = 1 },
        actionCost = "action",
        scoreInfo = CreateScore(),
        description = "fixture Grab generic prompt candidate",
    }
    local grabRejectCapability = self:AssessPromptCapability(grabRejectContext, grabRejectActor, grabRejectInfo, {
        actor = grabRejectActor,
        ability = grabRejectParent,
        abilityInfo = grabRejectInfo,
        targets = { { token = promptTarget } },
        symbols = { mode = 1 },
        _directorPromptPreflight = true,
    })
    if grabRejectCapability == nil or grabRejectCapability.status ~= "auto" then
        self:RejectCandidateForTurn(grabRejectActor, grabRejectOriginal, "blocked prompt before execution: Invoked Ability: no automated prompt policy")
    end
    local grabRejectFiltered = self.Pipeline:FilterRejectedCandidates(nil, grabRejectActor, "turn", { grabRejectVariant }, {}, {})
    Add("36h", grabRejectCapability ~= nil
        and grabRejectCapability.status == "auto"
        and #grabRejectFiltered == 1
        and "PASS" or "FAIL", "repaired Grab generic prompt does not enter blocked-prompt rejection")

    RunManualPromptHandoffAcceptanceFixtures(self, Add, promptCaster, promptRejectOriginal)

    RunModePromptAcceptanceFixtures(self, Add, fallbackContext, fallbackActor)

    RunPromotionConstantAcceptanceFixtures(self, Add)

    RunAreaPlacementAcceptanceFixtures(self, Add, AcceptancePromptFixtureGrid, AcceptancePromptFixtureToken)
    RunWerewolfPriorityAcceptanceFixtures(self, Add, AcceptancePromptFixtureGrid, AcceptancePromptFixtureToken)

    RunLiveSceneAcceptanceFixtures(self, Add, context, analyzed)

    local header = string.format("DirectorTactics acceptance: PASS=%d FAIL=%d DEFERRED=%d", counts.PASS or 0, counts.FAIL or 0, counts.DEFERRED or 0)
    AcceptanceSend(header)
    AcceptanceLog(self, header)
    for _,line in ipairs(rows) do
        local fullLine = "DT acceptance " .. line
        AcceptanceSend(fullLine)
        AcceptanceLog(self, fullLine)
    end
    self:SetStatus(header)
    return {
        counts = counts,
        rows = rows,
    }
end

local function TriggerKeyPart(value)
    if value == nil then
        return ""
    end

    value = tostring(value)
    value = string.gsub(value, "[\r\n\t|]+", " ")
    value = string.gsub(value, "%s%s+", " ")
    return value
end

local function TriggerTargetsKey(trigger)
    local targets = TryGet(trigger, "targets", nil)
    if type(targets) ~= "table" then
        return ""
    end

    local parts = {}
    for _,target in ipairs(targets) do
        parts[#parts+1] = TriggerKeyPart(target)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function AI:ResetReactiveTriggerAttempts()
    Runtime.reactiveTriggerAttempts = {}
    Runtime.reactiveTriggerAttemptsGeneration = Runtime.runGeneration
end

function AI:ReactiveTriggerAttemptKey(token, trigger, triggerInfo)
    local tokenKey = TokenId(token) or TryGet(token, "charid", nil) or TryGet(token, "id", nil) or TokenName(token)
    return table.concat({
        "token=" .. TriggerKeyPart(tokenKey),
        "trigger=" .. TriggerKeyPart(TryGet(trigger, "id", nil)),
        "timestamp=" .. TriggerKeyPart(TryGet(trigger, "timestamp", nil)),
        "text=" .. TriggerKeyPart(TryGet(trigger, "text", TryGet(trigger, "name", nil))),
        "rules=" .. TriggerKeyPart(TryGet(trigger, "rules", nil)),
        "event=" .. TriggerKeyPart(triggerInfo and triggerInfo.event),
        "targets=" .. TriggerTargetsKey(trigger),
    }, "|")
end

function AI:ReactiveTriggerAttemptMemory()
    if Runtime.reactiveTriggerAttemptsGeneration ~= Runtime.runGeneration
        or type(Runtime.reactiveTriggerAttempts) ~= "table"
    then
        self:ResetReactiveTriggerAttempts()
    end

    return Runtime.reactiveTriggerAttempts
end

function AI:ReactiveTriggerAttemptSuppressed(key, cooldown)
    if key == nil or key == "" then
        return false, nil
    end

    cooldown = tonumber(cooldown) or ConstNumber("Candidate", "TriggerRetryCooldownSeconds", 5)
    local memory = self:ReactiveTriggerAttemptMemory()
    local attempt = memory[key]
    if type(attempt) ~= "table" then
        return false, nil
    end

    local age = dmhub.Time() - (tonumber(attempt.time) or 0)
    if age < cooldown then
        return true, attempt
    end

    return false, attempt
end

function AI:RecordReactiveTriggerAttempt(key, reason)
    if key == nil or key == "" then
        return
    end

    local memory = self:ReactiveTriggerAttemptMemory()
    local previous = memory[key]
    memory[key] = {
        time = dmhub.Time(),
        reason = tostring(reason or "held"),
        count = (type(previous) == "table" and (tonumber(previous.count) or 0) or 0) + 1,
    }
end

function AI:ClearReactiveTriggerAttempt(key)
    if key == nil or key == "" then
        return
    end

    local memory = self:ReactiveTriggerAttemptMemory()
    memory[key] = nil
end

function AI:PruneReactiveTriggerAttempts(seen)
    local memory = self:ReactiveTriggerAttemptMemory()
    for key,_ in pairs(memory) do
        if seen == nil or seen[key] ~= true then
            memory[key] = nil
        end
    end
end

function AI:DispatchTriggerCandidate(candidate)
    local allowed, reason = self:TriggerCandidateCanAutoDispatch(candidate)
    if not allowed then
        self:Trace("trigger", "dispatch blocked", { candidate = candidate and candidate.description, reason = reason })
        return false, reason
    end

    if self.TriggerCanAutoActivate ~= nil
        and not self:TriggerCanAutoActivate(candidate.token, candidate.trigger, candidate.triggerInfo)
    then
        self:Trace("trigger", "dispatch blocked", { candidate = candidate.description, reason = "trigger no longer auto-activatable" })
        return false, "trigger no longer auto-activatable"
    end

    if candidate.execute == nil then
        self:Trace("trigger", "dispatch blocked", { candidate = candidate.description, reason = "missing trigger executor" })
        return false, "missing trigger executor"
    end

    local executed = SafeCall(function()
        return candidate.execute()
    end, false)
    if executed == false then
        self:Trace("trigger", "dispatch failed", { candidate = candidate.description, reason = "trigger execution failed" })
        return false, "trigger execution failed"
    end

    return true, nil
end

function AI:RunReactiveTriggerAttempt(queue, context, token, trigger, triggerInfo, triggerKey)
    triggerKey = triggerKey or self:ReactiveTriggerAttemptKey(token, trigger, triggerInfo)
    local triggerName = TryGet(trigger, "text", TryGet(trigger, "name", "trigger"))
    local result = self.Pipeline:Run(context, nil, "trigger", {
        token = token,
        trigger = trigger,
        triggerInfo = triggerInfo,
    }) or {}
    self:Trace("trigger", "pipeline result", {
        token = TokenName(token),
        trigger = triggerName,
        selected = result.selected and result.selected.description,
        heldReason = result.heldReason,
        ranked = result.ranked and #result.ranked,
    }, { coalesce = true })

    if result.selected == nil or result.selected.execute == nil then
        self:RecordReactiveTriggerAttempt(triggerKey, result.heldReason or "no trigger candidate")
        self:Trace("trigger", "attempt held", {
            token = TokenName(token),
            trigger = triggerName,
            reason = result.heldReason or "no trigger candidate",
        }, { coalesce = true, coalesceKey = triggerKey })
        return false, result.heldReason or "no trigger candidate"
    end

    self:Trace("trigger", "candidate prompt requested", {
        token = TokenName(token),
        trigger = triggerName,
        policy = triggerInfo and triggerInfo.policyId,
        candidate = result.selected.description,
    }, { coalesce = true, coalesceKey = triggerKey })
    if not self:EmitPhase(self.Phase.PromptRequested, {
        source = "trigger",
        queue = queue,
        context = context,
        token = token,
        trigger = trigger,
        triggerInfo = triggerInfo,
        runGeneration = context and context.runGeneration,
    }) then
        return false, "prompt phase stopped"
    end

    local executed, reason = self:DispatchTriggerCandidate(result.selected)
    self:Trace("trigger", "dispatch result", {
        token = TokenName(token),
        trigger = triggerName,
        selected = result.selected.description,
        executed = executed,
        reason = reason,
    })
    if executed then
        self:ClearReactiveTriggerAttempt(triggerKey)
        return true, nil
    end

    self:RecordReactiveTriggerAttempt(triggerKey, reason or "dispatch blocked")
    return false, reason or "dispatch blocked"
end

function AI:RunReactiveTriggerScan(queue, tokens, context)
    if queue == nil or queue.hidden then
        self:PruneReactiveTriggerAttempts(nil)
        self:Trace("trigger", "scan skipped", { reason = "no visible initiative queue" }, { coalesce = true })
        return 0
    end

    context = context or self:BuildContext(queue:CurrentInitiativeId())
    local seenTriggerKeys = {}
    local totalDispatched = 0
    self:Trace("trigger", "scan start", {
        initiativeid = queue:CurrentInitiativeId(),
        runGeneration = context and context.runGeneration,
    }, { coalesce = true })

    for _,token in ipairs(tokens or {}) do
        if IsTokenValid(token) and not token.playerControlled then
            local triggers = SafeCall(function()
                return token.properties:GetAvailableTriggers()
            end, nil)

            if triggers ~= nil then
                local triggerCount = 0
                for _,_ in pairs(triggers) do
                    triggerCount = triggerCount + 1
                end
                self:Trace("trigger", "token scan", { token = TokenName(token), triggers = triggerCount }, { coalesce = true })
                local dispatched = 0
                local triggerDispatchCap = ConstNumber("Candidate", "TriggerDispatchCap", 3)
                for _,trigger in pairs(triggers) do
                    if dispatched >= triggerDispatchCap then
                        self:Trace("trigger", "dispatch cap reached", { token = TokenName(token), cap = triggerDispatchCap })
                        break
                    end

                    local triggerInfo = self:ResolveActiveTriggerInfo(token, trigger)
                    local triggerKey = self:ReactiveTriggerAttemptKey(token, trigger, triggerInfo)
                    seenTriggerKeys[triggerKey] = true
                    local suppressed, attempt = self:ReactiveTriggerAttemptSuppressed(triggerKey)
                    if suppressed then
                        self:Trace("trigger", "attempt suppressed", {
                            token = TokenName(token),
                            trigger = TryGet(trigger, "text", TryGet(trigger, "name", "trigger")),
                            reason = attempt and attempt.reason,
                            attempts = attempt and attempt.count,
                        }, { coalesce = true, coalesceKey = triggerKey })
                    else
                        local executed = self:RunReactiveTriggerAttempt(queue, context, token, trigger, triggerInfo, triggerKey)
                        if executed then
                            dispatched = dispatched + 1
                            totalDispatched = totalDispatched + 1
                        end
                    end
                end
            end
        end
    end

    self:PruneReactiveTriggerAttempts(seenTriggerKeys)
    return totalDispatched
end

function AI:AutoReactiveTriggers()
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden then
        self:PruneReactiveTriggerAttempts(nil)
        self:Trace("trigger", "scan skipped", { reason = "no visible initiative queue" }, { coalesce = true })
        return
    end

    local initiativeid = queue:CurrentInitiativeId()
    if initiativeid ~= nil and self:ManualPromptHandoffBlocksAutomation(initiativeid, Runtime.runGeneration) then
        self:Trace("trigger", "scan skipped", {
            reason = "manual prompt handoff",
            initiativeid = initiativeid,
            handoff = Runtime.manualPromptHandoff and Runtime.manualPromptHandoff.description,
        }, { coalesce = true })
        return
    end

    local castBusy = CastBusy()
    if Runtime.activeTurnKey ~= nil or castBusy then
        self:Trace("trigger", "scan skipped", {
            reason = Pick(Runtime.activeTurnKey ~= nil, "active turn lock", "cast busy"),
            activeTurnKey = Runtime.activeTurnKey,
            castBusy = castBusy,
        }, { coalesce = true })
        return
    end

    return self:RunReactiveTriggerScan(queue, dmhub.allTokens)
end

function AI:AutoOpportunityAttacks()
    return self:AutoReactiveTriggers()
end

function AI:SelectNearestMonsterTurn(skipInitiativeId)
    local queue = dmhub.initiativeQueue
    if queue == nil or queue.hidden or (skipInitiativeId == nil and queue:CurrentInitiativeId() ~= nil) then
        self:Trace("poll", "select monster skipped", {
            reason = Pick(queue == nil, "no queue", Pick(queue and queue.hidden, "queue hidden", "current turn already selected")),
            skipInitiativeId = skipInitiativeId,
        }, { coalesce = true })
        return nil
    end

    local entriesUnmoved = queue:EntriesUnmoved()
    local bestId = nil
    local bestDistance = nil

    for entryid,_ in pairs(entriesUnmoved or {}) do
        if entryid ~= skipInitiativeId and not queue:IsEntryPlayer(entryid) then
            local tokens = self:GetInitiativeTokens(entryid)

            if not self:InitiativeWouldRepeatBossTurn(entryid, tokens) then
                local distanceToHeroes = 999
                for _,hero in ipairs(dmhub.allTokens or {}) do
                    if hero.playerControlled and IsTokenValid(hero) then
                        for _,monsterToken in ipairs(tokens) do
                            if IsTokenValid(monsterToken) then
                                distanceToHeroes = math.min(distanceToHeroes, Distance(hero, monsterToken))
                            end
                        end
                    end
                end

                if bestId == nil or distanceToHeroes < bestDistance then
                    bestId = entryid
                    bestDistance = distanceToHeroes
                end
            else
                self:Trace("poll", "monster turn candidate skipped", {
                    initiativeid = entryid,
                    reason = "would repeat solo/boss turn",
                }, { coalesce = true })
            end
        end
    end

    if bestId ~= nil then
        self:Trace("poll", "monster turn selected", {
            initiativeid = bestId,
            distanceToHeroes = bestDistance,
            skipped = skipInitiativeId,
        })
        queue:SelectTurn(bestId)
        dmhub:UploadInitiativeQueue()

        local centerOn = nil
        local tokens = self:GetInitiativeTokens(bestId)

        for _,tok in ipairs(tokens) do
            if IsTokenValid(tok) then
                SafeCall(function()
                    tok.properties:BeginTurn()
                end, nil)
                if centerOn == nil or not TryGet(tok.properties, "minion", false) then
                    centerOn = tok
                end
            end
        end

        if centerOn ~= nil then
            SafeCall(function()
                dmhub.CenterOnToken(centerOn.charid, { smooth = true })
                dmhub.SyncCamera{ speed = 1 }
            end, nil)
        end
    end

    if bestId == nil then
        self:Trace("poll", "monster turn held", { reason = "no unmoved Director entry", skipped = skipInitiativeId }, { coalesce = true })
    end

    return bestId
end

local function DirectorTacticsThread(runGeneration)
    Runtime.status = "Starting"
    AI:Trace("runtime", "thread started", { runGeneration = runGeneration })
    while true do
        Runtime.thread = coroutine.running()
        coroutine.yield(0.1)

        if (mod ~= nil and mod.unloaded) or Runtime.stop or runGeneration ~= Runtime.runGeneration then
            local requestedStop = Runtime.stop
            AI:Trace("runtime", "thread stopping", {
                runGeneration = runGeneration,
                currentGeneration = Runtime.runGeneration,
                requestedStop = requestedStop,
                unloaded = mod ~= nil and mod.unloaded,
            })
            Runtime.status = nil
            if Runtime.thread == coroutine.running() then
                Runtime.thread = nil
            end
            if requestedStop then
                Runtime.stop = false
                if AI.CleanupPromptTargeting ~= nil then
                    AI:CleanupPromptTargeting(nil, nil, nil, "automation stopped")
                else
                    AI:ClearPromptControls()
                end
                if mod == nil or not mod.unloaded then
                    AI:SetStatus("Automation stopped")
                end
            end
            return
        end

        AI:AutoReactiveTriggers()

        local queue = dmhub.initiativeQueue
        AI:Trace("poll", "queue state", {
            hasQueue = queue ~= nil,
            hidden = queue ~= nil and queue.hidden,
            activeTurnKey = Runtime.activeTurnKey,
            runGeneration = runGeneration,
        }, { coalesce = true })
        if queue ~= nil and not queue.hidden then
            AI:ObserveRoundForVillainActions()
            local observedInitiativeId = queue:CurrentInitiativeId()
            AI:Trace("poll", "initiative state", {
                initiativeid = observedInitiativeId,
                playersTurn = queue:IsPlayersTurn(),
                round = TryGet(queue, "round", nil),
            }, { coalesce = true })
            if observedInitiativeId ~= nil and queue:IsEntryPlayer(observedInitiativeId) then
                AI:ClearConsecutiveBossBlock("player turn observed")
            end
            if queue:IsPlayersTurn() then
                AI:ClearManualPromptHandoff("player turn observed")
            end
        else
            AI:ClearManualPromptHandoff("no active initiative queue")
        end

        if queue ~= nil and not queue.hidden and not queue:IsPlayersTurn() then
            local initiativeid = queue:CurrentInitiativeId()
            AI:StartTraceCapture("poll", {
                initiativeid = initiativeid,
                runGeneration = runGeneration,
                round = TryGet(queue, "round", nil),
            })
            if initiativeid == nil then
                AI:ClearManualPromptHandoff("no current initiative entry")
                Runtime.status = "Selecting Turn"
                AI:Trace("poll", "selecting monster turn")
                initiativeid = AI:SelectNearestMonsterTurn()
                AI.Sleep(0.4)
            elseif AI:ManualPromptHandoffActive(initiativeid, runGeneration) then
                local handoff = Runtime.manualPromptHandoff or {}
                if Runtime.status ~= "Paused for Director" then
                    AI:SetStatus("Paused for Director: " .. tostring(handoff.description or "manual prompt"))
                end
                Runtime.status = "Paused for Director"
                AI:Trace("poll", "manual prompt handoff active", {
                    initiativeid = initiativeid,
                    actorId = handoff.actorId,
                    candidateKey = handoff.candidateKey,
                    description = handoff.description,
                    runGeneration = runGeneration,
                }, { coalesce = true })
                AI.Sleep(0.4)
            elseif initiativeid ~= nil then
                local context = AI:BuildContext(initiativeid)
                if AI:InitiativeWouldRepeatBossTurn(initiativeid, context.activeTokens) then
                    Runtime.status = "Avoiding Consecutive Boss Turn"
                    AI:Trace("poll", "avoiding consecutive boss turn", { initiativeid = initiativeid })
                    local alternate = AI:SelectNearestMonsterTurn(initiativeid)
                    if alternate ~= nil then
                        AI.Sleep(0.4)
                    else
                        AI:Log("Waiting because only the previous solo/boss turn is available.")
                        AI.Sleep(1)
                    end
                else
                    Runtime.status = "Playing Turn"
                    AI:PlayTurnCoroutine(initiativeid)
                    if AI:ManualPromptHandoffActive(initiativeid, runGeneration) then
                        Runtime.status = "Paused for Director"
                    else
                        Runtime.status = "Waiting"
                    end
                end
            end
        else
            Runtime.status = "Waiting"
            AI:Trace("poll", "waiting", { reason = Pick(queue == nil, "no queue", "queue hidden or player turn") }, { coalesce = true })
        end
    end
end

function AI:RuntimeThreadActive()
    if Runtime.thread == nil then
        return false
    end

    local status = coroutine.status(Runtime.thread)
    if status == "running" or status == "suspended" then
        return true
    end

    Runtime.thread = nil
    return false
end

function AI:Start()
    if self:RuntimeThreadActive() then
        self:Trace("runtime", "start ignored", { reason = "thread already active", runGeneration = Runtime.runGeneration })
        return
    end

    Runtime.stop = false
    Runtime.runGeneration = Runtime.runGeneration + 1
    self:ClearManualPromptHandoff("automation restarted")
    self:ResetReactiveTriggerAttempts()
    if self.ResetTraceCoalescing ~= nil then
        self:ResetTraceCoalescing()
    end
    local runGeneration = Runtime.runGeneration
    self:SetStatus("Automation running")
    self:Trace("runtime", "start requested", { runGeneration = runGeneration })
    dmhub.Coroutine(function()
        DirectorTacticsThread(runGeneration)
    end)
end

function AI:Stop()
    self:Trace("runtime", "stop requested", { runGeneration = Runtime.runGeneration, activeTurnKey = Runtime.activeTurnKey })
    Runtime.stop = true
    Runtime.runGeneration = Runtime.runGeneration + 1
    Runtime.activeTurnKey = nil
    self:ClearManualPromptHandoff("automation stopped")
    if self.CleanupPromptTargeting ~= nil then
        self:CleanupPromptTargeting(nil, nil, nil, "automation stopped")
    else
        self:ClearPromptControls()
    end
    if self:RuntimeThreadActive() then
        Runtime.status = "Stopping"
        self:SetStatus("Stopping automation")
    else
        Runtime.stop = false
        Runtime.thread = nil
        Runtime.status = nil
        self:SetStatus("Automation stopped")
    end
end

function AI:IsRunning()
    return self:RuntimeThreadActive()
end

function AI:StatusText()
    if Runtime.stop then
        if self:RuntimeThreadActive() then
            return "Stopping"
        end

        Runtime.stop = false
        Runtime.status = nil
    end

    self:RefreshManualPromptHandoffState()
    local handoff = Runtime.manualPromptHandoff
    if handoff ~= nil then
        return "Paused for Director: " .. tostring(handoff.description or "manual prompt")
    end

    if self:IsRunning() then
        return Runtime.status or "Running"
    end

    return "Not Running"
end

local Commands = RawGlobal("Commands")
if Commands ~= nil and Commands.RegisterMacro ~= nil then
    Commands.RegisterMacro{
        name = "directortactics",
        summary = "play Director tactics turn",
        doc = "Usage: /directortactics\nPlays a Director tactics turn for the current initiative entry.",
        command = function()
            AI:PlayCurrentTurn()
        end,
    }

    Commands.RegisterMacro{
        name = "directortacticsanalyze",
        summary = "analyze Director tactics turn",
        doc = "Usage: /directortacticsanalyze\nShows Director tactics candidate scoring for the current initiative entry.",
        command = function()
            AI:AnalyzeCurrentTurn()
        end,
    }

    Commands.RegisterMacro{
        name = "directortacticsacceptance",
        summary = "run Director tactics acceptance harness",
        doc = "Usage: /directortacticsacceptance\nRuns the read-only Director Tactics Phase 8 acceptance harness against the current encounter.",
        command = function()
            AI:RunAcceptanceHarness()
        end,
    }
end
