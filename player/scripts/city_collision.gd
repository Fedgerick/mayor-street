class_name CityCollision
extends Node3D
## Physics for street level, generated from the City data: a ground plane, raised
## sidewalks, building boxes, invisible walls at the shoreline, and the street furniture
## CityView draws from the same data (street lamps, trees, palms, payphones and other
## street props). Built in 16x16-tile chunks and rebuilt when the city changes, so growth
## at street level stays solid. Parks and plazas stay open to walk into.
##
## Lamp and tree placement mirrors CityView._add_road and _rebuild_chunk (same hashes);
## player/test/collision_test.gd checks the two still agree.

const CHUNK := 16
const SIDEWALK_W := 2.25
const CURB_H := 0.17

const LAMP_X := 4.9      # CityView: lamp base offset across the road
## CityView.PIECES and rot_mask, copied: scripts run from `-s` compile before the Kit
## autoload exists, so player/ must not depend on CityView.
const PIECES := {"road_straight": 5, "road_corner": 3, "road_t": 7, "road_cross": 15, "road_end": 1, "road_single": 0}
const LAMP_Y := 0.17

var city: City
var _chunks := {}   # Vector2i -> StaticBody3D
var _dirty := {}
var _road_table := {}   # mask -> [piece, rot], as CityView builds it
static var _footprints := {}   # mesh name -> AABB of the parts above head height
var _lamp_shape: CylinderShape3D


func setup(c: City) -> void:
	city = c
	_lamp_shape = CylinderShape3D.new()
	_lamp_shape.radius = 0.14
	_lamp_shape.height = 6.0
	for piece in PIECES:
		var m: int = PIECES[piece]
		for k in 4:
			if not _road_table.has(m):
				_road_table[m] = [piece, k]
			m = _rot_mask(m)
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var gs := CollisionShape3D.new()
	gs.shape = WorldBoundaryShape3D.new()
	ground.add_child(gs)
	add_child(ground)
	city.cells_changed.connect(_on_cells_changed)
	city.building_added.connect(func(id: int, _a: bool): _mark_building(id))
	city.building_removed.connect(func(_id: int): pass)  # cells_changed follows a removal
	for cy in ceili(float(City.SIZE) / CHUNK):
		for cx in ceili(float(City.SIZE) / CHUNK):
			_dirty[Vector2i(cx, cy)] = true
	rebuild_dirty()


func _on_cells_changed(r: Rect2i) -> void:
	for cy in range(floori(float(r.position.y - 1) / CHUNK), floori(float(r.end.y) / CHUNK) + 1):
		for cx in range(floori(float(r.position.x - 1) / CHUNK), floori(float(r.end.x) / CHUNK) + 1):
			_dirty[Vector2i(cx, cy)] = true


func _mark_building(id: int) -> void:
	var b: Dictionary = city.buildings.get(id, {})
	if not b.is_empty():
		_on_cells_changed(Rect2i(b.x, b.y, b.size, b.size))


func _physics_process(_delta: float) -> void:
	if not _dirty.is_empty():
		rebuild_dirty()


func rebuild_dirty() -> void:
	for key in _dirty.keys():
		_rebuild(key)
	_dirty.clear()


func _rebuild(key: Vector2i) -> void:
	if _chunks.has(key):
		_chunks[key].queue_free()
		_chunks.erase(key)
	var x0: int = key.x * CHUNK
	var y0: int = key.y * CHUNK
	if x0 >= City.SIZE or y0 >= City.SIZE or x0 < 0 or y0 < 0:
		return
	var body := StaticBody3D.new()
	body.name = "Chunk_%d_%d" % [key.x, key.y]
	var seen := {}
	var T := City.TILE
	var h := T * 0.5
	for y in range(y0, mini(y0 + CHUNK, City.SIZE)):
		for x in range(x0, mini(x0 + CHUNK, City.SIZE)):
			var i := city.idx(x, y)
			var c := city.cell_center(x, y)
			if city.road[i] == 1:
				var m := city.road_mask(x, y)
				_add_lamp(body, x, y, c, m)
				for pid in city.props_at(i):
					_add_prop(body, city.buildings[pid])
				# Corner squares are always sidewalk; edges are sidewalk where no road continues.
				for sx in [-1, 1]:
					for sz in [-1, 1]:
						_box(body, c + Vector3(sx * (h - SIDEWALK_W * 0.5), CURB_H * 0.5, sz * (h - SIDEWALK_W * 0.5)), Vector3(SIDEWALK_W, CURB_H, SIDEWALK_W))
				var mid := T - SIDEWALK_W * 2.0
				if not (m & 1):
					_box(body, c + Vector3(0, CURB_H * 0.5, -h + SIDEWALK_W * 0.5), Vector3(mid, CURB_H, SIDEWALK_W))
				if not (m & 4):
					_box(body, c + Vector3(0, CURB_H * 0.5, h - SIDEWALK_W * 0.5), Vector3(mid, CURB_H, SIDEWALK_W))
				if not (m & 2):
					_box(body, c + Vector3(h - SIDEWALK_W * 0.5, CURB_H * 0.5, 0), Vector3(SIDEWALK_W, CURB_H, mid))
				if not (m & 8):
					_box(body, c + Vector3(-h + SIDEWALK_W * 0.5, CURB_H * 0.5, 0), Vector3(SIDEWALK_W, CURB_H, mid))
			elif city.land[i] == 0:
				# Shoreline wall where water meets land.
				var shore := false
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if city.inside(x + d.x, y + d.y) and city.land[city.idx(x + d.x, y + d.y)] == 1:
						_box(body, c + Vector3(0, 4.0, 0), Vector3(T, 8.0, T))
						shore = true
						break
				if not shore and city.height[i] > 0.055 and _hash(x, y, 40) < 0.35:
					# Beach palms on the sand ring.
					var p := c + Vector3(_hash(x, y, 41) * 8.0 - 4.0, 0, _hash(x, y, 42) * 8.0 - 4.0)
					if city.landness(p.x, p.z) > 0.06:
						_trunk(body, p, 0.9 + _hash(x, y, 44) * 0.5, 0.2)
			var bid: int = city.bld[i]
			if bid >= 0 and not seen.has(bid):
				seen[bid] = true
				var b: Dictionary = city.buildings[bid]
				_add_building(body, b)
				if b.zone == City.Zone.RES and b.stage == 1 and not b.has("kind"):
					var back := Basis(Vector3.UP, b.rot * PI * 0.5) * Vector3(_hash(b.x, b.y, 9) * 6.0 - 3.0, 0, -4.4)
					_add_tree(body, city.cell_center(b.x, b.y) + back, b.x, b.y, 5, false)
			elif bid < 0 and city.road[i] == 0 and city.land[i] == 1:
				for k in city.trees[i]:
					var off := Vector3(_hash(x, y, k) * 9.0 - 4.5, 0, _hash(x, y, k + 7) * 9.0 - 4.5)
					_add_tree(body, c + off, x, y, k, city.coast_dist[i] <= 2.0)
	if body.get_child_count() == 0:
		body.free()
		return
	add_child(body)
	_chunks[key] = body


func _add_building(body: StaticBody3D, b: Dictionary) -> void:
	var tags: Array = b.get("tags", [])
	if tags.has("park") or tags.has("plaza"):
		return   # open ground: walk (or drive) straight in
	var lot := AABB(Vector3(-City.TILE * 0.5 * b.size + 0.6, 0, -City.TILE * 0.5 * b.size + 0.6), Vector3(City.TILE * b.size - 1.2, 400.0, City.TILE * b.size - 1.2))
	var aabb := AABB(lot.position, Vector3(lot.size.x, 8.0, lot.size.z))
	var kit := get_node_or_null("/root/Kit")
	if kit:
		var nm: String = kit.special_mesh_name(b.kind, b.size, b.variant) if b.has("kind") else kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)
		var mesh: Mesh = kit.mesh(nm) if nm != "" else null
		if mesh:
			# Kit buildings include their lot paving, low walls and yards at ground level;
			# only what stands above head height blocks, kept inside the lot.
			aabb = footprint(nm, mesh).intersection(lot.grow(0.6))
			if aabb.size.x < 1.0 or aabb.size.z < 1.0:
				return
	var xf := Transform3D(Basis(Vector3.UP, b.rot * PI * 0.5), city.building_center(b))
	aabb = _clear_door(aabb, xf.affine_inverse() * city.door_position(b))
	var size := Vector3(aabb.size.x, maxf(aabb.end.y, 3.0), aabb.size.z)
	var center := aabb.get_center()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf * Transform3D(Basis.IDENTITY, Vector3(center.x, size.y * 0.5, center.z))
	body.add_child(cs)


## Pull the box face nearest the front door back behind it, so awnings, steps and signs
## in the footprint don't keep the player out of the doorway (interiors/ DoorTrigger
## stands just outside the door).
static func _clear_door(box: AABB, door: Vector3) -> AABB:
	const BACK := 0.15
	if door.x <= box.position.x or door.x >= box.end.x or door.z <= box.position.z or door.z >= box.end.z:
		return box
	var gaps := [door.x - box.position.x, box.end.x - door.x, door.z - box.position.z, box.end.z - door.z]
	var k := 0
	for i in 4:
		if gaps[i] < gaps[k]:
			k = i
	var lo := box.position
	var hi := box.end
	match k:
		0: lo.x = door.x + BACK
		1: hi.x = door.x - BACK
		2: lo.z = door.z + BACK
		3: hi.z = door.z - BACK
	return AABB(lo, hi - lo)


## The XZ extent of a mesh's parts above 1.2 m (walls, not paving), full height in Y.
static func footprint(nm: String, mesh: Mesh) -> AABB:
	if _footprints.has(nm):
		return _footprints[nm]
	var full := mesh.get_aabb()
	var lo := Vector3(INF, 0, INF)
	var hi := Vector3(-INF, 0, -INF)
	for s in mesh.get_surface_count():
		for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			if v.y > 1.2:
				lo = Vector3(minf(lo.x, v.x), 0, minf(lo.z, v.z))
				hi = Vector3(maxf(hi.x, v.x), 0, maxf(hi.z, v.z))
	var out := full
	if lo.x < hi.x and lo.z < hi.z:
		out = AABB(lo, Vector3(hi.x - lo.x, full.end.y, hi.z - lo.z))
	_footprints[nm] = out
	return out


func _add_prop(body: StaticBody3D, b: Dictionary) -> void:
	## Payphones and other street props: a box the size of the model.
	var kit := get_node_or_null("/root/Kit")
	var aabb := AABB(Vector3(-0.4, 0, -0.3), Vector3(0.8, 2.2, 0.6))
	if kit and b.has("kind"):
		var nm: String = kit.special_mesh_name(b.kind, b.size, b.variant)
		var mesh: Mesh = kit.mesh(nm) if nm != "" else null
		if mesh:
			aabb = mesh.get_aabb()
	if aabb.size.x > 4.0 or aabb.size.z > 4.0:
		aabb = AABB(Vector3(-0.4, 0, -0.3), Vector3(0.8, 2.2, 0.6))   # a borrowed placeholder block
	var xf := Transform3D(Basis(Vector3.UP, b.rot * PI * 0.5), city.building_center(b))
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(maxf(aabb.size.x, 0.3), maxf(aabb.size.y, 1.0), maxf(aabb.size.z, 0.3))
	cs.shape = bs
	var center := aabb.get_center()
	cs.transform = xf * Transform3D(Basis.IDENTITY, Vector3(center.x, CURB_H + bs.size.y * 0.5, center.z))
	body.add_child(cs)


## Where CityView stands this cell's street lamp, if it has one (base point).
func lamp_base(x: int, y: int, mask: int) -> Variant:
	var entry: Array = _road_table.get(mask, ["", 0])
	var piece: String = entry[0]
	var n := 0
	for bit in [1, 2, 4, 8]:
		if mask & bit:
			n += 1
	if n >= 3:
		return null
	var local := Vector3.ZERO
	if piece == "road_straight" or piece == "road_end":
		if not ((x + y) % 2 == 0 or piece == "road_end"):
			return null
		local = Vector3(LAMP_X if (x + y) % 4 == 0 else -LAMP_X, LAMP_Y, 0)
	elif piece == "road_corner":
		local = Vector3(-LAMP_X, LAMP_Y, LAMP_X)
	else:
		return null
	return city.cell_center(x, y) + Basis(Vector3.UP, entry[1] * PI * 0.5) * local


func _add_lamp(body: StaticBody3D, x: int, y: int, c: Vector3, mask: int) -> void:
	var base = lamp_base(x, y, mask)
	if base == null:
		return
	var cs := CollisionShape3D.new()
	cs.shape = _lamp_shape
	cs.position = base + Vector3(0, _lamp_shape.height * 0.5, 0)
	body.add_child(cs)


## Where CityView puts tree k of a cell and which model; mirrors CityView._add_tree.
func tree_at(p: Vector3, x: int, y: int, k: int, coastal: bool) -> Array:
	var h := _hash(x, y, k + 20)
	var nm := "tree_round_a" if h < 0.4 else ("tree_round_b" if h < 0.75 else "tree_pine")
	if coastal and h < 0.6:
		nm = "palm"
	return [nm, p, 0.8 + _hash(x, y, k + 30) * 0.55]


func _add_tree(body: StaticBody3D, p: Vector3, x: int, y: int, k: int, coastal: bool) -> void:
	var t := tree_at(p, x, y, k, coastal)
	_trunk(body, p, t[2], 0.28 if t[0] == "tree_pine" else 0.22)


func _trunk(body: StaticBody3D, p: Vector3, scale: float, radius: float) -> void:
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius * scale
	cyl.height = 3.0 * scale
	cs.shape = cyl
	cs.position = p + Vector3(0, cyl.height * 0.5, 0)
	body.add_child(cs)


static func _rot_mask(m: int) -> int:
	var r := 0
	if m & 1: r |= 8
	if m & 2: r |= 1
	if m & 4: r |= 2
	if m & 8: r |= 4
	return r


static func _hash(x: int, y: int, k: int) -> float:
	## CityView._cell_hash.
	var h := hash(Vector3i(x, y, k))
	return float(h & 0xffff) / 65535.0


func _box(body: StaticBody3D, pos: Vector3, size: Vector3) -> void:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.position = pos
	body.add_child(cs)


func is_land(p: Vector3) -> bool:
	var c := city.world_to_cell(p)
	return city.inside(c.x, c.y) and city.land[city.idx(c.x, c.y)] == 1
