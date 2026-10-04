class_name Police
extends Node3D
## Cops. When the suspect has wanted stars, patrol cars are dispatched from the nearest
## police station, drive the road grid toward the suspect with sirens (traffic pulls
## over), and drop officers who chase on foot. Cops share what they see: while any of
## them has line of sight the suspect is `seen`; break it and they head for the last
## sighting, then search. Capped at MAX_CARS cars and MAX_OFFICERS officers.
##
## The suspect is any object with `wanted_stars: int`, `suspect_position() -> Vector3`,
## `suspect_velocity() -> Vector3` and `suspect_in_vehicle() -> bool` (the player
## thread's wanted system). Stars and their fading belong to the suspect; Police only
## reports `sighting_changed(seen)` and `busted()`.

signal sighting_changed(seen: bool)
signal busted

const MAX_CARS := 6
const MAX_OFFICERS := 8
const CARS_PER_STAR := [0, 1, 2, 3, 5, 6]
const OFFICERS_PER_CAR := 2
const SIGHT := 75.0            # how far cops see, metres
const SIGHT_INTERVAL := 0.25
const DISPATCH_INTERVAL := 2.5
const FAR_STATION := 520.0     # stations farther than this send a unit from nearby instead
const CAR_LEN := 4.4
const BUST_TIME := 1.2
const OFFICER_RUN := 5.4

class CopCar:
	var cell := 0
	var din := 0
	var dout := 0
	var s := 0.0
	var v := 0.0
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	var siren := true
	var parked := false
	var leaving := false       # stars gone: drive off and despawn
	var officers: Array = []   # Officer objects out of this car
	var deployed := false
	var age := 0.0

class Officer:
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	var speed := 0.0
	var car: CopCar
	var model: CharacterModel
	var returning := false
	var near := 0.0            # seconds spent next to a slow suspect

var city: City
var net: RoadNet
var traffic: Traffic
var crowd: Crowd
var camera: Camera3D
var suspect: Object = null
var stations: Array[Vector2i] = []   # police station cells (stubbed until services exist)

var cars: Array[CopCar] = []
var officers: Array[Officer] = []
var seen := false
var last_seen := Vector3.ZERO
var rng := RandomNumberGenerator.new()

var _stars := 0
var _sight_timer := 0.0
var _dispatch_timer := 0.0
var _route_target := -1
var _route := PackedInt32Array()   # BFS hops to the target cell over road arms
var _route_timer := 0.0
var _pool: Array[CharacterModel] = []
var _car_mmi: MultiMeshInstance3D
var _bar_mmi: MultiMeshInstance3D
var _time := 0.0
var _panic_timer := 0.0

const BAR_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;
void fragment() {
	ALBEDO = COLOR.rgb * (0.4 + COLOR.a * 5.0);
}
"""


func setup(c: City, road_net: RoadNet, tr: Traffic, cr: Crowd) -> void:
	city = c
	net = road_net
	traffic = tr
	crowd = cr
	rng.seed = 4242
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var kit := get_tree().root.get_node_or_null("Kit") if is_inside_tree() else null
	var mesh: Mesh = kit.mesh("car_sedan") if kit else null
	if mesh == null:
		var b := BoxMesh.new()
		b.size = Vector3(1.8, 1.3, CAR_LEN)
		mesh = b
	mm.mesh = mesh
	mm.instance_count = MAX_CARS
	mm.visible_instance_count = 0
	_car_mmi = MultiMeshInstance3D.new()
	_car_mmi.name = "CopCars"
	_car_mmi.multimesh = mm
	add_child(_car_mmi)
	var bm := MultiMesh.new()
	bm.transform_format = MultiMesh.TRANSFORM_3D
	bm.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.14, 0.26)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = BAR_SHADER
	box.material = mat
	bm.mesh = box
	bm.instance_count = MAX_CARS * 2
	bm.visible_instance_count = 0
	_bar_mmi = MultiMeshInstance3D.new()
	_bar_mmi.name = "LightBars"
	_bar_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bar_mmi.multimesh = bm
	add_child(_bar_mmi)
	refresh_stations()


## Re-read police station cells. Uses City.service_sites("police") when the services
## thread provides it; otherwise one stub station near the middle of the city.
func refresh_stations() -> void:
	stations.clear()
	for host in [city, city.get("services") if "services" in city else null]:
		if host != null and host.has_method("service_sites"):
			for kind in ["police", "police_hq"]:
				for cell in host.service_sites(kind):
					stations.append(cell)
			return
	stations.append(city.center_cell())


func set_suspect(s: Object) -> void:
	suspect = s


func stars() -> int:
	if suspect == null:
		return 0
	return clampi(int(suspect.get("wanted_stars")), 0, 5)


func suspect_pos() -> Vector3:
	return suspect.suspect_position() if suspect else Vector3.ZERO


## Positions and headings of cars running sirens, for traffic to yield to.
func siren_list() -> Array:
	var out := []
	for c in cars:
		if c.siren and not c.parked:
			out.append([c.pos, c.fwd])
	return out


# ---------------------------------------------------------------- update ---

func step(dt: float) -> void:
	_time += dt
	_stars = stars()
	if _stars > 0:
		_update_sight(dt)
		_dispatch(dt)
	elif seen:
		seen = false
		sighting_changed.emit(false)
	_update_route(dt)
	for c in cars.duplicate():
		_drive(c, dt)
	for o in officers.duplicate():
		_run(o, dt)
	traffic.sirens = siren_list()
	# Trouble scares people: a chase with officers on foot clears the sidewalk.
	_panic_timer -= dt
	if _panic_timer <= 0.0 and _stars >= 2 and seen:
		_panic_timer = 1.5
		crowd.panic(suspect_pos(), 14.0 + _stars * 4.0, 6.0)


func _update_sight(dt: float) -> void:
	_sight_timer -= dt
	if _sight_timer > 0.0:
		return
	_sight_timer = SIGHT_INTERVAL
	var sp := suspect_pos()
	var now := false
	for c in cars:
		if not c.leaving and has_line_of_sight(c.pos, sp):
			now = true
			break
	if not now:
		for o in officers:
			if has_line_of_sight(o.pos, sp):
				now = true
				break
	if now:
		last_seen = sp
	if now != seen:
		seen = now
		sighting_changed.emit(seen)


## Grid line of sight: blocked by any building tile between the two points.
func has_line_of_sight(a: Vector3, b: Vector3) -> bool:
	var d := Vector2(b.x - a.x, b.z - a.z)
	var dist := d.length()
	if dist > SIGHT:
		return false
	var steps := int(dist / (City.TILE * 0.4)) + 1
	for k in range(1, steps):
		var t := float(k) / steps
		var cell := city.world_to_cell(a.lerp(b, t))
		if not city.inside(cell.x, cell.y):
			continue
		if city.bld[city.idx(cell.x, cell.y)] >= 0:
			return false
	return true


func _dispatch(dt: float) -> void:
	_dispatch_timer -= dt
	var want := mini(CARS_PER_STAR[_stars], MAX_CARS)
	var active := 0
	for c in cars:
		if not c.leaving:
			active += 1
	if active >= want or _dispatch_timer > 0.0 or cars.size() >= MAX_CARS:
		return
	_dispatch_timer = DISPATCH_INTERVAL
	var cell := _spawn_cell()
	if cell >= 0:
		spawn_car(cell)


func _spawn_cell() -> int:
	var sp := suspect_pos()
	var best := -1
	var bd := INF
	for st in stations:
		var cell := _nearest_road(st)
		if cell < 0:
			continue
		var d := net.center(cell).distance_to(sp)
		if d < bd:
			bd = d
			best = cell
	if best >= 0 and bd < FAR_STATION:
		return best
	# No station close enough: a patrol car turns up from a road out of sight nearby.
	for attempt in 40:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(150.0, 260.0)
		var p := sp + Vector3(cos(ang), 0, sin(ang)) * r
		var c := city.world_to_cell(p)
		if not city.inside(c.x, c.y):
			continue
		var i := city.idx(c.x, c.y)
		if net.is_road(i) and not _visible(net.center(i)):
			return i
	return best


func _nearest_road(cell: Vector2i) -> int:
	for r in 6:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x := cell.x + dx
				var y := cell.y + dy
				if city.inside(x, y) and net.is_road(city.idx(x, y)):
					return city.idx(x, y)
	return -1


func _visible(p: Vector3) -> bool:
	return camera != null and camera.is_inside_tree() and camera.is_position_in_frustum(p) \
		and camera.global_position.distance_to(p) < 160.0


func spawn_car(cell: int) -> CopCar:
	var heads := net.entries(cell)
	if heads.is_empty():
		return null
	var c := CopCar.new()
	c.cell = cell
	c.din = heads[rng.randi() % heads.size()]
	c.dout = _route_exit(cell, c.din)
	c.v = 6.0
	_place(c)
	cars.append(c)
	return c


# ---------------------------------------------------------------- routing ---

func _update_route(dt: float) -> void:
	_route_timer -= dt
	if _route_timer > 0.0 and _route_target >= 0:
		return
	_route_timer = 0.5
	var target_pos := suspect_pos() if seen or last_seen == Vector3.ZERO else last_seen
	var tc := city.world_to_cell(target_pos)
	var t := -1
	if city.inside(tc.x, tc.y):
		t = _nearest_road(tc)
	if t == _route_target and _route.size() == net.mask.size():
		return
	_route_target = t
	_route.resize(net.mask.size())
	_route.fill(1 << 20)
	if t < 0:
		return
	var q := PackedInt32Array([t])
	_route[t] = 0
	var head := 0
	while head < q.size():
		var i := q[head]
		head += 1
		for d in 4:
			if not net.has_arm(i, d):
				continue
			var n := net.neighbor(i, d)
			if n >= 0 and net.is_road(n) and _route[n] > _route[i] + 1:
				_route[n] = _route[i] + 1
				q.append(n)


func _hops(i: int) -> int:
	if i < 0 or i >= _route.size():
		return 1 << 20
	return _route[i]


## Exit toward the target; wander when there is no route (searching, or leaving).
func _route_exit(cell: int, din: int, wander := false) -> int:
	var opts: Array[int] = []
	for d in 4:
		if net.has_arm(cell, d):
			opts.append(d)
	if opts.is_empty():
		return RoadNet.opp(din)
	if wander or _route.size() != net.mask.size():
		var fwd_opts := opts.filter(func(d): return d != RoadNet.opp(din))
		if fwd_opts.is_empty():
			return opts[0]
		return fwd_opts[rng.randi() % fwd_opts.size()]
	var best: int = opts[0]
	var bh := 1 << 30
	for d in opts:
		var h := _hops(net.neighbor(cell, d)) * 4 + (3 if d == RoadNet.opp(din) else 0)
		if h < bh:
			bh = h
			best = d
	return best


# ---------------------------------------------------------------- cop cars ---

func _drive(c: CopCar, dt: float) -> void:
	c.age += dt
	var sp := suspect_pos()
	var dist := c.pos.distance_to(sp)
	var in_car: bool = suspect != null and suspect.suspect_in_vehicle()
	if _stars == 0 and not c.leaving:
		c.leaving = true
		c.siren = false
		c.parked = false
		_recall(c)
	if c.leaving:
		if c.officers.is_empty() and (c.age > 40.0 or not _visible(c.pos)) and c.v > 0.0 or c.age > 90.0:
			_remove_car(c)
			return
	# Pull up next to a suspect on foot (or a stopped car) and send officers out.
	var close := not c.leaving and seen and dist < (14.0 if in_car else 22.0)
	var suspect_slow: bool = suspect != null and suspect.suspect_velocity().length() < 2.0
	if close and (not in_car or suspect_slow):
		if c.v < 0.5 and not c.deployed:
			_deploy(c)
		c.parked = true
	elif c.parked and (c.officers.is_empty() or dist > 45.0):
		_recall(c)
		c.parked = false
	var v0 := 0.0 if c.parked or not c.officers.is_empty() else _cop_speed(c)
	if c.leaving:
		v0 = 9.0
	# Keep a car length from other cop cars ahead.
	for o in cars:
		if o != c:
			var to := o.pos - c.pos
			var ahead := c.fwd.dot(to)
			if ahead > 0.0 and ahead < 8.0 and absf(c.fwd.cross(to).y) < 2.5:
				v0 = minf(v0, o.v * 0.8)
	var a := 7.0 if v0 > c.v else -11.0
	c.v = move_toward(c.v, v0, absf(a) * dt)
	c.s += c.v * dt
	var m := c.din * 4 + c.dout
	while c.s >= net.move_len[m]:
		c.s -= net.move_len[m]
		var nxt := net.neighbor(c.cell, c.dout)
		if not net.is_road(nxt):
			_remove_car(c)
			return
		c.cell = nxt
		c.din = c.dout
		c.dout = _route_exit(nxt, c.din, c.leaving or (not seen and _hops(nxt) == 0))
		m = c.din * 4 + c.dout
	_place(c)


func _cop_speed(c: CopCar) -> float:
	var m := c.din * 4 + c.dout
	var top := 15.0 + _stars * 2.2
	if c.dout == RoadNet.opp(c.din):
		return 4.0
	if net.is_turn(m):
		return 8.0
	# Brake for the next turn.
	var nxt := net.neighbor(c.cell, c.dout)
	if net.is_road(nxt):
		var next_out := _route_exit(nxt, c.dout)
		if next_out != c.dout:
			return lerpf(8.0, top, clampf((net.move_len[m] - c.s) / 25.0, 0.0, 1.0))
	return top


func _place(c: CopCar) -> void:
	var smp := net.sample(c.din * 4 + c.dout, c.s)
	c.fwd = smp[1]
	c.pos = net.center(c.cell) + smp[0] + Vector3(0, Traffic.ROAD_Y, 0)
	if c.siren:
		# Run down the middle of the road while traffic pulls over.
		c.pos -= Vector3(-c.fwd.z, 0, c.fwd.x) * 1.4


func _remove_car(c: CopCar) -> void:
	for o in c.officers.duplicate():
		_remove_officer(o)
	cars.erase(c)


# ---------------------------------------------------------------- officers ---

func _deploy(c: CopCar) -> void:
	c.deployed = true
	for k in OFFICERS_PER_CAR:
		if officers.size() >= MAX_OFFICERS:
			return
		var o := Officer.new()
		o.car = c
		var side := Vector3(-c.fwd.z, 0, c.fwd.x) * (1.4 if k == 0 else -1.4)
		o.pos = c.pos + side
		o.fwd = c.fwd
		o.model = _take_model()
		officers.append(o)
		c.officers.append(o)
	if crowd:
		crowd.panic(c.pos, 18.0, 5.0)


func _recall(c: CopCar) -> void:
	for o in c.officers:
		o.returning = true


func _run(o: Officer, dt: float) -> void:
	var sp := suspect_pos()
	var target := o.car.pos if o.returning else (sp if seen else last_seen)
	var to := Vector3(target.x - o.pos.x, 0, target.z - o.pos.z)
	var d := to.length()
	if o.returning and d < 1.6:
		_remove_officer(o)
		return
	var want := OFFICER_RUN if d > 1.1 else 0.0
	if not o.returning and not seen and d < 2.0:
		want = 0.0  # searching where the suspect was last seen
	o.speed = move_toward(o.speed, want, 12.0 * dt)
	if d > 0.01:
		var dir := to / d
		o.fwd = o.fwd.slerp(dir, minf(1.0, dt * 8.0)).normalized()
		var step := dir * o.speed * dt
		o.pos = _walk(o.pos, step)
	# Busted: an officer holds onto a slow or stopped suspect.
	if not o.returning and seen and suspect != null:
		var reach := 2.6 if suspect.suspect_in_vehicle() else 1.3
		var slow: bool = suspect.suspect_velocity().length() < (1.0 if suspect.suspect_in_vehicle() else 2.2)
		if o.pos.distance_to(sp) < reach and slow:
			o.near += dt
			if o.near >= BUST_TIME:
				o.near = 0.0
				busted.emit()
		else:
			o.near = 0.0
	if o.model:
		o.model.global_position = o.pos
		if o.fwd.length_squared() > 0.01:
			o.model.global_basis = Basis.looking_at(o.fwd, Vector3.UP)
		o.model.animate(dt, o.speed, true, 0.0, 0.0)


## Move on foot without entering building lots.
func _walk(p: Vector3, step: Vector3) -> Vector3:
	for cand in [step, Vector3(step.x, 0, 0), Vector3(0, 0, step.z)]:
		var q: Vector3 = p + cand
		var c := city.world_to_cell(q)
		if not city.inside(c.x, c.y) or city.bld[city.idx(c.x, c.y)] < 0:
			q.y = 0.17 if not net.is_road(city.idx(c.x, c.y)) or _on_sidewalk(q) else 0.06
			return q
	return p


func _on_sidewalk(q: Vector3) -> bool:
	var c := city.world_to_cell(q)
	var ctr := city.cell_center(c.x, c.y)
	return absf(q.x - ctr.x) > 3.75 and absf(q.z - ctr.z) > 3.75


func _remove_officer(o: Officer) -> void:
	officers.erase(o)
	if o.car:
		o.car.officers.erase(o)
	if o.model:
		o.model.visible = false
		_pool.append(o.model)
		o.model = null


func _take_model() -> CharacterModel:
	if not CharacterModel.available():
		return null
	var m: CharacterModel
	if not _pool.is_empty():
		m = _pool.pop_back()
		m.visible = true
		return m
	m = CharacterModel.new()
	m.seed_value = 777
	add_child(m)
	_uniform(m)
	return m


## Dress a CharacterModel as a police officer: navy shirt and trousers, black shoes.
static func _uniform(m: CharacterModel) -> void:
	var cols := {"Shirt": Color(0.12, 0.17, 0.33), "Pants": Color(0.08, 0.1, 0.18),
		"Shoes": Color(0.05, 0.05, 0.06), "Hair": Color(0.06, 0.07, 0.12)}
	for mi in m.model.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := mi as MeshInstance3D
		for s in mesh_inst.mesh.get_surface_count():
			var src := mesh_inst.mesh.surface_get_material(s)
			var nm := src.resource_name if src else ""
			var mat := mesh_inst.get_surface_override_material(s) as StandardMaterial3D
			if mat and cols.has(nm):
				mat.albedo_color = cols[nm]


func cop_count() -> int:
	return cars.size()


func officer_count() -> int:
	return officers.size()


# ---------------------------------------------------------------- render ---

func render() -> void:
	var mm := _car_mmi.multimesh
	var bm := _bar_mmi.multimesh
	var flash := fmod(_time * 3.0, 1.0) < 0.5
	var n := 0
	for c in cars:
		if n >= MAX_CARS:
			break
		var back := -c.fwd
		var right := Vector3.UP.cross(back).normalized()
		var xf := Transform3D(Basis(right, Vector3.UP, back), c.pos)
		mm.set_instance_transform(n, xf)
		mm.set_instance_color(n, Color(0.95, 0.95, 0.97))
		mm.set_instance_custom_data(n, Color(0, 0, 0, 0))
		for k in 2:
			var on := c.siren and (flash if k == 0 else not flash)
			var col := Color(1.0, 0.08, 0.05) if k == 0 else Color(0.1, 0.3, 1.0)
			col.a = 1.0 if on else 0.0
			bm.set_instance_transform(n * 2 + k, xf * Transform3D(Basis(), Vector3(-0.28 if k == 0 else 0.28, 1.55, 0.1)))
			bm.set_instance_color(n * 2 + k, col)
		n += 1
	mm.visible_instance_count = n
	bm.visible_instance_count = n * 2
