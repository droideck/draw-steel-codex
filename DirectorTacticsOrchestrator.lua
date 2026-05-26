local mod = dmhub.GetModLoading()

-- DirectorTacticsOrchestrator.lua owns semantic turn/event phases.
--
-- Phase contract:
--   TurnObserved: polling adapter saw a non-hidden initiative queue.
--     Payload: queue, initiativeid, runGeneration.
--     Owner: DirectorTacticsAutomation.lua polling / turn start.
--   RoundAdvanced: polling adapter observed queue.round advancing.
--     Payload: queue, previousRound, round, runGeneration.
--     Owner: DirectorTacticsAutomation.lua round observer.
--   TurnStarted: a Director-controlled turn has a valid context.
--     Payload: queue, initiativeid, context, runGeneration.
--     Owner: DirectorTacticsAutomation.lua turn playback.
--   StartTurnMalice: start-turn group malice gate.
--     Payload: context, runGeneration.
--     Owner: DirectorTacticsAutomation.lua delegates to Abilities.
--   ActorActionLoop: one actor is about to run the existing candidate loop.
--     Payload: context, actor, actorIndex, actorCount, runGeneration.
--     Owner: DirectorTacticsAutomation.lua.
--   CandidateSelected: actor loop selected a candidate.
--     Payload: context, actor, candidate, iteration, runGeneration.
--     Owner: DirectorTacticsAutomation.lua.
--   CandidateExecutionStarted: execution is beginning for a candidate.
--     Payload: context, actor, candidate, runGeneration.
--     Owner: DirectorTacticsExecution.lua.
--   PromptRequested: a trigger or ability prompt needs policy handling.
--     Payload: source, context, actor, token, trigger, ability, symbols, options, runGeneration.
--     Owner: Automation trigger scanner or Execution prompt callback.
--   CandidateExecutionFinished: candidate execution reached a terminal result.
--     Payload: context, actor, candidate, executed, reason, runGeneration.
--     Owner: DirectorTacticsExecution.lua.
--   CritRefreshResolved: crit refresh refunded one or more action-economy resources.
--     Payload: context, actor, candidate, symbols, finishOptions, refreshed, naturalRoll, threshold, runGeneration.
--     Owner: DirectorTacticsExecution.lua.
--   ActorFinished: actor loop ended or paused.
--     Payload: context, actor, reason, candidate, runGeneration.
--     Owner: DirectorTacticsAutomation.lua.
--   EndRoundVillainAction: explicit round-transition villain action hook.
--     Payload: previousRound, round, context, runGeneration.
--     Owner: default handler calls DirectorTacticsAutomation.lua villain action.
--   TurnCompleted: all actors completed and turn memory is being recorded.
--     Payload: context, runGeneration.
--     Owner: DirectorTacticsAutomation.lua.
--   InitiativeAdvanceRequested: automation is allowed to advance initiative.
--     Payload: context, runGeneration.
--     Owner: default handler advances GameHud initiative.
--   AutomationCanceled: phase gate observed stale generation or stop/unload.
--     Payload: phase, reason, runGeneration.
--     Owner: DirectorTacticsOrchestrator.lua.

local AI = rawget(_G, "DirectorTacticsAI")
if AI == nil or AI._internal == nil then
    error("DirectorTacticsAI.lua must be loaded before this DirectorTactics subsystem")
end

local Internal = AI._internal
local Runtime = AI._runtime
local RawGlobal = Internal.RawGlobal
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local TokenName = Internal.TokenName

AI.Phase = AI.Phase or {}
AI.Phase.TurnObserved = AI.Phase.TurnObserved or "TurnObserved"
AI.Phase.RoundAdvanced = AI.Phase.RoundAdvanced or "RoundAdvanced"
AI.Phase.TurnStarted = AI.Phase.TurnStarted or "TurnStarted"
AI.Phase.StartTurnMalice = AI.Phase.StartTurnMalice or "StartTurnMalice"
AI.Phase.ActorActionLoop = AI.Phase.ActorActionLoop or "ActorActionLoop"
AI.Phase.CandidateSelected = AI.Phase.CandidateSelected or "CandidateSelected"
AI.Phase.CandidateExecutionStarted = AI.Phase.CandidateExecutionStarted or "CandidateExecutionStarted"
AI.Phase.PromptRequested = AI.Phase.PromptRequested or "PromptRequested"
AI.Phase.CandidateExecutionFinished = AI.Phase.CandidateExecutionFinished or "CandidateExecutionFinished"
AI.Phase.CritRefreshResolved = AI.Phase.CritRefreshResolved or "CritRefreshResolved"
AI.Phase.ActorFinished = AI.Phase.ActorFinished or "ActorFinished"
AI.Phase.EndRoundVillainAction = AI.Phase.EndRoundVillainAction or "EndRoundVillainAction"
AI.Phase.TurnCompleted = AI.Phase.TurnCompleted or "TurnCompleted"
AI.Phase.InitiativeAdvanceRequested = AI.Phase.InitiativeAdvanceRequested or "InitiativeAdvanceRequested"
AI.Phase.AutomationCanceled = AI.Phase.AutomationCanceled or "AutomationCanceled"

AI.phaseHandlers = AI.phaseHandlers or {}

local function PhaseHandlers(ai, name)
    ai.phaseHandlers = ai.phaseHandlers or {}
    ai.phaseHandlers[name] = ai.phaseHandlers[name] or {}
    return ai.phaseHandlers[name]
end

function AI:OnPhase(name, handler)
    if name == nil or handler == nil then
        return nil
    end

    local handlers = PhaseHandlers(self, name)
    handlers[#handlers+1] = handler
    return handler
end

local function PhaseCandidateDescription(candidate)
    if candidate == nil then
        return nil
    end

    return candidate.description or TryGet(candidate, "name", nil) or tostring(candidate)
end

local function PhaseTraceFields(payload)
    local fields = {
        runGeneration = payload and payload.runGeneration,
        initiativeid = payload and payload.initiativeid,
        round = payload and payload.round,
        previousRound = payload and payload.previousRound,
        source = payload and payload.source,
        reason = payload and payload.reason,
        reasonCode = payload and payload.reasonCode,
        validationPhase = payload and payload.validationPhase,
        canceledPhase = payload and payload.canceledPhase,
        actorIndex = payload and payload.actorIndex,
        actorCount = payload and payload.actorCount,
        executed = payload and payload.executed,
        advanced = payload and payload.advanced,
        stopped = payload and payload.stopped,
        refreshed = payload and payload.refreshed,
        naturalRoll = payload and payload.naturalRoll,
        threshold = payload and payload.threshold,
    }

    local actor = payload and payload.actor
    if actor ~= nil then
        fields.actor = TokenName(actor.token)
        fields.actorKind = actor.kind
    end

    local token = payload and (payload.token or payload.invokerToken or payload.casterToken)
    if token ~= nil then
        fields.token = TokenName(token)
    end

    local candidate = payload and payload.candidate
    if candidate ~= nil then
        fields.candidate = PhaseCandidateDescription(candidate)
        fields.flow = candidate.pipelineFlow
    end

    local ability = payload and payload.ability
    if ability ~= nil then
        fields.ability = TryGet(ability, "name", nil)
    elseif payload and payload.abilityName ~= nil then
        fields.ability = payload.abilityName
    end

    local trigger = payload and payload.trigger
    if trigger ~= nil then
        fields.trigger = TryGet(trigger, "text", TryGet(trigger, "name", nil))
    end

    return fields
end

function AI:EmitPhase(name, payload)
    payload = payload or {}
    payload.phase = name
    if payload.runGeneration == nil then
        payload.runGeneration = Runtime.runGeneration
    end

    self:Trace("phase", tostring(name), PhaseTraceFields(payload))

    if self:AutomationCanceled(payload.runGeneration) then
        payload.canceled = true
        local handlers = self.phaseHandlers and self.phaseHandlers[self.Phase.AutomationCanceled]
        if name ~= self.Phase.AutomationCanceled and handlers ~= nil then
            local cancelPayload = {
                phase = self.Phase.AutomationCanceled,
                canceledPhase = name,
                reason = "stale generation or stop requested",
                runGeneration = payload.runGeneration,
            }

            self:Trace("phase", tostring(self.Phase.AutomationCanceled), PhaseTraceFields(cancelPayload))
            for _,handler in ipairs(handlers) do
                handler(self, cancelPayload)
            end
        end
        return false, payload
    end

    local handlers = self.phaseHandlers and self.phaseHandlers[name]
    for _,handler in ipairs(handlers or {}) do
        local result = handler(self, payload)
        if result == false then
            payload.stopped = true
            self:Trace("phase", tostring(name) .. " stopped", PhaseTraceFields(payload))
            return false, payload
        end
    end

    self:Trace("phase", tostring(name) .. " complete", PhaseTraceFields(payload))
    return true, payload
end

if not AI._orchestratorDefaultsRegistered then
    AI._orchestratorDefaultsRegistered = true

    AI:OnPhase(AI.Phase.RoundAdvanced, function(ai, payload)
        if payload == nil or payload.previousRound == nil then
            return true
        end

        return ai:EmitPhase(ai.Phase.EndRoundVillainAction, payload)
    end)

    AI:OnPhase(AI.Phase.EndRoundVillainAction, function(ai, payload)
        if payload == nil or payload.previousRound == nil then
            return true
        end

        payload.executed = ai:RunEndRoundVillainAction(payload.previousRound, payload.context)
        return true
    end)

    AI:OnPhase(AI.Phase.InitiativeAdvanceRequested, function(ai, payload)
        if payload == nil or payload.context == nil then
            return true
        end

        local hud = RawGlobal("GameHud")
        if ai.config.autoAdvanceInitiative and hud ~= nil and hud.instance ~= nil then
            SafeCall(function()
                hud.instance:NextInitiative(function()
                    dmhub:UploadInitiativeQueue()
                end)
            end, nil)
            payload.advanced = true
        end

        return true
    end)
end
