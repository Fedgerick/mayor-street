class_name RoadNet
extends RefCounted
## Street-level view of the City's road grid, shared by traffic and pedestrians.
##
## Cars drive on the right in two 3.75 m lanes per road tile. Inside a tile a car follows
## one of 16 "movements" (entry direction x exit direction): a straight line, a quarter
## curve for turns, or a loop for U-turns at dead ends. Junction tiles (3+ arms) are
## signalled with two phases, N/S then E/W.
##
## Pedestrians walk a graph of sidewalk corners: four nodes per road tile, joined along
## the sidewalk strips, across tile borders, and over zebra crossings at junctions.
##
## Directions: 0 = N (grid y-1, world -Z), 1 = E (+X), 2 = S (+Z), 3 = W (-X).
## This matches City.road_mask bits (N=1, E=2, S=4, W=8), so bit = 1 << dir.

const HALF := City.TILE * 0.5
const LANE := 1.875           # lane centre offset from the road centreline
const WALK := 5.55            # sidewalk walking line offset from the road centreline
const SAMPLES := 12           # points per movement curve
const DV := [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]
const DG := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
# Sidewalk corners: 0 = NW, 1 = NE, 2 = SE, 3 = SW. Side d joins corner d and d+1.
const CORNER := [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]

# Signal timing (seconds of real time).
const GREEN := 13.0
const AMBER := 3.0
const ALL_RED := 1.5
const CYCLE := 2.0 * (GREEN + AMBER + ALL_RED)
enum Light { RED, AMBER, GREEN }

var city: City
var mask := PackedByteArray()        # road arms per cell (0 when not a road)
var junction := PackedByteArray()    # 1 when the cell has 3+ arms (signalled)
var signal_offset := PackedFloat32Array()

# Movement curves in tile-local space, indexed din * 4 + dout.
var move_pts: Array[PackedVector3Array] = []
var move_len := PackedFloat32Array()
var move_cum: Array[PackedFloat32Array] = []
var conflict := PackedByteArray()    # [m1 * 16 + m2] = 1 when the two paths cross

# Pedestrian graph. Node id = cell * 4 + corner.
var walk_adj := {}                   # node -> Array of [node, crosswalk_arm or -1]
var walk_nodes := PackedInt32Array() # every node that has at least one edge

# Crosswalk occupancy: cell * 4 + arm -> number of pedestrians on it.
var crossing := {}

var time := 0.0


func _init(c: City) -> void:
	city = c
	var n := City.W * City.H
	mask.resize(n)
	junction.resize(n)
	signal_offset.resize(n)
	for i in n:
		signal_offset[i] = _hash(i) * CYCLE
	_build_movements()
	rebuild()


static func _hash(i: int) -> float:
	var h := (i * 73856093) ^ (i * 19349663 >> 3)
	h = (h ^ (h >> 13)) * 1274126177
	return float(h & 0xFFFF) / 65535.0


static func opp(d: int) -> int:
	return (d + 2) % 4


static func right_of(d: int) -> Vector3:
	var v: Vector3 = DV[d]
	return Vector3(-v.z, 0, v.x)


# ------------------------------------------------------------------ graph ---

## Re-read the city's roads. Call after City.cells_changed.
func rebuild() -> void:
	for y in City.H:
		for x in City.W:
			var i := city.idx(x, y)
			if city.road[i] == 1:
				var m := city.road_mask(x, y)
				mask[i] = m
				junction[i] = 1 if _bits(m) >= 3 else 0
			else:
				mask[i] = 0
				junction[i] = 0
	_build_walk_graph()


static func _bits(m: int) -> int:
	return (m & 1) + ((m >> 1) & 1) + ((m >> 2) & 1) + ((m >> 3) & 1)


func is_road(i: int) -> bool:
	return i >= 0 and i < mask.size() and city.road[i] == 1


func has_arm(i: int, d: int) -> bool:
	return (mask[i] >> d) & 1 == 1


func neighbor(i: int, d: int) -> int:
	var x: int = i % City.W + DG[d].x
	var y: int = i / City.W + DG[d].y
	if Planet.on:  # east-west wraps round the ball (positions jump by a lap at the seam)
		x = posmod(x, City.W)
	if x < 0 or y < 0 or x >= City.W or y >= City.H:
		return -1
	return y * City.W + x


func center(i: int) -> Vector3:
	return Vector3((i % City.W + 0.5) * City.TILE, 0.0, (i / City.W + 0.5) * City.TILE)


## Exits a car may take from cell i after entering it heading din. U-turns only at dead ends.
func exits(i: int, din: int) -> Array[int]:
	var out: Array[int] = []
	for d in 4:
		if d != opp(din) and has_arm(i, d):
			out.append(d)
	if out.is_empty():
		out.append(opp(din))
	return out


## Headings a car can have inside cell i (it must have come in through an arm).
func entries(i: int) -> Array[int]:
	var out: Array[int] = []
	for d in 4:
		if has_arm(i, opp(d)):
			out.append(d)
	if out.is_empty() and mask[i] == 0 and city.road[i] == 1:
		out.append_array([0, 1, 2, 3])  # isolated tile
	return out


# -------------------------------------------------------------- movements ---

func _build_movements() -> void:
	move_pts.resize(16)
	move_cum.resize(16)
	move_len.resize(16)
	for din in 4:
		for dout in 4:
			var m := din * 4 + dout
			var a: Vector3 = -DV[din] * HALF + right_of(din) * LANE
			var b: Vector3 = DV[dout] * HALF + right_of(dout) * LANE
			var pts := PackedVector3Array()
			for k in SAMPLES + 1:
				var t := float(k) / SAMPLES
				var p: Vector3
				if dout == din:
					p = a.lerp(b, t)
				elif dout == opp(din):
					# U-turn: a loop that swings to the far side of the tile.
					var c1: Vector3 = a + DV[din] * 7.0 - right_of(din) * 1.2
					var c2: Vector3 = b - DV[dout] * 7.0 + right_of(dout) * 1.2
					p = _cubic(a, c1, c2, b, t)
				else:
					var c: Vector3 = right_of(din) * LANE + right_of(dout) * LANE
					p = a.lerp(c, t).lerp(c.lerp(b, t), t)
				pts.append(p)
			var cum := PackedFloat32Array()
			cum.append(0.0)
			for k in SAMPLES:
				cum.append(cum[k] + pts[k].distance_to(pts[k + 1]))
			move_pts[m] = pts
			move_cum[m] = cum
			move_len[m] = cum[SAMPLES]
	conflict.resize(256)
	for m1 in 16:
		for m2 in 16:
			conflict[m1 * 16 + m2] = 1 if _paths_cross(m1, m2) else 0


static func _cubic(a: Vector3, b: Vector3, c: Vector3, d: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u * u + b * 3.0 * u * u * t + c * 3.0 * u * t * t + d * t * t * t


func _paths_cross(m1: int, m2: int) -> bool:
	if m1 / 4 == m2 / 4:
		return false  # same approach: handled by car following
	for p in move_pts[m1]:
		for q in move_pts[m2]:
			if p.distance_squared_to(q) < 2.4 * 2.4:
				return true
	return false


## Local position and heading at distance s along movement m.
func sample(m: int, s: float) -> Array:
	var cum: PackedFloat32Array = move_cum[m]
	var pts: PackedVector3Array = move_pts[m]
	s = clampf(s, 0.0, move_len[m])
	var k := 0
	while k < SAMPLES - 1 and cum[k + 1] < s:
		k += 1
	var seg := cum[k + 1] - cum[k]
	var f := (s - cum[k]) / seg if seg > 0.0001 else 0.0
	var p := pts[k].lerp(pts[k + 1], f)
	var dir := (pts[k + 1] - pts[k]).normalized()
	return [p, dir]


func is_turn(m: int) -> bool:
	return m / 4 != m % 4


# ---------------------------------------------------------------- signals ---

## Light shown to traffic travelling along axis (0 = N/S, 1 = E/W) at junction i.
func light(i: int, axis: int) -> int:
	var t := fmod(time + signal_offset[i], CYCLE)
	if axis == 1:
		t = fmod(t + CYCLE * 0.5, CYCLE)
	if t < GREEN:
		return Light.GREEN
	if t < GREEN + AMBER:
		return Light.AMBER
	return Light.RED


## Seconds of green left for axis (0 when not green).
func green_left(i: int, axis: int) -> float:
	var t := fmod(time + signal_offset[i], CYCLE)
	if axis == 1:
		t = fmod(t + CYCLE * 0.5, CYCLE)
	return GREEN - t if t < GREEN else 0.0


## Pedestrians may start crossing arm `arm` of junction i: the traffic that drives over
## that crosswalk is red and the cross traffic has enough green left to get over.
func walk_ok(i: int, arm: int) -> bool:
	var axis := arm % 2
	return light(i, axis) == Light.RED and green_left(i, 1 - axis) > 6.0


# ------------------------------------------------------------- sidewalks ---

func corner_pos(i: int, k: int) -> Vector3:
	return center(i) + CORNER[k] * WALK + Vector3(0, 0.17, 0)


func _build_walk_graph() -> void:
	walk_adj.clear()
	for i in mask.size():
		if city.road[i] != 1:
			continue
		for d in 4:
			var a := i * 4 + d
			var b := i * 4 + (d + 1) % 4
			if not has_arm(i, d):
				_link(a, b, -1)
			elif junction[i] == 1:
				_link(a, b, d)  # zebra crossing over arm d
		# Continue the sidewalk into the next tile east and south (west/north are
		# covered when the neighbour is processed).
		if has_arm(i, 1):
			var n := neighbor(i, 1)
			if n >= 0 and city.road[n] == 1:
				_link(i * 4 + 1, n * 4 + 0, -1)
				_link(i * 4 + 2, n * 4 + 3, -1)
		if has_arm(i, 2):
			var n := neighbor(i, 2)
			if n >= 0 and city.road[n] == 1:
				_link(i * 4 + 2, n * 4 + 1, -1)
				_link(i * 4 + 3, n * 4 + 0, -1)
	walk_nodes = PackedInt32Array(walk_adj.keys())


func _link(a: int, b: int, arm: int) -> void:
	if not walk_adj.has(a):
		walk_adj[a] = []
	if not walk_adj.has(b):
		walk_adj[b] = []
	walk_adj[a].append([b, arm])
	walk_adj[b].append([a, arm])


func has_walk_edge(a: int, b: int) -> bool:
	if not walk_adj.has(a):
		return false
	for e in walk_adj[a]:
		if e[0] == b:
			return true
	return false


func node_pos(node: int) -> Vector3:
	return corner_pos(node / 4, node % 4)
