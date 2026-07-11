local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindScoring.lua
--
-- Position and target evaluation. These functions answer "from where, and at
-- whom?" for the action specs. They read the snapshot and may use engine
-- query APIs (theoretical positioning, movement arrows for charge paths,
-- line of sight) but never mutate real state: every MarkMovementArrow is
-- cleared before returning.
--
-- The algorithms are ported from the proven Monster AI baseline
-- (FindValidTargetsOfStrike / FindBestMoveToUseStrike / FindBestMoveToUseBurst)
-- with the tactic-bias hook generalized to the Warmind registry.
--
-- Role weight profiles (Stage 3) will plug into this file.
-- ============================================================================

Warmind.Scoring = {}
local Scoring = Warmind.Scoring

-- ----------------------------------------------------------------------------
-- Target evaluation.
-- ----------------------------------------------------------------------------

-- Finds the valid targets of a strike-style ability if the actor were
-- standing at loc. Returns a sorted array (best first) of:
--   { token = enemy, loc = enemyLoc, charge = Loc|nil, edges = number }
--
-- edges counts situational advantages: tactic biases add to it, obstructed
-- line of sight subtracts, being a pure-ranged attacker adjacent to an enemy
-- subtracts. Charge handling: melee free strikes and Charge-keyword
-- abilities may reach distant targets via a straight-line charge; the charge
-- destination is returned so execution can perform the move.
function Scoring.FindValidStrikeTargets(ctx, token, ability, loc, range)
    local snapshot = ctx.snapshot
    local meleeAbility = ability:HasKeyword("Melee")
    local rangedAbility = ability:HasKeyword("Ranged")

    -- Filter to enemies this ability could target at all. Hidden enemies
    -- cannot be targeted by strikes unless the monster has a sense that
    -- ignores hidden within a range.
    local filteredTokens = {}
    for i=1,#snapshot.enemies do
        local enemy = snapshot.enemies[i]
        local canTarget = ability:TargetPassesFilter(token, enemy, {})
        if canTarget and enemy.properties:HasNamedCondition("Hidden") and ability:HasKeyword("Strike") then
            local ignoreRange = token.properties:CalculateNamedCustomAttribute("Ignore Hidden Within Range") or 0
            if ignoreRange <= 0 or token:Distance(enemy) > ignoreRange then
                canTarget = false
            end
        end
        if canTarget then
            filteredTokens[#filteredTokens+1] = enemy
        end
    end

    local hasCharge = ability:HasKeyword("Charge") or ability.name == "Melee Free Strike"
    range = range or ability:GetRange(token.properties)

    local result = {}
    token:ExecuteWithTheoreticalLoc(loc, function()
        for i=1,#filteredTokens do
            local enemy = filteredTokens[i]
            local dist = token:Distance(enemy)

            local chargeLoc = nil
            if hasCharge then
                local movementInfo = token:MarkMovementArrow(enemy.loc, {straightline = true, ignorecreatures = false, moveThroughFriends = true})

                -- Reject charges that would make us fall more than one tile.
                if movementInfo ~= nil then
                    local path = movementInfo.path
                    local altitude = game.currentFloor:GetAltitudeAtLoc(path.origin)
                    for _,step in ipairs(path.steps) do
                        local fallDistance = altitude - game.currentFloor:GetAltitudeAtLoc(step)
                        if fallDistance > 1 then
                            movementInfo = nil
                            break
                        end
                    end
                end

                if movementInfo ~= nil then
                    local chargeDist = movementInfo.path.destination:DistanceInTiles(movementInfo.path.origin)
                    if chargeDist <= ability:try_get("chargeDistanceOverride", token.properties:CurrentMovementSpeed()) then
                        local dest = movementInfo.path.destination
                        dist = enemy:Distance(dest)
                        chargeLoc = dest
                    end
                end
            end

            if dist <= range then
                local los = token:GetLineOfSight(enemy, token.properties:GetPierceWalls())
                if los > 0 then
                    local edges = 0

                    -- Obstructed (but not blocked) line of sight.
                    if los < 1 then
                        edges = edges - 1
                    end

                    local tokenLoc = chargeLoc or loc

                    -- Tactic biases (flanking, high ground, ... Stage 2+).
                    for _,tactic in pairs(ctx.activeTactics or {}) do
                        local score = tactic.score(tactic, ctx, token, tokenLoc, enemy, ability) or 0
                        edges = edges + score
                    end

                    -- Pure-ranged attackers dislike firing while engaged.
                    if rangedAbility and not meleeAbility then
                        local hasNearbyEnemies = false
                        for _,enemyToken in ipairs(snapshot.enemies) do
                            if enemyToken:Distance(tokenLoc) <= 1 then
                                hasNearbyEnemies = true
                                break
                            end
                        end

                        if hasNearbyEnemies then
                            edges = edges - 1
                        end
                    end

                    result[#result+1] = { token = enemy, loc = enemy.loc, charge = chargeLoc, edges = edges }
                end
            end
        end
    end)

    if hasCharge then
        token:ClearMovementArrow()
    end

    table.sort(result, function(a,b) return a.edges > b.edges end)

    return result
end

-- ----------------------------------------------------------------------------
-- Position evaluation.
-- ----------------------------------------------------------------------------

-- Finds the best reachable tile from which to use a strike ability.
-- Returns loc, score (nil if no tile yields any target).
--
-- scorefn, if given, rates a candidate target: scorefn(targetToken) ->
-- number. The score is cached per token and reused across every candidate
-- tile, so scorers must depend only on the target itself, never on the
-- attacker's position (position quality is already handled by edges and
-- movement cost here). Without a scorefn, positions are rated by reachable
-- target count plus a small edge bonus. Movement cost breaks ties (closer
-- is better).
function Scoring.FindBestStrikePosition(ctx, token, ability, scorefn)
    if scorefn ~= nil then
        local scoreCache = {}
        local scoreInternal = scorefn
        scorefn = function(tok)
            local score = scoreCache[tok.charid]
            if score == nil then
                score = scoreInternal(tok)
                scoreCache[tok.charid] = score
            end
            return score
        end
    end

    local snapshot = ctx.snapshot
    local range = ability:GetRange(token.properties)
    local numTargets = ability:GetNumTargets(token)
    local bestScore = 0
    local bestMove = nil

    -- Consider staying put as well as every reachable tile. Pathfinding
    -- results may or may not include the current tile; evaluating it twice
    -- is harmless (same score, zero cost wins ties anyway).
    local candidates = { { loc = token.loc, cost = 0 } }
    for _,info in pairs(snapshot.paths) do
        candidates[#candidates+1] = info
    end

    for _,info in ipairs(candidates) do
        local destLoc = info.loc

        local targets = Scoring.FindValidStrikeTargets(ctx, token, ability, destLoc, range)

        local score = math.min(numTargets, #targets)
        if scorefn ~= nil then
            score = 0
            table.sort(targets, function(a,b)
                return scorefn(a.token, a.edges) > scorefn(b.token, b.edges)
            end)
            for i=1,math.min(numTargets, #targets) do
                score = score + scorefn(targets[i].token, targets[i].edges)
            end
        else
            local maxEdges = nil
            for _,target in ipairs(targets) do
                if maxEdges == nil or target.edges > maxEdges then
                    maxEdges = target.edges
                end
            end

            score = score + (maxEdges or 0)*0.1
        end

        score = score - info.cost*0.001

        if score > bestScore then
            bestScore = score
            bestMove = destLoc
        end
    end

    return bestMove, bestScore
end

-- Finds the best reachable tile from which to use a burst ("all" targetType)
-- ability. Returns loc, score.
--
-- scorefn rates each token that would be caught in the burst:
-- scorefn(targetToken) -> number (negative for allies you do not want hit).
-- Default counts every nearby token as 1, which is rarely what a real spec
-- wants; pass a scorefn.
function Scoring.FindBestBurstPosition(ctx, token, ability, scorefn)
    scorefn = scorefn or function() return 1 end
    local snapshot = ctx.snapshot
    local range = ability:GetRange(token.properties)
    local bestScore = nil
    local bestMove = nil
    local allTokens = dmhub.allTokens

    local candidates = { { loc = token.loc, cost = 0 } }
    for _,info in pairs(snapshot.paths) do
        candidates[#candidates+1] = info
    end

    for _,info in ipairs(candidates) do
        local score = 0
        local destLoc = info.loc
        for _,targetToken in ipairs(allTokens) do
            if targetToken ~= token and targetToken.valid and targetToken.properties ~= nil
                and (not targetToken.properties:IsDead())
                and targetToken:Distance(destLoc) <= range then
                score = score + scorefn(targetToken)
            end
        end

        if bestScore == nil or score > bestScore then
            bestScore = score
            bestMove = destLoc
        end
    end

    return bestMove, bestScore
end

-- Finds the lowest-cost reachable tile from which the actor would be
-- concealed. Returns loc or nil.
--
-- Faithful port of the baseline Monster AI FindReachableConcealment
-- (Monster AI/MonsterAI.lua ~788), used by the Stage 2 hide spec. Read-only:
-- ExecuteWithTheoreticalLoc is a query that restores the real loc, and
-- IsConcealed (Draw Steel Core Rules/MCDMCreature.lua ~3200) only reads
-- token.hasConcealment. The cost check runs BEFORE the theoretical-loc test
-- (baseline optimization -- strict less): only tiles cheaper than the best
-- concealed tile found so far are worth evaluating.
function Scoring.FindReachableConcealment(ctx, snapshot)
    local token = snapshot.token
    local bestLoc = nil
    local bestScore = nil
    for _,info in pairs(snapshot.paths) do
        local destLoc = info.loc

        if bestScore == nil or info.cost < bestScore then
            token:ExecuteWithTheoreticalLoc(destLoc, function()
                if token.properties:IsConcealed() then
                    bestLoc = info.loc
                    bestScore = info.cost
                end
            end)
        end
    end

    return bestLoc
end

-- ----------------------------------------------------------------------------
-- Simple distance helpers used by specs.
-- ----------------------------------------------------------------------------

function Scoring.FindClosestEnemy(ctx, token)
    local closestEnemy = nil
    local closestDistance = nil
    for _,enemy in ipairs(ctx.snapshot.enemies) do
        local dist = token:Distance(enemy)
        if closestDistance == nil or dist < closestDistance then
            closestDistance = dist
            closestEnemy = enemy
        end
    end
    return closestEnemy, closestDistance
end

function Scoring.DistanceFromNearestEnemy(ctx, token)
    local _, dist = Scoring.FindClosestEnemy(ctx, token)
    return dist or 999
end

-- ----------------------------------------------------------------------------
-- Baseline tactics.
--
-- Faithful ports of the three Monster AI baseline tactics
-- (Monster AI/MonsterAITactics.lua). Each is a passive edge bias consumed by
-- FindValidStrikeTargets above: Turn.PlayActivation copies every matching
-- tactic into ctx.activeTactics, and the tactic loop adds each tactic's score
-- to a candidate target's edge count. Signature (fixed by the registry):
--   score(tactic, ctx, token, tokenLoc, enemy, ability) -> number|nil
-- All generic (no monsters array); each contributes +1 edge when its condition
-- holds and nil otherwise.
-- ----------------------------------------------------------------------------

Warmind.RegisterTactic{
    id = "flanking",
    description = "Prefer positions that flank the target: an ally sits on the exact opposite side of the enemy from the attacker.",
    score = function(tactic, ctx, token, tokenLoc, enemy, ability)
        -- Allies come from the snapshot, not a live token scan. The snapshot
        -- already excludes the actor; the charid guard is kept faithful to the
        -- baseline and defensive.
        for _,ally in ipairs(ctx.snapshot.allies) do
            if ally.charid ~= token.charid and ally:Distance(enemy) <= 1 then
                if (enemy.loc.y - tokenLoc.y) == (ally.loc.y - enemy.loc.y) and (enemy.loc.x - tokenLoc.x) == (ally.loc.x - enemy.loc.x) then
                    return 1
                end
            end
        end
    end,
}

Warmind.RegisterTactic{
    id = "aid_attack",
    description = "Prefer attacking enemies an ally has aided attacks against (aid-attack ongoing effect).",
    score = function(tactic, ctx, token, tokenLoc, enemy, ability)
        -- Read the per-enemy flag precomputed once in Snapshot.Build; never
        -- rescan ActiveOngoingEffects here (this runs per candidate tile x per
        -- enemy, so a live scan would be quadratic).
        local map = ctx.snapshot.aidAttacked
        if map ~= nil and map[enemy.charid] == true then
            return 1
        end
    end,
}

Warmind.RegisterTactic{
    id = "high_ground",
    description = "Prefer attacking from higher ground: the candidate tile's altitude is above the target's.",
    score = function(tactic, ctx, token, tokenLoc, enemy, ability)
        -- Altitude is read at the CANDIDATE tile (tokenLoc), not token.loc.
        local ourAltitude = game.currentFloor:GetAltitudeAtLoc(tokenLoc)
        local targetAltitude = game.currentFloor:GetAltitudeAtLoc(enemy.loc)
        if ourAltitude > targetAltitude then
            return 1
        end
    end,
}
