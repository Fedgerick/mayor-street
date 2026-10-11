class_name CityHistory
extends Node
## One snapshot of the city per game day, for the City history charts (CityCharts): how
## many residential, commercial and industrial buildings stand at each growth stage
## (light, medium, heavy), population, jobs and money. Saved in the "city_history" section.
##
## Stage 1 is light, 2 medium, 3 heavy; the 2x2 towers count as heavy. Catalog buildings
## (services and specials) are left out: they have their own place in the build menu.

const MAX_DAYS := 400  # past this the older half is thinned to every other day
const STAGES := ["Light", "Medium", "Heavy"]

var city: City
var days: Array[Dictionary] = []


func setup(c: City) -> void:
	city = c
	if not city.day_passed.is_connected(record):
		city.day_passed.connect(record)
	if days.is_empty():
		record()  # a new game, or a save from before the history: start from today


## The city as it stands now, in the shape saved for each day.
func snapshot() -> Dictionary:
	var z := [[0, 0, 0], [0, 0, 0], [0, 0, 0]]  # [zone - 1][stage - 1]
	for b in city.buildings.values():
		if b.has("kind") or b.size == 0:
			continue
		var zi: int = int(b.zone) - 1
		if zi < 0 or zi > 2:
			continue
		var st := 2 if b.size == 2 else clampi(int(b.stage), 1, 3) - 1
		z[zi][st] += 1
	return {
		"day": city.game_day(), "r": z[0], "c": z[1], "i": z[2],
		"pop": city.population, "jc": city.jobs_c, "ji": city.jobs_i,
		"funds": roundi(city.funds), "inc": roundi(city.last_income), "exp": roundi(city.last_expense),
	}


func record() -> void:
	var s := snapshot()
	if not days.is_empty() and int(days[-1].day) == int(s.day):
		days[-1] = s  # the same day again (a load, or N skipping hours): keep the newest
	else:
		days.append(s)
	if days.size() > MAX_DAYS:
		_thin()


## Every saved day plus today as it stands, oldest first.
func series() -> Array[Dictionary]:
	var out: Array[Dictionary] = days.duplicate()
	var now := snapshot()
	if out.is_empty() or int(out[-1].day) != int(now.day):
		out.append(now)
	else:
		out[-1] = now
	return out


func _thin() -> void:
	var half := days.size() / 2
	var kept: Array[Dictionary] = []
	for k in days.size():
		if k >= half or k % 2 == 0:
			kept.append(days[k])
	days = kept


func to_dict() -> Dictionary:
	return {"days": days}


func from_dict(d: Dictionary) -> void:
	days.clear()
	var arr = d.get("days", [])
	if not arr is Array:
		return
	for e in arr:
		if not e is Dictionary:
			continue
		var s := {"day": int(e.get("day", 0))}
		for k in ["r", "c", "i"]:
			var v = e.get(k, [])
			s[k] = [int(v[0]), int(v[1]), int(v[2])] if v is Array and v.size() >= 3 else [0, 0, 0]
		for k in ["pop", "jc", "ji", "funds", "inc", "exp"]:
			s[k] = int(e.get(k, 0))
		days.append(s)
