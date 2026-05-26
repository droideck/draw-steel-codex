local mod = dmhub.GetModLoading()

-- DirectorTacticsAbilities.lua interprets abilities, prompt risk, action economy, malice, villain actions, and start-turn resources.
-- Load after DirectorTacticsGoals.lua and before DirectorTacticsScoring.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsAbilities.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local HasKey = Internal.HasKey
local Lower = Internal.Lower
local TokenName = Internal.TokenName
local TokenId = Internal.TokenId
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local Distance = Internal.Distance
local CurrentStamina = Internal.CurrentStamina
local MaxStamina = Internal.MaxStamina
local HighestCharacteristic = Internal.HighestCharacteristic
local HasKeyword = Internal.HasKeyword
local AbilityRange = Internal.AbilityRange
local AbilityRadius = Internal.AbilityRadius
local AbilityNumTargets = Internal.AbilityNumTargets
local AbilityCanAfford = Internal.AbilityCanAfford
local AbilityRequiresPrompt = Internal.AbilityRequiresPrompt
local AbilityHasPotency = Internal.AbilityHasPotency
local AbilityActionResourceKind = Internal.AbilityActionResourceKind
local IsAction = Internal.IsAction
local IsManeuver = Internal.IsManeuver
local EstimateRollText = Internal.EstimateRollText
local ExtractDamageFromRule = Internal.ExtractDamageFromRule
local TextHasAny = Internal.TextHasAny
local CreateScore = Internal.CreateScore
local AddScore = Internal.AddScore
local ConstNumber = Internal.ConstNumber

local function NoteCriticalRefreshText(result, text)
    text = Lower(tostring(text or ""))
    if text == "" or (string.find(text, "crit", 1, true) == nil and string.find(text, "critical", 1, true) == nil) then
        return
    end

    if not TextHasAny(text, { "gain", "regain", "refresh", "recover", "free", "additional", "another" }) then
        return
    end

    if string.find(text, "maneuver", 1, true) ~= nil then
        result.critRefreshKinds.maneuver = true
    end

    if string.find(text, "main action", 1, true) ~= nil or string.find(text, "action", 1, true) ~= nil then
        result.critRefreshKinds.action = true
    end
end

local REMOVABLE_CONDITIONS = {
    "bleeding",
    "burning",
    "cursed",
    "dazed",
    "frightened",
    "grabbed",
    "mazed",
    "prone",
    "restrained",
    "shadowed vision",
    "slowed",
    "taunted",
    "weakened",
}

local function AddConditionRemoval(result, conditionName, value)
    result.hasConditionRemoval = true
    result.conditionRemovalValue = math.max(result.conditionRemovalValue or 0, value or 4)
    if conditionName == nil then
        result.conditionRemovalGeneric = true
        return
    end

    result.conditionRemovalNames = result.conditionRemovalNames or {}
    for _,existing in ipairs(result.conditionRemovalNames) do
        if existing == conditionName then
            return
        end
    end
    result.conditionRemovalNames[#result.conditionRemovalNames+1] = conditionName
end

local function NoteConditionRemovalText(result, text)
    text = Lower(tostring(text or ""))
    if text == "" then
        return
    end

    if not TextHasAny(text, { "remove", "removes", "removed", "purge", "purges", "end one", "ends one", "end a", "ends a", "no longer", "is no longer", "are no longer" }) then
        return
    end

    local foundSpecific = false
    for _,conditionName in ipairs(REMOVABLE_CONDITIONS) do
        if string.find(text, conditionName, 1, true) ~= nil then
            AddConditionRemoval(result, conditionName, 4)
            foundSpecific = true
        end
    end

    if not foundSpecific and TextHasAny(text, { "condition", "effect", "ongoing effect", "saving throw", "save ends", "save" }) then
        AddConditionRemoval(result, nil, 4)
    end
end

local function AddConditionApply(result, conditionName)
    result.conditionApplyNames = result.conditionApplyNames or {}
    if conditionName == nil then
        result.conditionApplyGeneric = true
        return
    end

    for _,existing in ipairs(result.conditionApplyNames) do
        if existing == conditionName then
            return
        end
    end
    result.conditionApplyNames[#result.conditionApplyNames+1] = conditionName
end

local function NoteConditionApplyText(result, text)
    text = Lower(tostring(text or ""))
    if text == "" then
        return
    end

    local foundSpecific = false
    for _,conditionName in ipairs(REMOVABLE_CONDITIONS) do
        if string.find(text, conditionName, 1, true) ~= nil then
            AddConditionApply(result, conditionName)
            foundSpecific = true
        end
    end

    if not foundSpecific and TextHasAny(text, { "condition", "effect", "save ends" }) then
        AddConditionApply(result, nil)
    end
end

local function TrimLower(value)
    return string.gsub(Lower(value or ""), "^%s*(.-)%s*$", "%1")
end

local function ExtractForcedMovementDistance(text)
    text = Lower(tostring(text or ""))
    if text == "" or not TextHasAny(text, { "push", "pull", "slide", "knockback" }) then
        return nil
    end

    local best = nil
    for numberText in string.gmatch(text, "(%d+)") do
        local value = tonumber(numberText)
        if value ~= nil then
            best = math.max(best or 0, value)
        end
    end

    return best
end

local function NoteForcedMovementText(result, text, fallbackDistance)
    text = Lower(tostring(text or ""))
    if text == "" or not TextHasAny(text, { "push", "pull", "slide", "teleport", "shift", "knockback" }) then
        return
    end

    result.hasForcedMovement = true
    result.forcedMovementValue = math.max(result.forcedMovementValue or 0, ExtractForcedMovementDistance(text) or fallbackDistance or 1)
end

local ACTION_TYPE_KEYWORDS = { "Charge", "Strike", "Melee", "Ranged", "Area" }

local function ActionResourceId(ability)
    return SafeCall(function()
        return ability:ActionResource()
    end, TryGet(ability, "actionResourceId", nil))
end

local function SlotQuantity(ability)
    local raw = TryGet(ability, "actionNumber", 1)
    local quantity = tonumber(raw)
    if quantity == nil then
        quantity = tonumber(string.match(tostring(raw or ""), "%d+"))
    end

    return math.max(1, quantity or 1)
end

local function ActionTypeSlot(resourceId, slotName, quantity)
    if resourceId == nil or resourceId == "" or resourceId == "none" then
        return nil
    end

    return {
        resourceId = resourceId,
        slotName = slotName,
        quantity = math.max(1, tonumber(quantity) or 1),
    }
end

local function NumericAbilityRange(ability)
    local value = TryGet(ability, "range", nil)
    local number = tonumber(value)
    if number ~= nil then
        return number
    end

    return tonumber(string.match(tostring(value or ""), "%d+"))
end

local function NormalizeMovementMode(mode)
    mode = Lower(mode or "")
    if mode == "" or mode == "move" then
        return "walk"
    end

    return mode
end

local function RelocateMovementSpec(ability, behavior)
    if ability == nil or behavior == nil or TryGet(behavior, "typeName", "") ~= "ActivatedAbilityRelocateCreatureBehavior" then
        return nil
    end

    local mode = NormalizeMovementMode(TryGet(behavior, "movementType", "move"))
    return {
        maxTiles = NumericAbilityRange(ability),
        mode = mode,
        straightLine = Lower(TryGet(ability, "targeting", "")) == "straightline"
            or Lower(TryGet(ability, "targeting", "")) == "straightpath"
            or Lower(TryGet(ability, "targetType", "")) == "line",
    }
end

local function InvokedAbilityFromBehavior(behavior)
    local customAbility = TryGet(behavior, "customAbility", nil)
    if customAbility ~= nil then
        return customAbility
    end

    if TryGet(behavior, "abilityType", nil) == "standard" and dmhub ~= nil and dmhub.GetTable ~= nil then
        local standard = dmhub.GetTable("standardAbilities")
        local id = TryGet(behavior, "standardAbility", nil)
        if standard ~= nil and id ~= nil then
            return standard[id]
        end
    end

    return nil
end

local function InvokeRelocatesCaster(behavior)
    if behavior == nil or TryGet(behavior, "typeName", "") ~= "ActivatedAbilityInvokeAbilityBehavior" then
        return false
    end

    local targeting = Lower(TryGet(behavior, "targeting", "prompt") or "")
    return TryGet(behavior, "invokeOnCaster", false) == true or targeting == "self"
end

local function PreInvokeMovementFromBehaviors(ability)
    for _,behavior in ipairs(TryGet(ability, "behaviors", {}) or {}) do
        if InvokeRelocatesCaster(behavior) then
            local invokedAbility = InvokedAbilityFromBehavior(behavior)
            for _,subbehavior in ipairs(TryGet(invokedAbility, "behaviors", {}) or {}) do
                local spec = RelocateMovementSpec(invokedAbility, subbehavior)
                if spec ~= nil then
                    return spec
                end
            end
        end
    end

    return nil
end

function AI:ResolveActionType(ability)
    local resources = RawGlobal("CharacterResource")
    local name = TryGet(ability, "name", "")
    local categorization = TrimLower(TryGet(ability, "categorization", ""))
    local resourceCost = TryGet(ability, "resourceCost", "none")
    local resourceId = ActionResourceId(ability)
    local actionResourceKind = AbilityActionResourceKind(ability)
    local maliceResourceId = TryGet(resources, "maliceResourceId", "malice")
    local usesMaliceResource = resourceCost == maliceResourceId
    local isMonsterGroupMalice = categorization == "malice"
    local isStartTurnMalice = isMonsterGroupMalice and actionResourceKind == nil
    local quantity = SlotQuantity(ability)
    local keywords = {}

    for _,keyword in ipairs(ACTION_TYPE_KEYWORDS) do
        keywords[keyword] = HasKeyword(ability, keyword)
    end

    local preInvokeMovement = nil
    if keywords.Charge then
        preInvokeMovement = {
            maxTiles = tonumber(TryGet(ability, "chargeDistanceOverride", nil)),
            mode = "charge",
            straightLine = true,
        }
    else
        preInvokeMovement = PreInvokeMovementFromBehaviors(ability)
    end

    local function Result(kind, slot, moveSubKind)
        return {
            kind = kind,
            slot = slot,
            consumesMoveBudget = kind == "move" or preInvokeMovement ~= nil,
            preInvokeMovement = preInvokeMovement,
            keywords = keywords,
            moveSubKind = moveSubKind,
        }
    end

    if HasKey(ability, "villainAction")
        or categorization == "villain action"
        or resourceId == TryGet(resources, "villainActionId", nil)
    then
        return Result("villain", ActionTypeSlot(resourceId or TryGet(resources, "villainActionId", nil), "villain", quantity))
    end

    if self.IsSoloActionName ~= nil and self:IsSoloActionName(name) then
        return Result("solo", ActionTypeSlot(maliceResourceId, "malice", tonumber(TryGet(ability, "resourceNumber", nil)) or quantity))
    end

    if isStartTurnMalice or (usesMaliceResource and actionResourceKind == nil) then
        return Result("malice", ActionTypeSlot(maliceResourceId, "malice", tonumber(TryGet(ability, "resourceNumber", nil)) or quantity))
    end

    if resourceId == TryGet(resources, "freeManeuverResourceId", nil) then
        return Result("freeManeuver", ActionTypeSlot(resourceId, "freeManeuver", quantity))
    end

    if resourceId == TryGet(resources, "triggerResourceId", nil) then
        return Result("triggered", ActionTypeSlot(resourceId, "triggered", quantity))
    end

    if categorization == "trigger" then
        return Result("freeTriggered", nil)
    end

    if self.IsShiftName ~= nil and self:IsShiftName(name) then
        return Result("move", nil, "shift")
    end

    if categorization == "move" or (self.IsAdvanceName ~= nil and self:IsAdvanceName(name)) then
        return Result("move", nil, self:IsAdvanceName(name) and "advance" or "walk")
    end

    if self.IsEscapeGrabName ~= nil and self:IsEscapeGrabName(name) then
        return Result("maneuver", ActionTypeSlot(resourceId or TryGet(resources, "maneuverResourceId", nil), "maneuver", quantity))
    end

    if self.IsHideName ~= nil and self:IsHideName(name) then
        return Result("maneuver", ActionTypeSlot(resourceId or TryGet(resources, "maneuverResourceId", nil), "maneuver", quantity))
    end

    if self.IsSearchForHiddenName ~= nil and self:IsSearchForHiddenName(name) then
        return Result("maneuver", ActionTypeSlot(resourceId or TryGet(resources, "maneuverResourceId", nil), "maneuver", quantity))
    end

    if IsAction(ability) then
        return Result("main", ActionTypeSlot(resourceId or TryGet(resources, "actionResourceId", nil), "main", quantity))
    end

    if IsManeuver(ability) then
        return Result("maneuver", ActionTypeSlot(resourceId or TryGet(resources, "maneuverResourceId", nil), "maneuver", quantity))
    end

    return Result("none", nil)
end

function AI:AnalyzeAbility(actor, ability)
    local symbols = { mode = 1 }
    local categorization = TryGet(ability, "categorization", "")
    local resourceCost = TryGet(ability, "resourceCost", "none")
    local actionResourceKind = AbilityActionResourceKind(ability)
    local resources = RawGlobal("CharacterResource")
    local maliceResourceId = TryGet(resources, "maliceResourceId", "malice")
    local usesMaliceResource = resourceCost == maliceResourceId
    local isMonsterGroupMalice = categorization == "Malice"
    local isStartTurnMalice = isMonsterGroupMalice and actionResourceKind == nil
    local name = ability.name or "Ability"
    local lowerName = Lower(name)
    local chargeDistanceOverride = TryGet(ability, "chargeDistanceOverride", nil)
    local actionType = self:ResolveActionType(ability)

    local result = {
        ability = ability,
        name = name,
        targetType = TryGet(ability, "targetType", "target"),
        targetAllegiance = TryGet(ability, "targetAllegiance", ""),
        targetFilter = TryGet(ability, "targetFilter", ""),
        categorization = categorization,
        resourceCost = resourceCost,
        actionResourceKind = actionResourceKind,
        usesMaliceResource = usesMaliceResource,
        isMonsterGroupMalice = isMonsterGroupMalice,
        isStartTurnMalice = isStartTurnMalice,
        villainAction = TryGet(ability, "villainAction", nil),
        range = AbilityRange(ability, actor.token, symbols),
        radius = AbilityRadius(ability, actor.token, symbols),
        numTargets = AbilityNumTargets(ability, actor.token, symbols),
        isStrike = actionType.keywords.Strike == true,
        isMelee = actionType.keywords.Melee == true,
        isRanged = actionType.keywords.Ranged == true,
        isArea = actionType.keywords.Area == true,
        isChargeCapable = actionType.keywords.Charge == true,
        chargeDistanceOverride = chargeDistanceOverride,
        isSignature = categorization == "Signature Ability",
        isAction = actionType.kind == "main",
        isManeuver = actionType.kind == "maneuver",
        isMalice = isMonsterGroupMalice or usesMaliceResource,
        isVillain = HasKey(ability, "villainAction") or categorization == "Villain Action",
        requiresPrompt = AbilityRequiresPrompt(ability),
        hasPotency = AbilityHasPotency(ability),
        expectedDamage = 0,
        conditionValue = 0,
        conditionApplyNames = {},
        conditionApplyGeneric = false,
        conditionRemovalValue = 0,
        conditionRemovalNames = {},
        conditionRemovalGeneric = false,
        forcedMovementValue = 0,
        supportValue = 0,
        hasPowerRoll = false,
        hasDamage = false,
        hasConditionRemoval = false,
        hasForcedMovement = false,
        hasSupport = false,
        hasInvoke = false,
        hasAura = false,
        hasSummon = false,
        hasGrab = string.find(lowerName, "grab", 1, true) ~= nil,
        hasRestrainingControl = string.find(lowerName, "restrain", 1, true) ~= nil,
        hasAidAttack = string.find(lowerName, "aid attack", 1, true) ~= nil or string.find(lowerName, "aid an attack", 1, true) ~= nil,
        critRefreshKinds = { action = false, maneuver = false },
        manualPromptRisk = false,
    }

    for _,behavior in ipairs(TryGet(ability, "behaviors", {}) or {}) do
        local typeName = TryGet(behavior, "typeName", "")
        NoteCriticalRefreshText(result, TryGet(behavior, "name", ""))
        NoteCriticalRefreshText(result, TryGet(behavior, "text", ""))
        NoteCriticalRefreshText(result, TryGet(behavior, "description", ""))
        NoteCriticalRefreshText(result, TryGet(behavior, "rule", ""))
        NoteConditionRemovalText(result, TryGet(behavior, "name", ""))
        NoteConditionRemovalText(result, TryGet(behavior, "text", ""))
        NoteConditionRemovalText(result, TryGet(behavior, "description", ""))
        NoteConditionRemovalText(result, TryGet(behavior, "rule", ""))
        if typeName == "ActivatedAbilityPowerRollBehavior" then
            result.hasPowerRoll = true
            local tiers = TryGet(behavior, "tiers", {}) or {}
            local tierDamage = {}
            for i=1,3 do
                local tierText = tiers[i] or ""
                NoteCriticalRefreshText(result, tierText)
                NoteConditionRemovalText(result, tierText)
                if string.find(tierText, "<", 1, true) ~= nil then
                    result.hasPotency = true
                end
                tierDamage[i] = ExtractDamageFromRule(tierText)
                if TextHasAny(tierText, {"slowed", "restrained", "dazed", "weakened", "frightened", "prone", "grabbed", "taunted"}) then
                    result.conditionValue = result.conditionValue + 2 + i
                    NoteConditionApplyText(result, tierText)
                    if TextHasAny(tierText, {"grabbed"}) then
                        result.hasGrab = true
                    end
                    if TextHasAny(tierText, {"restrained"}) then
                        result.hasRestrainingControl = true
                    end
                end
                if TextHasAny(tierText, {"push", "pull", "slide", "teleport", "shift"}) then
                    result.forcedMovementValue = result.forcedMovementValue + 1 + i * 0.5
                    result.hasForcedMovement = true
                    NoteForcedMovementText(result, tierText, 1 + i * 0.5)
                end
            end

            result.expectedDamage = math.max(result.expectedDamage, (tierDamage[1] or 0) * 0.2 + (tierDamage[2] or 0) * 0.5 + (tierDamage[3] or 0) * 0.3)
        elseif typeName == "ActivatedAbilityDamageBehavior" then
            result.hasDamage = true
            result.expectedDamage = math.max(result.expectedDamage, EstimateRollText(TryGet(behavior, "roll", "0")))
        elseif typeName == "ActivatedAbilityDrawSteelCommandBehavior" then
            local rule = TryGet(behavior, "rule", "")
            NoteConditionRemovalText(result, rule)
            result.expectedDamage = math.max(result.expectedDamage, ExtractDamageFromRule(rule))
            if TextHasAny(rule, {"slowed", "restrained", "dazed", "weakened", "frightened", "prone", "grabbed", "taunted"}) then
                result.conditionValue = result.conditionValue + 4
                NoteConditionApplyText(result, rule)
                if TextHasAny(rule, {"grabbed"}) then
                    result.hasGrab = true
                end
                if TextHasAny(rule, {"restrained"}) then
                    result.hasRestrainingControl = true
                end
            end
            if TextHasAny(rule, {"push", "pull", "slide", "teleport", "shift"}) then
                result.forcedMovementValue = result.forcedMovementValue + 2
                result.hasForcedMovement = true
                NoteForcedMovementText(result, rule, 2)
            end
        elseif typeName == "ActivatedAbilityRelocateCreatureBehavior" then
            result.hasForcedMovement = true
            result.forcedMovementValue = result.forcedMovementValue + 2
        elseif typeName == "ActivatedAbilityApplyOngoingEffectBehavior" or typeName == "ActivatedAbilityApplyAbilityDurationEffect" or typeName == "ActivatedAbilityRecoverySelectionBehavior" or typeName == "ActivatedAbilityReplenishBehavior" then
            result.hasSupport = true
            result.supportValue = result.supportValue + 4
            if typeName == "ActivatedAbilityRecoverySelectionBehavior" then
                AddConditionRemoval(result, nil, 4)
            end
        elseif typeName == "ActivatedAbilityInvokeAbilityBehavior" then
            result.hasInvoke = true
            local targeting = TryGet(behavior, "targeting", "prompt")
            if targeting == "prompt" or targeting == "prompt_inherit" or TryGet(behavior, "promptWhenResolving", false) then
                result.requiresPrompt = true
                result.manualPromptRisk = true
            end
        elseif typeName == "ActivatedAbilityAuraBehavior" then
            result.hasAura = true
        elseif typeName == "ActivatedAbilitySummonBehavior" then
            result.hasSummon = true
            result.requiresPrompt = true
            result.manualPromptRisk = true
        end
    end

    if string.find(lowerName, "knockback", 1, true) ~= nil then
        NoteForcedMovementText(result, lowerName, 1)
    end

    for _,mode in ipairs(TryGet(ability, "modeList", {}) or {}) do
        NoteForcedMovementText(result, TryGet(mode, "text", TryGet(mode, "name", "")), 1)
    end

    if result.expectedDamage > 0 then
        result.hasDamage = true
    end

    if result.targetAllegiance == "ally" and not result.hasDamage then
        result.hasSupport = true
        result.supportValue = math.max(result.supportValue, 4)
    end

    if result.isStrike and result.expectedDamage <= 0 then
        result.expectedDamage = SafeCall(function()
            return actor.token.properties:OpportunityAttack()
        end, math.max(1, HighestCharacteristic(actor.token.properties)))
        result.hasDamage = true
    end

    result.autoResolvableModePrompt = self:IsAutoResolvableGrabModePrompt(result)
        or self:IsAutoResolvableForcedMovementModePrompt(result)

    return result
end

function AI:AbilityTargetsEnemies(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    local targetAllegiance = Lower(abilityInfo.targetAllegiance)
    local targetFilter = Lower(abilityInfo.targetFilter)
    return targetAllegiance == "enemy" or targetFilter == "enemy"
end

function AI:AbilityTargetsAllies(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    local targetAllegiance = Lower(abilityInfo.targetAllegiance)
    local targetFilter = Lower(abilityInfo.targetFilter)
    return targetAllegiance == "ally" or targetFilter == "ally" or targetFilter == "not enemy"
end

function AI:AbilityHasHostileEffect(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    if self:AbilityTargetsAllies(abilityInfo) and not abilityInfo.hasDamage and (abilityInfo.conditionValue or 0) <= 0 then
        return false
    end

    if self:AbilityTargetsEnemies(abilityInfo) then
        return true
    end

    if abilityInfo.hasDamage or (abilityInfo.conditionValue or 0) > 0 then
        return true
    end

    if (abilityInfo.forcedMovementValue or 0) > 0 and not self:AbilityTargetsAllies(abilityInfo) then
        return true
    end

    return false
end

function AI:AbilityHasFriendlyEffect(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    if self:AbilityTargetsAllies(abilityInfo) then
        return true
    end

    return abilityInfo.hasSupport and not self:AbilityHasHostileEffect(abilityInfo)
end

function AI:VillainActionKey(abilityOrInfo)
    if abilityOrInfo == nil then
        return nil
    end

    local key = TryGet(abilityOrInfo, "villainAction", nil)
    if key == nil then
        local ability = TryGet(abilityOrInfo, "ability", nil)
        key = TryGet(ability, "villainAction", nil)
    end

    local n = tonumber(key)
    if n ~= nil then
        return "Villain Action " .. tostring(n)
    end

    local text = Lower(tostring(key or ""))
    n = tonumber(string.match(text, "villain%s*action%s*(%d+)"))
    if n ~= nil then
        return "Villain Action " .. tostring(n)
    end

    if key ~= nil and key ~= "" then
        return tostring(key)
    end

    return nil
end

function AI:VillainActionNumber(abilityInfo)
    if abilityInfo == nil then
        return nil
    end

    local key = self:VillainActionKey(abilityInfo)
    local n = tonumber(key)
    if n ~= nil then
        return n
    end

    local keyText = Lower(tostring(key or ""))
    n = tonumber(string.match(keyText, "villain%s*action%s*(%d+)"))
    if n ~= nil then
        return n
    end

    local text = Lower(abilityInfo.name or "")
    n = tonumber(string.match(text, "villain%s*action%s*(%d+)"))
    if n ~= nil then
        return n
    end

    return tonumber(string.match(text, "^%s*(%d+)"))
end

function AI:VillainActionUsed(token, key)
    if token == nil or key == nil then
        return false
    end

    local state = RawGlobal("VillainActionState")
    if state == nil or state.HasUsed == nil then
        return false
    end

    return SafeCall(function()
        return state.HasUsed(token.charid, key) == true
    end, false)
end

function AI:NextVillainActionNumberForToken(token)
    for i=1,3 do
        if not self:VillainActionUsed(token, "Villain Action " .. tostring(i)) then
            return i
        end
    end

    return 3
end

local function VillainActionIgnoredCostEntry(entry, ability, resources)
    if entry == nil then
        return false
    end

    local cost = entry.cost
    if cost == nil or cost == "none" then
        return true
    end

    if cost == SafeCall(function()
        return ability:ActionResource()
    end, nil) then
        return true
    end

    if resources ~= nil and cost == TryGet(resources, "actionResourceId", nil) then
        return true
    end

    local usageLimit = TryGet(ability, "usageLimitOptions", nil)
    if usageLimit ~= nil and cost == TryGet(usageLimit, "resourceid", nil) and TryGet(resources, "villainActionId", nil) == cost then
        return true
    end

    return false
end

function AI:CanUseVillainAction(context, actor, ability, abilityInfo, symbols)
    local token = actor and actor.token
    if not IsTokenValid(token) then
        return false, "villain action owner is invalid"
    end

    local key = self:VillainActionKey(abilityInfo or ability)
    if key == nil or key == "" then
        return false, "villain action slot is missing"
    end

    local resource = RawGlobal("CharacterResource")
    local budget = SafeCall(function()
        return resource.GetVillainActions()
    end, context and context.villainActions or 0)
    if (budget or 0) <= 0 then
        return false, "no villain actions available"
    end

    if self:VillainActionUsed(token, key) then
        return false, "villain action already used this encounter"
    end

    local costInfo = SafeCall(function()
        return ability:GetCost(token, symbols or { mode = 1 })
    end, nil)
    if costInfo == nil then
        return true, nil
    end

    if costInfo.cannotMove == true then
        return false, "villain action movement cost unavailable"
    end

    if costInfo.outOfAmmo == true then
        return false, "villain action ammunition unavailable"
    end

    local ignoredUnaffordable = false
    for _,entry in ipairs(costInfo.details or {}) do
        if entry.canAfford == false then
            if VillainActionIgnoredCostEntry(entry, ability, resource) then
                ignoredUnaffordable = true
            else
                return false, "villain action secondary resource unavailable"
            end
        end
    end

    if costInfo.canAfford == false and not ignoredUnaffordable then
        return false, "villain action secondary resource unavailable"
    end

    return true, nil
end

function AI:IsMaliciousStrikeName(name)
    return string.find(Lower(name or ""), "malicious strike", 1, true) ~= nil
end

function AI:IsBrutalEffectivenessName(name)
    return string.find(Lower(name or ""), "brutal effectiveness", 1, true) ~= nil
end

function AI:IsSoloActionName(name)
    return string.find(Lower(name or ""), "solo action", 1, true) ~= nil
end

function AI:IsDefendName(name)
    return string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1") == "defend"
end

function AI:IsAidAttackName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "aid attack" or name == "aid an attack"
end

function AI:IsShiftName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "shift"
        or name == "move - shift"
        or name == "disengage"
        or name == "move - disengage"
        or string.find(name, "shift", 1, true) ~= nil
        or string.find(name, "disengage", 1, true) ~= nil
end

function AI:IsEscapeGrabName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "escape grab"
end

function AI:IsHideName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "hide"
end

function AI:IsSearchForHiddenName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "search"
        or name == "search for hidden"
        or name == "search for hidden creatures"
end

function AI:IsStandUpName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "stand up"
end

function AI:IsAdvanceName(name)
    name = string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1")
    return name == "advance"
        or name == "move - advance"
        or name == "use a move action"
        or name == "move action"
        or name == "move speed"
        or name == "move"
end

function AI:IsRangedFreeStrikeName(name)
    return string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1") == "ranged free strike"
end

function AI:IsMeleeFreeStrikeName(name)
    return string.gsub(Lower(name or ""), "^%s*(.-)%s*$", "%1") == "melee free strike"
end

function AI:ProneConditionId()
    local conditionType = RawGlobal("CharacterCondition")
    if conditionType == nil then
        return nil
    end

    local conditionsTable = SafeCall(function()
        return dmhub.GetTable(conditionType.tableName)
    end, nil)
    if conditionsTable == nil then
        return nil
    end

    for conditionid,conditionInfo in unhidden_pairs(conditionsTable) do
        if Lower(TryGet(conditionInfo, "name", "")) == "prone" then
            return conditionid
        end
    end

    return nil
end

function AI:TokenIsProne(token)
    if not IsTokenValid(token) then
        return false
    end

    return SafeCall(function()
        return token.properties:HasNamedCondition("Prone")
    end, TryGet(token.properties, "_tmp_prone", false) == true)
end

function AI:TokenCannotStand(token)
    if not IsTokenValid(token) then
        return true
    end

    if SafeCall(function()
        return token.properties:HasNamedCondition("Restrained")
    end, false) then
        return true
    end

    local conditionType = RawGlobal("CharacterCondition")
    local proneid = self:ProneConditionId()
    if conditionType == nil or proneid == nil then
        return false
    end

    local riderid = SafeCall(function()
        return conditionType.GetRiderIdFromName(proneid, "Cannot Stand")
    end, nil)
    if riderid ~= nil and SafeCall(function()
        return token.properties:ConditionHasRider(proneid, riderid)
    end, false) then
        return true
    end

    local riders = SafeCall(function()
        return token.properties:GetConditionRiders(proneid)
    end, nil)
    if riders == nil then
        return false
    end

    local ridersTable = SafeCall(function()
        return dmhub.GetTable(conditionType.ridersTableName)
    end, nil)
    if ridersTable == nil then
        return false
    end

    for _,id in ipairs(riders) do
        if Lower(TryGet(ridersTable[id], "name", "")) == "cannot stand" then
            return true
        end
    end

    return false
end

function AI:ShouldUseStandUp(actor)
    return actor ~= nil and self:TokenIsProne(actor.token) and not self:TokenCannotStand(actor.token)
end

function AI:IsShiftAbilityInfo(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    local name = TrimLower(abilityInfo.name or "")
    if self:IsShiftName(name) then
        return true
    end

    for _,behavior in ipairs(TryGet(abilityInfo.ability, "behaviors", {}) or {}) do
        if TryGet(behavior, "typeName", "") == "ActivatedAbilityRelocateCreatureBehavior"
            and Lower(TryGet(behavior, "movementType", "") or "") == "shift"
        then
            return true
        end
    end

    return false
end

function AI:AbilityBlockedByActorCondition(actor, abilityInfo)
    if actor == nil or actor.token == nil or abilityInfo == nil or self.TargetHasCondition == nil then
        return nil
    end

    if self:IsShiftAbilityInfo(abilityInfo) and self:TargetHasCondition(actor.token, "Slowed") then
        return "slowed creature cannot shift"
    end

    return nil
end

function AI:IsAdvanceAbilityInfo(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    local name = string.gsub(Lower(abilityInfo.name or ""), "^%s*(.-)%s*$", "%1")
    if not self:IsAdvanceName(name) then
        return false
    end

    local cost = self:AbilityActionCost(abilityInfo)
    if cost == "action" or cost == "maneuver" or cost == "movement" then
        return true
    end

    return self:IsAdvanceName(name) and abilityInfo.hasInvoke
end

function AI:IsMovementPromptAbility(ability)
    if ability == nil then
        return false
    end

    return self:IsDirectorMovementPromptAbility(ability)
end

function AI:IsForcedMovementPromptAbility(ability)
    if ability == nil then
        return false
    end

    local name = Lower(TryGet(ability, "name", ""))
    if string.find(name, "push", 1, true) ~= nil
        or string.find(name, "pull", 1, true) ~= nil
        or string.find(name, "slide", 1, true) ~= nil
    then
        return true
    end

    return TryGet(ability, "forcedMovement", nil) ~= nil
end

function AI:IsDirectorMovementPromptAbility(ability)
    if ability == nil then
        return false
    end

    if self:IsForcedMovementPromptAbility(ability) then
        return false
    end

    local name = string.gsub(Lower(TryGet(ability, "name", "")), "^%s*(.-)%s*$", "%1")
    if self:IsAdvanceName(name)
        or self:IsShiftName(name)
        or name == "charge"
        or name == "jump"
        or name == "teleport"
        or name == "dig"
        or name == "burrow"
        or string.find(name, "move speed", 1, true) ~= nil
        or string.find(name, "movement", 1, true) ~= nil
        or string.find(name, "burrow", 1, true) ~= nil
    then
        return true
    end

    local targetType = Lower(TryGet(ability, "targetType", "") or "")
    if targetType ~= "emptyspace" and targetType ~= "emptyspacefriend" and targetType ~= "anyspace" then
        return false
    end

    for _,behavior in ipairs(TryGet(ability, "behaviors", {}) or {}) do
        if TryGet(behavior, "typeName", "") == "ActivatedAbilityRelocateCreatureBehavior" then
            local movementType = Lower(TryGet(behavior, "movementType", "") or "")
            if movementType == "move"
                or movementType == "shift"
                or movementType == "jump"
                or movementType == "teleport"
                or movementType == "relocate"
                or movementType == "dig"
                or movementType == "burrow"
            then
                return true
            end
        end
    end

    return false
end

function AI:CurrentRoundNumber(context, state)
    return self.Ledger:CurrentRoundNumber(self, context, state)
end

function AI:MaliciousStrikeBlocked(context)
    return self.Ledger:MaliciousStrikeBlocked(self, context)
end

function AI:MarkMaliciousStrikeUsed(context)
    return self.Ledger:MarkMaliciousStrikeUsed(self, context)
end

function AI:ResourceNumber(abilityInfo, fallback)
    local raw = TryGet(TryGet(abilityInfo, "ability", nil), "resourceNumber", fallback or 0)
    local result = tonumber(raw)
    if result == nil then
        result = tonumber(string.match(tostring(raw or ""), "%d+"))
    end

    return result or fallback or 0
end

function AI:MaliceCost(abilityInfo)
    return math.max(1, self:ResourceNumber(abilityInfo, 1))
end

function AI:StartTurnMaliceKey(context)
    return self.Ledger:StartTurnMaliceKey(self, context)
end

function AI:HasUsedStartTurnMalice(context)
    return self.Ledger:HasUsedStartTurnMalice(self, context)
end

function AI:MarkStartTurnMaliceUsed(context)
    return self.Ledger:MarkStartTurnMaliceUsed(self, context)
end

function AI:AbilityActionCost(abilityInfo)
    return self.Ledger:AbilityActionCost(self, abilityInfo)
end

function AI:SyncTurnMemoryFromResources(actor, options)
    return self.Ledger:SyncTurnMemoryFromResources(self, actor, options)
end

function AI:NewTurnMemory()
    return self.Ledger:NewTurnMemory()
end

function AI:ActorActionEconomyComplete(actor)
    return self.Ledger:ActorActionEconomyComplete(self, actor)
end

function AI:ActorEconomySummary(actor)
    return self.Ledger:ActorEconomySummary(self, actor)
end

function AI:CanUseActionCost(actor, abilityInfo, explicitCost)
    return self.Ledger:CanSpend(self, actor, abilityInfo, explicitCost)
end

function AI:IsPreferredByOverride(actor, abilityInfo)
    if actor == nil or actor.override == nil or abilityInfo == nil then
        return false
    end

    local preferred = actor.override.preferredAbilities
    if preferred == nil then
        return false
    end

    if type(preferred) == "string" then
        return Lower(preferred) == Lower(abilityInfo.name)
    end

    if type(preferred) == "table" then
        for k,v in pairs(preferred) do
            if (type(k) == "string" and Lower(k) == Lower(abilityInfo.name) and v ~= false) or (type(v) == "string" and Lower(v) == Lower(abilityInfo.name)) then
                return true
            end
        end
    end

    return false
end

function AI:TokenRoleTag(tok)
    if tok == nil or tok.properties == nil then
        return "standard", "standard"
    end

    local role = SafeCall(function()
        return tok.properties:Role()
    end, nil)
    role = Lower(role)
    if role == "" or role == "none" or role == "hero" then
        local roleText = Lower(TryGet(tok.properties, "role", ""))
        local first, second = string.match(roleText, "^(%S+)%s+(%S+)")
        role = second or first or "standard"
    end

    local organization = SafeCall(function()
        return tok.properties:Organization()
    end, nil)
    organization = Lower(organization)
    if organization == "" then
        organization = string.match(Lower(TryGet(tok.properties, "role", "")), "^(%S+)") or "standard"
    end

    return role, organization
end

function AI:IsFragileRole(role, organization)
    role = Lower(role)
    organization = Lower(organization)
    return role == "artillery"
        or role == "controller"
        or role == "hexer"
        or role == "support"
        or organization == "leader"
end

function AI:IsFragileAllyToken(tok)
    if not IsTokenValid(tok) then
        return false
    end

    local role, organization = self:TokenRoleTag(tok)
    if self:IsFragileRole(role, organization) then
        return true
    end

    return CurrentStamina(tok) <= MaxStamina(tok) * 0.45
end

function AI:DefendScore(actor)
    if actor == nil then
        return 0
    end

    local score = 0
    for _,ally in ipairs(actor.allies or {}) do
        if self:IsFragileAllyToken(ally) and Distance(actor.token, ally) <= 2 then
            score = math.max(score, 4)
        end
    end

    local plan = (actor.context and actor.context.encounterPlan) or self:GetEncounterPlan()
    if plan ~= nil and (plan.objective == "hold_them_off" or plan.objective == "assault_defenses" or plan.objective == "defeat_specific_foe") then
        if self:RoleIs(actor, "defender") or self:RoleIs(actor, "leader") then
            score = math.max(score, 3)
        end
    end

    return score
end

function AI:ShouldUseDefend(actor, abilityInfo)
    if abilityInfo == nil or not self:IsDefendName(abilityInfo.name) then
        return false
    end

    if not (self:RoleIs(actor, "defender") or self:RoleIs(actor, "leader")) then
        return false
    end

    return self:DefendScore(actor) > 0
end

function AI:ShouldUseAidAttack(actor, abilityInfo)
    if abilityInfo == nil or not self:IsAidAttackName(abilityInfo.name) then
        return false
    end

    if not (self:RoleIs(actor, "defender") or self:RoleIs(actor, "support") or self:RoleIs(actor, "leader")) then
        return false
    end

    return #(actor.enemies or {}) > 0
end

function AI:IsSuppressedUtilityAbility(actor, abilityInfo)
    if abilityInfo == nil or self:IsPreferredByOverride(actor, abilityInfo) then
        return false
    end

    local name = string.gsub(Lower(abilityInfo.name or ""), "^%s*(.-)%s*$", "%1")
    if self:IsDefendName(name) then
        return not self:ShouldUseDefend(actor, abilityInfo)
    end

    if self:IsAidAttackName(name) then
        return not self:ShouldUseAidAttack(actor, abilityInfo)
    end

    if self:IsStandUpName(name) then
        return not self:ShouldUseStandUp(actor)
    end

    if self:IsAdvanceAbilityInfo(abilityInfo) then
        return false
    end

    return self.suppressedUtilityAbilities[name] == true
end

function AI:MarkActionCostUsed(actor, candidate)
    return self.Ledger:Spend(self, actor, candidate)
end

function AI:CriticalNaturalRoll(symbols, finishOptions)
    return self.Ledger:CriticalNaturalRoll(self, symbols, finishOptions)
end

function AI:RefreshMainActionResource(actor, note)
    return self.Ledger:RefreshMainActionResource(self, actor, note)
end

function AI:ApplyCriticalMainActionRefresh(actor, candidate, symbols, finishOptions)
    return self.Ledger:ApplyCriticalActionRefresh(self, actor, candidate, symbols, finishOptions)
end

function AI:HasUsefulMainActionAfterSoloAction(context, actor)
    return self.Ledger:HasUsefulMainActionAfterSoloAction(self, context, actor)
end

function AI:ShouldUseSoloActionNow(context, actor, abilityInfo, options)
    return self.Ledger:SoloActionAvailable(self, context, actor, abilityInfo, options)
end

function AI:ApplySoloActionMainActionRefresh(actor, context)
    return self.Ledger:ApplySoloActionMainActionRefresh(self, actor, context)
end

function AI:IsStartTurnMaliceAbility(abilityInfo)
    if abilityInfo == nil or not abilityInfo.isMalice or abilityInfo.isVillain then
        return false
    end

    return abilityInfo.isStartTurnMalice == true
end

function AI:IsSpecialMaliceFeature(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    return abilityInfo.isMonsterGroupMalice == true or abilityInfo.isStartTurnMalice == true
end

function AI:IsAutomatableStartTurnMaliceAbility(abilityInfo)
    if abilityInfo == nil or not self:IsStartTurnMaliceAbility(abilityInfo) then
        return false
    end

    return self:IsMaliciousStrikeName(abilityInfo.name)
        or self:IsBrutalEffectivenessName(abilityInfo.name)
end

function AI:AbilityUsesNonCreatureTargeting(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    if self:IsAdvanceAbilityInfo(abilityInfo) then
        return false
    end

    local targetType = Lower(abilityInfo.targetType or "")
    return targetType ~= ""
        and targetType ~= "target"
        and targetType ~= "creature"
        and targetType ~= "self"
end

function AI:AbilityUsesManualPromptTargeting(abilityInfo)
    if abilityInfo == nil or self:IsAdvanceAbilityInfo(abilityInfo) then
        return false
    end

    if self:IsSearchForHiddenName(abilityInfo.name) then
        return false
    end

    if self:IsDirectorMovementPromptAbility(abilityInfo.ability) then
        return false
    end

    local targetType = Lower(abilityInfo.targetType or "")
    if self.IsAreaAbilityInfo ~= nil and self:IsAreaAbilityInfo(abilityInfo) then
        return false
    end

    if abilityInfo.hasAura or abilityInfo.isArea then
        return true
    end

    if targetType == "all"
        or targetType == "line"
        or targetType == "cone"
        or targetType == "cube"
        or targetType == "sphere"
        or targetType == "cylinder"
    then
        return true
    end

    if targetType == "map" or targetType == "areatemplate" then
        return true
    end

    if targetType == "emptyspace" or targetType == "emptyspacefriend" or targetType == "anyspace" then
        return true
    end

    return targetType ~= ""
        and targetType ~= "target"
        and targetType ~= "creature"
        and targetType ~= "self"
end

function AI:AbilityHasPromptRisk(abilityInfo)
    if abilityInfo == nil then
        return true
    end

    local hasRisk = false
    if abilityInfo.requiresPrompt or abilityInfo.manualPromptRisk then
        hasRisk = true
    end

    if abilityInfo.isMalice and abilityInfo.hasInvoke then
        hasRisk = true
    end

    if self:AbilityUsesNonCreatureTargeting(abilityInfo) then
        hasRisk = true
    end

    return hasRisk
end

function AI:PromptInvokeAbility(behavior)
    if behavior == nil then
        return nil
    end

    local customAbility = TryGet(behavior, "customAbility", nil)
    if customAbility ~= nil then
        return customAbility
    end

    if TryGet(behavior, "abilityType", nil) == "standard" and dmhub ~= nil and dmhub.GetTable ~= nil then
        local standard = dmhub.GetTable("standardAbilities")
        local id = TryGet(behavior, "standardAbility", nil)
        if standard ~= nil and id ~= nil then
            return standard[id]
        end
    end

    return nil
end

function AI:PromptInvokeBehaviorIsPrompted(behavior)
    if behavior == nil then
        return false
    end

    local targeting = TryGet(behavior, "targeting", "prompt")
    return targeting == "prompt" or targeting == "prompt_inherit" or TryGet(behavior, "promptWhenResolving", false)
end

function AI:PromptInvokeBehaviorName(behavior)
    local ability = self:PromptInvokeAbility(behavior)
    return Lower(TryGet(ability, "name", TryGet(behavior, "namedAbility", TryGet(behavior, "standardAbility", ""))) or "")
end

function AI:PromptInvokeBehaviorIsMovement(behavior)
    if not self:PromptInvokeBehaviorIsPrompted(behavior) then
        return false
    end

    local ability = self:PromptInvokeAbility(behavior)
    if self:IsDirectorMovementPromptAbility(ability) then
        return true
    end

    local name = string.gsub(self:PromptInvokeBehaviorName(behavior), "^%s*(.-)%s*$", "%1")
    return self:IsAdvanceName(name)
        or name == "charge"
        or name == "shift"
        or name == "jump"
        or name == "teleport"
        or name == "dig"
        or name == "burrow"
        or string.find(name, "move speed", 1, true) ~= nil
        or string.find(name, "movement", 1, true) ~= nil
end

function AI:AbilityHasNestedMovementPrompt(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    for _,behavior in ipairs(TryGet(abilityInfo.ability, "behaviors", {}) or {}) do
        if TryGet(behavior, "typeName", "") == "ActivatedAbilityInvokeAbilityBehavior"
            and self:PromptInvokeBehaviorIsMovement(behavior)
        then
            return true
        end
    end

    return false
end

local AREA_PROMPT_TARGET_TYPES = {
    all = true,
    line = true,
    cone = true,
    cube = true,
    sphere = true,
    cylinder = true,
    areatemplate = true,
}

local function IsAreaPromptTargetType(targetType)
    return AREA_PROMPT_TARGET_TYPES[Lower(targetType or "")] == true
end

function AI:PromptInvokeBehaviorDisplayName(behavior)
    local ability = self:PromptInvokeAbility(behavior)
    return tostring(TryGet(ability, "name", TryGet(behavior, "namedAbility", TryGet(behavior, "standardAbility", "prompt"))) or "prompt")
end

function AI:AnalyzePromptInvokeAbility(behavior, context, actor)
    if behavior == nil or self.AnalyzeAbility == nil then
        return nil, nil
    end

    local ability = self:PromptInvokeAbility(behavior)
    if ability == nil then
        return nil, nil
    end

    local promptActor = actor
    if actor ~= nil and actor.token ~= nil then
        promptActor = {
            token = actor.token,
            role = actor.role,
            organization = actor.organization,
            profile = actor.profile,
            allies = actor.allies or {},
            enemies = actor.enemies or {},
            context = context,
        }
    end

    local abilityInfo = SafeCall(function()
        return self:AnalyzeAbility(promptActor, ability)
    end, nil)

    return ability, abilityInfo
end

function AI:IsSafeAutoPromptInvokeBehavior(behavior, context, actor)
    if behavior == nil then
        return true
    end

    if not self:PromptInvokeBehaviorIsPrompted(behavior) then
        return true
    end

    if TryGet(behavior, "promptWhenResolving", false) then
        return false
    end

    if self:PromptInvokeBehaviorIsMovement(behavior) then
        return true
    end

    local ability = self:PromptInvokeAbility(behavior)
    local name = self:PromptInvokeBehaviorName(behavior)
    if string.find(name, "push", 1, true) ~= nil
        or string.find(name, "pull", 1, true) ~= nil
        or string.find(name, "slide", 1, true) ~= nil
        or self:IsForcedMovementPromptAbility(ability)
    then
        return true
    end

    if ability ~= nil and self.AnalyzePromptInvokeAbility ~= nil and self.IsAreaAbilityInfo ~= nil then
        local _, abilityInfo = self:AnalyzePromptInvokeAbility(behavior, context, actor)
        if self:IsAreaAbilityInfo(abilityInfo)
            and (abilityInfo.isArea == true or abilityInfo.hasAura == true or not IsAreaPromptTargetType(abilityInfo.targetType))
        then
            local shapeName = self.AreaShapeName ~= nil and self:AreaShapeName(abilityInfo) or ""
            if shapeName ~= "" and shapeName ~= "areatemplate" then
                return true
            end
        end
    end

    local targetType = Lower(TryGet(ability, "targetType", "target") or "target")
    return targetType == "target" or targetType == "creature" or targetType == "self"
end

function AI:NestedPromptManualPromptReason(abilityInfo, context, actor)
    if abilityInfo == nil then
        return nil
    end

    for _,behavior in ipairs(TryGet(abilityInfo.ability, "behaviors", {}) or {}) do
        if TryGet(behavior, "typeName", "") == "ActivatedAbilityInvokeAbilityBehavior"
            and self.PromptInvokeBehaviorIsPrompted ~= nil
            and self:PromptInvokeBehaviorIsPrompted(behavior)
            and not (self.PromptInvokeBehaviorIsMovement ~= nil and self:PromptInvokeBehaviorIsMovement(behavior))
            and not self:IsSafeAutoPromptInvokeBehavior(behavior, context, actor)
        then
            return "nested prompt: " .. tostring(self:PromptInvokeBehaviorDisplayName(behavior))
        end
    end

    return nil
end

function AI:IsStandardGrabAbilityInfo(abilityInfo)
    if abilityInfo == nil then
        return false
    end

    if TrimLower(abilityInfo.name or "") == "grab" then
        return true
    end

    local ability = abilityInfo.ability
    local id = tostring(TryGet(ability, "guid", TryGet(ability, "id", "")) or "")
    return id == "1d642117-27c8-49c5-b37b-a8fc94b5ca5b"
end

function AI:IsAutoResolvableGrabModePrompt(abilityInfo)
    if not self:IsStandardGrabAbilityInfo(abilityInfo) then
        return false
    end

    local ability = abilityInfo and abilityInfo.ability
    if ability == nil or TryGet(ability, "multipleModes", false) == false then
        return false
    end

    local modeList = TryGet(ability, "modeList", nil)
    if type(modeList) ~= "table" or #modeList == 0 then
        return false
    end

    local hasAggressive = false
    local hasSafe = false
    for index,mode in ipairs(modeList) do
        local text = Lower(self:GrabModeText(mode, index))
        hasAggressive = hasAggressive or string.find(text, "aggressive", 1, true) ~= nil
        hasSafe = hasSafe or string.find(text, "safe", 1, true) ~= nil
    end

    return hasAggressive and hasSafe
end

function AI:IsAutoResolvableForcedMovementModePrompt(abilityInfo)
    if abilityInfo == nil or not abilityInfo.hasForcedMovement or self:IsStandardGrabAbilityInfo(abilityInfo) then
        return false
    end

    local ability = abilityInfo and abilityInfo.ability
    if ability == nil or TryGet(ability, "multipleModes", false) == false then
        return false
    end

    local modeList = TryGet(ability, "modeList", nil)
    if type(modeList) ~= "table" or #modeList == 0 then
        return false
    end

    local forcedModes = 0
    for index,mode in ipairs(modeList) do
        local text = Lower(self:GrabModeText(mode, index))
        if ExtractForcedMovementDistance(text) ~= nil then
            forcedModes = forcedModes + 1
        end
    end

    return forcedModes > 0
end

function AI:AbilityModeAvailable(actor, ability, mode)
    local condition = TryGet(mode, "condition", nil)
    if condition == nil or tostring(condition) == "" then
        return true
    end

    local executeGoblinScript = RawGlobal("ExecuteGoblinScript")
    if executeGoblinScript == nil or actor == nil or actor.token == nil or actor.token.properties == nil then
        return false
    end

    local available = SafeCall(function()
        return executeGoblinScript(condition, actor.token.properties:LookupSymbol(), 1, "Grab mode condition")
    end, 0)

    if type(available) == "boolean" then
        return available
    end

    return (tonumber(available) or 0) > 0
end

function AI:GrabModeText(mode, index)
    local text = TryGet(mode, "text", TryGet(mode, "name", nil))
    if text == nil or tostring(text) == "" then
        return "mode " .. tostring(index)
    end

    return tostring(text)
end

function AI:AvailableGrabModeSelections(actor, abilityInfo)
    local result = {}
    local modeList = TryGet(abilityInfo and abilityInfo.ability, "modeList", {}) or {}

    for index,mode in ipairs(modeList) do
        local text = self:GrabModeText(mode, index)
        local lower = Lower(text)
        if string.find(lower, "skip", 1, true) == nil and self:AbilityModeAvailable(actor, abilityInfo.ability, mode) then
            result[#result+1] = {
                index = index,
                text = text,
                lower = lower,
            }
        end
    end

    return result
end

function AI:AvailableForcedMovementModeSelections(actor, abilityInfo)
    local result = {}
    local modeList = TryGet(abilityInfo and abilityInfo.ability, "modeList", {}) or {}

    for index,mode in ipairs(modeList) do
        local text = self:GrabModeText(mode, index)
        local lower = Lower(text)
        local distance = ExtractForcedMovementDistance(lower)
        if distance ~= nil
            and string.find(lower, "skip", 1, true) == nil
            and self:AbilityModeAvailable(actor, abilityInfo.ability, mode)
        then
            result[#result+1] = {
                index = index,
                text = text,
                lower = lower,
                distance = math.max(1, distance),
            }
        end
    end

    return result
end

function AI:StandardGrabTargetAlreadyControlled(targetToken)
    if targetToken == nil then
        return false
    end

    if self.TargetHasCondition ~= nil then
        return self:TargetHasCondition(targetToken, "Grabbed") or self:TargetHasCondition(targetToken, "Restrained")
    end

    return SafeCall(function()
        return targetToken.properties ~= nil
            and (targetToken.properties:HasNamedCondition("Grabbed") or targetToken.properties:HasNamedCondition("Restrained"))
    end, false)
end

function AI:ActiveGrabbedHostileControlledByActor(context, actor)
    local actorToken = actor and actor.token
    if actorToken == nil then
        return nil
    end

    local tokens = {}
    if context ~= nil and type(context.allCombatTokens) == "table" then
        tokens = context.allCombatTokens
    elseif type(actor.enemies) == "table" then
        tokens = actor.enemies
    end

    for _,tok in ipairs(tokens or {}) do
        if tok ~= actorToken and IsTokenValid(tok) and not TokensFriendly(actorToken, tok) then
            local grabbed = false
            if self.TargetHasCondition ~= nil then
                grabbed = self:TargetHasCondition(tok, "Grabbed") == true
            else
                grabbed = SafeCall(function()
                    return tok.properties ~= nil and tok.properties:HasNamedCondition("Grabbed")
                end, false)
            end

            if grabbed and self.ConditionCasterMatchesToken ~= nil and self:ConditionCasterMatchesToken(tok, "Grabbed", actorToken) then
                return tok
            end
        end
    end

    return nil
end

function AI:ChooseGrabModeSelection(context, actor, abilityInfo, targetToken, scoreInfo)
    if not self:IsAutoResolvableGrabModePrompt(abilityInfo) then
        return nil, "not an auto-resolvable Grab mode prompt"
    end

    local modes = self:AvailableGrabModeSelections(actor, abilityInfo)
    if #modes == 0 then
        return nil, "no available non-skip Grab mode"
    end

    if #modes == 1 then
        return {
            index = modes[1].index,
            text = modes[1].text,
            reason = "only available Grab mode",
        }
    end

    local safeMode = nil
    local aggressiveMode = nil
    for _,mode in ipairs(modes) do
        if safeMode == nil and string.find(mode.lower, "safe", 1, true) ~= nil then
            safeMode = mode
        end
        if aggressiveMode == nil and string.find(mode.lower, "aggressive", 1, true) ~= nil then
            aggressiveMode = mode
        end
    end

    local staminaRatio = 1
    if actor ~= nil and actor.token ~= nil then
        staminaRatio = CurrentStamina(actor.token) / math.max(1, MaxStamina(actor.token))
    end

    local alreadyControlled = self:StandardGrabTargetAlreadyControlled(targetToken)
    if alreadyControlled and safeMode ~= nil then
        return {
            index = safeMode.index,
            text = safeMode.text,
            reason = "target already controlled",
        }
    end

    if staminaRatio < 0.45 and safeMode ~= nil then
        return {
            index = safeMode.index,
            text = safeMode.text,
            reason = "grabber below 45% stamina",
        }
    end

    local targetSpeed = 0
    if targetToken ~= nil and self.TargetSpeed ~= nil then
        targetSpeed = self:TargetSpeed(targetToken)
    elseif targetToken ~= nil and targetToken.properties ~= nil then
        targetSpeed = SafeCall(function()
            return targetToken.properties:CurrentMovementSpeed()
        end, 0) or 0
    end

    local scoreTotal = tonumber(scoreInfo and scoreInfo.total) or 0
    if aggressiveMode ~= nil and staminaRatio >= 0.45 and (targetSpeed >= 6 or scoreTotal >= 6) then
        return {
            index = aggressiveMode.index,
            text = aggressiveMode.text,
            reason = Pick(targetSpeed >= 6, "high-mobility target", "high-value target"),
        }
    end

    local chosen = safeMode or aggressiveMode or modes[1]
    return {
        index = chosen.index,
        text = chosen.text,
        reason = "default tactical Grab mode",
    }
end

function AI:ChooseForcedMovementModeSelection(context, actor, abilityInfo, targetToken, scoreInfo)
    if abilityInfo == nil or not abilityInfo.hasForcedMovement or targetToken == nil then
        return nil, "not a forced movement mode prompt"
    end

    local modes = self:AvailableForcedMovementModeSelections(actor, abilityInfo)
    if #modes == 0 then
        return nil, "no forced movement mode available"
    end

    local best = nil
    for _,mode in ipairs(modes) do
        local destinationScore = 0
        if self.BestForcedMovementDestinationScore ~= nil then
            destinationScore = self:BestForcedMovementDestinationScore(context, actor, targetToken, mode.distance)
        end

        local score = destinationScore + mode.distance * 0.05
        if best == nil
            or score > best.score
            or (score == best.score and mode.distance > best.distance)
            or (score == best.score and mode.distance == best.distance and mode.index < best.index)
        then
            best = {
                index = mode.index,
                text = mode.text,
                distance = mode.distance,
                destinationScore = destinationScore,
                score = score,
            }
        end
    end

    if best == nil then
        return nil, "no forced movement mode scored"
    end

    if scoreInfo ~= nil and best.destinationScore ~= nil then
        AddScore(scoreInfo, "forced movement mode", math.max(-1, math.min(3, best.destinationScore * 0.15)))
    end

    return {
        index = best.index,
        text = best.text,
        distance = best.distance,
        reason = string.format("best forced movement destination score %0.1f", best.destinationScore or 0),
    }
end

local function SuppressModePromptForAnalysis(ability)
    if ability == nil then
        return nil
    end

    SafeCall(function()
        ability._directorResolvedModePrompt = true
        ability.RequiresPromptWhenCast = function()
            return false
        end
    end, nil)

    return ability
end

function AI:PrepareModeAbilityForAnalysis(abilityInfo, modeIndex)
    local ability = abilityInfo and abilityInfo.ability
    if ability == nil or tonumber(modeIndex) == nil then
        return nil
    end

    local baseClone = SafeCall(function()
        return ability:MakeTemporaryClone()
    end, ability)
    local selectedAbility = SafeCall(function()
        return baseClone:SwitchModes(tonumber(modeIndex))
    end, baseClone) or baseClone

    if selectedAbility == ability then
        selectedAbility = SafeCall(function()
            return ability:MakeTemporaryClone()
        end, ability)
    end

    return SuppressModePromptForAnalysis(selectedAbility)
end

local function ModeLooksResourceIntensive(modeText, selectedInfo)
    local lower = Lower(modeText or "")
    if selectedInfo ~= nil and (selectedInfo.isMalice or selectedInfo.usesMaliceResource) then
        return true
    end

    return string.find(lower, "malice", 1, true) ~= nil
        or string.find(lower, "spend", 1, true) ~= nil
        or string.find(lower, "cost", 1, true) ~= nil
end

local function ModeSelectionReason(modeText, resourceIntensive)
    if resourceIntensive then
        return "selected safe resource mode"
    end

    return "selected safe default mode"
end

local function CopyModeActionType(actionType)
    if type(actionType) ~= "table" then
        return nil
    end

    local result = {}
    for key,value in pairs(actionType) do
        if type(value) == "table" then
            local nested = {}
            for nestedKey,nestedValue in pairs(value) do
                nested[nestedKey] = nestedValue
            end
            result[key] = nested
        else
            result[key] = value
        end
    end
    return result
end

function AI:ChooseTopLevelModeSelection(context, actor, abilityInfo)
    if abilityInfo == nil then
        return nil, nil, nil
    end

    if abilityInfo.autoResolvableModePrompt
        or self:IsAutoResolvableGrabModePrompt(abilityInfo)
        or self:IsAutoResolvableForcedMovementModePrompt(abilityInfo)
    then
        return nil, nil, nil
    end

    local ability = abilityInfo.ability
    if ability == nil or TryGet(ability, "multipleModes", false) == false or not abilityInfo.requiresPrompt then
        return nil, nil, nil
    end
    local baseActionType = SafeCall(function()
        return self:ResolveActionType(ability)
    end, nil)
    local baseActionCost = self.AbilityActionCost ~= nil and self:AbilityActionCost(abilityInfo) or nil

    local modeList = TryGet(ability, "modeList", nil)
    if type(modeList) ~= "table" or #modeList == 0 then
        return nil, "unresolved mode prompt: no modes exposed", nil
    end

    local safeModes = {}
    local details = {}
    for index,mode in ipairs(modeList) do
        local text = self:GrabModeText(mode, index)
        local lower = Lower(text)
        if string.find(lower, "skip", 1, true) ~= nil then
            details[#details+1] = tostring(index) .. " " .. text .. ": skip mode"
        elseif not self:AbilityModeAvailable(actor, ability, mode) then
            details[#details+1] = tostring(index) .. " " .. text .. ": mode condition unavailable"
        else
            local selectedAbility = self:PrepareModeAbilityForAnalysis(abilityInfo, index)
            local selectedInfo = nil
            if selectedAbility ~= nil then
                selectedInfo = SafeCall(function()
                    return self:AnalyzeAbility(actor, selectedAbility)
                end, nil)
            end

            if selectedInfo == nil then
                details[#details+1] = tostring(index) .. " " .. text .. ": mode analysis failed"
            else
                selectedInfo.baseAbility = ability
                selectedInfo.baseAbilityInfo = abilityInfo
                selectedInfo.topLevelModePromptResolved = true
                local selectedActionType = SafeCall(function()
                    return self:ResolveActionType(selectedAbility)
                end, nil)
                local selectedActionKind = selectedActionType and selectedActionType.kind
                local selectedActionCost = self.AbilityActionCost ~= nil and self:AbilityActionCost(selectedInfo) or nil
                if baseActionCost == "action"
                    and selectedActionCost == "none"
                    and selectedActionKind ~= "freeManeuver"
                    and selectedActionKind ~= "freeTriggered"
                    and selectedActionKind ~= "triggered"
                    and selectedActionKind ~= "malice"
                    and selectedActionKind ~= "solo"
                    and selectedInfo.isMalice ~= true
                    and selectedInfo.usesMaliceResource ~= true
                then
                    selectedInfo.semanticActionCost = "action"
                    selectedInfo.semanticActionType = CopyModeActionType(baseActionType) or { kind = "main" }
                    selectedInfo.isAction = true
                    selectedInfo.isManeuver = false
                end

                local symbols = { mode = index }
                if selectedInfo.isMalice then
                    symbols.charges = self:MaliceCost(selectedInfo)
                end

                local affordable = true
                if actor ~= nil and actor.token ~= nil then
                    affordable = AbilityCanAfford(selectedAbility, actor.token, symbols)
                    if not affordable and self.Ledger ~= nil and self.Ledger.CanAffordAbilityWithPendingGrant ~= nil then
                        affordable = self.Ledger:CanAffordAbilityWithPendingGrant(self, actor, selectedAbility, selectedInfo, symbols)
                    end
                end

                if affordable and selectedInfo.isMalice and context ~= nil and context.malice ~= nil and context.malice < self:MaliceCost(selectedInfo) then
                    affordable = false
                end

                local manualReason = self:AbilityManualPromptReason(selectedInfo, context, actor)
                local unsafeReason = nil
                if manualReason == nil then
                    unsafeReason = self:AbilityUnsafePromptReason(selectedInfo, context, actor)
                end

                if not affordable then
                    details[#details+1] = tostring(index) .. " " .. text .. ": cannot afford"
                elseif manualReason ~= nil then
                    details[#details+1] = tostring(index) .. " " .. text .. ": " .. tostring(manualReason)
                elseif unsafeReason ~= nil then
                    details[#details+1] = tostring(index) .. " " .. text .. ": " .. tostring(unsafeReason)
                else
                    local resourceIntensive = ModeLooksResourceIntensive(text, selectedInfo)
                    safeModes[#safeModes+1] = {
                        index = index,
                        text = text,
                        lower = lower,
                        selectedInfo = selectedInfo,
                        resourceIntensive = resourceIntensive,
                    }
                    details[#details+1] = tostring(index) .. " " .. text .. ": safe"
                end
            end
        end
    end

    table.sort(safeModes, function(a, b)
        if a.resourceIntensive ~= b.resourceIntensive then
            return not a.resourceIntensive
        end

        return a.index < b.index
    end)

    local chosen = safeModes[1]
    if chosen == nil then
        return nil, "unresolved mode prompt: no safe automatable mode (" .. table.concat(details, "; ") .. ")", nil
    end

    local modeSelection = {
        index = chosen.index,
        text = chosen.text,
        reason = ModeSelectionReason(chosen.text, chosen.resourceIntensive),
        topLevel = true,
    }
    chosen.selectedInfo.modeSelection = modeSelection
    chosen.selectedInfo.selectedModePromptReason = modeSelection.reason

    return modeSelection, nil, chosen.selectedInfo
end

function AI:AbilityHasUnsupportedPromptRisk(abilityInfo, context, actor)
    if abilityInfo == nil or not self:AbilityHasPromptRisk(abilityInfo) then
        return false
    end

    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        return capability ~= nil and capability.status == "blocked"
    end

    return abilityInfo.hasSummon == true
end

function AI:AbilityUnresolvedModePromptReason(abilityInfo)
    if abilityInfo == nil then
        return nil
    end

    if abilityInfo.autoResolvableModePrompt or abilityInfo.topLevelModePromptResolved or abilityInfo.modeSelection ~= nil then
        return nil
    end

    local ability = abilityInfo.ability
    if TryGet(ability, "multipleModes", false) and abilityInfo.requiresPrompt then
        return abilityInfo.modePromptSkipReason or "unresolved mode prompt"
    end

    return nil
end

function AI:AbilityUnsafePromptReason(abilityInfo, context, actor)
    if abilityInfo == nil then
        return nil
    end

    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        if capability ~= nil and capability.status == "blocked" then
            return capability.reason or "unresolved prompt"
        end
    end

    return nil
end

local function PromptTargetToken(target)
    if IsTokenValid(target) then
        return target
    end

    if type(target) ~= "table" then
        return nil
    end

    return target.token or target.tok
end

local function PromptTargetTokenMatches(left, right)
    if left == nil or right == nil then
        return false
    end

    if left == right then
        return true
    end

    local leftId = TokenId(left)
    local rightId = TokenId(right)
    return leftId ~= nil and rightId ~= nil and leftId == rightId
end

local function PromptTargetListContainsToken(list, token)
    if type(list) ~= "table" or token == nil then
        return false
    end

    for _,target in ipairs(list) do
        if PromptTargetTokenMatches(PromptTargetToken(target), token) then
            return true
        end
    end

    return false
end

local function SpecificTargetInvokeHasInheritedToken(options, token)
    if type(options) ~= "table" or token == nil then
        return false
    end

    return PromptTargetListContainsToken(TryGet(options, "targets", nil), token)
        or PromptTargetListContainsToken(TryGet(options, "targetArgs", nil), token)
        or PromptTargetListContainsToken(TryGet(options, "_directorCandidateTargets", nil), token)
end

local function ValidateSpecificTargetInvokeTargets(ai, abilityClone, options, targets)
    if type(targets) ~= "table" or #targets == 0 then
        return false, "specific-target invoke returned no inherited target"
    end

    for _,target in ipairs(targets) do
        if type(target) ~= "table" then
            return false, "specific-target invoke target was not a table"
        end

        local token = PromptTargetToken(target)
        if token == nil then
            return false, "specific-target invoke returned no token target"
        end

        if not IsTokenValid(token) then
            ai:Trace("prompt", "validate specific-target failed", {
                ability = TryGet(abilityClone, "name", "prompt"),
                target = TokenName(token),
                reason = "specific-target invoke target token was invalid",
            })
            return false, "specific-target invoke target token was invalid"
        end

        if not SpecificTargetInvokeHasInheritedToken(options, token) then
            ai:Trace("prompt", "validate specific-target failed", {
                ability = TryGet(abilityClone, "name", "prompt"),
                target = TokenName(token),
                reason = "specific-target invoke target was not inherited from parent candidate",
            })
            return false, "specific-target invoke target was not inherited from parent candidate"
        end
    end

    ai:Trace("prompt", "validate result passed", {
        ability = TryGet(abilityClone, "name", "prompt"),
        targets = #targets,
        reason = "specific-target invoke reused inherited target",
    })
    return true, nil
end

function AI:ValidatePromptResult(context, actor, invokerToken, casterToken, abilityClone, symbols, options, result)
    self:Trace("prompt", "validate result start", {
        ability = TryGet(abilityClone, "name", "prompt"),
        targetType = TryGet(abilityClone, "targetType", nil),
    })
    if type(result) ~= "table" then
        self:Trace("prompt", "validate result failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt policy returned no result" })
        return false, "prompt policy returned no result"
    end

    local promptActor = actor
    local abilityInfo = nil
    local promptAnalysisDone = false
    local function EnsurePromptAnalysis()
        if promptAnalysisDone then
            return promptActor, abilityInfo
        end

        promptAnalysisDone = true
        if abilityClone ~= nil and casterToken ~= nil and self.AnalyzeAbility ~= nil then
            promptActor = {
                token = casterToken,
                role = actor and actor.role,
                organization = actor and actor.organization,
                profile = actor and actor.profile,
                allies = actor and actor.allies or {},
                enemies = actor and actor.enemies or {},
                context = context,
            }
            abilityInfo = self:AnalyzeAbility(promptActor, abilityClone)
        end

        return promptActor, abilityInfo
    end

    local targets = result.targets
    if result._directorSpecificTargetInvoke == true and targets == nil then
        targets = result.targetArgs
    end
    if result._directorNestedPromptClass == "optional-child" and result._directorOptionalNestedPrompt == "skipped" then
        if targets == nil then
            targets = result.targetArgs
        end
        if type(targets) == "table" and #targets == 0 then
            self:Trace("prompt", "validate result passed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "optional child skipped" })
            return true, nil
        end
    end

    if targets == nil then
        if result.targetArea ~= nil then
            local analyzedActor, analyzedInfo = EnsurePromptAnalysis()
            if self.CheckAreaLegality ~= nil and analyzedInfo ~= nil and self:IsAreaAbilityInfo(analyzedInfo) then
                local areaLegality = self:CheckAreaLegality(context, analyzedActor, abilityClone, analyzedInfo, casterToken, casterToken and casterToken.loc, TryGet(result.targetArea, "origin", nil), result.targetArea, symbols or {}, {
                    phase = "prompt.validation",
                    allowEmpty = true,
                })
                self:Trace("prompt", "area legality check", {
                    ability = TryGet(abilityClone, "name", "prompt"),
                    allowed = areaLegality.ok == true,
                    reason = areaLegality.reason,
                    reasonCode = areaLegality.reasonCode,
                })
                if areaLegality.ok ~= true then
                    return false, areaLegality.reason or "prompt area was not legal"
                end
            end
            self:Trace("prompt", "validate result passed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "target area" })
            return true, nil
        end
        if result.improvements ~= nil or result.costOverride ~= nil then
            self:Trace("prompt", "validate result passed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "improvement or cost override" })
            return true, nil
        end
        self:Trace("prompt", "validate result failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt policy returned no targets" })
        return false, "prompt policy returned no targets"
    end

    if type(targets) ~= "table" or #targets == 0 then
        self:Trace("prompt", "validate result failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt policy returned no targets" })
        return false, "prompt policy returned no targets"
    end

    if result._directorSpecificTargetInvoke == true then
        return ValidateSpecificTargetInvokeTargets(self, abilityClone, options or {}, targets)
    end

    local targetType = Lower(TryGet(abilityClone, "targetType", "") or "")
    local needsLocTarget = false
    local needsTokenTarget = targetType == "target" or targetType == "creature" or targetType == "self"
    if self:IsDirectorMovementPromptAbility(abilityClone) or self:IsForcedMovementPromptAbility(abilityClone) then
        needsLocTarget = true
        needsTokenTarget = false
    elseif targetType == "emptyspace" or targetType == "emptyspacefriend" or targetType == "anyspace" or targetType == "map" then
        needsLocTarget = true
        needsTokenTarget = false
    end

    if not needsLocTarget then
        for _,behavior in ipairs(TryGet(abilityClone, "behaviors", {}) or {}) do
            if TryGet(behavior, "typeName", "") == "ActivatedAbilityRelocateCreatureBehavior" then
                local movementType = Lower(TryGet(behavior, "movementType", "") or "")
                if movementType ~= "teleport" and movementType ~= "relocate" then
                    needsLocTarget = true
                    needsTokenTarget = false
                    break
                end
            end
        end
    end

    promptActor, abilityInfo = EnsurePromptAnalysis()

    if result.targetArea ~= nil and self.CheckAreaLegality ~= nil and abilityInfo ~= nil and self:IsAreaAbilityInfo(abilityInfo) then
        local areaLegality = self:CheckAreaLegality(context, promptActor, abilityClone, abilityInfo, casterToken, casterToken and casterToken.loc, TryGet(result.targetArea, "origin", nil), result.targetArea, symbols or {}, {
            phase = "prompt.validation",
            targets = targets,
        })
        self:Trace("prompt", "area legality check", {
            ability = TryGet(abilityClone, "name", "prompt"),
            allowed = areaLegality.ok == true,
            reason = areaLegality.reason,
            reasonCode = areaLegality.reasonCode,
        })
        if areaLegality.ok ~= true then
            return false, areaLegality.reason or "prompt area was not legal"
        end
    end

    for _,target in ipairs(targets) do
        if type(target) ~= "table" then
            self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt target was not a table" })
            return false, "prompt target was not a table"
        end

        if needsLocTarget and target.loc == nil then
            self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "movement prompt returned no destination location" })
            return false, "movement prompt returned no destination location"
        end

        if needsTokenTarget and target.token == nil then
            self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "creature prompt returned no target token" })
            return false, "creature prompt returned no target token"
        end

        if target.token ~= nil then
            if not IsTokenValid(target.token) then
                self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), target = TokenName(target.token), reason = "prompt target token was invalid" })
                return false, "prompt target token was invalid"
            end

            if abilityClone ~= nil and casterToken ~= nil and self.CheckTargetLegality ~= nil and abilityInfo ~= nil then
                local legality = self:CheckTargetLegality(context, promptActor, abilityClone, abilityInfo, casterToken, target.token, symbols or {}, {
                    phase = "prompt.validation",
                })
                self:Trace("prompt", "target allowed check", {
                    ability = TryGet(abilityClone, "name", "prompt"),
                    target = TokenName(target.token),
                    allowed = legality.ok == true,
                    reason = legality.reason,
                    reasonCode = legality.reasonCode,
                })
                if legality.ok ~= true then
                    return false, legality.reason or "prompt target was not legal"
                end
            end
        elseif target.loc ~= nil then
            if TryGet(target.loc, "valid", true) == false or TryGet(target.loc, "isOnMap", true) == false then
                self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt target location was invalid" })
                return false, "prompt target location was invalid"
            end
        else
            self:Trace("prompt", "validate target failed", { ability = TryGet(abilityClone, "name", "prompt"), reason = "prompt target had no token or location" })
            return false, "prompt target had no token or location"
        end
    end

    self:Trace("prompt", "validate result passed", {
        ability = TryGet(abilityClone, "name", "prompt"),
        targets = #targets,
        needsLocTarget = needsLocTarget,
        needsTokenTarget = needsTokenTarget,
    })
    return true, nil
end

function AI:PromptPolicyCanHandle(context, actor, abilityInfo)
    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        return capability ~= nil and capability.status == "auto"
    end

    return not self:AbilityHasUnsupportedPromptRisk(abilityInfo, context, actor)
end

function AI:AbilityHasUnsafePromptRisk(abilityInfo, context, actor)
    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        return capability ~= nil and capability.status == "blocked"
    end

    return self:AbilityUnsafePromptReason(abilityInfo, context, actor) ~= nil
end

function AI:AbilityManualPromptReason(abilityInfo, context, actor)
    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        if capability ~= nil and capability.status == "manual" then
            return capability.reason or "manual targeting"
        end
    end

    return nil
end

function AI:AbilityNeedsManualPrompt(abilityInfo, context, actor)
    if self.AssessPromptCapability ~= nil then
        local capability = self:AssessPromptCapability(context, actor, abilityInfo)
        return capability ~= nil and capability.status == "manual"
    end

    return self:AbilityManualPromptReason(abilityInfo, context, actor) ~= nil
end

function AI:ScoreStartTurnMaliceAbility(context, actor, abilityInfo, candidate)
    local score = self.CandidateScoreTotal and self:CandidateScoreTotal(candidate) or (candidate and candidate.score) or 0
    local name = Lower(abilityInfo.name or "")
    local tuning = self:DifficultyTuning(context)
    local malice = self:MaliceScoreParts(context, abilityInfo)

    if string.find(name, "malicious strike", 1, true) ~= nil then
        score = score + ConstNumber("Score", "StartTurnMaliciousStrikeBase", 4) + HighestCharacteristic(actor.token.properties) * tuning.damageWeight
    elseif string.find(name, "brutal effectiveness", 1, true) ~= nil then
        score = score + ConstNumber("Score", "StartTurnBrutalEffectivenessBase", 3)
        if self:RoleIs(actor, "controller") or self:RoleIs(actor, "hexer") then
            score = score + ConstNumber("Score", "StartTurnBrutalEffectivenessRoleBonus", 2)
        end
    else
        score = score + ConstNumber("Score", "StartTurnMaliceWeightMultiplier", 1.5) * tuning.maliceWeight
    end

    score = score + malice.startTurnCost

    score = score + malice.unavailable

    return score
end

function AI:NextSelectedAbilityHasPotency(context, actor)
    if actor == nil then
        return false
    end

    actor.turnMemory = actor.turnMemory or {}
    if actor.turnMemory.nextSelectedAbilityHasPotency ~= nil then
        return actor.turnMemory.nextSelectedAbilityHasPotency
    end

    local candidates = self:FindCandidates(context, actor, { silent = true })

    local candidate = candidates[1]
    local result = true
    local movementOnly = false
    if candidate ~= nil then
        if self.CandidateMovementOnly ~= nil then
            movementOnly = self:CandidateMovementOnly(candidate)
        else
            movementOnly = candidate.movementOnly == true
        end
    end
    if candidate == nil or movementOnly or candidate.abilityInfo == nil then
        result = false
    else
        result = candidate.abilityInfo.hasPotency == true
    end

    actor.turnMemory.nextSelectedAbilityHasPotency = result
    return result
end

function AI:MaliceScoreParts(context, abilityInfo)
    local tuning = self:DifficultyTuning(context)
    local cost = self:MaliceCost(abilityInfo)
    local unavailable = 0
    if context ~= nil and context.malice ~= nil and context.malice < cost then
        unavailable = ConstNumber("Score", "MaliceUnavailablePenalty", -100)
    end

    return {
        cost = cost,
        impact = ConstNumber("Score", "MaliceImpactBase", 2) + math.min(ConstNumber("Score", "MaliceImpactCostCap", 6), cost) * ConstNumber("Score", "MaliceImpactCostMultiplier", 0.5),
        difficulty = (tuning.maliceWeight - 1) * ConstNumber("Score", "MaliceDifficultyMultiplier", 4),
        costPriority = cost * math.max(ConstNumber("Score", "MalicePriorityMinimumWeight", 0.35), tuning.maliceWeight) * ConstNumber("Score", "MaliceCostPriorityMultiplier", 0.45),
        unavailable = unavailable,
        startTurnCost = cost * ConstNumber("Score", "StartTurnMaliceCostMultiplier", 0.35),
    }
end

function AI:CollectStartTurnMaliceCandidates(context, actor)
    local candidates = {}
    if not self.config.maliceAbilities or actor == nil or actor.turnMemory.startTurnMaliceChecked then
        return candidates
    end

    actor.turnMemory.startTurnMaliceChecked = true

    local abilities = SafeCall(function()
        return actor.token.properties:GetActivatedAbilities()
    end, {}) or {}

    for _,ability in ipairs(abilities) do
        local info = self:AnalyzeAbility(actor, ability)
        if self:IsStartTurnMaliceAbility(info) and self:IsSoloActionName(info.name) then
            self:Skip(ability, "solo action is handled during the normal turn")
        elseif self:IsStartTurnMaliceAbility(info) and AbilityCanAfford(ability, actor.token, { mode = 1, charges = self:MaliceCost(info) }) then
            local manualPromptReason = nil
            local unsafePromptReason = nil
            local promptCapability = nil
            local includeStartTurnMalice = true
            if self.AssessPromptCapability ~= nil then
                promptCapability = self:AssessPromptCapability(context, actor, info, {
                    ability = ability,
                    abilityInfo = info,
                    symbols = {
                        mode = 1,
                        charges = self:MaliceCost(info),
                    },
                })
                if promptCapability ~= nil and promptCapability.status == "manual" then
                    manualPromptReason = promptCapability.reason or "manual targeting"
                elseif promptCapability ~= nil and promptCapability.status == "blocked" then
                    unsafePromptReason = promptCapability.reason or "unresolved prompt"
                end
            else
                if info.hasSummon then
                    manualPromptReason = "summon placement"
                else
                    manualPromptReason = self:AbilityManualPromptReason(info, context, actor)
                    if manualPromptReason == nil then
                        unsafePromptReason = self:AbilityUnsafePromptReason(info, context, actor)
                    end
                end
            end

            if manualPromptReason ~= nil then
                self:Skip(ability, manualPromptReason)
                includeStartTurnMalice = false
            end

            if unsafePromptReason ~= nil then
                self:Skip(ability, unsafePromptReason)
                includeStartTurnMalice = false
            end

            if includeStartTurnMalice then
                local canUse = self:CanUseActionCost(actor, info, "none")
                if canUse and self:IsBrutalEffectivenessName(info.name) and not self:NextSelectedAbilityHasPotency(context, actor) then
                    self:Skip(ability, "next selected ability has no potency")
                    canUse = false
                end

                if canUse then
                    local generated = self:EnumerateGenericAbility(context, actor, ability, info)
                    if #generated == 0 and self:IsStartTurnMaliceAbility(info) then
                        local score = CreateScore()
                        AddScore(score, "start-turn malice", ConstNumber("Score", "StartTurnFallbackScore", 1))
                        generated[#generated+1] = self:MakeCandidate{
                            actor = actor,
                            ability = ability,
                            abilityInfo = info,
                            loc = actor.token.loc,
                            targets = { { token = actor.token } },
                            symbols = { mode = 1, charges = self:MaliceCost(info) },
                            actionCost = "none",
                            promptCapability = promptCapability,
                            scoreInfo = score,
                            description = string.format("%s on self", info.name),
                        }
                    end
                    for _,candidate in ipairs(generated) do
                        if self.AnnotatePromptCapability ~= nil then
                            self:AnnotatePromptCapability(candidate, promptCapability)
                        end
                        if self.WriteCandidateIntent ~= nil then
                            self:WriteCandidateIntent(candidate, {
                                startTurnMalice = true,
                                actionCost = "none",
                            })
                        else
                            candidate.startTurnMalice = true
                            candidate.actionCost = "none"
                        end
                        local score = self:ScoreStartTurnMaliceAbility(context, actor, info, candidate)
                        if score ~= nil and score > 0 then
                            if self.WriteCandidateScore ~= nil then
                                self:WriteCandidateScore(candidate, {
                                    startTurnScore = score,
                                    maliceCost = self:MaliceCost(info),
                                })
                            else
                                candidate.startTurnScore = score
                                candidate.maliceCost = self:MaliceCost(info)
                                if self.SyncCandidateSections ~= nil then
                                    self:SyncCandidateSections(candidate)
                                end
                            end
                            candidates[#candidates+1] = candidate
                        end
                    end
                end
            end
        end
    end

    return candidates
end

function AI:UseGroupStartTurnMalice(context)
    return self.Ledger:UseGroupStartTurnMalice(self, context)
end
