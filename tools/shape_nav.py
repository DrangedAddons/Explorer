"""Builds Nav/Shapes.lua from Nav/Terrain.lua and Nav/Roads.lua: the ground between the points.

Usage: python -I tools/shape_nav.py        (tools/build_nav_data.py runs it after a rebuild)

AzerothGPS's roads are junctions and the length of road between each two. On a winding
mountain road a straight line between two junctions goes through the mountain. This works
out where each such road runs, by finding the way over open ground on the terrain grid, and
does the same for every explore pin: the walk from the pin to the road junctions nearest it.

Output (world yards, x north, y west):
  VP.Shapes[cont][a * 65536 + b] = { x1, y1, ... }     the points between junctions a < b, in
                                                       order from a, for roads whose straight
                                                       line is blocked
  VP.Links[cont] = { a, b, yards, ... }                extra roads. AzerothGPS's network comes in pieces
                                                       and its roads only meet at junctions (it has an
                                                       off-road router of its own for the rest). Two kinds:
                                                       a walk over open ground between junctions that are
                                                       near each other but far apart by road, and for each
                                                       piece a walk to the nearest junction of the rest.
                                                       Bends in Shapes.
  VP.Approach[overlayID] = { cont, { junction, yards, { x1, y1, ... } }, ... }
                                                       from an explore pin (Data.lua) to up to
                                                       two junctions: the walk, and the points
                                                       on the way from the pin
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
BUCKET = 60            # yards: wall stretches are looked up by this grid
EDGE_CAP = 400000      # cells an edge's search may open
REACH_CAP = 400000     # cells a pin's search may open
REACH_YARDS = 3000     # how far a pin looks for junctions, walking
LOCAL_YARDS = 450      # junctions this close over open ground get a walk between them ...
LOCAL_RATIO = 2.5      # ... when the roads take this many times longer to get there
LOCAL_WANT = 10        # ... looking at the nearest this many
LOCAL_CAP = 15000      # cells that search may open
LINK_CAP = 150000      # cells the search that joins a piece of the road network may open
LINK_CAP_EACH = 1200   # ... plus this many for each of the piece's junctions (it spreads out from all of them)
LINK_YARDS = 1500      # ... and how far it looks
LINK_THROUGH = 500     # ... and how many yards of blocked ground (a tunnel, a bridge) it may cross
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
            while j + 1 < len(pts) and self.clear(pts[i][0], pts[i][1], pts[j + 1][0], pts[j + 1][1]):
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


def main():
    stamp, grounds, roads = read_nav()
    out = [stamp + "\n",
           "-- AzerothGPS data (c) 2026 AzerothGPS, all rights reserved. Do not edit by hand.\n",
           "-- Where the roads run and how the explore pins join them, worked out from the terrain grid by\n",
           "-- tools/shape_nav.py.\n",
           "local _, VP = ...\n\n",
           "-- [cont][a * 65536 + b] = the points between junctions a < b, from a, where the straight line is blocked.\n",
           "VP.Shapes = {\n"]
    junction_cells, links = {}, {}
    for cont, (xs, ys, edges) in sorted(roads.items()):
        gr = grounds.get(cont)
        if not gr:
            continue
        started = time.time()
        cells, at = [], {}
        for i in range(len(xs)):
            rc = gr.open_near(*gr.g.to_cell(xs[i], ys[i]))
            cells.append(rc)
            if rc:
                at.setdefault(rc, i + 1)
        junction_cells[cont] = at
        shaped, straight, lost, crossed, seen = [], 0, 0, 0, set()
        for a, b, _ in edges:
            key = (min(a, b), max(a, b))
            if key in seen or a == b:
                continue
            seen.add(key)
            a, b = key
            pa, pb = (xs[a - 1], ys[a - 1]), (xs[b - 1], ys[b - 1])
            if gr.clear(pa[0], pa[1], pb[0], pb[1]):
                straight += 1
                continue
            ca, cb = cells[a - 1], cells[b - 1]
            way = None
            if ca and cb:
                span = max(abs(ca[0] - cb[0]), abs(ca[1] - cb[1]))
                way = gr.path(ca, cb, max(30, span), EDGE_CAP)
                if not way:
                    way = gr.path(ca, cb, max(30, span), EDGE_CAP, through=True)
                    crossed += 1 if way else 0
            if not way:
                lost += 1
                continue
            points = gr.pull(pa, way, pb)
            if points:
                shaped.append((a * 65536 + b, points))
            else:
                straight += 1
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
        # nothing. First over open ground only; what's left then may cross blocked ground.
        for through in (False, True):
            progress = True
            while progress and waiting:
                progress, still = False, []
                for piece in waiting:
                    starts = {cells[i - 1]: i for i in piece if cells[i - 1]}
                    reach_cost = LINK_YARDS / gr.g.cell + (STEEP * LINK_THROUGH / gr.g.cell if through else 0)
                    found = gr.reach(list(starts), joined, 1, LINK_CAP + LINK_CAP_EACH * len(starts), reach_cost, through) if starts else []
                    if not found:
                        still.append(piece)
                        continue
                    cell, _, way = found[0]
                    a, b = starts[way[0]], joined[cell]
                    pa, pb = (xs[a - 1], ys[a - 1]), (xs[b - 1], ys[b - 1])
                    points = gr.pull(pa, way, pb)
                    line = [pa] + points + [pb]
                    yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
                    joins.append((a, b, yards))
                    if points:
                        shaped.append((min(a, b) * 65536 + max(a, b), points if a < b else points[::-1]))
                    joined.update(starts)
                    progress = True
                waiting = still
        links[cont] = joins
        print("continent %d: %d walks added between roads that pass close by; then the roads come in %d pieces "
              "(the biggest has %d of %d junctions); %d joined on, %d left adrift" % (
                  cont, local, len(pieces), len(pieces[0]), len(xs), len(joins) - local, len(waiting)), flush=True)

        out.append("  [%d] = {\n" % cont)
        for key, points in sorted(shaped):
            out.append("    [%d]={%s},\n" % (key, fmt_points(points)))
        out.append("  },\n")
        print("continent %d: %d roads straight, %d shaped (%d of them across ground the grid has blocked), %d with no way (%.0fs)" % (
            cont, straight, len(shaped), crossed, lost, time.time() - started))
    out.append("}\n\n-- [cont] = { a, b, yards, ... }: walks that join the road network's separate pieces (bends in Shapes).\n")
    out.append("VP.Links = {\n")
    for cont, joins in sorted(links.items()):
        out.append("  [%d] = {%s},\n" % (cont, ",".join("%d,%d,%s" % (a, b, B.fmt(y)) for a, b, y in joins)))
    out.append("}\n\n-- [overlayID] = { cont, { junction, yards, { the points on the way from the pin } }, ... }\n")
    out.append("VP.Approach = {\n")

    done, none, crossed = 0, 0, 0
    started = time.time()
    for overlay, (cont, x, y) in sorted(pins().items()):
        gr, at = grounds.get(cont), junction_cells.get(cont)
        if not gr or not at:
            continue
        xs, ys, _ = roads[cont]
        start = gr.open_near(*gr.g.to_cell(x, y))
        found = gr.reach(start, at, REACH_WANT, REACH_CAP, REACH_YARDS / gr.g.cell) if start else []
        if start and not found:
            # closed off by the grid (a plateau, a cave mouth, an island): the way that crosses least of it
            found = gr.reach(start, at, 1, REACH_CAP, REACH_YARDS / gr.g.cell, through=True)
            crossed += 1 if found else 0
        if not found:
            none += 1
            continue
        parts = []
        for cell, walked, way in found:
            j = at[cell]
            points = gr.pull((x, y), way, (xs[j - 1], ys[j - 1]))
            # the walk, measured along the corners
            line = [(x, y)] + points + [(xs[j - 1], ys[j - 1])]
            yards = sum(math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in zip(line, line[1:]))
            parts.append("{%d,%s,{%s}}" % (j, B.fmt(yards), fmt_points(points)))
        out.append("  [%d]={%d,%s},\n" % (overlay, cont, ",".join(parts)))
        done += 1
    out.append("}\n")
    print("pins: %d joined to the roads (%d of them across ground the grid has blocked), %d with no junction in reach (%.0fs)" % (
        done, crossed, none, time.time() - started))

    with open(os.path.join(NAV, "Shapes.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    print("wrote Nav/Shapes.lua, %d KB" % (os.path.getsize(os.path.join(NAV, "Shapes.lua")) // 1024))


if __name__ == "__main__":
    main()
