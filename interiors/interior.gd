class_name Interior
extends Node3D
## One enterable room, built from interiors/models/<id>.glb (made by art/tools/build_interiors.py).
##
## The glb carries the room mesh, a "-colonly" collision mesh (Godot turns it into a
## StaticBody3D on import), empties named M_<name> for points of interest and
## L_<rrggbb>_<range>_<energy x10> for lights. This script turns the L_ empties into
## OmniLights, puts the room on its own render layer (so the city's sun doesn't light it)
## and adds a walk-out trigger at M_exit. Chairs, sofas, benches and stools listed for the
## room in interiors/seats.json (written by the same build script) are seats the player can
## sit on (player/ StreetSeating finds them through the "seat_sources" group).

signal exit_requested

const LAYER := 1 << 19          # render layer 20: interiors only
const EXIT_SIZE := Vector3(1.8, 2.4, 0.8)
const SEATS_PATH := "res://interiors/seats.json"
const SEAT_HEIGHT := 0.45       # the sitting clips' seat height; higher seats lift the sitter

static var _seat_data := {}

@export var interior_id := ""

var markers := {}               # "spawn" -> Node3D, "vault" -> Node3D, ...
var _exit_area: Area3D
var _armed := false             # the exit only fires once the player has stepped away from it
var seats: Array = []            # [Transform3D (room space, origin under the hips), kind, height]
var _taken := {}                 # seat index -> who sits there


static func create(id: String) -> Interior:
	var r := Interior.new()
	r.interior_id = id
	r.name = "Interior_" + id
	return r


static func model_path(id: String) -> String:
	return "res://interiors/models/%s.glb" % id


static func exists(id: String) -> bool:
	return ResourceLoader.exists(model_path(id))


func _ready() -> void:
	var scene: PackedScene = load(model_path(interior_id))
	var model := scene.instantiate()
	model.name = "Model"
	add_child(model)
	_walk(model)
	if markers.has("exit"):
		_add_exit(markers["exit"])
	_load_seats()
	add_to_group("seat_sources")


func _load_seats() -> void:
	if _seat_data.is_empty() and FileAccess.file_exists(SEATS_PATH):
		var d = JSON.parse_string(FileAccess.get_file_as_string(SEATS_PATH))
		if d is Dictionary:
			_seat_data = d
	for e in _seat_data.get(interior_id, []):
		var b := Basis(Vector3.UP, deg_to_rad(float(e[3])))
		# The sitter's origin is on the floor under the seat's middle (raised for tall seats).
		var lift := maxf(float(e[1]) - SEAT_HEIGHT, 0.0)
		seats.append([Transform3D(b, Vector3(float(e[0]), lift, float(e[2]))), String(e[4]), float(e[1])])


## Free seats within radius of a world point (see StreetSeating): {xform (world, -Z = the
## way the sitter faces), kind, lift, interior, slot}.
func seats_near(world_pos: Vector3, radius: float) -> Array:
	var out := []
	for i in seats.size():
		if _taken.has(i):
			continue
		var xf: Transform3D = global_transform * (seats[i][0] as Transform3D)
		if xf.origin.distance_to(world_pos) <= radius:
			out.append({"xform": xf, "kind": seats[i][1], "lift": (seats[i][0] as Transform3D).origin.y,
				"park": false, "interior": interior_id, "slot": i, "source": self})
	return out


func claim_seat(seat: Dictionary, who: Object) -> bool:
	if _taken.has(seat.slot) and _taken[seat.slot] != who:
		return false
	_taken[seat.slot] = who
	return true


func release_seat(seat: Dictionary, who: Object) -> void:
	if _taken.get(seat.slot) == who:
		_taken.erase(seat.slot)


func marker(name_: String) -> Node3D:
	## A point of interest (M_<name> in Blender): "spawn", "exit", "vault", "stash", "cell_1"...
	return markers.get(name_)


func marker_names() -> Array:
	return markers.keys()


func spawn_transform() -> Transform3D:
	var m: Node3D = markers.get("spawn")
	return m.global_transform if m else global_transform


func _walk(n: Node) -> void:
	for c in n.get_children():
		_walk(c)
	if n is VisualInstance3D:
		(n as VisualInstance3D).layers = LAYER
	var nm := String(n.name)
	if nm.begins_with("M_"):
		markers[nm.substr(2)] = n
	elif nm.begins_with("L_"):
		_add_light(n as Node3D, nm)


func _add_light(at: Node3D, nm: String) -> void:
	var parts := nm.split("_")
	if parts.size() < 4:
		return
	var l := OmniLight3D.new()
	l.light_color = Color.html(parts[1])
	l.omni_range = float(parts[2])
	l.light_energy = float(parts[3]) / 10.0
	l.omni_attenuation = 1.2
	l.shadow_enabled = false          # cheap on integrated graphics
	l.light_cull_mask = LAYER | 1     # the room and the player
	at.add_child(l)


func _add_exit(m: Node3D) -> void:
	_exit_area = Area3D.new()
	_exit_area.name = "Exit"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = EXIT_SIZE
	cs.shape = box
	cs.position = Vector3(0, EXIT_SIZE.y * 0.5, -0.1)
	_exit_area.add_child(cs)
	_exit_area.monitorable = false
	m.add_child(_exit_area)
	_exit_area.body_entered.connect(func(b: Node3D) -> void:
		if b is StreetPlayer and _armed:
			exit_requested.emit())
	_exit_area.body_exited.connect(func(b: Node3D) -> void:
		if b is StreetPlayer:
			_armed = true)


func arm_exit_after(seconds: float) -> void:
	## Called on entry: the player appears next to the exit, so wait before it can fire.
	_armed = false
	await get_tree().create_timer(seconds).timeout
	if not is_instance_valid(_exit_area):
		return
	for b in _exit_area.get_overlapping_bodies():
		if b is StreetPlayer:
			return          # still standing in it: body_exited will arm it
	_armed = true
