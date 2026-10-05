class_name CarDrawer
extends Node3D
## Draws every car of one model: three MultiMeshes, one per level of detail from the car
## kit (VehicleKit LOD0 near the camera, LOD1 and LOD2 farther out), filled from flat
## buffers each frame. Cars face -Z. Instance colour is the paint tint, custom data the
## VehicleKit flags (siren, brake, ...), wheel roll, steer and seed.

var model := ""
var max_count := 0
var _mmi: Array[MultiMeshInstance3D] = []
var _buf: Array[PackedFloat32Array] = []
var _n := [0, 0, 0]


func setup(model_name: String, count: int, fallback: Mesh = null) -> void:
	model = model_name
	name = model_name
	max_count = count
	var base: Mesh = VehicleKit.mesh(model, 0)
	if base == null:
		var kit: Node = Engine.get_main_loop().root.get_node_or_null("Kit")
		base = kit.mesh(model) if kit else null
	if base == null:
		base = fallback
	if base == null:
		var b := BoxMesh.new()
		b.size = Vector3(1.8, 1.4, 4.4)
		base = b
	for lod in 3:
		var mesh: Mesh = VehicleKit.mesh(model, lod) if lod > 0 else base
		if mesh == null:
			mesh = base
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = count
		mm.visible_instance_count = 0
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "LOD%d" % lod
		mmi.multimesh = mm
		add_child(mmi)
		_mmi.append(mmi)
		var buf := PackedFloat32Array()
		buf.resize(count * 20)
		_buf.append(buf)


func begin() -> void:
	_n = [0, 0, 0]


func add(pos: Vector3, fwd: Vector3, tint: Color, custom: Color, lod: int) -> void:
	var n: int = _n[lod]
	if n >= max_count:
		return
	_n[lod] = n + 1
	var back := -fwd
	var right := Vector3.UP.cross(back).normalized()
	var b := _buf[lod]
	var o := n * 20
	b[o] = right.x; b[o + 1] = 0.0; b[o + 2] = back.x; b[o + 3] = pos.x
	b[o + 4] = right.y; b[o + 5] = 1.0; b[o + 6] = back.y; b[o + 7] = pos.y
	b[o + 8] = right.z; b[o + 9] = 0.0; b[o + 10] = back.z; b[o + 11] = pos.z
	b[o + 12] = tint.r; b[o + 13] = tint.g; b[o + 14] = tint.b; b[o + 15] = 1.0
	b[o + 16] = custom.r; b[o + 17] = custom.g; b[o + 18] = custom.b; b[o + 19] = custom.a


func finish(shadows: bool) -> void:
	for lod in 3:
		var mm := _mmi[lod].multimesh
		mm.buffer = _buf[lod]
		mm.visible_instance_count = _n[lod]
		# The far cars' shadows are too small to see.
		var cast := shadows and lod < 2
		_mmi[lod].cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func count() -> int:
	return _n[0] + _n[1] + _n[2]


## Which LOD to draw a car at `pos` with, seen from `eye` (or LOD1 with no camera).
static func lod_at(pos: Vector3, eye: Vector3, has_eye: bool) -> int:
	if not has_eye:
		return 1
	return VehicleKit.lod_for(pos.distance_to(eye))
