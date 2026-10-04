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
## Keys: J quest log (either view); at street level Y takes a radio job, K abandons a job.

const PHONE_RADIUS := 2.6        # walk this close to a ringing phone to answer it
const PHONE_MIN_M := 50.0        # a phone rings somewhere this far ...
const PHONE_MAX_M := 320.0       # ... to this far from you
const RING_SECONDS := 45.0
const RADIO_GAP := Vector2(14.0, 28.0)   # seconds between radio calls while driving
const PHONE_GAP := Vector2(12.0, 30.0)   # seconds between rings
const OFFER_SECONDS := 16.0
const STAND_IN_PHONES := 8

var city: City
var street: Node
var link: StreetLink
var progress: ProgressLink
var goodness: Goodness
var director: MissionDirector
var quests: QuestEngine
var hud: MissionHud
var log_panel: QuestLog
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
	director.setup(c, link, goodness, progress)
	quests = QuestEngine.new(progress, goodness, director.tags)

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
	c.building_added.connect(func(_id, _a):
		_quest_t = 0.0
		_phones_dirty = true)
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
	_quest_t -= delta
	if _quest_t <= 0.0:
		_quest_t = 1.0
		quests.update()
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
	director.start(m)


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
			return m
	return director.make_offer(giver, from)


func offer_text() -> String:
	## For the HUD's offer box.
	if _brief_t > 0.0 and _brief != "":
		return _brief
	if _radio_offer and director.active == null:
		return "DISPATCH  %s\n%s\nPress Y to take it  ($%d, %.1f km)" % [
			"(quest)" if _radio_offer.quest != "" else "", _radio_offer.brief, _radio_offer.pay, _radio_offer.km()]
	return ""


func offer_side() -> String:
	if _brief_t > 0.0:
		return _brief_side
	return "good"


func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.keycode == KEY_J:
		log_panel.toggle()
		get_viewport().set_input_as_handled()
	elif not link.active():
		return
	elif k.keycode == KEY_Y and _radio_offer and director.active == null:
		var m := _radio_offer
		_radio_offer = null
		director.start(m)
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_K and director.active:
		director.abandon()
		get_viewport().set_input_as_handled()


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
	hud.banner("MISSION PASSED", sub, MissionHud.GOLD)
	_play_ui("mission_passed", "cash")
	if m.crime > 0:
		progress.count("job_crime", m.crime)  # services/ can read this into city crime
	if m.quest != "":
		quests.job_passed(m.quest, m.id)


func _on_failed(m: Mission) -> void:
	_phone_wait = _rng.randf_range(PHONE_GAP.x, PHONE_GAP.y)
	hud.banner("MISSION FAILED", m.fail_reason, MissionHud.BAD)
	_play_ui("mission_failed", "error")


func _on_goodness(value: float, _delta: float, reason: String) -> void:
	progress.set_goodness(value, reason)


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
	a.play_at(sound if a.stream(sound) else fallback, pos, 4.0)


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
					goal = m.target.global_position
					_target_mark.visible = true
					_target_mark.global_position = goal + Vector3.UP * (3.2 + sin(Time.get_ticks_msec() * 0.006) * 0.3)
			"collect":
				var me := link.position()
				var best := INF
				for p in m.points:
					var d := MissionDirector.flat_dist(me, p)
					if d < best:
						best = d
						goal = p
			"vehicle":
				if m.mission_car is Node3D and is_instance_valid(m.mission_car):
					goal = (m.mission_car as Node3D).global_position
			_:
				goal = m.step_pos()
		_sync_piles(m)
	else:
		_sync_piles(null)
		if _ringing >= 0:
			goal = phones[_ringing]
	if goal == Vector3.INF:
		_beacon.visible = false
		hud.arrow_dist = -1.0
		return
	var show_beacon: bool = m == null or m.step().get("do", "") != "chase"
	_beacon.visible = show_beacon
	var pulse := 0.25 + 0.12 * sin(Time.get_ticks_msec() * (0.012 if m == null else 0.004))
	(_beacon.material_override as StandardMaterial3D).albedo_color = Color(col.r, col.g, col.b, pulse)
	var radius: float = m.step().get("radius", MissionDirector.GOTO_RADIUS) if m else PHONE_RADIUS
	var sc := clampf(radius / 6.0, 0.5, 2.5)
	_beacon.scale = Vector3(sc, 1.0, sc)
	_beacon.global_position = Vector3(goal.x, 18.0, goal.z)
	# Arrow on the HUD: angle between where the camera looks and the goal.
	var cam := get_viewport().get_camera_3d()
	var me := link.position()
	hud.arrow_dist = MissionDirector.flat_dist(me, goal)
	if cam:
		var f := -cam.global_basis.z
		var to := goal - me
		hud.arrow_angle = atan2(f.x * to.z - f.z * to.x, f.x * to.x + f.z * to.z)


func _sync_piles(m: Mission) -> void:
	var pts: Array[Vector3] = []
	if m and m.step().get("do", "") == "collect":
		pts = m.points
	while _piles.size() < pts.size():
		_piles.append(_make_pile())
	for i in _piles.size():
		_piles[i].visible = i < pts.size()
		if i < pts.size():
			_piles[i].global_position = pts[i]


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
		model.position = pos
		model.rotation.y = yaw
		return model
	var n := Node3D.new()
	n.position = pos
	n.rotation.y = yaw
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
	return {"director": director.to_dict(), "stand_ins": director.tags.to_dict()}


func from_dict(d: Dictionary) -> void:
	director.from_dict(d.get("director", {}))
	director.tags.from_dict(d.get("stand_ins", {}))
