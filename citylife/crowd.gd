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
	mm.mesh.surface_set_material(0, mat)
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
	p.look = rng.randi() % 8 + (rng.randi() % 6) * 8
	p.look2 = rng.randi() % 5 + (rng.randi() % 5) * 8
	_place(p)
	peds.append(p)
	return p


func remove(p: Ped) -> void:
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
