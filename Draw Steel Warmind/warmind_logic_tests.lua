-- warmind_logic_tests.lua -- dev-only headless logic harness (L1 gate).
--
-- WHAT THIS IS:
--   A command-line test harness that loads the real Warmind module files under
--   stock Lua (brew lua 5.5) behind a minimal DMHub engine stub, then runs pure
--   decision-logic smoke tests (Traits, Core reason codes / DecisionResults,
--   Scoring, Turn budget-selection, Squads assembly). This is the L1 gate in the
--   Warmind verification model (see ROADMAP.md "Verification model").
--
-- DEV-ONLY, NEVER SHIPPED:
--   This file is NEVER registered in DMHub, NEVER added to main.lua, and NEVER
--   required by any module file. It exists only on disk for developers/agents to
--   run. It loads the 12 Warmind files by absolute path with loadfile (it never
--   copies or edits them, and never mutates a module file to become testable).
--   New Lua files remain forbidden for MODULE code; this harness is the single
--   sanctioned dev-only exception, created 2026-07-11 with user approval.
--
-- HOW TO RUN:
--   From the repo root:      lua "Draw Steel Warmind/warmind_logic_tests.lua"
--   From this file's dir:    lua warmind_logic_tests.lua
--   Exit code 0 = all tests green, 1 = any file failed to load or a test failed.
--
-- EXTENDING (stage sessions):
--   Implementation sessions that add pure decision logic append fixtures to the
--   flat TESTS table below (one entry per case: { name = "...", fn = function()
--   ... return ok_boolean, detail_string end }). Keep it ASCII, keep it pure
--   (no engine-bound / yielding code -- that lives behind the live app, L3/L4).
--
-- ASCII ONLY (DMHub runtime constraint mirrored here for consistency):
--   verify with LC_ALL=C grep -nP '[^\x00-\x7F]' and syntax-check with luac -p.

-- ---------------------------------------------------------------------------
-- Self-location: resolve REPO root and the Warmind dir from arg[0], so the
-- harness runs from the repo root or from its own directory without edits.
-- ---------------------------------------------------------------------------
local function dirOf(path)
    return path:match("^(.*)[/\\][^/\\]+$")
end

local scriptPath = (arg and arg[0]) or "warmind_logic_tests.lua"
local WARMIND = dirOf(scriptPath) or "."          -- the "Draw Steel Warmind" dir
-- Repo root = parent of WARMIND. When WARMIND has no slash (script launched by
-- bare name, or from the repo root as "Draw Steel Warmind/..."), dirOf is nil,
-- so append "/.." to step up one level rather than defaulting to WARMIND.
local REPO = dirOf(WARMIND) or (WARMIND .. "/..")

-- ---------------------------------------------------------------------------
-- DMHub engine stubs: the minimum surface to load and exercise Warmind under
-- stock Lua. Everything here stands in for the closed-source DMHub Unity
-- runtime; each stub records that it was hit (S.hits) for observability.
-- ---------------------------------------------------------------------------
local S = { hits = {} }
local function mark(name) S.hits[name] = (S.hits[name] or 0) + 1 end
_G.STUBS = S

-- print capture (WarmindCore.Trace prints "Warmind:: ..."). Still echoes to the
-- console so the run is visible, but also records lines for debugging.
S.printed = {}
local _print = print
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    S.printed[#S.printed + 1] = table.concat(parts, "\t")
    _print(...)
end

-- dmhub global -------------------------------------------------------------
local _t0 = os.clock()
dmhub = {
    canSafelyYield = true,
    allTokens = {},          -- fake tokens injected by tests
    initiativeQueue = nil,   -- nil == out of combat
}
function dmhub.GetModLoading() mark("dmhub.GetModLoading"); return { unloaded = false } end
function dmhub.Time() mark("dmhub.Time"); return os.clock() - _t0 end
function dmhub.Debug(msg) mark("dmhub.Debug") end
function dmhub.Log(msg) mark("dmhub.Log") end
function dmhub.Schedule(delay, fn) mark("dmhub.Schedule") end
function dmhub.Coroutine(fn) mark("dmhub.Coroutine") end -- NOT synchronous in engine; harness never load-calls it
function dmhub.GetTokenById(id) mark("dmhub.GetTokenById"); return nil end
function dmhub.TokensAreFriendly(a, b) mark("dmhub.TokensAreFriendly"); return false end
function dmhub.MarkLineOfSight(a, b, pierce) mark("dmhub.MarkLineOfSight"); return { Destroy = function() end } end
function dmhub.CenterOnToken(id, opts) mark("dmhub.CenterOnToken") end
function dmhub.SyncCamera(opts) mark("dmhub.SyncCamera") end
function dmhub.TableToString(t) return "<table>" end

-- Data-table reads (Traits resolves condition ids via "charConditions"; the
-- ApplyOngoingEffect ConditionID hop uses "characterOngoingEffects", modeled
-- inside FakeBehavior so the table here stays empty). Same name-space as
-- creature:HasNamedCondition (matches by lowercased condition.name).
S.tables = {
    charConditions = {
        ["cond-grabbed"] = { name = "Grabbed" },
        ["cond-hidden"]  = { name = "Hidden" },
        ["cond-dazed"]   = { name = "Dazed" },
    },
    characterOngoingEffects = {},
}
function dmhub.GetTable(name) mark("dmhub.GetTable"); return S.tables[name] end

-- settings: setting{} registers a default AND returns a settings object with
-- :Get()/:Set() (GoblinScript.lua relies on the return value; WarmindCore only
-- reads back through dmhub.GetSettingValue).
S.settings = {}
function setting(info)
    mark("setting")
    local id = info and info.id
    if id then S.settings[id] = info.default end
    return {
        id = id,
        Get = function(self) return S.settings[id] end,
        Set = function(self, v) S.settings[id] = v; if info and info.onchange then info.onchange() end end,
    }
end
function dmhub.GetSettingValue(id) mark("dmhub.GetSettingValue"); return S.settings[id] end

-- Profiling markers (Utils.lua wraps DeepCopy etc). Begin/End are no-ops.
function dmhub.ProfileMarker(name)
    mark("dmhub.ProfileMarker")
    return setmetatable({}, { __index = function() return function() end end })
end

-- RegisterGameType: faithful-minimal port of Definitions/lua-core.lua. Provides
-- new / has_key / try_get / get_or_add / IsDerivedFrom + inheritance. Warmind
-- itself never calls this, but Utils / any DS type might.
local g_types = {}
function IsDerivedFrom(a, b)
    if a == nil then return false end
    if a == b then return true end
    local info = g_types[a]
    return IsDerivedFrom(info and info.base, b)
end
function RegisterGameType(typeName, baseTypeName)
    mark("RegisterGameType")
    if baseTypeName and baseTypeName ~= typeName and g_types[baseTypeName] == nil then
        RegisterGameType(baseTypeName)
    end
    local existing = _G[typeName]
    local newType = existing or {}
    newType.typeName = typeName
    newType.new = function(o) o = o or {}; setmetatable(o, newType.mt); return o end
    newType.has_key = function(self, key) return rawget(self, key) ~= nil end
    newType.try_get = function(self, key, dflt) local r = rawget(self, key); if r == nil then return dflt end; return r end
    newType.get_or_add = function(self, key, dflt) local r = rawget(self, key); if r == nil then self[key] = dflt; return dflt end; return r end
    newType.IsDerivedFrom = function(t) return IsDerivedFrom(typeName, t) end
    newType.mt = {
        __index = function(t, k)
            local v = rawget(newType, k)
            if v ~= nil then return v end
            if baseTypeName then return _G[baseTypeName][k] end
            return nil
        end,
    }
    if baseTypeName then
        setmetatable(newType, { __index = function(_, k) return _G[baseTypeName][k] end })
    end
    g_types[typeName] = { base = baseTypeName }
    _G[typeName] = newType
    return newType
end

-- Draw Steel resource ids + malice (from DSResources.lua). Plain table; the ids
-- just need to be distinct and stable so Traits/Snapshot can map them.
CharacterResource = {
    triggerResourceId      = "res-trigger",
    actionResourceId       = "res-action",
    maneuverResourceId     = "res-maneuver",
    villainActionId        = "res-villain",
    freeManeuverResourceId = "res-freemaneuver",
    maliceResourceId       = "res-malice",
}
S.malice = 0
function CharacterResource.GetMalice() mark("CharacterResource.GetMalice"); return S.malice end
function CharacterResource.SetMalice(a, m) S.malice = a end

-- Initiative / hud seams (only reached from Snapshot/Director/Turn at runtime).
InitiativeQueue = {}
function InitiativeQueue.GetInitiativeId(tok) mark("InitiativeQueue.GetInitiativeId"); return tok and tok._initiativeId end
function InitiativeQueue.GetTokensForInitiativeId(id) mark("InitiativeQueue.GetTokensForInitiativeId"); return S.initiativeTokens or {} end

GameHud = { instance = { initiativeInterface = {} } }
function GameHud.GetTokensForInitiativeId(inst, iface, id) mark("GameHud.GetTokensForInitiativeId"); return S.initiativeTokens or {} end
function GameHud.instance.NextInitiative(self, cb) mark("GameHud.NextInitiative"); if cb then cb() end end

-- Ability casting seam + importer/utils (Adapter runtime only).
ActivatedAbilityInvokeAbilityBehavior = {}
function ActivatedAbilityInvokeAbilityBehavior.ExecuteInvoke(...) mark("ExecuteInvoke") end
MCDMImporter = {}
function MCDMImporter.GetStandardAbility(name) mark("MCDMImporter.GetStandardAbility"); return { name = name } end
MCDMUtils = {}
function MCDMUtils.DeepReplace(obj, a, b) mark("MCDMUtils.DeepReplace") end

-- UI seams: no-op factories returning inert tables.
local function panelTable() return setmetatable({}, { __index = function() return function() end end }) end
DockablePanel = {}
function DockablePanel.Register(args) mark("DockablePanel.Register"); S.registeredPanel = args end
gui = {}
function gui.Panel(a) mark("gui.Panel"); return panelTable() end
function gui.Label(a) mark("gui.Label"); return panelTable() end
function gui.Button(a) mark("gui.Button"); return panelTable() end

-- game global (Scoring reads game.currentFloor for charge altitude checks).
game = { currentFloor = {} }
function game.currentFloor.GetAltitudeAtLoc(self, loc) mark("game.currentFloor.GetAltitudeAtLoc"); return 0 end

-- Commands global needed by Utils.lua at load time.
Commands = Commands or {}

-- ---------------------------------------------------------------------------
-- File loading: Utils first (Warmind uses table.resize_array), then the 12
-- Warmind files in load order, each by absolute path with loadfile.
-- ---------------------------------------------------------------------------
local results = { files = {}, tests = {} }

local function loadOne(label, path)
    local chunk, lerr = loadfile(path)
    if not chunk then
        results.files[#results.files + 1] = { file = label, loaded = false, notes = "loadfile/parse error: " .. tostring(lerr) }
        return false
    end
    local ok, rerr = pcall(chunk)
    if not ok then
        results.files[#results.files + 1] = { file = label, loaded = false, notes = "runtime error at load: " .. tostring(rerr) }
        return false
    end
    results.files[#results.files + 1] = { file = label, loaded = true, notes = "ok" }
    return true
end

loadOne("DMHub Utils/Utils.lua", REPO .. "/DMHub Utils/Utils.lua")
local order = {
    "WarmindCore", "WarmindTraits", "WarmindSnapshot", "WarmindAdapter",
    "WarmindScoring", "WarmindSpecs", "WarmindPrompts", "WarmindSquads",
    "WarmindTurn", "WarmindDirector", "WarmindOverrides", "WarmindPanel",
}
for _, name in ipairs(order) do
    loadOne(name, WARMIND .. "/" .. name .. ".lua")
end

-- ---------------------------------------------------------------------------
-- Test fakes: minimal stand-ins for the engine object surfaces Warmind reads.
-- ---------------------------------------------------------------------------

-- FakeAbility mimics the ActivatedAbility surface Warmind reads.
local function FakeAbility(t)
    local kw = {}
    for _, k in ipairs(t.keywords or {}) do kw[k] = true end
    return {
        name = t.name,
        targetType = t.targetType or "target",
        numTargets = t.numTargets or "1",            -- RAW field (engine class default "1")
        resourceCost = t.resourceCost or "none",     -- RAW field (engine class default "none")
        _actionResource = t.actionResource,          -- resource id or nil
        _categorization = t.categorization,          -- "Signature Ability" | nil
        _villainAction = t.villainAction,            -- "Villain Action 1" | nil
        _forcedMovement = t.forcedMovement,          -- "push"|"pull"|"slide"|... | nil
        _behaviors = t.behaviors,                    -- array of FakeBehavior | nil
        _range = t.range or 1,
        _radius = t.radius,                          -- drives GetRadius | nil
        _numTargets = t.numTargets or 1,
        ActionResource = function(self) return self._actionResource end,
        HasKeyword = function(self, k) return kw[k] == true end,
        try_get = function(self, k, dflt)
            if k == "categorization" then local v = self._categorization; if v == nil then return dflt end; return v end
            if k == "villainAction" then local v = self._villainAction; if v == nil then return dflt end; return v end
            if k == "forcedMovement" then local v = self._forcedMovement; if v == nil then return dflt end; return v end
            if k == "behaviors" then local v = self._behaviors; if v == nil then return dflt end; return v end
            if k == "chargeDistanceOverride" then return dflt end
            return dflt
        end,
        GetRange = function(self) return self._range end,
        GetRadius = function(self, caster, symbols) return self._radius end,
        GetNumTargets = function(self) return self._numTargets end,
        CanAfford = function(self, token) return true end,
        TargetPassesFilter = function(self, caster, tok, symbols) return true end,
    }
end

-- FakeBehavior mimics an ActivatedAbilityBehavior entry in ability.behaviors.
-- typeName drives forced-movement presence; ConditionID returns a configurable
-- condition id (base engine returns nil); try_get serves the ongoingEffect field
-- (aid-attack detection compares it against the aid-attack guid).
local function FakeBehavior(t)
    t = t or {}
    return {
        typeName = t.typeName,
        _ongoingEffect = t.ongoingEffect,            -- ongoing-effect guid | nil
        _conditionId = t.conditionId,                -- condition id | nil
        ConditionID = function(self) return self._conditionId end,
        try_get = function(self, k, dflt)
            if k == "ongoingEffect" then local v = self._ongoingEffect; if v == nil then return dflt end; return v end
            return dflt
        end,
    }
end

-- FakeCreature: token.properties surface.
local function FakeCreature(t)
    t = t or {}
    return {
        minion = t.minion or false,
        _conditions = t.conditions or {},
        _customAttrs = t.customAttrs or {},
        _resourceUsage = t.resourceUsage or {},
        _abilities = t.abilities or {},
        monster_type = t.monster_type,
        try_get = function(self, k, dflt) local v = rawget(self, k); if v == nil then return dflt end; return v end,
        has_key = function(self, k) return rawget(self, k) ~= nil end,
        HasNamedCondition = function(self, name) return self._conditions[name] == true end,
        CalculateNamedCustomAttribute = function(self, name) return self._customAttrs[name] or 0 end,
        GetResourceUsage = function(self, id, refresh) return self._resourceUsage[id] or 0 end,
        GetActivatedAbilities = function(self) return self._abilities end,
        GetPierceWalls = function(self) return false end,
        CurrentMovementSpeed = function(self) return t.speed or 5 end,
        DistanceMovedThisTurn = function(self) return 0 end,
        IsDead = function(self) return t.dead == true end,
        MinionSquad = function(self) return t.squad or "Squad 1" end,
        ActiveOngoingEffects = function(self) return t.ongoingEffects or {} end,
    }
end

-- Chebyshev distance for grid locs.
local function cheb(a, b) return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y)) end

-- FakeToken: token surface used by Scoring/Snapshot.
local function FakeToken(t)
    local tok
    tok = {
        valid = true,
        charid = t.charid,
        loc = t.loc,
        playerControlled = t.playerControlled or false,
        properties = t.properties,
        _initiativeId = t.initiativeId,
        Distance = function(self, other)
            local ol = other.loc or other  -- accept token or loc
            return cheb(self.loc, ol)
        end,
        ExecuteWithTheoreticalLoc = function(self, loc, fn) local save = self.loc; self.loc = loc; fn(); self.loc = save end,
        GetLineOfSight = function(self, target, pierce) return 1 end,
        CalculatePathfindingArea = function(self, decis, flags) return {} end,
        MarkMovementArrow = function(self, loc, opts) return nil end,
        ClearMovementArrow = function(self) end,
    }
    return tok
end

-- ---------------------------------------------------------------------------
-- TESTS: flat table so stage sessions append fixtures easily. Each fn returns
-- (ok_boolean, detail_string). A returned false or a thrown error fails it.
-- ---------------------------------------------------------------------------
local TESTS = {}

-- (a) Traits.Get: melee signature strike vs ranged AoE.
TESTS[#TESTS + 1] = { name = "traits_melee_signature_strike", fn = function()
    if Warmind == nil or Warmind.Traits == nil then return false, "Warmind.Traits missing" end
    local ab = FakeAbility{ name = "Claw", keywords = { "Strike", "Melee" },
        categorization = "Signature Ability", actionResource = CharacterResource.actionResourceId, targetType = "target" }
    local tr = Warmind.Traits.Get(ab)
    local ok = tr.isStrike and tr.isMelee and (not tr.isRanged) and tr.isSignature
        and tr.actionKind == "main" and (not tr.isAoe)
    return ok, string.format("actionKind=%s isStrike=%s isMelee=%s isSignature=%s isAoe=%s",
        tostring(tr.actionKind), tostring(tr.isStrike), tostring(tr.isMelee), tostring(tr.isSignature), tostring(tr.isAoe))
end }

TESTS[#TESTS + 1] = { name = "traits_ranged_aoe", fn = function()
    local ab = FakeAbility{ name = "Fireball", keywords = { "Ranged", "Area" },
        actionResource = CharacterResource.actionResourceId, targetType = "sphere" }
    local tr = Warmind.Traits.Get(ab)
    local ok = tr.isRanged and (not tr.isMelee) and tr.isAreaKeyword and tr.isAoe and (not tr.isSignature)
    return ok, string.format("isRanged=%s isAreaKeyword=%s isAoe=%s targetType=%s",
        tostring(tr.isRanged), tostring(tr.isAreaKeyword), tostring(tr.isAoe), tostring(tr.targetType))
end }

TESTS[#TESTS + 1] = { name = "traits_villain_action", fn = function()
    local ab = FakeAbility{ name = "Doom", keywords = {}, villainAction = "Villain Action 2",
        actionResource = CharacterResource.villainActionId }
    local tr = Warmind.Traits.Get(ab)
    return (tr.villainAction == "Villain Action 2" and tr.actionKind == "villain"),
        string.format("villainAction=%s actionKind=%s", tostring(tr.villainAction), tostring(tr.actionKind))
end }

-- (a2) Stage 2 trait expansion: forced movement, conditions, aid attack,
-- aoe radius, malice cost, raw numTargets.

TESTS[#TESTS + 1] = { name = "traits_forced_movement_typed", fn = function()
    local ab = FakeAbility{ name = "Shove", keywords = { "Strike", "Melee" }, forcedMovement = "push" }
    local tr = Warmind.Traits.Get(ab)
    return tr.forcedMovementType == "push", string.format("forcedMovementType=%s", tostring(tr.forcedMovementType))
end }

TESTS[#TESTS + 1] = { name = "traits_forced_movement_unknown", fn = function()
    -- Relocate behavior present but no typed forcedMovement field -> "unknown".
    local ab = FakeAbility{ name = "Yank", keywords = { "Strike" },
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityRelocateCreatureBehavior" } } }
    local tr = Warmind.Traits.Get(ab)
    return tr.forcedMovementType == "unknown", string.format("forcedMovementType=%s", tostring(tr.forcedMovementType))
end }

TESTS[#TESTS + 1] = { name = "traits_forced_movement_absent", fn = function()
    local ab = FakeAbility{ name = "Poke", keywords = { "Strike", "Melee" } }
    local tr = Warmind.Traits.Get(ab)
    return tr.forcedMovementType == nil, string.format("forcedMovementType=%s", tostring(tr.forcedMovementType))
end }

TESTS[#TESTS + 1] = { name = "traits_forced_movement_self_move_excluded", fn = function()
    -- A Relocate behavior on a self-space targetType moves the CASTER
    -- (Charge/Disengage/Move Speed shape, live-verified): NOT forced movement.
    local ab = FakeAbility{ name = "Charge", keywords = {}, targetType = "emptyspace",
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityRelocateCreatureBehavior" } } }
    local tr = Warmind.Traits.Get(ab)
    -- But an authored forcedMovement field still wins even on a self-space type.
    local ab2 = FakeAbility{ name = "Repulse", keywords = {}, targetType = "emptyspace",
        forcedMovement = "push",
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityRelocateCreatureBehavior" } } }
    local tr2 = Warmind.Traits.Get(ab2)
    local ok = tr.forcedMovementType == nil and tr2.forcedMovementType == "push"
    return ok, string.format("selfMove=%s fieldWins=%s",
        tostring(tr.forcedMovementType), tostring(tr2.forcedMovementType))
end }

TESTS[#TESTS + 1] = { name = "traits_inflicts_grabbed", fn = function()
    local ab = FakeAbility{ name = "Snare", keywords = { "Strike", "Melee" },
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityApplyOngoingEffectBehavior", conditionId = "cond-grabbed" } } }
    local tr = Warmind.Traits.Get(ab)
    local ok = tr.inflictsConditions ~= nil and tr.inflictsConditions["grabbed"] == true
        and tr.appliesGrabbed == true and tr.isHide == false
    return ok, string.format("grabbed=%s appliesGrabbed=%s isHide=%s",
        tostring(tr.inflictsConditions and tr.inflictsConditions["grabbed"]), tostring(tr.appliesGrabbed), tostring(tr.isHide))
end }

TESTS[#TESTS + 1] = { name = "traits_is_hide", fn = function()
    local ab = FakeAbility{ name = "Vanish", keywords = {},
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityApplyOngoingEffectBehavior", conditionId = "cond-hidden" } } }
    local tr = Warmind.Traits.Get(ab)
    local ok = tr.isHide == true and tr.appliesGrabbed == false
        and tr.inflictsConditions ~= nil and tr.inflictsConditions["hidden"] == true
    return ok, string.format("isHide=%s hidden=%s appliesGrabbed=%s",
        tostring(tr.isHide), tostring(tr.inflictsConditions and tr.inflictsConditions["hidden"]), tostring(tr.appliesGrabbed))
end }

TESTS[#TESTS + 1] = { name = "traits_is_aid_attack", fn = function()
    local ab = FakeAbility{ name = "Mark Prey", keywords = {},
        behaviors = { FakeBehavior{ typeName = "ActivatedAbilityApplyOngoingEffectBehavior",
            ongoingEffect = Warmind.Traits.AID_ATTACK_EFFECT_GUID } } }
    local tr = Warmind.Traits.Get(ab)
    -- The aid-attack behavior carries no condition id -> no conditions detected.
    return (tr.isAidAttack == true and tr.inflictsConditions == nil),
        string.format("isAidAttack=%s inflictsConditions=%s", tostring(tr.isAidAttack), tostring(tr.inflictsConditions))
end }

TESTS[#TESTS + 1] = { name = "traits_aoe_radius", fn = function()
    local ab = FakeAbility{ name = "Blast", keywords = { "Area" }, targetType = "all", radius = 3 }
    local tr = Warmind.Traits.Get(ab)
    return (tr.isAoe == true and tr.aoeRadius == 3),
        string.format("isAoe=%s aoeRadius=%s", tostring(tr.isAoe), tostring(tr.aoeRadius))
end }

TESTS[#TESTS + 1] = { name = "traits_aoe_radius_nil_non_aoe", fn = function()
    -- radius present but not an area -> aoeRadius nil (gated on isAoe, not the field).
    local ab = FakeAbility{ name = "Jab", keywords = { "Strike", "Melee" }, targetType = "target", radius = 3 }
    local tr = Warmind.Traits.Get(ab)
    return (tr.isAoe == false and tr.aoeRadius == nil),
        string.format("isAoe=%s aoeRadius=%s", tostring(tr.isAoe), tostring(tr.aoeRadius))
end }

TESTS[#TESTS + 1] = { name = "traits_costs_malice", fn = function()
    local paid = FakeAbility{ name = "Doom Bolt", keywords = { "Ranged" }, resourceCost = CharacterResource.maliceResourceId }
    local free = FakeAbility{ name = "Plain Shot", keywords = { "Ranged" } }
    local trPaid = Warmind.Traits.Get(paid)
    local trFree = Warmind.Traits.Get(free)
    return (trPaid.costsMalice == true and trFree.costsMalice == false),
        string.format("paid=%s free=%s", tostring(trPaid.costsMalice), tostring(trFree.costsMalice))
end }

TESTS[#TESTS + 1] = { name = "traits_raw_num_targets", fn = function()
    local two = FakeAbility{ name = "Twin Strike", keywords = { "Strike", "Melee" }, numTargets = "2" }
    local dflt = FakeAbility{ name = "Single", keywords = { "Strike", "Melee" } }
    local trTwo = Warmind.Traits.Get(two)
    local trDflt = Warmind.Traits.Get(dflt)
    return (trTwo.numTargets == "2" and trDflt.numTargets == "1"),
        string.format("two=%s default=%s", tostring(trTwo.numTargets), tostring(trDflt.numTargets))
end }

-- (b) DecisionResult constructors + reason codes.
TESTS[#TESTS + 1] = { name = "decision_results", fn = function()
    local ex = Warmind.ResultExecuted{ spec = "x" }
    local held = Warmind.ResultHeld(Warmind.reason.NO_LEGAL_TARGET, "no target")
    local man = Warmind.ResultManual(Warmind.reason.TAKEN_OVER_BY_DM, "dm")
    local desc = Warmind.DescribeResult(held)
    local ok = ex.status == "executed" and held.status == "held"
        and held.reasonCode == "NO_LEGAL_TARGET" and man.status == "manual"
        and desc:find("NO_LEGAL_TARGET") ~= nil
    return ok, string.format("desc=%q reason=%s", desc, held.reasonCode)
end }

-- (b2) Spec registry populated by WarmindSpecs at load.
TESTS[#TESTS + 1] = { name = "specs_registered", fn = function()
    local hasMelee = Warmind.specs and Warmind.specs["melee_free_strike"] ~= nil
    local hasRanged = Warmind.specs and Warmind.specs["ranged_free_strike"] ~= nil
    return (hasMelee and hasRanged), string.format("specList=%d melee=%s ranged=%s",
        #(Warmind.specList or {}), tostring(hasMelee), tostring(hasRanged))
end }

-- (c) Scoring.FindValidStrikeTargets with a minimal fake snapshot/token.
TESTS[#TESTS + 1] = { name = "scoring_find_valid_strike_targets", fn = function()
    if Warmind.Scoring == nil then return false, "Warmind.Scoring missing" end
    local attackerProps = FakeCreature{ monster_type = "Goblin" }
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = attackerProps }
    local enemyProps = FakeCreature{}
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = enemyProps, playerControlled = true }
    local ctx = { snapshot = { enemies = { enemy } }, activeTactics = {}, token = attacker }
    -- Melee signature strike (not "Melee Free Strike", no Charge) -> no charge path.
    local ability = FakeAbility{ name = "Claw", keywords = { "Strike", "Melee" }, range = 1 }
    local targets = Warmind.Scoring.FindValidStrikeTargets(ctx, attacker, ability, attacker.loc, 1)
    local ok = #targets == 1 and targets[1].token == enemy
    return ok, string.format("num_targets=%d edges=%s", #targets, tostring(targets[1] and targets[1].edges))
end }

-- (c2) Ranged-while-engaged edge penalty is observable.
TESTS[#TESTS + 1] = { name = "scoring_ranged_engaged_penalty", fn = function()
    local attackerProps = FakeCreature{ monster_type = "Archer" }
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = attackerProps }
    local e1props = FakeCreature{}
    local e1 = FakeToken{ charid = "E1", loc = { x = 1, y = 0 }, properties = e1props } -- adjacent
    local ctx = { snapshot = { enemies = { e1 } }, activeTactics = {}, token = attacker }
    local ability = FakeAbility{ name = "Shot", keywords = { "Strike", "Ranged" }, range = 5 }
    local targets = Warmind.Scoring.FindValidStrikeTargets(ctx, attacker, ability, attacker.loc, 5)
    local ok = #targets == 1 and targets[1].edges == -1  -- adjacent enemy => ranged penalty
    return ok, string.format("num_targets=%d edges=%s (expect -1)", #targets, tostring(targets[1] and targets[1].edges))
end }

-- (c3) FindBestStrikePosition entry point (uses empty pathfinding => stay put).
TESTS[#TESTS + 1] = { name = "scoring_find_best_strike_position", fn = function()
    local attackerProps = FakeCreature{ monster_type = "Goblin" }
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = attackerProps }
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = FakeCreature{} }
    local ctx = { snapshot = { enemies = { enemy }, paths = {} }, activeTactics = {}, token = attacker }
    local ability = FakeAbility{ name = "Claw", keywords = { "Strike", "Melee" }, range = 1, numTargets = 1 }
    local loc, score = Warmind.Scoring.FindBestStrikePosition(ctx, attacker, ability)
    return (loc ~= nil and score ~= nil and score > 0), string.format("loc=%s score=%s", tostring(loc ~= nil), tostring(score))
end }

-- (e) Turn.CategoryAllowed budget gating incl. the Draw Steel dazed rule.
TESTS[#TESTS + 1] = { name = "turn_budget_gating", fn = function()
    if Warmind.Turn == nil then return false, "Warmind.Turn missing" end
    local ctx = { usedCategories = {} }
    local snapFull = { budget = { hasMainAction = true, hasManeuver = true, dazed = false } }
    local mainOk = Warmind.Turn.CategoryAllowed(ctx, snapFull, "main")
    -- after using main, main is blocked but maneuver still open
    ctx.usedCategories.main = true
    local mainBlocked = not Warmind.Turn.CategoryAllowed(ctx, snapFull, "main")
    local manStillOk = Warmind.Turn.CategoryAllowed(ctx, snapFull, "maneuver")
    -- dazed: once one category used, everything else blocked
    local ctx2 = { usedCategories = { main = true } }
    local snapDazed = { budget = { hasMainAction = true, hasManeuver = true, dazed = true } }
    local dazedBlocksManeuver = not Warmind.Turn.CategoryAllowed(ctx2, snapDazed, "maneuver")
    local ok = mainOk and mainBlocked and manStillOk and dazedBlocksManeuver
    return ok, string.format("main=%s mainBlocked=%s maneuverOpen=%s dazedBlocks=%s",
        tostring(mainOk), tostring(mainBlocked), tostring(manStillOk), tostring(dazedBlocksManeuver))
end }

-- (e2) Turn.ChooseCandidate selects the melee free-strike spec end to end
-- (spec matching -> CanAfford -> score -> best pick), pure selector logic.
TESTS[#TESTS + 1] = { name = "turn_choose_candidate", fn = function()
    local attackerProps = FakeCreature{ monster_type = "Goblin" }
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = attackerProps }
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = FakeCreature{} }
    local mfs = FakeAbility{ name = "Melee Free Strike", keywords = { "Strike", "Melee" }, range = 1, numTargets = 1 }
    local snapshot = {
        enemies = { enemy }, allies = {}, paths = {},
        budget = { hasMainAction = true, hasManeuver = true, dazed = false },
        abilities = { { ability = mfs, traits = Warmind.Traits.Get(mfs) } },
    }
    local ctx = { token = attacker, usedCategories = {}, skipSpecs = {}, activeTactics = {}, snapshot = snapshot }
    local choice = Warmind.Turn.ChooseCandidate(ctx, snapshot)
    local ok = choice ~= nil and choice.spec.id == "melee_free_strike" and choice.candidate.score == 0.2
    return ok, string.format("picked=%s score=%s",
        choice and choice.spec.id or "nil", choice and tostring(choice.candidate.score) or "nil")
end }

-- (e3) Squads fail-closed: CollectSquad groups minions, PlayActivation holds
-- with UNSUPPORTED_SQUAD (Stage 1 contract).
TESTS[#TESTS + 1] = { name = "squads_fail_closed", fn = function()
    if Warmind.Squads == nil then return false, "Warmind.Squads missing" end
    local m1 = FakeToken{ charid = "M1", loc = { x = 0, y = 0 }, properties = FakeCreature{ minion = true, monster_type = "Goblin", squad = "Sq1" } }
    local m2 = FakeToken{ charid = "M2", loc = { x = 1, y = 0 }, properties = FakeCreature{ minion = true, monster_type = "Goblin", squad = "Sq1" } }
    local members, captain, already = Warmind.Squads.CollectSquad({ m1, m2 }, 1)
    if #members ~= 2 or already ~= false then
        return false, string.format("CollectSquad members=%d already=%s", #members, tostring(already))
    end
    -- second index should report alreadyProcessed (earlier member is same squad)
    local _, _, already2 = Warmind.Squads.CollectSquad({ m1, m2 }, 2)
    local res = Warmind.Squads.PlayActivation(members, captain)
    local ok = already2 == true and res.status == "held" and res.reasonCode == "UNSUPPORTED_SQUAD"
    return ok, string.format("members=%d already2=%s hold=%s/%s", #members, tostring(already2), res.status, res.reasonCode)
end }

-- (d) GoblinScript standalone headless viability.
-- The .lua file is only a THIN WRAPPER: ExecuteGoblinScript delegates the real
-- compile/eval to engine-native dmhub.CompileGoblinScriptDeterministic /
-- dmhub.EvalGoblinScriptDeterministic (C#/Unity). So the wrapper loads, but the
-- compiler is NOT headless -- pass means "wrapper loads AND is native-bound".
TESTS[#TESTS + 1] = { name = "goblinscript_wrapper_loads_but_native", fn = function()
    local nativeCalled = { compile = false, eval = false }
    function dmhub.CompileGoblinScriptDeterministic(f, out) nativeCalled.compile = true; return function() return 0 end end
    function dmhub.EvalGoblinScriptDeterministic(f, s, d, c) nativeCalled.eval = true; return d end
    function dmhub.EvalGoblinScript(f, s, d, c) return d end
    local path = REPO .. "/DMHub Utils/GoblinScript.lua"
    local chunk, lerr = loadfile(path)
    if not chunk then return false, "parse error: " .. tostring(lerr) end
    local ok, rerr = pcall(chunk)
    if not ok then return false, "load runtime error: " .. tostring(rerr) end
    local hasExec = type(_G.ExecuteGoblinScript) == "function"
    -- Exercise the wrapper; it must reach into a native dmhub.* compiler/eval.
    if hasExec then pcall(ExecuteGoblinScript, "1 + 1", {}, 0, "test") end
    local nativeBound = nativeCalled.compile or nativeCalled.eval
    return (hasExec and nativeBound),
        string.format("ExecuteGoblinScript=%s native_compile/eval_reached=%s (compiler is engine-native, NOT pure Lua)",
            tostring(hasExec), tostring(nativeBound))
end }

-- (f) Scoring.FindReachableConcealment: lowest-cost concealed tile wins; nil
-- when no reachable tile conceals. IsConcealed is overridden on the fake
-- creature to key off the token's current loc (ExecuteWithTheoreticalLoc in
-- FakeToken swaps tok.loc), so the token local is forward-declared.
TESTS[#TESTS + 1] = { name = "scoring_reachable_concealment", fn = function()
    if Warmind.Scoring == nil or Warmind.Scoring.FindReachableConcealment == nil then
        return false, "FindReachableConcealment missing"
    end
    local tok
    -- Concealment only at (2,0) and (3,0); (2,0) is the cheaper of the two.
    local concealedLocs = { ["2,0"] = true, ["3,0"] = true }
    local props = FakeCreature{ monster_type = "Skulker" }
    props.IsConcealed = function(self)
        local l = tok.loc
        return concealedLocs[l.x .. "," .. l.y] == true
    end
    tok = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = props }
    local snapshot = {
        token = tok,
        paths = {
            p1 = { loc = { x = 1, y = 0 }, cost = 1 },  -- reachable, not concealed
            p2 = { loc = { x = 3, y = 0 }, cost = 5 },  -- concealed, costlier
            p3 = { loc = { x = 2, y = 0 }, cost = 2 },  -- concealed, cheapest concealed
        },
    }
    local best = Warmind.Scoring.FindReachableConcealment({ snapshot = snapshot }, snapshot)
    local okConcealed = best ~= nil and best.x == 2 and best.y == 0
    -- The theoretical-loc queries must restore the real loc.
    local okRestored = tok.loc.x == 0 and tok.loc.y == 0
    -- No concealing tile anywhere -> nil.
    concealedLocs = {}
    local none = Warmind.Scoring.FindReachableConcealment({ snapshot = snapshot }, snapshot)
    local ok = okConcealed and okRestored and none == nil
    return ok, string.format("best=%s restored=%s none=%s",
        best and (best.x .. "," .. best.y) or "nil", tostring(okRestored), tostring(none))
end }

-- (f2) flanking tactic scored directly: exact-opposite geometry -> 1;
-- non-collinear control -> falsy.
TESTS[#TESTS + 1] = { name = "tactic_flanking_direct", fn = function()
    local flanking = Warmind.tactics and Warmind.tactics["flanking"]
    if flanking == nil then return false, "flanking tactic not registered" end
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = FakeCreature{} }
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = FakeCreature{} }
    local allyOpp = FakeToken{ charid = "AL", loc = { x = 2, y = 0 }, properties = FakeCreature{} }
    local allyOff = FakeToken{ charid = "AL", loc = { x = 2, y = 1 }, properties = FakeCreature{} }
    local hit = flanking.score(flanking, { snapshot = { allies = { allyOpp } } }, attacker, attacker.loc, enemy, nil)
    local miss = flanking.score(flanking, { snapshot = { allies = { allyOff } } }, attacker, attacker.loc, enemy, nil)
    local ok = hit == 1 and (not miss)
    return ok, string.format("hit=%s miss=%s", tostring(hit), tostring(miss))
end }

-- (f3) aid_attack tactic scored directly: 1 when the enemy charid carries the
-- flag; falsy when the map is empty AND when it is nil.
TESTS[#TESTS + 1] = { name = "tactic_aid_attack_direct", fn = function()
    local aid = Warmind.tactics and Warmind.tactics["aid_attack"]
    if aid == nil then return false, "aid_attack tactic not registered" end
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = FakeCreature{} }
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = FakeCreature{} }
    local hit = aid.score(aid, { snapshot = { aidAttacked = { E = true } } }, attacker, attacker.loc, enemy, nil)
    local empty = aid.score(aid, { snapshot = { aidAttacked = {} } }, attacker, attacker.loc, enemy, nil)
    local nilmap = aid.score(aid, { snapshot = {} }, attacker, attacker.loc, enemy, nil)
    local ok = hit == 1 and (not empty) and (not nilmap)
    return ok, string.format("hit=%s empty=%s nil=%s", tostring(hit), tostring(empty), tostring(nilmap))
end }

-- (f4) high_ground tactic scored directly, with GetAltitudeAtLoc temporarily
-- overridden (restored after the test whatever the outcome): candidate above
-- target -> 1, equal -> falsy.
TESTS[#TESTS + 1] = { name = "tactic_high_ground_direct", fn = function()
    local hg = Warmind.tactics and Warmind.tactics["high_ground"]
    if hg == nil then return false, "high_ground tactic not registered" end
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = FakeCreature{} }
    local savedAlt = game.currentFloor.GetAltitudeAtLoc
    game.currentFloor.GetAltitudeAtLoc = function(self, loc) return loc.alt or 0 end
    local highTile = { x = 0, y = 0, alt = 5 }
    local lowEnemy = FakeToken{ charid = "E", loc = { x = 1, y = 0, alt = 0 }, properties = FakeCreature{} }
    local levelEnemy = FakeToken{ charid = "E2", loc = { x = 1, y = 0, alt = 5 }, properties = FakeCreature{} }
    -- pcall so the global stub is restored even if score throws (a throw would
    -- otherwise leak the override into later tests via the runner's pcall).
    local okCall, higher, equal = pcall(function()
        local h = hg.score(hg, { snapshot = {} }, attacker, highTile, lowEnemy, nil)
        local e = hg.score(hg, { snapshot = {} }, attacker, highTile, levelEnemy, nil)
        return h, e
    end)
    game.currentFloor.GetAltitudeAtLoc = savedAlt  -- restore whatever the outcome
    if not okCall then return false, "score error: " .. tostring(higher) end
    local ok = higher == 1 and (not equal)
    return ok, string.format("higher=%s equal=%s", tostring(higher), tostring(equal))
end }

-- (f5) Tactic edge integration through FindValidStrikeTargets: a flanking ally
-- adds +1 to the target's edge count; removing the ally drops it back to 0.
TESTS[#TESTS + 1] = { name = "tactic_edges_integration", fn = function()
    local flanking = Warmind.tactics and Warmind.tactics["flanking"]
    if flanking == nil then return false, "flanking tactic not registered" end
    local attacker = FakeToken{ charid = "A", loc = { x = 0, y = 0 }, properties = FakeCreature{ monster_type = "Goblin" } }
    local enemy = FakeToken{ charid = "E", loc = { x = 1, y = 0 }, properties = FakeCreature{} }
    local ally = FakeToken{ charid = "AL", loc = { x = 2, y = 0 }, properties = FakeCreature{} }
    local ability = FakeAbility{ name = "Claw", keywords = { "Strike", "Melee" }, range = 1 }
    local ctxHit = {
        snapshot = { enemies = { enemy }, allies = { ally } },
        activeTactics = { flanking = flanking },
    }
    local hit = Warmind.Scoring.FindValidStrikeTargets(ctxHit, attacker, ability, attacker.loc, 1)
    local ctxMiss = {
        snapshot = { enemies = { enemy }, allies = {} },
        activeTactics = { flanking = flanking },
    }
    local miss = Warmind.Scoring.FindValidStrikeTargets(ctxMiss, attacker, ability, attacker.loc, 1)
    local ok = #hit == 1 and hit[1].edges == 1 and #miss == 1 and miss[1].edges == 0
    return ok, string.format("hitEdges=%s missEdges=%s (expect 1 / 0)",
        hit[1] and tostring(hit[1].edges) or "nil", miss[1] and tostring(miss[1].edges) or "nil")
end }

-- (f6) The three baseline tactics are registered in the tactics registry.
TESTS[#TESTS + 1] = { name = "baseline_tactics_registered", fn = function()
    local t = Warmind.tactics or {}
    local ok = t["flanking"] ~= nil and t["aid_attack"] ~= nil and t["high_ground"] ~= nil
    return ok, string.format("flanking=%s aid_attack=%s high_ground=%s",
        tostring(t["flanking"] ~= nil), tostring(t["aid_attack"] ~= nil), tostring(t["high_ground"] ~= nil))
end }

-- (g) Snapshot.Build tags enemies carrying the aid-attack ongoing effect,
-- and only those enemies (Workstream C: one scan per enemy per Build).
TESTS[#TESTS + 1] = { name = "snapshot_aid_attacked", fn = function()
    if Warmind.Snapshot == nil then return false, "Warmind.Snapshot missing" end
    local guid = Warmind.Traits.AID_ATTACK_EFFECT_GUID
    if guid == nil then return false, "AID_ATTACK_EFFECT_GUID missing" end
    local actor = FakeToken{ charid = "A", loc = { x = 0, y = 0 },
        properties = FakeCreature{ monster_type = "Goblin" } }
    local aided = FakeToken{ charid = "E_AID", loc = { x = 1, y = 0 }, initiativeId = "iaid",
        playerControlled = true,
        properties = FakeCreature{ ongoingEffects = { { ongoingEffectid = guid } } } }
    local plain = FakeToken{ charid = "E_PLAIN", loc = { x = 2, y = 0 }, initiativeId = "iplain",
        playerControlled = true,
        properties = FakeCreature{ ongoingEffects = { { ongoingEffectid = "some-other-guid" } } } }

    local saveTokens, saveQueue = dmhub.allTokens, dmhub.initiativeQueue
    dmhub.allTokens = { aided, plain }
    dmhub.initiativeQueue = {
        entries = { iaid = true, iplain = true },
        try_get = function(self, k, dflt) return dflt end,
    }
    local okBuild, snapOrErr = pcall(Warmind.Snapshot.Build, actor)
    dmhub.allTokens, dmhub.initiativeQueue = saveTokens, saveQueue
    if not okBuild then return false, "Build error: " .. tostring(snapOrErr) end
    local snap = snapOrErr

    local aidedFlag = snap.aidAttacked["E_AID"]
    local plainFlag = snap.aidAttacked["E_PLAIN"]
    local count = 0
    for _ in pairs(snap.aidAttacked) do count = count + 1 end
    local ok = aidedFlag == true and plainFlag == nil and count == 1 and #snap.enemies == 2
    return ok, string.format("aided=%s plain=%s count=%d enemies=%d",
        tostring(aidedFlag), tostring(plainFlag), count, #snap.enemies)
end }

-- ---------------------------------------------------------------------------
-- Runner + report.
-- ---------------------------------------------------------------------------
for _, t in ipairs(TESTS) do
    local ok, a, b = pcall(t.fn)
    local passed, detail
    if not ok then
        passed, detail = false, "error: " .. tostring(a)
    else
        passed, detail = (a == true), (b or "")
    end
    results.tests[#results.tests + 1] = { name = t.name, passed = passed, detail = detail }
end

print("\n================ FILE LOAD RESULTS ================")
local filesLoaded, filesTotal = 0, 0
for _, f in ipairs(results.files) do
    filesTotal = filesTotal + 1
    if f.loaded then filesLoaded = filesLoaded + 1 end
    print(string.format("[%s] %-32s %s", f.loaded and "LOAD" or "FAIL", f.file, f.notes))
end

print("\n================ SMOKE TESTS ================")
local pass, total = 0, 0
for _, t in ipairs(results.tests) do
    total = total + 1
    if t.passed then pass = pass + 1 end
    print(string.format("[%s] %-38s %s", t.passed and "PASS" or "FAIL", t.name, t.detail))
end

print("\n================ STUB HIT COUNTS ================")
local keys = {}
for k in pairs(S.hits) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do print(string.format("  %-38s %d", k, S.hits[k])) end

print(string.format("\n%d/%d files loaded, %d/%d smoke tests passed", filesLoaded, filesTotal, pass, total))

local green = (filesLoaded == filesTotal) and (pass == total)
os.exit(green and 0 or 1)
