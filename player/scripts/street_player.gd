class_name StreetPlayer
extends CharacterBody3D
## The on-foot character: camera-relative walk and sprint, jump with coyote time and
## input buffering, curb step-up, and a third-person boom (OrbitRig).

signal interact_requested

@export var walk_speed := 3.6
@export var sprint_speed := 7.2
@export var ground_accel := 14.0
@export var air_accel := 3.0
@export var turn_speed := 12.0
@export var jump_velocity := 5.2
@export var step_height := 0.32
@export var look_seed := 7

const COYOTE := 0.12
const JUMP_BUFFER := 0.14

var controls_enabled := false
var in_vehicle := false
var rig: OrbitRig
var visual: CharacterModel
var puppet := false   # visible but driven by StreetMode (getting in or out of a car)

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _since_floor := 0.0
var _jump_buffer := 0.0
var _facing := 0.0
var _turn_rate := 0.0


func _init() -> void:
	floor_snap_length = 0.35
	floor_max_angle = deg_to_rad(50.0)
	safe_margin = 0.02


func _ready() -> void:
	StreetInput.ensure()
	add_to_group("street_player")
	collision_mask = 1 | DrivableCar.LAYER
	if not has_node("Shape"):
		var cs := CollisionShape3D.new()
		cs.name = "Shape"
		var cap := CapsuleShape3D.new()
		cap.radius = 0.3
		cap.height = 1.76
		cs.shape = cap
		cs.position.y = 0.88
		add_child(cs)
	visual = CharacterModel.new()
	visual.name = "Visual"
	visual.seed_value = look_seed
	add_child(visual)
	rig = OrbitRig.new()
	rig.name = "Rig"
	rig.target = self
	rig.height = 1.55
	rig.distance = 3.6
	add_child(rig)
	_facing = rotation.y
	rotation.y = 0.0


func set_controls(on: bool) -> void:
	controls_enabled = on
	rig.input_enabled = on


func place(pos: Vector3, face_yaw: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	_facing = face_yaw
	visual.rotation.y = face_yaw
	rig.yaw = face_yaw
	rig.snap()


func set_puppet(on: bool) -> void:
	## Visible, no physics, no input: StreetMode moves the character into or out of a car.
	puppet = on
	visible = true
	$Shape.disabled = on
	set_physics_process(not on)
	rig.input_enabled = controls_enabled and not on
	velocity = Vector3.ZERO
	if on:
		visual.animate(0.016, 0.0, true, 0.0, 0.0)


func face(yaw: float) -> void:
	_facing = yaw
	visual.rotation.y = yaw


func set_in_vehicle(on: bool) -> void:
	in_vehicle = on
	puppet = false
	visible = not on
	$Shape.disabled = on
	set_physics_process(not on)
	rig.input_enabled = controls_enabled and not on
	velocity = Vector3.ZERO


func _unhandled_input(e: InputEvent) -> void:
	if not controls_enabled or in_vehicle or puppet:
		return
	if e.is_action_pressed("street_interact"):
		interact_requested.emit()
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	var input := StreetInput.move_vector() if controls_enabled else Vector2.ZERO
	var wish := rig.right_flat() * input.x + rig.forward_flat() * input.y
	var sprinting := controls_enabled and Input.is_action_pressed("street_sprint")
	var target_speed := (sprint_speed if sprinting else walk_speed) * minf(input.length(), 1.0)

	if is_on_floor():
		_since_floor = 0.0
	else:
		_since_floor += delta
		velocity.y -= _gravity * delta * (1.6 if velocity.y < 0.0 else 1.0)

	if controls_enabled and Input.is_action_just_pressed("street_jump"):
		_jump_buffer = JUMP_BUFFER
	else:
		_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	if _jump_buffer > 0.0 and _since_floor < COYOTE:
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_since_floor = COYOTE

	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var goal := wish.normalized() * target_speed if wish.length() > 0.01 else Vector3.ZERO
	var accel := ground_accel if is_on_floor() else air_accel
	hv = hv.lerp(goal, 1.0 - exp(-accel * delta))
	velocity.x = hv.x
	velocity.z = hv.z

	var was_floor := is_on_floor()
	var before := global_position
	move_and_slide()
	if was_floor and goal != Vector3.ZERO and is_on_wall():
		if _try_step(before, goal * delta):
			velocity.y = 0.0

	# Face the direction of travel.
	var prev := _facing
	if hv.length() > 0.4:
		_facing = lerp_angle(_facing, atan2(-hv.x, -hv.z), 1.0 - exp(-turn_speed * delta))
	_turn_rate = lerpf(_turn_rate, wrapf(_facing - prev, -PI, PI) / maxf(delta, 1e-4), 0.2)
	visual.rotation.y = _facing
	visual.animate(delta, hv.length(), is_on_floor(), velocity.y, _turn_rate)


func _try_step(from_pos: Vector3, motion: Vector3) -> bool:
	## Climb a curb or stair: probe up, over the edge, and down; if there's flat ground
	## up there, lift onto it and let the next move carry the player forward.
	var dir := Vector3(motion.x, 0.0, motion.z).normalized()
	var reach := maxf(motion.length(), 0.34)
	var params := PhysicsTestMotionParameters3D.new()
	var res := PhysicsTestMotionResult3D.new()
	var xf := global_transform
	xf.origin = from_pos
	params.from = xf
	params.motion = Vector3.UP * step_height
	if PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	xf.origin += params.motion
	params.from = xf
	params.motion = dir * reach
	if PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	xf.origin += params.motion
	params.from = xf
	params.motion = Vector3.DOWN * step_height
	if not PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	if res.get_collision_normal().y < 0.7:
		return false
	var top := xf.origin.y + res.get_travel().y
	if top <= from_pos.y + 0.02:
		return false
	global_position = Vector3(from_pos.x, top + 0.01, from_pos.z) + dir * motion.length()
	return true


func facing_yaw() -> float:
	return _facing
