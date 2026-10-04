extends SceneTree
## Headless checks for missions/:  godot --headless --path . --script res://missions/tests/test_missions.gd

var failures := 0


class FakeCop:
	var pos: Vector3
	func _init(p: Vector3) -> void:
		pos = p


class FakePolice:
	var officers: Array = []
	var cars: Array = []


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	print("Missions tests")
	var city := City.new()
	city.animate_growth = false
	city.build_demo(24 * 30)
	check(city.population > 500, "demo city grew (%d people)" % city.population)

	# Roads: BFS route follows roads and its length matches the distance field.
	var router := RoadRouter.new(city)
	var some: Dictionary = city.buildings.values()[0]
	var a := router.access_cell(some)
	check(a.x >= 0 and city.is_road(a.x, a.y), "building has a road out front")
	var far := a
	var dist := router.reachable(a)
	for i in dist.size():
		if dist[i] > dist[city.idx(far.x, far.y)]:
			far = Vector2i(i % City.SIZE, i / City.SIZE)
	var path := router.route(a, far)
	check(path.size() == dist[city.idx(far.x, far.y)] + 1, "route length matches BFS (%d tiles)" % path.size())
	var all_road := true
	for c in path:
		all_road = all_road and city.is_road(c.x, c.y)
	check(all_road, "route stays on roads")

	# Goodness and perks.
	var g := Goodness.new()
	var gained: Array = []
	g.perk_gained.connect(func(p, _t): gained.append(p))
	g.add(30, "test")
	check(g.has_perk(&"shop_discount") and gained == [&"shop_discount"], "crossing +25 grants the first good perk")
	g.add(-90, "test")
	check(g.has_perk(&"black_market") and g.has_perk(&"chop_double") and not g.has_perk(&"shop_discount"),
		"dropping to -60 swaps to bad perks")
	g.value = 1.0
	g.day_passed()
	check(g.value == 0.0, "drift settles at zero")
	g.value = 0.0

	# Director: every template can be generated in the demo city with stand-ins.
	var link := StreetLink.new()
	var prog := ProgressLink.new(city, false)
	prog.unlock("job:armored_escort")
	var d := MissionDirector.new()
	root.add_child(d)
	await process_frame
	d.setup(city, link, g, prog)
	check(d.templates.size() >= 12, "templates loaded (%d)" % d.templates.size())
	link.fake_pos = city.cell_center(a.x, a.y)
	for id in d.templates:
		var m := d.generate(id, link.fake_pos)
		check(m != null and m.pay > 0 and m.route_m > 0.0,
			"%s: %s" % [id, m.summary() if m else "could not generate"])
		if m:
			check(not ("{" in m.brief or "{" in m.title), "%s: text filled in" % id)

	# Pay grows with road distance.
	var t: Dictionary = d.templates["taxi"]
	var short_m := INF
	var long_m := 0.0
	var short_pay := 0
	var long_pay := 0
	for i in 30:
		var m := d.generate("taxi")
		if m.route_m < short_m:
			short_m = m.route_m
			short_pay = m.pay
		if m.route_m > long_m:
			long_m = m.route_m
			long_pay = m.pay
	check(long_m > short_m and long_pay > short_pay, "longer taxi pays more (%d m $%d vs %d m $%d)" % [short_m, short_pay, long_m, long_pay])
	check(t.pay.per_km > 0, "taxi has a per-km rate")

	# Playing a taxi job with a fake player.
	var m := d.generate("taxi", link.fake_pos)
	check(d.start(m), "start taxi")
	link.fake_car = RefCounted.new()
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	check(m.step_i == 1, "reaching the fare advances to the pickup hold")
	for i in 25:
		d.tick(0.1)
	check(m.step_i == 2, "holding 2 s loads the fare")
	var cash0 := prog.cash()
	var funds0 := city.funds
	link.fake_pos = m.slots.end.pos
	d.tick(0.1)
	check(m.state == Mission.State.PASSED and d.active == null, "drop-off passes the job")
	check(prog.cash() == cash0 + m.pay, "pay goes to the Resident's wallet ($%d)" % m.pay)
	check(city.funds > funds0, "city bonus goes to city funds")
	check(g.value > 0.0, "good job raises goodness (%.1f)" % g.value)

	# On foot doesn't count for a car step; the timer fails a job.
	m = d.generate("ambulance", link.fake_pos)
	d.start(m)
	link.fake_car = null
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	check(m.step_i == 0, "car-only step ignores a player on foot")
	d.tick(m.time_limit + 1.0)
	check(m.state == Mission.State.FAILED and m.fail_reason == "Out of time", "timer runs out")

	# Collect step.
	m = d.generate("cleanup", link.fake_pos)
	d.start(m)
	check(m.points.size() == 5, "cleanup scatters 5 piles (%d)" % m.points.size())
	for p in m.points.duplicate():
		link.fake_pos = p
		d.tick(0.1)
	check(m.state == Mission.State.PASSED, "clearing every pile passes")

	# Vehicle step + wanted cap (smuggling fails on 2 stars), steal for car to order.
	g.value = -30.0
	m = d.generate("car_to_order", link.fake_pos)
	d.start(m)
	check(m.mission_car != null, "car to order spawns the target car")
	link.fake_car = m.mission_car
	var gv := g.value
	d.tick(0.1)
	check(m.step_i == 1 and g.value < gv, "stealing it advances and costs goodness")
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	check(m.state == Mission.State.PASSED and g.value < -30.0, "delivering it passes; bad job lowers goodness")
	m = d.generate("smuggling", link.fake_pos)
	d.start(m)
	link.set_wanted(2)
	d.tick(0.1)
	check(m.state == Mission.State.FAILED, "smuggling fails when the cops notice")
	link.set_wanted(0)

	# Getaway: the clean flag makes the hideout wait for zero stars.
	m = d.generate("getaway", link.fake_pos)
	d.start(m)
	link.fake_car = RefCounted.new()
	link.fake_pos = m.slots.pickup.pos
	for i in 40:
		d.tick(0.1)
	check(m.step_i == 3 and link.wanted() == 2, "crew in, two stars")
	link.fake_pos = m.slots.end.pos
	d.tick(0.1)
	check(m.state == Mission.State.ACTIVE, "hideout won't open with cops on you")
	link.set_wanted(0)
	d.tick(0.1)
	check(m.state == Mission.State.PASSED, "lost the cops, reached the hideout")

	# Offers respect sides and quest-only jobs.
	g.value = 0.0
	var seen := {}
	for i in 40:
		var o := d.make_offer("payphone")
		if o:
			seen[o.id] = true
	check(not seen.has("bank_job") and not seen.has("racket") and seen.has("car_to_order"),
		"payphones offer open bad jobs only (%s)" % ", ".join(seen.keys()))

	# Chase: the fleeing car drives on roads and is wrecked by hits.
	m = d.generate("vigilante", link.fake_pos)
	d.start(m)
	check(m.target is ChaseCar, "vigilante spawns the suspect car")
	await process_frame
	for i in 4:
		m.target.take_hit()
	d.tick(0.1)
	check(m.state == Mission.State.PASSED, "wrecking the suspect passes")

	# Bribes: price by stars, none at 4+, Ex-cop's one free a day, cooldown.
	var br := Bribe.new()
	check(br.status(0, true, 5000, 1, 0) == "", "no stars, no bribe")
	check(br.status(2, false, 5000, 1, 0) == "", "no cop nearby, no bribe")
	check(br.status(4, true, 5000, 1, 0) == "too_hot", "nobody takes a bribe at 4 stars")
	check(br.status(3, true, 100, 1, 0) == "broke", "too poor for 3 stars")
	check(br.status(2, true, 1000, 1, 0) == "ok" and br.pay(2, 1, 0) == 600, "2 stars cost $600")
	check(br.status(1, true, 1000, 1, 0) == "cooldown", "a minute between bribes")
	br.tick(61.0)
	check(br.status(1, true, 0, 2, 1) == "ok", "ex-cop with no cash can still call in a favor")
	check(br.pay(3, 2, 1) == 0, "the ex-cop favor is free")
	br.tick(61.0)
	check(br.status(1, true, 0, 2, 1) == "broke" and br.pay(1, 2, 1) == 250, "only one free bribe a day")
	br.tick(61.0)
	check(br.free_left(3, 1) == 1, "a new day brings a new favor")
	var pol := FakePolice.new()
	pol.officers = [FakeCop.new(Vector3(10, 0, 0))]
	check(Bribe.cop_near(pol, Vector3.ZERO) and not Bribe.cop_near(pol, Vector3(30, 0, 0)), "cop within 12 m counts")

	d.queue_free()
	print("FAILED: %d" % failures if failures else "All missions tests passed")
	quit(1 if failures else 0)
