local mod = dmhub.GetModLoading()

-- DirectorTacticsGoals.lua owns encounter intent, objective scoring, difficulty tuning, and future goal hooks.
-- Load after DirectorTacticsEncounter.lua and before DirectorTacticsAbilities.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsGoals.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal

local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local Lower = Internal.Lower
local IsTokenValid = Internal.IsTokenValid
local Distance = Internal.Distance
local LocDistance = Internal.LocDistance
local TokenId = Internal.TokenId
local TokenListContains = Internal.TokenListContains
local TokenFromEntry = Internal.TokenFromEntry
local LocFromEntry = Internal.LocFromEntry
local ZoneListContainsLoc = Internal.ZoneListContainsLoc

function AI:DifficultyTuning(context)
    if context ~= nil and context._tmp_difficultyTuning ~= nil then
        return context._tmp_difficultyTuning
    end

    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local difficulty = Lower(plan.difficulty)
    local tuning = {
        damageWeight = 1,
        maliceWeight = 1,
        villainWeight = 1,
        objectiveWeight = 1,
        spreadWeight = 1.4,
        resourceThreshold = 3,
        fleeWeight = 0,
    }

    if difficulty == "trivial" then
        tuning.damageWeight = 0.85
        tuning.maliceWeight = 0.35
        tuning.villainWeight = 0.55
        tuning.objectiveWeight = 0.75
        tuning.spreadWeight = 3
        tuning.resourceThreshold = 8
        tuning.fleeWeight = 2.5
    elseif difficulty == "easy" then
        tuning.damageWeight = 0.9
        tuning.maliceWeight = 0.65
        tuning.villainWeight = 0.8
        tuning.objectiveWeight = 0.85
        tuning.spreadWeight = 2.3
        tuning.resourceThreshold = 6
        tuning.fleeWeight = 1.5
    elseif difficulty == "hard" then
        tuning.damageWeight = 1.12
        tuning.maliceWeight = 1.25
        tuning.villainWeight = 1.2
        tuning.objectiveWeight = 1.25
        tuning.spreadWeight = 0.9
        tuning.resourceThreshold = 1.5
    elseif difficulty == "extreme" then
        tuning.damageWeight = 1.25
        tuning.maliceWeight = 1.5
        tuning.villainWeight = 1.35
        tuning.objectiveWeight = 1.5
        tuning.spreadWeight = 0.45
        tuning.resourceThreshold = 0
    end

    if plan.lethality == "merciful" then
        tuning.damageWeight = tuning.damageWeight * 0.85
        tuning.spreadWeight = tuning.spreadWeight + 1
        tuning.resourceThreshold = tuning.resourceThreshold + 2
    elseif plan.lethality == "ruthless" then
        tuning.damageWeight = tuning.damageWeight * 1.12
        tuning.spreadWeight = math.max(0, tuning.spreadWeight - 0.8)
        tuning.resourceThreshold = math.max(0, tuning.resourceThreshold - 1.5)
    end

    if context ~= nil then
        context._tmp_difficultyTuning = tuning
    end

    return tuning
end

function AI:DistanceToTokenList(fromToken, list)
    local best = 999
    if fromToken == nil or type(list) ~= "table" then
        return best
    end

    for _,entry in pairs(list) do
        local tok = TokenFromEntry(entry)
        if tok ~= nil and IsTokenValid(tok) then
            best = math.min(best, Distance(fromToken, tok))
        end
    end

    return best
end

function AI:DistanceFromLocToTokenList(loc, list)
    local best = 999
    if loc == nil or type(list) ~= "table" then
        return best
    end

    for _,entry in pairs(list) do
        local tok = TokenFromEntry(entry)
        if tok ~= nil and IsTokenValid(tok) then
            best = math.min(best, LocDistance(loc, tok.loc))
        end
    end

    return best
end

function AI:DistanceToZoneList(token, zones)
    if token == nil or type(zones) ~= "table" then
        return 999
    end

    if ZoneListContainsLoc(zones, token.loc, token) then
        return 0
    end

    local best = 999
    for _,zone in pairs(zones) do
        local zoneToken = TokenFromEntry(zone)
        if zoneToken ~= nil then
            best = math.min(best, Distance(token, zoneToken))
        else
            local loc = LocFromEntry(zone)
            if loc ~= nil then
                best = math.min(best, LocDistance(token.loc, loc))
            end
        end
    end

    return best
end

function AI:TargetsContainList(targets, list)
    if targets == nil or list == nil then
        return false
    end

    for _,target in ipairs(targets) do
        if target.token ~= nil and TokenListContains(list, target.token) then
            return true
        end
    end

    return false
end

function AI:CountTargetsNearList(targets, list, distanceLimit)
    local result = 0
    if targets == nil or list == nil then
        return result
    end

    distanceLimit = distanceLimit or 4
    for _,target in ipairs(targets) do
        if target.token ~= nil then
            for _,entry in pairs(list) do
                local tok = TokenFromEntry(entry)
                if tok ~= nil and IsTokenValid(tok) and Distance(target.token, tok) <= distanceLimit then
                    result = result + 1
                    break
                end
            end
        end
    end

    return result
end

function AI:ObjectiveNeedsFocus(context)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local objective = plan.objective
    return objective == "defeat_specific_foe" or objective == "stop_action" or objective == "destroy_the_thing"
end

function AI:ScoreObjectivePosition(context, actor, loc, abilityInfo, targetToken)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local state = (context and context.encounterState) or self.encounterState or self:NewEncounterState()
    local objective = plan.objective
    local score = 0

    local inObjectiveZone = ZoneListContainsLoc(plan.objectiveZones, loc, actor.token)
    local inDestinationZone = ZoneListContainsLoc(plan.destinationZones, loc, actor.token)
    local nearProtected = self:DistanceFromLocToTokenList(loc, plan.protectedTargets)
    local nearObjective = self:DistanceFromLocToTokenList(loc, plan.objectiveTokens)

    if state.fleeing and next(plan.escapeZones) ~= nil then
        local current = self:DistanceToZoneList(actor.token, plan.escapeZones)
        local moved = 999
        for _,zone in pairs(plan.escapeZones) do
            local zoneToken = TokenFromEntry(zone)
            if zoneToken ~= nil then
                moved = math.min(moved, LocDistance(loc, zoneToken.loc))
            else
                local zoneLoc = LocFromEntry(zone)
                if zoneLoc ~= nil then
                    moved = math.min(moved, LocDistance(loc, zoneLoc))
                end
            end
        end
        if moved < current then
            score = score + (current - moved) * (self:DifficultyTuning(context).fleeWeight or 0)
        end
    end

    if objective == "defeat_specific_foe" then
        if TokenListContains(plan.priorityTargets, actor.token) or TokenListContains(plan.protectedTargets, actor.token) then
            score = score + math.min(5, self:NearestEnemyDistanceFromLoc(actor, loc) * 0.45)
            if next(plan.escapeZones) ~= nil then
                score = score + math.max(0, 4 - self:DistanceToZoneList({ loc = loc }, plan.escapeZones)) * 0.7
            end
        elseif self:RoleIs(actor, "defender") or self:RoleIs(actor, "minion") then
            score = score + math.max(0, 5 - nearProtected) * 0.6
        end
    elseif objective == "get_the_thing" or objective == "destroy_the_thing" then
        if self:RoleIs(actor, "defender") or self:RoleIs(actor, "brute") or self:RoleIs(actor, "minion") then
            score = score + math.max(0, 5 - nearObjective) * 0.45
        end
        if inObjectiveZone then
            score = score + 2
        end
    elseif objective == "save_another" or objective == "escort" then
        if self:RoleIs(actor, "harrier") or self:RoleIs(actor, "mount") then
            score = score + math.max(0, 6 - nearObjective) * 0.35
        end
        if inDestinationZone then
            score = score + Pick(objective == "escort", 2.5, 1)
        end
    elseif objective == "hold_them_off" or objective == "assault_defenses" then
        if inObjectiveZone or inDestinationZone then
            score = score + Pick(self:RoleIs(actor, "defender") or self:RoleIs(actor, "minion"), 4, 2)
        end
    elseif objective == "stop_action" or objective == "complete_action" then
        if inObjectiveZone then
            score = score + Pick(objective == "complete_action", 2.5, 1)
        end
        if targetToken ~= nil and TokenListContains(plan.priorityTargets, targetToken) then
            score = score + 1.5
        end
    end

    return score
end

function AI:ScoreBuiltInObjective(context, actor, abilityInfo, targets, loc)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local objective = plan.objective
    local score = 0
    local tuning = self:DifficultyTuning(context)
    local hasControl = abilityInfo.conditionValue > 0 or abilityInfo.forcedMovementValue > 0
    local targetPriority = self:TargetsContainList(targets, plan.priorityTargets)
    local targetProtected = self:TargetsContainList(targets, plan.protectedTargets)
    local targetObjective = self:TargetsContainList(targets, plan.objectiveTokens)
    local nearProtectedTargets = self:CountTargetsNearList(targets, plan.protectedTargets, 5)
    local urgency = 1

    if plan.roundLimit ~= nil and tonumber(plan.roundLimit) ~= nil then
        local remaining = math.max(0, tonumber(plan.roundLimit) - ((context and context.round) or 1) + 1)
        urgency = 1 + math.max(0, 4 - remaining) * 0.35
    end

    if objective == "diminish_numbers" then
        if context ~= nil and context.encounterState ~= nil and context.encounterState.broken and plan.lethality ~= "ruthless" then
            score = score - 1.5
        end
    elseif objective == "defeat_specific_foe" then
        if targetPriority then
            score = score + Pick(abilityInfo.hasDamage, 6, 2)
        end
        if targetProtected and abilityInfo.hasSupport then
            score = score + 8
        elseif nearProtectedTargets > 0 and not abilityInfo.hasSupport then
            score = score + nearProtectedTargets * 3
        end
        if TokenListContains(plan.priorityTargets, actor.token) or TokenListContains(plan.protectedTargets, actor.token) then
            score = score + Pick(abilityInfo.hasSupport, 2, 0)
            if abilityInfo.isManeuver or abilityInfo.isRanged then
                score = score + 1
            end
        end
    elseif objective == "get_the_thing" then
        if targetObjective then
            score = score + Pick(abilityInfo.hasDamage, -4, 5)
        end
        if hasControl then
            score = score + 3
        end
        if next(plan.destinationZones) ~= nil then
            score = score + 1
        end
    elseif objective == "destroy_the_thing" then
        if targetObjective then
            score = score + Pick(abilityInfo.hasDamage, 8, 1)
        end
        if hasControl then
            score = score + 2
        end
    elseif objective == "save_another" or objective == "escort" then
        if targetObjective then
            score = score + Pick(abilityInfo.hasDamage, 3 * tuning.damageWeight, Pick(abilityInfo.hasSupport, -5, 0))
        end
        if hasControl then
            score = score + 4
        end
        if self:RoleIs(actor, "harrier") or self:RoleIs(actor, "mount") then
            score = score + 1.5
        end
    elseif objective == "hold_them_off" or objective == "assault_defenses" then
        if hasControl then
            score = score + 4
        end
        if abilityInfo.isArea then
            score = score + 2
        end
        if self:RoleIs(actor, "defender") or self:RoleIs(actor, "minion") then
            score = score + 1.5
        end
    elseif objective == "stop_action" then
        if targetPriority or targetObjective then
            score = score + Pick(abilityInfo.hasDamage, 5, 2) * urgency
        end
        if hasControl then
            score = score + 5 * urgency
        end
    elseif objective == "complete_action" then
        if targetProtected or targetObjective then
            score = score + Pick(abilityInfo.hasSupport, 6, -2) * urgency
        elseif hasControl then
            score = score + 3 * urgency
        end
    end

    return score * tuning.objectiveWeight
end

function AI:ScoreObjectiveCandidate(context, actor, abilityInfo, targets, loc)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local profile = self.objectiveProfiles[plan.objective]
    if profile ~= nil and profile.scoreCandidate ~= nil then
        return SafeCall(function()
            return profile.scoreCandidate(self, context, actor, abilityInfo, targets, loc)
        end, 0) or 0
    end

    return self:ScoreBuiltInObjective(context, actor, abilityInfo, targets or {}, loc)
end

function AI:ScoreObjectivePositionWithProfile(context, actor, loc, abilityInfo, targetToken)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    local profile = self.objectiveProfiles[plan.objective]
    if profile ~= nil and profile.scorePosition ~= nil and not profile.builtin then
        return SafeCall(function()
            return profile.scorePosition(self, context, actor, loc, abilityInfo, targetToken)
        end, 0) or 0
    end

    return self:ScoreObjectivePosition(context, actor, loc, abilityInfo, targetToken)
end

function AI:SpreadPenalty(context, actor, targetToken)
    local plan = (context and context.encounterPlan) or self:GetEncounterPlan()
    if not plan.spreadDamage or targetToken == nil or self:ObjectiveNeedsFocus(context) then
        return 0
    end

    local state = (context and context.encounterState) or self.encounterState
    if state == nil then
        return 0
    end

    local pressure = state.targetPressure[TokenId(targetToken)] or 0
    if pressure <= 0 then
        return 0
    end

    return -pressure * self:DifficultyTuning(context).spreadWeight
end
