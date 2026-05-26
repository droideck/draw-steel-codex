local mod = dmhub.GetModLoading()

local AI = rawget(_G, "DirectorTacticsAI")
if AI == nil or AI._internal == nil then
    error("DirectorTacticsAI.lua must be loaded before this DirectorTactics subsystem")
end

-- DirectorTacticsPipeline.lua owns the shared candidate lifecycle:
-- Analyze -> Gate -> Enumerate -> Score -> Apply Resource Policy -> Rank -> Select.
-- Load after DirectorTacticsCandidates.lua. It keeps legacy entry points as wrappers.

local Internal = AI._internal

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local TokenName = Internal.TokenName
local IsDead = Internal.IsDead
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local LocKey = Internal.LocKey
local CreateScore = Internal.CreateScore
local AddScore = Internal.AddScore
local ScoreText = Internal.ScoreText
local ConstNumber = Internal.ConstNumber

local Pipeline = AI.Pipeline or {}
AI.Pipeline = Pipeline

local CandidateActionCost

Pipeline.ValidFlows = Pipeline.ValidFlows or {
    turn = true,
    analysisOnly = true,
    manualPrompt = true,
    startTurnMalice = true,
    endRoundVillain = true,
    trigger = true,
}

local function CopyOptions(options)
    local result = {}
    for k,v in pairs(options or {}) do
        result[k] = v
    end
    return result
end

local function CandidateScore(candidate, flow)
    if candidate == nil then
        return 0
    end

    if AI.CandidateScoreTotal ~= nil then
        return AI:CandidateScoreTotal(candidate, flow)
    end

    if flow == "startTurnMalice" then
        return candidate.startTurnScore or candidate.score or 0
    end

    return candidate.score or 0
end

local function CandidateDescription(candidate)
    if candidate == nil then
        return "candidate"
    end

    if AI.CandidateScoreSection ~= nil then
        local score = AI:CandidateScoreSection(candidate)
        if score.description ~= nil then
            return score.description
        end
    end

    if candidate.description ~= nil then
        return candidate.description
    end

    if candidate.abilityInfo ~= nil and candidate.abilityInfo.name ~= nil then
        return candidate.abilityInfo.name
    end

    local triggerPolicy = AI.CandidateTriggerPolicy and AI:CandidateTriggerPolicy(candidate) or candidate.triggerPolicy
    if triggerPolicy ~= nil and triggerPolicy.id ~= nil then
        return triggerPolicy.id
    end

    return "candidate"
end

local function CandidateActionCostValue(candidate)
    return AI.CandidateActionCost and AI:CandidateActionCost(candidate) or candidate and candidate.actionCost
end

local function CandidateTargets(candidate)
    return AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate and candidate.targets or {}
end

local function CandidateHostileTargetCounts(candidate)
    local actorToken = candidate and candidate.actor and candidate.actor.token
    local hostile = 0
    local friendly = 0
    if actorToken == nil then
        return hostile, friendly
    end

    for _,target in ipairs(CandidateTargets(candidate)) do
        local tok = target and target.token or target
        if IsTokenValid(tok) then
            if TokensFriendly(actorToken, tok) then
                friendly = friendly + 1
            else
                hostile = hostile + 1
            end
        end
    end

    return hostile, friendly
end

local function CandidateIsExactAuto(candidate)
    local decision = candidate and candidate.automationDecision
    return decision == nil or TryGet(decision, "outcome", "exact_auto") == "exact_auto"
end

local function CandidateScoreHasLabel(candidate, label)
    if candidate == nil then
        return false
    end

    if AI.ScoreHasLabel ~= nil and AI:ScoreHasLabel(candidate.scoreInfo, label) then
        return true
    end

    local score = AI.CandidateScoreSection and AI:CandidateScoreSection(candidate) or nil
    local scoreInfo = score and score.scoreInfo
    if AI.ScoreHasLabel ~= nil and AI:ScoreHasLabel(scoreInfo, label) then
        return true
    end

    return false
end

local function CandidateIsSafeAreaMainAction(candidate)
    local info = candidate and candidate.abilityInfo
    if info == nil or not info.isArea or CandidateActionCostValue(candidate) ~= "action" or not CandidateIsExactAuto(candidate) then
        return false
    end

    if AI.AbilityHasHostileEffect ~= nil and not AI:AbilityHasHostileEffect(info) then
        return false
    end

    local hostile, friendly = CandidateHostileTargetCounts(candidate)
    return hostile >= 2 and friendly == 0
end

local function CandidateIsSingleTargetMainAction(candidate)
    local info = candidate and candidate.abilityInfo
    if info == nil or CandidateActionCostValue(candidate) ~= "action" or info.isArea then
        return false
    end

    local hostile, friendly = CandidateHostileTargetCounts(candidate)
    return hostile == 1 and friendly == 0
end

local function TraceActorName(actor)
    if actor == nil then
        return nil
    end

    return TokenName(actor.token)
end

local function TraceCandidateTargetSummary(candidate)
    if candidate == nil then
        return nil
    end

    local parts = {}
    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets or {}) do
        if #parts >= 3 then
            break
        end

        local token = target and target.token
        local loc = target and target.loc
        if token ~= nil then
            parts[#parts+1] = string.format("%s@%s", TokenName(token), LocKey(loc or TryGet(token, "loc", nil)))
        elseif loc ~= nil then
            parts[#parts+1] = LocKey(loc)
        end
    end

    local execution = AI.CandidateExecution and AI:CandidateExecution(candidate) or {}
    local loc = execution.loc or candidate.loc
    if #parts == 0 and loc ~= nil then
        parts[#parts+1] = "loc@" .. LocKey(loc)
    end

    local targetArea = AI.CandidateTargetArea and AI:CandidateTargetArea(candidate) or candidate.targetArea
    if targetArea ~= nil and #parts < 3 then
        parts[#parts+1] = "area@" .. LocKey(TryGet(targetArea, "origin", nil))
    end

    if #parts == 0 then
        return nil
    end

    return table.concat(parts, ",")
end

local function TraceCandidateFields(candidate, flow, index)
    if candidate == nil then
        return {}
    end

    local decision = AI.AutomationDecisionSummary and AI:AutomationDecisionSummary(candidate) or nil
    return {
        index = index,
        description = CandidateDescription(candidate),
        score = CandidateScore(candidate, flow),
        actionCost = CandidateActionCost(candidate),
        decision = decision,
        targets = TraceCandidateTargetSummary(candidate),
    }
end

local function TraceOptionsForFlow(flow)
    if flow == "trigger" then
        return { coalesce = true }
    end

    return nil
end

local function TraceTopCandidates(flow, candidates)
    local limit = math.min(5, #(candidates or {}))
    for i=1,limit do
        AI:Trace("pipeline", "ranked candidate", TraceCandidateFields(candidates[i], flow, i), TraceOptionsForFlow(flow))
    end
end

function CandidateActionCost(candidate)
    if candidate == nil then
        return "unknown"
    end

    if AI.CandidateMovementOnly ~= nil and AI:CandidateMovementOnly(candidate) then
        return "movement-only"
    end

    local actionCost = AI.CandidateActionCost and AI:CandidateActionCost(candidate) or candidate.actionCost
    if actionCost ~= nil then
        return tostring(actionCost)
    end

    if AI.Ledger ~= nil then
        return tostring(AI.Ledger:AbilityActionCost(AI, candidate.abilityInfo))
    end

    return "unknown"
end

local function CandidatePreInvokeDestination(candidate)
    if AI.CandidatePreInvokeDestination ~= nil then
        return AI:CandidatePreInvokeDestination(candidate)
    end

    return nil
end

local function CandidatePrimaryAttackLoc(candidate)
    if AI.CandidatePrimaryAttackLoc ~= nil then
        return AI:CandidatePrimaryAttackLoc(candidate)
    end

    return CandidatePreInvokeDestination(candidate) or (candidate and candidate.loc) or nil
end

local function CandidateThreshold(actor, candidate, fallback)
    if AI.Ledger ~= nil then
        return AI.Ledger:ActorSelectionThreshold(AI, actor, candidate)
    end

    return fallback or ConstNumber("Candidate", "ActorSelectionThreshold", 0.8)
end

local function LogTopCandidatesBelowThreshold(actor, candidates, threshold)
    local parts = {}
    for i=1,math.min(3, #candidates) do
        local candidate = candidates[i]
        local candidateThreshold = CandidateThreshold(actor, candidate, threshold)
        parts[#parts+1] = string.format(
            "%d) %s score=%0.1f cost=%s threshold=%0.1f",
            i,
            CandidateDescription(candidate),
            CandidateScore(candidate, nil),
            CandidateActionCost(candidate),
            candidateThreshold
        )
    end

    AI:Log(string.format(
        "Top candidates below threshold for %s threshold=%0.1f: %s",
        TokenName(actor and actor.token),
        tonumber(threshold) or 0,
        table.concat(parts, "; ")
    ))

    local maneuverParts = {}
    for _,candidate in ipairs(candidates or {}) do
        if CandidateActionCost(candidate) == "maneuver" then
            maneuverParts[#maneuverParts+1] = string.format(
                "%s score=%0.1f threshold=%0.1f",
                CandidateDescription(candidate),
                CandidateScore(candidate, nil),
                CandidateThreshold(actor, candidate, threshold)
            )
            if #maneuverParts >= 3 then
                break
            end
        end
    end

    if #maneuverParts > 0 then
        AI:Log(string.format(
            "Top maneuver candidates for %s: %s",
            TokenName(actor and actor.token),
            table.concat(maneuverParts, "; ")
        ))
    end
end

local function StableText(value)
    return string.lower(tostring(value or ""))
end

local function StableTokenKey(token)
    if token == nil then
        return ""
    end

    return tostring(TryGet(token, "charid", TryGet(token, "id", TryGet(token, "name", TokenName(token)))))
end

local function CandidateAbilityName(candidate)
    if candidate == nil then
        return ""
    end

    if candidate.abilityInfo ~= nil and candidate.abilityInfo.name ~= nil then
        return candidate.abilityInfo.name
    end

    local triggerPolicy = AI.CandidateTriggerPolicy and AI:CandidateTriggerPolicy(candidate) or candidate.triggerPolicy
    if triggerPolicy ~= nil and triggerPolicy.id ~= nil then
        return triggerPolicy.id
    end

    return CandidateDescription(candidate)
end

local function CandidateMaliceTie(candidate)
    if candidate == nil then
        return 0
    end

    local score = AI.CandidateScoreSection and AI:CandidateScoreSection(candidate) or {}
    if candidate.abilityInfo ~= nil and candidate.abilityInfo.isMalice then
        return tonumber(score.maliceCost) or tonumber(candidate.maliceCost) or AI:MaliceCost(candidate.abilityInfo) or 0
    end

    local startTurnMalice = candidate.startTurnMalice == true
    if AI.CandidateStartTurnMalice ~= nil then
        startTurnMalice = AI:CandidateStartTurnMalice(candidate)
    end
    if startTurnMalice then
        return tonumber(score.maliceCost) or tonumber(candidate.maliceCost) or 0
    end

    return 0
end

local function OrderingKeyComesBefore(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end

    if a.maliceTie ~= b.maliceTie then
        return a.maliceTie > b.maliceTie
    end

    local stringKeys = {
        "abilityName",
        "targetSignature",
        "actorKey",
        "locKey",
        "actionCost",
        "description",
    }
    for _,key in ipairs(stringKeys) do
        if a[key] ~= b[key] then
            return a[key] < b[key]
        end
    end

    return (a.ordinal or 0) < (b.ordinal or 0)
end

function Pipeline:FlowFlags(flow, options)
    return {
        flow = flow,
        manualPrompt = flow == "manualPrompt",
        startTurnMalice = flow == "startTurnMalice",
        endRoundVillain = flow == "endRoundVillain",
        trigger = flow == "trigger",
        analysisOnly = flow == "analysisOnly",
        turn = flow == "turn",
    }
end

function Pipeline:Analyze(context, actor, flow, options, result)
    if actor ~= nil then
        AI:SyncTurnMemoryFromResources(actor)
    end

    if context ~= nil and flow ~= "trigger" then
        AI:ResetCandidateEvaluationCache(context)
    end

    return true
end

function Pipeline:Gate(context, actor, flow, options, result)
    if flow == "turn" or flow == "analysisOnly" or flow == "manualPrompt" then
        if actor == nil or actor.token == nil then
            result.heldReason = "missing actor"
            return false
        end

        return true
    end

    if flow == "startTurnMalice" then
        if not AI.config.maliceAbilities then
            result.heldReason = "malice abilities disabled"
            return false
        end

        if context == nil then
            result.heldReason = "missing context"
            return false
        end

        if AI:AutomationCanceled(context.runGeneration) then
            result.heldReason = "automation canceled"
            return false
        end

        if AI.Ledger ~= nil and AI.Ledger:HasUsedStartTurnMalice(AI, context) then
            result.heldReason = "start-turn malice already used"
            return false
        end

        return true
    end

    if flow == "endRoundVillain" then
        if not AI.config.villainActions then
            result.heldReason = "villain actions disabled"
            return false
        end

        if context == nil then
            result.heldReason = "missing context"
            return false
        end

        local resource = RawGlobal("CharacterResource")
        local villainActions = SafeCall(function()
            return resource.GetVillainActions()
        end, context.villainActions or 0)
        if (villainActions or 0) <= 0 then
            result.heldReason = "no villain actions available"
            return false
        end

        local previousRound = options.previousRound
        local state = context.encounterState or AI.encounterState
        if state ~= nil and state.usedVillainActions ~= nil and state.usedVillainActions[previousRound] then
            result.heldReason = "villain action already used for round"
            return false
        end

        if state ~= nil and state.endRoundVillainActions ~= nil and state.endRoundVillainActions[previousRound] then
            result.heldReason = "end-round villain action already used"
            return false
        end

        return true
    end

    if flow == "trigger" then
        if options.token == nil or options.trigger == nil then
            result.heldReason = "missing trigger"
            return false
        end

        return true
    end

    result.heldReason = "unsupported flow: " .. tostring(flow)
    return false
end

function Pipeline:EnumerateTurnCandidates(context, actor, options, flow)
    local candidates = AI:EnumerateCandidatePipeline(context, actor, options)
    if flow == "manualPrompt" then
        local filtered = {}
        for _,candidate in ipairs(candidates or {}) do
            local manualPrompt = candidate.manualPrompt == true
            if AI.CandidateManualPrompt ~= nil then
                manualPrompt = AI:CandidateManualPrompt(candidate)
            end
            if manualPrompt then
                filtered[#filtered+1] = candidate
            end
        end
        return filtered
    end

    return candidates or {}
end

function Pipeline:EnumerateStartTurnMalice(context, actor, options)
    local candidates = {}
    if actor ~= nil then
        for _,candidate in ipairs(AI:CollectStartTurnMaliceCandidates(context, actor)) do
            candidates[#candidates+1] = candidate
        end
        return candidates
    end

    for _,candidateActor in ipairs(context.actors or {}) do
        for _,candidate in ipairs(AI:CollectStartTurnMaliceCandidates(context, candidateActor)) do
            candidates[#candidates+1] = candidate
        end
    end

    return candidates
end

function Pipeline:EnumerateEndRoundVillain(context, actor, options)
    local candidates = {}
    local previousRound = options.previousRound

    for _,tok in ipairs(context.allCombatTokens or {}) do
        if IsTokenValid(tok) and not tok.playerControlled and not IsDead(tok) then
            local candidateActor = AI:BuildActorForToken(context, tok)
            if candidateActor ~= nil then
                local abilities = SafeCall(function()
                    return tok.properties:GetActivatedAbilities()
                end, {}) or {}

                for _,ability in ipairs(abilities) do
                    local info = AI:AnalyzeAbility(candidateActor, ability)
                    if info.isVillain then
                        local include = true
                        local manualPromptCandidate = false
                        local promptCapability = nil
                        local canUseVillain, villainReason = AI:CanUseVillainAction(context, candidateActor, ability, info, { mode = 1 })
                        if not canUseVillain then
                            include = false
                            AI:Skip(ability, villainReason or "villain action unavailable")
                        end
                        local manualPromptReason = nil
                        local unsafePromptReason = nil
                        if include then
                            if AI.AssessPromptCapability ~= nil then
                                promptCapability = AI:AssessPromptCapability(context, candidateActor, info, {
                                    ability = ability,
                                    abilityInfo = info,
                                    symbols = { mode = 1 },
                                })
                                if promptCapability ~= nil and promptCapability.status == "manual" then
                                    manualPromptReason = promptCapability.reason or "manual targeting"
                                elseif promptCapability ~= nil and promptCapability.status == "blocked" then
                                    unsafePromptReason = promptCapability.reason or "unresolved prompt"
                                end
                            else
                                manualPromptReason = AI:AbilityManualPromptReason(info, context, candidateActor)
                                if manualPromptReason == nil then
                                    unsafePromptReason = AI:AbilityUnsafePromptReason(info, context, candidateActor)
                                end
                            end
                        end

                        if include and manualPromptReason ~= nil then
                            if AI.config.manualPrompts then
                                manualPromptCandidate = true
                            else
                                include = false
                                AI:Skip(ability, manualPromptReason)
                            end
                        end

                        if include and unsafePromptReason ~= nil then
                            include = false
                            AI:Skip(ability, unsafePromptReason)
                        end

                        if include then
                            local generated = nil
                            if manualPromptCandidate then
                                generated = AI:EnumerateManualPromptAbility(context, candidateActor, ability, info, manualPromptReason, promptCapability)
                            else
                                generated = AI:EnumerateGenericAbility(context, candidateActor, ability, info)
                            end

                            for _,candidate in ipairs(generated or {}) do
                                if AI.AnnotatePromptCapability ~= nil then
                                    AI:AnnotatePromptCapability(candidate, promptCapability)
                                end
                                if AI.WriteCandidateIntent ~= nil then
                                    AI:WriteCandidateIntent(candidate, {
                                        endRoundVillain = true,
                                        villainRound = previousRound,
                                        manualPrompt = (AI.CandidateManualPrompt and AI:CandidateManualPrompt(candidate) or candidate.manualPrompt == true) or manualPromptCandidate == true,
                                        manualPromptReason = (AI.CandidateManualPromptReason and AI:CandidateManualPromptReason(candidate) or candidate.manualPromptReason) or manualPromptReason,
                                })
                            else
                                candidate.endRoundVillain = true
                                candidate.villainRound = previousRound
                                candidate.manualPrompt = candidate.manualPrompt or manualPromptCandidate
                                candidate.manualPromptReason = candidate.manualPromptReason or manualPromptReason
                            end
                                AddScore(candidate.scoreInfo, "round-end timing", ConstNumber("Score", "EndRoundVillainTimingBonus", 4))
                                if AI.WriteCandidateScore ~= nil then
                                    AI:WriteCandidateScore(candidate, {
                                        scoreInfo = candidate.scoreInfo,
                                        total = candidate.scoreInfo.total,
                                    })
                                else
                                    candidate.score = candidate.scoreInfo.total
                                end
                                if AI.SyncCandidateSections ~= nil then
                                    AI:SyncCandidateSections(candidate)
                                end
                                candidates[#candidates+1] = candidate
                            end
                        end
                    end
                end
            end
        end
    end

    return candidates
end

function Pipeline:EnumerateTrigger(context, actor, options)
    local candidates = {}
    local token = options.token
    local trigger = options.trigger
    local triggerInfo = options.triggerInfo

    for _,policy in ipairs(AI.triggerPolicies or {}) do
        local ok = true
        if policy.matches ~= nil then
            ok = SafeCall(function()
                return policy.matches(AI, token, trigger, context, triggerInfo)
            end, false)
        end

        if ok then
            local scoreValue = 1
            if policy.score ~= nil then
                scoreValue = SafeCall(function()
                    return policy.score(AI, token, trigger, context, triggerInfo)
                end, 0)
            end
            scoreValue = scoreValue or 0

            local score = CreateScore()
            AddScore(score, "trigger policy", scoreValue)

            local objectiveProfile = AI.objectiveProfiles[((context and context.encounterPlan) or AI:GetEncounterPlan()).objective]
            if objectiveProfile ~= nil and objectiveProfile.scoreTrigger ~= nil and not objectiveProfile.builtin then
                AddScore(score, "objective trigger", SafeCall(function()
                    return objectiveProfile.scoreTrigger(AI, context, token, trigger)
                end, 0) or 0)
            end

            if score.total > 0 then
                local policyId = policy.id or tostring(#candidates + 1)
                local decision = AI:TriggerAutomationDecision{
                    token = token,
                    trigger = trigger,
                    context = context,
                    triggerInfo = triggerInfo,
                    triggerPolicy = policy,
                    policyId = policyId,
                }
                local candidate = {
                    id = "trigger:" .. tostring(policyId),
                    triggerPolicy = policy,
                    token = token,
                    trigger = trigger,
                    triggerInfo = triggerInfo,
                    context = context,
                    scoreInfo = score,
                    score = score.total,
                    description = policy.id or TryGet(trigger, "text", "trigger"),
                    automationDecision = decision,
                    execute = function()
                        local executed = SafeCall(function()
                            return policy.execute(AI, token, trigger, context, triggerInfo)
                        end, false)
                        return executed ~= false
                    end,
                }

                if AI.WriteCandidateIntent ~= nil then
                    AI:WriteCandidateIntent(candidate, {
                        triggerPolicy = policy,
                    })
                end
                if AI.WriteCandidateScore ~= nil then
                    AI:WriteCandidateScore(candidate, {
                        scoreInfo = score,
                        total = score.total,
                        description = candidate.description,
                    })
                end
                if AI.SyncCandidateSections ~= nil then
                    AI:SyncCandidateSections(candidate)
                end
                if AI:TriggerCandidateCanAutoDispatch(candidate) then
                    candidates[#candidates+1] = candidate
                end
            end
        end
    end

    return candidates
end

function Pipeline:Enumerate(context, actor, flow, options, result)
    if flow == "turn" or flow == "analysisOnly" or flow == "manualPrompt" then
        return self:EnumerateTurnCandidates(context, actor, options, flow)
    end

    if flow == "startTurnMalice" then
        return self:EnumerateStartTurnMalice(context, actor, options)
    end

    if flow == "endRoundVillain" then
        return self:EnumerateEndRoundVillain(context, actor, options)
    end

    if flow == "trigger" then
        return self:EnumerateTrigger(context, actor, options)
    end

    return {}
end

function Pipeline:Score(context, actor, flow, candidates, options, result)
    for _,candidate in ipairs(candidates or {}) do
        if AI.WriteCandidateScore ~= nil then
            AI:WriteCandidateScore(candidate, {
                pipelineFlow = flow,
                total = CandidateScore(candidate, flow),
            })
        else
            candidate.pipelineFlow = flow
            candidate.score = CandidateScore(candidate, flow)
            if AI.SyncCandidateSections ~= nil then
                AI:SyncCandidateSections(candidate)
            end
        end
    end
end

function Pipeline:MakeTargetSignature(candidate)
    local parts = {}

    local function AddPart(label, value)
        if value ~= nil and value ~= "" then
            parts[#parts+1] = label .. ":" .. tostring(value)
        end
    end

    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets) do
        AddPart("target", StableTokenKey(target.token))
        AddPart("targetLoc", LocKey(target.loc))
        AddPart("targetChargeLoc", LocKey(target["chargeLoc"]))
    end

    local execution = AI.CandidateExecution and AI:CandidateExecution(candidate) or {}
    for _,assignment in ipairs((AI.CandidateSquadAssignments and AI:CandidateSquadAssignments(candidate)) or execution.squadAssignments or candidate.squadAssignments or {}) do
        AddPart("member", StableTokenKey(assignment.member and assignment.member.token))
        AddPart("assignmentTarget", StableTokenKey(assignment.target))
        AddPart("assignmentLoc", LocKey(assignment.loc))
        AddPart("assignmentChargeLoc", LocKey(assignment.chargeLoc))
    end

    AddPart("token", StableTokenKey(candidate.token))
    AddPart("loc", LocKey((AI.CandidateExecutionLoc and AI:CandidateExecutionLoc(candidate)) or execution.loc or candidate.loc))
    AddPart("preInvokeDestination", LocKey(CandidatePreInvokeDestination(candidate)))
    AddPart("trigger", TryGet(AI.CandidateTriggerPolicy and AI:CandidateTriggerPolicy(candidate) or candidate.triggerPolicy, "id", nil))

    table.sort(parts)
    return table.concat(parts, "|")
end

function Pipeline:FilterRejectedCandidates(context, actor, flow, candidates, options, result)
    if flow ~= "turn" or actor == nil or actor.turnMemory == nil or actor.turnMemory.rejectedCandidateKeys == nil then
        return candidates
    end

    local filtered = {}
    local rejectedCount = 0
    local rejectedSamples = {}
    for _,candidate in ipairs(candidates or {}) do
        local rejected = false
        local keys = AI.CandidateRejectionKeys and AI:CandidateRejectionKeys(candidate, nil, true) or {}
        if #keys == 0 then
            local key = AI.CandidateRetryKey and AI:CandidateRetryKey(candidate) or candidate.retryKey
            if key ~= nil and key ~= "" then
                keys[#keys+1] = key
            end
        end

        for _,key in ipairs(keys) do
            if actor.turnMemory.rejectedCandidateKeys[key] then
                rejected = true
                break
            end
        end

        if rejected then
            rejectedCount = rejectedCount + 1
            if #rejectedSamples < 5 then
                rejectedSamples[#rejectedSamples+1] = string.format("%s keys=%s", CandidateDescription(candidate), table.concat(keys, ","))
            end
        else
            filtered[#filtered+1] = candidate
        end
    end

    if rejectedCount > 0 then
        result.heldReason = result.heldReason or string.format("%d candidate(s) rejected this turn", rejectedCount)
        result.rejectedCount = rejectedCount
        for i,sample in ipairs(rejectedSamples) do
            AI:Trace("pipeline", "candidate rejected", { index = i, flow = flow, sample = sample }, TraceOptionsForFlow(flow))
        end
    end

    return filtered
end

function Pipeline:MakeOrderingKey(candidate, flow, ordinal)
    local actorToken = candidate.actor and candidate.actor.token
    local actionCost = AI.CandidateActionCost and AI:CandidateActionCost(candidate) or candidate.actionCost
    local loc = AI.CandidateExecutionLoc and AI:CandidateExecutionLoc(candidate) or candidate.loc
    return {
        score = CandidateScore(candidate, flow),
        maliceTie = CandidateMaliceTie(candidate),
        abilityName = StableText(CandidateAbilityName(candidate)),
        targetSignature = self:MakeTargetSignature(candidate),
        actorKey = StableTokenKey(actorToken),
        locKey = LocKey(loc or CandidatePreInvokeDestination(candidate)),
        actionCost = StableText(actionCost),
        description = StableText(CandidateDescription(candidate)),
        ordinal = ordinal or 0,
    }
end

function Pipeline:PrepareOrderingKeys(candidates, flow)
    for i,candidate in ipairs(candidates or {}) do
        local orderingKey = self:MakeOrderingKey(candidate, flow, i)
        if AI.WriteCandidateScore ~= nil then
            AI:WriteCandidateScore(candidate, {
                orderingKey = orderingKey,
            })
        else
            candidate.orderingKey = orderingKey
            if AI.SyncCandidateSections ~= nil then
                AI:SyncCandidateSections(candidate)
            end
        end
    end
end

function Pipeline:CandidateComesBefore(a, b, flow)
    local akey = a.orderingKey or self:MakeOrderingKey(a, flow, 0)
    local bkey = b.orderingKey or self:MakeOrderingKey(b, flow, 0)
    return OrderingKeyComesBefore(akey, bkey)
end

function Pipeline:BestCandidate(candidates, flow, predicate)
    local best = nil
    for _,candidate in ipairs(candidates or {}) do
        if predicate == nil or predicate(candidate) then
            if best == nil or self:CandidateComesBefore(candidate, best, flow) then
                best = candidate
            end
        end
    end
    return best
end

function Pipeline:HostileComboSetupTargets(actor, candidate)
    local setupTargets = {}
    local targetKeys = {}
    if actor == nil or actor.token == nil or candidate == nil then
        return setupTargets, targetKeys
    end

    local sourceTargets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(sourceTargets) do
        local tok = target and target.token
        if tok ~= nil and not TokensFriendly(actor.token, tok) then
            local key = StableTokenKey(tok)
            if targetKeys[key] == nil then
                targetKeys[key] = true
                setupTargets[#setupTargets+1] = target
            end
        end
    end

    table.sort(setupTargets, function(a, b)
        return StableTokenKey(a.token) < StableTokenKey(b.token)
    end)

    return setupTargets, targetKeys
end

function Pipeline:CandidateCanSetupCombo(actor, candidate)
    local info = candidate and candidate.abilityInfo
    local actionCost = AI.CandidateActionCost and AI:CandidateActionCost(candidate) or candidate.actionCost
    if info == nil or actionCost ~= "maneuver" or (info.conditionValue or 0) <= 0 then
        return false
    end

    local conditionApplyNames = info.conditionApplyNames or {}
    if #conditionApplyNames == 0 and info.conditionApplyGeneric ~= true then
        return false
    end

    local targets = self:HostileComboSetupTargets(actor, candidate)
    return #targets > 0
end

function Pipeline:CandidateCanFollowCombo(actor, candidate, setupTargetKeys)
    local info = candidate and candidate.abilityInfo
    local actionCost = AI.CandidateActionCost and AI:CandidateActionCost(candidate) or candidate.actionCost
    local movementOnly = candidate.movementOnly == true
    if AI.CandidateMovementOnly ~= nil then
        movementOnly = AI:CandidateMovementOnly(candidate)
    end
    if actor == nil or info == nil or actionCost ~= "action" or movementOnly then
        return false
    end

    local manualPrompt = candidate.manualPrompt == true
    if AI.CandidateManualPrompt ~= nil then
        manualPrompt = AI:CandidateManualPrompt(candidate)
    end
    if not info.hasDamage or manualPrompt then
        return false
    end

    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets) do
        local tok = target and target.token
        if tok ~= nil and setupTargetKeys[StableTokenKey(tok)] and not TokensFriendly(actor.token, tok) then
            return true
        end
    end

    return false
end

function Pipeline:ComboFollowupDelta(context, actor, setup, setupTargets, followup)
    if AI.PushSimulatedTargetConditions == nil or AI.ScoreTargets == nil then
        return nil
    end

    local followupTargets = AI.CandidateTargets and AI:CandidateTargets(followup) or followup.targets or {}
    local baseScore = SafeCall(function()
        return AI:ScoreTargets(context, actor, followup.abilityInfo, followupTargets, CandidatePrimaryAttackLoc(followup))
    end, nil)
    if baseScore == nil then
        return nil
    end

    local restore = AI:PushSimulatedTargetConditions(context, setupTargets, setup.abilityInfo)
    if restore == nil then
        return nil
    end

    local simulatedScore = SafeCall(function()
        return AI:ScoreTargets(context, actor, followup.abilityInfo, followupTargets, CandidatePrimaryAttackLoc(followup))
    end, nil)
    restore()

    if simulatedScore == nil then
        return nil
    end

    return (simulatedScore.total or 0) - (baseScore.total or 0), simulatedScore.total or 0
end

function Pipeline:ApplyComboLookahead(context, actor, flow, candidates, options, result)
    if flow ~= "turn" and flow ~= "analysisOnly" and flow ~= "manualPrompt" then
        return
    end

    for _,setup in ipairs(candidates or {}) do
        if self:CandidateCanSetupCombo(actor, setup) then
            local setupTargets, setupTargetKeys = self:HostileComboSetupTargets(actor, setup)
            local best = nil

            for _,followup in ipairs(candidates or {}) do
                if followup ~= setup and self:CandidateCanFollowCombo(actor, followup, setupTargetKeys) then
                    local delta, simulatedTotal = self:ComboFollowupDelta(context, actor, setup, setupTargets, followup)
                    if delta ~= nil and delta >= ConstNumber("Score", "ComboLookaheadMinimumDelta", 0.5) then
                        if best == nil
                            or simulatedTotal > best.simulatedTotal
                            or (simulatedTotal == best.simulatedTotal and self:CandidateComesBefore(followup, best.followup, flow))
                        then
                            best = {
                                followup = followup,
                                delta = delta,
                                simulatedTotal = simulatedTotal,
                            }
                        end
                    end
                end
            end

            if best ~= nil then
                local bonus = math.min(ConstNumber("Score", "ComboLookaheadCap", 4), best.delta * ConstNumber("Score", "ComboLookaheadMultiplier", 1))
                if bonus > 0 then
                    AddScore(setup.scoreInfo, "combo lookahead", bonus)
                    local setupTargetKey = nil
                    for key,_ in pairs(setupTargetKeys) do
                        if setupTargetKey == nil or key < setupTargetKey then
                            setupTargetKey = key
                        end
                    end
                    local comboLookahead = {
                        bonus = bonus,
                        delta = best.delta,
                        setupTargetKey = setupTargetKey,
                        followupDescription = CandidateDescription(best.followup),
                    }
                    if AI.WriteCandidateScore ~= nil then
                        AI:WriteCandidateScore(setup, {
                            scoreInfo = setup.scoreInfo,
                            total = setup.scoreInfo.total,
                            comboLookahead = comboLookahead,
                        })
                    else
                        setup.score = setup.scoreInfo.total
                        setup.comboLookahead = comboLookahead
                        if AI.SyncCandidateSections ~= nil then
                            AI:SyncCandidateSections(setup)
                        end
                    end
                end
            end
        end
    end
end

function Pipeline:ApplyResourcePolicy(context, actor, flow, candidates, options, result)
    if flow ~= "turn" and flow ~= "analysisOnly" and flow ~= "manualPrompt" then
        return
    end

    local best = self:BestCandidate(candidates, flow)
    local bestNonMalice = self:BestCandidate(candidates, flow, function(candidate)
        return candidate.abilityInfo == nil or not candidate.abilityInfo.isMalice
    end)

    if best ~= nil and best.abilityInfo ~= nil and best.abilityInfo.isMalice and bestNonMalice ~= nil then
        local resourceThreshold = AI:DifficultyTuning(context).resourceThreshold
        local maliceCost = AI:MaliceCost(best.abilityInfo)
        local adjustedThreshold = math.max(0, resourceThreshold - maliceCost * ConstNumber("Candidate", "MaliceResourceThresholdCostDiscount", 0.5))
        if CandidateScore(best, flow) < CandidateScore(bestNonMalice, flow) + adjustedThreshold then
            result.heldReason = string.format("malice held below non-malice by %0.1f", adjustedThreshold)
            AI:Trace("pipeline", "malice held", {
                flow = flow,
                malice = CandidateDescription(best),
                maliceScore = CandidateScore(best, flow),
                nonMalice = CandidateDescription(bestNonMalice),
                nonMaliceScore = CandidateScore(bestNonMalice, flow),
                threshold = adjustedThreshold,
            })
            if not options.silent then
                AI:Log(string.format("Malice candidate %s held because it did not beat non-malice by %0.1f.", CandidateDescription(best), adjustedThreshold))
            end
            return bestNonMalice
        end
    end
end

local function AddPolicyAdjustment(candidate, adjustment)
    if candidate == nil or adjustment == nil then
        return
    end

    local score = AI.CandidateScoreSection and AI:CandidateScoreSection(candidate) or {}
    local policyAdjustments = score.policyAdjustments
    if type(policyAdjustments) ~= "table" then
        policyAdjustments = {}
    end
    policyAdjustments[#policyAdjustments+1] = adjustment
    if AI.WriteCandidateScore ~= nil then
        AI:WriteCandidateScore(candidate, {
            policyAdjustments = policyAdjustments,
        }, {
            mirrorRoot = false,
        })
    else
        candidate.normalized = candidate.normalized or {}
        candidate.normalized.score = candidate.normalized.score or {}
        candidate.normalized.score.policyAdjustments = policyAdjustments
    end
end

function Pipeline:ApplyPolicyScores(context, actor, flow, candidates, options, result)
    options = options or {}
    result = result or {}
    if flow ~= "turn" and flow ~= "analysisOnly" and flow ~= "manualPrompt" then
        return
    end

    local ordered = {}
    for i,candidate in ipairs(candidates or {}) do
        ordered[#ordered+1] = {
            candidate = candidate,
            key = self:MakeOrderingKey(candidate, flow, i),
        }
    end
    table.sort(ordered, function(a, b)
        return OrderingKeyComesBefore(a.key, b.key)
    end)

    local singleIndex = nil
    local areaIndex = nil
    for i,entry in ipairs(ordered) do
        local candidate = entry.candidate
        if singleIndex == nil and CandidateIsSingleTargetMainAction(candidate) then
            singleIndex = i
        end
        if areaIndex == nil and CandidateIsSafeAreaMainAction(candidate) then
            areaIndex = i
        end
        if singleIndex ~= nil and areaIndex ~= nil then
            break
        end
    end

    if singleIndex == nil or areaIndex == nil or areaIndex < singleIndex then
        return
    end

    local single = ordered[singleIndex].candidate
    local area = ordered[areaIndex].candidate
    local margin = ConstNumber("Candidate", "AreaMainActionPromotionMargin", 3)
    local singleScore = CandidateScore(single, flow)
    local areaScore = CandidateScore(area, flow)
    local singleFinishes = CandidateScoreHasLabel(single, "finish")
    local areaFinishes = CandidateScoreHasLabel(area, "finish")
    local blockedByFinish = singleFinishes and not areaFinishes

    if areaScore + margin < singleScore or blockedByFinish then
        AI:Trace("pipeline", "area main action comparison", {
            flow = flow,
            selected = CandidateDescription(single),
            selectedScore = singleScore,
            selectedParts = ScoreText(single.scoreInfo),
            area = CandidateDescription(area),
            areaScore = areaScore,
            areaParts = ScoreText(area.scoreInfo),
            margin = margin,
            blockedByFinish = blockedByFinish,
        })
        return
    end

    area.scoreInfo = area.scoreInfo or CreateScore()
    area.scoreInfo.total = area.scoreInfo.total or areaScore
    area.scoreInfo.parts = area.scoreInfo.parts or {}
    area.scoreInfo.labels = area.scoreInfo.labels or {}
    local bonus = math.max(0.1, (singleScore - areaScore) + 0.1)
    AddScore(area.scoreInfo, "policy area main pressure", bonus)
    AddPolicyAdjustment(area, {
        id = "area-main-action-pressure",
        amount = bonus,
        reason = "safe area main action within promotion margin",
        over = CandidateDescription(single),
        margin = margin,
        previousScore = areaScore,
        comparisonScore = singleScore,
    })
    if AI.WriteCandidateScore ~= nil then
        AI:WriteCandidateScore(area, {
            scoreInfo = area.scoreInfo,
            total = area.scoreInfo.total,
        })
    else
        area.score = area.scoreInfo.total
        if AI.SyncCandidateSections ~= nil then
            AI:SyncCandidateSections(area)
        end
    end
    result.policyAdjustments = result.policyAdjustments or {}
    result.policyAdjustments[#result.policyAdjustments+1] = {
        id = "area-main-action-pressure",
        candidate = CandidateDescription(area),
        amount = bonus,
        over = CandidateDescription(single),
    }

    AI:Trace("pipeline", "area main action policy score applied", {
        flow = flow,
        area = CandidateDescription(area),
        areaScore = area.scoreInfo.total,
        previousAreaScore = areaScore,
        areaParts = ScoreText(area.scoreInfo),
        over = CandidateDescription(single),
        overScore = singleScore,
        overParts = ScoreText(single.scoreInfo),
        margin = margin,
        bonus = bonus,
    })
    if not options.silent then
        AI:Log(string.format(
            "Area main action policy score: %s over %s (%0.1f vs %0.1f).",
            CandidateDescription(area),
            CandidateDescription(single),
            area.scoreInfo.total,
            singleScore
        ))
    end
end

function Pipeline:Rank(context, actor, flow, candidates, options, result, promoted)
    table.sort(candidates, function(a, b)
        return self:CandidateComesBefore(a, b, flow)
    end)

    if promoted ~= nil then
        for i,candidate in ipairs(candidates) do
            if candidate == promoted then
                table.remove(candidates, i)
                table.insert(candidates, 1, candidate)
                break
            end
        end
    end

    if flow == "turn" or flow == "analysisOnly" or flow == "manualPrompt" then
        AI:PromoteStandUpWhenProne(actor, candidates)
        AI:PromoteAdvanceOverRangedFreeStrike(candidates)
    end
end

function Pipeline:RecordOrderingKeys(candidates, flow, result)
    result.orderingKeys = {}
    for i,candidate in ipairs(candidates or {}) do
        local key = candidate.orderingKey or self:MakeOrderingKey(candidate, flow, i)
        result.orderingKeys[#result.orderingKeys+1] = {
            index = i,
            id = candidate.id,
            score = key.score,
            maliceTie = key.maliceTie,
            targetSignature = key.targetSignature,
            actorKey = key.actorKey,
            locKey = key.locKey,
            actionCost = key.actionCost,
            description = CandidateDescription(candidate),
        }
    end
end

function Pipeline:LogRanked(context, actor, flow, candidates, options)
    if options.silent or flow == "trigger" then
        return
    end

    AI.log.candidates = {}
    local candidateCounts = {}
    for _,candidate in ipairs(candidates) do
        local description = CandidateDescription(candidate)
        candidateCounts[description] = (candidateCounts[description] or 0) + 1
    end

    local loggedDescriptions = {}
    for i=1,#candidates do
        if #AI.log.candidates >= ConstNumber("Candidate", "LogLimit", 12) then
            break
        end

        local candidate = candidates[i]
        local description = CandidateDescription(candidate)
        if not loggedDescriptions[description] then
            loggedDescriptions[description] = true
            local count = candidateCounts[description] or 1
            if count > 1 then
                description = string.format("%s (best of %d)", description, count)
            end
            local decisionSuffix = ""
            if AI.config.debug and AI.AutomationDecisionSummary ~= nil then
                local decisionSummary = AI:AutomationDecisionSummary(candidate)
                if decisionSummary ~= nil and decisionSummary ~= "" then
                    decisionSuffix = " {" .. decisionSummary .. "}"
                end
            end
            AI.log.candidates[#AI.log.candidates+1] = string.format("%0.1f %s%s [%s]", CandidateScore(candidate, flow), description, decisionSuffix, ScoreText(candidate.scoreInfo))
        end
    end

    if flow == "turn" or flow == "analysisOnly" or flow == "manualPrompt" then
        AI:LogCandidatePerfSummary(context)
    end
    AI:TouchLog()
end

function Pipeline:Select(context, actor, flow, candidates, options, result)
    if #candidates == 0 then
        if result.heldReason == nil then
            result.heldReason = "no candidates"
        end

        if flow == "turn" and actor ~= nil then
            AI:Log("No legal automated action for " .. TokenName(actor.token))
            AI:SetStatus("Held: no legal automated action for " .. TokenName(actor.token))
        end

        return nil
    end

    if flow == "turn" then
        local threshold = CandidateThreshold(actor, candidates[1], ConstNumber("Candidate", "ActorSelectionThreshold", 0.8))
        if CandidateScore(candidates[1], flow) < threshold then
            result.heldReason = "best option below threshold"
            AI:Log(string.format("Best candidate was below threshold: %s (%0.1f < %0.1f)", tostring(CandidateDescription(candidates[1])), CandidateScore(candidates[1], flow), threshold))
            LogTopCandidatesBelowThreshold(actor, candidates, threshold)
            AI:SetStatus("Held: best option was below threshold for " .. TokenName(actor.token))
            return nil
        end
    elseif flow == "startTurnMalice" then
        local threshold = AI:DifficultyTuning(context).resourceThreshold
        threshold = math.max(ConstNumber("Candidate", "StartTurnMaliceThresholdMinimum", 1), threshold * ConstNumber("Candidate", "StartTurnMaliceThresholdMultiplier", 0.5))
        if CandidateScore(candidates[1], flow) < threshold then
            result.heldReason = "start-turn malice below threshold"
            return nil
        end
    elseif flow == "trigger" then
        if CandidateScore(candidates[1], flow) <= ConstNumber("Candidate", "TriggerPositiveThreshold", 0) then
            result.heldReason = "trigger score not positive"
            return nil
        end
    end

    return candidates[1]
end

function Pipeline:Run(context, actor, flow, options)
    options = options or {}
    flow = flow or "turn"

    if options.silent == true and options._pipelineSilentWrapped ~= true then
        return AI:RunWithSilentLog(function()
            local wrappedOptions = CopyOptions(options)
            wrappedOptions._pipelineSilentWrapped = true
            return self:Run(context, actor, flow, wrappedOptions)
        end)
    end

    AI:Trace("pipeline", "run", {
        flow = flow,
        actor = TraceActorName(actor),
        silent = options.silent == true,
        previousRound = options.previousRound,
        token = options.token and TokenName(options.token),
    }, TraceOptionsForFlow(flow))

    local result = {
        selected = nil,
        ranked = {},
        heldReason = nil,
        flowFlags = self:FlowFlags(flow, options),
        orderingKeys = {},
        comboHook = function(candidate)
            local score = AI.CandidateScoreSection and AI:CandidateScoreSection(candidate) or {}
            return score.comboLookahead or candidate and candidate.comboLookahead or nil
        end,
    }

    if not self.ValidFlows[flow] then
        result.heldReason = "unsupported flow: " .. tostring(flow)
        AI:Trace("pipeline", "unsupported flow", { flow = flow, heldReason = result.heldReason })
        return result
    end

    self:Analyze(context, actor, flow, options, result)
    if not self:Gate(context, actor, flow, options, result) then
        AI:Trace("pipeline", "gate held", {
            flow = flow,
            actor = TraceActorName(actor),
            heldReason = result.heldReason,
        }, TraceOptionsForFlow(flow))
        return result
    end

    local candidates = self:Enumerate(context, actor, flow, options, result) or {}
    AI:Trace("pipeline", "enumerated", {
        flow = flow,
        actor = TraceActorName(actor),
        count = #candidates,
    }, TraceOptionsForFlow(flow))
    candidates = self:FilterRejectedCandidates(context, actor, flow, candidates, options, result) or {}
    AI:Trace("pipeline", "after rejection filter", {
        flow = flow,
        actor = TraceActorName(actor),
        count = #candidates,
        heldReason = result.heldReason,
        rejected = result.rejectedCount,
    }, TraceOptionsForFlow(flow))
    self:Score(context, actor, flow, candidates, options, result)
    self:ApplyComboLookahead(context, actor, flow, candidates, options, result)
    self:ApplyPolicyScores(context, actor, flow, candidates, options, result)
    self:PrepareOrderingKeys(candidates, flow)
    local promoted = self:ApplyResourcePolicy(context, actor, flow, candidates, options, result)
    self:Rank(context, actor, flow, candidates, options, result, promoted)
    self:RecordOrderingKeys(candidates, flow, result)

    result.ranked = candidates
    result.selected = self:Select(context, actor, flow, candidates, options, result)
    TraceTopCandidates(flow, candidates)
    local selectedRetryKey = result.selected and (AI.CandidateRetryKey and AI:CandidateRetryKey(result.selected) or result.selected.retryKey) or nil
    local selectedFamilyKey = result.selected and (AI.CandidateFamilyRejectionKey and AI:CandidateFamilyRejectionKey(result.selected) or nil) or nil
    AI:Trace("pipeline", "selection result", {
        flow = flow,
        actor = TraceActorName(actor),
        selected = result.selected and CandidateDescription(result.selected),
        heldReason = result.heldReason,
        ranked = #candidates,
        retryKey = selectedRetryKey,
        familyKey = selectedFamilyKey,
    }, TraceOptionsForFlow(flow))
    self:LogRanked(context, actor, flow, candidates, options)

    return result
end
