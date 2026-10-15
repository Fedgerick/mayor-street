class_name BenchBus
extends Node
## The hidden bus job (msp). Sit on a park bench for a while and, now and then, a bus
## pulls up beside you and takes you on board. You ride (you don't drive) to a stop marked
## on the minimap; stay on all the way and the stranger on the back seat pays you. Press E
## to get off early and the job is lost. Nothing in the game mentions it beforehand.
##
## Uses player/ StreetSeating: sat_down(seat) with seat.park, ride(bus, local_seat) and
## end_ride(at). The bus is scripted like the tow trucks (vehicles/ TowService): a kit
## mesh and a traffic-layer body driven along road cell centres.
##
## Wiring (scripts/main.gd, after missions):
##   bench_bus = BenchBus.new(); add_child(bench_bus); bench_bus.setup(city, street, missions)

signal started
signal passed(pay: int)
signal failed(reason: String)

const MODEL := "car_bus"
const SIT_WAIT := 4.0           # seconds on a park bench before a bus may come
const CHANCE := 0.6             # ... and the chance it does
const COOLDOWN := 180.0         # seconds after a bus (or a miss) before the next roll
const SPAWN_CELLS := Vector2i(5, 9)    # road cells between where the bus appears and the bench
const TRIP_CELLS := Vector2i(22, 40)   # road cells from the bench to the marked stop
const KERB := 3.4               # how far the bus pulls over toward the bench
const CRUISE := 11.0
const ACCEL := 3.0
const BRAKE := 5.0
const TURN_RATE := 1.1
const BOARD_TIME := 1.6         # doors open, you climb on
const DROP_TIME := 1.4
const SEAT := Vector3(0.72, 0.81, -1.2)   # passenger cushion in bus space (-Z forward)
const DOOR := Vector3(2.1, 0.0, -4.4)     # where you step off: kerb side, by the front door
const GIVE_UP := 90.0           # a bus that hasn't arrived by now leaves

enum { IDLE, WAIT, COMING, BOARD, RIDE, DROP, LEAVE }

var city: City
var street: StreetMode
var missions: Node
var state := IDLE
var force := false              # tests: the next park bench always gets a bus
var rides := 0                  # finished rides (for tests)
var rng := RandomNumberGenerator.new()

var _t := 0.0
var _cool := 20.0
var _seat := {}
var _node: Node3D
var _mm: MultiMesh
var _body: AnimatableBody3D
var _pos := Vector3.ZERO        # flat map
var _yaw := 0.0
var _speed := 0.0
var _wheel := 0.0
var _steer := 0.0
var _path: Array[Vector3] = []
var _i := 0
var _goal := Vector3.INF        # the marked stop (flat)
var _trip_m := 0.0
var _beacon: MeshInstance3D
var _hooked := false


func setup(c: City, s: StreetMode, m: Node) -> void:
	city = c
	street = s
	missions = m
	rng.randomize()
	_beacon = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.2
	cyl.bottom_radius = 2.0
	cyl.height = 36.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	_beacon.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.75, 1.0, 0.32)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beacon.material_override = mat
	_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beacon.visible = false
	add_child(_beacon)
	_hook()


func _hook() -> void:
	if _hooked or street == null or street.seating == null:
		return
	street.seating.sat_down.connect(_on_sat)
	street.seating.stood_up.connect(_on_stood)
	_hooked = true


func busy() -> bool:
	return state != IDLE


func _on_sat(seat: Dictionary) -> void:
	if state != IDLE or not seat.get("park", false) or not seat.has("flat"):
		return
	_seat = seat
	_t = 0.0
	state = WAIT


func _on_stood(_s: Dictionary) -> void:
	if state == WAIT:
		state = IDLE
	elif state == COMING:
		# Walked off before it got here: it drives on by.
		state = LEAVE
		_leave_route()


func _can_start() -> bool:
	if not street.active or street.down or street.wanted > 0 or street.car != null:
		return false
	var dir = missions.get("director") if missions else null
	if dir != null and dir.active != null:
		return false
	return street.seating.seated and street.seating.riding == null


# ------------------------------------------------------------------- the job ---

func _physics_process(dt: float) -> void:
	_hook()
	_cool -= dt
	match state:
		WAIT:
			if not street.seating.seated:
				state = IDLE
				return
			_t += dt
			if _t >= SIT_WAIT and _cool <= 0.0:
				_cool = COOLDOWN
				if (force or rng.randf() < CHANCE) and _can_start():
					force = false
					if not _send():
						state = IDLE
				else:
					state = IDLE
		COMING:
			_t += dt
			if _t > GIVE_UP:
				state = LEAVE
				_leave_route()
				return
			var last := _i >= _path.size() - 1
			if _steer_to(dt, _path[_i], CRUISE, last):
				if last:
					_t = 0.0
					state = BOARD
					_hud("The bus stops right in front of you. The doors hiss open.")
				else:
					_i += 1
		BOARD:
			_t += dt
			if _t >= BOARD_TIME:
				if not street.seating.seated or not _can_start():
					state = LEAVE
					_leave_route()
					return
				_board()
		RIDE:
			if street.seating.riding != _node or street.down:
				_fail("You came off the bus.")
				return
			var last := _i >= _path.size() - 1
			if _steer_to(dt, _path[_i], CRUISE, last):
				if last:
					_t = 0.0
					state = DROP
				else:
					_i += 1
		DROP:
			_t += dt
			if _t >= DROP_TIME:
				_arrive()
		LEAVE:
			if _i < _path.size():
				if _steer_to(dt, _path[_i], CRUISE, false):
					_i += 1
			else:
				_steer_to(dt, _pos + Vector3(-sin(_yaw), 0, -cos(_yaw)) * 20.0, CRUISE, false)
			_t += dt
			if _node and (Planet.fdist(_pos, Planet.flat(street.player_position())) > 140.0 or _t > 40.0):
				_despawn()
				state = IDLE
	if _node:
		_show(dt)


func _send() -> bool:
	var at: Vector3 = _seat.flat
	var bench_cell := _road_cell_near(at)
	if bench_cell.x < 0:
		return false
	var seen := _bfs(bench_cell, SPAWN_CELLS.y + 2)
	var p := Planet.flat(street.player_position())
	var spawn := Vector2i(-1, -1)
	var far := -1.0
	for c in seen:
		var depth: int = seen[c][0]
		if depth < SPAWN_CELLS.x or depth > SPAWN_CELLS.y:
			continue
		var d := Planet.fdist(city.cell_center(c.x, c.y), p)
		if d > far:
			far = d
			spawn = c
	if spawn.x < 0:
		return false
	_path = _route(seen, spawn)
	if _path.size() < 2:
		return false
	# Pull over to the kerb by the bench.
	var last := _path[_path.size() - 1]
	var dir := (last - _path[_path.size() - 2]).normalized()
	var perp := Vector3(-dir.z, 0, dir.x)
	var side := signf((at - last).dot(perp))
	_path[_path.size() - 1] = last + perp * side * KERB - dir * 2.0
	var d0 := _path[1] - _path[0]
	_yaw = atan2(-d0.x, -d0.z)
	_build(_path[0])
	_i = 1
	_t = 0.0
	_speed = CRUISE * 0.7
	state = COMING
	return true


func _board() -> void:
	# Somewhere TRIP_CELLS down the road network, marked on the minimap.
	var from := _road_cell_near(_pos)
	var seen := _bfs(from, TRIP_CELLS.y)
	var picks: Array[Vector2i] = []
	for c in seen:
		if seen[c][0] >= TRIP_CELLS.x:
			picks.append(c)
	if picks.is_empty():
		for c in seen:
			if seen[c][0] >= 6:
				picks.append(c)
	if picks.is_empty():
		state = LEAVE
		_leave_route()
		return
	var goal: Vector2i = picks[rng.randi() % picks.size()]
	var back := _bfs(goal, TRIP_CELLS.y + 4)
	if not back.has(from):
		state = LEAVE
		_leave_route()
		return
	_path = _route(back, from)
	_path[0] = _pos
	_goal = _path[_path.size() - 1]
	_trip_m = 0.0
	for k in range(1, _path.size()):
		_trip_m += Planet.fdist(_path[k - 1], _path[k])
	_i = 1
	if not street.seating.ride(_node, Transform3D(Basis.IDENTITY, SEAT)):
		state = LEAVE
		_leave_route()
		return
	state = RIDE
	_mark(true)
	started.emit()
	_hud("A stranger on the back seat: \"Don't get off till I say. There's money in it.\"")


func _arrive() -> void:
	var xf := _node.global_transform
	street.seating.end_ride(xf * DOOR)
	_mark(false)
	var pay := int(round((300.0 + _trip_m * 0.6) / 10.0)) * 10
	var prog := get_node_or_null("/root/Progress")
	if prog:
		prog.add_cash(pay, "Bus ride")
		var n: int = prog.count("bench_bus")
		if n == 1:
			prog.set_flag("found:bench_bus")
	rides += 1
	street.hud.banner("HIDDEN JOB: THE LAST STOP", Color(0.35, 0.8, 1.0))
	_hud("The stranger presses an envelope into your hand and stays on. +$%d" % pay)
	passed.emit(pay)
	state = LEAVE
	_t = 0.0
	_leave_route()
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if street and not street.down:
			street.hud.clear_banner())


func _fail(reason: String) -> void:
	_mark(false)
	_hud(reason + " The bus pulls away without you.")
	failed.emit(reason)
	state = LEAVE
	_t = 0.0
	_leave_route()


func _unhandled_input(e: InputEvent) -> void:
	# On board, E gets you off at the next moment: the job is lost.
	if state == RIDE and street.seating.riding == _node and e.is_action_pressed("street_interact"):
		get_viewport().set_input_as_handled()
		_speed = 0.0
		street.seating.end_ride(_node.global_transform * DOOR)
		_fail("You got off.")


func _leave_route() -> void:
	## Drive on from wherever the bus is, out of sight.
	if _node == null:
		state = IDLE
		return
	var from := _road_cell_near(_pos)
	var seen := _bfs(from, 14)
	var far := Vector2i(-1, -1)
	var best := -1
	for c in seen:
		var d := Planet.fdist(city.cell_center(c.x, c.y), Planet.flat(street.player_position()))
		if seen[c][0] >= 8 and d > best:
			best = int(d)
			far = c
	if far.x < 0:
		_path = []
	else:
		var back := _bfs(far, 16)
		_path = _route(back, from) if back.has(from) else []
	_i = 1 if _path.size() > 1 else _path.size()
	_t = 0.0


func _mark(on: bool) -> void:
	var nav = get_tree().get_first_node_in_group("city_nav")
	if on:
		_beacon.visible = true
		var w := Planet.place(_goal)
		_beacon.global_transform = Transform3D(Planet.basis(w), w + Planet.up(w) * 18.0)
		if nav:
			nav.mark("bus:stop", _goal, {"color": Color(0.3, 0.75, 1.0), "kind": "job", "priority": 11, "label": "Last stop"})
	else:
		_beacon.visible = false
		if nav:
			nav.unmark("bus:stop")
		_goal = Vector3.INF


func _hud(text: String) -> void:
	var h = missions.get("hud") if missions else null
	if h and h.has_method("news"):
		h.news(text, 5.0)
	else:
		street.hud.note(text)


# ------------------------------------------------------------------- the bus ---

func _build(pos: Vector3) -> void:
	_despawn()
	_node = Node3D.new()
	_node.name = "BenchBus"
	add_child(_node)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = VehicleKit.mesh(MODEL, 0)
	_mm.instance_count = 1
	_mm.set_instance_color(0, Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	_node.add_child(mmi)
	_body = AnimatableBody3D.new()
	_body.collision_layer = 16     # StreetBodies.TRAFFIC_LAYER
	_body.collision_mask = 0
	_body.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.55, 3.3, 11.5)
	cs.shape = box
	cs.position = Vector3(0, 1.65, 0)
	_body.add_child(cs)
	_node.add_child(_body)
	_pos = pos
	_node.global_transform = _xf()


func _despawn() -> void:
	if _node and is_instance_valid(_node):
		if street and street.seating and street.seating.riding == _node:
			street.seating.end_ride(_node.global_transform * DOOR)
		_node.queue_free()
	_node = null
	_mm = null
	_body = null


func _xf() -> Transform3D:
	return Planet.xf_rigid(Transform3D(Basis(Vector3.UP, _yaw), _pos))


func _show(dt: float) -> void:
	_wheel += _speed * dt / 0.5
	var stopped := _speed < 0.3
	_mm.set_instance_custom_data(0, VehicleKit.custom(true, stopped, false, false, _wheel, _steer, 0.3))


func _steer_to(dt: float, target: Vector3, speed_cap: float, stop_at_end: bool) -> bool:
	var to := target - _pos
	to.x = Planet.fdx(_pos.x, target.x)
	to.y = 0.0
	var d := to.length()
	if stop_at_end and d < 0.6:
		_speed = 0.0
		return true
	var want := atan2(-to.x, -to.z) if d > 0.05 else _yaw
	var err := wrapf(want - _yaw, -PI, PI)
	var turn := TURN_RATE * clampf(_speed / 3.0, 0.35, 1.0) * dt
	_yaw += clampf(err, -turn, turn)
	_steer = lerpf(_steer, clampf(err * 0.8, -0.5, 0.5), 1.0 - exp(-8.0 * dt))
	var v := speed_cap if absf(err) < 0.4 else minf(speed_cap, 4.0)
	if stop_at_end:
		v = minf(v, sqrt(2.0 * 2.5 * maxf(d - 0.3, 0.0)) + 0.4)
	_speed = move_toward(_speed, v, (ACCEL if v > _speed else BRAKE) * dt)
	_pos += Vector3(-sin(_yaw), 0, -cos(_yaw)) * minf(_speed * dt, d)
	_node.global_transform = _xf()
	_body.global_transform = _node.global_transform
	return d < (0.6 if stop_at_end else 7.0)


# ------------------------------------------------------------------- routing ---

func _road_cell_near(pos: Vector3) -> Vector2i:
	var o := city.flat_to_cell(pos)
	var best := Vector2i(-1, -1)
	var best_d := INF
	for r in 4:
		for y in range(o.y - r, o.y + r + 1):
			for x in range(o.x - r, o.x + r + 1):
				var c := Vector2i(posmod(x, City.W), y)
				if maxi(absi(x - o.x), absi(y - o.y)) != r or not city.is_road(c.x, c.y):
					continue
				var d := Planet.fdist(city.cell_center(c.x, c.y), pos)
				if d < best_d:
					best_d = d
					best = c
		if best.x >= 0 and best_d < City.TILE * (r + 0.5):
			break
	return best


func _bfs(root: Vector2i, max_depth: int) -> Dictionary:
	var seen := {root: [0, root]}
	var queue: Array[Vector2i] = [root]
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var depth: int = seen[c][0]
		if depth >= max_depth:
			continue
		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + step
			n.x = posmod(n.x, City.W)
			if not seen.has(n) and city.is_road(n.x, n.y):
				seen[n] = [depth + 1, c]
				queue.append(n)
	return seen


func _route(seen: Dictionary, from_cell: Vector2i) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var c := from_cell
	while true:
		out.append(city.cell_center(c.x, c.y))
		var nxt: Vector2i = seen[c][1]
		if nxt == c:
			break
		c = nxt
	return out
