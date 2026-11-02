extends SceneTree
## Headless physics checks for DrivableCar, from Fedge's 0.4.8 feedback (cars thrown into
## the air when taken, flipping too easily, feeling weightless, wrecking each other):
##   godot --headless --path . -s res://vehicles/tests/test_car_physics.gd
## Each case prints its measurement, so before/after runs can be compared.

var fails := 0
var world: Node3D
var _driver := Node.new()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _stage() -> void:
	if world:
		world.free()
	world = Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 2, 400)
	cs.shape = box
	cs.position.y = -1.0
	floor_body.add_child(cs)
	world.add_child(floor_body)


func _car(model: String, pos: Vector3, yaw := 0.0) -> DrivableCar:
	var c := DrivableCar.new()
	c.model = model
	world.add_child(c)
	c.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	return c


func _proxy(pos: Vector3, size: Vector3) -> AnimatableBody3D:
	## The stand-in StreetBodies puts under an AI car (physics layer 5).
	var b := AnimatableBody3D.new()
	b.collision_layer = 16
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = size
	cs.shape = s
	b.add_child(cs)
	world.add_child(b)
	b.global_position = pos
	return b


func _run() -> void:
	# --- 1. A car appearing on top of an AI car's stand-in must not be thrown ----------
	for keep_proxy in [false, true]:
		_stage()
		var stand_in := _proxy(Vector3(0, 0.6, 0), Vector3(1.9, 1.2, 4.4))
		var c := _car("car_sedan", Vector3(0, 0.15, 0))
		var max_y := 0.0
		var max_speed := 0.0
		for i in 150:
			await physics_frame
			if i == 10 and not keep_proxy and is_instance_valid(stand_in):
				stand_in.queue_free()   # StreetBodies frees the stand-in within a tenth of a second
			max_y = maxf(max_y, c.global_position.y)
			max_speed = maxf(max_speed, c.linear_velocity.length())
		print("  spawn on a stand-in (%s): peak height %.2f m, peak speed %.1f m/s" % ["never freed" if keep_proxy else "freed", max_y, max_speed])
		check(max_y < (2.5 if keep_proxy else 0.6) and max_speed < 6.0, "spawning over a stand-in doesn't launch the car (%s)" % ("worst case" if keep_proxy else "normal"))

	# --- 2. A fresh car settles without popping off its springs ------------------------
	_stage()
	var c := _car("car_pickup", Vector3(0, 0.1, 0))
	var max_y := 0.0
	for i in 120:
		await physics_frame
		max_y = maxf(max_y, c.global_position.y)
	print("  spawn on the road: peak height %.2f m" % max_y)
	check(max_y < 0.9, "a spawned pickup doesn't bounce up")

	# --- 3. Hard cornering at speed, and clipping a kerb, don't flip it -----------------
	for model in ["car_sedan", "car_sports", "car_van", "car_pickup", "car_bus"]:
		_stage()
		c = _car(model, Vector3(0, 0.3, 0))
		c.set_driver(_driver)
		await frames(20)
		c.linear_velocity = c.forward() * 26.0
		var min_up := 1.0
		var top := 0.0
		for i in 480:
			Input.action_press("street_forward")
			if i > 60:
				var left := (i / 40) % 2 == 0
				Input.action_press("street_left" if left else "street_right")
				Input.action_release("street_right" if left else "street_left")
			await physics_frame
			top = maxf(top, c.linear_velocity.length())
			min_up = minf(min_up, c.global_basis.y.y)
		Input.action_release("street_forward")
		Input.action_release("street_left")
		Input.action_release("street_right")
		print("  %-10s slalom up to %.0f m/s: lowest up %.2f" % [model, top, min_up])
		check(min_up > 0.75, "%s stays on its wheels in a slalom" % model)
	for model in ["car_sedan", "car_pickup"]:
		_stage()
		var kerb := StaticBody3D.new()
		kerb.collision_layer = 1
		var kcs := CollisionShape3D.new()
		var kb := BoxShape3D.new()
		kb.size = Vector3(1.0, 0.3, 60.0)
		kcs.shape = kb
		kcs.position = Vector3(3.0, 0.15, -20.0)
		kerb.add_child(kcs)
		world.add_child(kerb)
		c = _car(model, Vector3(0, 0.3, 20.0), PI)
		c.set_driver(_driver)
		await frames(20)
		c.linear_velocity = c.forward() * 22.0
		var min_up3 := 1.0
		for i in 480:
			Input.action_press("street_forward")
			if i > 25 and i < 85:
				Input.action_press("street_right")   # swerve into the kerb
			else:
				Input.action_release("street_right")
			await physics_frame
			min_up3 = minf(min_up3, c.global_basis.y.y)
		Input.action_release("street_forward")
		Input.action_release("street_right")
		print("  %-10s kerb clip at %.0f m/s: lowest up %.2f" % [model, c.linear_velocity.length(), min_up3])
		check(min_up3 > 0.7, "%s doesn't roll over after clipping a kerb" % model)

	# --- 4. Running into a parked car --------------------------------------------------
	for dv in [10.0, 18.0]:
		_stage()
		var parked := _car("car_sedan", Vector3(0, 0.3, 0))
		var hitter := _car("car_sedan", Vector3(0, 0.3, -20.0), PI)   # facing -Z
		await frames(60)
		hitter.linear_velocity = Vector3(0, 0, dv)
		var lift := 0.0
		var pmax := 0.0
		var pmin_up := 1.0
		for i in 150:
			await physics_frame
			lift = maxf(lift, parked.global_position.y)
			pmax = maxf(pmax, parked.linear_velocity.length())
			pmin_up = minf(pmin_up, parked.global_basis.y.y)
		print("  hit at %.0f m/s: parked car peak speed %.1f, peak height %.2f, lowest up %.2f, health %.0f%%, hitter health %.0f%%" % [
			dv, pmax, lift, pmin_up, parked.health / 10.0, hitter.health / 10.0])
		check(pmax < dv * 0.8, "a %.0f m/s hit doesn't fire the other car faster than %.0f m/s" % [dv, dv * 0.8])
		check(lift < 1.0 and pmin_up > 0.6, "a %.0f m/s hit leaves the other car on its wheels" % dv)
		if dv < 12.0:
			check(parked.health > 800.0, "a gentle %.0f m/s bump barely dents the other car" % dv)
		else:
			check(parked.health > 450.0, "even a hard %.0f m/s hit doesn't wreck the other car" % dv)

	# --- 5. Kerb and wall clips don't send it airborne ----------------------------------
	_stage()
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var wcs := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(30, 2.0, 0.5)
	wcs.shape = wb
	wcs.position = Vector3(0, 1.0, -30)
	wall.add_child(wcs)
	world.add_child(wall)
	c = _car("car_sedan", Vector3(0, 0.3, 0), PI)
	c.set_driver(_driver)
	await frames(30)
	var max_y2 := 0.0
	var min_up2 := 1.0
	for i in 300:
		Input.action_press("street_forward")
		await physics_frame
		max_y2 = maxf(max_y2, c.global_position.y)
		min_up2 = minf(min_up2, c.global_basis.y.y)
	Input.action_release("street_forward")
	print("  into a wall at speed: peak height %.2f, lowest up %.2f, health %.0f%%" % [max_y2, min_up2, c.health / 10.0])
	check(max_y2 < 1.2 and min_up2 > 0.6, "driving into a wall doesn't flip or launch the car")

	print("car physics: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails else 0)
