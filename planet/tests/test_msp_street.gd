extends SceneTree
## msp street check on the real game: boot the planet demo, dive to the street, walk,
## get in a car and drive, and check everything stays upright on the ball.
## godot --path . -s planet/tests/test_msp_street.gd -- --demo --nosave

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _wait(s: float) -> void:
	await create_timer(s).timeout


func _run() -> void:
	print("msp street tests")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait(1.0)
	check(Planet.on, "the game is on the planet")
	check(City.W == 288 and City.H == 52, "city is 288 x 52 tiles")
	main.go_street()
	var street: StreetMode = main.street
	while not street.active:
		await process_frame
	var p := street.player
	var up := Planet.up(p.global_position)
	check(absf(p.global_position.length() - Planet.R) < 3.0, "player stands on the ball (%.1f m off sea level)" % (p.global_position.length() - Planet.R))
	check(p.global_basis.y.dot(up) > 0.99, "player stands upright")
	# A car right here, and drive it.
	# On the nearest east-west road, pointing east.
	var city: City = main.city
	var o := city.world_to_cell(p.global_position)
	var road := Vector2i(-999, 0)
	for r in 12:
		for y in range(o.y - r, o.y + r + 1):
			for x in range(o.x - r, o.x + r + 1):
				if road.x == -999 and city.road_mask(x, y) == 2 | 8 and city.road_mask(x + 1, y) == 2 | 8:
					road = Vector2i(x, y)
	check(road.x != -999, "found a straight road near by")
	var at := Planet.place(city.cell_center(road.x, road.y) + Vector3(0, 0.6, 2.0))
	var car := street.spawn_car("car_sedan", at, PI * 0.5, Color(0.8, 0.2, 0.2))
	p.place(at + Planet.dir(at, Vector3(0, 0, 3.0)), 0.0)
	await _wait(1.0)
	print("    car sleeping=%s v=%s" % [car.sleeping, car.linear_velocity])
	# Walk east along the road for two seconds.
	p.rig.yaw = -PI * 0.5
	var start := p.global_position
	Input.action_press("street_forward")
	await _wait(2.0)
	Input.action_release("street_forward")
	var walked := start.distance_to(p.global_position)
	check(walked > 4.0, "walked %.1f m" % walked)
	check(absf(p.global_position.length() - Planet.R) < 3.0, "still on the ground after walking")
	check(p.global_basis.y.dot(Planet.up(p.global_position)) > 0.99, "upright after walking")
	check(car.global_basis.y.dot(Planet.up(car.global_position)) > 0.95, "parked car sits upright")
	street._enter_car(car)
	while street.switching:
		await process_frame
	check(street.car == car, "got in the car")
	var c0 := car.global_position
	Input.action_press("street_forward")
	await _wait(4.0)
	print("    car v=%s throttle=%s driver=%s phys=%s" % [car.linear_velocity, car.throttle, car.driver, car.is_physics_processing()])
	Input.action_release("street_forward")
	var drove := c0.distance_to(car.global_position)
	check(drove > 10.0, "drove %.1f m" % drove)
	check(car.global_basis.y.dot(Planet.up(car.global_position)) > 0.9, "car still upright after driving")
	check(absf(car.global_position.length() - Planet.R) < 4.0, "car still on the ground")
	street._leave_car()
	while street.switching:
		await process_frame
	check(street.car == null and p.global_basis.y.dot(Planet.up(p.global_position)) > 0.99, "out of the car, upright")
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
