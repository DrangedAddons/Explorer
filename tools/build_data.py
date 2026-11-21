"""Builds Data.lua from WoW Forever's own game tables (DB2 exports on wago.tools, product wowf).

Usage: python tools/build_data.py [--refresh]
  --refresh  download the tables for the newest wowf build (otherwise tools/.cache is reused)

How the tables join:
  Achievement.Criteria_tree -> CriteriaTree (children) -> Criteria (Type 43 = explore area,
  Asset = WorldMapOverlay ID) -> WorldMapOverlay (hit rectangle in map art pixels)
  -> UiMapXMapArt (which map the art belongs to) / UiMapArtStyleLayer (art size in pixels).
A pin sits at the middle of the overlay's hit rectangle, which is the part of the map you
hover to see that area's name. Overlays without one use the middle of their texture.
"""
import csv
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", ".cache")
PRODUCT = "wowf"
TABLES = ["Achievement", "Achievement_Category", "CriteriaTree", "Criteria", "WorldMapOverlay",
          "UiMap", "UiMapXMapArt", "UiMapArt", "UiMapArtStyleLayer"]
EXPLORE_AREA = "43"
UA = {"User-Agent": "Mozilla/5.0"}


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r:
        return r.read()


def refresh():
    builds = json.loads(fetch("https://wago.tools/api/builds"))
    version = builds[PRODUCT][0]["version"]
    os.makedirs(CACHE, exist_ok=True)
    for t in TABLES:
        data = fetch("https://wago.tools/db2/%s/csv?build=%s" % (t, version))
        with open(os.path.join(CACHE, t + ".csv"), "wb") as f:
            f.write(data)
        print("fetched", t, len(data))
    with open(os.path.join(CACHE, "build.txt"), "w") as f:
        f.write(version)


def load(name):
    with open(os.path.join(CACHE, name + ".csv"), encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if "--refresh" in sys.argv or not os.path.exists(os.path.join(CACHE, "build.txt")):
        refresh()
    build = open(os.path.join(CACHE, "build.txt")).read().strip()

    criteria = {r["ID"]: r for r in load("Criteria")}
    overlays = {r["ID"]: r for r in load("WorldMapOverlay")}
    cats = {r["ID"]: r for r in load("Achievement_Category")}
    art_map = {r["UiMapArtID"]: int(r["UiMapID"]) for r in load("UiMapXMapArt")}
    art_style = {r["ID"]: r["UiMapArtStyleID"] for r in load("UiMapArt")}
    style_size = {r["UiMapArtStyleID"]: (int(r["LayerWidth"]), int(r["LayerHeight"]))
                  for r in load("UiMapArtStyleLayer") if r["LayerIndex"] == "0"}
    map_name = {int(r["ID"]): r["Name_lang"] for r in load("UiMap")}

    kids = {}
    for r in load("CriteriaTree"):
        kids.setdefault(r["Parent"], []).append(r)
    for rows in kids.values():
        rows.sort(key=lambda r: int(r["OrderIndex"]))

    # Forever redrew its zone maps under new art IDs, and the criteria still name the overlays
    # of the old art, which no map uses. The same area's overlay on the art in use has the
    # position, so swap to it (matched on the overlay's area IDs).
    def areas_of(o):
        return tuple(o["AreaID_%d" % i] for i in range(4))

    by_areas, by_first, by_any = {}, {}, {}
    for o in overlays.values():
        if o["UiMapArtID"] in art_map:
            by_areas.setdefault(areas_of(o), o)
            by_first.setdefault(o["AreaID_0"], o)
            for a in areas_of(o):
                if a != "0":
                    by_any.setdefault(a, o)

    def current(o):
        if not o or o["UiMapArtID"] in art_map:
            return o
        return by_areas.get(areas_of(o)) or by_first.get(o["AreaID_0"]) or by_any.get(o["AreaID_0"])

    # A few old overlays have no twin (Undercity, Blackmaw Hold ...). The old and new art share
    # one layout, so those keep their own rectangle, on the map most of their art's twins are on.
    votes, moved = {}, 0
    for o in overlays.values():
        twin = current(o)
        if twin and twin is not o:
            v = votes.setdefault(o["UiMapArtID"], {})
            v[art_map[twin["UiMapArtID"]]] = v.get(art_map[twin["UiMapArtID"]], 0) + 1
            if any(o[k] != twin[k] for k in ("HitRectLeft", "HitRectRight", "HitRectTop", "HitRectBottom")):
                moved += 1
    for art, v in votes.items():
        art_map[art] = max(v, key=v.get)
    print("old overlays whose twin sits somewhere else on the new art:", moved)

    zones, areas, skipped = [], {}, []
    for a in load("Achievement"):
        rows = []
        for k in kids.get(a["Criteria_tree"], []):
            c = criteria.get(k["CriteriaID"])
            if not c or c["Type"] != EXPLORE_AREA:
                continue
            asset = c["Asset"]
            o = current(overlays.get(asset)) or overlays.get(asset)
            size = o and style_size.get(art_style.get(o["UiMapArtID"]))
            ui_map = o and art_map.get(o["UiMapArtID"])
            if not (o and size and ui_map):
                skipped.append((a["Title_lang"], k["Description_lang"], c["Asset"]))
                continue
            left, right = int(o["HitRectLeft"]), int(o["HitRectRight"])
            top, bottom = int(o["HitRectTop"]), int(o["HitRectBottom"])
            if right <= left or bottom <= top:
                left, top = int(o["OffsetX"]), int(o["OffsetY"])
                right, bottom = left + int(o["TextureWidth"]), top + int(o["TextureHeight"])
            x = min(98.0, max(2.0, (left + right) / 2 / size[0] * 100))
            y = min(98.0, max(2.0, (top + bottom) / 2 / size[1] * 100))
            rows.append((int(asset), ui_map, round(x, 1), round(y, 1), k["Description_lang"]))
        if not rows:
            continue
        # The zone's map is the one most of its areas are drawn on.
        counts = {}
        for r in rows:
            counts[r[1]] = counts.get(r[1], 0) + 1
        ui_map = max(counts, key=counts.get)
        cat = cats.get(a["Category"], {})
        zones.append({
            "id": int(a["ID"]), "map": ui_map, "title": a["Title_lang"],
            "order": (int(cat.get("Ui_order", 0)), int(a["Ui_order"]), int(a["ID"])),
            "rows": rows,
        })
        for r in rows:
            areas[r[0]] = r

    zones.sort(key=lambda z: z["order"])
    out = [
        "-- GENERATED by tools/build_data.py from WoW Forever %s game tables (wago.tools). Do not edit by hand." % build,
        "local _, NS = ...",
        "",
        "NS.DataBuild = %s" % lua_str(build),
        "",
        "-- [map overlay ID] = { uiMapID, x, y, name }. x, y are map percent. The overlay ID is what",
        "-- GetAchievementCriteriaInfo returns as an explore criterion's asset (the game's",
        "-- WorldMapOverlay table; position from the same area's overlay on the map art in use).",
        "NS.Areas = {",
    ]
    for oid in sorted(areas):
        _, ui_map, x, y, name = areas[oid]
        out.append("  [%d] = {%d, %s, %s, %s}," % (oid, ui_map, x, y, lua_str(name)))
    out += [
        "}",
        "",
        "-- The zone challenges in the Legacy window's order: { achievementID, uiMapID, overlay IDs... }.",
        "-- The overlay IDs are in criteria order, for clients that don't report a criterion's asset.",
        "NS.Zones = {",
    ]
    for z in zones:
        ids = ", ".join(str(r[0]) for r in z["rows"])
        out.append("  {%d, %d, %s}, -- %s (%s)" % (z["id"], z["map"], ids, z["title"], map_name.get(z["map"], "?")))
    out += ["}", ""]

    with open(os.path.join(ROOT, "Data.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    print("build %s: %d zones, %d areas" % (build, len(zones), len(areas)))
    for s in skipped:
        print("  skipped (no overlay/map):", s)
    for z in zones:
        maps = sorted({r[1] for r in z["rows"]})
        if len(maps) > 1:
            print("  %s spans maps %s" % (z["title"], maps))


if __name__ == "__main__":
    main()
