---------------------------------------------------------
--  Explorer - Window
--  Author: Dranged
---------------------------------------------------------
-- One window, two columns: what's left zone by zone in route order (click a zone to open
-- its map), and the settings.

local ADDON, NS = ...
local UI = NS.UI
local ICON = "Interface\\AddOns\\Explorer\\icon"

local LEFT_W, RIGHT_W, GAP = 424, 380, 24
local LIST_ROWS = 17

local window

local function OpenMap(mapID)
    if window then window:Hide() end
    if OpenWorldMap and pcall(OpenWorldMap, mapID) then return end
    if WorldMapFrame and not WorldMapFrame:IsShown() and ToggleWorldMap then pcall(ToggleWorldMap) end
    if WorldMapFrame and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
end

-- The route's zones first, in its order (each row gets its number); then other zones with
-- areas left, in the Legacy window's order; finished ones last.
local function ZoneRows()
    local rows, rest, finished = {}, {}, {}
    local placed = {}
    local order = NS.db.route and NS.Route.Order() or nil
    local byId = {}
    for _, zone in ipairs(NS.Progress()) do byId[zone.id] = zone end
    for i, e in ipairs(order or {}) do
        local zone = byId[e.id]
        if zone and not placed[zone] then
            placed[zone] = true
            rows[#rows + 1] = { zone = zone, stop = i, noWay = e.noWay }
        end
    end
    for _, zone in ipairs(NS.Progress()) do
        if not placed[zone] then
            if zone.done < zone.total or not zone.known then
                rest[#rest + 1] = { zone = zone, high = order ~= nil and NS.Route.TooHigh(zone) }
            else
                finished[#finished + 1] = { zone = zone }
            end
        end
    end
    for _, r in ipairs(rest) do rows[#rows + 1] = r end
    for _, r in ipairs(finished) do rows[#rows + 1] = r end
    return rows
end

local function BuildWindow()
    local db = NS.db
    window = UI.Window({ name = "ExplorerFrame", title = "Explorer", width = 18 + LEFT_W + GAP + RIGHT_W + 18, height = 520 })
    local body = window.body

    ---------------------------------------------------------
    --  Left: progress and the route
    ---------------------------------------------------------
    local y = 0
    local function Left(widget, h)
        widget:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
        y = y - (h or 26)
        return widget
    end

    local summary = Left(UI.Text(body, "", "GameFontNormal"), 20)
    local nextLine = Left(UI.Text(body, "", "GameFontHighlightSmall"), 18)
    nextLine:SetWidth(LEFT_W)
    local hint = Left(UI.Text(body, "Unexplored areas have a spyglass pin on the map of the zone you're in and a small marker "
        .. "on other zones' maps. Click one to set a waypoint. Click a zone here to open its map.", "GameFontHighlightSmall"), 32)
    hint:SetWidth(LEFT_W - 4)
    hint:SetTextColor(0.75, 0.75, 0.75)

    local list = UI.List(body, LEFT_W, 20, LIST_ROWS, function(row, r)
        if not row.count then
            row.count = UI.Text(row, "", "GameFontHighlight")
            row.count:SetPoint("RIGHT", -6, 0)
            row.count:SetJustifyH("RIGHT")
            row.text:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
        end
        local zone = r.zone
        UI.RenderRow(row, r.stop and (r.stop .. ". " .. zone.name) or zone.name)
        if not zone.known then
            row.count:SetText("?")
            row.text:SetTextColor(0.5, 0.5, 0.5)
            row.count:SetTextColor(0.5, 0.5, 0.5)
        elseif zone.done >= zone.total then
            row.count:SetText("done")
            row.text:SetTextColor(0.5, 0.5, 0.5)
            row.count:SetTextColor(0.3, 0.8, 0.3)
        elseif r.high then
            -- left out of the route for its level
            row.count:SetText(("level %d   %d/%d"):format(NS.ZoneLevels[zone.map], zone.done, zone.total))
            row.text:SetTextColor(0.7, 0.7, 0.7)
            row.count:SetTextColor(0.9, 0.45, 0.3)
        elseif r.noWay then
            -- in the route, last: no road there and nothing this faction can ride
            row.count:SetText(("no way there   %d/%d"):format(zone.done, zone.total))
            row.text:SetTextColor(0.7, 0.7, 0.7)
            row.count:SetTextColor(0.9, 0.45, 0.3)
        else
            row.count:SetText(zone.done .. "/" .. zone.total)
            row.text:SetTextColor(1, 1, 1)
            row.count:SetTextColor(1, 0.82, 0)
        end
    end, function(_, r) OpenMap(r.zone.map) end)
    Left(list, LIST_ROWS * 20 + 16)

    UI.Track({ Refresh = function()
        local done, total, unknown = NS.Totals()
        local text = ("%d of %d areas explored"):format(done, total)
        if total > done then text = text .. (", %d to go"):format(total - done) end
        if unknown > 0 then text = text .. " (still loading)" end
        summary:SetText(text)
        local stop = db.route and NS.Route.Next()
        if stop then
            local g = NS.Route.Guide()
            nextLine:SetText(("Next stop: |cffffd100%s|r, %s%s"):format(stop.name, stop.zone.name,
                g and g.noWay and (". |cffe6734d%s.|r"):format(NS.Route.NoWayText()) or ""))
        elseif db.route then
            nextLine:SetText(total > done and "No route: nothing left that the route settings cover." or "")
        else
            nextLine:SetText("")
        end
        list:SetData(ZoneRows())
    end })

    ---------------------------------------------------------
    --  Right: settings
    ---------------------------------------------------------
    local x0 = LEFT_W + GAP
    y = 0
    local function Right(widget, h)
        widget:SetPoint("TOPLEFT", body, "TOPLEFT", x0, y)
        y = y - (h or 26)
        return widget
    end
    local function Labelled(label, widget, h, indent)
        local text = UI.Text(body, label, "GameFontHighlight")
        text:SetPoint("TOPLEFT", body, "TOPLEFT", x0 + (indent or 28), y - 4)
        widget:SetPoint("LEFT", text, "RIGHT", 10, 0)
        y = y - (h or 30)
    end
    local function Refreshed() NS.Route.Tick(); UI.RefreshAll(); NS.RefreshPins() end

    Right(UI.Text(body, "Route", "GameFontNormal"), 20)
    Right(UI.Check(body, "Plan a route through what's left", function() return db.route end,
        function(v) db.route = v; Refreshed() end))
    Right(UI.Check(body, "Point the way with an arrow", function() return db.arrow end,
        function(v) db.arrow = v end))
    Labelled("Route covers", UI.Dropdown(body, 190, function()
        return {
            { value = "zone", label = "The zone I'm in" },
            { value = "continent", label = "This continent" },
            { value = "all", label = "Everything" },
        }
    end, function() return db.routeScope end, function(v) db.routeScope = v; Refreshed() end))
    Right(UI.Check(body, "Leave out zones more than 5 levels above me", function() return not db.routeAllLevels end,
        function(v) db.routeAllLevels = not v; Refreshed() end), 34)

    Right(UI.Text(body, "Map", "GameFontNormal"), 20)
    Right(UI.Check(body, "Show pins on the world map", function() return db.pins end,
        function(v) db.pins = v; NS.RefreshPins() end))
    Labelled("Zones I'm not in", UI.Dropdown(body, 190, function()
        return {
            { value = "faint", label = "Small markers" },
            { value = "pins", label = "Full pins" },
            { value = "none", label = "Nothing" },
        }
    end, function() return db.others end, function(v) db.others = v; NS.RefreshPins() end))
    Right(UI.Check(body, "Show \"Explored 7/9\" under zone names", function() return db.hoverLine end,
        function(v) db.hoverLine = v end))
    Right(UI.Slider(body, "Pin size", 12, 48, 1, 240, function() return db.size end,
        function(v) db.size = v; NS.RefreshPins() end, true), 62)

    Right(UI.Text(body, "When an area is explored", "GameFontNormal"), 20)
    local sample = UI.Button(body, "Sample", 80, 22, function() NS.ToastSample() end)
    sample:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, y - 1)
    sample:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Shows a sample popup.")
        GameTooltip:AddLine("Drag the sample to where popups should appear.", 1, 1, 1)
        GameTooltip:AddLine("Scroll on it to make it bigger or smaller.", 1, 1, 1)
        GameTooltip:AddLine("Right-click it to put both back.", 1, 1, 1)
        GameTooltip:Show()
    end)
    sample:HookScript("OnLeave", function() GameTooltip:Hide() end)
    Right(UI.Check(body, "Show a popup", function() return db.popup end,
        function(v) db.popup = v end))
    Right(UI.Check(body, "Say it in chat", function() return db.announce end,
        function(v) db.announce = v end), 34)

    Right(UI.Check(body, "Show minimap button", function() return not db.minimap.hide end,
        function(v) UI.SetLauncherShown(db.minimap, v) end), 30)
    Labelled("Window look", UI.Dropdown(body, 190, function()
        local items = {}
        for _, o in ipairs(NS.LookOptions()) do items[#items + 1] = { value = o.value, label = o.text } end
        return items
    end, function() return db.theme end, function(v) NS.SetLook(v) end), 30, 4)
end

function NS.ToggleWindow()
    if not NS.db then return end
    if not window then BuildWindow() end
    window:SetShown(not window:IsShown())
end

---------------------------------------------------------
--  SECTION: Launcher and Options page
---------------------------------------------------------
UI.RegisterSettingsPage(ICON, "/ep", function() NS.ToggleWindow() end)

function NS.InitUI()
    UI.Launcher({
        icon = ICON,
        db = NS.db.minimap,
        onLeft = NS.ToggleWindow,
        lines = { "Pins for unexplored areas are on the world map", "|cffffd100/ep route|r plans the way through them" },
    })
end
