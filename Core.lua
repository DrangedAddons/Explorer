---------------------------------------------------------
--  Explorer - Core
--  Author: Dranged
---------------------------------------------------------
-- The Legacy "Explore <zone>" challenges are achievements. Each of their criteria is one
-- area of the zone, and the criterion's asset is that area's map overlay ID. Data.lua maps
-- overlay IDs to a map position, so every criterion the game reports as not done gets a
-- pin on the world map.

local ADDON, NS = ...

local EXPLORE_AREA = 43   -- GetAchievementCriteriaInfo's criteria type for "explore area"
local CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local PIN_ICON = "Interface\\Icons\\INV_Misc_Spyglass_02"
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

local DEFAULTS = {
    pins = true,            -- pins on the world map
    scope = "here",         -- which zones get them: "here" (the zone you're in) or "view" (also any zone zoomed in on)
    hoverLine = true,       -- "Explored 7/9" under a zone's name on the map
    announce = true,        -- chat line when an area gets its tick
    size = 24,              -- pin size on a zone map
    theme = "auto",
}

local db

function NS.Print(msg)
    print("|cffffd100Explorer:|r " .. tostring(msg))
end

---------------------------------------------------------
--  SECTION: Progress
---------------------------------------------------------
-- NS.Progress() returns one entry per zone challenge:
--   { id, map, name, done, total, known, areas = { { overlay, name, map, x, y, done, zone } } }
-- known is false when the game gave no criteria for the challenge (data not in yet).
local progress
local dirty = true
local seen = {}   -- [overlay] = done at the last scan, to spot new ticks

local function ZoneName(z)
    local info = C_Map.GetMapInfo(z[2])
    if info and info.name and info.name ~= "" then return info.name end
    local _, title = GetAchievementInfo(z[1])
    return type(title) == "string" and title or ("Zone " .. z[2])
end

local function ScanZone(z)
    local id = z[1]
    local zone = { id = id, map = z[2], name = ZoneName(z), done = 0, total = 0, areas = {} }
    -- Fallbacks for a criterion that comes back without a usable asset: its name, then its place.
    local byName = {}
    for i = 3, #z do
        local a = NS.Areas[z[i]]
        if a then byName[a[4]] = z[i] end
    end
    local n = tonumber(GetAchievementNumCriteria(id)) or 0
    zone.known = n > 0
    local used = {}
    for i = 1, n do
        local text, ctype, done, _, _, _, _, asset = GetAchievementCriteriaInfo(id, i)
        if ctype == nil or ctype == EXPLORE_AREA then
            local overlay = (NS.Areas[asset] and asset) or byName[text] or z[i + 2]
            local a = overlay and NS.Areas[overlay]
            if a and not used[overlay] then
                used[overlay] = true
                zone.total = zone.total + 1
                if done then zone.done = zone.done + 1 end
                zone.areas[#zone.areas + 1] = {
                    overlay = overlay, name = (type(text) == "string" and text ~= "" and text) or a[4],
                    map = a[1], x = a[2], y = a[3], done = done and true or false, zone = zone,
                }
            end
        end
    end
    return zone
end

local function Scan()
    local first = next(seen) == nil
    local out = {}
    for _, z in ipairs(NS.Zones) do
        local ok, zone = pcall(ScanZone, z)
        if ok then
            out[#out + 1] = zone
            for _, a in ipairs(zone.areas) do
                if a.done and seen[a.overlay] == false and not first and db.announce then
                    NS.Print(("%s explored. %s: %d/%d."):format(a.name, zone.name, zone.done, zone.total))
                end
                seen[a.overlay] = a.done
            end
        end
    end
    progress, dirty = out, false
    return out
end

function NS.Progress()
    if dirty or not progress then return Scan() end
    return progress
end

-- Areas ticked and areas in total, plus how many challenges the game gave no criteria for.
function NS.Totals()
    local done, total, unknown = 0, 0, 0
    for _, zone in ipairs(NS.Progress()) do
        done, total = done + zone.done, total + zone.total
        if not zone.known then unknown = unknown + 1 end
    end
    return done, total, unknown
end

---------------------------------------------------------
--  SECTION: Map pin (the game's own waypoint)
---------------------------------------------------------
function NS.SetWaypoint(a)
    if not (C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
        NS.Print(("%s is at %.1f, %.1f."):format(a.name, a.x, a.y))
        return
    end
    if C_Map.CanSetUserWaypointOnMap then
        local ok, can = pcall(C_Map.CanSetUserWaypointOnMap, a.map)
        if ok and not can then
            NS.Print(("%s is at %.1f, %.1f (this map can't take a map pin)."):format(a.name, a.x, a.y))
            return
        end
    end
    -- WaypointUI names the waypoint; a plain pin would read "Map Pin" there. Its call sets
    -- the game's pin too. Coordinates are 0-100.
    local nav = WaypointUIAPI and WaypointUIAPI.Navigation
    local named = false
    if nav and nav.NewUserNavigation then
        local ok, res = pcall(nav.NewUserNavigation, { name = a.name, mapID = a.map, x = a.x, y = a.y })
        named = ok and res ~= nil
    end
    if not named then
        local ok = pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(a.map, a.x / 100, a.y / 100))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                C_SuperTrack.SetSuperTrackedUserWaypoint(true)
            end
        end)
        if not ok then
            NS.Print(("%s is at %.1f, %.1f."):format(a.name, a.x, a.y))
            return
        end
    end
    NS.Print(("Waypoint set on %s (%.1f, %.1f)."):format(a.name, a.x, a.y))
end

-- The nearest area still missing on the map the player is on.
function NS.Nearest()
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil, nil end
    local px, py = pos:GetXY()
    px, py = px * 100, py * 100
    local best, bestD, zoneName
    for _, zone in ipairs(NS.Progress()) do
        for _, a in ipairs(zone.areas) do
            if a.map == map then
                zoneName = zone.name
                if not a.done then
                    -- Zone maps are 3:2, so a percent across is 1.5x a percent down.
                    local dx, dy = (a.x - px) * 1.5, a.y - py
                    local d = dx * dx + dy * dy
                    if not bestD or d < bestD then best, bestD = a, d end
                end
            end
        end
    end
    return best, zoneName
end

---------------------------------------------------------
--  SECTION: World map pins
---------------------------------------------------------
-- Our own frame under the map canvas with our own buttons on it. Nothing of Blizzard's map
-- is hooked and no pin is taken from its pools: a check while the map is open notices map,
-- zoom and pan changes.
--
-- OpenMap (the stitched world map) draws on the same canvas. There the map underneath is
-- whichever zone or continent the view has settled on, the view runs past its edges into
-- the neighbours, and the close-up art sits at higher frame levels than Blizzard's pins.
-- So while it is stitched, pins are placed through OpenMapAPI for every zone in view and
-- the layer is lifted above its art.
local layer
local pins, used = {}, 0
local shownMap, shownScale, shownWidth, shownStitched, shownPlayerMap
local shownScrollX, shownScrollY, scrollSlackX, scrollSlackY
local wantLevel
local rects = {}

local BIG_FROM = 0.4     -- a zone this much of the view across gets full pins on OpenMap's map,
local DOTS_FROM = 0.08   -- this much gets dots, and anything smaller gets nothing

-- The zone map the player is on. Its areas are the ones that get pins.
local function PlayerMap()
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    return ok and type(map) == "number" and map or nil
end

local function Canvas()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    return sc and (sc.Child or sc)
end

-- Where a zone map sits on a continent map: minX, maxX, minY, maxY (0-1), or false.
local function RectOn(zoneMap, onMap)
    local key = zoneMap * 100000 + onMap
    local r = rects[key]
    if r == nil then
        r = false
        local info, isChild, guard = C_Map.GetMapInfo(zoneMap), false, 0
        while info and info.parentMapID and info.parentMapID > 0 and guard < 6 do
            if info.parentMapID == onMap then isChild = true break end
            info = C_Map.GetMapInfo(info.parentMapID)
            guard = guard + 1
        end
        if isChild and C_Map.GetMapRectOnMap then
            local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, zoneMap, onMap)
            if ok and type(minX) == "number" and type(maxY) == "number" and maxX > minX and maxY > minY then
                r = { minX, maxX, minY, maxY }
            end
        end
        rects[key] = r
    end
    return r
end

local function PinEnter(self)
    local a = self.area
    if not a then return end
    self.ring:SetVertexColor(1, 1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(a.name, 1, 0.82, 0)
    GameTooltip:AddDoubleLine(a.zone.name, a.zone.done .. "/" .. a.zone.total .. " explored", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine(("Not explored yet (%.1f, %.1f)"):format(a.x, a.y), 0.7, 0.7, 0.7)
    GameTooltip:AddLine("|cffffd100Click|r to set a waypoint here", 1, 1, 1)
    GameTooltip:Show()
end

local function PinLeave(self)
    self.ring:SetVertexColor(1, 0.82, 0)
    GameTooltip:Hide()
end

local function PinClick(self)
    if self.area then NS.SetWaypoint(self.area) end
end

local function Round(tex, owner)
    if not owner.CreateMaskTexture then return end
    local mask = owner:CreateMaskTexture()
    mask:SetAllPoints(tex)
    mask:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    tex:AddMaskTexture(mask)
end

local function NewPin()
    local p = CreateFrame("Button", nil, layer)
    if not InCombatLockdown() then pcall(p.SetFrameLevel, p, layer:GetFrameLevel() + 1) end
    p.edge = p:CreateTexture(nil, "BACKGROUND")
    p.edge:SetAllPoints()
    p.edge:SetColorTexture(0, 0, 0, 1)
    p.ring = p:CreateTexture(nil, "BORDER")
    p.ring:SetColorTexture(1, 1, 1, 1)
    p.ring:SetVertexColor(1, 0.82, 0)
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetTexture(PIN_ICON)
    p.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pcall(Round, p.edge, p)
    pcall(Round, p.ring, p)
    pcall(Round, p.icon, p)
    p:RegisterForClicks("LeftButtonUp")
    -- Right-click still zooms the map out through a pin. Not allowed in combat, and not needed.
    if p.SetPassThroughButtons and not InCombatLockdown() then
        pcall(p.SetPassThroughButtons, p, "RightButton")
    end
    p:SetScript("OnEnter", PinEnter)
    p:SetScript("OnLeave", PinLeave)
    p:SetScript("OnClick", PinClick)
    return p
end

local function SizePin(p, scale)
    -- The canvas is scaled by the zoom; dividing by it keeps pins one size on screen.
    local size = (p.small and db.size * 0.45 or db.size) / scale
    p:SetSize(size, size)
    local ringInset = size * (p.small and 0.16 or 0.07)
    p.ring:ClearAllPoints()
    p.ring:SetPoint("TOPLEFT", ringInset, -ringInset)
    p.ring:SetPoint("BOTTOMRIGHT", -ringInset, ringInset)
    local iconInset = size * 0.16
    p.icon:ClearAllPoints()
    p.icon:SetPoint("TOPLEFT", iconInset, -iconInset)
    p.icon:SetPoint("BOTTOMRIGHT", -iconInset, iconInset)
    p.icon:SetShown(not p.small)
end

local function CanvasScale(canvas)
    local s = canvas:GetScale()
    return (s and s > 0) and s or 1
end

local function Place(a, x, y, small, w, h, scale)
    used = used + 1
    local p = pins[used]
    if not p then
        p = NewPin()
        pins[used] = p
    end
    p.area, p.small = a, small
    SizePin(p, scale)
    p:ClearAllPoints()
    p:SetPoint("CENTER", layer, "TOPLEFT", x * w, -y * h)
    p:Show()
end

-- OpenMapAPI while the world map is showing OpenMap's stitched map, else nil.
local function Stitched()
    local api = OpenMapAPI
    if type(api) ~= "table" or not (api.IsStitched and api.WorldFromMap and api.MapFromWorld) then return nil end
    local ok, on = pcall(api.IsStitched)
    return ok and on and api or nil
end

-- The layer's frame level: with Blizzard's area icons, or just above OpenMap's art when that
-- reaches higher. A frame level on the map can't change in combat; the open map tries again.
local function FitLevel(api)
    local want = Canvas():GetFrameLevel() + 500
    if WorldMapFrame.GetPinFrameLevelsManager then
        local ok, lvl = pcall(function()
            return WorldMapFrame:GetPinFrameLevelsManager():GetValidFrameLevel("PIN_FRAME_LEVEL_AREA_POI")
        end)
        if ok and type(lvl) == "number" then want = lvl end
    end
    if api and api.ArtTopLevel then
        local ok, top = pcall(api.ArtTopLevel)
        if ok and type(top) == "number" and top + 2 > want then want = top + 2 end
    end
    wantLevel = want
    if layer:GetFrameLevel() == want or InCombatLockdown() then return end
    pcall(layer.SetFrameLevel, layer, want)
    for _, p in ipairs(pins) do pcall(p.SetFrameLevel, p, want + 1) end
end

-- Pins on OpenMap's stitched map. Each zone's corners go through OpenMapAPI to the canvas of
-- the map underneath (0-1 across it, and past it for the neighbours); its areas follow from
-- those. Zones outside the view and a margin are skipped, so panning far enough refreshes.
local function PlaceStitched(api, mapID, w, h, scale, playerMap)
    local sc = WorldMapFrame.ScrollContainer
    local viewW, viewH = sc:GetWidth(), sc:GetHeight()
    if not viewW or viewW <= 0 or not viewH or viewH <= 0 then return end
    local cx = sc.GetCurrentScrollX and sc:GetCurrentScrollX()
    local cy = sc.GetCurrentScrollY and sc:GetCurrentScrollY()
    local reachX, reachY
    if type(cx) == "number" and type(cy) == "number" then
        -- half the view, in canvas widths; pins are kept out to twice that from the centre
        local halfX, halfY = viewW / (2 * scale * w), viewH / (2 * scale * h)
        reachX, reachY = halfX * 2, halfY * 2
        shownScrollX, shownScrollY, scrollSlackX, scrollSlackY = cx, cy, halfX / 2, halfY / 2
    end
    local across = math.min(viewW, viewH * 1.5)   -- a zone map is 3:2; a wide window fits it by height
    for _, zone in ipairs(NS.Progress()) do
        if zone.done < zone.total then
            -- a zone's areas are all on one map, but read it per area in case one isn't
            local corners = {}
            for _, a in ipairs(zone.areas) do
                if not a.done then
                    local c = corners[a.map]
                    if c == nil then
                        c = false
                        local u0, v0 = api.WorldFromMap(a.map, 0, 0)
                        local u1, v1 = api.WorldFromMap(a.map, 1, 1)
                        if u0 and u1 then
                            local x0, y0 = api.MapFromWorld(mapID, u0, v0)
                            local x1, y1 = api.MapFromWorld(mapID, u1, v1)
                            if x0 and x1 then
                                local share = (x1 - x0) * w * scale / across
                                -- the zone you're in: dots once it's big enough to tell them apart, full
                                -- pins zoomed in. Other zones: only zoomed in, and only if asked for.
                                local small = share < BIG_FROM
                                local wanted
                                if a.map == playerMap then
                                    wanted = share >= DOTS_FROM
                                else
                                    wanted = db.scope == "view" and not small
                                end
                                if wanted then c = { x0, y0, x1 - x0, y1 - y0, small } end
                            end
                        end
                        corners[a.map] = c
                    end
                    if c then
                        local x, y = c[1] + c[3] * a.x / 100, c[2] + c[4] * a.y / 100
                        if not reachX or (math.abs(x - cx) <= reachX and math.abs(y - cy) <= reachY) then
                            Place(a, x, y, c[5], w, h, scale)
                        end
                    end
                end
            end
        end
    end
end

function NS.RefreshPins()
    if not layer then return end
    for i = 1, used do pins[i]:Hide(); pins[i].area = nil end
    used = 0
    if not layer:IsVisible() then return end
    local canvas = Canvas()
    local mapID = WorldMapFrame:GetMapID()
    local api = Stitched()
    -- The canvas has a set size; the layer only has anchors, which resolve a frame late.
    local w, h, scale = canvas:GetWidth(), canvas:GetHeight(), CanvasScale(canvas)
    local playerMap = PlayerMap()
    shownMap, shownScale, shownWidth, shownStitched, shownPlayerMap = mapID, scale, w, api ~= nil, playerMap
    shownScrollX, shownScrollY = nil, nil
    FitLevel(api)
    if not mapID or not db.pins then return end
    if not w or w <= 0 or not h or h <= 0 then return end
    if api then
        if pcall(PlaceStitched, api, mapID, w, h, scale, playerMap) then return end
        -- OpenMap's API didn't answer as expected: fall back to the plain map's pins
        for i = 1, used do pins[i]:Hide(); pins[i].area = nil end
        used, shownScrollX, shownScrollY = 0, nil, nil
    end
    local info = C_Map.GetMapInfo(mapID)
    local onContinent = info and info.mapType == CONTINENT
    for _, zone in ipairs(NS.Progress()) do
        if zone.done < zone.total then
            for _, a in ipairs(zone.areas) do
                if not a.done then
                    if a.map == mapID then
                        if a.map == playerMap or db.scope == "view" then
                            Place(a, a.x / 100, a.y / 100, false, w, h, scale)
                        end
                    elseif onContinent and a.map == playerMap then
                        -- the zone you're in, as dots on its continent's map
                        local r = RectOn(a.map, mapID)
                        if r then
                            Place(a, r[1] + (r[2] - r[1]) * a.x / 100, r[3] + (r[4] - r[3]) * a.y / 100,
                                true, w, h, scale)
                        end
                    end
                end
            end
        end
    end
end

---------------------------------------------------------
--  SECTION: "Explored 7/9" under a zone's name
---------------------------------------------------------
-- The map's hover label (the zone name at the top while the cursor is over a zone) gets a
-- line under it for a zone with areas left. The label is Blizzard's (OpenMap fills it too);
-- we only read its text and hang a line of our own below it.
local hover

local function Plain(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("%s*%b()%s*$", "")   -- OpenMap adds the zone's levels: "Arathi Highlands (30-40)"
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ZoneByName(name)
    for _, zone in ipairs(NS.Progress()) do
        if zone.name == name then return zone end
    end
end

local function HoverUpdate(self)
    local label = self.label
    local text = db.hoverLine and label.Name:GetText() or ""
    if type(text) ~= "string" then text = "" end
    local desc = label.Description
    local descText = desc and desc:IsShown() and desc:GetText() or ""
    local under = (type(descText) == "string" and descText ~= "") and desc or label.Name
    if text == self.text and under == self.under and not dirty then return end
    self.text, self.under = text, under
    local zone = text ~= "" and ZoneByName(Plain(text))
    if zone and zone.known and zone.done < zone.total then
        self.line:ClearAllPoints()
        self.line:SetPoint("TOP", under, "BOTTOM", 0, -2)
        self.line:SetText(("Explored %d/%d"):format(zone.done, zone.total))
        self.line:Show()
    else
        self.line:Hide()
    end
end

local function BuildHover()
    if hover then return true end
    local label
    for provider in pairs(WorldMapFrame.dataProviders or {}) do
        local l = type(provider) == "table" and provider.Label
        if type(l) == "table" and l.SetLabel and l.Name then label = l break end
    end
    if not label then return false end
    hover = CreateFrame("Frame", nil, label)
    hover:SetSize(1, 1)
    hover:SetPoint("TOP")
    hover.label = label
    hover.line = hover:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    -- the description line's own font, where the label has one
    local font = label.Description and label.Description.GetFontObject and label.Description:GetFontObject()
    if font then pcall(hover.line.SetFontObject, hover.line, font) end
    hover.line:SetTextColor(1, 1, 1)
    hover.line:Hide()
    hover:SetScript("OnUpdate", HoverUpdate)
    return true
end

---------------------------------------------------------
--  SECTION: Pin layer
---------------------------------------------------------
local function BuildLayer()
    if layer then return true end
    local canvas = Canvas()
    if not canvas then return false end
    layer = CreateFrame("Frame", nil, canvas)
    layer:SetAllPoints()
    FitLevel(nil)
    layer:SetScript("OnShow", function()
        if not hover then pcall(BuildHover) end   -- the label exists once the map has opened
        NS.RefreshPins()
    end)
    local since = 0
    layer:SetScript("OnUpdate", function(self, elapsed)
        local c = Canvas()
        -- every frame while the map zooms, so pins hold their size on screen
        if CanvasScale(c) ~= shownScale then
            since = 0
            NS.RefreshPins()
            return
        end
        since = since + elapsed
        if since < 0.1 then return end
        since = 0
        local stale = dirty or WorldMapFrame:GetMapID() ~= shownMap or c:GetWidth() ~= shownWidth
            or (Stitched() ~= nil) ~= shownStitched or PlayerMap() ~= shownPlayerMap
            or (wantLevel and self:GetFrameLevel() ~= wantLevel and not InCombatLockdown())
        if not stale and shownScrollX then
            -- OpenMap's map panned far enough for zones outside the margin to come into view
            local sc = WorldMapFrame.ScrollContainer
            local x, y = sc:GetCurrentScrollX(), sc:GetCurrentScrollY()
            stale = type(x) ~= "number" or type(y) ~= "number"
                or math.abs(x - shownScrollX) > scrollSlackX or math.abs(y - shownScrollY) > scrollSlackY
        end
        if stale then NS.RefreshPins() end
    end)
    NS.RefreshPins()
    return true
end

---------------------------------------------------------
--  SECTION: Events
---------------------------------------------------------
-- Entering a subzone is what explores it, so those events rescan (after the game has had a
-- moment to tick the criterion). The busier achievement events only mark the data stale;
-- the open map or window picks that up.
local rescan = false
local function RescanSoon(delay)
    dirty = true
    if rescan then return end
    rescan = true
    C_Timer.After(delay or 1.5, function()
        rescan = false
        dirty = true
        Scan()
        NS.RefreshPins()
        if NS.UI and NS.UI.RefreshAll and ExplorerFrame and ExplorerFrame:IsVisible() then
            NS.UI.RefreshAll()
        end
    end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            ExplorerDB = type(ExplorerDB) == "table" and ExplorerDB or {}
            db = ExplorerDB
            if db.zonePins ~= nil then   -- 0.1.0's two switches became one
                db.pins = db.zonePins
                db.zonePins, db.continentPins = nil, nil
            end
            for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
            db.minimap = type(db.minimap) == "table" and db.minimap or { hide = false }
            NS.db = db
        end
        -- The world map loads on demand on some clients.
        if db and not layer and BuildLayer() then self:UnregisterEvent("ADDON_LOADED") end
    elseif event == "PLAYER_LOGIN" then
        BuildLayer()
        for _, e in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA",
            "MAP_EXPLORATION_UPDATED", "CRITERIA_UPDATE", "ACHIEVEMENT_EARNED" }) do
            pcall(self.RegisterEvent, self, e)
        end
        if NS.InitUI then NS.InitUI() end
        RescanSoon(5)   -- the baseline the "explored" chat lines compare against
    elseif event == "CRITERIA_UPDATE" or event == "ACHIEVEMENT_EARNED" then
        dirty = true
    else
        RescanSoon()
    end
end)

---------------------------------------------------------
--  SECTION: Slash command
---------------------------------------------------------
local function PrintZones()
    local done, total, unknown = NS.Totals()
    NS.Print(("%d of %d areas explored."):format(done, total))
    for _, zone in ipairs(NS.Progress()) do
        if zone.done < zone.total then
            NS.Print(("  %s: %d left"):format(zone.name, zone.total - zone.done))
        end
    end
    if unknown > 0 then
        NS.Print(unknown .. " zone challenges gave no data yet. Try again in a moment.")
    end
end

SLASH_EXPLORER1 = "/explorer"
SLASH_EXPLORER2 = "/ep"
SlashCmdList.EXPLORER = function(msg)
    if not db then return end
    local cmd = (msg or ""):match("^%s*(%S*)"):lower()
    if cmd == "" then
        if NS.ToggleWindow then NS.ToggleWindow() end
    elseif cmd == "next" then
        dirty = true
        local a, zoneName = NS.Nearest()
        if a then
            NS.SetWaypoint(a)
        elseif zoneName then
            NS.Print("Nothing left to explore in " .. zoneName .. ".")
        else
            NS.Print("This map has no explore challenge.")
        end
    elseif cmd == "list" then
        dirty = true
        PrintZones()
    else
        NS.Print("/ep - open the window")
        NS.Print("/ep next - waypoint on the nearest unexplored area of this zone")
        NS.Print("/ep list - what's left, zone by zone")
    end
end

function Explorer_OnCompartmentClick()
    if NS.ToggleWindow then NS.ToggleWindow() end
end
