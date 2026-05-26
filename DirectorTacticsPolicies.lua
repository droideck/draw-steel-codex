local mod = dmhub.GetModLoading()

-- DirectorTacticsPolicies.lua registers built-in role profiles, active objectives, ability rules, prompt policies, and trigger policies.
-- Load after DirectorTacticsAutomation.lua and before DirectorTacticsPanel.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsPolicies.lua")
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
local TokenId = Internal.TokenId
local TokensFriendly = Internal.TokensFriendly
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local IsTokenValid = Internal.IsTokenValid
local TokenId = Internal.TokenId
local CurrentStamina = Internal.CurrentStamina
local MaxStamina = Internal.MaxStamina
local AbilityRange = Internal.AbilityRange
local HasLineOfSight = Internal.HasLineOfSight
local CopySymbols = Internal.CopySymbols
local ConstNumber = Internal.ConstNumber

local function HandledPrompt(options)
    return {
        status = "handled",
        options = options,
    }
end

local function ManualOrBlockedPrompt(ai, reason)
    return {
        status = Pick(ai.config.manualPrompts, "manual", "blocked"),
        reason = reason,
    }
end

local function PromptActor(actor, casterToken, context)
    return {
        token = casterToken,
        role = actor and actor.role,
        organization = actor and actor.organization,
        profile = actor and actor.profile,
        allies = actor and actor.allies or {},
        enemies = actor and actor.enemies or {},
        context = context,
    }
end

local function IsSpecificTargetFreeStrikeName(name)
    name = Lower(name or "")
    return string.find(name, "free strike", 1, true) ~= nil
        and (string.find(name, "specific target", 1, true) ~= nil
            or string.find(name, "vs target", 1, true) ~= nil)
end

local function AidAttackHasAllyPayoff(actor, targetToken)
    if actor == nil or targetToken == nil then
        return false
    end

    for _,ally in ipairs(actor.allies or {}) do
        if IsTokenValid(ally) and Distance(ally, targetToken) <= 1.1 then
            return true
        end
    end

    return false
end

local function TokenByAnyId(id)
    if id == nil or dmhub == nil then
        return nil
    end

    id = tostring(id)
    for _,tok in ipairs(dmhub.allTokens or {}) do
        if IsTokenValid(tok)
            and (tostring(TokenId(tok) or "") == id
                or tostring(TryGet(tok, "id", "") or "") == id
                or tostring(TryGet(tok, "charid", "") or "") == id)
        then
            return tok
        end
    end

    return SafeCall(function()
        return dmhub.GetTokenById(id)
    end, nil)
end

local function TokenFromValue(value)
    if value == nil then
        return nil
    end

    if type(value) == "function" then
        value = SafeCall(function()
            return value("self")
        end, value)
    end

    if IsTokenValid(value) then
        return value
    end

    local token = SafeCall(function()
        return dmhub.LookupToken(value)
    end, nil)
    if IsTokenValid(token) then
        return token
    end

    local id = TryGet(value, "charid", TryGet(value, "id", nil))
    return TokenByAnyId(id or value)
end

local function ExtractSpecificTargetId(text)
    if type(text) ~= "string" then
        return nil
    end

    return string.match(text, "[Tt]arget%.id%s*=%s*\"([^\"]+)\"")
        or string.match(text, "[Tt]arget%.id%s*=%s*'([^']+)'")
        or string.match(text, "[Tt]arget%.id%s*=%s*([%w%-]+)")
end

local function AddSpecificTarget(result, seen, token)
    if not IsTokenValid(token) then
        return
    end

    local id = TokenId(token) or tostring(token)
    if seen[id] then
        return
    end

    seen[id] = true
    result[#result+1] = { token = token }
end

local function ResolveSpecificTargetFreeStrikeTargets(abilityClone, symbols, options)
    local result = {}
    local seen = {}

    local function AddTargetsFromList(list)
        if type(list) ~= "table" then
            return
        end

        for _,target in ipairs(list) do
            AddSpecificTarget(result, seen, target and target.token)
        end
    end

    AddTargetsFromList(TryGet(options, "targets", nil))
    AddTargetsFromList(TryGet(options, "targetArgs", nil))

    AddSpecificTarget(result, seen, TokenFromValue(TryGet(symbols, "target", nil)))
    AddSpecificTarget(result, seen, TokenFromValue(TryGet(options and options.symbols, "target", nil)))
    AddSpecificTarget(result, seen, TokenByAnyId(TryGet(symbols, "targetid", TryGet(options and options.symbols, "targetid", nil))))

    local formula = TryGet(abilityClone, "targetingFormula", TryGet(options, "targetingFormula", nil))
    AddSpecificTarget(result, seen, TokenByAnyId(ExtractSpecificTargetId(formula)))

    return result
end

local function ResolveInheritedFollowUpTargets(ai, context, invokerToken, symbols, options)
    local result = {}
    local seen = {}

    local function AddTargetsFromList(list)
        if type(list) ~= "table" then
            return
        end

        for _,target in ipairs(list) do
            AddSpecificTarget(result, seen, target and target.token or target)
        end
    end

    symbols = symbols or {}
    options = options or {}
    AddTargetsFromList(TryGet(options, "targets", nil))
    AddTargetsFromList(TryGet(options, "targetArgs", nil))
    AddTargetsFromList(TryGet(options, "_directorCandidateTargets", nil))
    AddTargetsFromList(TryGet(symbols, "targets", nil))
    AddTargetsFromList(TryGet(options and options.symbols, "targets", nil))

    local executingCandidate = context and context.executingCandidate
    if executingCandidate ~= nil then
        AddTargetsFromList(ai.CandidateTargets and ai:CandidateTargets(executingCandidate) or executingCandidate.targets)
    end

    AddSpecificTarget(result, seen, TokenFromValue(TryGet(symbols, "target", nil)))
    AddSpecificTarget(result, seen, TokenFromValue(TryGet(options and options.symbols, "target", nil)))
    AddSpecificTarget(result, seen, TokenByAnyId(TryGet(symbols, "targetid", TryGet(options and options.symbols, "targetid", nil))))

    local invokerId = tostring(TryGet(invokerToken, "charid", TryGet(invokerToken, "id", "")) or "")
    local targetPairs = TryGet(symbols, "targetPairs", TryGet(options and options.symbols, "targetPairs", {})) or {}
    for _,pair in ipairs(targetPairs) do
        if tostring(pair.a or "") == invokerId and pair.b ~= nil then
            AddSpecificTarget(result, seen, TokenByAnyId(pair.b))
        end
    end

    return result
end

local function FollowUpTokenKey(token)
    if token == nil then
        return ""
    end

    return tostring(TokenId(token) or TryGet(token, "charid", TryGet(token, "id", "")) or "")
end

local function FollowUpTargetableEntry(targetableSet, targetToken)
    if targetableSet == nil or targetToken == nil then
        return nil
    end

    for _,entry in ipairs(targetableSet) do
        if entry ~= nil and (entry.token == targetToken or FollowUpTokenKey(entry.token) == FollowUpTokenKey(targetToken)) then
            return entry
        end
    end

    return nil
end

local function AddFollowUpPoolToken(pool, seen, value)
    local token = value
    if type(value) == "table" and value.token ~= nil then
        token = value.token
    else
        token = TokenFromValue(value)
    end

    if not IsTokenValid(token) then
        return
    end

    local key = FollowUpTokenKey(token)
    if key == "" or seen[key] then
        return
    end

    seen[key] = true
    pool[#pool+1] = token
end

local function AddFollowUpPoolList(pool, seen, list)
    if type(list) ~= "table" then
        return
    end

    for _,entry in ipairs(list) do
        AddFollowUpPoolToken(pool, seen, entry)
    end
end

local function BuildFollowUpFallbackPool(context, actor, inheritedTargets, targetPairs)
    local pool = {}
    local seen = {}

    AddFollowUpPoolList(pool, seen, context and context.allCombatTokens)
    AddFollowUpPoolList(pool, seen, actor and actor.allies)
    AddFollowUpPoolList(pool, seen, actor and actor.enemies)
    AddFollowUpPoolList(pool, seen, inheritedTargets)

    for _,pair in ipairs(targetPairs or {}) do
        AddFollowUpPoolToken(pool, seen, TokenByAnyId(pair and pair.a))
        AddFollowUpPoolToken(pool, seen, TokenByAnyId(pair and pair.b))
    end

    return pool
end

local function FollowUpBlocked(reason)
    return {
        status = "blocked",
        reason = reason,
    }
end

local function MovementPromptFlags(abilityClone)
    local name = Lower(TryGet(abilityClone, "name", "") or "")
    if string.find(name, "shift", 1, true) ~= nil then
        return { "shift" }
    end

    if string.find(name, "jump", 1, true) ~= nil then
        return { "jump" }
    end

    if string.find(name, "teleport", 1, true) ~= nil then
        return { "teleport" }
    end

    if string.find(name, "dig", 1, true) ~= nil or string.find(name, "burrow", 1, true) ~= nil then
        return { "burrow" }
    end

    return {}
end

local function MovementPromptRange(abilityClone, casterToken, symbols)
    local range = AbilityRange(abilityClone, casterToken, symbols)
    if range ~= nil and range > 0 then
        return range
    end

    local speed = SafeCall(function()
        return casterToken.properties:CurrentMovementSpeed()
    end, 0) or 0
    local moved = SafeCall(function()
        return casterToken.properties:DistanceMovedThisTurn()
    end, 0) or 0
    return math.max(0, speed - moved)
end

local function ChooseMovementPromptDestination(ai, context, actor, casterToken, abilityClone, symbols, options)
    local function CurrentLocIfClear()
        if casterToken == nil or casterToken.loc == nil then
            return nil
        end

        local clear = true
        if ai.IsMovementDestinationClear ~= nil then
            clear = ai:IsMovementDestinationClear(context, casterToken, casterToken.loc)
        end
        if clear and (ai.MovementAllowedByFrightened == nil or ai:MovementAllowedByFrightened(context, casterToken, casterToken.loc)) then
            return casterToken.loc
        end
    end

    if options ~= nil and options._directorAdvanceLoc ~= nil then
        local clear = true
        if ai.IsMovementDestinationClear ~= nil then
            clear = ai:IsMovementDestinationClear(context, casterToken, options._directorAdvanceLoc)
        end
        if clear and (ai.MovementAllowedByFrightened == nil or ai:MovementAllowedByFrightened(context, casterToken, options._directorAdvanceLoc)) then
            return options._directorAdvanceLoc
        end
    end

    local range = MovementPromptRange(abilityClone, casterToken, symbols)
    if options ~= nil then
        options._directorPromptMovementRange = range
    end
    if range <= 0 then
        if options ~= nil then
            options._directorPromptMovementReason = "no movement remaining"
        end
        return CurrentLocIfClear()
    end

    local flags = MovementPromptFlags(abilityClone)
    local paths = SafeCall(function()
        return casterToken:CalculatePathfindingArea(range * 10, flags)
    end, nil)
    if paths == nil and #flags > 0 then
        paths = SafeCall(function()
            return casterToken:CalculatePathfindingArea(range * 10, {})
        end, nil)
    end

    if paths == nil then
        return CurrentLocIfClear()
    end

    local promptActor = PromptActor(actor, casterToken, context)
    local bestLoc = nil
    local bestScore = nil
    local target = promptActor.enemies and promptActor.enemies[1] or nil

    for _,info in pairs(paths) do
        local loc = info and info.loc
        if loc ~= nil then
            local clear = true
            if ai.IsMovementDestinationClear ~= nil then
                clear = ai:IsMovementDestinationClear(context, casterToken, loc)
            end

            if clear and (ai.MovementAllowedByFrightened == nil or ai:MovementAllowedByFrightened(context, casterToken, loc)) then
                local scoreInfo = ai:PositionScore(promptActor, loc, nil, target)
                if ai.AddMovementHazardScore ~= nil then
                    ai:AddMovementHazardScore(scoreInfo, casterToken, info, false, context)
                end
                local movementCost = tonumber(TryGet(info, "cost", 0)) or 0
                local distance = LocDistance(casterToken.loc, loc)
                local score = scoreInfo.total - movementCost * 0.002 - math.max(0, distance - range) * 0.5
                if bestLoc == nil or score > bestScore then
                    bestLoc = loc
                    bestScore = score
                    if options ~= nil then
                        options._directorPromptMovementReason = Pick(distance <= 0.01, "current location", "best scored destination")
                    end
                end
            end
        end
    end

    local fallback = CurrentLocIfClear()
    if bestLoc == nil and options ~= nil and fallback ~= nil then
        options._directorPromptMovementReason = "fallback current location"
    end
    return bestLoc or fallback
end

local function ActiveTriggerText(trigger)
    return Lower(SafeCall(function()
        return trigger:GetText()
    end, TryGet(trigger, "text", "")) or "")
end

local function StripCostSuffix(text)
    return string.gsub(text or "", "%s*%([^%)]*%)%s*$", "")
end

local function TriggerEvents(info, ids)
    if info == nil or info.event == nil then
        return false
    end

    for _,id in ipairs(ids or {}) do
        if info.event == id then
            return true
        end
    end

    return false
end

function AI:ResolveActiveTriggerInfo(token, trigger)
    if token == nil or trigger == nil or token.properties == nil then
        return nil
    end

    local triggerText = ActiveTriggerText(trigger)
    local strippedText = StripCostSuffix(triggerText)
    local entries = SafeCall(function()
        return token.properties:GetTriggeredAbilities()
    end, {}) or {}

    local fallback = nil
    for _,entry in ipairs(entries) do
        local ability = entry and entry.ability
        local abilityName = Lower(TryGet(ability, "name", ""))
        if ability ~= nil and abilityName ~= "" then
            if abilityName == triggerText or abilityName == strippedText then
                local mandatory = SafeCall(function()
                    return ability:IsMandatory(token)
                end, TryGet(ability, "mandatory", false) == true)
                return {
                    entry = entry,
                    ability = ability,
                    modifier = entry.modifier,
                    event = TryGet(ability, "trigger", nil),
                    mandatory = mandatory == true,
                    available = entry.available ~= false,
                    resources = entry.resources,
                }
            end

            if fallback == nil and string.find(triggerText, abilityName, 1, true) ~= nil then
                fallback = entry
            end
        end
    end

    if fallback ~= nil and fallback.ability ~= nil then
        local ability = fallback.ability
        local mandatory = SafeCall(function()
            return ability:IsMandatory(token)
        end, TryGet(ability, "mandatory", false) == true)
        return {
            entry = fallback,
            ability = ability,
            modifier = fallback.modifier,
            event = TryGet(ability, "trigger", nil),
            mandatory = mandatory == true,
            available = fallback.available ~= false,
            resources = fallback.resources,
        }
    end

    return nil
end

function AI:TriggerCanAutoActivate(token, trigger, info)
    if not self:ReactiveTriggersEnabled() or trigger == nil or trigger.triggered or trigger.dismissed then
        return false
    end

    if self.TargetHasCondition ~= nil and self:TargetHasCondition(token, "Dazed") then
        return false
    end

    if info ~= nil and info.available == false then
        return false
    end

    local heroicCost = tonumber(TryGet(trigger, "heroicResourceCost", 0)) or 0
    if heroicCost > 0 then
        local available = SafeCall(function()
            return token.properties:GetHeroicOrMaliceResourcesAvailableToSpend()
        end, 0) or 0
        if available < heroicCost then
            return false
        end
    end

    local epicCost = tonumber(TryGet(trigger, "epicResourceCost", 0)) or 0
    if epicCost > 0 then
        local available = SafeCall(function()
            return token.properties:GetEpicResources()
        end, 0) or 0
        if available < epicCost then
            return false
        end
    end

    return true
end

function AI:TriggerPolicyScore(baseScore, token, trigger, context, info)
    local score = baseScore or 1
    if info ~= nil and info.mandatory then
        score = score + 3
    end
    score = score - (tonumber(TryGet(trigger, "heroicResourceCost", 0)) or 0) * 0.5
    score = score - (tonumber(TryGet(trigger, "epicResourceCost", 0)) or 0)
    return score
end

function AI:ActivateAvailableTrigger(token, trigger, label)
    if token == nil or token.properties == nil or trigger == nil or trigger.triggered or trigger.dismissed then
        return false
    end

    trigger.triggered = true
    trigger.dismissed = SafeCall(function()
        return trigger:DismissOnTrigger()
    end, TryGet(trigger, "dismissOnTrigger", false) == true) == true
    token.properties:DispatchAvailableTrigger(trigger)
    self:Log(tostring(label or "Trigger") .. ": " .. TokenName(token) .. " - " .. tostring(TryGet(trigger, "text", "trigger")))
    return true
end

local function TriggerPolicy(args)
    AI:RegisterTriggerPolicy{
        id = args.id,
        matches = function(ai, token, trigger, context, info)
            return ai:TriggerCanAutoActivate(token, trigger, info) and TriggerEvents(info, args.events)
        end,
        score = function(ai, token, trigger, context, info)
            return ai:TriggerPolicyScore(args.score or 5, token, trigger, context, info)
        end,
        execute = function(ai, token, trigger)
            return ai:ActivateAvailableTrigger(token, trigger, args.label)
        end,
    }
end

local function ImprovementCost(ai, casterToken, improvement)
    local mod = improvement and improvement.mod
    if mod == nil or casterToken == nil or casterToken.properties == nil then
        return nil
    end

    local costType = TryGet(mod, "resourceCostType", "none")
    if costType == nil or costType == "none" then
        return 0, "none"
    end

    local amount = SafeCall(function()
        return ExecuteGoblinScript(TryGet(mod, "resourceCostAmount", "1"), casterToken.properties:LookupSymbol{}, 1)
    end, 1) or 1
    amount = math.max(0, math.floor(tonumber(amount) or 0))

    local available = 0
    if costType == "epic" then
        available = SafeCall(function()
            return casterToken.properties:GetEpicResources()
        end, 0) or 0
    else
        available = SafeCall(function()
            return casterToken.properties:GetHeroicOrMaliceResourcesAvailableToSpend()
        end, 0) or 0
    end

    if available < amount then
        return nil, costType
    end

    return amount, costType
end

local function CopyImprovementEntry(entry, checked)
    local result = {}
    for k,v in pairs(entry or {}) do
        result[k] = v
    end
    result.checked = checked == true
    return result
end

local function RegisterDefaults()
    if AI._tmp_defaultsRegisteredVersion == AI.version then
        return
    end
    AI._tmp_defaultsRegistered = true
    AI._tmp_defaultsRegisteredVersion = AI.version
    AI.abilityRules = {}
    AI.promptPolicies = {}
    AI.triggerPolicies = {}
    AI.tacticRules = {}

    AI:RegisterRoleProfile{ id = "standard", desiredRange = 1, rangeWeight = 0.25, flankWeight = 1.4, doctrine = "balanced" }
    AI:RegisterRoleProfile{ id = "ambusher", desiredRange = 1, rangeWeight = 0.35, flankWeight = ConstNumber("Tactic", "AmbusherFlankWeight", 2.4), avoidAdjacent = 0.8, doctrine = "strike vulnerable targets and reset" }
    AI:RegisterRoleProfile{ id = "harrier", desiredRange = 1, rangeWeight = 0.25, flankWeight = 2, avoidAdjacent = 2, doctrine = "pressure backline and retreat" }
    AI:RegisterRoleProfile{ id = "artillery", desiredRange = 7, rangedDesiredRange = 7, rangeWeight = 0.6, avoidAdjacent = 6, doctrine = "keep range edge and use screens" }
    AI:RegisterRoleProfile{ id = "brute", desiredRange = 1, rangeWeight = 0.35, flankWeight = 1.5, doctrine = "engage clusters and body-block" }
    AI:RegisterRoleProfile{ id = "controller", desiredRange = 4, rangedDesiredRange = 5, rangeWeight = 0.45, avoidAdjacent = 3.5, doctrine = "early control and objective disruption" }
    AI:RegisterRoleProfile{ id = "defender", desiredRange = 1, rangeWeight = 0.3, protectAllies = 1.6, flankWeight = 1.1, doctrine = "split threats and protect allies or zones" }
    AI:RegisterRoleProfile{ id = "hexer", desiredRange = 5, rangedDesiredRange = 5, rangeWeight = 0.45, avoidAdjacent = 4, doctrine = "debuff high-impact foes" }
    AI:RegisterRoleProfile{ id = "support", desiredRange = 4, rangedDesiredRange = 5, rangeWeight = 0.35, avoidAdjacent = 3, protectAllies = 1, doctrine = "preserve buffs and heal allies" }
    AI:RegisterRoleProfile{ id = "mount", desiredRange = 1, rangeWeight = 0.25, flankWeight = 1, avoidAdjacent = 0.5, doctrine = "safe melee mobility fallback" }
    AI:RegisterRoleProfile{ id = "leader", desiredRange = 3, rangeWeight = 0.3, protectAllies = 1, doctrine = "pace villain and malice actions" }
    AI:RegisterRoleProfile{ id = "solo", desiredRange = 2, rangeWeight = 0.25, flankWeight = 1, doctrine = "multi-target pressure and survival" }
    AI:RegisterRoleProfile{ id = "minion", desiredRange = 1, rangeWeight = 0.3, flankWeight = 1.6, doctrine = "squad pressure and space control" }

    AI:RegisterTacticRule{
        id = "flanking",
        scorePosition = function(ai, context, actor, abilityInfo, targets, loc)
            local target = targets ~= nil and targets[1] and targets[1].token
            if target == nil or not (abilityInfo == nil or abilityInfo.isMelee or abilityInfo.isStrike) then
                return 0
            end

            local flanking, count = ai:IsFlankingLoc(actor, loc, target)
            if not flanking then
                return 0
            end

            local profile = actor.profile or ai.roleProfiles.standard
            return (profile.flankWeight or 0.8) * (2.5 + count * 0.5), "flanking"
        end,
    }

    AI:RegisterTacticRule{
        id = "high-ground",
        scorePosition = function(ai, context, actor, abilityInfo, targets, loc)
            local target = targets ~= nil and targets[1] and targets[1].token
            if target == nil or abilityInfo == nil or not (abilityInfo.isRanged or abilityInfo.isStrike) then
                return 0
            end

            if ai:HasHighGround(loc, target) then
                local amount = Pick(abilityInfo.isRanged, 1.6, 0.8)
                local profile = actor.profile or ai.roleProfiles.standard
                if abilityInfo.isRanged then
                    if ai:RoleIs(actor, "artillery") then
                        amount = amount + 1.2
                    elseif (profile.avoidAdjacent or 0) >= 3 then
                        amount = amount + 0.5
                    end
                end
                return amount, "high ground"
            end
            return 0
        end,
    }

    AI:RegisterTacticRule{
        id = "ranged-safety",
        scorePosition = function(ai, context, actor, abilityInfo, targets, loc)
            if abilityInfo == nil or not abilityInfo.isRanged or abilityInfo.isMelee then
                return 0
            end

            local adjacent = ai:AdjacentEnemyCountFromLoc(actor, loc)
            if adjacent <= 0 then
                return 0
            end

            local profile = actor.profile or ai.roleProfiles.standard
            return -adjacent * math.max(3, profile.avoidAdjacent or 0), "ranged adjacent"
        end,
    }

    AI:RegisterTacticRule{
        id = "charge-setup",
        scoreCandidate = function(ai, context, actor, abilityInfo, targets, loc, candidate)
            local move = ai.CandidatePreInvokeMove and ai:CandidatePreInvokeMove(candidate) or candidate and candidate.preInvokeMove
            if move == nil or move.mode ~= "charge" then
                return 0
            end

            return 2.5 + math.min(2, (move.tiles or 0) * 0.25), "charge setup"
        end,
    }

    AI:RegisterTacticRule{
        id = "forced-movement-pressure",
        scoreTarget = function(ai, context, actor, abilityInfo, targets)
            if abilityInfo == nil or not abilityInfo.hasForcedMovement then
                return 0
            end

            local total = 0
            for _,target in ipairs(targets or {}) do
                if target.token ~= nil and not TokensFriendly(actor.token, target.token) then
                    if ai:TargetCanBeForceMovedByActor(actor, target.token) then
                        total = total + ai:ForcedMovementTargetScore(actor, target.token)
                        local distance = math.max(1, tonumber(abilityInfo.forcedMovementValue) or 1)
                        local destinationScore = ai:BestForcedMovementDestinationScore(context, actor, target.token, distance)
                        local destinationMultiplier = ConstNumber("Score", "ForcedMoveDestinationMultiplier", 0.6)
                        local destinationCap = ConstNumber("Score", "ForcedMoveDestinationCap", 8)
                        total = total + math.max(-4, math.min(destinationCap, destinationScore * destinationMultiplier))
                    end
                end
            end
            return total, "forced movement pressure"
        end,
    }

    AI:RegisterTacticRule{
        id = "area-main-pressure",
        scoreTarget = function(ai, context, actor, abilityInfo, targets)
            if actor == nil
                or actor.token == nil
                or abilityInfo == nil
                or not abilityInfo.isArea
                or not abilityInfo.isAction
                or not ai:AbilityHasHostileEffect(abilityInfo)
            then
                return 0
            end

            local hostileTargets = 0
            for _,target in ipairs(targets or {}) do
                local tok = target and target.token
                if tok ~= nil and IsTokenValid(tok) and not TokensFriendly(actor.token, tok) then
                    hostileTargets = hostileTargets + 1
                end
            end

            if hostileTargets <= 1 then
                return 0
            end

            return (hostileTargets - 1) * ConstNumber("Score", "AreaMainPressureBonus", 1.5), "area main pressure"
        end,
    }

    AI:RegisterTacticRule{
        id = "grab-control",
        scoreTarget = function(ai, context, actor, abilityInfo, targets)
            if abilityInfo == nil or not (abilityInfo.hasGrab or abilityInfo.hasRestrainingControl) then
                return 0
            end

            local total = 0
            local staminaRatio = CurrentStamina(actor.token) / math.max(1, MaxStamina(actor.token))
            if staminaRatio < 0.25 then
                total = total - 10
            elseif staminaRatio < 0.45 then
                total = total - 2
            end

            for _,target in ipairs(targets or {}) do
                local tok = target.token
                if tok ~= nil and not TokensFriendly(actor.token, tok) then
                    if ai:TargetHasCondition(tok, "Grabbed") or ai:TargetHasCondition(tok, "Restrained") then
                        total = total - 30
                    else
                        local controlScore = ConstNumber("Score", "GrabDefaultControlBonus", 0.4)
                        controlScore = controlScore + math.max(0, ai:TargetSpeed(tok) - 5) * 0.4

                        local plan = (context and context.encounterPlan) or ai:GetEncounterPlan()
                        if plan ~= nil and next(plan.objectiveZones or {}) ~= nil and ai.ScoreObjectivePosition ~= nil then
                            local objectivePressure = SafeCall(function()
                                return ai:ScoreObjectivePosition(context, actor, tok.loc, nil, tok)
                            end, 0) or 0
                            if objectivePressure > 0 then
                                controlScore = controlScore + math.min(ConstNumber("Score", "GrabObjectiveControlBonus", 1.2), objectivePressure * 0.3)
                            end
                        end

                        if ai.NearbyHostilePeerCount ~= nil and ai:NearbyHostilePeerCount(actor, tok, 2) > 0 then
                            controlScore = controlScore + ConstNumber("Score", "GrabNearbyEnemyControlBonus", 0.4)
                        end

                        total = total + controlScore
                    end
                end
            end

            return total, "grab control"
        end,
    }

    AI:RegisterTacticRule{
        id = "aid-setup",
        scoreTarget = function(ai, context, actor, abilityInfo, targets)
            if abilityInfo == nil or not abilityInfo.hasAidAttack then
                return 0
            end

            local total = 0
            for _,target in ipairs(targets or {}) do
                local tok = target.token
                if tok ~= nil and not TokensFriendly(actor.token, tok) then
                    if TryGet(tok.properties, "_tmp_directorTacticsAidAttack", TryGet(tok.properties, "_tmp_ai_aidAttack", false)) then
                        total = total - 20
                    else
                        total = total + 2
                        -- Heuristic only: DS legality stays with engine targetability;
                        -- this just values an ally positioned to use the setup.
                        if AidAttackHasAllyPayoff(actor, tok) then
                            total = total + ConstNumber("Score", "AidAttackAllyPayoffBonus", 3)
                        end
                    end
                end
            end

            return total, "aid setup"
        end,
    }

    local builtinObjectives = {
        "diminish_numbers",
        "defeat_specific_foe",
    }

    -- Additional objective scoring helpers are present in the engine code above,
    -- but only objectives in this table are registered for normal use. Register a
    -- custom objective profile to opt into more experimental encounter goals.

    for _,objectiveId in ipairs(builtinObjectives) do
        AI:RegisterObjectiveProfile{
            id = objectiveId,
            builtin = true,
            scoreCandidate = function(ai, context, actor, abilityInfo, targets, loc)
                return ai:ScoreBuiltInObjective(context, actor, abilityInfo, targets or {}, loc)
            end,
            scorePosition = function(ai, context, actor, loc, abilityInfo, targetToken)
                return ai:ScoreObjectivePosition(context, actor, loc, abilityInfo, targetToken)
            end,
            scoreTrigger = function()
                return 0
            end,
            isComplete = function(ai, context)
                local plan = (context and context.encounterPlan) or ai:GetEncounterPlan()
                local state = (context and context.encounterState) or ai.encounterState
                if plan.objective == "diminish_numbers" then
                    return state ~= nil and state.broken == true
                end
                return false
            end,
        }
    end

    AI:RegisterAbilityRule{
        id = "generic-active-ability",
        fallback = true,
        matches = function()
            return true
        end,
        enumerate = function(ai, context, actor, ability, abilityInfo)
            return ai:EnumerateGenericAbility(context, actor, ability, abilityInfo)
        end,
    }

    AI:RegisterPromptPolicy{
        id = "shift",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone)
            local name = Lower(abilityClone.name)
            return string.find(name, "shift", 1, true) ~= nil
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            if ai.TargetHasCondition ~= nil and ai:TargetHasCondition(casterToken, "Slowed") then
                return ManualOrBlockedPrompt(ai, "slowed creature cannot shift")
            end

            local bestLoc = ChooseMovementPromptDestination(ai, context, actor, casterToken, abilityClone, symbols, options)
            if bestLoc ~= nil then
                return HandledPrompt{ targets = { { loc = bestLoc } } }
            end

            return ManualOrBlockedPrompt(ai, "shift prompt has no legal destination")
        end,
    }

    AI:RegisterPromptPolicy{
        id = "movement",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone)
            return ai:IsMovementPromptAbility(abilityClone)
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            local bestLoc = ChooseMovementPromptDestination(ai, context, actor, casterToken, abilityClone, symbols, options)
            if bestLoc ~= nil then
                return HandledPrompt{ targets = { { loc = bestLoc } } }
            end

            return ManualOrBlockedPrompt(ai, "movement prompt has no legal destination")
        end,
    }

    AI:RegisterPromptPolicy{
        id = "resource-spend",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            return type(options) == "table" and type(options.improvements) == "table" and #options.improvements > 0
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            local bestIndex = nil
            local bestCost = nil
            for index,entry in ipairs(options.improvements or {}) do
                local cost = ImprovementCost(ai, casterToken, entry)
                if cost ~= nil and (bestIndex == nil or cost < bestCost) then
                    bestIndex = index
                    bestCost = cost
                end
            end

            if bestIndex == nil then
                return ManualOrBlockedPrompt(ai, "resource spend prompt has no affordable option")
            end

            local improvements = {}
            for index,entry in ipairs(options.improvements or {}) do
                improvements[#improvements+1] = CopyImprovementEntry(entry, index == bestIndex)
            end

            return HandledPrompt{ improvements = improvements }
        end,
    }

    AI:RegisterPromptPolicy{
        id = "area-placement",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone)
            if abilityClone == nil or casterToken == nil then
                return false
            end

            local promptActor = PromptActor(actor, casterToken, context)
            local abilityInfo = SafeCall(function()
                return ai:AnalyzeAbility(promptActor, abilityClone)
            end, nil)
            return ai:IsAreaAbilityInfo(abilityInfo)
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            local promptActor = PromptActor(actor, casterToken, context)
            local abilityInfo = SafeCall(function()
                return ai:AnalyzeAbility(promptActor, abilityClone)
            end, nil)

            if abilityInfo == nil or not ai:IsAreaAbilityInfo(abilityInfo) then
                return nil
            end

            local shapeName = ai:AreaShapeName(abilityInfo)
            if shapeName == "areatemplate" or shapeName == "" then
                return ManualOrBlockedPrompt(ai, "unsupported area placement shape")
            end

            local bestShape = nil
            local bestTargets = nil
            local bestScore = nil
            local combatTokens = (context and context.allCombatTokens) or dmhub.allTokens or {}
            local anchorLocs = ai:AreaAnchorLocs(promptActor, abilityInfo, casterToken.loc, false)

            for _,anchorLoc in ipairs(anchorLocs or {}) do
                local shape = ai:CalculateAreaShape(casterToken, abilityInfo, anchorLoc)
                if shape ~= nil then
                    local shapeSymbols = CopySymbols(symbols or {})
                    shapeSymbols.targetArea = shape
                    local areaLegality = ai:CheckAreaLegality(context, promptActor, abilityClone, abilityInfo, casterToken, casterToken.loc, anchorLoc, shape, shapeSymbols, {
                        combatTokens = combatTokens,
                        phase = "prompt.policy",
                    })
                    if areaLegality.ok ~= true then
                        ai:Skip(abilityClone, areaLegality.reason)
                    else
                        local targets = areaLegality.targets or {}
                        local score = ai:ScoreTargets(context, promptActor, abilityInfo, targets, casterToken.loc)
                        if bestShape == nil or score.total > bestScore then
                            bestShape = shape
                            bestTargets = targets
                            bestScore = score.total
                        end
                    end
                end
            end

            if bestShape ~= nil then
                symbols.targetArea = bestShape
                return HandledPrompt{
                    targets = bestTargets,
                    targetArea = bestShape,
                    symbols = symbols,
                }
            end

            return ManualOrBlockedPrompt(ai, "area placement prompt needs Director choice")
        end,
    }

    AI:RegisterPromptPolicy{
        id = "specific-target-invoke",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            if not IsSpecificTargetFreeStrikeName(TryGet(abilityClone, "name", "") or "") then
                return false
            end

            local promptClass = ai.ClassifyNestedPrompt ~= nil
                and ai:ClassifyNestedPrompt(context, actor, invokerToken, casterToken, abilityClone, symbols, options)
                or "required"
            return promptClass == "optional-child"
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            local targets = ResolveSpecificTargetFreeStrikeTargets(abilityClone, symbols or {}, options or {})
            if #targets > 0 then
                return HandledPrompt{
                    targets = targets,
                    targetArgs = targets,
                    _directorSpecificTargetInvoke = true,
                    _directorSpecificTargetSource = "inherited",
                    _directorNestedPromptClass = "optional-child",
                    _directorOptionalNestedPrompt = "handled",
                    _directorOptionalNestedReason = "specific-target invoke reused inherited target",
                }
            end

            return HandledPrompt{
                targets = {},
                targetArgs = {},
                _directorNestedPromptClass = "optional-child",
                _directorOptionalNestedPrompt = "skipped",
                _directorOptionalNestedReason = "specific-target invoke had no inherited target",
            }
        end,
    }

    AI:RegisterPromptPolicy{
        id = "follow-up-target",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone)
            local targetType = Lower(TryGet(abilityClone, "targetType", ""))
            local name = Lower(abilityClone.name)
            return targetType == "target"
                and string.find(name, "push", 1, true) == nil
                and string.find(name, "pull", 1, true) == nil
                and string.find(name, "slide", 1, true) == nil
                and not ai:IsMovementPromptAbility(abilityClone)
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            symbols = symbols or {}
            options = options or {}
            if casterToken == nil or abilityClone == nil then
                return FollowUpBlocked("missing follow-up target context")
            end

            local targetPairs = TryGet(symbols, "targetPairs", TryGet(options and options.symbols, "targetPairs", {})) or {}
            local invokerId = TryGet(invokerToken, "charid", TryGet(invokerToken, "id", nil))
            local assigned = {}
            for _,pair in ipairs(targetPairs) do
                if tostring(pair.a or "") == tostring(invokerId or "") and pair.b ~= nil then
                    local assignedToken = TokenByAnyId(pair.b)
                    local assignedKey = FollowUpTokenKey(assignedToken)
                    if assignedKey ~= "" then
                        assigned[assignedKey] = true
                    end
                    assigned[tostring(pair.b)] = true
                end
            end

            local promptActor = PromptActor(actor, casterToken, context)
            local abilityInfo = ai:AnalyzeAbility(promptActor, abilityClone)
            local range = AbilityRange(abilityClone, casterToken, symbols)
            local inheritedTargets = ResolveInheritedFollowUpTargets(ai, context, invokerToken, symbols, options)
            local fallbackPool = BuildFollowUpFallbackPool(context, actor, inheritedTargets, targetPairs)
            local targetableSet = nil
            if ai.TargetableSetFromEngine ~= nil then
                targetableSet = ai:TargetableSetFromEngine(abilityClone, casterToken, casterToken.loc, {
                    context = context,
                    abilityInfo = abilityInfo,
                    symbols = symbols,
                    targetPool = fallbackPool,
                    extraTargets = inheritedTargets,
                })
                range = tonumber(targetableSet and targetableSet._range) or range
            end

            local checked = 0
            local rejected = 0
            local legal = 0
            local rejectionSamples = {}

            local function Reject(target, source, reason)
                rejected = rejected + 1
                if #rejectionSamples < 3 then
                    rejectionSamples[#rejectionSamples+1] = string.format(
                        "%s:%s:%s",
                        tostring(source or "target"),
                        TokenName(target),
                        tostring(reason or "rejected")
                    )
                end
            end

            local function TargetLegal(target, source)
                checked = checked + 1
                if not IsTokenValid(target) then
                    Reject(target, source, "target invalid")
                    return false
                end

                local targetKey = FollowUpTokenKey(target)
                if source ~= "inherited" and (assigned[targetKey] or assigned[tostring(TryGet(target, "charid", TryGet(target, "id", "")) or "")]) then
                    Reject(target, source, "target already assigned")
                    return false
                end

                local entry = FollowUpTargetableEntry(targetableSet, target)
                if targetableSet ~= nil then
                    if entry == nil then
                        local dist = Distance(casterToken, target)
                        if dist > (range or 0) + 0.1 then
                            Reject(target, source, "target out of range")
                        else
                            Reject(target, source, "target not targetable")
                        end
                        return false
                    end

                    if (entry.distance or Distance(casterToken, target)) > (range or 0) + 0.1 then
                        Reject(target, source, "target out of range")
                        return false
                    end

                    if entry.lineOfSight ~= true then
                        Reject(target, source, "no line of sight")
                        return false
                    end

                    if entry.passedEngineFilter ~= true then
                        Reject(target, source, entry.rejectionReason or "target filter failed")
                        return false
                    end
                else
                    if Distance(casterToken, target) > (range or 0) + 0.1 then
                        Reject(target, source, "target out of range")
                        return false
                    end

                    if not HasLineOfSight(casterToken, target) then
                        Reject(target, source, "no line of sight")
                        return false
                    end
                end

                if ai.DirectorTargetAllowed ~= nil then
                    local allowed, reason = ai:DirectorTargetAllowed(context, promptActor, abilityClone, abilityInfo, casterToken, target, symbols)
                    if not allowed then
                        Reject(target, source, reason or "target filter failed")
                        return false
                    end
                end

                legal = legal + 1
                return true
            end

            for _,entry in ipairs(inheritedTargets) do
                local target = entry and entry.token
                if TargetLegal(target, "inherited") then
                    return HandledPrompt{
                        targets = { { token = target } },
                        targetArgs = { { token = target } },
                        _directorFollowUpTarget = "inherited",
                    }
                end
            end

            local bestTarget = nil
            local bestScore = nil
            local bestKey = nil

            for _,target in ipairs(fallbackPool) do
                if TargetLegal(target, "fallback") then
                    local score = SafeCall(function()
                        local scoreInfo = ai:ScoreTargets(context, promptActor, abilityInfo, { { token = target } }, casterToken.loc)
                        return tonumber(scoreInfo and scoreInfo.total) or 0
                    end, 0) or 0
                    local key = FollowUpTokenKey(target)
                    if bestTarget == nil or score > bestScore or (score == bestScore and key < bestKey) then
                        bestTarget = target
                        bestScore = score
                        bestKey = key
                    end
                end
            end

            if bestTarget ~= nil then
                return HandledPrompt{
                    targets = { { token = bestTarget } },
                    targetArgs = { { token = bestTarget } },
                    _directorFollowUpTarget = "fallback",
                }
            end

            local samples = ""
            if #rejectionSamples > 0 then
                samples = "; samples=" .. table.concat(rejectionSamples, " | ")
            end
            return FollowUpBlocked(string.format(
                "no legal follow-up target (inherited=%d fallback=%d checked=%d legal=%d rejected=%d%s)",
                #inheritedTargets,
                #fallbackPool,
                checked,
                legal,
                rejected,
                samples
            ))
        end,
    }

    AI:RegisterPromptPolicy{
        id = "forced-movement",
        matches = function(ai, context, actor, invokerToken, casterToken, abilityClone)
            local name = Lower(abilityClone.name)
            return string.find(name, "push", 1, true) ~= nil or string.find(name, "pull", 1, true) ~= nil or string.find(name, "slide", 1, true) ~= nil
        end,
        choose = function(ai, context, actor, invokerToken, casterToken, abilityClone, symbols, options)
            local range = math.max(1, AbilityRange(abilityClone, casterToken, symbols))
            local predicate = SafeCall(function()
                return abilityClone:TargetLocPassesFilterPredicate(casterToken, symbols)
            end, nil)

            local possibleLocs = {}
            local loc = casterToken.loc
            for _=1,range do
                loc = loc.north.west
            end

            for _=1,range * 2 do
                if predicate == nil or predicate(loc) then
                    possibleLocs[#possibleLocs+1] = loc
                end
                loc = loc.east
            end
            for _=1,range * 2 do
                if predicate == nil or predicate(loc) then
                    possibleLocs[#possibleLocs+1] = loc
                end
                loc = loc.south
            end
            for _=1,range * 2 do
                if predicate == nil or predicate(loc) then
                    possibleLocs[#possibleLocs+1] = loc
                end
                loc = loc.west
            end
            for _=1,range * 2 do
                if predicate == nil or predicate(loc) then
                    possibleLocs[#possibleLocs+1] = loc
                end
                loc = loc.north
            end

            local bestLoc = nil
            local bestScore = nil
            for _,testLoc in ipairs(possibleLocs) do
                local movementInfo = SafeCall(function()
                    return casterToken:MarkMovementArrow(testLoc, { straightline = true, ignorecreatures = false })
                end, nil)

                if movementInfo ~= nil and movementInfo.path ~= nil then
                    local score = ai:ScoreForcedMovementDestination(context, actor, invokerToken, casterToken, testLoc, movementInfo)

                    if bestLoc == nil or score > bestScore then
                        bestLoc = testLoc
                        bestScore = score
                    end
                end
            end

            SafeCall(function()
                casterToken:ClearMovementArrow()
            end, nil)

            if bestLoc ~= nil then
                return HandledPrompt{ targets = { { loc = bestLoc } } }
            end
        end,
    }

    AI:RegisterTriggerPolicy{
        id = "opportunity-attack",
        matches = function(ai, token, trigger, context, info)
            if not ai:TriggerCanAutoActivate(token, trigger, info) then
                return false
            end

            if info ~= nil and info.event ~= nil then
                return info.event == "leaveadjacent"
            end

            return ActiveTriggerText(trigger) == "opportunity attack"
        end,
        score = function(ai, token, trigger, context, info)
            return ai:TriggerPolicyScore(10, token, trigger, context, info)
        end,
        execute = function(ai, token, trigger)
            return ai:ActivateAvailableTrigger(token, trigger, "Opportunity attack")
        end,
    }

    TriggerPolicy{
        id = "when-hit",
        events = { "losehitpoints" },
        score = 8,
        label = "When-hit trigger",
    }

    TriggerPolicy{
        id = "on-hit-follow-up",
        events = { "dealdamage" },
        score = 7,
        label = "On-hit follow-up",
    }

    TriggerPolicy{
        id = "on-condition-applied",
        events = { "inflictcondition" },
        score = 7,
        label = "Condition trigger",
    }

    TriggerPolicy{
        id = "on-death",
        events = { "dying", "creaturedeath", "zerohitpoints" },
        score = 9,
        label = "Death trigger",
    }

    TriggerPolicy{
        id = "begin-turn",
        events = { "beginturn" },
        score = 6,
        label = "Begin-turn trigger",
    }

    TriggerPolicy{
        id = "end-turn",
        events = { "endturn" },
        score = 6,
        label = "End-turn trigger",
    }
end

RegisterDefaults()
