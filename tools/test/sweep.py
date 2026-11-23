"""Checks the walking data zone by zone: the walk between each two pins of a zone, against the terrain grid.

Usage: python tools/test/sweep.py [folder holding lupa]
  Needs tools/.cache (python tools/build_data.py fills it) for the maps' bounds.

For every pair of pins in a zone it asks Nav.lua for the way, as the route does, and looks at:
  no way     nothing found (the route then guesses a straight line)
  off-road   how much of the walk is over ground the grid has blocked, not counting the
             stretch along AzerothGPS's own roads (those run through tunnels and over bridges
             the grid has blocked, and are right all the same). What's left is the way from a
             pin to the road and walks between two nearby pins: guesses where the grid closes
             a pin off.
  detour     the walk against the bird's distance

Run it after rebuilding Nav/ (tools/build_nav_data.py or tools/shape_nav.py) to see what changed.
"""
import csv
import os
import re
import sys

if len(sys.argv) > 1:
    sys.path.insert(0, sys.argv[1])
import lupa.lua51 as lua

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE)).replace("\\", "/")

bounds = {}
with open(os.path.join(ROOT, "tools", ".cache", "UiMapAssignment.csv"), encoding="utf-8-sig", newline="") as f:
    for r in sorted(csv.DictReader(f), key=lambda r: int(r["OrderIndex"])):
        if (r["UiMin_0"], r["UiMin_1"], r["UiMax_0"], r["UiMax_1"]) == ("0", "0", "1", "1"):
            bounds.setdefault(int(r["UiMapID"]), (int(r["MapID"]), float(r["Region_4"]), float(r["Region_1"]),
                                                  float(r["Region_3"]), float(r["Region_0"])))
data = open(os.path.join(ROOT, "Data.lua"), encoding="utf-8").read()
zones = re.findall(r"^  \{(\d+), (\d+), ([\d, ]+)\}, -- Explore (.*?) \(", data, re.M)

rt = lua.LuaRuntime(unpack_returned_tuples=True)
g = rt.globals()
g.ROOT = ROOT
rt.execute('''
NS = {}
for _, f in ipairs({ "Data.lua", "Nav/Terrain.lua", "Nav/Roads.lua", "Nav/Shapes.lua", "Nav.lua" }) do
  local fh = assert(io.open(ROOT .. "/" .. f, "rb")); local src = fh:read("*a"); fh:close()
  assert(loadstring(src, "=" .. f))("Explorer", NS)
end
local Nav = NS.Nav
local BAD_SHARE, BAD_YARDS = 0.15, 120

function Zone(inst, left, right, top, bottom, overlays)
  local pins = {}
  for o in overlays:gmatch("%d+") do
    local a = NS.Areas[tonumber(o)]
    pins[#pins + 1] = { o = tonumber(o), name = a[4], x = top + a[3] / 100 * (bottom - top), y = left + a[2] / 100 * (right - left) }
  end
  if not Nav.Knows(inst) then return -1 end
  local n, none, direct, hops, bad, worst = 0, 0, 0, 0, 0, 0
  local ratios, far, farPair, tally = {}, 0, "", {}
  local loose = 0
  for _, p in ipairs(pins) do if not Nav.Approach(inst, p.o) then loose = loose + 1 end end
  for i = 1, #pins do
    local a = pins[i]
    local ctx = Nav.From(inst, a.x, a.y, Nav.Approach(inst, a.o))
    for j = i + 1, #pins do
      local b = pins[j]
      n = n + 1
      local yards, how, pts, roadFrom, roadTo = ctx.Path(b.x, b.y, Nav.Approach(inst, b.o))
      local bird = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
      if not yards then
        none = none + 1
      else
        if how == "direct" then direct = direct + 1 elseif how == "hop" then hops = hops + 1 end
        local line = { { a.x, a.y } }
        for k = 1, #pts - 1, 2 do line[#line + 1] = { pts[k], pts[k + 1] } end
        line[#line + 1] = { b.x, b.y }
        -- the stretch on the roads: line[first] .. line[last]
        local first, last = roadFrom and (roadFrom + 1) / 2 + 1, roadTo and (roadTo + 1) / 2 + 1
        local total, blocked = 0, 0
        for l = 2, #line do
          local p, q = line[l - 1], line[l]
          local d = math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2)
          total = total + d
          local onRoad = first and l - 1 >= first and l <= last
          if not onRoad and not Nav.Segment(inst, p[1], p[2], q[1], q[2]) then blocked = blocked + d end
        end
        local share = total > 0 and blocked / total or 0
        if share > BAD_SHARE and blocked > BAD_YARDS then
          bad = bad + 1
          tally[a.name] = (tally[a.name] or 0) + 1
          tally[b.name] = (tally[b.name] or 0) + 1
        end
        if share > worst then worst = share end
        local ratio = yards / math.max(bird, 1)
        ratios[#ratios + 1] = ratio
        if ratio > far and bird > 150 then far, farPair = ratio, a.name .. " - " .. b.name end
      end
    end
  end
  table.sort(ratios)
  local names = {}
  for name, c in pairs(tally) do names[#names + 1] = { name, c } end
  table.sort(names, function(x, y) return x[2] > y[2] end)
  local top3 = {}
  for k = 1, math.min(3, #names) do top3[k] = names[k][1] .. " x" .. names[k][2] end
  return n, none, direct, hops, bad, worst, ratios[math.ceil(#ratios / 2)] or 0, far, farPair, table.concat(top3, ", "), #pins, loose
end
''')

print("%-22s %4s %5s %6s %6s %5s %8s %6s %6s %6s" % ("zone", "pins", "pairs", "no way", "direct", "hops", "off-road", "worst", "median", "detour"))
tot = [0, 0, 0, 0, 0]
for ach, m, overlays, name in zones:
    b = bounds.get(int(m))
    res = g.Zone(b[0], b[1], b[2], b[3], b[4], overlays) if b else None
    if not isinstance(res, tuple):
        print("%-22s %s" % (name[:22], "no walking data for its continent" if res == -1 else "no map bounds"))
        continue
    n, none, direct, hops, bad, worst, med, far, far_pair, culprits, pins, loose = res
    tot[0] += n; tot[1] += none; tot[2] += bad; tot[3] += direct; tot[4] += hops
    notes = []
    if bad:
        notes.append(culprits)
    if far > 6:
        notes.append("%.0fx: %s" % (far, far_pair))
    if loose:
        notes.append("%d pins with no way to a road" % loose)
    print("%-22s %4d %5d %6d %6d %5d %8d %5.0f%% %6.2f %6.1f  %s" % (
        name[:22], pins, n, none, direct, hops, bad, worst * 100, med, far, "; ".join(notes)))
print("total: %d pairs; %d with no way; %d with a blocked stretch off the roads; %d direct; %d by a walk worked out between two pins" % tuple(tot))
