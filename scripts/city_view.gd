class_name CityView
extends Node3D
## Draws the City: terrain, sea, and chunked MultiMeshes for roads, buildings, lamps
## and trees. Also owns the data textures the shaders read (zones, traffic, lamps).

const CHUNK := 4  # draw cells (PERFORMANCE.md): small so shadow and view culling skip most of the city
# msp: the planet has over twice the island's cells, and every (chunk, model) pair is its
# own MultiMesh buffer. At 4 cells that was ~3,600 buffers, past what some Windows drivers
# allow (Fedge's AMD laptop failed buffer creation, then lost the device). Bigger chunks
# there; horizon culling (cull()) still skips the far side of the ball.
const PLANET_CHUNK := 8
var _chunk := CHUNK  # set in setup: PLANET_CHUNK on msp
const TERRAIN_MARGIN := 640.0
const TERRAIN_STEP := 6.0
const GROW_TIME := 1.4

const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")
const BEACON_SHADER := preload("res://shaders/beacon.gdshader")
const BEACON_HEIGHT := 40.0  # towers taller than this get red aircraft warning lights
const STANDIN_SHADER := preload("res://shaders/standin.gdshader")
const DETAIL_MARGIN := 40.0  # metres of overlap so a chunk doesn't flicker at the switch

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
var services: Object = null  # CityServices: buildings without power go dark at night
var _tops := {}  # mesh name -> its highest vertex
var _beacon_mesh: SphereMesh
# Past detail_distance a chunk's buildings, trees and props give way to one mesh of plain
# boxes (PERFORMANCE.md): main sets it per view and graphics level. 0 keeps full detail.
var detail_distance := 0.0
var _standin_mat: ShaderMaterial
## msp only: the sphere terrain's collision, and chunks behind the horizon are hidden.
var terrain_body: StaticBody3D
const TALLEST := 90.0  # metres: a chunk stays drawn while anything this tall could peek over the horizon
var _cull_t := 0.0
## msp: only chunks near the camera hold their full-detail MultiMeshes; the rest keep roads,
## beacons and the box stand-in. Every MultiMesh is GPU buffers whether it is drawn or not,
## and a whole planet of them is past what Fedge's AMD driver hands out.
var _full := {}       # Vector2i -> true while the chunk is built in full detail
var _want_full := {}  # Vector2i -> what cull() last decided
const FULL_IN := 60.0    # metres past detail_distance where a chunk gets full detail
const FULL_OUT := 160.0  # ... and where it drops back to the stand-in (hysteresis)
## msp: full-detail chunks further than this from the camera stop casting sun shadows. The
## street's shadow maps reach 140 m, and the ball tips far buildings away from the sun's
## view anyway; on Fedge's laptop shadows cost 5.8 ms of GPU, most of it far casters.
var shadow_reach := 0.0  # 0: every chunk casts
var _shadowed := {}      # Vector2i -> whether its MultiMeshes cast shadows now


func setup(c: City) -> void:
	city = c
	_chunk = PLANET_CHUNK if Planet.on else CHUNK
	city.cells_changed.connect(_on_cells_changed)
	city.building_added.connect(_on_building_added)
	city.building_removed.connect(_on_building_removed)
	city.day_passed.connect(func(): _map_dirty = true)
	_build_road_table()
	_make_textures()
	if Planet.on:
		terrain_body = PlanetGround.build(self, City.H, city.terrain_height, city.landness, city.ice)
	else:
		_build_terrain()
		_build_water()
	for cy in ceili(float(City.H) / _chunk):
		for cx in ceili(float(City.W) / _chunk):
			dirty[Vector2i(cx, cy)] = true
	refresh_map()


# ---------------------------------------------------------------- textures ---

func _make_textures() -> void:
	var n := City.W
	city_img = Image.create_empty(City.W, City.H, false, Image.FORMAT_RGBA8)
	city_tex = ImageTexture.create_from_image(city_img)
	lamp_img = Image.create_empty(City.W, City.H, false, Image.FORMAT_RGBA8)
	lamp_tex = ImageTexture.create_from_image(lamp_img)
	preview_img = Image.create_empty(City.W, City.H, false, Image.FORMAT_R8)
	preview_tex = ImageTexture.create_from_image(preview_img)
	RenderingServer.global_shader_parameter_set("city_map", city_tex)
	RenderingServer.global_shader_parameter_set("lamp_map", lamp_tex)
	RenderingServer.global_shader_parameter_set("preview_map", preview_tex)
	RenderingServer.global_shader_parameter_set("map_cells", float(n))
	RenderingServer.global_shader_parameter_set("tile_size", City.TILE)


func refresh_map() -> void:
	var n := City.W * City.H
	var data := PackedByteArray()
	data.resize(n * 4)
	var power_on: bool = services != null and services.power_in_play()
	for i in n:
		var bid := city.bld[i]
		var built := 32 if bid >= 0 else 0
		var dark := 16 if power_on and bid >= 0 and not city.buildings[bid].get("powered", true) else 0
		data[i * 4] = 255 if city.road[i] == 1 else 0
		data[i * 4 + 1] = city.zone[i] * 64 + built + dark
		data[i * 4 + 2] = clampi(int(city.traffic[i] * 127.0), 0, 255)
		data[i * 4 + 3] = clampi(int(city.land_value[i] * 255.0), 0, 255)
	city_img.set_data(City.W, City.H, false, Image.FORMAT_RGBA8, data)
	city_tex.update(city_img)
	_map_dirty = false


func mark_map_dirty() -> void:
	_map_dirty = true


func set_preview(cells: Array, color: Color) -> void:
	preview_img.fill(Color(0, 0, 0))
	for c in cells:
		if city.inside(c.x, c.y):
			preview_img.set_pixel(posmod(c.x, City.W), c.y, Color(1, 0, 0))
	preview_tex.update(preview_img)
	RenderingServer.global_shader_parameter_set("preview_color", color)


# ----------------------------------------------------------------- terrain ---

func _build_terrain() -> void:
	var size := City.W * City.TILE
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
	mi.position = Vector3(City.W * City.TILE * 0.5, -0.7, City.H * City.TILE * 0.5)
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
	if Planet.on:
		# x may run past either end of the map; wrap each chunk column round.
		var across := ceili(float(City.W) / _chunk)
		var y0 := maxi(r.position.y, 0) / _chunk
		var y1 := mini(r.end.y, City.H - 1) / _chunk
		for cy in range(y0, y1 + 1):
			for cx in range(floori(float(r.position.x) / _chunk), floori(float(r.end.x) / _chunk) + 1):
				dirty[Vector2i(posmod(cx, across), cy)] = true
		return
	var a := Vector2i(maxi(r.position.x, 0) / _chunk, maxi(r.position.y, 0) / _chunk)
	var b := Vector2i(mini(r.end.x, City.W - 1) / _chunk, mini(r.end.y, City.H - 1) / _chunk)
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
	mm.set_instance_transform(0, Planet.xf(xf))
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
	var order := dirty.keys()
	if Planet.on and order.size() > budget:
		# Chunks coming into full detail first: they are the ones next to the camera.
		order.sort_custom(func(a, b): return _want_full.get(a, false) and not _want_full.get(b, false))
	for key in order:
		if budget <= 0:
			break
		_rebuild_chunk(key)
		dirty.erase(key)
		budget -= 1
		_map_dirty = true
	if _map_dirty:
		refresh_map()
		lamp_tex.update(lamp_img)
	if Planet.on:
		_cull_t -= delta
		if _cull_t <= 0.0:
			_cull_t = 0.1
			cull()


## msp: hide the chunks behind the horizon; on a ball most of the city is out of sight.
func cull() -> void:
	if not Planet.on or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	var fe := Planet.flat(eye)
	var reach := detail_distance if detail_distance > 0.0 else INF
	var half := _chunk * City.TILE * 0.7
	for key in chunks:
		var node: Node3D = chunks[key]
		var c := Vector3((key.x * _chunk + _chunk * 0.5) * City.TILE, 0.0, (key.y * _chunk + _chunk * 0.5) * City.TILE)
		node.visible = Planet.above_horizon(eye, Planet.warp(c), TALLEST + half)
		var d := Vector3(Planet.fdx(fe.x, c.x), fe.y, c.z - fe.z).length()
		var was: bool = _want_full.get(key, false)
		# Behind the horizon nothing of it shows, so it needs no detail either.
		var want := node.visible and d < reach + half + (FULL_OUT if was else FULL_IN)
		_want_full[key] = want
		if want != _full.get(key, false):
			dirty[key] = true
		var cast := shadow_reach <= 0.0 or d < shadow_reach + half
		if _shadowed.get(key, true) != cast:
			_set_shadows(node, cast)
			_shadowed[key] = cast


func _set_shadows(node: Node3D, cast: bool) -> void:
	for c in node.get_children():
		if c is MultiMeshInstance3D and c.has_meta(&"shadow"):
			c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func rebuild_all() -> void:
	for key in dirty.keys():
		_rebuild_chunk(key)
	dirty.clear()
	refresh_map()
	lamp_tex.update(lamp_img)


func _building_mesh(b: Dictionary) -> String:
	if b.has("kind"):
		return Kit.special_mesh_name(b.kind, b.size, b.variant)
	return Kit.building_mesh_name(b.zone, b.stage, b.size, b.variant)


func _building_xform(b: Dictionary) -> Transform3D:
	var basis := Basis(Vector3.UP, b.rot * PI * 0.5)
	return Transform3D(basis, city.building_center(b))


func _wall_tint(b: Dictionary) -> Color:
	var pal: Array = Kit.WALLS[b.zone]
	var c: Color = pal[b.tint % pal.size()]
	# Each building gets its own shade of the palette colour: a little lighter or darker,
	# warmer or cooler, so a street of the same model never looks copy-pasted.
	var s: float = b.seed
	var v := 0.9 + 0.2 * fposmod(s * 7.31, 1.0)
	var warm := (fposmod(s * 13.7, 1.0) - 0.5) * 0.08
	return Color(c.r * v * (1.0 + warm), c.g * v, c.b * v * (1.0 - warm))


func _accent(b: Dictionary) -> Color:
	# Catalog buildings wear their brand colour on signs and trim.
	var c: Color = Catalog.get_def(b.kind).accent if b.has("kind") else Kit.ACCENTS[b.tint2 % Kit.ACCENTS.size()]
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
	var beacons: Array[Vector3] = []
	var boxes := []  # [world AABB, wall colour, seed] of each building, for the stand-in
	var full: bool = not Planet.on or _want_full.get(key, false)
	_full[key] = full
	var x0 := key.x * _chunk
	var y0 := key.y * _chunk
	for y in range(y0, mini(y0 + _chunk, City.H)):
		for x in range(x0, mini(x0 + _chunk, City.W)):
			var i := city.idx(x, y)
			lamp_img.set_pixel(x, y, Color(0, 0, 0, 0))
			var center := city.cell_center(x, y)
			if city.road[i] == 1:
				_add_road(groups, lamps, x, y, center)
				for pid in city.props_at(i):  # payphones and other street props
					var pb: Dictionary = city.buildings[pid]
					if not growing.has(pid):
						_push(groups, _building_mesh(pb), _building_xform(pb), _wall_tint(pb), _accent(pb), true)
				continue
			var bid := city.bld[i]
			if bid >= 0:
				var b: Dictionary = city.buildings[bid]
				if b.x == x and b.y == y and not growing.has(bid):
					var nm := _building_mesh(b)
					if nm != "":
						_push(groups, nm, _building_xform(b), _wall_tint(b), _accent(b), true)
						var mesh := Kit.mesh(nm)
						if mesh != null:
							boxes.append([_building_xform(b) * mesh.get_aabb(), _wall_tint(b), fposmod(float(b.seed), 1.0)])
						var top := _top_of(nm)
						if top.y > BEACON_HEIGHT:
							beacons.append(_building_xform(b) * (top + Vector3(0, 0.35, 0)))
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
		if not full and not (nm as String).begins_with("road_"):
			continue  # far away: the stand-in boxes draw it
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
			mm.set_instance_transform(k, Planet.xf(g[0][k]))  # flat map -> the ball on msp
			mm.set_instance_color(k, g[1][k])
			mm.set_instance_custom_data(k, g[2][k])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g[3] and _shadowed.get(key, true) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if g[3]:
			mmi.set_meta(&"shadow", true)
		if not (nm as String).begins_with("road_"):
			mmi.set_meta(&"detail", true)  # roads stay; the rest ends at detail_distance
		node.add_child(mmi)
	if not beacons.is_empty():
		node.add_child(_make_beacons(beacons))
	if not boxes.is_empty():
		var standin := MeshInstance3D.new()
		standin.name = "StandIn"
		standin.mesh = _standin_mesh(boxes)
		standin.material_override = _standin_material()
		standin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		standin.set_meta(&"standin", true)
		node.add_child(standin)
	_apply_detail(node)
	lamp_positions[key] = lamps


func set_detail_distance(d: float) -> void:
	## Where buildings, trees and props switch to the box stand-ins (0: never).
	if is_equal_approx(d, detail_distance):
		return
	detail_distance = d
	for key in chunks:
		_apply_detail(chunks[key])


func _apply_detail(node: Node3D) -> void:
	var d := detail_distance
	for c in node.get_children():
		if not c is GeometryInstance3D:
			continue
		var gi := c as GeometryInstance3D
		if gi.has_meta(&"detail"):
			gi.visibility_range_end = d
			gi.visibility_range_end_margin = DETAIL_MARGIN if d > 0.0 else 0.0
		elif gi.has_meta(&"standin"):
			gi.visible = d > 0.0
			gi.visibility_range_begin = d
			gi.visibility_range_begin_margin = DETAIL_MARGIN if d > 0.0 else 0.0


func _standin_material() -> ShaderMaterial:
	if _standin_mat == null:
		_standin_mat = ShaderMaterial.new()
		_standin_mat.shader = STANDIN_SHADER
	return _standin_mat


static func _standin_mesh(boxes: Array) -> ArrayMesh:
	## Four walls and a roof per building, with wall metres in UV for the window grid.
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for bx in boxes:
		var a: AABB = bx[0]
		var c: Color = bx[1]
		var sd: float = bx[2]
		var lo := a.position
		var hi := a.end
		var h := hi.y - lo.y
		var corners := [Vector3(lo.x, 0, lo.z), Vector3(hi.x, 0, lo.z), Vector3(hi.x, 0, hi.z), Vector3(lo.x, 0, hi.z)]
		for k in 4:
			var p0: Vector3 = corners[k]
			var p1: Vector3 = corners[(k + 1) % 4]
			var w := p0.distance_to(p1)
			var nrm := Vector3.UP.cross(p1 - p0).normalized()
			var b := v.size()
			for q in [[p0, 0.0, 0.0], [p1, w, 0.0], [p1, w, h], [p0, 0.0, h]]:
				v.append(q[0] + Vector3(0, lo.y + q[2], 0))
				n.append(nrm)
				uv.append(Vector2(q[1], q[2]))
				uv2.append(Vector2(sd, 0))
				col.append(c)
			idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])  # clockwise: Godot's front faces
		var r := v.size()
		for p in corners:
			v.append(Vector3(p.x, hi.y, p.z))
			n.append(Vector3.UP)
			uv.append(Vector2(0, -1))
			uv2.append(Vector2(sd, 0))
			col.append(c)
		idx.append_array([r, r + 1, r + 2, r, r + 2, r + 3])
	if Planet.on:
		# Built on the flat map like everything else, then each corner put on the ball.
		for k in v.size():
			n[k] = Planet.frame(v[k]) * n[k]
			v[k] = Planet.warp(v[k])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


func _top_of(nm: String) -> Vector3:
	## The highest point of a kit mesh (spire, antenna or roof corner), in mesh space.
	if _tops.has(nm):
		return _tops[nm]
	var top := Vector3(0, -1, 0)
	var mesh := Kit.mesh(nm)
	if mesh != null and mesh.get_aabb().end.y > BEACON_HEIGHT and mesh is ArrayMesh:
		for s in mesh.get_surface_count():
			for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				if v.y > top.y:
					top = v
	_tops[nm] = top
	return top


func _make_beacons(points: Array[Vector3]) -> MultiMeshInstance3D:
	if _beacon_mesh == null:
		_beacon_mesh = SphereMesh.new()
		_beacon_mesh.radius = 0.35
		_beacon_mesh.height = 0.7
		_beacon_mesh.radial_segments = 8
		_beacon_mesh.rings = 4
		var mat := ShaderMaterial.new()
		mat.shader = BEACON_SHADER
		_beacon_mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _beacon_mesh
	mm.instance_count = points.size()
	for k in points.size():
		mm.set_instance_transform(k, Transform3D(Basis.IDENTITY, Planet.place(points[k])))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi


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
	lamps.append(Planet.place(head))
	var hc := city.flat_to_cell(head)
	if city.inside(hc.x, hc.y):
		lamp_img.set_pixel(hc.x, hc.y, Color(head.x / City.TILE - hc.x, head.z / City.TILE - hc.y, 1.0, 1.0))
