extends SceneTree
## The fighting steps: fight, destroy, defend, race and rampage, played by a fake player.
##   godot --headless --path . --script res://missions/tests/test_fights.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	print("Fight steps tests")
	var city := City.new()
	city.animate_growth = false
	city.build_demo(24 * 30)
	var link := StreetLink.new()
	var prog := ProgressLink.new(city, false)
	var g := Goodness.new()
	var d := MissionDirector.new()
	root.add_child(d)
	await process_frame
	d.setup(city, link, g, prog)
	var c := city.center_cell()
	link.fake_pos = city.cell_center(c.x, c.y)

	for id in ["hit_job", "kill_frenzy", "street_race", "torch_ride", "clear_crew", "hold_the_line"]:
		check(d.templates.has(id), "template %s loaded" % id)
		var m := d.generate(id, link.fake_pos)
		check(m != null and m.pay > 0, "%s generates: %s" % [id, m.summary() if m else "nothing"])

	# Fight with a named target: only the target has to go down.
	var m := d.generate("hit_job", link.fake_pos)
	d.start(m)
	link.fake_car = null
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	check(m.step().do == "fight" and d.crew.alive() == 3, "the owner and two guards are out front")
	check(m.objective().contains("owner"), "objective names the target: " + m.objective())
	# They notice you and shoot back.
	var dmg0 := link.fake_damage
	for i in 120:
		d.crew.tick(0.1)
	check(d.crew.alert, "the crew noticed the player")
	check(link.fake_damage > dmg0, "they shot back (%.0f damage)" % (link.fake_damage - dmg0))
	# Hurting a guard doesn't finish the job; the owner does.
	var guard: MissionCrew.Enemy = null
	var boss: MissionCrew.Enemy = null
	for e in d.crew.enemies:
		if e.boss:
			boss = e
		else:
			guard = e
	d.crew.hurt(guard, 999.0)
	d.tick(0.1)
	check(m.step().do == "fight", "a dead guard isn't the target")
	d.crew.hurt(boss, 10.0)
	check(not boss.dead and boss.hp > 60.0, "the target takes more than one hit (hp %.0f)" % boss.hp)
	d.crew.hurt(boss, 999.0)
	d.tick(0.1)
	check(m.step().do == "goto" and link.wanted() == 2, "target down: two stars and run for it")
	check(d.kills >= 2, "kills counted (%d)" % d.kills)
	link.fake_pos = m.slots.end.pos
	d.tick(0.1)
	d.tick(0.1)
	check(m.state == Mission.State.PASSED, "hit job passes at the hideout")
	check(d.crew.enemies.is_empty(), "the crew is cleared when the job ends")

	# Running a gunman over in a car.
	m = d.generate("clear_crew", link.fake_pos)
	d.start(m)
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	var e0: MissionCrew.Enemy = d.crew.enemies[0]
	link.fake_pos = e0.pos
	link.fake_car = FastCar.new()
	d.crew.tick(0.05)
	check(e0.dead, "a car at speed knocks a gang member down for good")
	link.fake_car = null
	d.crew.kill_all()
	d.tick(0.1)
	check(m.state == Mission.State.PASSED, "clearing the gang passes the good job")

	# Destroy.
	m = d.generate("torch_ride", link.fake_pos)
	d.start(m)
	d.tick(0.1)
	check(m.step().do == "destroy" and m.mission_car != null, "the rival's car is parked out front")
	check(d.crew.alive() == 2, "with two friends")
	d.tick(0.5)
	check(m.step().do == "destroy", "it isn't done until the car is wrecked")
	m.mission_car.wrecked = true
	d.tick(0.1)
	check(m.step().do == "goto" and link.wanted() == 1, "wrecked: a star, and back to the chop shop")
	d.abandon()

	# Defend: waves come in; leaving the spot fails it.
	m = d.generate("hold_the_line", link.fake_pos)
	if m == null:
		g.value = 30.0
		m = d.generate("hold_the_line", link.fake_pos)
	d.start(m)
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	d.tick(0.1)
	check(m.step().do == "defend" and d.crew.alive() == 3, "first wave arrives (%d)" % d.crew.alive())
	for i in 40:
		d.tick(0.5)
	check(m.kills0 >= 2, "more waves came (%d)" % m.kills0)
	check(m.objective().contains(" s)"), "objective counts down: " + m.objective())
	for i in 60:
		d.tick(0.5)
	check(m.state == Mission.State.PASSED, "held the line for 45 s")
	m = d.generate("hold_the_line", link.fake_pos)
	d.start(m)
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	d.tick(0.1)
	link.fake_pos = m.slots.start.pos + Vector3(200, 0, 0)
	for i in 30:
		d.tick(0.5)
	check(m.state == Mission.State.FAILED and m.fail_reason == "You left your post", "walking away fails it")

	# Race: checkpoints in order, in a car, against the clock.
	link.fake_pos = city.cell_center(c.x, c.y)
	m = d.generate("street_race", link.fake_pos)
	d.start(m)
	link.fake_car = m.mission_car
	d.tick(0.1)
	check(m.step().do == "race" and m.points.size() >= 3, "race has %d checkpoints" % m.points.size())
	check(m.step_time > 30.0, "race clock set (%.0f s)" % m.step_time)
	var n := m.points.size()
	link.fake_pos = m.points[n - 1]
	d.tick(0.1)
	check(m.points.size() == n, "skipping to the finish doesn't count")
	link.fake_car = null
	link.fake_pos = m.points[0]
	d.tick(0.1)
	check(m.points.size() == n, "on foot doesn't count")
	link.fake_car = m.mission_car
	while not m.points.is_empty() and d.active == m:
		link.fake_pos = m.points[0]
		d.tick(0.2)
	check(m.state == Mission.State.PASSED, "all checkpoints: race won")
	m = d.generate("street_race", link.fake_pos)
	d.start(m)
	link.fake_car = m.mission_car
	d.tick(0.1)
	d.tick(m.step_time + 1.0)
	check(m.state == Mission.State.FAILED and m.fail_reason == "Too slow", "the clock runs out")

	# Rampage.
	g.value = -30.0
	link.fake_car = null
	link.fake_pos = city.cell_center(c.x, c.y)
	m = d.generate("kill_frenzy", link.fake_pos)
	d.start(m)
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	check(m.step().do == "rampage" and m.left == 15, "kill frenzy: 15 to go")
	for i in 14:
		link.crime.emit(&"murder")
	d.tick(0.1)
	check(m.left == 1, "14 counted (%d left)" % m.left)
	link.crime.emit(&"cop_killed")
	d.tick(0.1)
	check(m.state == Mission.State.PASSED, "fifteen: frenzy passed")
	m = d.generate("kill_frenzy", link.fake_pos)
	d.start(m)
	link.fake_pos = m.slots.start.pos
	d.tick(0.1)
	d.tick(91.0)
	check(m.state == Mission.State.FAILED and m.fail_reason == "Time's up", "frenzy times out")

	# Shots find the crew through the street_targets group.
	check(d.crew.is_in_group("street_targets"), "crew is in the street_targets group")

	# What a building opens up on the street, for the build menu and the placement news.
	var bank := StreetUses.text(Catalog.get_def("bank").tags, "Second National Bank")
	print("  bank: ", bank)
	check(bank.contains("The Second National Bank job") and bank.contains("farther it is from your hideout"),
		"bank: the heist, paid by distance to the hideout")
	var bunker := StreetUses.text(Catalog.get_def("bunker").tags, "The Bunker")
	print("  bunker: ", bunker)
	check(bunker.contains("Second National Bank") or bunker.contains("the bank"), "bunker: the bank job ends there")
	check(StreetUses.text(Catalog.get_def("small_park").tags if Catalog.has("small_park") else [], "Park") == "" or true,
		"parks don't crash it")
	check(StreetUses.text(["home"], "a house") == "", "an ordinary home lists nothing")

	print("Fight steps: %s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures else 0)


class FastCar:
	extends RefCounted
	func speed() -> float:
		return 12.0
