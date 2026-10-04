class_name Traffic
extends Node3D
## AI cars that drive the road grid: lane following with the Intelligent Driver Model,
## turns and U-turns, signalled junctions with box reservations, yielding to people on
## crosswalks. Drawn with one MultiMesh per car model, rebuilt from a flat buffer each
## frame, so a few hundred cars cost a handful of draw calls.

const MODELS := ["car_sedan", "car_hatch", "car_van", "car_truck", "car_bus"]
const LENGTHS := [4.4, 3.8, 4.8, 6.8, 10.5]
const BUS := 4
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
var _mmi: Array[MultiMeshInstance3D] = []
var _buf: Array[PackedFloat32Array] = []

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
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		var kit := _kit()
		var mesh: Mesh = kit.mesh(MODELS[k]) if kit else null
		if mesh == null and k == BUS:
			mesh = BusMesh.build()
		mm.mesh = mesh if mesh else _fallback_mesh(LENGTHS[k])
		mm.instance_count = max_cars
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = MODELS[k]
		add_child(mmi)
		_mmi.append(mmi)
		_buf.append(PackedFloat32Array())


func _fallback_mesh(length: float) -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(1.8, 1.3, length)
	return b


# ------------------------------------------------------------------ spawn ---

func spawn_garbage(cell: int) -> Car:
	var c := spawn_at(cell, false)
	if c:
		c.garbage = true
		c.model = 3
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
		if c.bus:
			continue  # no drivable bus yet
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
	var out := {"xform": xf, "model": MODELS[c.model], "tint": c.tint}
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
	var z := _zone_near(cell)
	var r := rng.randf()
	if z == City.Zone.IND:
		c.model = 3 if r < 0.45 else (2 if r < 0.75 else 0)
	else:
		c.model = 0 if r < 0.45 else (1 if r < 0.8 else (2 if r < 0.95 else 3))
	var tints: Array = _kit().CAR_TINTS if _kit() else [Color(0.8, 0.2, 0.2), Color(0.9, 0.9, 0.9)]
	c.tint = tints[rng.randi() % tints.size()]
	c.aggr = rng.randf_range(0.85, 1.12)
	c.v = V_STRAIGHT * 0.6
	_place(c)
	cars.append(c)
	_lane(cell * 4 + c.din).append(c)
	return c


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


func _place(c: Car) -> void:
	var m := c.din * 4 + c.dout
	var smp := net.sample(m, c.s)
	c.fwd = smp[1]
	c.pos = net.center(c.cell) + smp[0] + Vector3(0, ROAD_Y, 0)
	if c.pull > 0.0:
		c.pos += Vector3(-c.fwd.z, 0, c.fwd.x) * (c.pull * (0.5 if c.bus else 1.3))


# ---------------------------------------------------------------- render ---

func render() -> void:
	var counts := []
	counts.resize(MODELS.size())
	counts.fill(0)
	for k in MODELS.size():
		if _buf[k].size() != max_cars * 20:
			_buf[k].resize(max_cars * 20)
	for c in cars:
		var k := c.model
		var n: int = counts[k]
		if n >= max_cars:
			continue
		counts[k] = n + 1
		# Car meshes face -Z. Basis columns: x = right, y = up, z = back.
		var back := -c.fwd
		var right := Vector3.UP.cross(back).normalized()
		var b := _buf[k]
		var o := n * 20
		b[o] = right.x; b[o + 1] = 0.0; b[o + 2] = back.x; b[o + 3] = c.pos.x
		b[o + 4] = right.y; b[o + 5] = 1.0; b[o + 6] = back.y; b[o + 7] = c.pos.y
		b[o + 8] = right.z; b[o + 9] = 0.0; b[o + 10] = back.z; b[o + 11] = c.pos.z
		b[o + 12] = c.tint.r; b[o + 13] = c.tint.g; b[o + 14] = c.tint.b; b[o + 15] = 1.0
		b[o + 16] = 0.0; b[o + 17] = 0.0; b[o + 18] = 0.0; b[o + 19] = 0.0
	for k in MODELS.size():
		var mm := _mmi[k].multimesh
		mm.buffer = _buf[k]
		mm.visible_instance_count = counts[k]
		_mmi[k].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
