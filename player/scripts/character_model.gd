class_name CharacterModel
extends Node3D
## A street person: the rigged wardrobe in player/assets/character.glb (built by
## player/tools/build_character.py), dressed as one merged mesh, and driven by an
## AnimationTree made in code:
##   idle / walk / run blended by speed, jump and fall in the air, sitting in cars,
##   idle variations (looking around, arms folded, sitting on a bench) when standing,
##   talking and phone calls over any of that, and one-shots: get in / out of a car,
##   wave, jab / cross / hook, reloads, flinch, stumble, knocked down and getting up,
##   carjack, and dying.
##
## `seed_value` picks an outfit and colours, so the same model dresses a crowd.
## `set_outfit()` picks styles by hand (the character creator, police uniforms).
## Far from the camera the model swaps to its LOD1 mesh (about 1.5k triangles, one draw
## call: every material slot in one surface, coloured by player/scripts/person.gdshader).
## Up close the full mesh draws one surface per material, and the LOD1 mesh casts its
## shadow, so shadows stay cheap.

signal dressed   # end of _dress(); creator/ re-applies a created look on it

const SCENE := "res://player/assets/character.glb"
const LOD_SHADER := preload("res://player/scripts/person.gdshader")
const WALK_SPEED := 3.6     # m/s the Walk clip was authored for
const RUN_SPEED := 7.2
const LOOPS := ["Idle", "IdleLook", "IdleArms", "Walk", "Run", "Jump", "Fall", "Sit", "SitBench",
	"Talk", "Phone", "AimPistol", "AimShotgun"]
const UPPER := ["Chest", "Neck", "Head", "Jaw",
	"UpperArm.L", "LowerArm.L", "Hand.L", "Fingers1.L", "Fingers2.L", "Thumb.L",
	"UpperArm.R", "LowerArm.R", "Hand.R", "Fingers1.R", "Fingers2.R", "Thumb.R"]
enum Aim { NONE, PISTOL, SHOTGUN }

# Colour palettes. The first five are also used by citylife's crowd shader, in this order.
const SKIN := [Color(0.98, 0.8, 0.66), Color(0.89, 0.66, 0.5), Color(0.7, 0.48, 0.34), Color(0.47, 0.31, 0.21), Color(0.99, 0.87, 0.76)]
const SHIRT := [Color(0.9, 0.28, 0.22), Color(0.2, 0.47, 0.86), Color(0.98, 0.78, 0.2), Color(0.24, 0.68, 0.45), Color(0.95, 0.95, 0.93), Color(0.55, 0.3, 0.72), Color(0.13, 0.14, 0.17), Color(0.98, 0.55, 0.2)]
const PANTS := [Color(0.17, 0.22, 0.38), Color(0.14, 0.14, 0.16), Color(0.47, 0.39, 0.28), Color(0.3, 0.32, 0.36), Color(0.58, 0.52, 0.43)]
const HAIR := [Color(0.12, 0.09, 0.07), Color(0.36, 0.21, 0.1), Color(0.8, 0.6, 0.32), Color(0.58, 0.16, 0.08), Color(0.22, 0.22, 0.24)]
const SHOES := [Color(0.96, 0.96, 0.96), Color(0.1, 0.1, 0.11), Color(0.62, 0.26, 0.15), Color(0.85, 0.2, 0.2)]
const JACKET := [Color(0.16, 0.13, 0.11), Color(0.36, 0.22, 0.12), Color(0.2, 0.26, 0.2), Color(0.18, 0.22, 0.34), Color(0.55, 0.5, 0.42), Color(0.6, 0.12, 0.1)]
const HAT := [Color(0.12, 0.12, 0.14), Color(0.75, 0.15, 0.12), Color(0.15, 0.3, 0.6), Color(0.85, 0.8, 0.7), Color(0.2, 0.45, 0.25)]

# Styles, matching the part names in the glb ("" = none).
const TOPS := ["tee", "longsleeve", "hoodie", "jacket", "tank"]
const BOTTOMS := ["jeans", "shorts", "skirt"]
const SHOE_STYLES := ["sneakers", "boots"]
const HATS := ["", "cap", "beanie"]
const HAIR_STYLES := ["short", "buzz", "bald", "long", "ponytail", "bun", "mohawk", "afro"]
const FACES := ["clean", "stubble", "mustache", "beard", "glasses", "shades"]
const NO_HAT_HAIR := ["long", "bun", "mohawk", "afro"]   # hair a hat would clip through
const PRESETS := {
	"police": {"top": "longsleeve", "bottom": "jeans", "shoes": "boots", "hat": "cap",
		"colors": {"Shirt": Color(0.12, 0.17, 0.33), "Pants": Color(0.08, 0.1, 0.18),
			"Shoes": Color(0.05, 0.05, 0.06), "Hat": Color(0.08, 0.1, 0.2)}},
}
# Draw order of the merged surfaces, so every outfit and LOD lays out the same way.
const MAT_ORDER := ["Skin", "Shirt", "Jacket", "Pants", "Shoes", "Hair", "Brows", "Eyes", "EyeWhite", "Hat", "Stubble"]
const ROUGH := {"Skin": 0.55, "Hair": 0.85, "Brows": 0.85, "Shoes": 0.45, "Shirt": 0.78, "Jacket": 0.55,
	"Pants": 0.85, "Hat": 0.7, "Eyes": 0.15, "EyeWhite": 0.3, "Stubble": 0.95}
const LOD_DISTANCE := 14.0   # metres from the camera where the crowd mesh takes over
const PUNCHES := ["Jab", "Punch", "Hook"]   # a combo: left jab, right cross, right hook
const ONE_SHOTS_UPPER := ["Jab", "Punch", "Hook", "Hit", "Wave", "ReloadPistol", "ReloadShotgun"]
const IDLE_VARIANTS := ["look", "arms", "bench"]
const UPPER_ACTS := ["talk", "phone", "umbrella"]

@export var seed_value := 7
## -1 picks the LOD by distance to the camera; 0 or 1 pins it.
@export var lod := -1
## Play a look-around or folded-arms idle after standing still for a while.
@export var auto_idle := true

var model: Node3D
var anim: AnimationPlayer
var tree: AnimationTree
var body: MeshInstance3D          # the merged outfit mesh
var shadow_body: MeshInstance3D   # LOD1 shadow caster while the full mesh is shown
var skeleton: Skeleton3D
var outfit := {}                  # style picks: top, bottom, shoes, hat, hair, face
var colors := {}                  # material name -> Color
var activity := ""                # "", or one of IDLE_VARIANTS / UPPER_ACTS
var mats := {}                    # material name -> the StandardMaterial3D in use

var _air := 0.0
var _sit := 0.0
var _sitting := false
var _lean := 0.0
var _aim := 0.0
var _aim_kind := Aim.NONE
var _dead := false
var _dead_amt := 0.0
var _down := false
var _idlevar := 0.0
var _upper_act := 0.0
var _still := 0.0
var _auto_t := 0.0
var _auto_on := false
var _combo := 0
var _last_punch := -10.0
var _lod_now := 0
var _lod_check := 0.0
var _manual_outfit := {}
var _manual_colors := {}
var _phone: Node3D

static var _lib := {}             # part name -> Mesh
static var _skin: Skin
static var _merged := {}          # "parts@lod" -> ArrayMesh, least recently used first
# Merged outfits kept. Each holds GPU buffers, and crowd outfits come and go all session:
# unbounded, they piled up to the driver's buffer limit (VK_ERROR_TOO_MANY_OBJECTS).
const MERGED_MAX := 64
static var _src_mats := {}        # material name -> the glb's material (carries the name)
static var _lod_mat: ShaderMaterial
static var _arrays := {}          # "part#surface" -> the surface arrays, read once
static var _mat_cache := {}       # "slot|colour|roughness" -> StandardMaterial3D


static func available() -> bool:
	return ResourceLoader.exists(SCENE)


func _ready() -> void:
	model = (load(SCENE) as PackedScene).instantiate()
	model.rotation.y = PI   # the glTF faces +Z; the game's forward is -Z
	add_child(model)
	anim = model.find_children("*", "AnimationPlayer", true, false)[0]
	skeleton = model.find_children("*", "Skeleton3D", true, false)[0]
	for n in LOOPS:
		if anim.has_animation(n):
			anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	# The glb carries every wardrobe part; keep their meshes once, drop the nodes, and
	# draw the chosen outfit as one merged mesh.
	for mi in skeleton.find_children("*", "MeshInstance3D", false, false):
		var m := mi as MeshInstance3D
		if not _lib.has(String(m.name)):
			_lib[String(m.name)] = m.mesh
			# Keep a CPU copy of every part now: surface_get_arrays reads the mesh back from
			# the GPU and stalls the renderer, which was the 0.6-1.2 s hitch each time a
			# close-up pedestrian got a new outfit (0.4.6 benchmark on the laptop).
			for s in m.mesh.get_surface_count():
				_arrays[String(m.name) + "#" + str(s)] = m.mesh.surface_get_arrays(s)
			if _skin == null:
				_skin = m.skin
			for s in m.mesh.get_surface_count():
				var sm := m.mesh.surface_get_material(s)
				if sm and not _src_mats.has(sm.resource_name):
					_src_mats[sm.resource_name] = sm
		skeleton.remove_child(m)
		m.free()
	body = MeshInstance3D.new()
	body.name = "Body"
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	skeleton.add_child(body)
	body.skeleton = NodePath("..")
	body.skin = _skin
	shadow_body = MeshInstance3D.new()
	shadow_body.name = "ShadowBody"
	shadow_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	skeleton.add_child(shadow_body)
	shadow_body.skeleton = NodePath("..")
	shadow_body.skin = _skin
	_lod_now = maxi(lod, 0)
	_dress()
	_build_tree()


# ----------------------------------------------------------------- wardrobe ---

## The outfit and colours a seed gives. The first five picks match citylife's crowd
## shader palette, so a far pedestrian and its close-up model wear the same colours.
static func look_for_seed(s: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = s
	var cols := {
		"Skin": SKIN[rng.randi() % SKIN.size()],
		"Shirt": SHIRT[rng.randi() % SHIRT.size()],
		"Pants": PANTS[rng.randi() % PANTS.size()],
		"Hair": HAIR[rng.randi() % HAIR.size()],
		"Shoes": SHOES[rng.randi() % SHOES.size()],
	}
	cols["Jacket"] = JACKET[rng.randi() % JACKET.size()]
	cols["Hat"] = HAT[rng.randi() % HAT.size()]
	var top := _weighted(rng, {"tee": 4.0, "longsleeve": 2.0, "hoodie": 2.0, "jacket": 2.0, "tank": 1.0})
	var bottom := _weighted(rng, {"jeans": 6.0, "shorts": 2.0, "skirt": 2.0})
	var hair := _weighted(rng, {"short": 5.0, "buzz": 2.0, "bald": 1.0, "long": 3.0, "ponytail": 2.0,
		"bun": 1.0, "mohawk": 0.4, "afro": 1.0})
	var face := _weighted(rng, {"clean": 8.0, "stubble": 2.0, "mustache": 1.0, "beard": 1.5,
		"glasses": 1.5, "shades": 1.0})
	if (bottom == "skirt" or hair in ["long", "ponytail", "bun"]) and face in ["stubble", "mustache", "beard"]:
		face = "clean"
	var hat := ""
	if not hair in NO_HAT_HAIR and rng.randf() < 0.22:
		hat = "cap" if rng.randf() < 0.6 else "beanie"
	var shoes := "boots" if rng.randf() < 0.25 else "sneakers"
	return {"top": top, "bottom": bottom, "shoes": shoes, "hat": hat, "hair": hair, "face": face,
		"colors": cols}


static func _weighted(rng: RandomNumberGenerator, w: Dictionary) -> String:
	var total := 0.0
	for k in w:
		total += w[k]
	var r := rng.randf() * total
	for k in w:
		r -= w[k]
		if r <= 0.0:
			return k
	return w.keys()[0]


## Choose styles by hand: any of top, bottom, shoes, hat, hair, face (see the style
## lists), plus "colors" (material name -> Color) or "preset" ("police"). Unnamed
## choices keep what the seed gave. Re-dresses at once and emits `dressed`.
func set_outfit(styles: Dictionary) -> void:
	var st := styles.duplicate(true)
	if st.has("preset") and PRESETS.has(st.preset):
		var pre: Dictionary = PRESETS[st.preset].duplicate(true)
		pre.merge(st, true)
		st = pre
		st.erase("preset")
	if st.has("colors"):
		_manual_colors.merge(st.colors, true)
		st.erase("colors")
	_manual_outfit.merge(st, true)
	if body:
		_dress()


## Recolour material slots (Skin, Shirt, Jacket, Pants, Shoes, Hair, Hat, ...).
func set_colors(c: Dictionary) -> void:
	set_outfit({"colors": c})


## Forget hand-picked styles and colours; the seed decides again.
func clear_outfit() -> void:
	_manual_outfit.clear()
	_manual_colors.clear()
	if body:
		_dress()


func part_names() -> PackedStringArray:
	var p := PackedStringArray(["Head_skin", "Brows", "Hands"])
	p.append("Top_" + str(outfit.top))
	p.append("Bottom_" + str(outfit.bottom))
	p.append("Shoes_" + str(outfit.shoes))
	if outfit.hair != "bald" and outfit.hair != "":
		p.append("Hair_" + str(outfit.hair))
	if outfit.face != "clean" and outfit.face != "":
		p.append("Face_" + str(outfit.face))
	if outfit.hat != "":
		p.append("Hat_" + str(outfit.hat))
	return p


func _dress() -> void:
	var look := look_for_seed(seed_value)
	colors = look.colors
	colors.merge(_manual_colors, true)
	look.erase("colors")
	outfit = look
	outfit.merge(_manual_outfit, true)
	colors["Brows"] = _manual_colors.get("Brows", (colors.Hair as Color).darkened(0.15))
	colors["Stubble"] = _manual_colors.get("Stubble", (colors.Skin as Color).lerp(colors.Hair, 0.35).darkened(0.1))
	colors["Eyes"] = _manual_colors.get("Eyes", Color(0.03, 0.03, 0.04))
	colors["EyeWhite"] = Color(0.92, 0.91, 0.88)
	mats.clear()
	for nm in MAT_ORDER:
		var col: Color = colors.get(nm, Color(0.5, 0.5, 0.5))
		var key := "%s|%s|%s" % [nm, col.to_html(), ROUGH.get(nm, 0.7)]
		var mat: StandardMaterial3D = _mat_cache.get(key)
		if mat == null:  # shared by everyone in the same colour; nobody edits them in place
			mat = StandardMaterial3D.new()
			mat.resource_name = nm
			mat.albedo_color = col
			mat.roughness = ROUGH.get(nm, 0.7)
			mat.rim_enabled = not nm in ["Eyes", "EyeWhite"]
			mat.rim = 0.3
			mat.rim_tint = 0.5
			_mat_cache[key] = mat
		mats[nm] = mat
	_apply_mesh()
	dressed.emit()


func _apply_mesh() -> void:
	var parts := part_names()
	var low := _single_mesh(parts)
	_set_slot_colors(body)
	_set_slot_colors(shadow_body)
	if _lod_now == 1:
		body.mesh = low
		for s in body.get_surface_override_material_count():
			body.set_surface_override_material(s, null)
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		shadow_body.visible = false
	else:
		var hero = get_node_or_null("HeroLook")
		if hero and hero.cm == self and HeroLook._ok:
			# HeroLook draws the close-up; building the street mesh too would only churn
			# GPU buffers and push other outfits out of the cache.
			shadow_body.mesh = low
			shadow_body.visible = true
			if body.has_meta("creator_src_mesh"):
				body.remove_meta("creator_src_mesh")
			hero._apply()
			return
		body.mesh = _merged_mesh(parts, 0)
		for s in body.mesh.get_surface_count():
			var sm := body.mesh.surface_get_material(s)
			var nm := sm.resource_name if sm else ""
			body.set_surface_override_material(s, mats.get(nm))
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		shadow_body.mesh = low
		shadow_body.visible = true
	if body.has_meta("creator_src_mesh"):
		body.remove_meta("creator_src_mesh")


func _set_slot_colors(gi: GeometryInstance3D) -> void:
	for nm in MAT_ORDER:
		var c: Color = colors.get(nm, Color(0.5, 0.5, 0.5))
		gi.set_instance_shader_parameter("c_" + nm.to_lower(), Color(c.r, c.g, c.b, ROUGH.get(nm, 0.7)))


## LOD1 in one surface: the slot number goes in COLOR.r for person.gdshader.
static func _single_mesh(parts: PackedStringArray) -> ArrayMesh:
	var key := ",".join(parts) + "@single"
	if _merged.has(key):
		return _cached(key)
	var list := []
	for p in parts:
		var pn := p + "_lod1" if _lib.has(p + "_lod1") else p
		var mesh: Mesh = _lib.get(pn)
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var sm := mesh.surface_get_material(s)
			var slot := maxi(MAT_ORDER.find(sm.resource_name if sm else ""), 0)
			var arr: Array = _surface_arrays(pn, mesh, s).duplicate()
			var n := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var col := PackedColorArray()
			col.resize(n)
			col.fill(Color(slot / 15.0, 0, 0, 1))
			arr[Mesh.ARRAY_COLOR] = col
			arr[Mesh.ARRAY_TANGENT] = null
			list.append(arr)
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _concat(list))
	if _lod_mat == null:
		_lod_mat = ShaderMaterial.new()
		_lod_mat.shader = LOD_SHADER
	out.surface_set_material(0, _lod_mat)
	_keep(key, out)
	return out


static func _merged_mesh(parts: PackedStringArray, level: int) -> ArrayMesh:
	var key := ",".join(parts) + "@" + str(level)
	if _merged.has(key):
		return _cached(key)
	var by_mat := {}
	for p in parts:
		var nm := p + ("_lod1" if level == 1 else "")
		if not _lib.has(nm):
			nm = p
		var mesh: Mesh = _lib.get(nm)
		if mesh == null:
			push_warning("CharacterModel: no wardrobe part %s" % nm)
			continue
		for s in mesh.get_surface_count():
			var sm := mesh.surface_get_material(s)
			var mn := sm.resource_name if sm else ""
			if not by_mat.has(mn):
				by_mat[mn] = []
			by_mat[mn].append(_surface_arrays(nm, mesh, s))
	var out := ArrayMesh.new()
	for mn in MAT_ORDER:
		if not by_mat.has(mn):
			continue
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _concat(by_mat[mn]))
		out.surface_set_material(out.get_surface_count() - 1, _src_mats.get(mn))
	_keep(key, out)
	return out


## A cache hit, moved to the back so the least recently used outfit goes first.
static func _cached(key: String) -> ArrayMesh:
	var m: ArrayMesh = _merged[key]
	_merged.erase(key)
	_merged[key] = m
	return m


## Models wearing an evicted mesh keep their own reference until they re-dress.
static func _keep(key: String, mesh: ArrayMesh) -> void:
	while _merged.size() >= MERGED_MAX:
		_merged.erase(_merged.keys()[0])
	_merged[key] = mesh


static func _surface_arrays(part: String, mesh: Mesh, s: int) -> Array:
	var key := part + "#" + str(s)
	if not _arrays.has(key):
		_arrays[key] = mesh.surface_get_arrays(s)
	return _arrays[key]


static func _concat(list: Array) -> Array:
	if list.size() == 1:
		return list[0]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for idx in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR,
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		var all := true
		for a in list:
			if a[idx] == null:
				all = false
				break
		if not all:
			continue
		var acc = list[0][idx].duplicate()
		for i in range(1, list.size()):
			acc.append_array(list[i][idx])
		out[idx] = acc
	var index := PackedInt32Array()
	var base := 0
	for a in list:
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		if a[Mesh.ARRAY_INDEX] != null:
			for i in (a[Mesh.ARRAY_INDEX] as PackedInt32Array):
				index.append(i + base)
		else:
			for i in verts.size():
				index.append(i + base)
		base += verts.size()
	out[Mesh.ARRAY_INDEX] = index
	return out


## Triangles in the mesh being drawn now (not counting the shadow caster).
func triangle_count() -> int:
	var n := 0
	for s in body.mesh.get_surface_count():
		n += body.mesh.surface_get_array_index_len(s) / 3
	return n


func current_lod() -> int:
	return _lod_now


func _update_lod(delta: float) -> void:
	if lod >= 0:
		if _lod_now != lod:
			_lod_now = lod
			_apply_mesh()
		return
	_lod_check -= delta
	if _lod_check > 0.0:
		return
	_lod_check = 0.3 + randf() * 0.1
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return
	var d := cam.global_position.distance_to(global_position)
	var want := _lod_now
	if d > LOD_DISTANCE + 1.0:
		want = 1
	elif d < LOD_DISTANCE - 1.0:
		want = 0
	if want != _lod_now:
		_lod_now = want
		_apply_mesh()


# --------------------------------------------------------------- animation ---

func _clip(n: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = n
	return a


func _one_shot(bt: AnimationNodeBlendTree, k: String, last: String, x: int, upper: bool,
		fade_in := 0.06, fade_out := 0.15) -> String:
	var shot := AnimationNodeOneShot.new()
	shot.fadein_time = fade_in
	shot.fadeout_time = fade_out
	if upper:
		_upper_filter(shot)
	bt.add_node(k, shot, Vector2(x, 100))
	bt.add_node(k + "_clip", _clip(k), Vector2(x - 100, 300))
	bt.connect_node(k, 0, last)
	bt.connect_node(k, 1, k + "_clip")
	return k


func _build_tree() -> void:
	var bt := AnimationNodeBlendTree.new()
	var loco := AnimationNodeBlendSpace1D.new()
	loco.add_blend_point(_clip("Idle"), 0.0)
	loco.add_blend_point(_clip("Walk"), WALK_SPEED)
	loco.add_blend_point(_clip("Run"), RUN_SPEED)
	loco.min_space = 0.0
	loco.max_space = RUN_SPEED
	loco.sync = true
	bt.add_node("loco", loco, Vector2(0, 0))
	bt.add_node("pace", AnimationNodeTimeScale.new(), Vector2(200, 0))
	bt.connect_node("pace", 0, "loco")
	var airmix := AnimationNodeBlend2.new()
	bt.add_node("jump", _clip("Jump"), Vector2(0, 200))
	bt.add_node("fall", _clip("Fall"), Vector2(0, 300))
	bt.add_node("airmix", airmix, Vector2(200, 250))
	bt.connect_node("airmix", 0, "jump")
	bt.connect_node("airmix", 1, "fall")
	bt.add_node("air", AnimationNodeBlend2.new(), Vector2(400, 100))
	bt.connect_node("air", 0, "pace")
	bt.connect_node("air", 1, "airmix")
	# Idle variations (full body, only while standing still).
	var pick := AnimationNodeTransition.new()
	pick.xfade_time = 0.4
	var clips := {"look": "IdleLook", "arms": "IdleArms", "bench": "SitBench"}
	for i in IDLE_VARIANTS.size():
		var k: String = IDLE_VARIANTS[i]
		pick.add_input(k)
		bt.add_node("var_" + k, _clip(clips[k]), Vector2(400, 300 + 100 * i))
	bt.add_node("idle_pick", pick, Vector2(600, 300))
	for i in IDLE_VARIANTS.size():
		bt.connect_node("idle_pick", i, "var_" + IDLE_VARIANTS[i])
	bt.add_node("idlevar", AnimationNodeBlend2.new(), Vector2(800, 100))
	bt.connect_node("idlevar", 0, "air")
	bt.connect_node("idlevar", 1, "idle_pick")
	bt.add_node("sit_clip", _clip("Sit"), Vector2(800, 300))
	bt.add_node("sit", AnimationNodeBlend2.new(), Vector2(1000, 100))
	bt.connect_node("sit", 0, "idlevar")
	bt.connect_node("sit", 1, "sit_clip")
	var last := "sit"
	var x := 1200
	for k in ["EnterCar", "ExitCar"]:
		last = _one_shot(bt, k, last, x, false, 0.08, 0.12)
		x += 200
	# Talking or on the phone: upper body over anything the legs do.
	var act := AnimationNodeTransition.new()
	act.xfade_time = 0.3
	for k in UPPER_ACTS:
		act.add_input(k)
	bt.add_node("act_talk", _clip("Talk"), Vector2(x, 300))
	bt.add_node("act_phone", _clip("Phone"), Vector2(x, 400))
	bt.add_node("act_umbrella", _clip("Umbrella"), Vector2(x, 500))
	bt.add_node("act_pick", act, Vector2(x + 200, 300))
	bt.connect_node("act_pick", 0, "act_talk")
	bt.connect_node("act_pick", 1, "act_phone")
	bt.connect_node("act_pick", 2, "act_umbrella")
	var upper := AnimationNodeBlend2.new()
	_upper_filter(upper)
	bt.add_node("upper_act", upper, Vector2(x + 400, 100))
	bt.connect_node("upper_act", 0, last)
	bt.connect_node("upper_act", 1, "act_pick")
	last = "upper_act"
	x += 600
	# Weapons: an upper-body aim layer.
	bt.add_node("aim_pistol", _clip("AimPistol"), Vector2(x, 300))
	bt.add_node("aim_shotgun", _clip("AimShotgun"), Vector2(x, 400))
	bt.add_node("aim_pick", AnimationNodeBlend2.new(), Vector2(x + 200, 350))
	bt.connect_node("aim_pick", 0, "aim_pistol")
	bt.connect_node("aim_pick", 1, "aim_shotgun")
	var aim := AnimationNodeBlend2.new()
	_upper_filter(aim)
	bt.add_node("aim", aim, Vector2(x + 400, 100))
	bt.connect_node("aim", 0, last)
	bt.connect_node("aim", 1, "aim_pick")
	last = "aim"
	x += 600
	# Upper-body one-shots, then full-body ones.
	for k in ONE_SHOTS_UPPER:
		last = _one_shot(bt, k, last, x, true, 0.05, 0.12)
		x += 200
	for k in ["Carjack", "Stumble"]:
		last = _one_shot(bt, k, last, x, false, 0.08, 0.15)
		x += 200
	# Knocked down: holds the last frame of FallBack until get_up().
	bt.add_node("down_clip", _clip("FallBack"), Vector2(x, 300))
	bt.add_node("down_seek", AnimationNodeTimeSeek.new(), Vector2(x + 200, 300))
	bt.connect_node("down_seek", 0, "down_clip")
	bt.add_node("down", AnimationNodeBlend2.new(), Vector2(x + 400, 100))
	bt.connect_node("down", 0, last)
	bt.connect_node("down", 1, "down_seek")
	last = _one_shot(bt, "GetUp", "down", x + 600, false, 0.0, 0.2)
	x += 800
	# Death holds its last frame; the seek restarts it.
	bt.add_node("die_clip", _clip("Die"), Vector2(x, 300))
	bt.add_node("die_seek", AnimationNodeTimeSeek.new(), Vector2(x + 200, 300))
	bt.connect_node("die_seek", 0, "die_clip")
	bt.add_node("dead", AnimationNodeBlend2.new(), Vector2(x + 400, 100))
	bt.connect_node("dead", 0, last)
	bt.connect_node("dead", 1, "die_seek")
	bt.connect_node("output", 0, "dead")
	tree = AnimationTree.new()
	tree.tree_root = bt
	model.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	tree.active = true


## speed: horizontal m/s. on_floor: grounded. vy: vertical velocity. turn: yaw rate (rad/s).
func animate(delta: float, speed: float, on_floor: bool, vy: float, turn: float) -> void:
	_update_lod(delta)
	_air = move_toward(_air, 0.0 if on_floor else 1.0, delta * (8.0 if on_floor else 5.0))
	_sit = move_toward(_sit, 1.0 if _sitting else 0.0, delta * 6.0)
	tree.set("parameters/loco/blend_position", clampf(speed, 0.0, RUN_SPEED))
	# Slow the clips down when moving slower than they were authored for, so feet don't slide.
	var pace := 1.0
	if speed > 0.2 and speed < WALK_SPEED:
		pace = maxf(speed / WALK_SPEED, 0.45)
	elif speed > RUN_SPEED:
		pace = speed / RUN_SPEED
	tree.set("parameters/pace/scale", pace)
	tree.set("parameters/airmix/blend_amount", clampf(-vy / 3.0 + 0.3, 0.0, 1.0))
	tree.set("parameters/air/blend_amount", _air)
	tree.set("parameters/sit/blend_amount", _sit)
	_aim = move_toward(_aim, 0.0 if _aim_kind == Aim.NONE else 1.0, delta * 8.0)
	tree.set("parameters/aim/blend_amount", _aim)
	if _aim_kind != Aim.NONE:
		tree.set("parameters/aim_pick/blend_amount", 1.0 if _aim_kind == Aim.SHOTGUN else 0.0)
	# Idle variations fade in only while standing on the ground.
	var still := speed < 0.3 and on_floor and not _sitting and _aim_kind == Aim.NONE and not _dead and not _down
	_still = _still + delta if still else 0.0
	_auto_idle(delta, still)
	var want_var := still and activity in IDLE_VARIANTS
	_idlevar = move_toward(_idlevar, 1.0 if want_var else 0.0, delta * (2.5 if want_var else 5.0))
	tree.set("parameters/idlevar/blend_amount", _idlevar)
	var want_up := activity in UPPER_ACTS and _aim_kind == Aim.NONE and not _dead
	_upper_act = move_toward(_upper_act, 1.0 if want_up else 0.0, delta * 4.0)
	tree.set("parameters/upper_act/blend_amount", _upper_act)
	_dead_amt = move_toward(_dead_amt, 1.0 if _dead else 0.0, delta * 10.0)
	tree.set("parameters/dead/blend_amount", _dead_amt)
	tree.set("parameters/down/blend_amount", 1.0 if _down else 0.0)
	# Bank into turns a little.
	_lean = lerpf(_lean, clampf(-turn * speed * 0.02, -0.25, 0.25), 1.0 - exp(-8.0 * delta))
	model.rotation.z = _lean


func _auto_idle(delta: float, still: bool) -> void:
	if not auto_idle:
		return
	if _auto_on:
		_auto_t -= delta
		if _auto_t <= 0.0 or not still:
			_auto_on = false
			if activity in ["look", "arms"]:
				activity = ""
			_still = -randf_range(2.0, 6.0)
		return
	if still and activity == "" and _still > 7.0:
		_auto_on = true
		_auto_t = randf_range(4.5, 9.0)
		activity = "look" if randf() < 0.55 else "arms"
		tree.set("parameters/idle_pick/transition_request", activity)


## What the person is doing while not walking about: "" (nothing), "look", "arms",
## "bench" (sitting on a bench or chair), "talk", "phone" or "umbrella" (these three work
## while walking; "umbrella" holds the right fist up at the shoulder, see umbrella_grip()).
func set_activity(a: String) -> void:
	if a == activity:
		return
	_auto_on = false
	activity = a
	if a in IDLE_VARIANTS:
		tree.set("parameters/idle_pick/transition_request", a)
	elif a in UPPER_ACTS:
		tree.set("parameters/act_pick/transition_request", a)
	_show_phone(a == "phone")


func _show_phone(on: bool) -> void:
	if on and _phone == null:
		var mi := MeshInstance3D.new()
		mi.name = "Phone"
		var bm := BoxMesh.new()
		bm.size = Vector3(0.012, 0.13, 0.065)
		mi.mesh = bm
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(0.06, 0.06, 0.07)
		pm.roughness = 0.2
		pm.metallic = 0.4
		mi.material_override = pm
		mi.position = Vector3(0.0, 0.075, 0.025)
		_phone = mi
		hand_socket().add_child(_phone)
	if _phone:
		_phone.visible = on


func set_sitting(on: bool) -> void:
	_sitting = on


func _fire(k: String) -> void:
	tree.set("parameters/%s/request" % k, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func play_enter_car() -> void:
	_fire("EnterCar")


func play_exit_car() -> void:
	_fire("ExitCar")


func _upper_filter(n: AnimationNode) -> void:
	n.filter_enabled = true
	for b in UPPER:
		n.set_filter_path(NodePath("Rig/Skeleton3D:" + b), true)


func set_aim(kind: int) -> void:
	## Aim.NONE, Aim.PISTOL or Aim.SHOTGUN: raises the arms over the locomotion.
	_aim_kind = kind
	if kind != Aim.NONE and activity in UPPER_ACTS:
		set_activity("")


## Throws the next punch of the jab, cross, hook combo (or a named one) and returns
## the clip's name. A pause longer than 0.9 s starts the combo again from the jab.
func play_punch(kind := "") -> String:
	var now := Time.get_ticks_msec() / 1000.0
	if kind == "":
		_combo = (_combo + 1) % PUNCHES.size() if now - _last_punch < 0.9 else 0
		kind = PUNCHES[_combo]
	_last_punch = now
	_fire(kind)
	return kind


func play_hit() -> void:
	_fire("Hit")


func play_wave() -> void:
	_fire("Wave")


## Aim.PISTOL or Aim.SHOTGUN.
func play_reload(kind: int) -> void:
	_fire("ReloadShotgun" if kind == Aim.SHOTGUN else "ReloadPistol")


func play_stumble() -> void:
	_fire("Stumble")


func play_carjack() -> void:
	_fire("Carjack")


## Knocked off the feet (hit by a car, a blast); stays down until get_up().
func knock_down() -> void:
	if _down or _dead:
		return
	_down = true
	tree.set("parameters/down_seek/seek_request", 0.0)
	tree.set("parameters/down/blend_amount", 1.0)


func get_up() -> void:
	if not _down:
		return
	_down = false
	tree.set("parameters/down/blend_amount", 0.0)
	_fire("GetUp")


func is_down() -> bool:
	return _down


func set_dead(on: bool) -> void:
	## Falls down and stays down until set_dead(false).
	if on and not _dead:
		tree.set("parameters/die_seek/seek_request", 0.0)
	_dead = on
	_down = false
	if on:
		_dead_amt = 1.0
		tree.set("parameters/dead/blend_amount", 1.0)


## Where an umbrella handle goes for the "umbrella" activity: the right fist, world space.
func umbrella_grip() -> Vector3:
	return hand_socket().global_position


## Hand bone attachment for held items (weapons, the phone). Created on first use.
func hand_socket() -> Node3D:
	if skeleton.has_node("HandSocket"):
		return skeleton.get_node("HandSocket")
	var ba := BoneAttachment3D.new()
	ba.name = "HandSocket"
	ba.bone_name = "Hand.R"
	skeleton.add_child(ba)
	return ba


func clip_length(n: String) -> float:
	return anim.get_animation(n).length if anim.has_animation(n) else 0.5
