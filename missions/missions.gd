class_name Missions
extends Node3D
## Everything missions/ adds to a game, in one node: the director, payphones that ring with
## bad jobs, the dispatch radio with good jobs, the goodness scale, quests, the HUD, the
## quest log and the 3D markers. main.gd creates it after StreetMode:
##
##     missions = Missions.new()
##     add_child(missions)
##     missions.setup(city, street)
##
## Keys: J quest log (either view; with it open at street level, 1-9 replay a story job);
## at street level Y takes a radio job or Councilwoman Hart's job, K abandons a job, B bribes
## a nearby cop (bribe.gd); P black market phone and G crew backup with those perks
## (perk_effects.gd).
##
## Round 3: three contacts with respect (contacts.gd), story quests in three acts with a
## Hero or Kingpin ending (data/quests.json), a fly-by before story jobs (mission_intro.gd),
## medals and replays (medals.gd), and street results that change the city (city_effects.gd).

const PHONE_RADIUS := 2.6        # walk this close to a ringing phone to answer it
const PHONE_MIN_M := 50.0        # a phone rings somewhere this far ...
const PHONE_MAX_M := 320.0       # ... to this far from you
const RING_SECONDS := 45.0
const RADIO_GAP := Vector2(14.0, 28.0)   # seconds between radio calls while driving
const PHONE_GAP := Vector2(12.0, 30.0)   # seconds between rings
const OFFER_SECONDS := 16.0
const STAND_IN_PHONES := 8
const COUNCIL_GAP := Vector2(70.0, 160.0)  # seconds between Hart's messages
const COUNCIL_KEEP := 240.0                # how long her job waits to be taken
const COUNCIL_SHOW := 14.0                 # seconds the full message stays in the offer box
const ACT_TIERS := [2, 3, 5]               # Small city, City, Metropolis

var city: City
var street: Node
var link: StreetLink
var progress: ProgressLink
var goodness: Goodness
var director: MissionDirector
var quests: QuestEngine
var hud: MissionHud
var log_panel: QuestLog
var bribe := Bribe.new()
var perks: PerkEffects
var specials: SpecialSpawner
var contacts := Contacts.new()
var medals := Medals.new()
var effects: CityEffects
var intro: MissionIntro
var phones: Array[Vector3] = []   # payphone handsets on the sidewalk

var _layer: CanvasLayer
var _beacon: MeshInstance3D
var _target_mark: MeshInstance3D
var _piles: Array[Node3D] = []
var _phone_root: Node3D
var _ringing := -1               # index into phones
var _ring_offer: Mission = null
var _ring_t := 0.0
var _phone_wait := 8.0
var _radio_offer: Mission = null
var _radio_t := 0.0
var _radio_wait := 10.0
var _brief := ""                 # text shown in the offer box after answering
var _brief_side := ""
var _brief_t := 0.0
var _quest_t := 0.0
var _phones_dirty := true
var _bribe_state := ""           # Bribe.status() for the HUD hint
var _council_offer: Mission = null
var _council_t := 0.0
var _council_show := 0.0
var _council_wait := 30.0
var _nav_goal := Vector3.INF     # last target sent to navigation/
var _nav_kind := ""
var _nav_piles := 0
var _nav_step := -1
var _rng := RandomNumberGenerator.new()


func setup(c: City, s: Node) -> void:
	city = c
	street = s
	_rng.seed = 5150
	link = StreetLink.new(s)
	use_interiors(get_parent().get("interiors") if get_parent() else null)
	progress = ProgressLink.new(c)
	goodness = Goodness.new()
	goodness.value = progress.goodness()
	director = MissionDirector.new()
	director.name = "Director"
	add_child(director)
	director.contacts = contacts
	director.setup(c, link, goodness, progress)
	quests = QuestEngine.new(progress, goodness, director.tags)
	quests.contacts = contacts
	quests.templates = director.templates
	effects = CityEffects.new(c, progress)
	effects.news.connect(func(text): _news(text, 5.0))
	c.day_passed.connect(effects.day_passed)
	contacts.rank_changed.connect(func(who, rank, up):
		if up:
			_news("%s: you're %s now" % [Contacts.display_name(who), rank], 5.0)
		else:
			_news("%s doesn't trust you like before (%s)" % [Contacts.display_name(who), rank], 5.0))
	quests.ending.connect(_on_ending)
	quests.quest_dropped.connect(func(q): _quest_news("%s: someone else got there first" % q.title, q))

	goodness.changed.connect(_on_goodness)
	goodness.perk_gained.connect(func(p, text):
		progress.unlock("perk:" + p, "goodness")
		_news("Perk: " + text, 6.0))
	goodness.perk_lost.connect(func(p, text):
		progress.lock("perk:" + p)
		_news("Lost perk: " + text, 5.0))
	if progress.store:
		progress.store.goodness_changed.connect(func(v, _d, _r): goodness.value = v)
	link.goodness_action.connect(goodness.action)
	c.day_passed.connect(goodness.day_passed)
	c.building_added.connect(func(id, _a):
		_quest_t = 0.0
		_phones_dirty = true
		_announce(id))
	c.building_removed.connect(func(_id): _phones_dirty = true)

	director.started.connect(_on_started)
	director.passed.connect(_on_passed)
	director.failed.connect(_on_failed)
	director.step_changed.connect(_on_step)
	quests.quest_started.connect(func(q): _quest_news("New quest: " + q.title, q))
	quests.quest_advanced.connect(func(q): _quest_news(q.title + ": " + quests.step_text(q), q))
	quests.quest_done.connect(func(q): _quest_news("Quest complete: %s. %s" % [q.title, q.get("reward", {}).get("note", "")], q))

	_build_world()
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)
	hud = MissionHud.new()
	hud.missions = self
	_layer.add_child(hud)
	log_panel = QuestLog.new()
	log_panel.missions = self
	_layer.add_child(log_panel)
	intro = MissionIntro.new()
	intro.name = "Intro"
	add_child(intro)
	perks = PerkEffects.new()
	perks.name = "Perks"
	add_child(perks)
	perks.setup(self)
	specials = SpecialSpawner.new()
	specials.name = "Specials"
	add_child(specials)
	specials.setup(c, director.tags, director.router, progress)
	specials.spawned.connect(func(sp):
		_news("Reported: " + sp.name, 5.0)
		_mark_special(sp))
	specials.ended.connect(func(sp, ok):
		var nav = _nav()  # CityNav, untyped so missions/ loads without navigation/
		if nav:
			nav.unmark("mission:special:%d" % sp.id)
		if not ok and sp.kind == "burning_building":
			_news(sp.name.replace("Fire at", "Burned down:"), 5.0))
	_mark_specials.call_deferred()
	_sync_perks()
	if progress.store:
		progress.store.register_section("missions", self)


func use_interiors(im: Node) -> void:
	## Enterable buildings (interiors/InteriorManager): the bank job walks in and cracks
	## the vault marker. Picked up from main.gd's `interiors` when it exists.
	link.interiors = im


func _sync_perks() -> void:
	## Perk unlocks follow the scale (a save may predate a perk, or drift may have passed).
	for p in Goodness.PERKS:
		if goodness.has_perk(p[1]):
			if not progress.is_unlocked("perk:" + p[1]):
				progress.unlock("perk:" + p[1], "goodness")
		elif progress.is_unlocked("perk:" + p[1]):
			progress.lock("perk:" + p[1])


# ----------------------------------------------------------------- per frame ---

func _process(delta: float) -> void:
	if quests == null:
		return  # not set up yet
	_quest_t -= delta
	if _quest_t <= 0.0:
		_quest_t = 1.0
		quests.update()
	_tick_council(delta)
	var at_street := link.active()
	hud.visible = at_street
	if _phones_dirty:
		_phones_dirty = false
		_place_phones()
	if not at_street or link.inside() != "":
		_hide_markers()
		if not at_street:
			return
	_brief_t = maxf(0.0, _brief_t - delta)
	bribe.tick(delta)
	perks.tick(delta)
	_bribe_state = bribe.status(link.wanted(), Bribe.cop_near(_police(), link.position()),
		progress.cash(), city.game_day(), _free_bribes())
	if director.active == null:
		_tick_phone(delta)
		_tick_radio(delta)
	if link.inside() == "":
		_update_markers()


func _tick_phone(delta: float) -> void:
	if _ringing >= 0:
		var before := _ring_t
		_ring_t -= delta
		var p := phones[_ringing]
		if fmod(before, 5.0) < fmod(_ring_t, 5.0):  # the ring sound is one 4 s burst
			_play_at("phone_ring", p, "notify")
		if link.car() == null and MissionDirector.flat_dist(link.position(), p) < PHONE_RADIUS:
			_answer_phone()
		elif _ring_t <= 0.0:
			_stop_ring()
		return
	_phone_wait -= delta
	if _phone_wait > 0.0 or phones.is_empty():
		return
	_phone_wait = _rng.randf_range(PHONE_GAP.x, PHONE_GAP.y)
	var me := link.position()
	var cands: Array[int] = []
	for i in phones.size():
		var d := MissionDirector.flat_dist(me, phones[i])
		if d > PHONE_MIN_M and d < PHONE_MAX_M:
			cands.append(i)
	if cands.is_empty():
		return
	var offer := _offer("payphone", me)
	if offer == null:
		return
	_ringing = cands[_rng.randi() % cands.size()]
	_ring_offer = offer
	_ring_t = RING_SECONDS
	_play_at("phone_ring", phones[_ringing], "notify")
	hud.news("A payphone is ringing nearby", 3.0)


func _answer_phone() -> void:
	var m := _ring_offer
	_stop_ring()
	_brief = m.brief
	_brief_side = m.side
	_brief_t = 7.0
	begin(m)


func begin(m: Mission) -> void:
	## Starts a job; story jobs and replays first get a fly-by over their places.
	if not (m.story or m.replay) or link.street == null or intro.playing:
		director.start(m)
		return
	var places: Array = []
	var seen: Array = []
	var order: Array = m.template.get("route", [])
	if order.is_empty():
		order = m.slots.keys()
	for slot in order:
		var b: Dictionary = director.tags.building(m.slots[slot].building)
		if b.is_empty() or b.id in seen:
			continue
		seen.append(b.id)
		places.append([city.building_center(b), m.slots[slot].name])
	var who := Contacts.display_name(m.contact)
	var col: Color = Contacts.PEOPLE.get(m.contact, {}).get("color", Color(1, 0.82, 0.2))
	intro.finished.connect(func(): director.start(m), CONNECT_ONE_SHOT)
	intro.play(places, who + ("   (replay)" if m.replay else ""), col, m.brief)


func _stop_ring() -> void:
	_ringing = -1
	_ring_offer = null


func _tick_radio(delta: float) -> void:
	if _radio_offer:
		_radio_t -= delta
		if _radio_t <= 0.0 or link.car() == null:
			_radio_offer = null
			_radio_wait = _rng.randf_range(RADIO_GAP.x, RADIO_GAP.y)
		return
	if link.car() == null:
		return
	_radio_wait -= delta
	if _radio_wait > 0.0:
		return
	_radio_wait = _rng.randf_range(RADIO_GAP.x, RADIO_GAP.y)
	_radio_offer = _offer("radio", link.position())
	if _radio_offer:
		_radio_t = OFFER_SECONDS
		_play_ui("radio_static", "notify")


func _offer(giver: String, from: Vector3) -> Mission:
	## Quest jobs first, then a random one.
	for pair in quests.pending_jobs(director.templates, giver):
		var m := director.generate(pair[1], from)
		if m:
			m.quest = pair[0]
			m.story = quests.get_def(pair[0]).get("story", false)
			return m
	if _rng.randf() < 0.7:
		for sp in specials.active:
			for t in director.templates.values():
				if t.get("special", "") == sp.kind and t.giver == giver:
					var m := director.generate(t.id, from)
					if m:
						return m
	return director.make_offer(giver, from)


func offer_text() -> String:
	## For the HUD's offer box.
	var phone := perks.phone_text()
	if phone != "":
		return phone
	if _brief_t > 0.0 and _brief != "":
		return _brief
	if _radio_offer and director.active == null:
		return "DISPATCH  %s\n%s\nPress Y to take it  ($%d, %.1f km)" % [
			"(story)" if _radio_offer.story else ("(quest)" if _radio_offer.quest != "" else ""),
			_radio_offer.brief, _radio_offer.pay, _radio_offer.km()]
	if _council_offer and director.active == null:
		if _council_show > 0.0:
			return "CITY HALL  %s\n%s\nPress Y to take it  ($%d, %.1f km)" % [
				"(story)" if _council_offer.story else "", _council_offer.brief, _council_offer.pay, _council_offer.km()]
		return "Y  Hart's job: %s  ($%d)" % [_council_offer.title, _council_offer.pay]
	return ""


func offer_side() -> String:
	if perks.phone_open:
		return "bad"
	if _brief_t > 0.0:
		return _brief_side
	if _radio_offer == null and _council_offer and director.active == null:
		return "council"
	return "good"


# ------------------------------------------------------------ Councilwoman Hart ---

func _tick_council(delta: float) -> void:
	## Hart's jobs arrive as messages in either view (the mayor HUD shows Progress notices)
	## and wait a few minutes to be taken with Y at street level.
	if _council_offer:
		_council_t -= delta
		if link.active():
			_council_show = maxf(0.0, _council_show - delta)
		if _council_t <= 0.0:
			_council_offer = null
			_council_wait = _rng.randf_range(COUNCIL_GAP.x, COUNCIL_GAP.y)
		return
	if director.active or progress.city_tier() < 1:
		return
	_council_wait -= delta
	if _council_wait > 0.0:
		return
	_council_wait = _rng.randf_range(COUNCIL_GAP.x, COUNCIL_GAP.y)
	var m := _offer("council", link.position() if link.active() else Vector3.INF)
	if m == null:
		return
	_council_offer = m
	_council_t = COUNCIL_KEEP
	_council_show = COUNCIL_SHOW
	if link.active():
		hud.news("Message from Councilwoman Hart", 3.0)
		_play_ui("phone_ring", "notify")
	else:
		_news("Councilwoman Hart: %s (take it with Y at street level)" % m.title, 8.0)


func take_council_job() -> bool:
	if _council_offer == null or director.active:
		return false
	var m := _council_offer
	_council_offer = null
	_council_wait = _rng.randf_range(COUNCIL_GAP.x, COUNCIL_GAP.y)
	begin(m)
	return true


func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_J:
		log_panel.toggle()
		get_viewport().set_input_as_handled()
	elif not link.active():
		return
	elif log_panel.visible and k.keycode >= KEY_1 and k.keycode <= KEY_9:
		if replay(k.keycode - KEY_1):
			get_viewport().set_input_as_handled()
	elif perks.handle_key(k.keycode):
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_Y and _radio_offer and director.active == null:
		var m := _radio_offer
		_radio_offer = null
		begin(m)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_Y and take_council_job():
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_B and _bribe_state != "":
		_try_bribe()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_K and director.active:
		director.abandon()
		get_viewport().set_input_as_handled()


# --------------------------------------------------------------------- bribe ---

func _police() -> Object:
	var life: Object = street.get("life") if street else null
	return life.get("police") if life else null


func _free_bribes() -> int:
	return int(progress.resident_perk("free_bribes_per_day", 0.0))  # Ex-cop: 1


func _try_bribe() -> void:
	var stars := link.wanted()
	match _bribe_state:
		"too_hot":
			hud.news("Nobody takes a bribe at %d stars" % stars, 2.5)
		"cooldown":
			hud.news("The cops are watching you too closely to try that again yet", 2.5)
		"broke":
			hud.news("Not enough cash for that ($%d)" % bribe.price(stars), 2.5)
		"ok":
			var free := bribe.free_left(city.game_day(), _free_bribes()) > 0
			var cost := bribe.pay(stars, city.game_day(), _free_bribes())
			progress.add_cash(-cost, "bribe")
			link.set_wanted(0)
			goodness.add(Bribe.GOODNESS, "bribe")
			_play_ui("cash", "ui_select")
			hud.news("An old friend on the force lets it slide" if free else
				"The officer pockets $%d and looks the other way" % cost, 3.5)


func bribe_hint() -> String:
	## One line for the HUD while a bribe is possible.
	var stars := link.wanted()
	match _bribe_state:
		"ok":
			if bribe.free_left(city.game_day(), _free_bribes()) > 0:
				return "B  Call in a favor (free, ex-cop)"
			return "B  Bribe the cop  $%d" % bribe.price(stars)
		"broke":
			return "Bribe: $%d (not enough cash)" % bribe.price(stars)
		"cooldown":
			return "Bribe: wait %d s" % int(ceil(bribe.cooldown))
	return ""


# -------------------------------------------------------------------- events ---

func _on_started(m: Mission) -> void:
	_play_ui("mission_start", "ui_select")
	if m.quest != "":
		hud.news(quests.get_def(m.quest).get("title", ""), 3.0)


func _on_step(_m: Mission) -> void:
	_play_ui("checkpoint", "ui_toggle")


func _on_passed(m: Mission) -> void:
	_radio_wait = _rng.randf_range(RADIO_GAP.x, RADIO_GAP.y)
	_phone_wait = _rng.randf_range(PHONE_GAP.x, PHONE_GAP.y)
	var sub := "$%d" % m.pay
	if m.goodness != 0.0:
		sub += "     goodness %+d" % int(m.goodness)
	if not m.replay:
		var changes := contacts.earn(m.contact, contacts.job_gain(m.template, m.story))
		var rt := Contacts.change_text(changes)
		if rt != "":
			sub += "     respect: " + rt
		var fx: String = m.template.get("effect", "")
		var at: String = m.template.get("effect_at", "")
		if fx != "" and m.slots.has(at):
			effects.add(fx, director.tags.building(m.slots[at].building), m.slots[at].name)
	if m.story or m.replay:
		var medal := medals.record(m)
		sub += "     %s medal  %d:%02d" % [Medals.NAMES[medal], int(m.elapsed) / 60, int(m.elapsed) % 60]
	hud.banner("MISSION PASSED", sub, MissionHud.GOLD)
	_play_ui("mission_passed", "cash")
	if m.crime > 0:
		progress.count("job_crime", m.crime)  # services/ can read this into city crime
	if m.quest != "":
		quests.job_passed(m.quest, m.id)
	var r: String = m.template.get("resolves", "")
	if r != "":
		specials.resolve(m.slots[r].building)


func _on_failed(m: Mission) -> void:
	_phone_wait = _rng.randf_range(PHONE_GAP.x, PHONE_GAP.y)
	hud.banner("MISSION FAILED", m.fail_reason, MissionHud.BAD)
	_play_ui("mission_failed", "error")


func replay(i: int) -> bool:
	## Replays the i-th passed story job from the quest log: half pay, a medal to beat, and
	## nothing else changes (no goodness, respect, city funds or city effects).
	var list := medals.replays()
	if i < 0 or i >= list.size() or director.active or not link.active():
		return false
	var m := director.generate(list[i][0], link.position())
	if m == null:
		hud.news("That job's places aren't in the city any more", 3.0)
		return true
	m.replay = true
	m.story = true
	m.pay = int(m.pay * 0.5 / 10.0) * 10
	m.goodness = 0.0
	m.city_bonus = 0
	m.crime = 0
	log_panel.visible = false
	_radio_offer = null
	_stop_ring()
	begin(m)
	return true


func _on_ending(kind: String) -> void:
	## The story's end: Hero or Kingpin of the city. The game carries on.
	progress.unlock("ending:" + kind, "story")
	var hero := kind == "hero"
	hud.banner("HERO OF NEW HARBOR" if hero else "KINGPIN OF NEW HARBOR",
		"The city will remember you. Keep playing." if hero else "Nobody in this city says no to you again. Keep playing.",
		MissionHud.GOOD if hero else MissionHud.BAD)
	_news("The end of the story: you are the %s of New Harbor" % ("Hero" if hero else "Kingpin"), 10.0)


func act() -> int:
	## The story act the city has reached (0 before Small city).
	var a := 0
	for i in ACT_TIERS.size():
		if progress.city_tier() >= ACT_TIERS[i]:
			a = i + 1
	return a


func _on_goodness(value: float, _delta: float, reason: String) -> void:
	progress.set_goodness(value, reason)


func _announce(id: int) -> void:
	## A placed special says what it opens up on the street (and to whom it matters).
	var b: Dictionary = city.buildings.get(id, {})
	if not b.has("kind") or not b.has("tags"):
		return
	var name: String = b.get("name", Catalog.get_def(String(b.kind)).get("name", ""))
	var list := StreetUses.jobs(b.tags, name)
	if list.is_empty():
		return
	var titles: PackedStringArray = []
	for j in list.slice(0, 3):
		titles.append(j.title + (" (pays by distance to %s)" % j.partner if j.partner != "" else ""))
	_news("%s is open. New street jobs: %s" % [name, ", ".join(titles)], 8.0)


func _quest_news(text: String, _q: Dictionary) -> void:
	_news(text, 6.0)
	if log_panel.visible:
		log_panel.refresh()


func _news(text: String, seconds: float) -> void:
	hud.news(text, seconds)
	if progress.store and not link.active():
		progress.store.notice.emit(text)  # the mayor HUD shows Progress notices


func _play_ui(sound: String, fallback: String) -> void:
	var a := get_node_or_null("/root/Audio")
	if a == null:
		return
	a.play_ui(sound if a.stream(sound) else fallback)


func _play_at(sound: String, pos: Vector3, fallback: String) -> void:
	var a := get_node_or_null("/root/Audio")
	if a == null:
		return
	a.play_at(sound if a.stream(sound) else fallback, Planet.place(pos), 4.0)  # pos is flat map


# ------------------------------------------------------------------- world ---

func _build_world() -> void:
	_beacon = _make_beacon(1.6, 36.0)
	add_child(_beacon)
	_target_mark = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.7
	cone.height = 1.3
	_target_mark.mesh = cone
	_target_mark.rotation.x = PI
	_target_mark.material_override = _glow(Color(1, 0.3, 0.25))
	_target_mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_target_mark)
	_phone_root = Node3D.new()
	_phone_root.name = "Payphones"
	add_child(_phone_root)
	_hide_markers()


static func _glow(c: Color, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	return m


func _make_beacon(radius: float, height: float) -> MeshInstance3D:
	var b := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius * 0.6
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 20
	b.mesh = cyl
	b.material_override = _glow(Color(1, 0.85, 0.2), 0.32)
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return b


func _hide_markers() -> void:
	_beacon.visible = false
	_target_mark.visible = false
	for p in _piles:
		p.visible = false
	if hud:
		hud.arrow_dist = -1.0


func _update_markers() -> void:
	var m := director.active
	var goal := Vector3.INF
	var col := Color(1, 0.85, 0.2)
	_target_mark.visible = false
	if m:
		col = MissionHud.GOOD if m.side == "good" else MissionHud.BAD
		var s := m.step()
		match s.get("do", ""):
			"chase":
				if m.target and is_instance_valid(m.target):
					goal = m.target.flat_position()
					_target_mark.visible = true
					_put(_target_mark, goal + Vector3.UP * (3.2 + sin(Time.get_ticks_msec() * 0.006) * 0.3))
			"collect":
				var me := link.position()
				var best := INF
				for p in m.points:
					var d := MissionDirector.flat_dist(me, p)
					if d < best:
						best = d
						goal = p
			"vehicle", "destroy":
				if m.mission_car is Node3D and is_instance_valid(m.mission_car):
					goal = Planet.flat((m.mission_car as Node3D).global_position)
					if s.do == "destroy":
						_target_mark.visible = true
						_put(_target_mark, goal + Vector3.UP * (3.4 + sin(Time.get_ticks_msec() * 0.006) * 0.3))
			"fight":
				# Point at the hit target (or the nearest gunman) once you're close; until then the spot.
				var e = director.crew.nearest(link.position())
				goal = m.step_pos()
				if e and MissionDirector.flat_dist(link.position(), e.pos) < MissionCrew.AGGRO_M + 20.0:
					goal = e.pos
					_target_mark.visible = true
					_put(_target_mark, e.pos + Vector3.UP * (2.6 + sin(Time.get_ticks_msec() * 0.006) * 0.2))
			"race":
				if not m.points.is_empty():
					goal = m.points[0]
			"rampage":
				goal = Vector3.INF  # anywhere will do
			_:
				goal = m.step_pos()
		_sync_piles(m)
	else:
		_sync_piles(null)
		if _ringing >= 0:
			goal = phones[_ringing]
	_sync_nav(m, goal, col)
	if goal == Vector3.INF:
		_beacon.visible = false
		hud.arrow_dist = -1.0
		return
	var show_beacon: bool = not _target_mark.visible  # a target marker over a car or person replaces it
	_beacon.visible = show_beacon
	var pulse := 0.25 + 0.12 * sin(Time.get_ticks_msec() * (0.012 if m == null else 0.004))
	(_beacon.material_override as StandardMaterial3D).albedo_color = Color(col.r, col.g, col.b, pulse)
	var radius: float = m.step().get("radius", MissionDirector.GOTO_RADIUS) if m else PHONE_RADIUS
	var sc := clampf(radius / 6.0, 0.5, 2.5)
	_put(_beacon, Vector3(goal.x, 18.0, goal.z), Vector3(sc, 1.0, sc))
	# Arrow on the HUD: angle between where the camera looks and the goal.
	var cam := get_viewport().get_camera_3d()
	var me := link.position()
	hud.arrow_dist = MissionDirector.flat_dist(me, goal)
	if cam:
		var f := Planet.to_local(cam.global_position, -cam.global_basis.z)
		var to := goal - me
		to.x = Planet.fdx(me.x, goal.x)
		hud.arrow_angle = atan2(f.x * to.z - f.z * to.x, f.x * to.x + f.z * to.z)


## Stand a marker at a flat map point (upright on the ball on msp).
static func _put(n: Node3D, flat: Vector3, scale := Vector3.ONE) -> void:
	var w := Planet.place(flat)
	n.global_transform = Transform3D(Planet.basis(w) * Basis.from_scale(scale), w)


# ---------------------------------------------------------- minimap and GPS ---

func _nav() -> Node:
	## navigation/CityNav when main.gd has one (found by group, so missions/ loads without it).
	return get_tree().get_first_node_in_group("city_nav") if is_inside_tree() else null


func _sync_nav(m: Mission, goal: Vector3, col: Color) -> void:
	## The next objective (or the ringing payphone) as the minimap target with the GPS line,
	## and collect piles as pickups. Only re-marked when something changes.
	var nav = _nav()  # CityNav, untyped so missions/ loads without navigation/
	if nav == null:
		return
	var doing: String = m.step().get("do", "") if m else ""
	var kind := "phone" if m == null else ("car" if doing in ["chase", "vehicle", "destroy"] else "job")
	if goal == Vector3.INF:
		if _nav_goal != Vector3.INF:
			nav.unmark("mission:goal")
	elif kind != _nav_kind or _nav_goal == Vector3.INF or (m and m.step_i != _nav_step) \
			or (kind in ["job", "phone"] and goal.distance_to(_nav_goal) > 2.0):
		var where: Variant = goal
		if doing == "chase" and m.target and is_instance_valid(m.target):
			where = m.target  # the minimap follows the car itself
		elif doing in ["vehicle", "destroy"] and m.mission_car is Node3D and is_instance_valid(m.mission_car):
			where = m.mission_car
		nav.mark("mission:goal", where, {"color": col, "kind": kind, "priority": 10,
			"label": m.title if m else "Ringing payphone"})
	_nav_goal = goal
	_nav_kind = kind
	_nav_step = m.step_i if m else -1
	var piles: int = m.points.size() if m and doing == "collect" else 0
	if piles != _nav_piles:
		nav.unmark_prefix("mission:pile")
		for i in piles:
			nav.mark("mission:pile%d" % i, m.points[i], {"kind": "pickup", "gps": false, "color": col})
		_nav_piles = piles


func _mark_specials() -> void:
	for sp in specials.active:
		_mark_special(sp)


func _mark_special(sp: Dictionary) -> void:
	var nav = _nav()  # CityNav, untyped so missions/ loads without navigation/
	if nav:
		nav.mark("mission:special:%d" % sp.id, city.building_center(sp.b), {"kind": "place", "gps": false,
			"label": sp.name, "color": Color(1.0, 0.55, 0.2)})


func _sync_piles(m: Mission) -> void:
	var pts: Array[Vector3] = []
	if m and m.step().get("do", "") == "collect":
		pts = m.points
	while _piles.size() < pts.size():
		_piles.append(_make_pile())
	for i in _piles.size():
		_piles[i].visible = i < pts.size()
		if i < pts.size():
			_put(_piles[i], pts[i])


func _make_pile() -> Node3D:
	## A heap of trash bags with a small beacon so it reads from a car.
	var n := Node3D.new()
	var bag := StandardMaterial3D.new()
	bag.albedo_color = Color(0.08, 0.1, 0.08)
	bag.roughness = 0.35
	for i in 5:
		var mi := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.45
		sph.height = 0.75
		mi.mesh = sph
		mi.material_override = bag
		mi.position = Vector3(cos(i * 1.7) * 0.55, 0.32 + (0.35 if i == 4 else 0.0), sin(i * 1.7) * 0.55)
		n.add_child(mi)
	var b := _make_beacon(0.9, 10.0)
	b.position.y = 5.0
	b.material_override = _glow(MissionHud.GOOD, 0.3)
	n.add_child(b)
	add_child(n)
	return n


# ---------------------------------------------------------------- payphones ---

func _place_phones() -> void:
	## Placed payphones (catalog id payphone) once the Mayor has any; until then a handful
	## of stand-in phones outside shops so the bad jobs can be played.
	phones.clear()
	for c in _phone_root.get_children():
		c.queue_free()
	var real := progress.find_tagged("payphone")
	if not real.is_empty():
		for b in real:
			phones.append(_sidewalk(Vector2i(b.x, b.y), int(b.get("rot", 0))))
		_stop_ring_if_gone()
		return
	var picked: Array[Vector2i] = []
	var shops := director.tags.find("shop")
	shops.sort_custom(func(a, b): return a.id < b.id)
	for b in shops:
		if picked.size() >= STAND_IN_PHONES:
			break
		var cell := director.router.access_cell(b)
		if cell.x < 0:
			continue
		var spaced := true
		for p in picked:
			if absi(p.x - cell.x) + absi(p.y - cell.y) < 14:
				spaced = false
				break
		if not spaced:
			continue
		picked.append(cell)
		var toward := city.building_center(b) - city.cell_center(cell.x, cell.y)
		var pos := city.cell_center(cell.x, cell.y) + toward.normalized() * 4.6
		phones.append(pos)
		_phone_root.add_child(_make_phone(pos, atan2(-toward.x, -toward.z)))
	_stop_ring_if_gone()


func _stop_ring_if_gone() -> void:
	if _ringing >= phones.size():
		_stop_ring()


func _sidewalk(cell: Vector2i, rot: int) -> Vector3:
	var d: Vector2i = City.DIRS[clampi(rot, 0, 3)]
	return city.cell_center(cell.x, cell.y) + Vector3(d.x, 0, d.y) * 4.6


const PHONE_MODEL := "res://assets/kit/props/payphone.glb"


func _make_phone(pos: Vector3, yaw: float) -> Node3D:
	## The art kit's payphone, or a post with a hooded box when the kit isn't there (tests).
	if ResourceLoader.exists(PHONE_MODEL):
		var model: Node3D = (load(PHONE_MODEL) as PackedScene).instantiate()
		model.transform = Planet.xf_rigid(Transform3D(Basis(Vector3.UP, yaw), pos))
		return model
	var n := Node3D.new()
	n.transform = Planet.xf_rigid(Transform3D(Basis(Vector3.UP, yaw), pos))
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.55, 0.58, 0.62)
	metal.metallic = 0.7
	metal.roughness = 0.35
	var blue := StandardMaterial3D.new()
	blue.albedo_color = Color(0.1, 0.25, 0.6)
	for part in [[Vector3(0.12, 1.1, 0.12), Vector3(0, 0.55, 0), metal],
			[Vector3(0.5, 0.75, 0.32), Vector3(0, 1.45, 0.05), blue],
			[Vector3(0.6, 0.08, 0.45), Vector3(0, 1.86, 0.08), metal]]:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = part[0]
		mi.mesh = bm
		mi.position = part[1]
		mi.material_override = part[2]
		n.add_child(mi)
	return n


# ---------------------------------------------------------------------- save ---

func to_dict() -> Dictionary:
	## Section "missions" in the save. Goodness, quests and counters live in Progress.
	return {"director": director.to_dict(), "stand_ins": director.tags.to_dict(), "bribe": bribe.to_dict(),
		"perks": perks.to_dict(), "specials": specials.to_dict(), "respect": contacts.to_dict(),
		"medals": medals.to_dict(), "effects": effects.to_dict()}


func from_dict(d: Dictionary) -> void:
	director.from_dict(d.get("director", {}))
	director.tags.from_dict(d.get("stand_ins", {}))
	bribe.from_dict(d.get("bribe", {}))
	perks.from_dict(d.get("perks", {}))
	specials.from_dict(d.get("specials", {}))
	contacts.from_dict(d.get("respect", {}))
	medals.from_dict(d.get("medals", {}))
	effects.from_dict(d.get("effects", []))
