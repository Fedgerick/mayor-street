class_name City
extends RefCounted
## The city's data and simulation. No rendering here, so it runs headless in tests.
##
## The map is a W x H grid of 12 m tiles. Grid x maps to flat map +X and grid y to flat
## map +Z. Each tile can hold a road, a zone, and (part of) one building.
##
## On a planet (planet/, Planet.on) the grid is a belt round the equator: x wraps east to
## west (idx() and inside() take any x), and cell positions are flat map metres that
## Planet.warp() stands up on the ball. world_to_cell() takes a world position either way.

signal cells_changed(rect: Rect2i)
signal building_added(id: int, animate: bool)
signal building_removed(id: int)
signal day_passed
signal message(text: String)
signal land_value_computed  ## services/ adjusts land_value in place after each recompute

static var W := 80  # tiles east to west (planet: all the way round)
static var H := 80  # tiles north to south
const TILE := 12.0
const ROAD_COST := 25
const ZONE_COST := 10
const BULLDOZE_COST := 10
const ROAD_UPKEEP := 0.5
const MINUTES_PER_SECOND := 6.0  # at 1x speed: one game hour every 10 real seconds

enum Zone { NONE, RES, COM, IND }
const ZONE_NAMES := ["None", "Residential", "Commercial", "Industrial"]
const ZONE_KEYS := ["", "r", "c", "i"]

# Capacity per building, indexed [zone][stage]; size-2 towers use CAP_BIG.
const CAP := [[0, 0, 0, 0], [0, 6, 32, 140], [0, 6, 28, 110], [0, 10, 32, 70]]
const CAP_BIG := [0, 640, 520, 280]
# City population needed before a stage can appear (keeps towers for later).
const STAGE_POP := [0, 0, 120, 1400]
const STAGE_LV := [0.0, 0.0, 0.3, 0.6]

var land := PackedByteArray()      # 1 = buildable
var height := PackedFloat32Array()  # terrain landness at tile centre (for coast logic)
var road := PackedByteArray()
var zone := PackedByteArray()
var bld := PackedInt32Array()      # building id per cell, -1 none
var trees := PackedByteArray()     # decorative tree count per cell (0-3)
var traffic := PackedFloat32Array()  # 0..1+ congestion per road cell
var land_value := PackedFloat32Array()
var coast_dist := PackedFloat32Array()

var buildings := {}  # id -> Dictionary
var _next_id := 1
var _props := {}  # road cell index -> ids of the street props (payphones) standing there

var funds := 50000.0
var tax_rate := 0.09
var minutes := 7.0 * 60.0   # game time since day 0, 00:00
var population := 0
var jobs_c := 0
var jobs_i := 0
var demand := [0.0, 1.0, 0.4, 0.8]
var last_income := 0.0
var last_expense := 0.0
var rng := RandomNumberGenerator.new()
var animate_growth := true
var noise := FastNoiseLite.new()
var map_seed := 1337
## The Progress store (set by Progress.begin): building unlocks are checked against it.
var progress: Object = null
## Optional, from services/: func(x, y) -> bool, asked before a zone lot grows. False holds it back.
var growth_check := Callable()


func _init(seed_value: int = 1337) -> void:
	map_seed = seed_value
	rng.seed = seed_value
	noise.seed = seed_value
	noise.frequency = 0.0035
	noise.fractal_octaves = 4
	var n := W * H
	land.resize(n)
	height.resize(n)
	road.resize(n)
	zone.resize(n)
	bld.resize(n)
	bld.fill(-1)
	trees.resize(n)
	traffic.resize(n)
	land_value.resize(n)
	coast_dist.resize(n)
	_make_island()


# ------------------------------------------------------------------ terrain ---

## Landness at a world XZ point: > 0 is land. Shared by terrain mesh and water shader.
func landness(wx: float, wz: float) -> float:
	if Planet.on:
		return _planet_landness(wx, wz)
	var c := W * TILE * 0.5
	var dx := (wx - c) / (c * 1.02)
	var dz := (wz - c) / (c * 0.96)
	var r := sqrt(dx * dx + dz * dz)
	var n := noise.get_noise_2d(wx, wz)
	return 1.0 - r + n * 0.32 - 0.04


func terrain_height(wx: float, wz: float) -> float:
	if Planet.on:
		return _planet_height(wx, wz)
	var l := landness(wx, wz)
	if l > 0.05:
		return 0.0
	# Beach slopes down to the sea floor.
	return clampf((l - 0.05) * 60.0, -14.0, 0.0)


## The planet's belt: land all the way round, a wavy south shore a few tiles in from the
## belt's edge with the polar sea beyond it, and to the north tundra rising into the ice cap.
func _planet_coast(wx: float) -> float:
	var a := wx / (W * TILE) * TAU
	return (H - 3.0 + noise.get_noise_2d(cos(a) * 300.0, sin(a) * 300.0) * 2.5) * TILE


func _planet_landness(wx: float, wz: float) -> float:
	return clampf((_planet_coast(wx) - wz) / 260.0 + 0.05, -1.0, 1.0)


func _planet_height(wx: float, wz: float) -> float:
	var l := _planet_landness(wx, wz)
	if l <= 0.05:
		return clampf((l - 0.05) * 60.0, -14.0, 0.0)
	if wz >= 0.0:
		return 0.0
	var a := wx / (W * TILE) * TAU
	var hill := noise.get_noise_3d(cos(a) * 400.0, sin(a) * 400.0, wz * 2.0) * 0.5 + 0.5
	return smoothstep(0.0, -90.0, wz) * (2.0 + hill * 5.0) + smoothstep(-120.0, -360.0, wz) * 6.0


## 0 below the ice line .. 1 deep in the planet's north ice cap. 0 on the flat island.
func ice(wx: float, wz: float) -> float:
	if not Planet.on or wz > 0.0:
		return 0.0
	var a := wx / (W * TILE) * TAU
	var n := noise.get_noise_2d(cos(a) * 500.0 + 31.0, sin(a) * 500.0) * 40.0
	return clampf((-wz - 6.0 + n) / 140.0, 0.0, 1.0)


func _make_island() -> void:
	for y in H:
		for x in W:
			var i := y * W + x
			var wx := (x + 0.5) * TILE
			var wz := (y + 0.5) * TILE
			var l := landness(wx, wz)
			# Every corner must be flat land, plus a margin for the beach.
			var ok := l > 0.11
			for c in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
				if landness((x + c.x) * TILE, (y + c.y) * TILE) <= 0.075:
					ok = false
			land[i] = 1 if ok else 0
			height[i] = l
	# Distance to coast (BFS in tiles) for land value.
	coast_dist.fill(99.0)
	var q: Array[int] = []
	for i in W * H:
		if land[i] == 0:
			coast_dist[i] = 0.0
			q.append(i)
	var head := 0
	while head < q.size():
		var i: int = q[head]
		head += 1
		var x := i % W
		var y := i / W
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var ny: int = y + d.y
			if not inside(nx, ny):
				continue
			var j := idx(nx, ny)
			if coast_dist[j] > coast_dist[i] + 1.0:
				coast_dist[j] = coast_dist[i] + 1.0
				q.append(j)
	# Woods: clumps of trees where a second noise is high.
	var wood := FastNoiseLite.new()
	wood.seed = noise.seed + 7
	wood.frequency = 0.02
	for i in W * H:
		if land[i] == 1:
			var w := wood.get_noise_2d(i % W, i / W)
			if w > 0.12:
				trees[i] = 3 if w > 0.35 else 2
			elif rng.randf() < 0.06:
				trees[i] = 1


# -------------------------------------------------------------------- helpers ---

func idx(x: int, y: int) -> int:
	return y * W + posmod(x, W)


func inside(x: int, y: int) -> bool:
	return y >= 0 and y < H and (Planet.on or (x >= 0 and x < W))


func is_road(x: int, y: int) -> bool:
	return inside(x, y) and road[idx(x, y)] == 1


func road_mask(x: int, y: int) -> int:
	## Bits: N (y-1) = 1, E (x+1) = 2, S (y+1) = 4, W (x-1) = 8.
	var m := 0
	if is_road(x, y - 1): m |= 1
	if is_road(x + 1, y): m |= 2
	if is_road(x, y + 1): m |= 4
	if is_road(x - 1, y): m |= 8
	return m


const DIRS := [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]  # rot 0..3 = S, E, N, W


func road_access_dir(x: int, y: int) -> int:
	## Rotation (0..3) toward the nearest road within 2 tiles, or -1.
	for dist in [1, 2]:
		for r in 4:
			var d: Vector2i = DIRS[r]
			if is_road(x + d.x * dist, y + d.y * dist):
				return r
	return -1


## Flat map metres of a cell's centre (Planet.warp() puts it on the ball).
func cell_center(x: int, y: int) -> Vector3:
	return Vector3((x + 0.5) * TILE, 0.0, (y + 0.5) * TILE)


## The cell under a world position (on a planet, a point on the ball; x comes back wrapped).
func world_to_cell(p: Vector3) -> Vector2i:
	if Planet.on:
		p = Planet.unwarp(p)
		return Vector2i(posmod(floori(p.x / TILE), W), floori(p.z / TILE))
	return Vector2i(floori(p.x / TILE), floori(p.z / TILE))


## The cell under a flat map point.
func flat_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(posmod(floori(p.x / TILE), W) if Planet.on else floori(p.x / TILE), floori(p.z / TILE))


func game_day() -> int:
	return int(minutes / 1440.0)


func time_of_day() -> float:
	## Hours, 0..24.
	return fmod(minutes, 1440.0) / 60.0


func spend(amount: float) -> bool:
	if funds < amount:
		message.emit("Not enough money ($%d needed)" % int(amount))
		return false
	funds -= amount
	return true


# ----------------------------------------------------------------- editing ---

func road_path(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	## L-shaped path: along the longer axis first.
	var out: Array[Vector2i] = []
	var dx := b.x - a.x
	var dy := b.y - a.y
	var corner := Vector2i(b.x, a.y) if absi(dx) >= absi(dy) else Vector2i(a.x, b.y)
	for seg in [[a, corner], [corner, b]]:
		var p: Vector2i = seg[0]
		var q: Vector2i = seg[1]
		var step := Vector2i(signi(q.x - p.x), signi(q.y - p.y))
		var c := p
		while true:
			if out.is_empty() or out[-1] != c:
				out.append(c)
			if c == q:
				break
			c += step
	return out


func road_cost(path: Array[Vector2i]) -> int:
	var n := 0
	for c in path:
		if inside(c.x, c.y) and land[idx(c.x, c.y)] == 1 and road[idx(c.x, c.y)] == 0 and not is_special_cell(idx(c.x, c.y)):
			n += 1
	return n * ROAD_COST


func place_road(path: Array[Vector2i]) -> bool:
	var cost := road_cost(path)
	if cost == 0 or not spend(cost):
		return false
	var r := Rect2i(path[0], Vector2i.ONE)
	for c in path:
		if not inside(c.x, c.y) or land[idx(c.x, c.y)] == 0 or is_special_cell(idx(c.x, c.y)):
			continue
		var i := idx(c.x, c.y)
		if bld[i] >= 0:
			remove_building(bld[i])
		road[i] = 1
		zone[i] = Zone.NONE
		trees[i] = 0
		r = r.expand(c)
	_zoned_dirty = true
	cells_changed.emit(r.grow(2))
	return true


func rect_cells(a: Vector2i, b: Vector2i) -> Rect2i:
	var p := Vector2i(mini(a.x, b.x), mini(a.y, b.y))
	var q := Vector2i(maxi(a.x, b.x), maxi(a.y, b.y))
	if Planet.on:
		# The short way round: b may sit across the seam from a.
		var dx := posmod(b.x - a.x + W / 2, W) - W / 2
		p.x = a.x + mini(dx, 0)
		q.x = a.x + maxi(dx, 0)
		p.y = clampi(p.y, 0, H - 1)
		q.y = clampi(q.y, 0, H - 1)
		return Rect2i(p, q - p + Vector2i.ONE)
	p = p.clamp(Vector2i.ZERO, Vector2i(W - 1, H - 1))
	q = q.clamp(Vector2i.ZERO, Vector2i(W - 1, H - 1))
	return Rect2i(p, q - p + Vector2i.ONE)


func zone_cost(r: Rect2i, z: int) -> int:
	var n := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if land[i] == 1 and road[i] == 0 and zone[i] != z and not is_special_cell(i):
				n += 1
	return n * ZONE_COST


func place_zone(r: Rect2i, z: int) -> bool:
	var cost := zone_cost(r, z)
	if cost == 0 or not spend(cost):
		return false
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if land[i] == 0 or road[i] == 1 or zone[i] == z or is_special_cell(i):
				continue
			if bld[i] >= 0:
				remove_building(bld[i])
			zone[i] = z
			trees[i] = 0
	_zoned_dirty = true
	cells_changed.emit(r.grow(1))
	return true


func bulldoze_cost(r: Rect2i) -> int:
	var n := 0
	var seen := {}
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if road[i] == 1:
				n += 1 + _props.get(i, []).size()
			elif bld[i] >= 0 and not seen.has(bld[i]):
				seen[bld[i]] = true
				n += 1
	return n * BULLDOZE_COST


func bulldoze(r: Rect2i) -> bool:
	var cost := bulldoze_cost(r)
	var any_zone := false
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if zone[idx(x, y)] != Zone.NONE:
				any_zone = true
	if cost == 0 and not any_zone:
		return false
	if cost > 0 and not spend(cost):
		return false
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if bld[i] >= 0:
				remove_building(bld[i])
			for pid in _props.get(i, []).duplicate():
				remove_building(pid)
			road[i] = 0
			zone[i] = Zone.NONE
	_zoned_dirty = true
	cells_changed.emit(r.grow(2))
	return true


# --------------------------------------------------------------- buildings ---

func capacity(b: Dictionary) -> int:
	if b.size == 2:
		return CAP_BIG[b.zone]
	return CAP[b.zone][b.stage]


## extra: more keys for the entry (kind, name, tags...), set before building_added fires.
func add_building(x: int, y: int, size: int, z: int, stage: int, rot: int, animate := true, extra := {}) -> int:
	var id := _next_id
	_next_id += 1
	var b := {
		"id": id, "x": x, "y": y, "size": size, "zone": z, "stage": stage, "rot": rot,
		"variant": rng.randi(), "seed": rng.randf(), "born": minutes,
		"tint": rng.randi() % 8, "tint2": rng.randi() % 8, "connected": true,
	}
	b.merge(extra, true)
	_insert(b)
	building_added.emit(id, animate)
	return id


func _insert(b: Dictionary) -> void:
	buildings[b.id] = b
	if b.size == 0:
		var i := idx(b.x, b.y)
		if not _props.has(i):
			_props[i] = []
		_props[i].append(b.id)
	for dy in b.size:
		for dx in b.size:
			bld[idx(b.x + dx, b.y + dy)] = b.id
	_count(b, 1)


func remove_building(id: int) -> void:
	if not buildings.has(id):
		return
	var b: Dictionary = buildings[id]
	for dy in b.size:
		for dx in b.size:
			bld[idx(b.x + dx, b.y + dy)] = -1
	if b.size == 0:
		var i := idx(b.x, b.y)
		_props[i].erase(id)
		if _props[i].is_empty():
			_props.erase(i)
	buildings.erase(id)
	_count(b, -1)
	building_removed.emit(id)
	cells_changed.emit(Rect2i(b.x, b.y, maxi(b.size, 1), maxi(b.size, 1)))


func _count(b: Dictionary, sign: int) -> void:
	var c := capacity(b) * sign
	match b.zone:
		Zone.RES: population += c
		Zone.COM: jobs_c += c
		Zone.IND: jobs_i += c


func _recount() -> void:
	var pop := 0
	var jc := 0
	var ji := 0
	for b in buildings.values():
		var c := capacity(b)
		match b.zone:
			Zone.RES: pop += c
			Zone.COM: jc += c
			Zone.IND: ji += c
	population = pop
	jobs_c = jc
	jobs_i = ji


func building_center(b: Dictionary) -> Vector3:
	if b.size == 0:
		# A street prop stands at the sidewalk's outer edge, facing the road (rot).
		var f: Vector2i = DIRS[b.rot]
		return cell_center(b.x, b.y) - Vector3(f.x, 0.0, f.y) * PROP_OFFSET
	return Vector3((b.x + b.size * 0.5) * TILE, 0.0, (b.y + b.size * 0.5) * TILE)


## Where the front door is: the model's door spot for catalog buildings, otherwise the middle
## of the side facing the road.
func door_position(b: Dictionary) -> Vector3:
	var c := building_center(b)
	if b.size == 0:
		return c
	var basis := Basis(Vector3.UP, b.rot * PI * 0.5)
	if b.has("kind"):
		var door: Dictionary = Catalog.get_def(b.kind).get("door", {})
		if not door.is_empty():
			return c + basis * Vector3(door.x, 0.0, door.z)
	return c + basis * Vector3(0.0, 0.0, b.size * TILE * 0.5 - 0.6)


# ---------------------------------------------------------- special buildings ---

const PROP_OFFSET := 5.6  # street props: metres from the road tile's centre line


## Ids of the street props (payphones) standing on a road tile.
func props_at(i: int) -> Array:
	return _props.get(i, [])


func is_special_cell(i: int) -> bool:
	return bld[i] >= 0 and buildings[bld[i]].has("kind")


## "" when the catalog building can go at cell (its top-left tile; the road tile for a street
## prop), otherwise the reason it can't. free skips the unlock check and the cost.
func can_place_special(kind: String, cell: Vector2i, free := false) -> String:
	var d := Catalog.get_def(kind)
	if d.is_empty():
		return "Unknown building"
	if d.placement == "line":
		return "Drag power lines like a road"
	if not free and progress != null and not progress.is_unlocked(kind):
		return Catalog.lock_text(kind) + " to unlock it"
	if d.unique and not specials_of(kind).is_empty():
		return "The city already has %s" % d.name
	if not inside(cell.x, cell.y):
		return "Off the map"
	if d.placement == "street":
		var i := idx(cell.x, cell.y)
		if road[i] == 0:
			return "It goes on a sidewalk: pick a road"
		if _props.has(i):
			return "There's already one on this block"
	else:
		var s: int = d.size
		for y in range(cell.y, cell.y + s):
			for x in range(cell.x, cell.x + s):
				if not inside(x, y) or land[idx(x, y)] == 0:
					return "Needs flat land"
				if road[idx(x, y)] == 1:
					return "Can't build on a road"
				if bld[idx(x, y)] >= 0:
					return "Bulldoze what's there first"
		if d.needs_road and front_side(cell, s) < 0:
			return "Needs a road alongside"
	if not free and funds < float(d.cost):
		return "Not enough money ($%s needed)" % Catalog.thousands(int(d.cost))
	return ""


## Buys and places a catalog building. Returns its id, or -1 after a message saying why not.
## rot is the side the front faces (DIRS); -1 picks the road side.
func place_special(kind: String, cell: Vector2i, rot := -1, free := false) -> int:
	var why := can_place_special(kind, cell, free)
	if why != "":
		message.emit(why)
		return -1
	var d := Catalog.get_def(kind)
	if not free and float(d.cost) > 0.0 and not spend(float(d.cost)):
		return -1
	var s: int = d.size
	if d.placement == "street":
		if rot < 0:
			rot = (sidewalk_side(cell) + 2) % 4
	else:
		for y in range(cell.y, cell.y + s):
			for x in range(cell.x, cell.x + s):
				zone[idx(x, y)] = Zone.NONE
				trees[idx(x, y)] = 0
		_zoned_dirty = true
		if rot < 0:
			rot = maxi(front_side(cell, s), 0)
	var id := add_building(cell.x, cell.y, s, Zone.NONE, 1, rot, animate_growth,
		{"kind": kind, "name": d.name, "tags": d.tags.duplicate()})
	cells_changed.emit(Rect2i(cell, Vector2i(maxi(s, 1), maxi(s, 1))).grow(1))
	return id


## Placed buildings carrying a tag (catalog buildings only; zone buildings have no tags).
func find_tagged(tag: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in buildings.values():
		if b.has("tags") and tag in b.tags:
			out.append(b)
	return out


func specials_of(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in buildings.values():
		if b.get("kind", "") == kind:
			out.append(b)
	return out


## The side of a size x size lot at cell with the most road along it, or -1 for none.
func front_side(cell: Vector2i, s: int) -> int:
	var best := -1
	var most := 0
	for r in 4:
		var n := 0
		for k in s:
			var p: Vector2i
			match r:
				0: p = Vector2i(cell.x + k, cell.y + s)
				1: p = Vector2i(cell.x + s, cell.y + k)
				2: p = Vector2i(cell.x + k, cell.y - 1)
				_: p = Vector2i(cell.x - 1, cell.y + k)
			if is_road(p.x, p.y):
				n += 1
		if n > most:
			most = n
			best = r
	return best


## The side of a road tile whose sidewalk borders a lot (where street props stand).
func sidewalk_side(c: Vector2i) -> int:
	for r in 4:
		var n: Vector2i = c + DIRS[r]
		if inside(n.x, n.y) and land[idx(n.x, n.y)] == 1 and road[idx(n.x, n.y)] == 0:
			return r
	return 0


# ---------------------------------------------------------------- save, load ---

const _INT_KEYS := ["id", "x", "y", "size", "zone", "stage", "rot", "variant", "tint", "tint2"]


## Everything needed to rebuild this city. Every key of every building entry is kept, so
## other threads' keys must be JSON-safe.
func to_dict() -> Dictionary:
	return {
		"seed": map_seed, "size": W, "h": H, "planet": Planet.on,
		"land": Marshalls.raw_to_base64(land),
		"height": Marshalls.raw_to_base64(height.to_byte_array()),
		"road": Marshalls.raw_to_base64(road),
		"zone": Marshalls.raw_to_base64(zone),
		"trees": Marshalls.raw_to_base64(trees),
		"buildings": buildings.values(),
		"next_id": _next_id,
		"funds": funds, "tax_rate": tax_rate, "minutes": minutes, "demand": demand.duplicate(),
		"last_income": last_income, "last_expense": last_expense,
		"rng": str(rng.state),
	}


## Restores a city from to_dict() (after a trip through JSON). Use a City made with the same
## seed, before anything listens to it: a load builds the scene around the restored city.
func from_dict(d: Dictionary) -> bool:
	var n := W * H
	if int(d.get("size", W)) != W or int(d.get("h", 80)) != H or bool(d.get("planet", false)) != Planet.on:
		return false
	var a := Marshalls.base64_to_raw(str(d.get("land", "")))
	if a.size() == n:
		land = a
	var h := Marshalls.base64_to_raw(str(d.get("height", ""))).to_float32_array()
	if h.size() == n:
		height = h
	a = Marshalls.base64_to_raw(str(d.get("road", "")))
	if a.size() == n:
		road = a
	a = Marshalls.base64_to_raw(str(d.get("zone", "")))
	if a.size() == n:
		zone = a
	a = Marshalls.base64_to_raw(str(d.get("trees", "")))
	if a.size() == n:
		trees = a
	buildings.clear()
	_props.clear()
	bld.fill(-1)
	var top := 0
	for e in d.get("buildings", []):
		if not e is Dictionary:
			continue
		var b: Dictionary = e.duplicate(true)
		if not b.has_all(_INT_KEYS):
			continue
		for k in _INT_KEYS:
			b[k] = int(b[k])
		b["seed"] = float(b.get("seed", 0.0))
		b["born"] = float(b.get("born", 0.0))
		b["connected"] = bool(b.get("connected", true))
		if b.has("kind"):
			var cd := Catalog.get_def(str(b.kind))
			if cd.is_empty():
				continue  # a building this version of the game doesn't know
			b["kind"] = str(b.kind)
			b["tags"] = cd.tags.duplicate()  # tags follow the catalog; the name is the building's own
			if not b.has("name"):
				b["name"] = cd.name
		if not _fits(b):
			continue
		_insert(b)
		top = maxi(top, b.id)
	_next_id = maxi(int(d.get("next_id", 1)), top + 1)
	funds = float(d.get("funds", funds))
	tax_rate = float(d.get("tax_rate", tax_rate))
	minutes = float(d.get("minutes", minutes))
	var dm: Array = d.get("demand", [])
	for i in mini(dm.size(), demand.size()):
		demand[i] = float(dm[i])
	last_income = float(d.get("last_income", 0.0))
	last_expense = float(d.get("last_expense", 0.0))
	if d.has("rng"):
		rng.state = str(d.rng).to_int()
	_zoned_dirty = true
	_recount()
	compute_traffic()
	compute_land_value()
	return true


func _fits(b: Dictionary) -> bool:
	if not inside(b.x, b.y) or buildings.has(b.id) or b.zone < 0 or b.zone > Zone.IND or b.rot < 0 or b.rot > 3:
		return false
	for dy in b.size:
		for dx in b.size:
			if not inside(b.x + dx, b.y + dy) or bld[idx(b.x + dx, b.y + dy)] >= 0:
				return false
	return true


# --------------------------------------------------------------- simulation ---

## Advance the clock. Returns true when at least one hour ticked.
func advance(real_seconds: float, speed: float) -> bool:
	var before := int(minutes / 60.0)
	minutes += real_seconds * MINUTES_PER_SECOND * speed
	var after := int(minutes / 60.0)
	for h in range(before + 1, after + 1):
		_hour_tick()
		if h % 24 == 0:
			_day_tick()
		elif h % 24 == 12:
			compute_land_value()
	return after > before


func _update_demand() -> void:
	var workers := population * 0.55
	var jobs := float(jobs_c + jobs_i)
	var tax_pen := (tax_rate - 0.09) * 6.0
	demand[Zone.RES] = clampf(((jobs * 1.1 + 80.0) - workers) / maxf(40.0, workers * 0.2) - tax_pen, -1.0, 1.0)
	var want_c := population * 0.24 + 15.0
	demand[Zone.COM] = clampf((want_c - jobs_c) / maxf(25.0, want_c * 0.3) - tax_pen, -1.0, 1.0)
	var want_i := population * 0.34 + 40.0
	demand[Zone.IND] = clampf((want_i - jobs_i) / maxf(30.0, want_i * 0.3) - tax_pen, -1.0, 1.0)


var _zoned_cache: Array[int] = []
var _zoned_dirty := true


func _zoned_cells() -> Array[int]:
	if _zoned_dirty:
		_zoned_cache.clear()
		for i in W * H:
			if zone[i] != Zone.NONE:
				_zoned_cache.append(i)
		_zoned_dirty = false
	return _zoned_cache


func mark_zones_dirty() -> void:
	_zoned_dirty = true


func _hour_tick() -> void:
	_update_demand()
	var cells := _zoned_cells()
	if cells.is_empty():
		return
	var tries := mini(cells.size(), 24 + cells.size() / 12)
	for t in tries:
		var i: int = cells[rng.randi() % cells.size()]
		_try_grow(i % W, i / W)


func _try_grow(x: int, y: int) -> void:
	var i := idx(x, y)
	var z := zone[i]
	if z == Zone.NONE or road[i] == 1:
		return
	var d: float = demand[z]
	if d <= 0.02:
		return
	if growth_check.is_valid() and not growth_check.call(x, y):
		return
	var rot := road_access_dir(x, y)
	if bld[i] < 0:
		if rot < 0:
			return
		if rng.randf() < 0.45 * d:
			add_building(x, y, 1, z, 1, rot, animate_growth)
		return
	var b: Dictionary = buildings[bld[i]]
	if b.stage >= 3 or b.size == 2:
		return
	if minutes - b.born < 60.0 * 30.0:  # at least 30 game hours old
		return
	var next: int = b.stage + 1
	var lv_ok: bool = z == Zone.IND or land_value[i] >= STAGE_LV[next]
	if population < STAGE_POP[next] or not lv_ok or not b.connected:
		return
	if rng.randf() > 0.18 * d:
		return
	if next == 3 and _try_merge(b):
		return
	remove_building(b.id)
	add_building(x, y, 1, z, next, rot if rot >= 0 else b.rot, animate_growth)


func _try_merge(b: Dictionary) -> bool:
	## Grow a 2x2 tower when the three neighbouring lots are the same zone at stage >= 2.
	if rng.randf() > 0.5:
		return false
	for off in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		var ox: int = b.x + off.x
		var oy: int = b.y + off.y
		var ok := true
		var ids := {}
		for dy in 2:
			for dx in 2:
				var cx := ox + dx
				var cy := oy + dy
				if not inside(cx, cy):
					ok = false
					break
				var j := idx(cx, cy)
				if zone[j] != b.zone or road[j] == 1 or bld[j] < 0:
					ok = false
					break
				var nb: Dictionary = buildings[bld[j]]
				if nb.size != 1 or nb.stage < 2:
					ok = false
					break
				ids[nb.id] = true
			if not ok:
				break
		if not ok:
			continue
		var rot := -1
		for dy in 2:
			for dx in 2:
				var r := road_access_dir(ox + dx, oy + dy)
				if r >= 0 and rot < 0:
					rot = r
		if rot < 0:
			continue
		for id in ids:
			remove_building(id)
		add_building(ox, oy, 2, b.zone, 3, rot, animate_growth)
		return true
	return false


func _day_tick() -> void:
	compute_traffic()
	var income := (population + (jobs_c + jobs_i) * 0.8) * tax_rate * 3.0
	var roads := 0
	for i in W * H:
		roads += road[i]
	var expense := roads * ROAD_UPKEEP
	# Catalog buildings: upkeep, or a day's takings for businesses (negative upkeep).
	for b in buildings.values():
		if b.has("kind"):
			var u := float(Catalog.get_def(b.kind).get("upkeep", 0))
			if u >= 0.0:
				expense += u
			else:
				income -= u
	funds += income - expense
	last_income = income
	last_expense = expense
	day_passed.emit()


## Commuter traffic: a multi-source BFS over roads from every job site gives each road
## cell its next step toward the nearest job. Each home puts its commuters on its road
## cell, and one pass back up the BFS order carries the flow along every route.
func compute_traffic() -> void:
	var n := W * H
	var flow := PackedFloat32Array()
	flow.resize(n)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-2)
	var cells_of := {}
	for b in buildings.values():
		cells_of[b.id] = _building_road_cells(b)
	var q := PackedInt32Array()
	for b in buildings.values():
		if b.zone == Zone.RES:
			continue
		for c in cells_of[b.id]:
			if parent[c] == -2:
				parent[c] = -1
				q.append(c)
	var head := 0
	while head < q.size():
		var c: int = q[head]
		head += 1
		var cx := c % W
		var cy := c / W
		for d in DIRS:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if is_road(nx, ny):
				var j := idx(nx, ny)
				if parent[j] == -2:
					parent[j] = c
					q.append(j)
	for b in buildings.values():
		if b.zone != Zone.RES:
			continue
		var start := -1
		for c in cells_of[b.id]:
			if parent[c] != -2:
				start = c
				break
		b.connected = start >= 0 or population < 60
		if start >= 0:
			flow[start] += capacity(b) * 0.55
	for k in range(q.size() - 1, -1, -1):
		var c: int = q[k]
		if parent[c] >= 0:
			flow[parent[c]] += flow[c]
	# Job sites are "connected" when their road network also reaches some home.
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var label := 0
	for s0 in n:
		if road[s0] == 0 or comp[s0] >= 0:
			continue
		var stack := PackedInt32Array([s0])
		comp[s0] = label
		while not stack.is_empty():
			var c: int = stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var cx := c % W
			var cy := c / W
			for d in DIRS:
				var nx: int = cx + d.x
				var ny: int = cy + d.y
				if is_road(nx, ny):
					var j := idx(nx, ny)
					if comp[j] < 0:
						comp[j] = label
						stack.append(j)
		label += 1
	var home_comps := {}
	for b in buildings.values():
		if b.zone == Zone.RES:
			for c in cells_of[b.id]:
				home_comps[comp[c]] = true
	for b in buildings.values():
		if b.zone == Zone.RES:
			continue
		var ok := population < 60
		for c in cells_of[b.id]:
			if home_comps.has(comp[c]):
				ok = true
				break
		b.connected = ok
	for i in n:
		traffic[i] = flow[i] / 900.0 if road[i] == 1 else 0.0


func _building_road_cells(b: Dictionary) -> PackedInt32Array:
	## Road cells 1 or 2 tiles straight out from each side of the lot.
	var out := PackedInt32Array()
	var s: int = b.size
	var bx: int = b.x
	var by: int = b.y
	for dist in [1, 2]:
		for k in s:
			for p in [Vector2i(bx + k, by - dist), Vector2i(bx + k, by + s - 1 + dist),
					Vector2i(bx - dist, by + k), Vector2i(bx + s - 1 + dist, by + k)]:
				if inside(p.x, p.y) and road[idx(p.x, p.y)] == 1:
					out.append(idx(p.x, p.y))
	return out


func compute_land_value() -> void:
	var n := W * H
	var com := PackedFloat32Array()
	var ind := PackedFloat32Array()
	var res := PackedFloat32Array()
	var green := PackedFloat32Array()
	var traf := PackedFloat32Array()
	for a in [com, ind, res, green, traf]:
		a.resize(n)
	for b in buildings.values():
		var w: float = float(b.stage) * (2.0 if b.size == 2 else 1.0)
		var i := idx(b.x, b.y)
		match b.zone:
			Zone.COM: com[i] += w
			Zone.IND: ind[i] += w
			Zone.RES: res[i] += w
	for i in n:
		green[i] = float(trees[i])
		traf[i] = minf(traffic[i], 2.0)
	com = _blur(com, 6)
	ind = _blur(ind, 5)
	res = _blur(res, 5)
	green = _blur(green, 3)
	traf = _blur(traf, 2)
	for i in n:
		if land[i] == 0:
			land_value[i] = 0.0
			continue
		var v := 0.28
		v += minf(com[i] * 0.9, 0.3)
		v += minf(res[i] * 0.5, 0.15)
		v += minf(green[i] * 0.5, 0.12)
		v += 0.18 * clampf(1.0 - (coast_dist[i] - 2.0) / 6.0, 0.0, 1.0)
		v -= minf(ind[i] * 1.6, 0.4) * (0.4 if zone[i] == Zone.IND else 1.0)
		v -= maxf(traf[i] - 0.6, 0.0) * 0.6
		land_value[i] = clampf(v, 0.0, 1.0)
	land_value_computed.emit()


func _blur(src: PackedFloat32Array, r: int) -> PackedFloat32Array:
	## Separable box blur (average over a (2r+1)^2 window). On a planet it wraps east to west.
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	var out := PackedFloat32Array()
	out.resize(src.size())
	var k := 1.0 / float(2 * r + 1)
	var wrap := Planet.on
	for y in H:
		var acc := 0.0
		for x in range(-r, r + 1):
			if wrap or (x >= 0 and x < W):
				acc += src[y * W + posmod(x, W)]
		for x in W:
			tmp[y * W + x] = acc * k
			var xo := x - r
			var xi := x + r + 1
			if wrap or xo >= 0:
				acc -= src[y * W + posmod(xo, W)]
			if wrap or xi < W:
				acc += src[y * W + posmod(xi, W)]
	for x in W:
		var acc := 0.0
		for y in range(-r, r + 1):
			if y >= 0 and y < H:
				acc += tmp[y * W + x]
		for y in H:
			out[y * W + x] = acc * k
			var yo := y - r
			var yi := y + r + 1
			if yo >= 0:
				acc -= tmp[yo * W + x]
			if yi < H:
				acc += tmp[yi * W + x]
	return out


## Fast-forward without animation (demo city, tests).
func simulate_hours(hours: int) -> void:
	for h in hours:
		minutes += 60.0
		_hour_tick()
		var hh := int(minutes / 60.0) % 24
		if hh == 0:
			_day_tick()
		elif hh == 12:
			compute_land_value()


# ------------------------------------------------------------------ starters ---

func center_cell() -> Vector2i:
	## A land cell near the middle of the island.
	# On the planet the town starts half way round from the x seam, so the seam (where
	# flat x wraps) is on the far side of the ball.
	var c := Vector2i(W / 2, H / 2 - 3) if Planet.on else Vector2i(W / 2, H / 2)
	for r in 20:
		for y in range(c.y - r, c.y + r + 1):
			for x in range(c.x - r, c.x + r + 1):
				if inside(x, y) and land[idx(x, y)] == 1:
					return Vector2i(x, y)
	return c


## Grid columns from a to b, the short way round on a planet.
func _dx(a: int, b: int) -> int:
	return posmod(b - a + W / 2, W) - W / 2 if Planet.on else b - a


func _free_road(x: int, y: int) -> void:
	if inside(x, y) and land[idx(x, y)] == 1:
		road[idx(x, y)] = 1
		trees[idx(x, y)] = 0


func build_starter() -> void:
	## A main avenue crossing the island with a short cross street: free starter roads.
	var c := center_cell()
	if Planet.on:
		c.y = H / 2  # the avenue is a highway all the way round the equator
	for x in W:
		_free_road(x, c.y)
	for y in range(c.y - 12, c.y + 13):
		_free_road(c.x, y)
	compute_land_value()
	cells_changed.emit(Rect2i(0, 0, W, H))


func build_demo(grow_hours := 24 * 45) -> void:
	## A pre-planned city for screenshots and showing off: a street grid of 2-deep blocks,
	## downtown commercial in the middle, homes around it, industry on the west side.
	var c := center_cell()
	if Planet.on:
		for x in W:
			_free_road(x, H / 2)  # the equator highway
	for y in H:
		for x in W:
			var dx := _dx(c.x, x)
			var dy := y - c.y
			if absi(dx) > 30 or absi(dy) > 27:
				continue
			if posmod(dx, 6) == 0 or posmod(dy, 3) == 0:
				_free_road(x, y)
	for y in H:
		for x in W:
			var i := idx(x, y)
			if land[i] == 0 or road[i] == 1:
				continue
			var dx := _dx(c.x, x)
			var dy := y - c.y
			if absi(dx) > 30 or absi(dy) > 27:
				continue
			var r := sqrt(dx * dx + dy * dy * 1.3)
			var z := Zone.RES
			if r < 11.0:
				z = Zone.COM
			elif dx < -17:
				z = Zone.IND
			elif r < 17.0 and rng.randf() < 0.3:
				z = Zone.COM
			zone[i] = z
			trees[i] = 0
	mark_zones_dirty()
	funds = 250000.0
	compute_land_value()
	var was := animate_growth
	animate_growth = false
	var steps := grow_hours
	for h in steps:
		minutes += 60.0
		_update_demand()
		var cells := _zoned_cells()
		for t in 120:
			var i: int = cells[rng.randi() % cells.size()]
			var bx := i % W
			var by := i / W
			# Downtown grows faster and taller during the demo.
			_try_grow(bx, by)
		if h % 24 == 0:
			_day_tick()
		elif h % 24 == 12:
			compute_land_value()
	animate_growth = was
	minutes = float(game_day()) * 1440.0 + 17.5 * 60.0
	cells_changed.emit(Rect2i(0, 0, W, H))
