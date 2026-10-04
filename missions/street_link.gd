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
var fake_pos := Vector3.ZERO
var fake_car: Object = null
var fake_active := true
var _stub_wanted := 0
var _stub_fade := 0.0


func _init(s: Node = null) -> void:
	street = s
	if s == null:
		return
	for sig in ["wanted_changed", "wasted", "busted", "crime", "goodness_action"]:
		if s.has_signal(sig):
			s.connect(sig, Callable(self, "_relay_" + sig))


func _relay_wanted_changed(stars: int) -> void: wanted_changed.emit(stars)
func _relay_wasted() -> void: wasted.emit()
func _relay_busted() -> void: busted.emit()
func _relay_crime(kind: StringName) -> void: crime.emit(kind)
func _relay_goodness_action(kind: StringName) -> void: goodness_action.emit(kind)


func active() -> bool:
	return street.active if street else fake_active


func position() -> Vector3:
	if street == null:
		return fake_pos
	if street.car:
		return street.car.global_position
	return street.player.global_position


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


func ground_point(p: Vector3) -> Vector3:
	## A sidewalk spot near p, where StreetMode would put a pedestrian.
	if street and street.has_method("sidewalk_spawn"):
		return street.sidewalk_spawn(p)
	return p
