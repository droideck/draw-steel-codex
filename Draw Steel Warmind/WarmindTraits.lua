local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindTraits.lua
--
-- Pure ability classification. Given an ActivatedAbility, produce a small
-- flat table of traits the selector can reason about without re-reading the
-- ability object everywhere. This is what lets Warmind play monsters that
-- have no hand-written behavior: generic action specs key off traits.
--
-- Rules:
--   * Prefer structured fields (keywords, targetType, actionResourceId,
--     categorization, behaviors) over description-text parsing. Text parsing
--     was one of the complexity sinks that killed DirectorTactics. When the
--     data is not structured, a trait degrades to nil -- callers fail closed
--     or fall through; we NEVER guess from prose.
--   * This file must stay pure: no token reads, no engine mutation, no
--     movement, no casting. dmhub.GetTable data-table reads are sanctioned
--     (non-yielding plain reads) and are done at most once per Get call.
-- ============================================================================

Warmind.Traits = {}

-- Load-bearing constant carried over verbatim from the baseline Monster AI
-- (Monster AI/MonsterAI.lua line 169): the ongoing-effect guid that marks a
-- creature as having been aid-attacked. Shared with WarmindSnapshot.lua, which
-- scans enemies' ActiveOngoingEffects for it; both sites MUST use this exact id.
Warmind.Traits.AID_ATTACK_EFFECT_GUID = "e234f1f4-9953-43bd-894c-d96adbb63f84"

-- targetType values that describe an area or zone rather than a picked
-- creature target. "all" is the burst style targeting used by Draw Steel
-- burst abilities.
local g_aoeTargetTypes = {
    all = true,
    sphere = true,
    cylinder = true,
    line = true,
    cone = true,
    cube = true,
    areatemplate = true,
}

-- The behavior typeName that carries an invoked forced-movement relocation.
local g_relocateBehaviorType = "ActivatedAbilityRelocateCreatureBehavior"

-- targetTypes where a Relocate behavior moves the CASTER, not a target:
-- the engine's own idiom (ActivatedAbility:GetIcon, DMHub Game Rules/
-- ActivatedAbility.lua line 353) treats emptyspace/emptyspacefriend/anyspace
-- plus a Relocate behavior as a move/shift ability. "self" is the same by
-- definition. The standard Charge/Disengage/Move Speed abilities all match
-- this shape (verified live 2026-07-11); without this exclusion they would
-- all read as forcedMovementType = "unknown".
local g_selfSpaceTargetTypes = {
    self = true,
    emptyspace = true,
    emptyspacefriend = true,
    anyspace = true,
}

-- Maps an ability's action resource id to a Warmind action kind. Built
-- lazily because CharacterResource ids are assigned in Draw Steel Core Rules,
-- which loads before this module.
local g_actionKinds = nil
local function ActionKindForResource(resourceid)
    if g_actionKinds == nil then
        g_actionKinds = {
            [CharacterResource.actionResourceId] = "main",
            [CharacterResource.maneuverResourceId] = "maneuver",
            [CharacterResource.triggerResourceId] = "trigger",
            [CharacterResource.villainActionId] = "villain",
            [CharacterResource.freeManeuverResourceId] = "free_maneuver",
        }
    end
    if resourceid == nil then
        return "free"
    end
    return g_actionKinds[resourceid] or "other"
end

-- Structured-field forced-movement detection. We do NOT call
-- ability:ForcedMovementType()/IsForcedMovement(): the Draw Steel override of
-- IsForcedMovement (Draw Steel Core Rules/MCDMActivatedAbility.lua line 2561)
-- returns false unless the ability carries an "invoker" field, which top-level
-- abilities enumerated from GetActivatedAbilities never have, so the engine
-- ForcedMovementType (DMHub Game Rules/ActivatedAbility.lua line 1090) would
-- report nil for every ability we classify. Detect directly instead:
--   presence = the raw forcedMovement field is set, OR a Relocate behavior
--              exists AND the ability targets creatures (a Relocate on a
--              self-space targetType moves the caster -- Charge/Disengage/
--              Move Speed -- and is never forced movement)
--   type     = the raw forcedMovement field ("push"|"pull"|"slide"|"vertical_*")
--   presence with no typed field -> "unknown"; no presence -> nil
-- Known degrade (live-verified 2026-07-11): the standard Knockback maneuver
-- carries its push inside power-roll tier rules (no top-level structured
-- signal), so it reads nil here -- callers fail closed, per the plan.
local function ForcedMovementTypeOf(ability, behaviors)
    local rawType = ability:try_get("forcedMovement")
    local hasPresence = rawType ~= nil
    if not hasPresence and not g_selfSpaceTargetTypes[ability.targetType] then
        for _, behavior in ipairs(behaviors) do
            if behavior.typeName == g_relocateBehaviorType then
                hasPresence = true
                break
            end
        end
    end
    if not hasPresence then
        return nil
    end
    if rawType == nil then
        return "unknown"
    end
    return rawType
end

-- Single behaviors scan producing the condition set and the aid-attack flag.
-- Conditions come from behavior:ConditionID() -- the base
-- ActivatedAbilityBehavior:ConditionID returns nil (DMHub Game Rules/
-- ActivatedAbility.lua line 3788), so the call is safe on every behavior type;
-- the ApplyOngoingEffect override (line 4379) resolves its ongoingEffect through
-- characterOngoingEffects and returns a CONDITION id. We resolve that id to a
-- lowercased display name via the charConditions table -- the same name-space
-- creature:HasNamedCondition matches (Creature.lua line 10954) -- so
-- appliesGrabbed/isHide stay consistent with HasNamedCondition("Grabbed")/
-- ("Hidden"). The conditions table is fetched at most once, only when a
-- condition id is actually found. Aid attack is a direct ongoingEffect-guid
-- match (mirrors the baseline). Returns (conditionSet|nil, isAidAttack).
local function ScanBehaviorEffects(behaviors)
    local conditions = nil
    local isAidAttack = false
    local conditionsTable = nil
    for _, behavior in ipairs(behaviors) do
        if behavior:try_get("ongoingEffect") == Warmind.Traits.AID_ATTACK_EFFECT_GUID then
            isAidAttack = true
        end
        if type(behavior.ConditionID) == "function" then
            local conditionid = behavior:ConditionID()
            if conditionid ~= nil then
                if conditionsTable == nil then
                    conditionsTable = dmhub.GetTable("charConditions") or {}
                end
                local entry = conditionsTable[conditionid]
                if entry ~= nil and entry.name ~= nil then
                    conditions = conditions or {}
                    conditions[string.lower(entry.name)] = true
                end
            end
        end
    end
    return conditions, isAidAttack
end

-- Returns a trait table for the ability:
-- {
--   name          ability name
--   actionKind    "main"|"maneuver"|"trigger"|"villain"|"free_maneuver"|
--                 "free"|"other"
--   isSignature   true if this is the monster's Signature Ability
--   isStrike      has the Strike keyword
--   isMelee       has the Melee keyword
--   isRanged      has the Ranged keyword
--   isAreaKeyword has the Area keyword
--   isAoe         targetType describes an area/burst
--   targetType    raw targetType string
--   villainAction the ability's villainAction field, if any
--                 ("Villain Action 1" | "Villain Action 2" | ...)
--
--   forcedMovementType
--                 "push"|"pull"|"slide"|"vertical_push"|"vertical_pull"|
--                 "vertical_slide"|"unknown"|nil. Structured-field only:
--                 presence = the raw forcedMovement field, or a Relocate
--                 behavior on a creature-targeting ability (self-space
--                 targetTypes are caster movement, not forced movement);
--                 type = the raw forcedMovement field; presence with no
--                 typed field -> "unknown"; no forced movement -> nil.
--                 Effects living only in power-roll tier rules (e.g. the
--                 standard Knockback maneuver) are NOT detected -> nil.
--   inflictsConditions
--                 set: { [lowercased condition display name] = true }, or nil
--                 when the ability inflicts no structurally-detectable
--                 condition. Never an empty table.
--   appliesGrabbed
--                 true iff inflictsConditions["grabbed"] is set.
--   isHide        true iff inflictsConditions["hidden"] is set (no dedicated
--                 keyword exists; condition inflict is the reliable signal).
--   isAidAttack   true iff a behavior applies the aid-attack ongoing effect
--                 (Warmind.Traits.AID_ATTACK_EFFECT_GUID).
--   aoeRadius     number when isAoe, from ability:GetRadius(nil, {}) (nil-safe
--                 caster; interpretation is spec-side); nil when not an area.
--   numTargets    the RAW ability.numTargets field (a GoblinScript string,
--                 class default "1"). Plain dot read so the class default
--                 resolves; live per-token count is a spec concern.
--   costsMalice   true iff the ability's resourceCost is the malice resource
--                 (mirrors the engine MaliceCost field). Stage 2 specs skip
--                 malice-costing abilities; malice policy is Stage 4.
-- }
function Warmind.Traits.Get(ability)
    local targetType = ability.targetType
    -- The behaviors field can be absent; the engine defaults it the same way
    -- (DMHub Game Rules/ActivatedAbility.lua line 819).
    local behaviors = ability:try_get("behaviors", {})

    local inflictsConditions, isAidAttack = ScanBehaviorEffects(behaviors)
    local isAoe = g_aoeTargetTypes[targetType] == true

    local aoeRadius = nil
    if isAoe then
        aoeRadius = ability:GetRadius(nil, {})
    end

    return {
        name = ability.name,
        actionKind = ActionKindForResource(ability:ActionResource()),
        isSignature = ability:try_get("categorization") == "Signature Ability",
        isStrike = ability:HasKeyword("Strike"),
        isMelee = ability:HasKeyword("Melee"),
        isRanged = ability:HasKeyword("Ranged"),
        isAreaKeyword = ability:HasKeyword("Area"),
        isAoe = isAoe,
        targetType = targetType,
        villainAction = ability:try_get("villainAction"),
        forcedMovementType = ForcedMovementTypeOf(ability, behaviors),
        inflictsConditions = inflictsConditions,
        appliesGrabbed = inflictsConditions ~= nil and inflictsConditions["grabbed"] == true,
        isHide = inflictsConditions ~= nil and inflictsConditions["hidden"] == true,
        isAidAttack = isAidAttack,
        aoeRadius = aoeRadius,
        numTargets = ability.numTargets,
        costsMalice = ability.resourceCost == CharacterResource.maliceResourceId,
    }
end
