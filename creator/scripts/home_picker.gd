class_name HomePicker
extends Node3D
## Map-view mode for choosing a home: every residential building gets a pin, the one under
## the mouse lights up with its address, and a click moves in. Esc cancels.
##   var hp := HomePicker.new(); add_child(hp); hp.start(city, camera)
##   var cell: Vector2i = await hp.finished    # (-1, -1) when cancelled

signal finished(cell: Vector2i)

const PIN := Color(0.35, 0.85, 1.0)
const PIN_HOT := Color(1.0, 0.82, 0.3)

var city: City
var camera: Camera3D
var current := Vector2i(-1, -1)   # highlighted as the current home, if any
var _candidates: Array[Dictionary] = []
var _hover := -1
var _pins: MultiMeshInstance3D
var _hot: MeshInstance3D
var _ui: CanvasLayer
var _label: Label
var _active := false


func start(c: City, cam: Camera3D, current_home := Vector2i(-1, -1)) -> void:
	city = c
	camera = cam
	current = current_home
	_candidates = candidates(city)
	_build_pins()
	_build_ui()
	_active = true
	if _candidates.is_empty():
		_label.text = "No homes yet. Zone some residential land, or skip and move in later."


static func candidates(c: City) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b in c.buildings.values():
		if b.zone == City.Zone.RES:
			out.append(b)
	return out


static func building_height(b: Dictionary) -> float:
	## Rough roof height for picking and pins; the kit's real meshes vary around this.
	if b.size == 2:
		return 70.0
	return [0.0, 8.0, 22.0, 45.0][clampi(b.stage, 0, 3)]


func _pin_mesh() -> Mesh:
	var m := SphereMesh.new()
	m.radius = 1.6
	m.height = 3.2
	m.radial_segments = 12
	m.rings = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 10
	m.material = mat
	return m


func _build_pins() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _pin_mesh()
	mm.instance_count = _candidates.size()
	for i in _candidates.size():
		var b := _candidates[i]
		var p := city.building_center(b) + Vector3(0, building_height(b) + 6.0, 0)
		mm.set_instance_transform(i, Planet.xf_rigid(Transform3D(Basis.IDENTITY, p)))
		var is_cur := Vector2i(b.x, b.y) == current or _covers(b, current)
		mm.set_instance_color(i, PIN_HOT if is_cur else PIN)
	_pins = MultiMeshInstance3D.new()
	_pins.multimesh = mm
	_pins.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pins)
	_hot = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.82
	ring.outer_radius = 1.0
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = PIN_HOT
	rm.no_depth_test = true
	ring.material = rm
	_hot.mesh = ring
	_hot.visible = false
	_hot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_hot)


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.layer = 5
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Hud.make_theme()
	_ui.add_child(root)
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.position = Vector2(-330, 86)
	bar.custom_minimum_size = Vector2(660, 0)
	root.add_child(bar)
	var v := VBoxContainer.new()
	bar.add_child(v)
	var t := Label.new()
	t.text = "CHOOSE YOUR HOME"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 24)
	t.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	v.add_child(t)
	_label = Label.new()
	_label.text = "Click a marked building to move in. It becomes your save point and respawn spot."
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_label)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(h)
	var skip := Button.new()
	skip.text = "Skip, move in later" if current.x < 0 else "Keep my home"
	skip.pressed.connect(func(): _finish(Vector2i(-1, -1)))
	h.add_child(skip)
	Hud.no_keyboard_focus(root)


func _covers(b: Dictionary, cell: Vector2i) -> bool:
	return cell.x >= b.x and cell.y >= b.y and cell.x < b.x + b.size and cell.y < b.y + b.size


func pick_at(screen: Vector2) -> int:
	## Index of the candidate building under a screen point, nearest hit first, or -1.
	var from := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var best := -1
	var best_t := INF
	if Planet.on:  # msp: pick by footprint under the cursor
		var hit = Planet.ray_hit(from, dir)
		if hit == null:
			return -1
		var cell := city.flat_to_cell(Planet.unwarp(hit))
		for i in _candidates.size():
			if _covers(_candidates[i], cell):
				return i
		return -1
	for i in _candidates.size():
		var b := _candidates[i]
		var o := Vector3(b.x * City.TILE, -1.0, b.y * City.TILE)
		var aabb := AABB(o, Vector3(b.size * City.TILE, building_height(b) + 1.0, b.size * City.TILE))
		var hit = aabb.intersects_ray(from, dir)
		if hit != null:
			var t := from.distance_to(hit)
			if t < best_t:
				best_t = t
				best = i
	return best


func _unhandled_input(e: InputEvent) -> void:
	if not _active:
		return
	if e is InputEventMouseMotion:
		_set_hover(pick_at(e.position))
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var i := pick_at(e.position)
		get_viewport().set_input_as_handled()
		if i >= 0:
			var b := _candidates[i]
			_finish(Vector2i(b.x, b.y))
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_finish(Vector2i(-1, -1))


func _set_hover(i: int) -> void:
	if i == _hover:
		return
	_hover = i
	_hot.visible = i >= 0
	if i < 0:
		_label.text = "Click a marked building to move in. It becomes your save point and respawn spot."
		return
	var b := _candidates[i]
	var r: float = b.size * City.TILE * 0.62
	_hot.scale = Vector3(r, r, r)
	_hot.position = city.building_center(b) + Vector3(0, 0.6, 0)
	_label.text = ResidentHome.describe(city, b) + ". Click to move in."


func _finish(cell: Vector2i) -> void:
	if not _active:
		return
	_active = false
	finished.emit(cell)
	queue_free()
