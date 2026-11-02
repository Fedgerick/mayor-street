extends Node
## Autoload "Progress": what the whole game shares (the Resident's cash, goodness, unlock
## flags, milestone tier, city stats, story flags, counters, quests) and save games.
## The contract for other threads is scripts/PROGRESS_INTERFACE.md.
##
## City funds stay in City.funds. Other threads' state is saved through sections: objects
## with to_dict() / from_dict(d) handed to register_section().

signal cash_changed(cash: int, delta: int, reason: String)
signal city_funds_changed(funds: float, delta: float, reason: String)
signal goodness_changed(value: float, delta: float, reason: String)
signal unlocked(id: String, source: String)
signal locked(id: String)
signal tier_reached(tier: int, tier_name: String, ids: Array)
signal stats_changed(stats: Dictionary)
signal flag_changed(key: String, value: Variant)
signal quest_changed(id: String)
signal saved(slot: String)
signal game_started(loaded: bool)
signal notice(text: String)  ## good news for the HUD: milestones, unlocks, saves

const FORMAT := 1
var save_dir := "user://saves/"  # tests point this somewhere else
const AUTOSAVE := "autosave"
const SLOTS := ["slot1", "slot2", "slot3"]
const AUTOSAVE_DAYS := 3

var city: City
var cash := 0
var goodness := 0.0
var unlocks := {}
var city_tier := 0
var stats := {}
var flags := {}
var counts := {}
var quests := {}
var slot := ""
var playing := false          # a game is running (not the title screen)
var autosave_enabled := true  # off for screenshot runs and tests

var _sections := {}  # key -> Object
var _loaded := {}    # sections of the save this game was loaded from, until their owners register
var _pending := {}   # a save read by load_game, waiting for the main scene to restart
var _days := 0
var _was_loaded := false


# ------------------------------------------------------------------- wallets ---

func add_cash(n: int, reason := "") -> void:
	var before := cash
	cash = maxi(0, cash + n)
	if cash != before:
		cash_changed.emit(cash, cash - before, reason)


func spend_cash(n: int, reason := "") -> bool:
	if n < 0 or cash < n:
		return false
	if n > 0:
		cash -= n
		cash_changed.emit(cash, -n, reason)
	return true


func add_city_funds(n: float, reason := "") -> void:
	if city == null or n == 0.0:
		return
	city.funds += n
	city_funds_changed.emit(city.funds, n, reason)


func spend_city_funds(n: float, reason := "") -> bool:
	if city == null or not city.spend(n):
		return false
	city_funds_changed.emit(city.funds, -n, reason)
	return true


func donate(n: int) -> bool:
	## The Resident hands cash to a broke Mayor.
	if n <= 0 or city == null or not spend_cash(n, "donation"):
		return false
	add_city_funds(float(n), "donation")
	count("donated", n)
	notice.emit("You gave $%s to the city" % Catalog.thousands(n))
	return true


# ------------------------------------------------------------------ goodness ---

func add_goodness(delta: float, reason := "") -> void:
	set_goodness(goodness + delta, reason)


func set_goodness(v: float, reason := "") -> void:
	var before := goodness
	goodness = clampf(v, -100.0, 100.0)
	if not is_equal_approx(before, goodness):
		goodness_changed.emit(goodness, goodness - before, reason)


func goodness_tier() -> int:
	## -4 (Kingpin) .. 4 (Hero), one step per 25 points.
	return int(signf(goodness)) * mini(int(absf(goodness) / 25.0), 4)


# ------------------------------------------------------------------- unlocks ---

func unlock(id: String, source := "") -> bool:
	if not _unlock(id, source):
		return false
	var d := Catalog.get_def(id)
	if not d.is_empty() and d.menu:
		notice.emit("Unlocked: %s. It's in the build menu" % d.name)
	return true


func lock(id: String) -> void:
	if unlocks.erase(id):
		locked.emit(id)


func is_unlocked(id: String) -> bool:
	return unlocks.has(id)


func _unlock(id: String, source: String) -> bool:
	if unlocks.has(id):
		return false
	unlocks[id] = source
	unlocked.emit(id, source)
	return true


func reach_tier(t: int) -> void:
	## Unlocks every catalog building up to tier t and announces the milestone.
	t = mini(t, Catalog.TIERS.size() - 1)
	if t <= city_tier:
		return
	var ids := []
	for tt in range(city_tier + 1, t + 1):
		for id in Catalog.ids_for_tier(tt):
			if _unlock(id, "tier:%d" % tt):
				ids.append(id)
	city_tier = t
	var tier_name: String = Catalog.TIERS[t].name
	var n := 0
	for id in ids:
		if Catalog.get_def(id).menu:
			n += 1
	notice.emit("Milestone: %s! %d new buildings in the build menu (B)" % [tier_name, n])
	tier_reached.emit(t, tier_name, ids)


func check_milestones() -> void:
	if city == null:
		return
	var income := float(stats.get("income_per_resident", 0.0))
	var t := city_tier
	while t + 1 < Catalog.TIERS.size() and Catalog.goal_met(t + 1, city.population, income):
		t += 1
	reach_tier(t)
	var pops := Catalog.pop_unlocks()
	for id in pops:
		if city.population >= int(pops[id]) and not unlocks.has(id):
			unlock(id, "pop:%d" % pops[id])


# --------------------------------------------------------------------- stats ---

func set_stats(d: Dictionary) -> void:
	stats.merge(d, true)
	stats_changed.emit(stats)


func _city_stats() -> void:
	if city:
		stats["population"] = city.population
		stats["jobs"] = city.jobs_c + city.jobs_i


# ------------------------------------------------------ flags, counts, quests ---

func set_flag(key: String, value: Variant = true) -> void:
	if flags.has(key) and typeof(flags[key]) == typeof(value) and flags[key] == value:
		return
	flags[key] = value
	flag_changed.emit(key, value)


func get_flag(key: String, default: Variant = null) -> Variant:
	return flags.get(key, default)


func count(key: String, n := 1) -> int:
	counts[key] = int(counts.get(key, 0)) + n
	return counts[key]


func set_quest(id: String, d: Dictionary) -> void:
	quests[id] = d
	quest_changed.emit(id)


func quest_state(id: String) -> String:
	return str(quests.get(id, {}).get("state", ""))


# ------------------------------------------------------------------ sections ---

func register_section(key: String, obj: Object) -> void:
	## obj has to_dict() -> Dictionary and from_dict(d). During a load its saved data is
	## handed back right away.
	_sections[key] = obj
	if _loaded.has(key) and obj.has_method("from_dict"):
		var d = _loaded[key]
		obj.from_dict(d if d is Dictionary else {})


func get_section(key: String) -> Object:
	var o: Object = _sections.get(key)
	return o if is_instance_valid(o) else null


# ------------------------------------------------------------ game lifecycle ---

## Called by main.gd once the city exists: built fresh, or restored from save (the dict
## take_pending_load() returned). Resets everything else to a new game first.
func begin(c: City, save := {}) -> void:
	city = c
	city.progress = self
	_sections.clear()
	cash = 0
	goodness = 0.0
	unlocks = {}
	city_tier = 0
	stats = {}
	flags = {}
	counts = {}
	quests = {}
	_days = 0
	_loaded = {}
	slot = ""
	for id in Catalog.ids_for_tier(0):
		unlocks[id] = "start"
	_was_loaded = not save.is_empty()
	if _was_loaded:
		_core_from_dict(save.get("progress", {}))
		var sec = save.get("sections", {})
		_loaded = sec if sec is Dictionary else {}
		slot = str(save.get("slot", ""))
	_city_stats()
	if not city.day_passed.is_connected(_on_day):
		city.day_passed.connect(_on_day)
	playing = true


## Called by main.gd after every thread's objects are created and registered.
func started() -> void:
	check_milestones()  # a ready-made city (the demo) starts at the tier it has earned
	game_started.emit(_was_loaded)


func _on_day() -> void:
	_city_stats()
	check_milestones()
	stats_changed.emit(stats)
	_days += 1
	if _days % AUTOSAVE_DAYS == 0:
		autosave()


func _core_to_dict() -> Dictionary:
	return {
		"cash": cash, "goodness": goodness, "unlocks": unlocks, "city_tier": city_tier,
		"stats": stats, "flags": flags, "counts": counts, "quests": quests, "days": _days,
	}


func _core_from_dict(d: Dictionary) -> void:
	cash = maxi(0, int(d.get("cash", 0)))
	goodness = clampf(float(d.get("goodness", 0.0)), -100.0, 100.0)
	var u = d.get("unlocks", {})
	if u is Dictionary:
		for k in u:
			unlocks[str(k)] = str(u[k])
	city_tier = clampi(int(d.get("city_tier", 0)), 0, Catalog.TIERS.size() - 1)
	for t in range(1, city_tier + 1):  # buildings added to a tier after the game was saved
		for id in Catalog.ids_for_tier(t):
			if not unlocks.has(id):
				unlocks[id] = "tier:%d" % t
	for key in ["stats", "flags", "quests"]:
		var v = d.get(key, {})
		set(key, v.duplicate(true) if v is Dictionary else {})
	var c = d.get("counts", {})
	if c is Dictionary:
		for k in c:
			counts[str(k)] = int(c[k])
	_days = int(d.get("days", 0))


# --------------------------------------------------------------------- saves ---

func save_game(to_slot := "") -> bool:
	if city == null or not playing:
		return false
	var s := to_slot if to_slot != "" else (slot if slot != "" and slot != AUTOSAVE else SLOTS[0])
	var sections := {}
	for k in _loaded:  # a saved section whose owner isn't in this build stays in the save
		sections[k] = _loaded[k]
	for k in _sections:
		var o: Object = _sections[k]
		if is_instance_valid(o) and o.has_method("to_dict"):
			sections[k] = o.to_dict()
	var data := {
		"format": FORMAT, "version": str(ProjectSettings.get_setting("application/config/version", "")),
		"city": city.to_dict(), "progress": _core_to_dict(), "sections": sections,
	}
	var title := ""
	if sections.get("resident") is Dictionary:
		title = str(sections.resident.get("name", ""))
	var header := {
		"slot": s, "title": title, "saved_at": int(Time.get_unix_time_from_system()),
		"day": city.game_day(), "population": city.population, "cash": cash, "funds": int(city.funds),
		"tier": city_tier, "version": data.version,
	}
	DirAccess.make_dir_recursive_absolute(save_dir)
	var path := save_dir + s + ".json"
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		city.message.emit("Couldn't save the game (%s)" % error_string(FileAccess.get_open_error()))
		return false
	# Line 1 is a small header so the load menu can list saves without reading whole files.
	f.store_line(JSON.stringify(header))
	f.store_string(JSON.stringify(data, "", true, true))
	f.close()
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(path)
		if DirAccess.rename_absolute(tmp, path) != OK:
			city.message.emit("Couldn't save the game")
			return false
	if s != AUTOSAVE:
		slot = s
		notice.emit("Game saved")
	saved.emit(s)
	return true


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		autosave()  # closing the window keeps the game, like Quit to desktop


func autosave() -> bool:
	if not autosave_enabled or not playing:
		return false
	var ok := save_game(AUTOSAVE)
	if ok:
		notice.emit("Autosaved")
	return ok


func load_game(from_slot: String) -> bool:
	## Reads the save, then restarts the main scene, which builds the game from it.
	var data := read_save(from_slot)
	if data.is_empty():
		if city:
			city.message.emit("That save can't be loaded")
		return false
	_pending = data
	playing = false
	get_tree().paused = false
	get_tree().reload_current_scene()
	return true


## The save waiting to be built by main.gd, or {}. Taking it clears it.
func take_pending_load() -> Dictionary:
	var d := _pending
	_pending = {}
	return d


func read_save(from_slot: String) -> Dictionary:
	var path := save_dir + from_slot + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	f.get_line()  # the header
	var body := f.get_buffer(f.get_length() - f.get_position()).get_string_from_utf8()
	var json := JSON.new()  # quiet on a broken file, unlike JSON.parse_string
	if json.parse(body) != OK:
		return {}
	var data = json.data
	if not data is Dictionary or int(data.get("format", 0)) < 1 or int(data.get("format", 0)) > FORMAT:
		return {}
	if not data.get("city") is Dictionary:
		return {}
	data["slot"] = from_slot
	return data


func list_saves() -> Array:
	## Newest first: {slot, title, saved_at, day, population, cash, funds, tier, version}.
	var out := []
	if not DirAccess.dir_exists_absolute(save_dir):
		return out
	for file in DirAccess.get_files_at(save_dir):
		if not file.ends_with(".json"):
			continue
		var f := FileAccess.open(save_dir + file, FileAccess.READ)
		if f == null:
			continue
		var json := JSON.new()
		var h = json.data if json.parse(f.get_line()) == OK else null
		if h is Dictionary:
			h["slot"] = file.get_basename()
			out.append(h)
	out.sort_custom(func(a, b): return float(a.get("saved_at", 0)) > float(b.get("saved_at", 0)))
	return out


func has_save(s: String) -> bool:
	return FileAccess.file_exists(save_dir + s + ".json")


func delete_save(s: String) -> void:
	if has_save(s):
		DirAccess.remove_absolute(save_dir + s + ".json")
