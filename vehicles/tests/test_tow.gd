extends SceneTree
## Headless checks for TowService: a flipped car and a burnt-out car are fetched, carried
## off and removed; a driven car, a healthy car and a bus are left alone.
##   godot --headless --path . -s res://vehicles/tests/test_tow.gd

var fails := 0


class FakeStreet:
	extends Node3D
	var car: DrivableCar = null
	var active := true
	func focus_point() -> Vector3:
		return global_position


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var city := City.new(1337)
	city.build_demo(24 * 12)
	city.compute_traffic()
	var world := Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1200, 2, 1200)
	cs.shape = box
	cs.position = Vector3(480, -1.0, 480)
	floor_body.add_child(cs)
	world.add_child(floor_body)

	# A straight stretch of road with room both ways.
	var c0 := city.center_cell()
	var spot := Vector2i(-1, -1)
	for r in range(2, 20):
		var cand := Vector2i(c0.x + r, c0.y)
		if city.is_road(cand.x, cand.y) and city.is_road(cand.x - 1, cand.y) and city.is_road(cand.x + 1, cand.y):
			spot = cand
			break
	check(spot.x >= 0, "found a road to test on")
	var at := city.cell_center(spot.x, spot.y)

	var street := FakeStreet.new()
	world.add_child(street)
	street.global_position = at + Vector3(0, 0, 30)

	var service := TowService.new()
	service.setup(city, street)
	service.rng.seed = 7
	world.add_child(service)

	var healthy := _car(world, "car_sedan", at + Vector3(4, 0.4, 3))
	var bus := _car(world, "car_bus", at + Vector3(-5, 0.6, 5))
	var driven := _car(world, "car_pickup", at + Vector3(0, 0.4, -6))
	driven.set_driver(Node.new())
	var flipped := _car(world, "car_sedan", at + Vector3(2, 0.6, 0))
	await frames(40)
	flipped.global_transform = Transform3D(Basis(Vector3.FORWARD, PI), flipped.global_position + Vector3(0, 1.0, 0))   # on its roof
	flipped.linear_velocity = Vector3.ZERO
	await frames(120)
	check(flipped.global_basis.y.y < 0.35, "the flipped car stays upside down (up %.2f)" % flipped.global_basis.y.y)
	bus.wrecked = true
	bus.damage_stage = 3

	# Let it look. Nothing should be sent before the wait is over.
	await frames(60 * 2)
	check(service.sent == 0, "no truck before the car has been stuck for a while")

	var t := 0.0
	var seen_truck := false
	var loaded_at := -1.0
	var min_dist := INF
	while t < 90.0 and service.towed_count == 0:
		await physics_frame
		t += 1.0 / 60.0
		if service.busy():
			seen_truck = true
			var tr: TowService.Truck = service.trucks[0]
			min_dist = minf(min_dist, tr.node.global_position.distance_to(flipped.global_position))
			if tr.state == TowService.DRIVE_OUT and loaded_at < 0.0:
				loaded_at = t
				check(tr.car == flipped, "the flipped car is the one fetched")
				var d := flipped.global_position.distance_to(tr.node.global_position + tr.node.global_basis * TowService.BED)
				check(d < 0.5, "the car sits on the deck (%.2f m off)" % d)
				check(flipped.global_basis.y.y > 0.95, "...right way up")
	print("  truck seen: %s, closest %.1f m, loaded after %.1f s, towed %d" % [seen_truck, min_dist, loaded_at, service.towed_count])
	check(seen_truck, "a truck was sent")
	check(min_dist < 12.0, "it drove up to the car")
	check(loaded_at > 0.0, "it loaded the car")
	check(driven.is_inside_tree() and healthy.is_inside_tree(), "healthy and driven cars are left alone")

	# Carried away, then removed.
	t = 0.0
	while t < 120.0 and not (service.towed_count >= 1):
		await physics_frame
		t += 1.0 / 60.0
	check(service.towed_count >= 1, "the car is taken away and removed (%.0f s later)" % t)
	check(not is_instance_valid(flipped) or flipped.is_queued_for_deletion(), "the flipped car is gone")

	# The burnt-out bus is too long for the deck and stays.
	await frames(60 * 12)
	check(service.sent == 1 and is_instance_valid(bus), "the bus is too long to tow and is left")
	# But a burnt-out sedan is fetched.
	var burnt := _car(world, "car_sedan", at + Vector3(-3, 0.4, 2))
	await frames(40)
	burnt.wrecked = true
	burnt.damage_stage = 3
	t = 0.0
	while t < 150.0 and service.towed_count < 2:
		await physics_frame
		t += 1.0 / 60.0
	check(service.towed_count == 2, "a burnt-out sedan is fetched too")

	# Someone climbing in cancels the pickup.
	var other := _car(world, "car_hatch", at + Vector3(3, 0.6, -2))
	await frames(40)
	other.global_transform = Transform3D(Basis(Vector3.FORWARD, PI), other.global_position + Vector3(0, 1.0, 0))
	check(service.request(other), "a truck can be asked for directly")
	await frames(60 * 3)
	other.set_driver(Node.new())
	t = 0.0
	while t < 60.0 and service.busy():
		await physics_frame
		t += 1.0 / 60.0
	check(is_instance_valid(other) and not other.is_queued_for_deletion() and not other.freeze, "a car someone gets into is not taken")

	print("tow service: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails else 0)


func _car(world: Node3D, model: String, pos: Vector3) -> DrivableCar:
	var c := DrivableCar.new()
	c.model = model
	world.add_child(c)
	c.global_transform = Transform3D(Basis(Vector3.UP, 0.0), pos)
	return c
