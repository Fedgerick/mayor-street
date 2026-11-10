extends SceneTree
## Headless check that street level is solid where it looks solid:
##   godot --headless -s res://player/test/run_collision_test.gd
## Lamps and trees line up with what CityView draws, parks stay open, AI cars and people
## near the player get bodies, traffic brakes for things in its lane, a hard hit turns an
## AI car into a physics car, the player's car knocks people down, walkers stop for the
## player, and the per-frame cost stays small. Exits with code 1 on any failure.

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


func _ray(a: Vector3, b: Vector3, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b, mask)
	return t.get_world_3d().direct_space_state.intersect_ray(q)


## Where CityView puts its lamps and trees, from CityView's own placement code: its
## _add_road and _add_tree, fed the same cells its chunk builder loops over.
func _view_solids(view: Node, city: City) -> Dictionary:
	var groups := {}
	var lamps: Array[Vector3] = []
	for y in City.H:
		for x in City.W:
			var i := city.idx(x, y)
			var c := city.cell_center(x, y)
			if city.road[i] == 1:
				view._add_road(groups, lamps, x, y, c)
				continue
			var bid := city.bld[i]
			if bid >= 0:
				var b: Dictionary = city.buildings[bid]
				if b.x == x and b.y == y and b.zone == City.Zone.RES and b.stage == 1 and not b.has("kind"):
					var back := Basis(Vector3.UP, b.rot * PI * 0.5) * Vector3(view._cell_hash(x, y, 9) * 6.0 - 3.0, 0, -4.4)
					view._add_tree(groups, c + back, x, y, 5, false)
				continue
			if city.land[i] == 1:
				for k in city.trees[i]:
					var off := Vector3(view._cell_hash(x, y, k) * 9.0 - 4.5, 0, view._cell_hash(x, y, k + 7) * 9.0 - 4.5)
					view._add_tree(groups, c + off, x, y, k, city.coast_dist[i] <= 2.0)
	var out := {}
	for nm in groups:
		var pts: Array[Vector3] = []
		for xf in groups[nm][0]:
			pts.append((xf as Transform3D).origin)
		out[nm] = pts
	return out


func _shape_near(col: CityCollision, p: Vector3, tol: float) -> bool:
	for body in col.get_children():
		for cs in body.get_children():
			if cs is CollisionShape3D and cs.shape is CylinderShape3D:
				var o: Vector3 = cs.global_position
				if Vector2(o.x - p.x, o.z - p.z).length() < tol:
					return true
	return false


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	t.with_life = true
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var life: CityLife = t.life
	var city: City = t.city
	var col: CityCollision = street.collision
	var bodies: StreetBodies = street.bodies

	# --- Street furniture matches the drawing ----------------------------------------
	var solids := _view_solids(t.view, city)
	for nm in ["street_lamp", "tree_round_a", "tree_round_b", "tree_pine", "palm"]:
		var pts: Array = solids.get(nm, [])
		var missing := 0
		for p in pts:
			if not _shape_near(col, p, 0.1):
				missing += 1
		check(pts.is_empty() or missing == 0, "every %s CityView draws has a trunk or pole (%d drawn, %d missing)" % [nm, pts.size(), missing])
	var lamps: Array = solids.get("street_lamp", [])
	if not lamps.is_empty():
		var lp: Vector3 = lamps[0]
		var hit := _ray(lp + Vector3(1.5, 1.2, 0), lp + Vector3(-1.5, 1.2, 0), 1)
		var hit2 := _ray(lp + Vector3(0, 1.2, 1.5), lp + Vector3(0, 1.2, -1.5), 1)
		check(not hit.is_empty() or not hit2.is_empty(), "a street lamp stops a walker")

	# --- Parks are open, other specials are solid -------------------------------------
	var spot := Vector2i(-1, -1)
	for y in range(4, City.H - 4):
		for x in range(4, City.W - 4):
			if spot.x < 0 and city.can_place_special("small_park", Vector2i(x, y), true) == "":
				spot = Vector2i(x, y)
	if spot.x >= 0:
		var id := city.place_special("small_park", spot, -1, true)
		await frames(3)
		var c := city.cell_center(spot.x, spot.y)
		check(id >= 0 and _ray(c + Vector3(-5.2, 1.0, 0.3), c + Vector3(5.2, 1.0, 0.3), 1).is_empty(), "a small park can be walked into")
	else:
		check(false, "found a lot for a test park")

	# --- On the street ----------------------------------------------------------------
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "on the street")
	await frames(120)
	var p: StreetPlayer = street.player
	check(p.collision_mask & StreetBodies.TRAFFIC_LAYER and p.collision_mask & StreetBodies.PEOPLE_LAYER, "the player collides with traffic and people stand-ins")

	# A traffic car near the player gets a solid body.
	var tc = null
	var best := INF
	for c in life.traffic.cars:
		var d: float = c.pos.distance_to(p.global_position)
		if d < best:
			best = d
			tc = c
	if tc and best < StreetBodies.CAR_RADIUS:
		await frames(8)
		var at: Vector3 = tc.pos
		var side := Vector3(-tc.fwd.z, 0, tc.fwd.x)
		var hit := _ray(at + side * 3.0 + Vector3.UP * 0.9, at - side * 3.0 + Vector3.UP * 0.9, StreetBodies.TRAFFIC_LAYER)
		check(not hit.is_empty(), "an AI car %.0f m away is solid" % best)
	else:
		print("SKIP  no AI car near the player")

	# --- Traffic brakes for something in its lane ---------------------------------------
	var tr: Traffic = life.traffic
	var runner = null
	for c in tr.cars:
		# Going straight, with the next tile straight too, so the block stays in its path.
		if c.v > 4.0 and c.dout == c.din and tr.net.junction[c.cell] == 0 \
				and tr.net.junction[tr.net.neighbor(c.cell, c.dout)] == 0:
			runner = c
			break
	if runner:
		var right := Vector3(-runner.fwd.z, 0, runner.fwd.x)
		var block_at: Vector3 = runner.pos + runner.fwd * 14.0 - right * runner.dodge
		var saved_obstacles: Array = []
		var min_gap := INF
		for i in 170:   # under 3 s: after that an impatient driver swings round it
			# The street layer refreshes obstacles each frame; hold ours in place.
			tr.obstacles = [[block_at, right * 0.9, runner.fwd * 2.2, Vector3.ZERO]]
			tr.obstacle_focus = runner.pos
			bodies.set_physics_process(false)
			tr.step(1.0 / 60.0)
			if not tr.cars.has(runner):
				break
			var ahead: float = (block_at - runner.pos).dot(runner.fwd)
			if absf((block_at - runner.pos).dot(right)) < 1.5:
				min_gap = minf(min_gap, ahead - Traffic.LENGTHS[runner.model] * 0.5 - 2.2)
		bodies.set_physics_process(true)
		tr.obstacles = saved_obstacles
		var last_gap: float = (block_at - runner.pos).dot(runner.fwd) - Traffic.LENGTHS[runner.model] * 0.5 - 2.2
		check(min_gap > -0.05 and runner.v * runner.v / 18.0 < last_gap, "an AI car stops short of a car blocking its lane (gap %.2f m, speed %.1f)" % [min_gap, runner.v])
	else:
		print("SKIP  no moving AI car")

	# --- Traffic squeezes past a kerbside car -----------------------------------------
	var lane_car = null
	for c in tr.cars:
		if c.v > 4.0 and c.pull == 0.0:
			lane_car = c
			break
	if lane_car:
		var right := Vector3(-lane_car.fwd.z, 0, lane_car.fwd.x)
		lane_car.dodge = 0.0
		var kerb: Vector3 = lane_car.pos + lane_car.fwd * 20.0 + right * (StreetMode.PARK_OUT - RoadNet.LANE)
		tr.obstacles = [[kerb, right * 0.95, lane_car.fwd * 2.3, Vector3.ZERO]]
		var stops := false
		var lane_pos: Vector3 = lane_car.pos
		for i in 90:
			lane_car.pos = lane_pos - right * lane_car.dodge   # as Traffic._place offsets it
			if tr._obstacle_gap(lane_car, Traffic.LENGTHS[lane_car.model], 1.0 / 60.0) < 8.0:
				stops = true
		check(not stops and lane_car.dodge > 0.5 and lane_car.dodge <= Traffic.DODGE, "an AI car swerves %.2f m round a kerbside parked car instead of stopping" % lane_car.dodge)
		lane_car.dodge = 0.0
	tr.obstacles = []

	# --- A hard hit swaps the AI car for a physics car ----------------------------------
	var target = null
	for c in tr.cars:
		if c.pos.distance_to(p.global_position) < 40.0:
			target = c
			break
	if target:
		var fwd: Vector3 = target.fwd
		var spawn: Vector3 = target.pos - fwd * 5.2 + Vector3.UP * 0.2
		var mine := street.spawn_car("car_sedan", spawn, atan2(fwd.x, fwd.z), Color.RED)
		await frames(2)
		mine.global_position = target.pos - fwd * 4.7 + Vector3.UP * 0.2
		mine.linear_velocity = fwd * (float(target.v) + 12.0)
		bodies._pick(p.global_position)
		var before := bodies.knocked
		bodies._car_hits(mine)
		check(bodies.knocked == before + 1 and not tr.cars.has(target), "ramming an AI car turns it into a real car")
		var wreck: DrivableCar = null
		for v in root.get_tree().get_nodes_in_group("vehicles"):
			if v.get_meta("from_traffic", false):
				wreck = v
		check(wreck != null and wreck.get_meta("parked", false), "the knocked car stays as someone's car (taking it is theft)")
		mine.queue_free()
	else:
		print("SKIP  no AI car to ram")

	# --- The player's car knocks people down ----------------------------------------
	var ped = null
	for attempt in 5:
		for q in life.crowd.peds:
			if q.act == 0 and q.flee <= 0.0 and q.t > 2.0 and q.t < q.length - 4.0:
				ped = q
				break
		if ped == null:
			break
		p.place(ped.pos + Vector3(6, 0.3, 0), 0.0)   # the stand-ins follow the player
		await frames(4)
		if life.crowd.peds.has(ped):
			break
		ped = null
	if ped:
		var car := street.spawn_car("car_sedan", ped.pos + Vector3(0, 0.3, -1.0), 0.0, Color.BLUE)
		await frames(2)
		car.global_position = ped.pos + Vector3(0, 0.3, 0)
		car.linear_velocity = Vector3(0, 0, 12.0)
		bodies._pick(ped.pos)   # centred on the walker, so a crowd round them can't crowd them out
		var before := bodies.run_over
		bodies._car_hits(car)
		var picked := bodies._near_people.any(func(n): return n[0] == ped)
		check(bodies.run_over == before + 1 and not life.crowd.peds.has(ped), "a car at 43 km/h knocks a walker down for good (picked %s, %.2f m from the car)" % [picked, Vector2(ped.pos.x - car.global_position.x, ped.pos.z - car.global_position.z).length()])
		car.queue_free()
		street.heat.clear()
	else:
		print("SKIP  no walker near the player")

	# --- Walkers stop for the player ---------------------------------------------------
	var walker = null
	for q in life.crowd.peds:
		if q.act == 0 and q.flee <= 0.0 and q.pause <= 0.0 and q.arm < 0:
			walker = q
			break
	if walker:
		var block: Vector3 = walker.pos + walker.fwd * 0.8
		life.crowd.blockers.clear()
		life.crowd.blockers.append(block)
		bodies.set_physics_process(false)
		life.crowd.step(1.0 / 60.0)
		check(walker.pause > 0.0, "a walker stops instead of walking through the player")
		bodies.set_physics_process(true)

	# --- Cost --------------------------------------------------------------------------
	await frames(30)
	var usec := 0
	for i in 120:
		var t0 := Time.get_ticks_usec()
		bodies._physics_process(1.0 / 60.0)
		usec += Time.get_ticks_usec() - t0
		await physics_frame
	var ms := usec / 120.0 / 1000.0
	check(ms < 0.6, "street bodies cost %.3f ms a frame here (budget 0.6)" % ms)
	var shapes := 0
	for body in col.get_children():
		shapes += body.get_child_count()
	print("INFO  city collision shapes: %d" % shapes)

	print("\n%s" % ("ALL PASSED" if fails == 0 else "%d FAILED" % fails))
	quit(1 if fails > 0 else 0)
