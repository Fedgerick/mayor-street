# Mayor / Street

SimCity meets GTA, built in Godot 4.5 (Forward+). Design doc: `../design/core-loop.md`.

## Play it

**Windows, no install:** download `builds/MayorStreet-sandbox-windows.zip` from the project files, unzip, double-click `MayorStreet.exe`.

**From source (any OS):**
1. Install Godot 4.5.1 (standard build, not .NET) from https://godotengine.org/download.
2. Copy this `game` folder to your PC, open Godot, click Import, pick `project.godot`.
3. The first open imports the art (a minute or two). Press F5 to play.

## Mayor view controls

| | |
|---|---|
| Pan | WASD / arrows, or hold middle mouse and drag |
| Rotate / tilt | Q / E, or hold right mouse and drag |
| Zoom | Mouse wheel (zooms toward the cursor) |
| Tools | 1 Inspect, 2 Road, 3 Residential, 4 Commercial, 5 Industrial, 6 Bulldoze |
| Build | Click and drag. Roads draw an L-shape, zones and bulldoze a rectangle. Esc or right-click cancels |
| Overlays | O cycles zones / traffic / land value |
| Time | Space pause, `,` `.` slower/faster (1x, 3x, 10x), N skips an hour |
| Graphics | Low / Med / High buttons on the left (start on Med for a Ryzen 5700U) |
| F11 | Toggle fullscreen |
| Music | M toggles music on and off |

## Street level

Press **Tab** in the mayor view to dive down to a character on the sidewalk under the camera, and Tab again to fly
back up. Time runs at 1x while you're on the street.

| | |
|---|---|
| Move / sprint / jump | WASD, Shift, Space |
| Look | Mouse (Esc frees the cursor, click to grab it again) |
| Get in / out of a car | E or F near a car |
| Drive | W/S throttle and brake, A/D steer, Space handbrake, H horn, L lights, R reset |
| Gamepad | Left stick move, A jump, Y car, Back switches view |

Cars, trucks and pedestrians fill the streets around the camera (`citylife/`), with working signals at junctions.

## How the city grows

Zones grow when a road is within 2 tiles and there is demand (the R C I bars). Homes need jobs, shops need shoppers,
industry needs workers. Buildings upgrade through 3 stages as the city grows and land value rises; downtown blocks
can merge into 2x2 skyscrapers.

## Layout

- `scripts/city.gd` the city data and simulation (no rendering, runs headless)
- `scripts/city_view.gd` renders terrain, sea and chunked MultiMeshes; owns the data textures shaders read
- `scripts/day_night.gd`, `shaders/sky.gdshader` sun, moon, sky, post-processing
- `scripts/kit.gd` loads the Blender kit and swaps materials for `shaders/kit.gdshader`
- `scripts/mayor_camera.gd`, `scripts/hud.gd`, `scripts/main.gd`
- `tools/blender/build_kit.py` generates `assets/kit/**.glb` (`pip install bpy`, then `python3 tools/blender/build_kit.py`)
- `player/`, `citylife/`, `art/` are owned by their own threads

## Checks

```
godot --headless --path . --script res://tests/run_tests.gd
godot --path . -- --demo --hour=21 --screenshot=night.png   # render a frame and quit
```
