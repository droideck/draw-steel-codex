local mod = dmhub.GetModLoading()

-- ============================================================================
-- WarmindPanel.lua
--
-- The DM-facing panel and the polling thread that drives the AI.
--
-- Stage 1 panel: status, Start/Stop (stop is a clean takeover: control state
-- is released and initiative is left untouched), and a live decision trace.
-- Stage 5 adds step mode (pause after each activation), per-spec
-- enable/disable persisted to settings, and a richer trace viewer.
--
-- The thread is the only place that polls. It:
--   * dispatches monster opportunity-attack triggers,
--   * selects which monster entry activates when none is selected
--     (WarmindDirector decides), and
--   * plays the selected turn (WarmindTurn).
--
-- Two-tier error containment: WarmindTurn guards each activation; this
-- thread guards the drivers and AUTO-STOPS the AI on a driver error so a
-- bug can never error-loop the same turn forever.
-- ============================================================================

local g_thread = nil
local g_terminate = false
local g_status = nil

-- True between "Start AI was clicked" and "the thread's first scheduled
-- run". dmhub.Coroutine does not start synchronously, so without this flag
-- two quick clicks could both see a nil g_thread and start two AI threads.
local g_starting = false

-- ----------------------------------------------------------------------------
-- Thread helpers.
-- ----------------------------------------------------------------------------

local function DispatchOpportunityAttacks()
    for _,token in ipairs(dmhub.allTokens) do
        if (not token.playerControlled) and token.properties ~= nil then
            local triggers = token.properties:GetAvailableTriggers()
            if triggers ~= nil then
                for _,trigger in pairs(triggers) do
                    if trigger.text == "Opportunity Attack" and (not trigger.triggered) then
                        Warmind.Trace("Dispatching opportunity attack.")
                        trigger.triggered = true
                        token.properties:DispatchAvailableTrigger(trigger)
                        break
                    end
                end
            end
        end
    end
end

-- It is the Director's side of the round and no entry is selected: ask the
-- Director layer which monster group goes, select it, begin its tokens'
-- turns, and bring the camera to it.
local function SelectNextActivation(queue)
    local choice = Warmind.Director.ChooseActivation(queue)
    if choice == nil then
        return
    end

    queue:SelectTurn(choice)
    dmhub:UploadInitiativeQueue()

    local centerOn = nil
    local tokens = GameHud.GetTokensForInitiativeId(GameHud.instance, GameHud.instance.initiativeInterface, choice)
    for _,tok in ipairs(tokens) do
        if tok.properties ~= nil then
            tok.properties:BeginTurn()
            if centerOn == nil or (not tok.properties.minion) then
                centerOn = tok
            end
        end
    end

    if centerOn ~= nil then
        dmhub.CenterOnToken(centerOn.charid, {smooth = true})
        dmhub.SyncCamera{
            speed = 1,
        }
        Warmind.Sleep(1)
    end
end

-- After the monsters act, bring the camera back to an unmoved player entry.
local function CenterOnPlayers(queue)
    local centerOn = nil
    local entriesUnmoved = queue:EntriesUnmoved()
    for initiativeid,_ in pairs(entriesUnmoved) do
        if queue:IsEntryPlayer(initiativeid) then
            local tokens = GameHud.GetTokensForInitiativeId(GameHud.instance, GameHud.instance.initiativeInterface, initiativeid)
            for _,tok in ipairs(tokens) do
                if tok.properties ~= nil and (centerOn == nil or (not tok.properties.minion)) then
                    centerOn = tok
                end
            end
        end
    end

    if centerOn ~= nil then
        dmhub.CenterOnToken(centerOn.charid, {smooth = true})
        dmhub.SyncCamera{
            speed = 1,
        }
    end
end

-- ----------------------------------------------------------------------------
-- The thread.
-- ----------------------------------------------------------------------------

local function WarmindThread()
    g_starting = false
    g_status = nil
    Warmind.Trace("Warmind started.")

    while true do
        g_thread = coroutine.running()
        coroutine.yield(0.1)

        if mod.unloaded or g_terminate then
            g_thread = nil
            g_status = nil
            Warmind.Trace("Warmind stopped.")
            return
        end

        local queue = dmhub.initiativeQueue
        if queue ~= nil and (not queue.hidden) then
            -- While the director has awarded victory, the initiative bar is
            -- hidden and DSVictoryScreen owns the table, but the queue itself
            -- is not hidden yet. Idle (keep polling) until the director
            -- proceeds; acting here would advance turns under the victory
            -- screen. (queue.liveEncounter is false/nil when no live
            -- encounter is attached.)
            local liveEncounter = queue:try_get("liveEncounter")
            local victoryAwarded = type(liveEncounter) == "table" and liveEncounter:try_get("victoryAwarded", false)

            if victoryAwarded then
                g_status = "Victory screen"
            elseif g_status == "Victory screen" then
                g_status = nil
            end

            if not victoryAwarded then
                DispatchOpportunityAttacks()

                if not queue:IsPlayersTurn() then
                    local initiativeid = queue:CurrentInitiativeId()

                    if initiativeid == nil then
                        g_status = "Selecting activation"
                        local ok, err = Warmind.Guard(function()
                            SelectNextActivation(queue)
                        end)
                        g_status = nil

                        if not ok then
                            Warmind.Trace("[%s] Activation selection error; stopping: %s",
                                Warmind.reason.EXECUTION_ERROR, tostring(err))
                            g_terminate = true
                        end
                    else
                        g_status = "Playing turn"
                        local ok, summary = Warmind.Guard(function()
                            return Warmind.Turn.PlayCurrentTurn()
                        end)
                        g_status = nil

                        if not ok then
                            Warmind.Trace("[%s] Turn driver error; stopping: %s",
                                Warmind.reason.EXECUTION_ERROR, tostring(summary))
                            g_terminate = true
                        elseif summary ~= nil and summary.manualPending then
                            -- An action needs the DM's hands. Pause instead of
                            -- re-activating the same entry in a loop; the DM
                            -- finishes the action, advances initiative, and
                            -- presses Start AI to resume.
                            Warmind.Trace("Paused: an action needs manual resolution. Press Start AI to resume.")
                            g_terminate = true
                        elseif not Warmind.stopRequested then
                            CenterOnPlayers(queue)
                        end
                    end
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Panel UI.
-- ----------------------------------------------------------------------------

local function CreateWarmindPanel()
    local resultPanel
    local m_running = false
    local m_traceSerial = nil

    resultPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",

        gui.Label{
            fontSize = 16,
            width = "auto",
            height = "auto",
            thinkTime = 0.1,
            think = function(element)
                local status = g_thread ~= nil and coroutine.status(g_thread)
                if status == "suspended" or status == "running" then
                    m_running = true
                    if g_terminate then
                        element.text = "Stopping..."
                    else
                        element.text = g_status or "Active"
                    end
                else
                    m_running = false
                    element.text = "Not Running"
                end
                resultPanel:FireEventTree("refreshai")
            end,
        },

        gui.Button{
            text = "Start AI",
            width = 120,
            height = 30,
            fontSize = 14,
            refreshai = function(element)
                element.text = m_running and "Stop AI" or "Start AI"
            end,
            click = function()
                -- Check the thread directly rather than the cached
                -- m_running flag: a stale flag could double-start the
                -- thread and have two AIs playing turns at once.
                local status = g_thread ~= nil and coroutine.status(g_thread)
                local running = status == "suspended" or status == "running"
                if running or g_starting then
                    g_terminate = true
                    Warmind.RequestStop()
                else
                    g_starting = true
                    g_terminate = false
                    Warmind.ClearStop()
                    dmhub.Coroutine(WarmindThread)
                end
            end,
        },

        gui.Label{
            fontSize = 14,
            width = "100%",
            height = "auto",
            bold = true,
            text = "Decision trace",
        },

        gui.Label{
            fontSize = 12,
            width = "100%",
            height = "auto",
            thinkTime = 0.25,
            think = function(element)
                if Warmind.trace.serial == m_traceSerial then
                    return
                end
                m_traceSerial = Warmind.trace.serial

                local entries = Warmind.trace.entries
                local lines = {}
                local firstIndex = math.max(1, #entries - 24)
                for i=firstIndex,#entries do
                    lines[#lines+1] = entries[i].text
                end

                if #lines == 0 then
                    element.text = "(no decisions yet)"
                else
                    element.text = table.concat(lines, "\n")
                end
            end,
        },
    }

    return resultPanel
end

DockablePanel.Register{
    name = "Warmind",
    minHeight = 60,
    dmonly = true,
    content = function()
        return CreateWarmindPanel()
    end,
}
