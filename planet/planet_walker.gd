class_name PlanetWalker
extends CharacterBody3D
## The on-foot character on the ball: walks relative to the camera in the local frame,
## with up pointing away from the planet's centre. A cut-down StreetPlayer for the
## prototype (StreetPlayer and OrbitRig still assume +Y is up).

@export var walk_speed := 3.6
@export var sprint_speed := 7.2
@export var jump_velocity := 5.2

var visual: CharacterModel
var controls_enabled := true
var cam_yaw := 0.0       # the camera's heading in the local frame (0 = north), set by PlanetMain
var _facing := 0.0       # local heading the body faces
var _turn_rate := 0.0


func _ready() -> void:
	StreetInput.ensure()
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(50.0)
	safe_margin = 0.02
	collision_mask = 1 | DrivableCar.LAYER
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.76
	cs.shape = cap
	cs.position.y = 0.88
	add_child(cs)
	visual = CharacterModel.new()
	visual.name = "Visual"
	visual.seed_value = 7
	add_child(visual)


func place(world: Vector3, yaw := 0.0) -> void:
	_facing = yaw
	velocity = Vector3.ZERO
	global_transform = Transform3D(Planet.frame_world(world) * Basis(Vector3.UP, yaw), world)


func local_frame() -> Basis:
	return Planet.frame_world(global_position)


func _physics_process(delta: float) -> void:
	var q := local_frame()
	var up := q.y
	up_direction = up
	var input := StreetInput.move_vector() if controls_enabled else Vector2.ZERO
	var speed := sprint_speed if Input.is_action_pressed("street_sprint") else walk_speed
	# Camera-relative, in the local frame: yaw 0 looks north (-z).
	var cam := Basis(Vector3.UP, cam_yaw)
	var wish_local := cam * Vector3(input.x, 0.0, -input.y)
	var wish := q * wish_local * speed
	var vup := velocity.dot(up)
	var hv := velocity - up * vup
	var accel := 14.0 if is_on_floor() else 3.0
	hv = hv.lerp(wish, 1.0 - exp(-accel * delta))
	if is_on_floor():
		vup = minf(vup, 0.0)
		if controls_enabled and Input.is_action_just_pressed("street_jump"):
			vup = jump_velocity
	else:
		vup -= 9.8 * delta
	velocity = hv + up * vup
	move_and_slide()
	# Stand upright on the ball and turn toward where we walk.
	var hl := q.inverse() * hv
	if Vector2(hl.x, hl.z).length() > 0.3:
		var goal := atan2(-hl.x, -hl.z)
		var before := _facing
		_facing = lerp_angle(_facing, goal, 1.0 - exp(-12.0 * delta))
		_turn_rate = wrapf(_facing - before, -PI, PI) / maxf(delta, 0.001)
	else:
		_turn_rate = 0.0
	global_basis = local_frame() * Basis(Vector3.UP, _facing)
	visual.animate(delta, Vector2(hl.x, hl.z).length(), is_on_floor(), vup, _turn_rate)
