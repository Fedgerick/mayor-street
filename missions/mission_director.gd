class_name MissionDirector
extends Node3D
## Turns templates into jobs and runs the one that is active.
##
## generate(): fills each template slot with a real building found by tag, measures the
## road distance along the template's route, and prices it:
##     pay = (base + per_km x km) x risk x goodness lean
##     risk (bad jobs) grows with police near the route and the wealth at the start
## So where the Mayor puts the bank and The Bunker sets the stakes of robbing it.
##
## Steps (see README.md): goto, hold, wanted, chase, vehicle, collect.

signal offered(m: Mission)
signal started(m: Mission)
signal step_changed(m: Mission)
signal passed(m: Mission)
signal failed(m: Mission)
signal updated(m: Mission)  # chase hit, pile collected

const TEMPLATES_PATH := "res://missions/data/templates.json"
const GOTO_RADIUS := 9.0
## Tags with only one or two buildings, where a too-short trip still beats no job.
const SPARSE_TAGS := ["crime_den", "abandoned_warehouse", "burning_building", "film_shoot", "armored_truck",
	"substation", "bank", "hideout", "police_hq", "hospital"]
const CAR_NAMES := {"car_sedan": "sedan", "car_hatch": "hatchback", "car_van": "van", "car_truck": "pickup truck"}

var city: City
var tags: BuildingTags
var router: RoadRouter
var goodness: Goodness
var progress: ProgressLink
var link: StreetLink
var templates := {}  # id -> Dictionary, in file order
var active: Mission = null
var rng := RandomNumberGenerator.new()
var stats := {"passed": 0, "failed": 0, "good": 0, "bad": 0, "crime": 0}


func setup(c: City, l: StreetLink, g: Goodness, p: ProgressLink) -> void:
	city = c
	link = l
	goodness = g
	progress = p
	tags = BuildingTags.new(c)
	router = RoadRouter.new(c)
	rng.seed = 90210
	load_templates()
	link.wasted.connect(func(): fail("Wasted"))
	link.busted.connect(func(): fail("Busted"))


func load_templates(path := TEMPLATES_PATH) -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		push_error("missions: can't parse " + path)
		return
	for t in data.templates:
		templates[t.id] = t


# ---------------------------------------------------------------- generating ---

func eligible(t: Dictionary) -> bool:
	## Whether this template can be offered right now (flags and goodness lean).
	if t.get("quest_only", false) or t.has("special"):
		return false  # handed out by quests and by spawned specials only
	if t.has("unlock") and not progress.is_unlocked(t.unlock):
		return false
	var lean: float = t.get("lean", 0)
	if t.side == "good" and goodness.value < lean:
		return false
	if t.side == "bad" and goodness.value > -lean:
		return false
	return true


func make_offer(giver: String, from := Vector3.INF) -> Mission:
	## A random job from this giver ("radio" or "payphone") that the city can host.
	var pool: Array = []
	for t in templates.values():
		if t.giver == giver and eligible(t):
			pool.append(t.id)
	while not pool.is_empty():
		var id: String = pool.pop_at(rng.randi() % pool.size())
		var m := generate(id, from)
		if m:
			offered.emit(m)
			return m
	return null


func generate(id: String, from := Vector3.INF) -> Mission:
	## A job from the template, or null when the city lacks the buildings or roads for it.
	## Picks are random, so a few tries get past an unlucky first building.
	if not templates.has(id):
		push_error("missions: no template " + id)
		return null
	for attempt in 6:
		var m := _generate(templates[id], from)
		if m:
			return m
	return null


func _generate(t: Dictionary, from: Vector3) -> Mission:
	var id: String = t.id
	var m := Mission.new()
	m.template = t
	m.id = id
	m.side = t.side
	m.giver = t.giver
	if t.has("car"):
		var model: String = t.car[rng.randi() % t.car.size()]
		m.vars.car_model = model
		m.vars.car = CAR_NAMES.get(model, model)
	var from_cell := router.nearest_road(city.world_to_cell(from)) if from != Vector3.INF else Vector2i(-1, -1)
	var fields := {}  # slot -> road distance field from it
	var used: Array = []
	for slot in t.slots:
		var spec: Dictionary = t.slots[slot]
		var pick := _pick(spec, fields, used, from_cell)
		if pick.is_empty():
			return null
		var b: Dictionary = pick
		var cell := router.access_cell(b)
		used.append(b.id)
		fields[slot] = router.reachable(cell)
		m.slots[slot] = {"building": b.id, "name": tags.name_of(b, spec.tag), "cell": cell,
			"pos": _front_point(b, cell)}
	# Distance along the route, leg by leg.
	var route: Array = t.get("route", [])
	for i in range(1, route.size()):
		var tiles: int = fields[route[i - 1]][city.idx(m.slots[route[i]].cell.x, m.slots[route[i]].cell.y)]
		if tiles < 0:
			return null
		m.route_m += tiles * City.TILE
	m.risk = _risk(m, route) if m.side == "bad" else 1.0
	var p: Dictionary = t.get("pay", {})
	var raw: float = (p.get("base", 0.0) + p.get("per_km", 0.0) * m.km()) * m.risk * goodness.pay_multiplier(m.side)
	if t.get("stolen_goods", false):
		raw *= progress.resident_perk("stolen_goods_price", 1.0)  # Hustler sells for more
	m.pay = int(round(raw / 10.0)) * 10
	m.city_bonus = t.get("city_bonus", 0)
	m.goodness = t.get("goodness", 0)
	m.crime = t.get("crime", 0)
	m.max_wanted = t.get("max_wanted", 99)
	if t.has("time"):
		var approach := 0.0
		var first := _first_slot(t)
		if from_cell.x >= 0 and first != "":
			var d: int = fields[first][city.idx(from_cell.x, from_cell.y)]
			approach = maxf(0.0, d) * City.TILE
		m.time_limit = t.time.get("base", 60.0) + t.time.get("per_km", 0.0) * (m.route_m + approach) / 1000.0
	m.title = m.format(t.title)
	m.brief = m.format(t.brief)
	for s in t.steps:
		var step: Dictionary = s.duplicate()
		if step.has("text"):
			step.text = m.format(step.text)
		if step.get("model", "") == "{car}":
			step.model = m.vars.car_model
		m.steps.append(step)
	return m


func _first_slot(t: Dictionary) -> String:
	for s in t.steps:
		if s.has("at"):
			return s.at
	return ""


func _pick(spec: Dictionary, fields: Dictionary, used: Array, from_cell: Vector2i) -> Dictionary:
	var cands: Array[Dictionary] = []
	var near: Array[Dictionary] = []  # in range except for max_m, as a fallback
	var close: Array[Dictionary] = []  # nearer than min_m, the last resort
	var field: PackedInt32Array = fields.get(spec.get("from", ""), PackedInt32Array())
	var player_field := PackedInt32Array()
	if spec.has("near_player_m") and from_cell.x >= 0:
		player_field = router.reachable(from_cell)
	var pool := tags.find(spec.tag)
	var lending := pool.is_empty()
	if lending:
		pool = tags.stand_in_pool(spec.tag)
	for b in pool:
		if b.id in used:
			continue
		var cell := router.access_cell(b)
		if cell.x < 0:
			continue
		if not player_field.is_empty():
			var pd := player_field[city.idx(cell.x, cell.y)]
			if pd < 0 or pd * City.TILE > spec.near_player_m:
				continue
		if not field.is_empty():
			var tiles := field[city.idx(cell.x, cell.y)]
			if tiles < 0:
				continue
			if tiles * City.TILE < spec.get("min_m", 0.0):
				if tiles > 0:
					close.append(b)
				continue
			if tiles * City.TILE > spec.get("max_m", INF):
				near.append(b)
				continue
		cands.append(b)
	if cands.is_empty():
		cands = near
	if cands.is_empty() and spec.get("tag", "") in SPARSE_TAGS:
		cands = close  # a spawned special or a lone landmark: better close than no job
	if cands.is_empty():
		return {}
	if lending:  # the biggest building that fits becomes the stand-in, for good
		tags.lend(spec.tag, cands[0])
		return cands[0]
	return cands[rng.randi() % cands.size()]


func _front_point(b: Dictionary, cell: Vector2i) -> Vector3:
	## The kerb in front of the building: the road tile centre nudged toward the door.
	var c := city.cell_center(cell.x, cell.y)
	var toward := city.building_center(b) - c
	toward.y = 0.0
	return c + toward.limit_length(4.0)


func _risk(m: Mission, route: Array) -> float:
	var r := 1.0
	if not route.is_empty():
		var c: Vector2i = m.slots[route[0]].cell
		r += city.land_value[city.idx(c.x, c.y)] * 0.5
	var cops := 0.0
	for tag in ["police", "police_hq"]:
		for b in city.buildings.values():
			if not (b.has("tags") and tag in b.tags):
				continue
			var bp := city.building_center(b)
			for slot in route:
				var d: float = bp.distance_to(m.slots[slot].pos)
				cops += maxf(0.0, 1.0 - d / 360.0) * (0.35 if tag == "police_hq" else 0.25)
	return r + minf(cops, 1.0)


# ------------------------------------------------------------------- running ---

func start(m: Mission) -> bool:
	if active != null or m == null:
		return false
	active = m
	m.state = Mission.State.ACTIVE
	m.step_i = 0
	m.time_left = m.time_limit
	started.emit(m)
	_enter_step()
	return true


func abandon() -> void:
	fail("Abandoned")


func fail(reason: String) -> void:
	var m := active
	if m == null:
		return
	m.state = Mission.State.FAILED
	m.fail_reason = reason
	stats.failed += 1
	_cleanup(m)
	active = null
	failed.emit(m)


func _pass() -> void:
	var m := active
	m.state = Mission.State.PASSED
	stats.passed += 1
	stats[m.side] += 1
	stats.crime += m.crime
	progress.add_cash(m.pay, m.title)
	progress.add_city_funds(m.city_bonus, m.title)
	progress.count("missions_" + m.side)
	progress.count("job:" + m.id)
	progress.count("cash_earned", m.pay)
	goodness.add(m.goodness, m.title)
	_cleanup(m)
	active = null
	passed.emit(m)


func _cleanup(m: Mission) -> void:
	if m.target and is_instance_valid(m.target):
		m.target.queue_free()
	m.target = null
	m.points.clear()


func _enter_step() -> void:
	var m := active
	while m.step_i < m.steps.size():
		var s := m.step()
		m.hold = 0.0
		match s.do:
			"wanted":
				link.set_wanted(s.stars)
				m.step_i += 1
				continue
			"chase":
				_spawn_chase(m, s)
			"vehicle":
				_spawn_vehicle(m, s)
			"collect":
				_scatter(m, s)
		break
	if m.step_i >= m.steps.size():
		_pass()
		return
	step_changed.emit(m)


func _advance() -> void:
	active.step_i += 1
	_enter_step()


func _process(delta: float) -> void:
	tick(delta)


func tick(delta: float) -> void:
	link.tick(delta)
	var m := active
	if m == null or not link.active():
		return
	if m.time_limit > 0.0:
		m.time_left -= delta
		if m.time_left <= 0.0:
			fail("Out of time")
			return
	if link.wanted() > m.max_wanted:
		fail("You drew the cops")
		return
	var s := m.step()
	var me := link.position()
	var near: bool = flat_dist(me, m.step_pos()) <= s.get("radius", GOTO_RADIUS)
	match s.do:
		"goto":
			if s.has("interior") and _walk_in(m, s):
				if link.inside() == s.interior and link.inside_building() == m.slots[s.at].building:
					_advance()
			elif near and _car_ok(m, s) and (not s.get("clean", false) or link.wanted() == 0):
				_advance()
		"hold":
			if s.has("marker") and link.inside() != "":
				near = link.near_marker(s.marker, 3.0)
			if near and _car_ok(m, s):
				m.hold += delta
				if m.hold >= s.seconds:
					_advance()
			else:
				m.hold = maxf(0.0, m.hold - delta * 2.0)
		"vehicle":
			if m.mission_car and link.car() == m.mission_car:
				if s.get("steal", false) and link.street == null:
					goodness.action(&"steal_car")  # in the game StreetMode reports the theft itself
				_advance()
		"chase":
			if m.target == null or not is_instance_valid(m.target):
				fail("The suspect got away")
			elif m.target.is_wrecked:
				_advance()
			elif flat_dist(me, m.target.global_position) > s.get("escape_m", 450.0):
				m._escape_t += delta
				if m._escape_t > 8.0:
					fail("The suspect got away")
			else:
				m._escape_t = 0.0
		"collect":
			for i in range(m.points.size() - 1, -1, -1):
				if flat_dist(me, m.points[i]) < 6.0:
					m.points.remove_at(i)
					updated.emit(m)
			if m.points.is_empty():
				_advance()


func _walk_in(m: Mission, s: Dictionary) -> bool:
	## A goto with "interior" means going inside, when the building really has a door
	## (a placed special and an InteriorManager); stand-ins just need you at the kerb.
	return link.has_door(city.buildings.get(m.slots[s.at].building, {}))


func _car_ok(m: Mission, s: Dictionary) -> bool:
	var need = s.get("car", null)
	if need == null:
		return true
	if need is String and need == "mission":
		return m.mission_car != null and link.car() == m.mission_car
	return (link.car() != null) == bool(need)


static func flat_dist(a: Vector3, b: Vector3) -> float:
	if a == Vector3.INF or b == Vector3.INF:
		return INF
	return Vector2(a.x - b.x, a.z - b.z).length()


func _spawn_chase(m: Mission, s: Dictionary) -> void:
	var car := ChaseCar.new()
	car.model = m.vars.get("car_model", "car_sedan")
	add_child(car)
	car.setup(city, m.slots[s.at].cell, rng.randi())
	car.threat = link.position
	car.threat_car = link.car
	car.hit.connect(func(_h): updated.emit(m))
	m.target = car


func _spawn_vehicle(m: Mission, s: Dictionary) -> void:
	var cell: Vector2i = m.slots[s.at].cell
	var c := city.cell_center(cell.x, cell.y)
	var mask := city.road_mask(cell.x, cell.y)
	var along_x := (mask & 10) != 0 and (mask & 5) == 0
	var pos := c + (Vector3(0, 0.15, 2.75) if along_x else Vector3(2.75, 0.15, 0))
	var yaw := PI * 0.5 if along_x else 0.0
	var color := Color.from_string(s.get("color", "#8a1c22"), Color(0.55, 0.1, 0.15))
	m.mission_car = link.spawn_car(s.model, pos, yaw, color)
	if m.mission_car is Node:
		# StreetMode treats a "parked" car as theft (crime, goodness); a mission van is lent.
		m.mission_car.set_meta("parked" if s.get("steal", false) else "player_owned", true)
	if m.mission_car == null:  # no street (tests): a token the fake player can "drive"
		m.mission_car = RefCounted.new()


func _scatter(m: Mission, s: Dictionary) -> void:
	## Collect points on road tiles around the slot, at least a tile apart.
	var center: Vector2i = m.slots[s.at].cell
	var spread := int(ceil(s.get("spread_m", 100.0) / City.TILE))
	var dist := router.reachable(center)
	var cells: Array[Vector2i] = []
	for y in range(center.y - spread, center.y + spread + 1):
		for x in range(center.x - spread, center.x + spread + 1):
			if city.inside(x, y) and dist[city.idx(x, y)] > 0 and dist[city.idx(x, y)] <= spread * 2:
				cells.append(Vector2i(x, y))
	m.points.clear()
	var want: int = s.get("count", 5)
	while m.points.size() < want and not cells.is_empty():
		var c: Vector2i = cells.pop_at(rng.randi() % cells.size())
		var p := city.cell_center(c.x, c.y) + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
		var spaced := true
		for q in m.points:
			if q.distance_to(p) < City.TILE * 1.5:
				spaced = false
		if spaced:
			m.points.append(p)


# ---------------------------------------------------------------------- save ---

func to_dict() -> Dictionary:
	return {"stats": stats.duplicate()}


func from_dict(d: Dictionary) -> void:
	stats.merge(d.get("stats", {}), true)
