"""Copies FarstriderLib and FarstriderLibData (the travel pathfinder: flight paths, boats,
zeppelins, the tram, hearthstone) into Libs/, WoW Forever's files only.

Usage: python tools/vendor_farstrider.py [AddOns folder]
  The AddOns folder holds an installed FarstriderLib and FarstriderLibData (CurseForge, or
  https://github.com/Deathwing/FarstriderLib). Default: the folder Explorer is installed in.

One change is made to each copied .lua file. As addons of their own, the two packages each
get a private table from the game (`local _, FarstriderLib = ...`). Inside Explorer every
file gets Explorer's table, where their keys would collide with Explorer's (both have an
`Areas`). So that first line is rewritten to take a table of their own from
Libs/Farstrider.lua: NS.FarstriderLib and NS.FarstriderLibData. Nothing else is touched.

Other copies on the machine (WaypointUI installs them as addons) are fine: the library
picks the newest copy at load and the others stand down.
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME = "Camelot"   # the library's name for WoW Forever's data

LIB_FILES = ["FarstriderLib.xml", "FarstriderLib~Init.lua", "FarstriderLib~Data.lua", "FarstriderLib~Stub.lua",
             "FarstriderLib~NavNode.lua", "FarstriderLib~Pathfinding.lua", "FarstriderLib~Core.lua",
             "FarstriderLib~Finalizer.lua", "LICENSE", "README.md", "CHANGELOG.md"]
DATA_FILES = ["FarstriderLibData_%s.xml" % GAME, "FarstriderLibData~Init.lua", "FarstriderLibData~Config.lua",
              "FarstriderLibData~Util.lua", "FarstriderLibData~Taxi.lua", "FarstriderLibData~Connections.lua",
              "FarstriderLibData~Finalizer.lua", "LICENSE", "README.md", "CHANGELOG.md"]
DATA_DIRS = ["Locale", "Areas/" + GAME, "Waypoints/" + GAME, "Instances/" + GAME, "Taxi/" + GAME]

HEADER = re.compile(r"^local _, (FarstriderLib(?:Data)?) = \.\.\.[ \t]*$", re.M)


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not src.endswith(".lua"):
        shutil.copyfile(src, dst)
        return 0
    text = open(src, encoding="utf-8", newline="").read()
    text, n = HEADER.subn(lambda m: "local %s = select(2, ...).%s" % (m.group(1), m.group(1)), text)
    open(dst, "w", encoding="utf-8", newline="").write(text)
    return n


def version(path, pattern):
    m = re.search(pattern, open(path, encoding="utf-8").read(), re.M)
    return m.group(1) if m else "?"


def main():
    addons = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(ROOT)
    lib, data = os.path.join(addons, "FarstriderLib"), os.path.join(addons, "FarstriderLibData")
    for d in (lib, data):
        if not os.path.isdir(d):
            sys.exit("not found: " + d)

    out_lib, out_data = os.path.join(ROOT, "Libs", "FarstriderLib"), os.path.join(ROOT, "Libs", "FarstriderLibData")
    for d in (out_lib, out_data):
        shutil.rmtree(d, ignore_errors=True)

    files, rewritten, unpatched = 0, 0, []

    def take(src, dst):
        nonlocal files, rewritten
        n = copy(src, dst)
        files += 1
        rewritten += n
        if src.endswith(".lua") and n != 1:
            unpatched.append(os.path.relpath(src, addons))

    for f in LIB_FILES:
        take(os.path.join(lib, f), os.path.join(out_lib, f))
    for f in DATA_FILES:
        take(os.path.join(data, f), os.path.join(out_data, f))
    for d in DATA_DIRS:
        for base, _, names in os.walk(os.path.join(data, d)):
            for name in names:
                src = os.path.join(base, name)
                take(src, os.path.join(out_data, os.path.relpath(src, data)))

    print("FarstriderLib %s, FarstriderLibData %s: %d files copied, %d namespace lines rewritten" % (
        version(os.path.join(lib, "FarstriderLib.toc"), r"^## Version: (.+)$").strip(),
        version(os.path.join(data, "FarstriderLibData.toc"), r"^## Version: (.+)$").strip(), files, rewritten))
    if unpatched:
        sys.exit("these .lua files don't start the way the rewrite expects; check them:\n  " + "\n  ".join(unpatched))


if __name__ == "__main__":
    main()
