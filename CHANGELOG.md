# Changelog

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
