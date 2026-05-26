local mod = dmhub.GetModLoading()

-- DirectorTacticsScoring.lua owns tactical scoring primitives, target valuation, role doctrine, and position scoring.
-- Load after DirectorTacticsAbilities.lua and before DirectorTacticsCandidates.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsScoring.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local Lower = Internal.Lower
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local CurrentStamina = Internal.CurrentStamina
local MaxStamina = Internal.MaxStamina
local LocKey = Internal.LocKey
local CreateScore = Internal.CreateScore
local AddScore = Internal.AddScore
local TextHasAny = Internal.TextHasAny
local ConstNumber = Internal.ConstNumber

local function LocCoord(loc, key)
    return tonumber(TryGet(loc, key, nil))
end

local function LocAltitude(loc)
    if loc == nil then
        return 0
    end

    local explicitAltitude = tonumber(TryGet(loc, "altitude", nil))
    if explicitAltitude ~= nil then
        return explicitAltitude
    end

    return SafeCall(function()
        return game.currentFloor:GetAltitudeAtLoc(loc)
    end, 0) or 0
end

local function SameToken(a, b)
    return a ~= nil and b ~= nil and (a == b or TryGet(a, "charid", nil) == TryGet(b, "charid", false))
end

local function TargetsContainToken(targets, tok)
    if tok == nil then
        return false
    end

    for _,target in ipairs(targets or {}) do
        if SameToken(target and target.token, tok) then
            return true
        end
    end

    return false
end

local function HasNamedCondition(tok, conditionName)
    if tok == nil or tok.properties == nil then
        return false
    end

    return SafeCall(function()
        return tok.properties:HasNamedCondition(conditionName)
    end, false)
end

local function CacheTokenKey(token)
    return tostring(TryGet(token, "charid", TryGet(token, "id", nil)) or token or "")
end

local function TokenMatchesId(token, id)
    if token == nil or id == nil or id == false then
        return false
    end

    id = tostring(id)
    for _,candidate in ipairs({
        TryGet(token, "id", nil),
        TryGet(token, "charid", nil),
        TryGet(TryGet(token, "properties", nil), "id", nil),
        TryGet(TryGet(token, "properties", nil), "charid", nil),
    }) do
        if candidate ~= nil and tostring(candidate) == id then
            return true
        end
    end

    return false
end

local function ConditionIdByName(conditionName)
    local wanted = Lower(conditionName or "")
    if wanted == "" then
        return nil, "unknown: missing condition name"
    end

    local conditionType = RawGlobal("CharacterCondition")
    local tableName = TryGet(conditionType, "tableName", "charConditions") or "charConditions"
    local conditionsTable = SafeCall(function()
        return dmhub.GetTable(tableName)
    end, nil)
    if conditionsTable == nil then
        local getTableCached = RawGlobal("GetTableCached")
        if getTableCached ~= nil then
            conditionsTable = SafeCall(function()
                return getTableCached(tableName)
            end, nil)
        end
    end

    if type(conditionsTable) ~= "table" then
        return nil, "unknown: condition table unavailable"
    end

    local iter = RawGlobal("unhidden_pairs") or pairs
    for conditionid,condition in iter(conditionsTable) do
        if Lower(TryGet(condition, "name", "")) == wanted or Lower(conditionid) == wanted then
            return conditionid, nil
        end
    end

    return nil, "unknown: condition id not found"
end

local function ReasonUnknown(reason)
    return type(reason) == "string" and string.sub(reason, 1, 8) == "unknown:"
end

local function LocExplicitAltitude(loc)
    return tonumber(TryGet(loc, "altitude", nil)) or LocAltitude(loc)
end

local function CacheAbilityKey(abilityInfo)
    local ability = abilityInfo and abilityInfo.ability
    return tostring(TryGet(ability, "guid", TryGet(ability, "id", TryGet(ability, "name", abilityInfo and abilityInfo.name or ""))))
end

local SIMULATED_CONTROL_CONDITION = "__control"

local function SimulatedConditionsFor(context, tok)
    local cache = context and context._tmp_directorTacticsEval
    local simulated = cache and cache.simulatedConditions
    if simulated == nil then
        return nil
    end

    return simulated[CacheTokenKey(tok)]
end

local function HasSimulatedCondition(context, tok, conditionName)
    local conditions = SimulatedConditionsFor(context, tok)
    if conditions == nil then
        return false
    end

    return conditions[Lower(conditionName)] == true
end

local function HasSimulatedControlCondition(context, tok)
    local conditions = SimulatedConditionsFor(context, tok)
    if conditions == nil then
        return false
    end

    if conditions[SIMULATED_CONTROL_CONDITION] == true then
        return true
    end

    for _,conditionName in ipairs({ "grabbed", "restrained", "dazed", "weakened", "frightened", "slowed", "prone", "taunted" }) do
        if conditions[conditionName] == true then
            return true
        end
    end

    return false
end

local function EnsureEvalCache(context)
    if context == nil then
        return nil
    end

    context._tmp_directorTacticsEval = context._tmp_directorTacticsEval or {}
    local cache = context._tmp_directorTacticsEval
    cache.perf = cache.perf or {}
    cache.targetFacts = cache.targetFacts or {}
    cache.friendly = cache.friendly or {}
    cache.hazardDamage = cache.hazardDamage or {}
    cache.positionScore = cache.positionScore or {}
    cache.forcedMove = cache.forcedMove or {}
    cache.conditionSource = cache.conditionSource or {}
    cache.simulatedConditions = cache.simulatedConditions or {}
    return cache
end

local function CountPerf(context, key)
    local cache = EnsureEvalCache(context)
    if cache == nil then
        return
    end

    cache.perf[key] = (cache.perf[key] or 0) + 1
end

local function CloneScore(score)
    if score == nil then
        return nil
    end

    local result = {
        total = score.total or 0,
        parts = {},
    }
    for i,part in ipairs(score.parts or {}) do
        result.parts[i] = part
    end
    return result
end

local function CachedFriendly(ai, context, a, b)
    if ai.CachedTokensFriendly ~= nil then
        return ai:CachedTokensFriendly(context, a, b)
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

function AI:CachedTargetFacts(context, tok)
    if tok == nil then
        return {}
    end

    local cache = EnsureEvalCache(context)
    if cache == nil then
        return {
            currentStamina = CurrentStamina(tok),
            maxStamina = MaxStamina(tok),
            conditions = {},
        }
    end

    local key = CacheTokenKey(tok)
    if cache.targetFacts[key] == nil then
        cache.targetFacts[key] = {
            currentStamina = CurrentStamina(tok),
            maxStamina = MaxStamina(tok),
            conditions = {},
        }
    end
    return cache.targetFacts[key]
end

function AI:CachedCurrentStamina(context, tok)
    return self:CachedTargetFacts(context, tok).currentStamina or 0
end

function AI:CachedMaxStamina(context, tok)
    return math.max(1, self:CachedTargetFacts(context, tok).maxStamina or 1)
end

function AI:CachedTargetHasCondition(context, tok, conditionName)
    if HasSimulatedCondition(context, tok, conditionName) then
        return true
    end

    local facts = self:CachedTargetFacts(context, tok)
    facts.conditions = facts.conditions or {}
    local key = Lower(conditionName)
    if facts.conditions[key] == nil then
        facts.conditions[key] = self:TargetHasCondition(tok, conditionName)
    end
    return facts.conditions[key]
end

function AI:CachedTargetHasAnyControlCondition(context, tok)
    if HasSimulatedControlCondition(context, tok) then
        return true
    end

    for _,conditionName in ipairs({ "Grabbed", "Restrained", "Dazed", "Weakened", "Frightened", "Slowed", "Prone", "Taunted" }) do
        if self:CachedTargetHasCondition(context, tok, conditionName) then
            return true
        end
    end

    return false
end

function AI:PushSimulatedTargetConditions(context, targets, abilityInfo)
    if context == nil or abilityInfo == nil or (abilityInfo.conditionValue or 0) <= 0 then
        return nil
    end

    local names = abilityInfo.conditionApplyNames or {}
    if #names == 0 and abilityInfo.conditionApplyGeneric ~= true then
        return nil
    end

    local cache = EnsureEvalCache(context)
    if cache == nil then
        return nil
    end

    local previous = {}
    local touched = {}
    for _,target in ipairs(targets or {}) do
        local tok = target and target.token
        if tok ~= nil then
            local key = CacheTokenKey(tok)
            if previous[key] == nil then
                previous[key] = cache.simulatedConditions[key] or false
                touched[#touched+1] = key
            end

            local conditions = {}
            for conditionName,value in pairs(cache.simulatedConditions[key] or {}) do
                conditions[conditionName] = value
            end
            for _,conditionName in ipairs(names) do
                conditions[Lower(conditionName)] = true
            end
            if abilityInfo.conditionApplyGeneric == true then
                conditions[SIMULATED_CONTROL_CONDITION] = true
            end
            cache.simulatedConditions[key] = conditions
        end
    end

    if #touched == 0 then
        return nil
    end

    return function()
        for _,key in ipairs(touched) do
            if previous[key] == false then
                cache.simulatedConditions[key] = nil
            else
                cache.simulatedConditions[key] = previous[key]
            end
        end
    end
end

local CONDITION_REMOVAL_SEVERITY = {
    bleeding = 3,
    burning = 3,
    cursed = 3,
    dazed = 5,
    frightened = 4,
    grabbed = 3,
    mazed = 5,
    prone = 3,
    restrained = 6,
    ["shadowed vision"] = 3,
    slowed = 3,
    taunted = 2,
    weakened = 4,
}

local GENERIC_REMOVAL_CONDITIONS = {
    "Restrained",
    "Dazed",
    "Frightened",
    "Weakened",
    "Grabbed",
    "Slowed",
    "Prone",
    "Taunted",
    "Bleeding",
    "Burning",
    "Cursed",
    "Mazed",
    "Shadowed Vision",
}

local function OngoingEffectsTable()
    return SafeCall(function()
        return dmhub.GetTable("characterOngoingEffects")
    end, {}) or {}
end

local function EffectInfoForInstance(effect, tableCache)
    if effect == nil then
        return nil
    end

    tableCache = tableCache or OngoingEffectsTable()
    return tableCache[TryGet(effect, "ongoingEffectid", nil)]
end

local function ExtractObviousOngoingDamage(text)
    text = Lower(tostring(text or ""))
    if text == "" or not TextHasAny(text, { "damage", "stamina" }) then
        return 0
    end

    if not TextHasAny(text, { "end", "start", "ongoing", "bleeding", "burning", "poison", "save" }) then
        return 0
    end

    local result = 0
    for amount in string.gmatch(text, "(%d+)%s+[%a%s%-]*damage") do
        result = math.max(result, tonumber(amount) or 0)
    end
    for amount in string.gmatch(text, "(%d+)%s+stamina") do
        result = math.max(result, tonumber(amount) or 0)
    end
    return result
end

local function EffectTimingRelevant(effect, effectInfo, text)
    if effect ~= nil and (TryGet(effect, "removeOnSave", false) or TryGet(effect, "removeAtNextTurnEnd", false) or TryGet(effect, "removeAtRoundEnd", false)) then
        return true
    end

    local endTrigger = Lower(TryGet(effectInfo, "endTrigger", ""))
    if endTrigger == "endturn" or endTrigger == "beginturn" or endTrigger == "startturn" then
        return true
    end

    text = Lower(tostring(text or ""))
    return TextHasAny(text, { "end of", "ends their turn", "end their turn", "start of", "starts their turn", "start their turn", "ongoing" })
end

function AI:CachedTargetHasOngoingEffect(context, tok, effectName)
    local facts = self:CachedTargetFacts(context, tok)
    facts.ongoingEffects = facts.ongoingEffects or {}
    local key = Lower(effectName)
    if facts.ongoingEffects[key] ~= nil then
        return facts.ongoingEffects[key]
    end

    local found = false
    local tableCache = OngoingEffectsTable()
    local effects = SafeCall(function()
        return tok.properties:ActiveOngoingEffects()
    end, {}) or {}

    for _,effect in ipairs(effects) do
        local effectInfo = EffectInfoForInstance(effect, tableCache)
        local effectDisplayName = Lower(TryGet(effectInfo, "name", TryGet(effect, "name", "")))
        if effectDisplayName == key or string.find(effectDisplayName, key, 1, true) ~= nil then
            found = true
            break
        end
    end

    facts.ongoingEffects[key] = found
    return found
end

function AI:TargetHasRelevantOngoingEffect(context, tok)
    local tableCache = OngoingEffectsTable()
    local effects = SafeCall(function()
        return tok.properties:ActiveOngoingEffects()
    end, {}) or {}

    for _,effect in ipairs(effects) do
        local effectInfo = EffectInfoForInstance(effect, tableCache)
        if TryGet(effect, "removeOnSave", false)
            or TryGet(effect, "removeAtNextTurnEnd", false)
            or TryGet(effect, "removeAtRoundEnd", false)
            or TryGet(effectInfo, "buffType", "") == "debuff"
        then
            return true
        end
    end

    return false
end

function AI:EstimateEndOfTurnDamage(context, tok)
    local facts = self:CachedTargetFacts(context, tok)
    if facts.estimatedEndOfTurnDamage ~= nil then
        return facts.estimatedEndOfTurnDamage
    end

    local total = 0
    local tableCache = OngoingEffectsTable()
    local effects = SafeCall(function()
        return tok.properties:ActiveOngoingEffects()
    end, {}) or {}

    for _,effect in ipairs(effects) do
        local effectInfo = EffectInfoForInstance(effect, tableCache)
        local text = table.concat({
            tostring(TryGet(effectInfo, "name", TryGet(effect, "name", ""))),
            tostring(TryGet(effectInfo, "description", "")),
            tostring(TryGet(effectInfo, "rules", "")),
            tostring(TryGet(effectInfo, "text", "")),
            tostring(TryGet(effect, "description", "")),
        }, " ")
        local damage = ExtractObviousOngoingDamage(text)
        if damage > 0 and EffectTimingRelevant(effect, effectInfo, text) then
            total = total + damage
        end
    end

    facts.estimatedEndOfTurnDamage = total
    return total
end

function AI:TargetGenericConditionRemovalScore(context, tok)
    local best = 0
    for _,conditionName in ipairs(GENERIC_REMOVAL_CONDITIONS) do
        if self:CachedTargetHasCondition(context, tok, conditionName) then
            best = math.max(best, CONDITION_REMOVAL_SEVERITY[Lower(conditionName)] or 3)
        end
    end

    if best <= 0 and self:TargetHasRelevantOngoingEffect(context, tok) then
        best = 3
    end

    return best
end

function AI:TargetConditionRemovalScore(context, tok, abilityInfo)
    if abilityInfo == nil or (abilityInfo.conditionRemovalValue or 0) <= 0 then
        return 0
    end

    local best = 0
    for _,conditionName in ipairs(abilityInfo.conditionRemovalNames or {}) do
        if self:CachedTargetHasCondition(context, tok, conditionName) or self:CachedTargetHasOngoingEffect(context, tok, conditionName) then
            best = math.max(best, CONDITION_REMOVAL_SEVERITY[Lower(conditionName)] or 3)
        end
    end

    if abilityInfo.conditionRemovalGeneric then
        best = math.max(best, self:TargetGenericConditionRemovalScore(context, tok))
    end

    if best <= 0 then
        return 0
    end

    return best + math.min(3, (abilityInfo.conditionRemovalValue or 0) * 0.25)
end

function AI:NearestEnemyDistanceFromLoc(actor, loc)
    local result = 999
    for _,enemy in ipairs(actor.enemies) do
        result = math.min(result, LocDistance(loc, enemy.loc))
    end
    return result
end

function AI:RoleIs(actor, id)
    if actor == nil then
        return false
    end

    id = Lower(id)
    return actor.role == id or actor.organization == id
end

function AI:IsFlankingLoc(actor, loc, targetToken)
    if actor == nil or loc == nil or targetToken == nil or targetToken.loc == nil then
        return false, 0
    end

    if LocDistance(loc, targetToken.loc) > 1.1 then
        return false, 0
    end

    local ax = LocCoord(loc, "x")
    local ay = LocCoord(loc, "y")
    local tx = LocCoord(targetToken.loc, "x")
    local ty = LocCoord(targetToken.loc, "y")
    local count = 0

    for _,ally in ipairs(actor.allies or {}) do
        if IsTokenValid(ally) and not SameToken(ally, actor.token) and not SameToken(ally, targetToken) and LocDistance(ally.loc, targetToken.loc) <= 1.1 then
            local flanks = false
            local lx = LocCoord(ally.loc, "x")
            local ly = LocCoord(ally.loc, "y")
            if ax ~= nil and ay ~= nil and tx ~= nil and ty ~= nil and lx ~= nil and ly ~= nil then
                local dx1 = ax - tx
                local dy1 = ay - ty
                local dx2 = lx - tx
                local dy2 = ly - ty
                local dot = dx1 * dx2 + dy1 * dy2
                flanks = dot < 0 and (math.abs(dx1 + dx2) + math.abs(dy1 + dy2)) <= 1
            else
                flanks = LocDistance(loc, ally.loc) >= 1.8
            end

            if flanks then
                count = count + 1
            end
        end
    end

    return count > 0, count
end

function AI:HasHighGround(loc, targetToken)
    return targetToken ~= nil and targetToken.loc ~= nil and LocAltitude(loc) > LocAltitude(targetToken.loc) + 0.5
end

function AI:AdjacentEnemyCountFromLoc(actor, loc)
    local count = 0
    for _,enemy in ipairs(actor.enemies or {}) do
        if IsTokenValid(enemy) and LocDistance(loc, enemy.loc) <= 1.1 then
            count = count + 1
        end
    end
    return count
end

function AI:TargetHasCondition(tok, conditionName)
    return HasNamedCondition(tok, conditionName)
end

function AI:ConditionCasterMatchesToken(conditionedToken, conditionName, sourceToken)
    if conditionedToken == nil or conditionedToken.properties == nil or sourceToken == nil or sourceToken.properties == nil then
        return false, "unknown: missing token"
    end

    local conditionid, conditionIdReason = ConditionIdByName(conditionName)
    if conditionid ~= nil then
        local ok, directSource = pcall(function()
            return conditionedToken.properties:HasCondition(conditionid)
        end)
        if ok then
            if directSource == false or directSource == nil then
                return false, "condition absent"
            end

            if type(directSource) == "string" then
                if TokenMatchesId(sourceToken, directSource) then
                    return true, "direct source"
                end
                return false, "direct source mismatch"
            end
            -- A bare true means the condition exists, but no caster source is
            -- tracked. Fall through to GoblinScript, which may still expose it.
        else
            conditionIdReason = "unknown: condition source lookup failed"
        end
    end

    local executeGoblinScript = RawGlobal("ExecuteGoblinScript")
    local generateSymbols = RawGlobal("GenerateSymbols")
    if executeGoblinScript == nil or generateSymbols == nil then
        return false, conditionIdReason or "unknown: GoblinScript unavailable"
    end

    local sourceSymbols = SafeCall(function()
        return generateSymbols(sourceToken.properties)
    end, nil)
    if sourceSymbols == nil then
        return false, conditionIdReason or "unknown: source symbols unavailable"
    end

    local lookup = SafeCall(function()
        return conditionedToken.properties:LookupSymbol{ source = sourceSymbols }
    end, nil)
    if lookup == nil then
        return false, conditionIdReason or "unknown: condition lookup unavailable"
    end

    local escapedName = string.gsub(tostring(conditionName or ""), "\"", "")
    local formula = string.format("ConditionCaster(\"%s\") = Source", escapedName)
    local ok, result = pcall(function()
        return executeGoblinScript(formula, lookup, false, "Director condition source")
    end)
    if not ok then
        return false, conditionIdReason or "unknown: GoblinScript failed"
    end
    if result == nil then
        return false, conditionIdReason or "unknown: GoblinScript returned nil"
    end

    if type(result) == "boolean" then
        return result, "GoblinScript boolean"
    end

    local numeric = tonumber(result)
    if numeric ~= nil then
        return numeric > 0, "GoblinScript numeric"
    end

    return false, conditionIdReason or "unknown: GoblinScript returned non-numeric"
end

function AI:ConditionSourceToken(context, conditionedToken, conditionName)
    if conditionedToken == nil or conditionName == nil then
        return nil
    end

    local cache = EnsureEvalCache(context)
    local key = CacheTokenKey(conditionedToken) .. ":" .. Lower(conditionName)
    if cache ~= nil and cache.conditionSource[key] ~= nil then
        return cache.conditionSource[key] or nil
    end

    local unknown = false
    for _,tok in ipairs((context and context.allCombatTokens) or {}) do
        if IsTokenValid(tok) then
            local matches, reason = self:ConditionCasterMatchesToken(conditionedToken, conditionName, tok)
            if matches then
                if cache ~= nil then
                    cache.conditionSource[key] = tok
                end
                return tok
            end
            if ReasonUnknown(reason) then
                unknown = true
            end
        end
    end

    if unknown then
        return nil
    end

    if cache ~= nil then
        cache.conditionSource[key] = false
    end
    return nil
end
function AI:MovementAllowedByFrightened(context, token, loc)
    if token == nil or token.loc == nil or loc == nil or not self:TargetHasCondition(token, "Frightened") then
        return true
    end

    local source = self:ConditionSourceToken(context, token, "Frightened")
    if source == nil or source.loc == nil then
        return true
    end

    local currentDistance = LocDistance(token.loc, source.loc)
    local nextDistance = LocDistance(loc, source.loc)
    return nextDistance + 0.05 >= currentDistance
end

function AI:TargetCannotBeForceMoved(tok)
    if tok == nil or tok.properties == nil then
        return false
    end

    return SafeCall(function()
        return tok.properties:CalculateNamedCustomAttribute("Cannot Be Force Moved") > 0
    end, false)
end

function AI:TargetCanBeForceMovedByActor(actor, targetToken)
    if targetToken == nil then
        return false
    end

    if self:TargetHasCondition(targetToken, "Restrained") or self:TargetCannotBeForceMoved(targetToken) then
        return false
    end

    if self:TargetHasCondition(targetToken, "Grabbed") then
        return actor ~= nil and actor.token ~= nil and self:ConditionCasterMatchesToken(targetToken, "Grabbed", actor.token)
    end

    return true
end

function AI:AbilityIsPureForcedMovement(abilityInfo)
    if abilityInfo == nil or (abilityInfo.forcedMovementValue or 0) <= 0 then
        return false
    end

    return not abilityInfo.hasDamage
        and (abilityInfo.conditionValue or 0) <= 0
        and not abilityInfo.hasSupport
        and (abilityInfo.supportValue or 0) <= 0
end

function AI:CreatureSizeForForcedMovement(tok)
    if tok == nil or tok.properties == nil then
        return 1
    end

    return SafeCall(function()
        return tok.properties:CreatureSizeWhenBeingForceMoved()
    end, TryGet(tok.properties, "size", 1) or 1)
end

function AI:TargetStability(tok)
    if tok == nil or tok.properties == nil then
        return 0
    end

    return SafeCall(function()
        return tok.properties:Stability()
    end, 0)
end

function AI:TargetSpeed(tok)
    if tok == nil or tok.properties == nil then
        return 0
    end

    return SafeCall(function()
        return tok.properties:CurrentMovementSpeed()
    end, 0)
end

function AI:ForcedMovementTargetScore(actor, targetToken)
    if targetToken == nil then
        return 0
    end

    if not self:TargetCanBeForceMovedByActor(actor, targetToken) then
        return -60
    end

    local score = 0
    local stability = self:TargetStability(targetToken)
    score = score + math.max(-2, (5 - stability) * 0.35)

    local actorSize = self:CreatureSizeForForcedMovement(actor and actor.token)
    local targetSize = self:CreatureSizeForForcedMovement(targetToken)
    if actorSize > targetSize then
        score = score + 1.2
    elseif actorSize < targetSize then
        score = score - 0.8
    end

    return score
end

function AI:TargetHasAnyControlCondition(tok)
    for _,conditionName in ipairs({ "Grabbed", "Restrained", "Dazed", "Weakened", "Frightened", "Slowed", "Prone", "Taunted" }) do
        if self:TargetHasCondition(tok, conditionName) then
            return true
        end
    end

    return false
end

function AI:NearbyHostilePeerCount(actor, targetToken, distanceLimit)
    local count = 0
    distanceLimit = distanceLimit or 2
    for _,enemy in ipairs(actor.enemies or {}) do
        if IsTokenValid(enemy) and not SameToken(enemy, targetToken) and Distance(enemy, targetToken) <= distanceLimit then
            count = count + 1
        end
    end
    return count
end

function AI:NearestAllyDistanceToToken(actor, targetToken)
    local best = 999
    for _,ally in ipairs(actor.allies or {}) do
        if IsTokenValid(ally) then
            best = math.min(best, Distance(ally, targetToken))
        end
    end
    return best
end

function AI:RoleTargetNudge(context, actor, abilityInfo, targetToken, friendly)
    if actor == nil or abilityInfo == nil or targetToken == nil then
        return 0
    end

    local score = 0
    if not friendly then
        if self:RoleIs(actor, "ambusher") or self:RoleIs(actor, "harrier") then
            local missing = self:CachedMaxStamina(context, targetToken) - self:CachedCurrentStamina(context, targetToken)
            if missing > 0 then
                score = score + math.min(1.2, missing * 0.04)
            end
            if self:NearbyHostilePeerCount(actor, targetToken, 2) <= 1 then
                score = score + 0.8
            end
            if self:NearestAllyDistanceToToken(actor, targetToken) >= 3 then
                score = score + 0.6
            end
        end

        if (self:RoleIs(actor, "controller") or self:RoleIs(actor, "hexer")) and (abilityInfo.conditionValue > 0 or abilityInfo.forcedMovementValue > 0) then
            if not self:CachedTargetHasAnyControlCondition(context, targetToken) then
                score = score + 1.4
            else
                score = score - 0.8
            end
        end

        if self:RoleIs(actor, "defender") then
            for _,ally in ipairs(actor.allies or {}) do
                if self:IsFragileAllyToken(ally) and Distance(targetToken, ally) <= 2 then
                    score = score + 1.5
                    break
                end
            end
        end
    elseif self:RoleIs(actor, "support") then
        local role, organization = self:TokenRoleTag(targetToken)
        if self:IsFragileRole(role, organization) then
            score = score + 1
        end
        if self:CachedCurrentStamina(context, targetToken) <= self:CachedMaxStamina(context, targetToken) * 0.5 then
            score = score + 1
        end
    end

    return score
end

function AI:MovementPathHazardDamage(token, path)
    if token == nil or path == nil or path.CalculateHazards == nil then
        return 0
    end

    local hazards = SafeCall(function()
        return path:CalculateHazards(token)
    end, nil)
    if hazards == nil then
        return 0
    end

    local total = 0
    for _,hazard in ipairs(hazards) do
        if hazard ~= nil and hazard.type == "damage" then
            total = total + (tonumber(hazard.damageAmount) or 0)
        end
    end

    return total
end

function AI:CachedMovementPathHazardDamage(context, token, path)
    if token == nil or path == nil then
        return 0
    end

    local cache = EnsureEvalCache(context)
    if cache == nil then
        return self:MovementPathHazardDamage(token, path)
    end

    local key = table.concat({
        CacheTokenKey(token),
        LocKey(TryGet(path, "origin", nil)),
        LocKey(TryGet(path, "destination", nil)),
        tostring(path),
    }, "|")
    if cache.hazardDamage[key] ~= nil then
        CountPerf(context, "hazardHit")
        return cache.hazardDamage[key]
    end

    CountPerf(context, "hazardMiss")
    local result = self:MovementPathHazardDamage(token, path)
    cache.hazardDamage[key] = result
    return result
end

function AI:AddMovementHazardScore(score, token, locInfo, movingEnemy, context)
    if score == nil or locInfo == nil then
        return 0
    end

    local damage = tonumber(locInfo.hazardDamage)
    if damage == nil and locInfo.path ~= nil then
        damage = self:CachedMovementPathHazardDamage(context, token, locInfo.path)
        locInfo.hazardDamage = damage
    end
    damage = tonumber(damage) or 0
    if damage <= 0 then
        return 0
    end

    local amount = Pick(movingEnemy, damage * 1.5, -damage * 3)
    AddScore(score, Pick(movingEnemy, "hazard damage", "path hazard"), amount)
    return amount
end

function AI:EstimatedFallDamageFromLoc(token, loc)
    if token == nil or loc == nil then
        return 0
    end

    local stopFallDamage = SafeCall(function()
        return token.properties:CalculateNamedCustomAttribute("Stop Fall Damage", 0)
    end, 0) or 0
    if tonumber(stopFallDamage) ~= nil and tonumber(stopFallDamage) > 0 then
        return 0
    end

    local fallInfo = SafeCall(function()
        return token:GetFallInfoFromLoc(loc)
    end, nil)

    local startAltitude = LocExplicitAltitude(loc)
    local fallDistance = startAltitude - LocAltitude(loc)

    local landingLoc = TryGet(fallInfo, "loc", nil)
    if landingLoc ~= nil then
        fallDistance = math.max(fallDistance, startAltitude - LocExplicitAltitude(landingLoc))
    end

    if fallInfo == nil and fallDistance <= 1 then
        return 0
    end

    local fallReduction = SafeCall(function()
        return token.properties:CalculateNamedCustomAttribute("Fall Reduction", 0)
    end, 0) or 0

    return math.max(0, fallDistance - (tonumber(fallReduction) or 0))
end

function AI:ScoreForcedMovementDestination(context, actor, invokerToken, movingToken, testLoc, movementInfo)
    if actor == nil or movingToken == nil or testLoc == nil or movementInfo == nil or movementInfo.path == nil then
        return 0
    end

    local movingEnemy = not CachedFriendly(self, context, invokerToken or actor.token, movingToken)
    local score = 0
    local path = movementInfo.path
    score = score - LocDistance(path.destination, path.origin) * 0.2
    local hazardDamage = self:CachedMovementPathHazardDamage(context, movingToken, path)
    if hazardDamage > 0 then
        score = score + Pick(movingEnemy, hazardDamage * 1.5, -hazardDamage * 3)
    end

    local fallDamage = self:EstimatedFallDamageFromLoc(movingToken, path.destination or testLoc)
    if fallDamage > 0 then
        if movingEnemy then
            score = score + math.min(ConstNumber("Score", "ForcedMoveFallCap", 12), fallDamage * ConstNumber("Score", "ForcedMoveFallMultiplier", 3))
        else
            score = score - math.min(ConstNumber("Score", "ForcedMoveFriendlyFallCap", 18), fallDamage * ConstNumber("Score", "ForcedMoveFriendlyFallMultiplier", 4))
        end
    end

    for _,collideToken in ipairs(movementInfo.collideWith or {}) do
        if collideToken.isObject then
            score = score + Pick(movingEnemy, 3, -4)
        elseif CachedFriendly(self, context, invokerToken or actor.token, collideToken) then
            score = score - Pick(movingEnemy, 100, 3)
        else
            score = score + 2
        end
    end

    if movingEnemy then
        score = score + self:ForcedMovementTargetScore(actor, movingToken) * 0.5
        score = score + self:NearestEnemyDistanceFromLoc(actor, testLoc) * 0.2
        local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
        if plan ~= nil and next(plan.objectiveZones or {}) ~= nil then
            local currentInZone = self.ScoreObjectivePosition ~= nil and self:ScoreObjectivePosition(context, actor, movingToken.loc, nil, movingToken) or 0
            local movedInZone = self.ScoreObjectivePosition ~= nil and self:ScoreObjectivePosition(context, actor, testLoc, nil, movingToken) or 0
            score = score + math.max(-2, math.min(2, currentInZone - movedInZone))
        end
    else
        score = score + self:PositionScore(actor, testLoc, nil, actor.enemies[1]).total
    end

    return score
end

function AI:BestForcedMovementDestinationScore(context, actor, movingToken, distanceLimit)
    if actor == nil or movingToken == nil or movingToken.loc == nil then
        return 0
    end

    distanceLimit = math.max(1, math.min(6, math.ceil(tonumber(distanceLimit) or 1)))
    local cache = EnsureEvalCache(context)
    local cacheKey = nil
    if cache ~= nil then
        local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
        cacheKey = table.concat({
            CacheTokenKey(actor.token),
            LocKey(actor.token and actor.token.loc),
            CacheTokenKey(movingToken),
            LocKey(movingToken.loc),
            tostring(distanceLimit),
            tostring(plan and plan.objective or ""),
        }, "|")
        if cache.forcedMove[cacheKey] ~= nil then
            CountPerf(context, "forcedMoveHit")
            return cache.forcedMove[cacheKey]
        end
    end

    CountPerf(context, "forcedMoveMiss")
    local possibleLocs = {}
    local loc = movingToken.loc
    for _=1,distanceLimit do
        loc = SafeCall(function() return loc.north.west end, loc)
    end

    local function Add(locToAdd)
        if locToAdd ~= nil then
            possibleLocs[#possibleLocs+1] = locToAdd
        end
    end

    for _=1,distanceLimit * 2 do
        Add(loc)
        loc = SafeCall(function() return loc.east end, loc)
    end
    for _=1,distanceLimit * 2 do
        Add(loc)
        loc = SafeCall(function() return loc.south end, loc)
    end
    for _=1,distanceLimit * 2 do
        Add(loc)
        loc = SafeCall(function() return loc.west end, loc)
    end
    for _=1,distanceLimit * 2 do
        Add(loc)
        loc = SafeCall(function() return loc.north end, loc)
    end

    local best = 0
    for _,testLoc in ipairs(possibleLocs) do
        local movementInfo = SafeCall(function()
            return movingToken:MarkMovementArrow(testLoc, { straightline = true, ignorecreatures = false })
        end, nil)

        if movementInfo ~= nil and movementInfo.path ~= nil then
            best = math.max(best, self:ScoreForcedMovementDestination(context, actor, actor.token, movingToken, testLoc, movementInfo))
        end
    end

    SafeCall(function()
        movingToken:ClearMovementArrow()
    end, nil)

    if cache ~= nil then
        cache.forcedMove[cacheKey] = best
    end
    return best
end

function AI:ApplyTacticRules(score, methodName, context, actor, abilityInfo, targets, loc, extra)
    if score == nil then
        return
    end

    for _,rule in ipairs(self.tacticRules or {}) do
        local fn = rule[methodName]
        if fn ~= nil then
            local matches = true
            if rule.matches ~= nil then
                matches = SafeCall(function()
                    return rule.matches(self, context, actor, abilityInfo, targets, loc, extra)
                end, false)
            end

            if matches then
                local amount, label = SafeCall(function()
                    return fn(self, context, actor, abilityInfo, targets, loc, extra)
                end, nil)

                if type(amount) == "table" then
                    label = amount.label
                    amount = amount.score
                end

                if type(amount) == "number" then
                    AddScore(score, label or ("tactic " .. tostring(rule.id)), amount)
                end
            end
        end
    end
end

function AI:ScoreTargets(context, actor, abilityInfo, targets, loc)
    local score = CreateScore()
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local tuning = self:DifficultyTuning(context)
    local friendlyTargets = 0
    local hostileTargets = 0
    local totalAreaOverkill = 0
    local actorToken = actor and actor.token
    local actorTauntSource = self:ConditionSourceToken(context, actorToken, "Taunted")
    local actorFearSource = self:ConditionSourceToken(context, actorToken, "Frightened")

    for _,target in ipairs(targets) do
        local tok = target.token
        if tok ~= nil then
            local friendly = CachedFriendly(self, context, actor.token, tok)
            if friendly then
                friendlyTargets = friendlyTargets + 1
            else
                hostileTargets = hostileTargets + 1
            end

            if friendly and self:AbilityHasHostileEffect(abilityInfo) then
                AddScore(score, "blocked friendly hostile target", ConstNumber("Score", "BlockedTargetPenalty", -100))
            elseif not friendly and self:AbilityHasFriendlyEffect(abilityInfo) then
                AddScore(score, "blocked hostile support target", ConstNumber("Score", "BlockedTargetPenalty", -100))
            end

            local roleNudge = self:RoleTargetNudge(context, actor, abilityInfo, tok, friendly)
            if roleNudge ~= 0 then
                AddScore(score, "role target", roleNudge)
            end

            if abilityInfo.hasDamage then
                local damage = abilityInfo.expectedDamage * tuning.damageWeight
                if friendly then
                    AddScore(score, "friendly fire", damage * ConstNumber("Score", "FriendlyFireMultiplier", -3))
                else
                    AddScore(score, "damage", damage)
                    AddScore(score, "spread", self:SpreadPenalty(context, actor, tok))
                    local hp = self:CachedCurrentStamina(context, tok)
                    if hp > 0 then
                        totalAreaOverkill = totalAreaOverkill + math.max(0, damage - hp)
                    end

                    local pendingDamage = self:EstimateEndOfTurnDamage(context, tok)
                    local hpForPressure = hp
                    local pendingLethal = pendingDamage >= hp and hp > 0
                    if pendingLethal then
                        AddScore(score, "pending lethal ongoing", ConstNumber("Score", "PendingLethalPenalty", -5))
                    elseif pendingDamage > 0 then
                        hpForPressure = math.max(1, hp - pendingDamage)
                        AddScore(score, "pending ongoing damage", -math.min(ConstNumber("Score", "PendingOngoingCap", 2), pendingDamage * ConstNumber("Score", "PendingOngoingMultiplier", 0.1)))
                    end

                    if not pendingLethal and hpForPressure <= damage and hpForPressure > 0 then
                        AddScore(score, "finish", ConstNumber("Score", "FinishBonus", 6))
                    elseif not pendingLethal and hpForPressure <= damage * ConstNumber("Score", "PressureDamageMultiplier", 1.5) then
                        AddScore(score, "pressure", ConstNumber("Score", "PressureBonus", 2))
                    end

                    local missing = self:CachedMaxStamina(context, tok) - self:CachedCurrentStamina(context, tok)
                    if missing > 0 then
                        AddScore(score, "focus", math.min(ConstNumber("Score", "FocusCap", 3), missing * ConstNumber("Score", "FocusMissingStaminaMultiplier", 0.08)))
                    end
                    if self:CachedTargetHasAnyControlCondition(context, tok) then
                        AddScore(score, "controlled follow-up", ConstNumber("Score", "ControlledTargetFollowupBonus", 2))
                    end
                    if abilityInfo.isMelee and self:CachedTargetHasCondition(context, tok, "Prone") then
                        AddScore(score, "melee vs prone", ConstNumber("Score", "ProneMeleeTargetBonus", 1.5))
                    end
                    if self:CachedTargetHasCondition(context, tok, "Restrained") then
                        AddScore(score, "restrained target", ConstNumber("Score", "RestrainedTargetBonus", 1.5))
                    end
                    if self:CachedTargetHasCondition(context, tok, "Frightened") and actorToken ~= nil and self:ConditionCasterMatchesToken(tok, "Frightened", actorToken) then
                        AddScore(score, "fear source edge", ConstNumber("Score", "FrightenedSourceAttackBonus", 1.5))
                    end
                end
            end

            if abilityInfo.conditionValue > 0 then
                AddScore(score, "condition", Pick(friendly, -abilityInfo.conditionValue, abilityInfo.conditionValue))
                if (self:RoleIs(actor, "controller") or self:RoleIs(actor, "hexer")) and ((context and context.round) or 1) <= 2 and not friendly then
                    AddScore(score, "early control", 2)
                end
            end

            if friendly and (abilityInfo.conditionRemovalValue or 0) > 0 then
                AddScore(score, "condition removal", self:TargetConditionRemovalScore(context, tok, abilityInfo))
            end

            if abilityInfo.forcedMovementValue > 0 then
                local canForceMove = not friendly and self:TargetCanBeForceMovedByActor(actor, tok)
                if canForceMove then
                    AddScore(score, "forced move", abilityInfo.forcedMovementValue)
                    if next(plan.objectiveZones or {}) ~= nil then
                        AddScore(score, "objective control", 2)
                    end
                elseif friendly then
                    AddScore(score, "forced move", -math.max(8, abilityInfo.forcedMovementValue * 3))
                elseif self:AbilityIsPureForcedMovement(abilityInfo) then
                    AddScore(score, "invalid forced move", ConstNumber("Score", "InvalidForcedMovePenalty", -8))
                end
            end

            if abilityInfo.hasSupport then
                if friendly then
                    local missing = self:CachedMaxStamina(context, tok) - self:CachedCurrentStamina(context, tok)
                    AddScore(score, "support", abilityInfo.supportValue + math.min(5, missing * 0.15))
                else
                    AddScore(score, "bad support target", -5)
                end
            end

            if abilityInfo.hasAidAttack and not friendly then
                AddScore(score, "aid attack", Pick(self:RoleIs(actor, "support") or self:RoleIs(actor, "leader"), 2, 1))
            end
        end
    end

    if abilityInfo.hasPowerRoll and actorToken ~= nil then
        if self:TargetHasCondition(actorToken, "Weakened") then
            AddScore(score, "weakened power roll", ConstNumber("Score", "WeakenedPowerRollPenalty", -1.5))
        end
        if actorFearSource ~= nil and TargetsContainToken(targets, actorFearSource) then
            AddScore(score, "frightened source bane", ConstNumber("Score", "FrightenedSourceBanePenalty", -1.5))
        end
    end

    if abilityInfo.isStrike and actorToken ~= nil and self:TargetHasCondition(actorToken, "Prone") then
        AddScore(score, "prone strike", ConstNumber("Score", "ProneStrikePenalty", -1.5))
    end

    if actorToken ~= nil and self:TargetHasCondition(actorToken, "Bleeding")
        and (abilityInfo.isAction or abilityInfo.hasPowerRoll)
        and self:CachedCurrentStamina(context, actorToken) <= self:CachedMaxStamina(context, actorToken) * 0.35
    then
        AddScore(score, "bleeding risk", ConstNumber("Score", "BleedingRiskPenalty", -2))
    end

    if actorTauntSource ~= nil
        and hostileTargets > 0
        and self:AbilityHasHostileEffect(abilityInfo)
        and not TargetsContainToken(targets, actorTauntSource)
    then
        AddScore(score, "taunted off-target", ConstNumber("Score", "TauntedOffTargetPenalty", -8))
    end

    if hostileTargets > 1 and (abilityInfo.isArea or abilityInfo.targetType ~= "target") then
        AddScore(score, "multi-target", (hostileTargets - 1) * ConstNumber("Score", "MultiTargetBonus", 2))
        AddScore(score, "aoe overkill", -math.min(ConstNumber("Score", "AreaOverkillCap", 6), totalAreaOverkill * ConstNumber("Score", "AreaOverkillMultiplier", 0.15)))
    end

    if abilityInfo.isSignature then
        AddScore(score, "signature", ConstNumber("Score", "SignatureBonus", 6))
    elseif abilityInfo.isStrike and hostileTargets > 0 then
        AddScore(score, "strike", ConstNumber("Score", "StrikeBonus", 2))
    end

    if abilityInfo.isMalice then
        local malice = self:MaliceScoreParts(context, abilityInfo)
        AddScore(score, "malice impact", malice.impact)
        AddScore(score, "difficulty malice", malice.difficulty)
        AddScore(score, "malice cost priority", malice.costPriority)
        AddScore(score, "malice unavailable", malice.unavailable)
    end

    if abilityInfo.isVillain then
        AddScore(score, "villain action", ConstNumber("Score", "VillainActionBase", 8) * tuning.villainWeight)
        local villainNumber = self:VillainActionNumber(abilityInfo)
        if villainNumber ~= nil and actor ~= nil and actor.token ~= nil and self.NextVillainActionNumberForToken ~= nil then
            local expected = self:NextVillainActionNumberForToken(actor.token)
            if villainNumber == expected then
                AddScore(score, "villain pacing", ConstNumber("Score", "VillainPacingExpectedBonus", 2))
            else
                AddScore(score, "villain pacing", -math.abs(villainNumber - expected) * ConstNumber("Score", "VillainPacingMissMultiplier", 1.5))
            end
        end
        if self:RoleIs(actor, "solo") and self:CachedCurrentStamina(context, actor.token) <= self:CachedMaxStamina(context, actor.token) * 0.25 then
            AddScore(score, "solo late villain", ConstNumber("Score", "SoloLateVillainBonus", 3))
        end
    end

    if self:RoleIs(actor, "brute") and hostileTargets > 1 then
        AddScore(score, "brute cluster", hostileTargets * ConstNumber("Score", "BruteClusterMultiplier", 0.8))
    end

    if (self:RoleIs(actor, "leader") or self:RoleIs(actor, "support")) and friendlyTargets > 0 then
        AddScore(score, "ally doctrine", friendlyTargets * ConstNumber("Score", "AllyDoctrineMultiplier", 0.8))
    end

    AddScore(score, "objective", self:ScoreObjectiveCandidate(context, actor, abilityInfo, targets, loc))
    self:ApplyTacticRules(score, "scoreTarget", context, actor, abilityInfo, targets, loc, nil)

    if actor.override ~= nil then
        if self:IsPreferredByOverride(actor, abilityInfo) then
            AddScore(score, "preferred", 5)
        end

        local weights = actor.override.weights
        if type(weights) == "table" then
            if weights.damage ~= nil and abilityInfo.expectedDamage > 0 then
                AddScore(score, "damage weight", (weights.damage - 1) * abilityInfo.expectedDamage * math.max(1, hostileTargets))
            end
            if weights.conditions ~= nil and abilityInfo.conditionValue > 0 then
                AddScore(score, "condition weight", (weights.conditions - 1) * abilityInfo.conditionValue * math.max(1, hostileTargets))
            end
            if weights.support ~= nil and abilityInfo.supportValue > 0 then
                AddScore(score, "support weight", (weights.support - 1) * abilityInfo.supportValue * math.max(1, friendlyTargets))
            end
            if weights.forcedMovement ~= nil and abilityInfo.forcedMovementValue > 0 then
                AddScore(score, "forced weight", (weights.forcedMovement - 1) * abilityInfo.forcedMovementValue * math.max(1, hostileTargets))
            end
        end
    end

    local positionScore = self:PositionScore(actor, loc, abilityInfo, targets[1] and targets[1].token)
    AddScore(score, "position", positionScore.total)

    return score
end

function AI:PositionScore(actor, loc, abilityInfo, targetToken)
    local context = actor and actor.context
    local cache = EnsureEvalCache(context)
    local cacheKey = nil
    if cache ~= nil and actor ~= nil then
        local profile = actor.profile or self.roleProfiles.standard
        local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
        cacheKey = table.concat({
            CacheTokenKey(actor.token),
            LocKey(actor.token and actor.token.loc),
            LocKey(loc),
            CacheAbilityKey(abilityInfo),
            tostring(abilityInfo and abilityInfo.range or ""),
            tostring(abilityInfo and abilityInfo.isMelee or ""),
            tostring(abilityInfo and abilityInfo.isRanged or ""),
            CacheTokenKey(targetToken),
            LocKey(targetToken and targetToken.loc),
            tostring(profile and profile.id or ""),
            tostring(plan and plan.objective or ""),
        }, "|")
        if cache.positionScore[cacheKey] ~= nil then
            CountPerf(context, "positionHit")
            return CloneScore(cache.positionScore[cacheKey])
        end
    end

    CountPerf(context, "positionMiss")
    local profile = actor.profile or self.roleProfiles.standard
    local score = CreateScore()

    local nearestEnemy = self:NearestEnemyDistanceFromLoc(actor, loc)
    local desired = profile.desiredRange or 1
    if abilityInfo ~= nil and abilityInfo.isRanged then
        desired = math.max(desired, math.min(abilityInfo.range, profile.rangedDesiredRange or abilityInfo.range or desired))
    elseif abilityInfo ~= nil and abilityInfo.isMelee then
        desired = 1
    end

    AddScore(score, "range", -math.abs(nearestEnemy - desired) * (profile.rangeWeight or 0.3))

    if nearestEnemy <= 1 and (profile.avoidAdjacent or 0) > 0 then
        AddScore(score, "avoid adjacent", -(profile.avoidAdjacent or 0))
    end

    self:ApplyTacticRules(score, "scorePosition", actor.context, actor, abilityInfo, Pick(targetToken ~= nil, { { token = targetToken } }, {}), loc, nil)

    if (profile.protectAllies or 0) > 0 then
        local protected = 0
        for _,ally in ipairs(actor.allies) do
            if Distance(ally, actor.token) > 0 and LocDistance(loc, ally.loc) <= 2 then
                protected = protected + 1
            end
        end
        AddScore(score, "protect", protected * profile.protectAllies)
    end

    AddScore(score, "objective pos", self:ScoreObjectivePositionWithProfile(actor.context, actor, loc, abilityInfo, targetToken))

    if cache ~= nil then
        cache.positionScore[cacheKey] = CloneScore(score)
    end
    return score
end
