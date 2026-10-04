class_name QuestEngine
extends RefCounted
## Quests are data (missions/data/quests.json): a start condition, a list of steps, and a
## reward. A step either waits on city conditions ("until") or on a job ("job"), which the
## matching giver (payphone or radio) hands out before anything random. State lives in
## Progress.quests so it is saved with the game.
##
## Conditions (all keys must hold):
##   population: n            built: tag (a real, placed building)     and_built: tag
##   goodness_at_least: n     goodness_at_most: n                      flag: key
##   quest_done: id           tier: n
##   stat_at_least: {key: n}  stat_below: {key: n}   (Progress.stats, filled by services/)
##   respect_at_least: {contact: n}                   no_flag: key
## A quest with "unless" is dropped while still active once those conditions hold (two
## quests racing for the same tower, the two endings). Story quests ("story": true) carry
## an "act" and a "contact"; a reward may add "respect" {contact: n} and an "ending".

signal quest_started(q: Dictionary)
signal quest_advanced(q: Dictionary)
signal quest_done(q: Dictionary)
signal quest_dropped(q: Dictionary)
signal ending(kind: String)

const PATH := "res://missions/data/quests.json"

var quests: Array = []  # definitions, in file order
var progress: ProgressLink
var goodness: Goodness
var tags: BuildingTags
var contacts: Contacts = null
var templates := {}  # the director's, to say who hands out a quest's job


func _init(p: ProgressLink, g: Goodness, t: BuildingTags, path := PATH) -> void:
	progress = p
	goodness = g
	tags = t
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data == null:
		push_error("missions: can't parse " + path)
		return
	quests = data.quests


func get_def(id: String) -> Dictionary:
	for q in quests:
		if q.id == id:
			return q
	return {}


func state(id: String) -> Dictionary:
	return progress.quest(id)


func is_active(id: String) -> bool:
	return state(id).get("state", "") == "active"


func holds(cond: Dictionary) -> bool:
	for k in cond:
		var v = cond[k]
		match k:
			"population":
				if progress.population() < v: return false
			"built", "and_built":
				if not tags.has_real(v): return false
			"goodness_at_least":
				if goodness.value < v: return false
			"goodness_at_most":
				if goodness.value > v: return false
			"flag":
				if not progress.get_flag(v, false): return false
			"no_flag":
				if progress.get_flag(v, false): return false
			"respect_at_least":
				for c in v:
					if contacts == null or contacts.get_respect(c) < v[c]: return false
			"quest_done":
				if state(v).get("state", "") != "done": return false
			"tier":
				if progress.city_tier() < v: return false
			"stat_at_least":
				for s in v:
					if progress.stat(s, -1.0) < v[s]: return false
			"stat_below":
				for s in v:
					var x := progress.stat(s, -1.0)
					if x < 0.0 or x >= v[s]: return false
			_:
				push_warning("missions: unknown quest condition " + k)
				return false
	return true


func update() -> void:
	## Start quests whose conditions hold and advance city-goal steps. Cheap; call it
	## about once a second and after anything big (a building placed, a day passing).
	for q in quests:
		var st := state(q.id)
		var s: String = st.get("state", "")
		if s == "":
			if holds(q.get("when", {})) and not (q.has("unless") and holds(q.unless)):
				progress.set_quest(q.id, {"state": "active", "step": 0, "done": 0})
				quest_started.emit(q)
				_settle(q)
		elif s == "active":
			if q.has("unless") and holds(q.unless):
				var st2 := st.duplicate()
				st2.state = "dropped"
				progress.set_quest(q.id, st2)
				quest_dropped.emit(q)
				continue
			_settle(q)


func _settle(q: Dictionary) -> void:
	## Advance through every step whose goal already holds.
	while is_active(q.id):
		var st := state(q.id)
		var i := int(st.step)
		if i >= q.steps.size():
			_finish(q)
			return
		var step: Dictionary = q.steps[i]
		if step.has("until") and holds(step.until):
			_next(q)
		else:
			return


func _next(q: Dictionary) -> void:
	var st := state(q.id).duplicate()
	st.step = int(st.step) + 1
	st.done = 0
	progress.set_quest(q.id, st)
	if int(st.step) >= q.steps.size():
		_finish(q)
	else:
		quest_advanced.emit(q)


func _finish(q: Dictionary) -> void:
	var st := state(q.id).duplicate()
	st.state = "done"
	progress.set_quest(q.id, st)
	var r: Dictionary = q.get("reward", {})
	if r.has("cash"): progress.add_cash(int(r.cash), q.title)
	if r.has("funds"): progress.add_city_funds(float(r.funds), q.title)
	if r.has("goodness"): goodness.add(float(r.goodness), q.title)
	if r.has("flag"): progress.set_flag(r.flag, true)
	for u in r.get("unlock", []):
		progress.unlock(u, "quest:" + q.id)
	if contacts:
		for c in r.get("respect", {}):
			contacts.add(c, float(r.respect[c]))
	progress.count("quests_done")
	quest_done.emit(q)
	if r.has("ending"):
		progress.set_flag("ending", r.ending)
		ending.emit(r.ending)


func pending_jobs(giver_templates: Dictionary, giver: String) -> Array:
	## [quest id, template id] for every active quest step waiting on a job from this giver.
	var out: Array = []
	for q in quests:
		if not is_active(q.id):
			continue
		var step := current_step(q)
		if step.has("job") and giver_templates.has(step.job) and giver_templates[step.job].giver == giver:
			out.append([q.id, step.job])
	return out


func current_step(q: Dictionary) -> Dictionary:
	var i := int(state(q.id).get("step", 0))
	return q.steps[i] if i < q.steps.size() else {}


func job_passed(quest_id: String, template_id: String) -> void:
	var q := get_def(quest_id)
	if q.is_empty() or not is_active(quest_id):
		return
	var step := current_step(q)
	if step.get("job", "") != template_id:
		return
	var st := state(quest_id).duplicate()
	st.done = int(st.get("done", 0)) + 1
	progress.set_quest(quest_id, st)
	if st.done >= int(step.get("times", 1)):
		_next(q)
		_settle(q)
	else:
		quest_advanced.emit(q)


func step_text(q: Dictionary) -> String:
	var st := state(q.id)
	if st.get("state", "") == "done":
		return "Done"
	var step := current_step(q)
	var text: String = step.get("text", "")
	return text.replace("{done}", str(int(st.get("done", 0))))


func waiting_on(q: Dictionary) -> String:
	## What the log shows under the step: who will call, or what the city still needs.
	var step := current_step(q)
	if step.has("job"):
		match templates.get(step.job, {}).get("giver", "payphone" if q.role == "bad" else "radio"):
			"payphone": return "Answer a ringing payphone"
			"council": return "Councilwoman Hart will message you. Y takes her job at street level"
		return "Listen to the dispatch radio in any car"
	if step.has("until"):
		var u: Dictionary = step.until
		if u.has("population"):
			return "%d / %d people" % [progress.population(), int(u.population)]
		if u.has("built"):
			return "Mayor: place one from the build menu"
		if u.has("stat_at_least"):
			for s in u.stat_at_least:
				return "%s: %d%% now" % [s.replace("_pct", ""), int(progress.stat(s, 0.0))]
	return ""
