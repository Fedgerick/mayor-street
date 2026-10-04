# vehicles/: the round-3 car kit

Twelve vehicles built by a Blender script, with see-through glass and a driver, real
wheels, working lights and sirens, three damage stages and three LODs. Owned by the Cars
thread.

| Model | What | Tint | Siren | LOD0 / LOD1 / LOD2 tris |
|---|---|---|---|---|
| car_sedan | four-door sedan (old axles kept) | yes | | 6.2k / 1.3k / 306 |
| car_hatch | hatchback (old axles kept) | yes | | 6.2k / 1.3k / 306 |
| car_sports | low two-seater | yes | | 6.0k / 1.3k / 306 |
| car_pickup | pickup with an open bed | yes | | 6.0k / 1.3k / 306 |
| car_van | panel van (old axles kept) | yes | | 6.0k / 1.3k / 308 |
| car_truck | box delivery truck, 3 axles (old axles kept) | yes (stripe) | | 6.7k / 1.5k / 360 |
| car_taxi | yellow cab, roof sign glows at night | fixed | | 6.3k / 1.3k / 318 |
| car_police | black-and-white cruiser, light bar, push bar | fixed | yes | 6.6k / 1.3k / 398 |
| car_ambulance | van cab with a box module | fixed | yes | 6.6k / 1.6k / 412 |
| car_firetruck | crew cab, lockers, ladder | fixed | yes | 7.7k / 1.7k / 426 |
| car_garbage | green garbage truck | fixed | | 7.1k / 1.6k / 346 |
| car_bus | 11.5 m city bus with passengers | fixed | | 7.9k / 1.5k / 368 |

Each car is **two draw calls** at LOD0 (body + glass) and **one** at LOD1 and LOD2: every
part's look is packed in the UVs and drawn by `shaders/vehicle.gdshader`.

## Files

- `tools/build_cars.py`: the generator. `python3 vehicles/tools/build_cars.py [-- car_taxi ...] [--out DIR]` (pip `bpy` 4.2).
- `assets/<model>.glb`, `<model>_lod1.glb`, `<model>_lod2.glb`, `<model>_dmg1..3.glb`, `assets/specs.json`.
- `vehicle_kit.gd` (class `VehicleKit`): loading, materials, specs, custom data, `install(kit)`.
- `shaders/vehicle.gdshader`, `shaders/vehicle_glass.gdshader`.
- `tests/test_vehicles.gd`: `godot --headless --path . -s res://vehicles/tests/test_vehicles.gd`.
- `tools/preview.gd`: look-dev shots (`--shots=DIR --only=gallery,closeup,damage,lods,night,police,service,lineup,old`).

## Wiring (City sandbox)

One line in `scripts/kit.gd`, at the end of `_ready()`:

```gdscript
VehicleKit.install(self)
```

After that `Kit.mesh("car_sedan")` and the other three old names return the new cars,
and every new name (`car_taxi`, `car_police`, ... plus `_lod1`, `_lod2`, `_dmg1..3`)
works too. The four old names keep the old axle positions and wheel radii, so
`DrivableCar`, traffic, police and chase cars keep working unchanged. The old
`assets/kit/cars/*.glb` can be deleted afterwards, along with the `car()` builder in
`tools/blender/build_kit.py`.

## Per-instance data (MultiMesh)

Cars are meant to be drawn through MultiMeshes with `use_colors` and `use_custom_data`,
as all the current code does:

- **COLOR**: paint tint for civilian models (ignored by fixed liveries).
- **CUSTOM**: `VehicleKit.custom(siren, brake, empty, lights, wheel_angle, steer, seed)`
  - `r` flags: 1 siren flashing, 2 brake lights, 4 empty (hides the driver and
    passengers: parked cars), 8 headlights on in daylight. Headlights and tail lights
    turn on by themselves at night (`night` shader global).
  - `g` wheel roll angle in radians (add `distance / wheel_radius` each frame), `b` front
    wheel steer angle (+ left). The shader spins and steers the wheels, so no wheel nodes
    are needed.
  - `a` seed 0..1: which driver (skin, hair, clothes) and the siren phase.

All zeros (what traffic and police write today) means: driver shown, no siren, no
brake, lights automatic.

## Notes for the other threads

- **Traffic and pedestrians (citylife/)**: new names for variety: `car_sports`,
  `car_pickup`, `car_taxi`, `car_bus`; `car_garbage` for the garbage trucks (fixed green
  livery, so the `GARBAGE_TINT` is no longer needed). For LODs, split each model's
  MultiMesh into three by camera distance with `VehicleKit.lod_for(distance)` (28 m and
  80 m) and `VehicleKit.mesh(model, lod)`; that is what gets the street under the
  triangle budget. Police: use `car_police` with `VehicleKit.custom(siren)` and drop the
  separate LightBars MultiMesh; the bar is in the model and flashes in the shader.
  Ambulances and fire trucks: `car_ambulance` and `car_firetruck`, same siren flag.
- **Street-level player (player/)**: `VehicleKit.spec(model)` gives length, width,
  height, wheel radius, track, axles (Godot z, with `dual` and `steer`) and the driver
  seat for any model, so `DrivableCar.MODELS` can be filled for the new names. Damage:
  swap the MultiMesh mesh to `VehicleKit.damaged(model, 1)` on the first dents, `2`
  when it smokes, `3` when it burns out (the existing smoke and fire particles go on
  top). Set the empty flag while nobody is driving, the brake flag while braking, and
  feed the wheel angle and steer so the wheels turn.
- **Missions (missions/)**: `CAR_NAMES` can add "sports car", "pickup", "taxi",
  "police cruiser", "ambulance", "fire engine", "garbage truck", "bus". `car_truck` is a
  box delivery truck (the new pickup is `car_pickup`).
