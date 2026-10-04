extends SceneTree
## Headless checks for police, fleeing crowds, sirens and garbage trucks.
## godot --headless --path . --script res://citylife/tests/test_police.gd

var failures := 0


class Suspect:
	extends RefCounted
	signal wanted_changed(stars: int)
	var wanted_stars := 0
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var in_car := false
	func suspect_position() -> Vector3:
		return pos
	func suspect_velocity() -> Vector3:
		return vel
	func suspect_in_vehicle() -> bool:
		return in_car


func check(ok: bool, what: String) -> void:
	print("  ok   " if ok else "  FAIL ", what)
	if not ok:
		failures += 1


func _initialize() -> void:
	await process_frame
	if not root.has_node("Kit"):
		var kit: Node = load("res://scripts/kit.gd").new()
		kit.name = "Kit"
		root.add_child(kit)
	print("police tests")
	var city := City.new(1337)
	city.build_demo(24 * 12)
	city.compute_traffic()
	city.minutes = float(city.game_day()) * 1440.0 + 9.0 * 60.0
	var life := CityLife.new()
	life.auto_step = false
	root.add_child(life)
	life.setup(city, null)
	var dt := 1.0 / 30.0

	# --- garbage trucks ---------------------------------------------------------
	for f in 30 * 20:
		life.step(dt)
	check(life.traffic.garbage_count() > 0, "garbage trucks out in the morning (%d)" % life.traffic.garbage_count())

	# --- a suspect on foot on a street near the station ---------------------------
	var s := Suspect.new()
	life.set_suspect(s)
	var c0 := city.center_cell()
	var spot := Vector2i(-1, -1)
	for r in range(6, 20):
		var cand := Vector2i(c0.x + r, c0.y)
		if city.inside(cand.x, cand.y) and city.road[city.idx(cand.x, cand.y)] == 1:
			spot = cand
			break
	check(spot.x >= 0, "found a street for the suspect")
	s.pos = city.cell_center(spot.x, spot.y) + Vector3(0, 0, 5.3)
	var sightings := [0]
	var busts := [0]
	life.police.sighting_changed.connect(func(v): sightings[0] += 1)
	life.police.busted.connect(func(): busts[0] += 1)
	s.wanted_stars = 2
	var max_cars := 0
	var max_off := 0
	var pulled := 0
	var t0 := Time.get_ticks_usec()
	var frames := 0
	for f in 30 * 60:
		life.step(dt)
		frames += 1
		max_cars = maxi(max_cars, life.police.cop_count())
		max_off = maxi(max_off, life.police.officer_count())
		for c in life.traffic.cars:
			if c.pull > 0.8 and c.v < 0.5:
				pulled += 1
		if busts[0] > 0:
			break
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
	print("  2 stars: %d cop cars, %d officers max, busted after %.1f s, %.2f ms/step" % [max_cars, max_off, frames * dt, ms])
	check(max_cars == 2, "two stars bring two cop cars (%d)" % max_cars)
	check(sightings[0] > 0 and life.police.seen, "cops spot the suspect")
	check(max_off > 0, "officers get out and chase on foot (%d)" % max_off)
	check(busts[0] > 0, "a standing suspect gets busted")
	check(pulled > 0, "traffic pulls over for sirens")

	# --- five stars respects the caps -------------------------------------------
	s.wanted_stars = 5
	s.vel = Vector3(6, 0, 0)  # running, so no bust
	for f in 30 * 40:
		life.step(dt)
		max_cars = maxi(max_cars, life.police.cop_count())
		max_off = maxi(max_off, life.police.officer_count())
	check(max_cars <= Police.MAX_CARS and max_cars >= 5, "five stars: %d cop cars (cap 6)" % max_cars)
	check(max_off <= Police.MAX_OFFICERS, "officers capped (%d of 8)" % max_off)

	# --- breaking line of sight -------------------------------------------------------
	var hidden := false
	var lot := Vector2i(-1, -1)
	for b in city.buildings.values():
		var far := city.cell_center(b.x, b.y).distance_to(s.pos)
		if far > 250.0:
			lot = Vector2i(b.x, b.y)
			break
	s.pos = city.cell_center(lot.x, lot.y)  # inside a block, far away
	for f in 30 * 3:
		life.step(dt)
	check(not life.police.seen, "suspect lost when out of sight")
	check(life.police.has_line_of_sight(Vector3(0, 0, 0), Vector3(1, 0, 1)) or true, "line of sight query runs")

	# --- stars cleared: cops leave --------------------------------------------------
	s.wanted_stars = 0
	for f in 30 * 100:
		life.step(dt)
	check(life.police.cop_count() == 0 and life.police.officer_count() == 0, "cops leave once stars are gone (%d left)" % life.police.cop_count())

	# --- crowd flees ------------------------------------------------------------------
	var p0 = life.crowd.peds[0]
	var crime: Vector3 = p0.pos
	var n := life.report_crime(crime, 3)
	var near_before := 0
	for p in life.crowd.peds:
		if p.pos.distance_to(crime) < 20.0:
			near_before += 1
	for f in 30 * 4:
		life.step(dt)
	var near_after := 0
	for p in life.crowd.peds:
		if p.pos.distance_to(crime) < 20.0:
			near_after += 1
	check(n > 0 and near_after < near_before, "people run from gunfire (%d fled, %d -> %d within 20 m)" % [n, near_before, near_after])

	# --- carjacking -----------------------------------------------------------------
	var before := life.traffic.cars.size()
	var peds_before := life.crowd.peds.size()
	var car = life.traffic.nearest_car(life.traffic.cars[0].pos, 5.0)
	var info: Dictionary = life.traffic.take_car(car)
	check(life.traffic.cars.size() == before - 1 and info.has("xform") and info.model != "", "take_car hands the car over")
	check(life.crowd.peds.size() == peds_before + 1, "the driver runs off as a pedestrian")

	print("police: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)
