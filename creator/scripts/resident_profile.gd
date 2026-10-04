class_name ResidentProfile
extends RefCounted
## The Resident you create: name, look, background (with its starting perk), home and
## wardrobe. Saved as the Progress section "resident" (to_dict / from_dict).

const BACKGROUNDS := {
	"cabbie": {
		"label": "Cabbie",
		"blurb": "Twenty years behind the wheel. Knows every street by heart.",
		"perk": "Better car handling",
		"perks": {"car_handling": 1.15},
	},
	"ex_cop": {
		"label": "Ex-cop",
		"blurb": "Left the force, kept the friends. Some of them still owe you.",
		"perk": "One free bribe a day",
		"perks": {"free_bribes_per_day": 1},
	},
	"hustler": {
		"label": "Hustler",
		"blurb": "Always has a guy. Knows what anything is worth, and to whom.",
		"perk": "Shops pay 25% more for stolen goods",
		"perks": {"stolen_goods_price": 1.25},
	},
	"medic": {
		"label": "Medic",
		"blurb": "Night shifts in the ER. Patches up fast, including yourself.",
		"perk": "Heal 50% faster",
		"perks": {"heal_rate": 1.5},
	},
}
const BACKGROUND_ORDER := ["cabbie", "ex_cop", "hustler", "medic"]
const WARDROBE_SLOTS := 6
const START_CASH := 500
const NAMES := ["Alex Rivera", "Sam Kowalski", "Jordan Price", "Casey Moreno", "Riley Chen",
	"Morgan Hayes", "Danny Ortiz", "Jamie Brooks", "Toni Russo", "Chris Okafor", "Lou Bennett",
	"Max Delgado"]

var name := "Alex Rivera"
var look := CharacterLook.new()
var background := "cabbie"
var home := Vector2i(-1, -1)          # a cell of the home building; -1 = no home yet
var outfits: Array[Dictionary] = []   # saved looks in the wardrobe
var owned := PackedStringArray()      # shop items, e.g. "cloth:14"
var loaded := false                   # true once from_dict ran (a save was loaded)


func perk(key: String, default: Variant = 0) -> Variant:
	## A background perk value, e.g. perk("car_handling", 1.0) -> 1.15 for a Cabbie.
	return BACKGROUNDS[background].perks.get(key, default)


func has_home() -> bool:
	return home.x >= 0


func save_outfit(slot: int) -> void:
	while outfits.size() <= slot:
		outfits.append({})
	outfits[slot] = look.to_dict()


func wear_outfit(slot: int) -> bool:
	if slot >= outfits.size() or outfits[slot].is_empty():
		return false
	var l := CharacterLook.from_dict(outfits[slot])
	# A saved outfit can't smuggle in shop colors that are no longer owned.
	for k in ["top", "bottom", "shoes"]:
		if not CharacterLook.cloth_owned(l.get(k), owned):
			l.set(k, look.get(k))
	look = l
	return true


func to_dict() -> Dictionary:
	return {"name": name, "look": look.to_dict(), "background": background,
		"home": [home.x, home.y], "outfits": outfits.duplicate(true), "owned": Array(owned)}


func from_dict(d: Dictionary) -> void:
	## Loads in place: the profile is the Progress save section "resident".
	var p := parse(d)
	name = p.name
	look = p.look
	background = p.background
	home = p.home
	outfits = p.outfits
	owned = p.owned
	loaded = true


static func parse(d: Dictionary) -> ResidentProfile:
	var p := ResidentProfile.new()
	p.name = clean_name(str(d.get("name", p.name)))
	p.look = CharacterLook.from_dict(d.get("look", {}))
	p.background = d.get("background", p.background) if BACKGROUNDS.has(d.get("background")) else p.background
	var h: Array = d.get("home", [-1, -1])
	p.home = Vector2i(int(h[0]), int(h[1])) if h.size() == 2 else Vector2i(-1, -1)
	for o in d.get("outfits", []):
		if p.outfits.size() < WARDROBE_SLOTS:
			p.outfits.append(o if o is Dictionary else {})
	p.owned = PackedStringArray(d.get("owned", []))
	return p


static func clean_name(s: String) -> String:
	s = s.strip_edges().replace("\n", " ")
	if s.length() > 24:
		s = s.substr(0, 24).strip_edges()
	return s if s != "" else "Alex Rivera"
