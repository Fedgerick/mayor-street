# Mayor Street (Roblox)

The Roblox fork of Mayor Street Planet (msp). Mayor mode plus street mode: build a city from
above, then walk, sit and drive in it. Written in Luau; the code lives here and is synced into
Roblox Studio as a place file (or live with Rojo).

This branch is separate from the Godot game: nothing here touches `main` (ms) or the msp branch.

## Play it

1. Install Roblox Studio (free, roblox.com/create) and sign in.
2. Open `MayorStreetRoblox.rbxlx` (double-click it, or File > Open from File in Studio).
3. Press Play (F5).

Controls: WASD to walk, Shift to run, E by a car to drive (W/S, A/D, Space to get out),
walk into a bench to sit. M switches to the mayor view: 1 road, 2 homes, 3 shops, 4 industry,
5 bulldoze, drag with the left mouse to build, WASD to pan, Q/E to turn, wheel to zoom,
P to pause.

Saving uses a DataStore, which only works once the place is published (File > Publish to
Roblox) and, in Studio, with Home > Game Settings > Security > "Enable Studio Access to API
Services" turned on. Without it the game runs, it just doesn't save.

## Layout

| Path | In Roblox | What |
| --- | --- | --- |
| `src/shared/Grid.luau` | ReplicatedStorage.Shared.Grid | Map size, cell maths, road paths |
| `src/server/City.luau` | ServerScriptService.City | The city sim (port of msp `scripts/city.gd`) |
| `src/server/CityRenderer.luau` | ServerScriptService.CityRenderer | Terrain, roads, lamps, benches, buildings |
| `src/server/Vehicles.luau` | ServerScriptService.Vehicles | Drivable cars |
| `src/server/Saves.luau` | ServerScriptService.Saves | DataStore saves |
| `src/server/Main.server.luau` | ServerScriptService.Main | Start-up, clock, mayor orders, lighting |
| `src/client/Mayor.client.luau` | StarterPlayerScripts.Mayor | HUD and mayor view |
| `src/client/StreetPlayer.client.luau` | StarterPlayerScripts.StreetPlayer | Running and driving |

## Building the place file

`python3 tools/build_place.py` writes `build/MayorStreetRoblox.rbxlx` from `src/` (same layout
as `default.project.json`). With Rojo installed, `rojo serve` plus the Rojo Studio plugin syncs
live instead, and `rojo build -o MayorStreetRoblox.rbxlx` does the same as the script.

Tests: `lune run tests/city_test.luau` runs the city sim outside Roblox.
