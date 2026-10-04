class_name WeatherAudio
extends Node
## Feeds the director's rain and wind from whatever weather system the game has, and plays thunder.
## It looks for `main.weather`, or else the first node in the "weather" group, and reads:
##   rain: float    0..1 (0 = dry, 1 = downpour)
##   wind: float    0..1
##   signal lightning(pos: Vector3)   optional; thunder follows after the sound's travel time
## With no weather system it stays dry. Tests and debugging can set rain_override / wind_override.
## Without a lightning signal, heavy rain still brings the odd distant rumble.

var director: AudioDirector
var rain_override := -1.0
var wind_override := -1.0
var source: Object = null
var thunders := 0          # for tests

var _look_t := 0.0
var _rumble_t := 40.0
var _rng := RandomNumberGenerator.new()
var _thunder_player: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	# Thunder sits on the Ambience bus so it gets muffled with the rest of the sky up high.
	_thunder_player = AudioStreamPlayer.new()
	_thunder_player.bus = "Ambience"
	add_child(_thunder_player)


func _process(delta: float) -> void:
	_look_t -= delta
	if _look_t <= 0.0:
		_look_t = 1.0
		_find_source()
	var r := 0.0
	var w := 0.0
	if source != null and is_instance_valid(source):
		r = float(source.get("rain")) if "rain" in source else 0.0
		w = float(source.get("wind")) if "wind" in source else 0.0
	if rain_override >= 0.0:
		r = rain_override
	if wind_override >= 0.0:
		w = wind_override
	director.rain = move_toward(director.rain, clampf(r, 0.0, 1.0), delta * 0.25)
	director.wind = move_toward(director.wind, clampf(w, 0.0, 1.0), delta * 0.25)
	# Distant rumbles in a downpour when nothing reports lightning.
	var has_lightning := source != null and is_instance_valid(source) and source.has_signal("lightning")
	if director.rain > 0.7 and not has_lightning:
		_rumble_t -= delta
		if _rumble_t <= 0.0:
			_rumble_t = _rng.randf_range(25.0, 70.0)
			_thunder(_rng.randf_range(1500.0, 3000.0))


func _find_source() -> void:
	var s: Object = null
	var main = director.main
	if main != null and is_instance_valid(main) and "weather" in main:
		s = main.get("weather")
	if s == null:
		s = get_tree().get_first_node_in_group("weather")
	if s == source:
		return
	source = s
	if s != null and s.has_signal("lightning") and not s.is_connected("lightning", _on_lightning):
		s.connect("lightning", _on_lightning)


func _on_lightning(pos = null, _extra = null) -> void:
	var cam := get_viewport().get_camera_3d()
	var dist := 1200.0
	if pos is Vector3 and cam:
		dist = cam.global_position.distance_to(pos)
	_thunder(dist)


func _thunder(dist: float) -> void:
	## Sound travels about 343 m/s; far strikes are quieter and duller.
	var delay := clampf(dist / 343.0, 0.05, 8.0)
	var db := lerpf(0.0, -14.0, clampf(dist / 3000.0, 0.0, 1.0))
	var snd := "thunder_1" if dist < 900.0 else "thunder_2"
	thunders += 1
	get_tree().create_timer(delay, true).timeout.connect(_boom.bind(snd, db))


func _boom(sound: String, db: float) -> void:
	_thunder_player.stream = director.stream(sound)
	_thunder_player.volume_db = db + 3.0
	_thunder_player.pitch_scale = _rng.randf_range(0.85, 1.05)
	_thunder_player.play()
	director.played[sound] = director.played.get(sound, 0) + 1
