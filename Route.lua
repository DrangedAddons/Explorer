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
--           stops are ready at once.
--   guide   the next stop, and when it's in another zone the first thing to do to get
--           there ("Talk to the Flightmaster to travel to ..."), from FarstriderLib.
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
local LEG_EVERY = 3         -- seconds between travel lookups for the same stop
local ON_FOOT = 1000        -- FarstriderLib's kind of step for going on foot
local UNREACHED = 1.5       -- no way found on foot: the bird's distance and half again
local WAY_EVERY, WAY_MOVED = 5, 25   -- the walk to the next stop is found again after this many seconds or yards
local FLY_FROM = 1200       -- yards of walking inside a zone from which a flight is weighed against it
local FLY_BEATS = 0.8       -- ... and taken when it needs under this much of the walk's time

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

-- Walks from a zone's middle, kept by zone so one look at the roads serves every zone
-- weighed from it. { inst, wx, wy, nav } or false without walking data there.
local walkers = {}

local function Walker(key, map, x, y)
    local w = key and walkers[key]
    if w == nil then
        w = false
        local inst, wx, wy = NS.WorldPos(map, x, y)
        if inst and NS.Nav and NS.Nav.Knows(inst) then
            w = { inst = inst, wx = wx, wy = wy, nav = NS.Nav.From(inst, wx, wy) }
        end
        if key then walkers[key] = w end
    end
    return w or nil
end

-- Yards on foot between two map points by terrain and roads, and as the bird flies.
-- nil without walking data, across continents, or with no way found.
local function WalkYards(key, m1, x1, y1, m2, x2, y2)
    local w = Walker(key, m1, x1, y1)
    if not w then return nil end
    local inst, tx, ty = NS.WorldPos(m2, x2, y2)
    if inst ~= w.inst then return nil end
    local yards = w.nav.Walk(tx, ty)
    if not yards then return nil end
    return yards, math.sqrt((tx - w.wx) ^ 2 + (ty - w.wy) ^ 2)
end

-- Seconds from one map point to another. FarstriderLib's route where it has one; a route of
-- its that is all on foot is a straight line with 30% added, so that one is scaled to the
-- walk the terrain and roads allow. `key` names the start when it's a zone's middle.
local function TravelTime(key, m1, x1, y1, m2, x2, y2)
    local api = FarstriderLib_API
    if type(api) == "table" and api.FindTrail then
        local ok, _, _, edges = pcall(api.FindTrail, m1, x1, y1, 0, m2, x2, y2, 0)
        if ok and type(edges) == "table" and #edges > 0 then
            local cost, onFoot = 0, true
            for _, e in ipairs(edges) do
                cost = cost + (tonumber(e.cost) or 0)
                if e.locaId ~= ON_FOOT then onFoot = false end
            end
            if cost > 0 and cost < math.huge then
                if onFoot then
                    local yards, bird = WalkYards(key, m1, x1, y1, m2, x2, y2)
                    if yards and bird > 1 then cost = cost * yards / (bird * 1.3) end
                end
                return cost
            end
        end
    end
    local yards = WalkYards(key, m1, x1, y1, m2, x2, y2)
    if yards then return yards / 7 end
    yards = NS.Between(m1, x1, y1, m2, x2, y2)
    return yards and yards * WALK or FAR
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
local stale = true
local version = 0
local times = {}     -- ["from>to"] = seconds between two zones' middles
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
                    local _, cx, cy = Centre(left)
                    cands[#cands + 1] = { zone = zone, left = left, map = map, cx = cx, cy = cy, inZone = inZone }
                end
            end
        end
    end

    local from                           -- the zone the route stands in
    local curMap, curX, curY = pm, px, py
    local function Add(c, sx, sy, rough)
        local path = OrderStops(c.left, sx, sy)
        local stops = {}
        for i, a in ipairs(path) do stops[i] = a.overlay end
        p.order[#p.order + 1] = { id = c.zone.id, map = c.map, stops = stops, rough = rough }
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
    while #cands > 0 do
        local best, bestTime
        for _, c in ipairs(Shortlist(cands, curMap, curX, curY)) do
            local key = from and (from.zone.id .. ">" .. c.zone.id)
            local t = key and times[key]
            if not t then
                coroutine.yield()
                if from then
                    t = TravelTime(from.zone.id, from.map, from.cx, from.cy, c.map, c.cx, c.cy)
                    times[key] = t
                else
                    t = TravelTime(nil, curMap, curX, curY, c.map, c.cx, c.cy)
                end
            end
            if not bestTime or t < bestTime then best, bestTime = c, t end
        end
        for i, c in ipairs(cands) do
            if c == best then table.remove(cands, i) break end
        end
        -- the zone's path starts from where the route comes in, as near as the maps can say
        local sx, sy
        local inst, wx, wy = NS.WorldPos(curMap, curX, curY)
        if inst then sx, sy = NS.MapPos(best.map, inst, wx, wy) end
        if sx then sx, sy = sx * 100, sy * 100 end
        Add(best, sx, sy, true)
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
        if yards and how == "road" then
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
    if not builder and not refiner and not wayfinder then return end
    local started = debugprofilestop and debugprofilestop() or 0
    repeat
        if wayfinder then
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
    plan = { order = {}, done = false, scope = db.routeScope, allLevels = db.routeAllLevels, known = KnownZones() }
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
local legAt = 0

-- Yards a second on the ground at the player's level, as FarstriderLib counts it for Forever.
local function RideSpeed()
    local level = UnitLevel and UnitLevel("player") or 1
    return level >= 60 and 14 or level >= 40 and 11.2 or 7
end

-- The first thing to do on a trip to a stop: { map, x, y, text }, or nil when it's a walk.
-- `walkSeconds`: only take a trip that beats this walk clearly (a flight inside one zone).
local function Leg(stop, walkSeconds)
    local api = FarstriderLib_API
    if type(api) ~= "table" or not api.FindTrailTo then return nil end
    local ok, steps, _, edges = pcall(api.FindTrailTo, stop.map, stop.x / 100, stop.y / 100, 0)
    if not ok or type(steps) ~= "table" or #steps < 2 then return nil end
    if walkSeconds then
        local cost = 0
        for _, e in ipairs(type(edges) == "table" and edges or {}) do cost = cost + (tonumber(e.cost) or 0) end
        if not (cost > 0 and cost < walkSeconds * FLY_BEATS) then return nil end
    end
    local s = steps[1]
    local loc = type(s) == "table" and s.loc
    local pos = type(loc) == "table" and loc.pos
    if not (pos and type(loc.mapId) == "number" and type(pos.x) == "number" and type(pos.y) == "number") then return nil end
    if pos.x < -0.5 or pos.x > 1.5 or pos.y < -0.5 or pos.y > 1.5 then return nil end   -- not a map position
    return { map = loc.mapId, x = pos.x, y = pos.y, text = type(s.loca) == "string" and s.loca or "Travel on" }
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
        if yards and how == "road" then
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
        guide, legAt = g, 0
    end
    g.stop, g.entry = stop, e
    if not pm then return end
    if onTaxi or InCombatLockdown() then   -- what's there stands while you fly or fight
        g.flew = g.flew or onTaxi
        return
    end
    if g.flew then g.flew, g.leg, g.legFrom = nil, nil, nil end   -- landed: look again from here
    -- A trip (flight, boat, tram) for a stop in another zone. In the same zone only for a long
    -- walk, and only when the flight beats walking clearly.
    local walkSeconds
    if pm == stop.map then
        local bird = NS.Between(pm, px, py, stop.map, stop.x / 100, stop.y / 100)
        local yards = bird and bird * (g.walkRatio or 1.3)
        if yards and yards > FLY_FROM then walkSeconds = yards / RideSpeed() end
    end
    if pm ~= stop.map or walkSeconds then
        local now = GetTime()
        if g.legFrom ~= pm or now - legAt >= LEG_EVERY then
            legAt, g.legFrom = now, pm
            g.leg = Leg(stop, walkSeconds)
        end
    else
        g.leg, g.legFrom = nil, nil
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

-- { stop = area, entry, leg = { map, x, y, text } or nil }, or nil with nowhere to go.
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
    skipped, times, walkers, stale, guide = {}, {}, {}, true, nil
    Tick()
end

local frame = CreateFrame("Frame")
local since = 0
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LEVEL_UP" then
        times, walkers, stale = {}, {}, true    -- a faster mount changes the travel times, and more zones are in reach
    else
        lastMap = nil
        -- FarstriderLib rebuilds its graph when a flight master's map teaches it new flight paths
        local api = FarstriderLib_API
        if not Route.hooked and type(api) == "table" and api.RegisterRebuildCallback then
            Route.hooked = pcall(api.RegisterRebuildCallback, function() times = {} end)   -- walks don't change with it
        end
    end
end)
frame:SetScript("OnUpdate", function(_, elapsed)
    if (builder or refiner or wayfinder) and not InCombatLockdown() then
        local ok = pcall(Step)
        if not ok then builder, refiner, wayfinder = nil, nil, nil end
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
