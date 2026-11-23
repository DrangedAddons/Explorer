---------------------------------------------------------
--  Explorer - Route
--  Author: Dranged
---------------------------------------------------------
-- The order to visit what's left in, and how to get to the next stop.
--
--   stops   a zone's unexplored areas, ordered into a short path (nearest next, then
--           untangled). Distances are straight lines on the zone's map.
--   zones   the zone you're in first, then whichever is quickest to reach from the last
--           one, by FarstriderLib's travel time (flight paths you know, boats, zeppelins,
--           the tram, on foot). Those lookups are spread over frames; the first zone's
--           stops are ready at once. Only what the character's faction can ride counts
--           ("Whose rides" below); a zone with no way there goes last, marked.
--   guide   the next stop, and when a trip gets there quicker than walking, the first
--           thing to do ("Talk to the Flightmaster to travel to ...").
--
-- Walks are measured by Nav.lua (terrain, walls and roads) where it has data: the order of
-- the stops in the zone you're in, the way to the next stop, and walks between zones.
-- FarstriderLib's own walking legs are straight lines.

local ADDON, NS = ...

local CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local LEVEL_MARGIN = 5      -- zones more than this above your level are left out
local SHORTLIST = 6         -- nearest zones on the continent whose travel time gets looked up
local BUDGET_MS = 4         -- planning time per frame
local WALK = 1.3 / 7        -- seconds a yard on foot, with FarstriderLib's detour factor
local FAR = 3600            -- a cost for "no idea": another continent with no pathfinder
local ON_FOOT = 1000        -- FarstriderLib's kind of step for going on foot
local UNREACHED = 1.5       -- no way found on foot: the bird's distance and half again
local WAY_EVERY, WAY_MOVED = 5, 25   -- the walk to the next stop is found again after this many seconds or yards
local FLY_FROM = 1200       -- yards of walking from which a trip by flight is weighed against it
local FLY_BEATS = 0.8       -- ... and taken when it needs under this much of the walk's time
local GATE_RANGE = 8000     -- flight masters this far from a place (as the bird flies) are looked at ...
local GATE_LOOK = 8         -- ... the nearest this many, for the walk between them and the place
local TRIP_EVERY = 10       -- seconds between looks at how to get to the next stop

local Route = {}
NS.Route = Route

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

---------------------------------------------------------
--  SECTION: Where things are
---------------------------------------------------------
-- A map's corners in the world: { continent, x at the top, y at the left, x at the bottom,
-- y at the right } in yards. World x runs north and world y west, so a map's y (down)
-- moves world x and its x (across) moves world y.
local worldOf = {}

local function XY(v)
    if type(v) ~= "table" then return end
    if v.GetXY then return v:GetXY() end
    return v.x, v.y
end

local function MapWorld(map)
    local w = worldOf[map]
    if w then return w end
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok0, inst, p0 = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(0, 0))
    local ok1, _, p1 = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(1, 1))
    if not (ok0 and ok1) or Secret(inst) or type(inst) ~= "number" then return nil end
    local x0, y0 = XY(p0)
    local x1, y1 = XY(p1)
    if Secret(x0) or Secret(y0) or Secret(x1) or Secret(y1) then return nil end
    if type(x0) ~= "number" or type(y0) ~= "number" or type(x1) ~= "number" or type(y1) ~= "number" then return nil end
    if x0 == x1 or y0 == y1 then return nil end
    w = { inst, x0, y0, x1, y1 }
    worldOf[map] = w
    return w
end

-- A point on a map (0-1) in the world: continent, x, y. nil where the game can't say.
function NS.WorldPos(map, x, y)
    local w = map and MapWorld(map)
    if not w then return nil end
    return w[1], w[2] + y * (w[4] - w[2]), w[3] + x * (w[5] - w[3])
end

-- And back: a world point on a map of the same continent (0-1, and past it when it's off the map).
function NS.MapPos(map, inst, wx, wy)
    local w = map and MapWorld(map)
    if not w or w[1] ~= inst then return nil end
    return (wy - w[3]) / (w[5] - w[3]), (wx - w[2]) / (w[4] - w[2])
end

-- The player's zone map and position on it (0-1). nil in a dungeon, or when the game hides it.
function NS.PlayerPos()
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or Secret(map) or type(map) ~= "number" then return nil end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not ok2 or not pos then return nil end
    local x, y = XY(pos)
    if Secret(x) or Secret(y) or type(x) ~= "number" or type(y) ~= "number" then return nil end
    if x == 0 and y == 0 then return nil end
    return map, x, y
end

-- From one map point to another: yards, and the bearing as GetPlayerFacing counts it (0 is
-- north, turning left). With no world data but both on one map: no yards, the bearing from
-- the map (zone maps are 3:2). nil, nil across continents.
function NS.Between(m1, x1, y1, m2, x2, y2)
    local i1, ax, ay = NS.WorldPos(m1, x1, y1)
    local i2, bx, by = NS.WorldPos(m2, x2, y2)
    if i1 and i2 then
        if i1 ~= i2 then return nil, nil end
        local north, west = bx - ax, by - ay
        return math.sqrt(north * north + west * west), math.atan2(west, north)
    end
    if m1 == m2 then return nil, math.atan2(-(x2 - x1) * 1.5, -(y2 - y1)) end
    return nil, nil
end

local continentOf = {}
local function Continent(map)
    local c = continentOf[map]
    if c == nil then
        c = false
        local id, guard = map, 0
        while id and id > 0 and guard < 6 do
            local info = C_Map.GetMapInfo(id)
            if not info then break end
            if info.mapType == CONTINENT then c = id break end
            id, guard = info.parentMapID, guard + 1
        end
        continentOf[map] = c
    end
    return c
end

---------------------------------------------------------
--  SECTION: Whose rides
---------------------------------------------------------
-- A route rides what the character's faction can: its own flight masters, its own boats and
-- zeppelins, and the ones open to both. FarstriderLib sorts its flights and most of its boats
-- by faction when it loads. Three things are left to do here:
--
--   flight masters   the ones weighed for a trip are checked against the faction again
--                    (KnownNodes), whatever the saved list of known ones says
--   capitals         a ride that starts or ends inside a capital of the other faction is
--                    closed. FarstriderLib leaves a few of those open to everyone (the Deeprun
--                    Tram between Stormwind and Ironforge, the portal up to Darnassus).
--   last resort      where nothing above gets to a place, the other faction's boats and
--                    zeppelins and the closed rides are opened for one more look, each at a
--                    cost that keeps them to as few as will do. Anyone can board them, and
--                    the boat from Auberdine and the portal at Rut'theran Village are the only
--                    way a Horde character gets to Teldrassil. Such a journey is marked, and
--                    the setting "Use the other faction's boats ..." turns it off.

-- 1 Alliance, 2 Horde, as FarstriderLib's flight masters are marked; 0 when the game won't say.
local function Side()
    local faction, name = nil, nil
    if UnitFactionGroup then faction, name = UnitFactionGroup("player") end
    return faction == "Alliance" and 1 or faction == "Horde" and 2 or 0, name or faction
end

-- Whether a flight master's mark (1, 2 or 3 for both) covers a side.
local function Serves(mark, side)
    return side ~= 0 and type(mark) == "number" and (mark == side or mark == 3)
end

-- The capital cities' maps, and whose each is.
local CAPITALS = { [1453] = 1, [1455] = 1, [1457] = 1, [1454] = 2, [1456] = 2, [1458] = 2 }

-- The capital of the other faction a place in the world lies in (its map), or nil.
local function EnemyCapital(inst, wx, wy)
    local side = Side()
    if side == 0 then return nil end
    for map, owner in pairs(CAPITALS) do
        if owner ~= side then
            local x, y = NS.MapPos(map, inst, wx, wy)
            if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return map end
        end
    end
end

-- Where an end of one of FarstriderLib's connections is in the world, when it has a fixed place.
local function EndInWorld(side)
    local loc = type(side) == "table" and side.loc
    local pos = type(loc) == "table" and loc.pos
    if type(pos) ~= "table" or type(loc.mapId) ~= "number" or type(pos.x) ~= "number" or type(pos.y) ~= "number" then return nil end
    if loc.isUI then return NS.WorldPos(loc.mapId, pos.x, pos.y) end
    return loc.mapId, pos.x, pos.y
end

local function Never() return false end

-- The last resort is open only while Explorer itself asks for it (Whole and Leg, below).
local lastResort = false
local function LastResort() return lastResort end
local OTHERS_COST = 10800   -- seconds added to a ride of the other faction's: three hours, so a route takes as few as it can
local OTHERS_ID = 900000    -- their numbers in FarstriderLib's list start here

local function PassesNow(condition)
    if condition == nil then return true end
    local ok, yes = pcall(condition)
    return ok and yes and true or false
end

-- An end of a ride from Rides.lua, as FarstriderLib wants it.
local function RideEnd(e)
    local names = {}
    for i = 1, #e[6], 2 do
        local name = C_Map.GetAreaInfo and C_Map.GetAreaInfo(e[6][i])
        names[#names + 1] = type(name) == "string" and name ~= "" and name or e[6][i + 1]
    end
    return { unknown1 = 0, flags = 0, loc = { mapId = e[2], pos = { x = e[3], y = e[4], z = e[5] }, isUI = false },
        condition = LastResort, type = 1, important = true, locaId = e[1],
        locaArgs = #names > 0 and function() return names end or nil }
end

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- Sorts the rides in the list the running copy of FarstriderLib builds its graph from:
--
--   closes the ones with an end in a capital of the other faction,
--   and adds, for the last resort only, a copy of each of those that was open to everyone,
--   and the other faction's boats and zeppelins (Rides.lua).
--
-- Returns how many it changed this time; the graph has to be built (again) after that for
-- it to count.
local sorted = setmetatable({}, { __mode = "k" })   -- [a list] = true: Rides.lua is in it
local function SortRides()
    local api = FarstriderLibData_API
    local list = type(api) == "table" and api.WAYPOINTS
    local side = Side()
    if type(list) ~= "table" or side == 0 then return 0 end
    local changed, add = 0, {}
    for _, w in ipairs(list) do
        if type(w) == "table" and not w.explorerClosed and not w.explorerRide and type(w.from) == "table" and type(w.to) == "table" then
            local i1, x1, y1 = EndInWorld(w.from)
            local i2, x2, y2 = EndInWorld(w.to)
            if (i1 and EnemyCapital(i1, x1, y1)) or (i2 and EnemyCapital(i2, x2, y2)) then
                if i1 and i2 and PassesNow(w.condition) and PassesNow(w.from.condition) and PassesNow(w.to.condition) then
                    local from, to = Copy(w.from), Copy(w.to)
                    from.condition, to.condition = LastResort, LastResort
                    add[#add + 1] = { from = from, to = to, bidirectional = w.bidirectional, cost = (tonumber(w.cost) or 0) + OTHERS_COST }
                end
                w.explorerClosed = true
                w.from.condition, w.to.condition = Never, Never   -- one for each way along it
                changed = changed + 1
            end
        end
    end
    if not sorted[list] then
        sorted[list] = true
        for _, r in ipairs(NS.Rides and NS.Rides[side] or {}) do
            add[#add + 1] = { from = RideEnd(r[3]), to = RideEnd(r[4]), bidirectional = r[2], cost = r[1] + OTHERS_COST }
        end
    end
    for _, w in ipairs(add) do
        w.id, w.explorerRide = OTHERS_ID + #list, true
        list[#list + 1] = w
        changed = changed + 1
    end
    return changed
end
-- Before FarstriderLib builds its graph at login. (Looked at again on entering the world, in
-- case a newer copy of the library in another addon took over after this file loaded.)
pcall(SortRides)

-- The other faction's name, for saying whose a ride is.
local function OthersName()
    local side = Side()
    if side == 1 then return FACTION_HORDE or "Horde" end
    if side == 2 then return FACTION_ALLIANCE or "Alliance" end
    return "other faction"
end

---------------------------------------------------------
--  SECTION: What's left, and what it costs to get there
---------------------------------------------------------
local skipped = {}   -- [overlay] = true: stops passed over with /ep skip, until /ep route

local function Left(zone)
    local out = {}
    for _, a in ipairs(zone.areas) do
        if not a.done and not skipped[a.overlay] then out[#out + 1] = a end
    end
    return out
end

-- The middle of a set of areas: map, x, y (0-1).
local function Centre(areas)
    local x, y = 0, 0
    for _, a in ipairs(areas) do x, y = x + a.x, y + a.y end
    return areas[1].map, x / #areas / 100, y / #areas / 100
end

-- Whether a zone is left out for being too far above the player's level.
function Route.TooHigh(zone)
    if NS.db.routeAllLevels then return false end
    local zoneLevel = NS.ZoneLevels and NS.ZoneLevels[zone.map]
    local level = UnitLevel and UnitLevel("player")
    return zoneLevel ~= nil and type(level) == "number" and zoneLevel > level + LEVEL_MARGIN
end

---------------------------------------------------------
--  SECTION: Getting from one place to another
---------------------------------------------------------
-- One rule for every journey, whether it's weighed for the order of the zones or shown by
-- the arrow:
--
--   walk   all the way on foot, by terrain and roads (Nav.lua), when both ends are on one
--          continent
--   trip   on foot to a flight master the character knows, FarstriderLib's travel from there
--          to another one (flights, and the boats, zeppelins and tram between continents),
--          and on foot from where that lands
--
-- and the quicker of the two. Both walks of a trip are real walks. FarstriderLib on its own
-- counts every walk as a straight line, which picks a flight master that is near as the bird
-- flies and a mountain away on foot. So it is only asked for the part between two flight
-- masters, where there is no walk for it to get wrong. Where the walking data doesn't reach
-- (or the character knows no flight master near the end), its whole route is all there is.
--
-- A place is { map, x, y } (0-1 on a zone's map), with `pin` (an overlay ID) when it is an
-- explore pin and `player` when it is where the player stands. What's found from a place is
-- kept on it, so a zone's place is kept between plans.


-- Yards a second on the ground at the player's level, as FarstriderLib counts it for Forever.
local function RideSpeed()
    local level = UnitLevel and UnitLevel("player") or 1
    return level >= 60 and 14 or level >= 40 and 11.2 or 7
end

local continentMapOf = {}   -- [continent instance] = its uiMap, learned from the places seen
local nodesOf = {}          -- [continent instance] = the flight masters the character knows there
local flights = {}          -- ["from>to"] = { seconds, first step } between two flight masters, or false
local places = {}           -- [zone's challenge ID] = the zone's place

local function ForgetTravel()
    nodesOf, flights, places = {}, {}, {}
end

-- Fills in where a place is in the world. True when the walking data knows its continent.
local function Resolve(p)
    if p.inst == nil then
        local inst, wx, wy = NS.WorldPos(p.map, p.x, p.y)
        p.inst, p.wx, p.wy = inst or false, wx, wy
        if inst then
            local c = Continent(p.map)
            if c then continentMapOf[inst] = c end
        end
    end
    return p.inst ~= false and NS.Nav ~= nil and NS.Nav.Knows(p.inst)
end

-- The flight masters the character knows on a continent: { id, inst, x, y, name }. From
-- FarstriderLib's data and its record of the flight maps the character has opened.
local function KnownNodes(inst)
    local list = nodesOf[inst]
    if list then return list end
    list = {}
    local lib = FarstriderLibData   -- the copy of the library that's running sets this
    local data = (type(lib) == "table" and lib.TaxiNodes) or (NS.FarstriderLibData and NS.FarstriderLibData.TaxiNodes)
    local saved = FarstriderLibData_CharacterSettings
    local known = type(saved) == "table" and saved.knownTaxiNodes
    if type(data) == "table" and type(known) == "table" then
        local side = Side()
        for id, n in pairs(data) do
            if known[id] == true and n[1] == inst and Serves(n[5], side) then
                list[#list + 1] = { id = id, inst = inst, x = n[2], y = n[3], name = n[6] }
            end
        end
    end
    nodesOf[inst] = list
    return list
end

-- A flight master on its continent's map, for asking FarstriderLib about it.
local function NodeOnMap(n)
    if not n.map then
        local c = continentMapOf[n.inst]
        local x, y
        if c then x, y = NS.MapPos(c, n.inst, n.x, n.y) end
        if x then n.map, n.mx, n.my = c, x, y end
    end
    return n.map
end

-- The ways onto the roads from a place: a pin's are worked out ahead; the player's are
-- searched for over the ground when no straight line gets them to a junction.
local function Onto(p, pause)
    if p.onto == nil then
        p.onto = false
        if p.pin then
            p.onto = NS.Nav.Approach(p.inst, p.pin) or false
        elseif p.player and not NS.Nav.OnRoads(p.inst, p.wx, p.wy) then
            local ways = NS.Nav.Reach(p.inst, p.wx, p.wy, pause)
            if #ways > 0 then p.onto = ways end
        end
    end
    return p.onto or nil
end

local function Walker(p, pause)
    if not p.nav then p.nav = NS.Nav.From(p.inst, p.wx, p.wy, Onto(p, pause)) end
    return p.nav
end

-- The known flight masters nearest a place by the walk: { { node, yards }, ... }.
local function Gates(p, pause)
    if p.gates then return p.gates end
    local near = {}
    for _, n in ipairs(KnownNodes(p.inst)) do
        local bird = math.sqrt((n.x - p.wx) ^ 2 + (n.y - p.wy) ^ 2)
        if bird <= GATE_RANGE then near[#near + 1] = { node = n, bird = bird } end
    end
    table.sort(near, function(a, b) return a.bird < b.bird end)
    local nav, list = Walker(p, pause), {}
    for i = 1, math.min(GATE_LOOK, #near) do
        local n = near[i].node
        local yards = nav.Walk(n.x, n.y, NS.Nav.TaxiApproach(p.inst, n.id))
        if yards then list[#list + 1] = { node = n, yards = yards } end
    end
    table.sort(list, function(a, b) return a.yards < b.yards end)
    p.gates = list
    return list
end

-- Seconds and first step of a FarstriderLib route, whether any of it is a ride (not on
-- foot), and how many of its rides are the other faction's (their added cost isn't in the
-- seconds). With `keys`, the steps that are such rides are noted in it by their id.
local function Trail(steps, edges, keys)
    if type(edges) ~= "table" or #edges == 0 then return nil end
    local cost, rides, others = 0, false, 0
    for _, e in ipairs(edges) do
        cost = cost + (tonumber(e.cost) or 0)
        if e.locaId ~= ON_FOOT then rides = true end
        if e.condition == LastResort then
            others, cost = others + 1, cost - OTHERS_COST
            if keys and type(e.to) == "table" then keys[e.to.key] = true end
        end
    end
    if not (cost > 0 and cost < math.huge) then return nil end
    return cost, rides, type(steps) == "table" and steps[1] or nil, others
end

-- FarstriderLib's travel between two flight masters: seconds and its first step. nil when
-- it has nothing to ride between them.
local function Flight(a, b)
    local key = a.id .. ">" .. b.id
    local f = flights[key]
    if f == nil then
        f = false
        local api = FarstriderLib_API
        if type(api) == "table" and api.FindTrail and NodeOnMap(a) and NodeOnMap(b) then
            local ok, steps, _, edges = pcall(api.FindTrail, a.map, a.mx, a.my, 0, b.map, b.mx, b.my, 0)
            if ok then
                local seconds, rides, step = Trail(steps, edges)
                if seconds and rides then f = { seconds, step } end
            end
        end
        flights[key] = f
    end
    if f then return f[1], f[2] end
end

-- FarstriderLib's whole route between two places, walks as straight lines and all: seconds,
-- whether any of it is a ride, its first step and how many of its rides are the other
-- faction's. nil when it has no route. `open`: with the last resort.
local function Whole(from, to, open)
    local api = FarstriderLib_API
    if type(api) == "table" and api.FindTrail then
        lastResort = open and true or false
        local ok, steps, _, edges = pcall(api.FindTrail, from.map, from.x, from.y, 0, to.map, to.x, to.y, 0)
        lastResort = false
        if ok then return Trail(steps, edges) end
    end
end

-- From one place to another: seconds, the trip when a trip is the way ({ dep, arr, step,
-- seconds }; dep is nil when FarstriderLib picks where to leave from), the walk's seconds
-- when there is a walk, and how it's done:
--
--   "walk"   on foot all the way
--   "trip"   by the trip
--   "ride"   by FarstriderLib's whole route, which rides something: where there is no walk
--            and no flight master the character knows to make a trip of
--   "none"   there is no way: no walk (an island, another continent) and nothing to ride,
--            the last resort included. The seconds are FAR.
--   "guess"  the walking data doesn't cover it and nothing rides there: the bird's distance
--
-- and, last, true when it's a "ride" by the last resort: it takes the other faction's rides.
-- `tries` is how many flight masters are weighed at each end. `plain`: without the last resort.
local function Travel(from, to, tries, pause, plain)
    local navFrom, navTo = Resolve(from), Resolve(to)
    local speed = RideSpeed()
    local walk
    if navFrom and navTo and from.inst == to.inst then
        local yards = Walker(from, pause).Walk(to.wx, to.wy, Onto(to, pause))
        if yards then walk = yards / speed end
    end
    local best, trip = walk, nil
    if navTo and (not walk or walk * speed > FLY_FROM) then
        local limit = walk and walk * FLY_BEATS or math.huge
        local arrivals = Gates(to, pause)
        local departures = navFrom and Gates(from, pause) or nil
        for i = 1, math.min(tries, #arrivals) do
            local a = arrivals[i]
            if departures then
                for j = 1, math.min(tries, #departures) do
                    local d = departures[j]
                    if d.node.id ~= a.node.id then
                        if pause then pause() end
                        local seconds, step = Flight(d.node, a.node)
                        local t = seconds and d.yards / speed + seconds + a.yards / speed
                        if t and t < limit then
                            limit, best = t, t
                            trip = { dep = d.node, arr = a.node, step = step, seconds = t }
                        end
                    end
                end
            elseif from.player then
                -- no walking data where the player stands: FarstriderLib from there to the flight master
                local api = FarstriderLib_API
                if type(api) == "table" and api.FindTrailTo and NodeOnMap(a.node) then
                    if pause then pause() end
                    local ok, steps, _, edges = pcall(api.FindTrailTo, a.node.map, a.node.mx, a.node.my, 0)
                    local seconds, rides, step
                    if ok then seconds, rides, step = Trail(steps, edges) end
                    local t = seconds and rides and seconds + a.yards / speed
                    if t and t < limit then
                        limit, best = t, t
                        trip = { arr = a.node, step = step, seconds = t }
                    end
                end
            end
        end
    end
    if best then return best, trip, walk, trip and "trip" or "walk" end
    local seconds, rides = Whole(from, to)
    if seconds and rides then return seconds, nil, nil, "ride" end
    -- Nothing to ride. Where the walking data knows both ends it has already said there is no
    -- walk, and from one continent to another there never is one. So there is no way but the
    -- last resort. (A walk made up from the bird's distance would send a Horde character
    -- swimming for Teldrassil.)
    if (navFrom and navTo) or (from.inst and to.inst and from.inst ~= to.inst) then
        if not plain and NS.db and NS.db.othersRides then
            local others
            seconds, rides, _, others = Whole(from, to, true)
            if seconds and rides and others > 0 then return seconds, nil, nil, "ride", true end
        end
        return FAR, nil, nil, "none"
    end
    local yards = NS.Between(from.map, from.x, from.y, to.map, to.x, to.y)
    return seconds or (yards and yards * WALK) or FAR, nil, nil, "guess"
end

-- The explore pin nearest a place, as a place: { map, x, y, pin }.
local pinsInWorld
local function NearestPin(p)
    if not p.inst then return nil end
    if not pinsInWorld then
        pinsInWorld = {}
        for overlay, a in pairs(NS.Areas or {}) do
            local inst, wx, wy = NS.WorldPos(a[1], a[2] / 100, a[3] / 100)
            if inst then pinsInWorld[#pinsInWorld + 1] = { overlay = overlay, map = a[1], x = a[2] / 100, y = a[3] / 100, inst = inst, wx = wx, wy = wy } end
        end
    end
    local best, near
    for _, q in ipairs(pinsInWorld) do
        if q.inst == p.inst then
            local d = (q.wx - p.wx) ^ 2 + (q.wy - p.wy) ^ 2
            if not near or d < near then best, near = q, d end
        end
    end
    return best and { map = best.map, x = best.x, y = best.y, pin = best.overlay }
end

-- Travel from where the player stands. "No way" from there is only believed when the pin
-- nearest the player has none either: the player may stand where the walking data is blind
-- (indoors, on a boat, on a ledge the grid has closed off), and then all there is to go on
-- is the bird's distance.
local function TravelFromPlayer(me, to, tries, pause)
    local seconds, trip, walk, how, others = Travel(me, to, tries, pause)
    if how ~= "none" then return seconds, trip, walk, how, others end
    local pin = NearestPin(me)
    if pin and pin.pin ~= to.pin then
        local fromPin, _, _, howPin = Travel(pin, to, tries, pause)
        if howPin ~= "none" then return fromPin, nil, nil, "guess" end
    end
    return seconds, nil, nil, how
end

---------------------------------------------------------
--  SECTION: A zone's stops in order
---------------------------------------------------------
local function Gap(a, b)   -- map percent, across counting 1.5x (zone maps are 3:2)
    local dx, dy = (a.x - b.x) * 1.5, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- A short path through n stops: nearest next, then untangled. dist(i, j) is the walk between
-- stops i and j (the same both ways). Stop 0 is where the path starts from when `start` is
-- set; otherwise `first` is the stop to begin at. Returns the stops' numbers in order.
local function Order(n, start, dist, first)
    local left, path = {}, {}
    for i = 1, n do left[i] = i end
    local cur = 0
    if not start then
        cur = table.remove(left, first or 1)
        path[1] = cur
    end
    while #left > 0 do
        local pick, near
        for i, stop in ipairs(left) do
            local d = dist(cur, stop)
            if not near or d < near then pick, near = i, d end
        end
        cur = table.remove(left, pick)
        path[#path + 1] = cur
    end
    -- untangle: turn a stretch around while that shortens the path
    local improved, rounds = true, 0
    while improved and rounds < 20 do
        improved, rounds = false, rounds + 1
        for i = 1, n - 1 do
            for j = i + 1, n do
                local before, after = path[i - 1] or (start and 0 or nil), path[j + 1]
                local old = (before and dist(before, path[i]) or 0) + (after and dist(path[j], after) or 0)
                local new = (before and dist(before, path[j]) or 0) + (after and dist(path[i], after) or 0)
                if new + 1e-9 < old then
                    local a, b = i, j
                    while a < b do
                        path[a], path[b] = path[b], path[a]
                        a, b = a + 1, b - 1
                    end
                    improved = true
                end
            end
        end
    end
    return path
end

-- A zone's areas by straight lines on its map. sx, sy: where the path starts from (map
-- percent), or nil when that isn't known.
local function OrderStops(areas, sx, sy)
    local pts = {}
    for i, a in ipairs(areas) do pts[i] = a end
    local first
    if sx then
        pts[0] = { x = sx, y = sy }
    else
        -- no start: begin at the area furthest from the middle, so the path runs end to end
        local _, mx, my = Centre(areas)
        local mid, far = { x = mx * 100, y = my * 100 }, -1
        for i, a in ipairs(areas) do
            local d = Gap(mid, a)
            if d > far then first, far = i, d end
        end
    end
    local out = {}
    for i, stop in ipairs(Order(#areas, sx ~= nil, function(i, j) return Gap(pts[i], pts[j]) end, first)) do
        out[i] = areas[stop]
    end
    return out
end

---------------------------------------------------------
--  SECTION: The plan
---------------------------------------------------------
-- plan.order: { { id = achievement, map, stops = { overlay, ... }, rough = true while the
-- stops were ordered without knowing where you'd come in } }. Areas are held by overlay ID:
-- every scan makes new area tables.
local plan, builder
local refiner        -- a coroutine putting the zone you're in into walking order
local wayfinder      -- a coroutine finding the walk from the player to the next stop
local tripfinder     -- a coroutine weighing how to get to the next stop: on foot, or a trip
local stale = true
local version = 0
local times = {}     -- ["from>to"] = { seconds between two zones (false: no way), true when by the other faction's rides }
local cutOff = {}    -- [zone's challenge ID] = whether the faction's own rides and roads don't reach it
local lastMap

local function Changed()
    version = version + 1
    if NS.PinsStale then NS.PinsStale() end
    if NS.UI and NS.UI.RefreshAll and ExplorerFrame and ExplorerFrame:IsVisible() then NS.UI.RefreshAll() end
end

local function KnownZones()
    local n = 0
    for _, zone in ipairs(NS.LastProgress()) do
        if zone.known then n = n + 1 end
    end
    return n
end

local function Shortlist(cands, map, x, y)
    if #cands <= SHORTLIST then return cands end
    local inst, wx, wy = NS.WorldPos(map, x, y)
    if not inst then return cands end
    local near = {}
    for _, c in ipairs(cands) do
        local ci, cx, cy = NS.WorldPos(c.map, c.cx, c.cy)
        if ci == inst then near[#near + 1] = { c = c, d = (cx - wx) ^ 2 + (cy - wy) ^ 2 } end
    end
    if #near == 0 then return cands end   -- nothing left on this continent: weigh them all
    table.sort(near, function(a, b) return a.d < b.d end)
    local out = {}
    for i = 1, math.min(SHORTLIST, #near) do out[i] = near[i].c end
    return out
end

-- Runs as a coroutine: it yields before every travel lookup.
local function Build(p)
    local db = NS.db
    local pm, px, py = NS.PlayerPos()
    local here = pm and Continent(pm)
    local cands = {}
    for _, zone in ipairs(NS.LastProgress()) do
        if zone.known and zone.done < zone.total then
            local left = Left(zone)
            if #left > 0 then
                local map = left[1].map
                local inZone = map == pm
                local ok = inZone or db.routeScope == "all"
                    or (db.routeScope == "continent" and here and Continent(map) == here)
                if ok and not inZone and Route.TooHigh(zone) then ok = false end
                if ok then
                    -- the zone stands at the pin nearest the middle of what's left: a pin has a
                    -- worked-out way onto the roads, a point in the middle may be on a mountain
                    local _, mx, my = Centre(left)
                    local mid, at, near = { x = mx * 100, y = my * 100 }, left[1], nil
                    for _, a in ipairs(left) do
                        local d = Gap(mid, a)
                        if not near or d < near then at, near = a, d end
                    end
                    cands[#cands + 1] = { zone = zone, left = left, map = map, cx = at.x / 100, cy = at.y / 100,
                        pin = at.overlay, inZone = inZone }
                end
            end
        end
    end

    local from                           -- the zone the route stands in
    local curMap, curX, curY = pm, px, py
    local me = { map = pm, x = px, y = py, player = true }
    local function Place(c)
        local place = places[c.zone.id]
        if not place or place.pin ~= c.pin then
            place = { map = c.map, x = c.cx, y = c.cy, pin = c.pin }
            places[c.zone.id] = place
        end
        return place
    end
    -- Whether a zone is cut off: the faction's own roads and rides don't get to it from the
    -- rest of the world. A journey that takes the other faction's rides doesn't say which end
    -- is the one cut off (out of Teldrassil is by their boat as much as into it), so the zone
    -- is tried from three zones elsewhere, and is cut off when most of those have no way.
    local function CutOff(c)
        local cut = cutOff[c.zone.id]
        if cut == nil then
            local tried, failed = 0, 0
            for _, z in ipairs(NS.Zones) do
                local a = NS.Areas[z[3]]
                if tried < 3 and z[1] ~= c.zone.id and a and a[1] ~= c.map then
                    coroutine.yield()
                    local _, _, _, how = Travel({ map = a[1], x = a[2] / 100, y = a[3] / 100, pin = z[3] }, Place(c), 2, coroutine.yield, true)
                    tried = tried + 1
                    if how == "none" then failed = failed + 1 end
                end
            end
            cut = failed * 2 > tried
            cutOff[c.zone.id] = cut
        end
        return cut
    end
    local function Add(c, sx, sy, rough, noWay, others)
        local path = OrderStops(c.left, sx, sy)
        local stops = {}
        for i, a in ipairs(path) do stops[i] = a.overlay end
        p.order[#p.order + 1] = { id = c.zone.id, map = c.map, stops = stops, rough = rough, noWay = noWay, others = others }
        local last = path[#path]
        from, curMap, curX, curY = c, last.map, last.x / 100, last.y / 100
        Changed()
    end

    for i, c in ipairs(cands) do
        if c.inZone then
            table.remove(cands, i)
            Add(c, px * 100, py * 100, false)
            break
        end
    end
    -- A zone that takes the other faction's rides to get to (Teldrassil, for the Horde) goes
    -- where its travel time puts it, marked if it's the one cut off. A zone there is no way to at all from where the
    -- route stands (c.lost: the same zone with that setting off) waits. It goes in once
    -- everything with a way is placed, marked as having none. If nothing left has a way, it's
    -- where the route stands that is cut off: the nearest zone goes next, marked, and the rest
    -- are weighed again from there.
    while #cands > 0 do
        local open = {}
        for _, c in ipairs(cands) do
            if not c.lost then open[#open + 1] = c end
        end
        local best, bestTime, noWay, bestOthers
        if #open == 0 then
            best, noWay = Shortlist(cands, curMap, curX, curY)[1], true
            for _, c in ipairs(cands) do c.lost = nil end
        else
            for _, c in ipairs(Shortlist(open, curMap, curX, curY)) do
                local key = from and (from.zone.id .. ">" .. c.zone.id)
                local hit = key and times[key]   -- { seconds or false for no way, by the other faction's rides }
                if not hit then
                    coroutine.yield()
                    local t, how, others, _
                    if from then
                        t, _, _, how, others = Travel(Place(from), Place(c), 2, coroutine.yield)
                    else
                        t, _, _, how, others = TravelFromPlayer(me, Place(c), 2, coroutine.yield)
                    end
                    hit = { how ~= "none" and t, others }
                    if key then times[key] = hit end
                end
                if not hit[1] then
                    c.lost = true
                elseif not bestTime or hit[1] < bestTime then
                    best, bestTime, bestOthers = c, hit[1], hit[2]
                end
            end
        end
        if best then
            for i, c in ipairs(cands) do
                if c == best then table.remove(cands, i) break end
            end
            -- the zone's path starts from where the route comes in, as near as the maps can say
            local sx, sy
            local inst, wx, wy = NS.WorldPos(curMap, curX, curY)
            if inst then sx, sy = NS.MapPos(best.map, inst, wx, wy) end
            if sx then sx, sy = sx * 100, sy * 100 end
            Add(best, sx, sy, true, noWay, bestOthers and CutOff(best))
        end
    end
    p.done = true
end

-- The zone you're in, by real walks: terrain and roads between every two stops, the order
-- from those, and the way between each two stops in a row for the map. Runs as a coroutine
-- (one stop's walks a step) after the straight-line order is already up.
local function Refine(e)
    local Nav = NS.Nav
    local pm, px, py = NS.PlayerPos()
    if not Nav or pm ~= e.map then return end
    local inst, wx, wy = NS.WorldPos(pm, px, py)
    if not (inst and Nav.Knows(inst)) then return end
    -- onto[i]: the ways onto the roads from stop i, worked out ahead for every pin; for the
    -- player (0) a search over the ground, when no straight line gets them to a junction
    local areas, pts, onto = {}, { [0] = { wx, wy } }, {}
    for _, overlay in ipairs(e.stops) do
        local a = NS.AreaByOverlay(overlay)
        local ai, ax, ay
        if a then ai, ax, ay = NS.WorldPos(a.map, a.x / 100, a.y / 100) end
        if ai ~= inst then return end
        areas[#areas + 1] = a
        pts[#areas] = { ax, ay }
        onto[#areas] = Nav.Approach(inst, overlay)
    end
    local n = #areas
    if n < 2 then return end
    if not Nav.OnRoads(inst, wx, wy) then
        local ways = Nav.Reach(inst, wx, wy, coroutine.yield)
        if #ways > 0 then onto[0] = ways end
    end

    local from, D = {}, {}
    for i = 0, n do D[i] = {} end
    for i = 0, n - 1 do
        coroutine.yield()
        from[i] = Nav.From(inst, pts[i][1], pts[i][2], onto[i])
        for j = i + 1, n do
            local d = from[i].Walk(pts[j][1], pts[j][2], onto[j])
            if not d then
                d = math.sqrt((pts[i][1] - pts[j][1]) ^ 2 + (pts[i][2] - pts[j][2]) ^ 2) * UNREACHED
            end
            D[i][j], D[j][i] = d, d
        end
    end
    local order = Order(n, true, function(i, j) return D[i][j] end)

    local ways = {}
    for k = 2, n do
        coroutine.yield()
        local a, b = order[k - 1], order[k]
        local ctx = from[a] or Nav.From(inst, pts[a][1], pts[a][2], onto[a])
        local yards, how, points = ctx.Path(pts[b][1], pts[b][2], onto[b])
        if yards and how ~= "direct" then
            ways[areas[a].overlay .. ">" .. areas[b].overlay] = { inst = inst, points = points }
        end
    end

    -- stops ticked while this ran are gone from e.stops: the new order is for the rest
    local still, stops = {}, {}
    for _, overlay in ipairs(e.stops) do still[overlay] = true end
    for _, stop in ipairs(order) do
        local overlay = areas[stop].overlay
        if still[overlay] then stops[#stops + 1] = overlay end
    end
    e.stops, e.ways = stops, ways
    Changed()
end

local function Step()
    if not builder and not refiner and not wayfinder and not tripfinder then return end
    local started = debugprofilestop and debugprofilestop() or 0
    repeat
        if tripfinder then
            local ok = coroutine.resume(tripfinder)
            if not ok or coroutine.status(tripfinder) == "dead" then tripfinder = nil end
        elseif wayfinder then
            local ok = coroutine.resume(wayfinder)
            if not ok or coroutine.status(wayfinder) == "dead" then wayfinder = nil end
        elseif refiner then
            local ok = coroutine.resume(refiner)
            if not ok or coroutine.status(refiner) == "dead" then refiner = nil end
        elseif builder then
            local ok, err = coroutine.resume(builder)
            if not ok or coroutine.status(builder) == "dead" then
                builder = nil
                if plan then
                    plan.done = true
                    if not ok then plan.error = tostring(err) end
                end
                Changed()
            end
        else
            return
        end
    until not debugprofilestop or debugprofilestop() - started > BUDGET_MS
end

local function Start()
    local db = NS.db
    plan = { order = {}, done = false, scope = db.routeScope, allLevels = db.routeAllLevels, known = KnownZones(),
        othersRides = db.othersRides }
    stale, refiner, wayfinder = false, nil, nil
    local p = plan
    builder = coroutine.create(function() Build(p) end)
    -- up to the first travel lookup: the zone you're in is ready at once
    local ok, err = coroutine.resume(builder)
    if not ok or coroutine.status(builder) == "dead" then
        builder, plan.done = nil, true
        if not ok then plan.error = tostring(err) end
    end
    Changed()
end

-- Ticked and skipped stops go, and zones with none left.
local function Prune()
    if not plan then return false end
    local changed = false
    for i = #plan.order, 1, -1 do
        local e = plan.order[i]
        for j = #e.stops, 1, -1 do
            local a = NS.AreaByOverlay(e.stops[j])
            if not a or a.done or skipped[e.stops[j]] then
                table.remove(e.stops, j)
                changed = true
            end
        end
        if #e.stops == 0 then
            table.remove(plan.order, i)
            changed = true
        end
    end
    return changed
end

-- The zone you've walked into: its stops again, from where you stand.
local function Resort(e, px, py)
    local areas = {}
    for _, overlay in ipairs(e.stops) do
        local a = NS.AreaByOverlay(overlay)
        if a then areas[#areas + 1] = a end
    end
    if #areas > 0 then
        for i, a in ipairs(OrderStops(areas, px * 100, py * 100)) do e.stops[i] = a.overlay end
    end
    e.rough = false
end

---------------------------------------------------------
--  SECTION: The guide
---------------------------------------------------------
local guide


-- A FarstriderLib step as the arrow's leg: { map, x, y, text }.
local function StepLeg(step)
    local loc = type(step) == "table" and step.loc
    local pos = type(loc) == "table" and loc.pos
    if not (pos and type(loc.mapId) == "number" and type(pos.x) == "number" and type(pos.y) == "number") then return nil end
    if pos.x < -0.5 or pos.x > 1.5 or pos.y < -0.5 or pos.y > 1.5 then return nil end   -- not a map position
    return { map = loc.mapId, x = pos.x, y = pos.y, text = type(step.loca) == "string" and step.loca or "Travel on" }
end

-- FarstriderLib's own first step from where the player stands to a stop, or nil when it
-- would walk. Only for where the walking data has nothing to weigh. `open`: with the last
-- resort; a step that is a ride of the other faction's says so.
local function Leg(stop, open)
    local api = FarstriderLib_API
    if type(api) ~= "table" or not api.FindTrailTo then return nil end
    lastResort = open and true or false
    local ok, steps, _, edges = pcall(api.FindTrailTo, stop.map, stop.x / 100, stop.y / 100, 0)
    lastResort = false
    if not ok or type(steps) ~= "table" or #steps < 2 then return nil end
    local leg = StepLeg(steps[1])
    if leg and open then
        local theirs = {}
        Trail(steps, edges, theirs)
        if theirs[steps[1].id] then
            leg.others = true
            leg.text = ("%s (%s)"):format(leg.text, OthersName())
        end
    end
    return leg
end

-- How to get to a stop from where the player stands: the first leg of a trip
-- ({ map, x, y, text }) or nil to walk, the trip, how it's done and whether that takes the
-- other faction's rides (see Travel).
function Route.FindTrip(stop, pm, px, py, pause)
    local from = { map = pm, x = px, y = py, player = true }
    local to = { map = stop.map, x = stop.x / 100, y = stop.y / 100, pin = stop.overlay }
    local _, trip, _, how, others = TravelFromPlayer(from, to, 3, pause)
    if trip then
        local leg = StepLeg(trip.step)
        if not leg and trip.dep and NodeOnMap(trip.dep) then
            leg = { map = trip.dep.map, x = trip.dep.mx, y = trip.dep.my,
                text = ("Fly from %s to %s"):format(trip.dep.name, trip.arr.name) }
        end
        return leg, trip, how
    end
    if how == "ride" then return Leg(stop, others), nil, how, others end
    return nil, nil, how
end

-- What the arrow and the window say where there is no way to a stop.
function Route.NoWayText()
    local side, name = Side()
    if side == 0 or type(name) ~= "string" then return "No way there: no road, flight or boat" end
    return ("No way there for the %s: no road, flight or boat"):format(name)
end

-- And where the only way takes the other faction's rides.
function Route.OthersText()
    return ("only by %s rides"):format(OthersName())
end

-- The walk from the player to the stop (or to the first leg of the trip): g.way, with the
-- points on the way and the one to head for now when the straight line is blocked. Found by
-- a coroutine: where no straight line gets the player onto a road, the way there is searched
-- for over the ground, which takes a few frames.
local function UpdateWay(g, pm, px, py)
    local Nav = NS.Nav
    local toStop = not g.leg
    local tm, tx, ty = g.stop.map, g.stop.x / 100, g.stop.y / 100
    if g.leg then tm, tx, ty = g.leg.map, g.leg.x, g.leg.y end
    local inst, wx, wy = NS.WorldPos(pm, px, py)
    local ti, twx, twy = NS.WorldPos(tm, tx, ty)
    if not (Nav and inst and ti == inst and Nav.Knows(inst)) then
        g.way = nil
        return
    end
    if wayfinder then return end
    local now, w = GetTime(), g.way
    if w and w.tx == twx and w.ty == twy and now - w.at < WAY_EVERY
        and (wx - w.px) ^ 2 + (wy - w.py) ^ 2 < WAY_MOVED ^ 2
        and not (w.x and (wx - w.x) ^ 2 + (wy - w.y) ^ 2 < 20 ^ 2) then
        return
    end
    local overlay = toStop and g.stop.overlay or nil
    wayfinder = coroutine.create(function()
        local onto
        if not Nav.OnRoads(inst, wx, wy) then
            local ways = Nav.Reach(inst, wx, wy, coroutine.yield)
            if #ways > 0 then onto = ways end
        end
        local yards, how, points = Nav.From(inst, wx, wy, onto).Path(twx, twy, Nav.Approach(inst, overlay))
        local new = { at = now, px = wx, py = wy, tx = twx, ty = twy, inst = inst }
        local bird = math.sqrt((twx - wx) ^ 2 + (twy - wy) ^ 2)
        if yards and how ~= "direct" then
            new.yards, new.points = yards, points
            new.x, new.y = Nav.Ahead(inst, wx, wy, points, twx, twy)
        end
        if guide ~= g then return end   -- the stop changed while this ran
        g.way = new
        -- how much longer than the bird's distance the walk to the stop is, for weighing a flight
        if toStop and bird > 50 then g.walkRatio = math.max(1, (yards or bird) / bird) end
        if NS.PinsStale then NS.PinsStale() end
    end)
end

local function UpdateGuide(pm, px, py, onTaxi)
    local stop, e = Route.Next()
    if not stop then guide = nil return end
    local g = guide
    if not g or g.overlay ~= stop.overlay then
        g = { overlay = stop.overlay }
        guide = g
    end
    g.stop, g.entry = stop, e
    if not pm then return end
    if onTaxi or InCombatLockdown() then   -- what's there stands while you fly or fight
        g.flew = g.flew or onTaxi
        return
    end
    if g.flew then g.flew, g.leg, g.tripAt = nil, nil, nil end   -- landed: look again from here
    -- How to get there is weighed again every so often and on entering another zone, by a
    -- coroutine (it may search the ground and ask FarstriderLib several times).
    local now = GetTime()
    if not tripfinder and (g.tripFrom ~= pm or not g.tripAt or now - g.tripAt >= TRIP_EVERY) then
        g.tripFrom, g.tripAt = pm, now
        tripfinder = coroutine.create(function()
            local leg, _, how, others = Route.FindTrip(stop, pm, px, py, coroutine.yield)
            if guide == g then g.leg, g.noWay, g.others = leg, how == "none", others or false end
        end)
        local ok = coroutine.resume(tripfinder)
        if not ok or coroutine.status(tripfinder) == "dead" then tripfinder = nil end
    end
    UpdateWay(g, pm, px, py)
end

---------------------------------------------------------
--  SECTION: Keeping it current
---------------------------------------------------------
local function Tick()
    local db = NS.db
    if not db or not NS.Scanned() then return end
    if not db.route or Route.failed then
        if plan then plan, builder, guide = nil, nil, nil; Changed() end
        return
    end
    local pm, px, py = NS.PlayerPos()
    local onTaxi = UnitOnTaxi ~= nil and UnitOnTaxi("player") and true or false
    if plan and (plan.scope ~= db.routeScope or plan.allLevels ~= db.routeAllLevels or plan.known ~= KnownZones()) then
        stale = true
    end
    if plan and plan.othersRides ~= db.othersRides then   -- the last resort went on or off: every journey is to weigh again
        times, cutOff, stale, guide = {}, {}, true, nil
        ForgetTravel()
    end
    if (stale or not plan) and pm then Start() end
    if not plan then return end

    local changed = Prune()
    if pm and not onTaxi then
        local first = plan.order[1]
        if first and first.map ~= pm then
            -- walked into another zone with stops: it goes first
            for i = 2, #plan.order do
                if plan.order[i].map == pm then
                    Start()
                    first, changed = plan.order[1], false
                    break
                end
            end
        elseif first then
            if first.rough or lastMap ~= pm then
                Resort(first, px, py)
                first.walked, changed = false, true
            end
            if not first.walked and not refiner then
                first.walked = true
                local e = first
                refiner = coroutine.create(function() Refine(e) end)
            end
        end
        lastMap = pm
    end
    if changed then Changed() end
    UpdateGuide(pm, px, py, onTaxi)
end

-- Core calls this after a scan found new ticks.
function Route.OnProgress()
    if plan and Prune() then Changed() end
    if plan then
        local pm, px, py = NS.PlayerPos()
        UpdateGuide(pm, px, py, false)
    end
end

function Route.Next()
    local e = plan and plan.order[1]
    if not e then return nil end
    return NS.AreaByOverlay(e.stops[1]), e
end

-- { stop = area, entry, leg = { map, x, y, text } or nil, noWay = true when there is no way
-- to the stop from where the player stands, others = true when the only way takes the other
-- faction's rides }, or nil with nowhere to go.
function Route.Guide() return guide end

-- The zones in order, and whether the order is complete.
function Route.Order()
    if not plan then return nil, false end
    return plan.order, plan.done
end

-- A stop's place: its zone's number in the route and its own number in that zone.
function Route.Index(overlay)
    if not plan then return nil end
    if plan.indexVersion ~= version then
        local index = {}
        for zi, e in ipairs(plan.order) do
            for si, o in ipairs(e.stops) do index[o] = { zi, si } end
        end
        plan.index, plan.indexVersion = index, version
    end
    local t = plan.index[overlay]
    if t then return t[1], t[2] end
end

-- The road between two stops in a row, where the straight line between them is blocked:
-- { inst, points = { x1, y1, ... } } in world yards, or nil for a straight walk.
function Route.Way(fromOverlay, toOverlay)
    if not plan then return nil end
    local key = fromOverlay .. ">" .. toOverlay
    for _, e in ipairs(plan.order) do
        if e.ways and e.ways[key] then return e.ways[key] end
    end
end

function Route.Skip()
    local stop = Route.Next()
    if not stop then return nil end
    skipped[stop.overlay] = true
    Prune()
    Changed()
    local pm, px, py = NS.PlayerPos()
    UpdateGuide(pm, px, py, false)
    return stop
end

-- Plan again from where you stand; skipped stops come back.
function Route.Replan()
    skipped, times, cutOff, stale, guide = {}, {}, {}, true, nil
    ForgetTravel()
    Tick()
end

local frame = CreateFrame("Frame")
local since = 0
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LEVEL_UP" then
        ForgetTravel()
        times, cutOff, stale = {}, {}, true    -- a faster mount changes the travel times, and more zones are in reach
    else
        lastMap = nil
        local api = FarstriderLib_API
        -- a copy of the library that took over after this file loaded has built its graph
        -- from a list this file hasn't sorted
        local ok, changed = pcall(SortRides)
        if ok and changed > 0 and type(api) == "table" and api.Rebuild then pcall(api.Rebuild) end
        -- FarstriderLib rebuilds its graph when a flight master's map teaches it new flight paths
        if not Route.hooked and type(api) == "table" and api.RegisterRebuildCallback then
            Route.hooked = pcall(api.RegisterRebuildCallback, function() times, cutOff = {}, {}; ForgetTravel() end)
        end
    end
end)
frame:SetScript("OnUpdate", function(_, elapsed)
    if (builder or refiner or wayfinder or tripfinder) and not InCombatLockdown() then
        local ok = pcall(Step)
        if not ok then builder, refiner, wayfinder, tripfinder = nil, nil, nil, nil end
    end
    since = since + elapsed
    if since < 1 then return end
    since = 0
    local ok, err = pcall(Tick)
    if not ok and not Route.failed then
        Route.failed = true   -- for this session; the setting stays as it is
        NS.Print("route planning hit an error and is off until /reload: " .. tostring(err))
    end
end)

Route.Tick = Tick   -- for the settings and the tests
Route.Step = Step
Route.Travel = Travel            -- for the tests
Route.ForgetTravel = ForgetTravel
-- FarstriderLib's steps and edges between two map points, with or without the last resort.
function Route.Ask(m1, x1, y1, m2, x2, y2, open)
    lastResort = open and true or false
    local ok, steps, _, edges = pcall(FarstriderLib_API.FindTrail, m1, x1, y1, 0, m2, x2, y2, 0)
    lastResort = false
    if ok then return steps, edges end
end
