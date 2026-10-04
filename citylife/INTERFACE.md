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

## Round 2: police, crowd reactions, garbage trucks

Wiring for main.gd (sandbox thread):

```gdscript
life.set_suspect(street)        # the player's wanted system, once player/ provides it
life.police.busted.connect(func(): street.on_busted())   # name is the player thread's call
```

The suspect object needs `wanted_stars: int`, `suspect_position() -> Vector3`, `suspect_velocity() -> Vector3`, `suspect_in_vehicle() -> bool`. Stars and their fading belong to player/.

`life.police` (class Police):
- `signal sighting_changed(seen: bool)`: a cop has, or lost, line of sight. Fade stars only while not seen.
- `signal busted()`: an officer held a slow or stopped suspect for 1.2 s.
- `seen`, `last_seen`, `cop_count()`, `officer_count()`, `siren_list()` (for siren audio: `[pos, fwd]` per car).
- Dispatch: cars by stars `[0, 1, 2, 3, 5, 6]`, at most 6 cars and 8 officers. Cars come from the nearest station (`City.service_sites("police")` or `("police_hq")` when the services thread provides it; until then one stub station at the city centre). If no station is within 520 m, a patrol car turns up out of sight nearby.
- Line of sight is grid-based: any building tile between a cop and the suspect blocks it; range 75 m.

Crowd and traffic:
- `life.report_crime(pos, severity)`, with severity 1 for a punch up to 3 for gunfire: people nearby run away.
- `life.traffic.nearest_car(pos, radius)` and `life.traffic.take_car(car) -> {xform, model, tint}` for carjacking; the driver jumps out and runs.
- Traffic pulls over and stops for cop cars running sirens; cop cars drive down the centre line.
- Garbage trucks (green, `car_truck`) run 6:00 to 15:00, 1 to 4 per city, starting at `service_sites("garbage")` depots when they exist, and stop along blocks to collect.

Tests: `res://citylife/tests/test_police.gd`.
