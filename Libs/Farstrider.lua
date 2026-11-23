-- FarstriderLib and FarstriderLibData (Libs\FarstriderLib*, by Savi and Deathwing, GPL-3.0) are
-- written as addons of their own, each with a private table from the game. Inside Explorer
-- they'd share Explorer's table, where their keys collide with Explorer's (both have an
-- "Areas"). tools/vendor_farstrider.py points each of their files at one of these instead.
local _, NS = ...
NS.FarstriderLib = NS.FarstriderLib or {}
NS.FarstriderLibData = NS.FarstriderLibData or {}
