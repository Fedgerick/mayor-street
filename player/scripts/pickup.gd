class_name Pickup
extends Area3D
## A floating, spinning pickup on the street: health, armor, pistol or shotgun. Walk
## through it to take it; it comes back after `respawn_seconds` (0 = never, for one-off
## mission drops). StreetMode decides whether the player can use it (full health, full
## ammo) through `StreetMode.try_pickup`.

signal taken(kind: StringName)

const KINDS: Array[StringName] = [&"health", &"armor", &"pistol", &"shotgun"]
const GLOW := {&"health": Color(1.0, 0.25, 0.25), &"armor": Color(0.3, 0.55, 1.0),
	&"pistol": Color(1.0, 0.8, 0.3), &"shotgun": Color(1.0, 0.8, 0.3)}

@export var kind: StringName = &"health"
@export var respawn_seconds := 45.0

var street: Node
var _icon: Node3D
var _wait := 0.0
var _t := 0.0


func _ready() -> void:
	add_to_group("pickups")
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	var cs := CollisionShape3D.new()
	var sh := CylinderShape3D.new()
	sh.radius = 0.8
	sh.height = 2.0
	cs.shape = sh
	cs.position.y = 1.0
	add_child(cs)
	_icon = _make_icon(kind)
	_icon.position.y = 0.9
	add_child(_icon)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	tm.rings = 24
	tm.ring_segments = 6
	ring.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = GLOW[kind]
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color.a = 0.6
	ring.material_override = rm
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position.y = 0.05
	ring.scale = Vector3(1, 0.3, 1)
	_icon.add_child(ring)
	ring.position.y = -0.8
	var l := OmniLight3D.new()
	l.light_color = GLOW[kind]
	l.light_energy = 0.8
	l.omni_range = 2.5
	l.shadow_enabled = false
	_icon.add_child(l)
	body_entered.connect(_on_body)


func _process(delta: float) -> void:
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0:
			_icon.visible = true
			set_deferred("monitoring", true)
		return
	_t += delta
	_icon.rotation.y = _t * 1.6
	_icon.position.y = 0.9 + sin(_t * 2.2) * 0.08


func available() -> bool:
	return _wait <= 0.0


func _on_body(b: Node) -> void:
	if not (b is StreetPlayer) or not available():
		return
	if street and not street.try_pickup(kind):
		return
	taken.emit(kind)
	if respawn_seconds <= 0.0:
		queue_free()
		return
	_wait = respawn_seconds
	_icon.visible = false
	set_deferred("monitoring", false)


static func _make_icon(k: StringName) -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	match k:
		&"health":
			# A white box with a red cross.
			mat.albedo_color = Color(0.95, 0.95, 0.95)
			mat.emission = Color(0.4, 0.4, 0.4)
			_box(root, Vector3(0.5, 0.36, 0.3), Vector3.ZERO, mat)
			var red := StandardMaterial3D.new()
			red.albedo_color = Color(0.9, 0.08, 0.08)
			red.emission_enabled = true
			red.emission = Color(0.7, 0.0, 0.0)
			for s in [-1, 1]:
				_box(root, Vector3(0.24, 0.07, 0.02), Vector3(0, 0, s * 0.16), red)
				_box(root, Vector3(0.07, 0.24, 0.02), Vector3(0, 0, s * 0.16), red)
		&"armor":
			# A blue vest: a body plate and two shoulder straps.
			mat.albedo_color = Color(0.12, 0.26, 0.6)
			mat.emission = Color(0.05, 0.15, 0.5)
			_box(root, Vector3(0.44, 0.4, 0.14), Vector3(0, -0.02, 0), mat)
			for s in [-1, 1]:
				_box(root, Vector3(0.1, 0.14, 0.14), Vector3(s * 0.15, 0.24, 0), mat)
		_:
			var g := StreetCombat.gun_model(k)
			g.position = Vector3.ZERO
			g.rotation = Vector3(0, 0, PI * 0.5)
			g.scale = Vector3.ONE * (2.2 if k == &"pistol" else 1.3)
			root.add_child(g)
	return root


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
