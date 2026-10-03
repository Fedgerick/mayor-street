class_name CharacterModel
extends Node3D
## The rigged street character (player/assets/character.glb, built by
## player/tools/build_character.py) driven by an AnimationTree made in code:
## idle / walk / run blended by speed, jump and fall in the air, sitting in cars, and
## one-shot get-in / get-out clips. Same `animate()` call as the old CharacterVisual.
## `seed_value` picks an outfit, so the same model can dress a crowd.

const SCENE := "res://player/assets/character.glb"
const WALK_SPEED := 3.6     # m/s the Walk clip was authored for
const RUN_SPEED := 7.2
const LOOPS := ["Idle", "Walk", "Run", "Jump", "Fall", "Sit"]

const SKIN := [Color(0.98, 0.8, 0.66), Color(0.89, 0.66, 0.5), Color(0.7, 0.48, 0.34), Color(0.47, 0.31, 0.21), Color(0.99, 0.87, 0.76)]
const SHIRT := [Color(0.9, 0.28, 0.22), Color(0.2, 0.47, 0.86), Color(0.98, 0.78, 0.2), Color(0.24, 0.68, 0.45), Color(0.95, 0.95, 0.93), Color(0.55, 0.3, 0.72), Color(0.13, 0.14, 0.17), Color(0.98, 0.55, 0.2)]
const PANTS := [Color(0.17, 0.22, 0.38), Color(0.14, 0.14, 0.16), Color(0.47, 0.39, 0.28), Color(0.3, 0.32, 0.36), Color(0.58, 0.52, 0.43)]
const HAIR := [Color(0.12, 0.09, 0.07), Color(0.36, 0.21, 0.1), Color(0.8, 0.6, 0.32), Color(0.58, 0.16, 0.08), Color(0.22, 0.22, 0.24)]
const SHOES := [Color(0.96, 0.96, 0.96), Color(0.1, 0.1, 0.11), Color(0.62, 0.26, 0.15), Color(0.85, 0.2, 0.2)]

@export var seed_value := 7

var model: Node3D
var anim: AnimationPlayer
var tree: AnimationTree
var _air := 0.0
var _sit := 0.0
var _sitting := false
var _lean := 0.0


static func available() -> bool:
	return ResourceLoader.exists(SCENE)


func _ready() -> void:
	model = (load(SCENE) as PackedScene).instantiate()
	model.rotation.y = PI   # the glTF faces +Z; the game's forward is -Z
	add_child(model)
	anim = model.find_children("*", "AnimationPlayer", true, false)[0]
	for n in LOOPS:
		if anim.has_animation(n):
			anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	_dress()
	_build_tree()


func _dress() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pick := {
		"Skin": SKIN[rng.randi() % SKIN.size()],
		"Shirt": SHIRT[rng.randi() % SHIRT.size()],
		"Pants": PANTS[rng.randi() % PANTS.size()],
		"Hair": HAIR[rng.randi() % HAIR.size()],
		"Shoes": SHOES[rng.randi() % SHOES.size()],
	}
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		for s in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(s)
			var nm := src.resource_name if src else ""
			var mat := StandardMaterial3D.new()
			mat.albedo_color = pick.get(nm, Color(0.03, 0.03, 0.04))
			mat.roughness = {"Skin": 0.55, "Hair": 0.85, "Shoes": 0.45, "Shirt": 0.75, "Pants": 0.85}.get(nm, 0.2)
			mat.rim_enabled = nm != ""
			mat.rim = 0.3
			mat.rim_tint = 0.5
			m.set_surface_override_material(s, mat)


func _clip(n: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = n
	return a


func _build_tree() -> void:
	var bt := AnimationNodeBlendTree.new()
	var loco := AnimationNodeBlendSpace1D.new()
	loco.add_blend_point(_clip("Idle"), 0.0)
	loco.add_blend_point(_clip("Walk"), WALK_SPEED)
	loco.add_blend_point(_clip("Run"), RUN_SPEED)
	loco.min_space = 0.0
	loco.max_space = RUN_SPEED
	loco.sync = true
	bt.add_node("loco", loco, Vector2(0, 0))
	bt.add_node("pace", AnimationNodeTimeScale.new(), Vector2(200, 0))
	bt.connect_node("pace", 0, "loco")
	var airmix := AnimationNodeBlend2.new()
	bt.add_node("jump", _clip("Jump"), Vector2(0, 200))
	bt.add_node("fall", _clip("Fall"), Vector2(0, 300))
	bt.add_node("airmix", airmix, Vector2(200, 250))
	bt.connect_node("airmix", 0, "jump")
	bt.connect_node("airmix", 1, "fall")
	bt.add_node("air", AnimationNodeBlend2.new(), Vector2(400, 100))
	bt.connect_node("air", 0, "pace")
	bt.connect_node("air", 1, "airmix")
	bt.add_node("sit_clip", _clip("Sit"), Vector2(400, 300))
	bt.add_node("sit", AnimationNodeBlend2.new(), Vector2(600, 100))
	bt.connect_node("sit", 0, "air")
	bt.connect_node("sit", 1, "sit_clip")
	for k in ["EnterCar", "ExitCar"]:
		var shot := AnimationNodeOneShot.new()
		shot.fadein_time = 0.08
		shot.fadeout_time = 0.12
		bt.add_node(k, shot, Vector2(800, 100))
		bt.add_node(k + "_clip", _clip(k), Vector2(600, 300))
	bt.connect_node("EnterCar", 0, "sit")
	bt.connect_node("EnterCar", 1, "EnterCar_clip")
	bt.connect_node("ExitCar", 0, "EnterCar")
	bt.connect_node("ExitCar", 1, "ExitCar_clip")
	bt.connect_node("output", 0, "ExitCar")
	tree = AnimationTree.new()
	tree.tree_root = bt
	model.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	tree.active = true


## speed: horizontal m/s. on_floor: grounded. vy: vertical velocity. turn: yaw rate (rad/s).
func animate(delta: float, speed: float, on_floor: bool, vy: float, turn: float) -> void:
	_air = move_toward(_air, 0.0 if on_floor else 1.0, delta * (8.0 if on_floor else 5.0))
	_sit = move_toward(_sit, 1.0 if _sitting else 0.0, delta * 6.0)
	tree.set("parameters/loco/blend_position", clampf(speed, 0.0, RUN_SPEED))
	# Slow the clips down when moving slower than they were authored for, so feet don't slide.
	var pace := 1.0
	if speed > 0.2 and speed < WALK_SPEED:
		pace = maxf(speed / WALK_SPEED, 0.45)
	elif speed > RUN_SPEED:
		pace = speed / RUN_SPEED
	tree.set("parameters/pace/scale", pace)
	tree.set("parameters/airmix/blend_amount", clampf(-vy / 3.0 + 0.3, 0.0, 1.0))
	tree.set("parameters/air/blend_amount", _air)
	tree.set("parameters/sit/blend_amount", _sit)
	# Bank into turns a little.
	_lean = lerpf(_lean, clampf(-turn * speed * 0.02, -0.25, 0.25), 1.0 - exp(-8.0 * delta))
	model.rotation.z = _lean


func set_sitting(on: bool) -> void:
	_sitting = on


func play_enter_car() -> void:
	tree.set("parameters/EnterCar/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func play_exit_car() -> void:
	tree.set("parameters/ExitCar/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func clip_length(n: String) -> float:
	return anim.get_animation(n).length if anim.has_animation(n) else 0.5
