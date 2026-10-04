class_name CharacterLook
extends RefCounted
## What the Resident looks like: body, skin, hair, face and outfit colors.
## `apply(model)` dresses a CharacterModel (player/) after its _ready, without changing
## player/: it swaps surface materials by name, scales the body, and hangs hair, brows,
## beards and glasses on the Head bone. Plain data, so it saves as a Dictionary.

const BODIES := {
	"slim": {"label": "Slim", "scale": Vector3(0.9, 1.0, 0.92)},
	"average": {"label": "Average", "scale": Vector3(1.0, 1.0, 1.0)},
	"athletic": {"label": "Athletic", "scale": Vector3(1.1, 1.0, 1.02)},
	"heavy": {"label": "Heavy", "scale": Vector3(1.2, 0.98, 1.2)},
}
const BODY_ORDER := ["slim", "average", "athletic", "heavy"]

# keep_cap: whether the model's own hair cap stays under the extra pieces.
const HAIR_STYLES := {
	"short": {"label": "Short", "keep_cap": true},
	"buzz": {"label": "Buzz cut", "keep_cap": false},
	"bald": {"label": "Bald", "keep_cap": false},
	"long": {"label": "Long", "keep_cap": true},
	"ponytail": {"label": "Ponytail", "keep_cap": true},
	"bun": {"label": "Bun", "keep_cap": true},
	"mohawk": {"label": "Mohawk", "keep_cap": false},
	"afro": {"label": "Afro", "keep_cap": false},
}
const HAIR_ORDER := ["short", "buzz", "bald", "long", "ponytail", "bun", "mohawk", "afro"]

const FACES := {
	"clean": "Clean",
	"stubble": "Stubble",
	"mustache": "Mustache",
	"beard": "Beard",
	"glasses": "Glasses",
	"shades": "Shades",
}
const FACE_ORDER := ["clean", "stubble", "mustache", "beard", "glasses", "shades"]

const SKIN := [
	Color(0.99, 0.87, 0.76), Color(0.98, 0.8, 0.66), Color(0.93, 0.72, 0.56), Color(0.89, 0.66, 0.5),
	Color(0.78, 0.55, 0.39), Color(0.7, 0.48, 0.34), Color(0.56, 0.37, 0.25), Color(0.42, 0.27, 0.18),
]
const HAIR_COLORS := [
	Color(0.08, 0.06, 0.05), Color(0.2, 0.13, 0.08), Color(0.36, 0.21, 0.1), Color(0.6, 0.38, 0.18),
	Color(0.85, 0.66, 0.36), Color(0.58, 0.16, 0.08), Color(0.62, 0.62, 0.64), Color(0.92, 0.92, 0.9),
	Color(0.2, 0.35, 0.8), Color(0.85, 0.3, 0.55),
]
# Outfit colors. The first CLOTH_FREE are always available; the rest are sold in clothing
# shops (an unlock) and need "cloth:<index>" in the profile's owned list.
const CLOTH := [
	Color(0.95, 0.95, 0.93), Color(0.13, 0.14, 0.17), Color(0.45, 0.47, 0.5), Color(0.17, 0.22, 0.38),
	Color(0.2, 0.47, 0.86), Color(0.9, 0.28, 0.22), Color(0.24, 0.68, 0.45), Color(0.98, 0.78, 0.2),
	Color(0.47, 0.39, 0.28), Color(0.58, 0.52, 0.43), Color(0.62, 0.26, 0.15), Color(0.32, 0.38, 0.22),
	# shop colors
	Color(0.55, 0.3, 0.72), Color(0.98, 0.55, 0.2), Color(0.95, 0.45, 0.65), Color(0.15, 0.7, 0.75),
	Color(0.55, 0.06, 0.1), Color(0.85, 0.72, 0.3), Color(0.05, 0.25, 0.2), Color(0.75, 0.9, 0.2),
]
const CLOTH_FREE := 12

var body := "average"
var height := 1.0        # 0.92 .. 1.08
var skin := 1
var hair := "short"
var hair_color := 1
var face := "clean"
var top := 4
var bottom := 3
var shoes := 0


func to_dict() -> Dictionary:
	return {"body": body, "height": height, "skin": skin, "hair": hair, "hair_color": hair_color,
		"face": face, "top": top, "bottom": bottom, "shoes": shoes}


static func from_dict(d: Dictionary) -> CharacterLook:
	var l := CharacterLook.new()
	l.body = d.get("body", l.body) if BODIES.has(d.get("body")) else l.body
	l.height = clampf(float(d.get("height", 1.0)), 0.92, 1.08)
	l.skin = clampi(int(d.get("skin", l.skin)), 0, SKIN.size() - 1)
	l.hair = d.get("hair", l.hair) if HAIR_STYLES.has(d.get("hair")) else l.hair
	l.hair_color = clampi(int(d.get("hair_color", l.hair_color)), 0, HAIR_COLORS.size() - 1)
	l.face = d.get("face", l.face) if FACES.has(d.get("face")) else l.face
	l.top = clampi(int(d.get("top", l.top)), 0, CLOTH.size() - 1)
	l.bottom = clampi(int(d.get("bottom", l.bottom)), 0, CLOTH.size() - 1)
	l.shoes = clampi(int(d.get("shoes", l.shoes)), 0, CLOTH.size() - 1)
	return l


func duplicate_look() -> CharacterLook:
	return from_dict(to_dict())


static func random(rng: RandomNumberGenerator) -> CharacterLook:
	var l := CharacterLook.new()
	l.body = BODY_ORDER[rng.randi() % BODY_ORDER.size()]
	l.height = snappedf(rng.randf_range(0.94, 1.06), 0.01)
	l.skin = rng.randi() % SKIN.size()
	l.hair = HAIR_ORDER[rng.randi() % HAIR_ORDER.size()]
	l.hair_color = rng.randi() % 8   # natural colors mostly
	l.face = FACE_ORDER[rng.randi() % FACE_ORDER.size()]
	l.top = rng.randi() % CLOTH_FREE
	l.bottom = rng.randi() % CLOTH_FREE
	l.shoes = rng.randi() % CLOTH_FREE
	return l


static func cloth_owned(i: int, owned: PackedStringArray) -> bool:
	return i < CLOTH_FREE or owned.has("cloth:%d" % i)


# ------------------------------------------------------------------ dressing ---

const EXTRA := "CreatorLook"   # name of the node holding the hair/face pieces

static var _no_cap_meshes := {}   # source Mesh -> copy without the Hair surface


## Dress a CharacterModel that is already in the tree (its _ready has run).
func apply(cm: Node3D) -> void:
	var model: Node3D = cm.get("model")
	if model == null:
		return
	var bs: Vector3 = BODIES[body].scale
	model.scale = Vector3(bs.x, bs.y * height, bs.z)
	var colors := {
		"Skin": SKIN[skin], "Hair": HAIR_COLORS[hair_color],
		"Shirt": CLOTH[top], "Pants": CLOTH[bottom], "Shoes": CLOTH[shoes],
	}
	var hair_mat := _mat(colors.Hair, 0.85)
	for old in model.find_children(EXTRA, "", true, false):
		old.get_parent().remove_child(old)
		old.queue_free()
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if not m.has_meta("creator_src_mesh"):
			m.set_meta("creator_src_mesh", m.mesh)
		var src: Mesh = m.get_meta("creator_src_mesh")
		m.mesh = src if HAIR_STYLES[hair].keep_cap else _without_hair(src)
		for s in m.mesh.get_surface_count():
			var sm := m.mesh.surface_get_material(s)
			var nm := sm.resource_name if sm else ""
			if nm == "Hair":
				m.set_surface_override_material(s, hair_mat)
				continue
			var mat := _mat(colors.get(nm, Color(0.03, 0.03, 0.04)),
				{"Skin": 0.55, "Shoes": 0.45, "Shirt": 0.75, "Pants": 0.85}.get(nm, 0.2))
			mat.rim_enabled = nm != "" and nm != "Eyes"
			m.set_surface_override_material(s, mat)
	_build_extras(model, hair_mat)


static func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.roughness = rough
	mat.rim_enabled = true
	mat.rim = 0.3
	mat.rim_tint = 0.5
	return mat


static func _without_hair(src: Mesh) -> Mesh:
	if _no_cap_meshes.has(src):
		return _no_cap_meshes[src]
	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var sm := src.surface_get_material(s)
		if sm and sm.resource_name == "Hair":
			continue
		var am := src as ArrayMesh
		var fmt := am.surface_get_format(s) if am else 0
		var flags := fmt & (Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS | Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)
		out.add_surface_from_arrays(src.surface_get_primitive_type(s), src.surface_get_arrays(s),
			[], {}, flags)
		out.surface_set_material(out.get_surface_count() - 1, sm)
	_no_cap_meshes[src] = out
	return out


func _build_extras(model: Node3D, hair_mat: Material) -> void:
	var skel: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0] \
		if not model.find_children("*", "Skeleton3D", true, false).is_empty() else null
	if skel == null:
		return
	var bone := skel.find_bone("Head")
	if bone < 0:
		return
	var att := BoneAttachment3D.new()
	att.name = EXTRA
	att.bone_name = "Head"
	skel.add_child(att)
	# Pieces are placed in skeleton space (Y up, face toward +Z), then moved into the
	# bone's frame so they ride along with the head.
	var to_bone := skel.get_bone_global_rest(bone).affine_inverse()
	var dark := _mat(Color(0.05, 0.05, 0.06), 0.3)
	for p in pieces(hair, face):
		var mat: Material = hair_mat
		match p.get("mat", "hair"):
			"dark": mat = dark
			"lens":
				var lm := _mat(Color(0.04, 0.05, 0.07), 0.08)
				lm.metallic = 0.6
				mat = lm
			"stubble":
				var sm := _mat(SKIN[skin].lerp(HAIR_COLORS[hair_color], 0.3).darkened(0.12), 0.95)
				mat = sm
		var mi := MeshInstance3D.new()
		mi.mesh = _shape(p.shape)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var b := Basis.from_euler(p.get("rot", Vector3.ZERO)).scaled_local(p.size)
		mi.transform = to_bone * Transform3D(b, p.pos)
		att.add_child(mi)


static var _shapes := {}


static func _shape(kind: String) -> Mesh:
	if _shapes.has(kind):
		return _shapes[kind]
	var m: Mesh
	match kind:
		"ball":
			var s := SphereMesh.new()
			s.radius = 1.0
			s.height = 2.0
			s.radial_segments = 16
			s.rings = 8
			m = s
		"dome":
			var s := SphereMesh.new()
			s.radius = 1.0
			s.height = 1.0
			s.is_hemisphere = true
			s.radial_segments = 16
			s.rings = 5
			m = s
		"box":
			var b := BoxMesh.new()
			b.size = Vector3(2, 2, 2)
			m = b
		"ring":
			var t := TorusMesh.new()
			t.inner_radius = 0.8
			t.outer_radius = 1.0
			t.rings = 12
			t.ring_segments = 6
			m = t
		"disc":
			var c := CylinderMesh.new()
			c.top_radius = 1.0
			c.bottom_radius = 1.0
			c.height = 2.0
			c.radial_segments = 12
			c.rings = 1
			m = c
	_shapes[kind] = m
	return m


## The hair and face pieces as data: shape, position and half-size in skeleton space
## (metres, head centre about (0, 1.66, 0), face toward +Z). Exposed for tests.
static func pieces(hair_style: String, face_style: String) -> Array:
	var out := []
	# Brows on every face, in hair color.
	for sx in [-1.0, 1.0]:
		out.append({"shape": "box", "pos": Vector3(0.058 * sx, 1.715, 0.152),
			"size": Vector3(0.026, 0.006, 0.008), "rot": Vector3(0.25, 0, -0.12 * sx)})
	match hair_style:
		"buzz":
			out.append({"shape": "dome", "pos": Vector3(0, 1.668, -0.008),
				"size": Vector3(0.168, 0.182, 0.178), "rot": Vector3(-0.42, 0, 0)})
		"long":
			out.append({"shape": "ball", "pos": Vector3(0, 1.6, -0.075), "size": Vector3(0.165, 0.2, 0.1)})
			for sx in [-1.0, 1.0]:
				out.append({"shape": "ball", "pos": Vector3(0.13 * sx, 1.6, 0.0),
					"size": Vector3(0.045, 0.14, 0.08)})
		"ponytail":
			out.append({"shape": "ball", "pos": Vector3(0, 1.71, -0.16), "size": Vector3(0.05, 0.05, 0.05)})
			out.append({"shape": "ball", "pos": Vector3(0, 1.6, -0.19), "size": Vector3(0.042, 0.12, 0.042),
				"rot": Vector3(0.25, 0, 0)})
		"bun":
			out.append({"shape": "ball", "pos": Vector3(0, 1.83, -0.07), "size": Vector3(0.072, 0.065, 0.072)})
		"mohawk":
			out.append({"shape": "ball", "pos": Vector3(0, 1.785, -0.03), "size": Vector3(0.03, 0.09, 0.19)})
		"afro":
			out.append({"shape": "ball", "pos": Vector3(0, 1.79, -0.06), "size": Vector3(0.21, 0.18, 0.21)})
	match face_style:
		"stubble":
			out.append({"shape": "ball", "pos": Vector3(0, 1.572, 0.05), "size": Vector3(0.131, 0.1, 0.129),
				"mat": "stubble"})
		"mustache":
			out.append({"shape": "ball", "pos": Vector3(0, 1.603, 0.148), "size": Vector3(0.045, 0.011, 0.016),
				"rot": Vector3(0.2, 0, 0)})
		"beard":
			out.append({"shape": "ball", "pos": Vector3(0, 1.572, 0.05), "size": Vector3(0.132, 0.1, 0.13)})
			out.append({"shape": "ball", "pos": Vector3(0, 1.603, 0.15), "size": Vector3(0.045, 0.012, 0.016)})
		"glasses":
			for sx in [-1.0, 1.0]:
				out.append({"shape": "ring", "pos": Vector3(0.058 * sx, 1.68, 0.178),
					"size": Vector3(0.034, 0.03, 0.034), "rot": Vector3(PI / 2, 0, 0), "mat": "dark"})
			out.append({"shape": "box", "pos": Vector3(0, 1.684, 0.18), "size": Vector3(0.014, 0.003, 0.003),
				"mat": "dark"})
		"shades":
			for sx in [-1.0, 1.0]:
				out.append({"shape": "disc", "pos": Vector3(0.058 * sx, 1.682, 0.178),
					"size": Vector3(0.034, 0.003, 0.026), "rot": Vector3(PI / 2, 0, 0), "mat": "lens"})
			out.append({"shape": "box", "pos": Vector3(0, 1.69, 0.18), "size": Vector3(0.09, 0.004, 0.004),
				"mat": "dark"})
	return out
