local mod = dmhub.GetModLoading()

local AI = rawget(_G, "DirectorTacticsAI")
if AI == nil or AI._internal == nil then
    error("DirectorTacticsAI.lua must be loaded before this DirectorTactics subsystem")
end

local Internal = AI._internal
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local TokenName = Internal.TokenName
local LocKey = Internal.LocKey
local Pick = Internal.Pick
local Lower = Internal.Lower
local CopySymbols = Internal.CopySymbols

local VALID_PROMPT_STATUS = {
    handled = true,
    manual = true,
    blocked = true,
    abort = true,
}

local VALID_PROMPT_CAPABILITY_STATUS = {
    auto = true,
    manual = true,
    blocked = true,
}

local PROMPT_STATUS_CAPABILITY = {
    handled = "auto",
    manual = "manual",
    blocked = "blocked",
    abort = "blocked",
}

local function CopyList(list)
    local result = {}
    if type(list) ~= "table" then
        return result
    end

    for _,entry in ipairs(list) do
        result[#result+1] = entry
    end
    return result
end

local function PromptPolicyId(policy)
    if type(policy) == "table" then
        return policy.id or policy.name or tostring(policy)
    end

    return policy
end

local function PromptPolicyList(args)
    if type(args.policies) == "table" then
        return CopyList(args.policies)
    end

    local policy = PromptPolicyId(args.policy)
    if policy == nil then
        return {}
    end

    return { policy }
end

function AI:MakePromptCapability(args)
    args = args or {}
    local promptStatus = args.promptStatus
    local status = args.status
    if VALID_PROMPT_STATUS[status] and promptStatus == nil then
        promptStatus = status
        status = nil
    end

    if not VALID_PROMPT_CAPABILITY_STATUS[status] then
        status = PROMPT_STATUS_CAPABILITY[promptStatus] or "blocked"
    end

    return {
        status = status,
        promptStatus = promptStatus,
        requiredPrompts = CopyList(args.requiredPrompts),
        optionalPrompts = CopyList(args.optionalPrompts),
        policies = PromptPolicyList(args),
        reasonCode = args.reasonCode or ("prompt_" .. tostring(promptStatus or status)),
        reason = args.reason,
    }
end

function AI:PromptCapabilityFromPromptResult(result, policy, args)
    result = type(result) == "table" and result or {}
    args = args or {}
    return self:MakePromptCapability{
        status = args.status,
        promptStatus = args.promptStatus or result.status,
        requiredPrompts = args.requiredPrompts or result.requiredPrompts,
        optionalPrompts = args.optionalPrompts or result.optionalPrompts,
        policies = args.policies or result.policies,
        policy = args.policy or result.policy or policy,
        reasonCode = args.reasonCode or result.reasonCode,
        reason = args.reason or result.reason,
    }
end

local function PromptAbilityName(ability)
    return tostring(ability and ability.name or "prompt")
end

local function PromptReasonCode(reason, fallback)
    local code = tostring(reason or fallback or "prompt")
    code = string.lower(code)
    code = string.gsub(code, "[^%w]+", "_")
    code = string.gsub(code, "^_+", "")
    code = string.gsub(code, "_+$", "")
    if code == "" then
        code = tostring(fallback or "prompt")
    end
    return code
end

local function PromptResultHasConcreteResolution(result)
    if type(result) ~= "table" then
        return false
    end

    local targetArgs = result.targetArgs
    if type(targetArgs) == "table" and #targetArgs > 0 then
        return true
    end

    local targets = result.targets
    if type(targets) == "table" and #targets > 0 then
        return true
    end

    return result.targetArea ~= nil or result.improvements ~= nil or result.costOverride ~= nil
end

local function NestedPromptSpellName(symbols, options)
    local spellName = TryGet(symbols, "spellname", nil)
    if spellName == nil and options ~= nil then
        spellName = TryGet(TryGet(options, "symbols", nil), "spellname", nil)
    end

    return Lower(spellName or "")
end

local function NestedPromptText(ability)
    local text = TryGet(ability, "promptOverride", nil)
    if text == nil then
        text = TryGet(ability, "promptText", "")
    end

    return Lower(text or "")
end

local function IsFreeStrikePromptName(name)
    name = Lower(name or "")
    return string.find(name, "free strike", 1, true) ~= nil
end

local function IsSpecificTargetFreeStrikePromptName(name)
    name = Lower(name or "")
    return IsFreeStrikePromptName(name)
        and (string.find(name, "specific target", 1, true) ~= nil
            or string.find(name, "vs target", 1, true) ~= nil)
end

local function ParentAbilityName(abilityInfo, ability)
    local name = TryGet(ability, "name", nil)
    if name == nil and abilityInfo ~= nil then
        name = abilityInfo.name
    end
    if name == nil or tostring(name) == "" then
        return nil
    end

    return tostring(name)
end

local function ParentIsStandardGrab(ai, context, options)
    if TryGet(options, "_directorParentIsStandardGrab", false) == true then
        return true
    end

    if ai ~= nil and ai.IsStandardGrabAbilityInfo ~= nil then
        local parentInfo = TryGet(options, "_directorParentAbilityInfo", nil)
        if ai:IsStandardGrabAbilityInfo(parentInfo) then
            return true
        end

        local candidate = context and context.executingCandidate
        if ai:IsStandardGrabAbilityInfo(candidate and candidate.abilityInfo) then
            return true
        end
    end

    return false
end

local function IsGenericInvokePromptName(name)
    name = Lower(name or "")
    name = string.gsub(name, "^%s*(.-)%s*$", "%1")
    return name == "invoked ability"
end

local function IsKnownOptionalFreeStrikePrompt(ai, context, ability, symbols, options)
    local name = Lower(TryGet(ability, "name", "") or "")
    local spellName = NestedPromptSpellName(symbols, options)

    if IsSpecificTargetFreeStrikePromptName(name) and spellName == "grab" then
        return true, "Grab specific-target free strike is optional before Grabbed rider"
    end

    if ParentIsStandardGrab(ai, context, options or {})
        and (IsFreeStrikePromptName(name) or IsGenericInvokePromptName(name))
    then
        return true, "Grab optional nested invoke/free strike uses parent Grab context"
    end

    local promptText = NestedPromptText(ability)
    if TryGet(ability, "skippable", false)
        and IsFreeStrikePromptName(name)
        and string.find(promptText, "skip", 1, true) ~= nil
        and (string.find(promptText, "instead", 1, true) ~= nil
            or string.find(promptText, " or ", 1, true) ~= nil)
    then
        if string.find(promptText, "grab", 1, true) ~= nil then
            return true, "free strike prompt text explicitly skips to grab instead"
        end
    end

    return false, nil
end

function AI:ClassifyNestedPrompt(context, actor, invokerToken, casterToken, abilityClone, symbols, options, result)
    local explicitClass = TryGet(result, "_directorNestedPromptClass", nil)
    if explicitClass == "required" or explicitClass == "auto-resolved" or explicitClass == "optional-child" then
        local reason = TryGet(result, "_directorOptionalNestedReason", "prompt policy classified nested prompt")
        self:Trace("prompt", "nested classified", {
            ability = TryGet(abilityClone, "name", "prompt"),
            class = explicitClass,
            reason = reason,
        })
        return explicitClass, reason
    end

    local optional, reason = IsKnownOptionalFreeStrikePrompt(self, context, abilityClone, symbols or {}, options or {})
    if optional then
        self:Trace("prompt", "nested classified", {
            ability = TryGet(abilityClone, "name", "prompt"),
            class = "optional-child",
            reason = reason,
        })
        return "optional-child", reason
    end

    if PromptResultHasConcreteResolution(result) then
        self:Trace("prompt", "nested classified", {
            ability = TryGet(abilityClone, "name", "prompt"),
            class = "auto-resolved",
            reason = "prompt policy supplied concrete resolution",
        })
        return "auto-resolved", "prompt policy supplied concrete resolution"
    end

    self:Trace("prompt", "nested classified", {
        ability = TryGet(abilityClone, "name", "prompt"),
        class = "required",
        reason = "nested prompt is mandatory by default",
    })
    return "required", "nested prompt is mandatory by default"
end

local function PromptManualPolicyStatus(ai)
    return Pick(ai.config and ai.config.manualPrompts, "manual", "blocked")
end

local function CandidateAbility(ai, abilityInfo, candidate)
    return (candidate and candidate.ability) or (abilityInfo and abilityInfo.ability)
end

local function CandidateTargets(ai, candidate)
    if candidate == nil then
        return {}
    end

    if ai.CandidateTargets ~= nil then
        return ai:CandidateTargets(candidate) or {}
    end

    return candidate.targets or {}
end

local function CandidateTargetArea(ai, candidate)
    if candidate == nil then
        return nil
    end

    if ai.CandidateTargetArea ~= nil then
        return ai:CandidateTargetArea(candidate)
    end

    return candidate.targetArea
end

local function CandidateSymbols(ai, candidate)
    if candidate == nil then
        return {}
    end

    if ai.CandidateExecutionSymbols ~= nil then
        return ai:CandidateExecutionSymbols(candidate) or {}
    end

    return candidate.symbols or {}
end

local function PromptPolicyFromResolution(resolution)
    return resolution and resolution.policy and PromptPolicyId(resolution.policy) or nil
end

local function PromptEntry(ai, behavior, promptAbility, args)
    args = args or {}
    return {
        ability = PromptAbilityName(promptAbility),
        behavior = ai.PromptInvokeBehaviorDisplayName ~= nil and ai:PromptInvokeBehaviorDisplayName(behavior) or nil,
        class = args.class,
        status = args.status,
        policy = args.policy,
        reason = args.reason,
    }
end

local function AppendPolicy(policies, policy)
    if policy ~= nil then
        policies[#policies+1] = policy
    end
end

local function AppendPrompt(list, entry)
    list[#list+1] = entry
end

local function BuildNestedPromptOptions(ai, candidate, symbols, abilityInfo, ability, behavior)
    local candidateTargets = CandidateTargets(ai, candidate)
    local candidateTargetArea = CandidateTargetArea(ai, candidate)
    local parentName = ParentAbilityName(abilityInfo, ability)
    symbols = symbols or {}
    if symbols.spellname == nil and parentName ~= nil then
        symbols.spellname = parentName
    end

    local promptOptions = {
        symbols = CopySymbols(symbols or {}),
        targets = candidateTargets,
        targetArgs = candidateTargets,
        targetArea = TryGet(symbols, "targetArea", nil) or candidateTargetArea,
        _directorCandidateTargets = candidateTargets,
        _directorPromptPreflight = true,
        _directorParentAbilityName = parentName,
        _directorParentAbilityInfo = abilityInfo,
        _directorParentIsStandardGrab = ai.IsStandardGrabAbilityInfo ~= nil and ai:IsStandardGrabAbilityInfo(abilityInfo) or false,
        _directorPromptBehavior = behavior,
    }

    return promptOptions, candidateTargets
end

local function NestedPromptParentTargets(candidateTargets)
    if type(candidateTargets) == "table" and #candidateTargets > 0 then
        return candidateTargets
    end

    return { {} }
end

local function MergeNestedCapability(ai, context, actor, abilityInfo, candidate, resolvePolicies)
    local requiredPrompts = {}
    local optionalPrompts = {}
    local policies = {}
    local ability = CandidateAbility(ai, abilityInfo, candidate)
    local behaviors = TryGet(ability, "behaviors", {}) or {}

    for _,behavior in ipairs(behaviors) do
        if TryGet(behavior, "typeName", "") == "ActivatedAbilityInvokeAbilityBehavior"
            and ai.PromptInvokeBehaviorIsPrompted ~= nil
            and ai:PromptInvokeBehaviorIsPrompted(behavior)
        then
            local promptAbility = ai.PromptInvokeAbility and ai:PromptInvokeAbility(behavior) or nil
            local abilityName = tostring(promptAbility and promptAbility.name
                or (ai.PromptInvokeBehaviorDisplayName ~= nil and ai:PromptInvokeBehaviorDisplayName(behavior) or nil)
                or (ai.PromptInvokeBehaviorName ~= nil and ai:PromptInvokeBehaviorName(behavior) or nil)
                or "prompt")
            local symbols = CopySymbols(CandidateSymbols(ai, candidate))
            local promptOptions, candidateTargets = BuildNestedPromptOptions(ai, candidate, symbols, abilityInfo, ability, behavior)
            local promptClass, promptClassReason = ai:ClassifyNestedPrompt(context, actor, actor and actor.token, actor and actor.token, promptAbility, symbols, promptOptions)

            if promptClass == "optional-child" then
                AppendPrompt(optionalPrompts, PromptEntry(ai, behavior, promptAbility, {
                    class = promptClass,
                    status = "auto",
                    reason = promptClassReason,
                }))
            elseif promptAbility == nil then
                AppendPrompt(requiredPrompts, PromptEntry(ai, behavior, promptAbility, {
                    class = "required",
                    status = "blocked",
                    reason = abilityName .. ": missing nested prompt ability",
                }))
                return ai:MakePromptCapability{
                    status = "blocked",
                    promptStatus = "blocked",
                    requiredPrompts = requiredPrompts,
                    optionalPrompts = optionalPrompts,
                    policies = policies,
                    reasonCode = "missing_nested_prompt_ability",
                    reason = abilityName .. ": missing nested prompt ability",
                }
            elseif resolvePolicies == true then
                for _,parentTarget in ipairs(NestedPromptParentTargets(candidateTargets)) do
                    local promptCaster = actor and actor.token
                    if not TryGet(behavior, "invokeOnCaster", false) then
                        promptCaster = parentTarget and parentTarget.token
                    end

                    if promptCaster == nil then
                        AppendPrompt(requiredPrompts, PromptEntry(ai, behavior, promptAbility, {
                            class = "required",
                            status = "blocked",
                            reason = abilityName .. ": missing nested prompt caster",
                        }))
                        return ai:MakePromptCapability{
                            status = "blocked",
                            promptStatus = "blocked",
                            requiredPrompts = requiredPrompts,
                            optionalPrompts = optionalPrompts,
                            policies = policies,
                            reasonCode = "missing_nested_prompt_caster",
                            reason = abilityName .. ": missing nested prompt caster",
                        }
                    end

                    local targeting = TryGet(behavior, "targeting", "prompt")
                    if targeting == "formula" or targeting == "prompt_inherit" then
                        promptOptions.targetingFormula = TryGet(behavior, "targetingFormula", "")
                    end

                    local previousCandidate = context and context.executingCandidate
                    if context ~= nil then
                        context.executingCandidate = candidate
                    end
                    local resolution = ai:ResolvePromptV2(context, actor, actor and actor.token, promptCaster, promptAbility, symbols, promptOptions)
                    if context ~= nil then
                        context.executingCandidate = previousCandidate
                    end

                    local policyId = PromptPolicyFromResolution(resolution)
                    AppendPolicy(policies, policyId)

                    if resolution ~= nil and resolution.status == "handled" then
                        local resolvedClass, resolvedReason = ai:ClassifyNestedPrompt(context, actor, actor and actor.token, promptCaster, promptAbility, symbols, promptOptions, resolution.options)
                        local list = Pick(resolvedClass == "optional-child", optionalPrompts, requiredPrompts)
                        AppendPrompt(list, PromptEntry(ai, behavior, promptAbility, {
                            class = resolvedClass,
                            status = "auto",
                            policy = policyId,
                            reason = resolvedReason,
                        }))
                    else
                        local unresolvedClass, unresolvedReason = ai:ClassifyNestedPrompt(context, actor, actor and actor.token, promptCaster, promptAbility, symbols, promptOptions)
                        local reason = resolution and resolution.reason or "no automated prompt policy"
                        if unresolvedClass == "optional-child" then
                            AppendPrompt(optionalPrompts, PromptEntry(ai, behavior, promptAbility, {
                                class = unresolvedClass,
                                status = "auto",
                                policy = policyId,
                                reason = reason or unresolvedReason,
                            }))
                        else
                            AppendPrompt(requiredPrompts, PromptEntry(ai, behavior, promptAbility, {
                                class = "required",
                                status = "blocked",
                                policy = policyId,
                                reason = reason,
                            }))
                            return ai:MakePromptCapability{
                                status = "blocked",
                                promptStatus = (resolution and resolution.status == "abort") and "abort" or "blocked",
                                requiredPrompts = requiredPrompts,
                                optionalPrompts = optionalPrompts,
                                policies = policies,
                                reasonCode = resolution and resolution.reasonCode or PromptReasonCode(reason, "nested_prompt_blocked"),
                                reason = abilityName .. ": " .. tostring(reason),
                            }
                        end
                    end
                end
            elseif ai.IsSafeAutoPromptInvokeBehavior ~= nil and ai:IsSafeAutoPromptInvokeBehavior(behavior, context, actor) then
                AppendPrompt(requiredPrompts, PromptEntry(ai, behavior, promptAbility, {
                    class = "required",
                    status = "auto",
                    reason = "nested prompt has automated preflight policy",
                }))
            else
                local reason = "nested prompt: " .. tostring(abilityName)
                AppendPrompt(requiredPrompts, PromptEntry(ai, behavior, promptAbility, {
                    class = "required",
                    status = "blocked",
                    reason = reason,
                }))
                return ai:MakePromptCapability{
                    status = "blocked",
                    promptStatus = "blocked",
                    requiredPrompts = requiredPrompts,
                    optionalPrompts = optionalPrompts,
                    policies = policies,
                    reasonCode = "nested_prompt_unresolved",
                    reason = reason,
                }
            end
        end
    end

    return ai:MakePromptCapability{
        status = "auto",
        requiredPrompts = requiredPrompts,
        optionalPrompts = optionalPrompts,
        policies = policies,
        reasonCode = Pick(#requiredPrompts > 0 or #optionalPrompts > 0, "prompt_capability_auto", "no_prompt_risk"),
        reason = Pick(#requiredPrompts > 0 or #optionalPrompts > 0, "prompt capability preflight passed", "no prompt risk"),
    }
end

function AI:AssessPromptCapability(context, actor, abilityInfo, candidate)
    abilityInfo = abilityInfo or (candidate and candidate.abilityInfo)
    candidate = candidate or {}

    local preflight = TryGet(candidate, "_directorPromptPreflight", false) == true
    if preflight then
        return MergeNestedCapability(self, context, actor, abilityInfo, candidate, true)
    end

    if abilityInfo == nil then
        local status = PromptManualPolicyStatus(self)
        return self:MakePromptCapability{
            status = status,
            promptStatus = status,
            reasonCode = "manual_targeting",
            reason = "manual targeting",
        }
    end

    local manualReason = nil
    if abilityInfo.hasSummon then
        manualReason = "summon placement"
    elseif self.IsSpecialMaliceFeature ~= nil
        and self:IsSpecialMaliceFeature(abilityInfo)
        and not (self.IsSoloActionName ~= nil and self:IsSoloActionName(abilityInfo.name))
        and not (self.IsAutomatableStartTurnMaliceAbility ~= nil and self:IsAutomatableStartTurnMaliceAbility(abilityInfo))
    then
        manualReason = "special malice feature"
    elseif self.AbilityUsesManualPromptTargeting ~= nil and self:AbilityUsesManualPromptTargeting(abilityInfo) then
        manualReason = "non-creature targeting"
    end

    if manualReason ~= nil then
        local status = PromptManualPolicyStatus(self)
        return self:MakePromptCapability{
            status = status,
            promptStatus = status,
            reasonCode = PromptReasonCode(manualReason, "manual_prompt"),
            reason = manualReason,
        }
    end

    if self.IsAdvanceAbilityInfo ~= nil and self:IsAdvanceAbilityInfo(abilityInfo) then
        return self:MakePromptCapability{
            status = "auto",
            reasonCode = "advance_prompt_safe",
            reason = "advance prompt is automated",
        }
    end

    if self.IsDirectorMovementPromptAbility ~= nil
        and self:IsDirectorMovementPromptAbility(abilityInfo.ability)
        and self.AbilityUsesNonCreatureTargeting ~= nil
        and self:AbilityUsesNonCreatureTargeting(abilityInfo)
    then
        return self:MakePromptCapability{
            status = "blocked",
            promptStatus = "blocked",
            reasonCode = "movement_prompt_not_automated",
            reason = "movement/charge prompt is not automated",
        }
    end

    local modePromptReason = self.AbilityUnresolvedModePromptReason ~= nil
        and self:AbilityUnresolvedModePromptReason(abilityInfo)
        or nil
    if modePromptReason ~= nil then
        return self:MakePromptCapability{
            status = "blocked",
            promptStatus = "blocked",
            reasonCode = "unresolved_mode_prompt",
            reason = modePromptReason,
        }
    end

    if abilityInfo.requiresPrompt
        and not abilityInfo.manualPromptRisk
        and not (self.IsAutoResolvableGrabModePrompt ~= nil and self:IsAutoResolvableGrabModePrompt(abilityInfo))
        and not (self.IsAutoResolvableForcedMovementModePrompt ~= nil and self:IsAutoResolvableForcedMovementModePrompt(abilityInfo))
    then
        return self:MakePromptCapability{
            status = "blocked",
            promptStatus = "blocked",
            reasonCode = "unresolved_required_prompt",
            reason = "unresolved prompt",
        }
    end

    return MergeNestedCapability(self, context, actor, abilityInfo, candidate, false)
end

local function PromptTargetSummary(options)
    if type(options) ~= "table" then
        return nil
    end

    local parts = {}
    local targets = options.targetArgs or options.targets
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
                parts[#parts+1] = string.format("%s@%s", TokenName(token), LocKey(loc or TryGet(token, "loc", nil)))
            elseif loc ~= nil then
                parts[#parts+1] = LocKey(loc)
            elseif type(target) == "table" and TryGet(target, "str", nil) ~= nil then
                parts[#parts+1] = LocKey(target)
            end
        end
    end

    local targetArea = TryGet(options, "targetArea", nil)
    if targetArea ~= nil and #parts < 3 then
        parts[#parts+1] = "area@" .. LocKey(TryGet(targetArea, "origin", nil))
    end

    if #parts == 0 then
        return nil
    end

    return table.concat(parts, ",")
end

local function NormalizePolicyResult(result, policy)
    if type(result) ~= "table" then
        return nil
    end

    if type(result.status) == "string" then
        local status = result.status
        if VALID_PROMPT_STATUS[status] then
            if status == "handled" then
                result.options = result.options or result.result
                result.policy = result.policy or policy
            end
            return result
        end

        return {
            status = "abort",
            reason = "invalid prompt status: " .. tostring(status),
            policy = policy,
        }
    end

    return {
        status = "handled",
        options = result,
        policy = policy,
    }
end

function AI:ResolvePromptV2(a, b, c, d, e, f, g)
    local context, actor, invokerToken, casterToken, abilityClone, symbols, options
    if e ~= nil or f ~= nil or g ~= nil then
        context = a
        actor = b
        invokerToken = c
        casterToken = d
        abilityClone = e
        symbols = f
        options = g
    else
        abilityClone = a
        symbols = b
        options = c
        context = d or {}
        actor = context.actor
        invokerToken = context.invokerToken
        casterToken = context.casterToken
    end

    symbols = symbols or {}
    options = options or {}

    self:Trace("prompt", "resolve start", {
        ability = PromptAbilityName(abilityClone),
        actor = actor and actor.token and Internal.TokenName(actor.token),
        invoker = invokerToken and Internal.TokenName(invokerToken),
        caster = casterToken and Internal.TokenName(casterToken),
        targetType = abilityClone and Internal.TryGet(abilityClone, "targetType", nil),
    })

    local checked = 0
    local matched = 0
    local firstMatchedPolicy = nil
    for _,policy in ipairs(self.promptPolicies or {}) do
        checked = checked + 1
        local ok = true
        if policy.matches ~= nil then
            ok = SafeCall(function()
                return policy.matches(self, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            end, false)
        end

        if ok then
            matched = matched + 1
            firstMatchedPolicy = firstMatchedPolicy or policy.id
        end

        if ok and policy.choose ~= nil then
            local rawResult = SafeCall(function()
                return policy.choose(self, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            end, nil)

            local resolution = NormalizePolicyResult(rawResult, policy)
            if resolution ~= nil then
                resolution.policy = resolution.policy or policy
                if self.PromptCapabilityFromPromptResult ~= nil then
                    resolution.promptCapability = resolution.promptCapability
                        or self:PromptCapabilityFromPromptResult(resolution, resolution.policy)
                end
                self:Trace("prompt", "policy result", {
                    ability = PromptAbilityName(abilityClone),
                    policy = policy.id,
                    status = resolution.status,
                    reason = resolution.reason,
                    targets = PromptTargetSummary(resolution.options),
                })

                if resolution.status == "handled" then
                    local valid, reason = self:ValidatePromptResult(context, actor, invokerToken, casterToken, abilityClone, symbols, options, resolution.options)
                    self:Trace("prompt", "validation result", {
                        ability = PromptAbilityName(abilityClone),
                        policy = policy.id,
                        valid = valid,
                        reason = reason,
                        targets = PromptTargetSummary(resolution.options),
                    })
                    if valid then
                        return resolution
                    end

                    self:Log(string.format("Prompt policy %s could not resolve %s: %s", tostring(policy.id or "?"), PromptAbilityName(abilityClone), tostring(reason)))
                else
                    resolution.reason = resolution.reason or tostring(policy.id or "prompt policy")
                    return resolution
                end
            elseif ok then
                self:Trace("prompt", "policy returned no resolution", {
                    ability = PromptAbilityName(abilityClone),
                    policy = policy.id,
                })
                self:Log(string.format("Prompt policy %s returned no resolution for %s", tostring(policy.id or "?"), PromptAbilityName(abilityClone)))
            end
        end
    end

    self:Trace("prompt", "blocked", {
        ability = PromptAbilityName(abilityClone),
        reason = "no automated prompt policy",
        checked = checked,
        matched = matched,
        firstMatched = firstMatchedPolicy,
    })
    local blocked = {
        status = "blocked",
        reason = "no automated prompt policy",
    }
    if self.PromptCapabilityFromPromptResult ~= nil then
        blocked.promptCapability = self:PromptCapabilityFromPromptResult(blocked, nil, {
            reasonCode = "no_automated_prompt_policy",
        })
    end
    return blocked
end

function AI:ResolvePromptPolicy(context, actor, invokerToken, casterToken, abilityClone, symbols, options)
    local resolution = self:ResolvePromptV2(context, actor, invokerToken, casterToken, abilityClone, symbols, options)
    if resolution ~= nil and resolution.status == "handled" then
        return resolution.options, resolution.policy
    end

    return nil, nil
end
