local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindSnapshot.lua
--
-- Builds the read-only Snapshot that all scoring and selection works from.
-- A snapshot is rebuilt at the start of every decision iteration inside an
-- activation, because movement and casting change what is reachable and
-- affordable.
--
-- Snapshot shape:
-- {
--   token         the actor's CharacterToken
--   creature      token.properties
--   monsterType   string ("" if somehow absent)
--   minion        boolean
--   role          string|nil   (Draw Steel role, e.g. "Artillery")
--   organization  string|nil   (e.g. "Minion", "Platoon", "Solo")
--   abilities     array of { ability = ActivatedAbility, traits = table }
--   enemies       array of CharacterToken (hostile, alive, in initiative)
--   allies        array of CharacterToken (friendly, alive, in initiative)
--   aidAttacked   map of enemy charid -> true when that enemy currently
--                 carries the aid-attack ongoing effect
--   budget        { hasMainAction, hasManeuver, dazed }
--   malice        number (shared Director malice pool)
--   round         number|nil
--   moveRemaining number (tiles of movement left this turn)
--   paths         reachable tiles: map of { loc = Loc, cost = number }
-- }
--
-- This file reads engine state but never mutates it.
-- ============================================================================

Warmind.Snapshot = {}

-- The engine pays ability costs itself during a cast (see
-- ActivatedAbility:ConsumeResources), and ability:CanAfford() is the
-- authority on affordability. The budget here is the AI's *intent* layer:
-- it decides which spec categories are still worth considering this turn.
-- The "< 1" reading mirrors the engine's own check in
-- Draw Steel Core Rules/MCDMActivatedAbility.lua.
local function BuildBudget(creatureProps)
    local actionUsed = creatureProps:GetResourceUsage(CharacterResource.actionResourceId, "turn") or 0
    local maneuverUsed = creatureProps:GetResourceUsage(CharacterResource.maneuverResourceId, "turn") or 0

    local dazed = false
    if creatureProps:HasNamedCondition("Dazed") then
        dazed = true
    end

    return {
        hasMainAction = actionUsed < 1,
        hasManeuver = maneuverUsed < 1,
        dazed = dazed,
    }
end

function Warmind.Snapshot.Build(token)
    local queue = dmhub.initiativeQueue
    local c = token.properties

    local snapshot = {
        token = token,
        creature = c,
        monsterType = c:try_get("monster_type", ""),
        minion = c.minion == true,
        role = c:try_get("role"),
        organization = c:try_get("organization"),
        abilities = {},
        enemies = {},
        allies = {},
        aidAttacked = {},
        budget = BuildBudget(c),
        malice = 0,
        round = nil,
        moveRemaining = 0,
        paths = {},
    }

    -- Shared Director resources. Read defensively: these touch shared
    -- documents and should never be able to break a turn.
    local okMalice, malice = pcall(CharacterResource.GetMalice)
    if okMalice then
        snapshot.malice = malice or 0
    end

    if queue ~= nil then
        snapshot.round = queue:try_get("round")
    end

    -- Partition combatants. Mirrors the proven Monster AI baseline: only
    -- tokens that are part of the current initiative queue count, and
    -- anything not friendly is treated as an enemy.
    -- WarmindTraits loads before WarmindSnapshot in module load order, so this
    -- plain read is populated by Build time.
    local aidAttackGuid = Warmind.Traits.AID_ATTACK_EFFECT_GUID
    if queue ~= nil then
        for _,tok in ipairs(dmhub.allTokens) do
            if tok.valid and tok.properties ~= nil and tok.charid ~= token.charid then
                local tokInitiativeId = InitiativeQueue.GetInitiativeId(tok)
                if tokInitiativeId ~= nil and queue.entries[tokInitiativeId] ~= nil and (not tok.properties:IsDead()) then
                    if dmhub.TokensAreFriendly(token, tok) then
                        snapshot.allies[#snapshot.allies+1] = tok
                    else
                        snapshot.enemies[#snapshot.enemies+1] = tok
                        -- One scan per enemy per Build: flag enemies that carry
                        -- the aid-attack ongoing effect so specs and tactics
                        -- share this read instead of rescanning. The baseline
                        -- did this once per turn in PlayTurnCoroutine but stored
                        -- it by mutating enemy properties (_tmp_ai_aidAttack);
                        -- Warmind keeps the flag in the snapshot and never
                        -- mutates engine state here.
                        for _,effect in ipairs(tok.properties:ActiveOngoingEffects()) do
                            if effect.ongoingEffectid == aidAttackGuid then
                                snapshot.aidAttacked[tok.charid] = true
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Abilities with traits.
    local abilities = c:GetActivatedAbilities()
    for _,ability in ipairs(abilities) do
        snapshot.abilities[#snapshot.abilities+1] = {
            ability = ability,
            traits = Warmind.Traits.Get(ability),
        }
    end

    -- Movement and reachability.
    local speed = c:CurrentMovementSpeed() or 0
    local moved = c:DistanceMovedThisTurn() or 0
    snapshot.moveRemaining = math.max(0, speed - moved)
    snapshot.paths = token:CalculatePathfindingArea(snapshot.moveRemaining * 10, {}) or {}

    return snapshot
end

-- Finds an ability entry { ability, traits } by exact name, or nil.
function Warmind.Snapshot.FindAbility(snapshot, name)
    return Warmind.FindAbilityEntry(snapshot.abilities, name)
end
