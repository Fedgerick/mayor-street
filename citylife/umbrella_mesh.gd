class_name UmbrellaMesh
extends RefCounted
## An open umbrella (about 60 triangles) in PersonMesh space: the handle sits in the right
## hand of the ped shader's umbrella pose and the canopy covers the head, so an umbrella
## instance takes the same transform as the person carrying it. UV.x: 0 canopy, 1 pole.

const HAND := Vector3(0.25, 1.24, -0.58)
const CENTER := Vector3(0.18, 2.04, -0.36)
const RADIUS := 0.64
const SEGMENTS := 8


static func build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := CENTER + Vector3(0, 0.2, 0)
	for i in SEGMENTS:
		var a0 := TAU * i / SEGMENTS
		var a1 := TAU * (i + 1) / SEGMENTS
		var p0 := CENTER + Vector3(cos(a0) * RADIUS, -0.04, sin(a0) * RADIUS)
		var p1 := CENTER + Vector3(cos(a1) * RADIUS, -0.04, sin(a1) * RADIUS)
		var mid := CENTER + Vector3(cos((a0 + a1) * 0.5) * RADIUS * 0.97, 0.03, sin((a0 + a1) * 0.5) * RADIUS * 0.97)
		# Two triangles per panel so the rim scallops a little.
		_tri(st, apex, p1, mid, 0)
		_tri(st, apex, mid, p0, 0)
	# The pole, from the hand up to the top: a thin 4-sided stick.
	var up := (apex - HAND).normalized()
	var side := up.cross(Vector3.FORWARD).normalized() * 0.012
	var side2 := up.cross(side).normalized() * 0.012
	var ring := [side, side2, -side, -side2]
	for k in 4:
		var s0: Vector3 = ring[k]
		var s1: Vector3 = ring[(k + 1) % 4]
		_tri(st, HAND + s0, apex + s0, apex + s1, 1)
		_tri(st, HAND + s0, apex + s1, HAND + s1, 1)
	st.generate_normals()
	return st.commit()


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, part: int) -> void:
	for p in [a, b, c]:
		st.set_uv(Vector2(part, 0))
		st.add_vertex(p)
