local mod = dmhub.GetModLoading()

local AI = rawget(_G, "DirectorTacticsAI")
if AI == nil or AI._internal == nil then
    error("DirectorTacticsAI.lua must be loaded before this DirectorTactics subsystem")
end

local Internal = AI._internal

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick
local SafeCall = Internal.SafeCall
local TryGet = Internal.TryGet
local Lower = Internal.Lower
local ConstNumber = Internal.ConstNumber

local Ledger = AI.Ledger or {}
AI.Ledger = Ledger

Ledger.DefaultCriticalThreshold = Ledger.DefaultCriticalThreshold or ConstNumber("Resource", "DefaultCriticalThreshold", 19)

local function HasEntries(t)
    return type(t) == "table" and next(t) ~= nil
end

local ActionGrantAvailableCount
local ActionGrantConsumedCount
local ActionGrantAllowanceCount

local function ActorIsDazed(ai, actor)
    return actor ~= nil
        and actor.token ~= nil
        and ai.TargetHasCondition ~= nil
        and ai:TargetHasCondition(actor.token, "Dazed")
end

local function DazedTurnThingUsed(turnMemory)
    if turnMemory == nil then
        return false
    end

    local spent = (tonumber(turnMemory.actionsUsed) or 0)
        + (tonumber(turnMemory.maneuversUsed) or 0)
        + (tonumber(turnMemory.moveActionsUsed) or 0)
    if turnMemory.movedOnly or turnMemory.movementUsed then
        spent = math.max(spent, 1)
    end
    if ActionGrantConsumedCount ~= nil then
        spent = spent
            + ActionGrantConsumedCount(turnMemory, "action")
            + ActionGrantConsumedCount(turnMemory, "maneuver")
    end

    local allowed = 1 + (tonumber(turnMemory.soloActionsPaid) or 0)
    if ActionGrantAllowanceCount ~= nil then
        allowed = allowed
            + ActionGrantAllowanceCount(turnMemory, "action")
            + ActionGrantAllowanceCount(turnMemory, "maneuver")
    end
    return spent >= allowed
end

local function DazedCanTrySoloReopen(ai, actor)
    if ai == nil or actor == nil or ai.RoleIs == nil or not ai:RoleIs(actor, "solo") then
        return false
    end

    local context = actor.context
    if context ~= nil and context.malice ~= nil then
        return (tonumber(context.malice) or 0) >= 5
    end

    local resource = RawGlobal("CharacterResource")
    local malice = SafeCall(function()
        return resource.GetMalice()
    end, nil)

    return malice == nil or (tonumber(malice) or 0) >= 5
end

local function ActionCapacity(turnMemory)
    if turnMemory == nil then
        return 1
    end

    local base = math.max(1, tonumber(turnMemory.baseActionLimit) or tonumber(turnMemory.actionLimit) or 1)
    local solo = math.max(0, tonumber(turnMemory.soloActionsPaid) or tonumber(turnMemory.bonusActions) or 0)
    local temporary = math.max(0, tonumber(turnMemory._tmpBonusActions) or 0)
    return base + solo + temporary
end

local function SyncMovementMetrics(ai, actor, turnMemory)
    if turnMemory == nil then
        return
    end

    local props = actor ~= nil and actor.token ~= nil and actor.token.properties or nil
    local moveActionLimit = nil
    local moveBudgetTiles = nil
    local movedTiles = nil

    if props ~= nil then
        moveActionLimit = SafeCall(function()
            return props:NumberOfMovementActions()
        end, nil)
        moveBudgetTiles = SafeCall(function()
            return props:CurrentMovementSpeed()
        end, nil)
        movedTiles = SafeCall(function()
            return props:DistanceMovedThisTurn()
        end, nil)
    end

    moveActionLimit = tonumber(moveActionLimit)
    if moveActionLimit == nil or moveActionLimit <= 0 then
        moveActionLimit = tonumber(turnMemory.moveActionLimit) or 1
    end

    turnMemory.moveActionLimit = math.max(1, math.floor(moveActionLimit))
    turnMemory.moveActionsUsed = math.max(0, tonumber(turnMemory.moveActionsUsed) or 0)
    if turnMemory.moveActionUsed == true and turnMemory.moveActionsUsed <= 0 then
        turnMemory.moveActionsUsed = turnMemory.moveActionLimit
    end

    turnMemory.moveBudgetTiles = math.max(0, tonumber(moveBudgetTiles) or tonumber(turnMemory.moveBudgetTiles) or 0)
    turnMemory.movedTiles = math.max(0, tonumber(movedTiles) or tonumber(turnMemory.movedTiles) or 0)
    turnMemory.moveActionUsed = turnMemory.moveActionsUsed >= turnMemory.moveActionLimit
    turnMemory.movementUsed = turnMemory.moveActionUsed or turnMemory.movementUsed == true
    turnMemory.movedOnly = turnMemory.movedOnly == true
end

local function SnapshotActorConditions(ai, actor)
    local result = {}
    local props = actor ~= nil and actor.token ~= nil and actor.token.properties or nil
    local conditions = { "Dazed", "Restrained", "Grabbed", "Frightened", "Slowed", "Prone", "Hidden", "Taunted", "Weakened", "Bleeding" }

    for _,conditionName in ipairs(conditions) do
        local hasCondition = false
        if ai ~= nil and ai.TargetHasCondition ~= nil and actor ~= nil and actor.token ~= nil then
            hasCondition = ai:TargetHasCondition(actor.token, conditionName) == true
        elseif props ~= nil and props.HasNamedCondition ~= nil then
            hasCondition = SafeCall(function()
                return props:HasNamedCondition(conditionName)
            end, false) == true
        end
        result[conditionName] = hasCondition
    end

    return result
end

local function ActorCondition(turnMemory, conditionName)
    return turnMemory ~= nil
        and turnMemory.actorConditions ~= nil
        and turnMemory.actorConditions[conditionName] == true
end

local function IncrementGeneration(turnMemory)
    if turnMemory ~= nil then
        turnMemory.generation = (tonumber(turnMemory.generation) or 0) + 1
    end
end

local function ActionTypeForCost(cost)
    if cost == "action" then
        return { kind = "main" }
    elseif cost == "maneuver" then
        return { kind = "maneuver" }
    elseif cost == "movement" or cost == "movement-only" then
        return { kind = "move" }
    elseif cost == "villain" then
        return { kind = "villain" }
    elseif cost == "none" then
        return { kind = "none" }
    end

    return nil
end

local function CopyActionType(actionType)
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

local function SemanticActionTypeForAbilityInfo(abilityInfo)
    if abilityInfo == nil then
        return nil
    end

    local semantic = CopyActionType(abilityInfo.semanticActionType)
    if semantic ~= nil then
        return semantic
    end

    local semanticCost = abilityInfo.semanticActionCost
    if semanticCost ~= nil then
        return ActionTypeForCost(semanticCost)
    end

    return nil
end

local function ActionTypeFromAbilityInfo(ai, abilityInfo, explicitCost)
    local resolved = nil
    if ai ~= nil and ai.ResolveActionType ~= nil and abilityInfo ~= nil and abilityInfo.ability ~= nil then
        resolved = SafeCall(function()
            return ai:ResolveActionType(abilityInfo.ability)
        end, nil)
    end

    local semantic = SemanticActionTypeForAbilityInfo(abilityInfo)
    if explicitCost ~= nil and not (resolved ~= nil and resolved.kind == "solo") then
        local explicit = ActionTypeForCost(explicitCost)
        if explicit ~= nil then
            if explicit.kind == "none" and semantic ~= nil and semantic.kind ~= "none" then
                explicit = nil
            end
        end
        if explicit ~= nil then
            return explicit
        end
    end

    if resolved ~= nil and resolved.kind == "none" and semantic ~= nil and semantic.kind ~= "none" then
        return semantic
    end

    if resolved ~= nil then
        return resolved
    end

    if semantic ~= nil then
        return semantic
    end

    if abilityInfo ~= nil then
        if abilityInfo.isVillain then
            return { kind = "villain" }
        elseif abilityInfo.isManeuver then
            return { kind = "maneuver" }
        elseif abilityInfo.isAction then
            return { kind = "main" }
        elseif abilityInfo.isStartTurnMalice or abilityInfo.isMalice then
            return { kind = "malice" }
        end
    end

    return { kind = "none" }
end

local function DazedAllowedActionType(kind)
    return kind == "main" or kind == "maneuver" or kind == "move"
end

local function CopyTableShallow(t)
    if type(t) ~= "table" then
        return t
    end

    local result = {}
    for key,value in pairs(t) do
        result[key] = value
    end
    return result
end

local function CopyActionGrants(grants)
    if type(grants) ~= "table" then
        return {}
    end

    local result = {}
    for i,grant in ipairs(grants) do
        result[i] = CopyTableShallow(grant)
    end
    return result
end

local function EnsureActionGrants(turnMemory)
    if turnMemory == nil then
        return {}
    end

    if type(turnMemory.actionGrants) ~= "table" then
        turnMemory.actionGrants = {}
    end

    turnMemory.actionGrantSequence = math.max(0, tonumber(turnMemory.actionGrantSequence) or 0)
    return turnMemory.actionGrants
end

local function NormalizeGrantKind(kind)
    if kind == "main" then
        return "action"
    elseif kind == "action" or kind == "maneuver" then
        return kind
    end

    return nil
end

local function GrantKindForActionType(actionType)
    local kind = actionType and actionType.kind or "none"
    if kind == "main" then
        return "action"
    elseif kind == "maneuver" then
        return "maneuver"
    end

    return nil
end

local function GrantUsedKeys(kind)
    if kind == "maneuver" then
        return "maneuversUsed", "maneuverUsed"
    end

    return "actionsUsed", "actionUsed"
end

ActionGrantAvailableCount = function(turnMemory, kind)
    kind = NormalizeGrantKind(kind)
    if turnMemory == nil or kind == nil then
        return 0
    end

    local count = 0
    for _,grant in ipairs(EnsureActionGrants(turnMemory)) do
        if grant.kind == kind and grant.appliedToEngine ~= true and grant.consumed ~= true and grant.reserved ~= true then
            count = count + math.max(0, tonumber(grant.remaining) or tonumber(grant.quantity) or 1)
        end
    end
    return count
end

ActionGrantConsumedCount = function(turnMemory, kind)
    kind = NormalizeGrantKind(kind)
    if turnMemory == nil or kind == nil or type(turnMemory.actionGrants) ~= "table" then
        return 0
    end

    local count = 0
    for _,grant in ipairs(turnMemory.actionGrants) do
        if grant.kind == kind and grant.consumed == true then
            count = count + math.max(1, tonumber(grant.quantity) or 1)
        end
    end
    return count
end

ActionGrantAllowanceCount = function(turnMemory, kind)
    kind = NormalizeGrantKind(kind)
    if turnMemory == nil or kind == nil or type(turnMemory.actionGrants) ~= "table" then
        return 0
    end

    local count = 0
    for _,grant in ipairs(turnMemory.actionGrants) do
        if grant.kind == kind then
            count = count + math.max(1, tonumber(grant.quantity) or 1)
        end
    end
    return count
end

local function RecomputeResourceFlags(turnMemory)
    if turnMemory == nil then
        return
    end

    EnsureActionGrants(turnMemory)
    turnMemory.soloActionsPaid = math.max(0, tonumber(turnMemory.soloActionsPaid) or tonumber(turnMemory.bonusActions) or 0)
    turnMemory.bonusActions = turnMemory.soloActionsPaid

    if turnMemory.baseActionLimit == nil then
        local effectiveLimit = math.max(1, tonumber(turnMemory.actionLimit) or 1)
        local temporary = math.max(0, tonumber(turnMemory._tmpBonusActions) or 0)
        turnMemory.baseActionLimit = math.max(1, effectiveLimit - turnMemory.soloActionsPaid - temporary)
    end

    turnMemory.baseActionLimit = math.max(1, tonumber(turnMemory.baseActionLimit) or 1)
    turnMemory.actionLimit = ActionCapacity(turnMemory)
    turnMemory.actionsUsed = math.max(0, tonumber(turnMemory.actionsUsed) or 0)
    turnMemory.maneuversUsed = math.max(0, tonumber(turnMemory.maneuversUsed) or 0)
    turnMemory.actionUsed = turnMemory.actionsUsed >= turnMemory.actionLimit
    turnMemory.maneuverUsed = turnMemory.maneuversUsed >= 1
    turnMemory.moveActionLimit = math.max(1, tonumber(turnMemory.moveActionLimit) or 1)
    turnMemory.moveActionsUsed = math.max(0, tonumber(turnMemory.moveActionsUsed) or 0)
    turnMemory.moveActionUsed = turnMemory.moveActionsUsed >= turnMemory.moveActionLimit
    turnMemory.generation = math.max(0, tonumber(turnMemory.generation) or 0)
end

local function TurnSpendQuantity(actionType)
    local quantity = tonumber(actionType and actionType.slot and actionType.slot.quantity) or 1
    return math.max(1, quantity)
end

local function ShouldConsumeMove(actionType, preInvokeMove)
    return actionType ~= nil and actionType.kind == "move" or preInvokeMove ~= nil
end

local function MarkDazedSpend(ai, actor, turnMemory, kind)
    if turnMemory == nil or not ActorIsDazed(ai, actor) or not DazedAllowedActionType(kind) then
        return
    end

    turnMemory.turnEnded = true
end

local function RecomputeAfterDebit(turnMemory)
    RecomputeResourceFlags(turnMemory)
    IncrementGeneration(turnMemory)
end

-- Keep this definition close to the helpers that mutate action fields; old callers
-- still use actionUsed/maneuverUsed, while Phase 2 uses numeric counters.
local function NormalizeLegacyFlags(turnMemory)
    if turnMemory == nil then
        return
    end

    if turnMemory.actionUsed == true and (tonumber(turnMemory.actionsUsed) or 0) <= 0 then
        turnMemory.actionsUsed = math.max(1, tonumber(turnMemory.actionLimit) or 1)
    end
    if turnMemory.maneuverUsed == true and (tonumber(turnMemory.maneuversUsed) or 0) <= 0 then
        turnMemory.maneuversUsed = 1
    end
    if (turnMemory.movedOnly or turnMemory.movementUsed or turnMemory.moveActionUsed) and (tonumber(turnMemory.moveActionsUsed) or 0) <= 0 then
        turnMemory.moveActionsUsed = math.max(1, tonumber(turnMemory.moveActionLimit) or 1)
    end
end

local function ReconcileMoveCompatFlags(turnMemory)
    if turnMemory == nil then
        return
    end

    turnMemory.moveActionUsed = (tonumber(turnMemory.moveActionsUsed) or 0) >= (tonumber(turnMemory.moveActionLimit) or 1)
    turnMemory.movementUsed = turnMemory.movementUsed == true or turnMemory.moveActionUsed == true
end

local function ActionKind(actionType)
    return actionType and actionType.kind or "none"
end

local function MainCapacity(turnMemory)
    return tonumber(turnMemory and turnMemory.actionLimit) or 1
end

local function ManeuverCapacity(turnMemory)
    return 1
end

local function MoveCapacity(turnMemory)
    return tonumber(turnMemory and turnMemory.moveActionLimit) or 1
end

local function KindConsumesSquadEconomy(kind)
    return kind == "main" or kind == "maneuver"
end

local function MovementBudgetRemaining(turnMemory)
    local budget = tonumber(turnMemory and turnMemory.moveBudgetTiles) or 0
    local limit = tonumber(turnMemory and turnMemory.moveActionLimit) or 1
    local moved = tonumber(turnMemory and turnMemory.movedTiles) or 0
    return math.max(0, budget * limit - moved)
end

local function CanUseSoloActionType(ai, actor, actionType)
    if ai == nil or actor == nil or ai.RoleIs == nil or not ai:RoleIs(actor, "solo") then
        return false, "Solo Action requires a Solo actor"
    end

    local context = actor.context
    local cost = tonumber(actionType and actionType.slot and actionType.slot.quantity) or 5
    if context ~= nil and context.malice ~= nil and (tonumber(context.malice) or 0) < cost then
        return false, "cannot afford Solo Action"
    end

    return true, nil
end

local function DazedActionTypeBlocked(turnMemory, kind)
    if kind == "solo" then
        return false, nil
    end

    if not DazedAllowedActionType(kind) then
        return true, "dazed actor cannot use free actions"
    end

    return turnMemory.turnEnded
        or DazedTurnThingUsed(turnMemory),
        "dazed actor already used one turn option"
end

local function ModifyTokenProperties(token, description, execute)
    if token == nil or token.properties == nil or execute == nil then
        return nil
    end

    local result = nil
    if token.ModifyProperties ~= nil then
        SafeCall(function()
            token:ModifyProperties{
                description = description,
                execute = function()
                    result = execute()
                end,
            }
        end, nil)
    else
        result = SafeCall(execute, nil)
    end

    return result
end

function Ledger:NewTurnMemory()
    return {
        actionsUsed = 0,
        actionUsed = false,
        baseActionLimit = 1,
        actionLimit = 1,
        maneuversUsed = 0,
        maneuverUsed = false,
        moveActionsUsed = 0,
        moveActionLimit = 1,
        moveActionUsed = false,
        moveBudgetTiles = 0,
        movedTiles = 0,
        villainActionUsed = false,
        soloActionsPaid = 0,
        actionGrants = {},
        actionGrantSequence = 0,
        actorConditions = {},
        generation = 0,
        rejectedCandidateKeys = {},
    }
end

function Ledger:EnsureTurnMemory(ai, actor)
    if actor == nil then
        return nil
    end

    actor.turnMemory = actor.turnMemory or self:NewTurnMemory()
    actor.turnMemory.actionsUsed = tonumber(actor.turnMemory.actionsUsed) or 0
    actor.turnMemory.maneuversUsed = tonumber(actor.turnMemory.maneuversUsed) or 0
    actor.turnMemory.actionLimit = math.max(1, tonumber(actor.turnMemory.actionLimit) or tonumber(actor.turnMemory.baseActionLimit) or 1)
    actor.turnMemory.moveActionLimit = math.max(1, tonumber(actor.turnMemory.moveActionLimit) or 1)
    NormalizeLegacyFlags(actor.turnMemory)
    RecomputeResourceFlags(actor.turnMemory)

    return actor.turnMemory
end

function Ledger:Init(ai, actor)
    if actor == nil then
        return nil
    end

    self:SyncTurnMemoryFromResources(ai, actor)
    return actor.turnMemory
end

function Ledger:HasMoveAction(ai, actor)
    local turnMemory = self:Init(ai, actor)
    if turnMemory == nil then
        return false
    end

    return (tonumber(turnMemory.moveActionsUsed) or 0) < (tonumber(turnMemory.moveActionLimit) or 1)
end

function Ledger:HasMoveBudget(ai, actor, tiles)
    local turnMemory = self:Init(ai, actor)
    if turnMemory == nil then
        return false
    end

    tiles = tonumber(tiles)
    if tiles == nil then
        return true
    end

    return tiles <= MovementBudgetRemaining(turnMemory) + 0.1
end

function Ledger:Snapshot(ai, actor)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return nil
    end

    local keys = {
        "actionsUsed",
        "actionUsed",
        "baseActionLimit",
        "actionLimit",
        "maneuversUsed",
        "maneuverUsed",
        "moveActionsUsed",
        "moveActionLimit",
        "moveActionUsed",
        "moveBudgetTiles",
        "movedTiles",
        "movedOnly",
        "movementUsed",
        "villainActionUsed",
        "soloActionsPaid",
        "bonusActions",
        "actionGrants",
        "actionGrantSequence",
        "turnEnded",
        "mainOrManeuverUsed",
        "generation",
        "nextSelectedAbilityHasPotency",
    }

    local snap = {}
    for _,key in ipairs(keys) do
        if key == "actionGrants" then
            snap[key] = CopyActionGrants(turnMemory[key])
        else
            snap[key] = turnMemory[key]
        end
    end
    snap.actorConditions = CopyTableShallow(turnMemory.actorConditions)
    return snap
end

function Ledger:Restore(ai, actor, snap)
    if snap == nil then
        return false
    end

    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return false
    end

    for key,value in pairs(snap) do
        if key == "actorConditions" then
            turnMemory.actorConditions = CopyTableShallow(value)
        else
            turnMemory[key] = value
        end
    end
    RecomputeResourceFlags(turnMemory)
    return true
end

local function ActionCostForResolvedActionType(actionType)
    if actionType == nil then
        return nil
    end

    local kind = actionType.kind
    if kind == "main" then
        return "action"
    elseif kind == "maneuver" then
        return "maneuver"
    elseif kind == "move" then
        return "movement"
    elseif kind == "villain" then
        return "villain"
    elseif kind == "malice"
        or kind == "solo"
        or kind == "freeManeuver"
        or kind == "freeTriggered"
        or kind == "triggered"
        or kind == "none"
    then
        return "none"
    end

    return nil
end

function Ledger:AbilityActionCost(ai, abilityInfo)
    if abilityInfo == nil then
        return "none"
    end

    local semantic = SemanticActionTypeForAbilityInfo(abilityInfo)
    if ai ~= nil and ai.ResolveActionType ~= nil and abilityInfo.ability ~= nil then
        local actionType = SafeCall(function()
            return ai:ResolveActionType(abilityInfo.ability)
        end, nil)
        local resolvedCost = ActionCostForResolvedActionType(actionType)
        if resolvedCost ~= nil and not (resolvedCost == "none" and semantic ~= nil and semantic.kind ~= "none") then
            return resolvedCost
        end
    end

    local semanticCost = ActionCostForResolvedActionType(semantic)
    if semanticCost ~= nil then
        return semanticCost
    end

    if abilityInfo.isVillain then
        return "villain"
    end

    if abilityInfo.isStartTurnMalice or abilityInfo.isMalice then
        return "none"
    end

    if abilityInfo.isManeuver then
        return "maneuver"
    end

    if abilityInfo.isAction then
        return "action"
    end

    return "none"
end

function Ledger:ActionTypeFromAbilityInfo(ai, abilityInfo, explicitCost)
    return ActionTypeFromAbilityInfo(ai, abilityInfo, explicitCost)
end

function Ledger:SyncTurnMemoryFromResources(ai, actor, options)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or actor.token == nil or actor.token.properties == nil then
        return
    end

    local resource = RawGlobal("CharacterResource")
    if resource == nil then
        SyncMovementMetrics(ai, actor, turnMemory)
        RecomputeResourceFlags(turnMemory)
        return
    end

    local resourceOptions = {
        resourceTable = self:ResourceMetadataTable(options),
        resourceTableResolved = true,
    }
    local refreshedKinds = {}
    local function SyncResource(resourceid, usedKey, flagKey, limitKey, refreshKind)
        if resourceid == nil or resourceid == "none" then
            return
        end

        local refreshType = self:ResourceRefreshTypeForKind(refreshKind, resourceOptions)
        local usage = SafeCall(function()
            return actor.token.properties:GetResourceUsage(resourceid, refreshType)
        end, nil)

        if usage == nil then
            return
        end

        usage = tonumber(usage) or 0
        local previousUsage = tonumber(turnMemory[usedKey]) or 0
        if turnMemory[flagKey] then
            previousUsage = math.max(previousUsage, 1)
        end

        local allowDecrease = turnMemory._allowResourceDecrease ~= nil and turnMemory._allowResourceDecrease[usedKey] == true
        local observedDecrease = allowDecrease and usage < previousUsage
        if not allowDecrease then
            usage = math.max(usage, previousUsage)
        end
        turnMemory[usedKey] = usage
        turnMemory[flagKey] = usage >= 1
        if observedDecrease and refreshKind ~= nil then
            refreshedKinds[refreshKind] = true
        end
        if allowDecrease then
            turnMemory._allowResourceDecrease[usedKey] = nil
        end

        if limitKey ~= nil then
            local maximum = SafeCall(function()
                local resources = actor.token.properties:GetResources()
                return resources and resources[resourceid]
            end, nil)

            maximum = tonumber(maximum)
            local limit = nil
            if maximum ~= nil and maximum > 0 then
                limit = math.max(1, maximum)
            end

            if limitKey == "actionLimit" then
                turnMemory.baseActionLimit = math.max(1, tonumber(limit) or tonumber(turnMemory.baseActionLimit) or 1)
                limit = ActionCapacity(turnMemory)
            end

            if limit ~= nil then
                turnMemory[limitKey] = limit
                turnMemory[flagKey] = usage >= limit
            end
        end

        if ai ~= nil and ai.Trace ~= nil then
            ai:Trace("resource", "engine resource synced", {
                actor = actor and ai._internal and ai._internal.TokenName and ai._internal.TokenName(actor.token),
                kind = refreshKind,
                refreshType = refreshType,
                usage = usage,
                usedKey = usedKey,
                limitKey = limitKey,
            }, { coalesce = true })
        end
    end

    SyncResource(TryGet(resource, "actionResourceId", nil), "actionsUsed", "actionUsed", "actionLimit", "action")
    SyncResource(TryGet(resource, "maneuverResourceId", nil), "maneuversUsed", "maneuverUsed", nil, "maneuver")
    SyncMovementMetrics(ai, actor, turnMemory)
    RecomputeResourceFlags(turnMemory)
    if HasEntries(refreshedKinds) then
        self:ReopenRefreshedEconomy(ai, actor, refreshedKinds, "resource refresh observed")
    end
end

function Ledger:CurrentRoundNumber(ai, context, state)
    local round = tonumber((context and context.round) or (state and state.round) or 1) or 1
    return math.max(1, math.floor(round))
end

function Ledger:MaliciousStrikeBlocked(ai, context)
    local state = (context and context.encounterState) or ai.encounterState
    if state == nil then
        return false, nil
    end

    local currentRound = self:CurrentRoundNumber(ai, context, state)
    local rounds = state.maliciousStrikeRounds or {}
    if rounds[currentRound] == true or rounds[tostring(currentRound)] == true then
        return true, "Malicious Strike already used this round"
    end

    if currentRound > 1 and (rounds[currentRound - 1] == true or rounds[tostring(currentRound - 1)] == true) then
        return true, "Malicious Strike cannot be used two rounds in a row"
    end

    local lastRound = tonumber(state.lastMaliciousStrikeRound)
    if lastRound ~= nil and lastRound <= currentRound and lastRound >= currentRound - 1 then
        if lastRound == currentRound then
            return true, "Malicious Strike already used this round"
        end

        return true, "Malicious Strike cannot be used two rounds in a row"
    end

    return false, nil
end

function Ledger:MarkMaliciousStrikeUsed(ai, context)
    local state = (context and context.encounterState) or ai.encounterState
    if state == nil then
        return
    end

    local round = self:CurrentRoundNumber(ai, context, state)
    state.maliciousStrikeRounds = state.maliciousStrikeRounds or {}
    state.maliciousStrikeRounds[round] = true
    state.maliciousStrikeRounds[tostring(round)] = true
    state.lastMaliciousStrikeRound = round
end

function Ledger:StartTurnMaliceKey(ai, context)
    if context == nil then
        return "unknown"
    end

    local turn = SafeCall(function()
        if context.queue == nil or context.queue.entries == nil or context.initiativeid == nil then
            return nil
        end
        return context.queue.entries[context.initiativeid].turn
    end, nil)

    return tostring(context.round or 1) .. ":" .. tostring(turn or "") .. ":" .. tostring(context.initiativeid or "")
end

function Ledger:HasUsedStartTurnMalice(ai, context)
    if context ~= nil and context.startTurnMaliceUsed then
        return true
    end

    local state = (context and context.encounterState) or ai.encounterState
    if state == nil or state.usedStartTurnMaliceKeys == nil then
        return false
    end

    return state.usedStartTurnMaliceKeys[self:StartTurnMaliceKey(ai, context)] == true
end

function Ledger:MarkStartTurnMaliceUsed(ai, context)
    if context ~= nil then
        context.startTurnMaliceUsed = true
    end

    local state = (context and context.encounterState) or ai.encounterState
    if state == nil then
        return
    end

    state.usedStartTurnMaliceKeys = state.usedStartTurnMaliceKeys or {}
    state.usedStartTurnMaliceKeys[self:StartTurnMaliceKey(ai, context)] = true
end

function Ledger:CanSpend(ai, actor, abilityInfo, explicitCost)
    self:Init(ai, actor)

    if actor == nil then
        return false, "missing actor"
    end

    local actionType = ActionTypeFromAbilityInfo(ai, abilityInfo, explicitCost)
    local context = actor.context

    if abilityInfo ~= nil and abilityInfo.isMalice then
        local name = Lower(abilityInfo.name or "")
        local state = (context and context.encounterState) or ai.encounterState
        if ai:IsMaliciousStrikeName(name) and state ~= nil then
            local blocked, reason = self:MaliciousStrikeBlocked(ai, context)
            if blocked then
                return false, reason
            end
        end
    end

    return self:CanSpendActionType(ai, actor, actionType, nil)
end

function Ledger:CanSpendActionType(ai, actor, actionType, preInvokeMove)
    if actor == nil then
        ai:Trace("resource", "affordability failed", { reason = "missing actor" })
        return false, "missing actor"
    end

    self:SyncTurnMemoryFromResources(ai, actor)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    turnMemory.actorConditions = SnapshotActorConditions(ai, actor)
    local kind = ActionKind(actionType)
    local function Deny(reason)
        ai:Trace("resource", "affordability failed", {
            actor = ai._internal.TokenName(actor.token),
            kind = kind,
            reason = reason,
            actionsUsed = turnMemory.actionsUsed,
            actionLimit = turnMemory.actionLimit,
            maneuversUsed = turnMemory.maneuversUsed,
            moveActionsUsed = turnMemory.moveActionsUsed,
            moveActionLimit = turnMemory.moveActionLimit,
        })
        return false, reason
    end

    if actor.kind == "squad" and KindConsumesSquadEconomy(kind) and turnMemory.mainOrManeuverUsed then
        return Deny("minion squad already used main action or maneuver")
    end

    local actorDazed = ActorCondition(turnMemory, "Dazed") or ActorIsDazed(ai, actor)
    if turnMemory.turnEnded and not (kind == "solo" and actorDazed) then
        return Deny("turn already ended")
    end

    if actorDazed then
        local blocked, reason = DazedActionTypeBlocked(turnMemory, kind)
        if blocked then
            return Deny(reason)
        end
    end

    if kind == "solo" then
        local allowed, reason = CanUseSoloActionType(ai, actor, actionType)
        if not allowed then
            return Deny(reason)
        end
        return true, nil
    end

    if kind == "main" then
        local quantity = TurnSpendQuantity(actionType)
        if (tonumber(turnMemory.actionsUsed) or 0) + quantity > MainCapacity(turnMemory) then
            if ActionGrantAvailableCount(turnMemory, "action") >= quantity then
                ai:Trace("resource", "pending action grant allows spend", {
                    actor = actor and ai._internal.TokenName(actor.token),
                    kind = kind,
                    quantity = quantity,
                    pending = ActionGrantAvailableCount(turnMemory, "action"),
                })
            else
                return Deny("main action already used")
            end
        end
    end

    if kind == "maneuver" then
        local quantity = TurnSpendQuantity(actionType)
        if (tonumber(turnMemory.maneuversUsed) or 0) + quantity > ManeuverCapacity(turnMemory) then
            if ActionGrantAvailableCount(turnMemory, "maneuver") >= quantity then
                ai:Trace("resource", "pending action grant allows spend", {
                    actor = actor and ai._internal.TokenName(actor.token),
                    kind = kind,
                    quantity = quantity,
                    pending = ActionGrantAvailableCount(turnMemory, "maneuver"),
                })
            else
                return Deny("maneuver already used")
            end
        end
    end

    if ShouldConsumeMove(actionType, preInvokeMove) then
        if (tonumber(turnMemory.moveActionsUsed) or 0) + 1 > MoveCapacity(turnMemory) then
            return Deny("move already used")
        end
    end

    if kind == "villain" and turnMemory.villainActionUsed then
        return Deny("villain action already used")
    end

    return true, nil
end

function Ledger:CandidateActionGrant(ai, candidate)
    if candidate == nil then
        return nil
    end

    local execution = ai ~= nil and ai.CandidateExecution ~= nil and ai:CandidateExecution(candidate) or {}
    return execution.actionGrant or candidate.actionGrant
end

function Ledger:PendingGrantUseForActionType(ai, actor, actionType, preInvokeMove)
    self:SyncTurnMemoryFromResources(ai, actor)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    local kind = GrantKindForActionType(actionType)
    if turnMemory == nil or kind == nil then
        return nil
    end

    if ShouldConsumeMove(actionType, preInvokeMove)
        and (tonumber(turnMemory.moveActionsUsed) or 0) + 1 > MoveCapacity(turnMemory)
    then
        return nil
    end

    local quantity = TurnSpendQuantity(actionType)
    local usedKey = GrantUsedKeys(kind)
    local capacity = Pick(kind == "maneuver", ManeuverCapacity(turnMemory), MainCapacity(turnMemory))
    if (tonumber(turnMemory[usedKey]) or 0) + quantity <= capacity then
        return nil
    end

    if ActionGrantAvailableCount(turnMemory, kind) < quantity then
        return nil
    end

    return {
        kind = kind,
        quantity = quantity,
        source = "pending action grant",
    }
end

function Ledger:AnnotateCandidateActionGrant(ai, actor, candidate)
    if candidate == nil then
        return false
    end

    local execution = ai.CandidateExecution and ai:CandidateExecution(candidate) or {}
    local actionType = execution.actionType or candidate.actionType or ActionTypeFromAbilityInfo(ai, candidate.abilityInfo, ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost)
    if (actionType == nil or actionType.kind == "none") and candidate.abilityInfo ~= nil then
        actionType = ActionTypeFromAbilityInfo(ai, candidate.abilityInfo, nil)
    end
    local preInvokeMove = ai.CandidatePreInvokeMove and ai:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
    local grantUse = self:PendingGrantUseForActionType(ai, actor, actionType, preInvokeMove)
    if grantUse == nil then
        return false
    end

    grantUse.actionTypeKind = actionType and actionType.kind
    grantUse.candidate = candidate.description
    if ai.WriteCandidateExecution ~= nil then
        ai:WriteCandidateExecution(candidate, {
            actionGrant = grantUse,
            usesActionGrant = true,
        })
    else
        execution.actionGrant = grantUse
        candidate.actionGrant = grantUse
        candidate.usesActionGrant = true
        if ai.SyncCandidateSections ~= nil then
            ai:SyncCandidateSections(candidate)
        end
    end
    ai:Trace("resource", "candidate uses pending action grant", {
        actor = actor and ai._internal.TokenName(actor.token),
        candidate = candidate.description,
        kind = grantUse.kind,
        quantity = grantUse.quantity,
    })
    return true
end

function Ledger:CanAffordAbilityWithPendingGrant(ai, actor, ability, abilityInfo, symbols)
    if actor == nil or ability == nil or abilityInfo == nil then
        return false
    end

    self:EnsureTurnMemory(ai, actor)
    local cost = self:AbilityActionCost(ai, abilityInfo)
    local kind = Pick(cost == "maneuver", "maneuver", Pick(cost == "action", "action", nil))
    if kind == nil or ActionGrantAvailableCount(actor.turnMemory, kind) <= 0 then
        return false
    end

    local clone = SafeCall(function()
        return ability:MakeTemporaryClone()
    end, nil)
    if clone == nil then
        return false
    end

    clone.actionResourceId = "none"
    return SafeCall(function()
        return clone:CanAfford(actor.token, { symbols = symbols or {} })
    end, false) == true
end

function Ledger:ReservePendingActionGrant(ai, actor, candidate)
    local grantUse = self:CandidateActionGrant(ai, candidate)
    if grantUse == nil then
        return true, nil
    end

    local kind = NormalizeGrantKind(grantUse.kind)
    local quantity = math.max(1, tonumber(grantUse.quantity) or 1)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or kind == nil then
        return false, "missing pending action grant"
    end

    local reserved = {}
    for _,grant in ipairs(EnsureActionGrants(turnMemory)) do
        if #reserved >= quantity then
            break
        end
        if grant.kind == kind and grant.appliedToEngine ~= true and grant.consumed ~= true and grant.reserved ~= true and (tonumber(grant.remaining) or 1) > 0 then
            grant.reserved = true
            grant.reservedBy = candidate and candidate.id or nil
            reserved[#reserved+1] = grant
        end
    end

    if #reserved < quantity then
        for _,grant in ipairs(reserved) do
            grant.reserved = nil
            grant.reservedBy = nil
        end
        ai:Trace("resource", "action grant reservation failed", {
            actor = actor and ai._internal.TokenName(actor.token),
            candidate = candidate and candidate.description,
            kind = kind,
            requested = quantity,
            reserved = #reserved,
        })
        return false, "pending action grant no longer available"
    end

    ai:Trace("resource", "action grant reserved", {
        actor = actor and ai._internal.TokenName(actor.token),
        candidate = candidate and candidate.description,
        kind = kind,
        quantity = quantity,
    })
    return true, {
        kind = kind,
        quantity = quantity,
        grants = reserved,
    }
end

function Ledger:RollbackPendingActionGrant(ai, actor, reservation, reason)
    if reservation == nil then
        return false
    end

    for _,grant in ipairs(reservation.grants or {}) do
        if grant.consumed ~= true then
            grant.reserved = nil
            grant.reservedBy = nil
        end
    end
    ai:Trace("resource", "action grant reservation rolled back", {
        actor = actor and ai._internal.TokenName(actor.token),
        kind = reservation.kind,
        quantity = reservation.quantity,
        reason = reason,
    })
    return true
end

function Ledger:CommitPendingActionGrant(ai, actor, candidate, reservation)
    if reservation == nil then
        return false
    end

    local turnMemory = self:EnsureTurnMemory(ai, actor)
    for _,grant in ipairs(reservation.grants or {}) do
        grant.reserved = nil
        grant.reservedBy = nil
        grant.consumed = true
        grant.remaining = 0
        grant.consumedBy = candidate and candidate.description or nil
        grant.consumedGeneration = turnMemory and turnMemory.generation or nil
    end
    if candidate ~= nil then
        if ai ~= nil and ai.WriteCandidateExecution ~= nil then
            ai:WriteCandidateExecution(candidate, {
                actionGrantCommitted = true,
            })
        else
            candidate.actionGrantCommitted = true
        end
    end
    RecomputeAfterDebit(turnMemory)
    ai:Trace("resource", "action grant consumed", {
        actor = actor and ai._internal.TokenName(actor.token),
        candidate = candidate and candidate.description,
        kind = reservation.kind,
        quantity = reservation.quantity,
        generation = turnMemory and turnMemory.generation,
    })
    return true
end

function Ledger:Spend(ai, actor, candidate)
    if actor == nil or candidate == nil then
        return
    end

    local turnMemory = self:EnsureTurnMemory(ai, actor)
    ai:Trace("resource", "spend", {
        actor = ai._internal.TokenName(actor.token),
        candidate = candidate.description,
        actionsUsed = turnMemory and turnMemory.actionsUsed,
        maneuversUsed = turnMemory and turnMemory.maneuversUsed,
        moveActionsUsed = turnMemory and turnMemory.moveActionsUsed,
        villainActionUsed = turnMemory and turnMemory.villainActionUsed,
    })
    local movementOnly = candidate.movementOnly == true
    if ai.CandidateMovementOnly ~= nil then
        movementOnly = ai:CandidateMovementOnly(candidate)
    end
    if movementOnly then
        self:DebitActionType(ai, actor, { kind = "move" }, nil)
        return
    end

    local abilityInfo = candidate.abilityInfo
    local cost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost or self:AbilityActionCost(ai, abilityInfo)
    local execution = ai.CandidateExecution and ai:CandidateExecution(candidate) or {}
    local actionType = execution.actionType or candidate.actionType or ActionTypeFromAbilityInfo(ai, abilityInfo, cost)
    if (actionType == nil or actionType.kind == "none") and abilityInfo ~= nil then
        local semanticActionType = ActionTypeFromAbilityInfo(ai, abilityInfo, cost)
        if semanticActionType ~= nil and semanticActionType.kind ~= "none" then
            actionType = semanticActionType
        end
    end
    local preInvokeMove = ai.CandidatePreInvokeMove and ai:CandidatePreInvokeMove(candidate) or candidate.preInvokeMove
    local actionGrant = self:CandidateActionGrant(ai, candidate)
    local actionGrantCommitted = candidate.actionGrantCommitted == true
    if execution.actionGrantCommitted ~= nil then
        actionGrantCommitted = execution.actionGrantCommitted == true
    end
    if actionGrantCommitted and actionGrant ~= nil then
        if ShouldConsumeMove(actionType, preInvokeMove) then
            turnMemory.moveActionsUsed = (tonumber(turnMemory.moveActionsUsed) or 0) + 1
            ReconcileMoveCompatFlags(turnMemory)
        end
        if actor.kind == "squad" and KindConsumesSquadEconomy(ActionKind(actionType)) then
            turnMemory.mainOrManeuverUsed = true
            turnMemory.turnEnded = true
        end
        MarkDazedSpend(ai, actor, turnMemory, ActionKind(actionType))
        RecomputeAfterDebit(turnMemory)
        return
    end

    self:DebitActionType(ai, actor, actionType, preInvokeMove)

    if actor.kind == "squad" and cost ~= "villain" and cost ~= "none" then
        turnMemory.mainOrManeuverUsed = true
        turnMemory.turnEnded = true
    end

    if abilityInfo ~= nil and ai:IsDefendName(abilityInfo.name) then
        turnMemory.actionsUsed = math.max(turnMemory.actionsUsed or 0, 1)
        RecomputeResourceFlags(turnMemory)
        turnMemory.turnEnded = true
    end
end

function Ledger:DebitActionType(ai, actor, actionType, preInvokeMove)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return false
    end

    local kind = ActionKind(actionType)
    ai:Trace("resource", "debit", {
        actor = actor and ai._internal.TokenName(actor.token),
        kind = kind,
        quantity = TurnSpendQuantity(actionType),
        preInvokeMove = preInvokeMove ~= nil,
        actionsUsed = turnMemory.actionsUsed,
        maneuversUsed = turnMemory.maneuversUsed,
        moveActionsUsed = turnMemory.moveActionsUsed,
    })
    if kind == "solo" then
        return self:TransformSoloAction(ai, actor, actor and actor.context or nil, nil)
    end

    if kind == "main" then
        turnMemory.actionsUsed = (tonumber(turnMemory.actionsUsed) or 0) + TurnSpendQuantity(actionType)
    elseif kind == "maneuver" then
        turnMemory.maneuversUsed = (tonumber(turnMemory.maneuversUsed) or 0) + TurnSpendQuantity(actionType)
    elseif kind == "villain" then
        turnMemory.villainActionUsed = true
    end

    if ShouldConsumeMove(actionType, preInvokeMove) then
        turnMemory.moveActionsUsed = (tonumber(turnMemory.moveActionsUsed) or 0) + 1
        turnMemory.movedOnly = kind == "move" or turnMemory.movedOnly == true
        ReconcileMoveCompatFlags(turnMemory)
    end

    if actor ~= nil and actor.kind == "squad" and KindConsumesSquadEconomy(kind) then
        turnMemory.mainOrManeuverUsed = true
        turnMemory.turnEnded = true
    end

    MarkDazedSpend(ai, actor, turnMemory, kind)
    RecomputeAfterDebit(turnMemory)
    ai:Trace("resource", "debit applied", {
        actor = actor and ai._internal.TokenName(actor.token),
        kind = kind,
        actionsUsed = turnMemory.actionsUsed,
        maneuversUsed = turnMemory.maneuversUsed,
        moveActionsUsed = turnMemory.moveActionsUsed,
        villainActionUsed = turnMemory.villainActionUsed,
        turnEnded = turnMemory.turnEnded,
        generation = turnMemory.generation,
    })
    return true
end

function Ledger:ActorActionEconomyComplete(ai, actor)
    self:Init(ai, actor)

    local turnMemory = actor and actor.turnMemory
    if turnMemory == nil then
        return true, "missing turn memory"
    end

    if ActionGrantAvailableCount(turnMemory, "action") > 0 or ActionGrantAvailableCount(turnMemory, "maneuver") > 0 then
        return false, nil
    end

    local actorDazed = ActorIsDazed(ai, actor)
    if turnMemory.turnEnded and not (actorDazed and DazedCanTrySoloReopen(ai, actor)) then
        return true, "turn ended"
    end

    if actorDazed and DazedTurnThingUsed(turnMemory) and not DazedCanTrySoloReopen(ai, actor) then
        return true, "dazed turn option spent"
    end

    if turnMemory.actionUsed and turnMemory.maneuverUsed then
        return true, "action and maneuver spent"
    end

    return false, nil
end

function Ledger:CriticalNaturalRoll(ai, symbols, finishOptions)
    local function ReadKey(container, keys)
        if container == nil then
            return nil
        end

        for _,key in ipairs(keys) do
            local value = tonumber(TryGet(container, key, nil))
            if value ~= nil then
                return value
            end
        end

        return nil
    end

    local function ReadFrom(container)
        if container == nil then
            return nil
        end

        local naturalKeys = { "naturalRoll", "naturalroll", "NaturalRoll", "naturalAttackRoll", "naturalattackroll", "Natural Attack Roll" }
        local highKeys = { "highRoll", "highroll", "HighRoll", "High Roll" }
        local lowKeys = { "lowRoll", "lowroll", "LowRoll", "Low Roll" }
        local cast = TryGet(container, "cast", nil)

        local natural = ReadKey(cast, naturalKeys) or ReadKey(container, naturalKeys)
        if natural ~= nil then
            return natural
        end

        local high = ReadKey(cast, highKeys) or ReadKey(container, highKeys)
        local low = ReadKey(cast, lowKeys) or ReadKey(container, lowKeys)
        if high ~= nil and low ~= nil then
            return high + low
        end

        return nil
    end

    return ReadFrom(symbols) or ReadFrom(TryGet(finishOptions, "symbols", nil))
end

function Ledger:CriticalThreshold(ai, actor)
    local threshold = SafeCall(function()
        return actor.token.properties:CalculateNamedCustomAttribute("Critical Threshold")
    end, self.DefaultCriticalThreshold)

    return tonumber(threshold) or self.DefaultCriticalThreshold
end

function Ledger:ResourceIdForKind(kind)
    local resource = RawGlobal("CharacterResource")
    if kind == "action" then
        return TryGet(resource, "actionResourceId", nil)
    elseif kind == "maneuver" then
        return TryGet(resource, "maneuverResourceId", nil)
    end

    return nil
end

function Ledger:ResourceMetadataTable(options)
    if type(options) == "table" then
        if options.resourceTableResolved == true or options.resourceTable ~= nil then
            return options.resourceTable
        end
    end

    if dmhub == nil or dmhub.GetTable == nil then
        return nil
    end

    local resource = RawGlobal("CharacterResource")
    local tableName = TryGet(resource, "tableName", "characterResources") or "characterResources"
    return SafeCall(function()
        return dmhub.GetTable(tableName)
    end, nil)
end

function Ledger:ResourceRefreshTypeForKind(kind, options)
    local resourceId = self:ResourceIdForKind(kind)
    if resourceId == nil then
        return "turn"
    end

    local resources = self:ResourceMetadataTable(options)
    local resourceInfo = resources ~= nil and resources[resourceId] or nil
    return TryGet(resourceInfo, "usageLimit", "turn") or "turn"
end

function Ledger:ResourceUsageForKind(ai, actor, kind)
    if actor == nil or actor.token == nil or actor.token.properties == nil then
        return 0
    end

    local resourceId = self:ResourceIdForKind(kind)
    if resourceId == nil then
        return 0
    end

    return tonumber(SafeCall(function()
        return actor.token.properties:GetResourceUsage(resourceId, self:ResourceRefreshTypeForKind(kind))
    end, 0)) or 0
end

function Ledger:RefreshResourceKind(ai, actor, kind, note)
    if actor == nil or actor.token == nil or actor.token.properties == nil then
        return 0
    end

    local resourceId = self:ResourceIdForKind(kind)
    if resourceId == nil then
        return 0
    end

    return ModifyTokenProperties(actor.token, note or "Critical hit", function()
        return actor.token.properties:RefreshResource(resourceId, self:ResourceRefreshTypeForKind(kind), 1, note or "Critical hit")
    end) or 0
end

function Ledger:RefreshMainActionResource(ai, actor, note)
    return self:RefreshResourceKind(ai, actor, "action", note)
end

function Ledger:QueuePendingActionGrant(ai, actor, kind, source, note)
    kind = NormalizeGrantKind(kind)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or kind == nil then
        return nil
    end

    local grants = EnsureActionGrants(turnMemory)
    turnMemory.actionGrantSequence = (tonumber(turnMemory.actionGrantSequence) or 0) + 1
    local grant = {
        id = turnMemory.actionGrantSequence,
        kind = kind,
        source = source or "action grant",
        note = note or source or "action grant",
        quantity = 1,
        remaining = 1,
        createdGeneration = tonumber(turnMemory.generation) or 0,
    }
    grants[#grants+1] = grant
    return grant
end

function Ledger:ReopenGrantedEconomy(ai, actor, kinds, note)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or not HasEntries(kinds) then
        return false
    end

    local wasClosed = turnMemory.turnEnded == true or turnMemory.mainOrManeuverUsed == true
    turnMemory.turnEnded = false
    turnMemory.nextSelectedAbilityHasPotency = nil
    if actor ~= nil and actor.kind == "squad" then
        turnMemory.mainOrManeuverUsed = false
    end

    RecomputeAfterDebit(turnMemory)
    if ai ~= nil and ai.Trace ~= nil then
        ai:Trace("resource", "action grant reopened economy", {
            actor = actor and ai._internal.TokenName(actor.token),
            action = kinds.action == true,
            maneuver = kinds.maneuver == true,
            note = note,
            wasClosed = wasClosed,
        })
    end
    return wasClosed
end

function Ledger:GrantActionEconomy(ai, actor, grant)
    grant = grant or {}
    local kind = NormalizeGrantKind(grant.kind)
    local quantity = math.max(1, tonumber(grant.quantity) or 1)
    local source = grant.source or grant.note or "action grant"
    local note = grant.note or source
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or kind == nil then
        if ai ~= nil and ai.Trace ~= nil then
            ai:Trace("resource", "action grant ignored", {
                actor = actor and ai._internal.TokenName(actor.token),
                kind = grant.kind,
                source = source,
                reason = "unsupported grant kind",
            })
        end
        return nil
    end

    self:Init(ai, actor)
    turnMemory.nextSelectedAbilityHasPotency = nil
    local result = {
        source = source,
        note = note,
        granted = {},
        refreshed = {},
        pending = {},
    }

    for _=1,quantity do
        local usedKey = GrantUsedKeys(kind)
        local previousUsed = tonumber(turnMemory[usedKey]) or 0
        local engineUsage = self:ResourceUsageForKind(ai, actor, kind)
        if previousUsed > 0 or engineUsage > 0 then
            local amount = self:RefundSpentResource(ai, actor, kind, note)
            if amount > 0 then
                result.granted[kind] = (result.granted[kind] or 0) + 1
                result.refreshed[kind] = (result.refreshed[kind] or 0) + 1
            else
                local queued = self:QueuePendingActionGrant(ai, actor, kind, source, note)
                if queued ~= nil then
                    result.granted[kind] = (result.granted[kind] or 0) + 1
                    result.pending[kind] = (result.pending[kind] or 0) + 1
                end
            end
        else
            local queued = self:QueuePendingActionGrant(ai, actor, kind, source, note)
            if queued ~= nil then
                result.granted[kind] = (result.granted[kind] or 0) + 1
                result.pending[kind] = (result.pending[kind] or 0) + 1
            end
        end
    end

    if HasEntries(result.pending) then
        local reopenedKinds = {}
        reopenedKinds[kind] = true
        self:ReopenGrantedEconomy(ai, actor, reopenedKinds, note)
    end

    if HasEntries(result.granted) then
        if ai ~= nil and ai.Trace ~= nil then
            ai:Trace("resource", "action grant received", {
                actor = actor and ai._internal.TokenName(actor.token),
                kind = kind,
                source = source,
                refreshed = result.refreshed[kind],
                pending = result.pending[kind],
            })
        end
        return result
    end

    if ai ~= nil and ai.Trace ~= nil then
        ai:Trace("resource", "action grant ignored", {
            actor = actor and ai._internal.TokenName(actor.token),
            kind = kind,
            source = source,
            reason = "no resource refreshed or queued",
        })
    end
    return nil
end

function Ledger:CriticalRefreshKinds(ai, candidate)
    local kinds = { action = false, maneuver = false }
    if candidate == nil then
        return kinds
    end

    local abilityInfo = candidate.abilityInfo
    local actionCost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost or self:AbilityActionCost(ai, abilityInfo)
    if actionCost == "action" then
        kinds.action = true
    end

    local explicitKinds = abilityInfo and abilityInfo.critRefreshKinds
    if type(explicitKinds) == "table" then
        kinds.action = kinds.action or explicitKinds.action == true
        kinds.maneuver = kinds.maneuver or explicitKinds.maneuver == true
    end

    return kinds
end

function Ledger:RefundSpentResource(ai, actor, kind, note)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return 0
    end

    local usedKey = Pick(kind == "maneuver", "maneuversUsed", "actionsUsed")
    local flagKey = Pick(kind == "maneuver", "maneuverUsed", "actionUsed")
    local previousUsed = tonumber(turnMemory[usedKey]) or 0
    if previousUsed <= 0 and self:ResourceUsageForKind(ai, actor, kind) <= 0 then
        return 0
    end

    turnMemory._allowResourceDecrease = turnMemory._allowResourceDecrease or {}
    turnMemory._allowResourceDecrease[usedKey] = true

    local refreshed = self:RefreshResourceKind(ai, actor, kind, note)
    local memoryRefund = 0
    if previousUsed > 0 then
        turnMemory[usedKey] = math.max(0, previousUsed - 1)
        memoryRefund = 1
    end

    RecomputeResourceFlags(turnMemory)
    IncrementGeneration(turnMemory)

    if (refreshed or 0) > 0 or memoryRefund > 0 then
        self:ReopenRefreshedEconomy(ai, actor, { [kind] = true }, note or "resource refresh")
        return 1
    end

    return 0
end

function Ledger:ReopenRefreshedEconomy(ai, actor, refreshedKinds, note)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil or not HasEntries(refreshedKinds) then
        return false
    end

    RecomputeResourceFlags(turnMemory)

    if ActorIsDazed(ai, actor) then
        return false
    end

    local actionAvailable = refreshedKinds.action == true and not turnMemory.actionUsed
    local maneuverAvailable = refreshedKinds.maneuver == true and not turnMemory.maneuverUsed
    if not actionAvailable and not maneuverAvailable then
        return false
    end

    local wasClosed = turnMemory.turnEnded == true or turnMemory.mainOrManeuverUsed == true
    turnMemory.turnEnded = false
    if actor ~= nil and actor.kind == "squad" then
        turnMemory.mainOrManeuverUsed = false
    end

    if wasClosed and ai ~= nil and ai.Log ~= nil then
        local labels = {}
        if actionAvailable then
            labels[#labels+1] = "main action"
        end
        if maneuverAvailable then
            labels[#labels+1] = "maneuver"
        end
        ai:Log(string.format(
            "Resource refresh reopened %s economy: %s%s.",
            tostring(actor and actor.kind or "actor"),
            table.concat(labels, " and "),
            Pick(note ~= nil, " (" .. tostring(note) .. ")", "")
        ))
    end

    return wasClosed
end

function Ledger:ApplyCriticalActionRefresh(ai, actor, candidate, symbols, finishOptions)
    if actor == nil or candidate == nil or candidate.abilityInfo == nil then
        return nil
    end

    local naturalRoll = self:CriticalNaturalRoll(ai, symbols, finishOptions)
    if naturalRoll == nil then
        ai:Trace("resource", "critical grant ignored", {
            candidate = candidate.description,
            reason = "missing natural roll",
        })
        return nil
    end

    local threshold = self:CriticalThreshold(ai, actor)
    if naturalRoll < threshold then
        ai:Trace("resource", "critical grant ignored", {
            candidate = candidate.description,
            naturalRoll = naturalRoll,
            threshold = threshold,
            reason = "below threshold",
        })
        return nil
    end

    local kinds = self:CriticalRefreshKinds(ai, candidate)
    local granted = {}
    local refreshed = {}
    local pending = {}
    if kinds.action then
        local grant = self:GrantActionEconomy(ai, actor, {
            kind = "action",
            quantity = 1,
            source = "Critical hit",
            note = "Critical hit",
        })
        if grant ~= nil then
            granted.action = grant.granted.action
            refreshed.action = grant.refreshed.action
            pending.action = grant.pending.action
        end
    end
    if kinds.maneuver then
        local grant = self:GrantActionEconomy(ai, actor, {
            kind = "maneuver",
            quantity = 1,
            source = "Critical hit",
            note = "Critical hit",
        })
        if grant ~= nil then
            granted.maneuver = grant.granted.maneuver
            refreshed.maneuver = grant.refreshed.maneuver
            pending.maneuver = grant.pending.maneuver
        end
    end

    if not HasEntries(granted) then
        ai:Trace("resource", "critical grant ignored", {
            candidate = candidate.description,
            naturalRoll = naturalRoll,
            threshold = threshold,
            action = kinds.action,
            maneuver = kinds.maneuver,
            reason = "no grant kinds",
        })
        return nil
    end

    local labels = {}
    if granted.action ~= nil then
        labels[#labels+1] = "main action"
    end
    if granted.maneuver ~= nil then
        labels[#labels+1] = "maneuver"
    end

    ai:Log(string.format("Critical hit granted %s (roll %s >= %s).", table.concat(labels, " and "), tostring(naturalRoll), tostring(threshold)))
    return {
        granted = granted,
        refreshed = refreshed,
        pending = pending,
        naturalRoll = naturalRoll,
        threshold = threshold,
    }
end

function Ledger:ActorSelectionThreshold(ai, actor, candidate)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if candidate ~= nil then
        local cost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost or self:AbilityActionCost(ai, candidate.abilityInfo)
        local movementOnly = candidate.movementOnly == true
        if ai.CandidateMovementOnly ~= nil then
            movementOnly = ai:CandidateMovementOnly(candidate)
        end
        if movementOnly or cost == "movement" or cost == "action" or cost == "maneuver" then
            return ConstNumber("Candidate", "ActorSelectionThreshold", 0.8)
        end
    end

    if turnMemory ~= nil and (turnMemory.actionUsed or turnMemory.maneuverUsed) then
        return ConstNumber("Candidate", "ActorSelectionAfterSpendThreshold", 4)
    end

    return ConstNumber("Candidate", "ActorSelectionThreshold", 0.8)
end

function Ledger:ActorEconomySummary(ai, actor)
    self:SyncTurnMemoryFromResources(ai, actor)

    local turnMemory = self:EnsureTurnMemory(ai, actor) or {}
    local threshold = self:ActorSelectionThreshold(ai, actor)
    return string.format(
        "kind=%s actions=%d/%d maneuvers=%d/1 moveActions=%d/%d movedTiles=%d movementActionUsed=%s mainOrManeuverUsed=%s turnEnded=%s generation=%d threshold=%0.1f",
        tostring(actor and actor.kind or "unknown"),
        tonumber(turnMemory.actionsUsed) or 0,
        tonumber(turnMemory.actionLimit) or 1,
        tonumber(turnMemory.maneuversUsed) or 0,
        tonumber(turnMemory.moveActionsUsed) or 0,
        tonumber(turnMemory.moveActionLimit) or 1,
        tonumber(turnMemory.movedTiles) or 0,
        tostring(turnMemory.movedOnly == true or turnMemory.movementUsed == true),
        tostring(turnMemory.mainOrManeuverUsed == true),
        tostring(turnMemory.turnEnded == true),
        tonumber(turnMemory.generation) or 0,
        tonumber(threshold) or 0
    )
end

function Ledger:HasUsefulMainActionAfterSoloAction(ai, context, actor)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return false
    end

    local threshold = self:ActorSelectionThreshold(ai, actor)
    local previousTempBonus = turnMemory._tmpBonusActions
    local previousActionUsed = turnMemory.actionUsed
    local previousActionLimit = turnMemory.actionLimit
    local previousNextPotency = turnMemory.nextSelectedAbilityHasPotency

    turnMemory._tmpBonusActions = (tonumber(previousTempBonus) or 0) + 1
    turnMemory.actionUsed = false
    turnMemory.nextSelectedAbilityHasPotency = nil

    local candidates = SafeCall(function()
        return ai:FindCandidates(context, actor, { silent = true, suppressSoloAction = true })
    end, {}) or {}

    turnMemory._tmpBonusActions = previousTempBonus
    turnMemory.actionUsed = previousActionUsed
    turnMemory.actionLimit = previousActionLimit
    turnMemory.nextSelectedAbilityHasPotency = previousNextPotency
    self:SyncTurnMemoryFromResources(ai, actor)

    for _,candidate in ipairs(candidates) do
        local cost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate.actionCost or self:AbilityActionCost(ai, candidate.abilityInfo)
        local movementOnly = candidate.movementOnly == true
        if ai.CandidateMovementOnly ~= nil then
            movementOnly = ai:CandidateMovementOnly(candidate)
        end
        local score = ai.CandidateScoreTotal and ai:CandidateScoreTotal(candidate) or candidate.score or 0
        if cost == "action" and not movementOnly and candidate.abilityInfo ~= nil and not ai:IsSoloActionName(candidate.abilityInfo.name) and score >= threshold then
            return true
        end
    end

    return false
end

function Ledger:SoloActionAvailable(ai, context, actor, abilityInfo, options)
    if options ~= nil and options.suppressSoloAction then
        return false
    end

    if actor == nil or abilityInfo == nil or not ai:IsSoloActionName(abilityInfo.name) or not ai:IsStartTurnMaliceAbility(abilityInfo) then
        return false
    end

    if not ai:RoleIs(actor, "solo") then
        return false
    end

    self:Init(ai, actor)
    if actor.turnMemory.turnEnded and not ActorIsDazed(ai, actor) then
        return false
    end

    if context ~= nil and context.malice ~= nil and context.malice < ai:MaliceCost(abilityInfo) then
        return false
    end

    return self:HasUsefulMainActionAfterSoloAction(ai, context, actor)
end

function Ledger:ApplySoloActionMainActionRefresh(ai, actor, context)
    return self:TransformSoloAction(ai, actor, context, nil)
end

function Ledger:TransformSoloAction(ai, actor, context, abilityInfo)
    local turnMemory = self:EnsureTurnMemory(ai, actor)
    if turnMemory == nil then
        return false
    end

    self:Init(ai, actor)
    ai:Trace("resource", "solo action transform", {
        actor = actor and ai._internal.TokenName(actor.token),
        pendingBefore = ActionGrantAvailableCount(turnMemory, "action"),
        malice = context and context.malice,
    })
    turnMemory.nextSelectedAbilityHasPotency = nil
    local grant = self:GrantActionEconomy(ai, actor, {
        kind = "action",
        quantity = 1,
        source = "Solo Action",
        note = "Solo Action",
    })
    if grant == nil then
        return false
    end

    ai:Log("Solo Action granted a main action.")
    ai:Trace("resource", "solo action applied", {
        actor = actor and ai._internal.TokenName(actor.token),
        refreshed = grant.refreshed.action,
        pending = grant.pending.action,
        actionLimit = turnMemory.actionLimit,
        generation = turnMemory.generation,
    })
    return true
end

function Ledger:ForecastMainActionMaliceReservation(ai, context, startCandidate)
    if ai == nil or context == nil or startCandidate == nil or startCandidate.abilityInfo == nil then
        return false, nil
    end

    local actor = startCandidate.actor
    if actor == nil or ai.FindCandidates == nil then
        return false, nil
    end

    local malice = tonumber(context.malice)
    if malice == nil then
        return false, nil
    end

    local startCost = tonumber(startCandidate.maliceCost) or ai:MaliceCost(startCandidate.abilityInfo)
    if startCost <= 0 or malice < startCost then
        return false, nil
    end

    local remaining = malice - startCost
    local candidates = ai:FindCandidates(context, actor, {
        flow = "analysisOnly",
        silent = true,
        _reservationForecast = true,
    }) or {}
    local minimumScore = ConstNumber("Candidate", "StartTurnMaliceReservationMinimumScore", 6)
    local best = nil
    local bestScore = -999
    for _,candidate in ipairs(candidates) do
        local info = candidate and candidate.abilityInfo
        local actionCost = ai.CandidateActionCost and ai:CandidateActionCost(candidate) or candidate and candidate.actionCost
        if info ~= nil and info.isMalice and actionCost == "action" then
            local cost = ai:MaliceCost(info)
            if cost <= malice and cost > remaining then
                local score = ai.CandidateScoreTotal and ai:CandidateScoreTotal(candidate, "analysisOnly") or candidate.score or 0
                if score >= minimumScore and score > bestScore then
                    best = candidate
                    bestScore = score
                end
            end
        end
    end

    if best == nil then
        return false, nil
    end

    return true, {
        candidate = best,
        score = bestScore,
        malice = malice,
        remaining = remaining,
        startCost = startCost,
        mainCost = ai:MaliceCost(best.abilityInfo),
    }
end

function Ledger:UseGroupStartTurnMalice(ai, context)
    if not ai.config.maliceAbilities or context == nil or ai:AutomationCanceled(context.runGeneration) or self:HasUsedStartTurnMalice(ai, context) then
        ai:Trace("malice", "start-turn skipped", {
            enabled = ai.config.maliceAbilities,
            hasContext = context ~= nil,
            canceled = context ~= nil and ai:AutomationCanceled(context.runGeneration),
            alreadyUsed = context ~= nil and self:HasUsedStartTurnMalice(ai, context),
        })
        return false
    end

    local result = ai.Pipeline:Run(context, nil, "startTurnMalice")
    local candidates = result.ranked or {}
    local candidate = result.selected
    ai:Trace("malice", "start-turn pipeline", {
        ranked = #candidates,
        selected = candidate and candidate.description,
        heldReason = result.heldReason,
        malice = context.malice,
    })

    if candidate ~= nil then
        local score = ai.CandidateScoreTotal and ai:CandidateScoreTotal(candidate, "startTurnMalice") or candidate.startTurnScore or candidate.score or 0
        local wouldPriceOut, reservation = self:ForecastMainActionMaliceReservation(ai, context, candidate)
        if wouldPriceOut then
            local reservedCandidate = reservation and reservation.candidate
            local reservedDescription = reservedCandidate and reservedCandidate.description or "main-action malice"
            ai:Trace("malice", "start-turn held for main action malice", {
                candidate = candidate.description,
                cost = reservation and reservation.startCost,
                remaining = reservation and reservation.remaining,
                reserved = reservedDescription,
                reservedCost = reservation and reservation.mainCost,
                reservedScore = reservation and reservation.score,
                malice = reservation and reservation.malice,
            })
            ai:Log(string.format(
                "Group start-turn malice held: %s would price out %s.",
                tostring(candidate.description or candidate.abilityInfo.name),
                tostring(reservedDescription)
            ))
            return false
        end
        ai:Log(string.format("Group start-turn malice: %s (%0.1f, cost %d)", candidate.description or candidate.abilityInfo.name, score, candidate.maliceCost or ai:MaliceCost(candidate.abilityInfo)))
        if ai:ExecuteCandidate(context, candidate) then
            self:MarkStartTurnMaliceUsed(ai, context)
            ai:Trace("malice", "start-turn marked used", { candidate = candidate.description })
            return true
        end
        if context.manualPromptHandoff then
            return true
        end
    end

    if #candidates > 0 then
        local score = ai.CandidateScoreTotal and ai:CandidateScoreTotal(candidates[1], "startTurnMalice") or candidates[1].startTurnScore or candidates[1].score or 0
        ai:Log(string.format("Group start-turn malice held below threshold: %s (%0.1f)", candidates[1].description or candidates[1].abilityInfo.name, score))
    end

    return false
end

function Ledger:RecordCandidateResourceUse(ai, context, candidate)
    if context == nil or candidate == nil then
        return
    end

    local state = context.encounterState or ai.encounterState
    if state == nil or candidate.abilityInfo == nil then
        return
    end

    if candidate.abilityInfo.isVillain then
        local villainRound = candidate.villainRound or context.round or 1
        state.usedVillainActions = state.usedVillainActions or {}
        state.usedVillainActions[villainRound] = true
        state.endRoundVillainActions = state.endRoundVillainActions or {}
        local endRoundVillain = candidate.endRoundVillain == true
        if ai.CandidateEndRoundVillain ~= nil then
            endRoundVillain = ai:CandidateEndRoundVillain(candidate)
        end
        if endRoundVillain then
            state.endRoundVillainActions[villainRound] = true
        end
    end

    if candidate.abilityInfo.isMalice and ai:IsMaliciousStrikeName(candidate.abilityInfo.name) then
        self:MarkMaliciousStrikeUsed(ai, context)
    end
end

function Ledger:GlobalResourceSnapshot(ai, candidate)
    local resource = RawGlobal("CharacterResource")
    if resource == nil or candidate == nil or candidate.abilityInfo == nil then
        return nil
    end

    return {
        malice = SafeCall(function()
            return resource.GetMalice()
        end, nil),
        villainActions = SafeCall(function()
            return resource.GetVillainActions()
        end, nil),
    }
end

function Ledger:RefreshContextResources(ai, context)
    local resource = RawGlobal("CharacterResource")
    if context == nil or resource == nil then
        return
    end

    local beforeMalice = context.malice
    local beforeVillainActions = context.villainActions
    context.malice = SafeCall(function()
        return resource.GetMalice()
    end, context.malice or 0)
    context.villainActions = SafeCall(function()
        return resource.GetVillainActions()
    end, context.villainActions or 0)
    ai:Trace("resource", "context refreshed", {
        beforeMalice = beforeMalice,
        malice = context.malice,
        beforeVillainActions = beforeVillainActions,
        villainActions = context.villainActions,
    })
end

function Ledger:ReconcileGlobalResourceSpend(ai, candidate, snapshot)
    local resource = RawGlobal("CharacterResource")
    if resource == nil or candidate == nil or candidate.abilityInfo == nil or snapshot == nil then
        return
    end

    local name = candidate.abilityInfo.name or "AI ability"
    if candidate.abilityInfo.isMalice and snapshot.malice ~= nil then
        local cost = ai:MaliceCost(candidate.abilityInfo)
        if cost > 0 then
            local current = SafeCall(function()
                return resource.GetMalice()
            end, nil)
            ai:Trace("resource", "malice reconcile", {
                candidate = candidate.description,
                snapshot = snapshot.malice,
                current = current,
                cost = cost,
                willSpend = current ~= nil and current >= snapshot.malice,
            })
            if current ~= nil and current >= snapshot.malice then
                SafeCall(function()
                    resource.SetMalice(math.max(0, current - cost), name)
                end, nil)
            end
        end
    end

    if candidate.abilityInfo.isVillain and snapshot.villainActions ~= nil and snapshot.villainActions > 0 then
        local current = SafeCall(function()
            return resource.GetVillainActions()
        end, nil)
        ai:Trace("resource", "villain reconcile", {
            candidate = candidate.description,
            snapshot = snapshot.villainActions,
            current = current,
            willSpend = current ~= nil and current >= snapshot.villainActions,
        })
        if current ~= nil and current >= snapshot.villainActions then
            SafeCall(function()
                resource.SetVillainActions(math.max(0, current - 1), name)
            end, nil)
        end
    end
end
