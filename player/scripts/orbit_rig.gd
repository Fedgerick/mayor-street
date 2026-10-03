class_name OrbitRig
extends Node3D
## A third-person camera boom that follows a target. It doesn't own a camera: the
## StreetCamera reads `eye.global_transform` so one camera can glide between rigs
## (mayor view -> character -> car) without cuts.

@export var height := 1.6
@export var distance := 3.8
@export var side_offset := 0.35         # over-the-shoulder
@export var min_pitch := deg_to_rad(-70.0)
@export var max_pitch := deg_to_rad(35.0)
@export var mouse_sensitivity := 0.0025
@export var stick_speed := 2.6
@export var follow_sharpness := 18.0    # how tightly the boom tracks the target
@export var recenter_speed := 0.0       # >0: swing behind the target's heading when idle (cars)
@export var recenter_delay := 1.2
@export var collision_mask := 1 | 2      # world and cars (cars are layer 2)

var target: Node3D
var yaw := 0.0
var pitch := deg_to_rad(-12.0)
var input_enabled := false
var heading := 0.0                      # set by the owner each frame, used by recentering
var spring: SpringArm3D
var eye: Marker3D

var _idle := 0.0
var _boom_length := 0.0


func _init() -> void:
	top_level = true
	spring = SpringArm3D.new()
	spring.name = "Spring"
	var s := SphereShape3D.new()
	s.radius = 0.22
	spring.shape = s
	spring.margin = 0.15
	add_child(spring)
	eye = Marker3D.new()
	eye.name = "Eye"
	spring.add_child(eye)


func _ready() -> void:
	spring.collision_mask = collision_mask
	spring.spring_length = distance
	_boom_length = distance
	if target is CollisionObject3D:
		spring.add_excluded_object((target as CollisionObject3D).get_rid())
	snap()


func exclude(body: CollisionObject3D) -> void:
	spring.add_excluded_object(body.get_rid())


func snap() -> void:
	if target:
		global_position = target.global_position + Vector3.UP * height
	_apply()


func look_from(t: Transform3D) -> void:
	## Point the boom the way a given camera faces, for a seamless hand-off.
	var f := -t.basis.z
	yaw = atan2(-f.x, -f.z)


func _unhandled_input(e: InputEvent) -> void:
	if not input_enabled:
		return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var r: Vector2 = e.relative
		yaw -= r.x * mouse_sensitivity
		pitch = clampf(pitch - r.y * mouse_sensitivity, min_pitch, max_pitch)
		_idle = 0.0


func _process(delta: float) -> void:
	if input_enabled:
		var st := StreetInput.look_stick()
		if st != Vector2.ZERO:
			yaw -= st.x * stick_speed * delta
			pitch = clampf(pitch - st.y * stick_speed * 0.7 * delta, min_pitch, max_pitch)
			_idle = 0.0
	_idle += delta
	if recenter_speed > 0.0 and _idle > recenter_delay:
		yaw = lerp_angle(yaw, heading, 1.0 - exp(-recenter_speed * delta))
		pitch = lerpf(pitch, deg_to_rad(-12.0), 1.0 - exp(-recenter_speed * 0.5 * delta))
	if target:
		var goal := target.global_position + Vector3.UP * height
		global_position = global_position.lerp(goal, 1.0 - exp(-follow_sharpness * delta))
	_boom_length = lerpf(_boom_length, distance, 1.0 - exp(-4.0 * delta))
	spring.spring_length = _boom_length
	_apply()


func _apply() -> void:
	basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))
	spring.position = Vector3(side_offset, 0.0, 0.0)


func forward_flat() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func right_flat() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))
