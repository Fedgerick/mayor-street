class_name CityEffects
extends RefCounted
## Street results that change the city for a while (round-3 plan section 5):
##   casino_robbed  the casino's daily takings drop by 60% for a week
##   den_busted     crime falls around a raided den for two weeks
##   game_day       a good game day lifts happiness across the city for five days
##   pirate_radio / radio_saved   a small dip or lift in happiness for a week
## Jobs name theirs with "effect" (and "effect_at", the slot it happens at).
##
## Takings come straight out of city funds here. Crime and happiness are computed by
## services/ once a day, so this sits on the City as meta "street_effects" for it to read:
##     cr *= fx.crime_mult(x, y)        h += fx.happiness_add(x, y)

signal news(text: String)

const DEFS := {
	"casino_robbed": {"days": 7, "takings_cut": 0.6,
		"text": "%s was robbed. Its takings are down for a week"},
	"den_busted": {"days": 14, "radius": 8, "crime": 0.55,
		"text": "Crime is down around %s since the raid"},
	"game_day": {"days": 5, "happiness": 0.08,
		"text": "Game day at %s lifted the whole city's mood"},
	"pirate_radio": {"days": 7, "happiness": -0.03,
		"text": "%s is playing a pirate feed. Listeners are not happy"},
	"radio_saved": {"days": 5, "happiness": 0.03,
		"text": "%s is back on the air and thanking its listeners"},
}

var city: City
var progress: ProgressLink
var active: Array = []  # {kind, building, name, x, y, days}


func _init(c: City, p: ProgressLink) -> void:
	city = c
	progress = p
	c.set_meta("street_effects", self)


func add(kind: String, b: Dictionary, nm: String) -> void:
	if not DEFS.has(kind):
		return
	var def: Dictionary = DEFS[kind]
	var bid: int = b.get("id", -1)
	for e in active:  # the same effect again just starts its clock over
		if e.kind == kind and e.building == bid:
			e.days = def.days
			news.emit(def.text % nm)
			return
	active.append({"kind": kind, "building": bid, "name": nm,
		"x": int(b.get("x", 0)), "y": int(b.get("y", 0)), "days": int(def.days)})
	news.emit(def.text % nm)


func day_passed() -> void:
	for e in active:
		var def: Dictionary = DEFS[e.kind]
		if def.has("takings_cut") and city.buildings.has(e.building):
			var b: Dictionary = city.buildings[e.building]
			var takings := -float(Catalog.get_def(b.get("kind", "")).get("upkeep", 0)) if b.has("kind") else 0.0
			if takings > 0.0:
				progress.add_city_funds(-takings * def.takings_cut, e.name + " losses")
		e.days = int(e.days) - 1
	active = active.filter(func(e): return int(e.days) > 0)


func is_active(kind: String) -> bool:
	for e in active:
		if e.kind == kind:
			return true
	return false


func crime_mult(x: int, y: int) -> float:
	## Multiplier on crime at a cell: 1 normally, lower near a busted den.
	var m := 1.0
	for e in active:
		var def: Dictionary = DEFS[e.kind]
		if not def.has("crime"):
			continue
		var d := Vector2(x - e.x, y - e.y).length()
		var r: float = def.radius
		if d < r:
			m *= lerpf(def.crime, 1.0, d / r)
	return m


func happiness_add(_x: int, _y: int) -> float:
	## Added to happiness (0..1) at a cell; every current effect is citywide.
	var h := 0.0
	for e in active:
		h += DEFS[e.kind].get("happiness", 0.0)
	return h


func to_dict() -> Array:
	return active.duplicate(true)


func from_dict(a: Array) -> void:
	active.clear()
	for e in a:
		if DEFS.has(e.get("kind", "")):
			active.append(e.duplicate())
