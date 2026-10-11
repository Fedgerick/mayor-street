class_name HeroLook
extends Node
## The detailed look for people: the person the camera follows (the player on foot and the
## character creator's preview) at full detail, and everyone else close up (crowd heroes,
## police, mission crews) at `mid` detail. Add it as a child of a CharacterModel (player/),
## or call HeroLook.install(get_tree()) once and it finds every model by itself.
##
## While the model draws its close-up mesh (LOD0), HeroLook swaps in the same outfit built
## from characters/assets/hero.glb (characters/tools/build_hero.py): a sculpted face, eyes
## with irises, clothes trims, and materials from characters/shaders/ (wrap-lit skin, knit,
## denim, fleece, hair strands, stitching). It re-applies itself after every re-dress
## (`dressed`) and LOD swap, and steps aside at LOD1, so the crowd mesh and animations are
## CharacterModel's as before.
## Cost, full: ~25k triangles and up to ~15 draw calls instead of ~9k and ~8.
## Cost, mid: ~10k triangles (the street parts' budget, a little more for the face) and up
## to ~14 draw calls. Either way the shadow is one draw call per shadow pass.

const SCENE := "res://characters/assets/hero.glb"
const SKIN_SHADER := preload("res://characters/shaders/hero_skin.gdshader")
const CLOTH_SHADER := preload("res://characters/shaders/hero_cloth.gdshader")
# Draw order of the merged surfaces.
const SLOTS := ["Skin", "Stubble", "Shirt", "Trim", "Jacket", "Pants", "Shoes", "Sole", "Laces",
	"Hair", "Brows", "Lashes", "EyeWhite", "Iris", "Mouth", "Hat", "Frame", "Lens", "Eyes"]
const IRIS := [Color(0.32, 0.19, 0.09), Color(0.22, 0.13, 0.06), Color(0.42, 0.3, 0.14),
	Color(0.24, 0.42, 0.62), Color(0.3, 0.42, 0.25), Color(0.4, 0.42, 0.45)]
const IRIS_WEIGHT := [5.0, 3.0, 2.0, 2.0, 1.0, 0.5]

## Iris colour; leave transparent to pick one from the model's seed.
@export var iris := Color(0, 0, 0, 0)
## Painted fabric and skin detail (0 = flat colours, for the Low graphics level).
@export var detail := 1.0:
	set(v):
		if v != detail:
			detail = v
			if cm and is_inside_tree():
				_apply()   # materials carry the detail, so remake them
## Crowd detail: the hero parts decimated to the street parts' triangle budget.
@export var mid := false
## Crowd models cast their shadow from their own mid shape too (~9k triangles per shadow
## pass instead of 1.5k); off by default.
static var shadow_mid := false

var cm: CharacterModel
var _mesh: ArrayMesh
var _shadow: ArrayMesh
var _key := ""

static var _parts := {}       # part name -> [[material name, arrays], ...]
static var _skin: Skin
static var _ok := false
static var _tried := false
static var _built := {}       # parts key -> [ArrayMesh, shadow ArrayMesh]
static var _rest := {}        # "part#surface" -> its arrays with the rest pose baked in
const BUILT_MAX := 48         # outfits kept merged; crowd outfits come and go
static var _mats := {}        # material key -> ShaderMaterial


static func available() -> bool:
	return ResourceLoader.exists(SCENE)


## Upgrade every CharacterModel that appears in `tree`: the player's and the creator
## preview's at full detail, everyone else's at mid detail.
static func install(tree: SceneTree) -> void:
	if not available() or tree.node_added.is_connected(_on_node_added):
		return
	tree.node_added.connect(_on_node_added)


static func _on_node_added(n: Node) -> void:
	if n is CharacterModel:
		_maybe_attach.call_deferred(n)


static func _maybe_attach(n: Node) -> void:
	if not is_instance_valid(n) or not n.is_inside_tree() or n.has_node("HeroLook"):
		return
	var follow := n.get_parent() is StreetPlayer
	var p := n.get_parent()
	while p and not follow:
		follow = p is CharacterCreator
		p = p.get_parent()
	attach(n as CharacterModel, not follow)


static func attach(model: CharacterModel, crowd := false) -> HeroLook:
	var h := HeroLook.new()
	h.name = "HeroLook"
	h.mid = crowd
	model.add_child(h)
	return h


func _ready() -> void:
	cm = get_parent() as CharacterModel
	if cm == null or not _load():
		set_process(false)
		return
	cm.dressed.connect(_apply)
	_apply()


func _exit_tree() -> void:
	_restore()


func _process(_dt: float) -> void:
	if cm.body == null:
		return
	if cm.current_lod() == 0:
		if cm.body.mesh != _mesh:
			_apply()
	elif cm.body.skin == _skin or cm.shadow_body.skin == _skin:
		_restore()


func _restore() -> void:
	if cm == null or cm.body == null:
		return
	var off := cm.current_lod() != 0 or not is_inside_tree()
	if (off or cm.body.mesh != _mesh) and cm.body.skin == _skin:
		cm.body.skin = CharacterModel._skin
	if (off or cm.shadow_body.mesh != _shadow) and cm.shadow_body.skin == _skin:
		cm.shadow_body.skin = CharacterModel._skin


static func _load() -> bool:
	if _tried:
		return _ok
	_tried = true
	if not available():
		return false
	var root: Node = (load(SCENE) as PackedScene).instantiate()
	var skel: Skeleton3D = root.find_children("*", "Skeleton3D", true, false)[0]
	for mi in skel.find_children("*", "MeshInstance3D", false, false):
		var m := mi as MeshInstance3D
		if _skin == null:
			_skin = m.skin
		var list := []
		for s in m.mesh.get_surface_count():
			var sm := m.mesh.surface_get_material(s)
			list.append([sm.resource_name if sm else "Skin", m.mesh.surface_get_arrays(s)])
		_parts[String(m.name)] = list
	# The hero rig must be the street rig, bone for bone, or the skin would bind wrong.
	var street: Node = (load(CharacterModel.SCENE) as PackedScene).instantiate()
	var sk2: Skeleton3D = street.find_children("*", "Skeleton3D", true, false)[0]
	_ok = skel.get_bone_count() == sk2.get_bone_count() and _skin != null
	for i in skel.get_bone_count():
		if _ok and skel.get_bone_name(i) != sk2.get_bone_name(i):
			_ok = false
	if not _ok:
		push_warning("HeroLook: hero.glb's rig doesn't match the street rig; keeping the street look")
	else:
		# Bake every part's rest pose now, while the city loads, so a crowd person getting a
		# new outfit only merges arrays (as CharacterModel already does) and never stalls.
		for pn in _parts:
			var list: Array = _parts[pn]
			for i in list.size():
				_rest[pn + "#" + str(i)] = _with_rest(list[i][1])
	root.free()
	street.free()
	return _ok


func _apply() -> void:
	if cm == null or cm.body == null or cm.current_lod() != 0:
		return
	var names := cm.part_names()
	var key := ",".join(names) + ("@mid" if mid else "@full")
	if not _built.has(key):
		if _built.size() >= BUILT_MAX:
			_built.erase(_built.keys()[0])   # oldest first; models wearing it keep their copy
		_built[key] = _build(names, mid)
	_mesh = _built[key][0]
	_shadow = _built[key][1]
	_key = key
	cm.body.mesh = _mesh
	cm.body.skin = _skin
	# The player's shadow comes from the hero shape itself, merged into one surface so it
	# costs one draw per shadow pass: the crowd mesh's shadow doesn't hug the hero mesh and
	# darkened it in patches (hair, cheeks) wherever the two shapes part. Crowd people
	# keep the 1.5k-triangle crowd mesh's shadow: a dozen of them, further away.
	cm.body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not mid or shadow_mid:
		cm.shadow_body.mesh = _shadow
		cm.shadow_body.skin = _skin
	cm.shadow_body.visible = true
	for s in _mesh.get_surface_count():
		cm.body.set_surface_override_material(s, _material(_mesh.surface_get_name(s)))


## Merge the outfit's hero parts into one surface per material, with the rest pose
## baked in for the shaders (position in UV and UV2.x, normal in COLOR), plus the whole
## outfit as one plain surface for the shadow.
static func _build(names: PackedStringArray, crowd: bool) -> Array:
	var by_slot := {}
	for pn in names:
		var part := pn + "_mid" if crowd and _parts.has(pn + "_mid") else pn
		var list: Array = _parts.get(part, [])
		for i in list.size():
			var slot: String = list[i][0]
			if crowd and slot == "Lashes":
				slot = "Brows"   # one draw call fewer; at crowd distance they read the same
			if not by_slot.has(slot):
				by_slot[slot] = []
			var rk := part + "#" + str(i)
			if not _rest.has(rk):
				_rest[rk] = _with_rest(list[i][1])
			by_slot[slot].append(_rest[rk])
	var out := ArrayMesh.new()
	var all := []
	# The shadow always comes from the mid parts: the same shape in fewer triangles.
	for pn in names:
		var sp := pn + "_mid" if _parts.has(pn + "_mid") else pn
		var sl: Array = _parts.get(sp, [])
		for i in sl.size():
			if not sl[i][0] in ["Lens", "Iris", "EyeWhite", "Mouth", "Lashes"]:   # too small to show
				var bare: Array = (sl[i][1] as Array).duplicate()
				for idx in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR]:
					bare[idx] = null
				all.append(bare)
	for slot in SLOTS:
		if by_slot.has(slot):
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, CharacterModel._concat(by_slot[slot]))
			out.surface_set_name(out.get_surface_count() - 1, slot)
	var shadow := ArrayMesh.new()
	shadow.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, CharacterModel._concat(all))
	return [out, shadow]


static func _with_rest(src: Array) -> Array:
	var arr := src.duplicate()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	uv.resize(v.size())
	uv2.resize(v.size())
	col.resize(v.size())
	for i in v.size():
		var p := v[i]
		var n := nr[i]
		uv[i] = Vector2(p.x, p.y)
		uv2[i] = Vector2(p.z, 0.0)
		col[i] = Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, 1.0)
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_TANGENT] = null
	return arr


func _material(slot: String) -> ShaderMaterial:
	var c: Dictionary = cm.colors
	var o: Dictionary = cm.outfit
	var albedo: Color = c.get(slot, Color(0.5, 0.5, 0.5))
	var accent := Color(0, 0, 0)
	var rough: float = CharacterModel.ROUGH.get(slot, 0.7)
	var kind := 1
	match slot:
		"Skin":
			kind = 0
		"Stubble":
			kind = 18
			albedo = c.get("Stubble", albedo)
		"Shirt":
			kind = 2 if o.get("top") == "hoodie" else 1
		"Trim":
			kind = 16
			albedo = (c.get("Shirt", albedo) as Color).darkened(0.12)
		"Jacket":
			kind = 3
		"Pants":
			kind = 5 if o.get("bottom") == "skirt" else 4
		"Shoes":
			kind = 6
		"Sole":
			kind = 14
			var sh: Color = c.get("Shoes", Color.WHITE)
			albedo = Color(0.2, 0.14, 0.1) if o.get("shoes") == "boots" else (
				Color(0.93, 0.91, 0.87) if sh.get_luminance() < 0.8 else Color(0.85, 0.84, 0.82))
		"Laces":
			kind = 15
			var sh2: Color = c.get("Shoes", Color.WHITE)
			albedo = Color(0.94, 0.94, 0.92) if sh2.get_luminance() < 0.6 else sh2.darkened(0.08)
			if o.get("top") == "hoodie":
				albedo = Color(0.94, 0.94, 0.92)
		"Hair":
			kind = 7
		"Brows", "Lashes":
			kind = 8
			albedo = c.get("Brows", albedo)
			if slot == "Lashes":
				albedo = albedo.darkened(0.55)
		"EyeWhite":
			kind = 10
		"Iris":
			kind = 9
			accent = _iris()
		"Mouth":
			kind = 11
			albedo = (c.get("Skin", albedo) as Color) * Color(0.42, 0.22, 0.22)
		"Hat":
			kind = 17 if o.get("hat") == "beanie" else 19
		"Frame", "Eyes":
			kind = 12
			albedo = Color(0.05, 0.05, 0.06)
		"Lens":
			kind = 13
			albedo = Color(0.02, 0.025, 0.03)
	var key := "%s|%d|%s|%s|%.2f|%.2f" % [slot, kind, albedo.to_html(), accent.to_html(), rough, detail]
	var mat: ShaderMaterial = _mats.get(key)
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = SKIN_SHADER if kind in [0, 18] else CLOTH_SHADER
		mat.set_shader_parameter("albedo", albedo)
		mat.set_shader_parameter("accent", accent)
		mat.set_shader_parameter("rough", rough)
		mat.set_shader_parameter("kind", kind)
		mat.set_shader_parameter("detail", detail)
		_mats[key] = mat
	return mat


func _iris() -> Color:
	if iris.a > 0.0:
		return iris
	if cm.colors.has("Iris"):
		return cm.colors.Iris
	var rng := RandomNumberGenerator.new()
	rng.seed = cm.seed_value * 7919 + 13
	var total := 0.0
	for w in IRIS_WEIGHT:
		total += w
	var r := rng.randf() * total
	for i in IRIS.size():
		r -= IRIS_WEIGHT[i]
		if r <= 0.0:
			return IRIS[i]
	return IRIS[0]


## Triangles HeroLook draws now (0 while the model is on its crowd mesh).
func triangle_count() -> int:
	if cm == null or cm.body.mesh != _mesh or _mesh == null:
		return 0
	var n := 0
	for s in _mesh.get_surface_count():
		n += _mesh.surface_get_array_index_len(s) / 3
	return n
