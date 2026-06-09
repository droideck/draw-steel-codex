local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindSpecs.lua
--
-- Generic action specs: the library of things any monster can decide to do.
--
-- Stage 1 ships the free-strike pair, which proves the whole spine:
-- snapshot -> score -> move -> recheck -> cast -> wait -> result.
-- Stage 2 adds the full generic set (signature strike, charge, obvious areas,
-- grab, knockback, aid attack, hide, reposition) driven by ability traits.
--
-- Spec contract (see Warmind.RegisterSpec in WarmindCore.lua):
--   score(spec, ctx, snapshot, abilities) -> candidate | nil
--     A candidate is { score = number, loc = Loc|nil, ... } plus any data
--     execute wants back. Return nil when the spec cannot be used right now.
--   execute(spec, ctx, candidate, abilities) -> DecisionResult | nil
--     nil is treated as executed. Execution must recheck legality against
--     current state (RecheckStrikeTargets / fresh target search) because the
--     world can change between scoring and execution.
--
-- Scoring conventions (carried over from the proven baseline):
--   0.2        generic fallback (free strikes) - bespoke moves outrank these
--   0.5 - 0.8  situational maneuvers
--   1.0        standard signature action
--   1.5 - 2.5  high-impact or malice-charged abilities
-- ============================================================================

-- Shared score function: find the best position to strike from. baseScore is
-- the spec's fixed priority; position quality only breaks ties through loc
-- choice, not through the returned score (mirrors the baseline behavior).
local function StandardStrikeScore(baseScore)
    return function(spec, ctx, snapshot, abilities)
        local ability = abilities[1]
        local loc = Warmind.Scoring.FindBestStrikePosition(ctx, ctx.token, ability)
        if loc == nil then
            return nil
        end
        return { score = baseScore, loc = loc }
    end
end

-- Shared execute function: move to the chosen tile, re-find targets from the
-- actual position, and cast.
local function StandardStrikeExecute()
    return function(spec, ctx, candidate, abilities)
        local token = ctx.token
        local ability = abilities[1]

        if candidate.loc ~= nil then
            Warmind.Adapter.MoveTo(token, candidate.loc)
        end

        -- Re-derive targets from wherever we actually ended up; the scored
        -- position may not have been reached exactly.
        local targets = Warmind.Scoring.FindValidStrikeTargets(ctx, token, ability, token.loc)
        if #targets == 0 then
            return Warmind.ResultSkipped(Warmind.reason.NO_LEGAL_TARGET,
                string.format("%s: no valid target after moving", ability.name))
        end

        targets = Warmind.Adapter.RecheckStrikeTargets(token, ability, targets)
        if #targets == 0 then
            return Warmind.ResultSkipped(Warmind.reason.EXECUTION_RECHECK_FAILED,
                string.format("%s: targets failed the final legality recheck", ability.name))
        end

        return Warmind.Adapter.ExecuteAbilityAndWait(ctx, token, ability, targets)
    end
end

-- ----------------------------------------------------------------------------
-- Stage 1 specs: free strikes.
--
-- Every Draw Steel monster has free strikes, so these two specs alone give
-- any monster a baseline turn: close (charging if possible) and hit, or
-- shoot from range. They are deliberately low priority so that everything
-- added later outranks them.
-- ----------------------------------------------------------------------------

Warmind.RegisterSpec{
    id = "melee_free_strike",
    name = "Charge and Free Strike",
    category = "main",
    description = "Move to melee range, charging if possible, and use a melee free strike. Generic fallback when no better option exists.",
    abilities = {"Melee Free Strike"},
    score = StandardStrikeScore(0.2),
    execute = StandardStrikeExecute(),
}

Warmind.RegisterSpec{
    id = "ranged_free_strike",
    name = "Ranged Free Strike",
    category = "main",
    description = "Move into line of sight and use a ranged free strike. Generic fallback when no better option exists.",
    abilities = {"Ranged Free Strike"},
    score = StandardStrikeScore(0.2),
    execute = StandardStrikeExecute(),
}
