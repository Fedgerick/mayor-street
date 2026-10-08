class_name Crowd
extends Node3D
## Pedestrians on the sidewalks. They wander the RoadNet sidewalk graph, keep to the
## right of the walkway, stop now and then, and use zebra crossings only on the walk
## phase. Everyone is one MultiMesh of a procedural low-poly person; walking is animated
## in the vertex shader from a per-instance phase, so the CPU only moves points.
##
## People also stop for things: they sit on benches, wait at bus stops and get on the
## bus, stand in small groups chatting, look at their phones, walk dogs and stop to stare
## at crashes. How many do which follows the hour (see `hour`).

const PED_SHADER := preload("res://citylife/ped.gdshader")
const DOG_SHADER := preload("res://citylife/dog.gdshader")
const UMBRELLA_SHADER := preload("res://citylife/umbrella.gdshader")

enum Act { WALK, SIT, WAIT, CHAT, BOARD }
enum Pose { NONE, SIT, PHONE, CHAT, UMBRELLA, LEAD }

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
	var flee := 0.0       # seconds left running from trouble
	var flee_from := Vector3.ZERO
	var size := 1.0
	var crossing := false
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	# What they are doing besides walking (see Act). While act != WALK the person has
	# stepped off the walking line at t to `at`, by `go` (0 on the line .. 1 there).
	var act := 0
	var act_t := 0.0      # seconds left at the spot
	var go := 0.0
	var leaving := false
	var from := Vector3.ZERO
	var at := Vector3.ZERO
	var face := Vector3.FORWARD
	var spot: StreetSpots.Spot = null
	var slot := -1
	var spot_t := -1.0    # metres along the current edge where they step off to the spot
	var group: Array = [] # chat group obstacle [strip key, u, members left], shared
	var phone := false    # walks along looking at a phone
	var dog := false      # walks a dog
	var coat := 0
	var gawk := false     # stopped to stare at something
	var film := false     # ... and films it
	var umbrella := false # has an umbrella up

var net: RoadNet
var peds: Array[Ped] = []
var max_peds := 360
var rng := RandomNumberGenerator.new()
var weight := PackedFloat32Array()  # spawn weight per road cell (set by CityLife)
var shadows := true
var camera: Camera3D
var spots: StreetSpots           # benches and bus stops (set by CityLife)
var hour := 12.0                 # time of day, set by CityLife; shapes what people do
var buses_running := true
var max_dogs := 48
var rain := 0.0                  # 0..1 from Weather: people hurry, put umbrellas up
var wet := 0.0                   # 0..1 how wet the streets (and benches) are
var umbrella_share := 0.0
## Real bodies on the sidewalk (the player on foot), set each frame by the street layer.
## Walkers about to bump into one stop for a moment and step aside.
var blockers: Array[Vector3] = []

var _mmi: MultiMeshInstance3D
var _buf := PackedFloat32Array()
var _dog_mmi: MultiMeshInstance3D
var _dog_buf := PackedFloat32Array()
var _brolly_mmi: MultiMeshInstance3D
var _brolly_buf := PackedFloat32Array()
var _brolly_timer := 0.0
var _groups := {}                # strip key -> Array of chat groups standing there

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
	var dm := MultiMesh.new()
	dm.transform_format = MultiMesh.TRANSFORM_3D
	dm.use_custom_data = true
	dm.mesh = DogMesh.build()
	var dmat := ShaderMaterial.new()
	dmat.shader = DOG_SHADER
	dm.mesh.surface_set_material(0, dmat)
	dm.instance_count = max_dogs
	dm.visible_instance_count = 0
	_dog_mmi = MultiMeshInstance3D.new()
	_dog_mmi.multimesh = dm
	_dog_mmi.name = "Dogs"
	add_child(_dog_mmi)
	var um := MultiMesh.new()
	um.transform_format = MultiMesh.TRANSFORM_3D
	um.use_custom_data = true
	um.mesh = UmbrellaMesh.build()
	var umat := ShaderMaterial.new()
	umat.shader = UMBRELLA_SHADER
	um.mesh.surface_set_material(0, umat)
	um.instance_count = max_peds
	um.visible_instance_count = 0
	_brolly_mmi = MultiMeshInstance3D.new()
	_brolly_mmi.multimesh = um
	_brolly_mmi.name = "Umbrellas"
	add_child(_brolly_mmi)


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
		_drop_spot(p)
		return null  # never spawn on a crossing
	p.t = rng.randf() * p.length
	if p.spot_t >= 0.0 and p.t > p.spot_t:
		_drop_spot(p)  # spawned past their seat
	p.speed = rng.randf_range(1.1, 1.6) * _pace()
	p.size = rng.randf_range(0.9, 1.08)
	p.side = rng.randf_range(0.0, 0.3)
	p.phase = rng.randf() * TAU
	_set_outfit(p, rng.randi() % 100000)
	p.phone = rng.randf() < phone_share()
	if rng.randf() < dog_share() and dog_count() < max_dogs:
		p.dog = true
		p.coat = rng.randi() % 5
		p.speed = rng.randf_range(0.95, 1.2)
		p.phone = false
	_place(p)
	peds.append(p)
	return p


# ---------------------------------------------------------------- the hour ---
# Morning and evening commuters hurry and rarely sit; lunch fills the benches; late at
# night the few people out stand around talking or stare at their phones.

## Up go the umbrellas as the rain starts (each person decides from their own seed, so
## the same people carry one), and down when it stops.
func _update_umbrellas() -> void:
	for p in peds:
		p.umbrella = (p.outfit % 997) / 997.0 < umbrella_share


func _commute() -> bool:
	return hour >= 7.0 and hour < 9.5 or hour >= 16.5 and hour < 18.5


func _late() -> bool:
	return hour >= 21.0 or hour < 5.0


func _pace() -> float:
	return 1.15 if _commute() else 1.0


func sit_share() -> float:
	var dry := 1.0 - 0.9 * wet  # nobody sits on a soaked bench
	if _commute():
		return 0.12 * dry
	if hour >= 11.5 and hour < 14.0:
		return 0.55 * dry
	if _late():
		return 0.08 * dry
	return 0.3 * dry


func phone_share() -> float:
	return 0.24 if _late() else 0.15


func dog_share() -> float:
	if hour >= 6.0 and hour < 9.0 or hour >= 17.0 and hour < 21.0:
		return 0.08
	return 0.01 if _late() else 0.03


## Share of new people who appear as a group standing and talking.
func chat_share() -> float:
	var dry := 1.0 - 0.7 * rain
	if hour >= 11.5 and hour < 14.0:
		return 0.09 * dry
	if _late():
		return 0.12 * dry
	return (0.05 if not _commute() else 0.02) * dry


func dog_count() -> int:
	var n := 0
	for p in peds:
		if p.dog:
			n += 1
	return n


func count_act(a: int) -> int:
	var n := 0
	for p in peds:
		if p.act == a:
			n += 1
	return n


# ------------------------------------------------------------- chat groups ---

## Two or three people standing on the sidewalk talking. Returns how many were made.
func spawn_group(cell: int) -> int:
	var sides: Array[int] = []
	for d in 4:
		if net.is_road(cell) and not net.has_arm(cell, d) and net.has_walk_edge(cell * 4 + d, cell * 4 + (d + 1) % 4):
			if spots == null or not spots.by_strip.has(cell * 4 + d):
				sides.append(d)
	if sides.is_empty() or net.junction[cell] == 1:
		return 0
	var d: int = sides[rng.randi() % sides.size()]
	var key := cell * 4 + d
	var u := rng.randf_range(-3.6, 3.6)
	for g in _groups.get(key, []):
		if absf(g[1] - u) < 2.6:
			return 0
	var out: Vector3 = RoadNet.DV[d]
	var along := Vector3.UP.cross(-out)
	var mid := net.center(cell) + out * 5.45 + along * u + Vector3(0, 0.17, 0)
	var n := 2 + (1 if rng.randf() < 0.4 else 0)
	var group := [key, u, n]
	if not _groups.has(key):
		_groups[key] = []
	_groups[key].append(group)
	var stay := rng.randf_range(30.0, 110.0)
	var a0 := rng.randf() * TAU
	for k in n:
		var p := Ped.new()
		var fwd_dir := rng.randf() < 0.5
		p.a = cell * 4 + (d if fwd_dir else (d + 1) % 4)
		p.b = cell * 4 + ((d + 1) % 4 if fwd_dir else d)
		p.arm = -1
		p.length = maxf(net.node_pos(p.a).distance_to(net.node_pos(p.b)), 0.01)
		p.t = clampf(p.length * 0.5 + (u if fwd_dir else -u), 0.0, p.length)
		p.speed = rng.randf_range(1.1, 1.5)
		p.size = rng.randf_range(0.9, 1.08)
		p.side = rng.randf_range(0.0, 0.3)
		_set_outfit(p, rng.randi() % 100000)
		var ang := a0 + TAU * float(k) / n + rng.randf_range(-0.3, 0.3)
		p.at = mid + Vector3(cos(ang), 0, sin(ang)) * 0.5
		p.face = (mid - p.at).normalized()
		p.act = Act.CHAT
		p.go = 1.0
		p.act_t = stay + rng.randf_range(-4.0, 6.0)
		p.group = group
		p.from = _path_pos(p)
		p.pos = p.at
		p.fwd = p.face
		peds.append(p)
	return n


func _leave_group(p: Ped) -> void:
	if p.group.is_empty():
		return
	var g: Array = p.group
	p.group = []
	g[2] -= 1
	if g[2] <= 0:
		var list: Array = _groups.get(g[0], [])
		list.erase(g)
		if list.is_empty():
			_groups.erase(g[0])


# ------------------------------------------------------------------ spots ---

## Maybe plan to stop at the bench or bus stop on the edge just chosen.
func _plan_spot(p: Ped) -> void:
	if spots == null or p.arm >= 0 or p.a / 4 != p.b / 4 or p.flee > 0.0:
		return
	var cell: int = p.a / 4
	var ka: int = p.a % 4
	var kb: int = p.b % 4
	var side := ka if kb == (ka + 1) % 4 else kb
	var s: StreetSpots.Spot = spots.by_strip.get(cell * 4 + side)
	if s == null:
		return
	var chance := sit_share() * 0.6
	if s.kind == StreetSpots.Kind.STOP:
		chance = (0.18 if not _commute() else 0.35) * (1.0 + rain) if buses_running else 0.0
	if p.dog:
		chance *= 0.4
	if rng.randf() >= chance:
		return
	var k := -1
	if s.kind == StreetSpots.Kind.BENCH:
		k = s.free_slot()
	else:
		# Seats first for the tired, the rest stand.
		var order := range(s.taken.size())
		if rng.randf() < 0.5:
			order.reverse()
		for j in order:
			if s.taken[j] == null:
				k = j
				break
	if k < 0:
		return
	var axis := s.xform.basis.x
	var u := (s.slot_pos(k) - net.center(cell)).dot(axis)
	var fwd := kb == (ka + 1) % 4
	p.spot_t = clampf(p.length * 0.5 + (u if fwd else -u), 0.3, p.length - 0.3)
	p.spot = s
	p.slot = k
	s.taken[k] = p


func _drop_spot(p: Ped) -> void:
	if p.spot != null and p.slot >= 0 and p.slot < p.spot.taken.size() and p.spot.taken[p.slot] == p:
		p.spot.taken[p.slot] = null
		if p.act == Act.WAIT:
			p.spot.waiting = maxi(p.spot.waiting - 1, 0)
	p.spot = null
	p.slot = -1
	p.spot_t = -1.0


func _arrive(p: Ped) -> void:
	var s := p.spot
	p.t = p.spot_t
	p.from = _path_pos(p)
	p.at = s.slot_pos(p.slot)
	p.face = s.face()
	p.go = 0.0
	p.leaving = false
	if s.kind == StreetSpots.Kind.BENCH:
		p.act = Act.SIT
		p.act_t = rng.randf_range(15.0, 70.0) * (1.6 if hour >= 11.5 and hour < 14.0 else 1.0)
	else:
		p.act = Act.WAIT
		p.act_t = rng.randf_range(60.0, 120.0)  # give up on the bus after this
		s.waiting += 1


## Step toward the spot, stay, then step back onto the walking line and carry on.
func _station(p: Ped, dt: float) -> void:
	if p.act == Act.BOARD:
		var dist := maxf(p.from.distance_to(p.at), 0.3)
		p.go += dt * 1.4 / dist
		p.pos = p.from.lerp(p.at, minf(p.go, 1.0))
		p.fwd = (p.at - p.from).normalized() if dist > 0.31 else p.fwd
		p.phase = fmod(p.phase + 1.4 * dt * 4.2, TAU)
		if p.go >= 1.0:
			remove(p)
		return
	if p.leaving:
		p.go -= dt / 1.1
		if p.go <= 0.0:
			p.go = 0.0
			_end_station(p)
			_place(p)
			return
	elif p.go < 1.0:
		p.go = minf(p.go + dt / 1.1, 1.0)
	else:
		p.act_t -= dt
		if p.act_t <= 0.0:
			p.leaving = true
	var f := smoothstep(0.0, 1.0, p.go)
	p.pos = p.from.lerp(p.at, f)
	var moving := p.go > 0.0 and p.go < 1.0
	if moving:
		p.phase = fmod(p.phase + p.speed * dt * 4.2, TAU)
		var d := (p.at - p.from) * (-1.0 if p.leaving else 1.0)
		if d.length_squared() > 0.01:
			p.fwd = d.normalized()
	else:
		p.phase = 0.0
		p.fwd = p.face


func _end_station(p: Ped) -> void:
	_leave_group(p)
	_drop_spot(p)
	p.act = Act.WALK
	p.leaving = false


## The bus is in: everyone waiting at this stop walks to the door and gets on.
func board(s: StreetSpots.Spot, door: Vector3) -> int:
	var n := 0
	for p in peds.duplicate():
		if p.spot == s and p.act == Act.WAIT and p.go >= 0.9 and not p.leaving:
			_drop_spot(p)
			p.act = Act.BOARD
			p.from = p.pos
			p.at = door
			p.go = 0.0
			n += 1
	return n


## People getting off the bus at stop `s`: they step off at the door and walk away.
func alight(s: StreetSpots.Spot, door: Vector3, count: int) -> int:
	var made := 0
	for k in count:
		if peds.size() >= max_peds:
			break
		var p := Ped.new()
		var fwd_dir := rng.randf() < 0.5
		var d := s.side
		p.a = s.cell * 4 + (d if fwd_dir else (d + 1) % 4)
		p.b = s.cell * 4 + ((d + 1) % 4 if fwd_dir else d)
		if not net.has_walk_edge(p.a, p.b):
			break
		p.arm = -1
		p.length = maxf(net.node_pos(p.a).distance_to(net.node_pos(p.b)), 0.01)
		p.t = clampf(p.length * 0.5 + (s.u if fwd_dir else -s.u) + rng.randf_range(-1.0, 1.0), 0.0, p.length)
		p.speed = rng.randf_range(1.1, 1.6) * _pace()
		p.size = rng.randf_range(0.9, 1.08)
		p.side = rng.randf_range(0.0, 0.3)
		_set_outfit(p, rng.randi() % 100000)
		p.phone = rng.randf() < phone_share()
		# Start at the door, already "leaving" the spot back to the walking line.
		p.act = Act.WAIT
		p.at = door + s.xform.basis.x * rng.randf_range(-0.5, 0.5)
		p.from = _path_pos(p)
		p.go = 1.0
		p.leaving = true
		p.pos = p.at
		peds.append(p)
		made += 1
	return made


## Something happened at pos (a crash): people nearby stop and stare for a while, some
## get their phones out. Returns how many stopped.
func gawk(pos: Vector3, radius: float) -> int:
	var n := 0
	var r2 := radius * radius
	for p in peds:
		if p.flee > 0.0 or p.act == Act.BOARD:
			continue
		var d2 := p.pos.distance_squared_to(pos)
		if d2 > r2 or d2 < 0.01:
			continue
		n += 1
		var to := pos - p.pos
		to.y = 0.0
		if p.act == Act.WALK:
			if p.arm >= 0 and p.crossing:
				continue  # keep going over the road
			p.pause = rng.randf_range(3.0, 8.0)
			p.gawk = true
			p.film = rng.randf() < 0.35
			p.fwd = to.normalized()
		elif p.act == Act.SIT or p.act == Act.WAIT or p.act == Act.CHAT:
			if p.go >= 1.0:
				p.face = to.normalized()
				p.fwd = p.face
	return n


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
	p.umbrella = (outfit % 997) / 997.0 < umbrella_share


static func _palette(cols: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for c in cols:
		out.append(Vector3(c.r, c.g, c.b))
	return out


func remove(p: Ped) -> void:
	_release_hero(p)
	_leave_crossing(p)
	_leave_group(p)
	_drop_spot(p)
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
	_drop_spot(p)
	_plan_spot(p)
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


const RUN := 4.3


## Everyone within `radius` of `pos` runs away from it for a while.
func panic(pos: Vector3, radius: float, seconds := 8.0) -> int:
	var n := 0
	var r2 := radius * radius
	for p in peds:
		var d2 := p.pos.distance_squared_to(pos)
		if d2 > r2:
			continue
		n += 1
		p.pause = 0.0
		p.gawk = false
		if p.act == Act.BOARD:
			continue
		if p.act != Act.WALK:
			_end_station(p)
		_drop_spot(p)
		# Closer people run longer.
		p.flee = maxf(p.flee, seconds * (1.2 - 0.6 * sqrt(d2) / radius))
		p.flee_from = pos
		if p.arm < 0 or p.crossing:
			# Turn around if walking toward the trouble.
			var to := pos - p.pos
			if p.fwd.dot(to) > 0.0 and net.has_walk_edge(p.b, p.a) and p.arm < 0:
				var tmp := p.a
				p.a = p.b
				p.b = tmp
				p.t = p.length - p.t
		_place(p)
	return n


func fleeing_count() -> int:
	var n := 0
	for p in peds:
		if p.flee > 0.0:
			n += 1
	return n


## A person who just appeared at `pos` (a driver pulled from a car) and runs from `from`.
func spawn_fleeing(pos: Vector3, from: Vector3) -> Ped:
	var cell := net.city.world_to_cell(pos)
	if not net.city.inside(cell.x, cell.y):
		return null
	var i := net.city.idx(cell.x, cell.y)
	var best := -1
	var bd := INF
	for k in 4:
		var node := i * 4 + k
		if net.walk_adj.has(node):
			var d := net.node_pos(node).distance_squared_to(pos)
			if d < bd:
				bd = d
				best = node
	if best < 0:
		return null
	var p := Ped.new()
	p.a = best
	if not _choose_flee(p, -1):
		return null
	p.speed = rng.randf_range(1.1, 1.6)
	p.size = rng.randf_range(0.9, 1.08)
	p.side = rng.randf_range(0.0, 0.3)
	_set_outfit(p, rng.randi() % 100000)
	p.flee = 12.0
	p.flee_from = from
	_place(p)
	peds.append(p)
	return p


func _choose_flee(p: Ped, came_from: int) -> bool:
	var edges: Array = net.walk_adj.get(p.a, [])
	if edges.is_empty():
		return false
	var pick: Array = edges[0]
	var best := -INF
	for e in edges:
		var d := net.node_pos(e[0]).distance_to(p.flee_from)
		if e[0] == came_from:
			d -= 4.0  # prefer not to double back
		d += rng.randf() * 2.0
		if d > best:
			best = d
			pick = e
	p.b = pick[0]
	p.arm = pick[1]
	p.length = maxf(net.node_pos(p.a).distance_to(net.node_pos(p.b)), 0.01)
	p.t = 0.0
	p.crossing = false
	return true


func step(dt: float) -> void:
	_brolly_timer -= dt
	if _brolly_timer <= 0.0:
		_brolly_timer = 1.0
		_update_umbrellas()
	for p in peds.duplicate():
		if p.flee > 0.0:
			_run(p, dt)
			continue
		if p.act != Act.WALK:
			_station(p, dt)
			continue
		if p.pause > 0.0:
			p.pause -= dt
			p.phase = 0.0
			if p.pause <= 0.0:
				p.gawk = false
				p.film = false
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
		if not blockers.is_empty() and _blocked(p):
			continue
		var pace: float = p.speed * (1.0 + 0.2 * rain)
		p.t += pace * dt
		p.phase = fmod(p.phase + pace * dt * 4.2, TAU)
		if p.spot != null and p.spot_t >= 0.0 and p.t >= p.spot_t:
			_arrive(p)
			_station(p, 0.0)
			continue
		if p.t >= p.length:
			var came: int = p.a
			_leave_crossing(p)
			p.a = p.b
			if not _choose_next(p, came):
				remove(p)
				continue
			# Window shopping, a call, a dog sniffing a lamp post.
			if p.arm < 0 and p.spot == null and rng.randf() < (0.15 if p.dog else 0.06):
				p.pause = rng.randf_range(2.0, 7.0)
				p.film = not p.dog and rng.randf() < 0.4
		_place(p)


func _blocked(p: Ped) -> bool:
	for b in blockers:
		var to := b - p.pos
		to.y = 0.0
		var ahead := to.dot(p.fwd)
		if ahead <= 0.0 or ahead > 1.1:
			continue
		var right := Vector3(-p.fwd.z, 0, p.fwd.x)
		var lat := to.dot(right)
		if absf(lat) > 0.75:
			continue
		# Stop, then sidestep away from whoever is in the way.
		p.pause = 0.35
		p.phase = 0.0
		p.side = clampf(p.side + (-0.6 if lat > 0.0 else 0.6), -0.9, 0.9)
		_place(p)
		return true
	return false


func _run(p: Ped, dt: float) -> void:
	p.flee -= dt
	if p.arm >= 0 and not p.crossing:
		_enter_crossing(p)  # no waiting for the light when running
	p.t += RUN * dt
	p.phase = fmod(p.phase + RUN * dt * 3.2, TAU)
	if p.t >= p.length:
		var came: int = p.a
		_leave_crossing(p)
		p.a = p.b
		if not _choose_flee(p, came):
			remove(p)
			return
	_place(p)


func _place(p: Ped) -> void:
	p.pos = _path_pos(p)
	p.fwd = _dir


var _dir := Vector3.FORWARD


## Where on the walking line someone at t on their edge stands (sets _dir to the heading).
## On a sidewalk strip with a bench, bus shelter or group of people, walkers step toward
## the kerb to pass it.
func _path_pos(p: Ped) -> Vector3:
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
	elif p.a / 4 == p.b / 4:
		var cell: int = p.a / 4
		var ka: int = p.a % 4
		var kb: int = p.b % 4
		var side := ka if kb == (ka + 1) % 4 else kb
		var key := cell * 4 + side
		var lim := 9.0
		var u := 0.0
		if (spots != null and spots.by_strip.has(key)) or _groups.has(key):
			u = p.t - p.length * 0.5 if side == ka else p.length * 0.5 - p.t
			if spots != null and spots.by_strip.has(key):
				var w := spots.swerve_window(spots.by_strip[key])
				lim = minf(lim, _swerve(u, w.x, w.y))
			for g in _groups.get(key, []):
				lim = minf(lim, _swerve(u, g[1] - 1.0, g[1] + 1.0))
		if lim < 9.0:
			var out: Vector3 = RoadNet.DV[side]
			var o := (pos - net.center(cell)).dot(out)
			if o > lim:
				pos -= out * (o - lim)
	_dir = dir
	return pos


## Outward limit at u for an obstacle spanning u0..u1, easing in and out over a metre.
static func _swerve(u: float, u0: float, u1: float) -> float:
	var w := 0.0
	if u > u0 - 1.2 and u < u1 + 1.2:
		w = minf(smoothstep(u0 - 1.2, u0, u), 1.0 - smoothstep(u1, u1 + 1.2, u))
	if w <= 0.0:
		return 9.0
	return lerpf(RoadNet.WALK + 0.35, StreetSpots.SWERVE_OUT, w)


# ---------------------------------------------------------------- render ---

func render() -> void:
	if _buf.size() != max_peds * 16:
		_buf.resize(max_peds * 16)
	if _dog_buf.size() != max_dogs * 16:
		_dog_buf.resize(max_dogs * 16)
	if _brolly_buf.size() != max_peds * 16:
		_brolly_buf.resize(max_peds * 16)
	var n := 0
	var nd := 0
	var nu := 0
	for p in peds:
		if n >= max_peds:
			break
		var st := _stance(p)
		if p.dog and nd < max_dogs:
			_put_dog(p, nd, st.x > 0.0)
			nd += 1
		var back := -p.fwd * p.size
		var right := Vector3(back.z, 0, -back.x)
		if st.y == Pose.UMBRELLA:
			var ou := nu * 16
			var up := p.pos
			if p.hero != null:
				# Hang the canopy from the rigged model's raised fist.
				var hand := p.pos + right * UmbrellaMesh.HAND.x + Vector3(0, p.size * UmbrellaMesh.HAND.y, 0) + back * UmbrellaMesh.HAND.z
				var grip: Vector3 = p.hero.umbrella_grip()
				if grip.distance_to(hand) < 0.8:
					up += grip - hand
			_brolly_buf[ou] = right.x; _brolly_buf[ou + 1] = 0.0; _brolly_buf[ou + 2] = back.x; _brolly_buf[ou + 3] = up.x
			_brolly_buf[ou + 4] = 0.0; _brolly_buf[ou + 5] = p.size; _brolly_buf[ou + 6] = 0.0; _brolly_buf[ou + 7] = up.y
			_brolly_buf[ou + 8] = right.z; _brolly_buf[ou + 9] = 0.0; _brolly_buf[ou + 10] = back.z; _brolly_buf[ou + 11] = up.z
			_brolly_buf[ou + 12] = float(p.outfit % 6)
			_brolly_buf[ou + 13] = p.phase
			_brolly_buf[ou + 14] = st.x
			_brolly_buf[ou + 15] = 0.0
			nu += 1
		if p.hero != null:
			continue
		var o := n * 16
		_buf[o] = right.x; _buf[o + 1] = 0.0; _buf[o + 2] = back.x; _buf[o + 3] = p.pos.x
		_buf[o + 4] = 0.0; _buf[o + 5] = p.size; _buf[o + 6] = 0.0; _buf[o + 7] = p.pos.y
		_buf[o + 8] = right.z; _buf[o + 9] = 0.0; _buf[o + 10] = back.z; _buf[o + 11] = p.pos.z
		_buf[o + 12] = p.phase
		_buf[o + 13] = st.x + 4.0 * st.y
		_buf[o + 14] = float(p.look)
		_buf[o + 15] = float(p.look2)
		n += 1
	_mmi.multimesh.buffer = _buf
	_mmi.multimesh.visible_instance_count = n
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_dog_mmi.multimesh.buffer = _dog_buf
	_dog_mmi.multimesh.visible_instance_count = nd
	_dog_mmi.cast_shadow = _mmi.cast_shadow
	_brolly_mmi.multimesh.buffer = _brolly_buf
	_brolly_mmi.multimesh.visible_instance_count = nu
	_brolly_mmi.cast_shadow = _mmi.cast_shadow


func umbrella_count() -> int:
	var n := 0
	for p in peds:
		if _stance(p).y == Pose.UMBRELLA:
			n += 1
	return n


## (stride, pose) for the shader: how fast the legs go and what the arms do.
func _stance(p: Ped) -> Vector2:
	if p.flee > 0.0:
		return Vector2(1.5, Pose.NONE)
	if p.act != Act.WALK:
		if p.act == Act.BOARD or p.go < 1.0:
			return Vector2(1.0, Pose.NONE)
		if p.act == Act.SIT or p.act == Act.WAIT and p.spot != null and p.spot.is_seat(p.slot):
			return Vector2(0.0, Pose.SIT)
		if p.umbrella and not _sheltered(p):
			return Vector2(0.0, Pose.UMBRELLA)
		if p.act == Act.CHAT:
			return Vector2(0.0, Pose.CHAT)
		return Vector2(0.0, Pose.PHONE if p.phone else Pose.NONE)
	var moving := p.pause <= 0.0 and (p.arm < 0 or p.crossing)
	var pose := Pose.NONE
	if p.umbrella:
		pose = Pose.UMBRELLA
	elif p.dog:
		pose = Pose.LEAD
	elif p.film or p.phone:
		pose = Pose.PHONE
	return Vector2(1.0 if moving else 0.0, pose)


## Standing in the bus shelter: no umbrella needed.
func _sheltered(p: Ped) -> bool:
	return p.spot != null and p.spot.kind == StreetSpots.Kind.STOP and p.spot.is_seat(p.slot)


func _put_dog(p: Ped, k: int, moving: bool) -> void:
	var right := Vector3(-p.fwd.z, 0, p.fwd.x)
	var pos := p.pos + right * 0.35 + p.fwd * (1.05 if moving else 0.45)
	pos.y = p.pos.y if p.act == Act.WALK else 0.17
	var back := -p.fwd
	var r := Vector3(back.z, 0, -back.x)
	var o := k * 16
	_dog_buf[o] = r.x; _dog_buf[o + 1] = 0.0; _dog_buf[o + 2] = back.x; _dog_buf[o + 3] = pos.x
	_dog_buf[o + 4] = 0.0; _dog_buf[o + 5] = 1.0; _dog_buf[o + 6] = 0.0; _dog_buf[o + 7] = pos.y
	_dog_buf[o + 8] = r.z; _dog_buf[o + 9] = 0.0; _dog_buf[o + 10] = back.z; _dog_buf[o + 11] = pos.z
	_dog_buf[o + 12] = p.phase * 1.6
	_dog_buf[o + 13] = (1.6 if p.flee > 0.0 else 1.0) if moving else 0.0
	_dog_buf[o + 14] = float(p.coat)
	_dog_buf[o + 15] = 0.0


# ---------------------------------------------------------------- close-up ---
# The people nearest the camera swap to the full rigged CharacterModel (about 7.7k
# triangles, 17 bones). A small pool is reused; everyone else stays a MultiMesh instance.

const HERO_MAX := 24
var hero_max := HERO_MAX  # main lowers it on Low and Med graphics: each costs script time
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
			if _hero_count >= hero_max:
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
		if p.flee > 0.0:
			m.set_sitting(false)
			m.set_activity("")
			m.animate(dt, RUN, true, 0.0, 0.0)
			continue
		var st := _stance(p)
		m.set_sitting(st.y == Pose.SIT)
		m.set_activity(_hero_activity(p, int(st.y)))
		var moving := st.x > 0.0
		m.animate(dt, CharacterModel.WALK_SPEED if moving else 0.0, true, 0.0, 0.0)
		if moving:
			# The walk clip is authored at 3.6 m/s; play it slower to match a stroll.
			m.tree.set("parameters/pace/scale", clampf(p.speed / CharacterModel.WALK_SPEED * 1.7, 0.5, 1.0))


## What a close-up person's rigged model is doing, from the crowd's pose.
func _hero_activity(p: Ped, pose: int) -> String:
	match pose:
		Pose.SIT: return "bench"
		Pose.PHONE: return "phone"
		Pose.CHAT: return "talk"
		Pose.UMBRELLA: return "umbrella"
	return "look" if p.gawk else ""


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
	m.set_sitting(false)
	m.set_activity("")
	m.tree.active = false
	_pool.append(m)
	p.hero = null
	_hero_count -= 1


func hero_count() -> int:
	return _hero_count
