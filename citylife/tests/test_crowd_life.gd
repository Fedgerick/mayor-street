extends SceneTree
## Headless checks for people with lives: benches, bus stops and buses, chat groups,
## phones, dogs, crash gawkers and night crowds.
## godot --headless --path . --script res://citylife/tests/test_crowd_life.gd

var failures := 0


func check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)


func _initialize() -> void:
	await process_frame
	if not root.has_node("Kit"):
		var kit: Node = load("res://scripts/kit.gd").new()
		kit.name = "Kit"
		root.add_child(kit)
	print("crowd life tests")
	var city := City.new(1337)
	city.build_demo(24 * 12)
	city.compute_traffic()
	city.compute_land_value()
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0  # lunch
	var life := CityLife.new()
	life.auto_step = false
	root.add_child(life)
	life.setup(city, null)
	var sp := life.spots
	var net := life.net

	# --- spots -----------------------------------------------------------------
	var benches := sp.count(StreetSpots.Kind.BENCH)
	var stops := sp.count(StreetSpots.Kind.STOP)
	check(benches >= 6, "benches placed along the sidewalks (%d)" % benches)
	check(stops >= 4, "bus stops placed (%d)" % stops)
	var bad := 0
	for s in sp.spots:
		var out: Vector3 = RoadNet.DV[s.side]
		var o := (s.xform.origin - net.center(s.cell)).dot(out)
		if net.junction[s.cell] == 1 or net.has_arm(s.cell, s.side) or o < 3.75 or o > 6.0:
			bad += 1
		if s.kind == StreetSpots.Kind.STOP and RoadNet.right_of(s.heading).dot(out) < 0.9:
			bad += 1
	check(bad == 0, "spots stand on sidewalks, buses stop on the kerb side (%d bad)" % bad)
	var again := StreetSpots.new()
	root.add_child(again)
	again.setup(net)
	var same := again.spots.size() == sp.spots.size()
	for k in mini(again.spots.size(), sp.spots.size()):
		same = same and again.spots[k].xform.origin.is_equal_approx(sp.spots[k].xform.origin)
	check(same, "the same city gets the same spots")
	again.queue_free()
	check(sp._bench_mmi.multimesh.instance_count == benches and sp._stop_mmi.multimesh.instance_count == stops, "bench and shelter props drawn")

	# --- a lunchtime of street life ---------------------------------------------------
	var dt := 1.0 / 30.0
	var bus_stops := [0]
	life.traffic.bus_stopped.connect(func(_c, _s): bus_stops[0] += 1)
	var max_sit := 0
	var max_wait := 0
	var max_chat := 0
	var max_phone := 0
	var max_dogs := 0
	var max_bus := 0
	var walk_into := 0
	var seat_off := 0
	var total_ms := 0.0
	var frames := 30 * 240
	for f in frames:
		var t0 := Time.get_ticks_usec()
		life.step(dt)
		total_ms += (Time.get_ticks_usec() - t0) / 1000.0
		if f % 15 != 0:
			continue
		max_sit = maxi(max_sit, life.crowd.count_act(Crowd.Act.SIT))
		max_wait = maxi(max_wait, life.crowd.count_act(Crowd.Act.WAIT))
		max_chat = maxi(max_chat, life.crowd.count_act(Crowd.Act.CHAT))
		max_dogs = maxi(max_dogs, life.crowd.dog_count())
		max_bus = maxi(max_bus, life.traffic.bus_count())
		var ph := 0
		for p in life.crowd.peds:
			if p.phone and p.act == Crowd.Act.WALK:
				ph += 1
			if p.act == Crowd.Act.WALK and p.flee <= 0.0:
				walk_into += _inside_prop(sp, p.pos)
			if (p.act == Crowd.Act.SIT) and p.go >= 1.0 and p.pos.distance_to(p.spot.slot_pos(p.slot)) > 0.05:
				seat_off += 1
		max_phone = maxi(max_phone, ph)
	var avg := total_ms / frames
	print("  4 min at lunch: %.2f ms/step, peak sitting %d, waiting %d, chatting %d, phones %d, dogs %d, buses %d, stops %d, boarded %d" % [avg, max_sit, max_wait, max_chat, max_phone, max_dogs, max_bus, bus_stops[0], life.boarded])
	check(max_sit > 0, "people sit on benches (%d)" % max_sit)
	check(max_wait > 0, "people wait at bus stops (%d)" % max_wait)
	check(max_chat >= 2, "people stand around chatting (%d)" % max_chat)
	check(max_phone > 0, "people walk along on their phones (%d)" % max_phone)
	check(max_dogs > 0, "people walk dogs (%d)" % max_dogs)
	check(max_bus > 0, "buses run (%d)" % max_bus)
	check(bus_stops[0] > 0, "buses pull in at stops (%d)" % bus_stops[0])
	check(life.boarded > 0, "people get on the bus (%d)" % life.boarded)
	check(walk_into == 0, "walkers step around benches and shelters (%d inside)" % walk_into)
	check(seat_off == 0, "sitters sit on the seats")
	check(avg < 8.0, "street life fits a laptop frame (%.2f ms)" % avg)
	var leaks := 0
	for s in sp.spots:
		for p in s.taken:
			if p != null and (not life.crowd.peds.has(p) or p.spot != s):
				leaks += 1
	check(leaks == 0, "no seats held by people who left (%d)" % leaks)

	# --- crash ------------------------------------------------------------------------
	var target: Crowd.Ped = null
	for p in life.crowd.peds:
		if p.act == Crowd.Act.WALK and p.arm < 0 and p.flee <= 0.0:
			target = p
			break
	var stare := life.report_crash(target.pos + target.fwd * 9.0, 2)
	var gawkers := 0
	for p in life.crowd.peds:
		if p.gawk:
			gawkers += 1
	check(stare > 0 and gawkers > 0, "people stop to stare at a crash (%d of %d nearby)" % [gawkers, stare])
	for f in 30 * 10:
		life.step(dt)
	gawkers = 0
	for p in life.crowd.peds:
		if p.gawk:
			gawkers += 1
	check(gawkers == 0, "and then walk on")

	# --- commute vs lunch --------------------------------------------------------------
	life.crowd.hour = 8.0
	var commute_sit := life.crowd.sit_share()
	life.crowd.hour = 12.5
	check(commute_sit < life.crowd.sit_share(), "commuters sit less than the lunch crowd")

	# --- nightlife -----------------------------------------------------------------------
	city.minutes = float(city.game_day()) * 1440.0 + 23.0 * 60.0
	life._update_area()
	var before := life.want_peds
	var club := -1
	var c0 := city.center_cell()
	for r in range(2, 20):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if club < 0 and city.can_place_special("nightclub", c0 + Vector2i(dx, dy), true) == "":
					club = city.place_special("nightclub", c0 + Vector2i(dx, dy), -1, true)
		if club >= 0:
			break
	check(club >= 0, "placed a nightclub")
	life._update_area()
	var lt := 0.0
	for v in life.nightlife:
		lt += v
	print("  11pm people: %d before the club, %d after" % [before, life.want_peds])
	check(lt > 0.0 and life.want_peds > before, "a nightclub keeps its block busy at night")
	var inc := life.ped_night.duplicate()
	life.compute_weights()
	var diff := 0.0
	for i in inc.size():
		diff = maxf(diff, absf(inc[i] - life.ped_night[i]))
	check(diff < 0.001, "night weights stay in step incrementally (max diff %.4f)" % diff)

	print("crowd life: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


## 1 when pos is inside a bench or shelter footprint.
func _inside_prop(sp: StreetSpots, pos: Vector3) -> int:
	for s in sp.near(pos, 4.0):
		var l := s.xform.affine_inverse() * pos
		if s.kind == StreetSpots.Kind.BENCH:
			if absf(l.x) < 0.85 and l.z > -0.25 and l.z < 0.2:
				return 1
		elif l.x > -2.5 and l.x < 1.85 and l.z > -1.25 and l.z < 0.05:
			return 1
	return 0
