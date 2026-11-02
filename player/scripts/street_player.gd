class_name StreetPlayer
extends CharacterBody3D
## The on-foot character: camera-relative walk and sprint, jump with coyote time and
## input buffering, curb step-up, and a third-person boom (OrbitRig).
## On msp (Planet.on) the body stands on the ball: its basis is the local frame under it,
## and movement runs in that frame (y = away from the planet's centre).

signal interact_requested
signal damaged(amount: float, from_pos: Vector3)
signal died

@export var walk_speed := 3.6
@export var sprint_speed := 7.2
@export var ground_accel := 14.0
@export var air_accel := 3.0
@export var turn_speed := 12.0
@export var jump_velocity := 5.2
@export var step_height := 0.32
@export var look_seed := 7

const MAX_HEALTH := 100.0
const MAX_ARMOR := 100.0
const ARMOR_SHARE := 0.66   # armor soaks this much of each hit while it lasts
const REGEN_TO := 40.0      # health slowly comes back up to this on its own
const REGEN_RATE := 1.0     # hp per second
const REGEN_DELAY := 8.0    # seconds after the last hit

const COYOTE := 0.12
const JUMP_BUFFER := 0.14

var controls_enabled := false
var in_vehicle := false
var rig: OrbitRig
var visual: CharacterModel
var puppet := false   # visible but driven by StreetMode (getting in or out of a car)
var health := MAX_HEALTH
var armor := 0.0
var dead := false
var aiming := false   # set by StreetCombat: face where the camera looks, walk only
var aim_yaw := 0.0
var heal_rate := 1.0  # Medic perk 1.5: faster regeneration and stronger health pickups
var _since_hurt := 0.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _since_floor := 0.0
var _jump_buffer := 0.0
var _facing := 0.0
var _turn_rate := 0.0
var _air_time := 0.0


func _init() -> void:
	floor_snap_length = 0.35
	floor_max_angle = deg_to_rad(50.0)
	safe_margin = 0.02


func _ready() -> void:
	StreetInput.ensure()
	add_to_group("street_player")
	collision_mask = 1 | DrivableCar.LAYER | StreetBodies.TRAFFIC_LAYER | StreetBodies.PEOPLE_LAYER
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
	if Planet.on:
		global_basis = Planet.basis(pos)
		up_direction = global_basis.y
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
	if Planet.on:  # stand up on the ball where StreetMode put us (no physics while a puppet)
		global_basis = Planet.basis(global_position)
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
	_since_hurt += delta
	if not dead and health < REGEN_TO * heal_rate and _since_hurt > REGEN_DELAY / heal_rate:
		health = minf(health + REGEN_RATE * heal_rate * delta, REGEN_TO * heal_rate)
	# Everything below runs in the local frame; on the flat island that is the world.
	var q := Planet.basis(global_position)
	if Planet.on:
		global_basis = q
		up_direction = q.y
	var lv := q.inverse() * velocity
	var input := StreetInput.move_vector() if controls_enabled else Vector2.ZERO
	var wish := q.inverse() * (rig.right_flat() * input.x + rig.forward_flat() * input.y)
	var sprinting := controls_enabled and Input.is_action_pressed("street_sprint") and not aiming
	var target_speed := (sprint_speed if sprinting else walk_speed * (0.75 if aiming else 1.0)) * minf(input.length(), 1.0)

	if is_on_floor():
		_since_floor = 0.0
	else:
		_since_floor += delta
		lv.y -= _gravity * delta * (1.6 if lv.y < 0.0 else 1.0)

	if controls_enabled and Input.is_action_just_pressed("street_jump"):
		_jump_buffer = JUMP_BUFFER
	else:
		_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	if _jump_buffer > 0.0 and _since_floor < COYOTE:
		lv.y = jump_velocity
		_jump_buffer = 0.0
		_since_floor = COYOTE

	var hv := Vector3(lv.x, 0.0, lv.z)
	var goal := wish.normalized() * target_speed if wish.length() > 0.01 else Vector3.ZERO
	var accel := ground_accel if is_on_floor() else air_accel
	hv = hv.lerp(goal, 1.0 - exp(-accel * delta))
	lv.x = hv.x
	lv.z = hv.z
	velocity = q * lv

	var was_floor := is_on_floor()
	var before := global_position
	move_and_slide()
	if was_floor and goal != Vector3.ZERO and is_on_wall():
		if _try_step(before, q * goal * delta):
			velocity -= q.y * velocity.dot(q.y)
	lv = q.inverse() * velocity

	# Face the direction of travel.
	var prev := _facing
	if aiming:
		_facing = lerp_angle(_facing, aim_yaw, 1.0 - exp(-24.0 * delta))
	elif hv.length() > 0.4:
		_facing = lerp_angle(_facing, atan2(-hv.x, -hv.z), 1.0 - exp(-turn_speed * delta))
	_turn_rate = lerpf(_turn_rate, wrapf(_facing - prev, -PI, PI) / maxf(delta, 1e-4), 0.2)
	visual.rotation.y = _facing
	# A real drop ends in a landing (knees give) unless we land running.
	if is_on_floor():
		if _air_time > 0.45 and hv.length() < 3.0:
			visual.play_land()
		_air_time = 0.0
	else:
		_air_time += delta
	visual.animate(delta, hv.length(), is_on_floor(), lv.y, _turn_rate)


func _try_step(from_pos: Vector3, motion: Vector3) -> bool:
	## Climb a curb or stair: probe up, over the edge, and down; if there's flat ground
	## up there, lift onto it and let the next move carry the player forward.
	var up := Planet.up(from_pos)
	var dir := (motion - up * motion.dot(up)).normalized()
	var reach := maxf(motion.length(), 0.34)
	var params := PhysicsTestMotionParameters3D.new()
	var res := PhysicsTestMotionResult3D.new()
	var xf := global_transform
	xf.origin = from_pos
	params.from = xf
	params.motion = up * step_height
	if PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	xf.origin += params.motion
	params.from = xf
	params.motion = dir * reach
	if PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	xf.origin += params.motion
	params.from = xf
	params.motion = -up * step_height
	if not PhysicsServer3D.body_test_motion(get_rid(), params, res):
		return false
	if res.get_collision_normal().dot(up) < 0.7:
		return false
	var rise := (xf.origin + res.get_travel() - from_pos).dot(up)  # height of the step top
	if rise <= 0.02:
		return false
	global_position = from_pos + up * (rise + 0.01) + dir * motion.length()
	return true


func facing_yaw() -> float:
	return _facing


func hurt(amount: float, from_pos := Vector3.ZERO) -> bool:
	## Take damage; armor soaks most of it first. Returns true if this hit killed.
	if dead or amount <= 0.0:
		return false
	var soak := minf(armor, amount * ARMOR_SHARE)
	armor -= soak
	health = maxf(health - (amount - soak), 0.0)
	_since_hurt = 0.0
	damaged.emit(amount, from_pos)
	if health <= 0.0:
		dead = true
		died.emit()
		return true
	if amount >= 8.0:
		visual.play_hit()
	return false


func heal(amount: float) -> bool:
	if health >= MAX_HEALTH:
		return false
	health = minf(health + amount, MAX_HEALTH)
	return true


func add_armor(amount: float) -> bool:
	if armor >= MAX_ARMOR:
		return false
	armor = minf(armor + amount, MAX_ARMOR)
	return true


func revive() -> void:
	dead = false
	health = MAX_HEALTH
	visual.set_dead(false)
