# City life: traffic and pedestrians

Entry point: `res://citylife/city_life.gd` (`class_name CityLife`, a `Node3D`).

```gdscript
var life := CityLife.new()
add_child(life)
life.setup(city, cam)          # City and the active Camera3D
# when the street-level player camera takes over (and back):
life.set_camera(player_cam)
```

What it reads from the sandbox (no changes needed there):
- `City.road`, `road_mask(x, y)`, `zone`, `buildings` + `capacity(b)`, `traffic` (commuter flow), `time_of_day()`.
- Signals `cells_changed` (roads rebuilt next frame), `building_added/removed`, `day_passed` (density refresh, throttled to every 4 s).
- The `Kit` autoload for car meshes and `Kit.CAR_TINTS`; `shaders/common.gdshaderinc` for `night` and street-lamp light on people.
- Road geometry from `tools/blender/build_kit.py`: 12 m tiles, 7.5 m asphalt, 0.17 m kerbs.

What it draws: cars (one MultiMesh per model), people (one MultiMesh, procedural mesh, vertex-shader walk cycle), and live signal heads on every junction approach.

Optional for the sandbox: `CityView._add_road` places a static `traffic_light` prop on every other junction. CityLife now draws working signal heads at each approach, so that prop can be dropped to avoid doubled poles.

Knobs: `max_cars` (220), `max_peds` (360), `density` (1.0) exports, set before `setup()`.

LOD: cars and people are only simulated around the camera. Street level fills about a 200 m radius; the mayor view widens to the whole island, drops people above 200 m camera height, and turns off car shadows above 140 m.

Tests: `godot --headless --path . --script res://citylife/tests/test_citylife.gd` (run on a scratch copy of the repo after `--import`).
