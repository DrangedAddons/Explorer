"""Builds Nav/Shapes.lua from Nav/Terrain.lua and Nav/Roads.lua: what joins the roads up.

Usage: python -I tools/shape_nav.py        (tools/build_nav_data.py runs it after a rebuild)
       python -I tools/shape_nav.py --taxi   only the flight masters, into the Shapes.lua that's there

AzerothGPS's road network comes in dozens of unconnected pieces, and its roads only meet at
junctions; it has an off-road router of its own for the rest. This does that part ahead of time,
over the ground in Nav/Terrain.lua (AzerothGPS's grid with its bridges and tunnels laid in), and
does the same for every explore pin and flight master: the walk from it to the junctions nearest.

Every search here is over open ground. The one exception is a pin (or flight master) that itself
stands on ground the grid has blocked, or in a pocket the grid closes off: it has to get out
somehow, so it crosses as little blocked ground as will do. Roads are never joined that way: a
join across blocked ground was tried, and put a road over the wall of Un'Goro Crater.

Output (world yards, x north, y west):
  VP.Links[cont] = { a, b, yards, ... }                extra roads between junctions: a walk over open
                                                       ground between two that are near each other but far
                                                       apart by road, and for each piece of the network a
                                                       walk to the nearest junction of the rest
  VP.Shapes[cont][a * 65536 + b] = { x1, y1, ... }     the points along such a walk between a < b, from a
  VP.Approach[overlayID] = { cont, { junction, yards, { x1, y1, ... } }, ... }
                                                       from an explore pin (Data.lua) to up to
                                                       two junctions: the walk, and the points
                                                       on the way from the pin
  VP.Taxi[nodeID] = { cont, { junction, yards, { x1, y1, ... } }, ... }
                                                       the same for every flight master (FarstriderLib's
                                                       TaxiNodes): a flight is only worth taking for the
                                                       walk from where it lands
  VP.Hops[a * 65536 + b] = { yards, x1, y1, ... }      between two pins near each other (overlay IDs
                                                       a < b, points from a) whose straight line is
                                                       blocked: a walk round over the ground, where
                                                       that is much shorter than the way by road
"""
import csv
import heapq
import math
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_nav_data as B  # noqa: E402  (its Lua-table readers and the terrain grid)

ROOT = B.ROOT
NAV = os.path.join(ROOT, "Nav")
CACHE = os.path.join(ROOT, "tools", ".cache")
SQRT2 = math.sqrt(2)
ROOM = 2.5             # yards of room a way's straight stretches keep from blocked ground
BUCKET = 60            # yards: wall stretches are looked up by this grid
EDGE_CAP = 400000      # cells an edge's search may open
REACH_CAP = 1500000    # cells a pin's search may open
REACH_YARDS = 6000     # how far a pin looks for junctions, walking
REACH_THROUGH = 400    # ... and how many yards of blocked ground it may cross when it has to
HOP_YARDS = 700        # pins this close as the bird flies get a walk of their own worked out ...
HOP_CAP = 80000        # ... (cells that search may open)
HOP_BEATS = 0.7        # ... kept when it's under this much of the way by road
HOP_DETOUR = 3         # ... and it may cross blocked ground when the roads take this many times the bird's distance
LOCAL_YARDS = 450      # junctions this close over open ground get a walk between them ...
LOCAL_RATIO = 2.5      # ... when the roads take this many times longer to get there
LOCAL_WANT = 10        # ... looking at the nearest this many
LOCAL_CAP = 15000      # cells that search may open
CARRY_YARDS = 300      # two dead ends this close, in different pieces, are one road that carries on when ...
CARRY_AIM = 50         # ... each road points at the other end to within this many degrees
CARRY_BLOCKED = 0.3    # ... and no more than this much of the line between them is blocked ground
LINK_CAP = 150000      # cells the search that joins a piece of the road network may open
LINK_CAP_EACH = 1200   # ... plus this many for each of the piece's junctions (it spreads out from all of them)
LINK_YARDS = 4000      # ... and how far it looks
LINK_THROUGH = 0       # (blocked ground it may cross: none, see where the pieces are joined)
STEEP = 15             # a step onto blocked ground costs this many, when a search may cross it at all
REACH_WANT = 2
NUDGE = 20             # cells a point on blocked ground may move to reach open ground


class Ground:
    """The terrain grid as rows of bytes (0 open, 1 water, 2 blocked), plus walls a step can't cross."""

    def __init__(self, grid, walls):
        self.g = grid
        self.w, self.h = grid.w, grid.h
        self.rows = {}
        self.buckets = {}
        for pts in walls:
            for i in range(0, len(pts) - 3, 2):
                seg = (pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
                x1, x2 = sorted((seg[0], seg[2]))
                y1, y2 = sorted((seg[1], seg[3]))
                for bx in range(int(x1 // BUCKET) - 1, int(x2 // BUCKET) + 2):
                    for by in range(int(y1 // BUCKET) - 1, int(y2 // BUCKET) + 2):
                        self.buckets.setdefault((bx, by), []).append(seg)

    def row(self, r):
        row = self.rows.get(r)
        if row is None:
            row = bytearray(self.w + 2)
            pos = 0
            for end, v in B.decode_row(self.g.rows[r - 1]):
                if v:
                    row[pos + 1:end + 1] = bytes([v]) * (end - pos)
                pos = end
            base = r * 65536
            for c in range(1, self.w + 1):
                if row[c] and base + c in self.g.opens:
                    row[c] = 0
            row[0] = row[self.w + 1] = 2
            self.rows[r] = row
        return row

    def at(self, r, c):
        if r < 1 or r > self.h or c < 1 or c > self.w:
            return 2
        return self.row(r)[c]

    def walled(self, x1, y1, x2, y2):
        if not self.buckets:
            return False
        for seg in self.buckets.get((int(((x1 + x2) / 2) // BUCKET), int(((y1 + y2) / 2) // BUCKET)), ()):
            ax, ay, bx, by = seg
            d1 = (x2 - x1) * (ay - y1) - (y2 - y1) * (ax - x1)
            d2 = (x2 - x1) * (by - y1) - (y2 - y1) * (bx - x1)
            d3 = (bx - ax) * (y1 - ay) - (by - ay) * (x1 - ax)
            d4 = (bx - ax) * (y2 - ay) - (by - ay) * (x2 - ax)
            if (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0):
                return True
        return False

    def clear(self, x1, y1, x2, y2):
        """A straight walk with no blocked cell under it and no wall across it. No slack at the ends."""
        if self.g.crosses_wall(x1, y1, x2, y2):
            return False
        dx, dy = x2 - x1, y2 - y1
        n = max(1, math.ceil(math.hypot(dx, dy) / (self.g.cell / 3)))
        last = None
        for i in range(n + 1):
            t = i / n
            rc = self.g.to_cell(x1 + dx * t, y1 + dy * t)
            if rc != last:
                if self.at(*rc) == 2:
                    return False
                last = rc
        return True

    def roomy(self, x1, y1, x2, y2):
        """clear(), with room to spare: the same line a little to either side is clear too. A way's
        corners are cut with this, so a line never grazes a blocked cell's corner (written out to a
        tenth of a yard and sampled again in game, a grazing line comes out blocked half the time)."""
        if not self.clear(x1, y1, x2, y2):
            return False
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        if length < 1:
            return True
        ox, oy = -dy / length * ROOM, dx / length * ROOM
        return (self.clear(x1 + ox, y1 + oy, x2 + ox, y2 + oy) and
                self.clear(x1 - ox, y1 - oy, x2 - ox, y2 - oy))

    def open_near(self, r, c):
        """The cell itself when it's open ground, else the nearest one that is, within NUDGE cells."""
        if self.at(r, c) != 2:
            return r, c
        for ring in range(1, NUDGE + 1):
            best = None
            for dr in range(-ring, ring + 1):
                for dc in range(-ring, ring + 1):
                    if max(abs(dr), abs(dc)) == ring and self.at(r + dr, c + dc) != 2:
                        d = dr * dr + dc * dc
                        if best is None or d < best[0]:
                            best = (d, r + dr, c + dc)
            if best:
                return best[1], best[2]
        return None

    def steps(self, r, c, through=False):
        """Cells one step away, with the step's cost in cells. No cutting a blocked corner, no crossing a wall.
        `through` lets a step onto blocked ground at STEEP times the cost: for the places the grid
        closes off but a ramp, a bridge or a tunnel gets you through. The cheapest way then crosses
        where the blocked ground is thinnest, which is where those are."""
        cx, cy = self.g.centre(r, c)
        up, mid, down = self.row(r - 1) if r > 1 else None, self.row(r), self.row(r + 1) if r < self.h else None
        for dr, line in ((-1, up), (0, mid), (1, down)):
            if line is None:
                continue
            for dc in (-1, 0, 1):
                if (dr or dc) and (through or line[c + dc] != 2):
                    if c + dc < 1 or c + dc > self.w:
                        continue
                    if not through and dr and dc and (mid[c + dc] == 2 or line[c] == 2):
                        continue
                    if self.buckets:
                        nx, ny = self.g.centre(r + dr, c + dc)
                        if self.walled(cx, cy, nx, ny):
                            continue
                    cost = SQRT2 if dr and dc else 1.0
                    v = line[c + dc]
                    yield r + dr, c + dc, cost * (B.SWIM if v == 1 else STEEP if v == 2 else 1.0)

    def path(self, start, goal, margin, cap, through=False):
        """Cells from start to goal over open ground (A*), kept inside the two cells' box plus a margin."""
        (r1, c1), (r2, c2) = start, goal
        rlo, rhi = min(r1, r2) - margin, max(r1, r2) + margin
        clo, chi = min(c1, c2) - margin, max(c1, c2) + margin
        best = {start: 0.0}
        came = {}
        heap = [(math.hypot(r1 - r2, c1 - c2), 0.0, start)]
        opened = 0
        while heap:
            _, g, cur = heapq.heappop(heap)
            if cur == goal:
                out = [cur]
                while cur in came:
                    cur = came[cur]
                    out.append(cur)
                return out[::-1]
            if g > best.get(cur, 1e18):
                continue
            opened += 1
            if opened > cap:
                return None
            for nr, nc, cost in self.steps(cur[0], cur[1], through):
                if nr < rlo or nr > rhi or nc < clo or nc > chi:
                    continue
                ng = g + cost
                if ng < best.get((nr, nc), 1e18):
                    best[(nr, nc)] = ng
                    came[(nr, nc)] = cur
                    heapq.heappush(heap, (ng + math.hypot(nr - r2, nc - c2), ng, (nr, nc)))
        return None

    def reach(self, start, targets, want, cap, max_cells, through=False):
        """From start (a cell, or a list of cells) outward (Dijkstra) to the first `want` cells of
        `targets` that turn up: [(target cell, cells walked, the cells on the way)]."""
        starts = start if isinstance(start, list) else [start]
        best = {c: 0.0 for c in starts}
        came = {}
        heap = [(0.0, c) for c in starts]
        found, opened = [], 0
        while heap and len(found) < want:
            g, cur = heapq.heappop(heap)
            if g > best.get(cur, 1e18):
                continue
            if cur in targets:
                out, walk = [cur], cur
                while walk in came:
                    walk = came[walk]
                    out.append(walk)
                found.append((cur, g, out[::-1]))
            opened += 1
            if opened > cap or g > max_cells:
                break
            for nr, nc, cost in self.steps(cur[0], cur[1], through):
                ng = g + cost
                if ng < best.get((nr, nc), 1e18):
                    best[(nr, nc)] = ng
                    came[(nr, nc)] = cur
                    heapq.heappush(heap, (ng, (nr, nc)))
        return found

    def pull(self, first, cells, last):
        """The corners of a way: from `first` through the cells' middles to `last`, keeping only
        the points a straight clear walk can't skip. Returns the points between the two ends."""
        pts = [first] + [self.g.centre(r, c) for r, c in cells] + [last]
        out, i = [], 0
        while i < len(pts) - 1:
            j = i + 1
            while j + 1 < len(pts) and self.roomy(pts[i][0], pts[i][1], pts[j + 1][0], pts[j + 1][1]):
                j += 1
            if j < len(pts) - 1:
                out.append(pts[j])
            i = j
        return out


def read_nav():
    roads_text = open(os.path.join(NAV, "Roads.lua"), encoding="utf-8").read()
    terrain_text = open(os.path.join(NAV, "Terrain.lua"), encoding="utf-8").read()
    stamp = roads_text.split("\n", 1)[0]
    walls = {}
    for cont, body in B.top_entries(B.table_after(roads_text, "VP.Walls = ")):
        walls[cont] = [B.numbers(m.group(1)) for m in re.finditer(r"\{([^{}]*)\}", body[1:-1])]
    opens = {}
    for cont, body in B.top_entries(B.table_after(roads_text, "VP.Opens = ")):
        opens[cont] = {int(v) for v in B.numbers(body)}
    grounds = {}
    for cont, body in B.top_entries(B.table_after(terrain_text, "VP.Terrain = ")):
        grounds[cont] = Ground(B.Grid(body, opens.get(cont, set()), walls.get(cont, [])), walls.get(cont, []))
    roads = {}
    for cont, body in B.top_entries(B.table_after(roads_text, "VP.Roads = ")):
        nodes = B.numbers(B.block(body, body.index("n = {") + 4))
        e = B.numbers(B.block(body, body.index("e = {") + 4))
        roads[cont] = (nodes[0::2], nodes[1::2], [(int(e[i]), int(e[i + 1]), e[i + 2]) for i in range(0, len(e) - 2, 3)])
    return stamp, grounds, roads


def read_bends():
    """{ cont: { a * 65536 + b: [x1, y1, ...] } }: the points along each road, from Nav/Roads.lua."""
    text = open(os.path.join(NAV, "Roads.lua"), encoding="utf-8").read()
    out = {}
    if "VP.Bends = " in text:
        for cont, body in B.top_entries(B.table_after(text, "VP.Bends = ")):
            out[cont] = {int(m.group(1)): B.numbers(m.group(2)) for m in re.finditer(r"\[(\d+)\]=\{([^{}]*)\}", body)}
    return out


def pins():
    """Every explore pin in the world: overlay -> (continent, x, y), from Data.lua and the maps' bounds."""
    bounds = {}
    with open(os.path.join(CACHE, "UiMapAssignment.csv"), encoding="utf-8-sig", newline="") as f:
        for r in sorted(csv.DictReader(f), key=lambda r: int(r["OrderIndex"])):
            if (r["UiMin_0"], r["UiMin_1"], r["UiMax_0"], r["UiMax_1"]) == ("0", "0", "1", "1"):
                bounds.setdefault(int(r["UiMapID"]), (int(r["MapID"]), float(r["Region_4"]), float(r["Region_1"]),
                                                      float(r["Region_3"]), float(r["Region_0"])))
    out = {}
    data = open(os.path.join(ROOT, "Data.lua"), encoding="utf-8").read()
    for m in re.finditer(r"^\s*\[(\d+)\] = \{(\d+), ([\d.]+), ([\d.]+), \"", data, re.M):
        b = bounds.get(int(m.group(2)))
        if b:
            cont, left, right, top, bottom = b
            x, y = float(m.group(3)) / 100, float(m.group(4)) / 100
            out[int(m.group(1))] = (cont, top + y * (bottom - top), left + x * (right - left))
    return out


def fmt_points(points):
    return ",".join(B.fmt(v) for p in points for v in p)


def taxi_nodes():
    """FarstriderLib's flight masters: nodeID -> (continent, x, y)."""
    path = os.path.join(ROOT, "Libs", "FarstriderLibData", "Taxi", "Camelot", "FarstriderLibData_Taxi.lua")
    text = open(path, encoding="utf-8").read()
    text = text[text.index("TaxiNodes"):]
    text = text[:text.index("\n}")]
    out = {}
    for m in re.finditer(r"\[(\d+)\] = \{ (\d+), (-?[\d.]+), (-?[\d.]+),", text):
        out[int(m.group(1))] = (int(m.group(2)), float(m.group(3)), float(m.group(4)))
    return out


def ways_onto_roads(gr, xs, ys, at, true_at, x, y):
    """From a point to the junctions nearest it over the ground: ([(junction, yards, points)], crossed blocked ground)."""
    cell = gr.g.to_cell(x, y)
    found, through = [], False
    if gr.at(*cell) != 2:
        found = gr.reach(cell, at, REACH_WANT, REACH_CAP, REACH_YARDS / gr.g.cell)
    if not found:
        through = True
        found = gr.reach(cell, true_at, REACH_WANT, REACH_CAP, (REACH_YARDS + STEEP * REACH_THROUGH) / gr.g.cell, through=True)
    ways = []
    for c, _, way in found:
        j = (true_at if through else at)[c]
        points = gr.pull((x, y), way, (xs[j - 1], ys[j - 1]))
        line = [(x, y)] + points + [(xs[j - 1], ys[j - 1])]
        ways.append((j, sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:])), points))
    return ways, through


def taxi_block(grounds, roads, junction_cells, true_cells):
    out = ["\n-- [nodeID] = { cont, { junction, yards, { the points on the way from the flight master } }, ... }\n",
           "VP.Taxi = {\n"]
    started, done, none, crossed = time.time(), 0, 0, 0
    for node, (cont, x, y) in sorted(taxi_nodes().items()):
        gr, at = grounds.get(cont), junction_cells.get(cont)
        if not gr or not at:
            continue
        xs, ys, _ = roads[cont]
        ways, through = ways_onto_roads(gr, xs, ys, at, true_cells[cont], x, y)
        if not ways:
            none += 1
            continue
        crossed += 1 if through else 0
        out.append("  [%d]={%d,%s},\n" % (node, cont, ",".join(
            "{%d,%s,{%s}}" % (j, B.fmt(yards), fmt_points(points)) for j, yards, points in ways)))
        done += 1
    out.append("}\n")
    print("flight masters: %d joined to the roads (%d of them across ground the grid has blocked), %d with no junction in reach (%.0fs)" % (
        done, crossed, none, time.time() - started), flush=True)
    return out


def taxi_only():
    """Rewrites just VP.Taxi in an existing Nav/Shapes.lua (the rest takes ten minutes)."""
    stamp, grounds, roads = read_nav()
    junction_cells, true_cells = {}, {}
    for cont, (xs, ys, edges) in roads.items():
        gr = grounds.get(cont)
        if not gr:
            continue
        at, true_at = {}, {}
        for i in range(len(xs)):
            rc = gr.open_near(*gr.g.to_cell(xs[i], ys[i]))
            if rc:
                at.setdefault(rc, i + 1)
            true_at.setdefault(gr.g.to_cell(xs[i], ys[i]), i + 1)
        junction_cells[cont], true_cells[cont] = at, true_at
    path = os.path.join(NAV, "Shapes.lua")
    text = open(path, encoding="utf-8").read()
    marker = "\n-- [nodeID] = { cont,"
    if marker in text:
        text = text[:text.index(marker)]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text + "".join(taxi_block(grounds, roads, junction_cells, true_cells)))
    print("wrote Nav/Shapes.lua, %d KB" % (os.path.getsize(path) // 1024))


def main():
    stamp, grounds, roads = read_nav()
    out = [stamp + "\n",
           "-- AzerothGPS data (c) 2026 AzerothGPS, all rights reserved. Do not edit by hand.\n",
           "-- What joins AzerothGPS's roads up and how the explore pins and flight masters join them, worked out\n",
           "-- over the ground (Nav/Terrain.lua) by tools/shape_nav.py.\n",
           "local _, VP = ...\n\n",
           "-- [cont][a * 65536 + b] = the points along a walk in VP.Links between junctions a < b, from a.\n",
           "VP.Shapes = {\n"]
    junction_cells, true_cells, graphs, links = {}, {}, {}, {}
    courses = read_bends()
    for cont, (xs, ys, edges) in sorted(roads.items()):
        gr = grounds.get(cont)
        if not gr:
            continue
        started = time.time()
        bends_of = courses.get(cont, {})
        cells, at = [], {}
        for i in range(len(xs)):
            rc = gr.open_near(*gr.g.to_cell(xs[i], ys[i]))
            cells.append(rc)
            if rc:
                at.setdefault(rc, i + 1)
        junction_cells[cont] = at
        shaped = []   # the points along each walk added below (the roads' own are in Roads.lua)
        # Roads that pass close by each other without a junction between them: a walk over open
        # ground from one junction to another nearby, where the roads only get there the long way.
        adj = {}
        for a, b, length in edges:
            adj.setdefault(a, []).append((b, length))
            adj.setdefault(b, []).append((a, length))

        def road_yards(src, limit):
            dist, heap = {src: 0.0}, [(0.0, src)]
            while heap:
                d, u = heapq.heappop(heap)
                if d > dist.get(u, 1e18) or d > limit:
                    continue
                for v, length in adj.get(u, ()):
                    if d + length < dist.get(v, 1e18):
                        dist[v] = d + length
                        heapq.heappush(heap, (d + length, v))
            return dist

        joins = []
        for a in range(1, len(xs) + 1):
            if not cells[a - 1]:
                continue
            near = gr.reach(cells[a - 1], at, LOCAL_WANT, LOCAL_CAP, LOCAL_YARDS / gr.g.cell)
            by_road = None
            for cell, _, way in near:
                b = at[cell]
                if b == a:
                    continue
                pa, pb = (xs[a - 1], ys[a - 1]), (xs[b - 1], ys[b - 1])
                points = gr.pull(pa, way, pb)
                line = [pa] + points + [pb]
                yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
                if by_road is None:
                    by_road = road_yards(a, LOCAL_YARDS * LOCAL_RATIO)
                if by_road.get(b, 1e18) <= yards * LOCAL_RATIO:
                    continue
                joins.append((a, b, yards))
                adj.setdefault(a, []).append((b, yards))
                adj.setdefault(b, []).append((a, yards))
                by_road[b] = yards
                if points:
                    shaped.append((min(a, b) * 65536 + max(a, b), points if a < b else points[::-1]))
        local = len(joins)

        # the network's pieces, joined: biggest first, each to the nearest junction already joined
        parent = list(range(len(xs) + 1))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i
        for a, b, _ in edges + joins:
            parent[find(a)] = find(b)
        groups = {}
        for i in range(1, len(xs) + 1):
            groups.setdefault(find(i), []).append(i)
        pieces = sorted(groups.values(), key=len, reverse=True)
        joined = {cells[i - 1]: i for i in pieces[0] if cells[i - 1]}
        waiting = pieces[1:]
        # A piece may only reach the rest through another piece, so go round until a round joins
        # nothing. Over open ground only. A join across blocked ground was tried and taken out:
        # it put a road over the wall of Un'Goro Crater into Thousand Needles. Nothing in the
        # data says where a wall can be crossed, so a piece the open ground doesn't reach stays
        # apart, and a walk to it has no way (the route then takes a flight, or says so).
        #
        # With one exception the roads themselves give: a road that stops and carries on. Two
        # dead ends in different pieces, close, each road pointing at the other end, and the line
        # between them mostly open ground: the bridge at Thandol Span is drawn as two roads that
        # stop 216 yards apart, facing each other. Those are joined straight.
        degree = [0] * (len(xs) + 1)
        comes_from = {}   # junction -> the point its road reaches it from
        for a, b, _ in edges:
            degree[a] += 1
            degree[b] += 1
            lo, hi = min(a, b), max(a, b)
            pts = bends_of.get(lo * 65536 + hi, [])
            line = [(xs[lo - 1], ys[lo - 1])] + list(zip(pts[0::2], pts[1::2])) + [(xs[hi - 1], ys[hi - 1])]
            comes_from[lo], comes_from[hi] = line[1], line[-2]

        def aim(a, b):
            """How far off the line to b the road at dead end a points, in degrees."""
            fx, fy = xs[a - 1] - comes_from[a][0], ys[a - 1] - comes_from[a][1]
            gx, gy = xs[b - 1] - xs[a - 1], ys[b - 1] - ys[a - 1]
            if math.hypot(fx, fy) == 0 or math.hypot(gx, gy) == 0:
                return 180
            return math.degrees(math.acos(max(-1, min(1, (fx * gx + fy * gy) / (math.hypot(fx, fy) * math.hypot(gx, gy))))))

        def blocked_share(a, b):
            d = math.hypot(xs[a - 1] - xs[b - 1], ys[a - 1] - ys[b - 1])
            steps = max(1, int(d / 3))
            bad = 0
            for k in range(steps + 1):
                t = k / steps
                if gr.at(*gr.g.to_cell(xs[a - 1] + (xs[b - 1] - xs[a - 1]) * t, ys[a - 1] + (ys[b - 1] - ys[a - 1]) * t)) == 2:
                    bad += 1
            return bad / (steps + 1)

        joined_ids = set(pieces[0])
        carried = 0
        progress = True
        while progress and waiting:
            progress, still = False, []
            for piece in waiting:
                starts = {cells[i - 1]: i for i in piece if cells[i - 1]}
                found = gr.reach(list(starts), joined, 1, LINK_CAP + LINK_CAP_EACH * len(starts), LINK_YARDS / gr.g.cell) if starts else []
                if found:
                    cell, _, way = found[0]
                    a, b = starts[way[0]], joined[cell]
                    pa, pb = (xs[a - 1], ys[a - 1]), (xs[b - 1], ys[b - 1])
                    points = gr.pull(pa, way, pb)
                    line = [pa] + points + [pb]
                    yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
                    joins.append((a, b, yards))
                    if points:
                        shaped.append((min(a, b) * 65536 + max(a, b), points if a < b else points[::-1]))
                else:
                    best = None
                    for i in piece:
                        if degree[i] != 1:
                            continue
                        for j in joined_ids:
                            if degree[j] != 1:
                                continue
                            d = math.hypot(xs[i - 1] - xs[j - 1], ys[i - 1] - ys[j - 1])
                            if d <= CARRY_YARDS and (best is None or d < best[0]) and aim(i, j) <= CARRY_AIM \
                                    and aim(j, i) <= CARRY_AIM and blocked_share(i, j) <= CARRY_BLOCKED:
                                best = (d, i, j)
                    if not best:
                        still.append(piece)
                        continue
                    joins.append((best[1], best[2], best[0]))
                    carried += 1
                    print("    a road that carries on: %d (%.0f, %.0f) to %d (%.0f, %.0f), %d yd" % (
                        best[1], xs[best[1] - 1], ys[best[1] - 1], best[2], xs[best[2] - 1], ys[best[2] - 1], best[0]), flush=True)
                joined.update(starts)
                joined_ids.update(piece)
                progress = True
            waiting = still
        links[cont] = joins
        for piece in waiting:
            px = sum(xs[i - 1] for i in piece) / len(piece)
            py = sum(ys[i - 1] for i in piece) / len(piece)
            print("    apart: %d junctions around world %.0f, %.0f" % (len(piece), px, py), flush=True)
        graph = {}
        for a, b, length in edges + joins:
            graph.setdefault(a, []).append((b, length))
            graph.setdefault(b, []).append((a, length))
        graphs[cont] = graph
        true_cells[cont] = {}
        for i in range(len(xs)):
            true_cells[cont].setdefault(gr.g.to_cell(xs[i], ys[i]), i + 1)
        print("continent %d: %d walks added between roads that pass close by; then the roads come in %d pieces "
              "(the biggest has %d of %d junctions); %d joined on (%d of them a road that carries on), %d left apart" % (
                  cont, local, len(pieces), len(pieces[0]), len(xs), len(joins) - local, carried, len(waiting)), flush=True)

        out.append("  [%d] = {\n" % cont)
        for key, points in sorted(shaped):
            out.append("    [%d]={%s},\n" % (key, fmt_points(points)))
        out.append("  },\n")
        print("continent %d: done in %.0fs" % (cont, time.time() - started), flush=True)
    out.append("}\n\n-- [cont] = { a, b, yards, ... }: walks that join the road network's separate pieces (bends in Shapes).\n")
    out.append("VP.Links = {\n")
    for cont, joins in sorted(links.items()):
        out.append("  [%d] = {%s},\n" % (cont, ",".join("%d,%d,%s" % (a, b, B.fmt(y)) for a, b, y in joins)))
    out.append("}\n\n-- [overlayID] = { cont, { junction, yards, { the points on the way from the pin } }, ... }\n")
    out.append("VP.Approach = {\n")

    done, none, crossed = 0, 0, 0
    started = time.time()
    all_pins = pins()
    ways_of = {}
    for overlay, (cont, x, y) in sorted(all_pins.items()):
        gr, at = grounds.get(cont), junction_cells.get(cont)
        if not gr or not at:
            continue
        xs, ys, _ = roads[cont]
        cell = gr.g.to_cell(x, y)
        found, through = [], False
        if gr.at(*cell) != 2:
            found = gr.reach(cell, at, REACH_WANT, REACH_CAP, REACH_YARDS / gr.g.cell)
        if not found:
            # The pin is on ground the grid has blocked (a canyon floor, a cave, a tunnel: the grid
            # can't tell those from a cliff) or closed off by it. From the pin itself then, across
            # as little blocked ground as will do, to the junctions where they really are.
            through = True
            found = gr.reach(cell, true_cells[cont], REACH_WANT, REACH_CAP,
                             (REACH_YARDS + STEEP * REACH_THROUGH) / gr.g.cell, through=True)
        if not found:
            none += 1
            print("  no way to a road for pin %d" % overlay, flush=True)
            continue
        crossed += 1 if through else 0
        parts, ways = [], []
        for c, _, way in found:
            j = (true_cells[cont] if through else at)[c]
            points = gr.pull((x, y), way, (xs[j - 1], ys[j - 1]))
            line = [(x, y)] + points + [(xs[j - 1], ys[j - 1])]
            yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
            ways.append((j, yards))
            parts.append("{%d,%s,{%s}}" % (j, B.fmt(yards), fmt_points(points)))
        ways_of[overlay] = ways
        out.append("  [%d]={%d,%s},\n" % (overlay, cont, ",".join(parts)))
        done += 1
    out.append("}\n")
    print("pins: %d joined to the roads (%d of them across ground the grid has blocked), %d with no junction in reach (%.0fs)" % (
        done, crossed, none, time.time() - started), flush=True)

    # Pins near each other with blocked ground between them: the walk round, when the roads make much more of it.
    out.append("\n-- [a * 65536 + b] = { yards, x1, y1, ... }: the walk between two nearby pins (overlay IDs a < b, points from a)\n")
    out.append("-- where the straight line is blocked and going round over the ground is much shorter than by road.\n")
    out.append("VP.Hops = {\n")
    started, hops, over = time.time(), 0, 0
    by_cont = {}
    for overlay, (cont, x, y) in all_pins.items():
        by_cont.setdefault(cont, []).append((overlay, x, y))
    for cont, plist in sorted(by_cont.items()):
        gr, graph = grounds.get(cont), graphs.get(cont)
        if not gr or graph is None:
            continue
        plist.sort()

        def by_road(overlay):
            dist, heap = {}, []
            for j, yards in ways_of.get(overlay, ()):
                if yards < dist.get(j, 1e18):
                    dist[j] = yards
                    heapq.heappush(heap, (yards, j))
            while heap:
                d, u = heapq.heappop(heap)
                if d > dist.get(u, 1e18):
                    continue
                for v, length in graph.get(u, ()):
                    if d + length < dist.get(v, 1e18):
                        dist[v] = d + length
                        heapq.heappush(heap, (d + length, v))
            return dist

        roads_from = {}
        for i, (a, ax, ay) in enumerate(plist):
            for b, bx, by in plist[i + 1:]:
                bird = math.hypot(ax - bx, ay - by)
                if bird > HOP_YARDS or bird < 1 or gr.clear(ax, ay, bx, by):
                    continue
                if a not in roads_from:
                    roads_from[a] = by_road(a)
                road = min((roads_from[a].get(j, 1e18) + yards for j, yards in ways_of.get(b, ())), default=1e18)
                ca, cb = gr.g.to_cell(ax, ay), gr.g.to_cell(bx, by)
                margin = max(25, max(abs(ca[0] - cb[0]), abs(ca[1] - cb[1])))
                oa, ob = gr.open_near(*ca), gr.open_near(*cb)
                way = gr.path(oa, ob, margin, HOP_CAP) if oa and ob else None
                crossing = False
                if not way and road > bird * HOP_DETOUR:
                    way = gr.path(ca, cb, margin, HOP_CAP, through=True)
                    crossing = True
                if not way:
                    continue
                points = gr.pull((ax, ay), way, (bx, by))
                line = [(ax, ay)] + points + [(bx, by)]
                yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
                if yards < road * HOP_BEATS:
                    out.append("  [%d]={%s%s},\n" % (a * 65536 + b, B.fmt(yards), "," + fmt_points(points) if points else ""))
                    hops += 1
                    over += 1 if crossing else 0
    out.append("}\n")
    print("hops: %d walks between nearby pins (%d of them across ground the grid has blocked) (%.0fs)" % (
        hops, over, time.time() - started), flush=True)

    out += taxi_block(grounds, roads, junction_cells, true_cells)

    with open(os.path.join(NAV, "Shapes.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    print("wrote Nav/Shapes.lua, %d KB" % (os.path.getsize(os.path.join(NAV, "Shapes.lua")) // 1024))


if __name__ == "__main__":
    if "--taxi" in sys.argv:
        taxi_only()
    else:
        main()
