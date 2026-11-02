class_name MayorCamera
extends Camera3D
## Mayor view: orbit, tilt, zoom toward the cursor, pan with keys or by dragging.
## focus, panning and ground_point() are in flat map metres; on msp (Planet.on) the camera
## is stood up on the ball over the focus and can pull back far enough to see the globe.

signal moved(distance: float)

const MIN_DIST := 25.0
const MAX_DIST := 900.0
const PLANET_MAX_DIST := 2600.0  # msp: far enough out to see the whole ball

var focus := Vector3(480, 0, 480)
var yaw := deg_to_rad(-35.0)
var tilt := 0.0             # extra pitch the player adds with right-drag
var dist := 320.0
var bounds := Rect2(0, 0, 960, 960)

var _focus_goal := focus
var _yaw_goal := yaw
var _tilt_goal := tilt
var _dist_goal := dist
var _rotating := false
var _panning := false
var _pan_anchor := Vector3.ZERO
var auto_orbit := 0.0       # radians per second, used on the title screen


func _ready() -> void:
	fov = 45.0
	near = 0.5
	far = 6000.0
	_apply()


func set_view(f: Vector3, d: float, y: float, t := 0.0) -> void:
	focus = f
	_focus_goal = f
	dist = d
	_dist_goal = d
	yaw = y
	_yaw_goal = y
	tilt = t
	_tilt_goal = t
	_apply()


func glide_to(f: Vector3, d: float, y: float) -> void:
	## Ease over to a new framing; _process does the move.
	_focus_goal = f
	_dist_goal = d
	_yaw_goal = yaw + wrapf(y - yaw, -PI, PI)


func pitch_for(d: float) -> float:
	## Low and cinematic up close, more top-down when zoomed out.
	var k := clampf(inverse_lerp(MIN_DIST, 600.0, d), 0.0, 1.0)
	var p := deg_to_rad(lerpf(22.0, 58.0, sqrt(k))) + tilt
	if Planet.on:  # look straight down at the ball from orbit
		p = lerpf(p, deg_to_rad(84.0), smoothstep(700.0, 1800.0, d))
	return p


func max_dist() -> float:
	return PLANET_MAX_DIST if Planet.on else MAX_DIST


## East-west steps across the seam the short way on the planet.
static func _toward(from: Vector3, to: Vector3) -> Vector3:
	var d := to - from
	if Planet.on:
		d.x = Planet.dx(from.x, to.x)
	return d


func ground_point(screen: Vector2) -> Variant:
	var o := project_ray_origin(screen)
	var d := project_ray_normal(screen)
	if Planet.on:
		var hit = Planet.ray_hit(o, d)
		return Planet.unwarp(hit) * Vector3(1, 0, 1) if hit != null else null
	if absf(d.y) < 1e-4:
		return null
	var t := -o.y / d.y
	if t < 0.0:
		return null
	return o + d * t


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed:
				return
			var zoom_in := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			var k := 0.85 if zoom_in else 1.0 / 0.85
			var new_dist := clampf(_dist_goal * k, MIN_DIST, max_dist())
			if zoom_in:
				var gp = ground_point(mb.position)
				if gp != null:
					var frac := 1.0 - new_dist / _dist_goal
					_focus_goal += _toward(_focus_goal, gp) * frac
			_dist_goal = new_dist
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = mb.pressed
			if mb.pressed:
				var gp = ground_point(mb.position)
				_pan_anchor = gp if gp != null else focus
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _rotating:
			_yaw_goal -= mm.relative.x * 0.006
			_tilt_goal = clampf(_tilt_goal + mm.relative.y * 0.004, -0.35, 0.5)
		elif _panning:
			var gp = ground_point(mm.position)
			if gp != null:
				var step := _toward(gp, _pan_anchor)
				_focus_goal += step
				focus += step
				_apply()


func is_dragging() -> bool:
	return _rotating or _panning


func _process(delta: float) -> void:
	var move := Vector2.ZERO
	if not Input.is_key_pressed(KEY_CTRL):
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): move.y -= 1
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): move.y += 1
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): move.x -= 1
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): move.x += 1
		if Input.is_key_pressed(KEY_Q): _yaw_goal += delta * 1.5
		if Input.is_key_pressed(KEY_E): _yaw_goal -= delta * 1.5
	if Input.is_key_pressed(KEY_PAGEUP): _dist_goal = maxf(_dist_goal * (1.0 - delta * 1.5), MIN_DIST)
	if Input.is_key_pressed(KEY_PAGEDOWN): _dist_goal = minf(_dist_goal * (1.0 + delta * 1.5), max_dist())
	if move != Vector2.ZERO:
		var speed := _dist_goal * 1.1 * (2.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		var fwd := Vector3(-sin(_yaw_goal), 0, -cos(_yaw_goal))
		var right := Vector3(cos(_yaw_goal), 0, -sin(_yaw_goal))
		_focus_goal += (right * move.x - fwd * move.y) * speed * delta
	_yaw_goal += auto_orbit * delta
	if not Planet.on:  # the planet's east-west has no end
		_focus_goal.x = clampf(_focus_goal.x, bounds.position.x, bounds.end.x)
	_focus_goal.z = clampf(_focus_goal.z, bounds.position.y, bounds.end.y)
	var k := 1.0 - exp(-delta * 10.0)
	focus = focus.lerp(_focus_goal, k)
	yaw = lerpf(yaw, _yaw_goal, k)
	tilt = lerpf(tilt, _tilt_goal, k)
	dist = lerpf(dist, _dist_goal, 1.0 - exp(-delta * 8.0))
	_apply()


func _apply() -> void:
	var p := pitch_for(dist)
	p = clampf(p, deg_to_rad(8.0), deg_to_rad(85.0))
	var offset := Vector3(sin(yaw) * cos(p), sin(p), cos(yaw) * cos(p)) * dist
	if Planet.on:
		var q := Planet.frame(focus)
		var target := Planet.warp(focus)
		global_position = target + q * offset
		look_at(target, q.y)
		moved.emit(dist)
		return
	global_position = focus + offset
	look_at(focus, Vector3.UP)
	moved.emit(dist)
