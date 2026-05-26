local mod = dmhub.GetModLoading()

-- DirectorTacticsEncounter.lua owns encounter plans, encounter state, actor construction, role lookup, and boss-turn guards.
-- Load after DirectorTacticsAI.lua and before DirectorTacticsGoals.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsEncounter.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal
local Runtime = AI._runtime

local RawGlobal = Internal.RawGlobal
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local Lower = Internal.Lower
local TokenName = Internal.TokenName
local IsTokenValid = Internal.IsTokenValid
local TokensFriendly = Internal.TokensFriendly
local TokenId = Internal.TokenId
local CopyPlanList = Internal.CopyPlanList

function AI:DefaultEncounterPlan()
    return {
        objective = "diminish_numbers",
        difficulty = "standard",
        lethality = "fair",
        spreadDamage = true,
        priorityTargets = {},
        protectedTargets = {},
        objectiveTokens = {},
        objectiveZones = {},
        escapeZones = {},
        destinationZones = {},
        roundLimit = nil,
    }
end

function AI:GetEncounterPlan()
    if self.encounterPlan == nil then
        self.encounterPlan = self:DefaultEncounterPlan()
    end

    local objective = Lower(self.encounterPlan.objective)
    if objective == "" or (next(self.objectiveProfiles) ~= nil and self.objectiveProfiles[objective] == nil) then
        self.encounterPlan.objective = "diminish_numbers"
    else
        self.encounterPlan.objective = objective
    end

    self.encounterPlan.difficulty = Lower(self.encounterPlan.difficulty or "standard")
    if self.encounterPlan.difficulty == "" then
        self.encounterPlan.difficulty = "standard"
    end

    self.encounterPlan.lethality = Lower(self.encounterPlan.lethality or "fair")
    if self.encounterPlan.lethality == "" then
        self.encounterPlan.lethality = "fair"
    end

    self.encounterPlan.spreadDamage = self.encounterPlan.spreadDamage ~= false
    for _,key in ipairs({ "priorityTargets", "protectedTargets", "objectiveTokens", "objectiveZones", "escapeZones", "destinationZones" }) do
        if type(self.encounterPlan[key]) ~= "table" then
            self.encounterPlan[key] = {}
        end
    end

    return self.encounterPlan
end

function AI:NormalizeEncounterPlan(args)
    args = args or {}

    local base = self:DefaultEncounterPlan()
    local current = self.encounterPlan or {}
    for k,v in pairs(current) do
        base[k] = v
    end
    for k,v in pairs(args) do
        base[k] = v
    end

    base.objective = Lower(base.objective)
    if base.objective == "" or self.objectiveProfiles[base.objective] == nil then
        base.objective = "diminish_numbers"
    end

    base.difficulty = Lower(base.difficulty)
    if base.difficulty == "" then
        base.difficulty = "standard"
    end

    base.lethality = Lower(base.lethality)
    if base.lethality == "" then
        base.lethality = "fair"
    end

    base.spreadDamage = base.spreadDamage ~= false
    base.priorityTargets = CopyPlanList(base.priorityTargets)
    base.protectedTargets = CopyPlanList(base.protectedTargets)
    base.objectiveTokens = CopyPlanList(base.objectiveTokens)
    base.objectiveZones = CopyPlanList(base.objectiveZones)
    base.escapeZones = CopyPlanList(base.escapeZones)
    base.destinationZones = CopyPlanList(base.destinationZones)

    return base
end

function AI:NewEncounterState()
    return {
        signature = nil,
        initialFoeCount = 0,
        initialHeroCount = 0,
        initialNonMinionFoeCount = 0,
        round = 1,
        lastInitiativeId = nil,
        targetPressure = {},
        damageSpread = {},
        usedVillainActions = {},
        endRoundVillainActions = {},
        usedStartTurnMaliceKeys = {},
        maliciousStrikeRounds = {},
        lastTurnBlockIds = {},
        lastTurnSummary = "",
        lastTurnInitiativeId = nil,
        lastTurnRound = nil,
        lastTurnTurn = nil,
        lastObservedRound = nil,
        lastMaliciousStrikeRound = nil,
        broken = false,
        fleeing = false,
        progress = {},
    }
end

function AI:ResetEncounterState(reason)
    self.encounterState = self:NewEncounterState()
    if reason ~= nil then
        self:Log("Encounter state reset: " .. tostring(reason))
    end
end

function AI:SetEncounterPlan(args)
    self.encounterPlan = self:NormalizeEncounterPlan(args or {})
    self:ResetEncounterState("plan changed")
    self:TouchLog()
end

function AI:ClearEncounterPlan()
    self.encounterPlan = self:DefaultEncounterPlan()
    self:ResetEncounterState("plan cleared")
    self:TouchLog()
end

function AI:EncounterSignature(context)
    local ids = {}
    for _,tok in ipairs(context.allCombatTokens or {}) do
        local id = TokenId(tok)
        if id ~= nil then
            ids[#ids+1] = tostring(id)
        end
    end

    table.sort(ids)
    return table.concat(ids, "|")
end

function AI:GetInitiativeTokens(initiativeid, allTokens)
    if initiativeid == nil then
        return {}
    end

    local result = SafeCall(function()
        local initiativeQueue = RawGlobal("InitiativeQueue")
        if initiativeQueue ~= nil and initiativeQueue.GetTokensForInitiativeId ~= nil then
            return initiativeQueue.GetTokensForInitiativeId(initiativeid, allTokens)
        end

        local hud = RawGlobal("GameHud")
        if hud ~= nil and hud.instance ~= nil then
            return hud.GetTokensForInitiativeId(hud.instance, hud.instance.initiativeInterface, initiativeid)
        end

        return {}
    end, {}) or {}

    if string.sub(tostring(initiativeid), 1, 8) ~= "MONSTER-" then
        return result
    end

    local key = string.sub(tostring(initiativeid), 9)
    local seen = {}
    for _,tok in ipairs(result) do
        local id = TokenId(tok)
        if id ~= nil then
            seen[id] = true
        end
    end

    local function Sanitized(value)
        if value == nil then
            return nil
        end

        return SafeCall(function()
            return dmhub.SanitizeDatabaseKey(value)
        end, tostring(value))
    end

    for _,tok in ipairs(allTokens or dmhub.allTokens or {}) do
        if IsTokenValid(tok) then
            local id = TokenId(tok)
            if id == nil or not seen[id] then
                local monsterType = SafeCall(function()
                    return tok.properties:GetMonsterType()
                end, nil)
                local squadid = SafeCall(function()
                    return tok.properties:MinionSquad()
                end, nil)

                if Sanitized(monsterType) == key or Sanitized(squadid) == key or monsterType == key or squadid == key then
                    if id ~= nil then
                        seen[id] = true
                    end
                    result[#result+1] = tok
                end
            end
        end
    end

    return result
end

function AI:ExpandActiveTokens(context, activeTokens)
    local result = {}
    local seen = {}

    local function Add(tok)
        if not IsTokenValid(tok) then
            return
        end

        local id = TokenId(tok)
        if id ~= nil and seen[id] then
            return
        end

        if id ~= nil then
            seen[id] = true
        end

        result[#result+1] = tok
    end

    for _,tok in ipairs(activeTokens or {}) do
        Add(tok)
    end

    for _,tok in ipairs(activeTokens or {}) do
        if IsTokenValid(tok) then
            local squadid = SafeCall(function()
                return tok.properties:MinionSquad()
            end, nil)
            local initiativeGrouping = TryGet(tok.properties, "initiativeGrouping", nil)

            for _,other in ipairs(context.allCombatTokens or {}) do
                if IsTokenValid(other) and TokensFriendly(tok, other) then
                    if squadid ~= nil then
                        local otherSquad = SafeCall(function()
                            return other.properties:MinionSquad()
                        end, nil)
                        if otherSquad == squadid then
                            Add(other)
                        end
                    end

                    if initiativeGrouping ~= nil and TryGet(other.properties, "initiativeGrouping", nil) == initiativeGrouping then
                        Add(other)
                    end
                end
            end
        end
    end

    return result
end

function AI:RefreshTransientCombatFacts(context)
    local aidAttackGuid = TryGet(TryGet(self.K, "Tactic", {}), "AidAttackEffectGuid", nil)

    for _,tok in ipairs((context and context.allCombatTokens) or {}) do
        if IsTokenValid(tok) then
            local hasAidAttack = false
            local effects = SafeCall(function()
                return tok.properties:ActiveOngoingEffects()
            end, {}) or {}

            for _,effect in ipairs(effects) do
                local effectName = Lower(TryGet(effect, "name", TryGet(effect, "description", "")))
                if (aidAttackGuid ~= nil and TryGet(effect, "ongoingEffectid", nil) == aidAttackGuid) or effectName == "aid attack" or effectName == "aid an attack" then
                    hasAidAttack = true
                    break
                end
            end

            tok.properties._tmp_directorTacticsAidAttack = hasAidAttack
        end
    end
end

function AI:RefreshEncounterState(context)
    context.encounterPlan = self:GetEncounterPlan()
    if self.encounterState == nil then
        self.encounterState = self:NewEncounterState()
    end

    context.encounterState = self.encounterState
    local signature = self:EncounterSignature(context)
    local state = self.encounterState
    state.usedStartTurnMaliceKeys = state.usedStartTurnMaliceKeys or {}
    local materiallyChanged = state.signature ~= nil and state.signature ~= signature
    if state.signature == nil or materiallyChanged then
        local preservedMaliciousStrikeRounds = nil
        local preservedLastMaliciousStrikeRound = nil
        local preservedStartTurnMaliceKeys = nil
        if materiallyChanged then
            preservedMaliciousStrikeRounds = state.maliciousStrikeRounds
            preservedLastMaliciousStrikeRound = state.lastMaliciousStrikeRound
            preservedStartTurnMaliceKeys = state.usedStartTurnMaliceKeys
        end

        state.signature = signature
        state.initialFoeCount = 0
        state.initialHeroCount = 0
        state.initialNonMinionFoeCount = 0
        state.targetPressure = {}
        state.damageSpread = {}
        state.usedVillainActions = {}
        state.endRoundVillainActions = {}
        state.usedStartTurnMaliceKeys = preservedStartTurnMaliceKeys or {}
        state.maliciousStrikeRounds = preservedMaliciousStrikeRounds or {}
        state.lastTurnBlockIds = {}
        state.lastTurnSummary = ""
        state.lastTurnInitiativeId = nil
        state.lastTurnRound = nil
        state.lastTurnTurn = nil
        state.lastObservedRound = nil
        state.lastMaliciousStrikeRound = preservedLastMaliciousStrikeRound
        state.broken = false
        state.fleeing = false
        state.progress = {}

        for _,tok in ipairs(context.allCombatTokens or {}) do
            if tok.playerControlled then
                state.initialHeroCount = state.initialHeroCount + 1
            else
                state.initialFoeCount = state.initialFoeCount + 1
                if not TryGet(tok.properties, "minion", false) then
                    state.initialNonMinionFoeCount = state.initialNonMinionFoeCount + 1
                end
            end
        end
    end

    state.round = context.round or state.round or 1
    state.lastInitiativeId = context.initiativeid

    local liveFoes = 0
    local liveNonMinionFoes = 0
    for _,tok in ipairs(context.allCombatTokens or {}) do
        if not tok.playerControlled then
            liveFoes = liveFoes + 1
            if not TryGet(tok.properties, "minion", false) then
                liveNonMinionFoes = liveNonMinionFoes + 1
            end
        end
    end

    state.progress.liveFoes = liveFoes
    state.progress.liveNonMinionFoes = liveNonMinionFoes
    state.progress.initialFoes = state.initialFoeCount
    state.progress.initialNonMinionFoes = state.initialNonMinionFoeCount

    local plan = context.encounterPlan
    if plan.objective == "diminish_numbers" and state.initialFoeCount > 0 then
        if liveFoes <= math.max(1, math.floor(state.initialFoeCount * 0.5)) then
            state.broken = true
        end
        if state.initialNonMinionFoeCount > 0 and liveNonMinionFoes <= 0 then
            state.broken = true
        end
        state.fleeing = state.broken and plan.lethality ~= "ruthless"
    end

    context.encounterState = state
end

function AI:GetOrganization(token)
    local props = token.properties
    local org = SafeCall(function()
        return props:Organization()
    end, nil)

    if org ~= nil and org ~= "" then
        return Lower(org)
    end

    local role = Lower(TryGet(props, "role", ""))
    local first = string.match(role, "^(%S+)")
    return first or "standard"
end

function AI:GetRole(token)
    local props = token.properties
    local role = SafeCall(function()
        return props:Role()
    end, nil)

    role = Lower(role)
    if role ~= "" and role ~= "none" and role ~= "hero" then
        return role
    end

    local roleText = Lower(TryGet(props, "role", ""))
    local first, second = string.match(roleText, "^(%S+)%s+(%S+)")
    return second or first or "standard"
end

function AI:GetMonsterOverride(actor)
    for _,override in ipairs(self.monsterOverrides) do
        local matches = override.matches
        local ok = false

        if type(matches) == "function" then
            ok = SafeCall(function()
                return matches(actor)
            end, false)
        elseif type(matches) == "string" then
            ok = Lower(TryGet(actor.token.properties, "monster_type", "")) == Lower(matches)
        end

        if ok then
            return override
        end
    end

    return nil
end

local function CopyProfile(profile)
    local result = {}
    for k,v in pairs(profile or {}) do
        result[k] = v
    end
    return result
end

local function AddDoctrine(result, doctrine)
    if doctrine == nil or doctrine == "" then
        return
    end

    if result.doctrine == nil or result.doctrine == "" then
        result.doctrine = doctrine
        return
    end

    if string.find(result.doctrine, doctrine, 1, true) == nil then
        result.doctrine = result.doctrine .. "; " .. doctrine
    end
end

function AI:ApplyRoleProfileLayer(result, layer, primaryRange)
    if result == nil or layer == nil then
        return result
    end

    if primaryRange then
        if layer.desiredRange ~= nil then
            result.desiredRange = layer.desiredRange
        end
        if layer.rangedDesiredRange ~= nil then
            result.rangedDesiredRange = layer.rangedDesiredRange
        end
    elseif result.desiredRange == nil then
        result.desiredRange = layer.desiredRange
        result.rangedDesiredRange = layer.rangedDesiredRange
    end

    for _,key in ipairs({ "rangeWeight", "flankWeight", "avoidAdjacent", "protectAllies" }) do
        if layer[key] ~= nil then
            result[key] = math.max(result[key] or 0, layer[key])
        end
    end

    AddDoctrine(result, layer.doctrine)
    return result
end

function AI:GetRoleProfile(actor)
    local standard = self.roleProfiles.standard or {}
    local roleProfile = self.roleProfiles[actor.role]
    local organizationProfile = self.roleProfiles[actor.organization]
    local profile = CopyProfile(standard)
    profile.id = table.concat({ tostring(actor.organization or "standard"), tostring(actor.role or "standard") }, "+")

    if organizationProfile ~= nil and organizationProfile ~= roleProfile then
        self:ApplyRoleProfileLayer(profile, organizationProfile, roleProfile == nil)
    end

    if roleProfile ~= nil then
        self:ApplyRoleProfileLayer(profile, roleProfile, true)
    end

    local override = actor.override
    if override == nil then
        override = self:GetMonsterOverride(actor)
        actor.override = override
    end

    if override ~= nil and override.profile ~= nil and self.roleProfiles[override.profile] ~= nil then
        self:ApplyRoleProfileLayer(profile, self.roleProfiles[override.profile], true)
        profile.overrideProfile = override.profile
    end

    return profile or self.roleProfiles.standard
end

function AI:BuildContext(initiativeid)
    local queue = dmhub.initiativeQueue
    local context = {
        queue = queue,
        initiativeid = initiativeid,
        actors = {},
        allCombatTokens = {},
        activeTokens = {},
        startTurnMaliceUsed = false,
        runGeneration = Runtime.runGeneration,
        round = TryGet(queue, "round", 1),
        malice = SafeCall(function()
            local resource = RawGlobal("CharacterResource")
            if resource == nil then
                return 0
            end
            return resource.GetMalice()
        end, 0),
        villainActions = SafeCall(function()
            local resource = RawGlobal("CharacterResource")
            if resource == nil then
                return 0
            end
            return resource.GetVillainActions()
        end, 0),
    }
    context.encounterPlan = self:GetEncounterPlan()
    context.encounterState = self.encounterState or self:NewEncounterState()

    if queue == nil or queue.hidden then
        if self.encounterState ~= nil and self.encounterState.signature ~= nil then
            self:ResetEncounterState("combat ended")
            context.encounterState = self.encounterState
        end
        return context
    end

    local activeTokens = SafeCall(function()
        return self:GetInitiativeTokens(initiativeid)
    end, {}) or {}

    for _,tok in ipairs(dmhub.allTokens or {}) do
        local entryId = SafeCall(function()
            local initiativeQueue = RawGlobal("InitiativeQueue")
            if initiativeQueue == nil then
                return nil
            end
            return initiativeQueue.GetInitiativeId(tok)
        end, nil)

        if entryId ~= nil and queue.entries[entryId] ~= nil and IsTokenValid(tok) then
            context.allCombatTokens[#context.allCombatTokens+1] = tok
        end
    end

    activeTokens = self:ExpandActiveTokens(context, activeTokens)
    context.activeTokens = activeTokens
    self:RefreshTransientCombatFacts(context)

    self:RefreshEncounterState(context)

    local processedSquads = {}
    local function AddActorForToken(tok)
        if IsTokenValid(tok) and not tok.playerControlled then
            if TryGet(tok.properties, "minion", false) then
                local squadid = SafeCall(function()
                    return tok.properties:MinionSquad()
                end, tok.charid)

                if not processedSquads[squadid] then
                    processedSquads[squadid] = true

                    local squadMembers = {}
                    local captain = nil
                    for _,member in ipairs(context.allCombatTokens) do
                        local memberSquad = SafeCall(function()
                            return member.properties:MinionSquad()
                        end, nil)

                        if memberSquad == squadid and TokensFriendly(tok, member) then
                            if TryGet(member.properties, "minion", false) then
                                squadMembers[#squadMembers+1] = { token = member }
                            else
                                captain = member
                            end
                        end
                    end

                    context.actors[#context.actors+1] = {
                        token = tok,
                        kind = "squad",
                        squadid = squadid,
                        squadMembers = squadMembers,
                        squadCaptain = captain,
                        role = self:GetRole(tok),
                        organization = self:GetOrganization(tok),
                        enemies = {},
                        allies = {},
                        turnMemory = self.NewTurnMemory and self:NewTurnMemory() or {},
                    }
                end
            else
                context.actors[#context.actors+1] = {
                    token = tok,
                    kind = "single",
                    squadMembers = {},
                    role = self:GetRole(tok),
                    organization = self:GetOrganization(tok),
                    enemies = {},
                    allies = {},
                    turnMemory = self.NewTurnMemory and self:NewTurnMemory() or {},
                }
            end
        end
    end

    for _,tok in ipairs(activeTokens) do
        if IsTokenValid(tok) and TryGet(tok.properties, "minion", false) then
            AddActorForToken(tok)
        end
    end

    for _,tok in ipairs(activeTokens) do
        if IsTokenValid(tok) and not TryGet(tok.properties, "minion", false) then
            AddActorForToken(tok)
        end
    end

    for _,actor in ipairs(context.actors) do
        for _,tok in ipairs(context.allCombatTokens) do
            if tok.charid ~= actor.token.charid then
                if TokensFriendly(actor.token, tok) then
                    actor.allies[#actor.allies+1] = tok
                else
                    actor.enemies[#actor.enemies+1] = tok
                end
            end
        end
        actor.override = self:GetMonsterOverride(actor)
        actor.profile = self:GetRoleProfile(actor)
        actor.context = context
    end

    return context
end

function AI:BuildActorForToken(context, token)
    if context == nil or not IsTokenValid(token) or token.playerControlled then
        return nil
    end

    local actor = {
        token = token,
        kind = "single",
        squadMembers = {},
        allies = {},
        enemies = {},
        role = self:GetRole(token),
        organization = self:GetOrganization(token),
        turnMemory = self.NewTurnMemory and self:NewTurnMemory() or {},
    }

    for _,tok in ipairs(context.allCombatTokens or {}) do
        if tok.charid ~= token.charid then
            if TokensFriendly(token, tok) then
                actor.allies[#actor.allies+1] = tok
            else
                actor.enemies[#actor.enemies+1] = tok
            end
        end
    end

    actor.override = self:GetMonsterOverride(actor)
    actor.profile = self:GetRoleProfile(actor)
    actor.context = context

    return actor
end

function AI:IsMultiTurnBossToken(tok)
    if not IsTokenValid(tok) then
        return false
    end

    local turns = SafeCall(function()
        return tok.properties:TurnsPerRound()
    end, 1)

    if turns ~= nil and turns > 1 then
        return true
    end

    return self:GetOrganization(tok) == "solo"
end

function AI:InitiativeWouldRepeatBossTurn(initiativeid, tokens)
    local state = self.encounterState
    if state == nil or state.lastTurnBlockIds == nil or next(state.lastTurnBlockIds) == nil then
        return false
    end

    if self:HasInterveningTurnSinceBoss(initiativeid) then
        self:ClearConsecutiveBossBlock("another turn occurred")
        return false
    end

    tokens = tokens or self:GetInitiativeTokens(initiativeid)
    for _,tok in ipairs(tokens or {}) do
        local id = TokenId(tok)
        if id ~= nil and state.lastTurnBlockIds[id] and self:IsMultiTurnBossToken(tok) then
            return true
        end
    end

    return false
end

function AI:HasInterveningTurnSinceBoss(currentInitiativeId)
    local state = self.encounterState
    local queue = dmhub.initiativeQueue
    if state == nil or queue == nil or queue.hidden or state.lastTurnRound == nil or state.lastTurnTurn == nil then
        return false
    end

    local currentRound = tonumber(TryGet(queue, "round", state.lastTurnRound)) or state.lastTurnRound
    if currentRound > state.lastTurnRound + 1 then
        return true
    end

    for entryid,entry in pairs(TryGet(queue, "entries", {}) or {}) do
        if entryid ~= currentInitiativeId then
            local turn = tonumber(TryGet(entry, "turn", nil))
            local entryRound = tonumber(TryGet(entry, "round", nil))
            if turn ~= nil and entryRound ~= nil and entryRound > state.lastTurnRound and turn > state.lastTurnTurn then
                return true
            end
        end
    end

    return false
end

function AI:ClearConsecutiveBossBlock(reason)
    local state = self.encounterState
    if state == nil or state.lastTurnBlockIds == nil or next(state.lastTurnBlockIds) == nil then
        return
    end

    state.lastTurnBlockIds = {}
    state.lastTurnSummary = ""
    state.lastTurnInitiativeId = nil
    state.lastTurnRound = nil
    state.lastTurnTurn = nil
    if reason ~= nil then
        self:Log("Consecutive boss guard cleared: " .. tostring(reason))
    end
end

function AI:RecordCompletedTurn(context)
    if context == nil then
        return
    end

    local state = context.encounterState or self.encounterState
    if state == nil then
        return
    end

    local blockIds = {}
    local names = {}
    for _,tok in ipairs(context.activeTokens or {}) do
        if self:IsMultiTurnBossToken(tok) then
            local id = TokenId(tok)
            if id ~= nil then
                blockIds[id] = true
                names[#names+1] = TokenName(tok)
            end
        end
    end

    state.lastTurnBlockIds = blockIds
    state.lastTurnSummary = table.concat(names, ", ")
    state.lastTurnInitiativeId = context.initiativeid
    state.lastTurnRound = context.round
    state.lastTurnTurn = SafeCall(function()
        return context.queue.entries[context.initiativeid].turn
    end, nil)
end
