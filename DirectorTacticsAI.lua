local mod = dmhub.GetModLoading()

-- DirectorTacticsAI bootstraps the shared DirectorTacticsAI table, internal
-- helpers, runtime state, registries, logging, and cancellation checks.
-- Load this file first. The DirectorTactics user-mod load order is:
-- DirectorTacticsAI, DirectorTacticsConstants, DirectorTacticsOrchestrator,
-- DirectorTacticsEncounter, DirectorTacticsGoals, DirectorTacticsAbilities,
-- DirectorTacticsResourceLedger, DirectorTacticsScoring,
-- DirectorTacticsCandidates, DirectorTacticsPipeline,
-- DirectorTacticsPromptResolution, DirectorTacticsExecution,
-- DirectorTacticsAutomation, DirectorTacticsPolicies, DirectorTacticsPanel.

local function RawGlobal(name)
    return rawget(_G, name)
end

local function EnsureTable(value)
    if type(value) == "table" then
        return value
    end

    return {}
end

local function ApplyDefaults(target, defaults)
    target = EnsureTable(target)
    for key,value in pairs(defaults or {}) do
        if target[key] == nil then
            target[key] = value
        end
    end
    return target
end

local AI = RawGlobal("DirectorTacticsAI") or {}
rawset(_G, "DirectorTacticsAI", AI)

AI.version = "0.4.3"
AI.roleProfiles = EnsureTable(AI.roleProfiles)
AI.abilityRules = EnsureTable(AI.abilityRules)
AI.tacticRules = EnsureTable(AI.tacticRules)
AI.promptPolicies = EnsureTable(AI.promptPolicies)
AI.triggerPolicies = EnsureTable(AI.triggerPolicies)
AI.monsterOverrides = EnsureTable(AI.monsterOverrides)
AI.objectiveProfiles = EnsureTable(AI.objectiveProfiles)
AI.encounterPlan = AI.encounterPlan or nil
AI.encounterState = AI.encounterState or nil
AI.config = EnsureTable(AI.config)
if AI.config.reactiveTriggers == nil and AI.config.opportunityAttacks ~= nil then
    AI.config.reactiveTriggers = AI.config.opportunityAttacks
end
AI.config = ApplyDefaults(AI.config, {
    debug = false,
    movement = true,
    opportunityAttacks = true,
    reactiveTriggers = true,
    villainActions = true,
    maliceAbilities = true,
    safeMode = true,
    manualPrompts = true,
    autoAdvanceInitiative = true,
})
if AI.config.reactiveTriggers == false or AI.config.opportunityAttacks == false then
    AI.config.reactiveTriggers = false
    AI.config.opportunityAttacks = false
end
AI.log = ApplyDefaults(AI.log, {
    lines = {},
    candidates = {},
    skipped = {},
    status = "Ready",
    updated = dmhub.GenerateGuid(),
})
AI.log.lines = EnsureTable(AI.log.lines)
AI.log.candidates = EnsureTable(AI.log.candidates)
AI.log.skipped = EnsureTable(AI.log.skipped)
AI.log.status = AI.log.status or "Ready"
AI.log.updated = AI.log.updated or dmhub.GenerateGuid()
AI.trace = ApplyDefaults(AI.trace, {
    lines = {},
    continuous = false,
    nextTurn = false,
    capture = false,
    oneShotActive = false,
    detailed = false,
    updated = dmhub.GenerateGuid(),
})
AI.trace.lines = EnsureTable(AI.trace.lines)
AI.trace.continuous = AI.trace.continuous == true
AI.trace.nextTurn = AI.trace.nextTurn == true
AI.trace.capture = AI.trace.capture == true
AI.trace.oneShotActive = AI.trace.oneShotActive == true
AI.trace.detailed = AI.trace.detailed == true
AI.trace.updated = AI.trace.updated or dmhub.GenerateGuid()
AI.suppressedUtilityAbilities = ApplyDefaults(AI.suppressedUtilityAbilities, {
    ["charge"] = true,
    ["claw dirt"] = true,
    ["defend"] = true,
    ["help"] = true,
    ["jump"] = true,
    ["move"] = true,
    ["stand up"] = true,
})
for _,name in ipairs({ "escape grab", "search", "search for hidden creatures", "shift", "aid attack", "aid an attack" }) do
    AI.suppressedUtilityAbilities[name] = nil
end

AI._internal = EnsureTable(AI._internal)
AI._runtime = EnsureTable(AI._runtime)

local Internal = AI._internal
local Runtime = AI._runtime

local function ConstValue(domainName, key, default)
    local domain = AI.K and AI.K[domainName] or nil
    if type(domain) == "table" and domain[key] ~= nil then
        return domain[key]
    end

    return default
end

local function ConstNumber(domainName, key, default)
    return tonumber(ConstValue(domainName, key, default)) or default
end

Runtime.thread = Runtime.thread or nil
Runtime.stop = Runtime.stop == true
Runtime.status = Runtime.status or nil
Runtime.activeTurnKey = Runtime.activeTurnKey or nil
Runtime.runGeneration = Runtime.runGeneration or 0
Runtime.promptControlOwner = Runtime.promptControlOwner or ("DirectorTactics:" .. dmhub.GenerateGuid())
Runtime.silentLogDepth = Runtime.silentLogDepth or 0

local function Pick(condition, a, b)
    if condition then
        return a
    end
    return b
end

local function SafeCall(fn, fallback)
    local ok, result = pcall(fn)
    if ok then
        return result
    end
    return fallback
end

local function TryGet(obj, key, fallback)
    if obj == nil then
        return fallback
    end

    local hasTryGet, tryGetFn = pcall(function()
        return obj.try_get
    end)

    if hasTryGet and tryGetFn ~= nil then
        local ok, result = pcall(function()
            return obj:try_get(key)
        end)

        if ok and result ~= nil then
            return result
        end
    end

    local ok, result = pcall(function()
        return obj[key]
    end)

    if not ok or result == nil then
        return fallback
    end

    return result
end

local function HasKey(obj, key)
    if obj == nil then
        return false
    end

    local hasHasKey, hasKeyFn = pcall(function()
        return obj.has_key
    end)

    if hasHasKey and hasKeyFn ~= nil then
        local ok, result = pcall(function()
            return obj:has_key(key)
        end)

        if ok then
            return result
        end
    end

    local ok, result = pcall(function()
        return obj[key]
    end)

    return ok and result ~= nil
end

local function Lower(s)
    if s == nil then
        return ""
    end
    return string.lower(tostring(s))
end

local function TokenName(tok)
    if tok == nil then
        return "unknown"
    end

    return SafeCall(function()
        return creature.GetTokenDescription(tok)
    end, TryGet(tok.properties, "name", "token"))
end

local function IsDead(tok)
    if tok == nil or tok.properties == nil then
        return true
    end

    return SafeCall(function()
        return tok.properties:IsDead()
    end, false)
end

local function IsTokenValid(tok)
    return tok ~= nil and tok.valid ~= false and tok.properties ~= nil and not IsDead(tok)
end

local function TokensFriendly(a, b)
    if a == nil or b == nil then
        return false
    end

    return SafeCall(function()
        return dmhub.TokensAreFriendly(a, b)
    end, SafeCall(function()
        return a:IsFriend(b)
    end, false))
end

local function Distance(a, b)
    if a == nil or b == nil then
        return 999
    end

    return SafeCall(function()
        return a:Distance(b)
    end, 999)
end

local function LocDistance(a, b)
    if a == nil or b == nil then
        return 999
    end

    return SafeCall(function()
        return a:DistanceInTiles(b)
    end, 999)
end

local function CurrentStamina(tok)
    if tok == nil or tok.properties == nil then
        return 0
    end

    return SafeCall(function()
        return tok.properties:CurrentHitpoints()
    end, math.max(0, TryGet(tok.properties, "max_hitpoints", 1) - TryGet(tok.properties, "damage_taken", 0)))
end

local function MaxStamina(tok)
    if tok == nil or tok.properties == nil then
        return 1
    end

    return math.max(1, SafeCall(function()
        return tok.properties:MaxHitpoints()
    end, TryGet(tok.properties, "max_hitpoints", 1)))
end

local function TokenId(tok)
    if tok == nil then
        return nil
    end

    return tok.charid or tok.id or TryGet(tok, "charid", nil)
end

local function TokenEntryMatches(entry, tok)
    if entry == nil or tok == nil then
        return false
    end

    local charid = TokenId(tok)
    if entry == tok then
        return true
    end

    if type(entry) == "string" then
        return entry == charid
    end

    if type(entry) ~= "table" then
        return false
    end

    if entry.token == tok or entry.tok == tok then
        return true
    end

    local entryId = entry.charid or entry.id or entry.tokenid or entry.tokenId
    return entryId ~= nil and entryId == charid
end

local function TokenListContains(list, tok)
    if list == nil or tok == nil then
        return false
    end

    local charid = TokenId(tok)
    if charid ~= nil and list[charid] then
        return true
    end

    for _,entry in pairs(list) do
        if TokenEntryMatches(entry, tok) then
            return true
        end
    end

    return false
end

local function TokenFromEntry(entry)
    if entry == nil then
        return nil
    end

    if type(entry) == "table" then
        if entry.properties ~= nil and entry.loc ~= nil then
            return entry
        end
        return entry.token or entry.tok
    end

    return nil
end

local function LocFromEntry(entry)
    if entry == nil then
        return nil
    end

    if type(entry) == "table" then
        if entry.x ~= nil or entry.str ~= nil or entry.north ~= nil then
            return entry
        end
        return entry.loc or entry.center or entry.position
    end

    return nil
end

local function ZoneContainsLoc(zone, loc, tok)
    if zone == nil or loc == nil then
        return false
    end

    if type(zone) ~= "table" then
        return false
    end

    if tok ~= nil and TokenEntryMatches(zone, tok) then
        return true
    end

    local zoneLoc = LocFromEntry(zone)
    if zoneLoc ~= nil and LocDistance(zoneLoc, loc) <= (zone.radius or zone.range or 0) then
        return true
    end

    if zone.ContainsLoc ~= nil and SafeCall(function()
        return zone:ContainsLoc(loc)
    end, false) then
        return true
    end

    if tok ~= nil and zone.ContainsToken ~= nil and SafeCall(function()
        return zone:ContainsToken(tok)
    end, false) then
        return true
    end

    if zone.locs ~= nil or zone.locations ~= nil then
        for _,zoneLocEntry in pairs(zone.locs or zone.locations or {}) do
            local testLoc = LocFromEntry(zoneLocEntry)
            if testLoc ~= nil and LocDistance(testLoc, loc) <= 0.1 then
                return true
            end
        end
    end

    return false
end

local function ZoneListContainsLoc(zones, loc, tok)
    if zones == nil or loc == nil then
        return false
    end

    for _,zone in pairs(zones) do
        if ZoneContainsLoc(zone, loc, tok) then
            return true
        end
    end

    return false
end

local function HighestCharacteristic(creatureProps)
    if creatureProps == nil then
        return 0
    end

    return SafeCall(function()
        return creatureProps:HighestCharacteristic()
    end, math.max(
        TryGet(creatureProps, "might", 0),
        TryGet(creatureProps, "agility", 0),
        TryGet(creatureProps, "reason", 0),
        TryGet(creatureProps, "intuition", 0),
        TryGet(creatureProps, "presence", 0)
    ))
end

local function HasKeyword(ability, keyword)
    return SafeCall(function()
        return ability:HasKeyword(keyword)
    end, false)
end

local function AbilityRange(ability, token, symbols)
    return math.max(0, SafeCall(function()
        return ability:GetRange(token.properties, symbols or {})
    end, 1))
end

local function AbilityRadius(ability, token, symbols)
    return math.max(0, SafeCall(function()
        return ability:GetRadius(token.properties, symbols or {})
    end, 0))
end

local function AbilityNumTargets(ability, token, symbols)
    return math.max(1, SafeCall(function()
        return ability:GetNumTargets(token, symbols or {})
    end, tonumber(TryGet(ability, "numTargets", 1)) or 1))
end

local function AbilityCanAfford(ability, token, symbols)
    return SafeCall(function()
        return ability:CanAfford(token, { symbols = symbols or {} })
    end, SafeCall(function()
        return ability:CanAfford(token)
    end, false))
end

local function AbilityRequiresPrompt(ability)
    return SafeCall(function()
        return ability:RequiresPromptWhenCast()
    end, TryGet(ability, "multipleModes", false))
end

local function AbilityHasPotency(ability)
    return SafeCall(function()
        return ability:HasPotency()
    end, SafeCall(function()
        for _,behavior in ipairs(TryGet(ability, "behaviors", {}) or {}) do
            if TryGet(behavior, "typeName", "") == "ActivatedAbilityPowerRollBehavior" then
                for _,tier in ipairs(TryGet(behavior, "tiers", {}) or {}) do
                    if string.find(tostring(tier), "<", 1, true) ~= nil then
                        return true
                    end
                end
            end
        end

        return false
    end, false))
end

local function AbilityActionResourceKind(ability)
    local resourceId = SafeCall(function()
        return ability:ActionResource()
    end, nil)

    if resourceId == nil then
        return nil
    end

    local resources = RawGlobal("CharacterResource")
    if resources ~= nil then
        if resourceId == TryGet(resources, "actionResourceId", nil) then
            return "action"
        end

        if resourceId == TryGet(resources, "maneuverResourceId", nil) then
            return "maneuver"
        end
    end

    local resourceInfo = SafeCall(function()
        return dmhub.GetTable("characterResources")[resourceId]
    end, nil)
    local resourceName = Lower(TryGet(resourceInfo, "name", ""))
    if resourceName == "action" or resourceName == "main action" then
        return "action"
    end

    if resourceName == "maneuver" then
        return "maneuver"
    end

    return nil
end

local function IsAction(ability)
    if AbilityActionResourceKind(ability) == "action" then
        return true
    end

    return SafeCall(function()
        return ability:IsAction()
    end, false)
end

local function IsManeuver(ability)
    if AbilityActionResourceKind(ability) == "maneuver" then
        return true
    end

    return SafeCall(function()
        return ability:IsManeuver()
    end, false)
end

local function TargetPasses(ability, casterToken, targetToken, symbols)
    if not IsTokenValid(targetToken) then
        return false, "target invalid"
    end

    local ok, allowed, reason = pcall(function()
        return ability:TargetPassesFilter(casterToken, targetToken, symbols or {})
    end)
    if ok then
        return allowed == true, reason
    end

    return false
end

local function HasLineOfSight(casterToken, targetToken)
    return SafeCall(function()
        local pierce = SafeCall(function()
            return casterToken.properties:GetPierceWalls()
        end, false)
        local los = casterToken:GetLineOfSight(targetToken, pierce)
        return los == nil or los > 0
    end, true)
end

local function EstimateRollText(text)
    if text == nil then
        return 0
    end

    text = tostring(text)
    local total = 0
    local usedDice = false

    for count, sides in string.gmatch(text, "(%d+)%s*d%s*(%d+)") do
        total = total + tonumber(count) * (tonumber(sides) + 1) * 0.5
        usedDice = true
    end

    local withoutDice = string.gsub(text, "%d+%s*d%s*%d+", "")
    local signed = string.gsub(withoutDice, "%-", "+-")
    for n in string.gmatch(signed, "[%+%s](-?%d+)") do
        total = total + tonumber(n)
    end

    if total <= 0 and not usedDice then
        local first = string.match(text, "(%d+)")
        total = tonumber(first) or 0
    end

    return total
end

local function ExtractDamageFromRule(text)
    if text == nil then
        return 0
    end

    local best = 0
    for roll in string.gmatch(tostring(text), "([%d%s%+%-dD]+)%s+[%a%s]*damage") do
        best = math.max(best, EstimateRollText(roll))
    end

    if best <= 0 then
        local n = string.match(tostring(text), "(%d+)%s+[%a%s]*damage")
        best = tonumber(n) or 0
    end

    return best
end

local function TextHasAny(text, words)
    text = Lower(text)
    for _,word in ipairs(words) do
        if string.find(text, word, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function CreateScore()
    return {
        total = 0,
        parts = {},
        labels = {},
    }
end

local function AddScore(score, id, amount)
    if amount == nil or amount == 0 then
        return
    end

    score.total = score.total or 0
    score.parts = score.parts or {}
    score.labels = score.labels or {}
    score.total = score.total + amount
    score.parts[#score.parts+1] = string.format("%s %+0.1f", id, amount)
    score.labels[tostring(id)] = true
end

local function ScoreText(score)
    if score == nil then
        return ""
    end

    return table.concat(score.parts, ", ")
end

local function ScorePartLabel(part)
    local label = string.match(tostring(part or ""), "^%s*(.-)%s+[+%-]%d")
    if label ~= nil and label ~= "" then
        return label
    end

    return tostring(part or "")
end

function AI:ScoreHasLabel(score, label)
    if score == nil or label == nil then
        return false
    end

    local labelText = tostring(label)
    local labels = score.labels
    if type(labels) == "table" then
        if labels[labelText] == true then
            return true
        end

        local lowerLabel = Lower(labelText)
        for key,value in pairs(labels) do
            if value == true and Lower(key) == lowerLabel then
                return true
            end
        end
    end

    local lowerLabel = Lower(labelText)
    for _,part in ipairs(score.parts or {}) do
        if Lower(ScorePartLabel(part)) == lowerLabel then
            return true
        end
    end

    return false
end

function AI:TouchLog()
    self.log.updated = dmhub.GenerateGuid()
end

local TRACE_LINE_LIMIT = 2000

local function TraceSanitize(value)
    value = tostring(value)
    value = string.gsub(value, "[\r\n\t]+", " ")
    value = string.gsub(value, "%s%s+", " ")
    return value
end

local function TraceValue(value)
    local valueType = type(value)
    if value == nil then
        return "nil"
    elseif valueType == "boolean" then
        return Pick(value, "true", "false")
    elseif valueType == "number" then
        return tostring(value)
    elseif valueType == "string" then
        return TraceSanitize(value)
    elseif valueType == "table" then
        local ok, result = pcall(function()
            if value.description ~= nil then
                return value.description
            end
            if value.name ~= nil then
                return value.name
            end
            if value.charid ~= nil then
                return value.charid
            end
            if value.str ~= nil then
                return value.str
            end
            if value.id ~= nil then
                return value.id
            end
            return tostring(value)
        end)
        if ok then
            return TraceSanitize(result)
        end
    end

    return TraceSanitize(value)
end

local function TraceFields(fields)
    if type(fields) ~= "table" then
        return "", ""
    end

    local keys = {}
    for key,_ in pairs(fields) do
        keys[#keys+1] = tostring(key)
    end
    table.sort(keys)

    local display = {}
    local stable = {}
    for _,key in ipairs(keys) do
        local value = fields[key]
        if value ~= nil then
            local text = TraceValue(value)
            display[#display+1] = key .. "=" .. text
            stable[#stable+1] = key .. "=" .. text
        end
    end

    if #display == 0 then
        return "", ""
    end

    return " " .. table.concat(display, " "), " " .. table.concat(stable, " ")
end

function AI:TouchTrace()
    self.trace.updated = dmhub.GenerateGuid()
end

local function TraceCoalesceTable(trace)
    trace._coalesced = EnsureTable(trace._coalesced)
    return trace._coalesced
end

local function TraceTrim(trace)
    while #trace.lines > TRACE_LINE_LIMIT do
        table.remove(trace.lines, 1)
        local coalesced = trace._coalesced
        if type(coalesced) == "table" then
            for key,entry in pairs(coalesced) do
                entry.index = (tonumber(entry.index) or 0) - 1
                if entry.index < 1 then
                    coalesced[key] = nil
                end
            end
        end
    end
end

function AI:TraceActive()
    local trace = self.trace or {}
    return trace.continuous == true or trace.capture == true
end

function AI:Trace(phase, message, fields, options)
    options = options or {}
    self.trace = EnsureTable(self.trace)
    self.trace.lines = EnsureTable(self.trace.lines)

    if options.force ~= true and not self:TraceActive() then
        return
    end

    phase = TraceSanitize(phase or "trace")
    message = TraceSanitize(message or "")
    local fieldText, stableFields = TraceFields(fields)
    local key = phase .. "|" .. message .. stableFields
    local base = string.format("%0.1f [%s] %s%s", dmhub.Time(), phase, message, fieldText)

    if options.coalesce == true and self.trace.detailed ~= true then
        local coalesceKey = key
        if options.coalesceKey ~= nil then
            coalesceKey = phase .. "|" .. message .. "|" .. TraceSanitize(options.coalesceKey)
        end

        local coalesced = TraceCoalesceTable(self.trace)
        local entry = coalesced[coalesceKey]
        if entry ~= nil and tonumber(entry.index) ~= nil and self.trace.lines[entry.index] ~= nil then
            entry.count = (tonumber(entry.count) or 1) + 1
            self.trace.lines[entry.index] = string.format("%s (x%d last=%0.1f)", entry.base or base, entry.count, dmhub.Time())
        else
            self.trace.lines[#self.trace.lines+1] = base
            coalesced[coalesceKey] = {
                index = #self.trace.lines,
                count = 1,
                base = base,
            }
            self.trace._lastKey = nil
            self.trace._lastBase = nil
            self.trace._lastCount = nil
            TraceTrim(self.trace)
        end

        self:TouchTrace()
        return
    end

    if self.trace._lastKey == key and #self.trace.lines > 0 then
        self.trace._lastCount = (tonumber(self.trace._lastCount) or 1) + 1
        self.trace.lines[#self.trace.lines] = string.format("%s (x%d last=%0.1f)", self.trace._lastBase or base, self.trace._lastCount, dmhub.Time())
    else
        self.trace._lastKey = key
        self.trace._lastBase = base
        self.trace._lastCount = 1
        self.trace.lines[#self.trace.lines+1] = base
        TraceTrim(self.trace)
    end

    self:TouchTrace()
end

function AI:ClearTrace()
    self.trace.lines = {}
    self.trace._lastKey = nil
    self.trace._lastBase = nil
    self.trace._lastCount = nil
    self.trace._coalesced = nil
    self:TouchTrace()
end

function AI:ResetTraceCoalescing()
    self.trace = EnsureTable(self.trace)
    self.trace._lastKey = nil
    self.trace._lastBase = nil
    self.trace._lastCount = nil
    self.trace._coalesced = nil
end

function AI:TraceText()
    return table.concat(self.trace.lines or {}, "\n")
end

function AI:TraceNextTurn()
    self.trace.nextTurn = true
    self:Trace("trace", "next turn armed", nil, { force = true })
    self:TouchTrace()
end

function AI:SetTraceContinuous(value)
    self.trace.continuous = value == true
    if not self.trace.continuous and not self.trace.oneShotActive then
        self.trace.capture = false
    end
    self:Trace("trace", Pick(self.trace.continuous, "continuous enabled", "continuous disabled"), nil, { force = true })
    self:TouchTrace()
end

function AI:SetTraceDetailed(value)
    self.trace.detailed = value == true
    self:Trace("trace", Pick(self.trace.detailed, "detailed enabled", "detailed disabled"), nil, { force = true })
    self:TouchTrace()
end

function AI:StartTraceCapture(reason, fields)
    local trace = self.trace or {}
    if trace.nextTurn then
        trace.nextTurn = false
        trace.capture = true
        trace.oneShotActive = true
        self:ResetTraceCoalescing()
        self:Trace("trace", "capture started", fields or { reason = reason or "next turn" }, { force = true })
        self:TouchTrace()
        return true
    end

    if trace.continuous then
        trace.capture = true
        self:ResetTraceCoalescing()
        self:Trace("trace", "turn capture observed", fields or { reason = reason or "continuous" })
        self:TouchTrace()
        return true
    end

    return false
end

function AI:FinishTraceCapture(reason, fields)
    local trace = self.trace or {}
    if trace.oneShotActive then
        self:Trace("trace", "capture finished", fields or { reason = reason or "turn finished" }, { force = true })
        trace.capture = false
        trace.oneShotActive = false
        self:TouchTrace()
    elseif trace.continuous then
        self:Trace("trace", "turn capture finished", fields or { reason = reason or "turn finished" })
    end
end

function AI:AutomationCanceled(runGeneration)
    if (mod ~= nil and mod.unloaded) or Runtime.stop then
        return true
    end

    if runGeneration ~= nil and runGeneration ~= Runtime.runGeneration then
        return true
    end

    return false
end

function AI:ClearLog()
    self.log.lines = {}
    self.log.candidates = {}
    self.log.skipped = {}
    self.log.status = "Ready"
    self:TouchLog()
end

function AI:SetStatus(message)
    self.log.status = tostring(message or "Ready")
    self:Trace("status", self.log.status)
    self:TouchLog()
end

function AI:Log(message)
    self:Trace("log", message)
    if not self.config.debug or (Runtime.silentLogDepth or 0) > 0 then
        return
    end

    local lines = self.log.lines
    lines[#lines+1] = string.format("%0.1f: %s", dmhub.Time(), message)
    while #lines > 120 do
        table.remove(lines, 1)
    end
    self:TouchLog()
end

function AI:Skip(ability, reason)
    local name = "unknown"
    if ability ~= nil then
        name = TryGet(ability, "name", name)
    end

    self:Trace("skip", reason, { ability = name })
    if not self.config.debug or (Runtime.silentLogDepth or 0) > 0 then
        return
    end

    self.log.skipped[#self.log.skipped+1] = string.format("%s: %s", name, reason)
    while #self.log.skipped > 60 do
        table.remove(self.log.skipped, 1)
    end
    self:TouchLog()
end

function AI:RunWithSilentLog(fn)
    Runtime.silentLogDepth = (Runtime.silentLogDepth or 0) + 1
    local ok, result = xpcall(fn, function(err)
        return tostring(err)
    end)
    Runtime.silentLogDepth = math.max(0, (Runtime.silentLogDepth or 1) - 1)

    if ok then
        return result
    end

    error(result)
end

function AI.Sleep(seconds)
    if seconds == nil or seconds <= 0 then
        return
    end

    local finish = dmhub.Time() + seconds
    while dmhub.Time() < finish do
        coroutine.yield(0.1)
    end
end

function AI:RegisterRoleProfile(args)
    self.roleProfiles[args.id] = args
end

function AI:RegisterAbilityRule(args)
    self.abilityRules[#self.abilityRules+1] = args
end

function AI:RegisterTacticRule(args)
    if args ~= nil and args.id ~= nil then
        self.tacticRules[#self.tacticRules+1] = args
    end
end

function AI:RegisterPromptPolicy(args)
    self.promptPolicies[#self.promptPolicies+1] = args
end

function AI:RegisterTriggerPolicy(args)
    self.triggerPolicies[#self.triggerPolicies+1] = args
end

function AI:ReactiveTriggersEnabled()
    local config = self.config or {}
    if config.reactiveTriggers == false or config.opportunityAttacks == false then
        return false
    end

    return true
end

function AI:SetReactiveTriggersEnabled(value)
    self.config = EnsureTable(self.config)
    local enabled = value == true
    self.config.reactiveTriggers = enabled
    self.config.opportunityAttacks = enabled
end

function AI:RegisterMonsterOverride(args)
    self.monsterOverrides[#self.monsterOverrides+1] = args
end

function AI:RegisterObjectiveProfile(args)
    if args ~= nil and args.id ~= nil then
        args.id = Lower(args.id)
        self.objectiveProfiles[args.id] = args
    end
end

local function CopyPlanList(value)
    if type(value) ~= "table" then
        return {}
    end

    local result = {}
    for k,v in pairs(value) do
        result[k] = v
    end
    return result
end

local function CopyArray(value)
    if type(value) ~= "table" then
        return {}
    end

    local result = {}
    for i=1,#value do
        result[i] = value[i]
    end
    return result
end

local function CopySymbols(value)
    if type(value) ~= "table" then
        return {}
    end

    local result = {}
    for k,v in pairs(value) do
        if k == "targetPairs" and type(v) == "table" then
            local pairsCopy = {}
            for i,pair in ipairs(v) do
                if type(pair) == "table" then
                    local pairCopy = {}
                    for pairKey,pairValue in pairs(pair) do
                        pairCopy[pairKey] = pairValue
                    end
                    pairsCopy[i] = pairCopy
                else
                    pairsCopy[i] = pair
                end
            end
            result[k] = pairsCopy
        else
            result[k] = v
        end
    end
    return result
end

local function LocKey(loc, ...)
    if loc == nil then
        if select("#", ...) > 0 then
            return select(1, ...)
        end

        return ""
    end

    local str = TryGet(loc, "str", nil)
    if str ~= nil then
        return tostring(str)
    end

    return table.concat({
        tostring(TryGet(loc, "x", "")),
        tostring(TryGet(loc, "y", "")),
        tostring(TryGet(loc, "floor", "")),
        tostring(TryGet(loc, "altitude", "")),
    }, ":")
end

local function LocOccupancyKey(loc)
    if loc == nil then
        return nil
    end

    local x = TryGet(loc, "x", nil)
    local y = TryGet(loc, "y", nil)
    local floor = TryGet(loc, "floor", nil)
    if x ~= nil and y ~= nil then
        return tostring(floor or "") .. ":" .. tostring(x) .. ":" .. tostring(y)
    end

    local str = TryGet(loc, "str", nil)
    if str ~= nil then
        return tostring(str)
    end

    return nil
end

Internal.RawGlobal = RawGlobal
Internal.ConstValue = ConstValue
Internal.ConstNumber = ConstNumber
Internal.Pick = Pick
Internal.SafeCall = SafeCall
Internal.TryGet = TryGet
Internal.HasKey = HasKey
Internal.Lower = Lower
Internal.TokenName = TokenName
Internal.IsDead = IsDead
Internal.IsTokenValid = IsTokenValid
Internal.TokensFriendly = TokensFriendly
Internal.Distance = Distance
Internal.LocDistance = LocDistance
Internal.CurrentStamina = CurrentStamina
Internal.MaxStamina = MaxStamina
Internal.TokenId = TokenId
Internal.TokenEntryMatches = TokenEntryMatches
Internal.TokenListContains = TokenListContains
Internal.TokenFromEntry = TokenFromEntry
Internal.LocFromEntry = LocFromEntry
Internal.ZoneContainsLoc = ZoneContainsLoc
Internal.ZoneListContainsLoc = ZoneListContainsLoc
Internal.HighestCharacteristic = HighestCharacteristic
Internal.HasKeyword = HasKeyword
Internal.AbilityRange = AbilityRange
Internal.AbilityRadius = AbilityRadius
Internal.AbilityNumTargets = AbilityNumTargets
Internal.AbilityCanAfford = AbilityCanAfford
Internal.AbilityRequiresPrompt = AbilityRequiresPrompt
Internal.AbilityHasPotency = AbilityHasPotency
Internal.AbilityActionResourceKind = AbilityActionResourceKind
Internal.IsAction = IsAction
Internal.IsManeuver = IsManeuver
Internal.TargetPasses = TargetPasses
Internal.HasLineOfSight = HasLineOfSight
Internal.EstimateRollText = EstimateRollText
Internal.ExtractDamageFromRule = ExtractDamageFromRule
Internal.TextHasAny = TextHasAny
Internal.CreateScore = CreateScore
Internal.AddScore = AddScore
Internal.ScoreText = ScoreText
Internal.ScoreHasLabel = function(score, label)
    return AI:ScoreHasLabel(score, label)
end
Internal.CopyPlanList = CopyPlanList
Internal.CopyArray = CopyArray
Internal.CopySymbols = CopySymbols
Internal.LocKey = LocKey
Internal.LocOccupancyKey = LocOccupancyKey
