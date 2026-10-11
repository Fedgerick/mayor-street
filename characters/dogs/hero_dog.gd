class_name HeroDog
extends RefCounted
## The sculpted street dog from characters/assets/dog.glb (characters/tools/build_dog.py),
## as a drop-in for citylife's DogMesh: same size, facing and part layout (UV.x = 0 body,
## 1 head, 2..5 legs front left, front right, back left, back right, 6 tail), so the same
## MultiMesh and per-instance custom data drive it. UV.y carries the material: 0 coat,
## 1 nose, 2 eye, 3 collar, 4 tongue. Draw it with characters/dogs/hero_dog.gdshader.
##   mm.mesh = HeroDog.build()      # LOD0, ~2.3k triangles
##   HeroDog.build(1)               # LOD1, ~500 triangles, for far dogs

const SCENE := "res://characters/assets/dog.glb"
const SHADER := preload("res://characters/dogs/hero_dog.gdshader")
const PARTS := {"body": 0, "head": 1, "leg_fl": 2, "leg_fr": 3, "leg_bl": 4, "leg_br": 5, "tail": 6}
const MATS := {"Coat": 0, "Nose": 1, "Eye": 2, "Collar": 3, "Tongue": 4}

static var _meshes := {}


static func available() -> bool:
	return ResourceLoader.exists(SCENE)


static func build(lod := 0) -> ArrayMesh:
	if _meshes.has(lod):
		return _meshes[lod]
	var root: Node3D = (load(SCENE) as PackedScene).instantiate()
	var list := []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var nm := String(mi.name)
		var cut := nm.rfind("_lod")
		if cut < 0 or nm.substr(cut + 4) != str(lod) or not PARTS.has(nm.substr(0, cut)):
			continue
		var part: int = PARTS[nm.substr(0, cut)]
		var xf := Transform3D.IDENTITY
		var n: Node = mi
		while n != root and n is Node3D:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var mesh: Mesh = mi.mesh
		for s in mesh.get_surface_count():
			var arr := mesh.surface_get_arrays(s)
			var sm := mesh.surface_get_material(s)
			var mat: int = MATS.get(sm.resource_name if sm else "Coat", 0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uv := PackedVector2Array()
			uv.resize(v.size())
			for i in v.size():
				v[i] = xf * v[i]
				nr[i] = (xf.basis * nr[i]).normalized()
				uv[i] = Vector2(part, mat)
			arr[Mesh.ARRAY_VERTEX] = v
			arr[Mesh.ARRAY_NORMAL] = nr
			arr[Mesh.ARRAY_TEX_UV] = uv
			for idx in [Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
				arr[idx] = null
			list.append(arr)
	root.free()
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, CharacterModel._concat(list))
	var m := ShaderMaterial.new()
	m.shader = SHADER
	out.surface_set_material(0, m)
	_meshes[lod] = out
	return out


static func triangle_count(lod := 0) -> int:
	return build(lod).surface_get_array_index_len(0) / 3
