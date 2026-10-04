class_name ProgressLink
extends RefCounted
## The one place missions/ touches the shared Progress autoload (scripts/PROGRESS_INTERFACE.md):
## the Resident's wallet, city funds, goodness, unlocks, flags, counters and quest state.
## Without the autoload (headless tests) it keeps the same values locally.

signal cash_changed(cash: int, delta: int)
signal unlocked(id: String)

var city: City
var store: Node = null  # the Progress autoload, when running in the game
var _cash := 250
var _goodness := 0.0
var _unlocks := {}
var _flags := {}
var _counts := {}
var _quests := {}


func _init(c: City, use_store := true) -> void:
	city = c
	var tree := Engine.get_main_loop() as SceneTree
	if use_store and tree and tree.root.has_node("Progress"):
		store = tree.root.get_node("Progress")
		store.cash_changed.connect(func(v, d, _r): cash_changed.emit(v, d))
		store.unlocked.connect(func(id, _s): unlocked.emit(id))


func cash() -> int:
	return store.cash if store else _cash


func add_cash(n: int, reason := "") -> void:
	if store:
		store.add_cash(n, reason)
	elif n != 0:
		_cash = maxi(0, _cash + n)
		cash_changed.emit(_cash, n)


func add_city_funds(n: float, reason := "") -> void:
	if store:
		store.add_city_funds(n, reason)
	else:
		city.funds += n


func goodness() -> float:
	return store.goodness if store else _goodness


func set_goodness(v: float, reason := "") -> void:
	if store:
		store.set_goodness(v, reason)
	else:
		_goodness = v


func is_unlocked(id: String) -> bool:
	return store.is_unlocked(id) if store else _unlocks.has(id)


func unlock(id: String, source := "") -> void:
	if store:
		store.unlock(id, source)
	elif not _unlocks.has(id):
		_unlocks[id] = source
		unlocked.emit(id)


func lock(id: String) -> void:
	if store:
		store.lock(id)
	else:
		_unlocks.erase(id)


func get_flag(key: String, default: Variant = null) -> Variant:
	return store.get_flag(key, default) if store else _flags.get(key, default)


func set_flag(key: String, value: Variant = true) -> void:
	if store:
		store.set_flag(key, value)
	else:
		_flags[key] = value


func count(key: String, n := 1) -> int:
	if store:
		return store.count(key, n)
	_counts[key] = _counts.get(key, 0) + n
	return _counts[key]


func get_count(key: String) -> int:
	return int((store.counts if store else _counts).get(key, 0))


func quest(id: String) -> Dictionary:
	return (store.quests if store else _quests).get(id, {})


func set_quest(id: String, d: Dictionary) -> void:
	if store:
		store.set_quest(id, d)
	else:
		_quests[id] = d


func population() -> int:
	return city.population


func city_tier() -> int:
	return store.city_tier if store else 0


func stat(key: String, default := 0.0) -> float:
	return float(store.stats.get(key, default)) if store else default


func find_tagged(tag: String) -> Array:
	return city.find_tagged(tag) if city.has_method("find_tagged") else []
