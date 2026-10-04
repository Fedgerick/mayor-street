class_name SpecialSpawner
extends Node3D
## Spawned specials (round-2 plan section 4): once a game day the city is checked, and when
## its conditions call for one, a special appears on an existing building (or, for the
## armored truck and the substation, at the kerb). Each carries a tag that only its own
## jobs ask for, so the director finds it like any building. Dealing with it (passing a job
## that `resolves` it) removes it; otherwise it expires, and a fire nobody fought burns the
## building down.
##
##   kind                 appears when                                   jobs
##   abandoned_warehouse  an industrial building has no power            evict_squatters, drug_lab
##   crime_den            a district has high crime and few police      raid_den, join_den
##   burning_building     a building outside fire coverage, by chance    firefight
##   film_shoot           a commercial street in a happy city            stunt_driving
##   armored_truck        by chance, most often near the bank            return_cash, grab_cash
##   substation           the city is short of power                     substation_fix

signal spawned(s: Dictionary)
signal ended(s: Dictionary, resolved: bool)

const DEFS := {
	"abandoned_warehouse": {"tag": "abandoned_warehouse", "days": 6, "chance": 0.35, "name": "Abandoned warehouse on %s"},
	"crime_den": {"tag": "crime_den", "days": 8, "chance": 0.4, "name": "%s den"},
	"burning_building": {"tag": "burning_building", "days": 1, "chance": 0.18, "name": "Fire at %s"},
	"film_shoot": {"tag": "film_shoot", "days": 3, "chance": 0.25, "name": "Film shoot on %s"},
	"armored_truck": {"tag": "armored_truck", "days": 2, "chance": 0.15, "name": "Crashed armored truck on %s"},
	"substation": {"tag": "substation", "days": 3, "chance": 0.5, "name": "Failed substation on %s"},
}
const MAX_ACTIVE := 4
const TRUCK_MODEL := "res://assets/kit/props/armored_truck.glb"

var city: City
var tags: BuildingTags
var router: RoadRouter
var progress: ProgressLink
var active: Array[Dictionary] = []  # {kind, id, b (building or kerb stand-in), name, day, until}
var rng := RandomNumberGenerator.new()
var _next_pseudo := -1000
var _props := {}  # special id -> Node3D
var _main := PackedInt32Array()  # road distance from the city centre; -1 off the main network


func setup(c: City, t: BuildingTags, r: RoadRouter, p: ProgressLink) -> void:
	city = c
	tags = t
	router = r
	progress = p
	rng.seed = 31337
	c.day_passed.connect(daily)
	c.building_removed.connect(func(id):
		for s in active.duplicate():
			if s.b.id == id:
				_end(s, false))


func _services() -> Object:
	return progress.store.get_section("services") if progress.store else null


# --------------------------------------------------------------------- daily ---

func daily() -> void:
	var day := city.game_day()
	for s in active.duplicate():
		if day >= int(s.until):
			_expire(s)
	for kind in DEFS:
		if active.size() >= MAX_ACTIVE:
			break
		if _count(kind) > 0 or rng.randf() > DEFS[kind].chance:
			continue
		var b := _find_site(kind)
		if not b.is_empty():
			spawn(kind, b)


func _count(kind: String) -> int:
	var n := 0
	for s in active:
		if s.kind == kind:
			n += 1
	return n


func _taken(id: int) -> bool:
	for s in active:
		if s.b.id == id:
			return true
	return false


func connected(b: Dictionary) -> bool:
	## On the city's main road network, so jobs can route to it.
	var cell := router.access_cell(b)
	if cell.x < 0:
		return false
	if _main.is_empty():
		_main = router.reachable(router.nearest_road(city.center_cell(), 20))
		city.cells_changed.connect(func(_r): _main = PackedInt32Array(), CONNECT_ONE_SHOT)
	return _main[city.idx(cell.x, cell.y)] >= 0


func _find_site(kind: String) -> Dictionary:
	## A building (or a kerb spot) where this special fits today, or {}.
	var sv := _services()
	var cands: Array[Dictionary] = []
	for b in city.buildings.values():
		if b.has("tags") or _taken(b.id) or not connected(b):
			continue
		var at := city.building_center(b)
		match kind:
			"abandoned_warehouse":
				if b.zone == City.Zone.IND and sv and sv.has_method("is_powered") and not sv.is_powered(b.id):
					cands.append(b)
			"crime_den":
				if b.zone != City.Zone.RES and sv and sv.crime_at(at) > 0.45 and sv.coverage_at("police", at) < 0.3:
					cands.append(b)
			"burning_building":
				if sv == null or sv.coverage_at("fire", at) < 0.25:
					cands.append(b)
			"film_shoot":
				if b.zone == City.Zone.COM and b.stage >= 2 and progress.stat("happiness", 60.0) >= 55.0:
					cands.append(b)
			"armored_truck", "substation":
				var want := City.Zone.COM if kind == "armored_truck" else City.Zone.IND
				if b.zone == want:
					cands.append(b)
	if kind == "substation" and progress.stat("power_pct", 100.0) >= 95.0:
		return {}
	if cands.is_empty():
		return {}
	if kind == "armored_truck":
		var banks := tags.find("bank")
		if not banks.is_empty() and rng.randf() < 0.6:
			var bc := city.building_center(banks[0])
			cands.sort_custom(func(p, q): return city.building_center(p).distance_to(bc) < city.building_center(q).distance_to(bc))
			cands.resize(mini(cands.size(), 6))
	var host: Dictionary = cands[rng.randi() % cands.size()]
	if kind in ["armored_truck", "substation"]:
		return _kerb(host)
	return host


func _kerb(host: Dictionary) -> Dictionary:
	## A one-tile stand-in at the road in front of host, for specials that aren't buildings.
	var cell := router.access_cell(host)
	_next_pseudo -= 1
	return {"id": _next_pseudo, "x": cell.x, "y": cell.y, "size": 1, "zone": 0, "stage": 0, "rot": 0,
		"seed": 0.5, "kerb": true}


# ---------------------------------------------------------------- lifecycle ---

func spawn(kind: String, b: Dictionary, days := -1) -> Dictionary:
	var def: Dictionary = DEFS[kind]
	var street_name := tags.address(b).get_slice(" ", 1) + " St"
	var s := {"kind": kind, "id": b.id, "b": b, "name": def.name % street_name,
		"day": city.game_day(), "until": city.game_day() + (days if days > 0 else def.days)}
	active.append(s)
	tags.add_extra(b, def.tag, s.name)
	_dress(s)
	spawned.emit(s)
	return s


func resolve(building_id: int) -> void:
	## A job dealt with it.
	for s in active.duplicate():
		if s.b.id == building_id:
			progress.count("specials_" + s.kind)
			_end(s, true)


func _expire(s: Dictionary) -> void:
	if s.kind == "burning_building" and city.buildings.has(s.b.id):
		_end(s, false)
		city.remove_building(s.b.id)  # nobody came: it burned down
		progress.count("buildings_burned")
		return
	_end(s, false)


func _end(s: Dictionary, resolved: bool) -> void:
	active.erase(s)
	tags.remove_extra(s.b.id)
	if _props.has(s.b.id):
		_props[s.b.id].queue_free()
		_props.erase(s.b.id)
	ended.emit(s, resolved)


func of_tag(tag: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in active:
		if DEFS[s.kind].tag == tag:
			out.append(s)
	return out


# ------------------------------------------------------------------ visuals ---

func _dress(s: Dictionary) -> void:
	## Something to see from the street: flames, a truck on its side, lights and a camera.
	if not is_inside_tree():
		return
	var b: Dictionary = s.b
	var root := Node3D.new()
	root.position = city.building_center(b) if not b.get("kerb", false) else city.cell_center(b.x, b.y)
	add_child(root)
	_props[b.id] = root
	var h := 6.0 + float(b.get("stage", 1)) * 8.0
	match s.kind:
		"burning_building":
			root.add_child(_particles(Color(1.0, 0.45, 0.1), Vector3(0, h, 0), 60, 1.4, 4.0, true))
			root.add_child(_particles(Color(0.15, 0.15, 0.15, 0.6), Vector3(0, h + 3.0, 0), 40, 4.0, 3.0, false))
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.5, 0.2)
			l.light_energy = 4.0
			l.omni_range = 20.0
			l.position.y = h
			root.add_child(l)
		"armored_truck":
			if ResourceLoader.exists(TRUCK_MODEL):
				var t: Node3D = (load(TRUCK_MODEL) as PackedScene).instantiate()
				t.rotation = Vector3(0, rng.randf() * TAU, deg_to_rad(12))
				root.add_child(t)
			root.add_child(_particles(Color(0.3, 0.3, 0.3, 0.5), Vector3(0, 1.5, 0), 20, 2.5, 1.5, false))
		"substation":
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(2.0, 1.8, 1.4)
			box.mesh = bm
			box.position = Vector3(3.6, 0.9, 3.6)
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.35, 0.42, 0.38)
			box.material_override = m
			root.add_child(box)
			root.add_child(_particles(Color(0.6, 0.85, 1.0), Vector3(3.6, 2.0, 3.6), 16, 0.5, 2.0, true))
		_:
			var sign := Label3D.new()
			sign.text = {"crime_den": "NO COPS", "abandoned_warehouse": "CONDEMNED", "film_shoot": "QUIET ON SET"}.get(s.kind, "")
			sign.font_size = 64
			sign.pixel_size = 0.01
			sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sign.modulate = {"crime_den": Color(0.9, 0.2, 0.6), "abandoned_warehouse": Color(1, 0.85, 0.2)}.get(s.kind, Color.WHITE)
			sign.position.y = minf(h, 9.0)
			root.add_child(sign)
			if s.kind == "film_shoot":
				for i in 2:
					var lamp := SpotLight3D.new()
					lamp.position = Vector3(-4.0 + i * 8.0, 4.0, 7.0)
					lamp.rotation.x = deg_to_rad(-30)
					lamp.light_energy = 6.0
					lamp.spot_range = 18.0
					root.add_child(lamp)


func _particles(col: Color, at: Vector3, amount: int, size: float, life: float, glow: bool) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.position = at
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 2.5
	p.direction = Vector3.UP
	p.spread = 20.0
	p.gravity = Vector3(0, 1.5, 0)
	p.initial_velocity_min = 1.0
	p.initial_velocity_max = 3.0
	p.scale_amount_min = size * 0.6
	p.scale_amount_max = size
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	if glow:
		m.emission_enabled = true
		m.emission = col
	m.vertex_color_use_as_albedo = true
	q.material = m
	p.mesh = q
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, col.a))
	ramp.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = ramp
	return p


# --------------------------------------------------------------------- save ---

func to_dict() -> Dictionary:
	var out: Array = []
	for s in active:
		var b: Dictionary = s.b
		out.append({"kind": s.kind, "id": b.id, "name": s.name, "day": s.day, "until": s.until,
			"kerb": [b.x, b.y] if b.get("kerb", false) else []})
	return {"active": out, "next": _next_pseudo}


func from_dict(d: Dictionary) -> void:
	for s in active.duplicate():
		_end(s, false)
	_next_pseudo = int(d.get("next", -1000))
	for e in d.get("active", []):
		var b: Dictionary
		var kerb: Array = e.get("kerb", [])
		if kerb.size() == 2:
			b = {"id": int(e.id), "x": int(kerb[0]), "y": int(kerb[1]), "size": 1, "zone": 0, "stage": 0,
				"rot": 0, "seed": 0.5, "kerb": true}
		elif city.buildings.has(int(e.id)):
			b = city.buildings[int(e.id)]
		else:
			continue
		var s := spawn(String(e.kind), b)
		s.name = String(e.name)
		s.day = int(e.day)
		s.until = int(e.until)
		tags.add_extra(b, DEFS[s.kind].tag, s.name)
