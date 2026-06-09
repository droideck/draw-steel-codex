local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindSquads.lua
--
-- Minion squad subsystem. Minions act as coordinated squads (shared stamina,
-- one squad roll for signature attacks, captain benefits), so they get a
-- dedicated module instead of falling through the generic turn planner.
--
-- STAGE 1: fail-closed stub. Squad turns are detected by the turn loop and
-- routed here; this stub holds them with UNSUPPORTED_SQUAD so the DM plays
-- minions manually. The old Monster AI module remains loaded and can still
-- run squads in the meantime.
--
-- STAGE 2 ports the proven baseline squad logic (ExecuteSquadStrike /
-- FindSquadMemberStrikeOptions in Monster AI/MonsterAI.lua) with two known
-- fixes:
--   * later squad members re-path after earlier members have moved;
--   * a squad with no usable Signature Ability falls back to a squad
--     maneuver or holds with a clear reason instead of silently stopping.
-- ============================================================================

Warmind.Squads = {}

-- Collects the squad for tokens[index] within an initiative entry's token
-- list. Returns squadMembers (array of { token }), captain (token or nil),
-- and alreadyProcessed (true when an earlier token in the list belongs to
-- the same squad, meaning this squad has already had its activation).
function Warmind.Squads.CollectSquad(tokens, index)
    local token = tokens[index]
    local squadid = token.properties:MinionSquad()
    local squadMembers = {}
    local captain = nil

    for j=1,index-1 do
        local otherToken = tokens[j]
        if otherToken.valid and otherToken.properties ~= nil
            and otherToken.properties.minion
            and otherToken.properties:MinionSquad() == squadid then
            return {}, nil, true
        end
    end

    for j=index,#tokens do
        local otherToken = tokens[j]
        if otherToken.valid and otherToken.properties ~= nil
            and otherToken.properties.minion
            and otherToken.properties:MinionSquad() == squadid then
            squadMembers[#squadMembers+1] = { token = otherToken }
        end
    end

    for j=1,#tokens do
        local otherToken = tokens[j]
        if otherToken.valid and otherToken.properties ~= nil
            and (not otherToken.properties.minion)
            and otherToken.properties:MinionSquad() == squadid then
            captain = otherToken
            break
        end
    end

    return squadMembers, captain, false
end

-- Plays a squad activation. Stage 1: holds, fail closed.
function Warmind.Squads.PlayActivation(squadMembers, captain)
    local count = #squadMembers
    local squadName = "minion squad"
    if count > 0 and squadMembers[1].token.valid then
        squadName = string.format("%s squad (%d minions)",
            squadMembers[1].token.properties:try_get("monster_type", "minion"), count)
    end

    local result = Warmind.ResultHeld(Warmind.reason.UNSUPPORTED_SQUAD,
        string.format("%s: squad turns arrive in Stage 2; play this squad manually (or via the old Monster AI panel).", squadName))
    Warmind.Trace("%s", Warmind.DescribeResult(result))
    return result
end
