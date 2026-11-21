---------------------------------------------------------
--  Explorer - Discovery popup
--  Author: Dranged
---------------------------------------------------------
-- A banner near the top of the screen when an area gets its tick: the area, its zone and
-- the zone's new count. Several ticks at once queue up. The banner lets clicks through.
-- A sample (settings, or /ep test) takes the mouse: drag it to where the banner should sit,
-- scroll on it to resize it, right-click to put both back.

local ADDON, NS = ...
local UI = NS.UI

local ICON = "Interface\\Icons\\INV_Misc_Spyglass_02"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local WIDTH, HEIGHT = 360, 68
local DEFAULT_POS = { "TOP", "TOP", 0, -210 }   -- under the red error text, well above centre
local FADE_IN, HOLD, FADE_OUT = 0.25, 4, 0.8
local HOLD_QUEUED = 1.8    -- more waiting: move along
local HOLD_SAMPLE = 12     -- long enough to grab it
local MIN_SCALE, MAX_SCALE = 0.6, 3

local toast
local queue = {}
local current
local age = 0

local function Scale()
    local s = tonumber(NS.db and NS.db.popupScale) or 1
    return math.max(MIN_SCALE, math.min(MAX_SCALE, s))
end

-- popupPos holds offsets in UIParent's units, so the banner stays put when its size changes.
local function Anchor()
    local p = NS.db and NS.db.popupPos
    if type(p) ~= "table" or type(p[1]) ~= "string" or type(p[2]) ~= "string" then p = DEFAULT_POS end
    local s = Scale()
    toast:SetScale(s)
    toast:ClearAllPoints()
    toast:SetPoint(p[1], UIParent, p[2], (tonumber(p[3]) or 0) / s, (tonumber(p[4]) or 0) / s)
end

local function Fill(t)
    local r, g, b = NS.AccentColor()
    toast.title:SetTextColor(r, g, b)
    toast.bar:SetColorTexture(r, g, b, 1)
    toast.name:SetText(t.name)
    if t.sample then
        toast.sub:SetText("Drag: move. Scroll: size. Right-click: reset.")
        toast.sub:SetTextColor(0.75, 0.75, 0.75)
    elseif t.total > 0 and t.done >= t.total then
        toast.sub:SetText(t.zone .. " fully explored")
        toast.sub:SetTextColor(0.3, 0.9, 0.3)
    else
        toast.sub:SetText(("%s  %d/%d"):format(t.zone, t.done, t.total))
        toast.sub:SetTextColor(0.75, 0.75, 0.75)
    end
    local frac = t.total > 0 and math.min(1, t.done / t.total) or 0
    toast.bar:SetWidth(math.max(1, (WIDTH - 2) * frac))
    toast.bar:SetShown(frac > 0)
    toast:EnableMouse(t.sample and true or false)
    toast:EnableMouseWheel(t.sample and true or false)
    if NS.NoteThemeFonts then pcall(NS.NoteThemeFonts, toast) end
end

local function Next()
    current = table.remove(queue, 1)
    age = 0
    if not current then
        toast:Hide()
        return
    end
    Fill(current)
    toast:SetAlpha(0)
    toast:Show()
end

local function OnUpdate(self, elapsed)
    if self.dragging or not current then return end
    age = age + elapsed
    local hold = current.sample and HOLD_SAMPLE or (#queue > 0 and HOLD_QUEUED or HOLD)
    if age < FADE_IN then
        self:SetAlpha(age / FADE_IN)
    elseif age < FADE_IN + hold then
        self:SetAlpha(1)
    elseif age < FADE_IN + hold + FADE_OUT then
        self:SetAlpha(1 - (age - FADE_IN - hold) / FADE_OUT)
    else
        Next()
    end
end

local function Build()
    toast = CreateFrame("Frame", "ExplorerToast", UIParent, "BackdropTemplate")
    toast:SetSize(WIDTH, HEIGHT)
    toast:SetFrameStrata("HIGH")
    toast:SetClampedToScreen(true)
    toast:SetMovable(true)
    toast:EnableMouse(false)
    toast:RegisterForDrag("LeftButton")
    UI.Backdrop(toast, 0.06, 0.06, 0.07, 0.92)

    local icon = toast:CreateTexture(nil, "ARTWORK")
    icon:SetSize(HEIGHT - 20, HEIGHT - 20)
    icon:SetPoint("LEFT", 10, 1)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    toast.title = UI.Text(toast, "Area explored", "GameFontNormalSmall")
    toast.title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, 1)
    toast.name = UI.Text(toast, "", "GameFontNormalLarge")
    toast.name:SetPoint("LEFT", icon, "RIGHT", 12, 0)
    toast.name:SetPoint("RIGHT", toast, "RIGHT", -10, 0)
    toast.name:SetTextColor(1, 1, 1)
    toast.name:SetWordWrap(false)
    toast.sub = UI.Text(toast, "", "GameFontHighlightSmall")
    toast.sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 12, -1)
    toast.sub:SetPoint("RIGHT", toast, "RIGHT", -10, 0)
    toast.sub:SetWordWrap(false)

    -- The zone's progress along the bottom edge.
    toast.bar = toast:CreateTexture(nil, "OVERLAY")
    toast.bar:SetTexture(WHITE)
    toast.bar:SetHeight(2)
    toast.bar:SetPoint("BOTTOMLEFT", 1, 1)

    toast:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetAlpha(1)
        self:StartMoving()
    end)
    toast:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.dragging = false
        local point, _, relPoint, x, y = self:GetPoint(1)
        local s = Scale()
        if point then NS.db.popupPos = { point, relPoint or point, (x or 0) * s, (y or 0) * s } end
        age = FADE_IN   -- the full hold again, to look at where it landed
    end)
    toast:SetScript("OnMouseWheel", function(self, delta)
        if not (current and current.sample) then return end
        NS.db.popupScale = math.max(MIN_SCALE, math.min(MAX_SCALE, Scale() + (delta > 0 and 0.1 or -0.1)))
        Anchor()
        age = FADE_IN
    end)
    toast:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and current and current.sample then
            NS.db.popupPos, NS.db.popupScale = nil, nil
            Anchor()
            age = FADE_IN
        end
    end)
    toast:SetScript("OnUpdate", OnUpdate)
    toast:Hide()
end

local function Push(t)
    if not toast then Build() end
    Anchor()
    queue[#queue + 1] = t
    -- A sample steps aside for the real thing, and for a newer sample.
    if not current or current.sample then Next() end
end

function NS.Toast(areaName, zoneName, done, total)
    Push({ name = areaName, zone = zoneName, done = done or 0, total = total or 0 })
end

-- A sample of the popup: the nearest unexplored area if there is one.
function NS.ToastSample()
    local a = NS.Nearest and NS.Nearest()
    Push({ sample = true, name = a and a.name or "Area name", zone = "", done = 1, total = 2 })
end
