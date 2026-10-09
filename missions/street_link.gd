class_name StreetLink
extends RefCounted
## What missions/ reads from and asks of the street-level player (player/StreetMode).
## Wanted levels, Wasted and Busted are being built by the Street-level player thread;
## until StreetMode has them this keeps a stub wanted level that fades on its own, so
## the bad jobs can already be played end to end.
##
## Tests run without a StreetMode: set `fake_pos` / `fake_car_model` instead.

signal wanted_changed(stars: int)
signal wasted
signal busted
signal crime(kind: StringName)
signal goodness_action(kind: StringName)  # Goodness.ACTIONS kinds, from street action

const STUB_FADE_SECONDS := 9.0  # one stub star fades every this many seconds out of sight

var street: Node = null  # StreetMode
var interiors: Node = null  # InteriorManager (interiors/), when main.gd has one
var fake_pos := Vector3.ZERO
var fake_car: Object = null
var fake_active := true
var fake_damage := 0.0
var _stub_wanted := 0
var _damage := 0.0
var _hooked: Object = null  # the StreetPlayer whose damage is being counted
var _cars := {}             # cars whose damage is hooked up
var _stub_fade := 0.0


func _init(s: Node = null) -> void:
	street = s
	if s == null:
		return
	for sig in ["wanted_changed", "wasted", "busted", "crime", "goodness_action", "vehicle_changed"]:
		if s.has_signal(sig):
			s.connect(sig, Callable(self, "_relay_" + sig))


func _relay_vehicle_changed(c: Object) -> void:
	if c and c.has_signal("damaged") and not _cars.has(c):
		_cars[c] = true
		c.damaged.connect(_on_car_damaged.bind(c))


func _on_car_damaged(amount: float, c: Object) -> void:
	if street and street.car == c:  # only while you're driving it
		_damage += amount / 10.0  # a 1000-health car wrecked counts as 100, like a life


func _on_player_damaged(amount: float, _from: Vector3) -> void:
	_damage += amount


func damage_taken() -> float:
	## Health lost on foot plus car damage, since the game started (medals take the change).
	if street == null:
		return fake_damage
	var p: Object = street.get("player")
	if p and p != _hooked and p.has_signal("damaged"):
		_hooked = p
		p.damaged.connect(_on_player_damaged)
	if street.get("car"):
		_relay_vehicle_changed(street.car)
	return _damage


func _relay_wanted_changed(stars: int) -> void: wanted_changed.emit(stars)
func _relay_wasted() -> void: wasted.emit()
func _relay_busted() -> void: busted.emit()
func _relay_crime(kind: StringName) -> void: crime.emit(kind)
func _relay_goodness_action(kind: StringName) -> void: goodness_action.emit(kind)


func active() -> bool:
	return street.active if street else fake_active


func position() -> Vector3:
	## Where the player is on the map. Rooms load far above the city, so inside a
	## building this is that building's door.
	if street == null:
		return fake_pos
	if inside() != "" and not interiors.current_building.is_empty():
		return interiors.door_transform(interiors.current_building).origin
	if street.car:
		return street.car.global_position
	return street.player.global_position


func inside() -> String:
	## The interior the player is in ("bank", "bunker"...), or "".
	if interiors and interiors.is_inside():
		return interiors.current_id
	return ""


func inside_building() -> int:
	return int(interiors.current_building.get("id", -1)) if inside() != "" else -1


func has_door(b: Dictionary) -> bool:
	## Whether this building can really be walked into.
	return interiors != null and b.has("kind") and not interiors.door_info(String(b.kind)).is_empty()


func near_marker(marker: String, radius: float) -> bool:
	## Inside a room: is the player within radius of one of its markers (e.g. "vault")?
	if street == null or inside() == "" or interiors.current == null:
		return false
	var mk: Node3D = interiors.current.marker(marker)
	if mk == null:
		return false
	var p: Vector3 = street.player.global_position
	return Vector2(p.x - mk.global_position.x, p.z - mk.global_position.z).length() <= radius


func car() -> Object:
	## The car the player is driving, or null on foot.
	return street.car if street else fake_car


func car_speed() -> float:
	var c := car()
	return c.speed() if c and c.has_method("speed") else 0.0


func has_real_wanted() -> bool:
	return street != null and street.has_method("set_wanted")


func wanted() -> int:
	if has_real_wanted():
		return street.wanted
	return _stub_wanted


func set_wanted(stars: int) -> void:
	if has_real_wanted():
		street.set_wanted(stars)
		return
	if stars != _stub_wanted:
		_stub_wanted = clampi(stars, 0, 5)
		_stub_fade = 0.0
		wanted_changed.emit(_stub_wanted)


func tick(delta: float) -> void:
	## Stub stars fade one at a time while driving fast (no cops exist yet to escape).
	if has_real_wanted() or _stub_wanted == 0:
		return
	var rate := 1.0 if car_speed() > 8.0 else 0.35
	_stub_fade += delta * rate
	if _stub_fade >= STUB_FADE_SECONDS:
		_stub_fade = 0.0
		_stub_wanted -= 1
		wanted_changed.emit(_stub_wanted)


func spawn_car(model: String, pos: Vector3, yaw: float, color: Color) -> Object:
	if street and street.has_method("spawn_car"):
		return street.spawn_car(model, pos, yaw, color)
	return null


func damage_player(amount: float, from: Vector3) -> void:
	## A mission enemy hurts the player (in a car, the car takes it).
	if street and street.has_method("damage_player"):
		street.damage_player(amount, from, "crew")
	else:
		fake_damage += amount


func give_weapon(id: StringName, rounds := -1) -> void:
	if street and street.get("combat"):
		street.combat.give(id, rounds)


func set_sanctioned(on: bool) -> void:
	## A good job's fight: the police don't count your gunfire against you.
	if street and "sanctioned" in street:
		street.sanctioned = on


func ground_point(p: Vector3) -> Vector3:
	## A sidewalk spot near p, where StreetMode would put a pedestrian.
	if street and street.has_method("sidewalk_spawn"):
		return street.sidewalk_spawn(p)
	return p
