class_name Wanted
extends Node
## Wanted level, 0 to 5 stars, GTA style. Crimes add heat; heat crossing a threshold
## raises the stars. Stars only fade while no police report seeing the player.
##
## Police (citylife/) read `level`, `last_known_pos`, `wanted_changed` and
## `crime_committed`, and call `report_seen()` while an officer has line of sight.

signal wanted_changed(level: int)
signal crime_committed(kind: StringName, pos: Vector3, severity: int)
signal escaped   # the last star faded out: the player lost the police

const MAX_LEVEL := 5
const HEAT_FOR := [0.0, 1.0, 3.0, 6.0, 10.0, 15.0]   # heat needed for each star
const FADE_PER_STAR := 10.0     # seconds unseen to drop one star
const SEEN_GRACE := 1.0         # a report keeps the player "seen" this long
# kind: [heat, severity]
const CRIMES := {
	&"shots_fired": [0.5, 1],
	&"assault": [1.0, 1],
	&"car_theft": [0.6, 1],
	&"carjack": [1.0, 1],
	&"vehicle_damage": [0.4, 1],
	&"murder": [3.0, 2],
	&"cop_assault": [3.0, 3],
	&"cop_killed": [5.0, 4],
	&"evading": [0.0, 1],
}

var level := 0
var heat := 0.0
var last_known_pos := Vector3.ZERO
var witnessed_radius := 45.0     # crimes with nobody around count for half
var _unseen := 0.0
var _seen_timer := 0.0
var _witness_check: Callable      # (pos) -> bool, set by StreetMode


func commit(kind: StringName, pos: Vector3) -> void:
	var c: Array = CRIMES.get(kind, [1.0, 1])
	var h: float = c[0]
	if _witness_check.is_valid() and not _witness_check.call(pos) and level == 0:
		h *= 0.5
	heat += h
	last_known_pos = pos
	crime_committed.emit(kind, pos, c[1])
	var want := level
	while want < MAX_LEVEL and heat >= HEAT_FOR[want + 1]:
		want += 1
	# A cop killing always means at least 3 stars; murder at least 2.
	if kind == &"cop_killed":
		want = maxi(want, mini(level + 1, MAX_LEVEL))
		want = maxi(want, 3)
	elif kind == &"murder" or kind == &"cop_assault":
		want = maxi(want, 2)
	_set_level(want)
	_unseen = 0.0


func report_seen(_officer_pos: Vector3 = Vector3.ZERO, player_pos: Variant = null) -> void:
	## Police call this while they can see the player.
	_seen_timer = SEEN_GRACE
	_unseen = 0.0
	if player_pos != null:
		last_known_pos = player_pos


func is_seen() -> bool:
	return _seen_timer > 0.0


func set_level(n: int) -> void:
	## For missions (a bank job starts at 3 stars) and cheats.
	n = clampi(n, 0, MAX_LEVEL)
	heat = HEAT_FOR[n]
	_set_level(n)
	_unseen = 0.0


func clear() -> void:
	heat = 0.0
	_unseen = 0.0
	_set_level(0)


func _set_level(n: int) -> void:
	if n == level:
		return
	level = n
	wanted_changed.emit(level)


func _process(delta: float) -> void:
	_seen_timer = maxf(_seen_timer - delta, 0.0)
	if level == 0:
		heat = maxf(heat - delta * 0.1, 0.0)   # small stuff is forgotten
		return
	if _seen_timer > 0.0:
		return
	_unseen += delta
	if _unseen >= FADE_PER_STAR:
		_unseen = 0.0
		var n := level - 1
		heat = HEAT_FOR[n]
		_set_level(n)
		if n == 0:
			escaped.emit()


func fade_progress() -> float:
	## 0..1 toward losing the next star (for a flashing HUD).
	return 0.0 if level == 0 or _seen_timer > 0.0 else _unseen / FADE_PER_STAR
