class_name BuildingTags
extends RefCounted
## Finds buildings by tag, never by name, so missions keep working as the catalog grows.
## Special buildings carry `tags` and `name` in their City.buildings entry (the sandbox
## catalog). Ordinary zone buildings get tags from their zone: home, shop, industrial.
##
## Stand-ins: until the Mayor can place specials, a template that needs a tag nobody has
## built can borrow an ordinary building and give it a placeholder name, so the good jobs
## are playable today. Turn `stand_ins` off once the catalog is in.

const ZONE_TAGS := [[], ["home"], ["shop"], ["industrial"]]

## tag -> [zone the stand-in is borrowed from, placeholder names]
const STAND_INS := {
	"police": [City.Zone.COM, ["Precinct 9", "Harbor Precinct"]],
	"police_hq": [City.Zone.COM, ["Police Headquarters"]],
	"fire_station": [City.Zone.COM, ["Fire Station 3", "Engine Co. 14"]],
	"hospital": [City.Zone.COM, ["St. Jude's Hospital"]],
	"garbage_depot": [City.Zone.IND, ["Sanitation Depot"]],
	"power_plant": [City.Zone.IND, ["Bayside Power Station"]],
	"bank": [City.Zone.COM, ["Second National Bank"]],
	"hideout": [City.Zone.IND, ["The Bunker"]],
	"chop_shop": [City.Zone.IND, ["Eddie's Auto Body"]],
	"warehouse": [City.Zone.IND, ["Pier 4 Warehouse"]],
	"pawn_shop": [City.Zone.COM, ["Lucky Pawn"]],
	"nightclub": [City.Zone.COM, ["Club Voltage"]],
	"crime_den": [City.Zone.IND, ["The Rat Hole", "Dockside Den", "Cinder Block Club"]],
}

const STREETS := ["Elm", "Maple", "Harbor", "Lincoln", "Bay", "Pine", "Union", "Grand", "Market",
	"Ocean", "Cedar", "Main", "Park", "Mill", "Spring", "Hill"]

var city: City
var stand_ins := true
var _borrowed := {}  # tag -> building id lent as a stand-in
var _extra := {}     # building id -> {b, tag, name}: spawned specials (specials.gd)


func _init(c: City) -> void:
	city = c
	c.building_removed.connect(func(id):
		for t in _borrowed.keys():
			if _borrowed[t] == id:
				_borrowed.erase(t))


func tags_of(b: Dictionary) -> Array:
	var out: Array = []
	if b.has("tags"):
		out.append_array(b.tags)
	else:
		out.append_array(ZONE_TAGS[b.zone])
	for t in _borrowed:
		if _borrowed[t] == b.id:
			out.append(t)
	return out


func is_real(b: Dictionary) -> bool:
	return b.has("tags")


func find(tag: String) -> Array[Dictionary]:
	## Every building carrying the tag, or the ordinary building already lent for it.
	var out: Array[Dictionary] = []
	for b in city.buildings.values():
		if b.has("tags"):
			if tag in b.tags:
				out.append(b)
		elif tag in ZONE_TAGS[b.zone]:
			out.append(b)
	for id in _extra:
		if _extra[id].tag == tag:
			out.append(_extra[id].b)
	if out.is_empty() and _borrowed.has(tag) and city.buildings.has(_borrowed[tag]):
		out.append(city.buildings[_borrowed[tag]])
	return out


func stand_in_pool(tag: String) -> Array[Dictionary]:
	## Ordinary buildings that could stand in for a missing tag, biggest first. Empty when
	## stand-ins are off, the tag is real, or one is already lent.
	var out: Array[Dictionary] = []
	if not stand_ins or not STAND_INS.has(tag) or _borrowed.has(tag) or not find(tag).is_empty():
		return out
	var want: int = STAND_INS[tag][0]
	var taken := _borrowed.values()
	for b in city.buildings.values():
		if b.zone == want and not b.has("tags") and not (b.id in taken):
			out.append(b)
	out.sort_custom(func(p, q): return p.size * 10 + p.stage > q.size * 10 + q.stage)
	return out


func lend(tag: String, b: Dictionary) -> void:
	_borrowed[tag] = b.id


func add_extra(b: Dictionary, tag: String, nm: String) -> void:
	## A spawned special: an extra tag and name on a building (or a kerb stand-in).
	_extra[b.id] = {"b": b, "tag": tag, "name": nm}


func remove_extra(id: int) -> void:
	_extra.erase(id)


func building(id: int) -> Dictionary:
	## city.buildings or a spawned kerb special.
	if city.buildings.has(id):
		return city.buildings[id]
	return _extra[id].b if _extra.has(id) else {}


func has_real(tag: String) -> bool:
	for id in _extra:
		if _extra[id].tag == tag:
			return true
	for b in city.buildings.values():
		if b.has("tags") and tag in b.tags:
			return true
	return false


func name_of(b: Dictionary, tag := "") -> String:
	if _extra.has(b.id) and (tag == "" or _extra[b.id].tag == tag):
		return _extra[b.id].name
	if b.has("name"):
		return b.name
	for t in _borrowed:
		if _borrowed[t] == b.id:
			var names: Array = STAND_INS[t][1]
			return names[b.id % names.size()]
	return address(b) + _zone_noun(b, tag)


func address(b: Dictionary) -> String:
	## A stable street address from the grid position: "1204 Elm St".
	var street: String = STREETS[(b.y / 4 + b.x / 9) % STREETS.size()]
	return "%d %s St" % [100 + b.x * 12 + (b.y % 4) * 2, street]


func _zone_noun(b: Dictionary, tag: String) -> String:
	if tag == "home" or b.zone == City.Zone.RES:
		return "" if b.stage < 2 else " apartments"
	if b.zone == City.Zone.COM:
		return ["", " shops", " plaza", " tower"][b.stage]
	return " works"


func to_dict() -> Dictionary:
	## Which ordinary buildings stand in for which tags, so names stay put across saves.
	return {"borrowed": _borrowed.duplicate()}


func from_dict(d: Dictionary) -> void:
	_borrowed.clear()
	var b: Dictionary = d.get("borrowed", {})
	for t in b:
		_borrowed[t] = int(b[t])
