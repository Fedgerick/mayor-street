class_name DrivableCar
extends VehicleBody3D
## An enterable, drivable car using the city kit's car meshes. Arcade tuning: grippy,
## speed-sensitive steering, downforce and a self-righting reset so it stays fun on a
## laptop trackpad as well as a gamepad.
##
## The kit cars face -Z. VehicleBody3D drives along its +Z, so the mesh and the wheel
## layout are turned 180 degrees inside the body and `forward()` returns +Z.

signal driver_changed(driver: Node)
signal damaged(amount: float)
signal exploded(car: DrivableCar)

const LAYER := 2    # cars live on physics layer 2
const SAG := 0.15   # expected suspension compression at rest, so the kit wheels sit on the road
const MAX_HEALTH := 1000.0
const SMOKE_AT := 400.0     # engine smokes below this
const BURN_SECONDS := 4.5   # on fire this long before it blows
const CRASH_DV := 7.0       # a sudden speed change above this (m/s) dents the car

const MODELS := {
	# model: [wheel radius, front axle z, rear axle z, half track, mass, max engine force, top speed m/s]
	"car_sedan": [0.36, 1.4, -1.35, 0.81, 1250.0, 5200.0, 38.0],
	"car_hatch": [0.36, 1.1, -1.05, 0.76, 1050.0, 4300.0, 34.0],
	"car_van": [0.36, 1.6, -1.55, 0.88, 1700.0, 6000.0, 31.0],
	"car_truck": [0.48, 2.6, -2.55, 1.06, 3200.0, 10500.0, 26.0],
}

@export_enum("car_sedan", "car_hatch", "car_van", "car_truck") var model := "car_sedan"
@export var tint := Color(0.85, 0.12, 0.1)
@export var max_steer := 0.6
@export var steer_speed := 3.2
@export var brake_force := 40.0

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


func _ready() -> void:
	StreetInput.ensure()
	add_to_group("vehicles")
	collision_layer = LAYER
	collision_mask = 1 | LAYER
	var spec: Array = MODELS.get(model, MODELS["car_sedan"])
	mass = spec[4]
	_engine = spec[5]
	_top_speed = spec[6]
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
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Body"
	mmi.multimesh = mm
	mmi.rotation.y = PI
	mmi.position.y = -0.0
	add_child(mmi)

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
		b.position = Vector3(s * (hw - 0.3), 0.75 if model != "car_truck" else 0.95, -hl - 0.04)
		b.visible = false
		add_child(b)
		_brake_lights.append(b)
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
	var axles: Array = [[spec[1], true], [spec[2], false]]
	if model == "car_truck":
		axles.append([-1.4, false])
	for ax in axles:
		for s in [-1, 1]:
			var w := VehicleWheel3D.new()
			w.position = Vector3(s * spec[3], r + 0.22 - SAG, ax[0])
			w.wheel_radius = r
			w.wheel_rest_length = 0.22
			w.suspension_travel = 0.22
			w.suspension_stiffness = 48.0 if model != "car_truck" else 55.0
			w.suspension_max_force = mass * 14.0
			w.damping_compression = 0.9
			w.damping_relaxation = 1.2
			w.wheel_friction_slip = 2.6
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
	return global_position + left * 0.38 + forward() * (0.15 if model != "car_truck" else 2.2) + Vector3.UP * 0.25


func exit_point() -> Vector3:
	## Beside the driver's door (left side), on the ground.
	var left := global_basis.x
	return global_position + left * (_aabb.size.x * 0.5 + 0.7) + forward() * (0.3 if model != "car_truck" else 2.2) + Vector3.UP * 0.2


func take_hit(amount: float, _from_pos := Vector3.ZERO, _dir := Vector3.ZERO) -> void:
	## Bullets, crashes and blasts. Below SMOKE_AT it smokes; at 0 it catches fire and
	## explodes a few seconds later.
	if wrecked or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	damaged.emit(amount)
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
	_mm.set_instance_color(0, Color(0.06, 0.055, 0.05))
	for l in _lights:
		l.visible = false
	for w in _wheels:
		w.engine_force = 0.0
		w.brake = brake_force
	apply_central_impulse(Vector3.UP * mass * 4.5)
	apply_torque_impulse(Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * mass * 1.2)
	exploded.emit(self)


func _physics_process(delta: float) -> void:
	# Crash damage from sudden changes in velocity.
	var dv := (linear_velocity - _last_vel).length()
	_last_vel = linear_velocity
	if dv > CRASH_DV and delta > 0.0:
		take_hit((dv - CRASH_DV) * 28.0)
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
	var lock := max_steer * lerpf(1.0, 0.32, clampf(absf(v) / _top_speed, 0.0, 1.0))
	steering = move_toward(steering, steer_input * lock, steer_speed * delta)

	var braking := false
	var ef := 0.0
	var bf := 0.0
	if throttle > 0.05:
		if v < -1.0:
			bf = brake_force * throttle
			braking = true
		else:
			ef = _engine * throttle * clampf(1.0 - v / _top_speed, 0.0, 1.0)
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
		w.wheel_friction_slip = 1.5 if hb and rear else 2.6
		w.engine_force = 0.0 if hb and rear else ef / _wheels.size()
	for b in _brake_lights:
		b.visible = braking or hb or (driver != null and throttle < -0.05 and v > 0.5)

	# Downforce keeps it planted; anti-flip assist while on the ground.
	apply_central_force(Vector3.DOWN * mass * 0.004 * v * v)
	if global_basis.y.y < 0.3:
		_upside_down += delta
		if _upside_down > 2.5 and driver != null:
			reset_upright()
	else:
		_upside_down = 0.0
	rig.heading = heading_yaw()


func reset_upright() -> void:
	var f := forward()
	var yaw := atan2(f.x, f.z)
	var p := global_position
	global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, maxf(p.y, 0.0) + 1.0, p.z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_vel = Vector3.ZERO
	_upside_down = 0.0
