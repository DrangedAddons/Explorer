-- Every journey between two zones, as one faction, with the real pathfinder (the bundled
-- FarstriderLib) and the real walking data: is every ride one this faction can take?
-- Globals in: ADDON_DIR, HERE, FACTION ("Alliance" | "Horde"), QUICK (true: a handful of starts)
dofile(HERE .. "/mock.lua")
dofile(HERE .. "/real.lua")

local fails = 0
local function Check(cond, what)
    if cond then Say("  ok   " .. what) else fails = fails + 1; Say("  FAIL " .. what) end
end
Say("faction: " .. FACTION)

local ns, files = LoadWhole(ADDON_DIR)
local Route = ns.Route
Check(#files > 50 and type(FarstriderLib_API) == "table" and type(FarstriderLib_API.FindTrail) == "function",
    "the addon loads whole in its .toc's order, bundled pathfinder and all (" .. #files .. " files)")

local OWN = FACTION == "Alliance" and 1 or 2
local OTHER = FACTION == "Alliance" and "Horde" or "Alliance"
-- The capital cities, by their maps.
local CAPITALS = { Alliance = { 1453, 1455, 1457 }, Horde = { 1454, 1456, 1458 } }
local nodes = FarstriderLibData.TaxiNodes

local function World(loc)   -- instance, x, y of a place the pathfinder names
    if loc.isUI then
        local inst, v = C_Map.GetWorldPosFromMapPos(loc.mapId, CreateVector2D(loc.pos.x, loc.pos.y))
        if inst then return inst, v.x, v.y end
        return nil
    end
    return loc.mapId, loc.pos.x, loc.pos.y
end

local function InCapital(side, inst, x, y)
    for _, map in ipairs(CAPITALS[side]) do
        local id, v = C_Map.GetMapPosFromWorldPos(inst, CreateVector2D(x, y), map)
        if id and v.x >= 0 and v.x <= 1 and v.y >= 0 and v.y <= 1 then return WORLD[map][1] end
    end
end

local function NodeAt(inst, x, y)   -- the flight master standing here
    local best, near
    for id, n in pairs(nodes) do
        if n[1] == inst then
            local d = (n[2] - x) ^ 2 + (n[3] - y) ^ 2
            if d < 60 ^ 2 and (not near or d < near) then best, near = id, d end
        end
    end
    return best
end

-- Whether a ride is the other faction's: an end in one of their capitals, or one of their
-- boats and zeppelins (Rides.lua).
local function Theirs(e)
    local i1, x1, y1 = World(e.from:getLocation())
    local i2, x2, y2 = World(e.to:getLocation())
    if not (i1 and i2) then return false end
    if InCapital(OTHER, i1, x1, y1) or InCapital(OTHER, i2, x2, y2) then return true end
    local function At(r, inst, x, y) return r[2] == inst and (r[3] - x) ^ 2 + (r[4] - y) ^ 2 < 150 ^ 2 end
    for _, r in ipairs(ns.Rides[OWN]) do
        if (At(r[3], i1, x1, y1) and At(r[4], i2, x2, y2)) or (At(r[4], i1, x1, y1) and At(r[3], i2, x2, y2)) then return true end
    end
    return false
end

-- What's wrong with a route of the pathfinder's for this faction (a list), how many rides it
-- has and how many of them are the other faction's. Those are faults unless `allowed`; a
-- flight from one of their flight masters always is.
local RIDE = { [1001] = "flight", [1002] = "portal", [1003] = "boat", [1004] = "zeppelin", [1008] = "tram" }
local used, usedTheirs = {}, {}   -- [text] = how many routes ride it
local function Faults(steps, edges, allowed)
    local out, rides, theirs = {}, 0, 0
    for _, e in ipairs(edges or {}) do
        if e.locaId ~= 1000 then
            rides = rides + 1
            local text = FarstriderLib.Pathfinding:GetNodeLoca(e.locaId, e.locaArgs)
            local kind = RIDE[e.locaId] or "ride"
            if kind == "flight" then
                for _, node in ipairs({ e.from, e.to }) do
                    local inst, x, y = World(node:getLocation())
                    local id = inst and NodeAt(inst, x, y)
                    if not id then
                        out[#out + 1] = text .. ": no flight master where the flight starts or lands"
                    elseif bit.band(nodes[id][5], OWN) == 0 then
                        out[#out + 1] = ("%s: %s is a %s flight master"):format(text, nodes[id][6], OTHER)
                    end
                end
            elseif Theirs(e) then
                theirs = theirs + 1
                usedTheirs[text] = (usedTheirs[text] or 0) + 1
                if not allowed then out[#out + 1] = text .. ": a ride of the " .. OTHER .. "'s" end
            else
                used[text] = (used[text] or 0) + 1
            end
        end
    end
    return out, rides, theirs
end

local function Mid(map)   -- the zone's pin nearest the middle of its pins, as the route planner picks it
    local list, sx, sy = {}, 0, 0
    for overlay, a in pairs(ns.Areas) do
        if a[1] == map then
            list[#list + 1] = { overlay = overlay, x = a[2], y = a[3], name = a[4] }
            sx, sy = sx + a[2], sy + a[3]
        end
    end
    sx, sy = sx / #list, sy / #list
    table.sort(list, function(p, q)
        local dp, dq = (p.x - sx) ^ 2 + (p.y - sy) ^ 2, (q.x - sx) ^ 2 + (q.y - sy) ^ 2
        if dp ~= dq then return dp < dq end
        return p.overlay < q.overlay
    end)
    return list[1]
end

local zones = {}
for _, z in ipairs(ns.Zones) do
    local pin = Mid(z[2])
    zones[#zones + 1] = { map = z[2], name = WORLD[z[2]][1], pin = pin,
        place = function() return { map = z[2], x = pin.x / 100, y = pin.y / 100, pin = pin.overlay } end }
end
table.sort(zones, function(a, b) return a.map < b.map end)

-- Which flight masters the character knows: none, their faction's, or (a saved file gone
-- wrong) every one there is, the other faction's too.
local function Know(which)
    local known = {}
    for id, n in pairs(nodes) do
        if which == "every" or (which == "own" and bit.band(n[5], OWN) > 0) then known[id] = true end
    end
    FarstriderLibData_CharacterSettings = { knownTaxiNodes = known }
    FarstriderLib_API.Rebuild()
    Route.ForgetTravel()
end

local STARTS = QUICK and { [1411] = true, [1420] = true, [1429] = true, [1438] = true, [1446] = true } or nil
-- Every journey between two zones' pins. Returns how many take the other faction's rides
-- (the last resort) and which zones those are to or from.
local function Journeys(which)
    Know(which)
    local journeys, walks, trips, rides, lost, bad = 0, 0, 0, 0, {}, {}
    local last, most, ends = 0, 0, {}
    local seen = {}
    local function Fault(from, to, text)
        if not seen[text] then
            seen[text] = true
            bad[#bad + 1] = ("%s to %s: %s"):format(from.name, to.name, text)
        end
    end
    for _, from in ipairs(zones) do
        if not STARTS or STARTS[from.map] then
            for _, to in ipairs(zones) do
                if to ~= from then
                    journeys = journeys + 1
                    local a, b = from.place(), to.place()
                    local seconds, trip, walk, how, others = Route.Travel(a, b, 3)
                    if trip then
                        trips = trips + 1
                        for _, n in ipairs({ trip.dep, trip.arr }) do
                            if n and bit.band(nodes[n.id][5], OWN) == 0 then
                                Fault(from, to, ("a trip by %s, a %s flight master"):format(n.name, OTHER))
                            end
                        end
                        local steps, edges = Route.Ask(trip.dep.map, trip.dep.mx, trip.dep.my, trip.arr.map, trip.arr.mx, trip.arr.my)
                        for _, text in ipairs((Faults(steps, edges))) do Fault(from, to, text) end
                    elseif walk then
                        walks = walks + 1
                    else
                        local steps, edges = Route.Ask(a.map, a.x, a.y, b.map, b.x, b.y, others)
                        local faults, n, theirs = Faults(steps, edges, others)
                        for _, text in ipairs(faults) do Fault(from, to, text) end
                        if others then
                            last, most = last + 1, math.max(most, theirs)
                            ends[from.name], ends[to.name] = (ends[from.name] or 0) + 1, (ends[to.name] or 0) + 1
                            if theirs == 0 then Fault(from, to, "told as taking the " .. OTHER .. "'s rides, and takes none") end
                            if how ~= "ride" then Fault(from, to, "the last resort is told as " .. tostring(how)) end
                        elseif n > 0 then
                            rides = rides + 1
                        else
                            lost[#lost + 1] = { from, to, seconds, how }
                            ends[from.name], ends[to.name] = (ends[from.name] or 0) + 1, (ends[to.name] or 0) + 1
                        end
                    end
                end
            end
        end
    end
    local names = {}
    for name, n in pairs(ends) do if n > 2 then names[#names + 1] = name end end
    table.sort(names)
    local told = 0
    for _, l in ipairs(lost) do if l[4] == "none" then told = told + 1 end end
    Say(("  %s flight masters known: %d journeys, %d on foot, %d a trip between flight masters, %d by the pathfinder's rides, %d by the last resort, %d with no way")
        :format(which, journeys, walks, trips, rides, last, #lost))
    Check(#bad == 0, ("flight masters known: %s. No journey rides something of the %s's but by the last resort"):format(which, OTHER))
    for i = 1, math.min(#bad, 12) do Say("         " .. bad[i]) end
    return { last = last, most = most, lost = #lost, told = told, zones = table.concat(names, ", ") }
end

-- With the last resort (the default): the other faction's rides where nothing else gets to
-- a zone, as few as will do. For the Horde that is Teldrassil: the boat from Auberdine, and
-- the portal up from Rut'theran Village. The Alliance needs none.
local cut   -- how many journeys the Horde's own means have no way for
for _, which in ipairs({ "none", "own", "every" }) do
    local r = Journeys(which)
    Check(r.lost == 0, ("flight masters known: %s. Every journey has a way, got %d without"):format(which, r.lost))
    if FACTION == "Horde" then
        Check(r.last > 0 and r.zones == "Teldrassil" and r.most <= 2,
            ("flight masters known: %s. The last resort is for Teldrassil only (%s, %d journeys), at most two of the Alliance's rides in one, got %d")
                :format(which, r.zones, r.last, r.most))
        cut = r.last
    else
        Check(r.last == 0, ("flight masters known: %s. The Alliance never needs the last resort, got %d"):format(which, r.last))
    end
end

-- With the setting off: nothing of the other faction's, and where that leaves no way, the
-- route says so (not a walk made up from the bird's distance).
ns.db.othersRides = false
do
    local r = Journeys("own")
    Check(r.last == 0, "last resort off: no journey takes it, got " .. r.last)
    if FACTION == "Horde" then
        Check(r.lost == cut and r.told == r.lost and r.zones == "Teldrassil",
            ("last resort off: the %d journeys to and from %s have no way, and each is told as having none (%d)"):format(r.lost, r.zones, r.told))
    else
        Check(r.lost == 0, "last resort off: every journey still has a way, got " .. r.lost .. " without")
    end
end
ns.db.othersRides = true

local function Listed(t)
    local list = {}
    for text, n in pairs(t) do list[#list + 1] = ("%s (%d)"):format(text, n) end
    table.sort(list)
    return list
end
Say("  rides taken, other than flights:")
for _, text in ipairs(Listed(used)) do Say("         " .. text) end
Say("  rides of the " .. OTHER .. "'s taken by the last resort:")
for _, text in ipairs(Listed(usedTheirs)) do Say("         " .. text) end

-- The rides with an end in a capital: closed for the faction whose capital it isn't.
do
    local tram, portal, added = nil, nil, 0
    for _, w in ipairs(FarstriderLibData_API.WAYPOINTS) do
        if w.explorerRide then
            added = added + 1
        else
            if w.from.locaId == 1008 then tram = w end
            if w.from.locaId == 1002 and w.to.loc and math.abs(w.to.loc.pos.x - 9946.1) < 1 then portal = w end
        end
    end
    local horde = FACTION == "Horde"
    Check(tram and (tram.explorerClosed == true) == horde, "the Deeprun Tram (Stormwind to Ironforge) is " .. (horde and "closed" or "open"))
    Check(portal and (portal.explorerClosed == true) == horde, "the portal from Rut'theran Village up to Darnassus is " .. (horde and "closed" or "open"))
    Check(added == #ns.Rides[OWN] + (horde and 2 or 0),
        ("%d rides are kept for the last resort: the %s's %d boats and zeppelins%s"):format(added, OTHER, #ns.Rides[OWN],
            horde and ", the tram and the portal" or ""))
end

-- The whole route, standing in the faction's first zone with its flight masters known.
local function Plan(map, x, y)
    PLAYER.map, PLAYER.x, PLAYER.y = map, x, y
    Route.Replan()
    for _ = 1, 50 do Route.Step() end
    return Route.Order()
end
local function Guide()
    Route.Tick()
    for _ = 1, 50 do Route.Step() end
    ns.RefreshArrow()
    return Route.Guide()
end
local function NameOf(e) return WORLD[e.map][1] end
-- Entering a subzone has the addon read the challenges again.
local function Rescan()
    FireEvent("ZONE_CHANGED")
    FlushTimers()
end
Know("own")
Rescan()
local home = FACTION == "Horde" and 1411 or 1429
do
    local order, done = Plan(home, 0.5, 0.5)
    local none, theirs, at = {}, {}, nil
    for i, e in ipairs(order) do
        if e.noWay then none[#none + 1] = i .. ". " .. NameOf(e) end
        if e.others then theirs[#theirs + 1] = i .. ". " .. NameOf(e) end
        if e.map == 1438 then at = i end
    end
    Check(done and #order == #ns.Zones and order[1].map == home and #none == 0,
        ("the route covers all %d zones, %s first, none without a way"):format(#order, WORLD[home][1]))
    if FACTION == "Horde" then
        Check(#theirs == 1 and order[at].others,
            ("Teldrassil is the one zone marked as only by Alliance rides: %s, after %s and before %s"):format(table.concat(theirs, ", "),
                NameOf(order[at - 1]), order[at + 1] and NameOf(order[at + 1]) or "nothing"))
        ns.ToggleWindow()
        local row
        local function Find(f, depth)
            if f.count and f.text and f:IsShown() and tostring(f.text:GetText()):find("Teldrassil") then row = f end
            if depth < 6 then
                for _, child in ipairs({ f:GetChildren() }) do Find(child, depth + 1) end
            end
        end
        Find(ExplorerFrame, 0)
        Check(row ~= nil and tostring(row.count:GetText()):find("^only by Alliance rides   0/%d+$") ~= nil,
            "the window's row for it says so: " .. tostring(row and row.count:GetText()))
        ns.ToggleWindow()
    else
        Check(#theirs == 0, "no zone needs the Horde's rides: " .. (#theirs == 0 and "none marked" or table.concat(theirs, ", ")))
    end
end

-- Only Teldrassil left, standing in Darkshore by Auberdine. The Alliance is sent to the
-- flight master or the boat. The Horde is sent to the boat too, told that it's the
-- Alliance's; and from Rut'theran Village up by the portal.
do
    for overlay, a in pairs(ns.Areas) do DONE[overlay] = a[1] ~= 1438 end
    Rescan()
    local order = Plan(1439, 0.38, 0.44)
    local g, arrow = Guide(), ExplorerArrow
    local stop = g and g.stop
    Check(#order == 1 and order[1].map == 1438 and stop ~= nil, "one zone left: Teldrassil, next stop " .. tostring(stop and stop.name))
    if FACTION == "Horde" then
        Check(order[1].others and g.others and not g.noWay and g.leg and g.leg.others
            and g.leg.text == "Take the boat from Auberdine to Rut'theran Village (Alliance)",
            "Horde in Darkshore: " .. tostring(g.leg and g.leg.text))
        Check(arrow and arrow.title:GetText() == g.leg.text and arrow.dist:GetText():find("yd"),
            "the arrow points at the boat: " .. tostring(arrow and arrow.dist:GetText()))
        -- Off the boat at Rut'theran Village, its own area ticked: the rest is up the tree.
        local village
        for overlay, a in pairs(ns.Areas) do
            if a[1] == 1438 and a[4] == "Rut'theran Village" then village = a; DONE[overlay] = true end
        end
        Rescan()
        Plan(1438, village[2] / 100, village[3] / 100)
        g = Guide()
        Check(g and g.others and g.leg and g.leg.others and g.leg.text:find("^Take the portal to .+ %(Alliance%)$") ~= nil,
            "Horde at Rut'theran Village, next stop " .. tostring(g and g.stop and g.stop.name) .. ": " .. tostring(g and g.leg and g.leg.text))
        -- And with the last resort off there is no way, and the route says so.
        ns.db.othersRides = false
        order = Plan(1439, 0.38, 0.44)
        g = Guide()
        Check(order[1].noWay and g.noWay and not g.leg and not g.others, "last resort off, Horde in Darkshore: no leg to ride, the guide says there is no way")
        Check(arrow.dist:GetText() == "No way there for the Horde: no road, flight or boat", "the arrow says so: " .. tostring(arrow.dist:GetText()))
        ns.db.othersRides = true
    else
        Check(not order[1].noWay and not order[1].others and not g.noWay and not g.others and g.leg and g.leg.text:find("Rut'theran") ~= nil,
            "Alliance in Darkshore, flight masters known: " .. tostring(g.leg and g.leg.text))
        Know("none")
        Plan(1439, 0.38, 0.44)
        g = Guide()
        Check(g and not g.noWay and not g.others and g.leg and g.leg.text:find("^Take the boat") ~= nil and not g.leg.text:find("Horde"),
            "Alliance in Darkshore, no flight master known: " .. tostring(g and g.leg and g.leg.text))
        Know("own")
    end
    for overlay in pairs(DONE) do DONE[overlay] = nil end
    Rescan()
end

-- Changing the setting plans again: the zone's mark follows it.
if FACTION == "Horde" then
    local function Marks()
        local order = Route.Order()
        for _ = 1, 50 do Route.Step() end
        for i, e in ipairs(order) do
            if e.map == 1438 then return e.others and "others" or e.noWay and "none" or "plain", i, #order end
        end
    end
    Plan(home, 0.5, 0.5)
    local before = Marks()
    ns.db.othersRides = false
    Route.Tick()
    local after, at, n = Marks()
    ns.db.othersRides = true
    Route.Tick()
    local back = Marks()
    Check(before == "others" and after == "none" and at == n and back == "others",
        ("turning the setting off and on: Teldrassil is %s, then %s and last (%d of %d), then %s"):format(before, after, at, n, back))
end

-- Standing where the walking data is blind (out at sea): "no way" from there isn't believed
-- while the nearest pin has one.
do
    local stop = ns.AreaByOverlay(Mid(1411).overlay)
    local leg, trip, how = Route.FindTrip(stop, 1411, 0.97, 0.5)
    local _, _, walk, bare = Route.Travel({ map = 1411, x = 0.97, y = 0.5, player = true },
        { map = 1411, x = stop.x / 100, y = stop.y / 100, pin = stop.overlay }, 3)
    Check(bare == "none" and not walk, "out at sea off Durotar the walking data finds no way to " .. stop.name)
    Check(how == "guess" and not leg, "the guide doesn't call that no way, or send for the other faction's boats: the pin nearest the player has a way (" .. tostring(how) .. ")")
end

FAILS = fails
Say(fails == 0 and "all checks passed" or (fails .. " FAILED"))
