class_name Goodness
extends RefCounted
## The goodness scale: -100 (Kingpin) to +100 (Hero). Good jobs push it up, bad jobs and
## street crime push it down, and it drifts back toward zero a little every game day so
## the player has to keep choosing a side. Crossing 25 / 50 / 75 / 100 on either side
## turns a perk on; dropping back turns it off. See design/round-2-plan.md section 6.

signal changed(value: float, delta: float, reason: String)
signal perk_gained(perk: StringName, text: String)
signal perk_lost(perk: StringName, text: String)

const MIN := -100.0
const MAX := 100.0
const DRIFT_PER_DAY := 1.5

## [threshold, perk id, short text]; negative thresholds are the bad side.
const PERKS := [
	[25, &"shop_discount", "Shops give you 15% off and people tip you for help"],
	[50, &"minor_crimes_ignored", "Cops ignore minor crimes; free hospital respawn"],
	[75, &"emergency_vehicles", "Drive emergency vehicles any time; the city pays you a stipend"],
	[100, &"hero", "HERO: top hero jobs and a statue in the city park"],
	[-25, &"black_market", "Black market phone: buy weapons and lock picks anywhere"],
	[-50, &"chop_double", "Chop shops pay double; cops lose your trail faster"],
	[-75, &"crew_backup", "Crew backup: call a getaway car during jobs"],
	[-100, &"kingpin", "KINGPIN: top crime jobs and the mansion hideout"],
]

## Free-roam actions (signals from the street player) and how far they move the scale.
const ACTIONS := {
	&"steal_car": -2.0, &"hit_person": -1.5, &"kill_person": -6.0, &"flee_police": -1.0,
	&"hit_cop": -4.0, &"stop_mugging": 3.0, &"ambulance_save": 2.0, &"return_cash": 5.0,
}

var value := 0.0


func add(delta: float, reason := "") -> void:
	var before := perks()
	var old := value
	value = clampf(value + delta, MIN, MAX)
	if is_equal_approx(old, value):
		return
	changed.emit(value, value - old, reason)
	var after := perks()
	for p in PERKS:
		var had: bool = p[1] in before
		var has: bool = p[1] in after
		if has and not had:
			perk_gained.emit(p[1], p[2])
		elif had and not has:
			perk_lost.emit(p[1], p[2])


func action(kind: StringName) -> void:
	if ACTIONS.has(kind):
		add(ACTIONS[kind], String(kind).replace("_", " "))


func day_passed() -> void:
	## Drift toward zero. Drifting back over a perk line costs the perk, on purpose.
	if absf(value) <= DRIFT_PER_DAY:
		add(-value, "time")
	else:
		add(-signf(value) * DRIFT_PER_DAY, "time")


func perks() -> Array[StringName]:
	var out: Array[StringName] = []
	for p in PERKS:
		var t: int = p[0]
		if (t > 0 and value >= t) or (t < 0 and value <= t):
			out.append(p[1])
	return out


func has_perk(id: StringName) -> bool:
	return id in perks()


func title() -> String:
	if value >= 100: return "Hero"
	if value >= 75: return "Guardian"
	if value >= 50: return "Upstanding"
	if value >= 25: return "Good neighbor"
	if value > -25: return "Nobody special"
	if value > -50: return "Hustler"
	if value > -75: return "Gangster"
	if value > -100: return "Crime boss"
	return "Kingpin"


func pay_multiplier(side: String) -> float:
	## Further along a side, that side's jobs pay better.
	var lean := value / MAX if side == "good" else -value / MAX
	return 1.0 + clampf(lean, 0.0, 1.0) * 0.5


func next_line(side: String) -> int:
	## The next perk threshold on that side, or 0 when the end is reached.
	for t in [25, 50, 75, 100]:
		if side == "good" and value < t:
			return t
		if side == "bad" and value > -t:
			return -t
	return 0
