class_name Contacts
extends RefCounted
## The three people who hand out work, each with a respect meter (0 to 100) next to the
## goodness scale, like the gangs in GTA 2:
##   marchetti  Vinnie Marchetti, the crime boss: payphone jobs
##   ruiz       Captain Ruiz of the police: dispatch radio jobs
##   hart       Councilwoman Hart at City Hall: council jobs, messaged to the mayor view
## A passed job earns its contact respect (template "respect", 3 by default) and costs the
## rival half as much; Marchetti and Ruiz are rivals, Hart has none. Templates gate harder
## work with "needs_respect", and story quests with "respect_at_least".

signal changed(contact: String, value: float, delta: float)
signal rank_changed(contact: String, rank: String, up: bool)

const PEOPLE := {
	"marchetti": {"name": "Vinnie Marchetti", "short": "Marchetti", "giver": "payphone", "rival": "ruiz",
		"color": Color(0.95, 0.35, 0.3)},
	"ruiz": {"name": "Captain Ruiz", "short": "Ruiz", "giver": "radio", "rival": "marchetti",
		"color": Color(0.35, 0.65, 1.0)},
	"hart": {"name": "Councilwoman Hart", "short": "Hart", "giver": "council", "rival": "",
		"color": Color(0.55, 0.9, 0.55)},
}
const ORDER := ["marchetti", "ruiz", "hart"]
const START := 10.0
const DEFAULT_GAIN := 3.0
const RIVAL_SHARE := 0.5
## [respect at least, rank]
const RANKS := [[0.0, "Nobody"], [20.0, "Known face"], [40.0, "Trusted"], [70.0, "Inner circle"]]

var respect := {}


func _init() -> void:
	for c in ORDER:
		respect[c] = START


static func of_template(t: Dictionary) -> String:
	## Who a job is for: the template's "contact", else whoever uses its giver.
	if t.has("contact"):
		return t.contact
	for c in PEOPLE:
		if PEOPLE[c].giver == t.get("giver", ""):
			return c
	return ""


static func display_name(c: String) -> String:
	return PEOPLE[c].name if PEOPLE.has(c) else ""


func get_respect(c: String) -> float:
	return respect.get(c, 0.0)


func rank(c: String) -> String:
	return rank_for(get_respect(c))


static func rank_for(v: float) -> String:
	var out: String = RANKS[0][1]
	for r in RANKS:
		if v >= r[0]:
			out = r[1]
	return out


func add(c: String, amount: float) -> void:
	if not respect.has(c) or amount == 0.0:
		return
	var before: float = respect[c]
	var old_rank := rank(c)
	respect[c] = clampf(before + amount, 0.0, 100.0)
	var d: float = respect[c] - before
	if d != 0.0:
		changed.emit(c, respect[c], d)
	var new_rank := rank(c)
	if new_rank != old_rank:
		rank_changed.emit(c, new_rank, d > 0.0)


func earn(c: String, amount: float) -> Dictionary:
	## A job done for c: c gains, the rival loses half. Returns {contact: change}.
	var out := {}
	if not respect.has(c):
		return out
	var before := get_respect(c)
	add(c, amount)
	out[c] = get_respect(c) - before
	var rival: String = PEOPLE[c].rival
	if rival != "" and amount > 0.0:
		var rb := get_respect(rival)
		add(rival, -amount * RIVAL_SHARE)
		out[rival] = get_respect(rival) - rb
	return out


func job_gain(t: Dictionary, story: bool) -> float:
	return float(t.get("respect", 8.0 if story else DEFAULT_GAIN))


func allows(t: Dictionary) -> bool:
	## Whether the contact respects you enough for this template.
	return get_respect(of_template(t)) >= float(t.get("needs_respect", 0.0))


static func change_text(changes: Dictionary) -> String:
	## "Marchetti +3  Ruiz -1.5" for the pass banner.
	var parts: Array[String] = []
	for c in ORDER:
		if changes.has(c) and absf(changes[c]) >= 0.05:
			var v: float = changes[c]
			parts.append("%s %s" % [PEOPLE[c].short, ("%+d" % int(round(v))) if is_equal_approx(v, round(v)) else ("%+.1f" % v)])
	return "  ".join(parts)


func to_dict() -> Dictionary:
	return respect.duplicate()


func from_dict(d: Dictionary) -> void:
	for c in ORDER:
		respect[c] = clampf(float(d.get(c, START)), 0.0, 100.0)
