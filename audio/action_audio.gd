class_name ActionAudio
extends Node
## Round-2 street action sound, owned by AudioDirector (one child node, no setup needed).
## Hooks into signals the other modules already expose:
##   player/   StreetCombat fired / weapon_changed / reloading, StreetMode wanted_changed / wasted / busted,
##             StreetPlayer damaged, DrivableCar exploded / damaged, Pickup taken,
##             StreetMode hit_landed (optional, when player/ adds it)
##   citylife/ Police siren_list(), Traffic car_taken / bus_stopped, Crowd peds[].flee,
##             Police officer_fired (optional, when citylife/ adds it)
##   missions/ MissionDirector started / passed / failed / step_changed
##   interiors/ InteriorManager interior_entered / interior_exited
## What it drives on the director: `action` (mission music), `panic` (screaming crowd bed) and
## `indoors` (muffles the city, room tone on).

const SIREN_VOICES := 3
const ALARM_SECONDS := 12.0
const BANK_ALARM_SECONDS := 90.0

var director: AudioDirector
var mission_on := false
var wanted := 0
var bank_alarm := 0.0            # seconds the bank alarm keeps ringing
var interior_id := ""

var _main = null
var _street = null
var _combat = null
var _life = null
var _missions = null
var _interiors = null
var _sirens: Array[AudioStreamPlayer3D] = []
var _siren_goal: Array[Vector3] = []
var _siren_t := 0.0
var _panic_t := 0.0
var _alarms := {}                # car instance id -> AudioStreamPlayer3D
var _bank_in: AudioStreamPlayer
var _bank_out: AudioStreamPlayer3D
var _bank_pos := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
var _hit_frame := -1
var _hits_this_frame := 0


func _ready() -> void:
	_rng.randomize()
	for i in SIREN_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.stream = director.stream("siren_yelp_loop" if i == 1 else "siren_loop")
		p.bus = "SFX"
		p.unit_size = 22.0
		p.max_distance = 650.0
		p.attenuation_filter_cutoff_hz = 5000.0
		p.attenuation_filter_db = -10.0
		p.volume_db = -3.0
		add_child(p)
		_sirens.append(p)
		_siren_goal.append(Vector3.ZERO)
	_bank_in = AudioStreamPlayer.new()
	_bank_in.stream = director.stream("bank_alarm_loop")
	_bank_in.bus = "SFX"
	_bank_in.volume_db = -7.0
	add_child(_bank_in)
	_bank_out = AudioStreamPlayer3D.new()
	_bank_out.stream = director.stream("bank_alarm_loop")
	_bank_out.bus = "SFX"
	_bank_out.unit_size = 25.0
	_bank_out.max_distance = 400.0
	add_child(_bank_out)
	get_tree().node_added.connect(_on_node_added)


# ------------------------------------------------------------------- wiring ---

func _on_node_added(n: Node) -> void:
	if n.has_signal("exploded") and n.has_signal("damaged") and n is Node3D:
		n.exploded.connect(_on_exploded)
		n.damaged.connect(_on_car_damaged.bind(n))
	elif n.has_signal("taken") and n is Node3D:
		n.taken.connect(_on_pickup.bind(n))


func _wire() -> void:
	var m = director.main
	if m == null:
		return
	if m != _main:
		_main = m
	var s = m.get("street")
	if s != null and s != _street:
		_street = s
		s.wanted_changed.connect(_on_wanted)
		s.wasted.connect(func(): director.play_ui("wasted", -1.0))
		s.busted.connect(func(): director.play_ui("busted", -1.0))
		if s.has_signal("hit_landed"):
			s.hit_landed.connect(_on_hit)
		var p = s.get("player")
		if p and p.has_signal("damaged"):
			p.damaged.connect(_on_player_damaged)
	if _street != null:
		var c = _street.get("combat")
		if c != null and c != _combat:
			_combat = c
			c.fired.connect(_on_fired)
			c.weapon_changed.connect(func(_id): director.play_ui("weapon_switch", -4.0))
			if c.has_signal("reloading"):
				c.reloading.connect(_on_reloading)
	var l = m.get("life")
	if l != null and l != _life and l.get("traffic") != null:
		_life = l
		l.traffic.car_taken.connect(_on_car_taken)
		if l.traffic.has_signal("bus_stopped"):
			l.traffic.bus_stopped.connect(_on_bus_stopped)
		var police = l.get("police")
		if police and police.has_signal("officer_fired"):
			police.officer_fired.connect(_on_officer_fired)
	var ms = m.get("missions")
	if ms != null and ms != _missions and ms.get("director") != null:
		_missions = ms
		var d = ms.director
		d.started.connect(func(_m): mission_on = true)
		d.passed.connect(func(_m): mission_on = false)
		d.failed.connect(func(_m): mission_on = false)
		d.step_changed.connect(_on_step)
	var it = m.get("interiors")
	if it != null and it != _interiors and it.has_signal("interior_entered"):
		_interiors = it
		it.interior_entered.connect(_on_interior_entered)
		it.interior_exited.connect(_on_interior_exited)


# ------------------------------------------------------------------- events ---

func _player_pos() -> Vector3:
	if _street and _street.get("player"):
		return _street.player.global_position
	return Vector3.ZERO


func _on_fired(id: StringName) -> void:
	var pos := _player_pos() + Vector3.UP
	match id:
		&"fists":
			director.play_at("punch_swing", pos, -6.0, _rng.randf_range(0.9, 1.15), 4.0)
		&"pistol":
			director.play_at("gun_pistol", pos, 0.0, _rng.randf_range(0.95, 1.05), 22.0)
		&"shotgun":
			director.play_at("gun_shotgun", pos, 1.0, _rng.randf_range(0.96, 1.04), 26.0)


func _on_hit(kind: StringName, pos: Vector3, weapon: StringName) -> void:
	# A shotgun blast reports every pellet; three impact sounds per frame is plenty.
	var f := Engine.get_process_frames()
	if f != _hit_frame:
		_hit_frame = f
		_hits_this_frame = 0
	_hits_this_frame += 1
	if _hits_this_frame > 3:
		return
	var fists := weapon == &"fists"
	match kind:
		&"ped", &"officer":
			if fists:
				director.play_at("punch_hit_%d" % (_rng.randi() % 2 + 1), pos, -1.0, _rng.randf_range(0.9, 1.1), 6.0)
			else:
				director.play_at("body_hit", pos, -2.0, _rng.randf_range(0.9, 1.1), 6.0)
		&"car":
			director.play_at("bullet_metal", pos, -6.0 if fists else -1.0, _rng.randf_range(0.85, 1.15), 8.0)
		&"world":
			if not fists:
				var s := "ricochet" if _rng.randf() < 0.3 else "bullet_impact"
				director.play_at(s, pos, -3.0, _rng.randf_range(0.85, 1.15), 8.0)


func _on_officer_fired(pos: Vector3) -> void:
	director.play_at("gun_cop", pos + Vector3.UP * 1.3, -1.0, _rng.randf_range(0.93, 1.07), 22.0)


func _on_player_damaged(_amount: float, _from: Vector3) -> void:
	director.play_at("body_hit", _player_pos() + Vector3.UP, -4.0, _rng.randf_range(0.85, 1.0), 5.0)


func _on_wanted(stars: int) -> void:
	if stars > wanted:
		director.play_ui("radio_static", -9.0)  # the police band picks you up
	wanted = stars


func _on_car_taken(pos: Vector3, _fwd: Vector3) -> void:
	director.play_at("carjack", pos + Vector3.UP, 0.0, _rng.randf_range(0.95, 1.05), 8.0)


func _on_reloading(id: StringName) -> void:
	var p = _street.get("player") if _street else null
	if p == null:
		return
	var snd := "reload_shotgun" if id == &"shotgun" else "reload_pistol"
	director.play_at(snd, p.global_position + Vector3.UP, -3.0, 1.0, 5.0)


func _on_bus_stopped(car, _stop) -> void:
	if car == null or not ("pos" in car):
		return
	var pos: Vector3 = car.pos
	director.play_at("bus_stop", pos + Vector3.UP * 1.5, -3.0, _rng.randf_range(0.95, 1.05), 9.0)


func _on_exploded(car: Node3D) -> void:
	_stop_alarm(car)
	director.play_at("explosion", car.global_position + Vector3.UP, 2.0, _rng.randf_range(0.9, 1.05), 40.0)


func _on_car_damaged(_amount: float, car: Node3D) -> void:
	# An empty parked car that gets hit sets its alarm off.
	if not is_instance_valid(car) or car.get("driver") != null or car.get("wrecked") == true:
		return
	var id := car.get_instance_id()
	if _alarms.has(id) and is_instance_valid(_alarms[id]):
		return
	var p := director.attach_loop("car_alarm_loop", car, -4.0, 12.0)
	_alarms[id] = p
	get_tree().create_timer(ALARM_SECONDS).timeout.connect(_stop_alarm.bind(car))


func _stop_alarm(car: Object) -> void:
	if car == null:
		return
	var id := car.get_instance_id()
	var p = _alarms.get(id)
	_alarms.erase(id)
	if p != null and is_instance_valid(p):
		p.queue_free()


func _on_pickup(a = null, b = null) -> void:
	# Pickup emits taken(kind); the bound pickup node comes after it.
	var n = b if b is Node3D else a
	if n is Node3D and is_instance_valid(n):
		director.play_at("pickup", n.global_position + Vector3.UP * 0.5, -2.0, 1.0, 6.0)


func _on_step(m) -> void:
	# The bank job: the alarm goes off once you start on the vault, and keeps ringing a while.
	var st: Dictionary = m.step() if m.has_method("step") else {}
	if st.get("marker", "") == "vault" and bank_alarm <= 0.0:
		bank_alarm = BANK_ALARM_SECONDS
		var slot: Dictionary = m.slots.get(st.get("at", "start"), {})
		_bank_pos = slot.get("pos", _player_pos())


func _on_interior_entered(id: String, _b: Dictionary) -> void:
	interior_id = id
	director.indoors = true


func _on_interior_exited(_id: String, _b: Dictionary) -> void:
	interior_id = ""
	director.indoors = false


# ---------------------------------------------------------------- per frame ---

func _process(delta: float) -> void:
	_wire()
	var cam := get_viewport().get_camera_3d()
	var listener := cam.global_position if cam else Vector3.ZERO
	_update_sirens(delta, listener)
	_panic_t -= delta
	if _panic_t <= 0.0:
		_panic_t = 0.5
		_update_panic(listener)
	var w: int = _street.get("wanted") if _street and _street.get("wanted") != null else wanted
	director.action = 1.0 if mission_on or w >= 2 else 0.0
	_update_bank(delta)


func _update_sirens(delta: float, listener: Vector3) -> void:
	_siren_t -= delta
	if _siren_t <= 0.0:
		_siren_t = 0.2
		var list: Array = []
		var police = _life.get("police") if _life else null
		if police and police.has_method("siren_list"):
			list = police.siren_list()
		list.sort_custom(func(a, b): return a[0].distance_squared_to(listener) < b[0].distance_squared_to(listener))
		for i in _sirens.size():
			var p := _sirens[i]
			if i < list.size():
				var at: Vector3 = list[i][0] + Vector3.UP * 1.5
				if not p.playing:
					p.global_position = at
					p.play(_rng.randf() * 0.9)
				_siren_goal[i] = at
			elif p.playing:
				p.stop()
	var muffle := -10.0 if director.indoors else -3.0
	for i in _sirens.size():
		var p := _sirens[i]
		if p.playing:
			# Siren positions arrive five times a second; glide between them.
			p.global_position = p.global_position.lerp(_siren_goal[i], minf(delta * 10.0, 1.0))
			p.volume_db = muffle


func _update_panic(listener: Vector3) -> void:
	var n := 0
	var crowd = _life.get("crowd") if _life else null
	if crowd and _street and _street.get("active"):
		for ped in crowd.peds:
			if ped.flee > 0.0 and ped.pos.distance_squared_to(listener) < 1600.0:
				n += 1
	director.panic = clampf(n / 8.0, 0.0, 1.0)


func _update_bank(delta: float) -> void:
	if bank_alarm <= 0.0:
		if _bank_in.playing:
			_bank_in.stop()
		if _bank_out.playing:
			_bank_out.stop()
		return
	bank_alarm -= delta
	var inside := interior_id == "bank"
	if inside != _bank_in.playing:
		if inside:
			_bank_in.play()
		else:
			_bank_in.stop()
	if not inside and not _bank_out.playing:
		_bank_out.global_position = _bank_pos + Vector3.UP * 4.0
		_bank_out.play()
	elif inside and _bank_out.playing:
		_bank_out.stop()
