local mod = dmhub.GetModLoading()

-- DirectorTacticsCandidates.lua builds legal tactical candidates from abilities, movement, areas, squads, and advance actions.
-- Load after DirectorTacticsScoring.lua and before DirectorTacticsExecution.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsCandidates.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal

local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local Lower = Internal.Lower
local TokenName = Internal.TokenName
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local TokenId = Internal.TokenId
local AbilityRange = Internal.AbilityRange
local AbilityCanAfford = Internal.AbilityCanAfford
local TargetPasses = Internal.TargetPasses
local HasLineOfSight = Internal.HasLineOfSight
local CreateScore = Internal.CreateScore
local AddScore = Internal.AddScore
local CopySymbols = Internal.CopySymbols
local LocKey = Internal.LocKey
local LocOccupancyKey = Internal.LocOccupancyKey
local ConstNumber = Internal.ConstNumber

local function CacheTokenKey(token)
    return tostring(TokenId(token) or TryGet(token, "id", nil) or token or "")
end

local function LineOfSightSubjectKey(subject, loc, prefix)
    prefix = prefix or "subject"
    if subject ~= nil and TryGet(subject, "properties", nil) ~= nil then
        return prefix .. ":token:" .. CacheTokenKey(subject)
    end

    return prefix .. ":loc:" .. LocKey(loc or subject)
end

local function TargetAreaCacheKey(targetArea)
    if targetArea == nil then
        return ""
    end

    return table.concat({
        tostring(TryGet(targetArea, "shape", "")),
        LocKey(TryGet(targetArea, "origin", nil)),
        tostring(TryGet(targetArea, "radius", "")),
        tostring(TryGet(targetArea, "range", "")),
        tostring(targetArea),
    }, ":")
end

local VALID_LEGALITY_KINDS = {
    target = true,
    area = true,
}

local function ContractReasonCode(reason, fallback)
    local code = tostring(reason or fallback or "ok")
    code = string.lower(code)
    code = string.gsub(code, "[^%w]+", "_")
    code = string.gsub(code, "^_+", "")
    code = string.gsub(code, "_+$", "")
    if code == "" then
        code = tostring(fallback or "ok")
    end
    return code
end

function AI:MakeLegalityResult(args)
    args = args or {}
    local kind = args.kind
    if not VALID_LEGALITY_KINDS[kind] then
        kind = "target"
    end

    local ok = args.ok == true
    return {
        ok = ok,
        kind = kind,
        phase = args.phase,
        reasonCode = args.reasonCode or ContractReasonCode(args.reason, Pick(ok, "ok", kind .. "_illegal")),
        reason = args.reason,
        friendly = args.friendly,
        target = args.target or args.targetToken,
        loc = args.loc,
        area = args.area or args.targetArea,
        engine = args.engine,
        details = args.details,
    }
end

function AI:LegalityResultFromTuple(ok, reason, args)
    args = args or {}
    return self:MakeLegalityResult{
        ok = ok == true,
        kind = args.kind,
        phase = args.phase,
        reasonCode = args.reasonCode,
        reason = reason or args.reason,
        friendly = args.friendly,
        target = args.target or args.targetToken,
        loc = args.loc,
        area = args.area or args.targetArea,
        engine = args.engine,
        details = args.details,
    }
end

function AI:LegalityResultToTuple(result)
    if type(result) ~= "table" then
        return result == true, nil, nil
    end

    return result.ok == true, result.reason, result.friendly
end

local function AssignmentSortKey(member, target, loc, chargeLoc)
    return table.concat({
        CacheTokenKey(member and member.token),
        CacheTokenKey(target),
        LocKey(loc),
        LocKey(chargeLoc),
    }, "|")
end

local AnonymousAbilityKeys = setmetatable({}, { __mode = "k" })
local anonymousAbilityKeyCounter = 0

local function AnonymousAbilityKey(ability)
    local abilityType = type(ability)
    if abilityType ~= "table" and abilityType ~= "userdata" and abilityType ~= "function" then
        return nil
    end

    local key = AnonymousAbilityKeys[ability]
    if key == nil then
        anonymousAbilityKeyCounter = anonymousAbilityKeyCounter + 1
        key = "anon:" .. tostring(anonymousAbilityKeyCounter)
        AnonymousAbilityKeys[ability] = key
    end

    return key
end

local function CacheAbilityKey(ability, abilityInfo)
    ability = ability or (abilityInfo and abilityInfo.ability)
    local guid = TryGet(ability, "guid", nil)
    if guid ~= nil and tostring(guid) ~= "" then
        return "guid:" .. tostring(guid)
    end

    local id = TryGet(ability, "id", nil)
    if id ~= nil and tostring(id) ~= "" then
        return "id:" .. tostring(id)
    end

    local anonymousKey = AnonymousAbilityKey(ability)
    if anonymousKey ~= nil then
        return anonymousKey
    end

    return "name:" .. tostring(abilityInfo and abilityInfo.name or ability or "")
end

local function AbilityModeListSummary(ai, ability)
    local modeList = TryGet(ability, "modeList", nil)
    if type(modeList) ~= "table" or #modeList == 0 then
        return nil
    end

    local parts = {}
    for index,mode in ipairs(modeList) do
        local text = ai.GrabModeText and ai:GrabModeText(mode, index) or TryGet(mode, "text", TryGet(mode, "name", "mode " .. tostring(index)))
        parts[#parts+1] = tostring(index) .. ":" .. tostring(text)
    end

    return table.concat(parts, " | ")
end

function AI:TraceAbilityInventory(actor, ability, abilityInfo, skipReason, modeSelection)
    if self.TraceActive ~= nil and not self:TraceActive() then
        return
    end

    abilityInfo = abilityInfo or {}
    self:Trace("ability", "inventory", {
        actor = TokenName(actor and actor.token),
        ability = TryGet(ability, "name", abilityInfo.name or "Ability"),
        guid = TryGet(ability, "guid", TryGet(ability, "id", nil)),
        actionCost = self.AbilityActionCost and self:AbilityActionCost(abilityInfo) or nil,
        targetType = abilityInfo.targetType,
        targetFilter = abilityInfo.targetFilter,
        targetAllegiance = abilityInfo.targetAllegiance,
        isAction = abilityInfo.isAction,
        isManeuver = abilityInfo.isManeuver,
        isArea = abilityInfo.isArea,
        hasAura = abilityInfo.hasAura,
        areaShape = self.AreaShapeName and self:AreaShapeName(abilityInfo) or nil,
        requiresPrompt = abilityInfo.requiresPrompt,
        manualPromptRisk = abilityInfo.manualPromptRisk,
        multipleModes = TryGet(ability, "multipleModes", nil),
        modes = AbilityModeListSummary(self, ability),
        modeSelection = modeSelection and tostring(modeSelection.index) .. ":" .. tostring(modeSelection.text) or nil,
        skipReason = skipReason,
    })
end

-- CandidateProposal compatibility envelope.
--
-- Core fields:
--   id, actor, ability, abilityInfo, actionType, loc, preInvokeMove,
--   targets, targetArea, symbols, scoreInfo, score, enumeratorRule.
--
-- Legacy passthrough fields stay on the root table until their flows are
-- deliberately migrated: manualPrompt, startTurnMalice, endRoundVillain,
-- triggerPolicy, movementOnly, areaAnchorLoc, targetPairs, squadAssignments,
-- squadSupportMoves, advanceTargetLoc, modeSelection, and related manual prompt fields.
-- This lets old ad-hoc candidates and new CandidateProposal-shaped candidates
-- coexist while Phase 3 migrates only the single-token pre-invoke movement path.

local ActionEconomySkipReasons = {
    ["main action already used"] = true,
    ["maneuver already used"] = true,
    ["move already used"] = true,
    ["minion squad already used main action or maneuver"] = true,
    ["turn already ended"] = true,
    ["dazed actor already used one turn option"] = true,
}

local function LogActionEconomySkipOnce(ai, actor, ability, reason)
    if not ActionEconomySkipReasons[tostring(reason)] then
        return
    end

    if actor == nil then
        return
    end

    actor.turnMemory = actor.turnMemory or {}
    actor.turnMemory._directorLoggedEconomySkips = actor.turnMemory._directorLoggedEconomySkips or {}
    if actor.turnMemory._directorLoggedEconomySkips[reason] then
        return
    end

    actor.turnMemory._directorLoggedEconomySkips[reason] = true
    ai:Log(string.format(
        "Action economy blocked %s for %s: %s",
        tostring(ability and ability.name or "ability"),
        TokenName(actor.token),
        tostring(reason)
    ))
end

local function CacheSymbolsKey(symbols)
    if symbols == nil then
        return ""
    end

    return table.concat({
        tostring(TryGet(symbols, "mode", "")),
        tostring(TryGet(symbols, "charges", "")),
        tostring(TryGet(symbols, "upcast", "")),
        tostring(TryGet(symbols, "targetArea", "")),
    }, ":")
end

local AutomationDecisionOutcomes = {
    exact_auto = true,
    safe_approximate_auto = true,
    manual_before_execution = true,
    skip_with_fallback = true,
}

local AutomationDecisionLanes = {
    turn = true,
    trigger = true,
    villain = true,
    start_turn_malice = true,
}

local function CopyNameList(list)
    local result = {}
    for _,entry in ipairs(list or {}) do
        result[#result+1] = entry
    end
    return result
end

local function FirstNonNil(primary, fallback)
    if primary ~= nil then
        return primary
    end

    return fallback
end

local function AutomationDecisionLane(candidate)
    local lane = candidate and (candidate.automationLane or candidate.lane)
    if AutomationDecisionLanes[lane] then
        return lane
    end

    local intent = type(candidate and candidate.intent) == "table" and candidate.intent or {}
    if candidate ~= nil and (candidate.triggerPolicy ~= nil or intent.triggerPolicy ~= nil) then
        return "trigger"
    end

    local abilityInfo = candidate and candidate.abilityInfo
    if candidate ~= nil and (candidate.startTurnMalice or intent.startTurnMalice or (abilityInfo ~= nil and abilityInfo.isStartTurnMalice)) then
        return "start_turn_malice"
    end

    if candidate ~= nil and (candidate.endRoundVillain or intent.endRoundVillain or (abilityInfo ~= nil and abilityInfo.isVillain)) then
        return "villain"
    end

    return "turn"
end

local function AutomationCapabilities(ai, abilityInfo, candidate)
    abilityInfo = abilityInfo or {}
    candidate = candidate or {}
    local intent = type(candidate.intent) == "table" and candidate.intent or {}

    local targetType = Lower(abilityInfo.targetType or "")
    local resourceCost = abilityInfo.resourceCost
    local terrainOrObject = targetType == "map"
        or targetType == "areatemplate"
        or targetType == "emptyspace"
        or targetType == "emptyspacefriend"
        or targetType == "anyspace"

    local areaPlacement = candidate.targetArea ~= nil or intent.targetArea ~= nil
    if not areaPlacement and ai ~= nil and ai.IsAreaAbilityInfo ~= nil then
        areaPlacement = SafeCall(function()
            return ai:IsAreaAbilityInfo(abilityInfo)
        end, false) == true
    end

    return {
        damage = abilityInfo.hasDamage == true,
        conditions = CopyNameList(abilityInfo.conditionApplyNames),
        conditionRemoval = CopyNameList(abilityInfo.conditionRemovalNames),
        forcedMovement = abilityInfo.hasForcedMovement == true,
        areaPlacement = areaPlacement,
        summon = abilityInfo.hasSummon == true,
        terrainOrObject = terrainOrObject,
        allyActionGrant = false,
        resourceSpend = abilityInfo.isMalice == true
            or abilityInfo.usesMaliceResource == true
            or (resourceCost ~= nil and resourceCost ~= "" and resourceCost ~= "none"),
        modeChoice = candidate.modeSelection ~= nil
            or intent.modeSelection ~= nil
            or TryGet(TryGet(abilityInfo, "ability", nil), "multipleModes", false) == true,
        nestedPrompt = abilityInfo.hasInvoke == true
            or abilityInfo.requiresPrompt == true
            or abilityInfo.manualPromptRisk == true,
        prompt = candidate.promptCapability,
        support = abilityInfo.hasSupport == true,
    }
end

function AI:MakeAutomationDecision(args)
    args = args or {}
    local outcome = args.outcome
    if not AutomationDecisionOutcomes[outcome] then
        outcome = "exact_auto"
    end

    local lane = args.lane
    if not AutomationDecisionLanes[lane] then
        lane = "turn"
    end

    return {
        outcome = outcome,
        lane = lane,
        source = args.source or "candidate-safety",
        reason = args.reason or outcome,
        capabilities = args.capabilities or {},
        approximation = args.approximation or false,
        fallback = args.fallback or false,
        manualBeforeExecution = args.manualBeforeExecution == true or outcome == "manual_before_execution",
        partialPromptHandoff = false,
    }
end

function AI:AnnotatePromptCapability(candidate, promptCapability)
    if candidate == nil or type(promptCapability) ~= "table" then
        return candidate
    end

    candidate.promptCapability = promptCapability
    if type(candidate.automationDecision) == "table" then
        candidate.automationDecision.capabilities = candidate.automationDecision.capabilities or {}
        candidate.automationDecision.capabilities.prompt = promptCapability
    end

    return candidate
end

function AI:AutomationDecisionForCandidate(args)
    args = args or {}
    local intent = type(args.intent) == "table" and args.intent or {}
    local execution = type(args.execution) == "table" and args.execution or {}

    if type(args.automationDecision) == "table" then
        local decision = args.automationDecision
        decision.lane = decision.lane or AutomationDecisionLane(args)
        decision.capabilities = decision.capabilities or AutomationCapabilities(self, args.abilityInfo, args)
        if args.promptCapability ~= nil then
            decision.capabilities.prompt = args.promptCapability
        end
        return self:MakeAutomationDecision(decision)
    end

    local lane = AutomationDecisionLane(args)
    local capabilities = AutomationCapabilities(self, args.abilityInfo, args)
    local outcome = "exact_auto"
    local source = Pick(lane == "trigger", "trigger-policy", "candidate-safety")
    local reason = "candidate passed existing safety gates"
    local approximation = nil
    local fallback = nil
    local manualBeforeExecution = false

    local manualPrompt = FirstNonNil(args.manualPrompt, intent.manualPrompt)
    local manualPromptReason = FirstNonNil(args.manualPromptReason, intent.manualPromptReason)
    local modeSelection = FirstNonNil(args.modeSelection, intent.modeSelection)
    local targetArea = FirstNonNil(args.targetArea, intent.targetArea)
    local movementOnly = FirstNonNil(args.movementOnly, execution.movementOnly)

    if args.skipReason ~= nil then
        outcome = "skip_with_fallback"
        source = args.skipSource or "candidate-safety"
        reason = args.skipReason
        fallback = args.fallback or { kind = Pick(lane == "trigger", "no_trigger", "normal_candidate_enumeration") }
    elseif manualPrompt then
        outcome = "manual_before_execution"
        source = "manual-prompt"
        reason = manualPromptReason or "manual targeting"
        manualBeforeExecution = true
    elseif modeSelection ~= nil then
        outcome = "safe_approximate_auto"
        source = "mode-selection"
        reason = modeSelection.reason or "explicit safe mode selection"
        approximation = {
            kind = "mode_selection",
            mode = modeSelection.index,
            text = modeSelection.text,
            reason = modeSelection.reason or "explicit safe mode selection",
        }
    elseif movementOnly then
        reason = "legal movement-only candidate"
    elseif targetArea ~= nil then
        reason = "deterministic area candidate"
    elseif lane == "trigger" then
        reason = "trigger policy matched existing gates"
        fallback = { kind = "no_trigger" }
    end

    return self:MakeAutomationDecision{
        outcome = outcome,
        lane = lane,
        source = source,
        reason = reason,
        capabilities = capabilities,
        approximation = approximation,
        fallback = fallback,
        manualBeforeExecution = manualBeforeExecution,
    }
end

function AI:AutomationDecisionSummary(candidate)
    local decision = candidate and candidate.automationDecision
    if type(decision) ~= "table" then
        return nil
    end

    local summary = tostring(decision.outcome or "unknown") .. "/" .. tostring(decision.lane or "turn")
    if decision.reason ~= nil and decision.reason ~= "" then
        summary = summary .. ": " .. tostring(decision.reason)
    end
    return summary
end

local function EnsureCandidateSection(candidate, key)
    if candidate == nil then
        return {}
    end

    local section = candidate[key]
    if type(section) ~= "table" then
        section = {}
        candidate[key] = section
    end

    return section
end

local function ReadCandidateSection(candidate, key)
    if candidate == nil then
        return {}
    end

    local section = candidate[key]
    if type(section) == "table" then
        return section
    end

    return {}
end

local function EnsureNormalized(candidate)
    if candidate == nil then
        return {}
    end

    if type(candidate.normalized) ~= "table" then
        candidate.normalized = {}
    end

    return candidate.normalized
end

local function ReadNormalizedScore(candidate)
    local normalized = candidate and candidate.normalized
    if type(normalized) ~= "table" or type(normalized.score) ~= "table" then
        return {}
    end

    return normalized.score
end

local function ScoreInfoTotal(scoreInfo)
    if type(scoreInfo) == "table" and scoreInfo.total ~= nil then
        return scoreInfo.total
    end

    return nil
end

local IntentRootAliases = {
    actionCost = "actionCost",
    targets = "targets",
    targetArea = "targetArea",
    modeSelection = "modeSelection",
    manualPrompt = "manualPrompt",
    manualPromptReason = "manualPromptReason",
    startTurnMalice = "startTurnMalice",
    endRoundVillain = "endRoundVillain",
    villainRound = "villainRound",
    triggerPolicy = "triggerPolicy",
}

local ExecutionRootAliases = {
    loc = "loc",
    preInvokeMove = "preInvokeMove",
    symbols = "symbols",
    actionType = "actionType",
    actionGrant = "actionGrant",
    usesActionGrant = "usesActionGrant",
    actionGrantCommitted = "actionGrantCommitted",
    movementOnly = "movementOnly",
    areaAnchorLoc = "areaAnchorLoc",
    targetPairs = "targetPairs",
    squadAssignments = "squadAssignments",
    squadSupportMoves = "squadSupportMoves",
    advanceTargetLoc = "advanceTargetLoc",
    isAdvance = "isAdvance",
    isShift = "isShift",
}

local ScoreRootAliases = {
    total = "score",
    scoreInfo = "scoreInfo",
    startTurnScore = "startTurnScore",
    retryKey = "retryKey",
    enumeratorRule = "enumeratorRule",
    description = "description",
    orderingKey = "orderingKey",
    pipelineFlow = "pipelineFlow",
    comboLookahead = "comboLookahead",
    maliceCost = "maliceCost",
}

local function ClearFieldNames(clear)
    local names = {}
    if type(clear) == "string" then
        names[#names+1] = clear
    elseif type(clear) == "table" then
        for key,value in pairs(clear) do
            if type(key) == "number" then
                names[#names+1] = value
            elseif value == true then
                names[#names+1] = key
            end
        end
    end

    return names
end

local function MirrorRootAlias(candidate, key, value, rootAliases)
    local rootKey = rootAliases and rootAliases[key]
    if rootKey ~= nil then
        candidate[rootKey] = value
    end
end

local function WriteCandidateSection(candidate, sectionKey, fields, opts, rootAliases)
    if candidate == nil then
        return {}
    end

    fields = fields or {}
    opts = opts or {}
    local section = EnsureCandidateSection(candidate, sectionKey)
    local mirrorRoot = opts.mirrorRoot ~= false

    for key,value in pairs(fields) do
        section[key] = value
        if mirrorRoot then
            MirrorRootAlias(candidate, key, value, rootAliases)
        end
    end

    for _,key in ipairs(ClearFieldNames(opts.clear)) do
        section[key] = nil
        if mirrorRoot then
            MirrorRootAlias(candidate, key, nil, rootAliases)
        end
    end

    return section
end

function AI:WriteCandidateIntent(candidate, fields, opts)
    return WriteCandidateSection(candidate, "intent", fields, opts, IntentRootAliases)
end

function AI:WriteCandidateExecution(candidate, fields, opts)
    return WriteCandidateSection(candidate, "execution", fields, opts, ExecutionRootAliases)
end

function AI:WriteCandidateScore(candidate, fields, opts)
    if candidate == nil then
        return {}
    end

    fields = fields or {}
    opts = opts or {}
    local normalized = EnsureNormalized(candidate)
    local score = normalized.score
    if type(score) ~= "table" then
        score = {}
        normalized.score = score
    end

    local mirrorRoot = opts.mirrorRoot ~= false
    for key,value in pairs(fields) do
        score[key] = value
        if mirrorRoot then
            MirrorRootAlias(candidate, key, value, ScoreRootAliases)
        end
    end

    for _,key in ipairs(ClearFieldNames(opts.clear)) do
        score[key] = nil
        if mirrorRoot then
            MirrorRootAlias(candidate, key, nil, ScoreRootAliases)
        end
    end

    return score
end

local function TriggerNoOpFallback()
    return {
        kind = "no_trigger",
    }
end

function AI:NormalizeCandidate(candidate, opts)
    if candidate == nil then
        return nil
    end

    opts = opts or {}
    local existingIntent = ReadCandidateSection(candidate, "intent")
    local existingExecution = ReadCandidateSection(candidate, "execution")

    local movementOnly = FirstNonNil(candidate.movementOnly, existingExecution.movementOnly)
    local manualPrompt = FirstNonNil(candidate.manualPrompt, existingIntent.manualPrompt)
    local triggerPolicy = FirstNonNil(candidate.triggerPolicy, existingIntent.triggerPolicy)

    local intentFields = {
        role = existingIntent.role or "ability",
    }
    if movementOnly then
        intentFields.role = "movement"
    elseif manualPrompt then
        intentFields.role = "manual"
    elseif triggerPolicy ~= nil then
        intentFields.role = "trigger"
    end

    intentFields.actionCost = FirstNonNil(candidate.actionCost, existingIntent.actionCost)
    intentFields.targets = FirstNonNil(candidate.targets, existingIntent.targets)
    if intentFields.targets == nil then
        intentFields.targets = {}
    end
    intentFields.targetArea = FirstNonNil(candidate.targetArea, existingIntent.targetArea)
    intentFields.modeSelection = FirstNonNil(candidate.modeSelection, existingIntent.modeSelection)
    if manualPrompt ~= nil then
        intentFields.manualPrompt = manualPrompt == true
    end
    intentFields.manualPromptReason = FirstNonNil(candidate.manualPromptReason, existingIntent.manualPromptReason)
    local startTurnMalice = FirstNonNil(candidate.startTurnMalice, existingIntent.startTurnMalice)
    if startTurnMalice ~= nil then
        intentFields.startTurnMalice = startTurnMalice == true
    end
    local endRoundVillain = FirstNonNil(candidate.endRoundVillain, existingIntent.endRoundVillain)
    if endRoundVillain ~= nil then
        intentFields.endRoundVillain = endRoundVillain == true
    end
    intentFields.villainRound = FirstNonNil(candidate.villainRound, existingIntent.villainRound)
    intentFields.triggerPolicy = triggerPolicy
    self:WriteCandidateIntent(candidate, intentFields)

    local executionFields = {
        loc = FirstNonNil(candidate.loc, existingExecution.loc),
        preInvokeMove = FirstNonNil(candidate.preInvokeMove, existingExecution.preInvokeMove),
        symbols = FirstNonNil(candidate.symbols, existingExecution.symbols),
        actionType = FirstNonNil(candidate.actionType, existingExecution.actionType),
        actionGrant = FirstNonNil(candidate.actionGrant, existingExecution.actionGrant),
        areaAnchorLoc = FirstNonNil(candidate.areaAnchorLoc, existingExecution.areaAnchorLoc),
        targetPairs = FirstNonNil(candidate.targetPairs, existingExecution.targetPairs),
        squadAssignments = FirstNonNil(candidate.squadAssignments, existingExecution.squadAssignments),
        squadSupportMoves = FirstNonNil(candidate.squadSupportMoves, existingExecution.squadSupportMoves),
        advanceTargetLoc = FirstNonNil(candidate.advanceTargetLoc, existingExecution.advanceTargetLoc),
        usesActionGrant = FirstNonNil(candidate.usesActionGrant, existingExecution.usesActionGrant),
        actionGrantCommitted = FirstNonNil(candidate.actionGrantCommitted, existingExecution.actionGrantCommitted),
    }
    if movementOnly ~= nil then
        executionFields.movementOnly = movementOnly == true
    end
    local isAdvance = FirstNonNil(candidate.isAdvance, existingExecution.isAdvance)
    if isAdvance ~= nil then
        executionFields.isAdvance = isAdvance == true
    end
    local isShift = FirstNonNil(candidate.isShift, existingExecution.isShift)
    if isShift ~= nil then
        executionFields.isShift = isShift == true
    end
    self:WriteCandidateExecution(candidate, executionFields)

    local normalized = EnsureNormalized(candidate)
    local score = normalized.score
    if type(score) ~= "table" then
        score = {}
        normalized.score = score
    end

    local pipelineFlow = FirstNonNil(candidate.pipelineFlow, score.pipelineFlow)
    local startTurnScore = FirstNonNil(candidate.startTurnScore, score.startTurnScore)
    local effectiveScore = FirstNonNil(candidate.score, score.total)
    if pipelineFlow == "startTurnMalice" and startTurnScore ~= nil then
        effectiveScore = startTurnScore
    end

    local scoreFields = {}
    local scoreInfo = FirstNonNil(candidate.scoreInfo, score.scoreInfo)
    if scoreInfo ~= nil then
        scoreFields.scoreInfo = scoreInfo
        scoreFields.parts = scoreInfo.parts or score.parts
        scoreFields.labels = scoreInfo.labels or score.labels
        scoreFields.total = effectiveScore or ScoreInfoTotal(scoreInfo) or score.total or 0
    elseif effectiveScore ~= nil then
        scoreFields.total = effectiveScore
    elseif score.total == nil then
        scoreFields.total = 0
    end

    scoreFields.startTurnScore = startTurnScore
    scoreFields.retryKey = FirstNonNil(candidate.retryKey, score.retryKey)
    scoreFields.enumeratorRule = FirstNonNil(candidate.enumeratorRule, score.enumeratorRule)
    scoreFields.description = FirstNonNil(candidate.description, score.description)
    scoreFields.orderingKey = FirstNonNil(candidate.orderingKey, score.orderingKey)
    scoreFields.pipelineFlow = pipelineFlow
    scoreFields.comboLookahead = FirstNonNil(candidate.comboLookahead, score.comboLookahead)
    scoreFields.maliceCost = FirstNonNil(candidate.maliceCost, score.maliceCost)
    scoreFields.policyAdjustments = score.policyAdjustments
    self:WriteCandidateScore(candidate, scoreFields)

    if candidate.promptCapability ~= nil and type(candidate.automationDecision) == "table" then
        candidate.automationDecision.capabilities = candidate.automationDecision.capabilities or {}
        candidate.automationDecision.capabilities.prompt = candidate.promptCapability
    end

    local fallback = candidate.fallback
    if type(fallback) ~= "table" then
        local decisionFallback = candidate.automationDecision and candidate.automationDecision.fallback
        if type(decisionFallback) == "table" then
            fallback = decisionFallback
        elseif candidate.triggerPolicy ~= nil then
            fallback = TriggerNoOpFallback()
        else
            fallback = {
                kind = "normal_candidate_enumeration",
            }
        end
        candidate.fallback = fallback
    end

    return candidate
end

function AI:CandidateIntent(candidate)
    return ReadCandidateSection(candidate, "intent")
end

function AI:CandidateExecution(candidate)
    return ReadCandidateSection(candidate, "execution")
end

function AI:CandidateScoreSection(candidate)
    return ReadNormalizedScore(candidate)
end

function AI:CandidateFallback(candidate)
    if candidate == nil then
        return {}
    end

    local fallback = candidate.fallback
    if type(fallback) == "table" then
        return fallback
    end

    local decisionFallback = candidate.automationDecision and candidate.automationDecision.fallback
    if type(decisionFallback) == "table" then
        return decisionFallback
    end

    local triggerPolicy = self.CandidateTriggerPolicy and self:CandidateTriggerPolicy(candidate) or candidate.triggerPolicy
    if triggerPolicy ~= nil then
        return TriggerNoOpFallback()
    end

    fallback = {
        kind = "normal_candidate_enumeration",
    }
    return fallback
end

function AI:SyncCandidateSections(candidate)
    if candidate == nil then
        return nil
    end

    return self:NormalizeCandidate(candidate, { source = "root" })
end

function AI:CandidateScoreTotal(candidate, flow)
    if candidate == nil then
        return 0
    end

    local score = self:CandidateScoreSection(candidate)
    if flow == "startTurnMalice" then
        return score.startTurnScore or candidate.startTurnScore or score.total or candidate.score or 0
    end

    return score.total or candidate.score or 0
end

function AI:CandidateTargets(candidate)
    local intent = self:CandidateIntent(candidate)
    return intent.targets or candidate and candidate.targets or {}
end

function AI:CandidateActionCost(candidate)
    local intent = self:CandidateIntent(candidate)
    if intent.actionCost ~= nil then
        return intent.actionCost
    end

    return candidate and candidate.actionCost or nil
end

function AI:CandidateExecutionLoc(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.loc or candidate and candidate.loc or nil
end

function AI:CandidatePreInvokeMove(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.preInvokeMove or candidate and candidate.preInvokeMove or nil
end

function AI:CandidateExecutionSymbols(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.symbols or candidate and candidate.symbols or nil
end

function AI:CandidateActionGrant(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.actionGrant or candidate and candidate.actionGrant or nil
end

function AI:CandidateMovementOnly(candidate)
    local execution = self:CandidateExecution(candidate)
    if execution.movementOnly ~= nil then
        return execution.movementOnly == true
    end

    return candidate ~= nil and candidate.movementOnly == true
end

function AI:CandidateManualPrompt(candidate)
    local intent = self:CandidateIntent(candidate)
    if intent.manualPrompt ~= nil then
        return intent.manualPrompt == true
    end

    return candidate ~= nil and candidate.manualPrompt == true
end

function AI:CandidateManualPromptReason(candidate)
    local intent = self:CandidateIntent(candidate)
    return intent.manualPromptReason or candidate and candidate.manualPromptReason or nil
end

function AI:CandidateStartTurnMalice(candidate)
    local intent = self:CandidateIntent(candidate)
    if intent.startTurnMalice ~= nil then
        return intent.startTurnMalice == true
    end

    return candidate ~= nil and candidate.startTurnMalice == true
end

function AI:CandidateEndRoundVillain(candidate)
    local intent = self:CandidateIntent(candidate)
    if intent.endRoundVillain ~= nil then
        return intent.endRoundVillain == true
    end

    return candidate ~= nil and candidate.endRoundVillain == true
end

function AI:CandidateTriggerPolicy(candidate)
    local intent = self:CandidateIntent(candidate)
    return intent.triggerPolicy or candidate and candidate.triggerPolicy or nil
end

function AI:CandidateTargetArea(candidate)
    local intent = self:CandidateIntent(candidate)
    return intent.targetArea or candidate and candidate.targetArea or nil
end

function AI:CandidateModeSelection(candidate)
    local intent = self:CandidateIntent(candidate)
    return intent.modeSelection or candidate and candidate.modeSelection or nil
end

function AI:CandidateAreaAnchorLoc(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.areaAnchorLoc or candidate and candidate.areaAnchorLoc or nil
end

function AI:CandidateAdvanceTargetLoc(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.advanceTargetLoc or candidate and candidate.advanceTargetLoc or nil
end

function AI:CandidateSquadAssignments(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.squadAssignments or candidate and candidate.squadAssignments or {}
end

function AI:CandidateSquadSupportMoves(candidate)
    local execution = self:CandidateExecution(candidate)
    return execution.squadSupportMoves or candidate and candidate.squadSupportMoves or {}
end

function AI:TriggerAutomationSkipReason(token, trigger, triggerInfo)
    if trigger == nil then
        return "missing trigger"
    end

    if trigger.triggered then
        return "trigger already triggered"
    end

    if trigger.dismissed then
        return "trigger dismissed"
    end

    if self.ReactiveTriggersEnabled ~= nil and not self:ReactiveTriggersEnabled() then
        return "reactive triggers disabled"
    end

    if self.TargetHasCondition ~= nil and self:TargetHasCondition(token, "Dazed") then
        return "trigger actor Dazed"
    end

    if triggerInfo ~= nil and triggerInfo.available == false then
        return "trigger unavailable"
    end

    local heroicCost = tonumber(TryGet(trigger, "heroicResourceCost", 0)) or 0
    if heroicCost > 0 then
        local available = SafeCall(function()
            return token.properties:GetHeroicOrMaliceResourcesAvailableToSpend()
        end, 0) or 0
        if available < heroicCost then
            return "trigger heroic/malice cost unaffordable"
        end
    end

    local epicCost = tonumber(TryGet(trigger, "epicResourceCost", 0)) or 0
    if epicCost > 0 then
        local available = SafeCall(function()
            return token.properties:GetEpicResources()
        end, 0) or 0
        if available < epicCost then
            return "trigger epic cost unaffordable"
        end
    end

    if self.TriggerCanAutoActivate ~= nil
        and not self:TriggerCanAutoActivate(token, trigger, triggerInfo)
    then
        return "trigger not auto-activatable"
    end

    return nil
end

function AI:TriggerAutomationDecision(args)
    args = args or {}
    local policy = args.triggerPolicy or args.policy
    local policyId = args.policyId or TryGet(policy, "id", "trigger")
    local token = args.token
    local trigger = args.trigger
    local triggerInfo = args.triggerInfo
    local context = args.context
    local fallback = TriggerNoOpFallback()

    local function Skip(reason, source, promptCapability)
        return self:MakeAutomationDecision{
            outcome = "skip_with_fallback",
            lane = "trigger",
            source = source or "trigger-policy",
            reason = reason or "trigger skipped",
            capabilities = {
                trigger = true,
                prompt = promptCapability,
            },
            fallback = fallback,
        }
    end

    if policy == nil then
        return Skip("missing trigger policy")
    end

    if policy.execute == nil then
        return Skip("trigger policy has no executor", "trigger-policy")
    end

    local skipReason = self:TriggerAutomationSkipReason(token, trigger, triggerInfo)
    if skipReason ~= nil then
        return Skip(skipReason)
    end

    if triggerInfo == nil or triggerInfo.ability == nil then
        return Skip("ambiguous trigger ability")
    end

    local triggerActor = {
        token = token,
        context = context,
        allies = {},
        enemies = {},
    }
    local abilityInfo = SafeCall(function()
        return self:AnalyzeAbility(triggerActor, triggerInfo.ability)
    end, nil)

    if abilityInfo == nil then
        return Skip("ambiguous trigger ability")
    end

    local promptCapability = nil
    if self.AssessPromptCapability ~= nil then
        promptCapability = self:AssessPromptCapability(context, triggerActor, abilityInfo, {
            ability = triggerInfo.ability,
            abilityInfo = abilityInfo,
        })
    end

    if promptCapability ~= nil and promptCapability.status == "manual" then
        return Skip("trigger requires manual prompt: " .. tostring(promptCapability.reason or "manual targeting"), "manual-prompt", promptCapability)
    end

    if promptCapability ~= nil and promptCapability.status == "blocked" then
        return Skip("unsafe trigger prompt: " .. tostring(promptCapability.reason or "unresolved prompt"), "trigger-policy", promptCapability)
    end

    if self.AbilityHasPromptRisk ~= nil and self:AbilityHasPromptRisk(abilityInfo) then
        return Skip("trigger ability has prompt risk", "trigger-policy", promptCapability)
    end

    return self:MakeAutomationDecision{
        outcome = "exact_auto",
        lane = "trigger",
        source = "trigger-policy",
        reason = string.format("trigger policy %s matched%s", tostring(policyId), Pick(triggerInfo.event ~= nil, " " .. tostring(triggerInfo.event), "")),
        capabilities = {
            trigger = true,
            prompt = promptCapability,
        },
        fallback = fallback,
    }
end

function AI:TriggerCandidateCanAutoDispatch(candidate)
    if candidate == nil then
        return false, "missing trigger candidate"
    end

    local manualPrompt = candidate.manualPrompt == true
    if self.CandidateManualPrompt ~= nil then
        manualPrompt = self:CandidateManualPrompt(candidate)
    end
    if manualPrompt then
        return false, "trigger candidate requested manual prompt"
    end

    local decision = candidate.automationDecision
    if type(decision) ~= "table" then
        return false, "missing trigger automationDecision"
    end

    if decision.lane ~= "trigger" then
        return false, "automationDecision lane is not trigger"
    end

    if decision.outcome ~= "exact_auto" then
        return false, "automationDecision outcome is not exact_auto"
    end

    if decision.manualBeforeExecution == true then
        return false, "trigger automationDecision requested manual execution"
    end

    if candidate.partialPromptHandoff == true
        or (decision.partialPromptHandoff ~= nil and decision.partialPromptHandoff ~= false)
    then
        return false, "trigger automationDecision requested partial prompt handoff"
    end

    return true, nil
end

local function CandidateTargetParts(candidate)
    local parts = {}
    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets) do
        parts[#parts+1] = "target:" .. CacheTokenKey(target.token) .. ":" .. LocKey(target.loc) .. ":" .. LocKey(target["chargeLoc"])
    end
    local assignments = AI.CandidateSquadAssignments and AI:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
    for _,assignment in ipairs(assignments) do
        parts[#parts+1] = table.concat({
            "assignment",
            CacheTokenKey(assignment.member and assignment.member.token),
            CacheTokenKey(assignment.target),
            LocKey(assignment.loc),
            LocKey(assignment.chargeLoc),
        }, ":")
    end
    local supportMoves = AI.CandidateSquadSupportMoves and AI:CandidateSquadSupportMoves(candidate) or candidate.squadSupportMoves or {}
    for _,move in ipairs(supportMoves) do
        parts[#parts+1] = table.concat({
            "support",
            CacheTokenKey(move.member and move.member.token),
            LocKey(move.loc),
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function CandidatePreInvokeMoveParts(candidate)
    local move = AI.CandidatePreInvokeMove and AI:CandidatePreInvokeMove(candidate) or candidate and candidate.preInvokeMove
    if move == nil then
        return "preInvoke:none"
    end

    return table.concat({
        "preInvoke",
        tostring(move.mode or ""),
        LocKey(move.destination),
        tostring(move.tiles or ""),
        LocKey(move.path and move.path.destination),
    }, ":")
end

local function CandidateFamilyTargetParts(candidate)
    local parts = {}
    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate and candidate.targets or {}
    for _,target in ipairs(targets or {}) do
        if target ~= nil and target.token ~= nil then
            parts[#parts+1] = "target:" .. CacheTokenKey(target.token)
        elseif target ~= nil and target.loc ~= nil then
            parts[#parts+1] = "loc:" .. LocKey(target.loc)
        end
    end

    local targetArea = AI.CandidateTargetArea and AI:CandidateTargetArea(candidate) or candidate and candidate.targetArea
    if targetArea ~= nil then
        parts[#parts+1] = "area:" .. TargetAreaCacheKey(targetArea)
    end

    table.sort(parts)
    return table.concat(parts, "|")
end

local function CandidateModeKey(candidate)
    local mode = AI.CandidateModeSelection and AI:CandidateModeSelection(candidate) or candidate and candidate.modeSelection
    if type(mode) ~= "table" then
        return ""
    end

    return tostring(mode.index or "") .. ":" .. tostring(mode.text or "")
end

local function PromptFailureRejectsCandidateFamily(reason)
    reason = Lower(reason)
    return string.find(reason, "blocked prompt before execution", 1, true) ~= nil
        or string.find(reason, "unresolved nested prompt", 1, true) ~= nil
        or string.find(reason, "no automated prompt policy", 1, true) ~= nil
end

function AI:CandidateRetryKey(candidate)
    if candidate == nil then
        return ""
    end

    local execution = self:CandidateExecution(candidate)
    local score = self:CandidateScoreSection(candidate)
    return table.concat({
        tostring(TryGet(candidate.ability, "guid", TryGet(candidate.ability, "id", TryGet(candidate.ability, "name", "")))),
        tostring(score.description or candidate.description or ""),
        tostring(self:CandidateActionCost(candidate) or ""),
        LocKey(execution.loc or candidate.loc),
        CandidatePreInvokeMoveParts(candidate),
        LocKey(execution.advanceTargetLoc or candidate.advanceTargetLoc),
        CandidateTargetParts(candidate),
    }, "|")
end

function AI:FinalizeCandidateIdentity(candidate)
    if candidate == nil then
        return nil
    end

    self:NormalizeCandidate(candidate, { source = "root" })
    local retryKey = self:CandidateRetryKey(candidate)
    self:WriteCandidateScore(candidate, {
        retryKey = retryKey,
    })

    return retryKey
end

function AI:CandidateFamilyRejectionKey(candidate)
    if candidate == nil then
        return ""
    end

    local score = self:CandidateScoreSection(candidate)
    return table.concat({
        "family",
        CacheAbilityKey(candidate.ability, candidate.abilityInfo),
        tostring(score.description or candidate.description or ""),
        tostring(self:CandidateActionCost(candidate) or ""),
        CandidateModeKey(candidate),
        CandidateFamilyTargetParts(candidate),
    }, "|")
end

function AI:CandidateRejectionKeys(candidate, reason, includeFamilyKeys)
    local keys = {}
    local seen = {}
    local function Add(key)
        if key == nil then
            return
        end

        key = tostring(key)
        if key == "" or seen[key] then
            return
        end

        seen[key] = true
        keys[#keys+1] = key
    end

    Add(candidate and candidate.retryKey)
    local normalized = candidate and candidate.normalized
    local score = type(normalized) == "table" and normalized.score or nil
    if type(score) == "table" then
        Add(score.retryKey)
    end
    if self.CandidateRetryKey ~= nil then
        Add(self:CandidateRetryKey(candidate))
    end
    if includeFamilyKeys == true or PromptFailureRejectsCandidateFamily(reason) then
        Add(self:CandidateFamilyRejectionKey(candidate))
    end

    return keys
end

local function CandidateContractTargetListKey(targets)
    if type(targets) ~= "table" then
        return nil
    end

    local parts = {}
    for _,target in ipairs(targets) do
        parts[#parts+1] = "target:" .. CacheTokenKey(target and target.token) .. ":" .. LocKey(target and target.loc) .. ":" .. LocKey(target and target["chargeLoc"])
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function CandidateContractMoveKey(move)
    if type(move) ~= "table" then
        return nil
    end

    return table.concat({
        tostring(move.mode or ""),
        LocKey(move.destination),
        tostring(move.tiles or ""),
        LocKey(move.path and move.path.destination),
    }, ":")
end

local function CandidateContractModeKey(mode)
    if type(mode) ~= "table" then
        return nil
    end

    return tostring(mode.index or "") .. ":" .. tostring(mode.text or "")
end

local function CandidateContractAssignmentListKey(assignments)
    if type(assignments) ~= "table" then
        return nil
    end

    local parts = {}
    for _,assignment in ipairs(assignments) do
        parts[#parts+1] = table.concat({
            CacheTokenKey(assignment and assignment.member and assignment.member.token),
            CacheTokenKey(assignment and assignment.target),
            LocKey(assignment and assignment.loc),
            LocKey(assignment and assignment.chargeLoc),
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function CandidateContractSupportMoveListKey(moves)
    if type(moves) ~= "table" then
        return nil
    end

    local parts = {}
    for _,move in ipairs(moves) do
        parts[#parts+1] = table.concat({
            CacheTokenKey(move and move.member and move.member.token),
            LocKey(move and move.loc),
        }, ":")
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function AI:ValidateCandidateContract(candidate, phase)
    if candidate == nil then
        return false, "missing candidate", { phase = phase }
    end

    local intent = self:CandidateIntent(candidate)
    local execution = self:CandidateExecution(candidate)
    local score = self:CandidateScoreSection(candidate)

    local function Reject(reason, fields)
        fields = fields or {}
        fields.phase = phase
        fields.reason = reason
        return false, reason, fields
    end

    local function Check(label, rootSet, rootKey, normalizedSet, normalizedKey)
        if rootSet and normalizedSet and tostring(rootKey or "") ~= tostring(normalizedKey or "") then
            return Reject("contradictory " .. label, {
                field = label,
                root = rootKey,
                normalized = normalizedKey,
            })
        end

        return true, nil, nil
    end

    local ok, reason, fields = Check(
        "targets",
        candidate.targets ~= nil,
        CandidateContractTargetListKey(candidate.targets),
        intent.targets ~= nil,
        CandidateContractTargetListKey(intent.targets)
    )
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("actionCost", candidate.actionCost ~= nil, candidate.actionCost, intent.actionCost ~= nil, intent.actionCost)
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("targetArea", candidate.targetArea ~= nil, TargetAreaCacheKey(candidate.targetArea), intent.targetArea ~= nil, TargetAreaCacheKey(intent.targetArea))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("modeSelection", candidate.modeSelection ~= nil, CandidateContractModeKey(candidate.modeSelection), intent.modeSelection ~= nil, CandidateContractModeKey(intent.modeSelection))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("loc", candidate.loc ~= nil, LocKey(candidate.loc), execution.loc ~= nil, LocKey(execution.loc))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("preInvokeMove", candidate.preInvokeMove ~= nil, CandidateContractMoveKey(candidate.preInvokeMove), execution.preInvokeMove ~= nil, CandidateContractMoveKey(execution.preInvokeMove))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("advanceTargetLoc", candidate.advanceTargetLoc ~= nil, LocKey(candidate.advanceTargetLoc), execution.advanceTargetLoc ~= nil, LocKey(execution.advanceTargetLoc))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("areaAnchorLoc", candidate.areaAnchorLoc ~= nil, LocKey(candidate.areaAnchorLoc), execution.areaAnchorLoc ~= nil, LocKey(execution.areaAnchorLoc))
    if not ok then return ok, reason, fields end

    local rootAssignments = candidate.squadAssignments
    ok, reason, fields = Check("squadAssignments", rootAssignments ~= nil, CandidateContractAssignmentListKey(rootAssignments), execution.squadAssignments ~= nil, CandidateContractAssignmentListKey(execution.squadAssignments))
    if not ok then return ok, reason, fields end

    ok, reason, fields = Check("squadSupportMoves", candidate.squadSupportMoves ~= nil, CandidateContractSupportMoveListKey(candidate.squadSupportMoves), execution.squadSupportMoves ~= nil, CandidateContractSupportMoveListKey(execution.squadSupportMoves))
    if not ok then return ok, reason, fields end

    if candidate.retryKey ~= nil and score.retryKey ~= nil and candidate.retryKey ~= score.retryKey then
        return Reject("stored retry key differed from normalized retry key", {
            storedRetryKey = candidate.retryKey,
            normalizedRetryKey = score.retryKey,
        })
    end

    if candidate.retryKey ~= nil then
        local currentRetryKey = self:CandidateRetryKey(candidate)
        if currentRetryKey ~= nil and currentRetryKey ~= candidate.retryKey then
            return Reject("retry key no longer matches proposal", {
                storedRetryKey = candidate.retryKey,
                currentRetryKey = currentRetryKey,
            })
        end
    end

    return true, nil, nil
end

function AI:CandidatePreInvokeDestination(candidate)
    local move = self:CandidatePreInvokeMove(candidate)
    if move ~= nil and move.destination ~= nil then
        return move.destination
    end

    return nil
end

function AI:CandidatePrimaryAttackLoc(candidate)
    return self:CandidatePreInvokeDestination(candidate) or self:CandidateExecutionLoc(candidate) or nil
end

local function EnsureEvalCache(context)
    if context == nil then
        return nil
    end

    context._tmp_directorTacticsEval = context._tmp_directorTacticsEval or {}
    local cache = context._tmp_directorTacticsEval
    cache.perf = cache.perf or {}
    cache.pathAreas = cache.pathAreas or {}
    cache.reachableFull = cache.reachableFull or {}
    cache.friendly = cache.friendly or {}
    cache.targetAllowed = cache.targetAllowed or {}
    cache.targetableSet = cache.targetableSet or {}
    cache.los = cache.los or {}
    cache.chargeMove = cache.chargeMove or {}
    cache.legalMoveOptions = cache.legalMoveOptions or {}
    return cache
end

local function CountPerf(context, key)
    local cache = EnsureEvalCache(context)
    if cache == nil then
        return
    end

    cache.perf[key] = (cache.perf[key] or 0) + 1
end

local function ReachableSlice(full, limit)
    local result = {}
    local count = math.min(limit or #full, #full)
    for i=1,count do
        result[i] = full[i]
    end
    return result
end

local MovementConditionNames = {
    "Restrained",
    "Grabbed",
    "Slowed",
    "Frightened",
    "Prone",
    "Dazed",
    "Hidden",
}

local function MovementActorFromLedger(ledger)
    if type(ledger) == "table" and ledger.token ~= nil then
        return ledger
    end

    return nil
end

local function MovementTurnMemory(ledger)
    if type(ledger) ~= "table" then
        return nil
    end

    if ledger.turnMemory ~= nil then
        return ledger.turnMemory
    end

    if ledger.moveActionsUsed ~= nil
        or ledger.moveActionLimit ~= nil
        or ledger.moveBudgetTiles ~= nil
        or ledger.generation ~= nil
        or ledger.maneuverUsed ~= nil
    then
        return ledger
    end

    return nil
end

local function MovementContextFromLedger(ledger)
    local actor = MovementActorFromLedger(ledger)
    if actor ~= nil then
        return actor.context
    end

    return TryGet(ledger, "context", nil)
end

local function MovementHasCondition(ai, token, conditionName)
    if ai ~= nil and ai.TargetHasCondition ~= nil then
        return ai:TargetHasCondition(token, conditionName) == true
    end

    return SafeCall(function()
        return token.properties:HasNamedCondition(conditionName)
    end, false) == true
end

local function MovementConditionSnapshot(ai, token)
    local conditions = {}
    local parts = {}
    for _,conditionName in ipairs(MovementConditionNames) do
        local hasCondition = MovementHasCondition(ai, token, conditionName)
        conditions[conditionName] = hasCondition
        parts[#parts+1] = conditionName .. "=" .. tostring(hasCondition)
    end

    return conditions, table.concat(parts, ",")
end

local function MovementSpendValue(turnMemory, field, default)
    return tonumber(turnMemory and turnMemory[field]) or default
end

local function MovementManeuverAvailable(ai, actor, turnMemory)
    if actor ~= nil and ai ~= nil and ai.Ledger ~= nil and ai.Ledger.CanSpendActionType ~= nil then
        local ok = false
        ok = SafeCall(function()
            local allowed = ai.Ledger:CanSpendActionType(ai, actor, { kind = "maneuver" }, nil)
            return allowed == true
        end, false)
        return ok
    end

    if turnMemory == nil then
        return true
    end

    return turnMemory.turnEnded ~= true
        and turnMemory.maneuverUsed ~= true
        and MovementSpendValue(turnMemory, "maneuversUsed", 0) <= 0
end

local function MovementMoveAvailable(ai, actor, turnMemory)
    if actor ~= nil and ai ~= nil and ai.Ledger ~= nil and ai.Ledger.CanSpendActionType ~= nil then
        local result = SafeCall(function()
            local allowed, reason = ai.Ledger:CanSpendActionType(ai, actor, { kind = "move" }, nil)
            return { allowed = allowed == true, reason = reason }
        end, nil)
        if result ~= nil then
            return result.allowed == true, result.reason
        end

        return false, "move unavailable"
    end

    if turnMemory == nil then
        return true, nil
    end

    if turnMemory.turnEnded == true then
        return false, "turn already ended"
    end

    local used = MovementSpendValue(turnMemory, "moveActionsUsed", 0)
    local limit = math.max(1, MovementSpendValue(turnMemory, "moveActionLimit", 1))
    if used >= limit or turnMemory.moveActionUsed == true then
        return false, "move already used"
    end

    return true, nil
end

local function MovementFlagsForMode(mode)
    if mode == "shift" then
        return { "shift" }
    end

    return {}
end

local function MovementTilesAllowed(mode, speed, moved, turnMemory)
    speed = math.max(0, tonumber(speed) or 0)
    moved = math.max(0, tonumber(moved) or 0)

    local budget = tonumber(turnMemory and turnMemory.moveBudgetTiles) or speed
    local spent = tonumber(turnMemory and turnMemory.movedTiles) or moved
    local remaining = math.max(0, budget - spent)

    if mode == "shift" then
        return math.max(0, math.floor(speed / 2))
    end

    if mode == "charge" then
        return speed
    end

    return remaining
end

local function MovementConsequences(ai, token, mode, conditions)
    return {
        provokesOpportunityAttacks = mode ~= "shift",
        revealsHidden = conditions ~= nil and conditions.Hidden == true,
    }
end

local function MovementNoneOption(ai, context, token, reason)
    if ai ~= nil and ai.Log ~= nil then
        ai:Log(string.format(
            "LegalMoveOptions returned {mode=\"none\", reason=\"%s\"} for %s",
            tostring(reason),
            TokenName(token)
        ))
    end

    return {
        {
            mode = "none",
            tilesAllowed = 0,
            requiresMoveAction = false,
            reachableLocs = {},
            consequences = {},
            reason = reason,
        }
    }
end

local function MovementRequestedModes(desiredMode)
    if desiredMode ~= nil then
        return { desiredMode }
    end

    return { "walk", "advance", "shift", "charge" }
end

local function MovementModeOption(options, mode)
    for _,option in ipairs(options or {}) do
        if option.mode == mode then
            return option
        end
    end

    return nil
end

local function MovementOptionLoc(option, loc)
    local targetKey = LocKey(loc)
    for _,locInfo in ipairs(option and option.reachableLocs or {}) do
        if LocKey(locInfo.loc) == targetKey then
            return locInfo
        end
    end

    return nil
end

local function MovementPathForLoc(token, locInfo)
    local path = locInfo and locInfo.path or nil
    if path == nil then
        return {
            origin = token and token.loc,
            destination = locInfo and locInfo.loc,
            steps = {},
        }
    end

    if type(path) ~= "table" then
        return {
            origin = TryGet(path, "origin", nil) or (token and token.loc),
            destination = TryGet(path, "destination", nil) or (locInfo and locInfo.loc),
            steps = TryGet(path, "steps", {}) or {},
        }
    end

    if path.origin == nil then
        path.origin = token and token.loc
    end
    if path.destination == nil then
        path.destination = locInfo and locInfo.loc
    end

    return path
end

local function LocNumber(loc, key)
    return tonumber(TryGet(loc, key, nil))
end

local function LocsAreStraightLine(origin, dest)
    local ox = LocNumber(origin, "x")
    local oy = LocNumber(origin, "y")
    local dx = LocNumber(dest, "x")
    local dy = LocNumber(dest, "y")
    if ox == nil or oy == nil or dx == nil or dy == nil then
        return false
    end

    local xdelta = dx - ox
    local ydelta = dy - oy
    return xdelta == 0 or ydelta == 0 or math.abs(xdelta) == math.abs(ydelta)
end

local function PathIsStraightLine(path, origin, dest)
    if not LocsAreStraightLine(origin, dest) then
        return false
    end

    for _,step in ipairs(TryGet(path, "steps", {}) or {}) do
        if step ~= nil and not LocsAreStraightLine(origin, step) then
            return false
        end
    end

    return true
end

local function PathDropsTooFar(path, origin, dest)
    local originAltitude = SafeCall(function()
        return game.currentFloor:GetAltitudeAtLoc(origin)
    end, TryGet(origin, "altitude", 0) or 0)

    local function CheckLoc(loc)
        if loc == nil then
            return false
        end

        local altitude = SafeCall(function()
            return game.currentFloor:GetAltitudeAtLoc(loc)
        end, TryGet(loc, "altitude", originAltitude) or originAltitude)
        return originAltitude - altitude > 1
    end

    for _,step in ipairs(TryGet(path, "steps", {}) or {}) do
        if CheckLoc(step) then
            return true
        end
    end

    return CheckLoc(dest)
end

function AI:ResetCandidateEvaluationCache(context)
    if context == nil then
        return
    end

    context._tmp_directorTacticsEval = {
        perf = {},
        pathAreas = {},
        reachableFull = {},
        friendly = {},
        targetAllowed = {},
        targetableSet = {},
        los = {},
        chargeMove = {},
        legalMoveOptions = {},
        hazardDamage = {},
        positionScore = {},
        forcedMove = {},
    }
    context._tmp_reachableLocs = nil
    context._tmp_blockingOccupancyKeys = nil
end

function AI:CandidateEvaluationCache(context)
    return EnsureEvalCache(context)
end

function AI:LogCandidatePerfSummary(context)
    local perf = context and context._tmp_directorTacticsEval and context._tmp_directorTacticsEval.perf
    if perf == nil then
        return
    end

    local function Pair(hitKey, missKey)
        local hits = perf[hitKey] or 0
        local misses = perf[missKey] or 0
        if hits == 0 and misses == 0 then
            return nil
        end
        return string.format("%s/%s", hits, misses)
    end

    local parts = {}
    for _,entry in ipairs({
        { "reachable", "pathHit", "pathMiss" },
        { "path area", "pathAreaHit", "pathAreaMiss" },
        { "target", "targetHit", "targetMiss" },
        { "targetable", "targetableHit", "targetableMiss" },
        { "los", "losHit", "losMiss" },
        { "move options", "moveOptionsHit", "moveOptionsMiss" },
        { "charge", "chargeHit", "chargeMiss" },
        { "forced move", "forcedMoveHit", "forcedMoveMiss" },
        { "position", "positionHit", "positionMiss" },
        { "hazard", "hazardHit", "hazardMiss" },
    }) do
        local text = Pair(entry[2], entry[3])
        if text ~= nil then
            parts[#parts+1] = entry[1] .. " " .. text
        end
    end

    if #parts > 0 then
        self:Log("Candidate cache hits/misses: " .. table.concat(parts, ", "))
    end
end

function AI:CachedPathfindingArea(context, token, movementAllowanceDecis, flags)
    local cache = EnsureEvalCache(context)
    if cache == nil then
        return SafeCall(function()
            return token:CalculatePathfindingArea(movementAllowanceDecis, flags or {})
        end, nil)
    end

    local flagText = {}
    for i,flag in ipairs(flags or {}) do
        flagText[i] = tostring(flag)
    end
    local key = table.concat({
        CacheTokenKey(token),
        LocKey(token and token.loc),
        tostring(movementAllowanceDecis),
        table.concat(flagText, ","),
    }, "|")

    if cache.pathAreas[key] ~= nil then
        CountPerf(context, "pathAreaHit")
        local cached = cache.pathAreas[key]
        if cached == false then
            return nil
        end
        return cached
    end

    CountPerf(context, "pathAreaMiss")
    local result = SafeCall(function()
        return token:CalculatePathfindingArea(movementAllowanceDecis, flags or {})
    end, nil)
    cache.pathAreas[key] = result or false
    return result
end

function AI:CachedTokensFriendly(context, a, b)
    if a == nil or b == nil then
        return false
    end

    local cache = EnsureEvalCache(context)
    if cache == nil then
        return TokensFriendly(a, b)
    end

    local key = CacheTokenKey(a) .. ">" .. CacheTokenKey(b)
    if cache.friendly[key] ~= nil then
        CountPerf(context, "friendlyHit")
        return cache.friendly[key]
    end

    CountPerf(context, "friendlyMiss")
    local result = TokensFriendly(a, b)
    cache.friendly[key] = result
    return result
end

local function DirectHasLineOfSight(source, target, pierce, mode)
    return SafeCall(function()
        local los = nil
        if mode == "basic" or mode == "full" then
            los = source:GetLineOfSight(target, pierce, mode)
        else
            los = source:GetLineOfSight(target, pierce)
        end
        return los == nil or los > 0
    end, true)
end

function AI:CachedHasLineOfSight(context, sourceToken, targetToken, options)
    if sourceToken == nil or targetToken == nil then
        return false
    end

    options = options or {}
    local sourceLoc = options.sourceLoc or TryGet(sourceToken, "loc", nil)
    local targetArea = options.targetArea
    local areaOrigin = options.areaOrigin or TryGet(targetArea, "origin", nil)
    local targetLoc = options.targetLoc or TryGet(targetToken, "loc", nil) or areaOrigin
    local pierceSource = options.pierceSource or sourceToken
    local pierce = options.pierce
    if pierce == nil then
        pierce = SafeCall(function()
            return pierceSource.properties:GetPierceWalls()
        end, false)
    end
    local mode = options.mode or "default"

    local cache = EnsureEvalCache(context)
    if cache == nil then
        return DirectHasLineOfSight(sourceToken, targetToken, pierce, mode)
    end

    local key = table.concat({
        LineOfSightSubjectKey(sourceToken, sourceLoc, "source"),
        LocKey(sourceLoc),
        LineOfSightSubjectKey(targetToken, targetLoc, "target"),
        LocKey(targetLoc),
        LineOfSightSubjectKey(pierceSource, TryGet(pierceSource, "loc", nil), "pierce"),
        tostring(pierce),
        tostring(mode),
        TargetAreaCacheKey(targetArea),
    }, "|")

    if cache.los[key] ~= nil then
        CountPerf(context, "losHit")
        return cache.los[key]
    end

    CountPerf(context, "losMiss")
    local result = DirectHasLineOfSight(sourceToken, targetToken, pierce, mode)
    cache.los[key] = result
    return result
end

function AI:TokenOccupyingLocsAt(token, loc)
    if token == nil or loc == nil then
        return {}
    end

    local locs = SafeCall(function()
        return token:LocsOccupyingWhenAt(loc)
    end, nil)
    if type(locs) == "table" and #locs > 0 then
        return locs
    end

    return { loc }
end

function AI:TokenCurrentOccupyingLocs(token)
    if token == nil then
        return {}
    end

    local locs = TryGet(token, "locsOccupying", nil)
    if type(locs) == "table" and #locs > 0 then
        return locs
    end

    local loc = TryGet(token, "loc", nil)
    if loc ~= nil then
        return { loc }
    end

    return {}
end

function AI:TokensCanShareDestination(movingToken, otherToken)
    if movingToken == nil or otherToken == nil then
        return true
    end

    local movingId = TokenId(movingToken)
    local otherId = TokenId(otherToken)
    if movingId ~= nil and movingId == otherId then
        return true
    end

    if TryGet(movingToken, "mountedOn", nil) == otherId or TryGet(otherToken, "mountedOn", nil) == movingId then
        return true
    end
    if TryGet(movingToken, "rider", nil) == otherToken or TryGet(otherToken, "rider", nil) == movingToken then
        return true
    end
    if TryGet(movingToken, "mount", nil) == otherToken or TryGet(otherToken, "mount", nil) == movingToken then
        return true
    end

    return false
end

function AI:BlockingOccupancyKeys(context, movingToken)
    local cacheKey = TokenId(movingToken) or tostring(movingToken)
    local cache = nil
    if context ~= nil then
        context._tmp_blockingOccupancyKeys = context._tmp_blockingOccupancyKeys or {}
        cache = context._tmp_blockingOccupancyKeys
        if cache[cacheKey] ~= nil then
            return cache[cacheKey]
        end
    end

    local result = {}
    local tokens = (context and context.allCombatTokens) or dmhub.allTokens or {}
    for _,otherToken in ipairs(tokens) do
        if IsTokenValid(otherToken) and not self:TokensCanShareDestination(movingToken, otherToken) then
            for _,occupiedLoc in ipairs(self:TokenCurrentOccupyingLocs(otherToken)) do
                local key = LocOccupancyKey(occupiedLoc)
                if key ~= nil then
                    result[key] = otherToken
                end
            end
        end
    end

    if cache ~= nil then
        cache[cacheKey] = result
    end
    return result
end

function AI:DestinationOverlapsBlockingToken(context, movingToken, loc)
    if movingToken == nil or loc == nil then
        return false, nil
    end

    local movingKeys = {}
    for _,occupiedLoc in ipairs(self:TokenOccupyingLocsAt(movingToken, loc)) do
        local key = LocOccupancyKey(occupiedLoc)
        if key ~= nil then
            movingKeys[key] = true
        end
    end

    if next(movingKeys) == nil then
        return false, nil
    end

    local blockers = self:BlockingOccupancyKeys(context, movingToken)
    for key,_ in pairs(movingKeys) do
        local blocker = blockers[key]
        if blocker ~= nil then
            return true, blocker
        end
    end

    return false, nil
end

function AI:IsMovementDestinationClear(context, movingToken, loc)
    local blocked, blocker = self:DestinationOverlapsBlockingToken(context, movingToken, loc)
    return not blocked, blocker
end

function AI:MovementDestinationReserved(token, loc, reservedDestinations)
    if token == nil or loc == nil or reservedDestinations == nil then
        return false
    end

    for _,occupiedLoc in ipairs(self:TokenOccupyingLocsAt(token, loc)) do
        local key = LocOccupancyKey(occupiedLoc)
        if key ~= nil and reservedDestinations[key] then
            return true
        end
    end

    return false
end

function AI:ReserveMovementDestination(token, loc, reservedDestinations)
    if token == nil or loc == nil or reservedDestinations == nil then
        return
    end

    for _,occupiedLoc in ipairs(self:TokenOccupyingLocsAt(token, loc)) do
        local key = LocOccupancyKey(occupiedLoc)
        if key ~= nil then
            reservedDestinations[key] = true
        end
    end
end

function AI:LegalMoveOptions(token, ledger, desiredMode)
    local actor = MovementActorFromLedger(ledger)
    local context = MovementContextFromLedger(ledger)
    local turnMemory = MovementTurnMemory(ledger)

    if actor ~= nil and self.Ledger ~= nil and self.Ledger.Init ~= nil then
        turnMemory = SafeCall(function()
            return self.Ledger:Init(self, actor)
        end, turnMemory)
    end

    if token == nil then
        return MovementNoneOption(self, context, token, "missing token")
    end

    local speed = SafeCall(function()
        return token.properties:CurrentMovementSpeed()
    end, 0)
    local moved = SafeCall(function()
        return token.properties:DistanceMovedThisTurn()
    end, 0)
    local conditions, conditionKey = MovementConditionSnapshot(self, token)
    local cache = EnsureEvalCache(context)
    local cacheKey = nil
    if cache ~= nil then
        cacheKey = table.concat({
            CacheTokenKey(token),
            LocKey(TryGet(token, "loc", nil)),
            tostring(desiredMode or "*"),
            tostring(self.config.movement),
            tostring(speed),
            tostring(moved),
            conditionKey,
            tostring(MovementSpendValue(turnMemory, "moveActionsUsed", 0)),
            tostring(MovementSpendValue(turnMemory, "moveActionLimit", 1)),
            tostring(MovementSpendValue(turnMemory, "moveBudgetTiles", speed)),
            tostring(MovementSpendValue(turnMemory, "movedTiles", moved)),
            tostring(MovementSpendValue(turnMemory, "maneuversUsed", 0)),
            tostring(turnMemory and turnMemory.maneuverUsed == true),
            tostring(MovementSpendValue(turnMemory, "generation", 0)),
        }, "|")
        if cache.legalMoveOptions[cacheKey] ~= nil then
            CountPerf(context, "moveOptionsHit")
            return cache.legalMoveOptions[cacheKey]
        end
    end
    CountPerf(context, "moveOptionsMiss")

    local function Store(options)
        if cache ~= nil then
            cache.legalMoveOptions[cacheKey] = options
        end
        return options
    end

    if not self.config.movement then
        return Store(MovementNoneOption(self, context, token, "movement disabled"))
    end

    if conditions.Restrained then
        return Store(MovementNoneOption(self, context, token, "Restrained"))
    end

    if conditions.Grabbed then
        if MovementManeuverAvailable(self, actor, turnMemory) then
            return Store(MovementNoneOption(self, context, token, "Grabbed; Escape Grab maneuver required first"))
        end

        return Store(MovementNoneOption(self, context, token, "Grabbed; locked for the turn"))
    end

    if conditions.Prone then
        return Store(MovementNoneOption(self, context, token, "Prone; Stand Up required first"))
    end

    local moveAllowed, moveReason = MovementMoveAvailable(self, actor, turnMemory)
    if not moveAllowed then
        return Store(MovementNoneOption(self, context, token, moveReason or "move already used"))
    end

    local options = {}
    for _,mode in ipairs(MovementRequestedModes(desiredMode)) do
        local tilesAllowed = MovementTilesAllowed(mode, speed, moved, turnMemory)
        local reachableLocs = {
            { loc = token.loc, cost = 0, positionScore = 0, path = nil, hazardDamage = 0 },
        }
        local seen = {
            [LocKey(token.loc)] = true,
        }
        local frightenedFiltered = 0

        if tilesAllowed > 0 then
            local flags = MovementFlagsForMode(mode)
            local paths = self:CachedPathfindingArea(context, token, tilesAllowed * 10, flags)
            if paths == nil and mode == "shift" and #flags > 0 then
                paths = self:CachedPathfindingArea(context, token, tilesAllowed * 10, {})
            end

            local candidates = {}
            for _,info in pairs(paths or {}) do
                local loc = info.loc
                local key = LocKey(loc)
                if loc ~= nil and not seen[key] then
                    local clear = self:IsMovementDestinationClear(context, token, loc)
                    local frightenedAllowed = self:MovementAllowedByFrightened(context, token, loc)
                    if clear and frightenedAllowed then
                        local path = MovementPathForLoc(token, info)
                        local hazardDamage = self.CachedMovementPathHazardDamage ~= nil and self:CachedMovementPathHazardDamage(context, token, path) or self:MovementPathHazardDamage(token, path)
                        local position = -(tonumber(info.cost) or 0) * 0.002
                        if actor ~= nil then
                            local enemyDistance = SafeCall(function()
                                return self:NearestEnemyDistanceFromLoc(actor, loc)
                            end, 0) or 0
                            local objectiveScore = SafeCall(function()
                                return self:ScoreObjectivePositionWithProfile(actor.context, actor, loc, nil, nil)
                            end, 0) or 0
                            position = position - enemyDistance * 0.02
                            position = position + objectiveScore * 0.2
                        end
                        position = position - hazardDamage * 0.8

                        candidates[#candidates+1] = {
                            loc = loc,
                            cost = info.cost or 0,
                            path = path,
                            hazardDamage = hazardDamage,
                            positionScore = position,
                        }
                        seen[key] = true
                    elseif clear and not frightenedAllowed then
                        frightenedFiltered = frightenedFiltered + 1
                    end
                end
            end

            table.sort(candidates, function(a, b)
                local ascore = a.positionScore or 0
                local bscore = b.positionScore or 0
                if ascore ~= bscore then
                    return ascore > bscore
                end

                return LocKey(a.loc) < LocKey(b.loc)
            end)

            for _,candidate in ipairs(candidates) do
                reachableLocs[#reachableLocs+1] = candidate
            end
        end

        if frightenedFiltered > 0 and conditions.Frightened then
            self:Log(string.format("MovementAllowedByFrightened filtered %d candidates for %s", frightenedFiltered, TokenName(token)))
        end

        options[#options+1] = {
            mode = mode,
            tilesAllowed = tilesAllowed,
            requiresMoveAction = true,
            reachableLocs = reachableLocs,
            consequences = MovementConsequences(self, token, mode, conditions),
        }
    end

    return Store(options)
end

function AI:MovementOptionForDestination(token, ledger, mode, destination)
    if destination == nil then
        return nil, nil, "missing destination"
    end

    local options = self:LegalMoveOptions(token, ledger, mode)
    local option = MovementModeOption(options, mode)
    if option == nil then
        local reason = options and options[1] and options[1].reason
        return nil, nil, reason or "movement mode unavailable"
    end

    local locInfo = MovementOptionLoc(option, destination)
    if locInfo == nil then
        return option, nil, "destination no longer reachable"
    end

    return option, locInfo, nil
end

function AI:GetReachableLocs(token, actor, limit)
    limit = limit or 28
    local options = self:LegalMoveOptions(token, actor, "walk")
    local option = MovementModeOption(options, "walk")
    if option == nil then
        return {
            { loc = token and token.loc, cost = 0, positionScore = 0 },
        }
    end

    return ReachableSlice(option.reachableLocs or {}, limit)
end

function AI:MovementOscillationPenalty(token, loc)
    local memory = self._runtime and self._runtime.movementMemory
    if memory == nil or token == nil or loc == nil then
        return 0
    end

    local entry = memory[CacheTokenKey(token)]
    if entry == nil or type(entry.recent) ~= "table" then
        return 0
    end

    local destination = LocKey(loc)
    for index,key in ipairs(entry.recent) do
        if key == destination then
            return ConstNumber("Candidate", "MovementOscillationPenalty", 2.5) / index
        end
    end

    return 0
end

function AI:MakeCandidate(args)
    args.id = args.id or dmhub.GenerateGuid()
    args.enumeratorRule = args.enumeratorRule or "legacy"
    args.scoreInfo = args.scoreInfo or CreateScore()
    args.symbols = CopySymbols(args.symbols or {})
    args.symbols.mode = args.symbols.mode or 1
    if args.abilityInfo ~= nil and args.abilityInfo.isMalice and args.symbols.charges == nil then
        args.symbols.charges = self:MaliceCost(args.abilityInfo)
    end
    if args.actionType == nil then
        if self.Ledger ~= nil and self.Ledger.ActionTypeFromAbilityInfo ~= nil then
            args.actionType = self.Ledger:ActionTypeFromAbilityInfo(self, args.abilityInfo)
        elseif args.ability ~= nil and self.ResolveActionType ~= nil then
            args.actionType = SafeCall(function()
                return self:ResolveActionType(args.ability)
            end, nil)
        end
    end
    args.actionCost = args.actionCost or self:AbilityActionCost(args.abilityInfo)
    if args.scoreInfo ~= nil and args.actor ~= nil and self.ApplyTacticRules ~= nil then
        self:ApplyTacticRules(args.scoreInfo, "scoreCandidate", args.actor.context, args.actor, args.abilityInfo, args.targets or {}, args.loc, args)
    end
    self:NormalizeCandidate(args, { source = "make" })
    args.automationDecision = self:AutomationDecisionForCandidate(args)
    if args.promptCapability ~= nil then
        self:AnnotatePromptCapability(args, args.promptCapability)
    end
    self:FinalizeCandidateIdentity(args)
    return args
end

function AI:EnumerateManualPromptAbility(context, actor, ability, abilityInfo, reason, promptCapability)
    local score = CreateScore()
    AddScore(score, "manual prompt", ConstNumber("Score", "ManualPromptBase", 4))
    if abilityInfo ~= nil then
        AddScore(score, "manual value", math.max(abilityInfo.expectedDamage or 0, abilityInfo.supportValue or 0, abilityInfo.conditionValue or 0, abilityInfo.forcedMovementValue or 0, 1))
        if abilityInfo.isMalice then
            local malice = self:MaliceScoreParts(context, abilityInfo)
            AddScore(score, "malice priority", malice.costPriority)
            AddScore(score, "malice unavailable", malice.unavailable)
        end
        if self:AbilityUsesNonCreatureTargeting(abilityInfo) then
            AddScore(score, "manual targeting", ConstNumber("Score", "ManualTargetingBonus", 2))
        end
        if self:IsSpecialMaliceFeature(abilityInfo) then
            AddScore(score, "special malice", ConstNumber("Score", "SpecialMaliceManualBonus", 3))
        end
    end

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = actor.token.loc,
            targets = { { token = actor.token } },
            symbols = { mode = 1 },
            manualPrompt = true,
            manualPromptReason = reason or "manual targeting",
            promptCapability = promptCapability,
            enumeratorRule = "manual-prompt",
            scoreInfo = score,
            description = string.format("%s manually", abilityInfo and abilityInfo.name or "Ability"),
        }
    }
end

function AI:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, casterToken, targetToken, options)
    options = options or {}
    if not IsTokenValid(targetToken) then
        return false, "target invalid"
    end

    if not TryGet(ability, "selfTarget", false) and casterToken ~= nil and targetToken ~= nil and casterToken.properties == targetToken.properties then
        return false, "target was self"
    end

    local friendly = self:CachedTokensFriendly(context, casterToken or (actor and actor.token), targetToken)
    if self:AbilityTargetsEnemies(abilityInfo) and friendly then
        return false, "enemy ability target was friendly"
    end

    if self:AbilityTargetsAllies(abilityInfo) and not friendly then
        return false, "ally ability target was hostile"
    end

    if options.allegianceOnly then
        return true, nil
    end

    if self:AbilityHasHostileEffect(abilityInfo) and friendly then
        return false, "hostile effect target was friendly"
    end

    if self:AbilityHasFriendlyEffect(abilityInfo) and not friendly then
        return false, "support effect target was hostile"
    end

    return true, nil
end

local function AddTargetPoolToken(pool, seen, entry)
    local tok = entry
    if type(entry) == "table" and entry.token ~= nil then
        tok = entry.token
    end

    if not IsTokenValid(tok) then
        return
    end

    local key = CacheTokenKey(tok)
    if key == "" or seen[key] then
        return
    end

    seen[key] = true
    pool[#pool+1] = tok
end

local function AddTargetPoolList(pool, seen, list)
    for _,entry in ipairs(list or {}) do
        AddTargetPoolToken(pool, seen, entry)
    end
end

local function TargetablePool(ability, casterToken, options)
    options = options or {}
    local context = options.context
    local source = options.targetPool or options.tokens
    if source == nil and context ~= nil then
        source = context.allCombatTokens
    end
    if source == nil and dmhub ~= nil then
        source = dmhub.allTokens or dmhub.tokens
    end

    local pool = {}
    local seen = {}
    AddTargetPoolList(pool, seen, source or {})
    AddTargetPoolList(pool, seen, options.extraTargets or options.targets or {})

    if TryGet(ability, "selfTarget", false) then
        AddTargetPoolToken(pool, seen, casterToken)
    end

    return pool
end

local function TargetablePoolKey(pool)
    local parts = {}
    for _,tok in ipairs(pool or {}) do
        parts[#parts+1] = CacheTokenKey(tok) .. "@" .. LocKey(tok and tok.loc)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function TargetableSetEntry(targetableSet, targetToken)
    if targetableSet == nil or targetToken == nil then
        return nil
    end

    local byToken = targetableSet._byTokenKey
    if byToken ~= nil then
        return byToken[CacheTokenKey(targetToken)]
    end

    for _,entry in ipairs(targetableSet) do
        if entry.token == targetToken or CacheTokenKey(entry.token) == CacheTokenKey(targetToken) then
            return entry
        end
    end

    return nil
end

function AI:TargetableSetFromEngine(ability, casterToken, casterLoc, options)
    options = options or {}
    local context = options.context
    local symbols = CopySymbols(options.symbols or {})
    symbols.mode = symbols.mode or 1
    local result = {}

    if ability == nil or casterToken == nil then
        result._byTokenKey = {}
        return result
    end

    local pool = TargetablePool(ability, casterToken, options)
    local originLoc = casterLoc or TryGet(casterToken, "loc", nil)
    local cache = EnsureEvalCache(context)
    local cacheKey = nil
    if cache ~= nil then
        cacheKey = table.concat({
            CacheAbilityKey(ability, options.abilityInfo),
            CacheTokenKey(casterToken),
            LocKey(originLoc),
            CacheSymbolsKey(symbols),
            TargetablePoolKey(pool),
        }, "|")
        if cache.targetableSet[cacheKey] ~= nil then
            CountPerf(context, "targetableHit")
            return cache.targetableSet[cacheKey]
        end
    end
    CountPerf(context, "targetableMiss")

    local function Evaluate()
        local entries = {}
        local byToken = {}
        local range = AbilityRange(ability, casterToken, symbols)

        for _,targetToken in ipairs(pool) do
            local sameToken = casterToken == targetToken
                or TryGet(casterToken, "properties", nil) == TryGet(targetToken, "properties", false)
            local distance = sameToken and 0 or Distance(casterToken, targetToken)

            if distance <= range + 0.1 then
                local lineOfSight = sameToken or self:CachedHasLineOfSight(context, casterToken, targetToken, {
                    mode = options.lineOfSightMode,
                })
                local passed, rejectionReason = TargetPasses(ability, casterToken, targetToken, symbols)
                local entry = {
                    token = targetToken,
                    distance = distance,
                    lineOfSight = lineOfSight == true,
                    passedEngineFilter = passed == true,
                }
                if rejectionReason ~= nil then
                    entry.rejectionReason = rejectionReason
                end

                entries[#entries+1] = entry
                byToken[CacheTokenKey(targetToken)] = entry
            end
        end

        entries._byTokenKey = byToken
        entries._range = range
        return entries
    end

    if originLoc ~= nil and LocKey(originLoc) ~= LocKey(TryGet(casterToken, "loc", nil)) then
        -- Phase 0 verified that theoretical locs affect distance, LoS,
        -- TargetPassesFilter, and shape origin. If that engine behavior changes,
        -- evaluate filters at the real loc here and post-filter by endpoint reach.
        local evaluated = false
        SafeCall(function()
            casterToken:ExecuteWithTheoreticalLoc(originLoc, function()
                result = Evaluate()
                evaluated = true
            end)
        end, nil)
        if not evaluated then
            result = Evaluate()
        end
    else
        result = Evaluate()
    end

    result = result or {}
    result._byTokenKey = result._byTokenKey or {}
    if cache ~= nil then
        cache.targetableSet[cacheKey] = result
    end
    return result
end

local function TargetRangeReason(distance, range, options)
    if options ~= nil and options.afterMovement then
        return string.format("target out of range after movement (%0.1f > %0.1f)", distance or 999, range or 0)
    end

    return "target out of range"
end

function AI:CheckTargetLegality(context, actor, ability, abilityInfo, casterToken, targetToken, symbols, options)
    options = options or {}
    casterToken = casterToken or (actor and actor.token)

    local function Result(ok, reason, args)
        args = args or {}
        local result = self:MakeLegalityResult{
            ok = ok == true,
            kind = "target",
            phase = args.phase or options.phase,
            reasonCode = args.reasonCode or options.reasonCode,
            reason = reason,
            friendly = args.friendly,
            target = targetToken,
            loc = targetToken and targetToken.loc,
            area = options.targetArea,
            engine = args.engine,
            details = args.details,
        }
        result.source = options.source
        return result
    end

    if not IsTokenValid(targetToken) then
        return Result(false, Pick(options.afterMovement, "target was invalid after movement", "target invalid"), {
            friendly = false,
        })
    end

    if casterToken == nil or ability == nil then
        return Result(false, "missing target context", {
            friendly = false,
        })
    end

    local friendly = self:CachedTokensFriendly(context, casterToken, targetToken)

    if options.areaTarget == true then
        local cheapAllowed, cheapReason = self:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, casterToken, targetToken, {
            allegianceOnly = true,
        })
        if not cheapAllowed then
            return Result(false, cheapReason, {
                friendly = friendly,
            })
        end

        if self:AbilityHasFriendlyEffect(abilityInfo) and not self:AbilityHasHostileEffect(abilityInfo) and not friendly then
            return Result(false, "support effect target was hostile", {
                friendly = friendly,
            })
        end

        local areaOrigin = TryGet(options.targetArea, "origin", nil) or options.anchorLoc
        if options.skipLineOfSight ~= true and areaOrigin ~= nil then
            local areaLineOfSight = true
            if self.CachedHasLineOfSight ~= nil then
                areaLineOfSight = self:CachedHasLineOfSight(context, targetToken, areaOrigin, {
                    targetArea = options.targetArea,
                    targetLoc = areaOrigin,
                    pierceSource = targetToken,
                    mode = "area",
                })
            else
                areaLineOfSight = HasLineOfSight(targetToken, areaOrigin)
            end

            if areaLineOfSight ~= true then
                return Result(false, "target had no line of sight to area", {
                    friendly = friendly,
                    engine = {
                        lineOfSight = false,
                    },
                })
            end
        end

        local allowed, reason = TargetPasses(ability, casterToken, targetToken, symbols or {})
        return Result(allowed == true, Pick(allowed == true, nil, reason or "target filter failed"), {
            friendly = friendly,
            engine = {
                passedFilter = allowed == true,
                rejectionReason = reason,
            },
        })
    end

    local cheapAllowed, cheapReason = self:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, casterToken, targetToken)
    if not cheapAllowed then
        return Result(false, cheapReason, {
            friendly = friendly,
        })
    end

    local targetableSet = options.targetableSet
    if targetableSet ~= nil then
        local entry = TargetableSetEntry(targetableSet, targetToken)
        local range = tonumber(targetableSet._range or options.range) or tonumber(options.range) or AbilityRange(ability, casterToken, symbols or {})
        local distance = Distance(casterToken, targetToken)
        if entry == nil or (entry.distance or 999) > range + 0.1 then
            return Result(false, TargetRangeReason(distance, range, options), {
                friendly = friendly,
                engine = {
                    targetable = entry ~= nil,
                    distance = distance,
                    range = range,
                },
            })
        end

        if entry.lineOfSight ~= true then
            return Result(false, Pick(options.afterMovement, "target had no line of sight after movement", "no line of sight"), {
                friendly = friendly,
                engine = {
                    targetable = true,
                    lineOfSight = false,
                },
            })
        end

        if entry.passedEngineFilter ~= true then
            return Result(false, entry.rejectionReason or Pick(options.afterMovement, "target was illegal after movement", "target filter failed"), {
                friendly = friendly,
                engine = {
                    targetable = true,
                    passedFilter = false,
                    rejectionReason = entry.rejectionReason,
                },
            })
        end

        return Result(true, nil, {
            friendly = friendly,
            engine = {
                targetable = true,
                distance = entry.distance or distance,
                range = range,
                lineOfSight = true,
                passedFilter = true,
            },
        })
    end

    local cache = EnsureEvalCache(context)
    local key = nil
    if cache ~= nil then
        key = table.concat({
            CacheAbilityKey(ability, abilityInfo),
            CacheTokenKey(casterToken or actor.token),
            LocKey(casterToken and casterToken.loc),
            CacheTokenKey(targetToken),
            LocKey(targetToken and targetToken.loc),
            CacheSymbolsKey(symbols),
        }, "|")
        if cache.targetAllowed[key] ~= nil then
            CountPerf(context, "targetHit")
            local entry = cache.targetAllowed[key]
            return Result(entry.allowed == true, entry.reason, {
                friendly = friendly,
                engine = entry.engine,
            })
        end
    end

    CountPerf(context, "targetMiss")
    local allowed, reason = TargetPasses(ability, casterToken, targetToken, symbols)
    if not allowed then
        reason = reason or "target filter failed"
    end

    if cache ~= nil then
        cache.targetAllowed[key] = {
            allowed = allowed == true,
            reason = reason,
            engine = {
                passedFilter = allowed == true,
                rejectionReason = reason,
            },
        }
    end

    return Result(allowed == true, Pick(allowed == true, nil, reason), {
        friendly = friendly,
        engine = {
            passedFilter = allowed == true,
            rejectionReason = reason,
        },
    })
end

function AI:DirectorTargetAllowed(context, actor, ability, abilityInfo, casterToken, targetToken, symbols)
    return self:LegalityResultToTuple(self:CheckTargetLegality(context, actor, ability, abilityInfo, casterToken, targetToken, symbols, {
        source = "DirectorTargetAllowed",
    }))
end

function AI:AreaTargetAffected(context, actor, ability, abilityInfo, casterToken, targetToken, targetArea, symbols, options)
    options = options or {}
    options.areaTarget = true
    options.targetArea = targetArea
    options.source = options.source or "AreaTargetAffected"
    return self:LegalityResultToTuple(self:CheckTargetLegality(context, actor, ability, abilityInfo, casterToken, targetToken, symbols, options))
end

function AI:ChargeDistanceLimit(token, abilityInfo)
    local override = tonumber(abilityInfo and abilityInfo.chargeDistanceOverride)
    if override ~= nil then
        return override
    end

    return SafeCall(function()
        return token.properties:CurrentMovementSpeed()
    end, 0)
end

function AI:ChargeMoveInfo(context, token, abilityInfo, targetToken, actor)
    if token == nil or targetToken == nil or not (abilityInfo and abilityInfo.isChargeCapable) then
        return nil
    end

    if actor ~= nil and self.Ledger ~= nil and self.Ledger.Init ~= nil then
        SafeCall(function()
            self.Ledger:Init(self, actor)
        end, nil)
    end

    local cache = EnsureEvalCache(context)
    local cacheKey = nil
    if cache ~= nil then
        cacheKey = table.concat({
            CacheAbilityKey(nil, abilityInfo),
            CacheTokenKey(token),
            LocKey(token.loc),
            CacheTokenKey(targetToken),
            LocKey(targetToken.loc),
            tostring(self:ChargeDistanceLimit(token, abilityInfo)),
            tostring(tonumber(abilityInfo and abilityInfo.range) or 0),
            tostring(actor and actor.turnMemory and actor.turnMemory.moveActionsUsed or ""),
            tostring(actor and actor.turnMemory and actor.turnMemory.moveActionLimit or ""),
            tostring(actor and actor.turnMemory and actor.turnMemory.generation or ""),
        }, "|")
        if cache.chargeMove[cacheKey] ~= nil then
            CountPerf(context, "chargeHit")
            local cached = cache.chargeMove[cacheKey]
            if cached == false then
                return nil
            end
            return cached
        end
    end

    CountPerf(context, "chargeMiss")
    local legalOptions = self:LegalMoveOptions(token, actor or { context = context }, "charge")
    local chargeOption = MovementModeOption(legalOptions, "charge")
    if chargeOption == nil then
        if cache ~= nil then
            cache.chargeMove[cacheKey] = false
        end
        return nil
    end

    local origin = token.loc
    local range = tonumber(abilityInfo and abilityInfo.range) or 0
    local chargeLimit = self:ChargeDistanceLimit(token, abilityInfo)
    local best = nil
    local bestTargetDistance = nil
    local bestHazard = nil
    local bestChargeDistance = nil
    local bestKey = nil

    for _,locInfo in ipairs(chargeOption.reachableLocs or {}) do
        local loc = locInfo.loc
        if loc ~= nil and origin ~= nil and LocDistance(loc, origin) > 0.1 then
            local path = MovementPathForLoc(token, locInfo)
            local chargeDistance = LocDistance(loc, origin)
            local targetDistance = SafeCall(function()
                return targetToken:Distance(loc)
            end, LocDistance(loc, targetToken.loc))
            local hazardDamage = tonumber(locInfo.hazardDamage) or 0
            local key = LocKey(loc)

            if chargeDistance <= chargeLimit + 0.1
                and targetDistance <= range + 0.1
                and PathIsStraightLine(path, origin, loc)
                and not PathDropsTooFar(path, origin, loc)
                and (best == nil
                    or targetDistance < bestTargetDistance
                    or (targetDistance == bestTargetDistance and hazardDamage < bestHazard)
                    or (targetDistance == bestTargetDistance and hazardDamage == bestHazard and chargeDistance < bestChargeDistance)
                    or (targetDistance == bestTargetDistance and hazardDamage == bestHazard and chargeDistance == bestChargeDistance and key < bestKey))
            then
                best = {
                    loc = loc,
                    distance = chargeDistance,
                    path = path,
                    hazardDamage = hazardDamage,
                }
                bestTargetDistance = targetDistance
                bestHazard = hazardDamage
                bestChargeDistance = chargeDistance
                bestKey = key
            end
        end
    end

    local result = best

    if cache ~= nil then
        cache.chargeMove[cacheKey] = result or false
    end
    return result
end

function AI:BuildCandidate(ability, abilityInfo, origin, target, symbols, scoreInputs)
    scoreInputs = scoreInputs or {}
    local actor = scoreInputs.actor
    local context = scoreInputs.context or (actor and actor.context)
    local casterToken = scoreInputs.casterToken or (actor and actor.token)
    local targetToken = target and target.token or target

    if actor == nil or casterToken == nil or ability == nil or abilityInfo == nil or targetToken == nil then
        return nil, "candidate was incomplete"
    end

    if not IsTokenValid(targetToken) then
        return nil, "target invalid"
    end

    local cheapAllowed, cheapReason = self:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, casterToken, targetToken)
    if not cheapAllowed then
        return nil, cheapReason
    end

    local actionType = nil
    if self.Ledger ~= nil and self.Ledger.ActionTypeFromAbilityInfo ~= nil then
        actionType = self.Ledger:ActionTypeFromAbilityInfo(self, abilityInfo)
    elseif self.ResolveActionType ~= nil then
        actionType = SafeCall(function()
            return self:ResolveActionType(ability)
        end, nil)
    end
    local candidateSymbols = CopySymbols(symbols or {})
    candidateSymbols.mode = candidateSymbols.mode or 1

    local range = tonumber(scoreInputs.range or abilityInfo.range) or 0
    local dist = Distance(casterToken, targetToken)
    local preInvokeMove = nil
    local actionPreInvoke = actionType and actionType.preInvokeMovement
    local actorDazed = scoreInputs.actorDazed == true

    if not scoreInputs.disablePreInvokeMove
        and not actorDazed
        and actionPreInvoke ~= nil
        and actionPreInvoke.mode == "charge"
        and dist > range + 0.1
    then
        local chargeInfo = self:ChargeMoveInfo(context, casterToken, abilityInfo, targetToken, actor)
        if chargeInfo ~= nil then
            preInvokeMove = {
                mode = "charge",
                destination = chargeInfo.loc,
                tiles = chargeInfo.distance,
                path = chargeInfo.path,
                consumesMoveAction = true,
                hazardDamage = chargeInfo.hazardDamage,
            }
            dist = SafeCall(function()
                return targetToken:Distance(chargeInfo.loc)
            end, LocDistance(chargeInfo.loc, targetToken.loc))
        end
    end

    if preInvokeMove ~= nil and self.ActiveGrabbedHostileControlledByActor ~= nil then
        local activeGrab = self:ActiveGrabbedHostileControlledByActor(context, actor)
        if activeGrab ~= nil then
            return nil, "active grab by actor blocks pre-invoke movement"
        end
    end

    if preInvokeMove ~= nil then
        local moveOptions = self:LegalMoveOptions(casterToken, actor, preInvokeMove.mode)
        local moveOption = MovementModeOption(moveOptions, preInvokeMove.mode)
        local locInfo = MovementOptionLoc(moveOption, preInvokeMove.destination)
        if moveOption == nil or locInfo == nil then
            local reason = moveOptions and moveOptions[1] and moveOptions[1].reason
            return nil, reason or "illegal pre-invoke movement"
        end

        preInvokeMove.path = preInvokeMove.path or locInfo.path
        preInvokeMove.hazardDamage = preInvokeMove.hazardDamage or locInfo.hazardDamage
    end

    local targets = scoreInputs.targets or { { token = targetToken } }
    local targetOrigin = preInvokeMove and preInvokeMove.destination or origin or casterToken.loc
    local targetableSet = self:TargetableSetFromEngine(ability, casterToken, targetOrigin, {
        context = context,
        abilityInfo = abilityInfo,
        symbols = candidateSymbols,
        extraTargets = targets,
    })
    local targetRange = tonumber(targetableSet and targetableSet._range or range) or range
    for _,candidateTarget in ipairs(targets) do
        local candidateTargetToken = candidateTarget and candidateTarget.token or candidateTarget
        if not IsTokenValid(candidateTargetToken) then
            return nil, "target invalid"
        end

        local targetCheapAllowed, targetCheapReason = self:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, casterToken, candidateTargetToken)
        if not targetCheapAllowed then
            return nil, targetCheapReason
        end

        local entry = TargetableSetEntry(targetableSet, candidateTargetToken)
        if entry == nil or (entry.distance or 999) > targetRange + 0.1 then
            return nil, "target out of range"
        end

        if entry.lineOfSight ~= true then
            return nil, "no line of sight"
        end

        if entry.passedEngineFilter ~= true then
            return nil, entry.rejectionReason or "target filter failed"
        end
    end

    if self.Ledger ~= nil and self.Ledger.CanSpendActionType ~= nil then
        local canSpend, spendReason = self.Ledger:CanSpendActionType(self, actor, actionType, preInvokeMove)
        if not canSpend then
            return nil, spendReason
        end
    else
        local canUse, spendReason = self:CanUseActionCost(actor, abilityInfo)
        if not canUse then
            return nil, spendReason
        end
    end

    local description = scoreInputs.description or string.format("%s on %s", abilityInfo.name, TokenName(targetToken))
    return self:MakeCandidate{
        actor = actor,
        ability = ability,
        abilityInfo = abilityInfo,
        actionType = actionType,
        loc = origin or casterToken.loc,
        preInvokeMove = preInvokeMove,
        targets = targets,
        symbols = candidateSymbols,
        scoreInfo = scoreInputs.scoreInfo or CreateScore(),
        modeSelection = scoreInputs.modeSelection,
        enumeratorRule = scoreInputs.enumeratorRule or "single-target",
        description = description,
    }
end

function AI:EnumerateSingleTargetAbility(context, actor, ability, abilityInfo)
    local candidates = {}
    local token = actor.token
    local locs = self:GetReachableLocs(token, actor, 30)
    local actorDazed = self:TargetHasCondition(token, "Dazed")
    local actionType = nil
    if self.Ledger ~= nil and self.Ledger.ActionTypeFromAbilityInfo ~= nil then
        actionType = self.Ledger:ActionTypeFromAbilityInfo(self, abilityInfo)
    elseif self.ResolveActionType ~= nil then
        actionType = SafeCall(function()
            return self:ResolveActionType(ability)
        end, nil)
    end
    local actionPreInvoke = actionType and actionType.preInvokeMovement
    if actorDazed or self:AbilityHasNestedMovementPrompt(abilityInfo) then
        locs = { { loc = token.loc, cost = 0, positionScore = 0 } }
    elseif actionPreInvoke ~= nil then
        locs = { { loc = token.loc, cost = 0, positionScore = 0 } }
        self:Trace("movement", "pre-invoke movement restricted to current origin", {
            actor = TokenName(token),
            ability = abilityInfo and abilityInfo.name,
            mode = actionPreInvoke.mode,
        })
    end
    local preselectedMode = abilityInfo and abilityInfo.modeSelection or nil
    local symbols = { mode = tonumber(preselectedMode and preselectedMode.index) or 1 }
    local targetPool = {}
    local isAutoGrabModePrompt = self:IsAutoResolvableGrabModePrompt(abilityInfo)
    local isAutoForcedMovementModePrompt = self:IsAutoResolvableForcedMovementModePrompt(abilityInfo)

    if isAutoGrabModePrompt and self.ActiveGrabbedHostileControlledByActor ~= nil then
        local activeGrab = self:ActiveGrabbedHostileControlledByActor(context, actor)
        if activeGrab ~= nil then
            self:Skip(ability, "active grab already present")
            self:Trace("ability", "standard Grab suppressed by active grab", {
                actor = TokenName(token),
                ability = abilityInfo and abilityInfo.name,
                grabbed = TokenName(activeGrab),
            })
            return candidates
        end
    end

    for _,tok in ipairs(context.allCombatTokens) do
        targetPool[#targetPool+1] = tok
    end

    if TryGet(ability, "selfTarget", false) then
        targetPool[#targetPool+1] = token
    end

    for _,locInfo in ipairs(locs) do
        SafeCall(function()
            token:ExecuteWithTheoreticalLoc(locInfo.loc, function()
                local targetOptions = {}
                for _,targetToken in ipairs(targetPool) do
                    local skipControlledGrabTarget = isAutoGrabModePrompt and self:StandardGrabTargetAlreadyControlled(targetToken)
                    local skipInvalidForceMoveTarget = self:AbilityIsPureForcedMovement(abilityInfo) and not self:TargetCanBeForceMovedByActor(actor, targetToken)
                    if not skipControlledGrabTarget and not skipInvalidForceMoveTarget then
                        local probe = self:BuildCandidate(ability, abilityInfo, locInfo.loc, { token = targetToken }, symbols, {
                            context = context,
                            actor = actor,
                            casterToken = token,
                            actorDazed = actorDazed,
                            disablePreInvokeMove = abilityInfo.numTargets ~= 1,
                            scoreInfo = CreateScore(),
                            enumeratorRule = "single-target-probe",
                        })
                        if probe ~= nil then
                            local attackLoc = self:CandidatePrimaryAttackLoc(probe) or locInfo.loc
                            local target = {
                                token = targetToken,
                                preInvokeMove = probe.preInvokeMove,
                                actionType = probe.actionType,
                                attackLoc = attackLoc,
                                preInvokeSortKey = LocKey(self:CandidatePreInvokeDestination(probe)),
                            }
                            target.sortScore = self:ScoreTargets(context, actor, abilityInfo, { { token = targetToken } }, attackLoc).total
                            targetOptions[#targetOptions+1] = target
                        end
                    end
                end

                table.sort(targetOptions, function(a, b)
                    local ascore = a.sortScore or 0
                    local bscore = b.sortScore or 0
                    if ascore ~= bscore then
                        return ascore > bscore
                    end

                    local atarget = CacheTokenKey(a.token)
                    local btarget = CacheTokenKey(b.token)
                    if atarget ~= btarget then
                        return atarget < btarget
                    end

                    return tostring(a.preInvokeSortKey or "") < tostring(b.preInvokeSortKey or "")
                end)

                local targets = {}
                for i=1,math.min(abilityInfo.numTargets, #targetOptions) do
                    targets[#targets+1] = {
                        token = targetOptions[i].token,
                    }
                end

                if #targets > 0 then
                    local preInvokeMove = nil
                    local attackLoc = locInfo.loc
                    if #targets == 1 then
                        preInvokeMove = targetOptions[1].preInvokeMove
                        attackLoc = targetOptions[1].attackLoc or locInfo.loc
                    end
                    local score = self:ScoreTargets(context, actor, abilityInfo, targets, attackLoc)
                    AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
                    self:AddMovementHazardScore(score, token, locInfo, false, context)
                    if preInvokeMove ~= nil and (preInvokeMove.hazardDamage or 0) > 0 then
                        AddScore(score, "charge hazard", -(preInvokeMove.hazardDamage or 0) * 3)
                    end

                    local modeSelection = preselectedMode
                    local modeReason = nil
                    local candidateSymbols = symbols
                    local description = string.format("%s on %s", abilityInfo.name, TokenName(targets[1].token))
                    if modeSelection ~= nil then
                        candidateSymbols = CopySymbols(symbols)
                        candidateSymbols.mode = modeSelection.index
                        description = string.format("%s (%s)", description, modeSelection.text or ("mode " .. tostring(modeSelection.index)))
                    elseif isAutoGrabModePrompt then
                        modeSelection, modeReason = self:ChooseGrabModeSelection(context, actor, abilityInfo, targets[1].token, score)
                        if modeSelection ~= nil then
                            candidateSymbols = CopySymbols(symbols)
                            candidateSymbols.mode = modeSelection.index
                            description = string.format("%s (%s)", description, modeSelection.text)
                        end
                    elseif isAutoForcedMovementModePrompt then
                        modeSelection, modeReason = self:ChooseForcedMovementModeSelection(context, actor, abilityInfo, targets[1].token, score)
                        if modeSelection ~= nil then
                            candidateSymbols = CopySymbols(symbols)
                            candidateSymbols.mode = modeSelection.index
                            description = string.format("%s (%s)", description, modeSelection.text)
                        end
                    end

                    if isAutoGrabModePrompt and modeSelection == nil then
                        self:Skip(ability, modeReason or "Grab mode unavailable")
                    elseif isAutoForcedMovementModePrompt and modeSelection == nil then
                        self:Skip(ability, modeReason or "forced movement mode unavailable")
                    else
                        local candidate, buildReason = self:BuildCandidate(ability, abilityInfo, locInfo.loc, targets[1], candidateSymbols, {
                            context = context,
                            actor = actor,
                            casterToken = token,
                            actorDazed = actorDazed,
                            disablePreInvokeMove = #targets ~= 1,
                            targets = targets,
                            scoreInfo = score,
                            modeSelection = modeSelection,
                            enumeratorRule = "single-target",
                            description = description,
                        })
                        if candidate ~= nil then
                            candidates[#candidates+1] = candidate
                        else
                            self:Skip(ability, buildReason or "candidate unavailable")
                        end
                    end
                end
            end)
        end, nil)
    end

    return candidates
end

function AI:TokensInShape(shape, tokens)
    local result = {}
    if shape == nil then
        return result
    end

    for _,tok in ipairs(tokens) do
        local contains = SafeCall(function()
            return shape:ContainsToken(tok)
        end, false)
        if contains then
            result[#result+1] = tok
        end
    end

    return result
end

function AI:IsAreaTargetType(targetType)
    targetType = Lower(targetType)
    return targetType == "all"
        or targetType == "line"
        or targetType == "cone"
        or targetType == "cube"
        or targetType == "sphere"
        or targetType == "cylinder"
        or targetType == "areatemplate"
end

function AI:IsAreaAbilityInfo(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    local targetType = Lower(abilityInfo.targetType or "")
    if self:IsAreaTargetType(targetType) then
        return true
    end

    if abilityInfo.isArea and abilityInfo.hasAura then
        return true
    end

    if abilityInfo.isArea and (targetType == "self" or targetType == "target" or targetType == "") then
        return (tonumber(abilityInfo.radius) or 0) > 0
            or (tonumber(abilityInfo.range) or 0) > 0
            or (tonumber(abilityInfo.numTargets) or 0) > 1
    end

    return false
end

function AI:AreaShapeName(abilityInfo)
    local targetType = Lower(abilityInfo and abilityInfo.targetType or "")
    if self:IsAreaTargetType(targetType) then
        return targetType
    end

    if abilityInfo ~= nil and abilityInfo.isArea and abilityInfo.hasAura then
        return "cube"
    end

    if abilityInfo ~= nil and abilityInfo.isArea and (targetType == "self" or targetType == "target" or targetType == "") then
        return "all"
    end

    return targetType
end

function AI:AreaRadius(abilityInfo)
    if abilityInfo == nil then
        return 0
    end

    local shapeName = self:AreaShapeName(abilityInfo)
    if shapeName == "all" then
        local radius = tonumber(abilityInfo.radius) or 0
        if radius > 0 then
            return radius
        end

        return abilityInfo.range or 0
    end

    local radius = tonumber(abilityInfo.radius) or 0
    if radius > 0 then
        return radius
    end

    if abilityInfo.isArea and abilityInfo.hasAura and (abilityInfo.numTargets or 0) > 1 then
        return abilityInfo.numTargets
    end

    return radius
end

local function AreaPlacementRange(ability, abilityInfo, casterToken, symbols)
    local range = tonumber(abilityInfo and abilityInfo.range) or 0
    local dynamicRange = nil
    if ability ~= nil and casterToken ~= nil then
        dynamicRange = SafeCall(function()
            return ability:GetRange(casterToken.properties, symbols or {})
        end, nil)
    end

    if dynamicRange ~= nil then
        range = tonumber(dynamicRange) or range
    end

    return math.max(0, range)
end

local function AreaPlacementReason(base, options, detail)
    local reason = tostring(base or "area placement illegal")
    if options ~= nil and options.afterMovement then
        reason = reason .. " after movement"
    end
    if detail ~= nil and detail ~= "" then
        reason = reason .. " " .. tostring(detail)
    end
    return reason
end

local function AreaPlacementLegality(ai, context, actor, ability, abilityInfo, casterToken, casterLoc, anchorLoc, targetArea, symbols, options)
    options = options or {}
    local function Result(ok, reason, args)
        args = args or {}
        return ai:MakeLegalityResult{
            ok = ok == true,
            kind = "area",
            phase = args.phase or options.phase,
            reasonCode = args.reasonCode or options.reasonCode,
            reason = reason,
            friendly = args.friendly,
            target = args.target,
            loc = args.loc or anchorLoc or TryGet(targetArea, "origin", nil),
            area = targetArea,
            engine = args.engine,
            details = args.details,
        }
    end

    if abilityInfo == nil then
        return Result(false, AreaPlacementReason("area ability missing metadata", options))
    end

    if not ai:IsAreaAbilityInfo(abilityInfo) then
        return Result(true, nil)
    end

    casterToken = casterToken or (actor and actor.token)
    if casterToken == nil then
        return Result(false, AreaPlacementReason("area caster missing", options))
    end

    local shapeName = ai:AreaShapeName(abilityInfo)
    if shapeName == "all" then
        return Result(true, nil)
    end

    local placementLoc = TryGet(targetArea, "origin", nil) or anchorLoc
    if placementLoc == nil then
        return Result(false, AreaPlacementReason("area origin missing", options))
    end

    if TryGet(placementLoc, "valid", true) == false or TryGet(placementLoc, "isOnMap", true) == false then
        return Result(false, AreaPlacementReason("area origin invalid", options))
    end

    local originLoc = casterLoc or TryGet(casterToken, "loc", nil)
    if originLoc == nil then
        return Result(false, AreaPlacementReason("area caster location missing", options))
    end

    local range = AreaPlacementRange(ability, abilityInfo, casterToken, symbols or {})
    local distance = LocDistance(originLoc, placementLoc)
    if distance > range + 0.1 then
        return Result(false, AreaPlacementReason(
            "area origin out of range",
            options,
            string.format("(%0.1f > %0.1f)", distance, range)
        ), {
            engine = {
                distance = distance,
                range = range,
            },
        })
    end

    local hasLos = true
    if distance > 0.1 then
        local function EvaluateLineOfSight()
            if ai.CachedHasLineOfSight ~= nil then
                return ai:CachedHasLineOfSight(context, casterToken, placementLoc, {
                    sourceLoc = originLoc,
                    targetLoc = placementLoc,
                    areaOrigin = placementLoc,
                    targetArea = targetArea,
                    pierceSource = casterToken,
                    mode = "area",
                })
            end

            return HasLineOfSight(casterToken, placementLoc)
        end

        local currentLoc = TryGet(casterToken, "loc", nil)
        local evaluated = false
        if originLoc ~= nil and currentLoc ~= nil and LocKey(originLoc) ~= LocKey(currentLoc) then
            SafeCall(function()
                casterToken:ExecuteWithTheoreticalLoc(originLoc, function()
                    hasLos = EvaluateLineOfSight()
                    evaluated = true
                end)
            end, nil)
        end

        if not evaluated then
            hasLos = EvaluateLineOfSight()
        end
    end

    if hasLos ~= true then
        return Result(false, AreaPlacementReason("area origin had no line of sight", options), {
            engine = {
                lineOfSight = false,
            },
        })
    end

    return Result(true, nil, {
        engine = {
            distance = distance,
            range = range,
            lineOfSight = true,
        },
    })
end

function AI:ValidateAreaPlacement(context, actor, ability, abilityInfo, casterToken, casterLoc, anchorLoc, targetArea, symbols, options)
    return self:LegalityResultToTuple(AreaPlacementLegality(self, context, actor, ability, abilityInfo, casterToken, casterLoc, anchorLoc, targetArea, symbols, options))
end

local function CombatTokensForArea(context, options)
    options = options or {}
    if options.combatTokens ~= nil then
        return options.combatTokens
    end

    if context ~= nil and context.allCombatTokens ~= nil then
        return context.allCombatTokens
    end

    if dmhub ~= nil then
        return dmhub.allTokens or {}
    end

    return {}
end

function AI:CheckAreaLegality(context, actor, ability, abilityInfo, casterToken, casterLoc, anchorLoc, targetArea, symbols, options)
    options = options or {}
    casterToken = casterToken or (actor and actor.token)

    local placement = AreaPlacementLegality(self, context, actor, ability, abilityInfo, casterToken, casterLoc, anchorLoc, targetArea, symbols, options)
    if placement.ok ~= true then
        placement.targets = {}
        placement.friendlyCollateral = 0
        placement.targetDetails = {}
        return placement
    end

    local shapeTokens = options.shapeTokens
    if shapeTokens == nil then
        shapeTokens = self:TokensInShape(targetArea, CombatTokensForArea(context, options))
    end
    local scannedTokens = {}
    local seenShapeTokens = {}
    local function AddShapeToken(entry)
        local token = entry
        if type(entry) == "table" and entry.token ~= nil then
            token = entry.token
        end
        if not IsTokenValid(token) then
            return
        end

        local key = CacheTokenKey(token)
        if seenShapeTokens[key] then
            return
        end

        seenShapeTokens[key] = true
        scannedTokens[#scannedTokens+1] = token
    end
    for _,targetToken in ipairs(shapeTokens or {}) do
        AddShapeToken(targetToken)
    end
    for _,targetEntry in ipairs(options.targets or {}) do
        AddShapeToken(targetEntry)
    end
    shapeTokens = scannedTokens

    local targets = {}
    local friendlyCollateral = 0
    local targetDetails = {}
    for _,targetToken in ipairs(shapeTokens or {}) do
        if IsTokenValid(targetToken) then
            local targetResult = self:CheckTargetLegality(context, actor, ability, abilityInfo, casterToken, targetToken, symbols, {
                areaTarget = true,
                targetArea = targetArea,
                anchorLoc = anchorLoc,
                skipLineOfSight = options.skipLineOfSight,
                phase = options.phase,
                source = "CheckAreaLegality",
            })
            targetDetails[#targetDetails+1] = targetResult
            if targetResult.ok == true then
                if targetResult.friendly and TokenId(targetToken) ~= TokenId(casterToken) then
                    friendlyCollateral = friendlyCollateral + 1
                end
                targets[#targets+1] = { token = targetToken }
            end
        end
    end

    if #targets == 0 and options.allowEmpty ~= true then
        local result = self:MakeLegalityResult{
            ok = false,
            kind = "area",
            phase = options.phase,
            reasonCode = "area_no_legal_targets",
            reason = "area affected no legal targets",
            friendly = false,
            loc = anchorLoc or TryGet(targetArea, "origin", nil),
            area = targetArea,
            details = {
                targetDetails = targetDetails,
            },
        }
        result.targets = targets
        result.friendlyCollateral = friendlyCollateral
        result.targetDetails = targetDetails
        return result
    end

    if self:AbilityHasHostileEffect(abilityInfo) and friendlyCollateral > 0 then
        local result = self:MakeLegalityResult{
            ok = false,
            kind = "area",
            phase = options.phase,
            reasonCode = "friendly_collateral",
            reason = "hostile area would catch allies",
            friendly = true,
            loc = anchorLoc or TryGet(targetArea, "origin", nil),
            area = targetArea,
            details = {
                friendlyCollateral = friendlyCollateral,
                targets = targets,
                targetDetails = targetDetails,
            },
        }
        result.targets = targets
        result.friendlyCollateral = friendlyCollateral
        result.targetDetails = targetDetails
        return result
    end

    placement.targets = targets
    placement.friendlyCollateral = friendlyCollateral
    placement.targetDetails = targetDetails
    placement.details = placement.details or {}
    placement.details.targets = targets
    placement.details.friendlyCollateral = friendlyCollateral
    placement.details.targetDetails = targetDetails
    return placement
end

function AI:CalculateAreaShape(token, abilityInfo, anchorLoc)
    local targetPoint = SafeCall(function()
        return token:PosAtLoc(anchorLoc)
    end, nil)

    if targetPoint == nil then
        return nil
    end

    local shapeName = self:AreaShapeName(abilityInfo)
    local range = abilityInfo.range
    local radius = self:AreaRadius(abilityInfo)
    if shapeName == "all" then
        shapeName = "RadiusFromCreature"
        range = 0
        radius = abilityInfo.range
    end

    local altitude = nil
    if shapeName == "cube" and anchorLoc ~= nil then
        altitude = (TryGet(anchorLoc, "altitude", 0) or 0) * dmhub.unitsPerSquare
    end

    return SafeCall(function()
        return dmhub.CalculateShape{
            shape = shapeName,
            targetPoint = targetPoint,
            token = token,
            range = range,
            radius = radius,
            checklos = true,
            altitude = altitude,
        }
    end, nil)
end

function AI:AreaAnchorLocs(actor, abilityInfo, originLoc, skipRangeFilter)
    local result = {}
    local seen = {}
    local token = actor.token
    originLoc = originLoc or TryGet(token, "loc", nil)
    local shapeName = self:AreaShapeName(abilityInfo)
    local radius = math.max(0, math.ceil(self:AreaRadius(abilityInfo) or 0))
    local range = math.max(0, tonumber(abilityInfo.range) or 0)

    local function Add(loc)
        if loc == nil then
            return
        end

        if TryGet(loc, "valid", true) == false or TryGet(loc, "isOnMap", true) == false then
            return
        end

        local key = tostring(TryGet(loc, "str", nil) or string.format("%s:%s:%s:%s",
            tostring(TryGet(loc, "x", "")),
            tostring(TryGet(loc, "y", "")),
            tostring(TryGet(loc, "floor", "")),
            tostring(TryGet(loc, "altitude", ""))))
        if seen[key] then
            return
        end

        if not skipRangeFilter and shapeName ~= "all" and LocDistance(originLoc, loc) > range + 0.1 then
            return
        end

        seen[key] = true
        result[#result+1] = loc
    end

    if shapeName == "all" then
        Add(originLoc)
        return result
    end

    local offset = 0
    if shapeName == "cube" or shapeName == "sphere" or shapeName == "cylinder" then
        offset = math.max(1, radius)
    end

    for _,enemy in ipairs(actor.enemies or {}) do
        if IsTokenValid(enemy) then
            if offset <= 0 then
                Add(enemy.loc)
            else
                for dx = -offset, offset do
                    for dy = -offset, offset do
                        Add(SafeCall(function()
                            return enemy.loc:dir(dx, dy)
                        end, nil))
                    end
                end
            end
        end
    end

    return result
end

function AI:EnumerateAreaAbility(context, actor, ability, abilityInfo)
    local candidates = {}
    local token = actor.token
    local locs = self:GetReachableLocs(token, actor, 20)
    if self:TargetHasCondition(token, "Dazed") or self:AbilityHasNestedMovementPrompt(abilityInfo) then
        locs = { { loc = token.loc, cost = 0, positionScore = 0 } }
    end
    local shapeName = self:AreaShapeName(abilityInfo)
    local range = math.max(0, tonumber(abilityInfo.range) or 0)
    local anchorLocs = self:AreaAnchorLocs(actor, abilityInfo, token.loc, true)
    local modeSelection = abilityInfo and abilityInfo.modeSelection or nil
    local modeIndex = tonumber(modeSelection and modeSelection.index) or 1

    for _,locInfo in ipairs(locs) do
        SafeCall(function()
            token:ExecuteWithTheoreticalLoc(locInfo.loc, function()
                local locAnchorLocs = anchorLocs
                if shapeName == "all" then
                    locAnchorLocs = { locInfo.loc }
                end

                for _,anchorLoc in ipairs(locAnchorLocs) do
                    if shapeName == "all" or LocDistance(locInfo.loc, anchorLoc) <= range + 0.1 then
                        local shape = self:CalculateAreaShape(token, abilityInfo, anchorLoc)
                        local symbols = { mode = modeIndex, targetArea = shape }
                        local areaLegality = self:CheckAreaLegality(context, actor, ability, abilityInfo, token, locInfo.loc, anchorLoc, shape, symbols, {
                            phase = "candidate.enumeration",
                        })
                        if areaLegality.ok ~= true then
                            self:Skip(ability, areaLegality.reason)
                        else
                            local targets = areaLegality.targets or {}
                            local score = self:ScoreTargets(context, actor, abilityInfo, targets, locInfo.loc)
                            AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
                            self:AddMovementHazardScore(score, token, locInfo, false, context)
                            candidates[#candidates+1] = self:MakeCandidate{
                                actor = actor,
                                ability = ability,
                                abilityInfo = abilityInfo,
                                loc = locInfo.loc,
                                targets = targets,
                                targetArea = shape,
                                areaAnchorLoc = anchorLoc,
                                symbols = symbols,
                                scoreInfo = score,
                                modeSelection = modeSelection,
                                enumeratorRule = "area",
                                legalityResult = areaLegality,
                                description = string.format(
                                    "%s%s area (%d targets)",
                                    abilityInfo.name,
                                    modeSelection ~= nil and string.format(" (%s)", modeSelection.text or ("mode " .. tostring(modeSelection.index))) or "",
                                    #targets
                                ),
                            }
                        end
                    end
                end
            end)
        end, nil)
    end

    return candidates
end

function AI:EnumerateSelfAbility(context, actor, ability, abilityInfo)
    if self:IsStandUpName(abilityInfo.name) and not self:ShouldUseStandUp(actor) then
        return {}
    end

    local score = CreateScore()
    AddScore(score, "self value", math.max(abilityInfo.supportValue, abilityInfo.conditionValue, abilityInfo.forcedMovementValue, 1))
    if self:IsStandUpName(abilityInfo.name) then
        AddScore(score, "stand up", 12)
    end
    if self:IsDefendName(abilityInfo.name) then
        AddScore(score, "defend", self:DefendScore(actor))
    end
    if self:IsSoloActionName(abilityInfo.name) then
        AddScore(score, "solo action", 12)
    end
    if abilityInfo.isVillain then
        AddScore(score, "villain action", ConstNumber("Score", "VillainActionBase", 8))
    end
    if abilityInfo.isMalice then
        local malice = self:MaliceScoreParts(context, abilityInfo)
        AddScore(score, "malice impact", malice.impact)
        AddScore(score, "malice cost priority", malice.costPriority)
        AddScore(score, "malice unavailable", malice.unavailable)
    end

    local modeSelection = abilityInfo and abilityInfo.modeSelection or nil
    local modeIndex = tonumber(modeSelection and modeSelection.index) or 1
    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = actor.token.loc,
            targets = { { token = actor.token } },
            symbols = { mode = modeIndex },
            scoreInfo = score,
            modeSelection = modeSelection,
            enumeratorRule = "self",
            description = string.format(
                "%s%s on self",
                abilityInfo.name,
                modeSelection ~= nil and string.format(" (%s)", modeSelection.text or ("mode " .. tostring(modeSelection.index))) or ""
            ),
        }
    }
end

function AI:FindSquadAssignment(context, actor, member, ability, abilityInfo, assignedCounts, reservedDestinations)
    local best = nil
    local locs = self:GetReachableLocs(member.token, actor, 20)
    local symbols = { mode = 1 }

    for _,locInfo in ipairs(locs) do
        SafeCall(function()
            member.token:ExecuteWithTheoreticalLoc(locInfo.loc, function()
                for _,enemy in ipairs(actor.enemies) do
                    local count = assignedCounts[enemy.charid] or 0
                    if self:DirectorTargetCheapAllowed(context, actor, ability, abilityInfo, member.token, enemy) then
                        local dist = Distance(member.token, enemy)
                        local chargeInfo = nil
                        if dist > abilityInfo.range + 0.1 then
                            chargeInfo = self:ChargeMoveInfo(context, member.token, abilityInfo, enemy, actor)
                            if chargeInfo ~= nil then
                                dist = SafeCall(function()
                                    return enemy:Distance(chargeInfo.loc)
                                end, LocDistance(chargeInfo.loc, enemy.loc))
                            end
                        end

                        local finalLoc = chargeInfo and chargeInfo.loc or locInfo.loc
                        if dist <= abilityInfo.range + 0.1
                            and self:CachedHasLineOfSight(context, member.token, enemy)
                            and self:DirectorTargetAllowed(context, actor, ability, abilityInfo, member.token, enemy, symbols)
                            and not self:MovementDestinationReserved(member.token, finalLoc, reservedDestinations)
                        then
                            -- TODO Phase 3 compat: squad assignments keep legacy target.chargeLoc
                            -- fields until a dedicated squad proposal shape migrates this flow.
                            local target = {
                                token = enemy,
                                chargeLoc = chargeInfo and chargeInfo.loc,
                                chargeDistance = chargeInfo and chargeInfo.distance,
                                chargeHazardDamage = chargeInfo and chargeInfo.hazardDamage,
                            }
                            local score = self:ScoreTargets(context, actor, abilityInfo, { target }, target.chargeLoc or locInfo.loc)
                            local duplicatePenalty = Pick(self:ObjectiveNeedsFocus(context), ConstNumber("Squad", "DuplicatePenaltyFocus", 0.8), ConstNumber("Squad", "DuplicatePenaltyDefault", 3))
                            AddScore(score, "squad duplicate", -count * duplicatePenalty)
                            AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
                            self:AddMovementHazardScore(score, member.token, locInfo, false, context)
                            if (target.chargeHazardDamage or 0) > 0 then
                                AddScore(score, "charge hazard", -(target.chargeHazardDamage or 0) * 3)
                            end
                            AddScore(score, "member position", self:PositionScore(actor, target.chargeLoc or locInfo.loc, abilityInfo, enemy).total * 0.25)

                            local assignmentKey = AssignmentSortKey(member, enemy, locInfo.loc, target.chargeLoc)
                            if best == nil or score.total > best.scoreInfo.total or (score.total == best.scoreInfo.total and assignmentKey < best.assignmentKey) then
                                best = {
                                    member = member,
                                    loc = locInfo.loc,
                                    target = enemy,
                                    chargeLoc = target.chargeLoc,
                                    chargeDistance = target.chargeDistance,
                                    scoreInfo = score,
                                    assignmentKey = assignmentKey,
                                }
                            end
                        end
                    end
                end
            end)
        end, nil)
    end

    return best
end

local function TargetDistanceFromLoc(target, loc)
    if target == nil or loc == nil then
        return 999
    end

    local fallback = 999
    if target.loc ~= nil then
        fallback = LocDistance(loc, target.loc)
    end

    return tonumber(SafeCall(function()
        return target:Distance(loc)
    end, fallback)) or fallback
end

local function NearestSupportTarget(targets, loc)
    local bestTarget = nil
    local bestDistance = 999
    for _,entry in ipairs(targets or {}) do
        local target = entry and (entry.token or entry)
        if IsTokenValid(target) then
            local distance = TargetDistanceFromLoc(target, loc)
            if distance < bestDistance then
                bestTarget = target
                bestDistance = distance
            end
        end
    end

    return bestTarget, bestDistance
end

function AI:FindSquadSupportMove(context, actor, member, abilityInfo, primaryTargets, reservedDestinations)
    if member == nil or not IsTokenValid(member.token) then
        return nil
    end

    local token = member.token
    local target, currentDistance = NearestSupportTarget(primaryTargets, token.loc)
    if target == nil then
        target, currentDistance = NearestSupportTarget(actor.enemies, token.loc)
    end
    if target == nil or currentDistance >= 999 then
        return nil
    end

    local desired = self:AdvanceDesiredRange(actor)
    local currentScore = self:PositionScore(actor, token.loc, abilityInfo, target)
    local best = nil
    local locs = self:GetReachableLocs(token, actor, 20)

    for _,locInfo in ipairs(locs) do
        local loc = locInfo.loc
        if loc ~= nil
            and LocDistance(loc, token.loc) > 0
            and not self:MovementDestinationReserved(token, loc, reservedDestinations)
            and self:IsMovementDestinationClear(context, token, loc)
            and self:MovementAllowedByFrightened(context, token, loc)
        then
            local nearestTarget, distance = NearestSupportTarget(primaryTargets, loc)
            if nearestTarget == nil then
                nearestTarget, distance = NearestSupportTarget(actor.enemies, loc)
            end

            local closing = currentDistance - distance
            local rangeImprovement = math.abs(currentDistance - desired) - math.abs(distance - desired)
            local positionScore = self:PositionScore(actor, loc, abilityInfo, nearestTarget or target)
            local positionImprovement = positionScore.total - currentScore.total

            if closing > 0.1 or rangeImprovement > 0.25 or positionImprovement > 0.5 then
                local score = CreateScore()
                AddScore(score, "support closing", math.min(0.6, math.max(0, closing) * 0.12))
                AddScore(score, "support range", math.min(0.3, math.max(0, rangeImprovement) * 0.1))
                AddScore(score, "support position", math.min(0.4, math.max(0, positionImprovement) * 0.08))
                AddScore(score, "move cost", -(locInfo.cost or 0) * 0.001)
                self:AddMovementHazardScore(score, token, locInfo, false, context)
                local oscillationPenalty = self:MovementOscillationPenalty(token, loc)
                if oscillationPenalty > 0 then
                    AddScore(score, "anti-oscillation", -oscillationPenalty * 0.5)
                end

                if score.total > 0 then
                    local supportKey = AssignmentSortKey(member, nearestTarget or target, loc, nil)
                    if best == nil or score.total > best.scoreInfo.total or (score.total == best.scoreInfo.total and supportKey < best.assignmentKey) then
                        best = {
                            member = member,
                            loc = loc,
                            target = nearestTarget or target,
                            scoreInfo = score,
                            assignmentKey = supportKey,
                        }
                    end
                end
            end
        end
    end

    return best
end

function AI:EnumerateSquadAbility(context, actor, ability, abilityInfo)
    if not abilityInfo.isStrike then
        return {}
    end

    local assignments = {}
    local assignedMembers = {}
    local assignedCounts = {}
    local score = CreateScore()
    local uniqueTargets = {}
    local uniqueTargetsList = {}
    local targetPairs = {}
    local reservedDestinations = {}

    for _,member in ipairs(actor.squadMembers or {}) do
        if IsTokenValid(member.token) then
            local assignment = self:FindSquadAssignment(context, actor, member, ability, abilityInfo, assignedCounts, reservedDestinations)
            if assignment ~= nil then
                assignments[#assignments+1] = assignment
                assignedMembers[CacheTokenKey(member.token)] = true
                self:ReserveMovementDestination(assignment.member.token, assignment.chargeLoc or assignment.loc, reservedDestinations)
                assignedCounts[assignment.target.charid] = (assignedCounts[assignment.target.charid] or 0) + 1
                targetPairs[#targetPairs+1] = { a = member.token.charid, b = assignment.target.charid }
                if not uniqueTargets[assignment.target.charid] then
                    uniqueTargets[assignment.target.charid] = true
                    uniqueTargetsList[#uniqueTargetsList+1] = { token = assignment.target }
                end
                AddScore(score, string.format("minion %s -> %s", TokenName(assignment.member.token), TokenName(assignment.target)), assignment.scoreInfo.total)
            end
        end
    end

    if #assignments == 0 then
        return {}
    end

    local supportMoves = {}
    for _,member in ipairs(actor.squadMembers or {}) do
        if IsTokenValid(member.token) and not assignedMembers[CacheTokenKey(member.token)] then
            local supportMove = self:FindSquadSupportMove(context, actor, member, abilityInfo, uniqueTargetsList, reservedDestinations)
            if supportMove ~= nil then
                supportMoves[#supportMoves+1] = supportMove
                self:ReserveMovementDestination(supportMove.member.token, supportMove.loc, reservedDestinations)
                AddScore(score, string.format("support %s closes", TokenName(supportMove.member.token)), supportMove.scoreInfo.total)
            end
        end
    end

    AddScore(score, "squad size", #assignments * 0.4)
    if #supportMoves > 0 then
        AddScore(score, "support movers", #supportMoves * 0.1)
    end

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = actor.token.loc,
            targets = uniqueTargetsList,
            symbols = { mode = 1, targetPairs = targetPairs },
            targetPairs = targetPairs,
            squadAssignments = assignments,
            squadSupportMoves = Pick(#supportMoves > 0, supportMoves, nil),
            scoreInfo = score,
            enumeratorRule = "squad-strike",
            description = string.format("%s squad strike (%d attackers, %d targets)", abilityInfo.name, #assignments, #uniqueTargetsList),
        }
    }
end

function AI:AdvanceDesiredRange(actor)
    local profile = actor.profile or self.roleProfiles.standard
    return profile.desiredRange or 1
end

function AI:AdvanceMoveDistance(actor, abilityInfo)
    local speed = SafeCall(function()
        return actor.token.properties:CurrentMovementSpeed()
    end, 0)
    local range = tonumber(abilityInfo and abilityInfo.range) or 0
    return math.max(0, math.max(speed, range))
end

function AI:AdvanceTargets(actor, abilityInfo, loc)
    local targetType = Lower(abilityInfo and abilityInfo.targetType or "")
    if targetType == "emptyspace" or targetType == "anyspace" or targetType == "map" then
        return { { loc = loc } }
    end

    return { { token = actor.token } }
end

local function HostileCountNearLoc(actor, loc, limit)
    local count = 0
    limit = tonumber(limit) or 1.1
    for _,enemy in ipairs(actor and actor.enemies or {}) do
        if IsTokenValid(enemy) and enemy.loc ~= nil and LocDistance(loc, enemy.loc) <= limit then
            count = count + 1
        end
    end
    return count
end

local function HostileHasFullLineOfSight(actor, token)
    if token == nil then
        return true
    end

    for _,enemy in ipairs(actor and actor.enemies or {}) do
        if IsTokenValid(enemy) then
            local los = SafeCall(function()
                return enemy:GetLineOfSight(token, 0)
            end, 1)
            if tonumber(los) ~= nil and tonumber(los) >= 1 then
                return true
            end
        end
    end

    return false
end

local function HideRoleAllowed(ai, actor, abilityInfo)
    if ai == nil or actor == nil then
        return false
    end

    if ai:IsPreferredByOverride(actor, abilityInfo) then
        return true
    end

    return ai:RoleIs(actor, "ambusher")
end

local function HiddenHostilesForSearch(ai, context, actor, ability, abilityInfo)
    local result = {}
    if ai == nil or actor == nil or actor.token == nil then
        return result
    end

    local symbols = { mode = 1 }
    local range = tonumber(abilityInfo and abilityInfo.range) or AbilityRange(ability, actor.token, symbols)
    local targetableSet = ai:TargetableSetFromEngine(ability, actor.token, actor.token.loc, {
        context = context,
        abilityInfo = abilityInfo,
        symbols = symbols,
    })

    for _,enemy in ipairs(actor.enemies or {}) do
        if IsTokenValid(enemy) and ai:TargetHasCondition(enemy, "Hidden") then
            local entry = TargetableSetEntry(targetableSet, enemy)
            local inRange = Distance(actor.token, enemy) <= range + 0.1
            local engineAccepted = entry ~= nil
                and entry.passedEngineFilter == true
                and (entry.distance or 999) <= (targetableSet._range or range) + 0.1
            if inRange or engineAccepted then
                result[#result+1] = {
                    token = enemy,
                    targetableEntry = entry,
                    inRange = inRange,
                    engineAccepted = engineAccepted,
                }
            end
        end
    end

    return result
end

function AI:EnumerateAdvanceAbility(context, actor, ability, abilityInfo)
    if not self.config.movement or not self:IsAdvanceAbilityInfo(abilityInfo) then
        return {}
    end

    local token = actor.token
    if self:TokenIsProne(token) then
        return {}
    end

    local currentNearest = self:NearestEnemyDistanceFromLoc(actor, token.loc)
    if currentNearest >= 999 then
        return {}
    end

    local desired = self:AdvanceDesiredRange(actor)
    local currentDelta = math.abs(currentNearest - desired)
    local originLoc = token.loc
    local best = nil

    local moveOptions = self:LegalMoveOptions(token, actor, "advance")
    local advanceOption = MovementModeOption(moveOptions, "advance")
    if advanceOption == nil then
        return {}
    end

    for _,locInfo in ipairs(advanceOption.reachableLocs or {}) do
        local loc = locInfo.loc
        if loc ~= nil and LocDistance(loc, originLoc) > 0 then
            local nearest = self:NearestEnemyDistanceFromLoc(actor, loc)
            local rangeImprovement = currentDelta - math.abs(nearest - desired)
            local closing = currentNearest - nearest
            if rangeImprovement > 0.2 or closing > 0.5 then
                local score = CreateScore()
                AddScore(score, "advance", 2)
                AddScore(score, "range improvement", math.min(8, math.max(0, rangeImprovement) * 1.1))
                AddScore(score, "closing", math.min(4, math.max(0, closing) * 0.6))
                if desired <= 2 and currentNearest > desired + 1 and closing > 0.5 then
                    AddScore(score, "melee setup", 5)
                end
                if math.abs(nearest - desired) <= 0.5 then
                    AddScore(score, "desired range", 2)
                end
                AddScore(score, "position", self:PositionScore(actor, loc, nil, actor.enemies[1]).total)
                AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
                self:AddMovementHazardScore(score, token, locInfo, false, context)

                if best == nil or score.total > best.scoreInfo.total then
                    best = {
                        advanceLoc = loc,
                        scoreInfo = score,
                    }
                end
            end
        end
    end

    if best == nil then
        return {}
    end

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            targets = self:AdvanceTargets(actor, abilityInfo, best.advanceLoc),
            advanceTargetLoc = best.advanceLoc,
            isAdvance = true,
            actionCost = self:AbilityActionCost(abilityInfo),
            symbols = { mode = 1 },
            scoreInfo = best.scoreInfo,
            enumeratorRule = "advance",
            description = string.format("%s to better position", abilityInfo.name),
        }
    }
end

function AI:EnumerateShiftAbility(context, actor, ability, abilityInfo)
    if not self.config.movement or abilityInfo == nil or not self:IsShiftName(abilityInfo.name) then
        return {}
    end

    local token = actor and actor.token
    if token == nil then
        return {}
    end

    local moveOptions = self:LegalMoveOptions(token, actor, "shift")
    local shiftOption = MovementModeOption(moveOptions, "shift")
    if shiftOption == nil then
        return {}
    end

    local originLoc = token.loc
    local currentScore = self:PositionScore(actor, originLoc, nil, actor.enemies[1])
    local currentEngaged = HostileCountNearLoc(actor, originLoc, 1.1)
    local best = nil

    for _,locInfo in ipairs(shiftOption.reachableLocs or {}) do
        local loc = locInfo.loc
        if loc ~= nil and LocDistance(loc, originLoc) > 0 then
            local score = self:PositionScore(actor, loc, nil, actor.enemies[1])
            local finalEngaged = HostileCountNearLoc(actor, loc, 1.1)
            local escapedThreats = math.max(0, currentEngaged - finalEngaged)

            AddScore(score, "shift", 1)
            if currentEngaged > 0 then
                AddScore(score, "engaged shift", currentEngaged * ConstNumber("Score", "ShiftEngagedBonus", 2.5))
            end
            if escapedThreats > 0 then
                AddScore(score, "escape threat", escapedThreats * ConstNumber("Score", "ShiftEscapeThreatBonus", 2))
            end
            AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
            self:AddMovementHazardScore(score, token, locInfo, false, context)

            if best == nil or score.total > best.scoreInfo.total then
                best = {
                    shiftLoc = loc,
                    scoreInfo = score,
                }
            end
        end
    end

    if best == nil then
        return {}
    end

    local improvement = best.scoreInfo.total - currentScore.total
    if currentEngaged <= 0 and improvement < ConstNumber("Candidate", "MovementOnlyMinimumScoreDelta", 0.75) then
        return {}
    end

    AddScore(best.scoreInfo, "shift improvement", improvement)
    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            targets = self:AdvanceTargets(actor, abilityInfo, best.shiftLoc),
            advanceTargetLoc = best.shiftLoc,
            isShift = true,
            actionCost = self:AbilityActionCost(abilityInfo),
            symbols = { mode = 1 },
            scoreInfo = best.scoreInfo,
            enumeratorRule = "shift",
            description = string.format("%s to safer position", abilityInfo.name),
        }
    }
end

function AI:EnumerateEscapeGrabAbility(context, actor, ability, abilityInfo)
    if abilityInfo == nil or not self:IsEscapeGrabName(abilityInfo.name) then
        return {}
    end

    if actor == nil or actor.token == nil or not self:TargetHasCondition(actor.token, "Grabbed") then
        return {}
    end

    local score = CreateScore()
    AddScore(score, "escape grab", ConstNumber("Score", "EscapeGrabBase", 14))
    AddScore(score, "lost turn prevention", 4)

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = actor.token.loc,
            targets = { { token = actor.token } },
            symbols = { mode = 1 },
            scoreInfo = score,
            enumeratorRule = "escape-grab",
            description = string.format("%s", abilityInfo.name),
        }
    }
end

function AI:EnumerateHideAbility(context, actor, ability, abilityInfo)
    if abilityInfo == nil or not self:IsHideName(abilityInfo.name) then
        return {}
    end

    local token = actor and actor.token
    if token == nil then
        return {}
    end

    if TryGet(token, "hasConcealment", false) ~= true then
        return {}
    end

    if HostileHasFullLineOfSight(actor, token) then
        return {}
    end

    if not HideRoleAllowed(self, actor, abilityInfo) then
        return {}
    end

    local score = CreateScore()
    AddScore(score, "hide", ConstNumber("Score", "HideAmbushBase", 4))
    if self:RoleIs(actor, "ambusher") then
        AddScore(score, "ambusher doctrine", 2)
    end

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = token.loc,
            targets = { { token = token } },
            symbols = { mode = 1 },
            scoreInfo = score,
            enumeratorRule = "hide",
            description = string.format("%s", abilityInfo.name),
        }
    }
end

function AI:EnumerateSearchForHiddenAbility(context, actor, ability, abilityInfo)
    if abilityInfo == nil or not self:IsSearchForHiddenName(abilityInfo.name) then
        return {}
    end

    local token = actor and actor.token
    if token == nil then
        return {}
    end

    local hiddenHostiles = HiddenHostilesForSearch(self, context, actor, ability, abilityInfo)
    if #hiddenHostiles == 0 then
        return {}
    end

    local targetType = Lower(abilityInfo.targetType or "")
    if targetType == "target" or targetType == "creature" then
        local candidates = {}
        for _,hidden in ipairs(hiddenHostiles) do
            if hidden.engineAccepted then
                local score = CreateScore()
                AddScore(score, "search hidden", ConstNumber("Score", "SearchHiddenBase", 10))
                local candidate = self:BuildCandidate(ability, abilityInfo, token.loc, hidden.token, { mode = 1 }, {
                    actor = actor,
                    context = context,
                    scoreInfo = score,
                    enumeratorRule = "search-hidden",
                    description = string.format("%s for %s", abilityInfo.name, TokenName(hidden.token)),
                })
                if candidate ~= nil then
                    candidates[#candidates+1] = candidate
                end
            end
        end
        return candidates
    end

    local score = CreateScore()
    AddScore(score, "search hidden", ConstNumber("Score", "SearchHiddenBase", 10))
    AddScore(score, "hidden hostiles", math.min(4, #hiddenHostiles))

    return {
        self:MakeCandidate{
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            loc = token.loc,
            targets = { { token = token } },
            symbols = { mode = 1 },
            scoreInfo = score,
            enumeratorRule = "search-hidden",
            description = string.format("%s", abilityInfo.name),
        }
    }
end

function AI:EnumerateMovementOnly(context, actor)
    if actor.turnMemory.movedOnly or not self.config.movement then
        return {}
    end

    if actor.kind ~= "squad"
        and self:TargetHasCondition(actor.token, "Dazed")
        and (actor.turnMemory.actionUsed
            or actor.turnMemory.maneuverUsed
            or (tonumber(actor.turnMemory.actionsUsed) or 0) > 0
            or (tonumber(actor.turnMemory.maneuversUsed) or 0) > 0)
    then
        return {}
    end

    if actor.kind ~= "squad" and self:ShouldUseStandUp(actor) then
        return {}
    end

    if actor.kind == "squad" then
        local assignments = {}
        local score = CreateScore()
        local reservedDestinations = {}
        for _,member in ipairs(actor.squadMembers or {}) do
            if IsTokenValid(member.token) then
                local locs = self:GetReachableLocs(member.token, actor, 20)
                local best = nil
                local currentScore = self:PositionScore(actor, member.token.loc, nil, actor.enemies[1])
                for _,locInfo in ipairs(locs) do
                    if not self:MovementDestinationReserved(member.token, locInfo.loc, reservedDestinations) then
                        local memberScore = self:PositionScore(actor, locInfo.loc, nil, actor.enemies[1])
                        AddScore(memberScore, "move cost", -(locInfo.cost or 0) * 0.002)
                        self:AddMovementHazardScore(memberScore, member.token, locInfo, false, context)
                        local oscillationPenalty = self:MovementOscillationPenalty(member.token, locInfo.loc)
                        if oscillationPenalty > 0 then
                            AddScore(memberScore, "anti-oscillation", -oscillationPenalty)
                        end
                        if best == nil or memberScore.total > best.scoreInfo.total then
                            best = {
                                loc = locInfo.loc,
                                scoreInfo = memberScore,
                            }
                        end
                    end
                end

                if best ~= nil and LocDistance(best.loc, member.token.loc) > 0 then
                    local improvement = best.scoreInfo.total - currentScore.total
                    local threshold = ConstNumber("Candidate", "MovementOnlyMinimumScoreDelta", 0.75)
                    local highValueOverride = ConstNumber("Candidate", "MovementOscillationHighValueOverride", 3)
                    if improvement >= threshold or best.scoreInfo.total >= currentScore.total + highValueOverride then
                        assignments[#assignments+1] = {
                            member = member,
                            loc = best.loc,
                        }
                        self:ReserveMovementDestination(member.token, best.loc, reservedDestinations)
                        AddScore(best.scoreInfo, "movement improvement", improvement)
                        AddScore(score, "squad reposition", best.scoreInfo.total)
                    end
                end
            end
        end

        if #assignments == 0 then
            return {}
        end

        AddScore(score, "squad movement", #assignments)
        return {
            self:MakeCandidate{
                actor = actor,
                squadAssignments = assignments,
                targets = {},
                scoreInfo = score,
                movementOnly = true,
                enumeratorRule = "squad-reposition",
                description = string.format("Squad reposition (%d movers)", #assignments),
            }
        }
    end

    local token = actor.token
    local locs = self:GetReachableLocs(token, actor, 30)
    local best = nil
    local currentScore = self:PositionScore(actor, token.loc, nil, actor.enemies[1])

    for _,locInfo in ipairs(locs) do
        local score = self:PositionScore(actor, locInfo.loc, nil, actor.enemies[1])
        AddScore(score, "move cost", -(locInfo.cost or 0) * 0.002)
        self:AddMovementHazardScore(score, token, locInfo, false, context)
        local oscillationPenalty = self:MovementOscillationPenalty(token, locInfo.loc)
        if oscillationPenalty > 0 then
            AddScore(score, "anti-oscillation", -oscillationPenalty)
        end
        if best == nil or score.total > best.scoreInfo.total then
            best = {
                loc = locInfo.loc,
                scoreInfo = score,
            }
        end
    end

    if best == nil or LocDistance(best.loc, token.loc) <= 0 then
        return {}
    end

    local improvement = best.scoreInfo.total - currentScore.total
    if improvement < ConstNumber("Candidate", "MovementOnlyMinimumScoreDelta", 0.75)
        and best.scoreInfo.total < currentScore.total + ConstNumber("Candidate", "MovementOscillationHighValueOverride", 3)
    then
        return {}
    end

    AddScore(best.scoreInfo, "movement improvement", improvement)
    return {
        self:MakeCandidate{
            actor = actor,
            loc = best.loc,
            targets = {},
            scoreInfo = best.scoreInfo,
            movementOnly = true,
            enumeratorRule = "movement-only",
            description = "Reposition",
        }
    }
end

function AI:EnumerateGenericAbility(context, actor, ability, abilityInfo)
    if abilityInfo.hasSummon then
        self:Skip(ability, "summon placement unsupported")
        return {}
    end

    if actor.kind == "squad" then
        return self:EnumerateSquadAbility(context, actor, ability, abilityInfo)
    end

    if self:IsSoloActionName(abilityInfo.name) then
        return self:EnumerateSelfAbility(context, actor, ability, abilityInfo)
    end

    if self:IsStandUpName(abilityInfo.name) then
        return self:EnumerateSelfAbility(context, actor, ability, abilityInfo)
    end

    if self:IsAdvanceAbilityInfo(abilityInfo) then
        return self:EnumerateAdvanceAbility(context, actor, ability, abilityInfo)
    end

    if self:IsShiftName(abilityInfo.name) then
        return self:EnumerateShiftAbility(context, actor, ability, abilityInfo)
    end

    if self:IsEscapeGrabName(abilityInfo.name) then
        return self:EnumerateEscapeGrabAbility(context, actor, ability, abilityInfo)
    end

    if self:IsHideName(abilityInfo.name) then
        return self:EnumerateHideAbility(context, actor, ability, abilityInfo)
    end

    if self:IsSearchForHiddenName(abilityInfo.name) then
        return self:EnumerateSearchForHiddenAbility(context, actor, ability, abilityInfo)
    end

    if self:IsAreaAbilityInfo(abilityInfo) then
        return self:EnumerateAreaAbility(context, actor, ability, abilityInfo)
    end

    if abilityInfo.targetType == "self" then
        return self:EnumerateSelfAbility(context, actor, ability, abilityInfo)
    end

    if abilityInfo.targetType == "target" then
        return self:EnumerateSingleTargetAbility(context, actor, ability, abilityInfo)
    end

    if TryGet(ability, "selfTarget", false) then
        return self:EnumerateSelfAbility(context, actor, ability, abilityInfo)
    end

    self:Skip(ability, "unsupported target type: " .. tostring(abilityInfo.targetType))
    return {}
end

function AI:PromoteAdvanceOverRangedFreeStrike(candidates)
    local advanceIndex = nil
    local rangedFreeStrikeIndex = nil

    for i,candidate in ipairs(candidates) do
        local execution = self.CandidateExecution and self:CandidateExecution(candidate) or {}
        local score = self.CandidateScoreTotal and self:CandidateScoreTotal(candidate) or candidate.score or 0
        if advanceIndex == nil and (execution.isAdvance or candidate.isAdvance) and score >= ConstNumber("Candidate", "AdvancePromotionThreshold", 0.8) then
            advanceIndex = i
        end

        if rangedFreeStrikeIndex == nil and candidate.abilityInfo ~= nil and self:IsRangedFreeStrikeName(candidate.abilityInfo.name) then
            rangedFreeStrikeIndex = i
        end
    end

    if advanceIndex ~= nil and rangedFreeStrikeIndex ~= nil and rangedFreeStrikeIndex < advanceIndex then
        local candidate = table.remove(candidates, advanceIndex)
        table.insert(candidates, rangedFreeStrikeIndex, candidate)
        self:Log("Advance promoted over Ranged Free Strike because closing position scored positively.")
    end
end

function AI:PromoteStandUpWhenProne(actor, candidates)
    if not self:ShouldUseStandUp(actor) then
        return
    end

    local standUpIndex = nil
    for i,candidate in ipairs(candidates) do
        if candidate.abilityInfo ~= nil and self:IsStandUpName(candidate.abilityInfo.name) then
            standUpIndex = i
            break
        end
    end

    if standUpIndex ~= nil and standUpIndex > 1 then
        local candidate = table.remove(candidates, standUpIndex)
        table.insert(candidates, 1, candidate)
        self:Log("Stand Up promoted because actor is prone.")
    end
end

function AI:EnumerateCandidatePipeline(context, actor, options)
    options = options or {}

    self:SyncTurnMemoryFromResources(actor)

    local candidates = {}
    local abilities = SafeCall(function()
        return actor.token.properties:GetActivatedAbilities()
    end, {}) or {}

    if self.TraceActive == nil or self:TraceActive() then
        local abilityNames = {}
        for _,ability in ipairs(abilities) do
            abilityNames[#abilityNames+1] = tostring(TryGet(ability, "name", "Ability"))
        end
        self:Trace("ability", "activated abilities", {
            actor = TokenName(actor and actor.token),
            count = #abilities,
            abilities = table.concat(abilityNames, " | "),
        })
    end

    for _,ability in ipairs(abilities) do
        local originalAbility = ability
        local info = self:AnalyzeAbility(actor, ability)
        local include = true
        local manualPromptCandidate = false
        local manualPromptReason = nil
        local unsafePromptReason = nil
        local promptCapability = nil
        local modeSelection = nil
        local skipReason = nil
        local abilityKey = TryGet(ability, "guid", TryGet(ability, "name", ""))
        local function SkipAbility(reason)
            skipReason = skipReason or reason
            self:Skip(ability, reason)
        end

        if actor.turnMemory.usedAbilities ~= nil and actor.turnMemory.usedAbilities[abilityKey] then
            local cost = self:AbilityActionCost(info)
            local refreshedResourceAvailable = false
            if info == nil or not info.isMalice then
                if cost == "action" then
                    refreshedResourceAvailable = not actor.turnMemory.actionUsed
                        or (self.Ledger ~= nil and self.Ledger.PendingGrantUseForActionType ~= nil and self.Ledger:PendingGrantUseForActionType(self, actor, { kind = "main" }, nil) ~= nil)
                elseif cost == "maneuver" then
                    refreshedResourceAvailable = not actor.turnMemory.maneuverUsed
                        or (self.Ledger ~= nil and self.Ledger.PendingGrantUseForActionType ~= nil and self.Ledger:PendingGrantUseForActionType(self, actor, { kind = "maneuver" }, nil) ~= nil)
                elseif cost == "movement" then
                    refreshedResourceAvailable = not (actor.turnMemory.movedOnly or actor.turnMemory.movementUsed)
                end
            end

            include = refreshedResourceAvailable and not actor.turnMemory.turnEnded
            if not include then
                SkipAbility("already used this turn")
            end
        end

        if include then
            local canUse, reason = self:CanUseActionCost(actor, info)
            if not canUse then
                include = false
                LogActionEconomySkipOnce(self, actor, ability, reason)
                SkipAbility(reason)
            end
        end

        if include and self:IsSuppressedUtilityAbility(actor, info) then
            include = false
            SkipAbility("standard utility ability suppressed")
        end

        if include and self:IsStandUpName(info.name) and not self:ShouldUseStandUp(actor) then
            include = false
            SkipAbility("not prone or cannot stand")
        end

        if include then
            local conditionReason = self:AbilityBlockedByActorCondition(actor, info)
            if conditionReason ~= nil then
                include = false
                SkipAbility(conditionReason)
            end
        end

        if include and info.isVillain then
            include = false
            SkipAbility("villain actions are handled at round end")
        end

        if include and info.isMalice and not self.config.maliceAbilities then
            include = false
            SkipAbility("malice abilities disabled")
        end

        if include and self:IsStartTurnMaliceAbility(info) then
            if self:IsSoloActionName(info.name) and self:ShouldUseSoloActionNow(context, actor, info, options) then
                -- Solo Action is the normal-turn exception; its grant is applied or queued by the ledger.
            else
                include = false
                SkipAbility("start-turn malice is handled once for the group")
            end
        end

        if include then
            local modeReason = nil
            local modeAdjustedInfo = nil
            modeSelection, modeReason, modeAdjustedInfo = self:ChooseTopLevelModeSelection(context, actor, info)
            if modeAdjustedInfo ~= nil then
                modeAdjustedInfo.baseAbility = originalAbility
                modeAdjustedInfo.baseAbilityKey = abilityKey
                info = modeAdjustedInfo
                ability = info.ability or ability
            elseif modeReason ~= nil then
                info.modePromptSkipReason = modeReason
            end

            if self.AssessPromptCapability ~= nil then
                promptCapability = self:AssessPromptCapability(context, actor, info, {
                    ability = ability,
                    abilityInfo = info,
                    modeSelection = modeSelection,
                    symbols = {
                        mode = tonumber(modeSelection and modeSelection.index) or 1,
                    },
                })
                if promptCapability ~= nil and promptCapability.status == "manual" then
                    manualPromptReason = promptCapability.reason or "manual targeting"
                elseif promptCapability ~= nil and promptCapability.status == "blocked" then
                    unsafePromptReason = promptCapability.reason or "unresolved prompt"
                end
            else
                manualPromptReason = self:AbilityManualPromptReason(info, context, actor)
                if manualPromptReason == nil then
                    unsafePromptReason = self:AbilityUnsafePromptReason(info, context, actor)
                end
            end
        end

        if include and manualPromptReason ~= nil then
            if self.config.manualPrompts then
                manualPromptCandidate = true
            else
                include = false
                SkipAbility(manualPromptReason)
            end
        end

        if include and unsafePromptReason ~= nil then
            include = false
            SkipAbility(unsafePromptReason)
        end

        if include and info.hasSummon and not manualPromptCandidate then
            include = false
            SkipAbility("summon placement unsupported")
        end

        if include then
            local affordSymbols = { mode = tonumber(modeSelection and modeSelection.index) or 1 }
            if info.isMalice then
                affordSymbols.charges = self:MaliceCost(info)
            end
            local affordable = AbilityCanAfford(ability, actor.token, affordSymbols)
            if not affordable and self.Ledger ~= nil and self.Ledger.CanAffordAbilityWithPendingGrant ~= nil then
                affordable = self.Ledger:CanAffordAbilityWithPendingGrant(self, actor, ability, info, affordSymbols)
            end
            if not affordable then
                include = false
                SkipAbility("cannot afford")
            end
        end

        if include and info.isMalice and context ~= nil and context.malice ~= nil and context.malice < self:MaliceCost(info) then
            include = false
            SkipAbility("cannot afford")
        end

        self:TraceAbilityInventory(actor, originalAbility, info, skipReason, modeSelection)

        if include and manualPromptCandidate then
            for _,candidate in ipairs(self:EnumerateManualPromptAbility(context, actor, ability, info, manualPromptReason, promptCapability)) do
                local actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost
                local canUseCandidate, candidateReason = self:CanUseActionCost(actor, candidate.abilityInfo, actionCost)
                if canUseCandidate then
                    self:AnnotatePromptCapability(candidate, promptCapability)
                    if self.Ledger ~= nil and self.Ledger.AnnotateCandidateActionGrant ~= nil then
                        self.Ledger:AnnotateCandidateActionGrant(self, actor, candidate)
                    end
                    self:SyncCandidateSections(candidate)
                    candidates[#candidates+1] = candidate
                else
                    self:Skip(candidate.ability or ability, candidateReason)
                end
            end
        elseif include then
            local matched = false
            local fallbackRules = {}
            local function AddCandidatesForRule(rule)
                local ok = true
                if rule.matches ~= nil then
                    ok = SafeCall(function()
                        return rule.matches(self, context, actor, ability, info)
                    end, false)
                end

                if not ok then
                    return false
                end

                local ruleCandidates = SafeCall(function()
                    return rule.enumerate(self, context, actor, ability, info)
                end, {})
                if manualPromptCandidate and #(ruleCandidates or {}) == 0 then
                    ruleCandidates = self:EnumerateManualPromptAbility(context, actor, ability, info, manualPromptReason, promptCapability)
                end
                for _,candidate in ipairs(ruleCandidates or {}) do
                    local actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost
                    local canUseCandidate, candidateReason = self:CanUseActionCost(actor, candidate.abilityInfo, actionCost)
                    if canUseCandidate then
                        self:AnnotatePromptCapability(candidate, promptCapability)
                        if self.Ledger ~= nil and self.Ledger.AnnotateCandidateActionGrant ~= nil then
                            self.Ledger:AnnotateCandidateActionGrant(self, actor, candidate)
                        end
                        candidate.rule = rule
                        if self.WriteCandidateIntent ~= nil then
                            self:WriteCandidateIntent(candidate, {
                                manualPrompt = (self.CandidateManualPrompt and self:CandidateManualPrompt(candidate) or candidate.manualPrompt == true) or manualPromptCandidate == true,
                                manualPromptReason = (self.CandidateManualPromptReason and self:CandidateManualPromptReason(candidate) or candidate.manualPromptReason) or manualPromptReason,
                            })
                        else
                            candidate.manualPrompt = candidate.manualPrompt or manualPromptCandidate
                            candidate.manualPromptReason = candidate.manualPromptReason or manualPromptReason
                        end
                        self:SyncCandidateSections(candidate)
                        candidates[#candidates+1] = candidate
                    else
                        self:Skip(candidate.ability or ability, candidateReason)
                    end
                end

                return true
            end

            for _,rule in ipairs(self.abilityRules) do
                if rule.fallback then
                    fallbackRules[#fallbackRules+1] = rule
                elseif AddCandidatesForRule(rule) then
                    matched = true
                end
            end

            if not matched then
                local fallbackMatched = false
                for _,rule in ipairs(fallbackRules) do
                    if AddCandidatesForRule(rule) then
                        fallbackMatched = true
                    end
                end

                if not fallbackMatched then
                    local generated = self:EnumerateGenericAbility(context, actor, ability, info)
                    if manualPromptCandidate and #generated == 0 then
                        generated = self:EnumerateManualPromptAbility(context, actor, ability, info, manualPromptReason, promptCapability)
                    end
                    for _,candidate in ipairs(generated) do
                        local actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost
                        local canUseCandidate, candidateReason = self:CanUseActionCost(actor, candidate.abilityInfo, actionCost)
                        if canUseCandidate then
                            self:AnnotatePromptCapability(candidate, promptCapability)
                            if self.Ledger ~= nil and self.Ledger.AnnotateCandidateActionGrant ~= nil then
                                self.Ledger:AnnotateCandidateActionGrant(self, actor, candidate)
                            end
                            if self.WriteCandidateIntent ~= nil then
                                self:WriteCandidateIntent(candidate, {
                                    manualPrompt = (self.CandidateManualPrompt and self:CandidateManualPrompt(candidate) or candidate.manualPrompt == true) or manualPromptCandidate == true,
                                    manualPromptReason = (self.CandidateManualPromptReason and self:CandidateManualPromptReason(candidate) or candidate.manualPromptReason) or manualPromptReason,
                                })
                            else
                                candidate.manualPrompt = candidate.manualPrompt or manualPromptCandidate
                                candidate.manualPromptReason = candidate.manualPromptReason or manualPromptReason
                            end
                            self:SyncCandidateSections(candidate)
                            candidates[#candidates+1] = candidate
                        else
                            self:Skip(candidate.ability or ability, candidateReason)
                        end
                    end
                end
            end
        end
    end

    for _,candidate in ipairs(self:EnumerateMovementOnly(context, actor)) do
        candidates[#candidates+1] = candidate
    end

    return candidates
end

function AI:FindCandidates(context, actor, options)
    options = options or {}
    local flow = options.flow or "analysisOnly"
    local result = self.Pipeline:Run(context, actor, flow, options)
    return result.ranked or {}
end

function AI:ChooseCandidate(context, actor)
    local result = self.Pipeline:Run(context, actor, "turn")
    return result.selected, result
end
