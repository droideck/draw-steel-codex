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
--     categorization) over description-text parsing. Text parsing was one of
--     the complexity sinks that killed DirectorTactics.
--   * This file must stay pure: no engine mutation, no movement, no casting.
-- ============================================================================

Warmind.Traits = {}

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
-- }
function Warmind.Traits.Get(ability)
    local targetType = ability.targetType

    return {
        name = ability.name,
        actionKind = ActionKindForResource(ability:ActionResource()),
        isSignature = ability:try_get("categorization") == "Signature Ability",
        isStrike = ability:HasKeyword("Strike"),
        isMelee = ability:HasKeyword("Melee"),
        isRanged = ability:HasKeyword("Ranged"),
        isAreaKeyword = ability:HasKeyword("Area"),
        isAoe = g_aoeTargetTypes[targetType] == true,
        targetType = targetType,
        villainAction = ability:try_get("villainAction"),
    }
end
