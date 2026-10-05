class_name CharacterLook
extends RefCounted
## What the Resident looks like: body, skin, hair, face, clothes and their colors.
## `apply(character_model)` dresses a CharacterModel (player/) through its set_outfit(), so
## the rebuilt character's own hair, faces, hats and clothes are used. Plain data, so it
## saves as a Dictionary; old saves without clothing styles load as tee, jeans, sneakers.

const BODIES := {
	"slim": {"label": "Slim", "scale": Vector3(0.9, 1.0, 0.92)},
	"average": {"label": "Average", "scale": Vector3(1.0, 1.0, 1.0)},
	"athletic": {"label": "Athletic", "scale": Vector3(1.1, 1.0, 1.02)},
	"heavy": {"label": "Heavy", "scale": Vector3(1.2, 0.98, 1.2)},
}
const BODY_ORDER := ["slim", "average", "athletic", "heavy"]

# Names match the part names CharacterModel (player/) draws.
const HAIR_STYLES := {
	"short": "Short", "buzz": "Buzz cut", "bald": "Bald", "long": "Long",
	"ponytail": "Ponytail", "bun": "Bun", "mohawk": "Mohawk", "afro": "Afro",
}
const HAIR_ORDER := ["short", "buzz", "bald", "long", "ponytail", "bun", "mohawk", "afro"]
const NO_HAT_HAIR := ["long", "bun", "mohawk", "afro"]   # hair a hat would clip through

const FACES := {
	"clean": "Clean", "stubble": "Stubble", "mustache": "Mustache", "beard": "Beard",
	"glasses": "Glasses", "shades": "Shades",
}
const FACE_ORDER := ["clean", "stubble", "mustache", "beard", "glasses", "shades"]

# Clothing styles by slot: id -> label. FREE are always available; the rest are sold in
# clothing shops and need "<slot>:<id>" in the profile's owned list (see ClothingStock).
const STYLES := {
	"top": {"tee": "T-shirt", "longsleeve": "Long sleeve", "hoodie": "Hoodie", "jacket": "Jacket", "tank": "Tank top"},
	"bottom": {"jeans": "Jeans", "shorts": "Shorts", "skirt": "Skirt"},
	"shoes": {"sneakers": "Sneakers", "boots": "Boots"},
	"hat": {"": "No hat", "cap": "Cap", "beanie": "Beanie"},
}
const STYLE_ORDER := {
	"top": ["tee", "longsleeve", "hoodie", "jacket", "tank"],
	"bottom": ["jeans", "shorts", "skirt"],
	"shoes": ["sneakers", "boots"],
	"hat": ["", "cap", "beanie"],
}
const FREE_STYLES := {
	"top": ["tee", "longsleeve"], "bottom": ["jeans", "shorts"], "shoes": ["sneakers"], "hat": [""],
}

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
# shops and need "cloth:<index>" in the profile's owned list.
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
var top_style := "tee"
var bottom_style := "jeans"
var shoe_style := "sneakers"
var hat := ""            # "", "cap" or "beanie"
var top := 4             # color indexes into CLOTH
var jacket := 1          # the outer layer, used when top_style is "jacket"
var bottom := 3
var shoes := 0
var hat_color := 1


func to_dict() -> Dictionary:
	return {"body": body, "height": height, "skin": skin, "hair": hair, "hair_color": hair_color,
		"face": face, "top_style": top_style, "bottom_style": bottom_style, "shoe_style": shoe_style,
		"hat": hat, "top": top, "jacket": jacket, "bottom": bottom, "shoes": shoes, "hat_color": hat_color}


static func from_dict(d: Dictionary) -> CharacterLook:
	var l := CharacterLook.new()
	l.body = d.get("body", l.body) if BODIES.has(d.get("body")) else l.body
	l.height = clampf(float(d.get("height", 1.0)), 0.92, 1.08)
	l.skin = clampi(int(d.get("skin", l.skin)), 0, SKIN.size() - 1)
	l.hair = d.get("hair", l.hair) if HAIR_STYLES.has(d.get("hair")) else l.hair
	l.hair_color = clampi(int(d.get("hair_color", l.hair_color)), 0, HAIR_COLORS.size() - 1)
	l.face = d.get("face", l.face) if FACES.has(d.get("face")) else l.face
	l.top_style = d.get("top_style", l.top_style) if STYLES.top.has(d.get("top_style")) else l.top_style
	l.bottom_style = d.get("bottom_style", l.bottom_style) if STYLES.bottom.has(d.get("bottom_style")) else l.bottom_style
	l.shoe_style = d.get("shoe_style", l.shoe_style) if STYLES.shoes.has(d.get("shoe_style")) else l.shoe_style
	l.hat = d.get("hat", l.hat) if STYLES.hat.has(d.get("hat")) else l.hat
	if l.hat != "" and l.hair in NO_HAT_HAIR:
		l.hat = ""
	l.top = clampi(int(d.get("top", l.top)), 0, CLOTH.size() - 1)
	l.jacket = clampi(int(d.get("jacket", l.jacket)), 0, CLOTH.size() - 1)
	l.bottom = clampi(int(d.get("bottom", l.bottom)), 0, CLOTH.size() - 1)
	l.shoes = clampi(int(d.get("shoes", l.shoes)), 0, CLOTH.size() - 1)
	l.hat_color = clampi(int(d.get("hat_color", l.hat_color)), 0, CLOTH.size() - 1)
	return l


func duplicate_look() -> CharacterLook:
	return from_dict(to_dict())


static func random(rng: RandomNumberGenerator) -> CharacterLook:
	## A random look from what is free: basic clothes in free colors.
	var l := CharacterLook.new()
	l.body = BODY_ORDER[rng.randi() % BODY_ORDER.size()]
	l.height = snappedf(rng.randf_range(0.94, 1.06), 0.01)
	l.skin = rng.randi() % SKIN.size()
	l.hair = HAIR_ORDER[rng.randi() % HAIR_ORDER.size()]
	l.hair_color = rng.randi() % 8   # natural colors mostly
	l.face = FACE_ORDER[rng.randi() % FACE_ORDER.size()]
	for slot in ["top", "bottom", "shoes"]:
		var free: Array = FREE_STYLES[slot]
		l.set(slot + "_style" if slot != "shoes" else "shoe_style", free[rng.randi() % free.size()])
	l.top = rng.randi() % CLOTH_FREE
	l.bottom = rng.randi() % CLOTH_FREE
	l.shoes = rng.randi() % CLOTH_FREE
	l.jacket = rng.randi() % CLOTH_FREE
	l.hat_color = rng.randi() % CLOTH_FREE
	return l


static func cloth_owned(i: int, owned: PackedStringArray) -> bool:
	return i < CLOTH_FREE or owned.has("cloth:%d" % i)


## Can the Resident wear this style? slot is "top", "bottom", "shoes" or "hat".
static func style_owned(slot: String, style: String, owned: PackedStringArray) -> bool:
	return style in FREE_STYLES[slot] or owned.has("%s:%s" % [slot, style])


func get_style(slot: String) -> String:
	return {"top": top_style, "bottom": bottom_style, "shoes": shoe_style, "hat": hat}[slot]


func set_style(slot: String, style: String) -> void:
	match slot:
		"top": top_style = style
		"bottom": bottom_style = style
		"shoes": shoe_style = style
		"hat":
			hat = style
			if style != "" and hair in NO_HAT_HAIR:
				hair = "short"   # the chosen hat would clip through this hair


## Pick a hair style, taking off a hat that would clip through it.
func set_hair(style: String) -> void:
	hair = style
	if style in NO_HAT_HAIR:
		hat = ""


# ------------------------------------------------------------------ dressing ---

static var _applying := false


## What CharacterModel.set_outfit() is given for this look.
func outfit() -> Dictionary:
	return {
		"top": top_style, "bottom": bottom_style, "shoes": shoe_style, "hat": hat,
		"hair": hair, "face": face,
		"colors": {
			"Skin": SKIN[skin], "Hair": HAIR_COLORS[hair_color], "Shirt": CLOTH[top],
			"Jacket": CLOTH[jacket], "Pants": CLOTH[bottom], "Shoes": CLOTH[shoes],
			"Hat": CLOTH[hat_color],
		},
	}


## Dress a CharacterModel that is already in the tree (its _ready has run). Safe to call
## from the model's `dressed` signal: it does nothing when the model already matches.
func apply(cm: Node3D) -> void:
	var model: Node3D = cm.get("model")
	if model == null or _applying:
		return
	var bs: Vector3 = BODIES[body].scale
	model.scale = Vector3(bs.x, bs.y * height, bs.z)
	var want := outfit()
	if _matches(cm, want):
		return
	_applying = true
	cm.call("set_outfit", want)
	_applying = false


static func _matches(cm: Node3D, want: Dictionary) -> bool:
	var have: Dictionary = cm.get("outfit")
	for k in ["top", "bottom", "shoes", "hat", "hair", "face"]:
		if have.get(k) != want[k]:
			return false
	var cols: Dictionary = cm.get("colors")
	for k in want.colors:
		if cols.get(k) != want.colors[k]:
			return false
	return true
