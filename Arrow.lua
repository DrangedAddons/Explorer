---------------------------------------------------------
--  Explorer - Guide arrow
--  Author: Dranged
---------------------------------------------------------
-- An arrow on screen that points at the route's next stop (Route.lua), or at the first
-- thing to do on the way there (a flight master, a boat), with what it is, how far and how
-- long. It turns as you turn: the bearing to the target minus the way you face.
-- Only the arrow itself takes the mouse; the text under it lets clicks through.

local ADDON, NS = ...
local UI = NS.UI

local TEXTURE = "Interface\\AddOns\\Explorer\\arrow"
local SIZE = 56
local DEFAULT_POS = { "CENTER", "CENTER", 0, 230 }   -- above centre, clear of the cast bar
local MIN_SCALE, MAX_SCALE = 0.6, 3
local FAST, SLOW = 0.03, 0.5       -- seconds between updates: shown, and nothing to show
local HERE = 15                    -- yards from a pin that counts as being there

local arrow
local shown = {}   -- the texts on it now, so they're only set when they change

local function Scale()
    local s = tonumber(NS.db and NS.db.arrowScale) or 1
    return math.max(MIN_SCALE, math.min(MAX_SCALE, s))
end

-- arrowPos holds offsets in UIParent's units, so the arrow stays put when its size changes.
local function Anchor()
    local p = NS.db and NS.db.arrowPos
    if type(p) ~= "table" or type(p[1]) ~= "string" or type(p[2]) ~= "string" then p = DEFAULT_POS end
    local s = Scale()
    arrow:SetScale(s)
    arrow:ClearAllPoints()
    arrow:SetPoint(p[1], UIParent, p[2], (tonumber(p[3]) or 0) / s, (tonumber(p[4]) or 0) / s)
end

local function Set(key, text)
    if shown[key] ~= text then
        shown[key] = text
        arrow[key]:SetText(text)
    end
end

local function Distance(yards)
    if yards >= 1000 then return ("%.1fk yd"):format(yards / 1000) end
    return ("%d yd"):format(yards)
end

local function Clock(seconds)
    if seconds >= 3600 then return ("%dh %02dm"):format(seconds / 3600, seconds % 3600 / 60) end
    return ("%d:%02d"):format(seconds / 60, seconds % 60)
end

local function Outline(fs)
    local font, size = fs:GetFont()
    if font and size then pcall(fs.SetFont, fs, font, size, "OUTLINE") end
end

local function Build()
    arrow = CreateFrame("Button", "ExplorerArrow", UIParent)
    arrow:SetSize(SIZE, SIZE)
    arrow:SetFrameStrata("MEDIUM")
    arrow:SetClampedToScreen(true)
    arrow:SetMovable(true)
    arrow:EnableMouse(true)
    arrow:EnableMouseWheel(true)
    arrow:RegisterForDrag("LeftButton")
    arrow:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    arrow.tex = arrow:CreateTexture(nil, "ARTWORK")
    arrow.tex:SetAllPoints()
    arrow.tex:SetTexture(TEXTURE)

    arrow.title = UI.Text(arrow, "", "GameFontNormal")
    arrow.title:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
    arrow.title:SetJustifyH("CENTER")
    arrow.dist = UI.Text(arrow, "", "GameFontHighlightSmall")
    arrow.dist:SetPoint("TOP", arrow.title, "BOTTOM", 0, -2)
    arrow.dist:SetJustifyH("CENTER")
    arrow.sub = UI.Text(arrow, "", "GameFontHighlightSmall")
    arrow.sub:SetPoint("TOP", arrow.dist, "BOTTOM", 0, -2)
    arrow.sub:SetJustifyH("CENTER")
    arrow.sub:SetTextColor(0.75, 0.75, 0.75)
    -- legible over the world; EllesmereUI's font, where it's on, brings its own outline
    Outline(arrow.title); Outline(arrow.dist); Outline(arrow.sub)
    if NS.NoteThemeFonts then pcall(NS.NoteThemeFonts, arrow) end

    arrow:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:StartMoving()
    end)
    arrow:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.dragging = false
        local point, _, relPoint, x, y = self:GetPoint(1)
        local s = Scale()
        if point then NS.db.arrowPos = { point, relPoint or point, (x or 0) * s, (y or 0) * s } end
    end)
    arrow:SetScript("OnMouseWheel", function(self, delta)
        NS.db.arrowScale = math.max(MIN_SCALE, math.min(MAX_SCALE, Scale() + (delta > 0 and 0.1 or -0.1)))
        Anchor()
    end)
    arrow:SetScript("OnClick", function(self, button)
        local g = NS.Route.Guide()
        if not (g and g.stop) then return end
        if button == "RightButton" then
            local stop = NS.Route.Skip()
            if stop then NS.Print(("Skipped %s. |cffffd100/ep route|r brings skipped stops back."):format(stop.name)) end
        else
            NS.SetWaypoint(g.stop)
        end
    end)
    arrow:SetScript("OnEnter", function(self)
        local g = NS.Route.Guide()
        if not (g and g.stop) then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -52)
        GameTooltip:AddLine(g.stop.name, 1, 0.82, 0)
        GameTooltip:AddDoubleLine(g.stop.zone.name, g.stop.zone.done .. "/" .. g.stop.zone.total .. " explored", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine("|cffffd100Click|r to set a waypoint on it", 1, 1, 1)
        GameTooltip:AddLine("|cffffd100Right-click|r to skip this stop", 1, 1, 1)
        GameTooltip:AddLine("|cffffd100Drag|r to move, |cffffd100scroll|r to resize", 1, 1, 1)
        GameTooltip:Show()
    end)
    arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Anchor()
end

-- Shows what the guide says now. Returns the seconds until the next look.
local function Refresh()
    local db = NS.db
    local g = db and db.route and db.arrow and NS.Route.Guide()
    local stop = g and g.stop
    local pm, px, py
    if stop then pm, px, py = NS.PlayerPos() end
    if not pm then
        if arrow and arrow:IsShown() then arrow:Hide() end
        return SLOW
    end
    if not arrow then Build() end
    if arrow.dragging then return FAST end

    local leg = g.leg
    local tm, tx, ty = stop.map, stop.x / 100, stop.y / 100
    if leg then tm, tx, ty = leg.map, leg.x, leg.y end
    local yards, bearing = NS.Between(pm, px, py, tm, tx, ty)
    local flying = UnitOnTaxi ~= nil and UnitOnTaxi("player")

    local zone = stop.zone
    if flying then
        Set("title", "In flight")
        Set("sub", ("to %s, %s"):format(stop.name, zone.name))
    elseif leg then
        Set("title", leg.text)
        Set("sub", ("to %s, %s"):format(stop.name, zone.name))
    else
        Set("title", stop.name)
        Set("sub", ("%s  %d/%d"):format(zone.name, zone.done, zone.total))
    end

    local dist = ""
    if yards and not flying then
        if not leg and yards < HERE then
            dist = "You're at the pin. Walk around until it ticks."
        else
            dist = Distance(yards)
            local speed = GetUnitSpeed and GetUnitSpeed("player")
            if type(speed) == "number" and speed > 0 then dist = dist .. "   " .. Clock(yards / speed) end
        end
    end
    Set("dist", dist)

    local facing = GetPlayerFacing and GetPlayerFacing()
    if issecretvalue and issecretvalue(facing) then facing = nil end
    if bearing and type(facing) == "number" and not flying then
        local turn = bearing - facing
        arrow.tex:SetRotation(turn)
        -- green ahead, through yellow, to red behind
        local off = math.abs((turn + math.pi) % (2 * math.pi) - math.pi) / math.pi
        if off < 0.5 then
            arrow.tex:SetVertexColor(off * 2, 1, 0.1)
        else
            arrow.tex:SetVertexColor(1, (1 - off) * 2, 0.1)
        end
        arrow.tex:Show()
        arrow.turn = turn
    else
        arrow.tex:Hide()   -- the game won't say which way you face (or you're on a flight): text only
        arrow.turn = nil
    end
    if not arrow:IsShown() then
        Anchor()
        arrow:Show()
    end
    return FAST
end

local driver = CreateFrame("Frame")
local wait = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    wait = wait - elapsed
    if wait > 0 then return end
    local ok, again = pcall(Refresh)
    wait = ok and again or SLOW
end)

NS.RefreshArrow = Refresh   -- for the settings and the tests
