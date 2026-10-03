class_name CharacterVisual
extends Node3D
## A chunky stylized person built from primitives, with a procedural walk, run, jump
## and idle. Faces -Z. No skeleton or animation files, so it stays cheap enough to
## reuse for pedestrians. Swap for a rigged CC0 model (Quaternius / Mixamo) later by
## keeping the same `animate()` inputs.

@export var seed_value := 7

const SKIN := [Color(0.96, 0.8, 0.66), Color(0.87, 0.66, 0.5), Color(0.68, 0.47, 0.33), Color(0.45, 0.3, 0.2), Color(0.99, 0.87, 0.75)]
const SHIRT := [Color(0.9, 0.3, 0.22), Color(0.2, 0.5, 0.85), Color(0.98, 0.78, 0.2), Color(0.25, 0.7, 0.45), Color(0.95, 0.95, 0.93), Color(0.55, 0.3, 0.7), Color(0.12, 0.13, 0.16)]
const PANTS := [Color(0.18, 0.24, 0.4), Color(0.15, 0.15, 0.17), Color(0.45, 0.38, 0.28), Color(0.3, 0.32, 0.35), Color(0.55, 0.5, 0.42)]
const HAIR := [Color(0.12, 0.09, 0.07), Color(0.35, 0.2, 0.1), Color(0.75, 0.55, 0.3), Color(0.55, 0.15, 0.08), Color(0.2, 0.2, 0.22)]
const SHOES := [Color(0.95, 0.95, 0.95), Color(0.1, 0.1, 0.1), Color(0.6, 0.25, 0.15)]

const HIP_Y := 0.93

var hips: Node3D
var chest: Node3D
var head: Node3D
var arm_l: Node3D
var arm_r: Node3D
var elbow_l: Node3D
var elbow_r: Node3D
var leg_l: Node3D
var leg_r: Node3D
var knee_l: Node3D
var knee_r: Node3D

var _phase := 0.0
var _t := 0.0
var _air := 0.0
var _run := 0.0
var _move := 0.0
var _lean_side := 0.0
var _mats := {}


func _ready() -> void:
	_build()


func _mat(key: String, c: Color, rough := 0.75) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.rim_enabled = true
	m.rim = 0.25
	m.rim_tint = 0.6
	_mats[key] = m
	return m


func _capsule(parent: Node3D, r: float, h: float, mat: Material, pos: Vector3, scale_xz := Vector2.ONE) -> MeshInstance3D:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = maxf(h, r * 2.0)
	m.radial_segments = 12
	m.rings = 3
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	mi.scale = Vector3(scale_xz.x, 1.0, scale_xz.y)
	parent.add_child(mi)
	return mi


func _sphere(parent: Node3D, r: float, mat: Material, pos: Vector3, sc := Vector3.ONE) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 14
	m.rings = 7
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	mi.scale = sc
	parent.add_child(mi)
	return mi


func _box(parent: Node3D, size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _pivot(parent: Node3D, pos: Vector3, nm: String) -> Node3D:
	var n := Node3D.new()
	n.name = nm
	n.position = pos
	parent.add_child(n)
	return n


func _build() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var skin := _mat("skin", SKIN[rng.randi() % SKIN.size()], 0.6)
	var shirt := _mat("shirt", SHIRT[rng.randi() % SHIRT.size()])
	var pants := _mat("pants", PANTS[rng.randi() % PANTS.size()], 0.85)
	var hair := _mat("hair", HAIR[rng.randi() % HAIR.size()], 0.9)
	var shoes := _mat("shoes", SHOES[rng.randi() % SHOES.size()], 0.5)
	var dark := _mat("eyes", Color(0.05, 0.05, 0.07), 0.3)

	hips = _pivot(self, Vector3(0, HIP_Y, 0), "Hips")
	_capsule(hips, 0.17, 0.36, pants, Vector3(0, 0.02, 0), Vector2(1.25, 0.85))
	chest = _pivot(hips, Vector3(0, 0.12, 0), "Chest")
	_capsule(chest, 0.2, 0.56, shirt, Vector3(0, 0.22, 0), Vector2(1.18, 0.82))
	_capsule(chest, 0.07, 0.14, skin, Vector3(0, 0.5, 0))  # neck
	head = _pivot(chest, Vector3(0, 0.6, 0), "Head")
	_sphere(head, 0.165, skin, Vector3(0, 0.12, 0), Vector3(1.0, 1.08, 1.0))
	_sphere(head, 0.172, hair, Vector3(0, 0.17, 0.02), Vector3(1.03, 0.82, 1.05))
	_sphere(head, 0.024, dark, Vector3(-0.058, 0.13, -0.152))
	_sphere(head, 0.024, dark, Vector3(0.058, 0.13, -0.152))
	_sphere(head, 0.03, skin, Vector3(0, 0.09, -0.165))  # nose

	for side in [-1, 1]:
		var sh := _pivot(chest, Vector3(0.27 * side, 0.4, 0), "Shoulder")
		_sphere(sh, 0.085, shirt, Vector3.ZERO)
		_capsule(sh, 0.07, 0.3, shirt, Vector3(0, -0.13, 0))
		var el := _pivot(sh, Vector3(0, -0.28, 0), "Elbow")
		_capsule(el, 0.058, 0.28, skin, Vector3(0, -0.12, 0))
		_sphere(el, 0.065, skin, Vector3(0, -0.28, -0.01))
		sh.rotation.z = 0.08 * side
		var hip := _pivot(hips, Vector3(0.105 * side, -0.04, 0), "Hip")
		_capsule(hip, 0.09, 0.46, pants, Vector3(0, -0.2, 0))
		var kn := _pivot(hip, Vector3(0, -0.43, 0), "Knee")
		_capsule(kn, 0.075, 0.44, pants, Vector3(0, -0.2, 0))
		_box(kn, Vector3(0.13, 0.09, 0.27), shoes, Vector3(0, -0.425, -0.04))
		if side < 0:
			arm_l = sh; elbow_l = el; leg_l = hip; knee_l = kn
		else:
			arm_r = sh; elbow_r = el; leg_r = hip; knee_r = kn
	for mi in find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


## speed: horizontal m/s. on_floor: grounded. vy: vertical velocity. turn: yaw rate (rad/s).
func animate(delta: float, speed: float, on_floor: bool, vy: float, turn: float) -> void:
	_t += delta
	var k := 1.0 - exp(-10.0 * delta)
	_move = lerpf(_move, clampf(speed / 3.5, 0.0, 1.0), k)
	_run = lerpf(_run, clampf((speed - 4.0) / 3.5, 0.0, 1.0), k)
	_air = lerpf(_air, 0.0 if on_floor else 1.0, 1.0 - exp(-14.0 * delta))
	_lean_side = lerpf(_lean_side, clampf(-turn * speed * 0.025, -0.3, 0.3), k)
	if on_floor:
		# One full cycle every two steps; stride gets longer when running.
		_phase += delta * speed * lerpf(2.6, 1.75, _run)
	var ph := _phase
	var swing := lerpf(0.55, 0.95, _run) * _move
	var s := sin(ph)
	var c := cos(ph)

	# Legs: thigh swing, knee folds during the forward swing.
	var thigh_l := s * swing
	var thigh_r := -s * swing
	var knee_amt := lerpf(0.7, 1.5, _run) * _move
	var kl := -knee_amt * maxf(0.0, c) - 0.1 * _move
	var kr := -knee_amt * maxf(0.0, -c) - 0.1 * _move
	# Air pose: tuck.
	thigh_l = lerpf(thigh_l, 0.7, _air)
	thigh_r = lerpf(thigh_r, -0.1, _air)
	kl = lerpf(kl, -1.2, _air)
	kr = lerpf(kr, -0.4, _air)
	leg_l.rotation.x = thigh_l
	leg_r.rotation.x = thigh_r
	knee_l.rotation.x = kl
	knee_r.rotation.x = kr

	# Arms swing opposite to legs; elbows bend more when running.
	var arm_sw := lerpf(0.45, 1.0, _run) * _move
	var elbow := lerpf(0.2, 1.35, _run) * _move + 0.15
	arm_l.rotation.x = lerpf(-s * arm_sw, 2.3, _air * 0.7)
	arm_r.rotation.x = lerpf(s * arm_sw, 1.9, _air * 0.7)
	arm_l.rotation.z = lerpf(-0.08 - 0.05 * _run, -0.5, _air)
	arm_r.rotation.z = lerpf(0.08 + 0.05 * _run, 0.5, _air)
	elbow_l.rotation.x = lerpf(elbow, 0.4, _air)
	elbow_r.rotation.x = lerpf(elbow, 0.4, _air)

	# Body: bob twice per cycle, lean into speed and turns, breathe when idle.
	var bob := (1.0 - absf(c)) * lerpf(0.035, 0.07, _run) * _move
	var breathe := sin(_t * 2.2) * 0.006 * (1.0 - _move)
	hips.position.y = HIP_Y - bob + breathe - _air * 0.05 * (1.0 if vy < 0.0 else 0.0)
	hips.rotation.y = s * 0.12 * _move
	hips.rotation.z = _lean_side
	chest.rotation.x = -lerpf(0.04, 0.32, _run) * _move + breathe * 2.0 + _air * 0.1
	chest.rotation.y = -s * 0.2 * _move
	head.rotation.x = -chest.rotation.x * 0.6
	head.rotation.y = -chest.rotation.y * 0.8


func sit_pose() -> void:
	## Driving pose, used if the character is shown inside a convertible later.
	leg_l.rotation.x = 1.5
	leg_r.rotation.x = 1.5
	knee_l.rotation.x = -1.4
	knee_r.rotation.x = -1.4
	arm_l.rotation.x = -1.1
	arm_r.rotation.x = -1.1
