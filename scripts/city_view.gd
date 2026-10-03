class_name CityView
extends Node3D
## Draws the City: terrain, sea, and chunked MultiMeshes for roads, buildings, lamps
## and trees. Also owns the data textures the shaders read (zones, traffic, lamps).

const CHUNK := 16
const TERRAIN_MARGIN := 640.0
const TERRAIN_STEP := 6.0
const GROW_TIME := 1.4

const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")

const N := 1
const E := 2
const S := 4
const W := 8
const PIECES := {"road_straight": 5, "road_corner": 3, "road_t": 7, "road_cross": 15, "road_end": 1, "road_single": 0}

var city: City
var chunks := {}        # Vector2i -> Node3D
var dirty := {}         # Vector2i -> true
var growing := {}       # building id -> {node, t}
var road_table := {}    # mask -> [piece, rot]

var city_img: Image
var city_tex: ImageTexture
var lamp_img: Image
var lamp_tex: ImageTexture
var preview_img: Image
var preview_tex: ImageTexture
var lamp_positions := {}  # Vector2i chunk -> Array[Vector3] (lamp heads, used by real lights)
var _map_dirty := false


func setup(c: City) -> void:
	city = c
	city.cells_changed.connect(_on_cells_changed)
	city.building_added.connect(_on_building_added)
	city.building_removed.connect(_on_building_removed)
	city.day_passed.connect(func(): _map_dirty = true)
	_build_road_table()
	_make_textures()
	_build_terrain()
	_build_water()
	for cy in ceili(float(City.SIZE) / CHUNK):
		for cx in ceili(float(City.SIZE) / CHUNK):
			dirty[Vector2i(cx, cy)] = true
	refresh_map()


# ---------------------------------------------------------------- textures ---

func _make_textures() -> void:
	var n := City.SIZE
	city_img = Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	city_tex = ImageTexture.create_from_image(city_img)
	lamp_img = Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	lamp_tex = ImageTexture.create_from_image(lamp_img)
	preview_img = Image.create_empty(n, n, false, Image.FORMAT_R8)
	preview_tex = ImageTexture.create_from_image(preview_img)
	RenderingServer.global_shader_parameter_set("city_map", city_tex)
	RenderingServer.global_shader_parameter_set("lamp_map", lamp_tex)
	RenderingServer.global_shader_parameter_set("preview_map", preview_tex)
	RenderingServer.global_shader_parameter_set("map_cells", float(n))
	RenderingServer.global_shader_parameter_set("tile_size", City.TILE)


func refresh_map() -> void:
	var n := City.SIZE
	var data := PackedByteArray()
	data.resize(n * n * 4)
	for i in n * n:
		var built := 32 if city.bld[i] >= 0 else 0
		data[i * 4] = 255 if city.road[i] == 1 else 0
		data[i * 4 + 1] = city.zone[i] * 64 + built
		data[i * 4 + 2] = clampi(int(city.traffic[i] * 127.0), 0, 255)
		data[i * 4 + 3] = clampi(int(city.land_value[i] * 255.0), 0, 255)
	city_img.set_data(n, n, false, Image.FORMAT_RGBA8, data)
	city_tex.update(city_img)
	_map_dirty = false


func set_preview(cells: Array, color: Color) -> void:
	preview_img.fill(Color(0, 0, 0))
	for c in cells:
		if city.inside(c.x, c.y):
			preview_img.set_pixel(c.x, c.y, Color(1, 0, 0))
	preview_tex.update(preview_img)
	RenderingServer.global_shader_parameter_set("preview_color", color)


# ----------------------------------------------------------------- terrain ---

func _build_terrain() -> void:
	var size := City.SIZE * City.TILE
	var x0 := -TERRAIN_MARGIN
	var steps := int((size + TERRAIN_MARGIN * 2.0) / TERRAIN_STEP) + 1
	var hs := PackedFloat32Array()
	var ls := PackedFloat32Array()
	hs.resize(steps * steps)
	ls.resize(steps * steps)
	for j in steps:
		for i in steps:
			var wx := x0 + i * TERRAIN_STEP
			var wz := x0 + j * TERRAIN_STEP
			var l := city.landness(wx, wz)
			ls[j * steps + i] = l
			hs[j * steps + i] = 0.0 if l > 0.05 else clampf((l - 0.05) * 60.0, -14.0, 0.0)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(steps * steps)
	norms.resize(steps * steps)
	cols.resize(steps * steps)
	for j in steps:
		for i in steps:
			var k := j * steps + i
			verts[k] = Vector3(x0 + i * TERRAIN_STEP, hs[k], x0 + j * TERRAIN_STEP)
			var hl := hs[j * steps + maxi(i - 1, 0)]
			var hr := hs[j * steps + mini(i + 1, steps - 1)]
			var hd := hs[maxi(j - 1, 0) * steps + i]
			var hu := hs[mini(j + 1, steps - 1) * steps + i]
			norms[k] = Vector3(hl - hr, 2.0 * TERRAIN_STEP, hd - hu).normalized()
			cols[k] = Color(clampf(ls[k], 0.0, 1.0), 0, 0)
	var idx := PackedInt32Array()
	idx.resize((steps - 1) * (steps - 1) * 6)
	var t := 0
	for j in steps - 1:
		for i in steps - 1:
			var a := j * steps + i
			var b := a + 1
			var c := a + steps
			var d := c + 1
			idx[t] = a; idx[t + 1] = b; idx[t + 2] = c
			idx[t + 3] = b; idx[t + 4] = d; idx[t + 5] = c
			t += 6
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := ShaderMaterial.new()
	mat.shader = TERRAIN_SHADER
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	# Height texture for the water shader.
	var himg := Image.create_empty(steps, steps, false, Image.FORMAT_RF)
	for j in steps:
		for i in steps:
			himg.set_pixel(i, j, Color(-hs[j * steps + i] / 16.0, 0, 0))
	_height_tex = ImageTexture.create_from_image(himg)
	_height_rect = Vector4(x0, x0, (steps - 1) * TERRAIN_STEP, (steps - 1) * TERRAIN_STEP)


var _height_tex: ImageTexture
var _height_rect: Vector4


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(9000, 9000)
	plane.subdivide_width = 8
	plane.subdivide_depth = 8
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	mat.set_shader_parameter("height_tex", _height_tex)
	mat.set_shader_parameter("height_rect", _height_rect)
	for p in ["wave_a", "wave_b"]:
		var nt := NoiseTexture2D.new()
		nt.width = 256
		nt.height = 256
		nt.seamless = true
		nt.as_normal_map = true
		nt.bump_strength = 6.0 if p == "wave_a" else 4.0
		var fn := FastNoiseLite.new()
		fn.frequency = 0.03 if p == "wave_a" else 0.05
		fn.seed = 3 if p == "wave_a" else 9
		nt.noise = fn
		mat.set_shader_parameter(p, nt)
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	mi.mesh = plane
	mi.position = Vector3(City.SIZE * City.TILE * 0.5, -0.7, City.SIZE * City.TILE * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ------------------------------------------------------------------- roads ---

static func rot_mask(m: int) -> int:
	## Mask after rotating the piece +90 degrees about Y (N->W, E->N, S->E, W->S).
	var r := 0
	if m & N: r |= W
	if m & E: r |= N
	if m & S: r |= E
	if m & W: r |= S
	return r


func _build_road_table() -> void:
	for piece in PIECES:
		var m: int = PIECES[piece]
		for k in 4:
			if not road_table.has(m):
				road_table[m] = [piece, k]
			m = rot_mask(m)


# ------------------------------------------------------------------ chunks ---

func _on_cells_changed(r: Rect2i) -> void:
	_mark_rect(r)
	_map_dirty = true


func _mark_rect(r: Rect2i) -> void:
	var a := Vector2i(maxi(r.position.x, 0) / CHUNK, maxi(r.position.y, 0) / CHUNK)
	var b := Vector2i(mini(r.end.x, City.SIZE - 1) / CHUNK, mini(r.end.y, City.SIZE - 1) / CHUNK)
	for cy in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			dirty[Vector2i(cx, cy)] = true


func _on_building_added(id: int, animate: bool) -> void:
	var b: Dictionary = city.buildings[id]
	_map_dirty = true
	if animate and is_inside_tree():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = Kit.mesh(_building_mesh(b))
		mm.instance_count = 1
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		add_child(node)
		growing[id] = {"node": node, "t": 0.0}
		_set_grow(id, 0.02)
	else:
		_mark_rect(Rect2i(b.x, b.y, b.size, b.size))


func _on_building_removed(id: int) -> void:
	if growing.has(id):
		growing[id].node.queue_free()
		growing.erase(id)
	_map_dirty = true


func _set_grow(id: int, k: float) -> void:
	var b: Dictionary = city.buildings[id]
	var e := 1.0 - pow(1.0 - k, 3.0)
	var xf := _building_xform(b)
	xf.basis = xf.basis.scaled(Vector3(1.0, maxf(e, 0.02), 1.0))
	var mm: MultiMesh = growing[id].node.multimesh
	mm.set_instance_transform(0, xf)
	mm.set_instance_color(0, _wall_tint(b))
	mm.set_instance_custom_data(0, _accent(b))


func _process(delta: float) -> void:
	for id in growing.keys():
		var g: Dictionary = growing[id]
		g.t += delta / GROW_TIME
		if g.t >= 1.0 or not city.buildings.has(id):
			g.node.queue_free()
			growing.erase(id)
			if city.buildings.has(id):
				var b: Dictionary = city.buildings[id]
				_mark_rect(Rect2i(b.x, b.y, b.size, b.size))
		else:
			_set_grow(id, g.t)
	var budget := 4
	for key in dirty.keys():
		if budget <= 0:
			break
		_rebuild_chunk(key)
		dirty.erase(key)
		budget -= 1
		_map_dirty = true
	if _map_dirty:
		refresh_map()
		lamp_tex.update(lamp_img)


func rebuild_all() -> void:
	for key in dirty.keys():
		_rebuild_chunk(key)
	dirty.clear()
	refresh_map()
	lamp_tex.update(lamp_img)


func _building_mesh(b: Dictionary) -> String:
	return Kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)


func _building_xform(b: Dictionary) -> Transform3D:
	var basis := Basis(Vector3.UP, b.rot * PI * 0.5)
	return Transform3D(basis, city.building_center(b))


func _wall_tint(b: Dictionary) -> Color:
	var pal: Array = Kit.WALLS[b.zone]
	return pal[b.tint % pal.size()]


func _accent(b: Dictionary) -> Color:
	var c: Color = Kit.ACCENTS[b.tint2 % Kit.ACCENTS.size()]
	c.a = b.seed
	return c


func _cell_hash(x: int, y: int, k: int) -> float:
	var h := hash(Vector3i(x, y, k))
	return float(h & 0xffff) / 65535.0


func _rebuild_chunk(key: Vector2i) -> void:
	if chunks.has(key):
		chunks[key].queue_free()
	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [key.x, key.y]
	add_child(node)
	chunks[key] = node
	var groups := {}  # mesh name -> [xforms, colors, customs, shadow]
	var lamps: Array[Vector3] = []
	var x0 := key.x * CHUNK
	var y0 := key.y * CHUNK
	for y in range(y0, mini(y0 + CHUNK, City.SIZE)):
		for x in range(x0, mini(x0 + CHUNK, City.SIZE)):
			var i := city.idx(x, y)
			lamp_img.set_pixel(x, y, Color(0, 0, 0, 0))
			var center := city.cell_center(x, y)
			if city.road[i] == 1:
				_add_road(groups, lamps, x, y, center)
				continue
			var bid := city.bld[i]
			if bid >= 0:
				var b: Dictionary = city.buildings[bid]
				if b.x == x and b.y == y and not growing.has(bid):
					var nm := _building_mesh(b)
					if nm != "":
						_push(groups, nm, _building_xform(b), _wall_tint(b), _accent(b), true)
					if b.zone == City.Zone.RES and b.stage == 1:
						var back := Basis(Vector3.UP, b.rot * PI * 0.5) * Vector3(_cell_hash(x, y, 9) * 6.0 - 3.0, 0, -4.4)
						_add_tree(groups, center + back, x, y, 5, false)
				continue
			if city.land[i] == 1:
				for k in city.trees[i]:
					var off := Vector3(_cell_hash(x, y, k) * 9.0 - 4.5, 0, _cell_hash(x, y, k + 7) * 9.0 - 4.5)
					_add_tree(groups, center + off, x, y, k, city.coast_dist[i] <= 2.0)
				if city.zone[i] == 0 and _cell_hash(x, y, 31) < 0.12:
					var off := Vector3(_cell_hash(x, y, 32) * 8.0 - 4.0, 0, _cell_hash(x, y, 33) * 8.0 - 4.0)
					_push(groups, "bush", Transform3D(Basis(Vector3.UP, _cell_hash(x, y, 34) * TAU), center + off),
						Kit.LEAF_TINTS[int(_cell_hash(x, y, 35) * 5.99)], Color(0, 0, 0, 0), true)
			elif city.height[i] > 0.055 and _cell_hash(x, y, 40) < 0.35:
				# Beach palms on the sand ring.
				var off := Vector3(_cell_hash(x, y, 41) * 8.0 - 4.0, 0, _cell_hash(x, y, 42) * 8.0 - 4.0)
				var p := center + off
				if city.landness(p.x, p.z) > 0.06:
					_push(groups, "palm", Transform3D(Basis(Vector3.UP, _cell_hash(x, y, 43) * TAU).scaled(Vector3.ONE * (0.9 + _cell_hash(x, y, 44) * 0.5)), p),
						Kit.LEAF_TINTS[int(_cell_hash(x, y, 45) * 5.99)], Color(0, 0, 0, 0), true)
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
			mm.set_instance_transform(k, g[0][k])
			mm.set_instance_color(k, g[1][k])
			mm.set_instance_custom_data(k, g[2][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g[3] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mmi)
	lamp_positions[key] = lamps


func _push(groups: Dictionary, nm: String, xf: Transform3D, col: Color, custom: Color, shadow: bool) -> void:
	if not groups.has(nm):
		groups[nm] = [[], [], [], shadow]
	groups[nm][0].append(xf)
	groups[nm][1].append(col)
	groups[nm][2].append(custom)


func _add_tree(groups: Dictionary, p: Vector3, x: int, y: int, k: int, coastal: bool) -> void:
	var h := _cell_hash(x, y, k + 20)
	var nm := "tree_round_a" if h < 0.4 else ("tree_round_b" if h < 0.75 else "tree_pine")
	if coastal and h < 0.6:
		nm = "palm"
	var s := 0.8 + _cell_hash(x, y, k + 30) * 0.55
	var basis := Basis(Vector3.UP, _cell_hash(x, y, k + 40) * TAU).scaled(Vector3.ONE * s)
	var tint: Color = Kit.LEAF_TINTS[int(_cell_hash(x, y, k + 50) * 5.99)]
	_push(groups, nm, Transform3D(basis, p), tint, Color(0, 0, 0, 0), true)


func _add_road(groups: Dictionary, lamps: Array[Vector3], x: int, y: int, center: Vector3) -> void:
	var mask := city.road_mask(x, y)
	var entry: Array = road_table[mask]
	var piece: String = entry[0]
	var basis := Basis(Vector3.UP, entry[1] * PI * 0.5)
	_push(groups, piece, Transform3D(basis, center), Color.WHITE, Color(0, 0, 0, 0), false)
	var neighbours := 0
	for bit in [N, E, S, W]:
		if mask & bit:
			neighbours += 1
	var local := Vector3.ZERO
	var place := false
	if neighbours >= 3:
		return  # junctions get live signal heads from CityLife, and no lamp
	if piece == "road_straight" or piece == "road_end":
		place = (x + y) % 2 == 0 or piece == "road_end"
		local = Vector3(4.9 if (x + y) % 4 == 0 else -4.9, 0.17, 0)
	elif piece == "road_corner":
		place = true
		local = Vector3(-4.9, 0.17, 4.9)
	if not place:
		return
	# The lamp arm points toward -X; turn it to face the road centre.
	var face := 0.0 if local.x > 0.0 else PI
	if piece == "road_corner":
		face = -PI * 0.25 + PI
	var lb := basis * Basis(Vector3.UP, face)
	var base := center + basis * local
	_push(groups, "street_lamp", Transform3D(lb, base), Color.WHITE, Color(0, 0, 0, 0), true)
	var head := base + lb * Vector3(-1.4, 6.0, 0.0)
	lamps.append(head)
	var hc := city.world_to_cell(head)
	if city.inside(hc.x, hc.y):
		lamp_img.set_pixel(hc.x, hc.y, Color(head.x / City.TILE - hc.x, head.z / City.TILE - hc.y, 1.0, 1.0))
