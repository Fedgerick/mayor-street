extends Node
## Loads the Blender-generated kit and swaps every Blender material for a shared
## stylized ShaderMaterial, so the whole city renders with a handful of materials.

const KIT_SHADER := preload("res://shaders/kit.gdshader")
const ROOT := "res://assets/kit/"

# name: [base color, tint_src, tint_amount, pattern, kind, roughness, metallic, specular, ground_level]
const MATS := {
	"Wall": [Color(0.84, 0.81, 0.76), 1, 1.0, 1, 0, 0.9, 0.0, 0.4, false],
	"Accent": [Color(0.74, 0.7, 0.66), 1, 0.8, 3, 0, 0.85, 0.0, 0.4, false],
	"Brick": [Color(0.78, 0.42, 0.32), 1, 0.35, 2, 0, 0.92, 0.0, 0.3, false],
	"Concrete": [Color(0.6, 0.59, 0.57), 0, 0.0, 3, 0, 0.9, 0.0, 0.4, false],
	"Trim": [Color(0.8, 0.79, 0.75), 0, 0.0, 0, 0, 0.7, 0.0, 0.5, false],
	"Roof": [Color(0.42, 0.42, 0.43), 0, 0.0, 11, 0, 0.95, 0.0, 0.3, false],
	"RoofTile": [Color(0.62, 0.36, 0.3), 2, 0.45, 5, 0, 0.8, 0.0, 0.4, false],
	"Glass": [Color(0.1, 0.14, 0.18), 0, 0.0, 0, 1, 0.05, 0.1, 0.8, false],
	"Door": [Color(0.55, 0.4, 0.3), 2, 0.6, 0, 0, 0.6, 0.0, 0.5, false],
	"Metal": [Color(0.55, 0.58, 0.61), 0, 0.0, 4, 0, 0.45, 0.45, 0.5, false],
	"Awning": [Color(0.85, 0.85, 0.85), 2, 1.0, 9, 0, 0.8, 0.0, 0.3, false],
	"Sign": [Color(1.0, 1.0, 1.0), 2, 1.0, 0, 2, 0.4, 0.0, 0.5, false],
	"Grass": [Color(0.35, 0.55, 0.2), 0, 0.0, 7, 0, 0.95, 0.0, 0.2, true],
	"Paving": [Color(0.6, 0.58, 0.55), 0, 0.0, 6, 0, 0.85, 0.0, 0.4, true],
	"Asphalt": [Color(0.19, 0.19, 0.2), 0, 0.0, 8, 0, 0.88, 0.0, 0.35, true],
	"Sidewalk": [Color(0.58, 0.57, 0.55), 0, 0.0, 10, 0, 0.85, 0.0, 0.4, true],
	"Curb": [Color(0.66, 0.66, 0.64), 0, 0.0, 0, 0, 0.8, 0.0, 0.4, true],
	"Marking": [Color(0.85, 0.85, 0.82), 0, 0.0, 0, 0, 0.6, 0.0, 0.5, true],
	"MarkingYellow": [Color(0.95, 0.75, 0.2), 0, 0.0, 0, 0, 0.6, 0.0, 0.5, true],
	"Bark": [Color(0.4, 0.29, 0.2), 0, 0.0, 0, 0, 0.95, 0.0, 0.2, false],
	"Leaves": [Color(1.0, 1.0, 1.0), 1, 1.0, 0, 4, 0.9, 0.0, 0.25, false],
	"Lamp": [Color(1.0, 0.95, 0.85), 0, 0.0, 0, 3, 0.4, 0.0, 0.5, false],
	"CarBody": [Color(1.0, 1.0, 1.0), 1, 1.0, 0, 0, 0.3, 0.25, 0.7, false],
	"Tire": [Color(0.07, 0.07, 0.08), 0, 0.0, 0, 0, 0.9, 0.0, 0.2, false],
	"Headlight": [Color(1.0, 1.0, 0.95), 0, 0.0, 0, 5, 0.2, 0.0, 0.8, false],
	"Water": [Color(0.2, 0.55, 0.7), 0, 0.0, 0, 7, 0.05, 0.0, 0.8, false],
	"Taillight": [Color(0.7, 0.05, 0.05), 0, 0.0, 0, 6, 0.3, 0.0, 0.6, false],
}

# Wall tints per zone (instance COLOR) and accent tints (instance CUSTOM).
const WALLS := [
	[Color(1, 1, 1)],
	[Color(0.98, 0.93, 0.82), Color(0.86, 0.93, 0.98), Color(0.93, 0.85, 0.72), Color(0.82, 0.9, 0.8),
	 Color(0.98, 0.82, 0.74), Color(1.0, 0.98, 0.95), Color(0.85, 0.85, 0.88), Color(0.96, 0.9, 0.6)],
	[Color(0.95, 0.95, 0.95), Color(0.85, 0.87, 0.9), Color(0.93, 0.88, 0.78), Color(0.8, 0.62, 0.5),
	 Color(0.7, 0.78, 0.88), Color(0.98, 0.96, 0.9), Color(0.75, 0.75, 0.75), Color(0.9, 0.8, 0.7)],
	[Color(0.75, 0.75, 0.73), Color(0.62, 0.66, 0.7), Color(0.7, 0.55, 0.45), Color(0.62, 0.68, 0.58),
	 Color(0.8, 0.78, 0.7), Color(0.55, 0.6, 0.68), Color(0.68, 0.68, 0.66), Color(0.75, 0.65, 0.5)],
]
const ACCENTS := [
	Color(0.85, 0.22, 0.2), Color(0.1, 0.6, 0.62), Color(0.18, 0.3, 0.6), Color(0.95, 0.55, 0.12),
	Color(0.25, 0.6, 0.3), Color(0.55, 0.3, 0.65), Color(0.95, 0.8, 0.2), Color(0.55, 0.35, 0.22),
]
const LEAF_TINTS := [
	Color(0.36, 0.6, 0.22), Color(0.3, 0.52, 0.2), Color(0.45, 0.62, 0.22), Color(0.26, 0.46, 0.22),
	Color(0.55, 0.62, 0.2), Color(0.32, 0.56, 0.3),
]
const CAR_TINTS := [
	Color(0.85, 0.12, 0.1), Color(0.95, 0.95, 0.95), Color(0.12, 0.12, 0.14), Color(0.15, 0.3, 0.7),
	Color(0.7, 0.72, 0.75), Color(0.95, 0.75, 0.1), Color(0.1, 0.45, 0.3), Color(0.55, 0.1, 0.15),
]

## Meshes with several surfaces are merged into one that carries each vertex's material
## number in CUSTOM0, so a building costs one draw call a pass instead of one per material
## (PERFORMANCE.md). The look of every material is in these tables, read by kit.gdshader.
## Set to false to get the per-material surfaces back (for comparing).
var merge_surfaces := true
var merged_material: ShaderMaterial
var material_ids := {}  # material name -> number in the tables
var materials := {}
var meshes := {}
var variants := {}  # "r_1_1" -> Array[String]


func _ready() -> void:
	_make_materials()
	_load_dir("buildings")
	_load_dir("roads")
	_load_dir("props")
	_load_dir("cars")
	VehicleKit.install(self)  # the round-3 cars (vehicles/) replace the old car meshes


func _make_materials() -> void:
	for name in MATS:
		var d: Array = MATS[name]
		var m := ShaderMaterial.new()
		m.shader = KIT_SHADER
		m.resource_name = name
		var c: Color = d[0]
		m.set_shader_parameter("u_base_color", Vector3(c.r, c.g, c.b))
		m.set_shader_parameter("u_tint_src", d[1])
		m.set_shader_parameter("u_tint_amount", d[2])
		m.set_shader_parameter("u_pattern", d[3])
		m.set_shader_parameter("u_kind", d[4])
		m.set_shader_parameter("u_rough", d[5])
		m.set_shader_parameter("u_metal", d[6])
		m.set_shader_parameter("u_spec", d[7])
		m.set_shader_parameter("u_ground_level", d[8])
		materials[name] = m
	var leaves: ShaderMaterial = materials["Leaves"].duplicate()
	leaves.set_shader_parameter("u_wind", true)
	materials["LeavesWind"] = leaves
	var car_glass: ShaderMaterial = materials["Glass"].duplicate()
	car_glass.set_shader_parameter("u_kind", 7)
	materials["CarGlass"] = car_glass
	_make_merged_material()


func _make_merged_material() -> void:
	## One material that reads the look of all the others from tables, by number.
	var ids := {}
	var a := PackedVector4Array()  # base colour, tint amount
	var b := PackedVector4Array()  # roughness, metallic, specular, tint source
	var c := PackedVector4Array()  # pattern, kind, wind, ground level
	var rows := {}  # name -> [MATS row, kind override, wind]
	for name in MATS:
		rows[name] = [MATS[name], -1, false]
	rows["LeavesWind"] = [MATS["Leaves"], -1, true]
	rows["CarGlass"] = [MATS["Glass"], 7, false]
	for name in rows:
		var d: Array = rows[name][0]
		var col: Color = d[0]  # (set raw on the u_ uniform too: a Vector3 gets no sRGB conversion)
		ids[name] = a.size()
		a.append(Vector4(col.r, col.g, col.b, d[2]))
		b.append(Vector4(d[5], d[6], d[7], float(d[1])))
		c.append(Vector4(float(d[3]), float(d[4] if rows[name][1] < 0 else rows[name][1]),
			1.0 if rows[name][2] else 0.0, 1.0 if d[8] else 0.0))
	assert(a.size() <= 32, "kit.gdshader's tables hold 32 materials")
	a.resize(32)
	b.resize(32)
	c.resize(32)
	material_ids = ids
	merged_material = ShaderMaterial.new()
	merged_material.shader = KIT_SHADER
	merged_material.resource_name = "Merged"
	merged_material.set_shader_parameter("merged", true)
	merged_material.set_shader_parameter("mat_a", a)
	merged_material.set_shader_parameter("mat_b", b)
	merged_material.set_shader_parameter("mat_c", c)


const NAMES := {
	"buildings": ["r_1_1", "r_2_1", "r_3_1", "r_3_2", "c_1_1", "c_2_1", "c_3_1", "c_3_2", "i_1_1", "i_2_1", "i_3_1", "i_3_2"],
	"roads": ["road_straight", "road_corner", "road_t", "road_cross", "road_end", "road_single"],
	"props": ["street_lamp", "traffic_light", "tree_round_a", "tree_round_b", "tree_pine", "palm", "bush"],
	"cars": ["car_sedan", "car_hatch", "car_van", "car_truck"],
}


func _load_dir(sub: String) -> void:
	for base in NAMES[sub]:
		if sub == "buildings":
			var list: Array[String] = []
			for v in ["a", "b", "c", "d", "e", "f"]:
				var nm: String = base + "_" + v
				if _load_mesh(sub, nm):
					list.append(nm)
			variants[base] = list
		else:
			_load_mesh(sub, base)


func _load_mesh(sub: String, nm: String) -> bool:
	return _load_mesh_at(ROOT + sub + "/" + nm + ".glb", nm, sub)


func _load_mesh_at(path: String, nm: String, sub: String) -> bool:
	if not ResourceLoader.exists(path):
		return false
	var scene: PackedScene = load(path)
	var inst := scene.instantiate()
	var mi := _find_mesh(inst)
	if mi == null:
		inst.free()
		return false
	var mesh: Mesh = mi.mesh
	var keys := PackedStringArray()
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		var key := mat.resource_name if mat else "Wall"
		if sub == "props" and key == "Leaves":
			key = "LeavesWind"
		if sub == "cars" and key == "Glass":
			key = "CarGlass"
		if materials.has(key):
			mesh.surface_set_material(s, materials[key])
		else:
			push_warning("Kit: unknown material %s in %s" % [key, nm])
			key = "Wall"
		keys.append(key)
	if merge_surfaces and sub != "cars" and mesh.get_surface_count() > 1 and mesh is ArrayMesh:
		mesh = _merge(mesh as ArrayMesh, keys)
	meshes[nm] = mesh
	inst.free()
	return true


func _merge(src: ArrayMesh, keys: PackedStringArray) -> ArrayMesh:
	## Every surface of src in one, with the material number of each vertex in CUSTOM0.
	var ids := PackedFloat32Array()
	var indices := PackedInt32Array()
	var base := 0
	var wanted := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]
	var present := {}
	var parts: Array = []
	for s in src.get_surface_count():
		var arr := src.surface_get_arrays(s)
		parts.append(arr)
		for k in wanted:
			if arr[k] != null and arr[k].size() > 0:
				present[k] = true
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for s in parts.size():
		var arr: Array = parts[s]
		var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n := pv.size()
		verts.append_array(pv)
		var pn = arr[Mesh.ARRAY_NORMAL]
		if present.has(Mesh.ARRAY_NORMAL):
			if pn != null and pn.size() == n:
				normals.append_array(pn)
			else:
				var up := PackedVector3Array()
				up.resize(n)
				up.fill(Vector3.UP)
				normals.append_array(up)
		var pc = arr[Mesh.ARRAY_COLOR]
		if present.has(Mesh.ARRAY_COLOR):
			if pc != null and pc.size() == n:
				colors.append_array(pc)
			else:
				var white := PackedColorArray()
				white.resize(n)
				white.fill(Color.WHITE)
				colors.append_array(white)
		var p1 = arr[Mesh.ARRAY_TEX_UV]
		if present.has(Mesh.ARRAY_TEX_UV):
			if p1 != null and p1.size() == n:
				uv.append_array(p1)
			else:
				var z := PackedVector2Array()
				z.resize(n)
				uv.append_array(z)
		var p2 = arr[Mesh.ARRAY_TEX_UV2]
		if present.has(Mesh.ARRAY_TEX_UV2):
			if p2 != null and p2.size() == n:
				uv2.append_array(p2)
			else:
				var z2 := PackedVector2Array()
				z2.resize(n)
				uv2.append_array(z2)
		var id := float(material_ids.get(keys[s], 0))
		var ida := PackedFloat32Array()
		ida.resize(n)
		ida.fill(id)
		ids.append_array(ida)
		var pi = arr[Mesh.ARRAY_INDEX]
		if pi != null and pi.size() > 0:
			for i in pi:
				indices.append(i + base)
		else:
			for i in n:
				indices.append(i + base)
		base += n
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	if present.has(Mesh.ARRAY_NORMAL):
		out[Mesh.ARRAY_NORMAL] = normals
	if present.has(Mesh.ARRAY_COLOR):
		out[Mesh.ARRAY_COLOR] = colors
	if present.has(Mesh.ARRAY_TEX_UV):
		out[Mesh.ARRAY_TEX_UV] = uv
	if present.has(Mesh.ARRAY_TEX_UV2):
		out[Mesh.ARRAY_TEX_UV2] = uv2
	out[Mesh.ARRAY_CUSTOM0] = ids
	out[Mesh.ARRAY_INDEX] = indices
	# The glTF import made LODs for each surface; the merged surface needs its own, which
	# ImporterMesh builds the same way the import does.
	var flags: int = Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, out, [], {}, merged_material, "", flags)
	im.generate_lods(25.0, 60.0, [])
	var mesh := im.get_mesh()
	mesh.resource_name = src.resource_name
	return mesh


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null


func building_mesh_name(zone: int, stage: int, size: int, variant: int) -> String:
	var key := "%s_%d_%d" % [City.ZONE_KEYS[zone], stage, size]
	var list: Array = variants.get(key, [])
	if list.is_empty():
		return ""
	return list[variant % list.size()]


func mesh(nm: String) -> Mesh:
	return meshes.get(nm)


var _special_tried := {}


## The mesh name for a catalog building, loading its model on first use. Until a model
## exists it borrows a kit building of the same size, or gets a plain block.
func special_mesh_name(kind: String, size: int, variant: int) -> String:
	var nm := "special/" + kind
	if meshes.has(nm):
		return nm
	var d := Catalog.get_def(kind)
	if d.is_empty():
		return ""
	if not _special_tried.has(kind):
		_special_tried[kind] = true
		if d.model != "" and _load_mesh_at(d.model, nm, "specials"):
			return nm
	var list: Array = variants.get("%s_%d" % [d.stand_in, size], [])
	if list.is_empty() and size <= 2:
		list = variants.get("c_3_2" if size == 2 else "c_2_1", [])
	if not list.is_empty():
		return list[variant % list.size()]
	return _block(nm, d)


func _block(nm: String, d: Dictionary) -> String:
	var w: float = maxf(d.size, 1) * City.TILE - 2.0
	var h: float = d.height
	var box := BoxMesh.new()
	box.size = Vector3(w, h, w)
	var st := SurfaceTool.new()
	st.append_from(box, 0, Transform3D(Basis(), Vector3(0, h * 0.5, 0)))
	var m := st.commit()
	m.surface_set_material(0, materials["Concrete"])
	meshes[nm] = m
	return nm
