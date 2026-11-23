# Changelog

## 0.7.0

The route now goes by the ground and the roads, not as the bird flies.

- **Walks follow the terrain.** Explorer now knows where the ground is too steep, where there's water, where the walls are and where the roads run. A walk is a straight line when the ground allows it, and goes by road when it doesn't.
- **Stop order by real walks.** The stops in the zone you're in are ordered by walking distance. In Eastern Plaguelands that made the full loop about a fifth shorter than ordering by straight lines.
- **The arrow follows the road.** When the straight line to the next stop is blocked, the arrow points at the stretch of road ahead and shows the walk as "1.1k yd by road".
- **The map line follows the road.** The line between stops bends along the roads, and a green line shows the way from where you stand to the next stop.
- **Zone order** counts real walking distance between neighbouring zones.
- Roads are known junction to junction, so on a winding road the arrow cuts each bend's corner.
- A pin on ground the data says can't be reached (up a slope, on a roof, in a river) gets the road to the nearest junction and a straight line from there.

Terrain, walls and roads come from AzerothGPS's data, used with its author's permission and shipped inside Explorer. They cover the Eastern Kingdoms and Kalimdor.

## 0.6.0

Explorer now plans a route through everything you have left and points the way.

- **Route.** The areas left in your zone are ordered into a short path from where you stand. After that come the other zones, each time the one that is quickest to reach from the last, counting the flight paths you know, boats, zeppelins and the Deeprun Tram. Walk into another zone that has areas left and it moves to the front.
- **Arrow.** An arrow on screen points at the next stop and turns as you turn: green when you face it, red when it's behind you. Under it are the stop's name, the distance and the time at your current speed. When the stop is in another zone it points at the first thing to do on the way, such as "Talk to the Flightmaster to travel to Refuge Pointe". Click the arrow to set a waypoint on the stop, right-click to skip the stop, drag to move it, scroll on it to resize it.
- **On the map.** Pins are numbered in route order, a line joins a zone's stops, and the next stop has a green ring.
- **Settings.** "Route covers" picks the zone you're in, this continent, or everything. Zones more than 5 levels above you are left out unless you turn that off. The route and the arrow each have a switch. The window is now two columns, and lists the zones in route order.
- **Commands.** `/ep route` plans again from where you stand and prints the route. `/ep skip` passes over the current stop. `/ep arrow` shows or hides the arrow.
- **Nothing else to install.** The travel planning is done by FarstriderLib (by Savi and Deathwing), which now ships inside Explorer. Flight paths are only used once you've opened a flight master's map, because that is the only time the game says which ones you know.

Walking legs are straight lines: the route doesn't know about cliffs or walls between two stops.

## 0.5.1

- Eastern Plaguelands: all 22 pins were in the wrong places. Forever redrew this zone's map to a wider area (it now runs out to New Avalon), but the game's data still listed the areas at their spots on the old map. The pins are now worked out for the new map.
- Checked the other zones for the same fault: Mulgore and Redridge Mountains were also redrawn, and their pins were already right.

## 0.5.0

- Popup when an area is explored: a banner near the top of the screen with the area's name, its zone and the zone's new count ("Alterac Mountains 8/9"), plus a thin progress bar. It says "fully explored" on a zone's last area. Several areas at once show one after the other. The banner fades out after a few seconds and lets clicks through.
- "Sample" in the settings, or `/ep test`, shows a sample popup. Drag it to where popups should appear, scroll on it to make it bigger or smaller, right-click to put both back.
- Settings: "Show a popup when an area is explored". The chat line has its own switch as before.

## 0.4.0

- Zones you're not in: open a zone's map and its unexplored areas now show as small faint markers. They are see-through and sit under the full pins, so they don't cover the map. Hover one for the area's name, click it to set a waypoint.
- Continent maps are unchanged: only the zone you're in shows there, plus the "Explored 7/9" line when you hover a zone.
- Settings: "Zones I'm not in" picks between small markers (the default), full pins and nothing. It replaces "Pins for".

## 0.3.0

First release. The addon is now called Explorer (it was ExplorerPins while it was being built).

Explorer shows where you still have to go for the Legacy "Explore" challenges (Legacy Challenges > Adventure > Explorer).

- **The zone you're in:** a spyglass pin on the world map for every area the challenge hasn't ticked yet. Hover a pin for the area's name and the zone's count. Click it to set a waypoint (named in WaypointUI when that addon is loaded). Pins go away as areas get their tick.
- **Other zones:** hover a zone on the map and a line under its name says "Explored 7/9". Fully explored zones have no line.
- **OpenMap:** works on its stitched map at any zoom.
- **Chat line** when an area is explored, with the zone's new count.
- `/explorer` (or `/ep`) opens a window with progress for all 43 zones and the settings. `/ep next` sets a waypoint on the nearest unexplored area of your zone. `/ep list` prints what's left.
- Covers 549 areas, including Riverglades, Mount Hyjal and Shen'dralas.

## 0.2.0

- Pins now show only for the zone you're in. The dots for every other zone on the continent maps are gone.
- Other zones: hover a zone on the map and a line under its name says "Explored 7/9". A fully explored zone has no line.
- Settings: "Pins for" can be switched to "Any zone I zoom in on" to get the pins of zones you're looking at too. The "Explored 7/9" line has its own switch.
- OpenMap: pins show on its stitched map at every zoom. They were drawn underneath its close-up art. They are placed through OpenMap's own API: full pins once the zone fills a good part of the view, dots when zoomed out, nothing at whole-world zoom.
- Clicking any pin or dot sets a waypoint on it. Dots used to open the zone's map instead.
- Pins keep their size on screen while the map zooms, instead of catching up afterwards.

## 0.1.0

First version.

- A spyglass pin on the world map for every area you still have to visit for the Legacy "Explore <zone>" challenges. Areas the challenge already ticked get no pin.
- Small dots on the Eastern Kingdoms and Kalimdor maps show where the leftovers are. Click a dot to open that zone's map.
- Click a pin to set a map pin on it (named in WaypointUI when that addon is loaded).
- `/ep next` pins the nearest unexplored area of the zone you're in. `/ep list` prints what's left zone by zone.
- A window (`/ep`, minimap button) with progress per zone and the settings: zone pins, continent dots, chat line when an area is explored, pin size, window look.
- Covers 549 areas in 43 zones, including Riverglades, Mount Hyjal and Shen'dralas. Positions come from the game's own map tables (`tools/build_data.py`).
