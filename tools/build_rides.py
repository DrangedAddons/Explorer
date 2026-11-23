"""Writes Rides.lua: for each faction, the boats and zeppelins only the other one is offered.

Usage: python -I tools/build_rides.py [folder holding lupa]
  Run it again after tools/vendor_farstrider.py brings in a new FarstriderLib.

The bundled FarstriderLib decides by faction when it loads which boats and zeppelins it knows
(`if UnitFactionGroup("player") == "Alliance" then addBoat(...)`), so a Horde character's copy
has never heard of the boat from Auberdine to Rut'theran Village. Anyone can board it, though,
and it is the only way to Teldrassil. Explorer uses the other faction's rides as a last
resort, where nothing else gets to a zone (Route.lua, "Whose rides"), and for that it needs
them as data.

This loads the library twice in Lua 5.1 (lupa), once as each faction, against the stand-in
client the tests use (tools/test/mock.lua, real.lua), and keeps what one is offered and the
other isn't:

  - a ride has a fixed place at both ends, on the Eastern Kingdoms or Kalimdor (the continents
    Explorer has zones on)
  - flights are left out: a flight master only talks to its own faction
  - what needs a spell or an item (a mage's portals) is left out: its conditions fail here

Area names are read from tools/.cache/AreaTable.csv (tools/build_data.py fills it); in game
the client's own names are used, these are what's shown if it has none.
"""
import csv
import math
import os
import sys

if len(sys.argv) > 1:
    sys.path.insert(0, sys.argv[1])
import lupa.lua51 as lua

HERE = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")
ROOT = os.path.dirname(HERE).replace("\\", "/")
SAME = 150           # yards: two ends this close are the same landing
CONTINENTS = (0, 1)
SIDES = {"Alliance": 1, "Horde": 2}
KINDS = {1002: "portal", 1003: "boat", 1004: "zeppelin", 1008: "tram"}

COLLECT = r'''
dofile(HERE .. "/test/mock.lua")
HERE = HERE .. "/test"
dofile(HERE .. "/real.lua")
C_Map.GetAreaInfo = function(id) return "#" .. id end   -- so a ride's text gives its areas away
LoadWhole(ADDON_DIR, true)
OUT = {}
local function Passes(c)
    if c == nil then return true end
    local ok, v = pcall(c)
    return ok and v and true or false
end
local function End(side)
    local loc = side.loc
    if type(loc) ~= "table" then return nil end
    local inst, x, y = loc.mapId, loc.pos.x, loc.pos.y
    if loc.isUI then
        local v
        inst, v = C_Map.GetWorldPosFromMapPos(loc.mapId, CreateVector2D(loc.pos.x, loc.pos.y))
        if not inst then return nil end
        x, y = v.x, v.y
    end
    local areas = {}
    if side.locaArgs then
        local ok, args = pcall(side.locaArgs)
        if not ok then return nil end
        for _, a in ipairs(args) do
            local id = tostring(a):match("^#(%d+)$")
            if not id then return nil end   -- names something that isn't an area: an item, a spell
            areas[#areas + 1] = id
        end
    end
    local text = FarstriderLibData_API.GetLocalizedString(side.locaId)
    return { side.locaId, inst, x, y, loc.pos.z or 0, table.concat(areas, ","), tostring(text) }
end
for _, w in ipairs(FarstriderLibData_API.WAYPOINTS) do
    if type(w.from) == "table" and type(w.to) == "table" and w.from.locaId ~= 1001
        and Passes(w.condition) and Passes(w.from.condition) and Passes(w.to.condition) then
        local a, b = End(w.from), End(w.to)
        if a and b then
            OUT[#OUT + 1] = { w.cost, w.bidirectional and 1 or 0, a[1], a[2], a[3], a[4], a[5], a[6], a[7],
                b[1], b[2], b[3], b[4], b[5], b[6], b[7] }
        end
    end
end
'''


def offered(faction):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.ADDON_DIR, g.HERE, g.LOOK, g.FACTION = ROOT, HERE, "none", faction
    rt.execute(COLLECT)
    rides = []
    for r in g.OUT.values():
        v = list(r.values())
        rides.append({"seconds": v[0], "both": bool(v[1]),
                      "ends": [dict(zip(("loca", "inst", "x", "y", "z", "areas", "text"), v[2:9])),
                               dict(zip(("loca", "inst", "x", "y", "z", "areas", "text"), v[9:16]))]})
    return rides


def near(a, b):
    return a["inst"] == b["inst"] and math.hypot(a["x"] - b["x"], a["y"] - b["y"]) <= SAME


def same(r, s):
    (a, b), (c, d) = r["ends"], s["ends"]
    return (near(a, c) and near(b, d)) or (near(a, d) and near(b, c))


def main():
    names = {}
    table = os.path.join(HERE, ".cache", "AreaTable.csv")
    if not os.path.exists(table):
        sys.exit("no tools/.cache/AreaTable.csv: run tools/build_data.py first")
    with open(table, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            names[row["ID"]] = row["AreaName_lang"]
    rides = {faction: offered(faction) for faction in SIDES}

    out = ["-- For each faction, the boats and zeppelins only the other one is offered: a last resort,",
           "-- for where nothing else gets to a zone (Route.lua, \"Whose rides\"). Written by",
           "-- tools/build_rides.py from the bundled FarstriderLib, loaded once as each faction.",
           "local _, NS = ...",
           "",
           "-- [1 for the Alliance, 2 for the Horde] = { { seconds, both ways, end, end }, ... }",
           "-- end = { FarstriderLib's text for boarding here, continent, x, y, z, { area, \"its name\", ... } }",
           "-- World yards: x runs north, y west. The areas fill in the text, in order.",
           "NS.Rides = {"]
    for faction, side in SIDES.items():
        other = [f for f in SIDES if f != faction][0]
        kept = []
        # the library's own (text by area, in the client's language) before the ones from the game's tables
        for r in sorted(rides[other], key=lambda r: r["ends"][0]["loca"] < 1000):
            if not all(e["inst"] in CONTINENTS for e in r["ends"]):
                continue
            if any(same(r, s) for s in rides[faction]) or any(same(r, s) for s in kept):
                continue
            kept.append(r)
        out.append("  [%d] = {   -- for the %s: the %s's" % (side, faction, other))
        for r in kept:
            ends, told = [], []
            for e in r["ends"]:
                ids = [a for a in e["areas"].split(",") if a]
                missing = [a for a in ids if a not in names]
                if missing:
                    sys.exit("no name for area %s" % ", ".join(missing))
                areas = ", ".join('%s, "%s"' % (a, names[a].replace('"', '\\"')) for a in ids)
                ends.append("{ %d, %d, %.1f, %.1f, %.1f, { %s } }" % (e["loca"], e["inst"], e["x"], e["y"], e["z"], areas))
                told.append(e["text"] % tuple(names[a] for a in ids) if ids else e["text"])
            out.append("    { %d, %s, %s, %s },   -- %s" % (r["seconds"], "true" if r["both"] else "false", ends[0], ends[1], told[0]))
            print("%-8s %-8s %s" % (faction, KINDS.get(r["ends"][0]["loca"], "ride"), told[0]))
        out.append("  },")
    out.append("}")
    with open(os.path.join(ROOT, "Rides.lua"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out) + "\n")
    print("wrote Rides.lua")


if __name__ == "__main__":
    main()
