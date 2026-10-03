class_name CityCollision
extends Node3D
## Physics for street level, generated from the City data: a ground plane, raised
## sidewalks, building boxes and invisible walls at the shoreline. Built in 16x16-tile
## chunks and rebuilt when the city changes, so growth at street level stays solid.

const CHUNK := 16
const SIDEWALK_W := 2.25
const CURB_H := 0.17

var city: City
var _chunks := {}   # Vector2i -> StaticBody3D
var _dirty := {}


func setup(c: City) -> void:
	city = c
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
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if city.inside(x + d.x, y + d.y) and city.land[city.idx(x + d.x, y + d.y)] == 1:
						_box(body, c + Vector3(0, 4.0, 0), Vector3(T, 8.0, T))
						break
			var bid: int = city.bld[i]
			if bid >= 0 and not seen.has(bid):
				seen[bid] = true
				_add_building(body, city.buildings[bid])
	if body.get_child_count() == 0:
		body.free()
		return
	add_child(body)
	_chunks[key] = body


func _add_building(body: StaticBody3D, b: Dictionary) -> void:
	var aabb := AABB(Vector3(-City.TILE * 0.5 * b.size + 0.6, 0, -City.TILE * 0.5 * b.size + 0.6), Vector3(City.TILE * b.size - 1.2, 8.0, City.TILE * b.size - 1.2))
	var kit := get_node_or_null("/root/Kit")
	if kit:
		var nm: String = kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)
		var mesh: Mesh = kit.mesh(nm) if nm != "" else null
		if mesh:
			aabb = mesh.get_aabb()
	# Kit buildings include their lot paving at ground level; trim the footprint a little
	# so the yard stays walkable and only the walls block.
	var inset := 0.8
	var size := Vector3(maxf(aabb.size.x - inset * 2.0, 1.0), aabb.size.y, maxf(aabb.size.z - inset * 2.0, 1.0))
	var center := aabb.get_center()
	var xf := Transform3D(Basis(Vector3.UP, b.rot * PI * 0.5), city.building_center(b))
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = xf * Transform3D(Basis.IDENTITY, Vector3(center.x, size.y * 0.5, center.z))
	body.add_child(cs)


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
