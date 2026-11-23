-- FarstriderLibData_Waypoints_esMX.lua
local FarstriderLibData = select(2, ...).FarstriderLibData

if not FarstriderLibData.Internal then return end

if (GetLocale() ~= "esMX") then
  return
end

FarstriderLibData.WaypointL = {
  [58] = "Salida a Forjaz",
  [59] = "Sube al tranvía",
  [60] = "Sube al tranvía",
  [68] = "Toma el bote de Bahía de Baradin a Isla Theramore",
  [69] = "Toma el bote de Isla Theramore a Puerto de Menethil",
  [72] = "Toma el bote de Bahía del Botín a Trinquete",
  [73] = "Toma el bote de Trinquete a Bahía del Botín",
  [80] = "Salida a Ventormenta",
  [162] = "Entrada al Tranvía Subterráneo",
  [163] = "Salida del Tranvía Subterráneo",
  [166] = "Toma la salida a Ventormenta",
  [167] = "Toma la salida a Forjaz",
  [222] = "Crea un portal a Ventormenta",
  [223] = "Crea un portal a Forjaz",
  [226] = "Crea un portal a Theramore",
  [227] = "Crea un portal a Orgrimmar",
  [228] = "Crea un portal a Entrañas",
  [229] = "Crea un portal a Cima del Trueno",
  [231] = "Crea un portal a Rocal",
  [237] = "Crea un portal a Dalaran - Antigua",
  [246] = "Ventormenta",
  [247] = "Forjaz",
  [250] = "Theramore",
  [254] = "Dalaran - Antigua",
  [260] = "Orgrimmar",
  [261] = "Entrañas",
  [262] = "Cima del Trueno",
  [264] = "Rocal"
}
