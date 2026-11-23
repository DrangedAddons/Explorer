"""Build Explorer's walking data (Nav/Terrain.lua, Nav/Roads.lua, then Nav/Shapes.lua) from AzerothGPS's
data (used with its author's permission), without AzerothGPS having to be installed.

Usage:
  python -I tools/build_nav_data.py                 latest AzerothGPS release from CurseForge
  python -I tools/build_nav_data.py --zip <file>    a release zip already downloaded
  python -I tools/build_nav_data.py --from <dir>    an AzerothGPS folder on disk instead
  add --force to rebuild when the source version hasn't changed, --no-shapes to stop before shape_nav

Prints "unchanged" and writes nothing when Nav/ was already built from that version.

What is taken from AzerothGPS, and what is made of it:

  Terrain   its passability grid per continent (cells of 8.33 yards: open, water, too steep). On
            its own that grid closes off every bridge and every tunnel: a bridge's floor is over
            a drop and a tunnel's is under a mountain. AzerothGPS keeps those apart (Bridges.lua,
            Caves.lua, its wall erasers in Roads.lua) and lays them over the grid when it routes.
            Here they are laid over once and the result written out: Nav/Terrain.lua is the
            ground you can walk on, bridges and tunnels and all, in AzerothGPS's own row encoding.
              bridges   the cells under a bridge's floor outline are open
              caves     a cave's or tunnel's own grid (2-yard cells) is laid over the continent's:
                        where a quarter of a continent cell or more is cave floor, it is open
              erasers   cells AzerothGPS's hand-drawn wall erasers open
              deep sea  blocked (fatigue)
  Roads     its road network: junctions, and every road between two of them with its length
            and its course (the points along it). Nav/Roads.lua has the junctions and roads
            (VP.Roads), each road's course (VP.Bends) and the hand-drawn walls (VP.Walls).

AzerothGPS's roads come in dozens of unconnected pieces (it has an off-road router for the
gaps). tools/shape_nav.py, run from here, joins them over that ground and works out the rest
(Nav/Shapes.lua). Nothing here or there guesses where blocked ground can be crossed.

Output (all in the addon's private namespace, which these files call VP as VendorPoint's do, world
yards, x north, y west):
  VP.Terrain[cont] = { tx0, ty0, cell, w, h, rows = { run-length rows } }   0 open, 1 water, 2 blocked
  VP.Roads[cont]   = { n = { x1, y1, ... }, e = { a1, b1, len1, ... } }
  VP.Bends[cont]   = { [a * 65536 + b] = { x1, y1, ... } }                  the points between a < b, from a
  VP.Walls[cont]   = { { x1, y1, x2, y2, ... }, ... }
  VP.Opens[cont]   = {}                                                    (the erasers are in the grid now)
"""
import io
import json
import math
import os
import re
import sys
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CURSEFORGE_PROJECT = 1712208  # AzerothGPS
CF_FILES = "https://www.curseforge.com/api/v1/mods/%d/files?pageIndex=0&pageSize=20&sort=dateCreated&sortDescending=true"
CF_DOWNLOAD = "https://www.curseforge.com/api/v1/mods/%d/files/%d/download"
FOREVER_VERSION = "1.60."   # game versions starting with this are WoW Forever's
NEEDED = ("AzerothGPS.toc", "Data/Terrain.lua", "Data/Roads.lua", "Data/Bridges.lua", "Data/Caves.lua")

TILE = 1600 / 3
OPEN_YD = 6          # a wall eraser stroke or a bridge's outline opens blocked ground this close to it
END_SLACK = 40       # same as Nav.lua: blocked cells this close to either end are ignored
SWIM = 1.5
CAVE_SHARE = 0.25    # a continent cell is open when this much of it is a cave's floor
BEND_YD = 2.5        # a road's course is kept to within this of AzerothGPS's


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def from_zip(data):
    texts = {}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for name in NEEDED:
            texts[name] = z.read("AzerothGPS/" + name).decode("utf-8")
    return texts


def from_curseforge():
    files = json.loads(get(CF_FILES % CURSEFORGE_PROJECT))["data"]
    files = [f for f in files if f.get("releaseType") == 1
             and any(v.startswith(FOREVER_VERSION) for v in f.get("gameVersions", []))]
    if not files:
        sys.exit("no Forever release of AzerothGPS found on CurseForge")
    f = files[0]
    print("CurseForge:", f["displayName"], f["fileName"], f["dateCreated"])
    return from_zip(get(CF_DOWNLOAD % (CURSEFORGE_PROJECT, f["id"])))


def from_dir(path):
    texts = {}
    for name in NEEDED:
        with open(os.path.join(path, name), encoding="utf-8") as f:
            texts[name] = f.read()
    return texts


def block(text, start):
    """The balanced { ... } that opens at text[start] (no braces inside strings in these files)."""
    depth = 0
    for i in range(start, len(text)):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise ValueError("unbalanced")


def table_after(text, marker):
    return block(text, text.index(marker) + len(marker))


def top_entries(table_text):
    """[cont] = { ... } entries of a table literal, as (cont, body)."""
    out, i = [], 1
    pat = re.compile(r"\[(\d+)\]\s*=\s*\{")
    while True:
        m = pat.search(table_text, i)
        if not m:
            return out
        body = block(table_text, m.end() - 1)
        out.append((int(m.group(1)), body))
        i = m.end() - 1 + len(body)


def numbers(text):
    return [float(x) for x in re.findall(r"-?\d+(?:\.\d+)?(?:e-?\d+)?", text)]


def fmt(v):
    s = ("%.1f" % v).rstrip("0").rstrip(".")
    return s if s not in ("-0", "") else "0"


def fmt_exact(v):
    return ("%.6f" % v).rstrip("0").rstrip(".")


# --- terrain rows, the same reading as Nav.lua --------------------------------------------------
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
INDEX = {c: i for i, c in enumerate(ALPHABET)}
SHORT = 21


def decode_row(text, short=SHORT, long=3):
    """A run-length row as [(end, value)]: AzerothGPS's Passability.DecodeRow."""
    runs, pos, i = [], 0, 0
    while i < len(text):
        if text[i] == "_":
            v = ord(text[i + 1]) - 48
            if long == 2:
                n = INDEX[text[i + 2]] * 64 + INDEX[text[i + 3]]
                i += 4
            else:
                n = INDEX[text[i + 2]] * 4096 + INDEX[text[i + 3]] * 64 + INDEX[text[i + 4]]
                i += 5
        else:
            k = INDEX[text[i]]
            v, n = k // short, k % short + 1
            i += 1
        pos += n
        runs.append((pos, v))
    return runs


def encode_row(cells):
    """A row of 0/1/2 as AzerothGPS encodes it (short runs one character, long ones "_", value, 3 digits)."""
    out, i, n = [], 0, len(cells)
    while i < n:
        v = cells[i]
        j = i
        while j < n and cells[j] == v:
            j += 1
        length = j - i
        if length <= SHORT:
            out.append(ALPHABET[v * SHORT + length - 1])
        else:
            out.append("_%d%s%s%s" % (v, ALPHABET[length // 4096], ALPHABET[length // 64 % 64], ALPHABET[length % 64]))
        i = j
    return "".join(out)


class Grid:
    """A continent's grid read back from Nav/Terrain.lua (tools/shape_nav.py works on it)."""

    def __init__(self, body, opens, walls):
        head = body[: body.index("rows")]
        g = {k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*(-?[\d.]+)", head)}
        self.tx0, self.ty0, self.cell = g["tx0"], g["ty0"], g["cell"]
        self.w, self.h = int(g["w"]), int(g["h"])
        self.rows = re.findall(r'"([^"]*)"', body[body.index("rows"):])
        self.decoded = {}
        self.opens = opens
        self.walls = walls

    def to_cell(self, x, y):
        k = TILE / self.cell
        return math.floor(((32 - x / TILE) - self.ty0) * k) + 1, math.floor(((32 - y / TILE) - self.tx0) * k) + 1

    def centre(self, row, col):
        k = TILE / self.cell
        return (32 - self.ty0 - (row - 0.5) / k) * TILE, (32 - self.tx0 - (col - 0.5) / k) * TILE

    def at(self, row, col):
        if row < 1 or row > self.h or col < 1 or col > self.w:
            return 2
        if row * 65536 + col in self.opens:
            return 0
        runs = self.decoded.get(row)
        if runs is None:
            runs = self.decoded[row] = decode_row(self.rows[row - 1])
        lo, hi = 0, len(runs) - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if runs[mid][0] < col:
                lo = mid + 1
            else:
                hi = mid
        return runs[lo][1]

    def crosses_wall(self, x1, y1, x2, y2):
        def orient(ax, ay, bx, by, cx, cy):
            return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        for pts in self.walls:
            for i in range(0, len(pts) - 3, 2):
                ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
                if ((orient(x1, y1, x2, y2, ax, ay) > 0) != (orient(x1, y1, x2, y2, bx, by) > 0) and
                        (orient(ax, ay, bx, by, x1, y1) > 0) != (orient(ax, ay, bx, by, x2, y2) > 0)):
                    return True
        return False

    def segment(self, x1, y1, x2, y2):
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        if self.crosses_wall(x1, y1, x2, y2):
            return None
        n = max(1, math.ceil(length / (self.cell / 3)))
        slack = END_SLACK / length if length > 0 else 1
        water, last = 0, None
        for i in range(n + 1):
            t = i / n
            rc = self.to_cell(x1 + dx * t, y1 + dy * t)
            if rc != last:
                v, last = self.at(*rc), rc
            if v == 2 and slack < t < 1 - slack:
                return None
            if v == 1:
                water += 1
        return length + length * (water / (n + 1)) * (SWIM - 1)


def inside(poly, x, y):
    c, j = False, len(poly) - 1
    for i in range(len(poly)):
        (xi, yi), (xj, yj) = poly[i], poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c


def near(line, x, y, r):
    for (ax, ay), (bx, by) in zip(line, line[1:]):
        dx, dy = bx - ax, by - ay
        length2 = dx * dx + dy * dy
        t = 0 if length2 == 0 else max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / length2))
        if (ax + dx * t - x) ** 2 + (ay + dy * t - y) ** 2 <= r * r:
            return True
    return False


class Land:
    """A continent's grid as rows of cells, to lay bridges, caves and erasers over and write out again."""

    def __init__(self, body):
        head = body[: body.index("rows")]
        g = {k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*(-?[\d.]+)", head)}
        self.tx0, self.ty0, self.cell = g["tx0"], g["ty0"], g["cell"]
        self.w, self.h = int(g["w"]), int(g["h"])
        deep = int(g.get("deep", -1))
        self.rows = []
        for text in re.findall(r'"([^"]*)"', body[body.index("rows"):]):
            row, pos = bytearray(self.w), 0
            for end, v in decode_row(text):
                if v == deep or v > 2:
                    v = 2
                if v:
                    row[pos:end] = bytes([v]) * (end - pos)
                pos = end
            self.rows.append(row)
        assert len(self.rows) == self.h, (len(self.rows), self.h)

    def to_cell(self, x, y):
        k = TILE / self.cell
        return math.floor(((32 - x / TILE) - self.ty0) * k) + 1, math.floor(((32 - y / TILE) - self.tx0) * k) + 1

    def centre(self, row, col):
        k = TILE / self.cell
        return (32 - self.ty0 - (row - 0.5) / k) * TILE, (32 - self.tx0 - (col - 0.5) / k) * TILE

    def open(self, row, col):
        """Opens a cell. 1 when that changed it."""
        if 1 <= row <= self.h and 1 <= col <= self.w and self.rows[row - 1][col - 1] == 2:
            self.rows[row - 1][col - 1] = 0
            return 1
        return 0

    def open_shape(self, pts, area, pad):
        """Opens the cells inside a closed outline (`area`) and within `pad` yards of the line."""
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        r1, c1 = self.to_cell(max(xs) + pad, max(ys) + pad)
        r2, c2 = self.to_cell(min(xs) - pad, min(ys) - pad)
        line = pts + pts[:1] if area else pts
        changed = 0
        for row in range(min(r1, r2), max(r1, r2) + 1):
            for col in range(min(c1, c2), max(c1, c2) + 1):
                x, y = self.centre(row, col)
                if (area and inside(pts, x, y)) or (pad > 0 and near(line, x, y, pad)):
                    changed += self.open(row, col)
        return changed

    def lua(self):
        rows = ",\n".join('    "%s"' % encode_row(row) for row in self.rows)
        return "{ tx0 = %s, ty0 = %s, cell = %s, w = %d, h = %d, rows = {\n%s,\n  } }" % (
            fmt_exact(self.tx0), fmt_exact(self.ty0), fmt_exact(self.cell), self.w, self.h, rows)


def cave_grids(caves_text):
    """{ grid key: (tx0, ty0, cell, w, h, short, long, rows) } for every cave, and { grid key: continent }."""
    grids = {}
    for m in re.finditer(r'ns\.Terrain\["(\w+)"\]\s*=\s*\{([^{}]*?)rows\s*=\s*"([^"]*)"', caves_text):
        g = {k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*(-?[\d.]+)", m.group(2))}
        if g.get("short") and g.get("long"):
            grids[m.group(1)] = (g["tx0"], g["ty0"], g["cell"], int(g["w"]), int(g["h"]), int(g["short"]), int(g["long"]),
                                 m.group(3).split("/"))
    where = {}
    for m in re.finditer(r"^ns\.Caves\[(\d+)\] = \{", caves_text, re.M):
        body = block(caves_text, m.end() - 1)
        for key in re.findall(r'\{ "[^"]*", "(\w+)",', body):
            where[key] = int(m.group(1))
    return grids, where


def simplify(points, tolerance):
    """Douglas-Peucker: the points of a line that it can't do without, to within `tolerance`."""
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        (ax, ay), (bx, by) = points[first], points[last]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        far, at = -1.0, first
        for i in range(first + 1, last):
            px, py = points[i]
            d = abs(dx * (py - ay) - dy * (px - ax)) / length if length > 0 else math.hypot(px - ax, py - ay)
            if d > far:
                far, at = d, i
        if far > tolerance:
            keep[at] = True
            stack.append((first, at))
            stack.append((at, last))
    return [p for p, k in zip(points, keep) if k]


def build(texts):
    m = re.search(r"^## Version:\s*(\S+)", texts["AzerothGPS.toc"], re.M)
    ver = m.group(1) if m else "?"
    stamp = "-- GENERATED by tools/build_nav_data.py from AzerothGPS %s (with its author's permission).\n" % ver
    roads_path = os.path.join(ROOT, "Nav", "Roads.lua")
    if "--force" not in sys.argv and os.path.exists(roads_path):
        with open(roads_path, encoding="utf-8") as f:
            if f.readline() == stamp:
                print("unchanged: Nav/ is already built from AzerothGPS", ver)
                return
    header = stamp + ("-- AzerothGPS data (c) 2026 AzerothGPS, all rights reserved. Do not edit by hand.\n"
                      "local _, VP = ...\n")

    terrain_text, roads_text = texts["Data/Terrain.lua"], texts["Data/Roads.lua"]
    t_table = table_after(terrain_text, "ns.Terrain = ")
    r_table = table_after(roads_text, "ns.Roads = ")
    w_table = table_after(roads_text, "ns.Walls = ")
    o_table = table_after(roads_text, "ns.WallOpens = ")

    # walls
    walls = {}
    for cont, body in top_entries(w_table):
        walls[cont] = []
        for wm in re.finditer(r"\{([^{}]*)\}", body[1:-1]):
            pts = numbers(re.sub(r"\b[a-z]+\s*=\s*-?[\d.]+", "", wm.group(1)))  # drop z = ... fields
            if len(pts) >= 4:
                walls[cont].append(pts[: len(pts) // 2 * 2])

    # the ground: the grid, with the erasers, the bridges and the caves laid over it
    lands = {cont: Land(body) for cont, body in top_entries(t_table)}
    for cont, body in top_entries(o_table):
        g = lands.get(cont)
        if not g:
            continue
        changed = 0
        for om in re.finditer(r"\{\s*area\s*=\s*(true|false)\s*,\s*pts\s*=\s*\{([^{}]*)\}\s*\}", body):
            v = numbers(om.group(2))
            area = om.group(1) == "true"
            changed += g.open_shape(list(zip(v[0::2], v[1::2])), area, 0 if area else OPEN_YD)
        print("continent %d: wall erasers open %d cells" % (cont, changed), flush=True)
    for cont, body in top_entries(table_after(texts["Data/Bridges.lua"], "ns.Bridges = ")):
        g = lands.get(cont)
        if not g:
            continue
        changed, count = 0, 0
        for bm in re.finditer(r"\{([^{}]*)\}", body[1:-1]):
            v = numbers(bm.group(1))
            if len(v) >= 6:
                changed += g.open_shape(list(zip(v[0::2], v[1::2])), True, OPEN_YD)
                count += 1
        print("continent %d: %d bridges open %d cells" % (cont, count, changed), flush=True)
    grids, where = cave_grids(texts["Data/Caves.lua"])
    opened, used = {}, {}
    for key, (tx0, ty0, cell, w, h, short, long, rows) in grids.items():
        cont = where.get(key)
        g = lands.get(cont)
        if g is None:
            continue
        k = TILE / cell
        floor = {}
        for r, text in enumerate(rows, 1):
            pos = 0
            x = (32 - ty0 - (r - 0.5) / k) * TILE
            for end, v in decode_row(text, short, long):
                if v == 0:
                    for c in range(pos + 1, end + 1):
                        rc = g.to_cell(x, (32 - tx0 - (c - 0.5) / k) * TILE)
                        floor[rc] = floor.get(rc, 0) + 1
                pos = end
        need = CAVE_SHARE * (g.cell / cell) ** 2
        used[cont] = used.get(cont, 0) + 1
        for (row, col), count in floor.items():
            if count >= need:
                opened[cont] = opened.get(cont, 0) + g.open(row, col)
    for cont in sorted(used):
        print("continent %d: %d caves and tunnels open %d cells" % (cont, used[cont], opened.get(cont, 0)), flush=True)

    # roads: junctions, each road's length, and its course
    out = [header, "VP.Roads = {\n"]
    bends_out = ["\n-- [cont][a * 65536 + b] = the points along the road between junctions a < b, from a (the ends left out).\n",
                 "VP.Bends = {\n"]
    for cont, body in top_entries(r_table):
        nodes = numbers(block(body, body.index("n = {") + 4))
        best = {}
        for em in re.finditer(r"\{([^{}]*)\}", block(body, body.index("e = {") + 4)[1:-1]):
            v = numbers(em.group(1))
            if len(v) < 4:
                continue
            a, b = int(v[0]), int(v[1])
            if a == b:
                continue
            pts = list(zip(v[4::2], v[5::2]))
            if a > b:
                a, b, pts = b, a, pts[::-1]
            if (a, b) not in best or v[2] < best[(a, b)][0]:
                best[(a, b)] = (v[2], pts)
        edges, bends, kept = [], [], 0
        for (a, b), (length, pts) in sorted(best.items()):
            edges.append((a, b, length))
            inner = simplify(pts, BEND_YD)[1:-1] if len(pts) > 2 else []
            if inner:
                bends.append((a * 65536 + b, inner))
                kept += len(inner)
        out.append("  [%d] = {\n    n = {%s},\n    e = {%s},\n  },\n" % (
            cont, ",".join(fmt(x) for x in nodes),
            ",".join("%d,%d,%s" % (a, b, fmt(c)) for a, b, c in edges)))
        bends_out.append("  [%d] = {\n" % cont)
        for key, inner in bends:
            bends_out.append("    [%d]={%s},\n" % (key, ",".join("%d,%d" % (round(x), round(y)) for x, y in inner)))
        bends_out.append("  },\n")
        print("continent %d: %d junctions, %d roads, %d points along them" % (cont, len(nodes) // 2, len(edges), kept), flush=True)
    out.append("}\n")
    bends_out.append("}\n")
    out += bends_out
    out.append("\n-- Walls (what can't be walked through, like a mountain's edge the grid has open): point lists.\n")
    out.append("VP.Walls = {\n")
    for cont, lst in walls.items():
        out.append("  [%d] = {%s},\n" % (cont, ",".join("{" + ",".join(fmt(x) for x in p) + "}" for p in lst)))
    out.append("}\n\n-- (AzerothGPS's wall erasers are laid into the grid in Terrain.lua; nothing is opened on top of it.)\n")
    out.append("VP.Opens = {\n")
    for cont in sorted(lands):
        out.append("  [%d] = {},\n" % cont)
    out.append("}\n")

    os.makedirs(os.path.join(ROOT, "Nav"), exist_ok=True)
    with open(os.path.join(ROOT, "Nav", "Terrain.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(header)
        f.write("-- The ground per continent: cells of `cell` yards, row = south, col = east, from terrain tile\n"
                "-- (tx0, ty0). 0 open, 1 water, 2 blocked. AzerothGPS's terrain grid with its bridges' floors, its\n"
                "-- caves' and tunnels' floors and its wall erasers laid over it, and its deep sea blocked. Rows are\n"
                "-- run-length encoded as AzerothGPS's are.\n")
        f.write("VP.Terrain = {\n")
        for cont in sorted(lands):
            f.write("  [%d] = %s,\n" % (cont, lands[cont].lua()))
        f.write("}\n")
    with open(roads_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    print("built Nav/Terrain.lua and Nav/Roads.lua from AzerothGPS", ver, flush=True)
    if "--no-shapes" not in sys.argv:
        # the joins between the roads' pieces, and how the explore pins and the flight masters join them
        import shape_nav
        shape_nav.main()


if __name__ == "__main__":
    if "--from" in sys.argv:
        build(from_dir(sys.argv[sys.argv.index("--from") + 1]))
    elif "--zip" in sys.argv:
        with open(sys.argv[sys.argv.index("--zip") + 1], "rb") as f:
            build(from_zip(f.read()))
    else:
        build(from_curseforge())
