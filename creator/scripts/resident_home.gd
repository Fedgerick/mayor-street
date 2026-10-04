class_name ResidentHome
extends Node
## Keeps track of the Resident's home building: where its door is (save point and respawn
## spot), whether it still stands, and moving in automatically when the city has no homes
## yet. The home is stored as one cell of the building, because the sim replaces building
## ids when four lots merge into a tower.

signal home_changed(cell: Vector2i)
signal home_lost            # bulldozed or rezoned: ask the player to pick a new one

var city: City
var profile: ResidentProfile
var auto_move_in := true    # move into the first home that grows if there is none


func setup(c: City, p: ResidentProfile) -> void:
	city = c
	profile = p
	city.building_added.connect(_on_added)
	city.building_removed.connect(_on_removed)
	if not profile.has_home() and auto_move_in:
		var first := first_home()
		if first.x >= 0:
			move_in(first)


func move_in(cell: Vector2i) -> bool:
	if not is_home_cell(city, cell):
		return false
	profile.home = cell
	home_changed.emit(cell)
	return true


func building() -> Dictionary:
	## The home building's data from City.buildings, or {} when there is none.
	if city == null or not profile.has_home() or not city.inside(profile.home.x, profile.home.y):
		return {}
	var id := city.bld[city.idx(profile.home.x, profile.home.y)]
	return city.buildings.get(id, {})


func door_position() -> Vector3:
	## The front door, on the face toward the road.
	var b := building()
	return door_of(city, b) if not b.is_empty() else Vector3.INF


func spawn_transform() -> Transform3D:
	## Where to put the player outside the front door, facing the street.
	var b := building()
	if b.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3.INF)
	var d: Vector2i = City.DIRS[b.rot]
	var out := Vector3(d.x, 0, d.y)
	var p := door_of(city, b) + out * 1.6
	p.y = city.terrain_height(p.x, p.z) if city.has_method("terrain_height") else 0.0
	return Transform3D(Basis.looking_at(out, Vector3.UP), p)


func label() -> String:
	var b := building()
	return describe(city, b) if not b.is_empty() else "No home yet"


static func is_home_cell(c: City, cell: Vector2i) -> bool:
	if not c.inside(cell.x, cell.y):
		return false
	var id := c.bld[c.idx(cell.x, cell.y)]
	return c.buildings.has(id) and c.buildings[id].zone == City.Zone.RES


static func door_of(c: City, b: Dictionary) -> Vector3:
	var d: Vector2i = City.DIRS[b.rot]
	return c.building_center(b) + Vector3(d.x, 0, d.y) * (b.size * City.TILE * 0.5 - 1.0)


static func describe(c: City, b: Dictionary) -> String:
	## "Apartment tower, 42 Harbor St" style text for menus.
	var kind: String = ["", "House", "Apartments", "Apartment tower"][clampi(b.stage, 0, 3)]
	if b.size == 2:
		kind = "High-rise"
	var streets := ["Harbor", "Elm", "Maple", "Bay", "Union", "Cedar", "Ocean", "Park", "Grand", "Pine"]
	var st: String = streets[(b.x * 7 + b.y * 3) % streets.size()]
	var lv := c.land_value[c.idx(b.x, b.y)] if c.land_value.size() > 0 else 0.0
	var area := "downtown" if lv > 0.6 else ("nice part of town" if lv > 0.35 else "cheap side of town")
	return "%s, %d %s St, %s" % [kind, (b.y * 13 + b.x) % 180 + 2, st, area]


func first_home() -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_id := 1 << 30
	for b in city.buildings.values():
		if b.zone == City.Zone.RES and b.id < best_id:
			best_id = b.id
			best = Vector2i(b.x, b.y)
	return best


func _on_added(id: int, _animate: bool) -> void:
	if not profile.has_home() and auto_move_in:
		var b: Dictionary = city.buildings[id]
		if b.zone == City.Zone.RES:
			move_in(Vector2i(b.x, b.y))


func _on_removed(_id: int) -> void:
	if not profile.has_home():
		return
	# A merge removes four houses and adds the tower in the same call stack, so check after it.
	_check_home.call_deferred()


func _check_home() -> void:
	if profile.has_home() and not is_home_cell(city, profile.home):
		profile.home = Vector2i(-1, -1)
		home_lost.emit()
