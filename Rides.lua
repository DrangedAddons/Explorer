-- For each faction, the boats and zeppelins only the other one is offered: a last resort,
-- for where nothing else gets to a zone (Route.lua, "Whose rides"). Written by
-- tools/build_rides.py from the bundled FarstriderLib, loaded once as each faction.
local _, NS = ...

-- [1 for the Alliance, 2 for the Horde] = { { seconds, both ways, end, end }, ... }
-- end = { FarstriderLib's text for boarding here, continent, x, y, z, { area, "its name", ... } }
-- World yards: x runs north, y west. The areas fill in the text, in order.
NS.Rides = {
  [1] = {   -- for the Alliance: the Horde's
    { 600, true, { 1004, 0, 2070.5, 289.2, 97.0, { 1497, "Undercity", 1637, "Orgrimmar" } }, { 1004, 1, 1321.5, -4649.6, 0.0, { 1637, "Orgrimmar", 1497, "Undercity" } } },   -- Take the zeppelin from Undercity to Orgrimmar
    { 600, true, { 1004, 0, 2059.9, 235.9, 99.8, { 1497, "Undercity", 117, "Grom'gol Base Camp" } }, { 1004, 0, -12396.4, 217.5, 1.7, { 117, "Grom'gol Base Camp", 1497, "Undercity" } } },   -- Take the zeppelin from Undercity to Grom'gol Base Camp
    { 600, true, { 1004, 1, 1362.1, -4636.4, 0.0, { 1637, "Orgrimmar", 117, "Grom'gol Base Camp" } }, { 1004, 0, -12451.4, 219.8, 0.0, { 117, "Grom'gol Base Camp", 1637, "Orgrimmar" } } },   -- Take the zeppelin from Orgrimmar to Grom'gol Base Camp
  },
  [2] = {   -- for the Horde: the Alliance's
    { 600, true, { 1003, 0, -3831.0, -611.0, 4.0, { 150, "Menethil Harbor", 442, "Auberdine" } }, { 1003, 1, 6448.0, 835.0, 5.0, { 442, "Auberdine", 150, "Menethil Harbor" } } },   -- Take the boat from Menethil Harbor to Auberdine
    { 600, true, { 1003, 1, 6582.3, 767.1, 0.0, { 442, "Auberdine", 702, "Rut'theran Village" } }, { 1003, 1, 8546.1, 1019.3, 0.0, { 702, "Rut'theran Village", 442, "Auberdine" } } },   -- Take the boat from Auberdine to Rut'theran Village
    { 600, true, { 1003, 0, -3863.4, -653.0, 0.0, { 150, "Menethil Harbor", 513, "Theramore Isle" } }, { 1003, 1, -4005.2, -4729.3, 0.0, { 513, "Theramore Isle", 150, "Menethil Harbor" } } },   -- Take the boat from Menethil Harbor to Theramore Isle
  },
}
