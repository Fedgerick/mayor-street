# Mayor / Street

SimCity meets GTA, built in Godot 4.5 (Forward+). Design doc: `../design/core-loop.md`.

## Play it

**Windows installer:** download `builds/MayorStreet-Setup.exe` from the project files and run it. It installs for
your account only (no admin rights) into `%LOCALAPPDATA%\Programs\MayorStreet`, adds a Mayor Street icon to the
desktop and Start menu, and can be removed from Apps & features. It isn't code-signed, so Windows SmartScreen
warns the first time: click More info, then Run anyway.

**Windows, no install:** download `builds/MayorStreet-sandbox-windows.zip`, unzip, double-click `MayorStreet.exe`.

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
| Graphics | Low / Med / High buttons on the left. Med suits a Ryzen 5700U; High adds reflections, softer shadows and bounce light at full resolution |
| Menu | Esc (once it has dropped any build tool) pauses and opens the menu: resume, full screen or window, quit, and every control. Start on a gamepad |
| Full screen | F11 or Alt+Enter switch between full screen and a window, anywhere in the game |
| Music | M toggles music on and off |
| Frame rate | F3 shows fps, draw calls and triangles (works on the street too) |

## Street level

Press **Tab** in the mayor view to dive down to a character on the sidewalk under the camera, and Tab again to fly
back up. Time runs at 1x while you're on the street.

| | |
|---|---|
| Move / sprint / jump | WASD, Shift, Space |
| Look | Mouse |
| Get in / out of a car | E or F near a car |
| Drive | W/S throttle and brake, A/D steer, Space handbrake, H horn, R puts the car back on its wheels. Headlights come on by themselves |
| Menu | Esc pauses and frees the cursor; Resume grabs it again |
| Gamepad | Left stick move, A jump, Y car, Back switches view, Start opens the menu |

Cars, trucks and pedestrians fill the streets around the camera (`citylife/`), with working signals at junctions.
They are scenery for now: they don't collide with you or react to you. The parked cars you can drive and the
buildings do collide.

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
- `scripts/game_menu.gd` the Esc menu, the corner key hint and full screen switching. Keys that must always work
  (Tab, Esc, F11, Alt+Enter) are read in `_input`, ahead of the HUD, and HUD buttons never take keyboard focus
- `tools/blender/build_kit.py` generates `assets/kit/**.glb` (`pip install bpy`, then `python3 tools/blender/build_kit.py`,
  then `python3 art/tools/build_extra.py` for the art thread's pieces). Glass gets per-pane UVs for the window interiors;
  panes under 1.06 m tall or 0.2 m wide (balcony rails, glass edges) draw as frosted glass instead
- `tools/icon/make_icon.py` draws `assets/icon/` (game, exe and shortcut icon) and the installer's side panel
- `tools/installer/` builds the installer from an exported exe: `bash tools/installer/build.sh MayorStreet.exe [out_dir]`
  (needs NSIS: `apt-get install nsis`). Test it on Linux with 64-bit Wine: `wine64 MayorStreet-Setup.exe /S`
- `player/`, `citylife/`, `art/` are owned by their own threads

## Checks

```
godot --headless --path . --script res://tests/run_tests.gd
godot --headless --path . --fixed-fps 60 --script res://tests/input_test.gd   # Tab, Space, Esc after HUD clicks
godot --path . -- --demo --hour=21 --screenshot=night.png   # render a frame and quit
godot --path . -- --demo --shots=shots --nohud              # render the look-dev views (--only=day,night) and quit
godot --headless --path . --script res://tests/bench.gd -- --demo   # script cost per frame, mayor views and on foot
```
