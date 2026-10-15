class_name PlanetView
extends Node3D
## Draws a PlanetGrid on the ball: sphere terrain with the ice cap and the polar sea, and
## chunked MultiMeshes of kit roads, lamps, buildings and trees. Each instance is laid out
## on the flat map exactly as CityView does it, then stood up on the ball by
## Planet.warp_xform. Chunks behind the horizon are hidden.
##
## Also builds the collision: the terrain as one trimesh and a box per building.

const CHUNK := 4
const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")
const N := 1
const E := 2
const S := 4
const W := 8
const PIECES := {"road_straight": 5, "road_corner": 3, "road_t": 7, "road_cross": 15, "road_end": 1, "road_single": 0}
const TALLEST := 90.0  # metres: a chunk stays drawn while anything this tall could peek over the horizon

var grid: PlanetGrid
var chunks := {}       # Vector2i -> Node3D
var bodies := {}       # Vector2i -> StaticBody3D (building boxes)
var dirty := {}
var road_table := {}
var city_img: Image
var city_tex: ImageTexture
var lamp_img: Image
var lamp_tex: ImageTexture
var preview_img: Image
var preview_tex: ImageTexture
var terrain_body: StaticBody3D
var _map_dirty := true
var _cull_t := 0.0


func setup(g: PlanetGrid) -> void:
	grid = g
	grid.cells_changed.connect(_on_cells_changed)
	grid.building_added.connect(func(id): _mark_building(id))
	grid.building_removed.connect(func(_id): pass)  # its cells are marked by the add or the bulldoze
	for piece in PIECES:
		var m: int = PIECES[piece]
		for k in 4:
			if not road_table.has(m):
				road_table[m] = [piece, k]
			m = CityView.rot_mask(m)
	_make_textures()
	_build_terrain()
	for cy in ceili(float(grid.h) / CHUNK):
		for cx in ceili(float(grid.w) / CHUNK):
			dirty[Vector2i(cx, cy)] = true


func _make_textures() -> void:
	city_img = Image.create_empty(grid.w, grid.h, false, Image.FORMAT_RGBA8)
	city_tex = ImageTexture.create_from_image(city_img)
	lamp_img = Image.create_empty(grid.w, grid.h, false, Image.FORMAT_RGBA8)
	lamp_tex = ImageTexture.create_from_image(lamp_img)
	preview_img = Image.create_empty(grid.w, grid.h, false, Image.FORMAT_R8)
	preview_tex = ImageTexture.create_from_image(preview_img)
	RenderingServer.global_shader_parameter_set("city_map", city_tex)
	RenderingServer.global_shader_parameter_set("lamp_map", lamp_tex)
	RenderingServer.global_shader_parameter_set("preview_map", preview_tex)
	RenderingServer.global_shader_parameter_set("map_cells", float(grid.w))
	RenderingServer.global_shader_parameter_set("tile_size", Planet.TILE)


func refresh_map() -> void:
	var n := grid.w * grid.h
	var data := PackedByteArray()
	data.resize(n * 4)
	for i in n:
		data[i * 4] = 255 if grid.road[i] == 1 else 0
		data[i * 4 + 1] = grid.zone[i] * 64 + (32 if grid.bld[i] >= 0 else 0)
		data[i * 4 + 2] = 0
		data[i * 4 + 3] = 128
	city_img.set_data(grid.w, grid.h, false, Image.FORMAT_RGBA8, data)
	city_tex.update(city_img)
	_map_dirty = false


func set_preview(cells: Array, color: Color) -> void:
	preview_img.fill(Color(0, 0, 0))
	for c in cells:
		if grid.inside(c.x, c.y):
			preview_img.set_pixel(posmod(c.x, grid.w), c.y, Color(1, 0, 0))
	preview_tex.update(preview_img)
	RenderingServer.global_shader_parameter_set("preview_color", color)


# ------------------------------------------------------------------ terrain ---

func _build_terrain() -> void:
	terrain_body = PlanetGround.build(self, grid.h, grid.ground_height, grid.landness, grid.ice)


# ------------------------------------------------------------------- chunks ---

func _on_cells_changed(cells: Array) -> void:
	for c in cells:
		dirty[Vector2i(posmod(c.x, grid.w) / CHUNK, c.y / CHUNK)] = true
	_map_dirty = true


func _mark_building(id: int) -> void:
	var b: Dictionary = grid.buildings[id]
	for c in grid.cells_of(b):
		dirty[Vector2i(c.x / CHUNK, c.y / CHUNK)] = true
	_map_dirty = true


func _process(delta: float) -> void:
	var n := 0
	for key in dirty.keys():
		_rebuild_chunk(key)
		dirty.erase(key)
		n += 1
		if n >= 24:
			break
	if _map_dirty:
		refresh_map()
		lamp_tex.update(lamp_img)
	_cull_t -= delta
	if _cull_t <= 0.0:
		_cull_t = 0.1
		_cull()


func flush() -> void:
	for key in dirty.keys():
		_rebuild_chunk(key)
	dirty.clear()
	refresh_map()
	lamp_tex.update(lamp_img)
	_cull()


## Hide the chunks behind the horizon: on a ball most of the city is out of sight.
func _cull() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	for key in chunks:
		var node: Node3D = chunks[key]
		var c := Vector3((key.x * CHUNK + CHUNK * 0.5) * Planet.TILE, 0.0, (key.y * CHUNK + CHUNK * 0.5) * Planet.TILE)
		node.visible = Planet.above_horizon(eye, Planet.warp(c), TALLEST + CHUNK * Planet.TILE * 0.7)


func visible_chunks() -> int:
	var n := 0
	for key in chunks:
		if chunks[key].visible:
			n += 1
	return n


func _hash(x: int, y: int, k: int) -> float:
	return float(hash(Vector3i(x, y, k)) & 0xffff) / 65535.0


func _rebuild_chunk(key: Vector2i) -> void:
	if chunks.has(key):
		chunks[key].queue_free()
	if bodies.has(key):
		bodies[key].queue_free()
		bodies.erase(key)
	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [key.x, key.y]
	add_child(node)
	chunks[key] = node
	var groups := {}
	var boxes := []
	for y in range(key.y * CHUNK, mini(key.y * CHUNK + CHUNK, grid.h)):
		for x in range(key.x * CHUNK, mini(key.x * CHUNK + CHUNK, grid.w)):
			var i := grid.idx(x, y)
			lamp_img.set_pixel(x, y, Color(0, 0, 0, 0))
			var center := grid.cell_center(x, y)
			if grid.road[i] == 1:
				_add_road(groups, x, y, center)
				continue
			var bid := grid.bld[i]
			if bid >= 0:
				var b: Dictionary = grid.buildings[bid]
				if b.x == x and b.y == y:
					var nm := Kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)
					var mesh := Kit.mesh(nm)
					if mesh != null:
						# Big lots sink a little so their corners don't float over the curve.
						var sink: float = (b.size * Planet.TILE * 0.5) ** 2 / (2.0 * Planet.R)
						var xf := Transform3D(Basis(Vector3.UP, b.rot * PI * 0.5), grid.building_center(b) - Vector3(0, sink, 0))
						_push(groups, nm, xf, _wall_tint(b), _accent(b), true)
						var aabb := mesh.get_aabb()
						boxes.append([xf, aabb])
				continue
			if grid.land[i] == 1:
				for k in grid.trees[i]:
					var off := Vector3(_hash(x, y, k) * 9.0 - 4.5, 0, _hash(x, y, k + 7) * 9.0 - 4.5)
					_add_tree(groups, center + off, x, y, k)
	for nm in groups:
		var g: Array = groups[nm]
		var mesh := Kit.mesh(nm)
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = g[0].size()
		for k in g[0].size():
			mm.set_instance_transform(k, Planet.warp_xform(g[0][k]))
			mm.set_instance_color(k, g[1][k])
			mm.set_instance_custom_data(k, g[2][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g[3] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mmi)
	if not boxes.is_empty():
		var body := StaticBody3D.new()
		body.name = "Bodies_%d_%d" % [key.x, key.y]
		for bx in boxes:
			var aabb: AABB = bx[1]
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = aabb.size * Vector3(0.96, 1.0, 0.96)
			cs.shape = shape
			var local := Transform3D(Basis.IDENTITY, aabb.get_center())
			var wx := Planet.warp_xform(bx[0])
			cs.transform = Transform3D(wx.basis.orthonormalized(), wx.origin) * local
			body.add_child(cs)
		add_child(body)
		bodies[key] = body
	_map_dirty = true


func _wall_tint(b: Dictionary) -> Color:
	var pal: Array = Kit.WALLS[b.zone]
	var c: Color = pal[b.tint % pal.size()]
	var s: float = b.seed
	var v := 0.9 + 0.2 * fposmod(s * 7.31, 1.0)
	return Color(c.r * v, c.g * v, c.b * v)


func _accent(b: Dictionary) -> Color:
	var c: Color = Kit.ACCENTS[b.tint2 % Kit.ACCENTS.size()]
	c.a = b.seed
	return c


func _push(groups: Dictionary, nm: String, xf: Transform3D, col: Color, custom: Color, shadow: bool) -> void:
	if not groups.has(nm):
		groups[nm] = [[], [], [], shadow]
	groups[nm][0].append(xf)
	groups[nm][1].append(col)
	groups[nm][2].append(custom)


func _add_tree(groups: Dictionary, p: Vector3, x: int, y: int, k: int) -> void:
	var h := _hash(x, y, k + 20)
	var nm := "tree_round_a" if h < 0.4 else ("tree_round_b" if h < 0.75 else "tree_pine")
	if p.z > (grid.h - 5) * Planet.TILE and h < 0.6:
		nm = "palm"
	if p.z < 3 * Planet.TILE:
		nm = "tree_pine"
	var s := 0.8 + _hash(x, y, k + 30) * 0.55
	var basis := Basis(Vector3.UP, _hash(x, y, k + 40) * TAU).scaled(Vector3.ONE * s)
	var tint: Color = Kit.LEAF_TINTS[int(_hash(x, y, k + 50) * 5.99)]
	_push(groups, nm, Transform3D(basis, p), tint, Color(0, 0, 0, 0), true)


func _add_road(groups: Dictionary, x: int, y: int, center: Vector3) -> void:
	var mask := grid.road_mask(x, y)
	var entry: Array = road_table[mask]
	var piece: String = entry[0]
	var basis := Basis(Vector3.UP, entry[1] * PI * 0.5)
	_push(groups, piece, Transform3D(basis, center), Color.WHITE, Color(0, 0, 0, 0), false)
	var neighbours := 0
	for bit in [N, E, S, W]:
		if mask & bit:
			neighbours += 1
	if neighbours >= 3:
		return
	var local := Vector3.ZERO
	var place := false
	if piece == "road_straight" or piece == "road_end":
		place = (x + y) % 2 == 0 or piece == "road_end"
		local = Vector3(4.9 if (x + y) % 4 == 0 else -4.9, 0.17, 0)
	elif piece == "road_corner":
		place = true
		local = Vector3(-4.9, 0.17, 4.9)
	if not place:
		return
	var face := 0.0 if local.x > 0.0 else PI
	if piece == "road_corner":
		face = -PI * 0.25 + PI
	var lb := basis * Basis(Vector3.UP, face)
	var base := center + basis * local
	_push(groups, "street_lamp", Transform3D(lb, base), Color.WHITE, Color(0, 0, 0, 0), true)
	var head := base + lb * Vector3(-1.4, 6.0, 0.0)
	var hc := grid.world_to_cell(head)
	if grid.inside(hc.x, hc.y):
		var fx := fposmod(head.x / Planet.TILE, 1.0)
		lamp_img.set_pixel(hc.x, hc.y, Color(fx, head.z / Planet.TILE - hc.y, 1.0, 1.0))
