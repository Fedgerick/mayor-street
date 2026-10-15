class_name TowService
extends Node
## Flatbed tow trucks that come and take away stuck or broken cars.
##
## Every second it looks at the physics cars (group "vehicles") near the player. A car that
## nobody is driving and that has been burnt out for 8 s, upside down for 6 s or smashed
## and abandoned for 20 s gets a truck: it appears on a road about 70 m away, drives there
## along the city's roads with its amber beacon flashing, stops beside the car, winches it
## up on to the deck, and drives away. Once it is far off (or has driven a minute) truck and
## car are removed, so a wreck never sits in the street for ever.
##
## The truck is not a physics body: one MultiMesh instance drawn with the car kit's
## `car_tow` model, plus a kinematic box on the traffic layer so the player and their car
## can't drive through it. The car it carries is frozen (kinematic) and moved with the deck.
##
## Wiring (scripts/main.gd, after `street` and `life` exist):
##   tow = TowService.new(); tow.setup(city, street); add_child(tow)
## `street` needs `car` (the car being driven), `active` and `focus_point()`: StreetMode has all three.
##
## With `yards` set (SalvageYards, msp) the trucks belong to salvage yards: no yard, no
## trucks; each yard's two trucks can be out at once; a truck leaves from its yard's kerb
## when the yard is near, and brings the wreck back there, which pays the city a fee.

signal towed(model: String)
signal delivered(model: String, yard_id: int)   # a wreck brought back to a salvage yard

const MODEL := "car_tow"
const RANGE := 150.0          # cars further than this from the player are left alone
const SCAN := 1.0             # seconds between looks
const FLIPPED_WAIT := 6.0     # upside down or on its side this long
const BURNT_WAIT := 8.0       # burnt out, after the explosion has played
const SMASHED_WAIT := 20.0    # smashed and left
const COOLDOWN := 8.0         # between one truck leaving and the next being sent
const MAX_REACH := 20.0       # a car further than this from any road isn't fetched
const MAX_LEN := 5.8          # longer than the deck: buses and trucks are left
const CRUISE := 13.0
const ACCEL := 4.0
const BRAKE := 7.0
const TURN_RATE := 1.4        # rad/s at speed
const BED := Vector3(0, 1.2, 1.575)     # deck centre in truck space (the truck faces -Z)
const GONE := 160.0           # removed once this far from the player, driving away
const MAX_DRIVE_OUT := 70.0   # ... or after this many seconds
const SPAWN_CELLS := Vector2i(6, 10)    # road cells between where a truck appears and the car
const YARD_REACH := 60          # road cells: a yard this near sends its truck from its gate
const YARD_FEE := 120           # city funds a salvage yard makes on each wreck brought in

enum { DRIVE_IN, LOAD, DRIVE_OUT }

class Truck:
	extends RefCounted
	var node: Node3D
	var pos := Vector3.ZERO       # flat map metres (the same as the world on ms)
	var mm: MultiMesh
	var body: AnimatableBody3D
	var car: DrivableCar
	var path: Array[Vector3] = []
	var i := 0
	var state := DRIVE_IN
	var speed := 0.0
	var yaw := 0.0
	var wheel := 0.0
	var steer := 0.0
	var t := 0.0
	var lift_time := 2.0
	var from := Transform3D.IDENTITY
	var cell := Vector2i.ZERO
	var lod := 0
	var seed := 0.0
	var layers := Vector2i.ZERO   # the car's own collision layer and mask, restored if it is let go
	var yard := -1                # the salvage yard it belongs to (-1: none)
	var going_home := false       # DRIVE_OUT is a route to the yard's gate

var city: City
var street: Node
var trucks: Array[Truck] = []
var towed_count := 0          # cars taken away (for tests)
var sent := 0                 # trucks sent out (for tests)
var enabled := true
var yards: SalvageYards = null  # msp: trucks belong to salvage yards (none: one truck, no yard needed)
var delivered_count := 0      # wrecks brought back to a yard (for tests)
var rng := RandomNumberGenerator.new()

var _dwell := {}              # car instance id -> seconds it has been stuck
var _given_up := {}           # car instance id -> true: no road near it
var _scan := 0.0
var _cooldown := 3.0
var _lod_timer := 0.0


func setup(c: City, street_mode: Node) -> void:
	city = c
	street = street_mode
	rng.randomize()


## Send a truck for this car now (tests, missions). False when it can't be fetched.
func request(car: DrivableCar) -> bool:
	return _dispatch(car)


func busy() -> bool:
	return not trucks.is_empty()


## How many trucks may be out at once.
func capacity() -> int:
	if yards == null:
		return 1
	return yards.free_trucks() + yards.out_trucks()


func _can_send() -> bool:
	return trucks.size() < capacity() and (yards == null or yards.free_trucks() > 0)


func _physics_process(dt: float) -> void:
	if city == null or street == null:
		return
	_cooldown = maxf(0.0, _cooldown - dt)
	if enabled and _can_send() and _cooldown <= 0.0:
		_scan -= dt
		if _scan <= 0.0:
			_scan = SCAN
			_look()
	_lod_timer -= dt
	for tr in trucks.duplicate():
		match tr.state:
			DRIVE_IN:
				_drive_in(tr, dt)
			LOAD:
				_load(tr, dt)
			DRIVE_OUT:
				_drive_out(tr, dt)
		if tr.node != null:
			_show(tr, dt)
	if _lod_timer <= 0.0:
		_lod_timer = 0.5


# ------------------------------------------------------------------ choosing ---

func _player() -> Vector3:
	return street.focus_point() if street.has_method("focus_point") else Vector3.ZERO


func _wait_for(c: DrivableCar) -> float:
	## Seconds a car must have been stuck before it is fetched, or -1 when it's fine.
	if c.burning:
		return -1.0
	if c.wrecked or c.damage_stage >= 3:
		return BURNT_WAIT
	if c.global_basis.y.dot(Planet.up(c.global_position)) < 0.35:
		return FLIPPED_WAIT
	if c.damage_stage >= 2:
		return SMASHED_WAIT
	return -1.0


func _look() -> void:
	if not street.get("active"):
		return
	var p := _player()
	var seen := {}
	var best: DrivableCar = null
	var best_d := INF
	for v in get_tree().get_nodes_in_group("vehicles"):
		var c := v as DrivableCar
		if c == null or not c.is_inside_tree() or c.driver != null or c == street.get("car"):
			continue
		if c.get_meta("towing", false):
			continue
		var id := c.get_instance_id()
		if _given_up.has(id):
			continue
		var d := c.global_position.distance_to(p)
		var need := _wait_for(c)
		if need < 0.0 or d > RANGE or c.linear_velocity.length() > 1.5:
			continue
		seen[id] = _dwell.get(id, 0.0) + SCAN
		if seen[id] >= need and d < best_d and float(VehicleKit.spec(c.model).get("length", 4.5)) <= MAX_LEN:
			best = c
			best_d = d
	_dwell = seen
	if best != null:
		_dispatch(best)


# ------------------------------------------------------------------ routing ---

func _road_cell_near(pos: Vector3) -> Vector2i:
	## The road cell whose centre is closest to a flat map point, searching a few cells out.
	var o := city.flat_to_cell(pos)
	var best := Vector2i(-1, -1)
	var best_d := INF
	for r in 4:
		for y in range(o.y - r, o.y + r + 1):
			for x in range(o.x - r, o.x + r + 1):
				if maxi(absi(x - o.x), absi(y - o.y)) != r or not city.is_road(x, y):
					continue
				var d := Planet.fdist(city.cell_center(x, y), pos)
				if d < best_d:
					best_d = d
					best = Vector2i(x, y)
		if best.x >= 0 and best_d < City.TILE * (r + 0.5):
			break
	return best


func _bfs(root: Vector2i, max_depth: int) -> Dictionary:
	## Road cells reachable from root: cell -> [depth, next cell toward root].
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
			if not seen.has(n) and city.is_road(n.x, n.y):
				seen[n] = [depth + 1, c]
				queue.append(n)
	return seen


func _route(seen: Dictionary, from_cell: Vector2i) -> Array[Vector3]:
	## Cell centres from `from_cell` back to the BFS root.
	var out: Array[Vector3] = []
	var c := from_cell
	while true:
		out.append(city.cell_center(c.x, c.y))
		var nxt: Vector2i = seen[c][1]
		if nxt == c:
			break
		c = nxt
	return out


func _dispatch(car: DrivableCar) -> bool:
	if city == null or not _can_send() or car == null or not is_instance_valid(car):
		return false
	var id := car.get_instance_id()
	var at := Planet.flat(car.global_position)
	var tcell := _road_cell_near(at)
	if tcell.x < 0 or Planet.fdist(city.cell_center(tcell.x, tcell.y), at) > MAX_REACH:
		_given_up[id] = true
		return false
	var yard := -1
	var spawn := Vector2i(-1, -1)
	var seen := {}
	if yards != null:
		yard = yards.nearest_free(at)
		if yard < 0:
			return false
		var gate := yards.gate_cell(yard)
		if gate.x >= 0:
			seen = _bfs(tcell, YARD_REACH)
			if seen.has(gate):
				spawn = gate   # near enough: the truck pulls out of its yard
	if spawn.x < 0:
		seen = _bfs(tcell, SPAWN_CELLS.y + 2)
	var p := Planet.flat(_player())
	var far := -1.0
	for c in (seen if spawn.x < 0 else {}):
		var depth: int = seen[c][0]
		if depth < SPAWN_CELLS.x or depth > SPAWN_CELLS.y:
			continue
		var d := Planet.fdist(city.cell_center(c.x, c.y), p)
		if d > far:
			far = d
			spawn = c
	if spawn.x < 0:      # a short dead end: use the furthest cell there is
		for c in seen:
			if seen[c][0] >= 2 and (spawn.x < 0 or seen[c][0] > seen[spawn][0]):
				spawn = c
	if spawn.x < 0:
		_given_up[id] = true
		return false
	var path := _route(seen, spawn)
	# Stop beside the car: slide the last waypoint across the road toward it.
	if path.size() >= 2:
		var last := path[path.size() - 1]
		var dir := (last - path[path.size() - 2]).normalized()
		var perp := Vector3(-dir.z, 0, dir.x)
		var off := clampf((at - last).dot(perp), -3.0, 3.0)
		path[path.size() - 1] = last + perp * off
	var tr := Truck.new()
	tr.path = path
	tr.i = 1
	tr.car = car
	tr.cell = tcell
	tr.seed = rng.randf()
	tr.yard = yard
	if yard >= 0:
		yards.take(yard)
	var d0 := path[1] - path[0]
	tr.yaw = atan2(-d0.x, -d0.z)
	_build(tr, path[0])
	trucks.append(tr)
	sent += 1
	car.set_meta("towing", true)
	return true


# ------------------------------------------------------------------ the truck ---

func _build(tr: Truck, pos: Vector3) -> void:
	var node := Node3D.new()
	node.name = "TowTruck"
	add_child(node)
	tr.mm = MultiMesh.new()
	tr.mm.transform_format = MultiMesh.TRANSFORM_3D
	tr.mm.use_colors = true
	tr.mm.use_custom_data = true
	tr.mm.mesh = VehicleKit.mesh(MODEL, 0)
	tr.mm.instance_count = 1
	tr.mm.set_instance_color(0, Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = tr.mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(mmi)
	var b := AnimatableBody3D.new()
	b.collision_layer = 16     # StreetBodies.TRAFFIC_LAYER: blocks the player and their car
	b.collision_mask = 0
	b.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 2.6, 8.4)
	cs.shape = box
	cs.position = Vector3(0, 1.3, 0.2)
	b.add_child(cs)
	node.add_child(b)
	tr.body = b
	tr.node = node
	tr.pos = pos
	node.global_transform = _xf(tr)
	_show(tr, 0.0)


func _xf(tr: Truck) -> Transform3D:
	## The truck's world transform (stood on the ball on msp; yaw is in the local frame).
	return Planet.xf_rigid(Transform3D(Basis(Vector3.UP, tr.yaw), tr.pos))


func _show(tr: Truck, dt: float) -> void:
	tr.wheel += tr.speed * dt / 0.5
	tr.node.global_transform = _xf(tr)
	var pos := tr.node.global_position
	tr.mm.set_instance_custom_data(0, VehicleKit.custom(true, tr.speed < 0.3 or tr.state == LOAD, false, false, tr.wheel, tr.steer, tr.seed))
	if _lod_timer <= 0.0:
		var lod := VehicleKit.lod_for(pos.distance_to(_player()))
		if lod != tr.lod:
			tr.lod = lod
			tr.mm.mesh = VehicleKit.mesh(MODEL, lod)
	if tr.car != null and is_instance_valid(tr.car) and tr.state == DRIVE_OUT and tr.car.get_meta("on_deck", false):
		tr.car.global_transform = _deck(tr)


func _deck(tr: Truck) -> Transform3D:
	## Where the carried car sits: on the deck, facing the way the truck does.
	var truck_xf := _xf(tr)
	var basis := truck_xf.basis * Basis(Vector3.UP, PI)
	return Transform3D(basis, truck_xf * (BED + Vector3(0, DrivableCar.SAG, 0)))


func _steer_to(tr: Truck, dt: float, target: Vector3, speed_cap: float, stop_at_end: bool) -> bool:
	## Pure pursuit toward `target`. True once there (when stopping) or within a car length.
	var pos := tr.pos
	var to := target - pos
	to.x = Planet.fdx(pos.x, target.x)
	to.y = 0.0
	var d := to.length()
	if stop_at_end and d < 0.6:
		tr.speed = 0.0
		return true
	var want := atan2(-to.x, -to.z) if d > 0.05 else tr.yaw
	var err := wrapf(want - tr.yaw, -PI, PI)
	var turn := TURN_RATE * clampf(tr.speed / 3.0, 0.35, 1.0) * dt
	tr.yaw += clampf(err, -turn, turn)
	tr.steer = lerpf(tr.steer, clampf(err * 0.8, -0.5, 0.5), 1.0 - exp(-8.0 * dt))
	var v := speed_cap if absf(err) < 0.5 else minf(speed_cap, 4.5)
	if stop_at_end:
		v = minf(v, sqrt(2.0 * 3.0 * maxf(d - 0.3, 0.0)) + 0.4)
	tr.speed = move_toward(tr.speed, v, (ACCEL if v > tr.speed else BRAKE) * dt)
	var f := Vector3(-sin(tr.yaw), 0, -cos(tr.yaw))
	var step := minf(tr.speed * dt, d)
	pos += f * step
	tr.pos = pos
	tr.node.global_transform = _xf(tr)
	if tr.body != null:
		tr.body.global_transform = tr.node.global_transform
	return d < (0.6 if stop_at_end else 6.0)


func _car_ok(tr: Truck) -> bool:
	var c := tr.car
	return c != null and is_instance_valid(c) and c.driver == null and c != street.get("car") and _wait_for_ok(c)


func _wait_for_ok(c: DrivableCar) -> bool:
	return c.wrecked or c.damage_stage >= 2 or c.global_basis.y.dot(Planet.up(c.global_position)) < 0.5 or c.get_meta("on_deck", false)


func _drive_in(tr: Truck, dt: float) -> void:
	if not _car_ok(tr):
		_release(tr)
		_leave(tr)
		return
	var last := tr.i >= tr.path.size() - 1
	if _steer_to(tr, dt, tr.path[tr.i], CRUISE, last):
		if last:
			tr.state = LOAD
			tr.t = 0.0
			tr.speed = 0.0
			_grab(tr)
		else:
			tr.i += 1


func _grab(tr: Truck) -> void:
	var c := tr.car
	tr.layers = Vector2i(c.collision_layer, c.collision_mask)
	c.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	c.freeze = true
	c.collision_layer = 0
	c.collision_mask = 0
	c.linear_velocity = Vector3.ZERO
	c.angular_velocity = Vector3.ZERO
	tr.from = c.global_transform
	var d := tr.from.origin.distance_to(_deck(tr).origin)
	tr.lift_time = 1.8 + d * 0.12


func _load(tr: Truck, dt: float) -> void:
	var c := tr.car
	if c == null or not is_instance_valid(c) or c.driver != null or c == street.get("car"):
		_release(tr)
		_leave(tr)
		return
	tr.t += dt
	var pause := 1.0     # the driver gets out and hooks up
	if tr.t < pause:
		return
	var k := clampf((tr.t - pause) / tr.lift_time, 0.0, 1.0)
	var e := k * k * (3.0 - 2.0 * k)
	var to := _deck(tr)
	var q := tr.from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), e)
	var pos := tr.from.origin.lerp(to.origin, e) + Planet.up(to.origin) * sin(e * PI) * 0.9
	c.global_transform = Transform3D(Basis(q), pos)
	if k >= 1.0:
		c.set_meta("on_deck", true)
		_leave(tr)


func _release(tr: Truck) -> void:
	## Let the car go again (someone got in it, or it was freed).
	var c := tr.car
	if c != null and is_instance_valid(c):
		c.remove_meta("towing")
		c.remove_meta("on_deck")
		if c.freeze:
			c.freeze = false
			c.collision_layer = tr.layers.x if tr.layers.x != 0 else DrivableCar.LAYER
			c.collision_mask = tr.layers.y if tr.layers.y != 0 else (1 | DrivableCar.LAYER | 16)
	tr.car = null


func _leave(tr: Truck) -> void:
	## Pick a road away from here, preferring the way the truck already faces. A yard's
	## truck carrying a wreck heads back to its yard when the yard is in reach.
	tr.state = DRIVE_OUT
	tr.t = 0.0
	var here := city.flat_to_cell(tr.pos)
	var root := _road_cell_near(tr.pos) if not city.is_road(here.x, here.y) else here
	if root.x < 0:
		_finish(tr)
		return
	tr.going_home = false
	if tr.yard >= 0 and yards != null and city.buildings.has(tr.yard) and tr.car != null and is_instance_valid(tr.car):
		var gate := yards.gate_cell(tr.yard)
		if gate == root:
			_finish(tr, true)
			return
		var to_yard := _bfs(gate, YARD_REACH) if gate.x >= 0 else {}
		if to_yard.has(root):
			tr.path = _route(to_yard, root)   # root ... gate
			tr.i = 1 if tr.path.size() > 1 else 0
			tr.going_home = true
			return
	var seen := _bfs(root, 14)
	var f := Vector3(-sin(tr.yaw), 0, -cos(tr.yaw))
	var best := Vector2i(-1, -1)
	var best_score := -INF
	for c in seen:
		var depth: int = seen[c][0]
		if depth < 8:
			continue
		var score := float(depth) + rng.randf() * 3.0
		var route := _route(seen, c)       # c ... root
		if route.size() >= 2:
			var first := (route[route.size() - 2] - route[route.size() - 1]).normalized()
			score += 6.0 * f.dot(first)
		if score > best_score:
			best_score = score
			best = c
	if best.x < 0:
		for c in seen:
			if seen[c][0] > 0 and (best.x < 0 or seen[c][0] > seen[best][0]):
				best = c
	if best.x < 0:
		_finish(tr)
		return
	var route := _route(seen, best)
	route.reverse()                         # root ... best
	tr.path = route
	tr.i = 1 if route.size() > 1 else 0


func _drive_out(tr: Truck, dt: float) -> void:
	tr.t += dt
	if tr.car != null and (not is_instance_valid(tr.car)):
		tr.car = null
	if tr.i < tr.path.size():
		var last := tr.i >= tr.path.size() - 1
		if _steer_to(tr, dt, tr.path[tr.i], CRUISE, last and tr.going_home):
			if last and tr.going_home:
				_finish(tr, true)
				return
			elif last:
				_leave(tr)       # keep going somewhere else
			else:
				tr.i += 1
	else:
		_leave(tr)
	var far := tr.node.global_position.distance_to(_player())
	if far > GONE or tr.t > MAX_DRIVE_OUT and far > 70.0 or tr.t > MAX_DRIVE_OUT * 2.0:
		_finish(tr, tr.going_home)   # out of sight on its way home counts as home


func _finish(tr: Truck, at_yard := false) -> void:
	if tr.car != null and is_instance_valid(tr.car):
		if tr.car.get_meta("on_deck", false):
			var m := tr.car.model
			tr.car.queue_free()
			towed_count += 1
			towed.emit(m)
			if at_yard and tr.yard >= 0:
				delivered_count += 1
				var prog := get_node_or_null("/root/Progress")
				if prog and prog.has_method("add_city_funds"):
					prog.add_city_funds(YARD_FEE, "Salvage")
				delivered.emit(m, tr.yard)
		else:
			_release(tr)
	trucks.erase(tr)
	if tr.node != null:
		tr.node.queue_free()
	if tr.yard >= 0 and yards != null:
		yards.back(tr.yard)
	_cooldown = COOLDOWN
