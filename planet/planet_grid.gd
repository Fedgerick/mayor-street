class_name PlanetGrid
extends RefCounted
## The prototype's city: a Planet.W x Planet.H grid of tiles in a belt around the equator,
## wrapping east to west. Roads, zones, and buildings that grow along the roads. A cut-down
## stand-in for City (scripts/city.gd) so the planet can be tried before City itself goes
## W x H; same zone numbers, building fields and kit mesh names.

signal cells_changed(cells: Array)   # Array of Vector2i
signal building_added(id: int)
signal building_removed(id: int)

const TILE := Planet.TILE
const ZONE_KEYS := ["", "r", "c", "i"]
const DIRS := [Vector2i(0, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0)]  # rot 0..3 = S, E, N, W

var w := 0
var h := 0
var land := PackedByteArray()      # 1 = buildable
var road := PackedByteArray()
var zone := PackedByteArray()
var bld := PackedInt32Array()      # building id per cell, -1 none
var trees := PackedByteArray()
var buildings := {}                # id -> {x, y, size, zone, stage, rot, variant, tint, tint2, seed}
var population := 0
var jobs := 0
var funds := 250000.0
var rng := RandomNumberGenerator.new()
var noise := FastNoiseLite.new()
var _next_id := 1
var _grow_t := 0.0


func _init(seed_value := 4242) -> void:
	w = Planet.W
	h = Planet.H
	rng.seed = seed_value
	noise.seed = seed_value
	noise.frequency = 0.004
	var n := w * h
	land.resize(n)
	road.resize(n)
	zone.resize(n)
	bld.resize(n)
	trees.resize(n)
	bld.fill(-1)
	for y in h:
		for x in w:
			var i := idx(x, y)
			var c := cell_center(x, y)
			land[i] = 1 if landness(c.x, c.z) > 0.12 else 0
			if land[i] == 1 and noise.get_noise_2d(c.x * 3.0, c.z * 3.0) > 0.1:
				trees[i] = 1 + rng.randi() % 3


# ------------------------------------------------------------------- terrain ---

## Flat z of the south shore at flat x: a few tiles in from the belt's south edge.
func coast_z(x: float) -> float:
	var a := x / Planet.circumference() * TAU
	var wobble := noise.get_noise_2d(cos(a) * 300.0, sin(a) * 300.0)
	return (h - 2.6 + wobble * 2.2) * TILE


## 1 inland, 0.05 at the shoreline, negative out to sea. North of the belt stays land.
func landness(x: float, z: float) -> float:
	return clampf((coast_z(x) - z) / 260.0 + 0.05, -1.0, 1.0)


## Ground height (m above sea level) of the whole ball, at a flat point.
func ground_height(x: float, z: float) -> float:
	var l := landness(x, z)
	if l <= 0.05:
		return clampf((l - 0.05) * 60.0, -14.0, 0.0)
	if z >= 0.0:
		return 0.0
	# North of the belt: tundra rises into the ice cap.
	var a := x / Planet.circumference() * TAU
	var hill := noise.get_noise_3d(cos(a) * 400.0, sin(a) * 400.0, z * 2.0) * 0.5 + 0.5
	return smoothstep(0.0, -90.0, z) * (2.0 + hill * 5.0) + smoothstep(-120.0, -360.0, z) * 6.0


## 0 below the ice line .. 1 deep in the ice cap.
func ice(x: float, z: float) -> float:
	if z > 0.0:
		return 0.0
	var a := x / Planet.circumference() * TAU
	var n := noise.get_noise_2d(cos(a) * 500.0 + 31.0, sin(a) * 500.0) * 40.0
	return clampf((-z - 6.0 + n) / 140.0, 0.0, 1.0)


# --------------------------------------------------------------------- cells ---

func idx(x: int, y: int) -> int:
	return y * w + posmod(x, w)


func inside(_x: int, y: int) -> bool:
	return y >= 0 and y < h


func cell_center(x: int, y: int) -> Vector3:
	return Vector3((posmod(x, w) + 0.5) * TILE, 0.0, (y + 0.5) * TILE)


func world_to_cell(p: Vector3) -> Vector2i:
	## Flat map metres -> cell (x wrapped).
	return Vector2i(posmod(floori(p.x / TILE), w), floori(p.z / TILE))


func is_road(x: int, y: int) -> bool:
	return inside(x, y) and road[idx(x, y)] == 1


func road_mask(x: int, y: int) -> int:
	var m := 0
	if is_road(x, y - 1): m |= 1
	if is_road(x + 1, y): m |= 2
	if is_road(x, y + 1): m |= 4
	if is_road(x - 1, y): m |= 8
	return m


## Road cells from a to b: along the row first (the short way round), then the column.
func road_path(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dx := posmod(b.x - a.x + w / 2, w) - w / 2
	var sx := signi(dx)
	var x := a.x
	for k in absi(dx) + 1:
		out.append(Vector2i(posmod(x, w), a.y))
		x += sx
	var sy := signi(b.y - a.y)
	var y := a.y
	for k in absi(b.y - a.y):
		y += sy
		out.append(Vector2i(posmod(b.x, w), y))
	return out


## Cells of the rectangle between a and b (short way round east to west).
func rect_cells(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dx := posmod(b.x - a.x + w / 2, w) - w / 2
	var x0 := a.x if dx >= 0 else a.x + dx
	for yy in range(mini(a.y, b.y), maxi(a.y, b.y) + 1):
		for k in absi(dx) + 1:
			out.append(Vector2i(posmod(x0 + k, w), yy))
	return out


func place_road(cells: Array) -> int:
	var changed: Array = []
	for c in cells:
		if not inside(c.x, c.y):
			continue
		var i := idx(c.x, c.y)
		if land[i] == 0 or road[i] == 1:
			continue
		if bld[i] >= 0:
			remove_building(bld[i])
		road[i] = 1
		zone[i] = 0
		trees[i] = 0
		changed.append(c)
	_changed_with_neighbours(changed)
	return changed.size()


func place_zone(cells: Array, z: int) -> int:
	var changed: Array = []
	for c in cells:
		if not inside(c.x, c.y):
			continue
		var i := idx(c.x, c.y)
		if land[i] == 0 or road[i] == 1 or zone[i] == z:
			continue
		if bld[i] >= 0:
			remove_building(bld[i])
		zone[i] = z
		trees[i] = 0
		changed.append(c)
	if not changed.is_empty():
		cells_changed.emit(changed)
	return changed.size()


func bulldoze(cells: Array) -> int:
	var changed: Array = []
	for c in cells:
		if not inside(c.x, c.y):
			continue
		var i := idx(c.x, c.y)
		if bld[i] >= 0:
			remove_building(bld[i])
		if road[i] == 1 or zone[i] != 0 or trees[i] != 0:
			road[i] = 0
			zone[i] = 0
			trees[i] = 0
			changed.append(c)
	_changed_with_neighbours(changed)
	return changed.size()


func _changed_with_neighbours(changed: Array) -> void:
	if changed.is_empty():
		return
	var all := {}
	for c in changed:
		all[c] = true
		for d in DIRS:
			var n: Vector2i = c + d
			if inside(n.x, n.y):
				all[Vector2i(posmod(n.x, w), n.y)] = true
	cells_changed.emit(all.keys())


# ----------------------------------------------------------------- buildings ---

func building_center(b: Dictionary) -> Vector3:
	return Vector3((b.x + b.size * 0.5) * TILE, 0.0, (b.y + b.size * 0.5) * TILE)


func cells_of(b: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for yy in b.size:
		for xx in b.size:
			out.append(Vector2i(posmod(b.x + xx, w), b.y + yy))
	return out


func add_building(x: int, y: int, size: int, z: int, stage: int, rot: int) -> int:
	var id := _next_id
	_next_id += 1
	var b := {"id": id, "x": posmod(x, w), "y": y, "size": size, "zone": z, "stage": stage, "rot": rot,
		"variant": rng.randi() % 8, "tint": rng.randi() % 8, "tint2": rng.randi() % 8, "seed": rng.randf()}
	buildings[id] = b
	for c in cells_of(b):
		bld[idx(c.x, c.y)] = id
	_count(b, 1)
	building_added.emit(id)
	return id


func remove_building(id: int) -> void:
	if not buildings.has(id):
		return
	var b: Dictionary = buildings[id]
	for c in cells_of(b):
		bld[idx(c.x, c.y)] = -1
	_count(b, -1)
	buildings.erase(id)
	building_removed.emit(id)


func _count(b: Dictionary, sign: int) -> void:
	var cap: int = [[0, 0, 0, 0], [0, 6, 32, 140], [0, 6, 28, 110], [0, 10, 32, 70]][b.zone][b.stage] * b.size * b.size
	if b.zone == 1:
		population += cap * sign
	else:
		jobs += cap * sign


## Which way a lot at (x, y) can face a road (rot 0..3 = S, E, N, W), or -1. Lots one
## back from the street reach it through the lot in front.
func road_access_dir(x: int, y: int) -> int:
	for reach in [1, 2]:
		for r in 4:
			var d: Vector2i = DIRS[r]
			if is_road(x + d.x * reach, y + d.y * reach):
				return r
	return -1


## Grow the city: empty zoned lots by a road get houses, shops and works; they rise a
## stage at a time, and four tall ones in a block merge into a tower.
func advance(dt: float, rate := 1.0) -> void:
	_grow_t += dt * rate
	while _grow_t > 0.04:
		_grow_t -= 0.04
		_grow_step()


func _grow_step() -> void:
	var x := rng.randi() % w
	var y := rng.randi() % h
	var i := idx(x, y)
	var z := zone[i]
	if z == 0 or road[i] == 1:
		return
	if bld[i] < 0:
		var r := road_access_dir(x, y)
		if r >= 0:
			add_building(x, y, 1, z, 1, r)
		return
	var b: Dictionary = buildings[bld[i]]
	if b.size != 1 or b.stage >= 3:
		return
	# Rise a stage when the block around is built up.
	var built := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
		var n: Vector2i = Vector2i(x, y) + d
		if inside(n.x, n.y) and (bld[idx(n.x, n.y)] >= 0 or road[idx(n.x, n.y)] == 1):
			built += 1
	if built < 5 + b.stage or rng.randf() > 0.25:
		return
	if b.stage == 2 and _try_merge(b):
		return
	var keep: Dictionary = b.duplicate()
	remove_building(b.id)
	add_building(keep.x, keep.y, 1, keep.zone, keep.stage + 1, keep.rot)


func _try_merge(b: Dictionary) -> bool:
	## Four stage-2+ lots of one zone in a 2x2 block become one stage-3 tower.
	for off in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		var o: Vector2i = Vector2i(b.x, b.y) + off
		if o.y < 0 or o.y + 1 >= h:
			continue
		var ok := true
		var ids := []
		for yy in 2:
			for xx in 2:
				var j := idx(o.x + xx, o.y + yy)
				var id := bld[j]
				# Empty lots of the zone join in; built ones must be tall enough already.
				if zone[j] != b.zone or road[j] == 1 or (id >= 0 and (buildings[id].size != 1 or buildings[id].stage < 2)):
					ok = false
				if id >= 0:
					ids.append(id)
		if not ok or ids.size() < 2:
			continue
		var rot := -1
		for r in 4:
			for k in 2:
				var c: Vector2i = [o + Vector2i(k, 2), o + Vector2i(2, k), o + Vector2i(k, -1), o + Vector2i(-1, k)][r]
				if is_road(c.x, c.y):
					rot = r
		if rot < 0:
			continue
		for id in ids:
			remove_building(id)
		add_building(o.x, o.y, 2, b.zone, 3, rot)
		return true
	return false


# ------------------------------------------------------------------- starter ---

## Two towns and a highway round the equator, already grown, so there is something to
## walk and drive around in straight away.
func build_starter() -> void:
	var eq := h / 2
	var ring: Array[Vector2i] = []
	for x in w:
		ring.append(Vector2i(x, eq))
	place_road(ring)
	_town(0, 15, h / 2 - 15, h / 2 + 12)
	_town(w / 2, 10, h / 2 - 10, h / 2 + 8)
	_town(w / 4, 6, h / 2 - 12, h / 2 - 2)
	for k in 60000:
		_grow_step()


func _town(cx: int, half: int, y0: int, y1: int) -> void:
	for x in range(cx - half, cx + half + 1):
		for y in range(y0, y1 + 1):
			var on_col := posmod(x - cx, 5) == 0
			var on_row := posmod(y - y0, 5) == 0
			if on_col or on_row:
				place_road([Vector2i(posmod(x, w), y)])
	for x in range(cx - half, cx + half + 1):
		for y in range(y0, y1 + 1):
			var i := idx(x, y)
			if road[i] == 1 or land[i] == 0:
				continue
			var d := maxf(absf(x - cx) / float(half), absf(y - (y0 + y1) * 0.5) / float((y1 - y0) * 0.5))
			var z := 2 if d < 0.35 else (1 if d < 0.8 else 3)
			if road_access_dir(x, y) >= 0 or d < 0.8:
				place_zone([Vector2i(posmod(x, w), y)], z)
