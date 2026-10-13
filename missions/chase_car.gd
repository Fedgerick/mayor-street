class_name ChaseCar
extends AnimatableBody3D
## A car that flees the player along the road grid (vigilante jobs, and later any "chase"
## step). It is kinematic: it follows lane centres tile by tile and picks, at each
## junction, the turn that takes it furthest from the player. The player's car is a
## physics body on the same layer, so ramming it is a real collision; each hard hit
## costs it health and at zero it is wrecked.
##
## A stand-in for the police and gang cars the Traffic and pedestrians thread is
## building; it only needs City and the Kit meshes.

signal hit(health: int)
signal wrecked

const LANE := 1.9          # metres right of the road centre line
const HIT_SPEED := 4.0     # closing speed (m/s) that counts as a ram
const HIT_COOLDOWN := 0.7

@export var model := "car_sedan"
@export var tint := Color(0.55, 0.1, 0.15)
@export var cruise := 11.0
@export var flee := 17.0
@export var health := 4

var city: City
var threat: Callable = func() -> Vector3: return Vector3.INF  # where the chaser is
var threat_car: Callable = func() -> Object: return null      # the chaser's car, for rams
var is_wrecked := false

var _from := Vector2i.ZERO
var _to := Vector2i.ZERO
var _t := 0.0
var _speed := 0.0
var _cooldown := 0.0
var _rng := RandomNumberGenerator.new()
var _smoke: CPUParticles3D
var flat_xf := Transform3D()  # where it is on the flat map; stood up on the ball on msp


func setup(c: City, start: Vector2i, seed_value := 1) -> void:
	city = c
	_rng.seed = seed_value
	_from = start
	_to = _pick_next(start, Vector2i(-99, -99))
	flat_xf = Transform3D(Basis.IDENTITY, _lane_point(_from, _to, 0.0))
	transform = Planet.xf_rigid(flat_xf)


func flat_position() -> Vector3:
	return flat_xf.origin


func _ready() -> void:
	collision_layer = DrivableCar.LAYER
	collision_mask = 0
	sync_to_physics = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.8, 1.3, 4.3)
	shape.shape = box
	shape.position.y = 0.75
	add_child(shape)
	var mesh: Mesh = null
	var kit := get_node_or_null("/root/Kit")
	if kit and kit.has_method("mesh"):
		mesh = kit.mesh(model)
	if mesh == null:
		var bm := BoxMesh.new()
		bm.size = Vector3(1.8, 1.3, 4.3)
		mesh = bm
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_color(0, tint)
	mm.set_instance_custom_data(0, Color(0, 0, 0, 0.5))
	var body := MultiMeshInstance3D.new()
	body.name = "Body"
	body.multimesh = mm
	body.rotation.y = PI
	add_child(body)
	_smoke = CPUParticles3D.new()
	_smoke.emitting = false
	_smoke.amount = 24
	_smoke.lifetime = 2.2
	_smoke.position = Vector3(0, 1.2, 1.6)
	_smoke.direction = Vector3.UP
	_smoke.spread = 18.0
	_smoke.initial_velocity_min = 1.5
	_smoke.initial_velocity_max = 2.5
	_smoke.gravity = Vector3(0, 0.6, 0)
	_smoke.scale_amount_min = 0.8
	_smoke.scale_amount_max = 1.8
	var puff := SphereMesh.new()
	puff.radius = 0.35
	puff.height = 0.7
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.12, 0.12, 0.12, 0.55)
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = smat
	_smoke.mesh = puff
	add_child(_smoke)


func _lane_point(a: Vector2i, b: Vector2i, t: float) -> Vector3:
	var dir := Vector3(b.x - a.x, 0, b.y - a.y)
	var right := Vector3(-dir.z, 0, dir.x)  # right of travel, for right-hand traffic
	var p := city.cell_center(a.x, a.y).lerp(city.cell_center(b.x, b.y), t)
	return p + right * LANE + Vector3.UP * 0.05


func _pick_next(at: Vector2i, came_from: Vector2i) -> Vector2i:
	var options: Array[Vector2i] = []
	for d: Vector2i in City.DIRS:
		var n := at + d
		if city.is_road(n.x, n.y) and n != came_from:
			options.append(n)
	if options.is_empty():
		return came_from if city.is_road(came_from.x, came_from.y) else at  # dead end: turn back
	var danger: Vector3 = threat.call()
	var best := options[0]
	var best_score := -INF
	for n in options:
		var score := _rng.randf() * 30.0
		if danger != Vector3.INF:
			score += city.cell_center(n.x, n.y).distance_to(danger)
		if score > best_score:
			best_score = score
			best = n
	return best


func _physics_process(delta: float) -> void:
	if city == null or is_wrecked:
		return
	_cooldown = maxf(0.0, _cooldown - delta)
	var danger: Vector3 = threat.call()
	var close := danger != Vector3.INF and danger.distance_to(flat_xf.origin) < 60.0
	var target_speed := flee if close else cruise
	_speed = move_toward(_speed, target_speed, 6.0 * delta)
	var moving := _to != _from
	_t += _speed * delta / City.TILE
	while _t >= 1.0:
		_t -= 1.0
		var prev := _from
		_from = _to
		_to = _pick_next(_from, prev)
		if _to == _from:
			_t = 0.0
			break
	if not moving:
		return
	var p := _lane_point(_from, _to, _t)
	var fwd := p - flat_xf.origin
	fwd.y = 0.0
	var xf := flat_xf
	xf.origin = p
	if fwd.length() > 0.01:
		var yaw := atan2(fwd.x, fwd.z)
		var cur := xf.basis.get_euler().y
		xf.basis = Basis(Vector3.UP, lerp_angle(cur, yaw, minf(1.0, 10.0 * delta)))
	flat_xf = xf
	global_transform = Planet.xf_rigid(xf)
	_check_ram()


func _check_ram() -> void:
	var other: Object = threat_car.call()
	if other == null or _cooldown > 0.0 or not (other is Node3D):
		return
	var o := other as Node3D
	if o.global_position.distance_to(global_position) > 4.2:
		return
	var their_v: Vector3 = o.linear_velocity if "linear_velocity" in o else Vector3.ZERO
	var my_v := global_transform.basis.z * _speed
	if (their_v - my_v).length() < HIT_SPEED:
		return
	take_hit()


func take_hit() -> void:
	if is_wrecked:
		return
	_cooldown = HIT_COOLDOWN
	health -= 1
	hit.emit(health)
	_speed *= 0.5
	if health <= 1:
		_smoke.emitting = true
	if health <= 0:
		is_wrecked = true
		_smoke.emitting = true
		rotation.z = 0.08
		wrecked.emit()
