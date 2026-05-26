local mod = dmhub.GetModLoading()

-- DirectorTacticsPanel.lua contains only the Director Tactics dockable panel UI.
-- Load after DirectorTacticsPolicies.lua. It extends the shared DirectorTacticsAI table.

local function RequireDirectorTacticsAI()
    local ai = rawget(_G, "DirectorTacticsAI")
    if ai == nil or ai._internal == nil then
        error("DirectorTacticsAI.lua must be loaded before DirectorTacticsPanel.lua")
    end
    return ai
end

local AI = RequireDirectorTacticsAI()
local Internal = AI._internal

local RawGlobal = Internal.RawGlobal
local Pick = Internal.Pick

function AI.CreatePanel()
    local resultPanel
    local m_logUpdate = nil

    local function Tooltip(text)
        if text == nil or text == "" then
            return nil
        end

        return gui.Tooltip(text)
    end

    local function CountedText(text, count)
        if count ~= nil and count > 1 then
            return string.format("%s (x%d)", text, count)
        end

        return text
    end

    local function CompactUniqueLines(lines)
        local result = {}
        local byText = {}

        for _,line in ipairs(lines or {}) do
            local entry = byText[line]
            if entry == nil then
                entry = { text = line, count = 0 }
                byText[line] = entry
                result[#result+1] = entry
            end

            entry.count = entry.count + 1
        end

        return result
    end

    local function LogMessageKey(line)
        return string.match(line or "", "^%d+%.?%d*:%s*(.*)$") or line
    end

    local function CompactConsecutiveLogLines(lines)
        local result = {}
        local last = nil

        for _,line in ipairs(lines or {}) do
            local key = LogMessageKey(line)
            if last ~= nil and last.key == key then
                last.count = last.count + 1
            else
                last = { key = key, text = line, count = 1 }
                result[#result+1] = last
            end
        end

        return result
    end

    local function BuildMainLogText()
        local lines = {}
        local plan = AI:GetEncounterPlan()
        local state = AI.encounterState or AI:NewEncounterState()

        local function Add(text)
            lines[#lines+1] = tostring(text or "")
        end

        local function AddSection(title)
            if #lines > 0 then
                Add("")
            end
            Add(title)
        end

        Add("Director Tactics Log")
        Add("Status: " .. tostring(AI.log.status or "Ready"))

        AddSection("Encounter Assumptions")
        Add(string.format("Objective: %s | Difficulty: %s | Lethality: %s | Spread: %s", tostring(plan.objective), tostring(plan.difficulty), tostring(plan.lethality), Pick(plan.spreadDamage, "yes", "no")))
        Add(string.format("Round: %s | Foes: %s/%s | Non-minions: %s/%s | Broken: %s", tostring(state.round or 1), tostring((state.progress or {}).liveFoes or 0), tostring(state.initialFoeCount or 0), tostring((state.progress or {}).liveNonMinionFoes or 0), tostring(state.initialNonMinionFoeCount or 0), Pick(state.broken, "yes", "no")))

        AddSection("Top Candidates")
        if #AI.log.candidates == 0 then
            Add("No analysis yet.")
        else
            for _,line in ipairs(AI.log.candidates) do
                Add(line)
            end
        end

        AddSection("Not Automated")
        if #AI.log.skipped == 0 then
            Add("None.")
        else
            for _,entry in ipairs(CompactUniqueLines(AI.log.skipped)) do
                Add(CountedText(entry.text, entry.count))
            end
        end

        AddSection("Log")
        if #AI.log.lines == 0 then
            Add("No log lines.")
        else
            for _,entry in ipairs(CompactConsecutiveLogLines(AI.log.lines)) do
                Add(CountedText(entry.text, entry.count))
            end
        end

        return table.concat(lines, "\n")
    end

    local function RefreshLog(panel)
        local children = {}
        local plan = AI:GetEncounterPlan()
        local state = AI.encounterState or AI:NewEncounterState()

        children[#children+1] = gui.Label{
            fontSize = 14,
            width = "100%",
            height = "auto",
            bold = true,
            text = "Encounter Assumptions",
            hover = Tooltip("Current tactical assumptions used when scoring Director-controlled turns."),
        }

        children[#children+1] = gui.Label{
            fontSize = 12,
            width = "100%",
            height = "auto",
            text = string.format("Objective: %s | Difficulty: %s | Lethality: %s | Spread: %s", tostring(plan.objective), tostring(plan.difficulty), tostring(plan.lethality), Pick(plan.spreadDamage, "yes", "no")),
        }

        children[#children+1] = gui.Label{
            fontSize = 12,
            width = "100%",
            height = "auto",
            text = string.format("Round: %s | Foes: %s/%s | Non-minions: %s/%s | Broken: %s", tostring(state.round or 1), tostring((state.progress or {}).liveFoes or 0), tostring(state.initialFoeCount or 0), tostring((state.progress or {}).liveNonMinionFoes or 0), tostring(state.initialNonMinionFoeCount or 0), Pick(state.broken, "yes", "no")),
        }

        children[#children+1] = gui.Label{
            fontSize = 12,
            width = "100%",
            height = "auto",
            bold = true,
            text = "Status: " .. tostring(AI.log.status or "Ready"),
            hover = Tooltip("Most recent automation result or held-turn reason."),
        }

        children[#children+1] = gui.Label{
            fontSize = 14,
            width = "100%",
            height = "auto",
            bold = true,
            tmargin = 8,
            text = "Top Candidates",
            hover = Tooltip("Highest-scoring legal actions. The AI tries the first candidate that clears the score threshold."),
        }

        if #AI.log.candidates == 0 then
            children[#children+1] = gui.Label{
                fontSize = 13,
                width = "100%",
                height = "auto",
                text = "No analysis yet.",
            }
        else
            for _,line in ipairs(AI.log.candidates) do
                children[#children+1] = gui.Label{
                    fontSize = 13,
                    width = "100%",
                    height = "auto",
                    text = line,
                }
            end
        end

        if AI.config.debug and #AI.log.skipped > 0 then
            children[#children+1] = gui.Label{
                fontSize = 14,
                width = "100%",
                height = "auto",
                bold = true,
                tmargin = 8,
                text = "Not Automated",
                hover = Tooltip("Abilities ignored during analysis and the reason they were not considered safe or legal."),
            }
            for _,entry in ipairs(CompactUniqueLines(AI.log.skipped)) do
                children[#children+1] = gui.Label{
                    fontSize = 12,
                    width = "100%",
                    height = "auto",
                    text = CountedText(entry.text, entry.count),
                }
            end
        end

        if AI.config.debug and #AI.log.lines > 0 then
            children[#children+1] = gui.Label{
                fontSize = 14,
                width = "100%",
                height = "auto",
                bold = true,
                tmargin = 8,
                text = "Log",
                hover = Tooltip("Recent automation events, execution choices, and safety checks."),
            }
            local logLines = CompactConsecutiveLogLines(AI.log.lines)
            local startIndex = math.max(1, #logLines - 18)
            for i=startIndex,#logLines do
                children[#children+1] = gui.Label{
                    fontSize = 12,
                    width = "100%",
                    height = "auto",
                    text = CountedText(logLines[i].text, logLines[i].count),
                }
            end
        end

        panel.children = children
    end

    local function ConfigCheck(label, key, tooltip, setter, getter)
        return gui.Check{
            text = label,
            width = "100%",
            height = 22,
            fontSize = 13,
            value = getter ~= nil and getter() or AI.config[key],
            hover = Tooltip(tooltip),
            change = function(element)
                if setter ~= nil then
                    setter(element.value)
                else
                    AI.config[key] = element.value
                end
                AI:TouchLog()
            end,
            refreshai = function(element)
                element.value = getter ~= nil and getter() or AI.config[key]
            end,
        }
    end

    local function PlanCheck(label, key, tooltip)
        return gui.Check{
            text = label,
            width = "100%",
            height = 22,
            fontSize = 13,
            value = AI:GetEncounterPlan()[key],
            hover = Tooltip(tooltip),
            change = function(element)
                local update = {}
                update[key] = element.value
                AI:SetEncounterPlan(update)
            end,
            refreshai = function(element)
                element.value = AI:GetEncounterPlan()[key]
            end,
        }
    end

    local function PlanDropdown(label, key, options, tooltip)
        return gui.Panel{
            width = "100%",
            height = 28,
            flow = "horizontal",
            hover = Tooltip(tooltip),
            gui.Label{
                text = label,
                fontSize = 12,
                width = 78,
                height = 24,
                valign = "center",
            },
            gui.Dropdown{
                width = 174,
                height = 24,
                fontSize = 12,
                options = options,
                idChosen = AI:GetEncounterPlan()[key],
                change = function(element)
                    local update = {}
                    update[key] = element.idChosen
                    AI:SetEncounterPlan(update)
                end,
                refreshai = function(element)
                    element.idChosen = AI:GetEncounterPlan()[key]
                end,
            },
        }
    end

    resultPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        hpad = 8,
        vpad = 8,
        borderBox = true,

        gui.Label{
            fontSize = 16,
            width = "100%",
            height = "auto",
            bold = true,
            thinkTime = 0.2,
            hover = Tooltip("Automates Director-controlled creatures on the current initiative entry."),
            think = function(element)
                element.text = "Director Tactics: " .. AI:StatusText()
                resultPanel:FireEventTree("refreshai")
                if m_logUpdate ~= AI.log.updated then
                    m_logUpdate = AI.log.updated
                    resultPanel:FireEventTree("refreshlog")
                end
            end,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",

            gui.Button{
                text = "Play Turn",
                width = 104,
                height = 26,
                fontSize = 13,
                hover = Tooltip("Analyze and play the current Director initiative entry once."),
                click = function()
                    AI:PlayCurrentTurn()
                end,
            },

            gui.Button{
                text = "Analyze",
                width = 86,
                height = 26,
                fontSize = 13,
                hmargin = 4,
                hover = Tooltip("Score the current Director turn without executing any action."),
                click = function()
                    AI:AnalyzeCurrentTurn()
                end,
            },

            gui.Button{
                text = "Start",
                width = 86,
                height = 26,
                fontSize = 13,
                hover = Tooltip("Start or stop continuous automation for Director turns."),
                refreshai = function(element)
                    element.text = Pick(AI:IsRunning(), "Stop", "Start")
                end,
                click = function()
                    if AI:IsRunning() then
                        AI:Stop()
                    else
                        AI:Start()
                    end
                end,
            },

            gui.Button{
                text = "Resume",
                width = 86,
                height = 26,
                fontSize = 13,
                hmargin = 4,
                classes = { "collapsed" },
                hover = Tooltip("Resume Director automation after a manual prompt handoff."),
                refreshai = function(element)
                    element:SetClass("collapsed", not AI:ManualPromptHandoffPending())
                end,
                click = function()
                    AI:ResumeManualPromptHandoff()
                end,
            },
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "horizontal",
            tmargin = 4,

            gui.Button{
                text = "Copy Log",
                width = 104,
                height = 26,
                fontSize = 13,
                hover = Tooltip("Copy the current Director Tactics panel log to the system clipboard."),
                click = function(element)
                    dmhub.CopyToClipboard(BuildMainLogText())
                    gui.Tooltip("Copied")(element)
                end,
            },
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            tmargin = 6,
            gui.Label{
                fontSize = 14,
                width = "100%",
                height = "auto",
                bold = true,
                text = "Encounter Plan",
                hover = Tooltip("Controls the tactical scoring assumptions for this encounter."),
            },
            PlanDropdown("Objective", "objective", {
                { id = "diminish_numbers", text = "Diminish Numbers", tooltip = "Default combat behavior: reduce the heroes' numbers and pressure vulnerable targets." },
                { id = "defeat_specific_foe", text = "Defeat Specific Foe", tooltip = "Biases scoring toward priority targets set through the encounter plan API." },
                -- Other objective profiles remain available through SetEncounterPlan
                -- for explicit API testing, but are hidden here until token and zone
                -- configuration is reliable enough for normal panel use.
            }, "What the Director side is trying to accomplish."),
            PlanDropdown("Difficulty", "difficulty", {
                { id = "trivial", text = "Trivial", tooltip = "Uses resources sparingly and spreads damage heavily." },
                { id = "easy", text = "Easy", tooltip = "Plays softly while still taking useful actions." },
                { id = "standard", text = "Standard", tooltip = "Balanced default tactics." },
                { id = "hard", text = "Hard", tooltip = "Values damage, objectives, malice, and villain actions more aggressively." },
                { id = "extreme", text = "Extreme", tooltip = "Pushes strong tactics and resources with little restraint." },
            }, "How hard the AI should press its advantages."),
            PlanDropdown("Lethality", "lethality", {
                { id = "merciful", text = "Merciful", tooltip = "De-emphasizes finishing blows and spreads damage more." },
                { id = "fair", text = "Fair", tooltip = "Default target pressure." },
                { id = "ruthless", text = "Ruthless", tooltip = "Focuses damage more and is less likely to flee when broken." },
            }, "How willing the AI is to focus damage and finish targets."),
            PlanCheck("Spread damage", "spreadDamage", "Prefer not to keep attacking the same hero unless the objective calls for focus."),
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            tmargin = 6,
            gui.Label{
                fontSize = 14,
                width = "100%",
                height = "auto",
                bold = true,
                text = "Automation",
                hover = Tooltip("Runtime safety and automation behavior toggles."),
            },
            ConfigCheck("Debug log", "debug", "Show Not Automated and Log details for candidate scoring and execution events."),
            ConfigCheck("Movement", "movement", "Allow the AI to move tokens before abilities and to use movement-only repositioning."),
            ConfigCheck("Reactive triggers", "reactiveTriggers", "Automatically fire available Director reactive triggers, including opportunity attacks, when trigger windows appear.", function(value)
                AI:SetReactiveTriggersEnabled(value)
            end, function()
                return AI:ReactiveTriggersEnabled()
            end),
            ConfigCheck("Villain actions", "villainActions", "Allow end-of-round villain actions when a legal, safe candidate is available."),
            ConfigCheck("Malice abilities", "maliceAbilities", "Allow malice abilities that the AI can afford and resolve safely."),
            ConfigCheck("Manual prompts", "manualPrompts", "Allow handoff for broad non-creature targeting the AI cannot enumerate. Movement and charge prompts are always skipped unless automated safely."),
            ConfigCheck("Auto-advance initiative", "autoAdvanceInitiative", "After finishing a Director turn, automatically move to the next initiative entry."),
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            tmargin = 8,
            refreshlog = function(element)
                RefreshLog(element)
            end,
            create = function(element)
                RefreshLog(element)
            end,
        },
    }

    return resultPanel
end

function AI.CreateTracePanel()
    local resultPanel
    local m_traceUpdate = nil

    local function Tooltip(text)
        if text == nil or text == "" then
            return nil
        end

        return gui.Tooltip(text)
    end

    local function TraceStatusText()
        local trace = AI.trace or {}
        return string.format(
            "Trace: %s | Next Turn: %s | Detail: %s | Lines: %d",
            Pick(trace.continuous == true, "continuous", Pick(trace.capture == true, "capturing", "off")),
            Pick(trace.nextTurn == true, "armed", "off"),
            Pick(trace.detailed == true, "on", "off"),
            #(trace.lines or {})
        )
    end

    local function RefreshTrace(panel)
        local children = {}
        local lines = (AI.trace and AI.trace.lines) or {}

        children[#children+1] = gui.Label{
            fontSize = 12,
            width = "100%",
            height = "auto",
            text = TraceStatusText(),
        }

        if #lines == 0 then
            children[#children+1] = gui.Label{
                fontSize = 12,
                width = "100%",
                height = "auto",
                text = "No trace captured.",
            }
        else
            local startIndex = math.max(1, #lines - 399)
            if startIndex > 1 then
                children[#children+1] = gui.Label{
                    fontSize = 11,
                    width = "100%",
                    height = "auto",
                    text = string.format("Showing last %d of %d lines.", #lines - startIndex + 1, #lines),
                }
            end

            for i=startIndex,#lines do
                children[#children+1] = gui.Label{
                    fontSize = 11,
                    width = "100%",
                    height = "auto",
                    text = lines[i],
                }
            end
        end

        panel.children = children
    end

    resultPanel = gui.Panel{
        width = "100%",
        height = "auto",
        flow = "vertical",
        hpad = 8,
        vpad = 8,
        borderBox = true,

        gui.Label{
            fontSize = 16,
            width = "100%",
            height = "auto",
            bold = true,
            text = "Director Tactics Trace",
            thinkTime = 0.2,
            hover = Tooltip("Opt-in runtime trace for Director Tactics automation."),
            think = function(element)
                element.text = "Director Tactics Trace: " .. TraceStatusText()
                resultPanel:FireEventTree("refreshai")
                if m_traceUpdate ~= AI.trace.updated then
                    m_traceUpdate = AI.trace.updated
                    resultPanel:FireEventTree("refreshtrace")
                end
            end,
        },

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                gui.Button{
                    text = "Trace Next Turn",
                    width = 132,
                    height = 26,
                    fontSize = 12,
                    hover = Tooltip("Capture the next Director Tactics turn only."),
                    click = function()
                        AI:TraceNextTurn()
                    end,
                },
                gui.Check{
                    text = "Turn Trace",
                    width = 118,
                    height = 26,
                    fontSize = 12,
                    hmargin = 4,
                    value = AI.trace.continuous,
                    hover = Tooltip("Continuously capture Director Tactics turn traces until unchecked."),
                    change = function(element)
                        AI:SetTraceContinuous(element.value)
                    end,
                    refreshai = function(element)
                        element.value = AI.trace.continuous
                    end,
                },
                gui.Check{
                    text = "Detailed Trace",
                    width = 132,
                    height = 26,
                    fontSize = 12,
                    hmargin = 4,
                    value = AI.trace.detailed,
                    hover = Tooltip("Show repeated low-level polling, trigger scan, and resource sync trace lines without summarizing."),
                    change = function(element)
                        AI:SetTraceDetailed(element.value)
                    end,
                    refreshai = function(element)
                        element.value = AI.trace.detailed
                    end,
                },
            },
            gui.Panel{
                width = "100%",
                height = "auto",
                flow = "horizontal",
                tmargin = 4,
                gui.Button{
                    text = "Clear",
                    width = 70,
                    height = 26,
                    fontSize = 12,
                    hover = Tooltip("Clear the trace buffer."),
                    click = function()
                        AI:ClearTrace()
                    end,
                },
                gui.Button{
                    text = "Copy",
                    width = 70,
                    height = 26,
                    fontSize = 12,
                    hmargin = 4,
                    hover = Tooltip("Copy the full trace buffer to the system clipboard."),
                    click = function(element)
                        dmhub.CopyToClipboard(AI:TraceText())
                        gui.Tooltip("Copied")(element)
                    end,
                },
            },
        },

        gui.Panel{
            width = "100%",
            height = 440,
            flow = "vertical",
            vscroll = true,
            tmargin = 8,
            refreshtrace = function(element)
                RefreshTrace(element)
            end,
            create = function(element)
                RefreshTrace(element)
            end,
        },
    }

    return resultPanel
end

local DockablePanel = RawGlobal("DockablePanel")
if DockablePanel ~= nil then
    DockablePanel.Register{
        name = "Director Tactics",
        minHeight = 80,
        dmonly = true,
        content = function()
            return AI.CreatePanel()
        end,
    }

    DockablePanel.Register{
        name = "Director Tactics Trace",
        minHeight = 80,
        dmonly = true,
        content = function()
            return AI.CreateTracePanel()
        end,
    }
end
