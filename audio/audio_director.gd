class_name AudioDirector
extends Node
## All game audio in one autoload ("Audio"). It finds the main scene by itself and listens to
## what is already there, so it needs no calls from the other modules to work:
##   - city ambience that follows camera height, building density, the coast and day or night
##   - music stems that crossfade between the mayor view, walking and driving
##   - the nearest AI cars as positional sound, plus the odd honk from a stuck driver
##   - footsteps, landing, car doors, engine with fake gears, tyre roll, skids, horn, crashes
##   - mayor UI clicks, tool sounds, buildings finishing, toasts and "not enough money"
##   - a whoosh for the dive down to the street and the rise back up
##
## Optional API for other modules (see audio/INTEGRATION.md):
##   Audio.play_ui("cash")                         one-shot, non-positional
##   Audio.play_at("crash", pos, -3.0)             one-shot at a world position
##   var p := Audio.attach_loop("siren_loop", node) looping sound that follows a node
##   Audio.set_volume("Music", 0.6)                bus volume, linear 0..1
##   Audio.music_enabled = false                   (M toggles it in game)
##
## Cost: about 15 streaming Ogg voices at most, no per-sample script work. Everything
## is synthesized by audio/tools/synth_audio.py.

const DIR := "res://audio/"

const SFX := [
	"ui_click", "ui_select", "ui_toggle", "notify", "error", "cash",
	"build_road", "build_zone", "bulldoze", "building_done",
	"whoosh_down", "whoosh_up",
	"step_1", "step_2", "step_3", "step_4", "land",
	"door_open", "door_close", "engine_start", "crash", "horn_distant",
	"horn_loop", "engine_idle_loop", "engine_load_loop", "road_roll_loop", "skid_loop",
	"traffic_car_loop", "siren_loop",
	"phone_ring", "radio_static", "mission_start", "checkpoint", "mission_passed", "mission_failed",
	"gun_pistol", "gun_shotgun", "gun_cop", "punch_swing", "punch_hit_1", "punch_hit_2", "body_hit",
	"bullet_impact", "ricochet", "bullet_metal", "explosion", "car_alarm_loop", "bank_alarm_loop",
	"siren_yelp_loop", "weapon_switch", "pickup", "carjack", "wasted", "busted",
	"thunder_1", "thunder_2", "radio_tune", "bus_stop",
]
const AMBIENCE := ["amb_city_day", "amb_city_night", "amb_birds", "amb_crickets", "amb_wind", "amb_crowd", "amb_sea", "amb_panic", "amb_room",
	"amb_rain_light", "amb_rain_heavy", "amb_rain_roof", "amb_gusts"]
const MUSIC := ["music_mayor", "music_street", "music_drive", "music_action"]

# Default bus levels in dB.
const BUSES := {"Music": -9.0, "Ambience": -5.0, "SFX": -1.0, "UI": -6.0}

const TRAFFIC_VOICES := 8
const TRAFFIC_RADIUS := 70.0
const ONESHOT_VOICES := 14
const GEARS := [0.0, 7.0, 14.0, 21.0, 28.0, 40.0]  # m/s where each fake gear tops out

# Main tool ids (scripts/main.gd Tool enum).
const TOOL_ROAD := 1
const TOOL_BULLDOZE := 5

var music_enabled := true:
	set(v):
		music_enabled = v
		var i := AudioServer.get_bus_index("Music")
		if i >= 0:
			AudioServer.set_bus_mute(i, not v)

var main = null                  # the main scene (scripts/main.gd), found automatically

# What the director thinks is going on, readable by tests and debug overlays.
var height := 300.0              # listener height above ground, m
var density := 0.0               # 0..1 how built-up the area around the listener is
var commerce := 0.0              # 0..1 share of that which is shops and offices
var water := 0.0                 # 0..1 how much sea is around
var night := 0.0                 # 0..1
var peds_near := 0
var music_weights := Vector4(1, 0, 0, 0)   # mayor, street, drive, action (linear)
var action := 0.0                # 0..1 mission / chase music wanted (set by ActionAudio)
var panic := 0.0                 # 0..1 people running nearby (set by ActionAudio)
var indoors := false             # inside an interior (set by ActionAudio)
var rain := 0.0                  # 0..1 (set by WeatherAudio from the game's weather)
var wind := 0.0                  # 0..1
var canyon := 0.0                # 0..1 how hemmed in by tall buildings the street listener is
var action_audio: ActionAudio
var weather_audio: WeatherAudio
var radio: CarRadio
var amb_gains := {}
var played := {}                 # sound name -> times started (for tests)

var _streams := {}
var _music: Array[AudioStreamPlayer] = []
var _amb := {}
var _amb_target := {}
var _oneshots: Array[AudioStreamPlayer3D] = []
var _oneshot_next := 0
var _ui: Array[AudioStreamPlayer] = []
var _ui_next := 0
var _traffic: Array[AudioStreamPlayer3D] = []
var _traffic_cars: Array = []
var _eng_idle: AudioStreamPlayer3D
var _eng_load: AudioStreamPlayer3D
var _roll: AudioStreamPlayer3D
var _skid: AudioStreamPlayer3D
var _horn: AudioStreamPlayer3D

var _city = null                 # City
var _street = null               # StreetMode
var _car = null                  # DrivableCar being driven
var _engine_on := 0.0            # 0..1 fade for the player's engine
var _engine_target := 0.0
var _rpm := 0.2
var _load := 0.0
var _prev_car_vel := Vector3.ZERO
var _crash_cool := 0.0
var _step_t := 0.0
var _was_floor := true
var _air_time := 0.0
var _prev_busy := false
var _prev_active := false
var _diving := false
var _sample_t := 0.0
var _traffic_t := 0.0
var _honk_cool := 0.0
var _horn_timer := 8.0
var _done_cool := 0.0
var _last_click := -1000
var _release_frame := -1
var _tool_frame := -1
var _prev_tool := -1
var _prev_overlay := -1
var _prev_speed := -1
var _rng := RandomNumberGenerator.new()
var _amb_lp: AudioEffectLowPassFilter
var _music_lp: AudioEffectLowPassFilter
var _sfx_reverb: AudioEffectReverb
var _sfx_echo: AudioEffectDelay


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_setup_buses()
	_load_streams()
	_build_players()
	get_tree().node_added.connect(_on_node_added)
	action_audio = ActionAudio.new()
	action_audio.name = "Action"
	action_audio.director = self
	add_child(action_audio)
	weather_audio = WeatherAudio.new()
	weather_audio.name = "Weather"
	weather_audio.director = self
	add_child(weather_audio)
	radio = CarRadio.new()
	radio.name = "Radio"
	radio.director = self
	add_child(radio)


# ------------------------------------------------------------------- public ---

func attach(main_node: Node) -> void:
	## Point the director at a main scene. Normally automatic (the current scene).
	main = main_node


func stream(sound: String) -> AudioStream:
	return _streams.get(sound)


func play_ui(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	var s: AudioStream = _streams.get(sound)
	if s == null:
		return
	played[sound] = played.get(sound, 0) + 1
	var p := _ui[_ui_next]
	_ui_next = (_ui_next + 1) % _ui.size()
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func play_at(sound: String, pos: Vector3, volume_db := 0.0, pitch := 1.0, unit_size := 8.0) -> AudioStreamPlayer3D:
	var s: AudioStream = _streams.get(sound)
	if s == null:
		return null
	played[sound] = played.get(sound, 0) + 1
	var p := _oneshots[_oneshot_next]
	_oneshot_next = (_oneshot_next + 1) % _oneshots.size()
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.unit_size = unit_size
	p.max_distance = unit_size * 60.0
	p.global_position = pos
	p.play()
	return p


func attach_loop(sound: String, node: Node3D, volume_db := 0.0, unit_size := 10.0) -> AudioStreamPlayer3D:
	## A looping sound parented to `node` (freed with it). Stop it with `queue_free()`.
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams.get(sound)
	p.bus = "SFX"
	p.volume_db = volume_db
	p.unit_size = unit_size
	p.max_distance = unit_size * 40.0
	p.autoplay = true
	node.add_child(p)
	return p


func set_volume(bus: String, linear: float) -> void:
	var i := AudioServer.get_bus_index(bus)
	if i >= 0:
		AudioServer.set_bus_volume_db(i, BUSES.get(bus, 0.0) + linear_to_db(maxf(linear, 0.0001)))


# -------------------------------------------------------------------- setup ---

func _setup_buses() -> void:
	for name in BUSES:
		var i := AudioServer.get_bus_index(name)
		if i < 0:
			AudioServer.add_bus()
			i = AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, name)
			AudioServer.set_bus_send(i, "Master")
		AudioServer.set_bus_volume_db(i, BUSES[name])
	# Ambience gets duller the higher the camera; music a little at night in the mayor view.
	_amb_lp = AudioEffectLowPassFilter.new()
	_amb_lp.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(AudioServer.get_bus_index("Ambience"), _amb_lp)
	_music_lp = AudioEffectLowPassFilter.new()
	_music_lp.cutoff_hz = 20000.0
	var mi := AudioServer.get_bus_index("Music")
	AudioServer.add_bus_effect(mi, _music_lp)
	AudioServer.set_bus_effect_enabled(mi, 0, false)
	# A short street "room" so footsteps and doors sit between buildings; only on at street level.
	_sfx_reverb = AudioEffectReverb.new()
	_sfx_reverb.room_size = 0.35
	_sfx_reverb.damping = 0.6
	_sfx_reverb.spread = 0.8
	_sfx_reverb.wet = 0.09
	_sfx_reverb.dry = 1.0
	_sfx_reverb.predelay_msec = 25.0
	var si := AudioServer.get_bus_index("SFX")
	AudioServer.add_bus_effect(si, _sfx_reverb)
	AudioServer.set_bus_effect_enabled(si, 0, false)
	# Slap-back echo off tall walls; levels follow `canyon`.
	_sfx_echo = AudioEffectDelay.new()
	_sfx_echo.dry = 1.0
	_sfx_echo.tap1_active = true
	_sfx_echo.tap1_delay_ms = 140.0
	_sfx_echo.tap1_pan = -0.4
	_sfx_echo.tap2_active = true
	_sfx_echo.tap2_delay_ms = 255.0
	_sfx_echo.tap2_pan = 0.45
	_sfx_echo.feedback_active = false
	AudioServer.add_bus_effect(si, _sfx_echo)
	AudioServer.set_bus_effect_enabled(si, 1, false)


func _load_streams() -> void:
	for group in [["sfx/", SFX], ["ambience/", AMBIENCE], ["music/", MUSIC]]:
		for sound in group[1]:
			var path: String = DIR + group[0] + sound + ".ogg"
			if not ResourceLoader.exists(path):
				push_warning("Audio: missing " + path)
				continue
			var s: AudioStream = load(path)
			if s is AudioStreamOggVorbis:
				(s as AudioStreamOggVorbis).loop = sound.ends_with("_loop") or group[0] != "sfx/"
			_streams[sound] = s


func _player(sound: String, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = _streams.get(sound)
	p.bus = bus
	add_child(p)
	return p


func _player3d(sound: String, unit_size := 6.0) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams.get(sound)
	p.bus = "SFX"
	p.unit_size = unit_size
	p.max_distance = unit_size * 25.0
	p.attenuation_filter_cutoff_hz = 6000.0
	p.attenuation_filter_db = -12.0
	add_child(p)
	return p


func _build_players() -> void:
	for sound in MUSIC:
		var p := _player(sound, "Music")
		p.volume_db = -80.0
		_music.append(p)
	for p in _music:
		if p.stream:
			p.play()
	for sound in AMBIENCE:
		var p := _player(sound, "Ambience")
		p.volume_db = -80.0
		if p.stream:
			p.play()
		p.stream_paused = true
		_amb[sound] = p
		_amb_target[sound] = 0.0
		amb_gains[sound] = 0.0
	for i in ONESHOT_VOICES:
		_oneshots.append(_player3d("ui_click"))
	for i in 4:
		_ui.append(_player("ui_click", "UI"))
	for i in TRAFFIC_VOICES:
		var p := _player3d("traffic_car_loop", 7.0)
		p.max_distance = TRAFFIC_RADIUS + 10.0
		_traffic.append(p)
		_traffic_cars.append(null)
	_eng_idle = _player3d("engine_idle_loop", 9.0)
	_eng_load = _player3d("engine_load_loop", 9.0)
	_roll = _player3d("road_roll_loop", 8.0)
	_skid = _player3d("skid_loop", 10.0)
	_horn = _player3d("horn_loop", 14.0)


# ------------------------------------------------------------ wiring (auto) ---

func _on_node_added(n: Node) -> void:
	if n is BaseButton and not n.pressed.is_connected(_on_button):
		n.pressed.connect(_on_button)


func _on_button() -> void:
	_last_click = Time.get_ticks_msec()
	play_ui("ui_click")


func _find_main() -> void:
	if main == null or not is_instance_valid(main):
		main = null
		var s := get_tree().current_scene
		if s and "city" in s:
			main = s
	if main == null:
		return
	var c = main.get("city")
	if c != _city and c != null:
		_city = c
		if c.has_signal("cells_changed"):
			c.cells_changed.connect(_on_cells_changed)
			c.building_added.connect(_on_building_added)
			c.message.connect(_on_city_message)
	var s = main.get("street")
	if s != _street and s != null:
		_street = s
		s.vehicle_changed.connect(_on_vehicle_changed)


func _input(e: InputEvent) -> void:
	# Remember the frame a build drag ends; main applies the tool in this same frame.
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and not e.pressed:
		_release_frame = Engine.get_process_frames()


func _unhandled_key_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	if k and k.pressed and not k.echo and k.physical_keycode == KEY_M:
		music_enabled = not music_enabled


func _on_cells_changed(_r: Rect2i) -> void:
	var f := Engine.get_process_frames()
	if main == null or f != _release_frame or f == _tool_frame:
		return
	_tool_frame = f
	var t: int = main.get("tool")
	if t == TOOL_ROAD:
		play_ui("build_road", 0.0, _rng.randf_range(0.95, 1.05))
	elif t == TOOL_BULLDOZE:
		play_ui("bulldoze", 0.0, _rng.randf_range(0.95, 1.05))
	elif t > TOOL_ROAD and t < TOOL_BULLDOZE:
		play_ui("build_zone", -2.0, [1.0, 1.122, 1.335][t - 2])


func _on_building_added(id: int, animate: bool) -> void:
	if not animate or _done_cool > 0.0 or _city == null:
		return
	var b: Dictionary = _city.buildings.get(id, {})
	if b.is_empty():
		return
	_done_cool = 0.3
	play_at("building_done", _city.building_center(b), -4.0, _rng.randf_range(0.9, 1.15), 60.0)


func _on_city_message(text: String) -> void:
	if text.begins_with("Not enough"):
		play_ui("error")
	else:
		play_ui("notify", -3.0)


func _on_vehicle_changed(c: Node) -> void:
	if c != null:
		_car = c
		_prev_car_vel = (c as RigidBody3D).linear_velocity if c is RigidBody3D else Vector3.ZERO
		var pos := (c as Node3D).global_position
		# The character walks to the door and climbs in first; time the doors to that.
		var walk := 0.0
		var climb := 0.8
		var p = _street.get("player") if _street else null
		if p and c.has_method("exit_point"):
			walk = minf(p.global_position.distance_to(c.exit_point()) / 3.0, 1.5)
		if p and p.get("visual") and p.visual.has_method("clip_length"):
			climb = clampf(p.visual.clip_length("EnterCar"), 0.3, 2.5)
		_later(walk + 0.05, _door_open.bind(c, pos, -2.0))
		_later(walk + climb * 0.85, _door_close.bind(c, pos, -1.0))
		_later(walk + climb + 0.15, _engine_start.bind(c))
		_later(walk + climb + 0.7, _engine_running.bind(c))
	else:
		var old = _car
		_car = null
		_engine_target = 0.0
		if old and is_instance_valid(old):
			var pos: Vector3 = old.global_position
			play_at("door_open", pos, -3.0)
			_later(0.8, _door_close.bind(old, pos, -1.0))


func _door_open(c: Object, pos: Vector3, db: float) -> void:
	play_at("door_open", _pos_of(c, pos), db)


func _door_close(c: Object, pos: Vector3, db: float) -> void:
	play_at("door_close", _pos_of(c, pos), db)


func _engine_start(c: Object) -> void:
	if _car == c and is_instance_valid(c):
		play_at("engine_start", (c as Node3D).global_position, 0.0)


func _engine_running(c: Object) -> void:
	if _car == c:
		_engine_target = 1.0


func _pos_of(n: Object, fallback: Vector3) -> Vector3:
	return (n as Node3D).global_position if is_instance_valid(n) else fallback


func _later(sec: float, f: Callable) -> void:
	get_tree().create_timer(sec, true).timeout.connect(f)


# -------------------------------------------------------------- per frame ---

func _process(delta: float) -> void:
	_find_main()
	_crash_cool = maxf(_crash_cool - delta, 0.0)
	_honk_cool = maxf(_honk_cool - delta, 0.0)
	_done_cool = maxf(_done_cool - delta, 0.0)
	var cam := get_viewport().get_camera_3d()
	var listener := cam.global_position if cam else Vector3(0, 300, 0)
	var started: bool = main != null and main.get("started") == true
	var active: bool = _street != null and _street.get("active") == true
	var busy: bool = _street != null and _street.get("busy") == true

	# Dive and rise.
	if busy and not _prev_busy:
		_diving = not _prev_active
		play_ui("whoosh_down" if _diving else "whoosh_up", -4.0)
	_prev_busy = busy
	_prev_active = active
	var street_bound := active or (busy and _diving)

	height = maxf(listener.y, 1.5)
	var focus := listener
	if not street_bound and main and main.get("cam"):
		focus = main.get("cam").focus
	if _city:
		night = _night(_city.time_of_day())

	_sample_t -= delta
	if _sample_t <= 0.0:
		_sample_t = 0.5
		_sample_area(focus, listener, active)

	_update_ambience(delta, street_bound, started)
	_update_music(delta, street_bound, started)
	_update_mayor_ui()
	_update_car(delta)
	_traffic_t -= delta
	if _traffic_t <= 0.0:
		_traffic_t = 0.2
		_assign_traffic(listener)
	_follow_traffic()
	_ambient_horns(delta, focus)

	_update_street_space(active)


func _physics_process(delta: float) -> void:
	if _street == null or not _street.get("active"):
		_was_floor = true
		return
	var p: CharacterBody3D = _street.get("player")
	if p == null:
		return
	if _car != null:
		_crash_check()
		return
	var on_floor := p.is_on_floor()
	var hs := Vector2(p.velocity.x, p.velocity.z).length()
	if on_floor:
		if not _was_floor and _air_time > 0.25:
			play_at("land", p.global_position, linear_to_db(clampf(_air_time, 0.4, 1.0)) - 2.0, _rng.randf_range(0.9, 1.1))
			_step_t = 0.2
		_air_time = 0.0
		if hs > 0.6:
			_step_t -= delta
			if _step_t <= 0.0:
				_step_t = 1.0 / (1.4 + hs * 0.27)
				var loud := clampf(hs / 7.2, 0.45, 1.0)
				play_at("step_%d" % (_rng.randi() % 4 + 1), p.global_position, linear_to_db(loud) - 3.0, _rng.randf_range(0.9, 1.1), 5.0)
		else:
			_step_t = 0.06
	else:
		_air_time += delta
	_was_floor = on_floor


func _update_street_space(active: bool) -> void:
	## Street reverb, wider and wetter between tall buildings, plus echo off the walls.
	## Indoors it's a plain room: some reverb, no echo.
	var si := AudioServer.get_bus_index("SFX")
	var c := canyon if active and not indoors else 0.0
	AudioServer.set_bus_effect_enabled(si, 0, active)
	AudioServer.set_bus_effect_enabled(si, 1, c > 0.05)
	if indoors:
		_sfx_reverb.room_size = 0.5
		_sfx_reverb.wet = 0.16
		_sfx_reverb.damping = 0.5
		_sfx_reverb.predelay_msec = 12.0
	else:
		_sfx_reverb.room_size = lerpf(0.35, 0.72, c)
		_sfx_reverb.wet = lerpf(0.09, 0.2, c)
		_sfx_reverb.damping = lerpf(0.6, 0.35, c)
		_sfx_reverb.predelay_msec = lerpf(25.0, 60.0, c)
	_sfx_echo.tap1_level_db = lerpf(-24.0, -10.0, c)
	_sfx_echo.tap2_level_db = lerpf(-28.0, -14.0, c)


func _night(hr: float) -> float:
	if hr >= 20.5 or hr < 4.5:
		return 1.0
	if hr >= 18.5:
		return (hr - 18.5) / 2.0
	if hr < 6.5:
		return 1.0 - (hr - 4.5) / 2.0
	return 0.0


func _sample_area(focus: Vector3, listener: Vector3, street: bool) -> void:
	if _city == null:
		density = 0.0
		commerce = 0.0
		water = 1.0 if main == null else 0.3
		return
	var c: Vector2i = _city.world_to_cell(focus)
	var r := clampi(int(height / 24.0), 2, 12)
	var cells := 0
	var built := 0.0
	var com := 0.0
	var sea := 0
	var land: PackedByteArray = _city.land
	var bld: PackedInt32Array = _city.bld
	var size: int = City.SIZE
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			cells += 1
			if x < 0 or y < 0 or x >= size or y >= size:
				sea += 1
				continue
			var i := y * size + x
			if land[i] == 0:
				sea += 1
			elif bld[i] >= 0:
				var b: Dictionary = _city.buildings.get(bld[i], {})
				var w := float(b.get("stage", 1)) * float(b.get("size", 1))
				built += w
				if b.get("zone", 0) == 2:
					com += w
	density = clampf(built / (cells * 1.4), 0.0, 1.0)
	commerce = com / built if built > 0.0 else 0.0
	water = float(sea) / cells
	canyon = _canyon(c, street, land, bld, size)
	peds_near = 0
	if street and main and main.get("life"):
		var crowd = main.life.crowd
		if crowd:
			for ped in crowd.peds:
				if ped.pos.distance_squared_to(listener) < 900.0:
					peds_near += 1


func _canyon(c: Vector2i, street: bool, land: PackedByteArray, bld: PackedInt32Array, size: int) -> float:
	## How walled in the street listener is: tall buildings in the cells within about 36 m.
	if not street:
		return 0.0
	var tall := 0.0
	var cells := 0
	for y in range(c.y - 3, c.y + 4):
		for x in range(c.x - 3, c.x + 4):
			cells += 1
			if x < 0 or y < 0 or x >= size or y >= size:
				continue
			var i := y * size + x
			if land[i] != 0 and bld[i] >= 0:
				var b: Dictionary = _city.buildings.get(bld[i], {})
				var h := float(b.get("stage", 1)) * (2.0 if b.get("size", 1) == 2 else 1.0)
				tall += clampf((h - 1.0) / 3.0, 0.0, 1.0)
	return clampf(tall / (cells * 0.45), 0.0, 1.0)


func _smooth01(a: float, b: float, x: float) -> float:
	return smoothstep(a, b, x)


func _update_ambience(delta: float, street: bool, started: bool) -> void:
	var day := 1.0 - night
	var ground := 1.0 - smoothstep(60.0, 700.0, height)
	var low := 1.0 - smoothstep(40.0, 320.0, height)
	var d := density
	_amb_target["amb_city_day"] = (0.15 + 0.85 * d) * day * (0.35 + 0.65 * ground) if started else 0.0
	_amb_target["amb_city_night"] = (0.15 + 0.7 * d) * night * (0.35 + 0.65 * ground) if started else 0.0
	_amb_target["amb_birds"] = day * (1.0 - 0.8 * d) * low * (1.0 - 0.5 * water)
	_amb_target["amb_crickets"] = night * (1.0 - 0.85 * d) * low * 0.8
	_amb_target["amb_wind"] = 0.12 + 0.8 * smoothstep(120.0, 700.0, height)
	var crowd := 0.0
	if street:
		crowd = clampf(peds_near / 18.0, 0.0, 1.0) * (1.0 - 0.4 * night)
	elif height < 140.0:
		crowd = d * commerce * low * 0.5 * day
	_amb_target["amb_crowd"] = crowd
	_amb_target["amb_sea"] = water * (1.0 - 0.6 * smoothstep(150.0, 900.0, height))
	_amb_target["amb_panic"] = panic if street else 0.0
	_amb_target["amb_crowd"] *= 1.0 - panic
	_amb_target["amb_room"] = 0.8 if indoors else 0.0
	# Weather. Rain is heard from anywhere, softer up high; in a car it drums on the roof.
	var in_car := street and _car != null
	var heavy := smoothstep(0.35, 0.85, rain)
	var outside := sqrt(rain) * (0.45 + 0.55 * ground) * (0.35 if in_car else 1.0) if started else 0.0
	_amb_target["amb_rain_light"] = outside * (1.0 - heavy)
	_amb_target["amb_rain_heavy"] = outside * heavy
	_amb_target["amb_rain_roof"] = sqrt(rain) * 0.9 if in_car else 0.0
	# Gusts at street level, funnelled and whistling between tall buildings.
	var gust := clampf(wind * (0.5 + 0.5 * low) * (1.0 + 0.6 * canyon) + (0.12 * canyon if street else 0.0), 0.0, 1.0)
	_amb_target["amb_gusts"] = gust * (0.3 if in_car else 1.0) if started else 0.0
	_amb_target["amb_wind"] += 0.4 * wind
	if indoors:
		for k in _amb_target:
			if k != "amb_room":
				_amb_target[k] *= 0.15
	for k in _amb:
		var g: float = move_toward(amb_gains[k], _amb_target[k], delta * 0.45)
		amb_gains[k] = g
		var p: AudioStreamPlayer = _amb[k]
		p.volume_db = linear_to_db(maxf(g, 0.0001))
		p.stream_paused = g < 0.003
	# From street level to the clouds the city turns into a muffled hum.
	_amb_lp.cutoff_hz = 20000.0 * pow(1500.0 / 20000.0, smoothstep(30.0, 900.0, height))
	if indoors:
		_amb_lp.cutoff_hz = minf(_amb_lp.cutoff_hz, 4000.0)  # room tone stays clear, the city is quiet


func _update_music(delta: float, street: bool, started: bool) -> void:
	var target := Vector4(0.75 if not started else 1.0, 0.0, 0.0, 0.0)
	if street:
		var drive := 0.0
		if _car and is_instance_valid(_car) and _car.has_method("speed"):
			drive = clampf((absf(_car.speed()) - 3.0) / 15.0, 0.0, 1.0)
		# Missions and chases swap the street groove for the action stem.
		target = Vector4(0.0, 1.0 - action, drive * (1.0 - action), action)
		# The car radio replaces the street groove; mission music still plays under it.
		if radio and radio.gain > 0.0:
			target.y *= 1.0 - radio.gain
			target.z *= 1.0 - radio.gain
			target.w *= 1.0 - 0.4 * radio.gain
	# The whole crossfade takes about as long as the camera dive.
	var rate := delta / 2.8
	music_weights.x = move_toward(music_weights.x, target.x, rate)
	music_weights.y = move_toward(music_weights.y, target.y, rate)
	music_weights.z = move_toward(music_weights.z, target.z, delta / 1.5)
	music_weights.w = move_toward(music_weights.w, target.w, delta / 2.0)
	for i in _music.size():
		var w: float = music_weights[i]
		# Equal-power-ish curve so the middle of a crossfade doesn't dip.
		_music[i].volume_db = linear_to_db(maxf(sin(w * PI * 0.5), 0.0001))
	var mi := AudioServer.get_bus_index("Music")
	var lp := lerpf(20000.0, 5500.0, night) if not street else 20000.0
	_music_lp.cutoff_hz = lerpf(_music_lp.cutoff_hz, lp, minf(delta, 1.0))
	AudioServer.set_bus_effect_enabled(mi, 0, _music_lp.cutoff_hz < 19000.0)


func _update_mayor_ui() -> void:
	if main == null or not main.get("started"):
		return
	var t: int = main.get("tool")
	var o: int = main.get("overlay")
	var s: int = main.get("speed_index")
	var clicked := Time.get_ticks_msec() - _last_click < 200
	if _prev_tool >= 0 and not clicked and not _street_active():
		if t != _prev_tool:
			play_ui("ui_select")
		elif o != _prev_overlay or s != _prev_speed:
			play_ui("ui_toggle", -2.0)
	_prev_tool = t
	_prev_overlay = o
	_prev_speed = s


func _street_active() -> bool:
	return _street != null and (_street.get("active") or _street.get("busy"))


func _update_car(delta: float) -> void:
	_engine_on = move_toward(_engine_on, _engine_target, delta * (1.5 if _engine_target > 0.0 else 3.0))
	var car_ok := _car != null and is_instance_valid(_car)
	if _engine_on <= 0.001 or not car_ok:
		for p in [_eng_idle, _eng_load, _roll, _skid, _horn]:
			if p.playing:
				p.stop()
		return
	var pos: Vector3 = _car.global_position
	var v := absf(_car.speed()) if _car.has_method("speed") else 0.0
	var thr := absf(float(_car.get("throttle"))) if _car.get("throttle") != null else 0.0
	var g := 0
	while g < GEARS.size() - 2 and v >= GEARS[g + 1]:
		g += 1
	var frac := clampf((v - GEARS[g]) / (GEARS[g + 1] - GEARS[g]), 0.0, 1.0)
	var rpm := lerpf(0.2 if g == 0 else 0.42, 1.0, frac)
	if v < 1.0:
		rpm = maxf(rpm, 0.2 + 0.55 * thr)
	_rpm = lerpf(_rpm, rpm, 1.0 - exp(-delta * 7.0))
	_load = lerpf(_load, thr, 1.0 - exp(-delta * 6.0))
	var pitch := 0.7 + _rpm * 1.7
	for p in [_eng_idle, _eng_load, _roll, _skid, _horn]:
		p.global_position = pos
	_loop(_eng_idle, linear_to_db(maxf(_engine_on * (1.0 - 0.7 * _load), 0.0001)) - 4.0, pitch)
	_loop(_eng_load, linear_to_db(maxf(_engine_on * _load, 0.0001)) - 2.0, pitch)
	var roll := clampf(v / 30.0, 0.0, 1.0)
	_loop(_roll, linear_to_db(maxf(roll, 0.0001)) - 3.0, 0.7 + v / 45.0, roll > 0.02)
	var slip := 0.0
	if _car is RigidBody3D:
		slip = absf((_car as RigidBody3D).linear_velocity.dot(_car.global_basis.x))
	if InputMap.has_action("street_handbrake") and Input.is_action_pressed("street_handbrake") and v > 5.0:
		slip += 4.0
	var sk := smoothstep(2.0, 6.0, slip) * clampf(v / 8.0, 0.0, 1.0)
	_loop(_skid, linear_to_db(maxf(sk, 0.0001)) - 3.0, 0.95 + 0.1 * sk, sk > 0.02)
	var honk := InputMap.has_action("street_horn") and Input.is_action_pressed("street_horn") and _engine_target > 0.0
	_loop(_horn, -2.0, 1.0, honk)


func _loop(p: AudioStreamPlayer3D, db: float, pitch: float, on := true) -> void:
	if not on:
		if p.playing:
			p.stop()
		return
	p.volume_db = db
	p.pitch_scale = clampf(pitch, 0.3, 3.5)
	if not p.playing:
		p.play()


func _crash_check() -> void:
	if not (_car is RigidBody3D) or not is_instance_valid(_car):
		return
	var vel := (_car as RigidBody3D).linear_velocity
	var dv := (vel - _prev_car_vel).length()
	_prev_car_vel = vel
	if dv > 4.0 and _crash_cool <= 0.0:
		_crash_cool = 0.6
		play_at("crash", _car.global_position, linear_to_db(clampf(dv / 14.0, 0.35, 1.0)), _rng.randf_range(0.9, 1.1), 12.0)


func _assign_traffic(listener: Vector3) -> void:
	var cars: Array = []
	if main and main.get("life") and height < 150.0:
		var traffic = main.life.traffic
		if traffic:
			var r2 := TRAFFIC_RADIUS * TRAFFIC_RADIUS
			for c in traffic.cars:
				var d2: float = c.pos.distance_squared_to(listener)
				if d2 < r2:
					cars.append([d2, c])
					if c.stuck > 3.0 and _honk_cool <= 0.0 and d2 < 3600.0 and _rng.randf() < 0.03:
						_honk_cool = 5.0
						play_at("horn_distant", c.pos + Vector3.UP, -6.0, _rng.randf_range(0.85, 1.15), 10.0)
	cars.sort_custom(func(a, b): return a[0] < b[0])
	for i in _traffic.size():
		var p := _traffic[i]
		if i < cars.size():
			_traffic_cars[i] = cars[i][1]
			if not p.playing:
				p.play(_rng.randf() * 1.9)
		else:
			_traffic_cars[i] = null
			if p.playing:
				p.stop()


func _follow_traffic() -> void:
	for i in _traffic.size():
		var c = _traffic_cars[i]
		if c == null:
			continue
		var p := _traffic[i]
		p.global_position = c.pos + Vector3.UP * 0.6
		var sp := clampf(c.v / 12.5, 0.0, 1.3)
		p.pitch_scale = 0.65 + 0.6 * sp
		p.volume_db = linear_to_db(0.3 + 0.7 * minf(sp, 1.0)) - 3.0


func _ambient_horns(delta: float, focus: Vector3) -> void:
	_horn_timer -= delta
	if _horn_timer > 0.0:
		return
	_horn_timer = _rng.randf_range(7.0, 22.0)
	if _city == null or density < 0.2 or night > 0.7 or height > 450.0:
		return
	var a := _rng.randf() * TAU
	var dist := _rng.randf_range(60.0, 180.0)
	var pos := Vector3(focus.x + cos(a) * dist, 1.0, focus.z + sin(a) * dist)
	play_at("horn_distant", pos, -8.0 + 6.0 * density, _rng.randf_range(0.85, 1.15), 30.0)
