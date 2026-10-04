class_name Medals
extends RefCounted
## Bronze, silver and gold for story jobs, by time and damage, and the list of passed story
## jobs the quest log offers to replay.
##   gold    within 60% of par and under 15 damage
##   silver  within 85% of par and under 45 damage
##   bronze  passed
## Par is the job's time limit, else the template's "par" (seconds), else 120. Damage is
## health lost (0-100 a life) plus car damage scaled the same way (a wrecked car is 100).

const NAMES := ["", "Bronze", "Silver", "Gold"]
const COLORS := [Color.WHITE, Color(0.8, 0.5, 0.25), Color(0.78, 0.8, 0.85), Color(1.0, 0.82, 0.2)]
const GOLD := [0.6, 15.0]
const SILVER := [0.85, 45.0]

var best := {}  # template id -> {medal, time, damage, title}
var order: Array = []  # template ids, in the order first passed


static func par_of(m: Mission) -> float:
	if m.time_limit > 0.0:
		return m.time_limit
	return float(m.template.get("par", 120.0))


static func grade(elapsed: float, par: float, damage: float) -> int:
	var r := elapsed / maxf(par, 1.0)
	if r <= GOLD[0] and damage < GOLD[1]:
		return 3
	if r <= SILVER[0] and damage < SILVER[1]:
		return 2
	return 1


func record(m: Mission) -> int:
	## Grades a passed job and keeps it if it beats the best; returns the medal (1-3).
	var g := grade(m.elapsed, par_of(m), m.damage)
	var old: Dictionary = best.get(m.id, {})
	if old.is_empty():
		order.append(m.id)
	if old.is_empty() or g > int(old.medal) or (g == int(old.medal) and m.elapsed < float(old.time)):
		best[m.id] = {"medal": g, "time": snappedf(m.elapsed, 0.1), "damage": roundf(m.damage), "title": m.title}
	return g


func medal(id: String) -> int:
	return int(best.get(id, {}).get("medal", 0))


func replays() -> Array:
	## [template id, entry] for every story job passed, oldest first.
	var out: Array = []
	for id in order:
		out.append([id, best[id]])
	return out


func to_dict() -> Dictionary:
	return {"best": best.duplicate(true), "order": order.duplicate()}


func from_dict(d: Dictionary) -> void:
	best = d.get("best", {}).duplicate(true)
	order = d.get("order", []).duplicate()
	for id in best:
		if not id in order:
			order.append(id)
