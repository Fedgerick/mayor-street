class_name CarRadio
extends Node
## The car radio. Plays while you drive; C (or D-pad up) flips to the next station, and after the
## last one, off. Stations are long synthesized tracks with jingles between songs, made by
## audio/tools/synth_round3.py. They keep "broadcasting" while you're away: every station runs on
## its own clock, so tuning back lands mid-song the way a real radio does.
## KMAY only goes on air once the city has built the KMAY Radio Tower.
## Created by AudioDirector; reads the director's car and street state.

const STATIONS := [
	{"id": "kmay", "file": "radio_kmay", "name": "KMAY 92.1", "tag": "New Harbor's hit radio", "needs": "radio_tower"},
	{"id": "lofi", "file": "radio_lofi", "name": "Harbor Lo-Fi 88.5", "tag": "Beats to commute to"},
	{"id": "wave", "file": "radio_wave", "name": "Night Drive 101.7", "tag": "Synthwave after dark"},
	{"id": "boom", "file": "radio_boom", "name": "BOOM 104.3", "tag": "Bass for the block"},
]
const ACTION := "audio_radio_next"

var director: AudioDirector
var station := 0          # index into STATIONS, -1 = off
var gain := 0.0           # 0..1 fade, read by the director to drop the street music
var switches := 0         # for tests

var _player: AudioStreamPlayer
var _streams := {}
var _playing := -2
var _label: Label
var _label_t := 0.0
var _was_on := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for s in STATIONS:
		var path := "res://audio/music/%s.ogg" % s.file
		if ResourceLoader.exists(path):
			var st: AudioStream = load(path)
			if st is AudioStreamOggVorbis:
				(st as AudioStreamOggVorbis).loop = true
			_streams[s.id] = st
	_player = AudioStreamPlayer.new()
	_player.bus = "Music"
	add_child(_player)
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_C
		InputMap.action_add_event(ACTION, k)
		var j := InputEventJoypadButton.new()
		j.button_index = JOY_BUTTON_DPAD_UP
		InputMap.action_add_event(ACTION, j)
	_build_label()


func available() -> Array[int]:
	## Station indices that are on air right now.
	var out: Array[int] = []
	var city = director._city if director else null
	for i in STATIONS.size():
		var need: String = STATIONS[i].get("needs", "")
		if need != "" and city != null and city.has_method("specials_of") and city.specials_of(need).is_empty():
			continue
		if _streams.has(STATIONS[i].id):
			out.append(i)
	return out


func current_name() -> String:
	return "Radio off" if station < 0 else STATIONS[station].name


func next_station() -> void:
	var on := available()
	if on.is_empty():
		station = -1
	else:
		var k := on.find(station)
		station = -1 if k == on.size() - 1 else on[k + 1] if k >= 0 else on[0]
	switches += 1
	if in_car():
		director.play_ui("radio_tune", -10.0)
		_show()


func in_car() -> bool:
	return director != null and director._car != null and is_instance_valid(director._car) and director._street_active()


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed(ACTION) and not e.is_echo() and in_car():
		next_station()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var on := available()
	if station >= 0 and not on.has(station):
		station = on[0] if not on.is_empty() else -1
	var want := in_car() and director._engine_target > 0.0 and station >= 0
	if want and not _was_on:
		_show()
	_was_on = want
	gain = move_toward(gain, 1.0 if want else 0.0, delta * (1.0 if want else 4.0))
	if gain > 0.0:
		if _playing != station and station >= 0:
			_tune(station)
		_player.volume_db = linear_to_db(maxf(gain, 0.0001)) + 1.5 - 6.0 * director.action
	elif _player.playing:
		_player.stop()
		_playing = -2
	_label_t -= delta
	_label.modulate.a = clampf(_label_t / 0.6, 0.0, 1.0)
	_label.visible = _label_t > 0.0


func _tune(i: int) -> void:
	var s: AudioStream = _streams.get(STATIONS[i].id)
	if s == null:
		return
	_player.stream = s
	# Every station runs on its own clock, offset so they don't all start together.
	var at := fmod(Time.get_ticks_msec() / 1000.0 + i * 37.0, s.get_length())
	_player.play(at)
	_playing = i


func _show() -> void:
	_label.text = current_name() if station < 0 else "%s\n%s" % [STATIONS[station].name, STATIONS[station].tag]
	_label_t = 2.8


func _build_label() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 60
	add_child(layer)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_label.offset_left = -260
	_label.offset_right = 260
	_label.offset_top = 64
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_color", Color(1.0, 0.93, 0.62))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 6)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.visible = false
	layer.add_child(_label)
