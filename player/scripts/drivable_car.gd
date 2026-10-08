class_name DrivableCar
extends VehicleBody3D
## An enterable, drivable car using the city kit's car meshes. Arcade tuning: grippy,
## speed-sensitive steering, downforce and a self-righting reset so it stays fun on a
## laptop trackpad as well as a gamepad.
##
## Feel: the body leans out of corners, dips under braking and squats when accelerating,
## on a soft spring of its own (visual only, so the physics stays steady). Heavy vehicles
## steer, speed up and stop more slowly and lean more.
##
## The kit cars face -Z. VehicleBody3D drives along its +Z, so the mesh and the wheel
## layout are turned 180 degrees inside the body and `forward()` returns +Z.

signal driver_changed(driver: Node)
signal damaged(amount: float)
signal exploded(car: DrivableCar)
signal crashed(strength: float)   # a hard knock, 0..1, for camera shake and sound

const LAYER := 2    # cars live on physics layer 2
const SAG := 0.15   # expected suspension compression at rest, so the kit wheels sit on the road
const MAX_HEALTH := 1000.0
const SMOKE_AT := 400.0     # engine smokes below this
const BURN_SECONDS := 4.5   # on fire this long before it blows
const CRASH_DV := 7.0       # a sudden speed change above this (m/s) dents the car

const MODELS := {
	# model: [wheel radius, front axle z, rear axle z, half track, mass, max engine force, top speed m/s]
	# Axles of 0 are worked out from the mesh's size.
	"car_sedan": [0.36, 1.4, -1.35, 0.81, 1250.0, 5200.0, 38.0],
	"car_hatch": [0.36, 1.1, -1.05, 0.76, 1050.0, 4300.0, 34.0],
	"car_taxi": [0.36, 1.4, -1.35, 0.81, 1300.0, 5300.0, 37.0],
	"car_sports": [0.36, 0.0, 0.0, 0.0, 1150.0, 7800.0, 48.0],
	"car_police": [0.36, 0.0, 0.0, 0.0, 1500.0, 7000.0, 44.0],
	"car_pickup": [0.42, 0.0, 0.0, 0.0, 1900.0, 6800.0, 33.0],
	"car_van": [0.36, 1.6, -1.55, 0.88, 1700.0, 6000.0, 31.0],
	"car_ambulance": [0.42, 0.0, 0.0, 0.0, 2600.0, 8500.0, 33.0],
	"car_truck": [0.48, 2.6, -2.55, 1.06, 3200.0, 10500.0, 26.0],
	"car_bus": [0.5, 0.0, 0.0, 0.0, 9000.0, 21000.0, 22.0],
	"car_firetruck": [0.5, 0.0, 0.0, 0.0, 9000.0, 23000.0, 26.0],
	"car_garbage": [0.5, 0.0, 0.0, 0.0, 8500.0, 19000.0, 22.0],
}
## How the body moves on its springs: lean per m/s² sideways, pitch per m/s² fore/aft,
## spring rate (higher = firmer), steering speed, and grip.
const FEEL := {
	"default": {"roll": 0.010, "pitch": 0.006, "spring": 55.0, "steer": 3.2, "grip": 1.0},
	"car_sports": {"roll": 0.006, "pitch": 0.004, "spring": 90.0, "steer": 3.8, "grip": 1.12},
	"car_police": {"roll": 0.008, "pitch": 0.005, "spring": 70.0, "steer": 3.5, "grip": 1.06},
	"car_hatch": {"roll": 0.011, "pitch": 0.007, "spring": 55.0, "steer": 3.4, "grip": 1.0},
	"car_pickup": {"roll": 0.014, "pitch": 0.008, "spring": 42.0, "steer": 2.8, "grip": 0.95},
	"car_van": {"roll": 0.015, "pitch": 0.008, "spring": 40.0, "steer": 2.7, "grip": 0.93},
	"car_ambulance": {"roll": 0.016, "pitch": 0.009, "spring": 38.0, "steer": 2.5, "grip": 0.92},
	"car_truck": {"roll": 0.018, "pitch": 0.009, "spring": 34.0, "steer": 2.2, "grip": 0.9},
	"car_bus": {"roll": 0.02, "pitch": 0.01, "spring": 28.0, "steer": 1.8, "grip": 0.88},
	"car_firetruck": {"roll": 0.019, "pitch": 0.01, "spring": 30.0, "steer": 1.9, "grip": 0.9},
	"car_garbage": {"roll": 0.02, "pitch": 0.01, "spring": 28.0, "steer": 1.8, "grip": 0.88},
}
const SPECS := "res://vehicles/assets/specs.json"   # the Cars thread's measurements (vehicles/)
const SEAT_DROP := 0.52   # kit seat height down to the Sit pose's root, so getting in and out lines up
const EMERGENCY := ["car_police", "car_ambulance", "car_firetruck"]
const MAX_ROLL := 0.09     # radians
const MAX_PITCH := 0.06

@export_enum("car_sedan", "car_hatch", "car_taxi", "car_sports", "car_police", "car_pickup", "car_van",
	"car_ambulance", "car_truck", "car_bus", "car_firetruck", "car_garbage") var model := "car_sedan"
@export var tint := Color(0.85, 0.12, 0.1)
@export var max_steer := 0.6
@export var steer_speed := 3.2
@export var brake_force := 40.0
@export var handling := 1.0   # driver perk (Cabbie 1.15): more power, sharper steering, more grip
var weather_grip := 1.0   # Weather.grip(): 1 dry .. 0.7 soaked

var driver: Node = null
var rig: OrbitRig
var throttle := 0.0
var steer_input := 0.0
var headlights_on := false

var _wheels: Array[VehicleWheel3D] = []
var _engine := 4500.0
var _top_speed := 35.0
var _upside_down := 0.0
var _brake_lights: Array[MeshInstance3D] = []
var _lights: Array[Light3D] = []
var _aabb := AABB()
var health := MAX_HEALTH
var burning := false
var wrecked := false
var _burn := 0.0
var _last_vel := Vector3.ZERO
var _smoke: CPUParticles3D
var _fire: CPUParticles3D
var _mm: MultiMesh
var _tilt: Node3D                # the body mesh and its lamps, leaning on a visual spring
var _feel: Dictionary
var _roll := Vector2.ZERO        # x: angle, y: angular speed
var _pitch := Vector2.ZERO
var _heave := Vector2.ZERO       # vertical bob, metres
var _accel := Vector3.ZERO       # smoothed local acceleration
var _wheel_angle := 0.0
var _kit_shader := false         # the round-3 vehicle shader reads wheel spin and lamps
var _braking := false
var _radius := 0.36
var _seat := Vector3.ZERO        # driver's hip, body space (from the car kit's specs)
var _dmg_mesh := 0
var damage_stage := 0            # 0 clean, 1 dented, 2 smashed (smoking), 3 burnt out
static var _spec_cache := {}


func _ready() -> void:
	StreetInput.ensure()
	add_to_group("vehicles")
	collision_layer = LAYER
	collision_mask = 1 | LAYER | 16   # 16: StreetBodies.TRAFFIC_LAYER, the AI cars' stand-ins
	var spec: Array = MODELS.get(model, MODELS["car_sedan"])
	_radius = spec[0]
	_feel = FEEL.get(model, FEEL["default"])
	mass = spec[4]
	_engine = spec[5]
	_top_speed = spec[6]
	steer_speed = _feel.steer
	# Heavy vehicles need more brake to stop at all, but still take longer.
	brake_force = 40.0 * pow(mass / 1250.0, 0.75)
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.45, 0.1)
	angular_damp = 1.5
	linear_damp = 0.05
	continuous_cd = true
	can_sleep = true
	_build_visual()
	_build_body(spec)
	rig = OrbitRig.new()
	rig.name = "Rig"
	rig.target = self
	rig.height = _aabb.size.y + 0.9
	rig.distance = 5.0 + _aabb.size.z * 0.45
	rig.side_offset = 0.0
	rig.recenter_speed = 3.0
	rig.min_pitch = deg_to_rad(-50.0)
	rig.max_pitch = deg_to_rad(15.0)
	rig.pitch = deg_to_rad(-12.0)
	add_child(rig)
	rig.exclude(self)


## The Cars thread's spec for a model (axles, seat, size), read straight from its JSON so
## this script doesn't depend on the VehicleKit class being registered.
static func kit_spec(m: String) -> Dictionary:
	if _spec_cache.is_empty() and FileAccess.file_exists(SPECS):
		var d = JSON.parse_string(FileAccess.get_file_as_string(SPECS))
		_spec_cache = d if d is Dictionary else {"_": {}}
	return _spec_cache.get(m, {})


func is_emergency() -> bool:
	return model in EMERGENCY


func _kit_mesh() -> Mesh:
	var kit := get_node_or_null("/root/Kit")
	if kit and kit.has_method("mesh"):
		return kit.mesh(model)
	return null


func _build_visual() -> void:
	var mesh := _kit_mesh()
	if mesh == null:
		# Fallback so the car still works without the kit (unit tests).
		var bm := BoxMesh.new()
		bm.size = Vector3(1.8, 1.2, 4.3)
		mesh = bm
		_aabb = AABB(Vector3(-0.9, 0.0, -2.15), bm.size)
	else:
		_aabb = mesh.get_aabb()
	# A one-instance MultiMesh, so the kit shader gets its per-instance tint (COLOR).
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_color(0, tint)
	mm.set_instance_custom_data(0, Color(0, 0, 0, randf()))
	_mm = mm
	for s in mesh.get_surface_count():
		var sm := mesh.surface_get_material(s)
		if sm and sm.resource_name == "VehBody":
			_kit_shader = true
	if _kit_shader:
		mm.set_instance_custom_data(0, Color(4.0, 0, 0, 0.37))   # empty: no built-in driver
	var ks := kit_spec(model)
	if _kit_shader and ks.has("seat"):
		# Its seat in kit space (facing -Z) turned into ours.
		_seat = Vector3(-float(ks.seat[0]), float(ks.seat[1]), -float(ks.seat[2]))
		_radius = float(ks.get("wheel_radius", _radius))
	else:
		_seat = Vector3(0.38, 0.25 + SEAT_DROP, 0.15 if model != "car_truck" else 2.2)
	# Everything that leans with the body hangs off a pivot near the axle height.
	_tilt = Node3D.new()
	_tilt.name = "Tilt"
	_tilt.position.y = 0.45
	add_child(_tilt)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Body"
	mmi.multimesh = mm
	mmi.rotation.y = PI
	mmi.position.y = -0.45
	_tilt.add_child(mmi)

	# Brake lights and headlight beams (only lit while driven).
	var hl := _aabb.size.z * 0.5
	var hw := _aabb.size.x * 0.5
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(1, 0.1, 0.08)
	bmat.emission_enabled = true
	bmat.emission = Color(1, 0.08, 0.05)
	bmat.emission_energy_multiplier = 4.0
	for s in [-1, 1]:
		var b := MeshInstance3D.new()
		var q := BoxMesh.new()
		q.size = Vector3(0.38, 0.18, 0.04)
		b.mesh = q
		b.material_override = bmat
		b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.position = Vector3(s * (hw - 0.3), (0.75 if model != "car_truck" else 0.95) - 0.45, -hl - 0.04)
		b.visible = false
		_tilt.add_child(b)
		if not _kit_shader:   # the kit shader lights its own tail lamps
			_brake_lights.append(b)
		else:
			b.queue_free()
	var spot := SpotLight3D.new()
	spot.name = "Headlights"
	spot.position = Vector3(0, 0.8, hl + 0.1)
	spot.rotation = Vector3(deg_to_rad(-8.0), PI, 0)
	spot.spot_range = 38.0
	spot.spot_angle = 38.0
	spot.spot_attenuation = 0.7
	spot.light_energy = 6.0
	spot.light_color = Color(1.0, 0.95, 0.85)
	spot.shadow_enabled = false
	spot.light_specular = 0.3
	spot.visible = false
	add_child(spot)
	_lights.append(spot)
	var tail := OmniLight3D.new()
	tail.position = Vector3(0, 0.8, -hl - 0.5)
	tail.omni_range = 3.5
	tail.light_energy = 0.0
	tail.light_color = Color(1, 0.1, 0.05)
	tail.visible = false
	add_child(tail)
	_lights.append(tail)


func _build_body(spec: Array) -> void:
	var r: float = spec[0]
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	var box := BoxShape3D.new()
	var lower_h := minf(_aabb.size.y, 1.05 if model != "car_truck" else 1.3)
	box.size = Vector3(_aabb.size.x - 0.04, lower_h - r * 0.9, _aabb.size.z - 0.05)
	cs.shape = box
	cs.position = Vector3(0, r * 0.9 + box.size.y * 0.5, 0)
	add_child(cs)
	# Cabin as a second, narrower box so the roof collides too.
	if _aabb.size.y > lower_h + 0.1:
		var cab := CollisionShape3D.new()
		var cb := BoxShape3D.new()
		cb.size = Vector3(_aabb.size.x - 0.3, _aabb.size.y - lower_h, _aabb.size.z * 0.5)
		cab.shape = cb
		cab.position = Vector3(0, lower_h + cb.size.y * 0.5, 0 if model != "car_truck" else spec[1] - 0.4)
		add_child(cab)
	var front: float = spec[1] if spec[1] != 0.0 else _aabb.size.z * 0.31
	var rear: float = spec[2] if spec[2] != 0.0 else -_aabb.size.z * 0.3
	var track: float = spec[3] if spec[3] != 0.0 else _aabb.size.x * 0.42
	var axles: Array = [[front, true], [rear, false]]
	if mass > 3000.0:
		axles.append([lerpf(front, rear, 0.72), false])
	# The car kit's own axles when it has them (its cars face -Z, ours +Z).
	var ks := kit_spec(model)
	if _kit_shader and ks.has("axles"):
		axles.clear()
		for a in ks.axles:
			axles.append([-float(a.z), bool(a.steer)])
		track = float(ks.get("track", track))
	for ax in axles:
		for s in [-1, 1]:
			var w := VehicleWheel3D.new()
			w.position = Vector3(s * track, r + 0.22 - SAG, ax[0])
			w.wheel_radius = r
			w.wheel_rest_length = 0.22
			w.suspension_travel = 0.22
			# A little softer than before; the visual spring adds the rest of the lean.
			w.suspension_stiffness = 42.0 if mass < 3000.0 else 52.0
			w.suspension_max_force = mass * 14.0
			w.damping_compression = 0.8
			w.damping_relaxation = 1.1
			w.wheel_friction_slip = 2.6 * _feel.grip
			w.wheel_roll_influence = 0.15
			w.use_as_steering = ax[1]
			w.use_as_traction = true
			add_child(w)
			_wheels.append(w)


func forward() -> Vector3:
	return global_basis.z


func speed() -> float:
	## Signed forward speed, m/s.
	return linear_velocity.dot(forward())


func heading_yaw() -> float:
	var f := forward()
	return atan2(-f.x, -f.z)


func set_driver(d: Node) -> void:
	driver = d
	rig.input_enabled = d != null
	headlights_on = d != null
	for l in _lights:
		l.visible = headlights_on
	if d == null:
		throttle = 0.0
		steer_input = 0.0
	else:
		rig.yaw = heading_yaw()
		rig.snap()
	driver_changed.emit(d)


func seat_point() -> Vector3:
	## Where the driver's feet go when seated (left seat), in world space.
	var left := global_basis.x
	return global_position + left * _seat.x + forward() * _seat.z + global_basis.y * (_seat.y - SEAT_DROP)


func exit_point() -> Vector3:
	## Beside the driver's door (left side), on the ground.
	var left := global_basis.x
	return global_position + left * (_aabb.size.x * 0.5 + 0.7) + forward() * (_seat.z + 0.15) + Vector3.UP * 0.2


func take_hit(amount: float, _from_pos := Vector3.ZERO, _dir := Vector3.ZERO) -> void:
	## Bullets, crashes and blasts. Below SMOKE_AT it smokes; at 0 it catches fire and
	## explodes a few seconds later.
	if wrecked or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	damaged.emit(amount)
	if health < MAX_HEALTH * 0.75:
		_set_damage(1 if health >= SMOKE_AT else 2)
	if health < SMOKE_AT and _smoke == null:
		_smoke = StreetFx.smoke(health < SMOKE_AT * 0.5)
		add_child(_smoke)
		_smoke.position = Vector3(0, _aabb.size.y * 0.6, _aabb.size.z * 0.38)
	if health <= 0.0 and not burning:
		burning = true
		_burn = 0.0
		_fire = StreetFx.fire()
		add_child(_fire)
		_fire.position = Vector3(0, _aabb.size.y * 0.55, _aabb.size.z * 0.35)


func explode() -> void:
	if wrecked:
		return
	wrecked = true
	burning = false
	health = 0.0
	if _fire:
		_fire.emitting = false
	if _smoke == null:
		_smoke = StreetFx.smoke(true)
		add_child(_smoke)
		_smoke.position = Vector3(0, _aabb.size.y * 0.6, 0)
	StreetFx.explosion(get_parent(), global_position)
	if not _set_damage(3):
		_mm.set_instance_color(0, Color(0.06, 0.055, 0.05))
	for l in _lights:
		l.visible = false
	for w in _wheels:
		w.engine_force = 0.0
		w.brake = brake_force
	apply_central_impulse(Vector3.UP * mass * 4.5)
	apply_torque_impulse(Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * mass * 1.2)
	exploded.emit(self)


func _set_damage(stage: int) -> bool:
	## Swap to the car kit's dented / smashed / burnt mesh. False when there isn't one.
	if stage > damage_stage:
		damage_stage = stage
		var kit := get_node_or_null("/root/Kit")
		var m: Mesh = kit.mesh("%s_dmg%d" % [model, stage]) if _kit_shader and kit and kit.has_method("mesh") else null
		if m:
			_mm.mesh = m
			_dmg_mesh = stage
	return _dmg_mesh == stage


func _physics_process(delta: float) -> void:
	# Crash damage from sudden changes in velocity.
	var dv := (linear_velocity - _last_vel).length()
	if delta > 0.0:
		var a := global_basis.inverse() * ((linear_velocity - _last_vel) / delta)
		_accel = _accel.lerp(a.limit_length(40.0), 1.0 - exp(-10.0 * delta))
	_last_vel = linear_velocity
	if dv > CRASH_DV * 0.6 and delta > 0.0:
		crashed.emit(clampf((dv - CRASH_DV * 0.6) / 14.0, 0.15, 1.0))
		# A knock jolts the body on its springs.
		_heave.y -= minf(dv * 0.08, 0.6)
		_pitch.y += randf_range(-1.0, 1.0) * minf(dv * 0.04, 0.4)
	if dv > CRASH_DV and delta > 0.0:
		take_hit((dv - CRASH_DV) * 28.0)
	_body_motion(delta)
	if burning:
		_burn += delta
		if _burn >= BURN_SECONDS:
			explode()
	if wrecked:
		for b in _brake_lights:
			b.visible = false
		return
	var v := speed()
	var hb := false
	if driver != null:
		var acc := Input.get_action_strength("street_forward") + Input.get_action_strength("street_throttle")
		var rev := Input.get_action_strength("street_back") + Input.get_action_strength("street_brake")
		throttle = clampf(acc, 0.0, 1.0) - clampf(rev, 0.0, 1.0)
		steer_input = Input.get_action_strength("street_left") - Input.get_action_strength("street_right")
		hb = Input.is_action_pressed("street_handbrake")
		if Input.is_action_just_pressed("street_reset"):
			reset_upright()
	# Speed-sensitive steering: full lock when slow, gentle at speed.
	var lock := max_steer * clampf(handling, 0.5, 1.5) * lerpf(1.0, 0.32, clampf(absf(v) / _top_speed, 0.0, 1.0))
	steering = move_toward(steering, steer_input * lock, steer_speed * delta)

	var braking := false
	var ef := 0.0
	var bf := 0.0
	if throttle > 0.05:
		if v < -1.0:
			bf = brake_force * throttle
			braking = true
		else:
			ef = _engine * handling * throttle * clampf(1.0 - v / _top_speed, 0.0, 1.0)
	elif throttle < -0.05:
		if v > 1.0:
			bf = brake_force * -throttle
			braking = true
		else:
			ef = _engine * 0.6 * throttle * clampf(1.0 + v / (_top_speed * 0.35), 0.0, 1.0)
	else:
		bf = 1.5 if driver != null else brake_force * 0.3  # engine braking / parked
	for w in _wheels:
		var rear := w.position.z < 0.0
		w.brake = brake_force * 1.5 if hb and rear else bf
		w.wheel_friction_slip = 1.5 if hb and rear else 2.6 * handling * _feel.grip * weather_grip
		w.engine_force = 0.0 if hb and rear else ef / _wheels.size()
	_braking = braking or hb or (driver != null and throttle < -0.05 and v > 0.5)
	for b in _brake_lights:
		b.visible = _braking

	# Downforce keeps it planted; anti-flip assist while on the ground.
	apply_central_force(Vector3.DOWN * mass * 0.004 * v * v)
	if global_basis.y.y < 0.3:
		_upside_down += delta
		if _upside_down > 2.5 and driver != null:
			reset_upright()
	else:
		_upside_down = 0.0
	rig.heading = heading_yaw()


func _body_motion(delta: float) -> void:
	## The body's lean, dive and bob: damped springs chasing the car's acceleration.
	var on_ground := false
	for w in _wheels:
		if w.is_in_contact():
			on_ground = true
			break
	var k: float = _feel.spring
	var damp := 2.0 * sqrt(k) * 0.55   # a little under critical: one soft overshoot
	var roll_goal := clampf(_accel.x * _feel.roll, -MAX_ROLL, MAX_ROLL) if on_ground else 0.0
	var pitch_goal := clampf(-_accel.z * _feel.pitch, -MAX_PITCH, MAX_PITCH) if on_ground else 0.0
	var heave_goal := clampf(-_accel.y * 0.004, -0.05, 0.05)
	for pair in [[0, roll_goal], [1, pitch_goal], [2, heave_goal]]:
		var st: Vector2 = [_roll, _pitch, _heave][pair[0]]
		st.y += ((pair[1] - st.x) * k - st.y * damp) * delta
		st.x += st.y * delta
		match pair[0]:
			0: _roll = st
			1: _pitch = st
			2: _heave = st
	_roll.x = clampf(_roll.x, -MAX_ROLL * 1.4, MAX_ROLL * 1.4)
	_pitch.x = clampf(_pitch.x, -MAX_PITCH * 1.4, MAX_PITCH * 1.4)
	_heave.x = clampf(_heave.x, -0.12, 0.08)
	_tilt.rotation = Vector3(_pitch.x, 0.0, _roll.x)
	_tilt.position.y = 0.45 + _heave.x
	if _kit_shader and not wrecked:
		_wheel_angle += speed() * delta / _radius
		# Same packing as VehicleKit.custom(): lamp flags, wheel spin, steering angle, seed.
		_mm.set_instance_custom_data(0, Color(float(lamp_flags()), fmod(_wheel_angle, TAU), steering, 0.37))


## VehicleKit.custom() flags: brake 2, empty 4, headlights 8. The kit's own driver stands
## in for the player (who is hidden while driving), so the car is only "empty" when
## nobody is at the wheel.
func lamp_flags() -> int:
	return (2 if _braking else 0) | (4 if driver == null else 0) | (8 if headlights_on else 0)


## The body's current lean (roll, pitch) in radians, for the camera and tests.
func body_tilt() -> Vector2:
	return Vector2(_roll.x, _pitch.x)


func reset_upright() -> void:
	var f := forward()
	var yaw := atan2(f.x, f.z)
	var p := global_position
	global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, maxf(p.y, 0.0) + 1.0, p.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_vel = Vector3.ZERO
	_accel = Vector3.ZERO
	_upside_down = 0.0
