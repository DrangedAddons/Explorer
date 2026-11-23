"""Loads the addon against mock.lua (a stand-in for the WoW frame API) and runs the tests.

Usage: python tools/test/run.py [folder holding lupa] [--quick] [--only smoke|factions]
  lupa: pip install lupa, or pip install lupa --target <folder> and pass the folder.

  smoke.lua     the addon's own logic against a made-up world, once for each look
  factions.lua  every journey between two zones against the real world (world.lua) with the
                real bundled pathfinder, once as Alliance and once as Horde. --quick: from five
                zones only.

The mock only proves the Lua runs and the logic holds; looks have to be checked in game.
"""
import os
import sys

argv = sys.argv[1:]
only = None
if "--only" in argv:
    at = argv.index("--only")
    only = argv[at + 1]
    del argv[at:at + 2]
quick = "--quick" in argv
argv = [a for a in argv if not a.startswith("--")]
if argv:
    sys.path.insert(0, argv[0])
import lupa.lua51 as lua

HERE = os.path.dirname(os.path.abspath(__file__)).replace("\\", "/")
ROOT = os.path.dirname(os.path.dirname(HERE)).replace("\\", "/")


def failed(script, **given):
    rt = lua.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.ADDON_DIR = ROOT
    g.HERE = HERE
    g.MOCK = HERE + "/mock.lua"
    g.LOOK = "none"
    for name, value in given.items():
        g[name] = value
    rt.execute(
        'local ok, err = xpcall(function() dofile("%s/%s") end, debug.traceback) '
        "if not ok then (Say or print)(err) FAILS = 999 end" % (HERE, script)
    )
    return g.FAILS != 0


bad = 0
if only in (None, "smoke"):
    for look in ("none", "eui"):
        bad += failed("smoke.lua", LOOK=look)
if only in (None, "factions"):
    for faction in ("Alliance", "Horde"):
        bad += failed("factions.lua", FACTION=faction, QUICK=quick)
print("runs failed:", bad)
sys.exit(1 if bad else 0)
