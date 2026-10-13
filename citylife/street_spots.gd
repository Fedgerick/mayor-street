class_name StreetSpots
extends Node3D
## Places where people stop: benches and bus shelters on the sidewalks. Spots are worked
## out from the city (straight road tiles, the side away from the road, more of them by
## shops, parks and nightlife) so they follow whatever the Mayor builds, and they stay put
## between runs. The props are drawn here as two MultiMeshes until the street dresser
## takes over (set show_props = false then and read `spots` for where they stand).
##
## Sidewalk geometry: the strip on side d of a road tile runs from corner d to corner d+1
## at 3.75..6 m from the centre line. People walk at about 5.55 m, so they step toward the
## kerb around a spot (see Crowd._place).

enum Kind { BENCH, STOP }

const BENCH_MESH := "res://assets/kit/props/bench.glb"
const STOP_MESH := "res://assets/kit/props/bus_stop.glb"
const BENCH_OUT := 5.7      # bench origin from the centre line (backrest against the lots)
const STOP_OUT := 4.7       # shelter origin (back panel at 6.0)
const BENCH_U := 3.0        # along the strip, clear of the mid-tile street lamp
const STOP_U := 3.55
const SWERVE_OUT := 4.25    # walkers pass a spot this far from the centre line
const PROP_HEIGHT := 120.0  # camera height above which the props are hidden

class Spot:
	var id := 0
	var kind := 0
	var cell := 0
	var side := 0           # sidewalk side of the tile (0 N, 1 E, 2 S, 3 W)
	var u := 0.0            # metres along the strip from its middle, toward corner side+1
	var xform := Transform3D()  # prop transform; local +Z faces the road
	var seats: Array[Vector3] = []     # where sitters' hips go
	var stands: Array[Vector3] = []    # where standing waiters stand (bus stops)
	var taken: Array = []              # one Ped (or null) per seat, then per stand
	var heading := 0        # bus stops: travel direction of the buses that stop here
	var waiting := 0        # people waiting for the bus

	func face() -> Vector3:
		return xform.basis.z  # toward the road

	func free_slot() -> int:
		for k in taken.size():
			if taken[k] == null:
				return k
		return -1

	func slot_pos(k: int) -> Vector3:
		return seats[k] if k < seats.size() else stands[k - seats.size()]

	func is_seat(k: int) -> bool:
		return k < seats.size()

var net: RoadNet
var city: City
var spots: Array[Spot] = []
var by_strip := {}          # cell * 4 + side -> Spot
var stop_at := {}           # cell * 4 + heading -> Spot (bus stops, for buses)
var show_props := true
var camera: Camera3D

var _bench_mmi: MultiMeshInstance3D
var _stop_mmi: MultiMeshInstance3D


func setup(road_net: RoadNet) -> void:
	net = road_net
	city = net.city
	_bench_mmi = _make_mmi("Benches", BENCH_MESH, _fallback_bench())
	_stop_mmi = _make_mmi("BusStops", STOP_MESH, _fallback_stop())
	rebuild()


func _make_mmi(nm: String, path: String, fallback: Mesh) -> MultiMeshInstance3D:
	var mesh: Mesh = null
	if ResourceLoader.exists(path):
		var sc: PackedScene = load(path)
		if sc:
			var inst := sc.instantiate()
			var found := inst.find_children("*", "MeshInstance3D", true, false)
			if not found.is_empty():
				mesh = (found[0] as MeshInstance3D).mesh
			inst.free()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh if mesh else fallback
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	mmi.visibility_range_end = 260.0
	add_child(mmi)
	return mmi


func _fallback_bench() -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(1.8, 0.5, 0.5)
	return b


func _fallback_stop() -> Mesh:
	var b := BoxMesh.new()
	b.size = Vector3(3.6, 2.6, 1.3)
	return b


## Hash of a cell and side, 0..1, so the same street gets the same benches every run.
static func _hash01(i: int, k: int) -> float:
	var h := (i * 73856093) ^ (k * 19349663) ^ 0x5bd1e995
	h = (h ^ (h >> 13)) * 0x27d4eb2d
	h = h ^ (h >> 15)
	return float(h & 0xffff) / 65535.0


## Re-place every spot. Call after the roads or buildings change (cheap: one pass over
## the road tiles).
func rebuild() -> void:
	# Keep people on spots that survive; drop the rest.
	var old := by_strip
	spots.clear()
	by_strip = {}
	stop_at.clear()
	var last_stop := {}  # side axis row/column -> last tile index with a stop on that line
	for i in net.mask.size():
		if not net.is_road(i) or net.junction[i] == 1:
			continue
		var m: int = net.mask[i]
		if m != 5 and m != 10:
			continue  # straight tiles only
		if not city.props_at(i).is_empty():
			continue  # a payphone stands here already
		for d in 4:
			if net.has_arm(i, d):
				continue
			var n := net.neighbor(i, d)
			var lure := _lure(n)
			var h := _hash01(i, d)
			var kind := -1
			# Bus stops: about one every few blocks along a busy street, both sides.
			var line_key := d * 1000 + (i % City.W if d % 2 == 1 else i / City.W)
			var along := i / City.W if d % 2 == 1 else i % City.W
			var gap_ok: bool = not last_stop.has(line_key) or absi(along - last_stop[line_key]) >= 7
			if lure > 0.25 and gap_ok and h < 0.16:
				kind = Kind.STOP
				last_stop[line_key] = along
			elif h < 0.08 + 0.3 * lure:
				kind = Kind.BENCH
			if kind < 0:
				continue
			var s := _make_spot(i, d, kind)
			var prev: Spot = old.get(i * 4 + d)
			if prev and prev.kind == kind:
				s.taken = prev.taken
				s.waiting = prev.waiting
			spots.append(s)
			by_strip[i * 4 + d] = s
			if kind == Kind.STOP:
				stop_at[i * 4 + s.heading] = s
	for k in spots.size():
		spots[k].id = k
	_fill_props()


## How much a lot draws people to sit or wait: shops, parks and nightlife most.
func _lure(n: int) -> float:
	if n < 0:
		return 0.0
	var z: int = city.zone[n]
	var w := 0.0
	if z == City.Zone.COM:
		w = 0.6
	elif z == City.Zone.RES:
		w = 0.3
	elif z == City.Zone.IND:
		w = 0.05
	var id: int = city.bld[n]
	if id >= 0 and city.buildings.has(id):
		var tags: Array = city.buildings[id].get("tags", [])
		if tags.has("park") or tags.has("meeting_spot"):
			w = 1.0
		elif tags.has("nightlife") or tags.has("shop"):
			w = maxf(w, 0.8)
		elif w == 0.0:
			w = 0.3
	return w


func _make_spot(i: int, d: int, kind: int) -> Spot:
	var s := Spot.new()
	s.kind = kind
	s.cell = i
	s.side = d
	var out: Vector3 = RoadNet.DV[d]
	var z := -out                          # local +Z faces the road
	var x := Vector3.UP.cross(z)           # along the strip, toward corner d+1
	var basis := Basis(x, Vector3.UP, z)
	var c := net.center(i) + Vector3(0, 0.17, 0)
	if kind == Kind.BENCH:
		s.u = BENCH_U if _hash01(i, d + 7) < 0.5 else -BENCH_U
		s.xform = Transform3D(basis, c + out * BENCH_OUT + x * s.u)
		for sx in [-0.45, 0.45]:
			s.seats.append(s.xform * Vector3(sx, 0.0, 0.02))
	else:
		s.u = STOP_U
		s.heading = (d + 3) % 4
		s.xform = Transform3D(basis, c + out * STOP_OUT + x * s.u)
		for sx in [-0.7, 0.2]:
			s.seats.append(s.xform * Vector3(sx, 0.0, -0.85))
		for sz in [[2.35, 0.1], [2.9, -0.4], [2.55, -0.9]]:
			s.stands.append(s.xform * Vector3(sz[0], 0.0, sz[1]))
	s.taken.resize(s.seats.size() + s.stands.size())
	s.taken.fill(null)
	return s


## Along-strip window (metres from the strip middle) that walkers swerve around.
func swerve_window(s: Spot) -> Vector2:
	if s.kind == Kind.BENCH:
		return Vector2(s.u - 1.2, s.u + 1.2)
	return Vector2(s.u - 2.7, s.u + 3.2)


func _fill_props() -> void:
	var benches: Array[Transform3D] = []
	var stops: Array[Transform3D] = []
	for s in spots:
		if s.kind == Kind.BENCH:
			benches.append(s.xform)
		else:
			stops.append(s.xform)
	_set_xforms(_bench_mmi, benches)
	_set_xforms(_stop_mmi, stops)


func _set_xforms(mmi: MultiMeshInstance3D, xs: Array[Transform3D]) -> void:
	var mm := mmi.multimesh
	mm.instance_count = xs.size()
	for k in xs.size():
		mm.set_instance_transform(k, Planet.xf(xs[k]))  # flat map -> the ball on msp


func update_view(cam_height: float) -> void:
	visible = show_props and cam_height < PROP_HEIGHT


func count(kind: int) -> int:
	var n := 0
	for s in spots:
		if s.kind == kind:
			n += 1
	return n


## Spots within radius of pos, of one kind (-1 for any).
func near(pos: Vector3, radius: float, kind := -1) -> Array[Spot]:
	var out: Array[Spot] = []
	var r2 := radius * radius
	for s in spots:
		if (kind < 0 or s.kind == kind) and s.xform.origin.distance_squared_to(pos) < r2:
			out.append(s)
	return out
