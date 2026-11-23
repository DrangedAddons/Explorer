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

-- What's wrong with a route of the pathfinder's for this faction (a list), and its rides.
local RIDE = { [1001] = "flight", [1002] = "portal", [1003] = "boat", [1004] = "zeppelin", [1008] = "tram" }
local used = {}   -- [text] = how many routes ride it
local function Faults(steps, edges)
    local out, rides = {}, 0
    for _, e in ipairs(edges or {}) do
        if e.locaId ~= 1000 then
            rides = rides + 1
            local text = FarstriderLib.Pathfinding:GetNodeLoca(e.locaId, e.locaArgs)
            local kind = RIDE[e.locaId] or "ride"
            if kind ~= "flight" then used[text] = (used[text] or 0) + 1 end
            for _, node in ipairs({ e.from, e.to }) do
                local inst, x, y = World(node:getLocation())
                if inst then
                    local city = InCapital(OTHER, inst, x, y)
                    if city then out[#out + 1] = ("%s in %s, a %s capital"):format(text, city, OTHER) end
                    if kind == "flight" then
                        local id = NodeAt(inst, x, y)
                        if not id then
                            out[#out + 1] = text .. ": no flight master where the flight starts or lands"
                        elseif bit.band(nodes[id][5], OWN) == 0 then
                            out[#out + 1] = ("%s: %s is a %s flight master"):format(text, nodes[id][6], OTHER)
                        end
                    end
                end
            end
        end
    end
    return out, rides
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
for _, which in ipairs({ "none", "own", "every" }) do
    Know(which)
    local journeys, walks, trips, rides, lost, bad = 0, 0, 0, 0, {}, {}
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
                    local seconds, trip, walk, how = Route.Travel(a, b, 3)
                    if trip then
                        trips = trips + 1
                        for _, n in ipairs({ trip.dep, trip.arr }) do
                            if n and bit.band(nodes[n.id][5], OWN) == 0 then
                                Fault(from, to, ("a trip by %s, a %s flight master"):format(n.name, OTHER))
                            end
                        end
                        local steps, _, edges = FarstriderLib_API.FindTrail(trip.dep.map, trip.dep.mx, trip.dep.my, 0,
                            trip.arr.map, trip.arr.mx, trip.arr.my, 0)
                        for _, text in ipairs((Faults(steps, edges))) do Fault(from, to, text) end
                    elseif walk then
                        walks = walks + 1
                    else
                        local steps, _, edges = FarstriderLib_API.FindTrail(a.map, a.x, a.y, 0, b.map, b.x, b.y, 0)
                        local faults, n = Faults(steps, edges)
                        for _, text in ipairs(faults) do Fault(from, to, text) end
                        if n > 0 then rides = rides + 1 else lost[#lost + 1] = { from, to, seconds, how } end
                    end
                end
            end
        end
    end
    Say(("  %s flight masters known: %d journeys, %d on foot, %d a trip between flight masters, %d by the pathfinder's rides, %d with no way")
        :format(which, journeys, walks, trips, rides, #lost))
    Check(#bad == 0, ("flight masters known: %s. No journey rides something of the %s's"):format(which, OTHER))
    for i = 1, math.min(#bad, 12) do Say("         " .. bad[i]) end

    -- Where there's no way, the route has to say so: not a walk made up from the bird's distance.
    local ends, told = {}, 0
    for _, l in ipairs(lost) do
        ends[l[1].name] = (ends[l[1].name] or 0) + 1
        ends[l[2].name] = (ends[l[2].name] or 0) + 1
        if l[4] == "none" then told = told + 1 end
    end
    local names = {}
    for name, n in pairs(ends) do if n > 2 then names[#names + 1] = name end end
    table.sort(names)
    NOWAY = NOWAY or {}
    NOWAY[which] = table.concat(names, ", ")
    Check(told == #lost, ("flight masters known: %s. %d journeys have no way (%s): each is told as having none, got %d")
        :format(which, #lost, #names > 0 and NOWAY[which] or "-", told))
end

local list = {}
for text, n in pairs(used) do list[#list + 1] = ("%s (%d)"):format(text, n) end
table.sort(list)
Say("  rides taken, other than flights:")
for _, text in ipairs(list) do Say("         " .. text) end

-- The rides with an end in a capital: closed for the faction whose capital it isn't.
do
    local tram, portal
    for _, w in ipairs(FarstriderLibData_API.WAYPOINTS) do
        if w.from.locaId == 1008 then tram = w end
        if w.from.locaId == 1002 and w.to.loc and math.abs(w.to.loc.pos.x - 9946.1) < 1 then portal = w end
    end
    local horde = FACTION == "Horde"
    Check(tram and (tram.explorerClosed == true) == horde, "the Deeprun Tram (Stormwind to Ironforge) is " .. (horde and "closed" or "open"))
    Check(portal and (portal.explorerClosed == true) == horde, "the portal from Rut'theran Village up to Darnassus is " .. (horde and "closed" or "open"))
end

-- The whole route, standing in the faction's first zone with its flight masters known.
local function Plan(map, x, y)
    PLAYER.map, PLAYER.x, PLAYER.y = map, x, y
    Route.Replan()
    for _ = 1, 50 do Route.Step() end
    return Route.Order()
end
local function NameOf(e) return WORLD[e.map][1] end
-- Entering a subzone has the addon read the challenges again.
local function Rescan()
    FireEvent("ZONE_CHANGED")
    FlushTimers()
end
Know("own")
Rescan()
do
    local home = FACTION == "Horde" and 1411 or 1429
    local order, done = Plan(home, 0.5, 0.5)
    local marked = {}
    for i, e in ipairs(order) do
        if e.noWay then marked[#marked + 1] = i .. ". " .. NameOf(e) end
    end
    Check(done and #order == #ns.Zones and order[1].map == home, ("the route covers all %d zones, %s first"):format(#order, WORLD[home][1]))
    if FACTION == "Horde" then
        Check(#marked == 1 and order[#order].map == 1438 and order[#order].noWay,
            "Teldrassil is the one zone with no way there, and comes last: " .. table.concat(marked, ", "))
    else
        Check(#marked == 0, "every zone has a way there: " .. (#marked == 0 and "none marked" or table.concat(marked, ", ")))
    end
end

-- Only Teldrassil left, standing in Darkshore by Auberdine: the Alliance is sent to the
-- flight master or the boat; the Horde is told there is no way, not sent swimming.
do
    for overlay, a in pairs(ns.Areas) do DONE[overlay] = a[1] ~= 1438 end
    Rescan()
    local order = Plan(1439, 0.38, 0.44)
    Route.Tick()
    for _ = 1, 50 do Route.Step() end
    ns.RefreshArrow()
    local g, arrow = Route.Guide(), ExplorerArrow
    local stop = g and g.stop
    Check(#order == 1 and order[1].map == 1438 and stop ~= nil, "one zone left: Teldrassil, next stop " .. tostring(stop and stop.name))
    if FACTION == "Horde" then
        Check(order[1].noWay and g.noWay and not g.leg, "Horde in Darkshore: no leg to ride, the guide says there is no way")
        Check(arrow and arrow.dist:GetText() == "No way there for the Horde: no road, flight or boat",
            "the arrow says so: " .. tostring(arrow and arrow.dist:GetText()))
    else
        Check(not order[1].noWay and not g.noWay and g.leg and g.leg.text:find("Rut'theran") ~= nil,
            "Alliance in Darkshore, flight masters known: " .. tostring(g.leg and g.leg.text))
        Know("none")
        Plan(1439, 0.38, 0.44)
        Route.Tick()
        for _ = 1, 50 do Route.Step() end
        g = Route.Guide()
        Check(g and not g.noWay and g.leg and g.leg.text:find("^Take the boat") ~= nil,
            "Alliance in Darkshore, no flight master known: " .. tostring(g and g.leg and g.leg.text))
        Know("own")
    end
    for overlay in pairs(DONE) do DONE[overlay] = nil end
    Rescan()
end

-- Standing where the walking data is blind (out at sea): "no way" from there isn't believed
-- while the nearest pin has one.
do
    local stop = ns.AreaByOverlay(Mid(1411).overlay)
    local leg, trip, how = Route.FindTrip(stop, 1411, 0.97, 0.5)
    local _, _, walk, bare = Route.Travel({ map = 1411, x = 0.97, y = 0.5, player = true },
        { map = 1411, x = stop.x / 100, y = stop.y / 100, pin = stop.overlay }, 3)
    Check(bare == "none" and not walk, "out at sea off Durotar the walking data finds no way to " .. stop.name)
    Check(how == "guess" and not leg, "the guide doesn't call that no way: the pin nearest the player has one (" .. tostring(how) .. ")")
end

FAILS = fails
Say(fails == 0 and "all checks passed" or (fails .. " FAILED"))
