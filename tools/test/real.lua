-- The real world for the tests: the game's maps where they lie (world.lua), and the addon loaded
-- whole in its .toc's order, bundled FarstriderLib and all. Nothing here is faked but the client.
-- Globals in: ADDON_DIR, HERE, FACTION ("Alliance" | "Horde"); mock.lua loaded first.
dofile(HERE .. "/world.lua")

PLAYER = { map = 1429, x = 0.5, y = 0.5, level = 60 }
DONE = {}       -- [overlay] = true: areas the challenge has ticked
QUESTS = {}     -- [questID] = true

---------------------------------------------------------
--  Maps
---------------------------------------------------------
local function Info(id)
    local m = WORLD[id]
    if not m then return nil end
    return { mapID = id, name = m[1], parentMapID = m[2], mapType = m[3] }
end

-- A map's place on a continent instance: instance, left, right, top, bottom.
local function Place(id, inst)
    local m = WORLD[id]
    if not m then return nil end
    for i = 4, #m do
        if inst == nil or m[i][1] == inst then return m[i] end
    end
end

local function OnMap(id, inst, wx, wy)
    local p = Place(id, inst)
    if not p then return nil end
    local x, y = (wy - p[2]) / (p[3] - p[2]), (wx - p[4]) / (p[5] - p[4])
    return p[6] + x * (p[8] - p[6]), p[7] + y * (p[9] - p[7])
end

local function Inside(x, y) return x and x >= 0 and x <= 1 and y >= 0 and y <= 1 end

function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end

-- The smallest map of a kind at a spot. kinds: { [mapType] = true }; under: only maps below this one.
local function MapAt(inst, wx, wy, kinds, under)
    local best, bestSize
    for id, m in pairs(WORLD) do
        local p = Place(id, inst)
        if p and kinds[m[3]] and (not under or m[2] == under) and Inside(OnMap(id, inst, wx, wy)) then
            local size = math.abs((p[3] - p[2]) * (p[5] - p[4]))
            if not bestSize or size < bestSize then best, bestSize = id, size end
        end
    end
    return best
end

C_Map = {
    GetMapInfo = Info,
    GetWorldPosFromMapPos = function(id, v)
        local m = WORLD[id]
        if not m or not m[4] then return nil end
        local p = m[4]
        for i = 4, #m do   -- Azeroth holds both continents, each on its own part of the map
            local q = m[i]
            if v.x >= q[6] and v.x <= q[8] and v.y >= q[7] and v.y <= q[9] then p = q break end
        end
        local x, y = (v.x - p[6]) / (p[8] - p[6]), (v.y - p[7]) / (p[9] - p[7])
        return p[1], CreateVector2D(p[4] + y * (p[5] - p[4]), p[2] + x * (p[3] - p[2]))
    end,
    GetMapPosFromWorldPos = function(inst, v, hint)
        local id = hint
        if not id then
            id = MapAt(inst, v.x, v.y, { [3] = true }) or MapAt(inst, v.x, v.y, { [2] = true }, 947)
        end
        local x, y = OnMap(id, inst, v.x, v.y)
        if not x then return nil end
        return id, CreateVector2D(x, y)
    end,
    GetMapInfoAtPosition = function(id, x, y)
        local inst, v = C_Map.GetWorldPosFromMapPos(id, CreateVector2D(x, y))
        local child = inst and MapAt(inst, v.x, v.y, { [2] = true, [3] = true }, id)
        return Info(child or id)
    end,
    GetMapChildrenInfo = function(id, kind, all)
        local out = {}
        local function Add(parent)
            for child, m in pairs(WORLD) do
                if m[2] == parent then
                    if not kind or m[3] == kind then out[#out + 1] = Info(child) end
                    if all then Add(child) end
                end
            end
        end
        Add(id)
        table.sort(out, function(a, b) return a.mapID < b.mapID end)
        return out
    end,
    GetAreaInfo = function() return nil end,   -- the library falls back on its own names
    GetMapRectOnMap = function(zone, on)
        local p = Place(zone)
        if not p then return 0, 1, 0, 1 end
        local l, t = OnMap(on, p[1], p[4], p[2])
        local r, b = OnMap(on, p[1], p[5], p[3])
        return l or 0, r or 1, t or 0, b or 1
    end,
    GetBestMapForUnit = function() return PLAYER.map end,
    GetPlayerMapPosition = function(id)
        if id == PLAYER.map then return CreateVector2D(PLAYER.x, PLAYER.y) end
        local inst, v = C_Map.GetWorldPosFromMapPos(PLAYER.map, CreateVector2D(PLAYER.x, PLAYER.y))
        local x, y = OnMap(id, inst, v.x, v.y)
        return x and CreateVector2D(x, y) or nil
    end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) WAYPOINT = p end,
}
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 } }

---------------------------------------------------------
--  The client
---------------------------------------------------------
WOW_PROJECT_MAINLINE, WOW_PROJECT_CLASSIC, WOW_PROJECT_CAMELOT = 1, 2, 77
WOW_PROJECT_ID = WOW_PROJECT_CAMELOT
function GetExpansionLevel() return 0 end
function GetLocale() return "enUS" end
function GetBuildInfo() return "1.60.1", "71037", "", 16001 end
function UnitFactionGroup() return FACTION, FACTION end
function UnitRace() if FACTION == "Horde" then return "Orc", "Orc", 2 end return "Human", "Human", 1 end
function UnitClass() return "Warrior", "WARRIOR", 1 end
function UnitLevel() return PLAYER.level end
function UnitOnTaxi() return false end
function GetUnitSpeed() return 7 end
function GetPlayerFacing() return 0 end
function GetTime() return 100 end
function IsLoggedIn() return false end
function IsInInstance() return false end
function IsIndoors() return false end
function GetInstanceInfo() return "Azeroth", "none", 0, "", 0, 0, false, 0 end
function GetSubZoneText() return "" end
function GetBindLocation() return nil end
function GetItemCount() return 0 end
function PlayerHasToy() return false end
function debugstack() return "" end
function debugprofilestop() return 0 end
function geterrorhandler() return function(e) error(e, 2) end end
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return QUESTS[id] or false end, IsOnQuest = function() return false end }
C_SpellBook = { IsSpellInSpellBook = function() return false end }
C_Spell = { GetSpellCharges = function() return nil end, GetSpellCooldown = function() return { duration = 0 } end, GetSpellName = function() return nil end }
C_Item = { GetItemCount = function() return 0 end, IsUsableItem = function() return false end, GetItemNameByID = function() return nil end,
    GetItemSpell = function() return nil end }
C_Timer.NewTimer = function() return { Cancel = function() end } end
C_Timer.NewTicker = function() return { Cancel = function() end } end
-- Lua 5.1 has no bit library; the game does.
bit = {
    band = function(a, b)
        local out, place = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then out = out + place end
            a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
        end
        return out
    end,
}

-- The world map and the challenges, as far as the addon looks at them.
local viewed = 1429
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
WorldMapFrame.ScrollContainer = CreateFrame("Frame", nil, WorldMapFrame)
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
WorldMapFrame.ScrollContainer.Child:SetSize(1002, 668)
WorldMapFrame.ScrollContainer:SetSize(1002, 668)
WorldMapFrame.ScrollContainer.GetCurrentScrollX = function() return 0.5 end
WorldMapFrame.ScrollContainer.GetCurrentScrollY = function() return 0.5 end
WorldMapFrame.GetMapID = function() return viewed end
WorldMapFrame.SetMapID = function(_, id) viewed = id end
WorldMapFrame.dataProviders = {}
WorldMapFrame:Hide()

local ns
local function ZoneOf(id)
    for _, z in ipairs(ns.Zones) do if z[1] == id then return z end end
end
function GetAchievementInfo(id) return id, "Explore " .. id end
function GetAchievementNumCriteria(id)
    local z = ZoneOf(id)
    return z and (#z - 2) or 0
end
function GetAchievementCriteriaInfo(id, i)
    local overlay = ZoneOf(id)[i + 2]
    return ns.Areas[overlay][4], 43, DONE[overlay] or false, 0, 1, "", 0, overlay
end

---------------------------------------------------------
--  The addon, by its .toc
---------------------------------------------------------
local function Read(path)
    local fh = assert(io.open(path, "rb"), "no file " .. path)
    local s = fh:read("*a")
    fh:close()
    return s
end

-- The Lua files an .xml names, in order, with the .xml files it includes.
local function FromXml(dir, file, out)
    local folder = (file:match("^(.*)[/\\][^/\\]*$") or ""):gsub("\\", "/")
    for tag, name in Read(dir .. "/" .. file):gmatch("<(%a+)%s+file%s*=%s*['\"]([^'\"]+)['\"]") do
        local path = (folder ~= "" and folder .. "/" or "") .. name:gsub("\\", "/")
        if tag == "Script" then out[#out + 1] = path elseif tag == "Include" then FromXml(dir, path, out) end
    end
end

-- Loads everything the .toc lists but the libraries the mock stands in for.
function LoadWhole(dir)
    local files = {}
    for line in Read(dir .. "/Explorer.toc"):gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
        local stood = line:find("LibStub") or line:find("CallbackHandler") or line:find("LibDataBroker") or line:find("LibDBIcon")
        if line ~= "" and line:sub(1, 1) ~= "#" and not stood then
            if line:lower():match("%.xml$") then FromXml(dir, line, files) else files[#files + 1] = line end
        end
    end
    ns = {}
    for _, file in ipairs(files) do
        local chunk = assert(loadstring(Read(dir .. "/" .. file), "=" .. file))
        chunk("Explorer", ns)
        if ns.Zones and not ZONES_READY then ZONES_READY = true end
    end
    FireEvent("ADDON_LOADED", "Explorer")
    FireEvent("PLAYER_LOGIN")
    FireEvent("PLAYER_ENTERING_WORLD")
    FlushTimers()
    return ns, files
end
