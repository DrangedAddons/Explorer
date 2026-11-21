---------------------------------------------------------
--  Explorer - Window
--  Author: Dranged
---------------------------------------------------------
-- One window: what's left zone by zone (click a zone to open its map), then the settings.

local ADDON, NS = ...
local UI = NS.UI
local ICON = "Interface\\AddOns\\Explorer\\icon"

local window

local function OpenMap(mapID)
    if window then window:Hide() end
    if OpenWorldMap and pcall(OpenWorldMap, mapID) then return end
    if WorldMapFrame and not WorldMapFrame:IsShown() and ToggleWorldMap then pcall(ToggleWorldMap) end
    if WorldMapFrame and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
end

-- Zones with areas left first, in the Legacy window's order; finished ones after.
local function ZoneRows()
    local rows, finished = {}, {}
    for _, zone in ipairs(NS.Progress()) do
        if zone.done < zone.total or not zone.known then
            rows[#rows + 1] = zone
        else
            finished[#finished + 1] = zone
        end
    end
    for _, zone in ipairs(finished) do rows[#rows + 1] = zone end
    return rows
end

local function BuildWindow()
    local db = NS.db
    window = UI.Window({ name = "ExplorerFrame", title = "Explorer", width = 460, height = 660 })
    local body = window.body
    local y = 0
    local function Row(widget, h)
        widget:SetPoint("TOPLEFT", body, "TOPLEFT", 0, y)
        y = y - (h or 26)
        return widget
    end

    local summary = Row(UI.Text(body, "", "GameFontNormal"), 22)
    local hint = Row(UI.Text(body, "Unexplored areas have a spyglass pin on the map of the zone you're in and a small marker "
        .. "on other zones' maps. Click one to set a waypoint. Click a zone here to open its map.", "GameFontHighlightSmall"), 30)
    hint:SetWidth(420)

    local list = UI.List(body, 424, 20, 12, function(row, zone)
        if not row.count then
            row.count = UI.Text(row, "", "GameFontHighlight")
            row.count:SetPoint("RIGHT", -6, 0)
            row.count:SetJustifyH("RIGHT")
            row.text:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
        end
        UI.RenderRow(row, zone.name)
        if not zone.known then
            row.count:SetText("?")
            row.text:SetTextColor(0.5, 0.5, 0.5)
            row.count:SetTextColor(0.5, 0.5, 0.5)
        elseif zone.done >= zone.total then
            row.count:SetText("done")
            row.text:SetTextColor(0.5, 0.5, 0.5)
            row.count:SetTextColor(0.3, 0.8, 0.3)
        else
            row.count:SetText(zone.done .. "/" .. zone.total)
            row.text:SetTextColor(1, 1, 1)
            row.count:SetTextColor(1, 0.82, 0)
        end
    end, function(_, zone) OpenMap(zone.map) end)
    Row(list, 12 * 20 + 16)

    UI.Track({ Refresh = function()
        local done, total, unknown = NS.Totals()
        local text = ("%d of %d areas explored"):format(done, total)
        if total > done then text = text .. (", %d to go"):format(total - done) end
        if unknown > 0 then text = text .. " (still loading)" end
        summary:SetText(text)
        list:SetData(ZoneRows())
    end })

    Row(UI.Check(body, "Show pins on the world map", function() return db.pins end,
        function(v) db.pins = v; NS.RefreshPins() end))
    local scopeLabel = UI.Text(body, "Zones I'm not in", "GameFontHighlight")
    scopeLabel:SetPoint("TOPLEFT", body, "TOPLEFT", 28, y - 4)
    local scope = UI.Dropdown(body, 200, function()
        return {
            { value = "faint", label = "Small markers" },
            { value = "pins", label = "Full pins" },
            { value = "none", label = "Nothing" },
        }
    end, function() return db.others end, function(v) db.others = v; NS.RefreshPins() end)
    scope:SetPoint("LEFT", scopeLabel, "RIGHT", 10, 0)
    y = y - 30
    Row(UI.Check(body, "Show \"Explored 7/9\" under zone names on the map", function() return db.hoverLine end,
        function(v) db.hoverLine = v end))
    Row(UI.Check(body, "Say in chat when an area is explored", function() return db.announce end,
        function(v) db.announce = v end))
    Row(UI.Check(body, "Show minimap button", function() return not db.minimap.hide end,
        function(v) UI.SetLauncherShown(db.minimap, v) end), 34)

    Row(UI.Slider(body, "Pin size", 12, 48, 1, 260, function() return db.size end,
        function(v) db.size = v; NS.RefreshPins() end, true), 66)

    Row(UI.Text(body, "Window look", "GameFontNormalSmall"), 18)
    Row(UI.Dropdown(body, 260, function()
        local items = {}
        for _, o in ipairs(NS.LookOptions()) do items[#items + 1] = { value = o.value, label = o.text } end
        return items
    end, function() return db.theme end, function(v) NS.SetLook(v) end), 30)
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
        lines = { "Pins for unexplored areas are on the world map", "|cffffd100/ep next|r pins the nearest one" },
    })
end
