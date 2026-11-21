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
        -- every zone hangs off Eastern Kingdoms here; enough to test the dots
        return { name = "Zone " .. id, mapType = 3, parentMapID = 1415 }
    end,
    GetMapRectOnMap = function(zone, on) return 0.2, 0.4, 0.1, 0.3 end,
    GetBestMapForUnit = function() return player.map end,
    GetPlayerMapPosition = function() return { GetXY = function() return player.x, player.y end } end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) waypoint = p end,
}
UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }

ns = LoadAddon(ADDON_DIR, "Explorer", { "Theme.lua", "Widgets.lua", "Window.lua", "Data.lua", "Core.lua", "Toast.lua", "UI.lua" })
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

FAILS = fails
