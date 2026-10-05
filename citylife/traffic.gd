class_name Traffic
extends Node3D
## AI cars that drive the road grid: lane following with the Intelligent Driver Model,
## turns and U-turns, signalled junctions with box reservations, yielding to people on
## crosswalks. Drawn from the car kit (vehicles/) with a CarDrawer per model: three
## MultiMeshes by distance, rebuilt from flat buffers each frame, so a few hundred cars
## cost a few dozen draw calls.

const MODELS := ["car_sedan", "car_hatch", "car_van", "car_truck", "car_bus",
	"car_sports", "car_pickup", "car_taxi", "car_garbage"]
const LENGTHS := [4.5, 3.85, 4.9, 6.84, 11.5, 4.45, 5.5, 4.5, 8.0]   # VehicleKit.spec lengths
const WHEEL_R := [0.36, 0.36, 0.36, 0.48, 0.5, 0.36, 0.42, 0.36, 0.5]
const SEDAN := 0
const HATCH := 1
const VAN := 2
const TRUCK := 3
const BUS := 4
const SPORTS := 5
const PICKUP := 6
const TAXI := 7
const GARBAGE := 8
## What the player gets when taking a car, while the city kit lacks the newer models.
const OLD_NAME := {"car_sports": "car_sedan", "car_taxi": "car_sedan", "car_pickup": "car_van", "car_garbage": "car_truck", "car_bus": "car_truck"}
const ROAD_Y := 0.05

# Intelligent Driver Model.
const V_STRAIGHT := 12.5   # m/s, about 45 km/h
const V_TURN := 5.5
const V_UTURN := 3.5
const ACCEL := 2.2
const BRAKE := 3.5
const MIN_GAP := 1.8
const HEADWAY := 1.1
const LOOKAHEAD := 30.0

class Car:
	var id := 0
	var cell := 0
	var din := 0
	var dout := 0
	var nd := 0          # exit to take in the next cell
	var s := 0.0
	var v := 0.0
	var model := 0
	var tint := Color.WHITE
	var holds: Array[int] = []  # junction cells this car holds a reservation for
	var stuck := 0.0
	var aggr := 1.0      # per-driver multiplier on desired speed
	var pos := Vector3.ZERO
	var fwd := Vector3.FORWARD
	var pull := 0.0      # 0 in lane .. 1 pulled over to the kerb for a siren
	var garbage := false # a garbage truck: stops along the block to collect
	var halt := 0.0      # seconds left standing at a pickup
	var bus := false     # a city bus: stops at the bus stops it passes
	var served := -1     # cell of the last bus stop served
	var wheel := 0.0     # wheel roll angle, for the kit's wheel shader
	var steer := 0.0     # front wheel angle, + left
	var brake := false   # brake lights on
	var seed := 0.0      # which driver sits inside

signal car_taken(pos: Vector3, fwd: Vector3)  # a driver was pulled out at pos
signal bus_stopped(car: Car, stop: Object)    # a bus pulled in at a stop (StreetSpots.Spot)

const GARBAGE_TINT := Color(0.22, 0.5, 0.3)
const SIREN_RANGE := 45.0

var net: RoadNet
var cars: Array[Car] = []
var max_cars := 220
var rng := RandomNumberGenerator.new()
var weight := PackedFloat32Array()  # spawn weight per road cell (set by CityLife)
var camera: Camera3D
var shadows := true

var reserved := {}     # junction cell -> Array[Car]
var _lanes := {}       # cell * 4 + din -> Array[Car] sorted by s
var _next_id := 1
var _draw: Array[CarDrawer] = []

# Stats for tests.
var red_runs := 0
var despawned_stuck := 0
var wait_reason := {}  # debug: why stopped cars are stopped
var sirens: Array = []  # [pos, fwd] of emergency vehicles running sirens (set by Police)
var garbage_cells := PackedInt32Array()  # depot road cells where garbage trucks start
var stops := {}        # cell * 4 + heading -> bus stop (StreetSpots.stop_at)
var wet := 0.0         # 0..1 from Weather: drivers slow down and leave longer gaps
const BUS_DWELL := 9.0


func setup(road_net: RoadNet, seed_value := 7) -> void:
	net = road_net
	rng.seed = seed_value
	for k in MODELS.size():
		var d := CarDrawer.new()
		add_child(d)
		var fallback: Mesh = BusMesh.build() if k == BUS else _fallback_mesh(LENGTHS[k])
		if k >= SPORTS and VehicleKit.mesh(MODELS[k]) == null:
			fallback = _old_mesh(k)
		d.setup(MODELS[k], max_cars if k <= TRUCK else max_cars / 4, fallback)
		_draw.append(d)


## Before the car kit: newer models borrow an old kit car.
func _old_mesh(k: int) -> Mesh:
	var kit := _kit()
	var old: String = OLD_NAME.get(MODELS[k], "car_sedan")
	var m: Mesh = kit.mesh(old) if kit else null
	return m if m else _fallback_mesh(LENGTHS[k])


func _fallback_mesh(length: float) -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(1.8, 1.3, length)
	return b


# ------------------------------------------------------------------ spawn ---

func spawn_garbage(cell: int) -> Car:
	var c := spawn_at(cell, false)
	if c:
		c.garbage = true
		c.model = GARBAGE
		c.tint = GARBAGE_TINT
		c.aggr = 0.7
	return c


func spawn_bus(cell: int) -> Car:
	var c := spawn_at(cell, false)
	if c:
		c.bus = true
		c.model = BUS
		c.tint = Color.WHITE
		c.aggr = 0.8
	return c


func bus_count() -> int:
	var n := 0
	for c in cars:
		if c.bus:
			n += 1
	return n


func garbage_count() -> int:
	var n := 0
	for c in cars:
		if c.garbage:
			n += 1
	return n


## The AI car nearest `pos` within `radius`, or null. For carjacking.
func nearest_car(pos: Vector3, radius: float) -> Car:
	var best: Car = null
	var bd := radius * radius
	for c in cars:
		var d := c.pos.distance_squared_to(pos)
		if d < bd:
			bd = d
			best = c
	return best


## Take a car out of traffic so the player can spawn a real one in its place.
func take_car(c: Car) -> Dictionary:
	var back := -c.fwd
	var right := Vector3.UP.cross(back).normalized()
	var xf := Transform3D(Basis(right, Vector3.UP, back), c.pos)
	var model: String = MODELS[c.model]
	var kit := _kit()
	if kit and kit.mesh(model) == null:
		model = OLD_NAME.get(model, "car_sedan")
	var out := {"xform": xf, "model": model, "tint": c.tint}
	remove(c)
	car_taken.emit(c.pos, c.fwd)
	return out


func spawn_at(cell: int, rand_pos := true) -> Car:
	if not net.is_road(cell) or net.junction[cell] == 1:
		return null
	var heads := net.entries(cell)
	if heads.is_empty():
		return null
	var c := Car.new()
	c.id = _next_id
	_next_id += 1
	c.cell = cell
	c.din = heads[rng.randi() % heads.size()]
	c.dout = _pick_exit(cell, c.din)
	var nxt := net.neighbor(cell, c.dout)
	if not net.is_road(nxt):
		return null
	c.nd = _pick_exit(nxt, c.dout)
	var m := c.din * 4 + c.dout
	c.s = rng.randf() * net.move_len[m] * 0.7 if rand_pos else 0.0
	# Keep clear of cars already in that lane.
	for o in _lane(cell * 4 + c.din):
		if absf(o.s - c.s) < 9.0:
			return null
	c.model = _pick_model(_zone_near(cell))
	c.seed = rng.randf()
	var tints: Array = _kit().CAR_TINTS if _kit() else [Color(0.8, 0.2, 0.2), Color(0.9, 0.9, 0.9)]
	c.tint = tints[rng.randi() % tints.size()]
	c.aggr = rng.randf_range(0.85, 1.12)
	c.v = V_STRAIGHT * 0.6
	_place(c)
	cars.append(c)
	_lane(cell * 4 + c.din).append(c)
	return c


# Model mix by the zone along the street: [model, weight].
const MIX_TOWN := [[SEDAN, 34], [HATCH, 22], [SPORTS, 6], [PICKUP, 10], [VAN, 10], [TRUCK, 5], [TAXI, 3]]
const MIX_SHOPS := [[SEDAN, 30], [HATCH, 20], [SPORTS, 7], [PICKUP, 6], [VAN, 10], [TRUCK, 7], [TAXI, 20]]
const MIX_INDUSTRY := [[SEDAN, 15], [PICKUP, 20], [VAN, 25], [TRUCK, 40]]


func _pick_model(zone: int) -> int:
	var mix: Array = MIX_INDUSTRY if zone == City.Zone.IND else (MIX_SHOPS if zone == City.Zone.COM else MIX_TOWN)
	var total := 0
	for m in mix:
		total += m[1]
	var r := rng.randi() % total
	for m in mix:
		r -= m[1]
		if r < 0:
			return m[0]
	return SEDAN


func _kit() -> Node:
	# The Kit autoload, looked up at runtime so this also runs in --script test mode.
	return Engine.get_main_loop().root.get_node_or_null("Kit")


func _zone_near(cell: int) -> int:
	var x := cell % City.SIZE
	var y := cell / City.SIZE
	for d in RoadNet.DG:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if net.city.inside(nx, ny):
			var z: int = net.city.zone[net.city.idx(nx, ny)]
			if z != 0:
				return z
	return 0


func _pick_exit(cell: int, din: int) -> int:
	var opts := net.exits(cell, din)
	if opts.size() == 1:
		return opts[0]
	var total := 0.0
	var ws: Array[float] = []
	for d in opts:
		var n := net.neighbor(cell, d)
		var w := 0.3 + (weight[n] if n >= 0 and n < weight.size() else 0.0)
		if d == din:
			w *= 2.2
		ws.append(w)
		total += w
	var r := rng.randf() * total
	for k in opts.size():
		r -= ws[k]
		if r <= 0.0:
			return opts[k]
	return opts[-1]


func remove(c: Car) -> void:
	_release(c)
	cars.erase(c)
	var lane: Array = _lanes.get(c.cell * 4 + c.din, [])
	lane.erase(c)


func _release(c: Car, only := -1) -> void:
	for j in c.holds.duplicate():
		if only >= 0 and j != only:
			continue
		if reserved.has(j):
			reserved[j].erase(c)
		c.holds.erase(j)


func _lane(key: int) -> Array:
	if not _lanes.has(key):
		_lanes[key] = []
	return _lanes[key]


## Drop cars whose road was bulldozed or rerouted. Call after RoadNet.rebuild().
func validate() -> void:
	for c in cars.duplicate():
		var ok: bool = net.is_road(c.cell) and (net.has_arm(c.cell, c.dout) or c.dout == RoadNet.opp(c.din))
		var nxt := net.neighbor(c.cell, c.dout)
		ok = ok and net.is_road(nxt)
		if ok and not (net.has_arm(nxt, c.nd) or net.exits(nxt, c.dout).has(c.nd)):
			c.nd = _pick_exit(nxt, c.dout)
		if not ok:
			remove(c)


# -------------------------------------------------------------- simulate ---

func step(dt: float) -> void:
	for key in _lanes:
		_lanes[key].sort_custom(func(a, b): return a.s < b.s)
	for c in cars:
		_drive(c, dt)
	for c in cars.duplicate():
		_advance(c, dt)
	_unstick()


## Gridlock safety valve. Cars stuck out of sight vanish; cars stuck in view for a long
## time get waved through their junction.
func _unstick() -> void:
	for c in cars.duplicate():
		if c.stuck < 25.0:
			continue
		var seen := camera != null and camera.is_position_in_frustum(c.pos) \
			and camera.global_position.distance_to(c.pos) < 160.0
		if not seen:
			despawned_stuck += 1
			remove(c)
		elif c.stuck > 45.0:
			var nxt := net.neighbor(c.cell, c.dout)
			if net.is_road(nxt) and net.junction[nxt] == 1 and not c.holds.has(nxt):
				if not reserved.has(nxt):
					reserved[nxt] = []
				reserved[nxt].append(c)
				c.holds.append(nxt)
			c.stuck = 0.0


func _desired_speed(c: Car) -> float:
	var m := c.din * 4 + c.dout
	if c.dout == RoadNet.opp(c.din):
		return V_UTURN
	if net.is_turn(m) or net.junction[c.cell] == 1 and c.dout != c.din:
		return V_TURN
	# Slow down ahead of a turn in the next tile.
	if c.nd != c.dout:
		var left := net.move_len[m] - c.s
		return lerpf(V_TURN, V_STRAIGHT * c.aggr, clampf(left / 18.0, 0.0, 1.0))
	return V_STRAIGHT * c.aggr


func _drive(c: Car, dt: float) -> void:
	var m := c.din * 4 + c.dout
	var len_here := net.move_len[m]
	var gap := INF
	var lead_v := 0.0
	var my_len: float = LENGTHS[c.model]
	# Leader in the same lane of this tile.
	var lane: Array = _lanes[c.cell * 4 + c.din]
	var k := lane.find(c)
	if k >= 0 and k + 1 < lane.size():
		var o: Car = lane[k + 1]
		gap = o.s - c.s - (LENGTHS[o.model] + my_len) * 0.5
		lead_v = o.v
	var to_end := len_here - c.s
	var nxt := net.neighbor(c.cell, c.dout)
	if gap == INF and to_end < LOOKAHEAD:
		# Leader in the next tile.
		var lane2: Array = _lanes.get(nxt * 4 + c.dout, [])
		if not lane2.is_empty():
			var o: Car = lane2[0]
			gap = to_end + o.s - (LENGTHS[o.model] + my_len) * 0.5
			lead_v = o.v
		# Junction ahead: need a green light and a reservation before entering. Ask for
		# the reservation close to the stop line so it is not held for long.
		if net.is_road(nxt) and net.junction[nxt] == 1 and not c.holds.has(nxt):
			var near := to_end <= c.v * c.v / (2.0 * BRAKE) + 6.0
			var go := false
			if near:
				go = _try_grant(c, nxt, to_end)
			elif net.light(nxt, c.dout % 2) == RoadNet.Light.GREEN:
				go = true  # keep rolling toward the green; decide at the line
			if not go:
				var stop := to_end - my_len * 0.5 - 0.6
				if stop < gap:
					gap = stop
					lead_v = 0.0
	# Inside a junction: yield to people on the crosswalk we are about to cross.
	if net.junction[c.cell] == 1 and c.dout != c.din:
		var cw: int = net.crossing.get(c.cell * 4 + c.dout, 0)
		if cw > 0 and c.s < len_here * 0.55:
			var stop := len_here * 0.55 - c.s
			if stop < gap:
				gap = stop
				lead_v = 0.0
	var v0 := _desired_speed(c) * (1.0 - 0.15 * wet)
	# Emergency vehicle close by: ease to the kerb and stop until it has passed.
	var yield_now := false
	for sr in sirens:
		var to: Vector3 = c.pos - sr[0]
		if to.length_squared() < SIREN_RANGE * SIREN_RANGE and (sr[1] as Vector3).dot(to) > -6.0:
			yield_now = true
			break
	c.pull = move_toward(c.pull, 1.0 if yield_now else 0.0, dt * (1.2 if yield_now else 0.6))
	if yield_now:
		v0 = 0.0
	if c.garbage:
		if c.halt > 0.0:
			c.halt -= dt
			v0 = 0.0
		elif net.junction[c.cell] == 0 and c.v > 2.0 and rng.randf() < dt * 0.08 \
				and _zone_near(c.cell) != 0:
			c.halt = rng.randf_range(4.0, 8.0)  # stop to empty the bins
	if c.bus:
		if c.halt > 0.0:
			c.halt -= dt
			v0 = 0.0
		elif c.served != c.cell and c.dout == c.din and stops.has(c.cell * 4 + c.din):
			# Pull in with the front door at the shelter.
			var stop_s := len_here * 0.5 - StreetSpots.STOP_U + 2.6
			if c.s < stop_s + 0.5:
				var g := stop_s + MIN_GAP - c.s
				if g < gap:
					gap = g
					lead_v = 0.0
				if c.s > stop_s - 0.6 and c.v < 0.6:
					c.halt = BUS_DWELL
					c.served = c.cell
					bus_stopped.emit(c, stops[c.cell * 4 + c.din])
			else:
				c.served = c.cell  # rolled past (spawned beyond it)
		c.pull = move_toward(c.pull, 1.0 if c.halt > 0.0 or yield_now else 0.0, dt * 0.8)
	var acc := ACCEL * (1.0 - pow(c.v / maxf(v0, 0.1), 4.0)) if v0 > 0.0 else -BRAKE * 1.2
	if gap < INF:
		var dv := c.v - lead_v
		var s_star := MIN_GAP + maxf(0.0, c.v * HEADWAY * (1.0 + 0.35 * wet) + c.v * dv / (2.0 * sqrt(ACCEL * BRAKE)))
		acc -= ACCEL * pow(s_star / maxf(gap, 0.1), 2.0)
	acc = clampf(acc, -9.0, ACCEL)
	c.brake = acc < -0.8 or c.v < 0.3
	c.v = maxf(0.0, c.v + acc * dt)
	if gap < 0.3:
		c.v = 0.0
	c.stuck = c.stuck + dt if c.v < 0.3 and not yield_now and c.halt <= 0.0 else 0.0
	if c.v < 0.3 and OS.is_debug_build():
		var why := "follow" if lead_v > 0.0 or gap == INF else "stopline"
		if net.junction[c.cell] == 1:
			why = "in_junction"
		wait_reason[why] = wait_reason.get(why, 0) + 1


func _try_grant(c: Car, j: int, to_end: float) -> bool:
	var axis := c.dout % 2
	var l := net.light(j, axis)
	if l == RoadNet.Light.RED:
		return false
	if l == RoadNet.Light.AMBER:
		# Go through on amber only when too close to stop comfortably.
		var stop_dist := c.v * c.v / (2.0 * BRAKE)
		if to_end > stop_dist + 1.0:
			return false
	return _reserve(c, j)


func _reserve(c: Car, j: int) -> bool:
	var mj := c.dout * 4 + c.nd
	var list: Array = reserved.get(j, [])
	for o in list:
		var mo: int
		if o.cell == j:
			mo = o.din * 4 + o.dout
		else:
			mo = o.dout * 4 + o.nd
		if net.conflict[mj * 16 + mo] == 1:
			return false
	# Don't block the box: the lane beyond the junction needs room for us.
	var beyond := net.neighbor(j, c.nd)
	if net.is_road(beyond):
		var lane: Array = _lanes.get(beyond * 4 + c.nd, [])
		var queued := 0.0
		for o in lane:
			queued += LENGTHS[o.model] + 2.0
		for o in list:
			if o.cell != j and o.nd == c.nd or o.cell == j and o.dout == c.nd:
				queued += LENGTHS[o.model] + 2.0
		if queued + LENGTHS[c.model] > City.TILE + 2.0:
			if lane.size() > 0 and lane[0].s < 4.0:
				return false
	if not reserved.has(j):
		reserved[j] = []
	reserved[j].append(c)
	c.holds.append(j)
	return true


func _advance(c: Car, dt: float) -> void:
	c.s += c.v * dt
	c.wheel = fmod(c.wheel + c.v * dt / WHEEL_R[c.model], TAU)
	var old_fwd := c.fwd
	var m := c.din * 4 + c.dout
	while c.s >= net.move_len[m]:
		c.s -= net.move_len[m]
		var old_key := c.cell * 4 + c.din
		var was_junction := net.junction[c.cell] == 1
		var nxt := net.neighbor(c.cell, c.dout)
		if not net.is_road(nxt):
			remove(c)
			return
		if net.junction[nxt] == 1 and not c.holds.has(nxt):
			red_runs += 1  # entered a junction without a reservation (should not happen)
		if was_junction:
			_release(c, c.cell)
		_lanes[old_key].erase(c)
		c.cell = nxt
		c.din = c.dout
		c.dout = c.nd
		if not (net.has_arm(nxt, c.dout) or net.exits(nxt, c.din).has(c.dout)):
			c.dout = _pick_exit(nxt, c.din)
		var after := net.neighbor(nxt, c.dout)
		if not net.is_road(after):
			remove(c)
			return
		c.nd = _pick_exit(after, c.dout)
		_lane(c.cell * 4 + c.din).append(c)
		m = c.din * 4 + c.dout
	_place(c)
	# Front wheels follow how fast the heading turns (wheelbase about 0.6 of the length).
	if dt > 0.0 and c.v > 0.2:
		var yaw := old_fwd.signed_angle_to(c.fwd, Vector3.UP) / dt
		var want := clampf(yaw * LENGTHS[c.model] * 0.6 / c.v, -0.6, 0.6)
		c.steer = lerpf(c.steer, want, minf(dt * 8.0, 1.0))


func _place(c: Car) -> void:
	var m := c.din * 4 + c.dout
	var smp := net.sample(m, c.s)
	c.fwd = smp[1]
	c.pos = net.center(c.cell) + smp[0] + Vector3(0, ROAD_Y, 0)
	if c.pull > 0.0:
		c.pos += Vector3(-c.fwd.z, 0, c.fwd.x) * (c.pull * (0.5 if c.bus else 1.3))


# ---------------------------------------------------------------- render ---

func render() -> void:
	var eye := Vector3.ZERO
	var has_eye := camera != null and camera.is_inside_tree()
	if has_eye:
		eye = camera.global_position
	for d in _draw:
		d.begin()
	for c in cars:
		var lod := CarDrawer.lod_at(c.pos, eye, has_eye)
		var cu := VehicleKit.custom(false, c.brake, false, false, c.wheel, c.steer, c.seed)
		_draw[c.model].add(c.pos, c.fwd, c.tint, cu, lod)
	for d in _draw:
		d.finish(shadows)


## Cars drawn at each LOD, for budgets and tests.
func lod_counts() -> Array:
	var out := [0, 0, 0]
	for d in _draw:
		for k in 3:
			out[k] += d._n[k]
	return out
