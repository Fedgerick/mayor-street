extends SceneTree
## Spawned specials and perk effects:  godot --headless --path . --script res://missions/tests/test_specials.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _play(d: MissionDirector, link: StreetLink, m: Mission) -> void:
	d.start(m)
	var guard := 0
	while d.active == m and guard < 400:
		guard += 1
		var s := m.step()
		match s.do:
			"goto", "hold":
				link.fake_pos = m.step_pos()
				var need = s.get("car", null)
				if need is bool:
					link.fake_car = RefCounted.new() if need else null
				if s.get("clean", false):
					link.set_wanted(0)
			"collect":
				link.fake_pos = m.points[0]
		d.tick(0.5)


func _initialize() -> void:
	print("Specials and perks tests")
	var city := City.new()
	city.animate_growth = false
	city.build_demo(24 * 30)
	var ms := Missions.new()
	root.add_child(ms)
	await process_frame
	ms.setup(city, null)
	await process_frame
	var sp := ms.specials
	var d := ms.director
	var link := ms.link
	link.fake_pos = city.cell_center(40, 40)

	# Each special can be spawned, gets a name, and its jobs find it.
	var day0 := city.game_day()
	for kind in SpecialSpawner.DEFS:
		var host: Dictionary = {}
		for b in city.buildings.values():
			if not sp._taken(b.id) and sp.connected(b) and b.zone == (City.Zone.IND if kind in ["abandoned_warehouse", "substation"] else City.Zone.COM):
				host = b
				break
		if kind in ["armored_truck", "substation"]:
			host = sp._kerb(host)
		var s := sp.spawn(kind, host)
		check(d.tags.has_real(SpecialSpawner.DEFS[kind].tag), "%s spawned: %s" % [kind, s.name])
	check(sp.active.size() == 6, "six specials active")
	var jobs := 0
	for t in d.templates.values():
		if not t.has("special"):
			continue
		var m := d.generate(t.id, link.fake_pos)
		check(m != null, "%s generates (%s)" % [t.id, m.summary() if m else "-"])
		if m:
			jobs += 1
			check(not d.eligible(t), "%s stays out of the random pool" % t.id)
	check(jobs >= 9, "special jobs available (%d)" % jobs)

	# Offers prefer a special's job, and passing a resolving job removes the special.
	ms._rng.seed = 1
	var o: Mission = null
	for i in 10:
		o = ms._offer("radio", link.fake_pos)
		if o and o.template.has("special"):
			break
	check(o != null and o.template.has("special"), "the radio offers special jobs (%s)" % (o.id if o else "-"))
	var fire := d.generate("firefight", link.fake_pos)
	var fire_b: int = fire.slots.end.building
	_play(d, link, fire)
	ms._on_passed(fire)
	check(fire.state == Mission.State.PASSED and sp.of_tag("burning_building").is_empty(), "fighting the fire ends it")
	check(city.buildings.has(fire_b), "the building was saved")
	var truck := d.generate("return_cash", link.fake_pos)
	if truck:
		_play(d, link, truck)
		ms._on_passed(truck)
		check(sp.of_tag("armored_truck").is_empty(), "returning the cash clears the crashed truck")

	# Save and load keep the rest.
	var saved := sp.to_dict()
	var n := sp.active.size()
	sp.from_dict(saved)
	check(sp.active.size() == n, "specials survive a save (%d)" % n)

	# An unfought fire burns the building down when it expires.
	var victim: Dictionary = {}
	for b in city.buildings.values():
		if b.zone == City.Zone.RES and not sp._taken(b.id):
			victim = b
			break
	sp.spawn("burning_building", victim)
	var vid: int = victim.id
	for i in 2:
		city.minutes += 1440.0
		sp.daily()
	check(not city.buildings.has(vid), "a fire nobody fought burns the building down")

	# Everything expires in time.
	for i in 10:
		city.minutes += 1440.0
		sp.daily()
	var left := 0
	for s in sp.active:
		if int(s.day) <= day0:
			left += 1
	check(left == 0, "old specials expire")

	# Perks: stipend, black market, crew backup.
	var cash0 := ms.progress.cash()
	ms.goodness.value = 80.0
	ms.perks._on_day()
	check(ms.progress.cash() == cash0 + PerkEffects.STIPEND, "emergency-vehicle perk pays a daily stipend")
	ms.goodness.value = -30.0
	ms.progress.add_cash(1000)
	check(ms.perks.handle_key(KEY_P) and ms.perks.phone_open, "P opens the black market phone")
	check(ms.perks.phone_text().begins_with("BLACK MARKET"), "the phone lists the goods")
	ms.perks.handle_key(KEY_4)
	check(ms.progress.get_count("lock_picks") == 3, "lock picks bought")
	ms.perks.handle_key(KEY_P)
	check(not ms.perks.phone_open, "P hangs up")
	ms.goodness.value = 10.0
	check(not ms.perks.handle_key(KEY_P), "no phone without the perk")
	ms.goodness.value = -80.0
	check(ms.perks.handle_key(KEY_G) and not ms.perks._crew_called, "no crew without a bad job")
	var job := d.generate("getaway", link.fake_pos)
	d.start(job)
	link.fake_car = null
	ms.perks.handle_key(KEY_G)
	check(ms.perks._crew_called, "G calls the crew during a bad job")
	d.abandon()

	ms.queue_free()
	print("FAILED: %d" % failures if failures else "All specials tests passed")
	quit(1 if failures else 0)
