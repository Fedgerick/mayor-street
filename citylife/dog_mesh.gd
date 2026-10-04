class_name DogMesh
extends RefCounted
## A small low-poly dog (about 130 triangles), 0.6 m tall, facing -Z, paws at y=0.
## UV.x holds the part for dog.gdshader: 0 body, 1 head, 2..5 legs (front left, front
## right, back left, back right), 6 tail.


static func build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	PersonMesh._box(st, Vector3(-0.12, 0.27, -0.32), Vector3(0.12, 0.5, 0.3), 0)
	PersonMesh._box(st, Vector3(-0.1, 0.4, -0.5), Vector3(0.1, 0.62, -0.28), 1)
	PersonMesh._box(st, Vector3(-0.055, 0.42, -0.62), Vector3(0.055, 0.52, -0.49), 1)
	PersonMesh._box(st, Vector3(-0.1, 0.58, -0.36), Vector3(-0.05, 0.68, -0.3), 1)
	PersonMesh._box(st, Vector3(0.05, 0.58, -0.36), Vector3(0.1, 0.68, -0.3), 1)
	var legs := [Vector2(-0.075, -0.24), Vector2(0.075, -0.24), Vector2(-0.075, 0.22), Vector2(0.075, 0.22)]
	for k in 4:
		var l: Vector2 = legs[k]
		PersonMesh._box(st, Vector3(l.x - 0.035, 0.0, l.y - 0.035), Vector3(l.x + 0.035, 0.32, l.y + 0.035), 2 + k)
	PersonMesh._box(st, Vector3(-0.025, 0.44, 0.28), Vector3(0.025, 0.62, 0.34), 6)
	st.generate_normals()
	return st.commit()
