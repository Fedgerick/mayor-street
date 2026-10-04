class_name StreetCombat
extends Node
## On-foot weapons: fists, one pistol, one shotgun. Hold right mouse (left trigger) to
## aim over the shoulder, left mouse (right trigger) to punch or fire; Q / mouse wheel /
## 1-3 switch. Shots are hitscan from the centre of the screen, so what the crosshair
## covers is what gets hit; the tracer is drawn from the gun's muzzle.
##
## StreetMode owns this node and resolves what a shot hits (`StreetMode.trace_shot`) and
## what damage does (`StreetMode.apply_hit`), because the targets (people, police, cars)
## live there and in citylife/.

signal weapon_changed(id: StringName)
signal fired(id: StringName)

const ORDER: Array[StringName] = [&"fists", &"pistol", &"shotgun"]
const WEAPONS := {
	&"fists": {"name": "Fists", "damage": 12.0, "range": 1.6, "cooldown": 0.45, "pellets": 1, "spread": 0.0,
		"aim": CharacterModel.Aim.NONE, "shake": 0.0},
	&"pistol": {"name": "Pistol", "damage": 25.0, "range": 70.0, "cooldown": 0.28, "pellets": 1, "spread": 0.8,
		"aim": CharacterModel.Aim.PISTOL, "shake": 0.25, "pickup_ammo": 34, "max_ammo": 170},
	&"shotgun": {"name": "Shotgun", "damage": 12.0, "range": 26.0, "cooldown": 0.95, "pellets": 8, "spread": 5.5,
		"aim": CharacterModel.Aim.SHOTGUN, "shake": 0.6, "pickup_ammo": 12, "max_ammo": 60},
}
const AIM_DISTANCE := 2.1
const AIM_SIDE := 0.62
const AIM_FOV := 0.8          # street FOV multiplier while aiming
const POSE_HOLD := 0.7        # seconds the gun stays raised after a hip-fire shot
const PUNCH_DELAY := 0.14     # the fist lands this long after the swing starts

var street: Node              # StreetMode
var current: StringName = &"fists"
var ammo := {&"pistol": 0, &"shotgun": 0}
var aiming := false
var _cool := 0.0
var _pose := 0.0
var _gun: Node3D
var _guns := {}
var _base_distance := 3.6
var _base_side := 0.35
var _base_fov := 68.0
var _rng := RandomNumberGenerator.new()


func setup(s: Node) -> void:
	street = s
	_base_distance = s.player.rig.distance
	_base_side = s.player.rig.side_offset
	_base_fov = s.camera.street_fov
	_rng.randomize()


func has_weapon(id: StringName) -> bool:
	return id == &"fists" or ammo.get(id, 0) > 0


func give(id: StringName, rounds := -1) -> bool:
	## Add a weapon or its ammo. Returns false when already full.
	if id == &"fists" or not WEAPONS.has(id):
		return false
	var w: Dictionary = WEAPONS[id]
	var n: int = w.pickup_ammo if rounds < 0 else rounds
	if ammo[id] >= w.max_ammo:
		return false
	var had: bool = ammo[id] > 0
	ammo[id] = mini(ammo[id] + n, w.max_ammo)
	if not had and current == &"fists":
		select(id)
	return true


func strip() -> void:
	## Busted: the police keep your guns.
	for k in ammo:
		ammo[k] = 0
	select(&"fists")


func select(id: StringName) -> void:
	if not has_weapon(id):
		return
	if id != current:
		current = id
		weapon_changed.emit(id)
	_show_gun()


func cycle(step: int) -> void:
	var i := ORDER.find(current)
	for k in ORDER.size():
		i = wrapi(i + step, 0, ORDER.size())
		if has_weapon(ORDER[i]):
			select(ORDER[i])
			return


func weapon_name() -> String:
	return WEAPONS[current].name


func ammo_text() -> String:
	return "" if current == &"fists" else str(ammo[current])


func show_crosshair() -> bool:
	return aiming or (current != &"fists" and _pose > 0.0)


# ---------------------------------------------------------------------- update ---

func _process(delta: float) -> void:
	if street == null:
		return
	var p: StreetPlayer = street.player
	_cool = maxf(_cool - delta, 0.0)
	_pose = maxf(_pose - delta, 0.0)
	var can: bool = street.can_fight()
	if not can:
		_set_aim(false, p)
		if _gun:
			_gun.visible = not p.in_vehicle and not p.dead and current != &"fists"
		return
	if Input.is_action_just_pressed("street_next_weapon"):
		cycle(1)
	elif Input.is_action_just_pressed("street_prev_weapon"):
		cycle(-1)
	for k in 3:
		if Input.is_action_just_pressed("street_weapon_%d" % (k + 1)):
			select(ORDER[k])
	if current != &"fists" and not has_weapon(current):
		cycle(-1)
	_set_aim(Input.is_action_pressed("street_aim") and current != &"fists", p)
	p.aim_yaw = p.rig.yaw
	p.aiming = aiming or _pose > 0.0
	p.visual.set_aim(WEAPONS[current].aim if p.aiming else CharacterModel.Aim.NONE)
	if Input.is_action_pressed("street_fire") and _cool <= 0.0 and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		fire()


func _set_aim(on: bool, p: StreetPlayer) -> void:
	if on == aiming:
		return
	aiming = on
	p.rig.distance = AIM_DISTANCE if on else _base_distance
	p.rig.side_offset = AIM_SIDE if on else _base_side
	street.camera.street_fov = _base_fov * (AIM_FOV if on else 1.0)
	if not on:
		p.aiming = _pose > 0.0


func fire() -> void:
	var w: Dictionary = WEAPONS[current]
	var p: StreetPlayer = street.player
	if current != &"fists" and ammo[current] <= 0:
		return
	_cool = w.cooldown
	if current == &"fists":
		p.visual.play_punch()
		fired.emit(current)
		_punch_land.call_deferred(w)
		return
	ammo[current] -= 1
	# Hip fire: snap round to where the camera looks and hold the gun up a moment.
	if not aiming:
		p.face(p.rig.yaw)
	_pose = POSE_HOLD
	p.aiming = true
	p.visual.set_aim(w.aim)
	var cam: Camera3D = street.camera
	var origin := cam.global_position
	var fwd := -cam.global_basis.z
	# Start the ray level with the player so nothing between camera and player is hit.
	var skip := maxf((p.global_position - origin).dot(fwd), 0.0)
	var muzzle := muzzle_point()
	for i in int(w.pellets):
		var dir := _spread(fwd, cam.global_basis, w.spread)
		var hit: Dictionary = street.trace_shot(origin + dir * skip, dir, w.range)
		street.apply_hit(hit, w.damage, dir, current)
		StreetFx.tracer(street, muzzle, hit.pos)
	StreetFx.muzzle(street, muzzle, fwd, current == &"shotgun")
	street.camera.shake(w.shake)
	street.on_shot_fired(current, muzzle)
	fired.emit(current)


func _punch_land(w: Dictionary) -> void:
	await get_tree().create_timer(PUNCH_DELAY).timeout
	if street == null or not street.can_fight():
		return
	var p: StreetPlayer = street.player
	var yaw := p.facing_yaw()
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var from := p.global_position + Vector3.UP * 1.3
	var hit: Dictionary = street.trace_shot(from, fwd, w.range, true)
	if hit.kind != &"none":
		street.apply_hit(hit, w.damage, fwd, &"fists")


func _spread(fwd: Vector3, b: Basis, deg: float) -> Vector3:
	if deg <= 0.0:
		return fwd
	var a := _rng.randf() * TAU
	var r := sqrt(_rng.randf()) * deg_to_rad(deg)
	return (fwd + (b.x * cos(a) + b.y * sin(a)) * tan(r)).normalized()


func muzzle_point() -> Vector3:
	if _gun and _gun.visible and _gun.has_node("Tip"):
		return (_gun.get_node("Tip") as Node3D).global_position
	var p: StreetPlayer = street.player
	return p.global_position + Vector3.UP * 1.35 + p.rig.forward_flat() * 0.6


# ---------------------------------------------------------------- gun meshes ---

func _show_gun() -> void:
	var p: StreetPlayer = street.player
	if not CharacterModel.available() or p.visual.model == null:
		return
	for k in _guns:
		_guns[k].visible = false
	_gun = null
	if current == &"fists":
		return
	if not _guns.has(current):
		var g := gun_model(current)
		p.visual.hand_socket().add_child(g)
		_guns[current] = g
	_gun = _guns[current]
	_gun.visible = true


static func gun_model(id: StringName) -> Node3D:
	## Built from boxes and cylinders: dark metal, a wooden stock on the shotgun.
	## The barrel runs along the hand bone (+Y), the grip in the palm.
	var root := Node3D.new()
	root.name = String(id).capitalize()
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.09, 0.09, 0.1)
	metal.metallic = 0.7
	metal.roughness = 0.35
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.36, 0.2, 0.1)
	wood.roughness = 0.6
	var parts: Array = []
	var tip := 0.0
	if id == &"pistol":
		# [size, position, material]
		parts = [[Vector3(0.035, 0.2, 0.05), Vector3(0, 0.1, 0.03), metal],     # slide
			[Vector3(0.03, 0.05, 0.11), Vector3(0, 0.02, -0.03), metal]]     # grip
		tip = 0.21
	else:
		parts = [[Vector3(0.04, 0.62, 0.045), Vector3(0, 0.33, 0.035), metal],  # barrel
			[Vector3(0.05, 0.22, 0.06), Vector3(0, 0.36, -0.005), wood],    # pump
			[Vector3(0.045, 0.16, 0.07), Vector3(0, 0.0, 0.02), metal],     # receiver
			[Vector3(0.04, 0.26, 0.09), Vector3(0, -0.18, 0.0), wood]]      # stock
		tip = 0.65
	for part in parts:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = part[0]
		mi.mesh = bm
		mi.position = part[1]
		mi.material_override = part[2]
		root.add_child(mi)
	var t := Marker3D.new()
	t.name = "Tip"
	t.position = Vector3(0, tip, 0.035)
	root.add_child(t)
	# Sit in the palm: a little past the wrist, barrel along the fingers.
	root.position = Vector3(0.0, 0.07, 0.03)
	return root
