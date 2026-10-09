extends SceneTree
## Contacts, landmark jobs, the three-act story, medals, replays and city effects:
##     godot --headless --path . --script res://missions/tests/test_story.gd

var failures := 0


class FakeNav extends Node:
	var marks := {}
	func mark(id: String, where: Variant, opts := {}) -> void:
		marks[id] = [where, opts]
	func unmark(id: String) -> void:
		marks.erase(id)
	func unmark_prefix(prefix: String) -> void:
		for id in marks.keys():
			if id.begins_with(prefix):
				marks.erase(id)
	func has_mark(id: String) -> bool:
		return marks.has(id)


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


var _placed: Array[Vector2] = []
var _ms: Missions


func _tag(city: City, zone: int, tags: Array, nm: String, kind := "") -> Dictionary:
	## Turn a grown zone building into a placed landmark for the test, spread out from the
	## others the way a mayor would place them.
	var best: Dictionary = {}
	var best_d := -1.0
	for b in city.buildings.values():
		if b.zone != zone or b.has("tags") or not _ms.specials.connected(b):
			continue
		var at := Vector2(b.x, b.y)
		var d := 1e9
		for q in _placed:
			d = minf(d, at.distance_to(q))
		d = minf(d, 30.0)  # far enough; prefer the first such building
		if d > best_d:
			best_d = d
			best = b
	if best.is_empty():
		return best
	best.tags = tags
	best.name = nm
	if kind != "":
		best.kind = kind
	_placed.append(Vector2(best.x, best.y))
	return best


func _play(ms: Missions, m: Mission) -> void:
	## Walk a fake player through every step, then hand the result to Missions.
	var d := ms.director
	var link := ms.link
	d.start(m)
	var guard := 0
	while d.active == m and guard < 600:
		guard += 1
		var s := m.step()
		match s.do:
			"goto", "hold":
				link.fake_pos = m.step_pos()
				var need = s.get("car", null)
				if need is String:
					link.fake_car = m.mission_car
				elif need is bool:
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
	link.set_wanted(0)  # Missions._on_passed runs from the director's passed signal


func _story_job(ms: Missions, giver: String, quest: String) -> Mission:
	## The job this quest is waiting on, as its giver would hand it out.
	ms.quests.update()
	for pair in ms.quests.pending_jobs(ms.director.templates, giver):
		if pair[0] == quest:
			var m := ms.director.generate(pair[1], ms.link.fake_pos)
			if m:
				m.quest = quest
				m.story = true
			return m
	return null


func _initialize() -> void:
	print("Story tests")
	var city := City.new()
	city.animate_growth = false
	city.build_demo(24 * 30)
	var ms := Missions.new()
	root.add_child(ms)
	await process_frame
	ms.setup(city, null)
	await process_frame
	var d := ms.director
	var p := ms.progress
	_ms = ms
	var c := ms.contacts
	if p.store:
		p.store.city = city  # city funds go through the Progress autoload
	ms.link.fake_pos = city.cell_center(40, 40)

	# ---------------------------------------------------------------- contacts ---
	check(c.get_respect("marchetti") == Contacts.START and c.rank("ruiz") == "Nobody", "everyone starts at 10 respect")
	check(Contacts.of_template(d.templates["taxi"]) == "ruiz" and Contacts.of_template(d.templates["getaway"]) == "marchetti"
		and Contacts.of_template(d.templates["hart_expose"]) == "hart", "jobs belong to their giver's contact")
	var ch := c.earn("marchetti", 6.0)
	check(c.get_respect("marchetti") == 16.0 and c.get_respect("ruiz") == 7.0, "working for Marchetti costs Ruiz half")
	check(Contacts.change_text(ch) == "Marchetti +6  Ruiz -3", "pass banner text: " + Contacts.change_text(ch))
	c.earn("hart", 5.0)
	check(c.get_respect("marchetti") == 16.0 and c.get_respect("ruiz") == 7.0, "Hart has no rival")
	var ranks: Array = []
	c.rank_changed.connect(func(who, r, up): ranks.append([who, r, up]))
	c.add("ruiz", 15.0)
	check(ranks.size() == 1 and ranks[0][1] == "Known face", "rank up news at 20")
	ms.goodness.value = -60.0
	check(not d.eligible(d.templates["racket"]), "racket needs 30 respect with Marchetti")
	c.add("marchetti", 20.0)
	check(d.eligible(d.templates["racket"]), "and is offered once he trusts you")
	check(not d.eligible(d.templates["casino_heist"]), "the casino heist waits for its story chapter")
	ms.goodness.value = 0.0

	# ---------------------------------------------------------------- landmarks ---
	var casino := _tag(city, City.Zone.COM, ["casino", "nightlife", "robbable", "landmark"], "The Golden Ace Casino", "casino")
	_tag(city, City.Zone.IND, ["hideout", "bunker"], "The Bunker")
	_tag(city, City.Zone.IND, ["airfield", "escape", "landmark"], "Municipal Airfield")
	_tag(city, City.Zone.IND, ["warehouse", "industrial"], "Pier 4 Warehouse")
	_tag(city, City.Zone.COM, ["stadium", "sports", "landmark"], "City Stadium")
	_tag(city, City.Zone.COM, ["radio_tower", "landmark"], "KMAY Radio Tower")
	_tag(city, City.Zone.COM, ["police"], "Precinct 9")
	_tag(city, City.Zone.RES, ["park"], "Central Park")
	var landmark_jobs := ["casino_heist", "card_counter", "game_day", "runway_cargo", "pirate_take", "pirate_back",
		"hart_rally", "ruiz_stakeout", "hart_site_guard", "hart_expose"]
	for id in landmark_jobs:
		var m := d.generate(id, ms.link.fake_pos)
		check(m != null and m.pay > 0 and not ("{" in m.brief), "%s: %s" % [id, m.summary() if m else "could not generate"])

	# ------------------------------------------------------------------- Act I ---
	ms.quests.update()
	check(not ms.quests.is_active("council_business"), "no story before Small city")
	check(ms.act() == 0, "act 0 before Small city")
	p.fake_tier = 2
	check(ms.act() == 1, "Small city opens Act I")
	var m1 := _story_job(ms, "council", "council_business")
	check(m1 != null and m1.id == "hart_site_guard" and m1.story, "Hart's first story job comes from City Hall")
	var hart0 := c.get_respect("hart")
	_play(ms, m1)
	check(m1.state == Mission.State.PASSED, "site guarded")
	check(c.get_respect("hart") == hart0 + 4.0, "Hart respect +4 (the template's)")
	check(ms.medals.medal("hart_site_guard") > 0, "story job earns a medal (%s)" % Medals.NAMES[ms.medals.medal("hart_site_guard")])
	var m2 := _story_job(ms, "council", "council_business")
	_play(ms, m2)
	check(p.quest("council_business").get("state", "") == "done", "Council Business done")
	check(c.get_respect("hart") >= hart0 + 18.0, "chapter reward adds respect")
	check(ms.quests.is_active("friends_of_the_family"), "Marchetti's chapter is open (respect %d)" % c.get_respect("marchetti"))

	# Hart's messages: offered in either view, Y takes them.
	ms._council_offer = null
	ms._council_wait = 0.0
	ms._tick_council(0.1)
	check(ms._council_offer != null and ms._council_offer.giver == "council", "Hart sends a job (%s)" %
		(ms._council_offer.title if ms._council_offer else "-"))
	check(ms.offer_side() == "council" and ms.offer_text().begins_with("CITY HALL"), "the offer box shows City Hall")
	check(ms.take_council_job() and d.active != null, "Y takes Hart's job")
	d.abandon()

	# ------------------------------------------------------------------ Act II ---
	p.fake_tier = 3
	p.set_quest("friends_of_the_family", {"state": "done", "step": 2, "done": 0})
	c.respect["marchetti"] = 45.0
	ms.goodness.value = -20.0
	var heist := _story_job(ms, "payphone", "house_always_loses")
	check(heist != null and heist.id == "casino_heist", "The House Always Loses hands out the casino heist")
	var funds0 := city.funds
	_play(ms, heist)
	check(heist.state == Mission.State.PASSED and heist.pay >= 6000, "casino robbed for $%d" % heist.pay)
	check(ms.effects.is_active("casino_robbed"), "the robbed casino earns less")
	var funds1 := city.funds
	ms.effects.day_passed()
	check(city.funds < funds1, "a day of casino losses comes out of city funds (%.0f)" % (city.funds - funds1))
	check(funds1 < funds0, "the heist itself cost the city")
	check(d.eligible(d.templates["casino_heist"]), "after the chapter, casino heists repeat on the payphones")
	# Two quests race for the radio tower; the first one done drops the other.
	c.respect["ruiz"] = 35.0
	ms.quests.update()
	check(ms.quests.is_active("pirate_radio") and ms.quests.is_active("dead_air"), "both sides want the tower")
	var pirate := _story_job(ms, "payphone", "pirate_radio")
	_play(ms, pirate)
	ms.quests.update()
	check(p.quest("pirate_radio").get("state", "") == "done" and p.quest("dead_air").get("state", "") == "dropped",
		"Marchetti takes the tower; Ruiz's chapter is dropped")

	# ----------------------------------------------------------------- Act III ---
	p.fake_tier = 5
	c.respect["marchetti"] = 80.0
	ms.goodness.value = -60.0
	p.set_quest("hit_on_the_hill_quest", {"state": "done", "step": 2, "done": 0})
	ms.quests.update()
	check(ms.quests.is_active("the_big_one"), "The Big One opens for a Kingpin")
	check(ms.quests.step_text(ms.quests.get_def("the_big_one")) == "Mayor: build the Federal Reserve", "it waits on the Reserve")
	_tag(city, City.Zone.COM, ["bank", "vault", "robbable", "landmark"], "Federal Reserve")
	_tag(city, City.Zone.RES, ["mansion", "hideout"], "Mansion on the Hill")
	for id in ["hit_on_the_hill", "federal_reserve", "reserve_defense"]:
		var m := d.generate(id, ms.link.fake_pos)
		check(m != null and m.pay > 0, "%s: %s" % [id, m.summary() if m else "could not generate"])
	var endings: Array = []
	ms.quests.ending.connect(func(k): endings.append(k))
	var fed := _story_job(ms, "payphone", "the_big_one")
	check(fed != null and fed.id == "federal_reserve", "the finale is the Federal Reserve")
	_play(ms, fed)
	check(endings == ["kingpin"] and p.get_flag("ending", "") == "kingpin", "Kingpin ending")
	check(p.is_unlocked("ending:kingpin"), "the ending is recorded")
	c.respect["ruiz"] = 90.0
	ms.goodness.value = 60.0
	p.set_quest("count_me_out", {"state": "done", "step": 2, "done": 0})
	ms.quests.update()
	check(not ms.quests.is_active("thin_blue_line"), "no second ending")

	# ------------------------------------------------------------ medals, replay ---
	check(Medals.grade(30.0, 100.0, 5.0) == 3 and Medals.grade(80.0, 100.0, 5.0) == 2
		and Medals.grade(30.0, 100.0, 60.0) == 1, "gold, silver, bronze by time and damage")
	var list := ms.medals.replays()
	check(list.size() >= 4, "story jobs to replay (%d)" % list.size())
	var cash0 := p.cash()
	var g0 := ms.goodness.value
	var resp0 := c.to_dict()
	check(ms.replay(0) and d.active and d.active.replay, "1 in the quest log replays the first story job")
	var rp := d.active
	d.active = null
	_play(ms, rp)
	check(rp.state == Mission.State.PASSED, "replay passed")
	check(ms.goodness.value == g0 and c.to_dict() == resp0, "a replay changes no goodness or respect")
	check(p.cash() - cash0 == rp.pay, "a replay pays half ($%d)" % rp.pay)

	# ------------------------------------------------------------- city effects ---
	var fx := ms.effects
	var den := {"id": 999999, "x": 20, "y": 20}
	fx.add("den_busted", den, "The Rat Hole")
	check(fx.crime_mult(20, 20) < 0.6 and fx.crime_mult(60, 60) == 1.0, "a busted den lowers crime nearby only")
	var h0 := fx.happiness_add(1, 1)
	fx.add("game_day", casino, "City Stadium")
	check(fx.happiness_add(1, 1) - h0 > 0.05, "game day lifts happiness")
	check(city.get_meta("street_effects") == fx, "services/ can find the effects on the City")
	for i in 15:
		fx.day_passed()
	check(not fx.is_active("den_busted") and not fx.is_active("game_day"), "effects wear off")

	# ---------------------------------------------------------------- save, intro ---
	var saved := ms.to_dict()
	var ms2 := Missions.new()
	root.add_child(ms2)
	await process_frame
	ms2.setup(city, null)
	ms2.from_dict(JSON.parse_string(JSON.stringify(saved)))
	check(ms2.contacts.to_dict() == c.to_dict(), "respect survives a save")
	check(ms2.medals.replays().size() == list.size(), "medals survive a save")
	var done := [false]
	ms.intro.finished.connect(func(): done[0] = true, CONNECT_ONE_SHOT)
	ms.intro.play([[Vector3(100, 0, 100), "Somewhere"]], "Vinnie Marchetti", Color.RED, "\"Kid.\"")
	check(ms.intro.playing and paused, "the intro pauses the game")
	ms.intro.finish()
	check(done[0] and not paused, "skipping it unpauses and starts the job")

	# ---------------------------------------------------------------- minimap/GPS ---
	var nav := FakeNav.new()
	nav.add_to_group("city_nav")
	root.add_child(nav)
	var job := d.generate("runway_cargo", ms.link.fake_pos)
	d.start(job)
	ms._sync_nav(job, job.step_pos(), MissionHud.BAD)
	check(nav.marks.has("mission:goal") and nav.marks["mission:goal"][1].kind == "job", "the next objective is the GPS target")
	ms.link.fake_pos = job.step_pos()
	ms.link.fake_car = RefCounted.new()
	d.tick(0.5)
	ms._sync_nav(job, job.points[0], MissionHud.BAD)
	check(nav.marks.has("mission:pile0") and nav.marks.size() == 1 + job.points.size(), "crates show on the minimap (%d)" % job.points.size())
	d.abandon()
	ms._sync_nav(null, Vector3.INF, MissionHud.GOOD)
	check(not nav.marks.has("mission:goal") and not nav.marks.has("mission:pile0"), "marks clear when the job ends")
	ms.specials.spawn("film_shoot", city.buildings.values()[5])
	check(nav.marks.keys().any(func(k): return k.begins_with("mission:special:")), "spawned specials get a blip")

	ms.queue_free()
	ms2.queue_free()
	print("FAILED: %d" % failures if failures else "All story tests passed")
	quit(1 if failures else 0)
