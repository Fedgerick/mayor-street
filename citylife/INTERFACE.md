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
- `signal officer_fired(pos: Vector3)`: an officer took a shot from `pos` (hit or miss), for gunshot audio.
- `seen`, `last_seen`, `cop_count()`, `officer_count()`, `siren_list()` (for siren audio: `[pos, fwd]` per car).
- Dispatch: cars by stars `[0, 1, 2, 3, 5, 6]`, at most 6 cars and 8 officers. Cars come from the nearest station: `CityServices.police_stations()` (each station's `road` point), read from `Progress.get_section("services")` or handed over with `life.set_services(services)`; else catalog buildings tagged `police`; else one stub station at the city centre. Stations are re-read every 2 s. If no station is within 520 m, a patrol car turns up out of sight nearby.
- Line of sight is grid-based: any building tile between a cop and the suspect blocks it; range 75 m.

Crowd and traffic:
- `life.report_crime(pos, severity)`, with severity 1 for a punch up to 3 for gunfire: people nearby run away.
- `life.traffic.nearest_car(pos, radius)` and `life.traffic.take_car(car) -> {xform, model, tint}` for carjacking; the driver jumps out and runs.
- Traffic pulls over and stops for cop cars running sirens; cop cars drive down the centre line.
- Garbage trucks (green, `car_truck`) run 6:00 to 15:00, 1 to 4 per city, starting at `CityServices.garbage_depots()` (else buildings tagged `garbage_depot`) when they exist, and stop along blocks to collect.

Tests: `res://citylife/tests/test_police.gd`.

## Round 3: people with lives, buses, weather

Nothing new is needed to get street life: CityLife makes it all in `setup()`.

- `life.spots` (StreetSpots): benches and bus shelters on the sidewalks, worked out from the city (straight road tiles, more by shops, parks and nightlife) and stable between runs. Rebuilt after road edits and once a game day. Each `Spot` has `kind` (`StreetSpots.Kind.BENCH` or `STOP`), `cell`, `side`, `xform` (the prop's transform, local +Z toward the road) and `seats` / `stands`. The props are drawn here from `assets/kit/props/bench.glb` and `bus_stop.glb` (two draw calls, hidden above 120 m). **For the street dresser:** read `life.spots.spots` to know where they stand, and set `life.spots.show_props = false` if you draw them yourself.
- People (Crowd): sit on benches, wait at stops (seated in the shelter or standing beside it) and get on the bus, stand in groups of 2 or 3 chatting, walk along on their phones, walk dogs, and step around benches, shelters and groups. Shares follow the hour: commuters at 7:00-9:30 and 16:30-18:30 hurry and rarely sit, lunch fills the benches, late at night people gather near clubs, the casino and other `nightlife` buildings.
- `life.report_crash(pos, severity := 1) -> int`: a crash at pos. People within 6-10 m jump clear, people within 30-46 m stop and stare for a few seconds, some filming on their phones. Returns how many stopped. **For the player and car threads:** call it when the player's car hits something hard.
- `crowd.gawk(pos, radius)`, `crowd.board(spot, door)`, `crowd.alight(spot, door, n)`, `crowd.spawn_group(cell)` are the pieces behind the above.
- Buses (Traffic): `traffic.spawn_bus(cell)`, `traffic.bus_count()`, `signal bus_stopped(car, stop)`. They run 5:30 to midnight, about one for every five stops in view, pull in to the kerb at stops for 9 s, and people get on and off. They use the Kit mesh `car_bus` when the car kit has one, else a built-in 10.5 m bus. Buses can be carjacked like any car.
- `life.set_weather(weather)`: hand over the Weather (weather/weather.gd). Rain thins the crowd by up to 40 %, puts umbrellas up (`crowd.umbrella_count()`), keeps people off wet benches, sends more to the bus shelters, and makes drivers slow down 15 % and leave longer gaps on wet roads.

Poses in the cheap crowd's shader (`ped.gdshader`, INSTANCE_CUSTOM.y = stride + 4 * pose): 1 sitting, 2 phone, 3 chatting, 4 umbrella, 5 dog lead. The full CharacterModel heroes sit with `set_sitting(true)`; the rebuilt people from the Street-level player thread can take over phone, talking and umbrella poses when their animations exist.
