local mod = dmhub.GetModLoading()

-- DirectorTacticsExecution.lua executes selected candidates through DMHub ability invocation and prompt control.
-- Load after DirectorTacticsCandidates.lua and before DirectorTacticsAutomation.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsExecution.lua")
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
local Lower = Internal.Lower
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local TokenId = Internal.TokenId
local TokenName = Internal.TokenName
local AbilityCanAfford = Internal.AbilityCanAfford
local AbilityRequiresPrompt = Internal.AbilityRequiresPrompt
local AbilityRange = Internal.AbilityRange
local HasLineOfSight = Internal.HasLineOfSight
local CopySymbols = Internal.CopySymbols
local SharedLocKey = Internal.LocKey

local function SameLoc(a, b)
    if a == nil or b == nil then
        return false
    end

    local astr = TryGet(a, "str", nil)
    local bstr = TryGet(b, "str", nil)
    if astr ~= nil and bstr ~= nil then
        return astr == bstr
    end

    return SafeCall(function()
        return LocDistance(a, b) <= 0.01
    end, false)
end

local function ValidationReasonCode(reason, fallback)
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

function AI:MakeValidationResult(args)
    args = args or {}
    local ok = args.ok == true
    return {
        ok = ok,
        phase = args.phase,
        reasonCode = args.reasonCode or ValidationReasonCode(args.reason, Pick(ok, "ok", "validation_failed")),
        reason = args.reason,
        details = args.details,
    }
end

function AI:ValidationResultFromTuple(ok, reason, details, args)
    args = args or {}
    return self:MakeValidationResult{
        ok = ok == true,
        phase = args.phase,
        reasonCode = args.reasonCode,
        reason = reason or args.reason,
        details = details or args.details,
    }
end

function AI:ValidationResultToTuple(result)
    if type(result) ~= "table" then
        return result == true, nil, nil
    end

    return result.ok == true, result.reason, result.details
end

local function ValidationResultFromLegality(ai, legality, reason)
    if type(legality) ~= "table" then
        return nil
    end

    return ai:MakeValidationResult{
        ok = legality.ok == true,
        phase = legality.phase or "movement.stale",
        reasonCode = legality.reasonCode,
        reason = reason or legality.reason,
        details = {
            legality = legality,
            kind = legality.kind,
            friendly = legality.friendly,
            target = legality.target,
            area = legality.area,
            friendlyCollateral = legality.friendlyCollateral,
        },
    }
end

local function ValidationResultFromPromptCapability(ai, capability, phase, reason)
    if type(capability) ~= "table" then
        return nil
    end

    return ai:MakeValidationResult{
        ok = capability.status == "auto",
        phase = phase or "prompt.preflight",
        reasonCode = capability.reasonCode,
        reason = reason or capability.reason,
        details = {
            promptCapability = capability,
            promptStatus = capability.promptStatus,
            requiredPrompts = capability.requiredPrompts,
            optionalPrompts = capability.optionalPrompts,
            policies = capability.policies,
        },
    }
end

local function MakePhaseValidation(ai, phase, ok, reason, details, reasonCode)
    return ai:MakeValidationResult{
        ok = ok == true,
        phase = phase,
        reasonCode = reasonCode,
        reason = reason,
        details = details,
    }
end

local function AbilityCanAffordWithActionGrant(abilityToCheck, actor, symbols)
    if abilityToCheck == nil or actor == nil then
        return false
    end

    local clone = SafeCall(function()
        return abilityToCheck:MakeTemporaryClone()
    end, nil)
    if clone == nil then
        return false
    end

    clone.actionResourceId = "none"
    return AbilityCanAfford(clone, actor.token, symbols or {})
end

local function AddMoveLoc(locs, loc)
    if loc == nil then
        return
    end

    if #locs > 0 and SameLoc(locs[#locs], loc) then
        return
    end

    locs[#locs+1] = loc
end

local function CandidateMoveLocs(candidate)
    local result = {}
    if candidate ~= nil then
        local loc = AI.CandidateExecutionLoc ~= nil and AI:CandidateExecutionLoc(candidate) or candidate.loc
        AddMoveLoc(result, loc)
        local preInvokeDestination = AI.CandidatePreInvokeDestination ~= nil and AI:CandidatePreInvokeDestination(candidate) or nil
        AddMoveLoc(result, preInvokeDestination)
    end
    return result
end

local function AssignmentMoveLocs(assignment)
    local result = {}
    if assignment ~= nil then
        AddMoveLoc(result, assignment.loc)
        -- Squad assignments still carry their own charge destination until
        -- assignment movement semantics get a dedicated proposal shape.
        AddMoveLoc(result, assignment.chargeLoc)
    end
    return result
end

local function TargetableEntryFromSet(targetableSet, targetToken)
    if targetableSet == nil or targetToken == nil then
        return nil
    end

    local targetId = TokenId(targetToken)
    for _,entry in ipairs(targetableSet) do
        local tok = entry.token
        if tok == targetToken or (targetId ~= nil and TokenId(tok) == targetId) then
            return entry
        end
    end

    return nil
end

local function AddTokenLocationSnapshot(seen, snapshots, tok)
    if not IsTokenValid(tok) or tok.loc == nil then
        return
    end

    local key = TokenId(tok) or tostring(tok)
    if seen[key] then
        return
    end

    seen[key] = true
    snapshots[#snapshots+1] = {
        token = tok,
        loc = tok.loc,
    }
end

local function SnapshotInvokeTokenLocations(context, actor, candidate)
    local seen = {}
    local snapshots = {}

    AddTokenLocationSnapshot(seen, snapshots, actor and actor.token)
    AddTokenLocationSnapshot(seen, snapshots, candidate and candidate.actor and candidate.actor.token)

    for _,tok in ipairs((context and context.allCombatTokens) or {}) do
        AddTokenLocationSnapshot(seen, snapshots, tok)
    end

    local targets = AI.CandidateTargets and AI:CandidateTargets(candidate) or candidate and candidate.targets or {}
    for _,target in ipairs(targets) do
        AddTokenLocationSnapshot(seen, snapshots, target and target.token)
    end

    local squadAssignments = AI.CandidateSquadAssignments and AI:CandidateSquadAssignments(candidate) or candidate and candidate.squadAssignments or {}
    for _,assignment in ipairs(squadAssignments) do
        AddTokenLocationSnapshot(seen, snapshots, assignment and assignment.member and assignment.member.token)
        AddTokenLocationSnapshot(seen, snapshots, assignment and assignment.target)
    end

    return snapshots
end

local function RestoreInvokeTokenLocations(ai, snapshots, actor, reason)
    local restored = false
    for i=#(snapshots or {}),1,-1 do
        local entry = snapshots[i]
        local tok = entry and entry.token
        local loc = entry and entry.loc
        if IsTokenValid(tok) and loc ~= nil and not SameLoc(tok.loc, loc) then
            ai:Trace("movement", "rollback invoke side effect", {
                token = TokenName(tok),
                loc = TryGet(loc, "str", loc),
                reason = reason,
            })
            local moved = SafeCall(function()
                tok:Move(loc, { maxCost = 10000, ignoreFalling = true })
                return true
            end, false)
            if moved then
                restored = true
                if ai.SyncExecutionMovedTiles ~= nil then
                    ai:SyncExecutionMovedTiles(actor, tok)
                end
            end
        end
    end

    if restored and ai.SyncExecutionMovedTiles ~= nil and actor ~= nil then
        ai:SyncExecutionMovedTiles(actor, actor.token)
    end
end

local function CandidateExecutionActionType(ai, candidate)
    if candidate == nil then
        return nil
    end

    local movementOnly = candidate.movementOnly == true
    if ai.CandidateMovementOnly ~= nil then
        movementOnly = ai:CandidateMovementOnly(candidate)
    end
    if movementOnly then
        return { kind = "move" }
    end

    local execution = ai.CandidateExecution and ai:CandidateExecution(candidate) or {}
    if execution.actionType ~= nil or candidate.actionType ~= nil then
        local actionType = execution.actionType or candidate.actionType
        if actionType ~= nil
            and actionType.kind == "none"
            and ai ~= nil
            and ai.Ledger ~= nil
            and ai.Ledger.ActionTypeFromAbilityInfo ~= nil
        then
            local explicitCost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost
            local semantic = ai.Ledger:ActionTypeFromAbilityInfo(ai, candidate.abilityInfo, explicitCost)
            if semantic ~= nil and semantic.kind ~= "none" then
                return semantic
            end
        end
        return actionType
    end

    local resolved = nil
    if candidate.ability ~= nil and ai ~= nil and ai.ResolveActionType ~= nil then
        resolved = SafeCall(function()
            return ai:ResolveActionType(candidate.ability)
        end, nil)
    end

    if (resolved == nil or resolved.kind == "none")
        and ai ~= nil
        and ai.Ledger ~= nil
        and ai.Ledger.ActionTypeFromAbilityInfo ~= nil
    then
        local explicitCost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost
        return ai.Ledger:ActionTypeFromAbilityInfo(ai, candidate.abilityInfo, explicitCost)
    end

    return resolved
end

local function CandidateMovementMode(candidate, fallback)
    local execution = AI.CandidateExecution and AI:CandidateExecution(candidate) or {}
    local actionType = execution.actionType or candidate and candidate.actionType
    local moveSubKind = TryGet(actionType, "moveSubKind", nil)
    if moveSubKind ~= nil then
        return moveSubKind
    end

    local advanceTargetLoc = AI.CandidateAdvanceTargetLoc and AI:CandidateAdvanceTargetLoc(candidate) or execution.advanceTargetLoc or candidate and candidate.advanceTargetLoc
    if candidate ~= nil and (execution.isAdvance or candidate.isAdvance or advanceTargetLoc ~= nil) then
        return "advance"
    end

    return fallback or "walk"
end

local function SuppressResolvedModePrompt(ability)
    if ability == nil then
        return false
    end

    return SafeCall(function()
        ability._directorResolvedModePrompt = true
        ability.RequiresPromptWhenCast = function()
            return false
        end
        return ability:RequiresPromptWhenCast() == false
    end, false)
end

local function CopyOptional(value)
    if value == nil then
        return nil
    end

    return SafeCall(function()
        return DeepCopy(value)
    end, value)
end

local function CastTryGet(cast, key)
    if cast == nil then
        return nil
    end

    return SafeCall(function()
        return cast:try_get(key, nil)
    end, TryGet(cast, key, nil))
end

local function IsSpecificTargetFreeStrikeAbility(ability)
    local name = Lower(TryGet(ability, "name", "") or "")
    return string.find(name, "free strike", 1, true) ~= nil
        and (string.find(name, "specific target", 1, true) ~= nil
            or string.find(name, "vs target", 1, true) ~= nil)
end

local function IsGrabSpecificTargetFreeStrikePrompt(ability, symbols, options)
    if not IsSpecificTargetFreeStrikeAbility(ability) then
        return false
    end

    local spellName = TryGet(symbols, "spellname", nil)
    if spellName == nil and options ~= nil then
        spellName = TryGet(options.symbols, "spellname", nil)
    end

    return Lower(spellName or "") == "grab"
end

local function OptionsUseDirectorParentCast(options, symbols, parentCast)
    if parentCast == nil then
        return false
    end

    -- Nested invokes often receive a fresh options table but keep the parent cast object.
    if options ~= nil and options.symbols ~= nil and options.symbols.cast == parentCast then
        return true
    end

    return symbols ~= nil and symbols.cast == parentCast
end

local function SnapshotDirectorParentInvokeState(options, parentCast)
    if options == nil and parentCast == nil then
        return nil
    end

    local snapshot = {}

    if options ~= nil then
        snapshot.options = true
        snapshot.executedFinish = options.executedFinish
        snapshot.alreadyPaid = options.alreadyPaid
        snapshot.pay = options.pay
        snapshot.payIfNotAborted = options.payIfNotAborted
        snapshot.firedUseAbility = options.firedUseAbility
        snapshot.abort = options.abort
        snapshot.stopProcessing = options.stopProcessing
        snapshot.directorPromptStatus = options._directorPromptStatus
        snapshot.powerRollPass = options.powerRollPass
        snapshot.surges = options.surges
        snapshot.targets = options.targets
        snapshot.targetArgs = options.targetArgs
        snapshot.targetArea = options.targetArea
        snapshot.targetingFormula = options.targetingFormula

        if type(options.OnFinishCastHandlers) == "table" then
            snapshot.finishHandlerCount = #options.OnFinishCastHandlers
        else
            snapshot.finishHandlersAbsent = true
        end
    end

    local cast = parentCast or (options ~= nil and options.symbols ~= nil and options.symbols.cast)
    if cast ~= nil then
        snapshot.cast = cast
        snapshot.castFields = {
            tier = cast.tier,
            total = cast.total,
            naturalRoll = cast.naturalRoll,
            lowRoll = cast.lowRoll,
            highRoll = cast.highRoll,
            boonsApplied = cast.boonsApplied,
            banesApplied = cast.banesApplied,
            casterid = cast.casterid,
            targets = cast.targets,
            tokenToTier = CopyOptional(CastTryGet(cast, "tokenToTier")),
            potencyApplied = CopyOptional(CastTryGet(cast, "potencyApplied")),
        }
    end

    return snapshot
end

local function RestoreDirectorParentInvokeState(options, snapshot, restoreFlowFields)
    if snapshot == nil then
        return
    end

    if options ~= nil and snapshot.options then
        options.executedFinish = snapshot.executedFinish
        options.alreadyPaid = snapshot.alreadyPaid
        options.pay = snapshot.pay
        options.payIfNotAborted = snapshot.payIfNotAborted
        options.firedUseAbility = snapshot.firedUseAbility
        options.targets = snapshot.targets
        options.targetArgs = snapshot.targetArgs
        options.targetArea = snapshot.targetArea
        options.targetingFormula = snapshot.targetingFormula

        if restoreFlowFields then
            options.abort = snapshot.abort
            options.stopProcessing = snapshot.stopProcessing
            options._directorPromptStatus = snapshot.directorPromptStatus
            options.powerRollPass = snapshot.powerRollPass
            options.surges = snapshot.surges
        end

        if snapshot.finishHandlersAbsent then
            options.OnFinishCastHandlers = nil
        elseif snapshot.finishHandlerCount ~= nil and type(options.OnFinishCastHandlers) == "table" then
            while #options.OnFinishCastHandlers > snapshot.finishHandlerCount do
                table.remove(options.OnFinishCastHandlers)
            end
        end
    end

    local cast = snapshot.cast
    local fields = snapshot.castFields
    if cast ~= nil and fields ~= nil then
        cast.tier = fields.tier
        cast.total = fields.total
        cast.naturalRoll = fields.naturalRoll
        cast.lowRoll = fields.lowRoll
        cast.highRoll = fields.highRoll
        cast.boonsApplied = fields.boonsApplied
        cast.banesApplied = fields.banesApplied
        cast.casterid = fields.casterid
        cast.targets = fields.targets
        cast.tokenToTier = fields.tokenToTier
        cast.potencyApplied = fields.potencyApplied
    end
end

local function SnapshotOptionalNestedPromptMarker(options)
    if options == nil then
        return nil
    end

    return {
        class = TryGet(options, "_directorNestedPromptClass", nil),
        marker = TryGet(options, "_directorOptionalNestedPrompt", nil),
        reason = TryGet(options, "_directorOptionalNestedReason", nil),
    }
end

local function OptionalNestedPromptWasHandledOrSkipped(options, before)
    if options == nil then
        return false
    end

    if TryGet(options, "_directorNestedPromptClass", nil) ~= "optional-child" then
        return false
    end

    local marker = TryGet(options, "_directorOptionalNestedPrompt", nil)
    local beforeMarker = before and before.marker or nil
    return marker ~= nil and marker ~= beforeMarker
end

local function RestoreOptionalNestedPromptMarker(options, before)
    if options == nil then
        return
    end

    options._directorNestedPromptClass = before and before.class or nil
    options._directorOptionalNestedPrompt = before and before.marker or nil
    options._directorOptionalNestedReason = before and before.reason or nil
end

local function ParentTargetTier(parentCast, options)
    local target = nil
    if options ~= nil and type(options.targets) == "table" and options.targets[1] ~= nil then
        target = options.targets[1].token
    end

    if target == nil and parentCast ~= nil and type(CastTryGet(parentCast, "targets")) == "table" then
        local targets = CastTryGet(parentCast, "targets")
        if targets[1] ~= nil then
            target = targets[1].token
        end
    end

    local targetId = TokenId(target)
    local tokenToTier = CastTryGet(parentCast, "tokenToTier")
    if targetId ~= nil and type(tokenToTier) == "table" then
        return tokenToTier[targetId], targetId
    end

    return nil, targetId
end

local function LogGrabParentStateAfterNestedFreeStrike(abilityClone, symbols, options, parentCast)
    if not IsGrabSpecificTargetFreeStrikePrompt(abilityClone, symbols, options) then
        return
    end

    local tierForTarget, targetId = ParentTargetTier(parentCast, options)
    SafeCall(function()
        AI:Log(string.format(
            "Grab parent state after nested free strike: tier=%s targetTier=%s target=%s abort=%s stopProcessing=%s",
            tostring(parentCast and parentCast.tier or nil),
            tostring(tierForTarget),
            tostring(targetId or "?"),
            tostring(options and options.abort or nil),
            tostring(options and options.stopProcessing or nil)
        ))
    end, nil)
end

local function InstallParentInvokeStateProtection(invoker, parentCast)
    if invoker == nil or type(invoker.ExecuteInvoke) ~= "function" then
        return function()
        end
    end

    local originalExecuteInvoke = invoker.ExecuteInvoke
    local depth = 0
    local wrappedExecuteInvoke
    wrappedExecuteInvoke = function(invokerToken, abilityClone, casterToken, targeting, symbols, options)
        local protect = depth > 0 and OptionsUseDirectorParentCast(options, symbols, parentCast)
        local snapshot = protect and SnapshotDirectorParentInvokeState(options, parentCast) or nil
        local optionalNestedBefore = protect and SnapshotOptionalNestedPromptMarker(options) or nil
        depth = depth + 1
        local result = originalExecuteInvoke(invokerToken, abilityClone, casterToken, targeting, symbols, options)
        depth = depth - 1
        if protect then
            local restoreFlowFields = OptionalNestedPromptWasHandledOrSkipped(options, optionalNestedBefore)
            RestoreDirectorParentInvokeState(options, snapshot, restoreFlowFields)
            RestoreOptionalNestedPromptMarker(options, optionalNestedBefore)
            if restoreFlowFields then
                LogGrabParentStateAfterNestedFreeStrike(abilityClone, symbols, options, parentCast)
            end
        end
        return result
    end
    invoker.ExecuteInvoke = wrappedExecuteInvoke

    return function()
        if invoker.ExecuteInvoke == wrappedExecuteInvoke then
            invoker.ExecuteInvoke = originalExecuteInvoke
        end
    end
end

local function ExecutionLocKey(loc)
    return SharedLocKey(loc, nil)
end

local function TraceShortText(value, limit)
    if value == nil then
        return nil
    end

    local text = tostring(value)
    limit = tonumber(limit) or 240
    if string.len(text) <= limit then
        return text
    end

    return string.sub(text, 1, math.max(1, limit - 3)) .. "..."
end

local function TracePromptTargetSummary(options)
    if type(options) ~= "table" then
        return nil
    end

    local parts = {}
    local targets = TryGet(options, "targetArgs", nil) or TryGet(options, "targets", nil)
    if type(targets) == "table" then
        for _,target in ipairs(targets) do
            if #parts >= 3 then
                break
            end

            local token = TryGet(target, "token", nil)
            if token == nil and TryGet(target, "charid", nil) ~= nil then
                token = target
            end

            local loc = TryGet(target, "loc", nil)
            if token ~= nil then
                parts[#parts+1] = string.format("%s@%s", TokenName(token), ExecutionLocKey(loc or TryGet(token, "loc", nil)))
            elseif loc ~= nil then
                parts[#parts+1] = ExecutionLocKey(loc)
            elseif type(target) == "table" and TryGet(target, "str", nil) ~= nil then
                parts[#parts+1] = ExecutionLocKey(target)
            end
        end
    end

    local targetArea = TryGet(options, "targetArea", nil)
    if targetArea ~= nil and #parts < 3 then
        parts[#parts+1] = "area@" .. ExecutionLocKey(TryGet(targetArea, "origin", nil))
    end

    if #parts == 0 then
        return nil
    end

    return table.concat(parts, ",")
end

local function SplitRetryKey(key)
    local parts = {}
    local text = tostring(key or "")
    local startIndex = 1

    while true do
        local separator = string.find(text, "|", startIndex, true)
        if separator == nil then
            parts[#parts+1] = string.sub(text, startIndex)
            break
        end

        parts[#parts+1] = string.sub(text, startIndex, separator - 1)
        startIndex = separator + 1
    end

    return parts
end

local function RetryKeyMismatchSummary(storedKey, currentKey)
    local storedParts = SplitRetryKey(storedKey)
    local currentParts = SplitRetryKey(currentKey)
    local count = math.max(#storedParts, #currentParts)
    for i=1,count do
        if storedParts[i] ~= currentParts[i] then
            return string.format(
                "part %d stored=%s current=%s",
                i,
                TraceShortText(storedParts[i], 80),
                TraceShortText(currentParts[i], 80)
            )
        end
    end

    return "keys differ"
end

local function PreparedPromptTraceFields(candidate, ability)
    local fields = {
        candidate = candidate and candidate.description,
        ability = ability and ability.name,
        targetType = TryGet(ability, "targetType", nil),
        multipleModes = TryGet(ability, "multipleModes", nil),
        selfTarget = TryGet(ability, "selfTarget", nil),
        prompt = TraceShortText(
            TryGet(ability, "promptText", nil)
                or TryGet(ability, "prompt", nil)
                or TryGet(ability, "targetPrompt", nil)
                or TryGet(ability, "promptOverride", nil),
            160
        ),
    }

    fields.reason = Pick(TryGet(ability, "multipleModes", false), "multiple modes", "RequiresPromptWhenCast")

    local behaviorSummaries = {}
    for _,behavior in ipairs(TryGet(ability, "behaviors", {}) or {}) do
        local typeName = TryGet(behavior, "typeName", "")
        local targeting = Lower(TryGet(behavior, "targeting", "") or "")
        local promptWhenResolving = TryGet(behavior, "promptWhenResolving", false)
        local promptWhenCast = TryGet(behavior, "promptWhenCast", false)
        if targeting == "prompt" or targeting == "prompt_inherit" or promptWhenResolving == true or promptWhenCast == true then
            behaviorSummaries[#behaviorSummaries+1] = string.format("%s targeting=%s promptWhenResolving=%s", tostring(typeName), tostring(targeting), tostring(promptWhenResolving))
        end
    end

    if #behaviorSummaries > 0 then
        fields.promptBehaviors = TraceShortText(table.concat(behaviorSummaries, ";"), 240)
    end

    return fields
end

function AI:CreatePromptCallback(context, actor)
    return function(invokerToken, casterToken, abilityClone, symbols, options)
        symbols = symbols or {}
        options = options or {}
        local abilityName = tostring(abilityClone and abilityClone.name or "prompt")
        local promptClass, promptClassReason = self:ClassifyNestedPrompt(context, actor, invokerToken, casterToken, abilityClone, symbols, options)
        self:Trace("prompt", "callback", {
            ability = abilityName,
            promptClass = promptClass,
            reason = promptClassReason,
            actor = actor and TokenName(actor.token),
            invoker = invokerToken and TokenName(invokerToken),
            caster = casterToken and TokenName(casterToken),
        })
        if not self:EmitPhase(self.Phase.PromptRequested, {
            source = "abilityPrompt",
            context = context,
            actor = actor,
            invokerToken = invokerToken,
            casterToken = casterToken,
            ability = abilityClone,
            abilityName = abilityName,
            symbols = symbols,
            options = options,
            runGeneration = context and context.runGeneration,
        }) then
            if context ~= nil then
                context.promptResolutionExit = {
                    status = "abort",
                    ability = abilityName,
                    reason = "automation canceled before prompt resolution",
                }
            end
            options.abort = true
            options.stopProcessing = true
            options.targetArgs = {}
            options.targets = {}
            self:Log("Prompt aborted because automation was canceled: " .. abilityName)
            return "args"
        end

        local resolution = self:ResolvePromptV2(context, actor, invokerToken, casterToken, abilityClone, symbols, options)
        self:Trace("prompt", "callback resolution", {
            ability = abilityName,
            status = resolution and resolution.status,
            reason = resolution and resolution.reason,
            policy = resolution and resolution.policy and resolution.policy.id,
            targets = resolution and TracePromptTargetSummary(resolution.options),
        })
        if resolution ~= nil and resolution.status == "handled" then
            local resolvedPromptClass = promptClass
            local resolvedPromptReason = promptClassReason
            if resolution.options ~= nil then
                resolvedPromptClass, resolvedPromptReason = self:ClassifyNestedPrompt(context, actor, invokerToken, casterToken, abilityClone, symbols, options, resolution.options)
            end
            self:Trace("prompt", "handled", {
                ability = abilityName,
                promptClass = resolvedPromptClass,
                reason = resolvedPromptReason,
                policy = resolution.policy and resolution.policy.id,
                targets = TracePromptTargetSummary(resolution.options),
            })
            for k,v in pairs(resolution.options or {}) do
                options[k] = v
            end
            options._directorPromptStatus = "handled"
            if resolvedPromptClass == "optional-child" then
                options._directorNestedPromptClass = "optional-child"
                options._directorOptionalNestedPrompt = TryGet(options, "_directorOptionalNestedPrompt", "handled") or "handled"
                options._directorOptionalNestedReason = TryGet(options, "_directorOptionalNestedReason", resolvedPromptReason) or resolvedPromptReason
                if options._directorOptionalNestedPrompt == "skipped" then
                    self:Log("Optional nested prompt skipped: " .. abilityName .. " (" .. tostring(TryGet(options, "_directorOptionalNestedReason", "no target")) .. ")")
                end
            end
            if self:IsDirectorMovementPromptAbility(abilityClone) then
                local target = resolution.options and resolution.options.targets and resolution.options.targets[1]
                local loc = target and target.loc
                local range = tonumber(options._directorPromptMovementRange)
                local reason = tostring(options._directorPromptMovementReason or "policy")
                if loc ~= nil and casterToken ~= nil and casterToken.loc ~= nil and SameLoc(casterToken.loc, loc) then
                    self:Log(string.format("Ability move no-op: %s stayed at %s (%s, range %s)", abilityName, tostring(TryGet(loc, "str", loc)), reason, tostring(range or "?")))
                elseif loc ~= nil then
                    self:Log(string.format("Ability move planned: %s -> %s (%s, range %s)", abilityName, tostring(TryGet(loc, "str", loc)), reason, tostring(range or "?")))
                end
            end
            self:Log("Prompt handled: " .. abilityName .. " via " .. tostring(resolution.policy and resolution.policy.id or "policy"))
            local resolvedTargets = resolution.options and (resolution.options.targetArgs or resolution.options.targets)
            if resolvedTargets ~= nil then
                options.targets = resolvedTargets
                options.targetArgs = resolvedTargets
                return "args"
            end
            return "inherit"
        end

        local status = resolution and resolution.status or "blocked"
        local reason = resolution and resolution.reason or "no automated prompt policy"
        self:Trace("prompt", "unresolved", {
            ability = abilityName,
            promptClass = promptClass,
            status = status,
            reason = reason,
        })
        if context ~= nil then
            context.promptResolutionExit = {
                status = status,
                ability = abilityName,
                reason = reason,
            }
        end

        if promptClass == "optional-child" then
            if context ~= nil then
                context.promptResolutionExit = nil
            end
            options._directorPromptStatus = "optional-skipped"
            options._directorNestedPromptClass = "optional-child"
            options._directorOptionalNestedPrompt = "skipped"
            options._directorOptionalNestedReason = reason or promptClassReason
            options.targetArgs = {}
            options.targets = {}
            self:Log("Optional nested prompt skipped: " .. abilityName .. " (" .. tostring(reason) .. ")")
            return "args"
        end

        options.abort = true
        options.stopProcessing = true
        options._directorPromptStatus = status
        options.targetArgs = {}
        options.targets = {}
        self:Log("Prompt " .. tostring(status) .. " during automation: " .. abilityName .. " (" .. tostring(reason) .. ")")
        return "args"
    end
end

local function RestorePromptControlEntry(tok, entry)
    if TryGet(tok.properties, "_tmp_aipromptCallback", nil) == entry.callback then
        tok.properties._tmp_aicontrol = entry.previousControl or 0
        tok.properties._tmp_aipromptCallback = entry.previousCallback
    else
        tok.properties._tmp_aicontrol = math.max(0, (TryGet(tok.properties, "_tmp_aicontrol", 1) or 1) - 1)
    end
end

local function RestorePromptControlForToken(tok, owner, clearAll)
    if tok == nil or not tok.valid or tok.properties == nil then
        return
    end

    local stack = TryGet(tok.properties, "_tmp_directorTacticsPromptControlStack", nil)
    if type(stack) ~= "table" then
        return
    end

    while #stack > 0 and stack[#stack].owner == owner do
        local entry = stack[#stack]
        stack[#stack] = nil
        RestorePromptControlEntry(tok, entry)
        if not clearAll then
            break
        end
    end

    if clearAll then
        for i=#stack,1,-1 do
            if stack[i].owner == owner then
                table.remove(stack, i)
            end
        end
    end

    if #stack == 0 then
        tok.properties._tmp_directorTacticsPromptControlStack = nil
    end
end

function AI:InstallPromptControl(context, actor)
    local promptCallback = self:CreatePromptCallback(context, actor)
    local tokens = {}
    local owner = Runtime.promptControlOwner

    if actor.kind == "squad" then
        for _,member in ipairs(actor.squadMembers or {}) do
            if IsTokenValid(member.token) then
                tokens[#tokens+1] = member.token
            end
        end
    else
        tokens[#tokens+1] = actor.token
    end

    self:Trace("prompt", "control install", { actor = actor and TokenName(actor.token), tokens = #tokens, owner = owner })
    for _,tok in ipairs(tokens) do
        local stack = TryGet(tok.properties, "_tmp_directorTacticsPromptControlStack", nil)
        if type(stack) ~= "table" then
            stack = {}
            tok.properties._tmp_directorTacticsPromptControlStack = stack
        end

        stack[#stack+1] = {
            owner = owner,
            callback = promptCallback,
            previousControl = TryGet(tok.properties, "_tmp_aicontrol", 0) or 0,
            previousCallback = TryGet(tok.properties, "_tmp_aipromptCallback", nil),
        }

        tok.properties._tmp_aicontrol = (TryGet(tok.properties, "_tmp_aicontrol", 0) or 0) + 1
        tok.properties._tmp_aipromptCallback = promptCallback
    end

    return function()
        self:Trace("prompt", "control cleanup", { actor = actor and TokenName(actor.token), tokens = #tokens, owner = owner })
        for _,tok in ipairs(tokens) do
            RestorePromptControlForToken(tok, owner, false)
        end
    end
end

function AI:ClearPromptControls()
    local owner = Runtime.promptControlOwner
    self:Trace("prompt", "control clear all", { owner = owner })
    for _,tok in ipairs(dmhub.allTokens or {}) do
        if tok ~= nil and tok.valid and tok.properties ~= nil then
            SafeCall(function()
                RestorePromptControlForToken(tok, owner, true)
            end, nil)
        end
    end
end

function AI:CleanupPromptTargeting(context, actor, candidate, reason, skipActionBarCancel)
    self:Trace("prompt", "targeting cleanup", {
        actor = actor and TokenName(actor.token),
        candidate = candidate and candidate.description,
        reason = reason,
        skipActionBarCancel = skipActionBarCancel,
    })
    self:ClearPromptControls()

    if not skipActionBarCancel then
        SafeCall(function()
            if gamehud ~= nil and gamehud.actionBarPanel ~= nil and gamehud.actionBarPanel.valid then
                gamehud.actionBarPanel:FireEventTree("cancel")
            end
        end, nil)
    end

    SafeCall(function()
        if gui ~= nil and gui.SetFocus ~= nil then
            gui.SetFocus(nil)
        end
    end, nil)

    local tokens = {}
    local count = 0
    local function AddToken(tok)
        if not IsTokenValid(tok) then
            return
        end

        local key = TokenId(tok) or tostring(tok)
        if tokens[key] == nil then
            tokens[key] = tok
            count = count + 1
        end
    end

    AddToken(actor and actor.token)
    AddToken(candidate and candidate.actor and candidate.actor.token)
    local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate and candidate.squadAssignments or {}
    for _,assignment in ipairs(squadAssignments) do
        AddToken(assignment.member and assignment.member.token)
    end
    local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate and candidate.targets or {}
    for _,target in ipairs(targets) do
        AddToken(target.token)
    end

    if count == 0 then
        for _,tok in ipairs(dmhub.allTokens or {}) do
            AddToken(tok)
        end
    end

    for _,tok in pairs(tokens) do
        SafeCall(function()
            tok:ClearMovementArrow()
        end, nil)
    end
end

local function ManualPromptActiveCastCount()
    local activatedAbility = RawGlobal("ActivatedAbility")
    return SafeCall(function()
        if activatedAbility == nil or activatedAbility.CountActiveCasts == nil then
            return 0
        end

        return activatedAbility.CountActiveCasts()
    end, 0) or 0
end

local function ManualPromptRollShown()
    return SafeCall(function()
        return gamehud.rollDialog.valid and gamehud.rollDialog.data.IsShown()
    end, false) == true
end

local function ManualPromptActionPreparing()
    return SafeCall(function()
        return gamehud.actionBarPanel.valid and gamehud.actionBarPanel.data.IsCastingSpell()
    end, false) == true
end

function AI:ReleaseManualPromptUi(reason)
    self:Trace("prompt", "manual prompt ui release requested", { reason = reason })
    self:ClearPromptControls()

    SafeCall(function()
        if gui ~= nil and gui.SetFocus ~= nil then
            gui.SetFocus(nil)
        end
    end, nil)

    if Runtime.manualPromptUiReleaseInProgress == true then
        return
    end

    Runtime.manualPromptUiReleaseInProgress = true
    dmhub.Coroutine(function()
        coroutine.yield(0.1)

        local activeCasts = ManualPromptActiveCastCount()
        local rollShown = ManualPromptRollShown()
        if activeCasts <= 0 and not rollShown then
            SafeCall(function()
                if gamehud ~= nil and gamehud.actionBarPanel ~= nil and gamehud.actionBarPanel.valid then
                    gamehud.actionBarPanel:FireEventTree("cancel")
                end
            end, nil)
        end

        coroutine.yield(0.1)
        activeCasts = ManualPromptActiveCastCount()
        rollShown = ManualPromptRollShown()
        local actionPreparing = ManualPromptActionPreparing()
        if activeCasts <= 0 and not rollShown then
            SafeCall(function()
                dmhub.blockTokenSelection = false
            end, nil)
        end

        Runtime.manualPromptUiReleaseInProgress = nil
        self:Trace("prompt", "manual prompt ui release complete", {
            reason = reason,
            activeCasts = activeCasts,
            rollShown = rollShown,
            actionPreparing = actionPreparing,
            blockTokenSelection = SafeCall(function() return dmhub.blockTokenSelection end, nil),
        })
    end)
end

function AI:OpenManualPromptCandidate(context, candidate)
    if candidate == nil or candidate.actor == nil or candidate.actor.token == nil or candidate.ability == nil then
        return false
    end

    local actor = candidate.actor
    local execution = self.CandidateExecution and self:CandidateExecution(candidate) or {}
    local symbols = CopySymbols(execution.symbols or candidate.symbols or {})
    symbols.mode = symbols.mode or 1
    if candidate.abilityInfo ~= nil and candidate.abilityInfo.isMalice and symbols.charges == nil then
        symbols.charges = self:MaliceCost(candidate.abilityInfo)
    end

    local ability = SafeCall(function()
        return candidate.ability:MakeTemporaryClone()
    end, candidate.ability)
    if ability == nil then
        return false
    end

    ability.countsAsCast = true
    ability.skippable = true
    ability.castImmediately = false

    self:ClearPromptControls()

    local invokerInfo = {
        oncast = function()
            self:Log("Manual prompt cast started: " .. tostring(candidate.description or ability.name))
        end,
        oncancel = function()
            self:Log("Manual prompt canceled: " .. tostring(candidate.description or ability.name))
            if self.MarkManualPromptHandoffCanceled ~= nil then
                self:MarkManualPromptHandoffCanceled(context, actor, candidate)
            end
            self:CleanupPromptTargeting(context, actor, candidate, "manual prompt canceled", true)
            self:ReleaseManualPromptUi("manual prompt canceled")
        end,
    }

    return SafeCall(function()
        if gamehud == nil or gamehud.actionBarPanel == nil or not gamehud.actionBarPanel.valid then
            return false
        end

        gamehud.actionBarPanel:FireEventTree("invokeAbility", actor.token, ability, symbols, invokerInfo, {
            instantCast = false,
        })
        return true
    end, false) == true
end

function AI:RecordActualMovement(token, fromLoc, toLoc)
    if token == nil or fromLoc == nil or toLoc == nil or SameLoc(fromLoc, toLoc) then
        return
    end

    Runtime.movementMemory = Runtime.movementMemory or {}
    local key = TokenId(token) or tostring(token)
    local entry = Runtime.movementMemory[key] or {}
    local recent = {}
    recent[#recent+1] = ExecutionLocKey(fromLoc)
    if type(entry.recent) == "table" then
        for _,locKey in ipairs(entry.recent) do
            if locKey ~= nil and locKey ~= recent[1] and #recent < 3 then
                recent[#recent+1] = locKey
            end
        end
    end
    entry.recent = recent
    entry.last = ExecutionLocKey(toLoc)
    Runtime.movementMemory[key] = entry
end

function AI:MoveToken(token, loc, context, reason)
    if loc == nil or not self.config.movement then
        return true
    end

    if token.loc ~= nil and loc.str ~= nil and token.loc.str == loc.str then
        return true
    end

    if self.IsMovementDestinationClear ~= nil then
        if context ~= nil then
            context._tmp_blockingOccupancyKeys = nil
        end
        local clear, blocker = self:IsMovementDestinationClear(context, token, loc)
        if not clear then
            self:Log("Movement blocked: " .. TokenName(token) .. " destination overlaps " .. TokenName(blocker))
            return false
        end
    end

    local fromLoc = token.loc
    local beforeMoved = SafeCall(function()
        return token.properties:DistanceMovedThisTurn()
    end, nil)
    local speed = SafeCall(function()
        return token.properties:CurrentMovementSpeed()
    end, nil)

    local moved = SafeCall(function()
        token:Move(loc, { maxCost = 10000, ignoreFalling = false })
        return true
    end, false)
    if moved then
        self:RecordActualMovement(token, fromLoc, loc)
        local afterMoved = SafeCall(function()
            return token.properties:DistanceMovedThisTurn()
        end, beforeMoved)
        local spent = nil
        if beforeMoved ~= nil and afterMoved ~= nil then
            spent = afterMoved - beforeMoved
        end
        local remaining = nil
        if speed ~= nil and afterMoved ~= nil then
            remaining = math.max(0, speed - afterMoved)
        end
        self:Log(string.format("Actual %s move: %s %s -> %s (spent %s, remaining %s)",
            tostring(reason or "planned"),
            TokenName(token),
            tostring(TryGet(fromLoc, "str", fromLoc)),
            tostring(TryGet(loc, "str", loc)),
            tostring(spent or "?"),
            tostring(remaining or "?")))
        AI.Sleep(0.35)
    end
    return moved == true
end

function AI:RecordCandidateExecution(context, candidate)
    if context == nil or candidate == nil then
        return
    end

    local state = context.encounterState or self.encounterState
    if state == nil then
        return
    end

    local actor = candidate.actor
    local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets) do
        local tok = target.token
        if tok ~= nil and actor ~= nil and not TokensFriendly(actor.token, tok) then
            local id = TokenId(tok)
            if id ~= nil then
                state.targetPressure[id] = (state.targetPressure[id] or 0) + 1
                if tok.playerControlled then
                    state.damageSpread[id] = (state.damageSpread[id] or 0) + 1
                end
            end
        end
    end

    self.Ledger:RecordCandidateResourceUse(self, context, candidate)
end

function AI:GlobalResourceSnapshot(candidate)
    return self.Ledger:GlobalResourceSnapshot(self, candidate)
end

function AI:RefreshContextResources(context)
    return self.Ledger:RefreshContextResources(self, context)
end

function AI:ReconcileGlobalResourceSpend(candidate, snapshot)
    return self.Ledger:ReconcileGlobalResourceSpend(self, candidate, snapshot)
end

function AI:GetActiveCastSnapshot()
    return SafeCall(function()
        local activatedAbility = RawGlobal("ActivatedAbility")
        if activatedAbility == nil or activatedAbility.GetActiveCastSnapshot == nil then
            return nil
        end

        return activatedAbility.GetActiveCastSnapshot()
    end, nil)
end

function AI:WaitForCastSettle(timeout, stableTicks, snapshot, label)
    local started = dmhub.Time()
    local quietTicks = 0
    local sawBusy = false
    local lastBusy = "none"
    stableTicks = stableTicks or 3

    while dmhub.Time() - started < (timeout or 3) do
        local activatedAbility = RawGlobal("ActivatedAbility")
        local activeCasts = SafeCall(function()
            if activatedAbility == nil or activatedAbility.CountActiveCasts == nil then
                return 0
            end

            return activatedAbility.CountActiveCasts()
        end, 0) or 0

        local newCoroutines = SafeCall(function()
            if snapshot == nil or activatedAbility == nil or activatedAbility.HasCoroutinesNotInSnapshot == nil then
                return false
            end

            return activatedAbility.HasCoroutinesNotInSnapshot(snapshot)
        end, false)

        local rollShown = SafeCall(function()
            return gamehud.rollDialog.valid and gamehud.rollDialog.data.IsShown()
        end, false)

        local actionPreparing = SafeCall(function()
            return gamehud.actionBarPanel.valid and gamehud.actionBarPanel.data.IsCastingSpell()
        end, false)

        local activeBusy = activeCasts > 0
        if snapshot ~= nil then
            activeBusy = false
        end

        if not activeBusy and not newCoroutines and not rollShown and not actionPreparing then
            quietTicks = quietTicks + 1
            if quietTicks >= stableTicks then
                if sawBusy then
                    self:Log(string.format("Cast settled%s after %0.1fs.", label and (" for " .. label) or "", dmhub.Time() - started))
                end
                return true
            end
        else
            sawBusy = true
            lastBusy = string.format("active=%s new=%s roll=%s action=%s", Pick(snapshot ~= nil, "ignored", tostring(activeCasts)), tostring(newCoroutines), tostring(rollShown), tostring(actionPreparing))
            quietTicks = 0
        end

        coroutine.yield(0.1)
    end

    self:Log(string.format("Cast settle timed out%s after %0.1fs (%s).", label and (" for " .. label) or "", dmhub.Time() - started, lastBusy))
    return false
end

function AI:CandidateSettleTimeout(candidate)
    local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate and candidate.squadAssignments or {}
    if #squadAssignments > 0 then
        return math.max(4, 1.5 + #squadAssignments)
    end

    return 2.5
end

function AI:ExecutionActorForCaster(actor, casterToken)
    if actor == nil or casterToken == nil or casterToken == actor.token then
        return actor
    end

    return {
        token = casterToken,
        role = actor.role,
        organization = actor.organization,
        profile = actor.profile,
        allies = actor.allies or {},
        enemies = actor.enemies or {},
        context = actor.context,
    }
end

function AI:ValidateExecutionTokenTarget(context, actor, ability, abilityInfo, casterToken, targetToken, symbols, targetArea, options)
    options = options or {}
    local phase = options.phase or "movement.stale"
    local afterMovement = options.afterMovement ~= false

    if targetToken == nil then
        return true, nil
    end

    if not IsTokenValid(targetToken) then
        return false, Pick(afterMovement, "target was invalid after movement", "target invalid")
    end

    local targetType = Lower(TryGet(abilityInfo, "targetType", "target"))
    local promptActor = self:ExecutionActorForCaster(actor, casterToken)

    if targetArea ~= nil then
        local contains = SafeCall(function()
            return targetArea:ContainsToken(targetToken)
        end, false)
        if not contains then
            return false, Pick(afterMovement, "target left recomputed area after movement", "target outside planned area")
        end

        if self.CheckTargetLegality ~= nil then
            local legality = self:CheckTargetLegality(context, promptActor, ability, abilityInfo, casterToken, targetToken, symbols or {}, {
                areaTarget = true,
                targetArea = targetArea,
                phase = phase,
                source = "ValidateExecutionTokenTarget",
            })
            if legality.ok ~= true then
                return false, legality.reason or Pick(afterMovement, "target was illegal after movement", "target was illegal"), legality
            end
        elseif self.AreaTargetAffected ~= nil then
            local allowed, reason = self:AreaTargetAffected(context, promptActor, ability, abilityInfo, casterToken, targetToken, targetArea, symbols or {})
            if not allowed then
                return false, reason or Pick(afterMovement, "target was illegal after movement", "target was illegal")
            end
        end
        return true, nil
    end

    if targetType ~= "target" and not TryGet(ability, "selfTarget", false) then
        return true, nil
    end

    if casterToken == targetToken or TryGet(casterToken, "properties", nil) == TryGet(targetToken, "properties", false) then
        return true, nil
    end

    local range = AbilityRange(ability, casterToken, symbols or {})
    local distance = Distance(casterToken, targetToken)

    if self.TargetableSetFromEngine ~= nil then
        local targetableSet = self:TargetableSetFromEngine(ability, casterToken, casterToken.loc, {
            context = context,
            abilityInfo = abilityInfo,
            symbols = symbols or {},
            extraTargets = { { token = targetToken } },
        })
        if self.CheckTargetLegality ~= nil then
            local legality = self:CheckTargetLegality(context, promptActor, ability, abilityInfo, casterToken, targetToken, symbols or {}, {
                targetableSet = targetableSet,
                range = range,
                afterMovement = afterMovement,
                phase = phase,
                source = "ValidateExecutionTokenTarget",
            })
            if legality.ok ~= true then
                return false, legality.reason or Pick(afterMovement, "target was illegal after movement", "target was illegal"), legality
            end
            return true, nil, legality
        else
            local entry = TargetableEntryFromSet(targetableSet, targetToken)
            range = tonumber(targetableSet and targetableSet._range) or range
            if entry == nil or (entry.distance or 999) > range + 0.1 then
                return false, Pick(afterMovement,
                    string.format("target out of range after movement (%0.1f > %0.1f)", distance, range),
                    string.format("target out of range (%0.1f > %0.1f)", distance, range))
            end

            if entry.lineOfSight ~= true then
                return false, Pick(afterMovement, "target had no line of sight after movement", "target had no line of sight")
            end

            if entry.passedEngineFilter ~= true then
                return false, entry.rejectionReason or Pick(afterMovement, "target was illegal after movement", "target was illegal")
            end

            return true, nil
        end
    end

    if self.CheckTargetLegality ~= nil then
        local legality = self:CheckTargetLegality(context, promptActor, ability, abilityInfo, casterToken, targetToken, symbols or {}, {
            phase = phase,
            source = "ValidateExecutionTokenTarget",
        })
        if legality.ok ~= true then
            return false, legality.reason or Pick(afterMovement, "target was illegal after movement", "target was illegal"), legality
        end
    elseif self.DirectorTargetAllowed ~= nil then
        local allowed, reason = self:DirectorTargetAllowed(context, promptActor, ability, abilityInfo, casterToken, targetToken, symbols or {})
        if not allowed then
            return false, reason or Pick(afterMovement, "target was illegal after movement", "target was illegal")
        end
    elseif self.DirectorTargetCheapAllowed ~= nil then
        local cheapAllowed, cheapReason = self:DirectorTargetCheapAllowed(context, promptActor, ability, abilityInfo, casterToken, targetToken)
        if not cheapAllowed then
            return false, cheapReason or Pick(afterMovement, "target was illegal after movement", "target was illegal")
        end
    end

    if distance > range + 0.1 then
        return false, Pick(afterMovement,
            string.format("target out of range after movement (%0.1f > %0.1f)", distance, range),
            string.format("target out of range (%0.1f > %0.1f)", distance, range))
    end

    local hasLos = nil
    if self.CachedHasLineOfSight ~= nil then
        hasLos = self:CachedHasLineOfSight(context, casterToken, targetToken)
    else
        hasLos = HasLineOfSight(casterToken, targetToken)
    end
    if not hasLos then
        return false, Pick(afterMovement, "target had no line of sight after movement", "target had no line of sight")
    end

    return true, nil
end

function AI:RefreshExecutionTargetArea(context, candidate, actor, symbols, options)
    options = options or {}
    local phase = options.phase or "movement.stale"
    local afterMovement = options.afterMovement ~= false

    local areaAnchorLoc = self.CandidateAreaAnchorLoc and self:CandidateAreaAnchorLoc(candidate) or candidate and candidate.areaAnchorLoc
    if candidate == nil or areaAnchorLoc == nil or candidate.abilityInfo == nil or actor == nil or actor.token == nil then
        return true, nil
    end

    local shape = self:CalculateAreaShape(actor.token, candidate.abilityInfo, areaAnchorLoc)
    if shape == nil then
        return false, "area could not be recomputed after movement"
    end

    if self.CheckAreaLegality ~= nil then
        local legality = self:CheckAreaLegality(context, actor, candidate.ability, candidate.abilityInfo, actor.token, actor.token.loc, areaAnchorLoc, shape, symbols, {
            afterMovement = afterMovement,
            phase = phase,
            targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {},
        })
        if legality.ok ~= true then
            return false, legality.reason or Pick(afterMovement, "area placement illegal after movement", "area placement illegal"), legality
        end
    elseif self.ValidateAreaPlacement ~= nil then
        local ok, reason = self:ValidateAreaPlacement(context, actor, candidate.ability, candidate.abilityInfo, actor.token, actor.token.loc, areaAnchorLoc, shape, symbols, {
            afterMovement = afterMovement,
        })
        if not ok then
            return false, reason or Pick(afterMovement, "area placement illegal after movement", "area placement illegal")
        end
    end

    if self.WriteCandidateIntent ~= nil then
        self:WriteCandidateIntent(candidate, {
            targetArea = shape,
        })
    else
        candidate.targetArea = shape
        if self.SyncCandidateSections ~= nil then
            self:SyncCandidateSections(candidate)
        end
    end
    if symbols ~= nil then
        symbols.targetArea = shape
    end
    return true, nil
end

function AI:LogStaleAbort(context, candidate, reason)
    reason = tostring(reason or "candidate stale")
    local safeReason = string.gsub(reason, "\"", "'")
    local description = tostring(candidate and candidate.description or "unknown")
    description = string.gsub(description, "\"", "'")
    self:Log(string.format("LogStaleAbort reason=\"%s\" candidate=\"%s\"", safeReason, description))
    if context ~= nil then
        context.lastStaleAbort = {
            candidate = candidate,
            reason = reason,
        }
    end
    return "candidate invalid before invoke: " .. reason
end

function AI:SyncExecutionMovedTiles(actor, token)
    if actor == nil or token == nil or actor.token ~= token or token.properties == nil then
        return
    end

    actor.turnMemory = actor.turnMemory or self:NewTurnMemory()
    local moved = SafeCall(function()
        return token.properties:DistanceMovedThisTurn()
    end, nil)
    if moved ~= nil then
        actor.turnMemory.movedTiles = math.max(0, tonumber(moved) or 0)
    end
end

function AI:ValidateExecutionMoveDestination(context, candidate, token, ledger, mode, destination, label, originLoc)
    if destination == nil or token == nil then
        return true, nil
    end

    label = label or "movement destination"
    mode = mode or "walk"

    local function Check()
        if SameLoc(token.loc, destination) then
            return true, nil
        end

        if self.MovementOptionForDestination == nil then
            return false, "movement resolver unavailable"
        end

        local _, locInfo, reason = self:MovementOptionForDestination(token, ledger, mode, destination)
        if locInfo == nil then
            return false, string.format("%s no longer legal: %s", label, tostring(reason or "destination unreachable"))
        end

        if self.IsMovementDestinationClear ~= nil then
            if context ~= nil then
                context._tmp_blockingOccupancyKeys = nil
            end
            local clear, blocker = self:IsMovementDestinationClear(context, token, destination)
            if not clear then
                return false, string.format("%s occupied by %s", label, TokenName(blocker))
            end
        end

        return true, nil
    end

    if originLoc ~= nil and not SameLoc(token.loc, originLoc) then
        local ok = false
        local reason = nil
        local evaluated = false
        SafeCall(function()
            token:ExecuteWithTheoreticalLoc(originLoc, function()
                ok, reason = Check()
                evaluated = true
            end)
        end, nil)
        if evaluated then
            return ok, reason
        end
    end

    return Check()
end

function AI:ValidateCandidateMovementPlan(context, candidate)
    if candidate == nil or candidate.actor == nil then
        return false, "candidate was incomplete"
    end

    local actor = candidate.actor
    local preInvokeMove = self.CandidatePreInvokeMove and self:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
    if actor.kind == "squad" then
        local supportMoves = self.CandidateSquadSupportMoves and self:CandidateSquadSupportMoves(candidate) or candidate.squadSupportMoves or {}
        for _,move in ipairs(supportMoves) do
            if move.member ~= nil then
                local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, move.member.token, actor, "walk", move.loc, "squad support destination")
                if not valid then
                    return false, reason
                end
            end
        end
        local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
        for _,assignment in ipairs(squadAssignments) do
            if assignment.member ~= nil then
                local memberToken = assignment.member.token
                local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, memberToken, actor, "walk", assignment.loc, "squad assignment destination")
                if not valid then
                    return false, reason
                end
                valid, reason = self:ValidateExecutionMoveDestination(context, candidate, memberToken, actor, "charge", assignment.chargeLoc, "squad charge destination", assignment.loc)
                if not valid then
                    return false, reason
                end
            end
        end
        return true, nil
    end

    local token = actor.token
    local plannedOrigin = token and token.loc
    local loc = self.CandidateExecutionLoc and self:CandidateExecutionLoc(candidate) or candidate.loc
    if loc ~= nil and token ~= nil and not SameLoc(token.loc, loc) then
        local movementOnly = candidate.movementOnly == true
        if self.CandidateMovementOnly ~= nil then
            movementOnly = self:CandidateMovementOnly(candidate)
        end
        local mode = Pick(movementOnly, "walk", CandidateMovementMode(candidate, "walk"))
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, mode, loc, "candidate movement destination")
        if not valid then
            return false, reason
        end
        plannedOrigin = loc
    end

    if preInvokeMove ~= nil and preInvokeMove.destination ~= nil then
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, preInvokeMove.mode or "walk", preInvokeMove.destination, "pre-invoke destination", plannedOrigin)
        if not valid then
            return false, reason
        end
    end

    local advanceTargetLoc = self.CandidateAdvanceTargetLoc and self:CandidateAdvanceTargetLoc(candidate) or candidate.advanceTargetLoc
    if advanceTargetLoc ~= nil then
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, CandidateMovementMode(candidate, "advance"), advanceTargetLoc, "advance destination")
        if not valid then
            return false, reason
        end
    end

    return true, nil
end

local function LastMoveLoc(locs)
    for i=#(locs or {}),1,-1 do
        if locs[i] ~= nil then
            return locs[i]
        end
    end
    return nil
end

function AI:ValidateMovedDestinationState(context, candidate)
    if candidate == nil or candidate.actor == nil then
        return false, "candidate was incomplete"
    end

    local actor = candidate.actor
    local function CheckToken(tok, locs, label)
        if tok == nil then
            return true, nil
        end
        if not IsTokenValid(tok) then
            return false, tostring(label or "token") .. " was invalid after movement"
        end

        local destination = LastMoveLoc(locs)
        if destination ~= nil and not SameLoc(tok.loc, destination) then
            return false, tostring(label or "token") .. " did not reach planned destination"
        end

        if destination ~= nil and self.IsMovementDestinationClear ~= nil then
            if context ~= nil then
                context._tmp_blockingOccupancyKeys = nil
            end
            local clear, blocker = self:IsMovementDestinationClear(context, tok, destination)
            if not clear then
                return false, tostring(label or "movement destination") .. " occupied by " .. TokenName(blocker)
            end
        end

        return true, nil
    end

    local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
    local supportMoves = self.CandidateSquadSupportMoves and self:CandidateSquadSupportMoves(candidate) or candidate.squadSupportMoves or {}
    if #squadAssignments > 0 or #supportMoves > 0 then
        for _,move in ipairs(supportMoves) do
            if move.member ~= nil then
                local valid, reason = CheckToken(move.member.token, AssignmentMoveLocs(move), "squad support destination")
                if not valid then
                    return false, reason
                end
            end
        end
        for _,assignment in ipairs(squadAssignments) do
            if assignment.member ~= nil then
                local valid, reason = CheckToken(assignment.member.token, AssignmentMoveLocs(assignment), "squad assignment destination")
                if not valid then
                    return false, reason
                end
            end
        end
        return true, nil
    end

    return CheckToken(actor.token, CandidateMoveLocs(candidate), "candidate movement destination")
end

function AI:ValidateCandidateBeforeMovement(context, candidate)
    if candidate == nil or candidate.actor == nil then
        return false, "candidate was incomplete"
    end

    local actor = candidate.actor
    if self.ValidateCandidateContract ~= nil then
        local contractValid, contractReason, contractFields = self:ValidateCandidateContract(candidate, "pre-move")
        if not contractValid then
            contractFields = contractFields or {}
            contractFields.candidate = candidate.description
            if contractFields.storedRetryKey ~= nil then
                contractFields.storedRetryKey = TraceShortText(contractFields.storedRetryKey, 320)
            end
            if contractFields.normalizedRetryKey ~= nil then
                contractFields.normalizedRetryKey = TraceShortText(contractFields.normalizedRetryKey, 320)
            end
            if contractFields.currentRetryKey ~= nil then
                contractFields.currentRetryKey = TraceShortText(contractFields.currentRetryKey, 320)
            end
            self:Trace("execute", "candidate contract mismatch", contractFields)
            return false, "candidate contract mismatch: " .. tostring(contractReason or "invalid candidate contract")
        end
    end

    local actionType = CandidateExecutionActionType(self, candidate)
    local preInvokeMove = self.CandidatePreInvokeMove and self:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
    if self.Ledger ~= nil and self.Ledger.CanSpendActionType ~= nil then
        local canSpend, spendReason = self.Ledger:CanSpendActionType(self, actor, actionType, preInvokeMove)
        if not canSpend then
            return false, spendReason or "action economy changed"
        end
    elseif candidate.abilityInfo ~= nil then
        local actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost
        local canUse, spendReason = self:CanUseActionCost(actor, candidate.abilityInfo, actionCost)
        if not canUse then
            return false, spendReason or "action economy changed"
        end
    end

    if candidate.retryKey ~= nil and self.CandidateRetryKey ~= nil then
        local currentRetryKey = self:CandidateRetryKey(candidate)
        if currentRetryKey ~= nil and currentRetryKey ~= candidate.retryKey then
            self:Trace("execute", "retry key mismatch", {
                candidate = candidate.description,
                reason = RetryKeyMismatchSummary(candidate.retryKey, currentRetryKey),
                storedRetryKey = TraceShortText(candidate.retryKey, 320),
                currentRetryKey = TraceShortText(currentRetryKey, 320),
            })
            return false, "retry key no longer matches proposal"
        end
    end

    if actor.kind == "squad" then
        local supportMoves = self.CandidateSquadSupportMoves and self:CandidateSquadSupportMoves(candidate) or candidate.squadSupportMoves or {}
        for _,move in ipairs(supportMoves) do
            if move.member ~= nil then
                local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, move.member.token, actor, "walk", move.loc, "squad support destination")
                if not valid then
                    return false, reason
                end
            end
        end
        local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
        for _,assignment in ipairs(squadAssignments) do
            if assignment.member ~= nil then
                local memberToken = assignment.member.token
                local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, memberToken, actor, "walk", assignment.loc, "squad assignment destination")
                if not valid then
                    return false, reason
                end
                valid, reason = self:ValidateExecutionMoveDestination(context, candidate, memberToken, actor, "charge", assignment.chargeLoc, "squad charge destination", assignment.loc)
                if not valid then
                    return false, reason
                end
            end
        end
        return true, nil
    end

    local token = actor.token
    local plannedOrigin = token and token.loc
    local loc = self.CandidateExecutionLoc and self:CandidateExecutionLoc(candidate) or candidate.loc
    if loc ~= nil and token ~= nil and not SameLoc(token.loc, loc) then
        local movementOnly = candidate.movementOnly == true
        if self.CandidateMovementOnly ~= nil then
            movementOnly = self:CandidateMovementOnly(candidate)
        end
        local mode = Pick(movementOnly, "walk", CandidateMovementMode(candidate, "walk"))
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, mode, loc, "candidate movement destination")
        if not valid then
            return false, reason
        end
        plannedOrigin = loc
    end

    if preInvokeMove ~= nil and preInvokeMove.destination ~= nil then
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, preInvokeMove.mode or "walk", preInvokeMove.destination, "pre-invoke destination", plannedOrigin)
        if not valid then
            return false, reason
        end
    end

    local advanceTargetLoc = self.CandidateAdvanceTargetLoc and self:CandidateAdvanceTargetLoc(candidate) or candidate.advanceTargetLoc
    if advanceTargetLoc ~= nil then
        local valid, reason = self:ValidateExecutionMoveDestination(context, candidate, token, actor, CandidateMovementMode(candidate, "advance"), advanceTargetLoc, "advance destination")
        if not valid then
            return false, reason
        end
    end

    return true, nil
end

function AI:ValidateExecutionVariation(context, candidate, symbols, options)
    options = options or {}
    if candidate == nil or candidate.actor == nil or candidate.ability == nil then
        return true, nil
    end

    if not TryGet(candidate.ability, "meleeAndRanged", false) or candidate._tmp_executionVariation == nil then
        return true, nil
    end

    local melee = TryGet(candidate.ability, "meleeVariation", nil)
    local ranged = TryGet(candidate.ability, "rangedVariation", nil)
    if melee == nil or ranged == nil then
        return true, nil
    end

    local actor = candidate.actor
    local attackLoc = actor.token and actor.token.loc
    local meleeRange = AbilityRange(melee, actor.token, symbols or {})
    local allMelee = true
    local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {}
    for _,target in ipairs(targets) do
        if target.token ~= nil and attackLoc ~= nil and LocDistance(attackLoc, target.token.loc) > meleeRange + 0.1 then
            allMelee = false
            break
        end
    end

    local actualVariation = Pick(allMelee, "melee", "ranged")
    if actualVariation ~= candidate._tmp_executionVariation then
        return false, Pick(options.afterMovement ~= false,
            "melee/ranged variation changed after movement",
            "melee/ranged variation did not match planned location")
    end

    return true, nil
end

function AI:ValidateCandidateBeforeInvoke(context, candidate, ability, symbols, options)
    options = options or {}
    if candidate == nil or candidate.actor == nil or ability == nil then
        return false, "candidate was incomplete"
    end

    local actor = candidate.actor
    local variationValid, variationReason = self:ValidateExecutionVariation(context, candidate, symbols, options)
    if not variationValid then
        return false, variationReason
    end

    local ok, reason, areaLegality = self:RefreshExecutionTargetArea(context, candidate, actor, symbols, options)
    if not ok then
        return false, reason, ValidationResultFromLegality(self, areaLegality, reason)
    end

    local targetArea = (self.CandidateTargetArea and self:CandidateTargetArea(candidate) or candidate.targetArea) or TryGet(symbols, "targetArea", nil)
    local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
    if #squadAssignments > 0 then
        for _,assignment in ipairs(squadAssignments) do
            local memberToken = assignment.member and assignment.member.token
            local targetToken = assignment.target
            if memberToken ~= nil and targetToken ~= nil then
                local memberActor = self:ExecutionActorForCaster(actor, memberToken)
                local abilityInfo = SafeCall(function()
                    return self:AnalyzeAbility(memberActor, ability)
                end, nil) or candidate.abilityInfo
                local valid, targetReason, targetLegality = self:ValidateExecutionTokenTarget(context, memberActor, ability, abilityInfo, memberToken, targetToken, symbols, nil, options)
                if not valid then
                    local squadReason = string.format("%s -> %s: %s", TokenName(memberToken), TokenName(targetToken), targetReason or "target invalid")
                    return false, squadReason, ValidationResultFromLegality(self, targetLegality, squadReason)
                end
            end
        end
    else
        local abilityInfo = SafeCall(function()
            return self:AnalyzeAbility(actor, ability)
        end, nil) or candidate.abilityInfo

        local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {}
        for _,target in ipairs(targets) do
            if target.token ~= nil then
                local valid, targetReason, targetLegality = self:ValidateExecutionTokenTarget(context, actor, ability, abilityInfo, actor.token, target.token, symbols, targetArea, options)
                if not valid then
                    return false, targetReason, ValidationResultFromLegality(self, targetLegality, targetReason)
                end
            end
        end
    end

    return true, nil
end

function AI:ValidateCandidateDryRunLegality(context, candidate, ability, symbols)
    local movementValid, movementReason = self:ValidateCandidateMovementPlan(context, candidate)
    if not movementValid then
        return false, movementReason
    end

    if candidate == nil or candidate.actor == nil or ability == nil then
        return true, nil
    end

    local actor = candidate.actor
    local options = {
        phase = "legality.dry_run",
        afterMovement = false,
    }
    local function Check()
        return self:ValidateCandidateBeforeInvoke(context, candidate, ability, symbols, options)
    end

    local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
    if #squadAssignments > 0 then
        for _,assignment in ipairs(squadAssignments) do
            local memberToken = assignment.member and assignment.member.token
            local targetToken = assignment.target
            if memberToken ~= nil and targetToken ~= nil then
                local memberActor = self:ExecutionActorForCaster(actor, memberToken)
                local plannedLoc = assignment.chargeLoc or assignment.loc
                local valid = true
                local reason = nil
                local targetLegality = nil
                local evaluated = false
                local function CheckAssignment()
                    local abilityInfo = SafeCall(function()
                        return self:AnalyzeAbility(memberActor, ability)
                    end, nil) or candidate.abilityInfo
                    valid, reason, targetLegality = self:ValidateExecutionTokenTarget(context, memberActor, ability, abilityInfo, memberToken, targetToken, symbols, nil, options)
                    evaluated = true
                end

                if plannedLoc ~= nil and memberToken.loc ~= nil and not SameLoc(memberToken.loc, plannedLoc) then
                    SafeCall(function()
                        memberToken:ExecuteWithTheoreticalLoc(plannedLoc, CheckAssignment)
                    end, nil)
                end
                if not evaluated then
                    CheckAssignment()
                end
                if not valid then
                    local squadReason = string.format("%s -> %s: %s", TokenName(memberToken), TokenName(targetToken), reason or "target invalid")
                    return false, squadReason, ValidationResultFromLegality(self, targetLegality, squadReason)
                end
            end
        end
        return true, nil
    end

    local token = actor.token
    local attackLoc = self.CandidatePrimaryAttackLoc and self:CandidatePrimaryAttackLoc(candidate) or candidate.loc
    if token ~= nil and token.loc ~= nil and attackLoc ~= nil and not SameLoc(token.loc, attackLoc) then
        local valid = false
        local reason = nil
        local validationResult = nil
        local evaluated = false
        SafeCall(function()
            token:ExecuteWithTheoreticalLoc(attackLoc, function()
                valid, reason, validationResult = Check()
                evaluated = true
            end)
        end, nil)
        if evaluated then
            return valid, reason, validationResult
        end
    end

    return Check()
end

function AI:ValidateCandidateForPhase(context, candidate, phase, args)
    args = args or {}
    local actor = candidate and candidate.actor or nil
    local movementOnly = args.movementOnly
    if movementOnly == nil and candidate ~= nil then
        movementOnly = candidate.movementOnly == true
        if self.CandidateMovementOnly ~= nil then
            movementOnly = self:CandidateMovementOnly(candidate)
        end
    end

    if phase == "contract" then
        if candidate == nil then
            return MakePhaseValidation(self, phase, false, "missing candidate")
        end
        if actor == nil then
            return MakePhaseValidation(self, phase, false, "missing actor", {
                candidate = candidate.description,
            })
        end
        if movementOnly ~= true and candidate.ability == nil then
            return MakePhaseValidation(self, phase, false, "missing ability", {
                candidate = candidate.description,
            })
        end

        if self.ValidateCandidateContract ~= nil then
            local contractValid, contractReason, contractFields = self:ValidateCandidateContract(candidate, phase)
            if not contractValid then
                contractFields = contractFields or {}
                contractFields.candidate = candidate.description
                if contractFields.storedRetryKey ~= nil then
                    contractFields.storedRetryKey = TraceShortText(contractFields.storedRetryKey, 320)
                end
                if contractFields.normalizedRetryKey ~= nil then
                    contractFields.normalizedRetryKey = TraceShortText(contractFields.normalizedRetryKey, 320)
                end
                if contractFields.currentRetryKey ~= nil then
                    contractFields.currentRetryKey = TraceShortText(contractFields.currentRetryKey, 320)
                end
                self:Trace("execute", "candidate contract mismatch", contractFields)
                return MakePhaseValidation(self, phase, false, "candidate contract mismatch: " .. tostring(contractReason or "invalid candidate contract"), contractFields)
            end
        end

        return MakePhaseValidation(self, phase, true, nil, {
            candidate = candidate.description,
        })
    end

    if actor == nil then
        return MakePhaseValidation(self, phase, false, "candidate was incomplete")
    end

    if phase == "resource.pre_move" then
        local actionType = args.actionType or CandidateExecutionActionType(self, candidate)
        local preInvokeMove = self.CandidatePreInvokeMove and self:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
        if self.Ledger ~= nil and self.Ledger.CanSpendActionType ~= nil then
            local canSpend, spendReason = self.Ledger:CanSpendActionType(self, actor, actionType, preInvokeMove)
            if not canSpend then
                return MakePhaseValidation(self, phase, false, spendReason or "action economy changed", {
                    actionType = actionType,
                })
            end
        elseif candidate.abilityInfo ~= nil then
            local actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost
            local canUse, spendReason = self:CanUseActionCost(actor, candidate.abilityInfo, actionCost)
            if not canUse then
                return MakePhaseValidation(self, phase, false, spendReason or "action economy changed", {
                    actionCost = actionCost,
                })
            end
        end

        if movementOnly == true then
            return MakePhaseValidation(self, phase, true, nil, {
                actionType = actionType,
            })
        end

        local ability = args.ability or candidate.ability
        local symbols = args.symbols or {}
        local abilityInfo = candidate.abilityInfo
        local actionGrant = args.actionGrant or (self.Ledger ~= nil and self.Ledger.CandidateActionGrant ~= nil and self.Ledger:CandidateActionGrant(self, candidate) or nil)
        local pendingGrantRequired = false
        if self.Ledger ~= nil and self.Ledger.PendingGrantUseForActionType ~= nil then
            pendingGrantRequired = self.Ledger:PendingGrantUseForActionType(self, actor, actionType, preInvokeMove) ~= nil
        end
        if actionGrant == nil
            and pendingGrantRequired
            and self.Ledger ~= nil
            and self.Ledger.AnnotateCandidateActionGrant ~= nil
        then
            self.Ledger:AnnotateCandidateActionGrant(self, actor, candidate)
            actionGrant = self.Ledger:CandidateActionGrant(self, candidate)
        end
        local canAfford = true
        local affordabilityReason = nil

        if abilityInfo ~= nil and abilityInfo.isVillain and self.CanUseVillainAction ~= nil then
            canAfford, affordabilityReason = self:CanUseVillainAction(context, actor, ability, abilityInfo, symbols)
        elseif ability ~= nil then
            local realCanAfford = AbilityCanAfford(ability, actor.token, symbols)
            canAfford = realCanAfford
            if not realCanAfford and actionGrant == nil and self.Ledger ~= nil and self.Ledger.AnnotateCandidateActionGrant ~= nil then
                self.Ledger:AnnotateCandidateActionGrant(self, actor, candidate)
                actionGrant = self.Ledger:CandidateActionGrant(self, candidate)
                canAfford = actionGrant ~= nil and AbilityCanAffordWithActionGrant(ability, actor, symbols)
            elseif not realCanAfford and actionGrant ~= nil then
                canAfford = AbilityCanAffordWithActionGrant(ability, actor, symbols)
            elseif realCanAfford and actionGrant ~= nil then
                if pendingGrantRequired then
                    canAfford = AbilityCanAffordWithActionGrant(ability, actor, symbols)
                else
                    local execution = self.CandidateExecution and self:CandidateExecution(candidate) or {}
                    if self.WriteCandidateExecution ~= nil then
                        self:WriteCandidateExecution(candidate, nil, {
                            clear = {
                                "actionGrant",
                                "usesActionGrant",
                            },
                        })
                    else
                        execution.actionGrant = nil
                        candidate.actionGrant = nil
                        candidate.usesActionGrant = nil
                    end
                    actionGrant = nil
                end
            end
        end

        args.actionGrant = actionGrant
        if not canAfford then
            return MakePhaseValidation(self, phase, false, affordabilityReason or "ability unaffordable before execution", {
                actionGrant = actionGrant,
                ability = ability and ability.name,
            })
        end

        return MakePhaseValidation(self, phase, true, nil, {
            actionGrant = actionGrant,
            ability = ability and ability.name,
        })
    end

    if phase == "prompt.preflight" then
        if movementOnly == true then
            return MakePhaseValidation(self, phase, true)
        end

        local ability = args.ability or candidate.ability
        local symbols = args.symbols or {}
        local manualPrompt = args.manualPrompt
        if manualPrompt == nil then
            manualPrompt = self.CandidateManualPrompt and self:CandidateManualPrompt(candidate) or candidate.manualPrompt == true
        end

        local promptCapability = candidate.promptCapability
        if self.AssessPromptCapability ~= nil then
            promptCapability = self:AssessPromptCapability(context, actor, candidate.abilityInfo, candidate)
            if self.AnnotatePromptCapability ~= nil then
                self:AnnotatePromptCapability(candidate, promptCapability)
            end
        end
        args.promptCapability = promptCapability

        if promptCapability ~= nil
            and promptCapability.status ~= "auto"
            and not (manualPrompt == true and promptCapability.status == "manual")
        then
            return ValidationResultFromPromptCapability(self, promptCapability, phase, promptCapability.reason or "prompt was not automated")
                or MakePhaseValidation(self, phase, false, promptCapability.reason or "prompt was not automated", {
                    promptCapability = promptCapability,
                }, promptCapability.reasonCode)
        end

        if AbilityRequiresPrompt(ability) and manualPrompt ~= true then
            return MakePhaseValidation(self, phase, false, "prepared ability still requires prompt", PreparedPromptTraceFields(candidate, ability), "prepared_ability_still_requires_prompt")
        end

        if manualPrompt == true then
            return MakePhaseValidation(self, phase, true, nil, {
                promptCapability = promptCapability,
            })
        end

        local nestedValid, nestedReason, nestedStatus, nestedCapability = self:ValidateNestedPromptPoliciesBeforeExecution(context, actor, candidate, ability, symbols)
        args.nestedPromptCapability = nestedCapability
        if not nestedValid then
            if nestedCapability ~= nil then
                return ValidationResultFromPromptCapability(self, nestedCapability, phase, nestedReason)
            end

            return MakePhaseValidation(self, phase, false, nestedReason or "nested prompt was not automated", {
                promptStatus = nestedStatus,
            }, "nested_prompt_blocked")
        end

        return MakePhaseValidation(self, phase, true, nil, {
            promptCapability = nestedCapability or promptCapability,
        })
    end

    if phase == "legality.dry_run" then
        local valid, reason, validationResult = self:ValidateCandidateDryRunLegality(context, candidate, args.ability, args.symbols or {})
        if not valid then
            if type(validationResult) == "table" then
                validationResult.phase = validationResult.phase or phase
                return validationResult
            end
            return MakePhaseValidation(self, phase, false, reason or "candidate failed planned-location validation")
        end

        return MakePhaseValidation(self, phase, true)
    end

    if phase == "resource.reserve" then
        local actionGrant = args.actionGrant or (self.Ledger ~= nil and self.Ledger.CandidateActionGrant ~= nil and self.Ledger:CandidateActionGrant(self, candidate) or nil)
        if actionGrant == nil then
            return MakePhaseValidation(self, phase, true)
        end
        if self.Ledger == nil or self.Ledger.ReservePendingActionGrant == nil then
            return MakePhaseValidation(self, phase, false, "pending action grant ledger unavailable", {
                actionGrant = actionGrant,
            })
        end

        local reserved, reservationOrReason = self.Ledger:ReservePendingActionGrant(self, actor, candidate)
        if not reserved then
            return MakePhaseValidation(self, phase, false, reservationOrReason or "pending action grant unavailable", {
                actionGrant = actionGrant,
            })
        end

        args.actionGrantReservation = reservationOrReason
        return MakePhaseValidation(self, phase, true, nil, {
            actionGrant = actionGrant,
            reservation = reservationOrReason,
        })
    end

    if phase == "movement.stale" then
        local destinationValid, destinationReason = self:ValidateMovedDestinationState(context, candidate)
        if not destinationValid then
            return MakePhaseValidation(self, phase, false, destinationReason or "movement destination stale")
        end

        if movementOnly == true then
            return MakePhaseValidation(self, phase, true)
        end

        local valid, reason, validationResult = self:ValidateCandidateBeforeInvoke(context, candidate, args.ability, args.symbols or {}, {
            phase = phase,
            afterMovement = true,
        })
        if not valid then
            if type(validationResult) == "table" then
                validationResult.phase = validationResult.phase or phase
                return validationResult
            end
            return MakePhaseValidation(self, phase, false, reason or "candidate became illegal after movement")
        end

        return MakePhaseValidation(self, phase, true)
    end

    if phase == "invoke" then
        local invoker = args.invoker
        if invoker == nil or invoker.ExecuteInvoke == nil then
            return MakePhaseValidation(self, phase, false, "execution API unavailable")
        end
        if movementOnly ~= true and args.ability == nil then
            return MakePhaseValidation(self, phase, false, "ability clone failed")
        end
        return MakePhaseValidation(self, phase, true)
    end

    return MakePhaseValidation(self, phase or "unknown", false, "unknown validation phase")
end

function AI:ValidateNestedPromptPoliciesBeforeExecution(context, actor, candidate, ability, symbols)
    if actor == nil or ability == nil or self.AssessPromptCapability == nil then
        return true, nil, nil
    end

    local function Check()
        local abilityInfo = candidate and candidate.abilityInfo
        if abilityInfo == nil and self.AnalyzeAbility ~= nil then
            abilityInfo = SafeCall(function()
                return self:AnalyzeAbility(actor, ability)
            end, nil)
        end

        local assessmentCandidate = {
            actor = actor,
            ability = ability,
            abilityInfo = abilityInfo,
            targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate and candidate.targets or {},
            targetArea = self.CandidateTargetArea and self:CandidateTargetArea(candidate) or candidate and candidate.targetArea,
            symbols = CopySymbols(symbols or {}),
            loc = self.CandidatePrimaryAttackLoc and self:CandidatePrimaryAttackLoc(candidate) or candidate and candidate.loc,
            preInvokeMove = self.CandidatePreInvokeMove and self:CandidatePreInvokeMove(candidate) or candidate and candidate.preInvokeMove,
            description = candidate and candidate.description,
            _directorPromptPreflight = true,
        }

        local capability = self:AssessPromptCapability(context, actor, abilityInfo, assessmentCandidate)
        if self.AnnotatePromptCapability ~= nil then
            self:AnnotatePromptCapability(candidate, capability)
        end
        if capability == nil or capability.status == "auto" then
            return true, nil, nil, capability
        end

        return false, capability.reason or "nested prompt was not automated", "blocked", capability
    end

    local token = actor.token
    local preflightLoc = self.CandidatePrimaryAttackLoc and self:CandidatePrimaryAttackLoc(candidate) or candidate and candidate.loc
    if token ~= nil and token.loc ~= nil and preflightLoc ~= nil and not SameLoc(token.loc, preflightLoc) then
        local ok = false
        local reason = nil
        local status = nil
        local capability = nil
        local evaluated = false
        SafeCall(function()
            token:ExecuteWithTheoreticalLoc(preflightLoc, function()
                ok, reason, status, capability = Check()
                evaluated = true
            end)
        end, nil)
        if evaluated then
            return ok, reason, status, capability
        end
    end

    return Check()
end

function AI:ExecuteCandidate(context, candidate)
    if candidate == nil then
        self:Trace("execute", "missing candidate")
        return false
    end

    local actor = candidate.actor
    if actor == nil then
        self:Trace("execute", "missing actor", { candidate = candidate.description })
        return false
    end

    if self:AutomationCanceled(context and context.runGeneration) then
        self:Trace("execute", "canceled before start", { candidate = candidate.description, actor = TokenName(actor.token) })
        return false
    end

    local executionFinished = false
    local function FinishExecution(executed, reason, validationResult)
        self:Trace("execute", "finished", {
            candidate = candidate.description,
            actor = TokenName(actor.token),
            executed = executed == true,
            reason = reason,
            validationPhase = validationResult and validationResult.phase,
            reasonCode = validationResult and validationResult.reasonCode,
            validationResult = validationResult,
        })
        candidate.executionFailureReason = Pick(executed == true, nil, reason)
        candidate.executionValidationResult = Pick(executed == true, nil, validationResult)
        if context ~= nil then
            context.lastExecutionFailureReason = Pick(executed == true, nil, reason)
            context.lastExecutionFailureCandidate = Pick(executed == true, nil, candidate)
            context.lastExecutionValidationResult = Pick(executed == true, nil, validationResult)
        end
        if not executionFinished then
            executionFinished = true
            self:EmitPhase(self.Phase.CandidateExecutionFinished, {
                context = context,
                actor = actor,
                candidate = candidate,
                executed = executed == true,
                reason = reason,
                validationResult = validationResult,
                validationPhase = validationResult and validationResult.phase,
                reasonCode = validationResult and validationResult.reasonCode,
                runGeneration = context and context.runGeneration,
            })
        end

        return executed == true, reason
    end

    if not self:EmitPhase(self.Phase.CandidateExecutionStarted, {
        context = context,
        actor = actor,
        candidate = candidate,
        runGeneration = context and context.runGeneration,
    }) then
        return FinishExecution(false, "execution start canceled")
    end

    local manualPrompt = candidate.manualPrompt == true
    if self.CandidateManualPrompt ~= nil then
        manualPrompt = self:CandidateManualPrompt(candidate)
    end
    self:Trace("execute", "started", {
        candidate = candidate.description,
        actor = TokenName(actor.token),
        retryKey = self.CandidateRetryKey and self:CandidateRetryKey(candidate) or candidate.retryKey,
        actionCost = self.CandidateActionCost and self:CandidateActionCost(candidate) or candidate.actionCost,
        manualPrompt = manualPrompt,
    })
    self:SetStatus("Last action: " .. tostring(candidate.description or "unknown"))
    self:Log("Executing: " .. tostring(candidate.description))

    local function StaleAbort(reason, status, validationResult)
        self:SetStatus(status or "Held: candidate became stale")
        return FinishExecution(false, self:LogStaleAbort(context, candidate, reason), validationResult)
    end

    local function AbortValidation(validationResult, status)
        local reason = validationResult and validationResult.reason or "candidate failed validation"
        local phase = validationResult and validationResult.phase or nil
        if phase == "prompt.preflight" then
            self:Log("Skipping ability with unresolved prompt before movement: " .. tostring(candidate.description) .. " (" .. tostring(reason) .. ")")
            self:SetStatus(status or "Held: prompt was not automated")
            if validationResult ~= nil and validationResult.reasonCode == "prepared_ability_still_requires_prompt" then
                return FinishExecution(false, "prepared ability still requires prompt", validationResult)
            end
            return FinishExecution(false, "blocked prompt before execution: " .. tostring(reason), validationResult)
        elseif phase == "invoke" then
            self:SetStatus(status or "Failed: ability execution API unavailable")
            return FinishExecution(false, reason, validationResult)
        end

        return StaleAbort(reason, status, validationResult)
    end

    local movementOnly = candidate.movementOnly == true
    if self.CandidateMovementOnly ~= nil then
        movementOnly = self:CandidateMovementOnly(candidate)
    end

    local executionArgs = {
        manualPrompt = manualPrompt,
        movementOnly = movementOnly,
    }
    local validation = self:ValidateCandidateForPhase(context, candidate, "contract", executionArgs)
    self:Trace("execute", "phase validation", {
        candidate = candidate.description,
        phase = validation and validation.phase,
        valid = validation and validation.ok,
        reason = validation and validation.reason,
        reasonCode = validation and validation.reasonCode,
    })
    if validation == nil or validation.ok ~= true then
        return AbortValidation(validation, "Held: candidate failed contract validation")
    end

    local intent = self.CandidateIntent and self:CandidateIntent(candidate) or {}
    local symbols = CopySymbols((self.CandidateExecutionSymbols and self:CandidateExecutionSymbols(candidate)) or candidate.symbols or {})
    symbols.mode = symbols.mode or 1
    local candidateTargetArea = self.CandidateTargetArea and self:CandidateTargetArea(candidate) or candidate.targetArea
    if candidateTargetArea ~= nil then
        symbols.targetArea = candidateTargetArea
    end
    local modeSelection = self.CandidateModeSelection and self:CandidateModeSelection(candidate) or intent.modeSelection or candidate.modeSelection
    if modeSelection ~= nil then
        local modeIndex = tonumber(modeSelection.index)
        if modeIndex == nil then
            local modeValidation = MakePhaseValidation(self, "contract", false, "invalid mode selection", {
                mode = modeSelection.index,
            })
            self:Trace("execute", "invalid mode selection", { candidate = candidate.description, mode = modeSelection.index })
            self:Log("Skipping mode-selected ability with invalid mode: " .. tostring(candidate.description))
            self:SetStatus("Held: selected ability had invalid mode")
            return FinishExecution(false, "invalid mode selection", modeValidation)
        end
        symbols.mode = modeIndex
    end

    if candidate.abilityInfo ~= nil and candidate.abilityInfo.isMalice and symbols.charges == nil then
        symbols.charges = self:MaliceCost(candidate.abilityInfo)
    end

    local ability = candidate.ability
    local startTurnMalice = intent.startTurnMalice or candidate.startTurnMalice
    if self.CandidateStartTurnMalice ~= nil then
        startTurnMalice = self:CandidateStartTurnMalice(candidate)
    end
    if not movementOnly then
        candidate._tmp_executionVariation = nil
        if TryGet(ability, "meleeAndRanged", false) then
            local melee = TryGet(ability, "meleeVariation", nil)
            local ranged = TryGet(ability, "rangedVariation", nil)
            if melee ~= nil and ranged ~= nil then
                local meleeRange = AbilityRange(melee, actor.token, symbols)
                local attackLoc = AI.CandidatePrimaryAttackLoc ~= nil and AI:CandidatePrimaryAttackLoc(candidate) or candidate.loc or actor.token.loc
                local allMelee = true
                local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {}
                for _,target in ipairs(targets) do
                    if target.token ~= nil and LocDistance(attackLoc, target.token.loc) > meleeRange + 0.1 then
                        allMelee = false
                        break
                    end
                end
                candidate._tmp_executionVariation = Pick(allMelee, "melee", "ranged")
                ability = Pick(allMelee, melee, ranged)
            end
        end

        ability = SafeCall(function()
            return ability:MakeTemporaryClone()
        end, ability)

        if ability == nil then
            self:Trace("execute", "ability clone failed", { candidate = candidate.description })
            self:SetStatus("Failed: selected ability could not be prepared")
            return FinishExecution(false, "ability clone failed", MakePhaseValidation(self, "invoke", false, "ability clone failed"))
        end

        if startTurnMalice then
            ability.actionResourceId = "none"
        end

        if modeSelection ~= nil then
            local modeIndex = tonumber(modeSelection.index)
            ability = SafeCall(function()
                return ability:SwitchModes(modeIndex)
            end, ability) or ability
            SuppressResolvedModePrompt(ability)
            symbols.mode = modeIndex
            self:Log(string.format(
                "Mode selection: %s (%s)",
                tostring(modeSelection.text or ("mode " .. tostring(modeIndex))),
                tostring(modeSelection.reason or "tactical")
            ))
        end
    end

    executionArgs.symbols = symbols
    executionArgs.ability = ability
    executionArgs.actionType = CandidateExecutionActionType(self, candidate)

    validation = self:ValidateCandidateForPhase(context, candidate, "resource.pre_move", executionArgs)
    self:Trace("execute", "phase validation", {
        candidate = candidate.description,
        phase = validation and validation.phase,
        valid = validation and validation.ok,
        reason = validation and validation.reason,
        reasonCode = validation and validation.reasonCode,
        validationResult = validation,
    })
    if validation == nil or validation.ok ~= true then
        return AbortValidation(validation, "Held: selected ability could not be afforded")
    end

    local actionGrant = executionArgs.actionGrant or (self.Ledger ~= nil and self.Ledger.CandidateActionGrant ~= nil and self.Ledger:CandidateActionGrant(self, candidate) or nil)
    if actionGrant ~= nil and ability ~= nil then
        ability.actionResourceId = "none"
        self:Trace("resource", "prepared pending action grant cast", {
            candidate = candidate.description,
            kind = actionGrant.kind,
            quantity = actionGrant.quantity,
        })
    end
    if startTurnMalice or actionGrant ~= nil then
        if ability ~= nil then
            ability.actionResourceId = "none"
        end
    end

    validation = self:ValidateCandidateForPhase(context, candidate, "prompt.preflight", executionArgs)
    self:Trace("execute", "phase validation", {
        candidate = candidate.description,
        phase = validation and validation.phase,
        valid = validation and validation.ok,
        reason = validation and validation.reason,
        reasonCode = validation and validation.reasonCode,
        validationResult = validation,
    })
    if validation == nil or validation.ok ~= true then
        return AbortValidation(validation, "Held: prompt was not automated")
    end

    validation = self:ValidateCandidateForPhase(context, candidate, "legality.dry_run", executionArgs)
    self:Trace("execute", "phase validation", {
        candidate = candidate.description,
        phase = validation and validation.phase,
        valid = validation and validation.ok,
        reason = validation and validation.reason,
        reasonCode = validation and validation.reasonCode,
        validationResult = validation,
    })
    if validation == nil or validation.ok ~= true then
        return AbortValidation(validation, "Held: candidate failed planned-location validation")
    end

    if manualPrompt then
        local reason = self.CandidateManualPromptReason and self:CandidateManualPromptReason(candidate) or candidate.manualPromptReason or "manual targeting"
        self:Trace("execute", "manual prompt open", {
            candidate = candidate.description,
            actor = TokenName(actor.token),
            reason = reason,
        })
        local opened = self:OpenManualPromptCandidate(context, candidate)
        if opened then
            if context ~= nil then
                context.manualPromptHandoff = true
                context.manualPromptHandoffCandidate = candidate
            end
            self:Log("Manual prompt opened for Director resolution: " .. tostring(candidate.description) .. " (" .. tostring(reason) .. ")")
            self:SetStatus("Manual prompt opened: resolve " .. tostring(candidate.description) .. " (" .. tostring(reason) .. ")")
        else
            if context ~= nil then
                context.manualPromptHandoff = nil
                context.manualPromptHandoffCandidate = nil
            end
            self:CleanupPromptTargeting(context, actor, candidate, "manual prompt open failed")
            self:Log("Manual prompt could not be opened: " .. tostring(candidate.description) .. " (" .. tostring(reason) .. ")")
            self:SetStatus("Manual prompt failed to open: " .. tostring(candidate.description))
        end
        return FinishExecution(false, Pick(opened, "manual prompt handoff", "manual prompt open failed"))
    end

    local invoker = nil
    if not movementOnly then
        invoker = RawGlobal("ActivatedAbilityInvokeAbilityBehavior")
        executionArgs.invoker = invoker
        validation = self:ValidateCandidateForPhase(context, candidate, "invoke", executionArgs)
        self:Trace("execute", "phase validation", {
            candidate = candidate.description,
            phase = validation and validation.phase,
            valid = validation and validation.ok,
            reason = validation and validation.reason,
            reasonCode = validation and validation.reasonCode,
            validationResult = validation,
        })
        if validation == nil or validation.ok ~= true then
            self:Trace("execute", "execution API unavailable", { candidate = candidate.description })
            self:Log("Cannot execute ability because ExecuteInvoke is unavailable.")
            return AbortValidation(validation, "Failed: ability execution API unavailable")
        end
    end

    local movedTokens = {}
    local capturedTokens = {}
    local function CaptureMove(tok)
        if tok == nil or not tok.valid or tok.loc == nil then
            return
        end

        local key = TokenId(tok) or tostring(tok)
        if capturedTokens[key] then
            return
        end

        capturedTokens[key] = true
        movedTokens[#movedTokens+1] = { token = tok, loc = tok.loc }
    end

    local function RollbackMoves()
        local rolledBack = false
        for i=#movedTokens,1,-1 do
            local entry = movedTokens[i]
            if entry.token ~= nil and entry.token.valid and entry.loc ~= nil then
                self:Trace("movement", "rollback token", { token = TokenName(entry.token), loc = TryGet(entry.loc, "str", entry.loc) })
                SafeCall(function()
                    entry.token:Move(entry.loc, { maxCost = 10000, ignoreFalling = true })
                end, nil)
                self:SyncExecutionMovedTiles(actor, entry.token)
                rolledBack = true
            end
        end
        if rolledBack then
            self:SyncExecutionMovedTiles(actor, actor.token)
        end
    end

    local function MovePlannedToken(tok, locs)
        if tok == nil then
            return true
        end

        for index,loc in ipairs(locs or {}) do
            CaptureMove(tok)
            if loc ~= nil and not SameLoc(tok.loc, loc) then
                self:Log(string.format("Planned %s move %d: %s -> %s", Pick(movementOnly, "movement-only", "pre-invoke"), index, TokenName(tok), tostring(TryGet(loc, "str", loc))))
                self:Trace("movement", "planned move", {
                    token = TokenName(tok),
                    index = index,
                    kind = Pick(movementOnly, "movement-only", "pre-invoke"),
                    from = TryGet(tok.loc, "str", tok.loc),
                    to = TryGet(loc, "str", loc),
                })
            end
            if not self:MoveToken(tok, loc, context, Pick(movementOnly, "movement-only", "pre-invoke")) then
                self:Trace("movement", "move failed", { token = TokenName(tok), loc = TryGet(loc, "str", loc) })
                return false
            end
            self:SyncExecutionMovedTiles(actor, tok)
        end

        return true
    end

    local function MoveCandidateToExecutionLocs()
        local squadAssignments = self.CandidateSquadAssignments and self:CandidateSquadAssignments(candidate) or candidate.squadAssignments or {}
        local supportMoves = self.CandidateSquadSupportMoves and self:CandidateSquadSupportMoves(candidate) or candidate.squadSupportMoves or {}
        if #squadAssignments > 0 or #supportMoves > 0 then
            for _,move in ipairs(supportMoves) do
                if move.member ~= nil and not MovePlannedToken(move.member.token, AssignmentMoveLocs(move)) then
                    return false
                end
            end
            for _,assignment in ipairs(squadAssignments) do
                if assignment.member ~= nil and not MovePlannedToken(assignment.member.token, AssignmentMoveLocs(assignment)) then
                    return false
                end
            end
            return true
        end

        return MovePlannedToken(actor.token, CandidateMoveLocs(candidate))
    end

    local actionGrantReservation = nil
    local actionGrantCommitted = false
    local function RollbackActionGrant(reason)
        if actionGrantReservation ~= nil and not actionGrantCommitted then
            self.Ledger:RollbackPendingActionGrant(self, actor, actionGrantReservation, reason)
            actionGrantReservation = nil
        end
    end

    if not movementOnly then
        validation = self:ValidateCandidateForPhase(context, candidate, "resource.reserve", executionArgs)
        self:Trace("execute", "phase validation", {
            candidate = candidate.description,
            phase = validation and validation.phase,
            valid = validation and validation.ok,
            reason = validation and validation.reason,
            reasonCode = validation and validation.reasonCode,
            validationResult = validation,
        })
        if validation == nil or validation.ok ~= true then
            return AbortValidation(validation, "Held: pending action grant was unavailable")
        end
        actionGrantReservation = executionArgs.actionGrantReservation
    end

    if not MoveCandidateToExecutionLocs() then
        RollbackActionGrant("movement destination occupied")
        RollbackMoves()
        return StaleAbort("movement destination occupied", "Held: movement destination was occupied", MakePhaseValidation(self, "movement.stale", false, "movement destination occupied"))
    end

    validation = self:ValidateCandidateForPhase(context, candidate, "movement.stale", executionArgs)
    self:Trace("execute", "phase validation", {
        candidate = candidate.description,
        phase = validation and validation.phase,
        valid = validation and validation.ok,
        reason = validation and validation.reason,
        reasonCode = validation and validation.reasonCode,
        validationResult = validation,
    })
    if validation == nil or validation.ok ~= true then
        RollbackActionGrant("movement stale")
        RollbackMoves()
        self:Log("Candidate became illegal after movement: " .. tostring(candidate.description) .. " (" .. tostring(validation and validation.reason or "candidate became illegal after movement") .. ")")
        return StaleAbort(validation and validation.reason or "candidate became illegal after movement", "Held: candidate became illegal after movement", validation)
    end

    if movementOnly then
        self:MarkActionCostUsed(actor, candidate)
        self:RecordCandidateExecution(context, candidate)
        return FinishExecution(true, "movement only")
    end

    local cleanup = self:InstallPromptControl(context, actor)

    local options = {
        symbols = symbols,
        targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {},
        targetArea = symbols.targetArea or (self.CandidateTargetArea and self:CandidateTargetArea(candidate) or candidate.targetArea),
        countsAsCast = true,
        _directorCandidateTargets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {},
        _directorAdvanceLoc = self.CandidateAdvanceTargetLoc and self:CandidateAdvanceTargetLoc(candidate) or candidate.advanceTargetLoc,
        _directorProtectParentInvokeState = symbols.cast ~= nil,
    }
    options.costOverride = SafeCall(function()
        return ability:GetCost(actor.token, symbols)
    end, nil)
    local restoreParentInvokeStateProtection = function()
    end
    if options._directorProtectParentInvokeState then
        restoreParentInvokeStateProtection = InstallParentInvokeStateProtection(invoker, symbols.cast)
    end

    local began = false
    local finished = false
    local aborted = false
    local paid = false
    local finishOptionsSnapshot = nil
    local previousBegin = TryGet(ability, "OnBeginCast", nil)
    local previousFinish = TryGet(ability, "OnFinishCast", nil)
    ability.OnBeginCast = function(abilityArg, castOptions)
        began = true
        if previousBegin ~= nil then
            previousBegin(abilityArg, castOptions)
        end
    end

    ability.OnFinishCast = function(abilityArg, finishOptions)
        if previousFinish ~= nil then
            previousFinish(abilityArg, finishOptions)
        end
        aborted = finishOptions ~= nil and finishOptions.abort == true
        paid = finishOptions ~= nil and finishOptions.pay == true
        finishOptionsSnapshot = finishOptions
        finished = true
    end

    local function RestoreAbilityCallbacks()
        ability.OnBeginCast = previousBegin
        ability.OnFinishCast = previousFinish
    end

    local cleanedUp = false
    local previousExecutingCandidate = context and context.executingCandidate
    if context ~= nil then
        context.executingCandidate = candidate
    end
    local function CleanupExecution()
        if cleanedUp then
            return
        end

        cleanedUp = true
        RestoreAbilityCallbacks()
        restoreParentInvokeStateProtection()
        cleanup()
        if context ~= nil then
            context.executingCandidate = previousExecutingCandidate
        end
    end

    local castSnapshot = nil
    local invokeLocSnapshot = nil
    local invokeLocRestored = false
    local function RollbackInvokeSideEffects(reason)
        if invokeLocRestored then
            return
        end

        invokeLocRestored = true
        RestoreInvokeTokenLocations(self, invokeLocSnapshot, actor, reason)
    end

    local function CurrentPromptResolutionExit()
        if context == nil or type(context.promptResolutionExit) ~= "table" then
            return nil
        end

        return context.promptResolutionExit
    end

    local function FinishPromptResolutionExit()
        local promptExit = CurrentPromptResolutionExit()
        if promptExit == nil then
            return nil
        end

        context.promptResolutionExit = nil
        local status = promptExit.status or "blocked"
        local reason = promptExit.reason or "prompt resolution stopped"
        local promptAbility = promptExit.ability or "prompt"
        self:Trace("prompt", "execution prompt exit", {
            candidate = candidate.description,
            ability = promptAbility,
            status = status,
            reason = reason,
        })

        self:CleanupPromptTargeting(context, actor, candidate, "prompt resolution " .. tostring(status))
        self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
        RollbackActionGrant("prompt resolution " .. tostring(status))
        CleanupExecution()
        RollbackInvokeSideEffects("prompt resolution " .. tostring(status))
        RollbackMoves()
        self:Log("Ability stopped by prompt resolution: " .. tostring(candidate.description) .. " (" .. tostring(promptAbility) .. ": " .. tostring(reason) .. ")")
        self:SetStatus(Pick(status == "abort", "Aborted: prompt was unsafe", "Held: unresolved prompt was not automated"))
        return FinishExecution(false, tostring(status) .. " prompt: " .. tostring(promptAbility))
    end

    local resourceSnapshot = self.Ledger:GlobalResourceSnapshot(self, candidate)
    self:Trace("resource", "snapshot before invoke", {
        candidate = candidate.description,
        malice = resourceSnapshot and resourceSnapshot.malice,
        villainActions = resourceSnapshot and resourceSnapshot.villainActions,
    })
    castSnapshot = self:GetActiveCastSnapshot()
    local didWork = false
    if context ~= nil then
        context.promptResolutionExit = nil
    end
    self:Trace("execute", "invoke start", {
        candidate = candidate.description,
        actor = TokenName(actor.token),
        ability = ability.name,
        mode = symbols.mode,
        charges = symbols.charges,
    })
    invokeLocSnapshot = SnapshotInvokeTokenLocations(context, actor, candidate)
    local invoked = SafeCall(function()
        didWork = invoker.ExecuteInvoke(actor.token, ability, actor.token, "inherit", symbols, options) == true
        restoreParentInvokeStateProtection()
        return true
    end, false)
    self:Trace("execute", "invoke returned", { candidate = candidate.description, invoked = invoked, didWork = didWork })

    if not invoked then
        self:CleanupPromptTargeting(context, actor, candidate, "ability invoke failed")
        self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
        RollbackActionGrant("ability invoke failed")
        CleanupExecution()
        RollbackInvokeSideEffects("ability invoke failed")
        RollbackMoves()
        self:Log("Ability invoke failed: " .. tostring(candidate.description))
        self:SetStatus("Failed: " .. tostring(candidate.description))
        return FinishExecution(false, "ability invoke failed")
    end

    local promptExitResult = FinishPromptResolutionExit()
    if promptExitResult ~= nil then
        return promptExitResult
    end

    if not didWork and not began and not finished then
        self:CleanupPromptTargeting(context, actor, candidate, "ability produced no cast")
        self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
        RollbackActionGrant("ability produced no cast")
        CleanupExecution()
        RollbackInvokeSideEffects("ability produced no cast")
        RollbackMoves()
        self:Log("Ability invoke produced no cast: " .. tostring(candidate.description))
        self:SetStatus("No cast produced: " .. tostring(candidate.description))
        return FinishExecution(false, "ability produced no cast")
    end

    local started = dmhub.Time()
    while not finished and CurrentPromptResolutionExit() == nil and dmhub.Time() - started < 18 and not self:AutomationCanceled(context and context.runGeneration) do
        coroutine.yield(0.1)
    end
    self:Trace("execute", "cast wait complete", {
        candidate = candidate.description,
        finished = finished,
        began = began,
        paid = paid,
        aborted = aborted,
        promptExit = CurrentPromptResolutionExit() ~= nil,
    })

    if self:AutomationCanceled(context and context.runGeneration) then
        self:CleanupPromptTargeting(context, actor, candidate, "automation canceled during execution")
        RollbackActionGrant("automation canceled during execution")
        CleanupExecution()
        RollbackInvokeSideEffects("automation canceled during execution")
        RollbackMoves()
        self:Log("Ability abandoned because automation was stopped: " .. tostring(candidate.description))
        self:SetStatus("Stopped during: " .. tostring(candidate.description))
        return FinishExecution(false, "automation canceled during execution")
    end

    promptExitResult = FinishPromptResolutionExit()
    if promptExitResult ~= nil then
        return promptExitResult
    end

    if not finished then
        self:CleanupPromptTargeting(context, actor, candidate, "execution timed out")
        self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
        RollbackActionGrant("execution timed out")
        CleanupExecution()
        RollbackInvokeSideEffects("execution timed out")
        RollbackMoves()
        self:Log("Ability did not report completion before timeout: " .. tostring(candidate.description))
        self:SetStatus("Timed out: " .. tostring(candidate.description))
        return FinishExecution(false, "execution timed out")
    end

    if aborted or (not began and not didWork and not paid) then
        self:CleanupPromptTargeting(context, actor, candidate, "ability did not complete usable work")
        self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
        RollbackActionGrant("no usable work completed")
        CleanupExecution()
        RollbackInvokeSideEffects("no usable work completed")
        RollbackMoves()
        self:Log("Ability did not complete usable work: " .. tostring(candidate.description))
        self:SetStatus("No usable work completed: " .. tostring(candidate.description))
        return FinishExecution(false, "no usable work completed")
    end

    self:WaitForCastSettle(self:CandidateSettleTimeout(candidate), 4, castSnapshot, tostring(candidate.description))
    CleanupExecution()

    if candidate.abilityInfo ~= nil and self:IsStandardGrabAbilityInfo(candidate.abilityInfo) then
        local targets = self.CandidateTargets and self:CandidateTargets(candidate) or candidate.targets or {}
        local targetToken = targets[1] and targets[1].token
        local grabbed = false
        if targetToken ~= nil then
            if self.TargetHasCondition ~= nil then
                grabbed = self:TargetHasCondition(targetToken, "Grabbed") == true
            else
                grabbed = SafeCall(function()
                    return targetToken.properties ~= nil and targetToken.properties:HasNamedCondition("Grabbed")
                end, false) == true
            end
        end
        local targetTier = nil
        local cast = symbols and symbols.cast
        local tokenToTier = CastTryGet(cast, "tokenToTier")
        local targetId = TokenId(targetToken)
        if targetId ~= nil and type(tokenToTier) == "table" then
            targetTier = tokenToTier[targetId]
        end
        self:Log(string.format(
            "Grab result: %s grabbed=%s tier=%s targetTier=%s",
            TokenName(targetToken),
            tostring(grabbed),
            tostring(cast and cast.tier or nil),
            tostring(targetTier)
        ))
    end

    actor.turnMemory.usedAbilities = actor.turnMemory.usedAbilities or {}
    if not (candidate.abilityInfo ~= nil and self:IsSoloActionName(candidate.abilityInfo.name)) then
        local usedAbility = candidate.abilityInfo and candidate.abilityInfo.baseAbility or candidate.baseAbility or candidate.ability
        actor.turnMemory.usedAbilities[TryGet(usedAbility, "guid", TryGet(usedAbility, "name", ""))] = true
        if usedAbility ~= candidate.ability then
            actor.turnMemory.usedAbilities[TryGet(candidate.ability, "guid", TryGet(candidate.ability, "name", ""))] = true
        end
    end
    if actionGrantReservation ~= nil then
        self.Ledger:CommitPendingActionGrant(self, actor, candidate, actionGrantReservation)
        actionGrantCommitted = true
        actionGrantReservation = nil
    end
    self:MarkActionCostUsed(actor, candidate)
    local critRefresh = self:ApplyCriticalMainActionRefresh(actor, candidate, symbols, finishOptionsSnapshot)
    if critRefresh ~= nil then
        self:EmitPhase(self.Phase.CritRefreshResolved, {
            context = context,
            actor = actor,
            candidate = candidate,
            symbols = symbols,
            finishOptions = finishOptionsSnapshot,
            granted = critRefresh.granted,
            refreshed = critRefresh.refreshed,
            pending = critRefresh.pending,
            naturalRoll = critRefresh.naturalRoll,
            threshold = critRefresh.threshold,
            runGeneration = context and context.runGeneration,
        })
    end
    self:RecordCandidateExecution(context, candidate)
    self.Ledger:ReconcileGlobalResourceSpend(self, candidate, resourceSnapshot)
    self.Ledger:RefreshContextResources(self, context)
    self:SyncTurnMemoryFromResources(actor)
    self:Trace("resource", "after execution", {
        candidate = candidate.description,
        malice = context and context.malice,
        villainActions = context and context.villainActions,
        actionsUsed = actor.turnMemory and actor.turnMemory.actionsUsed,
        maneuversUsed = actor.turnMemory and actor.turnMemory.maneuversUsed,
        moveActionsUsed = actor.turnMemory and actor.turnMemory.moveActionsUsed,
        turnEnded = actor.turnMemory and actor.turnMemory.turnEnded,
        paid = paid,
        aborted = aborted,
    })

    local executed = FinishExecution(true, "executed")
    AI.Sleep(0.4)
    return executed
end
