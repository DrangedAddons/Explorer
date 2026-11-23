-- Runs Explorer against the mock. Globals in: ADDON_DIR, MOCK, LOOK
dofile(MOCK)

local fails = 0
local function Check(cond, what)
    if cond then Say("  ok   " .. what) else fails = fails + 1; Say("  FAIL " .. what) end
end
Say("look: " .. LOOK)

-- World map: a canvas the size of a zone map's art.
local viewed = 1416
WorldMapFrame = CreateFrame("Frame", "WorldMapFrame", UIParent)
WorldMapFrame.ScrollContainer = CreateFrame("Frame", nil, WorldMapFrame)
WorldMapFrame.ScrollContainer.Child = CreateFrame("Frame", nil, WorldMapFrame.ScrollContainer)
WorldMapFrame.ScrollContainer.Child:SetSize(1002, 668)
WorldMapFrame.ScrollContainer:SetSize(1002, 668)
local scroll = { x = 0.5, y = 0.5 }
WorldMapFrame.ScrollContainer.GetCurrentScrollX = function() return scroll.x end
WorldMapFrame.ScrollContainer.GetCurrentScrollY = function() return scroll.y end
WorldMapFrame.GetMapID = function() return viewed end
WorldMapFrame.SetMapID = function(_, id) viewed = id end
mapLabel = CreateFrame("Frame", nil, WorldMapFrame)   -- the hover label at the top of the map
mapLabel.Name = mapLabel:CreateFontString()
mapLabel.Description = mapLabel:CreateFontString()
mapLabel.SetLabel = function() end
WorldMapFrame.dataProviders = { [{ Label = mapLabel }] = true, [{}] = true }
WorldMapFrame:Hide()

local ns
local MODE = "asset"   -- what GetAchievementCriteriaInfo gives: "asset", "name" or "bare"
local doneSet = {}     -- [overlay] = true
local waypoint
local player = { map = 1416, x = 0.5, y = 0.5 }

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
    local text = ns.Areas[overlay][4]
    if MODE == "asset" then return text, 43, doneSet[overlay] or false, 0, 1, "", 0, overlay end
    if MODE == "name" then return text, 43, doneSet[overlay] or false, 0, 1, "", 0, 0 end
    return "", nil, doneSet[overlay] or false
end

local CONTINENTS = { [1414] = true, [1415] = true }
C_Map = {
    GetMapInfo = function(id)
        if CONTINENTS[id] then return { name = "Continent " .. id, mapType = 2, parentMapID = 947 } end
        if id == 947 then return { name = "Azeroth", mapType = 1, parentMapID = 0 } end
        -- every zone hangs off Eastern Kingdoms here (enough to test the dots), but for the three
        -- Kalimdor zones the travel tests stand in
        return { name = "Zone " .. id, mapType = 3, parentMapID = (id == 2482 or id == 1441 or id == 1446) and 1414 or 1415 }
    end,
    GetMapRectOnMap = function(zone, on) return 0.2, 0.4, 0.1, 0.3 end,
    GetBestMapForUnit = function() return player.map end,
    GetPlayerMapPosition = function() return { GetXY = function() return player.x, player.y end } end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) waypoint = p end,
}
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }

-- The world: every zone map is 1500 yards across and 1000 down, laid out on a grid by its ID,
-- on a continent (99) the walking data doesn't know. Eastern Plaguelands is the exception:
-- its real place in the Eastern Kingdoms (0), so walks there go by the real terrain and roads.
-- World x runs north and world y west, as in game.
local function MapOrigin(map) return -math.floor(map / 7) % 7 * 1100, -(map % 7) * 1600 end
function CreateVector2D(x, y) return { x = x, y = y, GetXY = function(self) return self.x, self.y end } end
local function EPL(x, y) return 3691.67 + y * (825 - 3691.67), -2256.25 + x * (-6558.33 + 2256.25) end
local function HYJAL(x, y) return 6304.17 + y * (3989.58 - 6304.17), -922.92 + x * (-4395.83 + 922.92) end
-- { left, right, top, bottom } in world yards (UiMapAssignment): Thousand Needles, Tanaris, Kalimdor
local REAL = { [1441] = { -433.33, -4833.33, -3966.67, -6900 }, [1446] = { -218.75, -7118.75, -5875, -10475 },
    [1414] = { 17066.6, -19733.2, 12799.9, -11733.3 } }
local function OnReal(map, x, y)
    local b = REAL[map]
    return b[3] + y * (b[4] - b[3]), b[1] + x * (b[2] - b[1])
end
local function FromReal(map, wx, wy)
    local b = REAL[map]
    return (wy - b[1]) / (b[2] - b[1]), (wx - b[3]) / (b[4] - b[3])
end
C_Map.GetWorldPosFromMapPos = function(map, v)
    if map == 1423 then return 0, CreateVector2D(EPL(v.x, v.y)) end
    if map == 2482 then return 1, CreateVector2D(HYJAL(v.x, v.y)) end
    if REAL[map] then return 1, CreateVector2D(OnReal(map, v.x, v.y)) end
    local bx, by = MapOrigin(map)
    return 99, CreateVector2D(bx - v.y * 1000, by - v.x * 1500)
end
local facing, level, now, onTaxi = 0, 60, 100, false
function GetPlayerFacing() return facing end
function UnitLevel() return level end
function UnitOnTaxi() return onTaxi end
function GetUnitSpeed() return 7 end
function GetTime() return now end
function debugprofilestop() return 0 end
-- The pathfinder: a tenth of a second a yard, and a flight to anywhere outside the zone you're in.
local trails, trailsTo = 0, 0
local flyInZone = false   -- the pathfinder offers a flight inside the zone you're in
-- The flight masters: FarstriderLib's own list, and which of them the character knows.
do
    local lib = { FarstriderLibData = { Internal = {} } }
    local fh = assert(io.open(ADDON_DIR .. "/Libs/FarstriderLibData/Taxi/Camelot/FarstriderLibData_Taxi.lua", "rb"))
    local src = fh:read("*a")
    fh:close()
    assert(loadstring(src, "=FarstriderLibData_Taxi.lua"))("Explorer", lib)
    FarstriderLibData = lib.FarstriderLibData
end
FarstriderLibData_CharacterSettings = { knownTaxiNodes = {} }
function UnitFactionGroup() return "Alliance" end
local function Yards(m1, x1, y1, m2, x2, y2)
    local a, b = select(2, C_Map.GetWorldPosFromMapPos(m1, CreateVector2D(x1, y1))), select(2, C_Map.GetWorldPosFromMapPos(m2, CreateVector2D(x2, y2)))
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end
FarstriderLib_API = {
    FindTrail = function(m1, x1, y1, _, m2, x2, y2)
        trails = trails + 1
        local step = { loc = { mapId = m1, pos = { x = x1, y = y1 } }, loca = "Talk to the Flightmaster to travel to Testville" }
        return { step }, {}, { { cost = flyInZone or Yards(m1, x1, y1, m2, x2, y2) / 30, locaId = 1001 } }
    end,
    FindTrailTo = function(map, x, y)
        trailsTo = trailsTo + 1
        local goal = { loc = { mapId = map, pos = { x = x, y = y } }, loca = "Reach the destination" }
        if map == player.map and not flyInZone then return { goal }, {}, {} end
        return { { loc = { mapId = player.map, pos = { x = 0.9, y = 0.9 } }, loca = "Talk to the Flightmaster to travel to Testville" }, goal },
            {}, { { cost = flyInZone or 60, locaId = 1001 } }
    end,
}

ns = LoadAddon(ADDON_DIR, "Explorer", { "Theme.lua", "Widgets.lua", "Window.lua", "Data.lua", "Core.lua",
    "Nav/Terrain.lua", "Nav/Roads.lua", "Nav/Shapes.lua", "Nav.lua", "Route.lua", "Toast.lua", "Arrow.lua", "UI.lua" })
FireEvent("ADDON_LOADED", "Explorer")
FireEvent("PLAYER_LOGIN")
FlushTimers()

local canvas = WorldMapFrame.ScrollContainer.Child
local layer = canvas:GetChildren()
local function Pins()
    -- shown pins, how many aren't full pins, the pins, how many are faint markers
    local n, small, list, faint = 0, 0, {}, 0
    for _, p in ipairs({ layer:GetChildren() }) do
        if p:IsShown() then
            n = n + 1
            if p.style ~= "pin" then small = small + 1 end
            if p.style == "faint" then faint = faint + 1 end
            list[#list + 1] = p
        end
    end
    return n, small, list, faint
end
local function Tick() layer:GetScript("OnUpdate")(layer, 1) end
local function Count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function Printed(pattern)
    for _, line in ipairs(PRINTED) do if line:find(pattern) then return true end end
    return false
end

Check(layer ~= nil, "pin layer sits on the map canvas")
Check(Count(ns.Areas) == 549 and #ns.Zones == 43, "data: 549 areas in 43 zones")
do
    local seen, bad = {}, 0
    for _, z in ipairs(ns.Zones) do
        for i = 3, #z do
            local a = ns.Areas[z[i]]
            if not a or seen[z[i]] or a[2] < 0 or a[2] > 100 or a[3] < 0 or a[3] > 100 then bad = bad + 1 end
            seen[z[i]] = true
        end
    end
    Check(bad == 0, "every criterion has one area with a position on the map")
    -- Eastern Plaguelands' map was redrawn to wider bounds; on Classic's layout this is 31.2, 15.3.
    local s = ns.Areas[873]
    Check(s[1] == 1423 and s[2] == 26.4 and s[3] == 10.0, "Stratholme sits where Forever's Eastern Plaguelands map has it")
end

WorldMapFrame:Show()
local n, small, list = Pins()
Check(n == 15 and small == 0, "Alterac Mountains map: 15 pins, got " .. n)
do
    local p
    for _, q in ipairs(list) do if q.area.name == "Crushridge Hold" then p = q end end
    local _, _, _, x, y = p:GetPoint(1)
    Check(math.abs(x - 484.9) < 1 and math.abs(y + 279.9) < 1, "Crushridge Hold pin at 48.4, 41.9 of the canvas")
    p:GetScript("OnEnter")(p)
    p:GetScript("OnLeave")(p)
    p:Click()
    Check(waypoint and waypoint.map == 1416 and math.abs(waypoint.x - 0.484) < 0.001, "clicking a pin sets the map pin")
end

-- Explore two areas: their pins go, chat says so once each.
doneSet[443], doneSet[444] = true, true
FireEvent("ZONE_CHANGED")
FlushTimers()
n = Pins()
Check(n == 13, "two areas ticked: 13 pins left, got " .. n)
Check(Printed("Crushridge Hold explored%. Zone 1416: 2/15%."), "chat line for a newly ticked area")

-- And a popup each, one after the other.
do
    local toast = ExplorerToast
    local step = toast and toast:GetScript("OnUpdate")
    Check(toast and toast:IsShown() and toast._alpha == 0, "popup comes up for a newly ticked area, faded out to start")
    Check(toast.sub:GetText() == "Zone 1416  2/15", "popup names the zone and its count")
    Check(not toast._mouse, "popup lets clicks through")
    local first = toast.name:GetText()
    step(toast, 0.3)
    Check(toast._alpha == 1, "popup fades in")
    step(toast, 3)
    Check(toast.name:GetText() ~= first and toast:IsShown(), "second area's popup follows the first")
    local names = { [first] = true, [toast.name:GetText()] = true }
    Check(names["Crushridge Hold"] and Count(names) == 2, "both areas got a popup")
    step(toast, 0.3)
    step(toast, 4.5)
    Check(toast._alpha < 1 and toast._alpha > 0, "popup fades out after its hold")
    step(toast, 1)
    Check(not toast:IsShown(), "popup goes away")
end

-- Zoom: pins keep their screen size.
canvas:SetScale(2)
Tick()
_, _, list = Pins()
Check(list[1]:GetWidth() == 12, "zoomed in 2x: pin is 24/2 wide on the canvas")
canvas:SetScale(1)
Tick()

-- Continent map: dots for the zone you're in, nothing for the others.
viewed = 1415
Tick()
n, small, list = Pins()
Check(n == 13 and small == 13, "continent map: 13 dots, all in the zone you're in, got " .. n)
waypoint = nil
list[1]:Click()
Check(viewed == 1415 and waypoint and waypoint.map == 1416, "clicking a dot sets a waypoint, map stays")
viewed = 947
Tick()
Check(Pins() == 0, "world map: no pins")

-- Another zone's map: small faint markers, a level under the pins. Or full pins, or nothing.
viewed = 1417
Tick()
do
    local faint
    n, small, list, faint = Pins()
    Check(n == 16 and faint == 16, "another zone's map: 16 faint markers, got " .. n)
    local p = list[1]
    Check(p:GetWidth() < 24 * 0.4 and p._alpha == 0.6 and p:GetFrameLevel() == layer:GetFrameLevel(),
        "a faint marker is small, see-through and under the pins")
    p:GetScript("OnEnter")(p)
    Check(p._alpha == 1, "and solid while the mouse is on it")
    p:GetScript("OnLeave")(p)
    waypoint = nil
    p:Click()
    Check(waypoint and waypoint.map == 1417, "clicking a faint marker sets a waypoint")
end
ns.db.others = "pins"
ns.RefreshPins()
n, small = Pins()
Check(n == 16 and small == 0, "another zone's map, 'Full pins': its 16 pins")
ns.db.others = "none"
ns.RefreshPins()
Check(Pins() == 0, "another zone's map, 'Nothing': none")
ns.db.others = "faint"

-- Travel there: its pins come up.
player.map = 1417
Tick()
Check(Pins() == 16, "now in that zone: its 16 pins")
player.map = 1416

-- "Explored 7/9" under the zone name the map's hover label shows.
do
    local hover = mapLabel:GetChildren()
    Check(hover ~= nil, "hover line hangs off the map's label")
    local function Hover(name, desc)
        mapLabel.Name:SetText(name)
        mapLabel.Description:SetText(desc)
        hover:GetScript("OnUpdate")(hover, 0.1)
        return hover.line:IsShown() and hover.line:GetText() or nil
    end
    Check(Hover("Zone 1416 |cffff8040(30-40)|r") == "Explored 2/15", "hovering a zone with areas left: Explored 2/15")
    local _, anchor = hover.line:GetPoint(1)
    Check(anchor == mapLabel.Name, "the line sits under the name")
    Hover("Zone 1416", "Fishing 150")
    _, anchor = hover.line:GetPoint(1)
    Check(anchor == mapLabel.Description, "and under the description when the label has one")
    Check(Hover("Crushridge Hold") == nil, "hovering an area: no line")
    for _, z in ipairs(ns.Zones) do
        if z[2] == 1430 then for i = 3, #z do doneSet[z[i]] = true end end
    end
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    Check(Hover("Zone 1430") == nil, "hovering a fully explored zone: no line")
    ns.db.hoverLine = false
    Check(Hover("Zone 1416") == nil, "setting off: no line")
    ns.db.hoverLine = true
    Hover("")
end
-- OpenMap's stitched map: a mock world with the zones in an 8-wide grid, each 1/8 of it across.
do
    local cell = {}
    for i, z in ipairs(ns.Zones) do cell[z[2]] = { ((i - 1) % 8) / 8, math.floor((i - 1) / 8) / 8, 1 / 8 } end
    cell[1415] = { 0, 0, 1 }
    cell[947] = { 0, 0, 1 }
    local stitched = true
    OpenMapAPI = {
        IsStitched = function() return stitched end,
        ArtTopLevel = function() return 3000 end,
        WorldFromMap = function(m, x, y) local c = cell[m] if c then return c[1] + x * c[3], c[2] + y * c[3] end end,
        MapFromWorld = function(m, u, v) local c = cell[m] if c then return (u - c[1]) / c[3], (v - c[2]) / c[3] end end,
    }
    viewed = 1415
    Tick()
    n, small, list = Pins()
    Check(n == 13 and small == 13, "OpenMap, whole continent in view: 13 dots in the zone you're in, got " .. n)
    Check(layer:GetFrameLevel() == 3002 and list[1]:GetFrameLevel() == 3003, "OpenMap: pins lifted above its art")
    waypoint = nil
    list[1]:Click()
    Check(viewed == 1415 and waypoint ~= nil, "OpenMap: clicking a dot sets a waypoint")

    canvas:SetScale(0.5)
    Tick()
    Check(Pins() == 0, "OpenMap, zoomed far out: zones too small for pins")
    canvas:SetScale(1)

    -- Zoomed into Alterac: the map underneath is the zone, and its neighbours are on the canvas too.
    viewed = 1416
    Tick()
    local faint
    n, small, list, faint = Pins()
    local own, far, wrong = 0, 0, 0
    for _, p in ipairs(list) do
        if p.area.map == 1416 then own = own + 1 end
        if (p.area.map == 1416) ~= (p.style == "pin") then wrong = wrong + 1 end
        local _, _, _, x = p:GetPoint(1)
        if math.abs(x / 1002 - 0.5) > 1.0001 then far = far + 1 end
    end
    Check(own == 13 and wrong == 0 and faint == n - 13 and faint > 0,
        "OpenMap, zone level: your zone's 13 full pins, the neighbours' as faint markers (" .. faint .. ")")
    Check(far == 0, "OpenMap: none past the margin")
    scroll.x = 1.2
    Tick()
    local before = n
    n = Pins()
    Check(n ~= before, "OpenMap: panning brings in the next zones' markers")
    scroll.x = 0.5

    -- Zoomed into a zone you're not in: its areas as faint markers.
    viewed = 1417
    Tick()
    local theirs = 0
    for _, p in ipairs(select(3, Pins())) do
        if p.area.map == 1417 and p.style == "faint" then theirs = theirs + 1 end
    end
    Check(theirs == 16, "OpenMap, zoomed into another zone: its 16 faint markers")

    ns.db.others = "none"
    ns.RefreshPins()
    n, small = Pins()
    Check(select(4, Pins()) == 0, "OpenMap, 'Nothing': no markers for other zones")
    ns.db.others = "faint"

    -- Continent level: only the zone you're in, as dots.
    viewed = 1415
    Tick()
    n, small, list, faint = Pins()
    Check(n == 13 and small == 13 and faint == 0, "OpenMap, continent in view: only your zone's dots, no faint markers")

    stitched = false
    viewed = 1416
    Tick()
    n = Pins()
    Check(n == 13 and layer:GetFrameLevel() == 501, "OpenMap showing a plain map: the zone's own 13 pins, level back")
    OpenMapAPI = nil
end

-- Settings.
viewed = 1416
Tick()
ns.db.pins = false
ns.RefreshPins()
Check(Pins() == 0, "pins off: none shown")
ns.db.pins = true
ns.RefreshPins()

-- Window.
SlashCmdList.EXPLORER("")
Check(ExplorerFrame and ExplorerFrame:IsShown(), "/ep opens the window")
local done, total = ns.Totals()
Check(done == 5 and total == 549, "totals: 5 of 549")
Explorer_OnCompartmentClick()
Check(not ExplorerFrame:IsShown(), "compartment click closes it")

-- /ep next: nearest missing area to the player.
player.x, player.y = 0.47, 0.20
waypoint = nil
SlashCmdList.EXPLORER("next")
Check(waypoint and Printed("Waypoint set on Dandred's Fold"), "/ep next picks the nearest missing area")
player.map = 1453
PRINTED = {}
SlashCmdList.EXPLORER("next")
Check(Printed("no explore challenge"), "/ep next in a city says there is nothing here")
SlashCmdList.EXPLORER("list")
Check(Printed("5 of 549 areas explored"), "/ep list prints the totals")

-- Clients that don't hand back the asset, or anything but the tick.
player.map = 1416
for _, mode in ipairs({ "name", "bare" }) do
    MODE = mode
    FireEvent("ACHIEVEMENT_EARNED")
    Tick()
    n = Pins()
    done, total = ns.Totals()
    Check(n == 13 and done == 5 and total == 549, "criteria matched by " .. mode .. ": 13 pins, 5 of 549")
end

-- The route: the zone you're in first, its stops in a short path from where you stand.
MODE = "asset"
FireEvent("ACHIEVEMENT_EARNED")
do
    local R = ns.Route
    local function Plan()
        R.Replan()
        for _ = 1, 2000 do R.Step() end
        return R.Order()
    end
    player.map, player.x, player.y = 1416, 0.47, 0.20
    local order, done = Plan()
    local stop = R.Next()
    Check(stop and stop.name == "Dandred's Fold", "route starts at the nearest area: " .. tostring(stop and stop.name))
    local stops, zonesSeen, twice = 0, {}, 0
    for _, e in ipairs(order) do
        if zonesSeen[e.id] then twice = twice + 1 end
        zonesSeen[e.id] = true
        stops = stops + #e.stops
    end
    local open = 0   -- zones with areas left (the tests above finished one)
    for _, zone in ipairs(ns.Progress()) do
        if zone.done < zone.total then open = open + 1 end
    end
    Check(done and order[1].map == 1416 and #order == open and open >= 42 and twice == 0 and stops == 544,
        "route covers every zone once, yours first: " .. #order .. " zones, " .. stops .. " stops")
    Check(trails > 0 and trails < 43 * 42 / 2, "zone order asked the pathfinder, but not for every pair (" .. trails .. " lookups)")
    do
        -- the path through the zone: no shorter one by swapping the order of two neighbours
        local e, len = order[1], 0
        local prev = { x = 47, y = 20 }
        for _, o in ipairs(e.stops) do
            local a = ns.AreaByOverlay(o)
            len = len + math.sqrt(((a.x - prev.x) * 1.5) ^ 2 + (a.y - prev.y) ^ 2)
            prev = a
        end
        Check(#e.stops == 13 and len < 330, ("your zone's 13 stops in a %.0f-point path"):format(len))
    end

    -- On the map: numbers, a line between stops, the next one marked.
    viewed = 1416
    Tick()
    local numbered, nextPin, bad = 0, nil, 0
    for _, p in ipairs(select(3, Pins())) do
        if p.numHolder and p.numHolder:IsShown() then
            numbered = numbered + 1
            local _, si = R.Index(p.area.overlay)
            if tostring(p.num:GetText()) ~= tostring(si) then bad = bad + 1 end
        end
        if p.isNext then nextPin = p end
    end
    local lineCount = 0
    for _, r in ipairs({ layer:GetRegions() }) do
        if r:GetObjectType() == "Line" and r:IsShown() then lineCount = lineCount + 1 end
    end
    Check(numbered == 13 and bad == 0 and lineCount == 12, "map: 13 numbered pins joined by 12 lines")
    Check(nextPin and nextPin.area.overlay == stop.overlay, "map: the next stop's pin is marked")

    -- The arrow: at the stop, turned by the bearing less the way you face.
    facing = 0.5
    ns.Route.Tick()
    ns.RefreshArrow()
    local arrow = ExplorerArrow
    local north, west = -(stop.y / 100 - 0.20) * 1000, -(stop.x / 100 - 0.47) * 1500
    Check(arrow and arrow:IsShown() and arrow.title:GetText() == "Dandred's Fold", "arrow names the next stop")
    Check(arrow.turn and math.abs(arrow.turn - (math.atan2(west, north) - 0.5)) < 1e-6, "arrow turns to the stop's bearing")
    Check(arrow.dist:GetText():find(("%d yd"):format(math.sqrt(north ^ 2 + west ^ 2))), "arrow gives the distance: " .. arrow.dist:GetText())
    Check(arrow.sub:GetText() == "Zone 1416  2/15", "arrow's last line is the zone's count")
    waypoint = nil
    arrow:Click("LeftButton")
    Check(waypoint and waypoint.map == 1416, "clicking the arrow sets a waypoint on the stop")

    -- An area ticks: the route moves on.
    doneSet[stop.overlay] = true
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    local after = R.Next()
    Check(after and after.overlay ~= stop.overlay and #select(1, R.Order())[1].stops == 12, "a tick moves the route to the next stop")
    arrow:Click("RightButton")
    Check(R.Next().overlay ~= after.overlay and #select(1, R.Order())[1].stops == 11, "right-clicking the arrow skips a stop")

    -- Out of the zone (a city, nothing to explore there): the way back is a travel leg.
    player.map, player.x, player.y = 1453, 0.5, 0.5
    now = now + 10
    R.Tick()
    ns.RefreshArrow()
    local g = R.Guide()
    Check(g and g.leg and trailsTo == 1 and arrow.title:GetText() == "Talk to the Flightmaster to travel to Testville",
        "another zone's stop: the arrow shows the first leg of the trip")
    Check(arrow.sub:GetText():find("^to .+, Zone 1416$"), "and where the trip ends: " .. arrow.sub:GetText())
    R.Tick()
    Check(trailsTo == 1, "the leg isn't looked up again within three seconds")
    onTaxi = true
    ns.RefreshArrow()
    Check(arrow.title:GetText() == "In flight" and not arrow.tex:IsShown(), "on a flight: no arrow, just where you're going")
    onTaxi = false

    -- Walking into another zone with stops puts it first.
    player.map, player.x, player.y = 1417, 0.5, 0.5
    R.Tick()
    for _ = 1, 2000 do R.Step() end
    Check(select(1, R.Order())[1].map == 1417 and R.Next().map == 1417, "walking into another zone puts its stops first")

    -- Settings: what the route covers, and zones above your level.
    player.map, player.x, player.y = 1416, 0.47, 0.20
    ns.db.routeScope = "zone"
    order = Plan()
    Check(#order == 1 and order[1].map == 1416, "'The zone I'm in': one zone")
    ns.db.routeScope = "all"
    level = 20
    order = Plan()
    local want, high = 0, 0
    for _, zone in ipairs(ns.Progress()) do
        if zone.done < zone.total then
            local zl = ns.ZoneLevels[zone.map]
            if zone.map == 1416 or not zl or zl <= 25 then want = want + 1 else high = high + 1 end
        end
    end
    Check(#order == want and high > 10 and order[1].map == 1416, "level 20: " .. high .. " zones above level 25 left out, your own zone kept")
    ns.db.routeAllLevels = true
    Check(#Plan() == open, "'Leave out zones above me' off: all of them")
    ns.db.routeAllLevels = false
    level = 60

    -- The window lists the route's zones in order.
    Plan()
    SlashCmdList.EXPLORER("")
    Check(ExplorerFrame:IsShown(), "window opens with a route")
    ExplorerFrame:Hide()
    PRINTED = {}
    SlashCmdList.EXPLORER("route")
    Check(Printed("1%. Zone 1416: 12 stops, first "), "/ep route prints the plan")
    ns.db.arrow = false
    ns.RefreshArrow()
    Check(not arrow:IsShown(), "arrow setting off: hidden")
    ns.db.arrow = true
    ns.db.route = false
    R.Tick()
    Tick()
    numbered = 0
    for _, p in ipairs(select(3, Pins())) do
        if p.numHolder and p.numHolder:IsShown() then numbered = numbered + 1 end
    end
    Check(R.Next() == nil and numbered == 0, "route setting off: no route, no numbers")
    ns.db.route = true
end

-- Walking: straight where the ground is clear, by road where it isn't.
do
    local Nav = ns.Nav
    local function At(name)
        for _, a in pairs(ns.Areas) do
            if a[1] == 1423 and a[4] == name then return EPL(a[2] / 100, a[3] / 100) end
        end
    end
    local function Walk(from, to)
        local ax, ay = At(from)
        local bx, by = At(to)
        local yards, how, points = Nav.From(0, ax, ay).Path(bx, by)
        return yards, how, points, math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
    end
    Check(Nav.Knows(0) and not Nav.Knows(99), "walking data: the Eastern Kingdoms, not the test continent")
    local yards, how, points, bird = Walk("The Marris Stead", "Crown Guard Tower")
    Check(how == "direct" and #points == 0 and math.abs(yards - bird) < bird * 0.02, "clear ground: a straight walk")
    yards, how, points, bird = Walk("Stratholme", "Tyr's Hand")
    Check(how == "road" and #points >= 12 and yards > bird * 1.1 and yards < bird * 2,
        ("Stratholme to Tyr's Hand goes by road: %d yd through %d junctions, %d as the bird flies"):format(yards, #points / 2, bird))
    yards, how = Walk("Thondroril River", "Zul'Mashar")
    Check(yards and how == "road", "a pin the terrain says can't be reached still gets a way: the road as far as it goes")
    do
        local ax, ay = At("Corin's Crossing")
        local bx, by = At("Light's Hope Chapel")
        local _, _, pts = Nav.From(0, ax, ay).Path(bx, by)
        local hx, hy = Nav.Ahead(0, ax, ay, pts, bx, by)
        local onWay = false
        for i = 1, #pts - 1, 2 do
            if pts[i] == hx and pts[i + 1] == hy then onWay = true end
        end
        Check(onWay and Nav.Segment(0, ax, ay, hx, hy) ~= nil, "the point to head for is a junction on the way, in clear sight")
        local lx, ly = pts[#pts - 1], pts[#pts]
        hx, hy = Nav.Ahead(0, lx, ly, { lx, ly }, bx, by)
        Check(hx == bx and hy == by, "at the last junction the way points at the stop itself")
    end

    -- In Eastern Plaguelands the route's stops are ordered by those walks, and drawn along them.
    local R = ns.Route
    player.map, player.x, player.y = 1423, 0.52, 0.596
    R.Replan()
    for _ = 1, 3000 do R.Step() end
    R.Tick()
    for _ = 1, 3000 do R.Step() end
    local e = R.Order()[1]
    local ways = 0
    for _ in pairs(e.ways or {}) do ways = ways + 1 end
    Check(e.map == 1423 and #e.stops == 22 and ways >= 10, "Eastern Plaguelands: 22 stops in walking order, " .. ways .. " of the hops by road")
    local len, straight = 0, 0
    do
        -- the walk along the order, against the straight-line order's walk
        local function PathLen(stops)
            local total, px, py = 0, EPL(0.52, 0.596)
            local onto
            for _, o in ipairs(stops) do
                local a = ns.AreaByOverlay(o)
                local ax, ay = EPL(a.x / 100, a.y / 100)
                local off = Nav.Approach(0, o)
                total = total + (Nav.From(0, px, py, onto).Walk(ax, ay, off) or 0)
                px, py, onto = ax, ay, off
            end
            return total
        end
        len = PathLen(e.stops)
        local areas = {}
        for _, o in ipairs(e.stops) do areas[#areas + 1] = ns.AreaByOverlay(o) end
        table.sort(areas, function(a, b) return a.overlay < b.overlay end)
        local rough, cur = {}, { x = 52, y = 59.6 }
        while #areas > 0 do   -- nearest next by the map alone
            local pick, near
            for i, a in ipairs(areas) do
                local d = ((a.x - cur.x) * 1.5) ^ 2 + (a.y - cur.y) ^ 2
                if not near or d < near then pick, near = i, d end
            end
            cur = table.remove(areas, pick)
            rough[#rough + 1] = cur.overlay
        end
        straight = PathLen(rough)
    end
    Check(len <= straight * 1.02, ("walking order is no longer than the straight-line order: %d against %d yd"):format(len, straight))

    local g = R.Guide()
    Check(g and g.stop.map == 1423 and g.way ~= nil, "the guide has the walk to the next stop")
    -- pass over stops until the next one is a walk by road
    for _ = 1, 8 do
        if g.way and g.way.points then break end
        R.Skip()
        for _ = 1, 500 do R.Step() end
        g = R.Guide()
    end
    ns.RefreshArrow()
    local arrow = ExplorerArrow
    Check(g.way.points and arrow:IsShown() and arrow.dist:GetText():find("^%d[%d.k]* yd by road"),
        "a stop behind blocked ground: the arrow counts the walk by road: " .. arrow.dist:GetText())
    do
        local wx, wy = EPL(0.52, 0.596)
        local tx, ty = EPL(g.stop.x / 100, g.stop.y / 100)
        local along, straightAt = math.atan2(g.way.y - wy, g.way.x - wx), math.atan2(ty - wy, tx - wx)
        Check(math.abs(arrow.turn - (along - facing)) < 1e-6 and (g.way.x ~= tx or g.way.y ~= ty),
            ("and points at the road ahead (%.0f degrees off the straight line)"):format(math.abs(along - straightAt) * 180 / math.pi))
    end
    viewed = 1423
    Tick()
    local lineCount = 0
    for _, r in ipairs({ layer:GetRegions() }) do
        if r:GetObjectType() == "Line" and r:IsShown() then lineCount = lineCount + 1 end
    end
    Check(lineCount > 21 + ways, "map: the line between stops bends along the roads (" .. lineCount .. " stretches for 22 stops)")
    player.map, player.x, player.y = 1416, 0.47, 0.20
    viewed = 1416
    R.Replan()
    for _ = 1, 3000 do R.Step() end
end

-- Mount Hyjal, as it was reported: three stops left, the player in the Tainted Foothills, and
-- the route drawn straight through the cliffs between a handful of road junctions.
do
    local R, Nav = ns.Route, ns.Nav
    local function Pump() for _ = 1, 4000 do R.Step() end end
    for _, o in ipairs({ 4988, 4989, 4991, 4993, 4995, 4996 }) do doneSet[o] = true end
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    player.map, player.x, player.y = 2482, 0.686, 0.692
    R.Replan()
    Pump()
    R.Tick()
    Pump()
    local e = R.Order()[1]
    Check(e.map == 2482 and #e.stops == 3, "Mount Hyjal: its three stops come first")

    -- how much of a line through these world points lies over ground the data has blocked
    local function Blocked(points, fx, fy, tx, ty)
        local line = { { fx, fy } }
        for i = 1, #points - 1, 2 do line[#line + 1] = { points[i], points[i + 1] } end
        line[#line + 1] = { tx, ty }
        local total, bad = 0, 0
        for i = 2, #line do
            local a, b = line[i - 1], line[i]
            local d = math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)
            total = total + d
            if not Nav.Segment(1, a[1], a[2], b[1], b[2]) then bad = bad + d end
        end
        return bad, total, #line - 1
    end
    local px, py = HYJAL(0.686, 0.692)
    local worst, legs = 0, 0
    for _, overlay in ipairs({ 4994, 4992, 4990 }) do
        local a = ns.Areas[overlay]
        local tx, ty = HYJAL(a[2] / 100, a[3] / 100)
        local onto = Nav.Reach(1, px, py)
        local yards, how, points = Nav.From(1, px, py, #onto > 0 and onto or nil).Path(tx, ty, Nav.Approach(1, overlay))
        if yards and how == "road" then
            legs = legs + 1
            local bad, total = Blocked(points, px, py, tx, ty)
            worst = math.max(worst, bad / total)
        end
    end
    Check(legs == 3 and worst < 0.12, ("Mount Hyjal: all three stops have a way by road, at most %d%% of one over blocked ground"):format(worst * 100))
    do
        -- the same walk as the junction-to-junction data alone gives it: through the cliffs
        local a = ns.Areas[4992]
        local tx, ty = HYJAL(a[2] / 100, a[3] / 100)
        local shapes, approach, bends = ns.Shapes, ns.Approach, ns.Bends
        ns.Shapes, ns.Approach, ns.Bends = nil, nil, nil
        local _, _, points = Nav.From(1, px, py).Path(tx, ty)
        ns.Shapes, ns.Approach, ns.Bends = shapes, approach, bends
        local bad, total = Blocked(points, px, py, tx, ty)
        Check(bad / total > 0.25, ("(without the roads' courses %d%% of that walk is over blocked ground)"):format(bad / total * 100))
    end

    local g = R.Guide()
    Check(g and g.way and g.way.points and #g.way.points >= 12, "the guide's way to the next stop follows the ground: " .. (g.way and g.way.points and #g.way.points / 2 or 0) .. " points")
    ns.RefreshArrow()
    Check(ExplorerArrow.dist:GetText():find("by road"), "arrow: " .. ExplorerArrow.dist:GetText())

    -- A flight inside the zone: taken for a long walk when it's clearly quicker, not otherwise.
    -- Two flight masters the character knows: one by the player, one by the stop.
    do
        local stop = R.Guide().stop
        local sx, sy = HYJAL(stop.x / 100, stop.y / 100)
        FarstriderLibData.TaxiNodes[9001] = { 1, px + 30, py, 0, 3, "Here" }
        FarstriderLibData.TaxiNodes[9002] = { 1, sx + 30, sy, 0, 3, "There" }
        FarstriderLibData_CharacterSettings.knownTaxiNodes = { [9001] = true, [9002] = true }
    end
    R.Replan()
    Pump()
    flyInZone = 30
    now = now + 10
    R.Tick()
    Pump()
    ns.RefreshArrow()
    g = R.Guide()
    Check(g.leg ~= nil and ExplorerArrow.title:GetText() == "Talk to the Flightmaster to travel to Testville",
        "a long walk inside the zone: the arrow sends you to the flight master when the flight is much quicker")
    flyInZone = 100000
    R.Replan()
    Pump()
    now = now + 10
    R.Tick()
    Pump()
    Check(R.Guide().leg == nil, "and keeps you walking when it isn't")
    flyInZone = false

    player.map, player.x, player.y = 1416, 0.47, 0.20
    R.Replan()
    Pump()
end

-- The sample popup: takes the mouse, drags, resizes, resets.
do
    local toast = ExplorerToast
    local step = toast:GetScript("OnUpdate")
    for _ = 1, 50 do step(toast, 100) end   -- run out the popups from the ticks above
    Check(not toast:IsShown(), "queued popups run out")
    SlashCmdList.EXPLORER("test")
    Check(toast:IsShown() and toast._mouse == true and toast.sub:GetText():find("Drag"), "/ep test shows a sample that takes the mouse")
    local _, _, _, _, y0 = toast:GetPoint(1)
    Check(y0 == -210, "popup sits 210 under the top of the screen by default")
    toast:GetScript("OnMouseWheel")(toast, 1)
    toast:GetScript("OnMouseWheel")(toast, 1)
    local _, _, _, _, y1 = toast:GetPoint(1)
    Check(math.abs(ns.db.popupScale - 1.2) < 0.001 and math.abs(toast:GetScale() - 1.2) < 0.001 and math.abs(y1 * 1.2 + 210) < 0.01,
        "scrolling on the sample resizes it in place")
    toast:GetScript("OnDragStart")(toast)
    step(toast, 60)
    Check(toast:IsShown(), "sample stays up while it's dragged")
    toast:ClearAllPoints()
    toast:SetPoint("CENTER", UIParent, "CENTER", 100, 50)   -- where the drag left it
    toast:GetScript("OnDragStop")(toast)
    local pos = ns.db.popupPos
    Check(pos and pos[1] == "CENTER" and math.abs(pos[3] - 120) < 0.01 and math.abs(pos[4] - 60) < 0.01, "dragging the sample saves its place")
    toast:GetScript("OnMouseUp")(toast, "RightButton")
    Check(ns.db.popupPos == nil and ns.db.popupScale == nil and toast:GetScale() == 1, "right-click puts the sample back")

    -- A real popup takes over from the sample; with the setting off there is none.
    local z = ZoneOf(760)
    local fresh = {}
    for i = 3, #z do if not doneSet[z[i]] then fresh[#fresh + 1] = z[i] end end
    doneSet[fresh[1]] = true
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    Check(toast:IsShown() and not toast._mouse and toast.name:GetText() == ns.Areas[fresh[1]][4], "a real popup replaces the sample")
    step(toast, 0.3); step(toast, 4.5); step(toast, 1)
    Check(not toast:IsShown(), "and goes away")
    ns.db.popup = false
    doneSet[fresh[2]] = true
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    Check(not toast:IsShown(), "popup setting off: no popup")
    ns.db.popup = true

    -- The last area of a zone.
    for i = 3, #fresh do doneSet[fresh[i]] = true end
    FireEvent("ZONE_CHANGED")
    FlushTimers()
    Check(toast:IsShown() and toast.sub:GetText() == "Zone 1416 fully explored", "last area: popup says the zone is fully explored")
end

-- A trip is weighed by the walk from where it lands, not the bird's distance. Reported: for
-- Highperch in Thousand Needles the arrow said to fly to Marshal's Refuge in Un'Goro Crater,
-- which is near on the map and a crater wall away on foot.
do
    local R, Nav = ns.Route, ns.Nav
    local nodes, id = FarstriderLibData.TaxiNodes, {}
    for nodeID, n in pairs(nodes) do
        if n[6] == "Marshal's Refuge, Un'Goro Crater" then id.refuge = nodeID end
        if n[6] == "Thalanaar, Feralas" then id.thalanaar = nodeID end
        if n[6] == "Gadgetzan, Tanaris" and n[5] == 1 then id.gadgetzan = nodeID end
    end
    local stop = ns.AreaByOverlay(689)
    Check(stop and stop.name == "Highperch" and id.refuge and id.thalanaar and id.gadgetzan, "the reported stop and its flight masters are in the data")
    local hx, hy = OnReal(1441, stop.x / 100, stop.y / 100)
    local function WalkFrom(nodeID)
        local n = nodes[nodeID]
        local yards = Nav.From(1, n[2], n[3], Nav.TaxiApproach(1, nodeID)).Walk(hx, hy, Nav.Approach(1, 689))
        return yards, math.sqrt((n[2] - hx) ^ 2 + (n[3] - hy) ^ 2)
    end
    local refuge, refugeBird = WalkFrom(id.refuge)
    local gadget = WalkFrom(id.gadgetzan)
    Check(not refuge or refuge > refugeBird * 4, ("Marshal's Refuge is %d yd from Highperch as the bird flies, and on foot: %s"):format(
        refugeBird, refuge and (math.floor(refuge) .. " yd") or "no way"))
    -- standing at Gadgetzan's flight master, knowing Gadgetzan and Marshal's Refuge
    local g = nodes[id.gadgetzan]
    local gx, gy = FromReal(1446, g[2], g[3])
    FarstriderLibData_CharacterSettings.knownTaxiNodes = { [id.gadgetzan] = true, [id.refuge] = true }
    R.Replan()
    local leg, trip = R.FindTrip(stop, 1446, gx, gy)
    Check(leg == nil and trip == nil and gadget ~= nil, ("knowing only Gadgetzan and Marshal's Refuge: walk the %d yd, no flight into the crater"):format(gadget or 0))
    -- and knowing Thalanaar as well, which is by Highperch on foot
    FarstriderLibData_CharacterSettings.knownTaxiNodes[id.thalanaar] = true
    R.Replan()
    leg, trip = R.FindTrip(stop, 1446, gx, gy)
    Check(leg ~= nil and trip and trip.arr.name == "Thalanaar, Feralas" and trip.dep.name == "Gadgetzan, Tanaris",
        "knowing Thalanaar too: fly there, " .. (trip and trip.arr and trip.arr.name or "?"))
    FarstriderLibData_CharacterSettings.knownTaxiNodes = {}
    R.Replan()
end

-- Reading progress. An area's state is the challenge's tick where the challenge reports it,
-- and the character's own map where it doesn't; a zone with neither is unknown, never done.
do
    local silithus = ZoneOf(856)
    local function Zone()
        FireEvent("ACHIEVEMENT_EARNED")
        for _, z in ipairs(ns.Progress()) do
            if z.id == 856 then return z end
        end
    end
    local z = Zone()
    Check(z.known and z.total == 6 and z.done == 0 and z.areas[1].source == "challenge", "Silithus: six areas, read from the challenge")

    -- the challenge lists nothing for the zone, and the game has no map record either
    local real = GetAchievementNumCriteria
    GetAchievementNumCriteria = function(id) if id == 856 then return 0 end return real(id) end
    z = Zone()
    Check(not z.known and z.total == 0 and z.done == 0, "a zone the game says nothing about is unknown, not fully explored")
    SlashCmdList.EXPLORER("")
    ExplorerFrame:Hide()

    -- the same, with the character's map to go by: two of its pieces are revealed
    local pieces = {}
    for i = 3, #silithus do
        local a = ns.Areas[silithus[i]]
        if a[6] ~= "" then pieces[#pieces + 1] = a[6] end
    end
    Check(#pieces == 5, "five of Silithus's six areas have a piece on the map in use (Cenarion Hold has none)")
    local function Piece(key)
        local w, h, x, y = key:match("(%d+):(%d+):(%d+):(%d+)")
        return { textureWidth = tonumber(w), textureHeight = tonumber(h), offsetX = tonumber(x), offsetY = tonumber(y) }
    end
    C_MapExplorationInfo = { GetExploredMapTextures = function(map)
        if map == 1451 then return { Piece(pieces[1]), Piece(pieces[2]) } end
        return {}
    end }
    z = Zone()
    Check(z.known and z.total == 5 and z.done == 2 and z.unread == 1 and z.areas[1].source == "map",
        ("no criteria from the challenge: the character's map is read instead (%d/%d, %s unread)"):format(z.done, z.total, tostring(z.unread)))
    viewed = 1451
    player.map = 1451
    Tick()
    Check(Pins() == 3, "and its three unrevealed areas get pins")

    -- the challenge back: its ticks count, the map's record is kept for the report
    GetAchievementNumCriteria = real
    doneSet[silithus[3]] = true
    z = Zone()
    local first
    for _, a in ipairs(z.areas) do if a.overlay == silithus[3] then first = a end end
    Check(z.total == 6 and z.done == 1 and first.done and first.source == "challenge", "with criteria the challenge's ticks are what counts")
    PRINTED = {}
    SlashCmdList.EXPLORER("check")
    Check(Printed("challenge 856: 1/6 explored") and Printed("lists 6 criteria; 6 matched") and Printed("revealed on your map"),
        "/ep check reports what the game says, area by area")
    C_MapExplorationInfo = nil
    player.map, viewed = 1416, 1416
end

FAILS = fails
