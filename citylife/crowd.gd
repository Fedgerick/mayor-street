class_name Crowd
extends Node3D
## Pedestrians on the sidewalks. They wander the RoadNet sidewalk graph, keep to the
## right of the walkway, stop now and then, and use zebra crossings only on the walk
## phase. Everyone is one MultiMesh of a procedural low-poly person; walking is animated
## in the vertex shader from a per-instance phase, so the CPU only moves points.

const PED_SHADER := preload("res://citylife/ped.gdshader")

class Ped:
	var a := 0            # node walked from
	var b := 0            # node walked to
	var arm := -1         # crosswalk arm when this edge is a zebra crossing
	var t := 0.0          # metres along the edge
	var length := 1.0
	var speed := 1.3
	var phase := 0.0
	var pause := 0.0      # seconds left standing still
	var side := 0.0       # lateral offset, + is to the walker's right
	var look := 0         # palette indices packed for the shader
	var look2 := 0
	var outfit := 0       # CharacterModel seed; `look` matches its colours
	var hero: CharacterModel  # full rigged model while close to the camera
	var size := 1.0
	var crossing := false
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD

var net: RoadNet
var peds: Array[Ped] = []
var max_peds := 360
var rng := RandomNumberGenerator.new()
var weight := PackedFloat32Array()  # spawn weight per road cell (set by CityLife)
var shadows := true
var camera: Camera3D

var _mmi: MultiMeshInstance3D
var _buf := PackedFloat32Array()

# Stats for tests.
var jaywalks := 0


func setup(road_net: RoadNet, seed_value := 11) -> void:
	net = road_net
	rng.seed = seed_value
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = false
	mm.use_custom_data = true
	mm.mesh = PersonMesh.build()
	var mat := ShaderMaterial.new()
	mat.shader = PED_SHADER
	mat.set_shader_parameter("shirts", _palette(CharacterModel.SHIRT))
	mat.set_shader_parameter("pants", _palette(CharacterModel.PANTS))
	mat.set_shader_parameter("skins", _palette(CharacterModel.SKIN))
	mat.set_shader_parameter("hairs", _palette(CharacterModel.HAIR))
	mat.set_shader_parameter("shoes", _palette(CharacterModel.SHOES))
	mm.mesh.surface_set_material(0, mat)
	_heroes_on = CharacterModel.available()
	mm.instance_count = max_peds
	mm.visible_instance_count = 0
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = mm
	_mmi.name = "People"
	add_child(_mmi)


# ------------------------------------------------------------------ spawn ---

func spawn_at(cell: int) -> Ped:
	var k := rng.randi() % 4
	var node := cell * 4 + k
	if not net.walk_adj.has(node):
		return null
	var p := Ped.new()
	p.a = node
	var ok := false
	for attempt in 3:
		if _choose_next(p, -1) and p.arm < 0:
			ok = true
			break
	if not ok:
		return null  # never spawn on a crossing
	p.t = rng.randf() * p.length
	p.speed = rng.randf_range(1.1, 1.6)
	p.size = rng.randf_range(0.9, 1.08)
	p.side = rng.randf_range(0.0, 0.3)
	p.phase = rng.randf() * TAU
	_set_outfit(p, rng.randi() % 100000)
	_place(p)
	peds.append(p)
	return p


## Pick the same colours CharacterModel._dress() would for this seed, so a person
## keeps their clothes when they switch between the cheap and the full model.
func _set_outfit(p: Ped, outfit: int) -> void:
	var r := RandomNumberGenerator.new()
	r.seed = outfit
	var skin := r.randi() % CharacterModel.SKIN.size()
	var shirt := r.randi() % CharacterModel.SHIRT.size()
	var pants := r.randi() % CharacterModel.PANTS.size()
	var hair := r.randi() % CharacterModel.HAIR.size()
	var shoes := r.randi() % CharacterModel.SHOES.size()
	p.outfit = outfit
	p.look = shirt + pants * 8
	p.look2 = skin + hair * 8 + shoes * 64


static func _palette(cols: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in cols:
		out.append(Vector3(c.r, c.g, c.b))
	return out


func remove(p: Ped) -> void:
	_release_hero(p)
	_leave_crossing(p)
	peds.erase(p)


## Drop people whose sidewalk was removed. Call after RoadNet.rebuild().
func validate() -> void:
	for p in peds.duplicate():
		if not net.has_walk_edge(p.a, p.b):
			remove(p)


# -------------------------------------------------------------- simulate ---

func _choose_next(p: Ped, came_from: int) -> bool:
	var edges: Array = net.walk_adj.get(p.a, [])
	if edges.is_empty():
		return false
	var opts := []
	var ws := []
	var total := 0.0
	for e in edges:
		if e[0] == came_from and edges.size() > 1:
			continue
		var w := 1.0
		if e[1] >= 0:
			w = 0.45  # crossings are taken less often than staying on the block
		var cell: int = e[0] / 4
		if cell < weight.size():
			w *= 0.4 + weight[cell]
		opts.append(e)
		ws.append(w)
		total += w
	var r := rng.randf() * total
	var pick: Array = opts[-1]
	for k in opts.size():
		r -= ws[k]
		if r <= 0.0:
			pick = opts[k]
			break
	p.b = pick[0]
	p.arm = pick[1]
	p.length = maxf(net.node_pos(p.a).distance_to(net.node_pos(p.b)), 0.01)
	p.t = 0.0
	p.crossing = false
	return true


func _enter_crossing(p: Ped) -> void:
	var key: int = (p.a / 4) * 4 + p.arm
	net.crossing[key] = net.crossing.get(key, 0) + 1
	p.crossing = true


func _leave_crossing(p: Ped) -> void:
	if p.crossing:
		var key: int = (p.a / 4) * 4 + p.arm
		net.crossing[key] = maxi(net.crossing.get(key, 1) - 1, 0)
		p.crossing = false


func step(dt: float) -> void:
	for p in peds.duplicate():
		if p.pause > 0.0:
			p.pause -= dt
			p.phase = 0.0
			continue
		if p.arm >= 0 and not p.crossing:
			# Waiting at the kerb for the walk signal.
			var cell: int = p.a / 4
			if net.junction[cell] == 0 or net.walk_ok(cell, p.arm):
				_enter_crossing(p)
			else:
				p.phase = 0.0
				_place(p)
				continue
		p.t += p.speed * dt
		p.phase = fmod(p.phase + p.speed * dt * 4.2, TAU)
		if p.t >= p.length:
			var came: int = p.a
			_leave_crossing(p)
			p.a = p.b
			if not _choose_next(p, came):
				remove(p)
				continue
			if p.arm < 0 and rng.randf() < 0.06:
				p.pause = rng.randf_range(2.0, 7.0)  # window shopping, phone, chat
		_place(p)


func _place(p: Ped) -> void:
	var pa := net.node_pos(p.a)
	var pb := net.node_pos(p.b)
	var dir := (pb - pa) / p.length
	if dir.length_squared() < 0.5:
		dir = p.fwd
	var right := Vector3(-dir.z, 0, dir.x)
	var f := clampf(p.t / p.length, 0.0, 1.0)
	var pos := pa.lerp(pb, f) + right * p.side
	if p.arm >= 0:
		pos.y = 0.06 if p.crossing and f > 0.08 and f < 0.92 else 0.17
	# Waiting at a crossing: stand at the kerb, facing the road.
	p.pos = pos
	p.fwd = dir


# ---------------------------------------------------------------- render ---

func render() -> void:
	if _buf.size() != max_peds * 16:
		_buf.resize(max_peds * 16)
	var n := 0
	for p in peds:
		if n >= max_peds:
			break
		if p.hero != null:
			continue
		var back := -p.fwd * p.size
		var right := Vector3(back.z, 0, -back.x)
		var o := n * 16
		_buf[o] = right.x; _buf[o + 1] = 0.0; _buf[o + 2] = back.x; _buf[o + 3] = p.pos.x
		_buf[o + 4] = 0.0; _buf[o + 5] = p.size; _buf[o + 6] = 0.0; _buf[o + 7] = p.pos.y
		_buf[o + 8] = right.z; _buf[o + 9] = 0.0; _buf[o + 10] = back.z; _buf[o + 11] = p.pos.z
		var moving := p.pause <= 0.0 and (p.arm < 0 or p.crossing)
		_buf[o + 12] = p.phase
		_buf[o + 13] = 1.0 if moving else 0.0
		_buf[o + 14] = float(p.look)
		_buf[o + 15] = float(p.look2)
		n += 1
	_mmi.multimesh.buffer = _buf
	_mmi.multimesh.visible_instance_count = n
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# ---------------------------------------------------------------- close-up ---
# The people nearest the camera swap to the full rigged CharacterModel (about 7.7k
# triangles, 17 bones). A small pool is reused; everyone else stays a MultiMesh instance.

const HERO_MAX := 24
const HERO_RADIUS := 28.0
const HERO_KEEP := 34.0        # hysteresis so people don't flicker at the edge
const HERO_SPAWNS_PER_FRAME := 2

var _heroes_on := false
var _pool: Array[CharacterModel] = []   # idle models
var _hero_count := 0


func update_heroes(dt: float) -> void:
	if not _heroes_on or camera == null or not camera.is_inside_tree():
		for p in peds:
			_release_hero(p)
		return
	var eye := camera.global_position
	var close := eye.y < 40.0
	# Let go of anyone who walked away (or when the camera went up).
	for p in peds:
		if p.hero != null and (not close or p.pos.distance_to(eye) > HERO_KEEP):
			_release_hero(p)
	if close:
		var cand: Array = []
		for p in peds:
			if p.hero == null:
				var d := p.pos.distance_squared_to(eye)
				if d < HERO_RADIUS * HERO_RADIUS:
					cand.append([d, p])
		cand.sort_custom(func(a, b): return a[0] < b[0])
		var made := 0
		for c in cand:
			if _hero_count >= HERO_MAX:
				break
			if _pool.is_empty():
				if made >= HERO_SPAWNS_PER_FRAME:
					break  # spread model creation over frames
				made += 1
			_take_hero(c[1])
	for p in peds:
		if p.hero == null:
			continue
		var m: CharacterModel = p.hero
		m.global_position = p.pos
		m.global_basis = Basis.looking_at(p.fwd, Vector3.UP).scaled(Vector3.ONE * p.size)
		var moving := p.pause <= 0.0 and (p.arm < 0 or p.crossing)
		m.animate(dt, CharacterModel.WALK_SPEED if moving else 0.0, true, 0.0, 0.0)
		if moving:
			# The walk clip is authored at 3.6 m/s; play it slower to match a stroll.
			m.tree.set("parameters/pace/scale", clampf(p.speed / CharacterModel.WALK_SPEED * 1.7, 0.5, 1.0))


func _take_hero(p: Ped) -> void:
	var m: CharacterModel
	if _pool.is_empty():
		m = CharacterModel.new()
		m.seed_value = p.outfit
		add_child(m)
	else:
		m = _pool.pop_back()
		m.visible = true
		if m.seed_value != p.outfit:
			m.seed_value = p.outfit
			m._dress()
		m.tree.active = true
	p.hero = m
	_hero_count += 1


func _release_hero(p: Ped) -> void:
	if p.hero == null:
		return
	var m: CharacterModel = p.hero
	m.visible = false
	m.tree.active = false
	_pool.append(m)
	p.hero = null
	_hero_count -= 1


func hero_count() -> int:
	return _hero_count
