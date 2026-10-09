extends SceneTree
## Quests and the Missions node:  godot --headless --path . --script res://missions/tests/test_quests.gd

var failures := 0


class FakeRoom extends Node3D:
	var marks := {}
	func marker(n: String) -> Node3D:
		return marks.get(n)


class FakeInteriors extends Node:
	var current: FakeRoom = null
	var current_id := ""
	var current_building := {}
	var city: City
	func is_inside() -> bool:
		return current != null
	func door_info(kind: String) -> Dictionary:
		return {"door": Vector3(0, 0, 6)} if kind == "bank" else {}
	func door_transform(b: Dictionary) -> Transform3D:
		return Transform3D(Basis(), city.building_center(b))


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _tag(city: City, zone: int, tag: String, nm: String, avoid: Array) -> Dictionary:
	## Turn a grown zone building into a "placed special" for the test.
	for b in city.buildings.values():
		if b.zone == zone and not b.has("tags") and not (b.id in avoid):
			b.tags = [tag]
			b.name = nm
			return b
	return {}


func _play(d: MissionDirector, link: StreetLink, m: Mission) -> void:
	## Walk a fake player through every step of a job.
	d.start(m)
	var guard := 0
	while d.active == m and guard < 400:
		guard += 1
		var s := m.step()
		match s.do:
			"goto", "hold":
				link.fake_pos = m.step_pos()
				var need = s.get("car", null)
				if need is String:
					link.fake_car = m.mission_car
				elif need == null:
					pass
				else:
					link.fake_car = RefCounted.new() if need else null
				if s.get("clean", false):
					link.set_wanted(0)
			"vehicle":
				link.fake_car = m.mission_car
			"chase":
				m.target.take_hit()
			"collect":
				if not m.points.is_empty():
					link.fake_pos = m.points[0]
			"fight", "destroy":
				link.fake_pos = m.step_pos()
				d.crew.kill_all()
				if s.do == "destroy":
					m.mission_car.wrecked = true
			"defend":
				link.fake_pos = m.step_pos()
			"race":
				link.fake_car = RefCounted.new()
				if not m.points.is_empty():
					link.fake_pos = m.points[0]
			"rampage":
				link.crime.emit(&"murder")
		d.tick(0.5)


func _initialize() -> void:
	print("Quest tests")
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
	d.tags.stand_ins = false
	var qe := QuestEngine.new(prog, g, d.tags)
	check(qe.quests.filter(func(q): return not q.get("story", false)).size() == 4, "four side quests loaded")

	# Grand Opening: starts at once, population step passes in the grown demo city, waits on the bank.
	qe.update()
	check(qe.is_active("grand_opening"), "Grand Opening starts")
	check(qe.step_text(qe.get_def("grand_opening")) == "Build Second National Bank", "5,000 people already reached")
	check(not qe.is_active("the_bunker"), "The Bunker waits for a bunker")
	var used: Array = []
	var bank := _tag(city, City.Zone.COM, "bank", "Second National Bank", used)
	used.append(bank.id)
	qe.update()
	check(prog.quest("grand_opening").state == "done", "placing the bank finishes Grand Opening")
	check(prog.is_unlocked("job:armored_escort"), "reward unlocks armored escort jobs")
	check(d.generate("armored_escort") == null, "escort still needs a police HQ to be generated")

	# The Bunker: three payphone jobs in order, then the reward.
	var bunker := _tag(city, City.Zone.IND, "hideout", "The Bunker", used)
	used.append(bunker.id)
	qe.update()
	check(qe.is_active("the_bunker"), "The Bunker starts once bank and bunker exist")
	var jobs := qe.pending_jobs(d.templates, "payphone")
	check(jobs.size() == 1 and jobs[0][1] == "bunker_van", "payphone offers the van job first")
	check(qe.pending_jobs(d.templates, "radio").is_empty(), "radio has no bunker jobs")
	var cash0 := prog.cash()
	var g0 := g.value
	for want in ["bunker_van", "case_the_bank", "bank_job"]:
		jobs = qe.pending_jobs(d.templates, "payphone")
		check(not jobs.is_empty() and jobs[0][1] == want, "next job is %s" % want)
		if jobs.is_empty():
			break
		var m := d.generate(want, city.cell_center(40, 40))
		check(m != null, "%s generated: %s" % [want, m.summary() if m else "-"])
		if m == null:
			break
		if want == "bank_job":
			check(m.slots.start.name == "Second National Bank" and m.slots.end.name == "The Bunker",
				"bank job uses the placed bank and bunker")
		m.quest = "the_bunker"
		d.passed.connect(func(pm): qe.job_passed(pm.quest, pm.id), CONNECT_ONE_SHOT)
		_play(d, link, m)
		check(m.state == Mission.State.PASSED, "%s passed" % want)
	check(prog.quest("the_bunker").get("state", "") == "done", "The Bunker complete")
	check(prog.get_flag("bunker_upgraded", false) and prog.is_unlocked("route:kingpin"), "Bunker upgraded, Kingpin route open")
	check(prog.cash() > cash0 + 2500 and g.value < g0 - 20.0, "robbing the bank pays big and costs goodness (%.0f)" % g.value)
	check(link.wanted() == 0, "reaching the Bunker clears the wanted level")

	# Bank job pay depends on where the Mayor put the bunker.
	var near_pay := 0
	var far_pay := 0
	var dist := d.router.reachable(d.router.access_cell(bank))
	var best_near := 1 << 30
	var best_far := -1
	var near_b := {}
	var far_b := {}
	for b in city.buildings.values():
		if b.zone != City.Zone.IND or b.has("tags"):
			continue
		var c := d.router.access_cell(b)
		if c.x < 0:
			continue
		var t := dist[city.idx(c.x, c.y)]
		if t > 20 and t < best_near:
			best_near = t
			near_b = b
		if t > best_far:
			best_far = t
			far_b = b
	bunker.erase("tags")
	near_b.tags = ["hideout"]
	near_pay = d.generate("bank_job").pay
	near_b.erase("tags")
	far_b.tags = ["hideout"]
	far_pay = d.generate("bank_job").pay
	check(far_pay > near_pay, "a far-off bunker makes a bigger score ($%d at %d tiles vs $%d at %d)" % [far_pay, best_far, near_pay, best_near])

	# With enterable buildings the bank job means walking in and standing in the vault.
	near_b.erase("tags")
	far_b.erase("tags")
	bunker.tags = ["hideout"]
	bank.kind = "bank"
	var fi := FakeInteriors.new()
	fi.city = city
	root.add_child(fi)
	link.interiors = fi
	var bj := d.generate("bank_job", city.cell_center(40, 40))
	d.start(bj)
	link.fake_car = null
	link.fake_pos = bj.slots.start.pos
	d.tick(0.1)
	check(bj.step().do == "fight" and d.crew.alive() == 3, "guards outside the bank")
	d.crew.kill_all()
	d.tick(0.1)
	d.tick(0.1)
	check(bj.step_i == 1, "standing outside the bank isn't enough")
	var room := FakeRoom.new()
	root.add_child(room)
	var vault := Node3D.new()
	room.add_child(vault)
	vault.global_position = Vector3(0, 2500, 0)
	room.marks["vault"] = vault
	fi.current = room
	fi.current_id = "bank"
	fi.current_building = bank
	d.tick(0.1)
	check(bj.step_i == 3 and link.wanted() == 1, "walking in sets off the alarm")
	check(link.near_marker("vault", 3.0) == false, "no street player: marker check is off")
	d.fail("test")
	link.interiors = null
	link.set_wanted(0)

	# Clean Streets needs goodness 10 and a police station; three raids, then HQ.
	_tag(city, City.Zone.COM, "police", "Precinct 9", used)
	qe.update()
	check(not qe.is_active("clean_streets"), "Clean Streets waits for a good reputation")
	g.value = 15.0
	qe.update()
	check(qe.is_active("clean_streets"), "Clean Streets starts at goodness 15")
	d.tags.stand_ins = true  # no crime dens yet: a stand-in den
	for i in 3:
		var m := d.generate("raid_den", city.cell_center(40, 40))
		m.quest = "clean_streets"
		d.passed.connect(func(pm): qe.job_passed(pm.quest, pm.id), CONNECT_ONE_SHOT)
		_play(d, link, m)
	check(qe.step_text(qe.get_def("clean_streets")) == "Mayor: build Police Headquarters", "three raids done")
	_tag(city, City.Zone.COM, "police_hq", "Police Headquarters", used)
	qe.update()
	check(prog.quest("clean_streets").state == "done", "HQ finishes Clean Streets")

	# Lights On needs a blackout reported by services (no stats without the Progress store).
	qe.update()
	check(not qe.is_active("lights_on"), "Lights On waits for a blackout")

	# The Missions node runs headless without a street.
	var ms := Missions.new()
	root.add_child(ms)
	ms.setup(city, null)
	for i in 5:
		await process_frame
	check(ms.phones.size() > 0, "stand-in payphones placed (%d)" % ms.phones.size())
	check(ms.to_dict().has("stand_ins"), "missions section saves")
	ms.link.fake_pos = ms.phones[0] + Vector3(100, 0, 0)
	ms._phone_wait = 0.0
	ms._tick_phone(0.1)
	check(ms._ringing >= 0, "a payphone rings")
	if ms._ringing >= 0:
		ms.link.fake_pos = ms.phones[ms._ringing]
		ms._tick_phone(0.1)
		check(ms.director.active != null and ms.director.active.side == "bad", "answering starts a bad job")

	d.queue_free()
	ms.queue_free()
	print("FAILED: %d" % failures if failures else "All quest tests passed")
	quit(1 if failures else 0)
