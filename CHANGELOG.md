# Changelog

## 0.10.0

The other faction's boats, as a last resort.

- A Horde character had no way to Teldrassil (0.9.1 said so). The only way there is the Alliance's: the boat from Auberdine to Rut'theran Village, then the portal up to Darnassus. Where your own roads and rides get nowhere, the route now takes the other faction's boats and zeppelins and the rides 0.9.1 closed, as few of them as will do. For the Horde that is those two, for Teldrassil, and nothing else: no boat from Menethil Harbor, no tram. The Alliance has a way everywhere and never needs it.
- Such a ride says whose it is: "Take the boat from Auberdine to Rut'theran Village (Alliance)". The zone's row in the window reads "only by Alliance rides", and so does the next stop's line.
- Teldrassil goes where its travel time puts it, after Darkshore, not last.
- New setting, on by default: "Use the other faction's boats where nothing else goes". Off, Teldrassil goes last for the Horde and is marked "no way there", as in 0.9.1.
- The rides come from the bundled FarstriderLib, which only loads a faction's own. `tools/build_rides.py` loads it once as each faction and writes what the other one is offered to `Rides.lua`.
- The window is one row taller for the new setting.

Not checked in game: that a Horde character can board at Auberdine on WoW Forever, as on Classic. If the guards or the boat say no, turn the setting off.

## 0.9.1

Faction, for flight masters, boats, zeppelins and the tram.

- The route only rides what your faction can. Flight masters and most boats were already sorted by faction (by the bundled FarstriderLib). Now a ride that starts or ends inside a capital of the other faction is closed as well. That shuts the Deeprun Tram for the Horde: it was open to everyone, and came up on a Horde character's way from Durotar to Dun Morogh. It also shuts the portal from Rut'theran Village up to Darnassus for the Horde.
- Where there is no way to a zone, the route says so. A Horde character has no road to Teldrassil and nothing of the Horde's to ride there. The route used to make up a walk from the bird's distance, put Teldrassil right after Darkshore and point the arrow across the sea. Now Teldrassil comes last in the route, the window marks it "no way there", and the arrow says "No way there for the Horde: no road, flight or boat".
- A stop in your own zone that you can only ride to gets its ride. For the Alliance, Rut'theran Village and the rest of Teldrassil are joined by the portal.
- The flight masters weighed for a trip are checked against your faction, whatever the saved list of known ones says.
- New test: every journey between two zones (1,806 of them) with no flight master known, with your faction's, and with every one there is, once as Alliance and once as Horde. It runs against the game's real map bounds and the real bundled pathfinder, where the tests before it used a made-up world, a stand-in pathfinder and an Alliance character only. No journey rides anything of the other faction's.

## 0.9.0

Two reports from players, and what was behind them.

**"It told me to fly to Un'Goro to get to Thousand Needles."**

- Flights were picked by straight-line distance from where they land. Marshal's Refuge is 1,150 yards from Highperch as the bird flies and over 10,000 on foot, round the crater wall. Now there is one rule for every journey: the walk to a flight master you know, the flight, and the walk from where it lands, against walking all the way. Both walks are real walks over the ground. The same rule orders the zones.
- Every flight master has its way onto the roads worked out, as every pin has.
- The walking data is now built from AzerothGPS's full data (1.3.14): its roads with the course each one takes, its bridges and its caves and tunnels. Before, Explorer had only which junctions a road joins, worked the courses out itself, and joined the network's separate pieces by crossing blocked ground where it was thinnest. One of those joins went over the wall of Un'Goro Crater. Now a bridge's floor and a tunnel's floor are open ground, roads are only ever joined over open ground, and a road that stops and carries on across a short gap (Thandol Span) is joined straight.

**"It said Silithus was completely discovered, and it wasn't."**

- A zone the game gave no usable challenge data for could show as done. It now shows as unknown.
- Progress has a second source. Each area takes the challenge's tick where the challenge reports it, and the character's own map (what's revealed on it) where it doesn't.
- Areas are matched to the challenge by ID, then by name in your client's language, so a non-English client no longer depends on the order the game lists them in.
- `/ep check` prints what the game reports for the zone you're in (or the zone whose map is open), area by area, and where the challenge and your map disagree. If a zone ever reads wrong, that output says why.
- An "explored" popup or chat line only fires for the zone you're in.
- Four pins moved to where the current map has them (Gnomeregan side of Dun Morogh, Tirisfal, Moonglade).

## 0.8.1

The walking data was checked zone by zone (every walk between two pins of a zone, 3,806 of them) and fixed where it came up short.

- **Every pin has a way to a road.** Five had none (Plaguemist Ravine, Altar of Storms, Land's End Beach, Tower of Eldara, Ravencrest Monument) and got a straight line.
- **Pins in canyons, caves and tunnels.** The terrain data marks those as blocked ground, the same as a cliff. Such a pin was sent out to the nearest open ground and back in; it now goes straight to the road across as little blocked ground as will do.
- **Nearby pins go round, not the long way.** Two pins close together with something between them were sent by road, sometimes many times the distance. 377 such pairs now have a walk of their own round the obstacle.
- **Lines keep clear of blocked ground.** A stretch that grazed the corner of blocked ground could count as blocked, which made the arrow point at a nearer spot than it needed to.
- After this, 2 of the 3,806 walks have a stretch over blocked ground away from the roads (Blackrock Mountain to Blackrock Stronghold, Gordunni Outpost to Camp Mojache). `tools/test/sweep.py` runs the check.

## 0.8.0

Fixes the route cutting through cliffs (reported in Mount Hyjal), and adds flights inside a zone.

- **Roads keep their shape.** The road data only says which junctions a road joins, so a winding mountain road was drawn, and followed, as a straight line through the mountain. Explorer now works out where each such road runs from the terrain, and follows that: 1,158 roads got their bends.
- **Pins join the road over real ground.** The walk from each pin to the road is worked out the same way, where before it was a straight line from the nearest junction. A pin the terrain closes off (a plateau, a cave mouth) gets the way that crosses the least blocked ground, which is where the ramp or bridge is.
- **Getting onto the road from where you stand.** When no straight line gets you to a road (in a canyon, behind a ridge), Explorer searches the ground around you for the way.
- **The road network is joined up.** The data's roads came in separate pieces, so some stops had no route at all. The pieces are now linked, and roads that pass close to each other are joined where the ground between them is open.
- **Flights inside a zone.** For a long walk within one zone, the arrow sends you to a flight master when flying is clearly quicker (under 80% of the walk's time) and you know both flight points.

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
