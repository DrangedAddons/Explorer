-- FarstriderLibData_Instances.lua
local FarstriderLibData = select(2, ...).FarstriderLibData

if not FarstriderLibData.Internal then return end

-- [instanceMapId] = entrance on its continent (uiMapHint: zone map to show it on), or { Alliance = entrance, Horde = entrance }
FarstriderLibData.Instances = {
  [33] = { mapId = 0, pos = { x = -228, y = 1576.7, z = 80.9 }, uiMapHint = 1421 },
  [34] = { mapId = 0, pos = { x = -8761.8, y = 848.6, z = 87.8 }, uiMapHint = 1453 },
  [36] = { mapId = 0, pos = { x = -11207.9, y = 1679.7, z = 24.1 }, uiMapHint = 1436 },
  [43] = { mapId = 1, pos = { x = -753.6, y = -2212.8, z = 21.5 }, uiMapHint = 1413 },
  [44] = { mapId = 0, pos = { x = 2892.4, y = -811.2, z = 0 }, uiMapHint = 1420 },
  [47] = { mapId = 1, pos = { x = -4455.1, y = -1655, z = 85 }, uiMapHint = 1413 },
  [48] = { mapId = 1, pos = { x = 4253.1, y = 757, z = -19.5 }, uiMapHint = 1439 },
  [70] = { mapId = 0, pos = { x = -6055.5, y = -2955, z = 220 }, uiMapHint = 1432 },
  [90] = { mapId = 0, pos = { x = -5155, y = 916.5, z = 287.4 }, uiMapHint = 1426 },
  [109] = { mapId = 0, pos = { x = -10170.1, y = -3996, z = 0 }, uiMapHint = 1435 },
  [129] = { mapId = 1, pos = { x = -4664.6, y = -2536.9, z = 82.7 }, uiMapHint = 1441 },
  [189] = { mapId = 0, pos = { x = 2892.2, y = -811.3, z = 0 }, uiMapHint = 1420 },
  [209] = { mapId = 1, pos = { x = -6790.9, y = -2891.9, z = 8.9 }, uiMapHint = 1446 },
  [229] = { mapId = 0, pos = { x = -7527.9, y = -1336.8, z = 290.7 }, uiMapHint = 1428 },
  [230] = { mapId = 0, pos = { x = -7176.6, y = -937.7, z = 170.2 }, uiMapHint = 1427 },
  [249] = { mapId = 1, pos = { x = -4768.6, y = -3752.1, z = 53.4 }, uiMapHint = 1445 },
  [269] = { mapId = 1, pos = { x = -8777.4, y = -4156.9, z = -190 }, uiMapHint = 1446 },
  [289] = { mapId = 0, pos = { x = 1274.8, y = -2552.6, z = 0 }, uiMapHint = 1422 },
  [309] = { mapId = 0, pos = { x = -11916.1, y = -1224.6, z = 0 }, uiMapHint = 1434 },
  [329] = { mapId = 0, pos = { x = 3392.5, y = -3389.2, z = 143.1 }, uiMapHint = 1423 },
  [349] = { mapId = 1, pos = { x = -1382, y = 2918.7, z = 73.2 }, uiMapHint = 1443 },
  [389] = { mapId = 1, pos = { x = 1818.4, y = -4427.3, z = -10.4 }, uiMapHint = 1454 },
  [409] = { mapId = 0, pos = { x = -7512.2, y = -1034.8, z = 177.2 }, uiMapHint = 1428 },
  [429] = { mapId = 1, pos = { x = -3822.6, y = 1249.9, z = 160.3 }, uiMapHint = 1444 },
  [469] = { mapId = 0, pos = { x = -7664.8, y = -1217.4, z = 289.3 }, uiMapHint = 1428 },
  [509] = { mapId = 1, pos = { x = -8114.5, y = 1526.4, z = 0 }, uiMapHint = 1451 },
  [531] = { mapId = 1, pos = { x = -8230.4, y = 2005.3, z = 129.9 }, uiMapHint = 1451 },
  [533] = { mapId = 0, pos = { x = 3133.1, y = -3730.3, z = 138.7 }, uiMapHint = 1423 },
  [2959] = { mapId = 0, pos = { x = 394.7, y = 546.5, z = 0 }, uiMapHint = 1416 },
  [2970] = { mapId = 0, pos = { x = -12351.4, y = 855.2, z = 0 }, uiMapHint = 1434 },
  [2974] = { mapId = 1, pos = { x = 4550.5, y = -5051.9, z = 0 }, uiMapHint = 1447 },
  [2994] = { mapId = 1, pos = { x = -2526.8, y = -4928.2, z = 0 }, uiMapHint = 1445 },
  [2998] = { mapId = 0, pos = { x = -3695.8, y = -2365.9, z = 0 }, uiMapHint = 1437 },
  [2999] = { mapId = 0, pos = { x = 1805.2, y = 178.5, z = 0 }, uiMapHint = 1458 },
  [3001] = { mapId = 1, pos = { x = -6117.1, y = -1246.4, z = 0 }, uiMapHint = 1449 },
  [3039] = { mapId = 0, pos = { x = -7669.5, y = -3710.4, z = 0 }, uiMapHint = 2548 },
  [3065] = { mapId = 0, pos = { x = -4821.6, y = -932, z = 0 }, uiMapHint = 1455 }
}
