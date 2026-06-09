local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindDirector.lua
--
-- The encounter-level layer: deliberately thin and intended to stay so.
--
-- Stage 4 gives this file its real responsibilities (each a small function,
-- not a framework):
--   * Activation chooser: pick WHICH monster entry activates next when it is
--     the Director's side of the round (captains before their squads,
--     endangered groups early, leaders timed for impact).
--   * Malice policy: decide whether a stat-block malice ability is worth its
--     cost right now (spend when its score clearly beats the best free
--     option and the pool keeps a floor).
--   * Villain action scheduler: leaders/solos fire villain actions 1 -> 2 ->
--     3, once each per encounter (VillainActionState in DSResources.lua
--     already tracks this), at most one per round across the encounter.
--
-- Stage 1 implements only the activation chooser, with the same heuristic
-- the old Monster AI used: act with the group closest to a player token.
-- ============================================================================

Warmind.Director = {}

-- Chooses which unmoved non-player initiative entry should activate next.
-- Returns an initiativeid or nil if no monster entry remains this round.
function Warmind.Director.ChooseActivation(queue)
    local entriesUnmoved = queue:EntriesUnmoved()

    local bestEntry = nil
    local bestScore = nil

    for initiativeid,_ in pairs(entriesUnmoved) do
        if not queue:IsEntryPlayer(initiativeid) then
            local distance = nil
            local tokens = GameHud.GetTokensForInitiativeId(GameHud.instance, GameHud.instance.initiativeInterface, initiativeid)
            for _,tok in ipairs(dmhub.allTokens) do
                if tok.playerControlled then
                    for _,monsterTok in ipairs(tokens) do
                        local d = tok:Distance(monsterTok)
                        if distance == nil or d < distance then
                            distance = d
                        end
                    end
                end
            end

            distance = distance or 0
            if bestScore == nil or distance < bestScore then
                bestScore = distance
                bestEntry = initiativeid
            end
        end
    end

    return bestEntry
end
