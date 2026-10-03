class_name City
extends RefCounted
## The city's data and simulation. No rendering here, so it runs headless in tests.
##
## The map is a SIZE x SIZE grid of 12 m tiles. Grid x maps to world +X and grid y to
## world +Z. Each tile can hold a road, a zone, and (part of) one building.

signal cells_changed(rect: Rect2i)
signal building_added(id: int, animate: bool)
signal building_removed(id: int)
signal day_passed
signal message(text: String)

const SIZE := 80
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


func _init(seed_value: int = 1337) -> void:
	rng.seed = seed_value
	noise.seed = seed_value
	noise.frequency = 0.0035
	noise.fractal_octaves = 4
	var n := SIZE * SIZE
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
	var c := SIZE * TILE * 0.5
	var dx := (wx - c) / (c * 1.02)
	var dz := (wz - c) / (c * 0.96)
	var r := sqrt(dx * dx + dz * dz)
	var n := noise.get_noise_2d(wx, wz)
	return 1.0 - r + n * 0.32 - 0.04


func terrain_height(wx: float, wz: float) -> float:
	var l := landness(wx, wz)
	if l > 0.05:
		return 0.0
	# Beach slopes down to the sea floor.
	return clampf((l - 0.05) * 60.0, -14.0, 0.0)


func _make_island() -> void:
	for y in SIZE:
		for x in SIZE:
			var i := y * SIZE + x
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
	for i in SIZE * SIZE:
		if land[i] == 0:
			coast_dist[i] = 0.0
			q.append(i)
	var head := 0
	while head < q.size():
		var i: int = q[head]
		head += 1
		var x := i % SIZE
		var y := i / SIZE
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var ny: int = y + d.y
			if nx < 0 or ny < 0 or nx >= SIZE or ny >= SIZE:
				continue
			var j := ny * SIZE + nx
			if coast_dist[j] > coast_dist[i] + 1.0:
				coast_dist[j] = coast_dist[i] + 1.0
				q.append(j)
	# Woods: clumps of trees where a second noise is high.
	var wood := FastNoiseLite.new()
	wood.seed = noise.seed + 7
	wood.frequency = 0.02
	for i in SIZE * SIZE:
		if land[i] == 1:
			var w := wood.get_noise_2d(i % SIZE, i / SIZE)
			if w > 0.12:
				trees[i] = 3 if w > 0.35 else 2
			elif rng.randf() < 0.06:
				trees[i] = 1


# -------------------------------------------------------------------- helpers ---

func idx(x: int, y: int) -> int:
	return y * SIZE + x


func inside(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < SIZE and y < SIZE


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


func cell_center(x: int, y: int) -> Vector3:
	return Vector3((x + 0.5) * TILE, 0.0, (y + 0.5) * TILE)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / TILE), floori(p.z / TILE))


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
		if inside(c.x, c.y) and land[idx(c.x, c.y)] == 1 and road[idx(c.x, c.y)] == 0:
			n += 1
	return n * ROAD_COST


func place_road(path: Array[Vector2i]) -> bool:
	var cost := road_cost(path)
	if cost == 0 or not spend(cost):
		return false
	var r := Rect2i(path[0], Vector2i.ONE)
	for c in path:
		if not inside(c.x, c.y) or land[idx(c.x, c.y)] == 0:
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
	p = p.clamp(Vector2i.ZERO, Vector2i(SIZE - 1, SIZE - 1))
	q = q.clamp(Vector2i.ZERO, Vector2i(SIZE - 1, SIZE - 1))
	return Rect2i(p, q - p + Vector2i.ONE)


func zone_cost(r: Rect2i, z: int) -> int:
	var n := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if land[i] == 1 and road[i] == 0 and zone[i] != z:
				n += 1
	return n * ZONE_COST


func place_zone(r: Rect2i, z: int) -> bool:
	var cost := zone_cost(r, z)
	if cost == 0 or not spend(cost):
		return false
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var i := idx(x, y)
			if land[i] == 0 or road[i] == 1 or zone[i] == z:
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
				n += 1
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


func add_building(x: int, y: int, size: int, z: int, stage: int, rot: int, animate := true) -> int:
	var id := _next_id
	_next_id += 1
	var b := {
		"id": id, "x": x, "y": y, "size": size, "zone": z, "stage": stage, "rot": rot,
		"variant": rng.randi(), "seed": rng.randf(), "born": minutes,
		"tint": rng.randi() % 8, "tint2": rng.randi() % 8, "connected": true,
	}
	buildings[id] = b
	for dy in size:
		for dx in size:
			bld[idx(x + dx, y + dy)] = id
	_recount()
	building_added.emit(id, animate)
	return id


func remove_building(id: int) -> void:
	if not buildings.has(id):
		return
	var b: Dictionary = buildings[id]
	for dy in b.size:
		for dx in b.size:
			bld[idx(b.x + dx, b.y + dy)] = -1
	buildings.erase(id)
	_recount()
	building_removed.emit(id)
	cells_changed.emit(Rect2i(b.x, b.y, b.size, b.size))


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
	return Vector3((b.x + b.size * 0.5) * TILE, 0.0, (b.y + b.size * 0.5) * TILE)


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
		for i in SIZE * SIZE:
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
		_try_grow(i % SIZE, i / SIZE)


func _try_grow(x: int, y: int) -> void:
	var i := idx(x, y)
	var z := zone[i]
	if z == Zone.NONE or road[i] == 1:
		return
	var d: float = demand[z]
	if d <= 0.02:
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
	compute_land_value()
	var income := (population + (jobs_c + jobs_i) * 0.8) * tax_rate * 3.0
	var roads := 0
	for i in SIZE * SIZE:
		roads += road[i]
	var expense := roads * ROAD_UPKEEP
	funds += income - expense
	last_income = income
	last_expense = expense
	day_passed.emit()


## Commuter traffic: a multi-source BFS over roads from every job site, then each home
## walks its commuters down the BFS tree, adding flow to each road cell on the way.
func compute_traffic() -> void:
	var n := SIZE * SIZE
	var flow := PackedFloat32Array()
	flow.resize(n)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-2)
	var q: Array[int] = []
	var res_reach := PackedByteArray()
	res_reach.resize(n)
	for b in buildings.values():
		if b.zone == Zone.RES:
			continue
		for c in _building_road_cells(b):
			if parent[c] == -2:
				parent[c] = -1
				q.append(c)
	var head := 0
	while head < q.size():
		var c: int = q[head]
		head += 1
		var cx := c % SIZE
		var cy := c / SIZE
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
		var cells := _building_road_cells(b)
		var start := -1
		for c in cells:
			if parent[c] != -2:
				start = c
				break
		b.connected = start >= 0 or population < 60
		if start < 0:
			continue
		var commuters := capacity(b) * 0.55
		var c := start
		var guard := 0
		while c >= 0 and guard < 400:
			flow[c] += commuters
			res_reach[c] = 1
			c = parent[c]
			guard += 1
	# Job sites are "connected" when their road network also reaches some home.
	var comp := PackedInt32Array()
	comp.resize(n)
	comp.fill(-1)
	var label := 0
	for s0 in n:
		if road[s0] == 0 or comp[s0] >= 0:
			continue
		var stack: Array[int] = [s0]
		comp[s0] = label
		while not stack.is_empty():
			var c: int = stack.pop_back()
			for d in DIRS:
				var nx: int = c % SIZE + d.x
				var ny: int = c / SIZE + d.y
				if is_road(nx, ny) and comp[idx(nx, ny)] < 0:
					comp[idx(nx, ny)] = label
					stack.append(idx(nx, ny))
		label += 1
	var home_comps := {}
	for b in buildings.values():
		if b.zone == Zone.RES:
			for c in _building_road_cells(b):
				home_comps[comp[c]] = true
	for b in buildings.values():
		if b.zone == Zone.RES:
			continue
		var ok := population < 60
		for c in _building_road_cells(b):
			if home_comps.has(comp[c]):
				ok = true
				break
		b.connected = ok
	for i in n:
		traffic[i] = flow[i] / 900.0 if road[i] == 1 else 0.0


func _building_road_cells(b: Dictionary) -> Array[int]:
	var out: Array[int] = []
	for dy in range(-2, b.size + 2):
		for dx in range(-2, b.size + 2):
			var inside_x: bool = dx >= 0 and dx < b.size
			var inside_y: bool = dy >= 0 and dy < b.size
			if inside_x == inside_y:
				continue  # only straight-out cells, not corners or the lot itself
			var x: int = b.x + dx
			var y: int = b.y + dy
			if is_road(x, y):
				out.append(idx(x, y))
	return out


func compute_land_value() -> void:
	var n := SIZE * SIZE
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


func _blur(src: PackedFloat32Array, r: int) -> PackedFloat32Array:
	## Separable box blur (average over a (2r+1)^2 window).
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	var out := PackedFloat32Array()
	out.resize(src.size())
	var k := 1.0 / float(2 * r + 1)
	for y in SIZE:
		var acc := 0.0
		for x in range(-r, r + 1):
			if x >= 0 and x < SIZE:
				acc += src[y * SIZE + x]
		for x in SIZE:
			tmp[y * SIZE + x] = acc * k
			var xo := x - r
			var xi := x + r + 1
			if xo >= 0:
				acc -= src[y * SIZE + xo]
			if xi < SIZE:
				acc += src[y * SIZE + xi]
	for x in SIZE:
		var acc := 0.0
		for y in range(-r, r + 1):
			if y >= 0 and y < SIZE:
				acc += tmp[y * SIZE + x]
		for y in SIZE:
			out[y * SIZE + x] = acc * k
			var yo := y - r
			var yi := y + r + 1
			if yo >= 0:
				acc -= tmp[yo * SIZE + x]
			if yi < SIZE:
				acc += tmp[yi * SIZE + x]
	return out


## Fast-forward without animation (demo city, tests).
func simulate_hours(hours: int) -> void:
	for h in hours:
		minutes += 60.0
		_hour_tick()
		if int(minutes / 60.0) % 24 == 0:
			_day_tick()


# ------------------------------------------------------------------ starters ---

func center_cell() -> Vector2i:
	## A land cell near the middle of the island.
	var c := Vector2i(SIZE / 2, SIZE / 2)
	for r in 20:
		for y in range(c.y - r, c.y + r + 1):
			for x in range(c.x - r, c.x + r + 1):
				if inside(x, y) and land[idx(x, y)] == 1:
					return Vector2i(x, y)
	return c


func _free_road(x: int, y: int) -> void:
	if inside(x, y) and land[idx(x, y)] == 1:
		road[idx(x, y)] = 1
		trees[idx(x, y)] = 0


func build_starter() -> void:
	## A main avenue crossing the island with a short cross street: free starter roads.
	var c := center_cell()
	for x in SIZE:
		_free_road(x, c.y)
	for y in range(c.y - 12, c.y + 13):
		_free_road(c.x, y)
	compute_land_value()
	cells_changed.emit(Rect2i(0, 0, SIZE, SIZE))


func build_demo(grow_hours := 24 * 45) -> void:
	## A pre-planned city for screenshots and showing off: a street grid of 2-deep blocks,
	## downtown commercial in the middle, homes around it, industry on the west side.
	var c := center_cell()
	for y in SIZE:
		for x in SIZE:
			var dx := x - c.x
			var dy := y - c.y
			if absi(dx) > 30 or absi(dy) > 27:
				continue
			if posmod(dx, 6) == 0 or posmod(dy, 3) == 0:
				_free_road(x, y)
	for y in SIZE:
		for x in SIZE:
			var i := idx(x, y)
			if land[i] == 0 or road[i] == 1:
				continue
			var dx := x - c.x
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
			var bx := i % SIZE
			var by := i / SIZE
			# Downtown grows faster and taller during the demo.
			_try_grow(bx, by)
		if h % 24 == 0:
			_day_tick()
	animate_growth = was
	minutes = float(game_day()) * 1440.0 + 17.5 * 60.0
	cells_changed.emit(Rect2i(0, 0, SIZE, SIZE))
