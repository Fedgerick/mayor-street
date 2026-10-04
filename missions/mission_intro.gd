class_name MissionIntro
extends Node3D
## Before a story job: a short camera fly-by over each place the job uses, letterboxed, with
## the contact's line on screen. The game is paused while it plays (this node keeps running);
## Space, Enter or Esc skips it. missions.gd starts the job when `finished` fires.

signal finished

const SHOT := 2.8          # seconds per place
const MAX_SHOTS := 3

var playing := false
var _cam: Camera3D
var _prev: Camera3D
var _was_paused := false
var _layer: CanvasLayer
var _bars: Array[ColorRect] = []
var _who: Label
var _line: Label
var _place: Label
var _shots: Array = []     # [Vector3 centre, place name]
var _t0 := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cam = Camera3D.new()
	_cam.fov = 55.0
	_cam.far = 3000.0
	add_child(_cam)
	_layer = CanvasLayer.new()
	_layer.layer = 8
	_layer.visible = false
	add_child(_layer)
	for i in 2:
		var bar := ColorRect.new()
		bar.color = Color(0, 0, 0, 0.92)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_layer.add_child(bar)
		_bars.append(bar)
	_who = _label(26, Color(1, 0.82, 0.2))
	_line = _label(21, Color.WHITE)
	_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place = _label(30, Color.WHITE)
	_place.add_theme_constant_override("outline_size", 8)
	_place.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(l)
	return l


func play(places: Array, speaker: String, color: Color, line: String) -> void:
	## places: [Vector3 centre, name] pairs, first to last.
	_shots = places.slice(0, MAX_SHOTS)
	if _shots.is_empty() or not is_inside_tree():
		finished.emit()
		return
	playing = true
	_prev = get_viewport().get_camera_3d()
	_cam.current = true
	_was_paused = get_tree().paused
	get_tree().paused = true
	_who.text = speaker
	_who.add_theme_color_override("font_color", color)
	_line.text = line
	_layer.visible = true
	_t0 = Time.get_ticks_msec()
	_layout()
	_frame(0.0)


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	var bar_h := vs.y * 0.13
	_bars[0].position = Vector2.ZERO
	_bars[0].size = Vector2(vs.x, bar_h)
	_bars[1].position = Vector2(0, vs.y - bar_h)
	_bars[1].size = Vector2(vs.x, bar_h)
	_who.position = Vector2(vs.x * 0.08, vs.y - bar_h + 8)
	_line.position = Vector2(vs.x * 0.08, vs.y - bar_h + 42)
	_line.size = Vector2(vs.x * 0.84, bar_h - 46)
	_place.position = Vector2(vs.x * 0.06, bar_h + 18)


func _process(_delta: float) -> void:
	if not playing:
		return
	_layout()
	_frame((Time.get_ticks_msec() - _t0) / 1000.0)


func _frame(t: float) -> void:
	var i := int(t / SHOT)
	if i >= _shots.size():
		finish()
		return
	var u := fmod(t, SHOT) / SHOT
	var target: Vector3 = _shots[i][0]
	_place.text = _shots[i][1]
	_place.modulate.a = clampf(u * 4.0, 0.0, 1.0) * clampf((1.0 - u) * 5.0, 0.0, 1.0)
	var ang := float(i) * 1.9 + u * 0.7
	var dist := lerpf(80.0, 48.0, u)
	var h := lerpf(52.0, 26.0, u)
	_cam.global_position = target + Vector3(cos(ang) * dist, h, sin(ang) * dist)
	_cam.look_at(target + Vector3.UP * 5.0)


func _input(e: InputEvent) -> void:
	if not playing:
		return
	var k := e as InputEventKey
	if k and k.pressed and not k.echo and k.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]:
		finish()
	if e is InputEventKey or e is InputEventMouseButton:
		get_viewport().set_input_as_handled()


func finish() -> void:
	if not playing:
		return
	playing = false
	_layer.visible = false
	_cam.current = false
	if _prev and is_instance_valid(_prev):
		_prev.make_current()
	get_tree().paused = _was_paused
	finished.emit()
