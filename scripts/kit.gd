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

var materials := {}
var meshes := {}
var variants := {}  # "r_1_1" -> Array[String]


func _ready() -> void:
	_make_materials()
	_load_dir("buildings")
	_load_dir("roads")
	_load_dir("props")
	_load_dir("cars")


func _make_materials() -> void:
	for name in MATS:
		var d: Array = MATS[name]
		var m := ShaderMaterial.new()
		m.shader = KIT_SHADER
		m.resource_name = name
		var c: Color = d[0]
		m.set_shader_parameter("base_color", Vector3(c.r, c.g, c.b))
		m.set_shader_parameter("tint_src", d[1])
		m.set_shader_parameter("tint_amount", d[2])
		m.set_shader_parameter("pattern", d[3])
		m.set_shader_parameter("kind", d[4])
		m.set_shader_parameter("rough", d[5])
		m.set_shader_parameter("metal", d[6])
		m.set_shader_parameter("spec", d[7])
		m.set_shader_parameter("ground_level", d[8])
		materials[name] = m
	var leaves: ShaderMaterial = materials["Leaves"].duplicate()
	leaves.set_shader_parameter("wind", true)
	materials["LeavesWind"] = leaves
	var car_glass: ShaderMaterial = materials["Glass"].duplicate()
	car_glass.set_shader_parameter("kind", 7)
	materials["CarGlass"] = car_glass


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
	meshes[nm] = mesh
	inst.free()
	return true


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
