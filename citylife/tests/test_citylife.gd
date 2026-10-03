extends SceneTree
## Headless checks for traffic and pedestrians.
## godot --headless --path game --script res://citylife/tests/test_citylife.gd

var failures := 0


func check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)


func _initialize() -> void:
	# Autoloads (Kit) are ready after the first frame.
	await process_frame
	if not root.has_node("Kit"):
		var kit: Node = load("res://scripts/kit.gd").new()
		kit.name = "Kit"
		root.add_child(kit)
	print("citylife tests")
	var city := City.new(1337)
	var t0 := Time.get_ticks_msec()
	city.build_demo(24 * 12)
	city.compute_traffic()
	city.compute_land_value()
	city.minutes = float(city.game_day()) * 1440.0 + 8.0 * 60.0  # morning rush
	print("  demo city: %d buildings, pop %d (%d ms)" % [city.buildings.size(), city.population, Time.get_ticks_msec() - t0])

	var life := CityLife.new()
	life.auto_step = false
	root.add_child(life)
	life.setup(city, null)
	var net := life.net

	# --- road network -------------------------------------------------------
	var junctions := 0
	for i in net.junction.size():
		junctions += net.junction[i]
	check(junctions > 10, "junctions found (%d)" % junctions)
	check(net.conflict[0 * 16 + 0] == 0, "same-approach movements don't conflict")
	check(net.conflict[(2 * 4 + 2) * 16 + (1 * 4 + 1)] == 1, "crossing straights conflict")
	check(net.conflict[(2 * 4 + 2) * 16 + (0 * 4 + 0)] == 0, "opposing straights don't conflict")
	# Heading S the driver's left is E.
	check(net.conflict[(2 * 4 + 1) * 16 + (0 * 4 + 0)] == 1, "left turn conflicts with oncoming straight")
	check(net.conflict[(2 * 4 + 3) * 16 + (0 * 4 + 0)] == 0, "right turn clears oncoming straight")
	var lane_ok := true
	for m in 16:
		var a: Vector3 = net.sample(m, 0.0)[0]
		var d: int = m / 4
		# Entry point sits on the right-hand lane.
		if a.dot(RoadNet.right_of(d)) < 1.5:
			lane_ok = false
	check(lane_ok, "cars enter tiles in the right-hand lane")
	check(net.walk_nodes.size() > 100, "sidewalk graph built (%d nodes)" % net.walk_nodes.size())

	# --- population -----------------------------------------------------------
	check(life.want_cars > 20, "rush hour wants cars (%d)" % life.want_cars)
	check(life.traffic.cars.size() > 20, "cars spawned (%d)" % life.traffic.cars.size())
	check(life.crowd.peds.size() > 20, "people spawned (%d)" % life.crowd.peds.size())

	# --- simulate 3 minutes -----------------------------------------------------
	var dt := 1.0 / 30.0
	var frames := 30 * 180
	var moved := 0.0
	var max_ms := 0.0
	var total_ms := 0.0
	var overlap := 0
	var off_sidewalk := 0
	var samples := 0
	for f in frames:
		var s := Time.get_ticks_usec()
		life.step(dt)
		var ms := (Time.get_ticks_usec() - s) / 1000.0
		total_ms += ms
		if f > 30:
			max_ms = maxf(max_ms, ms)
		if f % 30 == 0:
			for c in life.traffic.cars:
				moved += c.v
				samples += 1
			overlap += _overlaps(life.traffic)
			off_sidewalk += _off_sidewalk(life)
	var avg_v := moved / maxf(samples, 1)
	print("  step: avg %.2f ms, worst %.2f ms, %d cars, %d people" % [total_ms / frames, max_ms, life.traffic.cars.size(), life.crowd.peds.size()])
	check(avg_v > 2.0, "traffic flows (avg speed %.1f m/s)" % avg_v)
	check(life.traffic.red_runs == 0, "no car entered a junction without a green and a reservation (%d)" % life.traffic.red_runs)
	check(overlap == 0, "no cars overlapping in a lane (%d)" % overlap)
	check(off_sidewalk == 0, "people stay on sidewalks and crossings (%d)" % off_sidewalk)
	check(life.traffic.despawned_stuck < life.traffic.cars.size(), "few gridlock removals (%d)" % life.traffic.despawned_stuck)
	check(total_ms / frames < 8.0, "sim cost fits a laptop frame (%.2f ms)" % (total_ms / frames))

	# --- night is quieter -------------------------------------------------------
	var day_cars := life.want_cars
	city.minutes = float(city.game_day()) * 1440.0 + 3.0 * 60.0
	life._update_area()
	check(life.want_cars < day_cars * 0.5, "3am has fewer cars (%d vs %d)" % [life.want_cars, day_cars])

	# --- editing roads ----------------------------------------------------------
	var c0 := city.center_cell()
	city.bulldoze(Rect2i(c0.x - 8, c0.y - 8, 16, 16))
	life.step(dt)
	var bad := 0
	for c in life.traffic.cars:
		if city.road[c.cell] != 1:
			bad += 1
	check(bad == 0, "cars removed from bulldozed roads")
	for f in 300:
		life.step(dt)
	check(life.traffic.red_runs == 0, "still no red runs after editing")

	# --- mayor vs street camera ---------------------------------------------------
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(480, 700, 900)
	cam.look_at(Vector3(480, 0, 480))
	life.set_camera(cam)
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0
	for f in 60:
		life.step(dt)
	check(life.crowd.peds.is_empty(), "no people simulated from the mayor view")
	check(not life.traffic.shadows, "no car shadows from the mayor view")
	var street := city.cell_center(c0.x + 12, c0.y)
	cam.global_position = street + Vector3(0, 1.7, 0)
	cam.look_at(street + Vector3(30, 1.5, 0))
	for f in 90:
		life.step(dt)
	check(life.crowd.peds.size() > 10, "people around you at street level (%d)" % life.crowd.peds.size())
	check(life.traffic.shadows, "car shadows at street level")

	print("citylife: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func _overlaps(tr: Traffic) -> int:
	var n := 0
	for key in tr._lanes:
		var lane: Array = tr._lanes[key].duplicate()
		lane.sort_custom(func(x, y): return x.s < y.s)
		for k in lane.size() - 1:
			var a = lane[k]
			var b = lane[k + 1]
			var need: float = (Traffic.LENGTHS[a.model] + Traffic.LENGTHS[b.model]) * 0.5 - 0.5
			if b.s - a.s < need:
				n += 1
				if OS.has_environment("CITYLIFE_DEBUG"):
					print("    overlap cell %d j=%d a(%d>%d s%.1f v%.1f) b(%d>%d s%.1f v%.1f)" % [a.cell, tr.net.junction[a.cell], a.din, a.dout, a.s, a.v, b.din, b.dout, b.s, b.v])
	return n


func _off_sidewalk(life: CityLife) -> int:
	var n := 0
	for p in life.crowd.peds:
		if p.arm >= 0:
			continue
		var cell := life.city.world_to_cell(p.pos)
		var c := life.city.cell_center(cell.x, cell.y)
		var i := life.city.idx(cell.x, cell.y)
		if life.city.road[i] != 1:
			n += 1
			continue
		var dx := p.pos.x - c.x
		var dz := p.pos.z - c.z
		var m: int = life.net.mask[i]
		var asphalt := absf(dx) < 3.75 and absf(dz) < 3.75
		asphalt = asphalt or absf(dx) < 3.75 and (dz < 0.0 and m & 1 or dz > 0.0 and m & 4)
		asphalt = asphalt or absf(dz) < 3.75 and (dx > 0.0 and m & 2 or dx < 0.0 and m & 8)
		if asphalt:
			n += 1
	return n
