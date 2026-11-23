---------------------------------------------------------
--  Explorer - Walking
--  Author: Dranged
---------------------------------------------------------
-- Getting somewhere on foot on a continent: the ground (AzerothGPS's terrain grid with its
-- bridges and tunnels laid in), drawn walls and the road network with each road's course, from
-- AzerothGPS's data (Nav/*.lua, built by tools/build_nav_data.py with its author's
-- permission). Started from VendorPoint's Nav.lua, which only measures a walk; this one also
-- gives the way: the points to pass.
--
-- A walk is a straight line when the ground allows it. Otherwise it's a straight walk to a
-- road junction nearby, along the roads, and a straight walk off the last junction.
-- World coordinates are yards, x north, y west. Continents are the game's instance IDs.

local _, NS = ...
local Nav = {}
NS.Nav = Nav

local TILE = 1600 / 3
local SWIM = 1.5          -- swimming is about 2/3 of run speed
local END_SLACK = 40      -- blocked ground this close to either end is ignored: pins sit on
                          -- ledges and rooftops, and the player is evidently standing there
local SNAP_RANGE = 600    -- road junctions this close (as the bird flies) are tried to get on or off
local SNAP_TRIES = 6      -- ... the nearest this many of them
local CLEAR = 1.05        -- a straight walk this close to the bird's distance has no road to beat it
local LOOSE_RANGE = 2000  -- with no junction in clear reach (a pin up a slope, on a roof, in a
local LOOSE = 1.5         -- river): the nearest ones within this, the last stretch counted this
local LOOSE_TRIES = 2     -- much longer than the bird's distance
local AT_JUNCTION = 30    -- yards from a junction that count as having reached it
local NEAR_END = 400      -- the end is tried for a straight walk first when it's this close

---------------------------------------------------------
--  SECTION: Terrain grid (run-length rows, decoded the first time a row is read)
---------------------------------------------------------
local ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local INDEX = {}
for i = 1, #ALPHABET do INDEX[ALPHABET:byte(i)] = i - 1 end
local SHORT = 21

local function DecodeRow(text)
    local runs, pos, i, n = {}, 0, 1, #text
    while i <= n do
        local b = text:byte(i)
        local v, len
        if b == 95 then -- "_": a long run, value then three length digits
            v = text:byte(i + 1) - 48
            len = INDEX[text:byte(i + 2)] * 4096 + INDEX[text:byte(i + 3)] * 64 + INDEX[text:byte(i + 4)]
            i = i + 5
        else
            local k = INDEX[b]
            v = math.floor(k / SHORT)
            len = k % SHORT + 1
            i = i + 1
        end
        pos = pos + len
        runs[#runs + 1] = pos
        runs[#runs + 1] = v
    end
    return runs
end

local rowCache = {}  -- [grid][row] = runs
local openCache = {} -- [cont] = { [row * 65536 + col] = true }

local function Opens(cont)
    local set = openCache[cont]
    if not set then
        set = {}
        for _, key in ipairs(NS.Opens and NS.Opens[cont] or {}) do set[key] = true end
        openCache[cont] = set
    end
    return set
end

-- 0 open, 1 water, 2 blocked (and off the grid).
local function Cell(g, opens, row, col)
    if row < 1 or row > g.h or col < 1 or col > g.w then return 2 end
    if opens[row * 65536 + col] then return 0 end
    local rc = rowCache[g]
    if not rc then rc = {}; rowCache[g] = rc end
    local runs = rc[row]
    if not runs then
        runs = DecodeRow(g.rows[row])
        rc[row] = runs
    end
    local lo, hi = 1, #runs / 2
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if runs[mid * 2 - 1] < col then lo = mid + 1 else hi = mid end
    end
    return runs[lo * 2]
end

---------------------------------------------------------
--  SECTION: Walls (point lists): a leg crossing one is blocked
---------------------------------------------------------
local wallBoxes = {} -- [cont] = { { pts, minX, minY, maxX, maxY }, ... }

local function Walls(cont)
    local list = wallBoxes[cont]
    if list then return list end
    list = {}
    for _, pts in ipairs(NS.Walls and NS.Walls[cont] or {}) do
        local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, #pts - 1, 2 do
            x1, x2 = math.min(x1, pts[i]), math.max(x2, pts[i])
            y1, y2 = math.min(y1, pts[i + 1]), math.max(y2, pts[i + 1])
        end
        list[#list + 1] = { pts, x1, y1, x2, y2 }
    end
    wallBoxes[cont] = list
    return list
end

local function Orient(ax, ay, bx, by, cx, cy)
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

local function CrossesWall(cont, x1, y1, x2, y2)
    local lx1, lx2 = math.min(x1, x2), math.max(x1, x2)
    local ly1, ly2 = math.min(y1, y2), math.max(y1, y2)
    for _, w in ipairs(Walls(cont)) do
        if w[4] >= lx1 and w[2] <= lx2 and w[5] >= ly1 and w[3] <= ly2 then
            local pts = w[1]
            for i = 1, #pts - 3, 2 do
                local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
                local d1, d2 = Orient(x1, y1, x2, y2, ax, ay), Orient(x1, y1, x2, y2, bx, by)
                local d3, d4 = Orient(ax, ay, bx, by, x1, y1), Orient(ax, ay, bx, by, x2, y2)
                if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then return true end
            end
        end
    end
    return false
end

---------------------------------------------------------
--  SECTION: A straight walk
---------------------------------------------------------
-- Yards of walking straight from (x1, y1) to (x2, y2), water counted slower, or nil when the
-- line crosses steep ground or a wall. Without terrain data for the continent: the distance.
function Nav.Segment(cont, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx * dx + dy * dy)
    local g = NS.Terrain and NS.Terrain[cont]
    if not g then return len end
    if CrossesWall(cont, x1, y1, x2, y2) then return nil end
    local k = TILE / g.cell
    local n = math.max(1, math.ceil(len / (g.cell / 3)))
    local slack = len > 0 and END_SLACK / len or 1
    local opens = Opens(cont)
    local water, lastRow, lastCol, lastV = 0, nil, nil, nil
    for i = 0, n do
        local t = i / n
        local x, y = x1 + dx * t, y1 + dy * t
        local col = math.floor(((32 - y / TILE) - g.tx0) * k) + 1
        local row = math.floor(((32 - x / TILE) - g.ty0) * k) + 1
        local v
        if row == lastRow and col == lastCol then
            v = lastV
        else
            v = Cell(g, opens, row, col)
            lastRow, lastCol, lastV = row, col, v
        end
        if v == 2 and t > slack and t < 1 - slack then return nil end
        if v == 1 then water = water + 1 end
    end
    return len + len * (water / (n + 1)) * (SWIM - 1)
end

---------------------------------------------------------
--  SECTION: Roads
---------------------------------------------------------
local graphs = {} -- [cont] = { xs, ys, adj = { [i] = { j, len, j, len, ... } } }

local function Graph(cont)
    local g = graphs[cont]
    if g ~= nil then return g or nil end
    local r = NS.Roads and NS.Roads[cont]
    if not r then graphs[cont] = false; return nil end
    local xs, ys, adj = {}, {}, {}
    for i = 1, #r.n - 1, 2 do
        xs[#xs + 1], ys[#ys + 1] = r.n[i], r.n[i + 1]
        adj[#xs] = {}
    end
    local e = r.e
    for i = 1, #e - 2, 3 do
        local a, b, len = e[i], e[i + 1], e[i + 2]
        if adj[a] and adj[b] and a ~= b then
            local la, lb = adj[a], adj[b]
            la[#la + 1], la[#la + 2] = b, len
            lb[#lb + 1], lb[#lb + 2] = a, len
        end
    end
    -- walks that join the network's separate pieces (Nav/Shapes.lua)
    local links = NS.Links and NS.Links[cont] or {}
    for i = 1, #links - 2, 3 do
        local a, b, len = links[i], links[i + 1], links[i + 2]
        if adj[a] and adj[b] and a ~= b then
            local la, lb = adj[a], adj[b]
            la[#la + 1], la[#la + 2] = b, len
            lb[#lb + 1], lb[#lb + 2] = a, len
        end
    end
    g = { xs = xs, ys = ys, adj = adj }
    graphs[cont] = g
    return g
end

-- Junctions you can walk to straight from (x, y): { node, yards }, nearest first. Where the
-- terrain says none can be reached, the nearest few anyway: the road as far as it goes and a
-- guess for the rest beats no way at all.
local function Snap(g, cont, x, y)
    local near, further = {}, {}
    for i = 1, #g.xs do
        local d = math.sqrt((g.xs[i] - x) ^ 2 + (g.ys[i] - y) ^ 2)
        if d <= SNAP_RANGE then
            near[#near + 1] = { i, d }
        elseif d <= LOOSE_RANGE then
            further[#further + 1] = { i, d }
        end
    end
    table.sort(near, function(a, b) return a[2] < b[2] end)
    local out = {}
    for i = 1, math.min(SNAP_TRIES, #near) do
        local node = near[i][1]
        local walk = Nav.Segment(cont, x, y, g.xs[node], g.ys[node])
        if walk then out[#out + 1] = { node, walk } end
    end
    if #out == 0 then
        if #near == 0 then
            near = further
            table.sort(near, function(a, b) return a[2] < b[2] end)
        end
        for i = 1, math.min(LOOSE_TRIES, #near) do
            out[#out + 1] = { near[i][1], near[i][2] * LOOSE }
        end
    end
    return out
end

-- Along the roads from a set of ways onto them ({ node, yards, points }): yards to every
-- junction, for each the junction before it on the way there, and for the first junction of
-- each way the snap that led onto it (Dijkstra; a few hundred to 1,500 junctions).
local function RoadsFrom(g, snaps)
    local dist, prev, onto, done = {}, {}, {}, {}
    local heap = {}
    local function push(node, d)
        heap[#heap + 1] = { node, d }
        local i = #heap
        while i > 1 do
            local p = math.floor(i / 2)
            if heap[p][2] <= heap[i][2] then break end
            heap[p], heap[i] = heap[i], heap[p]
            i = p
        end
    end
    local function pop()
        local top = heap[1]
        local last = table.remove(heap)
        if #heap > 0 then
            heap[1] = last
            local i = 1
            while true do
                local l, r, s = i * 2, i * 2 + 1, i
                if heap[l] and heap[l][2] < heap[s][2] then s = l end
                if heap[r] and heap[r][2] < heap[s][2] then s = r end
                if s == i then break end
                heap[s], heap[i] = heap[i], heap[s]
                i = s
            end
        end
        return top
    end
    for _, s in ipairs(snaps) do
        if not dist[s[1]] or s[2] < dist[s[1]] then
            dist[s[1]], onto[s[1]] = s[2], s
            push(s[1], s[2])
        end
    end
    while #heap > 0 do
        local top = pop()
        local node, d = top[1], top[2]
        if not done[node] then
            done[node] = true
            local a = g.adj[node]
            for i = 1, #a - 1, 2 do
                local nb, nd = a[i], d + a[i + 1]
                if not dist[nb] or nd < dist[nb] then
                    dist[nb], prev[nb], onto[nb] = nd, node, nil
                    push(nb, nd)
                end
            end
        end
    end
    return dist, prev, onto
end

-- The ways onto the roads from an explore pin, worked out ahead from the terrain
-- (Nav/Shapes.lua): { { junction, yards, points }, ... }, or nil where there are none.
function Nav.Approach(cont, overlay)
    local a = overlay and NS.Approach and NS.Approach[overlay]
    if not a or a[1] ~= cont or not a[2] then return nil end
    local out = { pin = overlay }   -- which pin these are for: two pins may have a walk of their own (Hop)
    for i = 2, #a do out[#out + 1] = a[i] end
    return out
end

-- The same for a flight master (FarstriderLib's node ID).
function Nav.TaxiApproach(cont, node)
    local a = node and NS.Taxi and NS.Taxi[node]
    if not a or a[1] ~= cont or not a[2] then return nil end
    local out = {}
    for i = 2, #a do out[#out + 1] = a[i] end
    return out
end

-- The walk worked out ahead between two pins near each other, where the straight line is
-- blocked and the roads make much more of it: yards, and the points on the way from `from`.
local function Hop(from, to)
    local h = NS.Hops and NS.Hops[math.min(from, to) * 65536 + math.max(from, to)]
    if not h then return nil end
    local points = {}
    if from < to then
        for i = 2, #h do points[#points + 1] = h[i] end
    else
        for i = #h - 1, 2, -2 do
            points[#points + 1], points[#points + 2] = h[i], h[i + 1]
        end
    end
    return h[1], points
end

---------------------------------------------------------
--  SECTION: Onto the roads over the ground
---------------------------------------------------------
-- For a start no straight line gets to a junction from (the player in a canyon): spread out
-- from it over open ground, cell by cell, until junctions turn up. Slow next to the rest
-- (thousands of cells), so it's capped, and `pause` (a coroutine's yield) is called as it goes.
local REACH_YARDS, REACH_CELLS, REACH_WANT, PAUSE_EVERY = 2500, 40000, 2, 500

local junctionAt = {}   -- [cont] = { [row * 65536 + col] = node }
local wallBuckets = {}  -- [cont] = { [bx * 4096 + by] = { ax, ay, bx, by, ... } } on a 60-yard grid
local BUCKET = 60

local function CellOf(g, x, y)
    local k = TILE / g.cell
    return math.floor(((32 - x / TILE) - g.ty0) * k) + 1, math.floor(((32 - y / TILE) - g.tx0) * k) + 1
end

local function CentreOf(g, row, col)
    local k = TILE / g.cell
    return (32 - g.ty0 - (row - 0.5) / k) * TILE, (32 - g.tx0 - (col - 0.5) / k) * TILE
end

local function JunctionCells(cont, g, graph)
    local at = junctionAt[cont]
    if not at then
        at = {}
        for i = 1, #graph.xs do
            local row, col = CellOf(g, graph.xs[i], graph.ys[i])
            local key = row * 65536 + col
            if not at[key] then at[key] = i end
        end
        junctionAt[cont] = at
    end
    return at
end

local function WallBuckets(cont)
    local b = wallBuckets[cont]
    if not b then
        b = {}
        for _, w in ipairs(Walls(cont)) do
            local pts = w[1]
            for i = 1, #pts - 3, 2 do
                local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
                for u = math.floor(math.min(ax, bx) / BUCKET) - 1, math.floor(math.max(ax, bx) / BUCKET) + 1 do
                    for v = math.floor(math.min(ay, by) / BUCKET) - 1, math.floor(math.max(ay, by) / BUCKET) + 1 do
                        local key = u * 4096 + v
                        local list = b[key]
                        if not list then list = {}; b[key] = list end
                        list[#list + 1], list[#list + 2], list[#list + 3], list[#list + 4] = ax, ay, bx, by
                    end
                end
            end
        end
        wallBuckets[cont] = b
    end
    return b
end

-- { { junction, yards, points on the way from (x, y) }, ... }: the nearest junctions over
-- open ground. Empty when none turn up within the caps.
function Nav.Reach(cont, x, y, pause)
    local g, graph = NS.Terrain and NS.Terrain[cont], Graph(cont)
    if not (g and graph) then return {} end
    local opens, at, buckets = Opens(cont), JunctionCells(cont, g, graph), WallBuckets(cont)
    local walled = next(buckets) ~= nil
    local sr, sc = CellOf(g, x, y)
    local start = sr * 65536 + sc
    local best, came = { [start] = 0 }, {}
    local heap, size = { { start, 0 } }, 1
    local found, opened, limit = {}, 0, REACH_YARDS / g.cell
    while size > 0 and #found < REACH_WANT do
        -- pop
        local top = heap[1]
        local last = heap[size]
        heap[size] = nil
        size = size - 1
        if size > 0 then
            heap[1] = last
            local i = 1
            while true do
                local l, r, s = i * 2, i * 2 + 1, i
                if l <= size and heap[l][2] < heap[s][2] then s = l end
                if r <= size and heap[r][2] < heap[s][2] then s = r end
                if s == i then break end
                heap[s], heap[i] = heap[i], heap[s]
                i = s
            end
        end
        local key, d = top[1], top[2]
        if d <= best[key] then
            if at[key] then found[#found + 1] = { at[key], d, key } end
            opened = opened + 1
            if opened > REACH_CELLS or d > limit then break end
            if pause and opened % PAUSE_EVERY == 0 then pause() end
            local row, col = math.floor(key / 65536), key % 65536
            local cx, cy
            if walled then cx, cy = CentreOf(g, row, col) end
            for dr = -1, 1 do
                for dc = -1, 1 do
                    if dr ~= 0 or dc ~= 0 then
                        local nr, nc = row + dr, col + dc
                        local v = Cell(g, opens, nr, nc)
                        -- no cutting a blocked corner
                        if v ~= 2 and (dr == 0 or dc == 0 or (Cell(g, opens, row, nc) ~= 2 and Cell(g, opens, nr, col) ~= 2)) then
                            local ok = true
                            if walled then
                                local nx, ny = CentreOf(g, nr, nc)
                                local list = buckets[math.floor((cx + nx) / 2 / BUCKET) * 4096 + math.floor((cy + ny) / 2 / BUCKET)]
                                if list then
                                    for i = 1, #list - 3, 4 do
                                        local ax, ay, bx, by = list[i], list[i + 1], list[i + 2], list[i + 3]
                                        local d1, d2 = Orient(cx, cy, nx, ny, ax, ay), Orient(cx, cy, nx, ny, bx, by)
                                        local d3, d4 = Orient(ax, ay, bx, by, cx, cy), Orient(ax, ay, bx, by, nx, ny)
                                        if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then ok = false break end
                                    end
                                end
                            end
                            if ok then
                                local step = (dr ~= 0 and dc ~= 0) and 1.41421356 or 1
                                if v == 1 then step = step * SWIM end
                                local nd, nkey = d + step, nr * 65536 + nc
                                if not best[nkey] or nd < best[nkey] then
                                    best[nkey], came[nkey] = nd, key
                                    -- push
                                    size = size + 1
                                    heap[size] = { nkey, nd }
                                    local i = size
                                    while i > 1 do
                                        local p = math.floor(i / 2)
                                        if heap[p][2] <= heap[i][2] then break end
                                        heap[p], heap[i] = heap[i], heap[p]
                                        i = p
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- each way as its corners: the cells where the walk turns
    local out = {}
    for _, f in ipairs(found) do
        local cells, key = {}, f[3]
        while key do
            cells[#cells + 1] = key
            key = came[key]
        end
        local points = {}
        for i = #cells - 1, 2, -1 do   -- from the start's side; the two ends aren't corners
            local a, b, c = cells[i + 1], cells[i], cells[i - 1]
            if b - a ~= c - b then
                local px, py = CentreOf(g, math.floor(b / 65536), b % 65536)
                points[#points + 1], points[#points + 2] = px, py
            end
        end
        out[#out + 1] = { f[1], f[2] * g.cell, points }
    end
    return out
end

---------------------------------------------------------
--  SECTION: From one place to many
---------------------------------------------------------
-- A context for walks from one start. `onto` is the ways onto the roads from the start when
-- they're known already (Nav.Approach for a pin, Nav.Reach for the player); without it they
-- are the junctions a straight line reaches.
--   ctx.Walk(x, y, onto)  yards and "direct", "road" or "hop" (a walk worked out ahead between
--                         two pins); nil when nothing reaches it. `onto` here is the end's ways
--                         onto the roads.
--   ctx.Path(x, y, onto)  the same, plus the points to pass on the way as { x1, y1, ... }
--                         (empty for a direct walk): the way onto the road, the junctions and
--                         the bends of the roads between them, and the way off
function Nav.From(cont, sx, sy, onto)
    local g = Graph(cont)
    -- the points along a road (AzerothGPS's own, NS.Bends) or along a walk added between roads (NS.Shapes)
    local bendsOf, shapes = NS.Bends and NS.Bends[cont] or {}, NS.Shapes and NS.Shapes[cont] or {}
    local roadDist, roadPrev, roadOnto   -- found the first time a direct walk fails or a road might be shorter
    local ctx = {}

    local function Best(x, y, off)
        local direct = Nav.Segment(cont, sx, sy, x, y)
        if not g then return direct, direct and "direct" or nil end
        local bird = math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2)
        if direct and direct <= bird * CLEAR then return direct, "direct" end
        if not roadDist then roadDist, roadPrev, roadOnto = RoadsFrom(g, onto or Snap(g, cont, sx, sy)) end
        local best, how, last = direct, direct and "direct" or nil, nil
        for _, s in ipairs(off or Snap(g, cont, x, y)) do
            local d = roadDist[s[1]]
            if d and (not best or d + s[2] < best) then best, how, last = d + s[2], "road", s end
        end
        if onto and off and onto.pin and off.pin then
            local yards, points = Hop(onto.pin, off.pin)
            if yards and (not best or yards < best) then best, how, last = yards, "hop", points end
        end
        return best, how, last
    end

    function ctx.Walk(x, y, off)
        local yards, how = Best(x, y, off)
        return yards, how
    end

    function ctx.Path(x, y, off)
        local yards, how, last = Best(x, y, off)
        if not yards then return nil end
        local roadFrom, roadTo
        local points = {}
        if how == "hop" then
            points = last
        elseif how == "road" then
            local chain, node, guard = {}, last[1], 0
            while node and guard < 5000 do
                chain[#chain + 1] = node
                node, guard = roadPrev[node], guard + 1
            end
            -- onto the road
            local first = roadOnto[chain[#chain]]
            for _, v in ipairs(first and first[3] or {}) do points[#points + 1] = v end
            roadFrom = #points + 1
            -- along it: each junction, and the bends of the road to the next
            for i = #chain, 1, -1 do
                local a = chain[i]
                points[#points + 1], points[#points + 2] = g.xs[a], g.ys[a]
                local b = chain[i - 1]
                if b then
                    local key = math.min(a, b) * 65536 + math.max(a, b)
                    local bends = bendsOf[key] or shapes[key]
                    if bends then
                        if a < b then
                            for _, v in ipairs(bends) do points[#points + 1] = v end
                        else
                            for k = #bends - 1, 1, -2 do
                                points[#points + 1], points[#points + 2] = bends[k], bends[k + 1]
                            end
                        end
                    end
                end
            end
            roadTo = #points - 1
            -- and off it: the end's way onto the road, backwards
            local way = last[3]
            if way then
                for k = #way - 1, 1, -2 do
                    points[#points + 1], points[#points + 2] = way[k], way[k + 1]
                end
            end
        end
        -- roadFrom, roadTo: where in the points the first and last junction sit (the stretch on the roads)
        return yards, how, points, roadFrom, roadTo
    end

    return ctx
end

-- Whether a straight line from (x, y) gets onto the roads (else Nav.Reach is worth its time).
function Nav.OnRoads(cont, x, y)
    local g = Graph(cont)
    if not g then return true end
    for i = 1, #g.xs do
        local d = (g.xs[i] - x) ^ 2 + (g.ys[i] - y) ^ 2
        if d <= SNAP_RANGE ^ 2 and Nav.Segment(cont, x, y, g.xs[i], g.ys[i]) then return true end
    end
    return false
end

-- Where to head now on a way (its points, then the end) from (px, py): the furthest point in
-- a row that a clear straight walk reaches, which cuts the corners the way doesn't need.
-- Points you're already standing at don't count. Past the last point it's the end itself,
-- clear or not (the end may be a pin the terrain says can't be reached).
function Nav.Ahead(cont, px, py, points, tx, ty)
    local function Clear(x, y)
        local walk = Nav.Segment(cont, px, py, x, y)
        return walk and walk <= math.sqrt((x - px) ^ 2 + (y - py) ^ 2) * CLEAR
    end
    if (tx - px) ^ 2 + (ty - py) ^ 2 < NEAR_END ^ 2 and Clear(tx, ty) then return tx, ty end
    local hx, hy
    for i = 1, #points - 1, 2 do
        local x, y = points[i], points[i + 1]
        if hx or (x - px) ^ 2 + (y - py) ^ 2 > AT_JUNCTION ^ 2 then
            if Clear(x, y) then
                hx, hy = x, y
            elseif hx then
                return hx, hy
            else
                return x, y   -- the next point isn't in clear sight (a bridge, a ramp): head for it anyway
            end
        end
    end
    if hx and not Clear(tx, ty) then return hx, hy end
    return tx, ty
end

-- Has terrain data for this continent (else every walk is the bird's distance).
function Nav.Knows(cont)
    return NS.Terrain ~= nil and NS.Terrain[cont] ~= nil
end
