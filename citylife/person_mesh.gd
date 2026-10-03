class_name PersonMesh
extends RefCounted
## A stylized low-poly person (about 180 triangles), 1.75 m tall, facing -Z, feet at y=0.
## UV.x holds the body part so ped.gdshader can colour and animate it:
## 0/1 left/right leg, 2 torso, 3/4 left/right arm, 5 head, 6 hair.


static func build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Legs (with a shoe that pokes forward).
	_box(st, Vector3(-0.155, 0.0, -0.075), Vector3(-0.025, 0.9, 0.075), 0)
	_box(st, Vector3(0.025, 0.0, -0.075), Vector3(0.155, 0.9, 0.075), 1)
	_box(st, Vector3(-0.15, 0.0, -0.15), Vector3(-0.03, 0.07, 0.0), 0)
	_box(st, Vector3(0.03, 0.0, -0.15), Vector3(0.15, 0.07, 0.0), 1)
	# Torso: tapered from waist to shoulders.
	_taper(st, 0.86, 1.44, 0.17, 0.21, 0.105, 0.115, 2)
	# Arms.
	_box(st, Vector3(-0.29, 0.8, -0.055), Vector3(-0.205, 1.43, 0.055), 3)
	_box(st, Vector3(0.205, 0.8, -0.055), Vector3(0.29, 1.43, 0.055), 4)
	# Neck and head.
	_box(st, Vector3(-0.05, 1.42, -0.05), Vector3(0.05, 1.52, 0.05), 5)
	_sphere(st, Vector3(0, 1.62, 0), Vector3(0.105, 0.125, 0.115), 5, 0.0)
	# Hair: a cap over the top and back of the head.
	_sphere(st, Vector3(0, 1.645, 0.012), Vector3(0.115, 0.118, 0.122), 6, 0.35)
	st.generate_normals()
	return st.commit()


static func _vert(st: SurfaceTool, p: Vector3, part: int) -> void:
	st.set_uv(Vector2(part, 0))
	st.add_vertex(p)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, part: int) -> void:
	# a, b, c, d run clockwise seen from outside (Godot's front-face winding).
	for p in [a, b, c, a, c, d]:
		_vert(st, p, part)


static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3, part: int) -> void:
	_taper(st, lo.y, hi.y, (hi.x - lo.x) * 0.5, (hi.x - lo.x) * 0.5, (hi.z - lo.z) * 0.5, (hi.z - lo.z) * 0.5, part,
		Vector3((lo.x + hi.x) * 0.5, 0, (lo.z + hi.z) * 0.5))


static func _taper(st: SurfaceTool, y0: float, y1: float, w0: float, w1: float, d0: float, d1: float, part: int, c := Vector3.ZERO) -> void:
	var b := [c + Vector3(-w0, y0, -d0), c + Vector3(w0, y0, -d0), c + Vector3(w0, y0, d0), c + Vector3(-w0, y0, d0)]
	var t := [c + Vector3(-w1, y1, -d1), c + Vector3(w1, y1, -d1), c + Vector3(w1, y1, d1), c + Vector3(-w1, y1, d1)]
	for k in 4:
		var k2 := (k + 1) % 4
		_quad(st, b[k], b[k2], t[k2], t[k], part)
	_quad(st, t[0], t[1], t[2], t[3], part)
	_quad(st, b[3], b[2], b[1], b[0], part)


static func _sphere(st: SurfaceTool, c: Vector3, r: Vector3, part: int, cut: float) -> void:
	## Low-poly ellipsoid. `cut` > 0 keeps only the upper/back part (for hair).
	var seg := 8
	var rings := 6
	for j in rings:
		var a0 := PI * float(j) / rings
		var a1 := PI * float(j + 1) / rings
		for i in seg:
			var b0 := TAU * float(i) / seg
			var b1 := TAU * float(i + 1) / seg
			var p00 := _sp(c, r, a0, b0)
			var p01 := _sp(c, r, a0, b1)
			var p10 := _sp(c, r, a1, b0)
			var p11 := _sp(c, r, a1, b1)
			if cut > 0.0:
				var mid := (p00 + p11) * 0.5 - c
				# Keep the crown and the back (+Z), leave the face clear.
				if mid.y < r.y * cut - r.y * 0.9 * clampf(mid.z / r.z + 0.2, 0.0, 1.0):
					continue
			_quad(st, p00, p10, p11, p01, part)


static func _sp(c: Vector3, r: Vector3, a: float, b: float) -> Vector3:
	return c + Vector3(sin(a) * cos(b) * r.x, cos(a) * r.y, sin(a) * sin(b) * r.z)
