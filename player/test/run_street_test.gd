extends SceneTree
## Headless check of the street-level loop on the demo city:
##   godot --headless -s res://player/test/run_street_test.gd
## Dive from the mayor view, walk, sprint, jump, climb a curb, enter a car, drive, steer,
## get out, and rise back to the mayor view. Exits with code 1 on any failure.

var fails := 0
var t: Node3D


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func hold(action: String, seconds: float) -> void:
	Input.action_press(action)
	await frames(int(seconds * 60.0))
	Input.action_release(action)


func tap(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await process_frame
	var r := InputEventAction.new()
	r.action = action
	r.pressed = false
	Input.parse_input_event(r)
	await frames(2)


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var p: StreetPlayer = street.player

	# --- Dive -------------------------------------------------------------------
	var mayor_h: float = t.cam.global_position.y
	t.go_street()
	await frames(30)
	check(street.busy and street.camera.current, "dive started; street camera is current")
	var mid_h := street.camera.global_position.y
	await frames(int(street.dive_seconds * 60.0) + 20)
	check(street.active and not street.busy, "dive finished; player has control")
	check(mid_h < mayor_h and mid_h > 3.0, "camera descends through the sky (%.0f m -> %.0f m)" % [mayor_h, mid_h])
	var eye := p.rig.eye.global_position
	check(street.camera.global_position.distance_to(eye) < 0.05, "camera lands exactly on the character boom")
	check(p.global_position.y > 0.0 and p.global_position.y < 0.6, "player stands on the ground (y=%.2f)" % p.global_position.y)

	# --- Walk / sprint -------------------------------------------------------------
	var fwd := p.rig.forward_flat()
	var start := p.global_position
	await hold("street_forward", 1.5)
	var walked := (p.global_position - start).dot(fwd)
	check(walked > 3.0, "walks forward relative to the camera (%.1f m)" % walked)
	start = p.global_position
	Input.action_press("street_sprint")
	await hold("street_forward", 1.5)
	Input.action_release("street_sprint")
	var sprinted := (p.global_position - start).dot(fwd)
	check(sprinted > walked * 1.4, "sprint is faster (%.1f m vs %.1f m)" % [sprinted, walked])
	await frames(30)

	# --- Jump --------------------------------------------------------------------
	var y0 := p.global_position.y
	await tap("street_jump")
	var peak := y0
	for i in 40:
		await physics_frame
		peak = maxf(peak, p.global_position.y)
	check(peak - y0 > 0.8, "jumps (%.2f m)" % (peak - y0))
	await frames(60)
	check(p.is_on_floor(), "lands again")

	# --- Curb step-up ------------------------------------------------------------------
	var city: City = t.city
	var road_cell := Vector2i(-1, -1)
	var cc := city.center_cell()
	for r in 10:
		for y in range(cc.y - r, cc.y + r + 1):
			for x in range(cc.x - r, cc.x + r + 1):
				if road_cell.x < 0 and city.road_mask(x, y) == (2 | 8):
					road_cell = Vector2i(x, y)
	check(road_cell.x >= 0, "found a straight east-west road")
	var rc := city.cell_center(road_cell.x, road_cell.y)
	p.place(rc + Vector3(0, 0.2, 0), PI)   # facing +Z, toward the south sidewalk
	p.rig.yaw = PI
	await frames(20)
	var on_road_y := p.global_position.y
	Input.action_press("street_forward")
	var top_y := on_road_y
	for i in 120:
		await physics_frame
		if p.global_position.z > rc.z + 4.3 and p.global_position.z < rc.z + 5.6:
			top_y = maxf(top_y, p.global_position.y)
	Input.action_release("street_forward")
	check(top_y > on_road_y + 0.12, "steps up the curb onto the sidewalk (y %.2f -> %.2f)" % [on_road_y, top_y])

	# --- Car ---------------------------------------------------------------------
	var car := street.spawn_car("car_sedan", rc + Vector3(4.0, 0.15, -2.75), PI * 0.5, Color(0.2, 0.4, 0.9))
	await frames(60)
	check(car.global_position.y > -0.1 and car.global_position.y < 0.4, "parked car settles on its wheels (y=%.2f)" % car.global_position.y)
	p.place(car.exit_point(), 0.0)
	await frames(5)
	await tap("street_interact")
	await frames(110)
	check(street.car == car and p.in_vehicle and not p.visible, "gets into the car")
	check(street.camera.rig == car.rig, "camera follows the car")
	var c0 := car.global_position
	await hold("street_forward", 3.0)
	var drove := (car.global_position - c0).dot(Vector3(1, 0, 0))
	check(drove > 12.0, "drives forward along the road (%.1f m, %.0f km/h)" % [drove, car.speed() * 3.6])
	var v0 := car.speed()
	Input.action_press("street_back")
	var stop_t := 0.0
	while car.speed() > 0.5 and stop_t < 5.0:
		await physics_frame
		stop_t += 1.0 / 60.0
	check(stop_t < 3.0, "brakes from %.0f km/h to a stop in %.1f s" % [v0 * 3.6, stop_t])
	await frames(90)
	Input.action_release("street_back")
	check(car.speed() < -1.0, "reverses (%.1f m/s)" % car.speed())
	await frames(60)
	var yaw0 := car.heading_yaw()
	Input.action_press("street_forward")
	await hold("street_left", 1.5)
	Input.action_release("street_forward")
	var turned := wrapf(car.heading_yaw() - yaw0, -PI, PI)
	check(turned > 0.3, "steers left (%.0f deg)" % rad_to_deg(turned))
	await hold("street_back", 1.5)
	await frames(60)
	await frames(30)
	check(car.global_basis.y.y > 0.9, "car stays upright")
	await tap("street_interact")
	await frames(110)
	check(street.car == null and not p.in_vehicle and p.visible, "gets out of the car")
	check(p.global_position.distance_to(car.global_position) < 4.0, "player is beside the car")
	check(street.camera.rig == p.rig, "camera back on the character")

	# --- Rise ----------------------------------------------------------------------
	t.go_mayor()
	await frames(int(street.rise_seconds * 60.0) + 20)
	check(not street.active and t.cam.current, "rises back to the mayor view")
	check(street.camera.global_position.distance_to(t.cam.global_position) < 0.1, "rise ends exactly on the mayor camera")

	print("\n%s: %d failure(s)" % ["OK" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)
