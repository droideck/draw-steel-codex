-- MapImportPlus -- standalone test mod for the upcoming UVTT/Foundry import
-- improvements. Duplicates the Codex's MapImport.lua and the floor-processing
-- part of CreateMapDialog.lua so the new behavior (asset picker dialog,
-- secret-door handling, unrecognized-Foundry-walls checkbox) can be tested
-- on a Steam-installed Codex without modifying its files.
--
-- When the future PR lands in the Codex itself, this mod can be removed or
-- left alongside as a parallel entry point. Settings IDs intentionally match
-- the PR so your saved choices migrate transparently.
--
-- Entry: a "Map Import+" dockable panel registers a button that opens the
-- file-drop dialog and then the asset picker. Use scripts/fvtt_to_uvtt.py
-- to produce .dd2vtt files first, then drag them into the panel.

local mod = dmhub.GetModLoading()

----------------------------------------------------------------------------
-- Settings (same IDs as the future PR; if both the Codex PR and this mod
-- declare the setting, DMHub picks one declaration -- behavior is identical
-- because defaults match).
----------------------------------------------------------------------------

setting{
    id = "mapimport:wall_asset_id",
    description = "UVTT Import: Wall Material",
    editor = "text",
    default = "-MGADhKw0vw30yXNF2-e",
    storage = "preference",
}
setting{
    id = "mapimport:object_wall_asset_id",
    description = "UVTT Import: Object Occluder Wall Material",
    editor = "text",
    default = "eae7f3fe-d278-455c-853a-ac43f948c743",
    storage = "preference",
}
setting{
    id = "mapimport:terrain_wall_asset_id",
    description = "UVTT Import: Terrain Wall Material",
    editor = "text",
    default = "",
    storage = "preference",
}
setting{
    id = "mapimport:invisible_wall_asset_id",
    description = "UVTT Import: Invisible Wall Material",
    editor = "text",
    default = "",
    storage = "preference",
}
setting{
    id = "mapimport:transparent_window_wall_asset_id",
    description = "UVTT Import: Transparent Window Wall Material",
    editor = "text",
    default = "",
    storage = "preference",
}
setting{
    id = "mapimport:unrecognized_wall_asset_id",
    description = "UVTT Import: Unrecognized Wall Material",
    editor = "text",
    default = "-MGADhKw0vw30yXNF2-e",
    storage = "preference",
}
setting{
    id = "mapimport:door_object_id",
    description = "UVTT Import: Door Object",
    editor = "text",
    default = "-MfWx0b2IlyApLQwasYg",
    storage = "preference",
}
setting{
    id = "mapimport:window_object_id",
    description = "UVTT Import: Window Object",
    editor = "text",
    default = "-MDd3Knydcq2WsjStef2",
    storage = "preference",
}
setting{
    id = "mapimport:secret_door_object_id",
    description = "UVTT Import: Secret Door Object",
    editor = "text",
    default = "-MfWx0b2IlyApLQwasYg",
    storage = "preference",
}
setting{
    id = "mapimport:light_object_id",
    description = "UVTT Import: Light Object",
    editor = "text",
    default = "2339211c-c35a-4e0a-a5fa-79d2e446bd3b",
    storage = "preference",
}
setting{
    id = "mapimport:structural_wall_mode",
    description = "UVTT Import: Structural wall behavior",
    editor = "text",
    default = "wall",
    storage = "preference",
}
setting{
    id = "mapimport:object_wall_mode",
    description = "UVTT Import: Object occluder behavior",
    editor = "text",
    default = "wall",
    storage = "preference",
}
setting{
    id = "mapimport:terrain_wall_mode",
    description = "UVTT Import: Foundry terrain wall behavior",
    editor = "text",
    default = "wall",
    storage = "preference",
}
setting{
    id = "mapimport:invisible_wall_mode",
    description = "UVTT Import: Foundry invisible wall behavior",
    editor = "text",
    default = "",
    storage = "preference",
}
-- Legacy setting retained so existing saved movement-wall choices can be read.
setting{
    id = "mapimport:movement_wall_mode",
    description = "UVTT Import: Legacy Foundry invisible wall behavior",
    editor = "text",
    default = "wall",
    storage = "preference",
}
setting{
    id = "mapimport:unrecognized_wall_mode",
    description = "UVTT Import: Unrecognized wall behavior",
    editor = "text",
    default = "none",
    storage = "preference",
}
setting{
    id = "mapimport:door_mode",
    description = "UVTT Import: Door behavior",
    editor = "text",
    default = "asset",
    storage = "preference",
}
setting{
    id = "mapimport:window_mode",
    description = "UVTT Import: Window behavior",
    editor = "text",
    default = "asset",
    storage = "preference",
}
setting{
    id = "mapimport:secret_door_mode",
    description = "UVTT Import: Secret door behavior",
    editor = "text",
    default = "asset",
    storage = "preference",
}
setting{
    id = "mapimport:light_mode",
    description = "UVTT Import: Light behavior",
    editor = "text",
    default = "asset",
    storage = "preference",
}
-- Some door/window assets are modelled with their long axis along X (the
-- door is "horizontal" by default) while others have it along Y. The
-- standard placement formula rotates by +90 to fit the wall orientation,
-- which is correct for one convention and produces 90-degree-rotated
-- (perpendicular) doors for the other. If your chosen asset places
-- doors perpendicular to walls, flip this setting to 0.
setting{
    id = "mapimport:portal_rotation_offset",
    description = "UVTT Import: Portal rotation offset (90 or 0 if doors appear perpendicular)",
    editor = "text",
    default = 90,
    storage = "preference",
}
setting{
    id = "mapimport:portal_object_scale_multiplier",
    description = "UVTT Import: Door/window art scale multiplier",
    editor = "text",
    default = 1,
    storage = "preference",
}
setting{
    id = "mapimport:flip_foundry_terrain_walls",
    description = "UVTT Import: Flip Foundry terrain wall direction",
    editor = "check",
    default = false,
    storage = "preference",
}

----------------------------------------------------------------------------
-- Namespace. DMHub's sandbox throws on reads of uninitialized globals, so
-- the usual `X = X or {}` idiom is not safe here. Just assign.
----------------------------------------------------------------------------

MapImportPlus = {}

----------------------------------------------------------------------------
-- Helpers copied from CreateMapDialog.lua
----------------------------------------------------------------------------

local function isClockwise(polygon)
    local sum = 0
    local n = #polygon

    for i = 1, n do
        local j = (i % n) + 1
        sum = sum + (polygon[j].x - polygon[i].x) * (polygon[j].y + polygon[i].y)
    end

    return sum > 0
end

local function ComponentTypeMatches(value, componentType)
    if value == nil then
        return false
    end

    local text = tostring(value)
    return text == componentType or text == ("ObjectComponent" .. componentType)
end

local function ComponentField(component, field)
    local ok, value = pcall(function()
        return component[field]
    end)
    if ok then
        return value
    end

    return nil
end

local function ComponentMatches(component, key, componentType)
    if ComponentTypeMatches(key, componentType) then
        return true
    end

    return ComponentTypeMatches(ComponentField(component, "name"), componentType)
        or ComponentTypeMatches(ComponentField(component, "type"), componentType)
        or ComponentTypeMatches(ComponentField(component, "componentType"), componentType)
        or ComponentTypeMatches(ComponentField(component, "@class"), componentType)
end

local function ObjectNodeHasComponent(id, componentType)
    local node = id and assets:GetObjectNode(id)
    if node == nil or node.components == nil then
        return false
    end

    for key, component in pairs(node.components) do
        if ComponentMatches(component, key, componentType) then
            return true
        end
    end

    return false
end

----------------------------------------------------------------------------
-- ImportMapToFloorCo -- spawns walls, doors, secret doors, windows, lights
-- onto a floor based on the UVTT data. Adapted from CreateMapDialog.lua
-- with the asset-choices wiring and secret-door / unrecognized-walls
-- handling added.
----------------------------------------------------------------------------

MapImportPlus.ImportMapToFloorCo = function(info)
    if info == nil or info.floor == nil or info.primaryFloor == nil then
        return
    end

    local obj = info.floor:SpawnObjectLocal(info.objid)
    if obj == nil then
        return
    end

    obj.x = 0
    obj.y = 0
    obj:Upload()

    if type(info.uvttData) ~= "table" then
        return
    end

    local function pointsEqual(a, b)
        return a ~= nil and b ~= nil
            and tonumber(a.x) == tonumber(b.x)
            and tonumber(a.y) == tonumber(b.y)
    end

    local function gridSize(data)
        local result = 100
        if type(data.grid) == "table" then
            result = tonumber(data.grid.size) or 100
        elseif data.grid ~= nil then
            result = tonumber(data.grid) or 100
        end
        if result == 0 then
            result = 100
        end
        return result
    end

    local function safeColor(value, defaultValue)
        local text = tostring(value or defaultValue or "ffffff")
        if string.sub(text, 1, 1) ~= "#" then
            text = "#" .. text
        end

        local ok, result = pcall(function() return core.Color(text) end)
        if ok then
            return result
        end

        return core.Color("#ffffff")
    end

    local function portalObjectScale(nodeId, segmentLength)
        local node = nodeId and assets:GetObjectNode(nodeId)
        local imageId = node and (node.image or node.thumbnailId or node.imageId)
        local info = imageId and gui.TryGetImageDimensions(imageId)
        local width = info and tonumber(info.width)
        local height = info and tonumber(info.height)
        local ppu = info and tonumber(info.ppu)

        if width ~= nil and height ~= nil and ppu ~= nil and ppu > 0 then
            -- Object instance scale is absolute for the image. The asset node's
            -- default scale is already consumed by normal spawning behavior and
            -- would make imported portals too small if applied again here.
            local nativeLongAxisTiles = math.max(width, height) / ppu
            if nativeLongAxisTiles > 0 then
                return segmentLength / nativeLongAxisTiles
            end
        end

        return segmentLength
    end

    local maxcount = 0
    while (obj.area == nil or (obj.area.x1 == 0 and obj.area.x2 == 0)) and maxcount < 20 do
        coroutine.yield(0.1)
        maxcount = maxcount + 1
    end

    for i = 1, 60 do
        coroutine.yield(0.01)
    end

    local area = obj.area
    if area == nil then
        return
    end

    local data = info.uvttData
    local choices = info.assetChoices or {}
    local function importAsset(choiceValue, settingId, fallback)
        local value = choiceValue
        if value == nil or value == "" then
            value = dmhub.GetSettingValue(settingId)
        end
        if value == nil or value == "" then
            value = fallback
        end
        return value
    end

    local wallAsset       = choices.wallAssetId        or dmhub.GetSettingValue("mapimport:wall_asset_id")
    local objectWallAsset = choices.objectWallAssetId  or dmhub.GetSettingValue("mapimport:object_wall_asset_id")
    local terrainWallAsset = importAsset(choices.terrainWallAssetId, "mapimport:terrain_wall_asset_id", objectWallAsset)
    local invisibleWallAsset = importAsset(choices.invisibleWallAssetId, "mapimport:invisible_wall_asset_id", objectWallAsset)
    local transparentWindowWallAsset = importAsset(choices.transparentWindowWallAssetId, "mapimport:transparent_window_wall_asset_id", objectWallAsset)
    local unrecognizedWallAsset = choices.unrecognizedWallAssetId or dmhub.GetSettingValue("mapimport:unrecognized_wall_asset_id") or wallAsset
    local doornode        = choices.doorObjectId       or dmhub.GetSettingValue("mapimport:door_object_id")
    local windownode      = choices.windowObjectId     or dmhub.GetSettingValue("mapimport:window_object_id")
    local secretDoorNode  = choices.secretDoorObjectId or dmhub.GetSettingValue("mapimport:secret_door_object_id")
    local lightnode       = choices.lightObjectId      or dmhub.GetSettingValue("mapimport:light_object_id")
    local function normalizeMode(value, defaultValue, allowed)
        local mode = tostring(value or defaultValue)
        if allowed[mode] == true then
            return mode
        end
        return defaultValue
    end

    local function importMode(choiceKey, settingId, defaultValue, allowed)
        local mode = choices[choiceKey]
        if mode == nil then
            mode = dmhub.GetSettingValue(settingId)
        end
        return normalizeMode(mode, defaultValue, allowed)
    end

    local function legacyImportMode(choiceKey, legacyChoiceKey, settingId, legacySettingId, defaultValue, allowed)
        local mode = choices[choiceKey]
        if mode == nil then
            mode = choices[legacyChoiceKey]
        end
        if mode == nil then
            mode = dmhub.GetSettingValue(settingId)
        end
        if mode == nil or mode == "" then
            mode = dmhub.GetSettingValue(legacySettingId)
        end
        return normalizeMode(mode, defaultValue, allowed)
    end

    local function appendList(result, source)
        if type(source) == "table" then
            for _, item in ipairs(source) do
                result[#result+1] = item
            end
        end
    end

    local function mergedFoundryInvisibleWalls(data)
        local result = {}
        appendList(result, type(data) == "table" and data.foundry_invisible_walls or nil)
        appendList(result, type(data) == "table" and data.foundry_movement_walls or nil)
        return result
    end

    local function hasEntries(list)
        return type(list) == "table" and #list > 0
    end

    local function optionalList(list)
        if hasEntries(list) then
            return list
        end
        return nil
    end

    local wallModeAllowed = {wall = true, none = true}
    local assetModeAllowed = {asset = true, none = true}
    local windowModeAllowed = {asset = true, movement_wall = true, none = true}
    local structuralWallMode = importMode("structuralWallMode", "mapimport:structural_wall_mode", "wall", wallModeAllowed)
    local objectWallMode = importMode("objectWallMode", "mapimport:object_wall_mode", "wall", wallModeAllowed)
    local terrainWallMode = importMode("terrainWallMode", "mapimport:terrain_wall_mode", "wall", wallModeAllowed)
    local invisibleWallMode = legacyImportMode("invisibleWallMode", "movementWallMode", "mapimport:invisible_wall_mode", "mapimport:movement_wall_mode", "wall", wallModeAllowed)
    local unrecognizedWallMode = importMode("unrecognizedWallMode", "mapimport:unrecognized_wall_mode", "none", wallModeAllowed)
    local doorMode = importMode("doorMode", "mapimport:door_mode", "asset", assetModeAllowed)
    local windowMode = importMode("windowMode", "mapimport:window_mode", "asset", windowModeAllowed)
    local secretDoorMode = importMode("secretDoorMode", "mapimport:secret_door_mode", "asset", assetModeAllowed)
    local lightMode = importMode("lightMode", "mapimport:light_mode", "asset", assetModeAllowed)
    if choices.unrecognizedWallMode == nil and choices.includeUnrecognizedWalls ~= nil then
        unrecognizedWallMode = cond(choices.includeUnrecognizedWalls == true, "wall", "none")
    end
    local flipFoundryTerrainWalls = choices.flipFoundryTerrainWalls == true
    if choices.flipFoundryTerrainWalls == nil then
        flipFoundryTerrainWalls = dmhub.GetSettingValue("mapimport:flip_foundry_terrain_walls") == true
    end
    local nudgeX = tonumber(choices.alignmentOffsetX) or 0
    local nudgeY = tonumber(choices.alignmentOffsetY) or 0
    if nudgeX ~= 0 or nudgeY ~= 0 then
        area = {
            x1 = area.x1 + nudgeX,
            x2 = area.x2 + nudgeX,
            y1 = area.y1 - nudgeY,
            y2 = area.y2 - nudgeY,
        }
    end

    local function executeWalls(points, wallid, closed)
        if #points == 0 or wallid == nil or wallid == "" then
            return
        end

        info.primaryFloor:ExecutePolygonOperation{
            points = points,
            tileid = nil,
            wallid = wallid,
            erase = false,
            closed = closed,
        }
    end

    local function appendWorldPoint(points, p)
        if type(p) ~= "table" then
            return false
        end

        local x = tonumber(p.x)
        local y = tonumber(p.y)
        if x == nil or y == nil then
            return false
        end

        points[#points+1] = area.x1 + x
        points[#points+1] = area.y2 - y
        return true
    end

    local function copySegments(lineSet)
        local segments = {}
        if type(lineSet) ~= "table" then
            return segments
        end

        for _, segment in ipairs(lineSet) do
            if type(segment) == "table" and #segment >= 2 then
                local copy = {}
                for _, p in ipairs(segment) do
                    if type(p) == "table" and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil then
                        copy[#copy+1] = {x = tonumber(p.x), y = tonumber(p.y)}
                    end
                end
                if #copy >= 2 then
                    segments[#segments+1] = copy
                end
            end
        end

        return segments
    end

    local function processLineSet(lineSet, wallid, objectWalls)
        local segments = copySegments(lineSet)
        local segmentsDeleted = {}
        local changes = true
        local ncount = 0

        while (not objectWalls) and changes and ncount < 50 do
            changes = false
            ncount = ncount + 1

            for i, segment in ipairs(segments) do
                if segmentsDeleted[i] == nil then
                    for j, nextSegment in ipairs(segments) do
                        if i ~= j and segmentsDeleted[j] == nil and pointsEqual(segment[#segment], nextSegment[1]) then
                            for _, point in ipairs(nextSegment) do
                                segment[#segment+1] = point
                            end

                            segmentsDeleted[j] = true
                            changes = true
                        end
                    end
                end
            end
        end

        local pointsList = {}
        local objectPointsList = {}
        for i, seg in ipairs(segments) do
            if segmentsDeleted[i] == nil then
                local poly = seg
                if objectWalls and pointsEqual(seg[1], seg[#seg]) and not isClockwise(seg) then
                    poly = {}
                    for j = #seg, 1, -1 do
                        poly[#poly+1] = seg[j]
                    end
                end

                local isObject = objectWalls and pointsEqual(poly[1], poly[#poly])
                local points = {}
                for j, p in ipairs(poly) do
                    if (not isObject) or j ~= #poly then
                        appendWorldPoint(points, p)
                    end
                end

                if #points >= 4 then
                    if isObject then
                        objectPointsList[#objectPointsList+1] = points
                    else
                        pointsList[#pointsList+1] = points
                    end
                end
            end
        end

        executeWalls(pointsList, wallid, false)
        executeWalls(objectPointsList, wallid, true)
    end

    local function lineSetHasSegments(lineSet)
        if type(lineSet) ~= "table" then
            return false
        end

        for _, segment in ipairs(lineSet) do
            if type(segment) == "table" and #segment >= 2 then
                return true
            end
        end

        return false
    end

    local function splitOpenClosedLineSet(lineSet)
        local openLines = {}
        local closedLines = {}
        if type(lineSet) ~= "table" then
            return openLines, closedLines
        end

        for _, segment in ipairs(lineSet) do
            if type(segment) == "table" and #segment >= 2 then
                if pointsEqual(segment[1], segment[#segment]) then
                    closedLines[#closedLines+1] = segment
                else
                    openLines[#openLines+1] = segment
                end
            end
        end

        return openLines, closedLines
    end

    local function buildPolylines(walls)
        local out = {}
        if type(walls) ~= "table" then
            return out
        end

        for _, wall in ipairs(walls) do
            if type(wall) == "table" and type(wall.points) == "table" and #wall.points >= 2 then
                local pts = {}
                for _, p in ipairs(wall.points) do
                    appendWorldPoint(pts, p)
                end
                if #pts >= 4 then
                    out[#out+1] = pts
                end
            end
        end

        return out
    end

    local function reverseLine(line)
        local result = {}
        for i = #line, 1, -1 do
            result[#result+1] = line[i]
        end
        return result
    end

    local function buildWallLineSet(walls)
        local out = {}
        if type(walls) ~= "table" then
            return out
        end

        for _, wall in ipairs(walls) do
            local sourcePoints = type(wall) == "table" and wall.points or nil
            if type(sourcePoints) == "table" and #sourcePoints >= 2 then
                local pts = {}
                for _, p in ipairs(sourcePoints) do
                    if type(p) == "table" and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil then
                        pts[#pts+1] = {x = tonumber(p.x), y = tonumber(p.y)}
                    end
                end
                if #pts >= 2 then
                    out[#out+1] = pts
                end
            end
        end

        return out
    end

    local function foundrySenseName(value)
        value = tonumber(value)
        if value == 0 then return "None" end
        if value == 10 then return "Limited" end
        if value == 20 then return "Normal" end
        if value == 30 then return "Proximity" end
        if value == 40 then return "Distance" end
        return tostring(value)
    end

    local function foundryDoorName(value)
        value = tonumber(value)
        if value == 0 then return "Wall" end
        if value == 1 then return "Door" end
        if value == 2 then return "SecretDoor" end
        return tostring(value)
    end

    local function foundryDirectionName(value)
        value = tonumber(value)
        if value == 0 then return "Both" end
        if value == 1 then return "Left" end
        if value == 2 then return "Right" end
        return tostring(value)
    end

    local function foundryDoorStateName(value)
        value = tonumber(value)
        if value == 0 then return "Closed" end
        if value == 1 then return "Open" end
        if value == 2 then return "Locked" end
        return tostring(value)
    end

    local function foundryWallFlags(wall)
        local door = tonumber(wall.door) or 0
        local sight = tonumber(wall.sight) or 20
        local move = tonumber(wall.move) or 20
        local light = tonumber(wall.light) or 20
        local sound = tonumber(wall.sound) or 20
        local dir = tonumber(wall.dir) or 0
        local ds = tonumber(wall.ds) or 0
        local threshold = type(wall.threshold) == "table" and wall.threshold or nil

        local sense = {
            door = door,
            door_name = foundryDoorName(door),
            sight = sight,
            sight_name = foundrySenseName(sight),
            move = move,
            move_name = foundrySenseName(move),
            light = light,
            light_name = foundrySenseName(light),
            sound = sound,
            sound_name = foundrySenseName(sound),
        }
        if threshold ~= nil then
            sense.threshold = threshold
        end

        return {
            foundry_direction = dir,
            foundry_direction_name = foundryDirectionName(dir),
            foundry_door_state = ds,
            foundry_door_state_name = foundryDoorStateName(ds),
            foundry_sense = sense,
        }
    end

    local function foundryWallEntry(p1, p2, wall)
        local threshold = type(wall.threshold) == "table" and wall.threshold or nil
        local entry = {
            points = {p1, p2},
            sense = {
                door = foundryDoorName(tonumber(wall.door) or 0),
                sight = foundrySenseName(tonumber(wall.sight) or 20),
                move = foundrySenseName(tonumber(wall.move) or 20),
                light = foundrySenseName(tonumber(wall.light) or 20),
                sound = foundrySenseName(tonumber(wall.sound) or 20),
            },
            flags = foundryWallFlags(wall),
        }
        if threshold ~= nil then
            entry.threshold = threshold
        end
        return entry
    end

    local function foundryPortal(p1, p2, wall, closed, secret)
        local flags = foundryWallFlags(wall)
        local portal = {
            bounds = {p1, p2},
            closed = closed,
            flags = flags,
            foundryDoorState = flags.foundry_door_state,
            foundryDoorStateName = flags.foundry_door_state_name,
            foundryDirection = flags.foundry_direction,
            foundryDirectionName = flags.foundry_direction_name,
        }
        if secret == true then
            portal.secret = true
        end
        return portal
    end

    local function processFoundryTerrainWalls(walls, wallid, flipOpen)
        local segments = buildWallLineSet(walls)
        local segmentsDeleted = {}
        local changes = true
        local ncount = 0

        while changes and ncount < 50 do
            changes = false
            ncount = ncount + 1

            for i, segment in ipairs(segments) do
                if segmentsDeleted[i] == nil then
                    for j, nextSegment in ipairs(segments) do
                        if i ~= j and segmentsDeleted[j] == nil and pointsEqual(segment[#segment], nextSegment[1]) then
                            for _, point in ipairs(nextSegment) do
                                segment[#segment+1] = point
                            end

                            segmentsDeleted[j] = true
                            changes = true
                        end
                    end
                end
            end
        end

        local pointsList = {}
        local closedPointsList = {}
        for i, seg in ipairs(segments) do
            if segmentsDeleted[i] == nil then
                local poly = seg
                local closed = pointsEqual(poly[1], poly[#poly])
                if closed and not isClockwise(poly) then
                    poly = reverseLine(poly)
                elseif (not closed) and flipOpen then
                    poly = reverseLine(poly)
                end

                local points = {}
                for j, p in ipairs(poly) do
                    if (not closed) or j ~= #poly then
                        appendWorldPoint(points, p)
                    end
                end

                if #points >= 4 then
                    if closed then
                        closedPointsList[#closedPointsList+1] = points
                    else
                        pointsList[#pointsList+1] = points
                    end
                end
            end
        end

        executeWalls(pointsList, wallid, false)
        executeWalls(closedPointsList, wallid, true)
    end

    local function readPortalSegment(portal)
        local bounds = type(portal) == "table" and portal.bounds or nil
        if type(bounds) ~= "table" or #bounds ~= 2 then
            return nil
        end

        local b1 = type(bounds[1]) == "table" and bounds[1] or nil
        local b2 = type(bounds[2]) == "table" and bounds[2] or nil
        local x1 = b1 and tonumber(b1.x) or nil
        local y1 = b1 and tonumber(b1.y) or nil
        local x2 = b2 and tonumber(b2.x) or nil
        local y2 = b2 and tonumber(b2.y) or nil

        if x1 == nil or y1 == nil or x2 == nil or y2 == nil then
            return nil
        end

        local dx = x2 - x1
        local dy = y2 - y1
        return {
            portal = portal,
            x1 = x1,
            y1 = y1,
            x2 = x2,
            y2 = y2,
            closed = portal.closed == true,
            secret = portal.secret == true,
            length = math.sqrt(dx*dx + dy*dy),
        }
    end

    local function endpointsEqual(ax, ay, bx, by)
        return math.abs(ax - bx) <= 0.0001 and math.abs(ay - by) <= 0.0001
    end

    local function portalSegmentsTouch(a, b)
        return endpointsEqual(a.x1, a.y1, b.x1, b.y1)
            or endpointsEqual(a.x1, a.y1, b.x2, b.y2)
            or endpointsEqual(a.x2, a.y2, b.x1, b.y1)
            or endpointsEqual(a.x2, a.y2, b.x2, b.y2)
    end

    local function collapsedPortalFromGroup(group)
        local minX = group[1].x1
        local maxX = group[1].x1
        local minY = group[1].y1
        local maxY = group[1].y1
        local best = group[1]
        local closed = false
        local secret = false

        for _, segment in ipairs(group) do
            minX = math.min(minX, segment.x1, segment.x2)
            maxX = math.max(maxX, segment.x1, segment.x2)
            minY = math.min(minY, segment.y1, segment.y2)
            maxY = math.max(maxY, segment.y1, segment.y2)
            closed = closed or segment.closed
            secret = secret or segment.secret
            if segment.length > best.length then
                best = segment
            end
        end

        local centerX = (minX + maxX) / 2
        local centerY = (minY + maxY) / 2
        local width = maxX - minX
        local height = maxY - minY
        local p1, p2

        if width >= height then
            if best.x1 <= best.x2 then
                p1 = {x = minX, y = centerY}
                p2 = {x = maxX, y = centerY}
            else
                p1 = {x = maxX, y = centerY}
                p2 = {x = minX, y = centerY}
            end
        else
            if best.y1 <= best.y2 then
                p1 = {x = centerX, y = minY}
                p2 = {x = centerX, y = maxY}
            else
                p1 = {x = centerX, y = maxY}
                p2 = {x = centerX, y = minY}
            end
        end

        return {
            bounds = {p1, p2},
            closed = closed,
            secret = secret,
        }
    end

    local function collapseConnectedPortals(portalList)
        local segments = {}
        if type(portalList) ~= "table" then
            return segments
        end

        for _, portal in ipairs(portalList) do
            local segment = readPortalSegment(portal)
            if segment ~= nil then
                segments[#segments+1] = segment
            end
        end

        local result = {}
        local used = {}
        for i, segment in ipairs(segments) do
            if used[i] == nil then
                local group = {segment}
                used[i] = true

                local changed = true
                while changed do
                    changed = false
                    for j, candidate in ipairs(segments) do
                        if used[j] == nil and candidate.closed == segment.closed and candidate.secret == segment.secret then
                            for _, member in ipairs(group) do
                                if portalSegmentsTouch(member, candidate) then
                                    group[#group+1] = candidate
                                    used[j] = true
                                    changed = true
                                    break
                                end
                            end
                        end
                    end
                end

                if #group >= 3 then
                    result[#result+1] = collapsedPortalFromGroup(group)
                else
                    for _, candidate in ipairs(group) do
                        result[#result+1] = candidate.portal
                    end
                end
            end
        end

        return result
    end

    local structuralLines = data.line_of_sight
    local objectLines = data.objects_line_of_sight
    local portals = type(data.portals) == "table" and data.portals or nil
    local foundryTerrainWalls = type(data.foundry_terrain_walls) == "table" and data.foundry_terrain_walls or nil
    local foundryInvisibleWalls = optionalList(mergedFoundryInvisibleWalls(data))
    local foundryUnrecognizedWalls = type(data.foundry_unrecognized_walls) == "table" and data.foundry_unrecognized_walls or nil
    local convertedFromFoundry = false
    local objectOnlyLineOfSight = false

    if type(structuralLines) ~= "table" and type(data.walls) == "table" then
        convertedFromFoundry = true
        structuralLines = {}
        portals = {}
        foundryTerrainWalls = {}
        foundryInvisibleWalls = {}
        foundryUnrecognizedWalls = {}

        local foundryGrid = gridSize(data)
        for _, wall in ipairs(data.walls) do
            local points = type(wall) == "table" and wall.c or nil
            if type(points) == "table" and #points == 4 then
                local x1 = tonumber(points[1])
                local y1 = tonumber(points[2])
                local x2 = tonumber(points[3])
                local y2 = tonumber(points[4])
                if x1 ~= nil and y1 ~= nil and x2 ~= nil and y2 ~= nil then
                    local p1 = {x = x1 / foundryGrid, y = y1 / foundryGrid}
                    local p2 = {x = x2 / foundryGrid, y = y2 / foundryGrid}
                    local door = tonumber(wall.door) or 0
                    local move = tonumber(wall.move) or 20
                    local sight = tonumber(wall.sight) or 20
                    local light = tonumber(wall.light) or 20
                    local dir = tonumber(wall.dir) or 0
                    local threshold = type(wall.threshold) == "table" and wall.threshold or nil
                    local windowLike = threshold ~= nil
                        and threshold.light ~= nil and threshold.sight ~= nil
                        and light ~= move and sight ~= move

                    if (door == 0 or door == 2) and windowLike then
                        portals[#portals+1] = foundryPortal(p1, p2, wall, false, false)
                    elseif door == 1 then
                        portals[#portals+1] = foundryPortal(p1, p2, wall, true, false)
                    elseif door == 2 then
                        portals[#portals+1] = foundryPortal(p1, p2, wall, true, true)
                    elseif door ~= 0 or dir ~= 0 then
                        foundryUnrecognizedWalls[#foundryUnrecognizedWalls+1] = foundryWallEntry(p1, p2, wall)
                    elseif door == 0 and sight == 20 and move == 20 then
                        structuralLines[#structuralLines+1] = {p1, p2}
                    elseif door == 0 and sight == 10 and move == 20 then
                        foundryTerrainWalls[#foundryTerrainWalls+1] = foundryWallEntry(p1, p2, wall)
                    elseif door == 0 and sight == 0 and move == 20 then
                        foundryInvisibleWalls[#foundryInvisibleWalls+1] = foundryWallEntry(p1, p2, wall)
                    else
                        foundryUnrecognizedWalls[#foundryUnrecognizedWalls+1] = foundryWallEntry(p1, p2, wall)
                    end
                end
            end
        end
    end

    if (not convertedFromFoundry)
            and (not lineSetHasSegments(structuralLines))
            and lineSetHasSegments(objectLines) then
        objectOnlyLineOfSight = true
        structuralLines, objectLines = splitOpenClosedLineSet(objectLines)
    end

    if structuralWallMode == "wall" then
        processLineSet(structuralLines, wallAsset, false)
    end
    if objectWallMode == "wall" then
        processLineSet(objectLines, objectWallAsset, true)
    end
    if terrainWallMode == "wall" then
        processFoundryTerrainWalls(foundryTerrainWalls, terrainWallAsset, flipFoundryTerrainWalls)
    end
    if invisibleWallMode == "wall" then
        processFoundryTerrainWalls(foundryInvisibleWalls, invisibleWallAsset, flipFoundryTerrainWalls)
    end
    if unrecognizedWallMode == "wall" then
        executeWalls(buildPolylines(foundryUnrecognizedWalls), unrecognizedWallAsset, false)
    end

    if portals ~= nil then
        local portalsToSpawn = portals
        if objectOnlyLineOfSight then
            portalsToSpawn = collapseConnectedPortals(portals)
        end
        for _, portal in ipairs(portalsToSpawn) do
            local bounds = type(portal) == "table" and portal.bounds or nil
            if type(bounds) == "table" and #bounds == 2 then
                local b1 = type(bounds[1]) == "table" and bounds[1] or nil
                local b2 = type(bounds[2]) == "table" and bounds[2] or nil
                local x1 = b1 and tonumber(b1.x) or nil
                local y1 = b1 and tonumber(b1.y) or nil
                local x2 = b2 and tonumber(b2.x) or nil
                local y2 = b2 and tonumber(b2.y) or nil

                if x1 ~= nil and y1 ~= nil and x2 ~= nil and y2 ~= nil then
                    local points = {area.x1 + x1, area.y2 - y1, area.x1 + x2, area.y2 - y2}
                    local portalKind = "window"
                    if portal.closed then
                        portalKind = cond(portal.secret == true, "secret", "door")
                    end
                    local portalMode = windowMode
                    if portalKind == "door" then
                        portalMode = doorMode
                    elseif portalKind == "secret" then
                        portalMode = secretDoorMode
                    end

                    if portalMode == "asset" and not convertedFromFoundry and not objectOnlyLineOfSight then
                        executeWalls({points}, wallAsset, false)
                    elseif portalKind == "window" and portalMode == "movement_wall" then
                        executeWalls({points}, transparentWindowWallAsset, false)
                    end

                    local nodeId = windownode
                    if portal.closed then
                        nodeId = cond(portal.secret == true, secretDoorNode, doornode)
                    end

                    if portalMode == "asset" and nodeId ~= nil and nodeId ~= "" then
                        local portalObj = info.primaryFloor:SpawnObjectLocal(nodeId)
                        if portalObj ~= nil then
                            local flags = type(portal.flags) == "table" and portal.flags or nil
                            local foundryDoorState = portal.foundryDoorState or (flags and flags.foundry_door_state)
                            -- TODO: Apply Foundry open/locked door state when DMHub exposes a door-state API.
                            local delta = core.Vector2(x2 - x1, y1 - y2)
                            portalObj.x = area.x1 + ((x1 + x2) / 2)
                            portalObj.y = area.y2 - ((y1 + y2) / 2)
                            portalObj.rotation = delta.angle + (tonumber(dmhub.GetSettingValue("mapimport:portal_rotation_offset")) or 90)
                            portalObj.scale = portalObjectScale(nodeId, delta.length)
                            portalObj:Upload()
                        end
                    end
                end
            end
        end
    end

    if lightMode == "asset" and type(data.lights) == "table" and ObjectNodeHasComponent(lightnode, "Light") then
        local foundryGrid = gridSize(data)
        for _, light in ipairs(data.lights) do
            if type(light) == "table" then
                local x, y, radius, intensity, color, shadows
                if type(light.position) == "table" then
                    x = tonumber(light.position.x)
                    y = tonumber(light.position.y)
                    radius = tonumber(light.range) or 0
                    intensity = ((tonumber(light.intensity) or 1) * 0.5) ^ 0.5
                    color = safeColor(light.color, "ffffff")
                    shadows = light.shadows
                    if shadows == nil then
                        shadows = true
                    end
                else
                    x = tonumber(light.x) and (tonumber(light.x) / foundryGrid) or nil
                    y = tonumber(light.y) and (tonumber(light.y) / foundryGrid) or nil
                    radius = tonumber(light.dim) or tonumber(light.bright) or 0
                    intensity = (tonumber(light.tintAlpha) or 0.1) * 3
                    color = safeColor(light.tintColor, "#ffffff")
                    shadows = true
                end

                if x ~= nil and y ~= nil then
                    local lightObj = info.primaryFloor:SpawnObjectLocal(lightnode)
                    local component = lightObj and lightObj:GetComponent("Light")
                    if component ~= nil then
                        lightObj.x = area.x1 + x
                        lightObj.y = area.y2 - y
                        component:SetProperty("radius", radius)
                        component:SetProperty("intensity", intensity)
                        component:SetProperty("castsShadows", shadows)
                        component:SetProperty("color", color)
                        lightObj:Upload()
                    end
                end
            end
        end
    end

    if type(data.environment) == "table" then
        if data.environment.ambient_light ~= nil then
            dmhub.SetSettingValue("undergroundillumination", safeColor(data.environment.ambient_light, "ffffff").value)
        else
            dmhub.SetSettingValue("undergroundillumination", 1.0)
        end
    end
end

----------------------------------------------------------------------------
-- FinishMapImport -- creates the map, switches to it, and dispatches the
-- floor processing through MapImportPlus.ImportMapToFloorCo (not the
-- Codex's mod.shared.ImportMapToFloorCo, which lives in a different mod
-- and is not reachable from here).
----------------------------------------------------------------------------

MapImportPlus.FinishMapImport = function(mapName, info)
    local floors = {}

    for i, objid in ipairs(info.objids) do
        floors[#floors+1] = {
            description = cond(#info.objids == 1, "Main Floor", string.format("Floor %d", i)),
            layerDescription = "Map Layer",
            parentFloor = #floors+1,
        }

        floors[#floors+1] = {
            description = cond(#info.objids == 1, "Main Floor", string.format("Floor %d", i)),
        }
    end


    local guid = game.CreateMap{
        description = mapName,
        groundLevel = #floors,
        floors = floors,
    }
    dmhub.Coroutine(function()
        while game.GetMap(guid) == nil do
            coroutine.yield(0.05)
        end

        local w = math.floor(info.width + 0.5)
        local h = math.floor(info.height + 0.5)

        local MAX_DIM = 2000
        if w > MAX_DIM or h > MAX_DIM then
            w = math.min(w, MAX_DIM)
            h = math.min(h, MAX_DIM)
        end

        local map = game.GetMap(guid)
        map.description = mapName
        map.dimensions = {
            x1 = -math.ceil(w / 2) + 1,
            y1 = -math.ceil(h / 2) + 1,
            x2 = math.floor(w / 2),
            y2 = math.floor(h / 2),
        }
        map:Upload()

        map:Travel()

        while game.currentMapId ~= guid do
            coroutine.yield(0.05)
        end

        --try to wait a bit to make sure we are synced on the new map.
        for i = 1, 120 do
            coroutine.yield(0.01)
        end

        local settings = info.mapSettings
        if settings ~= nil then
            for k, v in pairs(settings) do
                dmhub.SetSettingValue(k, v)
            end
        end

        local mapFloors = game.currentMap.floorsWithoutLayers

        for i, floor in ipairs(mapFloors) do
            local uvttData = nil
            if info.uvttData ~= nil then
                uvttData = info.uvttData[i]
            end

            --send to the map layer instead of the primary floor.
            local targetFloor = floor
            for _, layer in ipairs(game.currentMap.floors) do
                if layer.parentFloor == floor.floorid then
                    targetFloor = layer
                    break
                end
            end

            MapImportPlus.ImportMapToFloorCo{
                objid = info.objids[i],
                floor = targetFloor,
                primaryFloor = floor,
                uvttData = uvttData,
                assetChoices = info.assetChoices,
            }
        end

    end)
end

----------------------------------------------------------------------------
-- Asset picker helpers
----------------------------------------------------------------------------

local function CountImportFeatures(uvttData)
    local counts = {
        structural = 0,
        object = 0,
        terrain = 0,
        invisible = 0,
        unrecognized = 0,
        doors = 0,
        windows = 0,
        secretDoors = 0,
        lights = 0,
    }
    if uvttData == nil then return counts end

    local function countSegments(lineSet)
        local n = 0
        if type(lineSet) ~= "table" then
            return 0
        end
        for _, segment in ipairs(lineSet) do
            if type(segment) == "table" and #segment >= 2 then
                n = n + 1
            end
        end
        return n
    end

    local function addOne(d)
        if type(d) ~= "table" then return end
        counts.structural = counts.structural + countSegments(d.line_of_sight)
        counts.object = counts.object + countSegments(d.objects_line_of_sight)
        if type(d.portals) == "table" then
            for _, portal in ipairs(d.portals) do
                if type(portal) == "table" then
                    if portal.closed == true then
                        if portal.secret == true then
                            counts.secretDoors = counts.secretDoors + 1
                        else
                            counts.doors = counts.doors + 1
                        end
                    else
                        counts.windows = counts.windows + 1
                    end
                end
            end
        end
        if type(d.lights) == "table" then
            counts.lights = counts.lights + #d.lights
        end
        if d.foundry_terrain_walls ~= nil then
            counts.terrain = counts.terrain + #d.foundry_terrain_walls
        end
        if d.foundry_invisible_walls ~= nil then
            counts.invisible = counts.invisible + #d.foundry_invisible_walls
        end
        if d.foundry_movement_walls ~= nil then
            counts.invisible = counts.invisible + #d.foundry_movement_walls
        end
        if d.foundry_unrecognized_walls ~= nil then
            counts.unrecognized = counts.unrecognized + #d.foundry_unrecognized_walls
        end

        if type(d.line_of_sight) ~= "table" and type(d.walls) == "table" then
            for _, wall in ipairs(d.walls) do
                if type(wall) == "table" then
                    local points = wall.c
                    if type(points) == "table" and #points == 4 then
                        local door = tonumber(wall.door) or 0
                        local move = tonumber(wall.move) or 20
                        local sight = tonumber(wall.sight) or 20
                        local light = tonumber(wall.light) or 20
                        local dir = tonumber(wall.dir) or 0
                        local threshold = type(wall.threshold) == "table" and wall.threshold or nil
                        local windowLike = threshold ~= nil
                            and threshold.light ~= nil and threshold.sight ~= nil
                            and light ~= move and sight ~= move

                        if (door == 0 or door == 2) and windowLike then
                            counts.windows = counts.windows + 1
                        elseif door == 1 then
                            counts.doors = counts.doors + 1
                        elseif door == 2 then
                            counts.secretDoors = counts.secretDoors + 1
                        elseif door == 0 and dir ~= 0 then
                            counts.unrecognized = counts.unrecognized + 1
                        elseif door ~= 0 and door ~= 1 and door ~= 2 then
                            counts.unrecognized = counts.unrecognized + 1
                        elseif door == 0 and sight == 20 and move == 20 then
                            counts.structural = counts.structural + 1
                        elseif door == 0 and sight == 10 and move == 20 then
                            counts.terrain = counts.terrain + 1
                        elseif door == 0 and sight == 0 and move == 20 then
                            counts.invisible = counts.invisible + 1
                        elseif door == 0 then
                            counts.unrecognized = counts.unrecognized + 1
                        end
                    end
                end
            end
        end
    end
    addOne(uvttData)
    if type(uvttData) == "table" then
        for _, d in ipairs(uvttData) do
            addOne(d)
        end
    end
    return counts
end

local PICKER_LIMIT = 20
local PICKER_UI = {
    dialogWidth = 760,
    dialogHeight = 720,
    tooltipWidth = 304,
    tooltipContentWidth = 280,
    tooltipWallWidth = 240,
    tooltipWallHeight = 60,
    tooltipObjectSize = 220,
    tileLabelLength = 28,
    summaryLength = 44,
    summaryWidth = 330,
    headerLabelWidth = 190,
    headerHeight = 42,
    searchWidth = 320,
    inputWidth = 80,
    inputHeight = 24,
    thumbnail = {
        square = {tileW = 96, tileH = 120, imageW = 80, imageH = 80},
        wide = {tileW = 160, tileH = 80, imageW = 144, imageH = 44},
    },
    preview = {
        square = {outerW = 38, outerH = 38, innerW = 30, innerH = 30},
        wide = {outerW = 86, outerH = 34, innerW = 74, innerH = 22},
    },
}

local function ShortLabel(s, maxLen)
    s = tostring(s or "")
    s = string.gsub(s, "[\r\n]+", " ")
    if #s <= maxLen then return s end
    return string.sub(s, 1, maxLen - 3) .. "..."
end

-- Keep search focused on the asset title/header rather than long item lore.
local SEARCH_HEAD_LEN = 60

local function ObjectBehaviorText(node)
    if node == nil or node.components == nil then return nil end
    local parts = {}
    local seen = {}
    for _,component in pairs(node.components) do
        local text = component.behaviorDescription
        if text ~= nil and text ~= "" and not seen[text] then
            parts[#parts+1] = text
            seen[text] = true
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "\n")
end

local function ObjectItemFromNode(id, node, suffix)
    local baseLabel = (node and (node.description or node.name)) or id
    return {
        id = id,
        label = (suffix and (baseLabel .. " " .. suffix)) or baseLabel,
        kind = "object",
        image = node and node.image,
        thumbnailId = node and node.thumbnailId,
        description = node and node.description,
        behavior = ObjectBehaviorText(node),
        artist = node and node.artist,
        hue = node and node.hue,
        saturation = node and node.saturation,
        brightness = node and node.brightness,
    }
end

local function SearchObjectItems(query, currentId)
    local q = string.lower(query or "")
    local items = {}
    local seen = {}
    local totalMatched = 0

    local function addCurrent()
        if currentId == nil or currentId == "" or seen[currentId] then return end
        local node = assets:GetObjectNode(currentId)
        items[#items+1] = ObjectItemFromNode(currentId, node, "(current)")
        seen[currentId] = true
    end

    addCurrent()

    local function record(id, v)
        if id == nil or seen[id] then return end
        totalMatched = totalMatched + 1
        if #items < PICKER_LIMIT then
            items[#items+1] = ObjectItemFromNode(id, v)
        end
        seen[id] = true
    end

    if q ~= "" then
        local kwObjs = assets:GetObjectsWithKeyword(q)
        if kwObjs ~= nil then
            for _,v in ipairs(kwObjs) do
                record(v.id, v)
            end
        end

        if assets.allObjects ~= nil then
            for id,v in pairs(assets.allObjects) do
                if v ~= nil and not v.isfolder and not seen[id] then
                    local head = string.lower(string.sub(
                        tostring(v.description or v.name or id), 1, SEARCH_HEAD_LEN))
                    if string.find(head, q, 1, true) ~= nil then
                        record(id, v)
                    end
                end
            end
        end
    elseif assets.allObjects ~= nil then
        for id,v in pairs(assets.allObjects) do
            if v ~= nil and not v.isfolder then
                record(id, v)
            end
        end
    end

    return items, totalMatched
end

-- TODO: Replace this raw-field summary with an engine-provided WallAsset
-- behavior description when one is exposed.
local function WallBehaviorText(wall)
    if wall == nil then return nil end
    local parts = {}
    local fields = {
        "invisible",
        "visionOneWay",
        "visionWidth",
        "movementOneWay",
        "occludesVision",
        "occludesLight",
        "blocksMovement",
        "blocksForcedMovement",
        "blocksFlying",
        "cover",
        "soundOcclusion",
        "wallHeight",
        "climbable",
        "solidity",
        "breakStamina",
        "rubbleKeyword",
        "rubbleTerrainId",
        "replacementWallId",
    }

    for _, field in ipairs(fields) do
        local value = wall[field]
        if value ~= nil then
            parts[#parts+1] = string.format("<b>%s</b>: %s", field, tostring(value))
        end
    end

    if #parts == 0 then return nil end
    return table.concat(parts, "\n")
end

local function WallItemFromAsset(id, wall, suffix)
    local baseLabel = (wall and wall.description) or id
    return {
        id = id,
        label = (suffix and (baseLabel .. " " .. suffix)) or baseLabel,
        kind = "wall",
        tint = wall and wall.tint,
        hueshift = wall and wall.hueshift,
        saturation = wall and wall.saturation,
        brightness = wall and wall.brightness,
        description = wall and wall.description,
        behavior = WallBehaviorText(wall),
        artist = wall and wall.artist,
    }
end

local function SearchWallItems(query, currentId)
    local q = string.lower(query or "")
    local items = {}
    local seen = {}
    local totalMatched = 0

    local function addCurrent()
        if currentId == nil or currentId == "" or seen[currentId] then return end
        local wall = assets.walls and assets.walls[currentId]
        items[#items+1] = WallItemFromAsset(currentId, wall, "(current)")
        seen[currentId] = true
    end

    addCurrent()

    if assets.walls ~= nil then
        for id,wall in pairs(assets.walls) do
            if not seen[id] then
                local label = string.lower(tostring(wall.description or id))
                if q == "" or string.find(label, q, 1, true) ~= nil then
                    totalMatched = totalMatched + 1
                    if #items < PICKER_LIMIT then
                        items[#items+1] = WallItemFromAsset(id, wall)
                    end
                    seen[id] = true
                end
            end
        end
    end

    return items, totalMatched
end

local function ValidateMapAssetChoices(choices)
    local counts = choices.counts or {}
    local wallModeAllowed = {wall = true, none = true}
    local assetModeAllowed = {asset = true, none = true}
    local windowModeAllowed = {asset = true, movement_wall = true, none = true}
    local function validMode(value, defaultValue, allowed)
        local mode = tostring(value or "")
        if allowed[mode] == true then
            return mode
        end
        return defaultValue
    end
    local function legacyMode(value, legacyValue, defaultValue, allowed)
        if value ~= nil and value ~= "" then
            return validMode(value, defaultValue, allowed)
        end
        return validMode(legacyValue, defaultValue, allowed)
    end
    local structuralWallMode = validMode(choices.structuralWallMode, "wall", wallModeAllowed)
    local objectWallMode = validMode(choices.objectWallMode, "wall", wallModeAllowed)
    local terrainWallMode = validMode(choices.terrainWallMode, "wall", wallModeAllowed)
    local invisibleWallMode = legacyMode(choices.invisibleWallMode, choices.movementWallMode, "wall", wallModeAllowed)
    local unrecognizedWallMode = validMode(choices.unrecognizedWallMode, cond(choices.includeUnrecognizedWalls == true, "wall", "none"), wallModeAllowed)
    local doorMode = validMode(choices.doorMode, "asset", assetModeAllowed)
    local windowMode = validMode(choices.windowMode, "asset", windowModeAllowed)
    local secretDoorMode = validMode(choices.secretDoorMode, "asset", assetModeAllowed)
    local lightMode = validMode(choices.lightMode, "asset", assetModeAllowed)
    local invisibleCount = counts.invisible or counts.movement or 0
    local terrainWallAssetId = choices.terrainWallAssetId or choices.objectWallAssetId
    local invisibleWallAssetId = choices.invisibleWallAssetId or choices.objectWallAssetId
    local transparentWindowWallAssetId = choices.transparentWindowWallAssetId or choices.objectWallAssetId
    if terrainWallAssetId == "" then terrainWallAssetId = choices.objectWallAssetId end
    if invisibleWallAssetId == "" then invisibleWallAssetId = choices.objectWallAssetId end
    if transparentWindowWallAssetId == "" then transparentWindowWallAssetId = choices.objectWallAssetId end

    local needsWallAsset =
        ((counts.structural or 0) > 0 and structuralWallMode == "wall")
        or ((counts.doors or 0) > 0 and doorMode == "asset")
        or ((counts.windows or 0) > 0 and windowMode == "asset")
        or ((counts.secretDoors or 0) > 0 and secretDoorMode == "asset")
    local needsObjectWallAsset =
        ((counts.object or 0) > 0 and objectWallMode == "wall")
    local needsTerrainWallAsset = ((counts.terrain or 0) > 0 and terrainWallMode == "wall")
    local needsInvisibleWallAsset = (invisibleCount > 0 and invisibleWallMode == "wall")
    local needsTransparentWindowWallAsset = ((counts.windows or 0) > 0 and windowMode == "movement_wall")

    if needsWallAsset and (assets.walls == nil or assets.walls[choices.wallAssetId] == nil) then
        return "The selected wall material is missing. Pick another wall material before continuing.", "wall"
    end
    if needsObjectWallAsset and (assets.walls == nil or assets.walls[choices.objectWallAssetId] == nil) then
        return "The selected object occluder material is missing. Pick another object occluder material before continuing.", "objectWall"
    end
    if needsTerrainWallAsset and (assets.walls == nil or assets.walls[terrainWallAssetId] == nil) then
        return "The selected terrain wall material is missing. Pick another terrain wall material before continuing.", "terrain"
    end
    if needsInvisibleWallAsset and (assets.walls == nil or assets.walls[invisibleWallAssetId] == nil) then
        return "The selected invisible wall material is missing. Pick another invisible wall material before continuing.", "invisible"
    end
    if needsTransparentWindowWallAsset and (assets.walls == nil or assets.walls[transparentWindowWallAssetId] == nil) then
        return "The selected transparent window wall material is missing. Pick another transparent window wall material before continuing.", "window"
    end
    if (counts.unrecognized or 0) > 0 and unrecognizedWallMode == "wall" and (assets.walls == nil or assets.walls[choices.unrecognizedWallAssetId] == nil) then
        return "The selected unrecognized wall material is missing. Pick another unrecognized wall material before continuing.", "unrecognizedWall"
    end
    if (counts.doors or 0) > 0 and doorMode == "asset" and (choices.doorObjectId == nil or assets:GetObjectNode(choices.doorObjectId) == nil) then
        return "The selected door object is missing. Pick another door before continuing.", "door"
    end
    if (counts.windows or 0) > 0 and windowMode == "asset" and (choices.windowObjectId == nil or assets:GetObjectNode(choices.windowObjectId) == nil) then
        return "The selected window object is missing. Pick another window before continuing.", "window"
    end
    if (counts.secretDoors or 0) > 0 and secretDoorMode == "asset" and (choices.secretDoorObjectId == nil or assets:GetObjectNode(choices.secretDoorObjectId) == nil) then
        return "The selected secret door object is missing. Pick another secret door before continuing.", "secretDoor"
    end
    if (counts.lights or 0) > 0 and lightMode == "asset" and (choices.lightObjectId == nil or assets:GetObjectNode(choices.lightObjectId) == nil) then
        return "The selected light object is missing. Pick another light before continuing.", "light"
    end
    if (counts.lights or 0) > 0 and lightMode == "asset" and not ObjectNodeHasComponent(choices.lightObjectId, "Light") then
        return "The selected light object does not have a Light component. Pick a light-emitting object before continuing.", "light"
    end

    return nil
end

local function BuildAssetTooltip(item)
    local children = {
        gui.Label{
            text = "<b>" .. (item.label or "(no name)") .. "</b>",
            fontSize = 18,
            color = "white",
            width = PICKER_UI.tooltipContentWidth,
            height = "auto",
            wrap = true,
        },
        gui.Panel{width = PICKER_UI.tooltipContentWidth, height = 6, interactable = false},
    }

    if item.kind == "wall" then
        children[#children+1] = gui.Panel{
            bgimageStreamed = item.id,
            bgcolor = item.tint,
            hueshift = item.hueshift,
            saturation = item.saturation and (1 + item.saturation) or nil,
            brightness = item.brightness and (1 + item.brightness) or nil,
            width = PICKER_UI.tooltipWallWidth,
            height = PICKER_UI.tooltipWallHeight,
            halign = "center",
            interactable = false,
        }
    elseif item.thumbnailId or item.image then
        children[#children+1] = gui.Panel{
            bgimage = item.thumbnailId or item.image,
            bgcolor = "white",
            hueshift = item.hue,
            saturation = item.saturation,
            brightness = item.brightness,
            width = PICKER_UI.tooltipObjectSize,
            height = PICKER_UI.tooltipObjectSize,
            halign = "center",
            interactable = false,
        }
    end

    local detail = item.behavior
    if (detail == nil or detail == "") and
            item.description and item.description ~= "" and
            item.description ~= item.label then
        detail = item.description
    end
    if detail ~= nil and detail ~= "" then
        children[#children+1] = gui.Panel{width = PICKER_UI.tooltipContentWidth, height = 6, interactable = false}
        children[#children+1] = gui.Label{
            text = detail,
            fontSize = 12,
            color = "white",
            width = PICKER_UI.tooltipContentWidth,
            height = "auto",
            wrap = true,
        }
    end

    if item.artist and item.artist ~= "" then
        children[#children+1] = gui.Panel{width = PICKER_UI.tooltipContentWidth, height = 4, interactable = false}
        children[#children+1] = gui.Label{
            classes = {"fgMuted"},
            text = "<i>Artist: " .. tostring(item.artist) .. "</i>",
            fontSize = 10,
            width = PICKER_UI.tooltipContentWidth,
            height = "auto",
        }
    end

    return gui.TooltipFrame(
        gui.Panel{
            interactable = false,
            width = PICKER_UI.tooltipWidth,
            height = "auto",
            pad = 12,
            borderBox = true,
            flow = "vertical",
            styles = ThemeEngine.GetStyles(),
            children = children,
        },
        {valign = "center", halign = "left"}
    )
end

local function BuildThumbnailTile(item, onClick, tileShape)
    tileShape = tileShape or "wide"

    local sizes = PICKER_UI.thumbnail[tileShape] or PICKER_UI.thumbnail.wide

    local imageChild
    if item.kind == "wall" then
        imageChild = gui.Panel{
            bgimageStreamed = item.id,
            bgcolor = item.tint,
            hueshift = item.hueshift,
            saturation = item.saturation and (1 + item.saturation) or nil,
            brightness = item.brightness and (1 + item.brightness) or nil,
            width = "100%",
            height = "100%",
            halign = "center",
            valign = "center",
            interactable = false,
            events = {
                imageLoaded = function(element)
                    if tileShape == "square"
                            and element.bgimageWidth and element.bgimageHeight
                            and element.bgimageWidth > element.bgimageHeight * 1.5 then
                        element.selfStyle.imageRect = {
                            x1 = 0,
                            x2 = element.bgimageHeight / element.bgimageWidth,
                            y1 = 0,
                            y2 = 1,
                        }
                    end
                end,
            },
        }
    else
        imageChild = gui.Panel{
            bgimage = item.thumbnailId or item.image,
            bgcolor = "white",
            hueshift = item.hue,
            saturation = item.saturation,
            brightness = item.brightness,
            width = "100%",
            height = "100%",
            halign = "center",
            valign = "center",
            interactable = false,
            events = {
                imageLoaded = function(element)
                    if element.bgsprite ~= nil and element.bgsprite.dimensions ~= nil then
                        local dx = element.bgsprite.dimensions.x
                        local dy = element.bgsprite.dimensions.y
                        local maxDim = math.max(dx, dy)
                        if maxDim > 0 then
                            element.selfStyle.width = tostring(dx / maxDim * 100) .. "%"
                            element.selfStyle.height = tostring(dy / maxDim * 100) .. "%"
                        end
                    end
                end,
            },
        }
    end

    local fullLabel = tostring(item.label or "")
    local shortLabel = ShortLabel(fullLabel, PICKER_UI.tileLabelLength)

    local thumb
    thumb = gui.Panel{
        classes = {"assetThumbnail"},
        bgimage = "panels/square.png",
        width = sizes.tileW,
        height = sizes.tileH,
        hmargin = 4,
        vmargin = 4,
        flow = "vertical",
        clip = true,
        data = {assetId = item.id},
        events = {
            hover = function(element)
                if element.tooltip == nil then
                    element.tooltip = BuildAssetTooltip(item)
                end
            end,
        },
        press = function(element)
            onClick(element.data.assetId)
        end,

        gui.Panel{
            width = sizes.imageW,
            height = sizes.imageH,
            halign = "center",
            valign = "top",
            interactable = false,
            imageChild,
        },

        gui.Label{
            text = shortLabel,
            width = "100%",
            height = "auto",
            maxHeight = 28,
            fontSize = 10,
            halign = "center",
            valign = "top",
            textAlignment = "center",
            wrap = true,
            interactable = false,
        },
    }
    return thumb
end

local function CurrentAssetItem(kind, id)
    if kind == "wall" then
        local wall = assets.walls and assets.walls[id]
        if wall ~= nil then
            return WallItemFromAsset(id, wall)
        end
    else
        local node = id and assets:GetObjectNode(id)
        if node ~= nil then
            return ObjectItemFromNode(id, node)
        end
    end

    return nil
end

local function BuildAssetPreviewTile(item, tileShape)
    tileShape = tileShape or "wide"

    local sizes = PICKER_UI.preview[tileShape] or PICKER_UI.preview.wide

    if item == nil then
        return gui.Panel{
            classes = {"bgAlt"},
            bgimage = "panels/square.png",
            width = sizes.outerW,
            height = sizes.outerH,
            hmargin = 6,
            valign = "center",
            flow = "none",
            interactable = false,
            gui.Label{
                classes = {"fgMuted"},
                text = "?",
                width = "100%",
                height = "100%",
                textAlignment = "center",
                valign = "center",
                fontSize = 16,
                interactable = false,
            },
        }
    end

    local imageChild
    if item.kind == "wall" then
        imageChild = gui.Panel{
            bgimageStreamed = item.id,
            bgcolor = item.tint,
            hueshift = item.hueshift,
            saturation = item.saturation and (1 + item.saturation) or nil,
            brightness = item.brightness and (1 + item.brightness) or nil,
            width = "100%",
            height = "100%",
            halign = "center",
            valign = "center",
            interactable = false,
        }
    elseif item.thumbnailId or item.image then
        imageChild = gui.Panel{
            bgimage = item.thumbnailId or item.image,
            bgcolor = "white",
            hueshift = item.hue,
            saturation = item.saturation,
            brightness = item.brightness,
            width = "100%",
            height = "100%",
            halign = "center",
            valign = "center",
            interactable = false,
            events = {
                imageLoaded = function(element)
                    if element.bgsprite ~= nil and element.bgsprite.dimensions ~= nil then
                        local dx = element.bgsprite.dimensions.x
                        local dy = element.bgsprite.dimensions.y
                        local maxDim = math.max(dx, dy)
                        if maxDim > 0 then
                            element.selfStyle.width = tostring(dx / maxDim * 100) .. "%"
                            element.selfStyle.height = tostring(dy / maxDim * 100) .. "%"
                        end
                    end
                end,
            },
        }
    else
        imageChild = gui.Label{
            classes = {"fgMuted"},
            text = "?",
            width = "100%",
            height = "100%",
            textAlignment = "center",
            valign = "center",
            fontSize = 16,
            interactable = false,
        }
    end

    return gui.Panel{
        classes = {"bgAlt"},
        bgimage = "panels/square.png",
        width = sizes.outerW,
        height = sizes.outerH,
        hmargin = 6,
        valign = "center",
        flow = "none",
        clip = true,
        interactable = false,
        events = {
            hover = function(element)
                if element.tooltip == nil then
                    element.tooltip = BuildAssetTooltip(item)
                end
            end,
        },
        gui.Panel{
            width = sizes.innerW,
            height = sizes.innerH,
            halign = "center",
            valign = "center",
            interactable = false,
            imageChild,
        },
    }
end

local function BuildSearchableThumbnailPicker(opts)
    local kind = opts.kind or "object"
    local query = opts.initialQuery or ""
    local currentSelection = opts.currentId
    local thumbnails = {}
    local resultPanel
    local infoLabel
    local rebuild

    local function fetch()
        if kind == "wall" then
            return SearchWallItems(query, currentSelection)
        else
            return SearchObjectItems(query, currentSelection)
        end
    end

    local function setSelection(newId, fireChange)
        currentSelection = newId
        local found = false
        for _,t in ipairs(thumbnails) do
            local match = t.data and t.data.assetId == newId
            t:SetClass("selected", match)
            if match then found = true end
        end
        if not found and rebuild ~= nil then
            rebuild()
        end
        if fireChange and opts.onChange ~= nil then
            opts.onChange(newId)
        end
    end

    rebuild = function()
        local items, totalMatched = fetch()
        local newChildren = {}
        thumbnails = {}
        for _,item in ipairs(items) do
            local thumb = BuildThumbnailTile(item, function(id)
                setSelection(id, true)
            end, opts.tileShape)
            if item.id == currentSelection then
                thumb:SetClass("selected", true)
            end
            newChildren[#newChildren+1] = thumb
            thumbnails[#thumbnails+1] = thumb
        end
        resultPanel.children = newChildren

        if infoLabel ~= nil then
            if totalMatched == 0 then
                infoLabel.text = "(no matches -- showing default only)"
            elseif totalMatched > #items then
                infoLabel.text = string.format(
                    "showing %d of %d -- type to narrow", #items, totalMatched)
            else
                infoLabel.text = string.format("%d match%s",
                    totalMatched, totalMatched == 1 and "" or "es")
            end
        end
    end

    local pickerStyles = ThemeEngine.MergeTokens({
        {
            selectors = {"assetThumbnail"},
            borderWidth = 2,
            borderColor = "@border",
            bgcolor = "@bg",
            cornerRadius = 4,
            pad = 4,
            borderBox = true,
        },
        {
            selectors = {"assetThumbnail", "hover"},
            borderColor = "@accent",
        },
        {
            selectors = {"assetThumbnail", "selected"},
            borderWidth = 3,
            borderColor = "@fg",
        },
    })

    resultPanel = gui.Panel{
        flow = "horizontal",
        wrap = true,
        width = "100%",
        height = "auto",
        styles = pickerStyles,
    }

    infoLabel = gui.Label{
        classes = {"fgMuted"},
        text = "",
        width = "auto",
        height = "auto",
        fontSize = 11,
        hmargin = 8,
        valign = "center",
    }

    local searchInput = gui.Input{
        classes = {"form"},
        text = query,
        width = PICKER_UI.searchWidth,
        height = PICKER_UI.inputHeight,
        placeholderText = "Search...",
        change = function(element)
            query = element.text or ""
            rebuild()
        end,
    }

    rebuild()

    local panel = gui.Panel{
        flow = "vertical",
        width = "100%",
        height = "auto",

        gui.Panel{
            flow = "horizontal",
            width = "100%",
            height = "auto",
            vmargin = 4,
            valign = "center",
            searchInput,
            infoLabel,
        },

        resultPanel,
    }

    return panel, setSelection
end

MapImportPlus.ShowMapAssetPickerDialog = function(uvttData, callback)
    local wallId        = dmhub.GetSettingValue("mapimport:wall_asset_id")
    local objectWallId  = dmhub.GetSettingValue("mapimport:object_wall_asset_id")
    local terrainWallId = dmhub.GetSettingValue("mapimport:terrain_wall_asset_id")
    local invisibleWallId = dmhub.GetSettingValue("mapimport:invisible_wall_asset_id")
    local transparentWindowWallId = dmhub.GetSettingValue("mapimport:transparent_window_wall_asset_id")
    local unrecognizedWallId = dmhub.GetSettingValue("mapimport:unrecognized_wall_asset_id")
    local doorId        = dmhub.GetSettingValue("mapimport:door_object_id")
    local windowId      = dmhub.GetSettingValue("mapimport:window_object_id")
    local secretDoorId  = dmhub.GetSettingValue("mapimport:secret_door_object_id")
    local lightId       = dmhub.GetSettingValue("mapimport:light_object_id")
    local flipFoundryTerrain = dmhub.GetSettingValue("mapimport:flip_foundry_terrain_walls") == true
    local offsetX       = 0
    local offsetY       = 0

    local DEFAULT_WALL        = "-MGADhKw0vw30yXNF2-e"
    local DEFAULT_OBJECT_WALL = "eae7f3fe-d278-455c-853a-ac43f948c743"
    local DEFAULT_TERRAIN_WALL = "eae7f3fe-d278-455c-853a-ac43f948c743"
    local DEFAULT_INVISIBLE_WALL = "eae7f3fe-d278-455c-853a-ac43f948c743"
    local DEFAULT_TRANSPARENT_WINDOW_WALL = "eae7f3fe-d278-455c-853a-ac43f948c743"
    local DEFAULT_UNRECOGNIZED_WALL = "-MGADhKw0vw30yXNF2-e"
    local DEFAULT_DOOR        = "-MfWx0b2IlyApLQwasYg"
    local DEFAULT_WINDOW      = "-MDd3Knydcq2WsjStef2"
    local DEFAULT_SECRET_DOOR = "-MfWx0b2IlyApLQwasYg"
    local DEFAULT_LIGHT       = "2339211c-c35a-4e0a-a5fa-79d2e446bd3b"
    if unrecognizedWallId == nil or unrecognizedWallId == "" then
        unrecognizedWallId = wallId or DEFAULT_UNRECOGNIZED_WALL
    end
    if terrainWallId == nil or terrainWallId == "" then
        terrainWallId = objectWallId or DEFAULT_TERRAIN_WALL
    end
    if invisibleWallId == nil or invisibleWallId == "" then
        invisibleWallId = objectWallId or DEFAULT_INVISIBLE_WALL
    end
    if transparentWindowWallId == nil or transparentWindowWallId == "" then
        transparentWindowWallId = objectWallId or DEFAULT_TRANSPARENT_WINDOW_WALL
    end

    local counts = CountImportFeatures(uvttData)
    local floorCount = 1
    if type(uvttData) == "table" and uvttData[1] ~= nil then
        floorCount = #uvttData
    end

    local function ValidMode(value, defaultValue, allowed)
        local mode = tostring(value or defaultValue)
        if allowed[mode] == true then
            return mode
        end
        return defaultValue
    end

    local function LegacyMode(value, legacyValue, defaultValue, allowed)
        if value == nil or value == "" then
            value = legacyValue
        end
        return ValidMode(value, defaultValue, allowed)
    end

    local wallModeAllowed = {wall = true, none = true}
    local assetModeAllowed = {asset = true, none = true}
    local windowModeAllowed = {asset = true, movement_wall = true, none = true}
    local structuralWallMode = ValidMode(dmhub.GetSettingValue("mapimport:structural_wall_mode"), "wall", wallModeAllowed)
    local objectWallMode = ValidMode(dmhub.GetSettingValue("mapimport:object_wall_mode"), "wall", wallModeAllowed)
    local terrainWallMode = ValidMode(dmhub.GetSettingValue("mapimport:terrain_wall_mode"), "wall", wallModeAllowed)
    local invisibleWallMode = LegacyMode(dmhub.GetSettingValue("mapimport:invisible_wall_mode"), dmhub.GetSettingValue("mapimport:movement_wall_mode"), "wall", wallModeAllowed)
    local unrecognizedWallMode = ValidMode(dmhub.GetSettingValue("mapimport:unrecognized_wall_mode"), "none", wallModeAllowed)
    local doorMode = ValidMode(dmhub.GetSettingValue("mapimport:door_mode"), "asset", assetModeAllowed)
    local windowMode = ValidMode(dmhub.GetSettingValue("mapimport:window_mode"), "asset", windowModeAllowed)
    local secretDoorMode = ValidMode(dmhub.GetSettingValue("mapimport:secret_door_mode"), "asset", assetModeAllowed)
    local lightMode = ValidMode(dmhub.GetSettingValue("mapimport:light_mode"), "asset", assetModeAllowed)

    local refreshAllSummaries = nil
    local modeRefreshers = {}
    local bodyRefreshers = {}
    local allPickerPanels = {}
    local attachedPickerPanels = {}
    local function MakePicker(options)
        local picker, setter = BuildSearchableThumbnailPicker(options)
        if picker ~= nil then
            allPickerPanels[#allPickerPanels+1] = picker
        end
        return picker, setter
    end
    local function MarkPickerAttached(picker)
        if picker ~= nil then
            attachedPickerPanels[picker] = true
        end
    end

    local wallPicker,       setWall       = MakePicker{
        kind = "wall", tileShape = "wide", initialQuery = "", currentId = wallId,
        onChange = function(v)
            wallId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local objectWallPicker, setObjectWall = MakePicker{
        kind = "wall", tileShape = "wide", initialQuery = "one-direction", currentId = objectWallId,
        onChange = function(v)
            objectWallId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local terrainWallPicker, setTerrainWall = MakePicker{
        kind = "wall", tileShape = "wide", initialQuery = "one-direction", currentId = terrainWallId,
        onChange = function(v)
            terrainWallId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local invisibleWallPicker, setInvisibleWall = MakePicker{
        kind = "wall", tileShape = "wide", initialQuery = "see-thru", currentId = invisibleWallId,
        onChange = function(v)
            invisibleWallId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local transparentWindowWallPicker, setTransparentWindowWall = MakePicker{
        kind = "wall", tileShape = "wide", initialQuery = "see-thru", currentId = transparentWindowWallId,
        onChange = function(v)
            transparentWindowWallId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local unrecognizedWallPicker = nil
    local setUnrecognizedWall = nil
    if counts.unrecognized > 0 then
        unrecognizedWallPicker, setUnrecognizedWall = MakePicker{
            kind = "wall", tileShape = "wide", initialQuery = "", currentId = unrecognizedWallId,
            onChange = function(v)
                unrecognizedWallId = v
                if refreshAllSummaries ~= nil then refreshAllSummaries() end
            end,
        }
    end

    local doorPicker,       setDoor       = MakePicker{
        kind = "object", tileShape = "square", initialQuery = "door", currentId = doorId,
        onChange = function(v)
            doorId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local windowPicker,     setWindow     = MakePicker{
        kind = "object", tileShape = "square", initialQuery = "window", currentId = windowId,
        onChange = function(v)
            windowId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local secretDoorPicker, setSecretDoor = MakePicker{
        kind = "object", tileShape = "square", initialQuery = "secret", currentId = secretDoorId,
        onChange = function(v)
            secretDoorId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }
    local lightPicker,      setLight      = MakePicker{
        kind = "object", tileShape = "square", initialQuery = "light", currentId = lightId,
        onChange = function(v)
            lightId = v
            if refreshAllSummaries ~= nil then refreshAllSummaries() end
        end,
    }

    local sectionRefreshers = {}
    local sectionsById = {}
    local openSection = nil
    local importSummaryLabel = nil
    local ACTION_LABELS = {
        wall = "Line",
        none = "None",
        asset = "Asset",
        movement_wall = "Transparent Wall",
    }

    local function FormatNumber(value)
        local text = string.format("%.2f", tonumber(value) or 0)
        text = string.gsub(text, "0+$", "")
        text = string.gsub(text, "%.$", "")
        return cond(text == "-0", "0", text)
    end

    local function AdvancedSummaryText()
        local parts = {
            string.format("offset %s, %s", FormatNumber(offsetX), FormatNumber(offsetY)),
        }
        if flipFoundryTerrain then
            parts[#parts+1] = "terrain flipped"
        end
        return table.concat(parts, " | ")
    end

    local function CountLabel(count, singular, plural)
        return string.format("%d %s", count, count == 1 and singular or (plural or (singular .. "s")))
    end

    local function ImportSummaryText()
        local creating = {}
        local skipped = {}

        local function addLine(count, singular, plural, mode, createText)
            if count <= 0 then return end
            if mode == "none" then
                skipped[#skipped+1] = CountLabel(count, singular, plural)
            else
                creating[#creating+1] = string.format("%d %s", count, createText)
            end
        end

        addLine(counts.structural, "structural wall", "structural walls", structuralWallMode, "structural wall lines")
        addLine(counts.object, "object occluder", "object occluders", objectWallMode, "object occluder lines")
        addLine(counts.terrain, "terrain wall", "terrain walls", terrainWallMode, "terrain wall lines")
        addLine(counts.invisible, "invisible wall", "invisible walls", invisibleWallMode, "invisible wall lines")
        addLine(counts.unrecognized, "unrecognized wall", "unrecognized walls", unrecognizedWallMode, "unrecognized wall lines")

        if counts.doors > 0 then
            if doorMode == "asset" then
                creating[#creating+1] = string.format("%d door asset%s", counts.doors, counts.doors == 1 and "" or "s")
            else
                skipped[#skipped+1] = CountLabel(counts.doors, "door", "doors")
            end
        end
        if counts.windows > 0 then
            if windowMode == "asset" then
                creating[#creating+1] = string.format("%d window asset%s", counts.windows, counts.windows == 1 and "" or "s")
            elseif windowMode == "movement_wall" then
                creating[#creating+1] = string.format("%d transparent window wall%s", counts.windows, counts.windows == 1 and "" or "s")
            else
                skipped[#skipped+1] = CountLabel(counts.windows, "window", "windows")
            end
        end
        if counts.secretDoors > 0 then
            if secretDoorMode == "asset" then
                creating[#creating+1] = string.format("%d secret door asset%s", counts.secretDoors, counts.secretDoors == 1 and "" or "s")
            else
                skipped[#skipped+1] = CountLabel(counts.secretDoors, "secret door", "secret doors")
            end
        end
        if counts.lights > 0 then
            if lightMode == "asset" then
                creating[#creating+1] = string.format("%d light asset%s", counts.lights, counts.lights == 1 and "" or "s")
            else
                skipped[#skipped+1] = CountLabel(counts.lights, "light", "lights")
            end
        end

        local text = "Creating: " .. cond(#creating > 0, table.concat(creating, "; "), "map image only") .. "."
        if #skipped > 0 then
            text = text .. " Skipping: " .. table.concat(skipped, "; ") .. "."
        end
        return text
    end

    local function SetSectionExpanded(section, expanded)
        if section == nil then return end
        if expanded and openSection ~= nil and openSection ~= section then
            openSection.arrow:SetClass("expanded", false)
            openSection.bodyPanel:SetClass("collapsed", true)
        end

        section.arrow:SetClass("expanded", expanded)
        section.bodyPanel:SetClass("collapsed", not expanded)
        if expanded then
            openSection = section
        elseif openSection == section then
            openSection = nil
        end
    end

    local function BuildDisclosureRow(args)
        local bodyPanel = args.bodyPanel
        local summaryLabel = gui.Label{
            classes = {"fg"},
            text = "",
            width = PICKER_UI.summaryWidth,
            height = "auto",
            maxHeight = 22,
            fontSize = 12,
            valign = "center",
            textAlignment = "left",
            interactable = false,
        }
        local previewSlot = gui.Panel{
            width = "auto",
            height = "auto",
            valign = "center",
            interactable = false,
        }
        local arrow = gui.ExpandoArrow{
            interactable = false,
            hmargin = 6,
            valign = "center",
        }
        local section = {
            id = args.id,
            arrow = arrow,
            bodyPanel = bodyPanel,
        }

        local function refreshSummary()
            if args.summaryText ~= nil then
                summaryLabel.text = args.summaryText()
                summaryLabel:SetClass("fg", true)
                summaryLabel:SetClass("fgMuted", false)
                previewSlot.children = {}
                return
            end

            if args.summaryState ~= nil then
                local text, assetKind, assetId, tileShape = args.summaryState()
                summaryLabel.text = text or ""
                summaryLabel:SetClass("fg", true)
                summaryLabel:SetClass("fgMuted", false)
                if assetKind ~= nil and assetId ~= nil then
                    local item = CurrentAssetItem(assetKind, assetId)
                    previewSlot.children = {BuildAssetPreviewTile(item, tileShape)}
                else
                    previewSlot.children = {}
                end
                return
            end

            local item = CurrentAssetItem(args.assetKind, args.getId())
            if item ~= nil then
                summaryLabel.text = ShortLabel(item.label, PICKER_UI.summaryLength)
                summaryLabel:SetClass("fg", true)
                summaryLabel:SetClass("fgMuted", false)
            else
                summaryLabel.text = "(missing)"
                summaryLabel:SetClass("fg", false)
                summaryLabel:SetClass("fgMuted", true)
            end
            previewSlot.children = {BuildAssetPreviewTile(item, args.tileShape)}
        end

        section.refreshSummary = refreshSummary
        sectionRefreshers[#sectionRefreshers+1] = refreshSummary
        sectionsById[args.id] = section

        local row = gui.Panel{
            width = "100%",
            height = "auto",
            vmargin = 3,
            flow = "vertical",

            gui.Panel{
                classes = {"row", "headerRow"},
                width = "100%",
                height = PICKER_UI.headerHeight,
                flow = "horizontal",
                valign = "center",
                click = function()
                    SetSectionExpanded(section, not arrow:HasClass("expanded"))
                end,

                arrow,
                gui.Label{
                    text = "<b>" .. args.labelText .. "</b>",
                    width = PICKER_UI.headerLabelWidth,
                    height = "auto",
                    fontSize = 14,
                    valign = "center",
                    textAlignment = "left",
                    interactable = false,
                },
                summaryLabel,
                previewSlot,
            },

            bodyPanel,
        }

        refreshSummary()
        return row
    end

    local modeStyles = ThemeEngine.MergeTokens({
        {
            selectors = {"modeButton"},
            borderWidth = 1,
            borderColor = "@border",
            bgcolor = "@bg",
            cornerRadius = 4,
            fontSize = 12,
            height = 26,
        },
        {
            selectors = {"modeButton", "hover"},
            borderColor = "@accent",
        },
        {
            selectors = {"modeButton", "selected"},
            borderWidth = 2,
            borderColor = "@fg",
            bgcolor = "@accent",
        },
    })

    local function BuildModeControl(args)
        local buttons = {}

        local function refreshButtons()
            local mode = args.getMode()
            for _,button in ipairs(buttons) do
                button:SetClass("selected", button.data.value == mode)
            end
        end

        for _, option in ipairs(args.options) do
            local button = gui.Button{
                classes = {"modeButton"},
                text = option.label,
                width = option.width or 128,
                height = 26,
                data = {value = option.value},
                click = function(element)
                    args.setMode(element.data.value)
                    refreshButtons()
                    if refreshAllSummaries ~= nil then refreshAllSummaries() end
                end,
            }
            buttons[#buttons+1] = button
        end

        modeRefreshers[#modeRefreshers+1] = refreshButtons

        local panel = gui.Panel{
            flow = "horizontal",
            width = "auto",
            height = "auto",
            vmargin = 4,
            styles = modeStyles,
            children = buttons,
        }
        refreshButtons()
        return panel
    end

    local function BehaviorRow(args)
        if args.count <= 0 and args.alwaysShow ~= true then
            return nil
        end

        local modeControl = BuildModeControl{
            options = args.options,
            getMode = args.getMode,
            setMode = args.setMode,
        }

        local pickerContainers = {}
        local bodyChildren = {modeControl}

        local function addPicker(picker, visible)
            if picker == nil then
                return
            end

            local container = gui.Panel{
                width = "100%",
                height = "auto",
                flow = "vertical",
                picker,
            }
            MarkPickerAttached(picker)
            pickerContainers[#pickerContainers+1] = {
                panel = container,
                visible = visible,
            }
            bodyChildren[#bodyChildren+1] = container
        end

        if args.pickers ~= nil then
            for _, pickerSpec in ipairs(args.pickers) do
                addPicker(pickerSpec.picker, pickerSpec.visible)
            end
        else
            addPicker(args.picker, args.pickerVisible)
        end

        local function refreshBody()
            local mode = args.getMode()
            for _, picker in ipairs(pickerContainers) do
                local visible = false
                if picker.visible ~= nil then
                    visible = picker.visible(mode)
                else
                    visible = mode == "asset" or mode == "wall"
                end
                picker.panel:SetClass("collapsed", not visible)
            end
        end
        bodyRefreshers[#bodyRefreshers+1] = refreshBody

        local hint = nil
        if args.hintText ~= nil then
            hint = gui.Label{
                classes = {"fgMuted"},
                text = "<i>" .. args.hintText .. "</i>",
                width = "100%",
                height = "auto",
                fontSize = 11,
                vmargin = 2,
                wrap = true,
            }
        end

        if hint ~= nil then
            table.insert(bodyChildren, 2, hint)
        end

        local bodyPanel = gui.Panel{
            classes = {"collapsed"},
            width = "100%",
            height = "auto",
            flow = "vertical",
            lmargin = 28,
            rmargin = 8,
            bmargin = 8,
            children = bodyChildren,
        }

        return BuildDisclosureRow{
            id = args.id,
            labelText = args.labelText,
            bodyPanel = bodyPanel,
            summaryState = function()
                refreshBody()
                local mode = args.getMode()
                local action = ACTION_LABELS[mode] or mode
                local text = CountLabel(args.count, args.singular, args.plural) .. " | " .. action
                if args.assetForMode ~= nil then
                    local asset = args.assetForMode(mode)
                    if asset ~= nil then
                        return text, asset.kind, asset.id, asset.tileShape
                    end
                end
                return text
            end,
        }
    end

    local function MaterialRow(args)
        if args.show ~= true then
            return nil
        end
        MarkPickerAttached(args.picker)

        local hint = nil
        if args.hintText ~= nil then
            hint = gui.Label{
                classes = {"fgMuted"},
                text = "<i>" .. args.hintText .. "</i>",
                width = "100%",
                height = "auto",
                fontSize = 11,
                vmargin = 2,
                wrap = true,
            }
        end

        local bodyPanel = gui.Panel{
            classes = {"collapsed"},
            width = "100%",
            height = "auto",
            flow = "vertical",
            lmargin = 28,
            rmargin = 8,
            bmargin = 8,
            hint,
            args.picker,
        }

        return BuildDisclosureRow{
            id = args.id,
            labelText = args.labelText,
            bodyPanel = bodyPanel,
            summaryState = function()
                return args.summaryText, args.assetKind, args.getId(), args.tileShape
            end,
        }
    end

    local function PickerRow(args)
        MarkPickerAttached(args.picker)

        local hint = nil
        if args.hintText ~= nil then
            hint = gui.Label{
                classes = {"fgMuted"},
                text = "<i>" .. args.hintText .. "</i>",
                width = "100%",
                height = "auto",
                fontSize = 11,
                vmargin = 2,
                wrap = true,
            }
        end

        local bodyPanel = gui.Panel{
            classes = {"collapsed"},
            width = "100%",
            height = "auto",
            flow = "vertical",
            lmargin = 28,
            rmargin = 8,
            bmargin = 8,
            hint,
            args.picker,
        }

        return BuildDisclosureRow{
            id = args.id,
            labelText = args.labelText,
            bodyPanel = bodyPanel,
            assetKind = args.assetKind,
            tileShape = args.tileShape,
            getId = args.getId,
        }
    end

    local floorCountRow = nil
    if floorCount > 1 then
        floorCountRow = gui.Label{
            classes = {"success"},
            text = string.format("%d floors will be imported with these behavior choices.", floorCount),
            width = "100%",
            height = "auto",
            vmargin = 4,
            fontSize = 13,
            wrap = true,
        }
    end

    local summaryRow = gui.Label{
        classes = {"success"},
        text = ImportSummaryText(),
        width = "100%",
        height = "auto",
        vmargin = 4,
        fontSize = 13,
        wrap = true,
        create = function(element)
            importSummaryLabel = element
        end,
    }

    local flipTerrainCheck = nil
    local flipTerrainRow = nil
    if counts.terrain > 0 or counts.invisible > 0 then
        flipTerrainCheck = gui.Check{
            text = "Flip Foundry terrain/invisible wall direction",
            value = flipFoundryTerrain,
            change = function(element)
                flipFoundryTerrain = element.value
                if refreshAllSummaries ~= nil then refreshAllSummaries() end
            end,
        }
        flipTerrainRow = gui.Panel{
            width = "100%",
            height = "auto",
            vmargin = 4,
            flow = "vertical",
            flipTerrainCheck,
            gui.Label{
                classes = {"fgMuted"},
                text = "Use when one-direction Foundry terrain or invisible walls face the wrong side. Closed loops are normalized automatically.",
                width = "100%",
                height = "auto",
                fontSize = 11,
                wrap = true,
            },
        }
    end

    local offsetXInput = nil
    local offsetYInput = nil

    local advancedPanel = gui.Panel{
        classes = {"collapsed"},
        width = "100%",
        height = "auto",
        flow = "vertical",
        lmargin = 28,
        rmargin = 8,
        bmargin = 8,

        gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            vmargin = 4,
            gui.Label{
                classes = {"form"},
                text = "<b>Alignment offset (tiles)</b>",
                width = "auto",
                height = "auto",
                fontSize = 14,
            },
            gui.Label{
                classes = {"fgMuted"},
                text = "<i>Shifts imported walls, doors, windows, and lights. Use only when they land off the image.</i>",
                width = "100%",
                height = "auto",
                fontSize = 11,
                wrap = true,
                vmargin = 2,
            },
            gui.Panel{
                width = "auto",
                height = "auto",
                flow = "horizontal",
                valign = "center",
                vmargin = 4,
                gui.Label{ text = "X:", width = "auto", height = "auto", valign = "center", hmargin = 4 },
                gui.Input{
                    classes = {"form"},
                    text = "0",
                    width = PICKER_UI.inputWidth,
                    height = PICKER_UI.inputHeight,
                    create = function(element)
                        offsetXInput = element
                    end,
                    change = function(element)
                        offsetX = tonumber(element.text) or 0
                        if refreshAllSummaries ~= nil then refreshAllSummaries() end
                    end,
                },
                gui.Label{ text = "Y:", width = "auto", height = "auto", valign = "center", hmargin = 4 },
                gui.Input{
                    classes = {"form"},
                    text = "0",
                    width = PICKER_UI.inputWidth,
                    height = PICKER_UI.inputHeight,
                    create = function(element)
                        offsetYInput = element
                    end,
                    change = function(element)
                        offsetY = tonumber(element.text) or 0
                        if refreshAllSummaries ~= nil then refreshAllSummaries() end
                    end,
                },
            },
        },

        flipTerrainRow,
    }

    local wallMaterialRelevant = counts.structural > 0 or counts.doors > 0 or counts.windows > 0 or counts.secretDoors > 0
    local objectMaterialRelevant = counts.object > 0
    local wallRow = nil
    if counts.structural > 0 then
        wallRow = BehaviorRow{
            id = "wall",
            labelText = "Structural walls",
            count = counts.structural,
            singular = "structural wall",
            plural = "structural walls",
            options = {{value = "wall", label = "Line"}, {value = "none", label = "None"}},
            getMode = function() return structuralWallMode end,
            setMode = function(v) structuralWallMode = v end,
            picker = wallPicker,
            hintText = "Room boundaries and normal line-of-sight walls.",
            assetForMode = function(mode)
                if mode == "wall" then return {kind = "wall", id = wallId, tileShape = "wide"} end
                return nil
            end,
        }
    elseif wallMaterialRelevant then
        wallRow = MaterialRow{
            id = "wall",
            labelText = "Wall material",
            show = true,
            picker = wallPicker,
            hintText = "Used by UVTT portal wall lines when the source format supplies them.",
            summaryText = "Portal line material",
            assetKind = "wall",
            tileShape = "wide",
            getId = function() return wallId end,
        }
    end

    local objectWallRow = nil
    if counts.object > 0 then
        objectWallRow = BehaviorRow{
            id = "objectWall",
            labelText = "Object occluders",
            count = counts.object,
            singular = "object occluder",
            plural = "object occluders",
            options = {{value = "wall", label = "Line"}, {value = "none", label = "None"}},
            getMode = function() return objectWallMode end,
            setMode = function(v) objectWallMode = v end,
            picker = objectWallPicker,
            hintText = "Closed UVTT object occluders.",
            assetForMode = function(mode)
                if mode == "wall" then return {kind = "wall", id = objectWallId, tileShape = "wide"} end
                return nil
            end,
        }
    elseif objectMaterialRelevant then
        objectWallRow = MaterialRow{
            id = "objectWall",
            labelText = "Object occluder material",
            show = true,
            picker = objectWallPicker,
            hintText = "Used for closed UVTT object occluders.",
            summaryText = "Object occluder material",
            assetKind = "wall",
            tileShape = "wide",
            getId = function() return objectWallId end,
        }
    end

    local terrainRow = BehaviorRow{
        id = "terrain",
        labelText = "Terrain walls",
        count = counts.terrain,
        singular = "terrain wall",
        plural = "terrain walls",
        options = {{value = "wall", label = "Line"}, {value = "none", label = "None"}},
        getMode = function() return terrainWallMode end,
        setMode = function(v) terrainWallMode = v end,
        picker = terrainWallPicker,
        hintText = "Foundry partial-sight, movement-blocking walls.",
        assetForMode = function(mode)
            if mode == "wall" then return {kind = "wall", id = terrainWallId, tileShape = "wide"} end
            return nil
        end,
    }
    local invisibleRow = BehaviorRow{
        id = "invisible",
        labelText = "Invisible walls",
        count = counts.invisible,
        singular = "invisible wall",
        plural = "invisible walls",
        options = {{value = "wall", label = "Line"}, {value = "none", label = "None"}},
        getMode = function() return invisibleWallMode end,
        setMode = function(v) invisibleWallMode = v end,
        picker = invisibleWallPicker,
        hintText = "Foundry walls that block movement but not vision.",
        assetForMode = function(mode)
            if mode == "wall" then return {kind = "wall", id = invisibleWallId, tileShape = "wide"} end
            return nil
        end,
    }
    local unrecognizedWallRow = nil
    if unrecognizedWallPicker ~= nil then
        unrecognizedWallRow = BehaviorRow{
            id = "unrecognizedWall",
            labelText = "Unrecognized walls",
            count = counts.unrecognized,
            singular = "unrecognized wall",
            plural = "unrecognized walls",
            options = {{value = "wall", label = "Line"}, {value = "none", label = "None"}},
            getMode = function() return unrecognizedWallMode end,
            setMode = function(v) unrecognizedWallMode = v end,
            picker = unrecognizedWallPicker,
            hintText = "Foundry wall modes that cannot be mapped directly. Leave as None unless you want them as plain wall lines.",
            assetForMode = function(mode)
                if mode == "wall" then return {kind = "wall", id = unrecognizedWallId, tileShape = "wide"} end
                return nil
            end,
        }
    end
    local doorRow = BehaviorRow{
        id = "door",
        labelText = "Doors",
        count = counts.doors,
        singular = "door",
        plural = "doors",
        options = {{value = "asset", label = "Asset"}, {value = "none", label = "None"}},
        getMode = function() return doorMode end,
        setMode = function(v) doorMode = v end,
        picker = doorPicker,
        assetForMode = function(mode)
            if mode == "asset" then return {kind = "object", id = doorId, tileShape = "square"} end
            return nil
        end,
    }
    local windowRow = BehaviorRow{
        id = "window",
        labelText = "Windows",
        count = counts.windows,
        singular = "window",
        plural = "windows",
        options = {
            {value = "asset", label = "Asset"},
            {value = "movement_wall", label = "Transparent Wall", width = 164},
            {value = "none", label = "None"},
        },
        getMode = function() return windowMode end,
        setMode = function(v) windowMode = v end,
        pickers = {
            {picker = windowPicker, visible = function(mode) return mode == "asset" end},
            {picker = transparentWindowWallPicker, visible = function(mode) return mode == "movement_wall" end},
        },
        hintText = "Transparent Wall creates a movement-blocking, vision-transparent segment.",
        assetForMode = function(mode)
            if mode == "asset" then return {kind = "object", id = windowId, tileShape = "square"} end
            if mode == "movement_wall" then return {kind = "wall", id = transparentWindowWallId, tileShape = "wide"} end
            return nil
        end,
    }
    local secretDoorRow = BehaviorRow{
        id = "secretDoor",
        labelText = "Secret doors",
        count = counts.secretDoors,
        alwaysShow = true,
        singular = "secret door",
        plural = "secret doors",
        options = {{value = "asset", label = "Asset"}, {value = "none", label = "None"}},
        getMode = function() return secretDoorMode end,
        setMode = function(v) secretDoorMode = v end,
        picker = secretDoorPicker,
        assetForMode = function(mode)
            if mode == "asset" then return {kind = "object", id = secretDoorId, tileShape = "square"} end
            return nil
        end,
    }
    local lightRow = BehaviorRow{
        id = "light",
        labelText = "Lights",
        count = counts.lights,
        singular = "light",
        plural = "lights",
        options = {{value = "asset", label = "Asset"}, {value = "none", label = "None"}},
        getMode = function() return lightMode end,
        setMode = function(v) lightMode = v end,
        picker = lightPicker,
        assetForMode = function(mode)
            if mode == "asset" then return {kind = "object", id = lightId, tileShape = "square"} end
            return nil
        end,
    }

    local advancedRow = BuildDisclosureRow{
        id = "advanced",
        labelText = "Advanced Options",
        bodyPanel = advancedPanel,
        summaryText = AdvancedSummaryText,
    }

    refreshAllSummaries = function()
        if importSummaryLabel ~= nil then
            importSummaryLabel.text = ImportSummaryText()
        end
        for _, refresh in ipairs(modeRefreshers) do
            refresh()
        end
        for _, refresh in ipairs(bodyRefreshers) do
            refresh()
        end
        for _, refresh in ipairs(sectionRefreshers) do
            refresh()
        end
    end
    refreshAllSummaries()

    local pickerParkingChildren = {}
    for _, picker in ipairs(allPickerPanels) do
        if attachedPickerPanels[picker] ~= true then
            pickerParkingChildren[#pickerParkingChildren+1] = picker
        end
    end
    local pickerParkingPanel = nil
    if #pickerParkingChildren > 0 then
        pickerParkingPanel = gui.Panel{
            classes = {"collapsed"},
            width = 0,
            height = 0,
            children = pickerParkingChildren,
        }
    end

    local dialogPanel
    dialogPanel = gui.Panel{
        id = "MapAssetPickerDialogPlus",
        classes = {"framedPanel"},
        width = PICKER_UI.dialogWidth,
        height = PICKER_UI.dialogHeight,
        pad = 12,
        borderBox = true,
        flow = "vertical",
        vscroll = true,
        styles = ThemeEngine.GetStyles(),

        gui.Label{
            classes = {"dialogTitle"},
            text = "UVTT Import: Behavior & Assets",
        },

        gui.Label{
            text = "Choose what UVTT import should create. Your choices are remembered.",
            width = "100%",
            height = "auto",
            fontSize = 12,
            wrap = true,
            vmargin = 4,
        },

        floorCountRow,
        summaryRow,

        wallRow,
        objectWallRow,
        terrainRow,
        invisibleRow,
        unrecognizedWallRow,
        doorRow,
        windowRow,
        secretDoorRow,
        lightRow,
        advancedRow,
        pickerParkingPanel,

        gui.Panel{
            width = "100%",
            height = 48,
            valign = "bottom",
            halign = "center",
            flow = "horizontal",
            vmargin = 8,

            gui.Button{
                classes = {"sizeL"},
                text = "Reset to defaults",
                halign = "left",
                hmargin = 4,
                click = function()
                    setWall(DEFAULT_WALL, true)
                    setObjectWall(DEFAULT_OBJECT_WALL, true)
                    setTerrainWall(DEFAULT_TERRAIN_WALL, true)
                    setInvisibleWall(DEFAULT_INVISIBLE_WALL, true)
                    setTransparentWindowWall(DEFAULT_TRANSPARENT_WINDOW_WALL, true)
                    if setUnrecognizedWall ~= nil then
                        setUnrecognizedWall(DEFAULT_UNRECOGNIZED_WALL, true)
                    end
                    setDoor(DEFAULT_DOOR, true)
                    setWindow(DEFAULT_WINDOW, true)
                    setSecretDoor(DEFAULT_SECRET_DOOR, true)
                    setLight(DEFAULT_LIGHT, true)
                    structuralWallMode = "wall"
                    objectWallMode = "wall"
                    terrainWallMode = "wall"
                    invisibleWallMode = "wall"
                    unrecognizedWallMode = "none"
                    doorMode = "asset"
                    windowMode = "asset"
                    secretDoorMode = "asset"
                    lightMode = "asset"
                    flipFoundryTerrain = false
                    offsetX = 0
                    offsetY = 0
                    if flipTerrainCheck ~= nil then
                        flipTerrainCheck.value = false
                    end
                    if offsetXInput ~= nil then
                        offsetXInput.text = "0"
                    end
                    if offsetYInput ~= nil then
                        offsetYInput.text = "0"
                    end
                    refreshAllSummaries()
                end,
            },
            gui.Button{
                classes = {"sizeL"},
                text = "Continue",
                halign = "right",
                hmargin = 4,
                click = function()
                    local choices = {
                        counts                    = counts,
                        wallAssetId              = wallId,
                        objectWallAssetId        = objectWallId,
                        terrainWallAssetId       = terrainWallId,
                        invisibleWallAssetId     = invisibleWallId,
                        transparentWindowWallAssetId = transparentWindowWallId,
                        unrecognizedWallAssetId  = unrecognizedWallId,
                        doorObjectId             = doorId,
                        windowObjectId           = windowId,
                        secretDoorObjectId       = secretDoorId,
                        lightObjectId            = lightId,
                        structuralWallMode       = structuralWallMode,
                        objectWallMode           = objectWallMode,
                        terrainWallMode          = terrainWallMode,
                        invisibleWallMode        = invisibleWallMode,
                        unrecognizedWallMode     = unrecognizedWallMode,
                        includeUnrecognizedWalls = unrecognizedWallMode == "wall",
                        doorMode                 = doorMode,
                        windowMode               = windowMode,
                        secretDoorMode           = secretDoorMode,
                        lightMode                = lightMode,
                        flipFoundryTerrainWalls  = flipFoundryTerrain,
                        alignmentOffsetX         = offsetX,
                        alignmentOffsetY         = offsetY,
                    }
                    local errorMessage, errorSection = ValidateMapAssetChoices(choices)
                    if errorMessage ~= nil then
                        SetSectionExpanded(sectionsById[errorSection], true)
                        refreshAllSummaries()
                        gui.ModalMessage{
                            title = "UVTT Import",
                            message = errorMessage,
                        }
                        return
                    end

                    dmhub.SetSettingValue("mapimport:wall_asset_id", wallId)
                    dmhub.SetSettingValue("mapimport:object_wall_asset_id", objectWallId)
                    dmhub.SetSettingValue("mapimport:terrain_wall_asset_id", terrainWallId)
                    dmhub.SetSettingValue("mapimport:invisible_wall_asset_id", invisibleWallId)
                    dmhub.SetSettingValue("mapimport:transparent_window_wall_asset_id", transparentWindowWallId)
                    dmhub.SetSettingValue("mapimport:unrecognized_wall_asset_id", unrecognizedWallId)
                    dmhub.SetSettingValue("mapimport:door_object_id", doorId)
                    dmhub.SetSettingValue("mapimport:window_object_id", windowId)
                    dmhub.SetSettingValue("mapimport:secret_door_object_id", secretDoorId)
                    dmhub.SetSettingValue("mapimport:light_object_id", lightId)
                    dmhub.SetSettingValue("mapimport:structural_wall_mode", structuralWallMode)
                    dmhub.SetSettingValue("mapimport:object_wall_mode", objectWallMode)
                    dmhub.SetSettingValue("mapimport:terrain_wall_mode", terrainWallMode)
                    dmhub.SetSettingValue("mapimport:invisible_wall_mode", invisibleWallMode)
                    dmhub.SetSettingValue("mapimport:unrecognized_wall_mode", unrecognizedWallMode)
                    dmhub.SetSettingValue("mapimport:door_mode", doorMode)
                    dmhub.SetSettingValue("mapimport:window_mode", windowMode)
                    dmhub.SetSettingValue("mapimport:secret_door_mode", secretDoorMode)
                    dmhub.SetSettingValue("mapimport:light_mode", lightMode)
                    dmhub.SetSettingValue("mapimport:flip_foundry_terrain_walls", flipFoundryTerrain)
                    gui.CloseModal()
                    callback(choices)
                end,
            },
            gui.Button{
                classes = {"sizeL"},
                text = "Cancel",
                halign = "right",
                hmargin = 4,
                escapeActivates = true,
                escapePriority = EscapePriority.EXIT_MODAL_DIALOG,
                click = function()
                    gui.CloseModal()
                    callback(nil)
                end,
            },
        },
    }

    gui.ShowModal(dialogPanel)
end

local UVTT_EXTENSIONS = {".dd2vtt", ".uvtt", ".json"}

local function IsUVTTPath(path)
    local lower = string.lower(tostring(path or ""))
    for _, ext in ipairs(UVTT_EXTENSIONS) do
        if string.ends_with(lower, ext) then
            return true
        end
    end

    return false
end

----------------------------------------------------------------------------
-- File-drop wizard (UVTT-only). For image-only flows the user should
-- continue using the Codex's built-in "Create Map" -> "Import" path; this
-- mod intentionally does NOT duplicate the image-alignment dialog.
----------------------------------------------------------------------------

local function ImportMapWizard(options)

    local mapName = options.mapName or "Imported Map+"

    local contentPanel

    contentPanel = gui.Panel{
        width = "95%",
        height = "94%",
        halign = "center",
        valign = "bottom",
        flow = "vertical",

        processFiles = function(element, paths)
            if paths == nil or #paths == 0 then
                return
            end
            if #paths > 12 then
                gui.ModalMessage{
                    title = "Error Importing",
                    message = "Cannot import more than 12 layers.",
                }
                return
            end

            if not IsUVTTPath(paths[1]) then
                gui.ModalMessage{
                    title = "Map Import+",
                    message = "MapImportPlus only handles .dd2vtt / .uvtt / .json files. Use the Codex's built-in Create Map dialog for image imports.",
                }
                return
            end

            for _, path in ipairs(paths) do
                if not IsUVTTPath(path) then
                    gui.ModalMessage{
                        title = "Error Importing",
                        message = "Cannot import layers of mixed file types.",
                    }
                    return
                end
            end

            assets:ImportUniversalVTT(paths, function(info)
                MapImportPlus.ShowMapAssetPickerDialog(info.uvttData, function(choices)
                    if choices == nil then
                        return
                    end
                    info.assetChoices = choices
                    MapImportPlus.FinishMapImport(mapName, info)
                    gui.CloseModal()
                end)
            end,
            function(err)
                gui.ModalMessage{
                    title = "Error Importing",
                    message = err,
                }
            end)
        end,

        gui.Panel{
            classes = "dropArea",
            bgimage = "panels/square.png",

            dragAndDropExtensions = {".dd2vtt", ".uvtt", ".json"},

            dropfiles = function(element, paths)
                contentPanel:FireEvent("processFiles", paths)
            end,

            styles = ThemeEngine.MergeTokens({
                {
                    width = "80%",
                    height = "60%",
                    valign = "center",
                    selectors = {"dropArea"},
                    bgcolor = "@bgAlt",
                    borderColor = "@border",
                    borderWidth = 6,
                    cornerRadius = 16,
                },
                {
                    selectors = {"dropArea","hover"},
                    bgcolor = "@accent",
                }
            }),

            gui.Label{
                fontSize = 22,
                width = "auto",
                height = "auto",
                halign = "center",
                valign = "center",
                textAlignment = "center",
                text = "Drag & drop one or more .dd2vtt / .uvtt files here.\nMultiple files become a multi-floor map (max 12).\nProduced by scripts/fvtt_to_uvtt.py or Dungeondraft.",
            },
        },

        gui.Label{
            valign = "center",
            halign = "center",
            fontSize = 16,
            width = "auto",
            height = "auto",
            text = "-or-",
        },

        gui.Panel{
            width = "auto",
            height = "auto",
            halign = "center",
            flow = "horizontal",

            gui.Input{
                classes = {"form"},
                text = mapName,
                width = 320,
                hmargin = 8,
                change = function(element)
                    mapName = element.text
                end,
            },

            gui.Button{
                classes = {"sizeL"},
                text = "Choose Files",
                click = function(element)
                    dmhub.OpenFileDialog{
                        id = "MapImportPlusFile",
                        extensions = {"dd2vtt", "uvtt", "json"},
                        multiFiles = true,
                        prompt = "Choose one or more UVTT files. Multiple files become a multi-floor map.",
                        openFiles = function(paths)
                            contentPanel:FireEvent("processFiles", paths)
                        end,
                    }
                end,
            },
        },
    }

    local dialogPanel
    dialogPanel = gui.Panel{
        id = "MapImportPlusDialog",
        classes = {"framedPanel"},
        width = 1200,
        height = 700,
        pad = 8,
        flow = "vertical",
        styles = ThemeEngine.GetStyles(),

        gui.Label{
            classes = {"dialogTitle"},
            text = "Map Import+ (test mod)",
        },

        contentPanel,

        gui.Button{
            classes = {"closeButton"},
            halign = "right",
            valign = "top",
            floating = true,
            escapeActivates = true,
            escapePriority = EscapePriority.EXIT_MODAL_DIALOG,
            click = gui.CloseModal,
        },
    }

    gui.ShowModal(dialogPanel)
end

----------------------------------------------------------------------------
-- Public entry point
----------------------------------------------------------------------------

MapImportPlus.Show = function()
    ImportMapWizard{
        mapName = "Imported Map+",
    }
end

----------------------------------------------------------------------------
-- Dockable panel registration -- adds a sidebar entry the user can open
-- to launch the import dialog.
----------------------------------------------------------------------------

DockablePanel.Register{
    name = "Map Import+",
    icon = "icons/standard/Icon_App_Maps.png",
    notitle = false,
    vscroll = false,
    dmonly = true,
    minHeight = 80,
    content = function()
        return gui.Panel{
            width = "100%",
            height = "auto",
            flow = "vertical",
            halign = "center",
            pad = 8,

            gui.Label{
                width = "100%",
                height = "auto",
                fontSize = 12,
                wrap = true,
                halign = "center",
                textAlignment = "center",
                text = "Test mod for upcoming UVTT/Foundry import improvements (asset picker, secret doors, unrecognized-walls option).",
            },

            -- The dockable panel is narrow, so the sizeL preset font
            -- overflowed the button bounds. A medium-size button with an
            -- explicit fontSize and width fits inside any panel width
            -- comfortably and keeps the label readable.
            gui.Button{
                classes = {"sizeM"},
                halign = "center",
                vmargin = 8,
                width = "90%",
                height = 32,
                fontSize = 14,
                text = "Import UVTT Map",
                click = function()
                    MapImportPlus.Show()
                end,
            },
        }
    end,
}
