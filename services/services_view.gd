class_name ServicesView
extends Node3D
## Draws what services/ adds to the map: the coverage overlays, power lines, and garbage bags
## on the sidewalks. Catalog buildings themselves are drawn by CityView.
##
##   var sv := ServicesView.new()
##   add_child(sv)
##   sv.setup(services)
##   sv.set_overlay(CityServices.Overlay.POWER)   # NONE hides it

const OVERLAY_Y := 0.45
const UPDATE_EVERY := 0.5  # seconds between services.update() calls while the city changes
const POLE_H := 8.5

var services: CityServices
var city: City
var overlay := CityServices.Overlay.NONE

var _overlay_mesh: MeshInstance3D
var _overlay_img: Image
var _overlay_tex: ImageTexture
var _poles: MultiMeshInstance3D
var _wires: MultiMeshInstance3D
var _bags: MultiMeshInstance3D
var _t := 0.0
var _overlay_dirty := true
var _lines_dirty := true


func setup(s: CityServices) -> void:
	services = s
	city = s.city
	_make_overlay()
	_poles = _multimesh(_pole_mesh(), Color(0.36, 0.3, 0.24), true)
	_wires = _multimesh(_box(Vector3(1, 1, 1)), Color(0.08, 0.08, 0.08), false)
	var bag := SphereMesh.new()
	bag.radius = 0.45
	bag.height = 0.7
	bag.radial_segments = 8
	bag.rings = 4
	_bags = _multimesh(bag, Color(0.12, 0.13, 0.12), true)
	_bags.multimesh.use_colors = true
	var bm: StandardMaterial3D = _bags.material_override
	bm.vertex_color_use_as_albedo = true
	bm.albedo_color = Color.WHITE
	s.coverage_changed.connect(func(): _overlay_dirty = true; _lines_dirty = true)
	s.stats_changed.connect(func(): _overlay_dirty = true; _refresh_bags())
	_refresh_lines()
	_refresh_bags()


func set_overlay(mode: int) -> void:
	overlay = mode
	_overlay_mesh.visible = mode != CityServices.Overlay.NONE
	_overlay_dirty = true


func _process(delta: float) -> void:
	if services == null:
		return
	_t += delta
	if _t >= UPDATE_EVERY:
		_t = 0.0
		services.update()
	if _lines_dirty:
		_refresh_lines()
	if _overlay_dirty and _overlay_mesh.visible:
		_refresh_overlay()


# ------------------------------------------------------------------ overlay ---

func _make_overlay() -> void:
	_overlay_img = Image.create_empty(City.W, City.H, false, Image.FORMAT_RGBA8)
	_overlay_tex = ImageTexture.create_from_image(_overlay_img)
	var plane: Mesh
	if Planet.on:
		plane = Planet.belt_mesh(OVERLAY_Y)
	else:
		plane = PlaneMesh.new()
		plane.size = Vector2(City.W * City.TILE, City.H * City.TILE)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _overlay_tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 1
	_overlay_mesh = MeshInstance3D.new()
	_overlay_mesh.mesh = plane
	_overlay_mesh.material_override = mat
	_overlay_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not Planet.on:
		_overlay_mesh.position = Vector3(City.W * City.TILE * 0.5, OVERLAY_Y, City.H * City.TILE * 0.5)
	_overlay_mesh.visible = false
	add_child(_overlay_mesh)


## Colour for a value 0..1. "Good" maps run red (none) to green (full); "bad" maps the other way.
static func overlay_color(mode: int, v: float) -> Color:
	var bad := mode == CityServices.Overlay.GARBAGE or mode == CityServices.Overlay.CRIME
	if bad:
		if v < 0.04:
			return Color(0, 0, 0, 0)
		return Color(0.95, 0.85, 0.1).lerp(Color(0.9, 0.12, 0.08), clampf(v, 0.0, 1.0)) * Color(1, 1, 1, 0.35 + 0.35 * v)
	if mode == CityServices.Overlay.POWER:
		if v <= 0.0:
			return Color(0, 0, 0, 0)
		return Color(0.95, 0.85, 0.15, 0.6) if v >= 1.0 else Color(0.9, 0.15, 0.1, 0.6)
	var c := Color(0.9, 0.2, 0.12).lerp(Color(0.95, 0.85, 0.15), clampf(v * 2.0, 0.0, 1.0))
	c = c.lerp(Color(0.2, 0.85, 0.3), clampf(v * 2.0 - 1.0, 0.0, 1.0))
	c.a = 0.5
	return c


func _refresh_overlay() -> void:
	_overlay_dirty = false
	var vals := services.overlay_values(overlay)
	if vals.is_empty():
		return
	var n := City.W * City.H
	var data := PackedByteArray()
	data.resize(n * 4)
	var built_only := overlay == CityServices.Overlay.HAPPINESS or overlay == CityServices.Overlay.GARBAGE \
		or overlay == CityServices.Overlay.CRIME
	var near_built := PackedByteArray()
	if built_only:
		near_built.resize(n)
		for i in n:
			if city.bld[i] >= 0:
				var x := i % City.W
				var y := i / City.W
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if city.inside(x + dx, y + dy):
							near_built[city.idx(x + dx, y + dy)] = 1
	for i in n:
		var c := Color(0, 0, 0, 0)
		if city.land[i] == 1 and (not built_only or near_built[i] == 1):
			c = overlay_color(overlay, vals[i])
		data[i * 4] = c.r8
		data[i * 4 + 1] = c.g8
		data[i * 4 + 2] = c.b8
		data[i * 4 + 3] = c.a8
	_overlay_img.set_data(City.W, City.H, false, Image.FORMAT_RGBA8, data)
	_overlay_tex.update(_overlay_img)


# -------------------------------------------------------------- power lines ---

func _refresh_lines() -> void:
	_lines_dirty = false
	var poles: Array[Transform3D] = []
	var wires: Array[Transform3D] = []
	for i in City.W * City.H:
		if services.power_line[i] == 0:
			continue
		var x := i % City.W
		var y := i / City.W
		var p := city.cell_center(x, y)
		var horiz := services.power_line[city.idx(x - 1, y)] == 1 if (x > 0 or Planet.on) else false
		horiz = horiz or ((x < City.W - 1 or Planet.on) and services.power_line[city.idx(x + 1, y)] == 1)
		var b := Basis(Vector3.UP, 0.0 if horiz else PI * 0.5)
		poles.append(Transform3D(b, p))
		# A wire to the east and south neighbour (or the road the line meets), at both arm ends.
		for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
			var nx: int = x + d.x
			var ny: int = y + d.y
			if not city.inside(nx, ny):
				continue
			var j := city.idx(nx, ny)
			var to_line: bool = services.power_line[j] == 1 and (d.x > 0 or d.y > 0)
			var to_grid: bool = services.power_line[j] == 0 and (city.road[j] == 1 or city.bld[j] >= 0)
			if not (to_line or to_grid):
				continue
			var q := city.cell_center(nx, ny)
			if Planet.on:
				q.x = p.x + Planet.dx(p.x, q.x)
			if to_grid:
				q = p.lerp(q, 0.5)
			var dir := (q - p)
			var side := Vector3(-dir.z, 0, dir.x).normalized() * 1.1
			for s: float in [-1.0, 1.0]:
				var a: Vector3 = p + side * s + Vector3(0, POLE_H - 0.2, 0)
				var e: Vector3 = q + side * s + Vector3(0, POLE_H - (0.2 if to_line else 3.0), 0)
				var mid: Vector3 = (a + e) * 0.5 - Vector3(0, 0.35, 0)
				var len: float = a.distance_to(e)
				var basis := Basis.looking_at((e - a).normalized(), Vector3.UP).scaled(Vector3(0.05, 0.05, len))
				wires.append(Transform3D(basis, mid))
	_fill(_poles, poles)
	_fill(_wires, wires)


func _pole_mesh() -> Mesh:
	var st := SurfaceTool.new()
	var pole := CylinderMesh.new()
	pole.top_radius = 0.12
	pole.bottom_radius = 0.18
	pole.height = POLE_H
	pole.radial_segments = 6
	pole.rings = 1
	st.append_from(pole, 0, Transform3D(Basis(), Vector3(0, POLE_H * 0.5, 0)))
	st.append_from(_box(Vector3(0.18, 0.18, 2.6)), 0, Transform3D(Basis(), Vector3(0, POLE_H - 0.4, 0)))
	return st.commit()


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


# ------------------------------------------------------------------ garbage ---

func _refresh_bags() -> void:
	var xfs: Array[Transform3D] = []
	var k := 0
	for p in services.garbage_piles():
		var h := fposmod(sin(float(k) * 12.9898) * 43758.5453, 1.0)
		var b := Basis(Vector3.UP, h * TAU).scaled(Vector3.ONE * (0.8 + h * 0.5))
		xfs.append(Transform3D(b, p + Vector3(0, 0.3, 0)))
		k += 1
	_fill(_bags, xfs)
	var mm := _bags.multimesh
	for i in mm.instance_count:
		var h := fposmod(sin(float(i) * 78.233) * 43758.5453, 1.0)
		mm.set_instance_color(i, Color(0.1, 0.11, 0.1) if h < 0.6 else Color(0.18, 0.32, 0.16))


# ------------------------------------------------------------------ helpers ---

func _multimesh(mesh: Mesh, col: Color, shadow: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 0.85
	mat.vertex_color_use_as_albedo = false
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _fill(node: MultiMeshInstance3D, xfs: Array[Transform3D]) -> void:
	var mm := node.multimesh
	var colors := mm.use_colors
	mm.instance_count = 0
	mm.use_colors = colors
	mm.instance_count = xfs.size()
	for i in xfs.size():
		mm.set_instance_transform(i, Planet.xf(xfs[i]))  # flat map -> the ball on msp
