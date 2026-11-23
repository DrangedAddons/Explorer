---------------------------------------------------------
--  Explorer - Walking
--  Author: Dranged
---------------------------------------------------------
-- Getting somewhere on foot on a continent: the terrain grid (open, water, too steep), drawn
-- walls and the road network, from AzerothGPS's data (Nav/*.lua, built by
-- tools/build_nav_data.py with its author's permission). Ported from VendorPoint's Nav.lua,
-- which only measures a walk; this one also gives the way: the road junctions to pass.
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

-- Along the roads from (x, y): yards to every junction, and for each the junction before it
-- on the way there (Dijkstra; a few hundred to 1,500 junctions).
local function RoadsFrom(g, cont, x, y)
    local dist, prev, done = {}, {}, {}
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
    for _, s in ipairs(Snap(g, cont, x, y)) do
        if not dist[s[1]] or s[2] < dist[s[1]] then
            dist[s[1]] = s[2]
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
                    dist[nb], prev[nb] = nd, node
                    push(nb, nd)
                end
            end
        end
    end
    return dist, prev
end

---------------------------------------------------------
--  SECTION: From one place to many
---------------------------------------------------------
-- A context for walks from one start.
--   ctx.Walk(x, y)  yards and "direct" or "road"; nil when neither a straight walk nor the
--                   roads reach it
--   ctx.Path(x, y)  the same, plus the junctions to pass on the way as { x1, y1, x2, y2, ... }
--                   (empty for a direct walk)
function Nav.From(cont, sx, sy)
    local g = Graph(cont)
    local roadDist, roadPrev   -- found the first time a direct walk fails or a road might be shorter
    local ctx = {}

    local function Best(x, y)
        local direct = Nav.Segment(cont, sx, sy, x, y)
        if not g then return direct, direct and "direct" or nil end
        local bird = math.sqrt((x - sx) ^ 2 + (y - sy) ^ 2)
        if direct and direct <= bird * CLEAR then return direct, "direct" end
        if not roadDist then roadDist, roadPrev = RoadsFrom(g, cont, sx, sy) end
        local best, how, last = direct, direct and "direct" or nil, nil
        for _, s in ipairs(Snap(g, cont, x, y)) do
            local d = roadDist[s[1]]
            if d and (not best or d + s[2] < best) then best, how, last = d + s[2], "road", s[1] end
        end
        return best, how, last
    end

    function ctx.Walk(x, y)
        local yards, how = Best(x, y)
        return yards, how
    end

    function ctx.Path(x, y)
        local yards, how, last = Best(x, y)
        if not yards then return nil end
        local points = {}
        if how == "road" then
            local chain, node, guard = {}, last, 0
            while node and guard < 5000 do
                chain[#chain + 1] = node
                node, guard = roadPrev[node], guard + 1
            end
            for i = #chain, 1, -1 do
                points[#points + 1] = g.xs[chain[i]]
                points[#points + 1] = g.ys[chain[i]]
            end
        end
        return yards, how, points
    end

    return ctx
end

-- Where to head now on a way (its junctions, then the end) from (px, py): the furthest
-- point a clear straight walk reaches, which cuts the corners the roads don't need. Junctions
-- you're already standing at don't count; past the last of them it's the end itself, clear
-- or not (the end may be a pin the terrain says can't be reached).
function Nav.Ahead(cont, px, py, points, tx, ty)
    local function Clear(x, y)
        local walk = Nav.Segment(cont, px, py, x, y)
        return walk and walk <= math.sqrt((x - px) ^ 2 + (y - py) ^ 2) * CLEAR
    end
    local function Far(i) return (points[i] - px) ^ 2 + (points[i + 1] - py) ^ 2 > AT_JUNCTION ^ 2 end
    if Clear(tx, ty) then return tx, ty end
    for i = #points - 1, 1, -2 do
        if Far(i) and Clear(points[i], points[i + 1]) then return points[i], points[i + 1] end
    end
    for i = 1, #points - 1, 2 do
        if Far(i) then return points[i], points[i + 1] end
    end
    return tx, ty
end

-- Has terrain data for this continent (else every walk is the bird's distance).
function Nav.Knows(cont)
    return NS.Terrain ~= nil and NS.Terrain[cont] ~= nil
end
