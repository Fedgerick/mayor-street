class_name BusMesh
extends RefCounted
## A city bus (about 400 triangles), 10.5 m long, facing -Z, wheels on y=0. Colours are
## baked into the vertices, so it needs no textures. Stands in until the car kit's own
## bus (Kit mesh "car_bus") exists.

const LENGTH := 10.5
const BODY := Color(0.93, 0.94, 0.95)
const STRIPE := Color(0.12, 0.42, 0.78)
const GLASS := Color(0.08, 0.1, 0.13)
const TYRE := Color(0.06, 0.06, 0.07)
const SIGN := Color(1.0, 0.72, 0.15)
const LAMP := Color(1.0, 0.95, 0.8)
const TAIL := Color(0.8, 0.08, 0.06)


static func build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hl := LENGTH * 0.5
	_box(st, Vector3(-1.25, 0.38, -hl), Vector3(1.25, 2.95, hl), BODY)
	_box(st, Vector3(-1.2, 2.95, -hl + 0.3), Vector3(1.2, 3.08, hl - 0.3), BODY.darkened(0.08))
	# Side window band and colour stripe, both sides.
	for sx in [-1.0, 1.0]:
		var x0: float = 1.25 * sx
		var x1: float = 1.27 * sx
		_box(st, Vector3(minf(x0, x1), 1.55, -hl + 0.6), Vector3(maxf(x0, x1), 2.55, hl - 0.4), GLASS)
		_box(st, Vector3(minf(x0, x1), 0.85, -hl + 0.1), Vector3(maxf(x0, x1), 1.2, hl - 0.1), STRIPE)
	# Front: windscreen, destination sign, door on the kerb (right) side, lamps.
	_box(st, Vector3(-1.15, 1.0, -hl - 0.02), Vector3(1.15, 2.55, -hl), GLASS)
	_box(st, Vector3(-0.9, 2.62, -hl - 0.03), Vector3(0.9, 2.88, -hl), SIGN)
	_box(st, Vector3(1.25, 0.4, -hl + 0.7), Vector3(1.28, 2.5, -hl + 1.85), GLASS)
	_box(st, Vector3(-1.1, 0.55, -hl - 0.03), Vector3(-0.75, 0.75, -hl), LAMP)
	_box(st, Vector3(0.75, 0.55, -hl - 0.03), Vector3(1.1, 0.75, -hl), LAMP)
	_box(st, Vector3(-1.1, 0.55, hl), Vector3(-0.8, 0.85, hl + 0.03), TAIL)
	_box(st, Vector3(0.8, 0.55, hl), Vector3(1.1, 0.85, hl + 0.03), TAIL)
	_box(st, Vector3(-1.0, 1.6, hl), Vector3(1.0, 2.5, hl + 0.02), GLASS)
	for wz in [-hl + 2.0, hl - 2.4]:
		for sx in [-1.0, 1.0]:
			_wheel(st, Vector3(sx * 1.08, 0.48, wz), 0.48, 0.32)
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.55
	mesh.surface_set_material(0, mat)
	return mesh


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	# Clockwise seen from outside (Godot's front-face winding), as in PersonMesh.
	for p in [a, b, c, a, c, d]:
		st.set_color(col)
		st.add_vertex(p)


static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3, col: Color) -> void:
	var b := [Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z)]
	var t := [Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z)]
	for k in 4:
		var k2 := (k + 1) % 4
		_quad(st, b[k], b[k2], t[k2], t[k], col)
	_quad(st, t[0], t[1], t[2], t[3], col)
	_quad(st, b[3], b[2], b[1], b[0], col)


## An octagonal wheel on the X axis.
static func _wheel(st: SurfaceTool, c: Vector3, r: float, w: float) -> void:
	var seg := 8
	var hx := w * 0.5
	for i in seg:
		var a0 := TAU * i / seg
		var a1 := TAU * (i + 1) / seg
		var p0 := Vector3(0, cos(a0) * r, sin(a0) * r)
		var p1 := Vector3(0, cos(a1) * r, sin(a1) * r)
		_quad(st, c + p0 + Vector3(-hx, 0, 0), c + p1 + Vector3(-hx, 0, 0), c + p1 + Vector3(hx, 0, 0), c + p0 + Vector3(hx, 0, 0), TYRE)
		for sx in [-hx, hx]:
			var cc := c + Vector3(sx, 0, 0)
			var hub := Color(0.55, 0.56, 0.58)
			if sx > 0.0:
				_tri(st, cc, cc + p1, cc + p0, hub)
			else:
				_tri(st, cc, cc + p0, cc + p1, hub)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	for p in [a, b, c]:
		st.set_color(col)
		st.add_vertex(p)
