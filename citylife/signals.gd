class_name Signals
extends Node3D
## Traffic signal heads at every junction: one pole per approach on the near-right
## corner, with red, amber and green lamps that follow RoadNet's phases. Poles are one
## static MultiMesh; lamps are a second MultiMesh whose colours refresh a few times a second.

const BULB_SHADER := """
shader_type spatial;
render_mode cull_back;
void fragment() {
	ALBEDO = COLOR.rgb * 0.25;
	ROUGHNESS = 0.3;
	EMISSION = COLOR.rgb * COLOR.a * 5.0;
}
"""
const CORNER := 4.35
const LAMP_Y := [3.32, 3.0, 2.68]  # red, amber, green
const ON := [Color(1.0, 0.1, 0.06, 1.0), Color(1.0, 0.6, 0.05, 1.0), Color(0.15, 1.0, 0.45, 1.0)]

var net: RoadNet
var heads: Array = []    # [cell, heading, Transform3D]
var _poles: MultiMeshInstance3D
var _bulbs: MultiMeshInstance3D
var _accum := 0.0


func setup(road_net: RoadNet) -> void:
	net = road_net
	_poles = MultiMeshInstance3D.new()
	_poles.name = "SignalPoles"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _pole_mesh()
	_poles.multimesh = mm
	add_child(_poles)
	_bulbs = MultiMeshInstance3D.new()
	_bulbs.name = "SignalLamps"
	_bulbs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var bm := MultiMesh.new()
	bm.transform_format = MultiMesh.TRANSFORM_3D
	bm.use_colors = true
	var sphere := SphereMesh.new()
	sphere.radius = 0.1
	sphere.height = 0.2
	sphere.radial_segments = 8
	sphere.rings = 4
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = BULB_SHADER
	sphere.material = mat
	bm.mesh = sphere
	_bulbs.multimesh = bm
	add_child(_bulbs)
	rebuild()


func rebuild() -> void:
	heads.clear()
	for i in net.junction.size():
		if net.junction[i] != 1:
			continue
		for d in 4:
			if not net.has_arm(i, RoadNet.opp(d)):
				continue  # nobody arrives heading d
			var back: Vector3 = -RoadNet.DV[d]
			var pos: Vector3 = net.center(i) + back * CORNER + RoadNet.right_of(d) * CORNER + Vector3(0, 0.17, 0)
			# Lamps face oncoming traffic: local -Z points back down the approach.
			var basis := Basis.looking_at(back, Vector3.UP)
			heads.append([i, d, Transform3D(basis, pos)])
	var mm := _poles.multimesh
	mm.instance_count = heads.size()
	for k in heads.size():
		mm.set_instance_transform(k, heads[k][2])
	_bulbs.multimesh.instance_count = heads.size() * 3
	_accum = 1.0
	update(0.0)


func update(dt: float) -> void:
	_accum += dt
	if _accum < 0.2:
		return
	_accum = 0.0
	var bm := _bulbs.multimesh
	for k in heads.size():
		var h: Array = heads[k]
		var state := net.light(h[0], h[1] % 2)
		var on_idx := 0 if state == RoadNet.Light.RED else (1 if state == RoadNet.Light.AMBER else 2)
		var xf: Transform3D = h[2]
		for b in 3:
			var c: Color = ON[b]
			if b != on_idx:
				c = Color(c.r * 0.12, c.g * 0.12, c.b * 0.12, 0.0)
			bm.set_instance_transform(k * 3 + b, Transform3D(xf.basis, xf * Vector3(0, LAMP_Y[b], -0.2)))
			bm.set_instance_color(k * 3 + b, c)


func _pole_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(-0.07, 0, -0.07), Vector3(0.07, 3.55, 0.07))           # pole
	_box(st, Vector3(-0.19, 2.48, -0.17), Vector3(0.19, 3.52, 0.12))        # housing
	for y in LAMP_Y:
		_box(st, Vector3(-0.15, y + 0.1, -0.36), Vector3(0.15, y + 0.13, -0.17))  # visor
	_box(st, Vector3(-0.3, 2.4, 0.12), Vector3(0.3, 3.6, 0.14))             # backplate
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.17, 0.18)
	mat.roughness = 0.55
	mat.metallic = 0.3
	mesh.surface_set_material(0, mat)
	return mesh


static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var c := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	# Clockwise from outside.
	var faces := [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7], [4, 5, 6, 7], [3, 2, 1, 0]]
	for f in faces:
		for k in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(c[f[k]])
