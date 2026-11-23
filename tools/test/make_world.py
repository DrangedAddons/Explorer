"""Writes tools/test/world.lua: the game's maps and where each lies in the world, for the tests
that run the real pathfinder (factions.lua).

Usage: python -I tools/test/make_world.py      (after tools/build_data.py has filled tools/.cache)

From UiMap and UiMapAssignment (wago.tools, product wowf).
"""
import csv
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(os.path.dirname(HERE), ".cache")


def rows(name):
    with open(os.path.join(CACHE, name + ".csv"), encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def main():
    build = open(os.path.join(CACHE, "build.txt"), encoding="utf-8").read().strip()
    where = {}
    for r in rows("UiMapAssignment"):
        where.setdefault(int(r["UiMapID"]), []).append(r)
    out = ["-- The game's maps and where each lies in the world. Written by tools/test/make_world.py from",
           "-- UiMap and UiMapAssignment, build %s." % build,
           "-- [uiMapID] = { name, parent, type, { instance, left, right, top, bottom, uiLeft, uiTop, uiRight, uiBottom }, ... }",
           "-- World yards: x runs north, y west. left/right are y, top/bottom are x.",
           "WORLD = {"]
    for m in sorted(rows("UiMap"), key=lambda r: int(r["ID"])):
        parts = []
        for a in sorted(where.get(int(m["ID"]), []), key=lambda r: int(r["OrderIndex"])):
            parts.append("{ %d, %s, %s, %s, %s, %s, %s, %s, %s }" % (
                int(a["MapID"]),
                *("%.2f" % float(a[k]) for k in ("Region_4", "Region_1", "Region_3", "Region_0")),
                *("%.4g" % float(a[k]) for k in ("UiMin_0", "UiMin_1", "UiMax_0", "UiMax_1"))))
        out.append('  [%d] = { "%s", %d, %d, %s },' % (
            int(m["ID"]), m["Name_lang"].replace('"', '\\"'), int(m["ParentUiMapID"]), int(m["Type"]), ", ".join(parts)))
    out.append("}")
    with open(os.path.join(HERE, "world.lua"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out) + "\n")
    print("wrote world.lua: %d maps" % len(rows("UiMap")))


if __name__ == "__main__":
    main()
