class_name StreetMode
extends Node3D
## Street level in one node: the character, the street camera, enterable cars, collision
## built from the City, and a small HUD. The mayor view stays outside; it hands over with
## `enter_street()` and takes the camera back after `exit_street()`.
##
## Integration (main scene):
##     var street := preload("res://player/scenes/street_mode.tscn").instantiate()
##     add_child(street)
##     street.setup(city)
##     # Mayor -> street, dropping onto whatever the mayor camera looks at:
##     street.enter_street(mayor_camera, mayor_camera.focus)
##     # Street -> mayor: give the transform/FOV the mayor camera should end on.
##     street.exit_street(mayor_target_xform, mayor_camera.fov)
##     street.street_exited.connect(func(): mayor_camera.make_current())

signal street_entered
signal street_exited
signal vehicle_changed(car: DrivableCar)

const CAR_MODELS := ["car_sedan", "car_hatch", "car_van", "car_sedan", "car_truck"]
const CAR_COLORS := [Color(0.85, 0.12, 0.1), Color(0.95, 0.95, 0.95), Color(0.12, 0.12, 0.14), Color(0.15, 0.3, 0.7),
	Color(0.7, 0.72, 0.75), Color(0.95, 0.75, 0.1), Color(0.1, 0.45, 0.3), Color(0.55, 0.1, 0.15)]

@export var dive_seconds := 3.2
@export var rise_seconds := 2.6
@export var parked_cars_per_drop := 4
@export var enter_radius := 3.2

var city: City
var player: StreetPlayer
var camera: StreetCamera
var collision: CityCollision
var car: DrivableCar = null         # the car being driven, if any
var active := false                 # player has control at street level
var busy := false                   # a zoom is playing

var _hud: CanvasLayer
var _hint: Label
var _speedo: Label
var _cars_root: Node3D
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	StreetInput.ensure()
	_rng.seed = 4242
	_cars_root = Node3D.new()
	_cars_root.name = "Cars"
	add_child(_cars_root)
	player = StreetPlayer.new()
	player.name = "Player"
	add_child(player)
	player.interact_requested.connect(_on_interact)
	player.process_mode = Node.PROCESS_MODE_DISABLED
	player.visible = false
	camera = StreetCamera.new()
	camera.name = "StreetCamera"
	add_child(camera)
	_build_hud()


func setup(c: City) -> void:
	city = c
	collision = CityCollision.new()
	collision.name = "Collision"
	add_child(collision)
	collision.setup(c)


# ------------------------------------------------------------------ mode switch ---

func enter_street(from_camera: Camera3D, ground_point: Vector3) -> void:
	if busy or active:
		return
	busy = true
	var spot := sidewalk_spawn(ground_point)
	player.process_mode = Node.PROCESS_MODE_INHERIT
	player.visible = true
	player.set_in_vehicle(false)
	player.set_controls(false)
	# Face the way the mayor camera looks, so the dive swings in from the same side.
	var f := -from_camera.global_basis.z
	var yaw := atan2(-f.x, -f.z)
	player.place(spot, yaw)
	player.rig.pitch = deg_to_rad(-14.0)
	player.rig.snap()
	if parked_cars_per_drop > 0:
		spawn_parked_cars_near(spot, parked_cars_per_drop)
	camera.make_current()
	camera.dive_to(player.rig, from_camera.global_transform, from_camera.fov, dive_seconds)
	await camera.flight_finished
	busy = false
	active = true
	player.set_controls(true)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	street_entered.emit()


func exit_street(to: Transform3D, to_fov := 45.0) -> void:
	if busy or not active:
		return
	busy = true
	active = false
	if car:
		_leave_car()
	player.set_controls(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	camera.rise_to(to, to_fov, rise_seconds)
	await camera.flight_finished
	busy = false
	player.process_mode = Node.PROCESS_MODE_DISABLED
	street_exited.emit()


func focus_point() -> Vector3:
	## Where the mayor camera should centre when returning.
	return car.global_position if car else player.global_position


func view_yaw() -> float:
	return (car.rig.yaw if car else player.rig.yaw)


# ----------------------------------------------------------------------- cars ---

func _on_interact() -> void:
	if not active:
		return
	var best: DrivableCar = null
	var best_d := enter_radius
	for v in get_tree().get_nodes_in_group("vehicles"):
		var d: float = (v as Node3D).global_position.distance_to(player.global_position)
		if d < best_d and v.driver == null:
			best = v
			best_d = d
	if best:
		_enter_car(best)


func _unhandled_input(e: InputEvent) -> void:
	if active and car and e.is_action_pressed("street_interact"):
		get_viewport().set_input_as_handled()
		if absf(car.speed()) < 6.0:
			_leave_car()
	if active and e is InputEventKey and e.pressed and e.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	if active and e is InputEventMouseButton and e.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _enter_car(c: DrivableCar) -> void:
	car = c
	player.set_in_vehicle(true)
	c.set_driver(player)
	camera.blend_to(c.rig, 0.7)
	vehicle_changed.emit(c)


func _leave_car() -> void:
	var c := car
	car = null
	var p := c.exit_point()
	# If the door side is blocked, try the other side, then the roof.
	var space := get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.7
	q.shape = cap
	q.exclude = [c.get_rid()]
	for cand in [p, p - c.global_basis.x * (c._aabb.size.x + 1.4), c.global_position + Vector3.UP * (c._aabb.size.y + 1.0)]:
		q.transform = Transform3D(Basis.IDENTITY, cand + Vector3.UP * 0.9)
		if space.intersect_shape(q, 1).is_empty():
			p = cand
			break
	c.set_driver(null)
	player.set_in_vehicle(false)
	player.place(p, c.heading_yaw())
	player.rig.yaw = c.rig.yaw
	player.rig.pitch = clampf(c.rig.pitch, player.rig.min_pitch, player.rig.max_pitch)
	player.rig.snap()
	player.set_controls(active or busy)
	camera.blend_to(player.rig, 0.6)
	vehicle_changed.emit(null)


func spawn_car(model: String, pos: Vector3, yaw: float, color: Color) -> DrivableCar:
	var c := DrivableCar.new()
	c.model = model
	c.tint = color
	_cars_root.add_child(c)
	c.global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	return c


func spawn_parked_cars_near(p: Vector3, count: int) -> void:
	## Park a few cars at the kerb of nearby straight roads so there's always a ride.
	if city == null:
		return
	var existing := 0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if (v as Node3D).global_position.distance_to(p) < 40.0:
			existing += 1
	var need := count - existing
	if need <= 0:
		return
	var origin := city.world_to_cell(p)
	var spots: Array = []
	for r in range(0, 5):
		for y in range(origin.y - r, origin.y + r + 1):
			for x in range(origin.x - r, origin.x + r + 1):
				if maxi(absi(x - origin.x), absi(y - origin.y)) != r or not city.is_road(x, y):
					continue
				var m := city.road_mask(x, y)
				if m == 2 | 8 or m == 1 | 4:
					spots.append(Vector2i(x, y))
	for s in spots:
		if need <= 0:
			break
		var cell: Vector2i = s
		var m := city.road_mask(cell.x, cell.y)
		var c := city.cell_center(cell.x, cell.y)
		var side := 1.0 if _rng.randf() < 0.5 else -1.0
		var pos: Vector3
		var yaw: float
		if m == 2 | 8:   # road runs along X: park at a kerb, drive on the right
			pos = c + Vector3(_rng.randf_range(-2.5, 2.5), 0.15, side * 2.75)
			yaw = PI * 0.5 if side > 0.0 else -PI * 0.5
		else:            # along Z
			pos = c + Vector3(side * 2.75, 0.15, _rng.randf_range(-2.5, 2.5))
			yaw = 0.0 if side < 0.0 else PI
		var clear := true
		for v in get_tree().get_nodes_in_group("vehicles"):
			if (v as Node3D).global_position.distance_to(pos) < 6.0:
				clear = false
		if not clear:
			continue
		var model: String = CAR_MODELS[_rng.randi() % CAR_MODELS.size()]
		spawn_car(model, pos, yaw, CAR_COLORS[_rng.randi() % CAR_COLORS.size()])
		need -= 1


func sidewalk_spawn(p: Vector3) -> Vector3:
	## Nearest sidewalk to a ground point, or the point itself if there are no roads.
	if city == null:
		return p + Vector3.UP * 0.3
	var o := city.world_to_cell(p)
	for r in range(0, 12):
		var best := Vector3.ZERO
		var best_d := INF
		for y in range(o.y - r, o.y + r + 1):
			for x in range(o.x - r, o.x + r + 1):
				if maxi(absi(x - o.x), absi(y - o.y)) != r or not city.is_road(x, y):
					continue
				var c := city.cell_center(x, y)
				var m := city.road_mask(x, y)
				for cand in [Vector3(4.9, 0, 4.9), Vector3(-4.9, 0, 4.9), Vector3(4.9, 0, -4.9), Vector3(-4.9, 0, -4.9),
						Vector3(0, 0, 4.9) if not (m & 4) else Vector3(4.9, 0, 0),
						Vector3(0, 0, -4.9) if not (m & 1) else Vector3(-4.9, 0, 0)]:
					var w: Vector3 = c + cand
					var d := w.distance_squared_to(p)
					if d < best_d:
						best_d = d
						best = w
		if best_d < INF:
			return best + Vector3.UP * 0.3
	return p + Vector3.UP * 0.3


# ------------------------------------------------------------------------ HUD ---

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "HUD"
	add_child(_hud)
	_hint = _label(22, HORIZONTAL_ALIGNMENT_CENTER)
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -110
	_hint.offset_bottom = -70
	_speedo = _label(44, HORIZONTAL_ALIGNMENT_RIGHT)
	_speedo.anchor_left = 1.0
	_speedo.anchor_right = 1.0
	_speedo.anchor_top = 1.0
	_speedo.anchor_bottom = 1.0
	_speedo.offset_left = -320
	_speedo.offset_right = -40
	_speedo.offset_top = -110
	_speedo.offset_bottom = -40


func _label(size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0.05, 0.06, 0.1, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(l)
	return l


func _process(_delta: float) -> void:
	_hud.visible = active
	if not active:
		return
	if car:
		var kmh := absf(car.speed()) * 3.6
		_speedo.text = "%d km/h" % roundi(kmh)
		_hint.text = "E  get out" if absf(car.speed()) < 6.0 else ""
		camera.fov_boost = clampf(absf(car.speed()) / 35.0, 0.0, 1.0)
	else:
		_speedo.text = ""
		camera.fov_boost = 0.0
		var near := false
		for v in get_tree().get_nodes_in_group("vehicles"):
			if (v as Node3D).global_position.distance_to(player.global_position) < enter_radius:
				near = true
				break
		_hint.text = "E  get in" if near else ""
