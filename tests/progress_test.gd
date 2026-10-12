extends SceneTree
## The phase-0 foundation: building catalog, placing catalog buildings, the Progress store,
## milestones and a full save / load round trip.
##   godot --headless --path . --script res://tests/progress_test.gd
## Saves go to user://test_saves/, which the test empties first.

var failures := 0
var P: Node  # the Progress autoload (named through the tree: tests compile before autoloads)


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	P = root.get_node("Progress")
	P.save_dir = "user://test_saves/"
	P.autosave_enabled = false
	if DirAccess.dir_exists_absolute(P.save_dir):
		for f in DirAccess.get_files_at(P.save_dir):
			DirAccess.remove_absolute(P.save_dir + f)
	_catalog()
	_placing()
	_progress_store()
	_save_round_trip()
	print("ALL PASSED" if failures == 0 else "%d FAILED" % failures)
	quit(1 if failures > 0 else 0)


func _catalog() -> void:
	print("Catalog")
	var bad := []
	for id in Catalog.DEFS:
		var d := Catalog.get_def(id)
		if d.name == "" or not d.group in Catalog.GROUPS or int(d.tier) < -1 or int(d.tier) >= Catalog.TIERS.size():
			bad.append(id)
		if not d.placement in ["lot", "street", "line"] or int(d.size) < 0 or int(d.size) > 4:
			bad.append(id)
	check(bad.is_empty(), "every entry is well formed %s" % [bad])
	check(Catalog.ids().size() == Catalog.DEFS.size() - 1, "the menu lists everything but spawned-only buildings")
	check(Catalog.with_tag("bank").has("bank") and Catalog.with_tag("hideout").has("bunker"), "the bank job finds bank and hideout tags")
	check(Catalog.goal_text(2) == "Reach 5,000 people", "goal text: %s" % Catalog.goal_text(2))
	check(Catalog.lock_text("bunker") == "Reach 15,000 people or $52,000 income per resident", "either-or goal: %s" % Catalog.lock_text("bunker"))
	check(Catalog.goal_met(3, 1000, 60000.0) and not Catalog.goal_met(4, 50000, 1000.0), "tier goals: any vs all")
	# The catalog follows the models the art thread built: same names and footprints.
	var art = JSON.parse_string(FileAccess.get_file_as_string("res://art/specials.json"))
	var drift := []
	if art is Dictionary:
		for e in art.get("specials", []):
			if Catalog.has(e.id) and int(e.size) != int(Catalog.get_def(e.id).size):
				drift.append("%s size %d vs %d" % [e.id, e.size, Catalog.get_def(e.id).size])
			if Catalog.has(e.id) and str(e.name) != Catalog.get_def(e.id).name:
				drift.append("%s name %s" % [e.id, e.name])
	check(art is Dictionary and drift.is_empty(), "names and sizes match art/specials.json %s" % [drift])
	var missing := []
	var kit: Node = root.get_node("Kit")
	for id in Catalog.ids():
		var d := Catalog.get_def(id)
		if d.placement != "line" and kit.mesh(kit.special_mesh_name(id, d.size, 0)) == null:
			missing.append(id)
	check(missing.is_empty(), "every building has a model or a stand-in %s" % [missing])
	var models := 0
	for id in Catalog.ids():
		if Catalog.get_def(id).model != "":
			models += 1
	print("       %d of %d menu buildings have their own model" % [models, Catalog.ids().size()])


## A starter city with the avenue along row c.y; returns a free lot cell beside it.
func _lot_beside_road(c: City, size: int, from_x: int) -> Vector2i:
	var y := c.center_cell().y + 1
	for x in range(from_x, City.W - size):
		if c.can_place_special("small_park", Vector2i(x, y), true) == "" \
				and c.can_place_special("police_station", Vector2i(x, y), true) == "":
			var ok := true
			for dy in size:
				for dx in size:
					var i := c.idx(x + dx, y + dy)
					if c.land[i] == 0 or c.road[i] == 1 or c.bld[i] >= 0:
						ok = false
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _placing() -> void:
	print("Placing catalog buildings")
	var c := City.new()
	c.build_starter()
	c.funds = 500000.0
	var cell := _lot_beside_road(c, 1, 10)
	check(cell.x >= 0, "found a lot beside the avenue at %s" % cell)
	var f0 := c.funds
	var added := []
	c.building_added.connect(func(id, _a): added.append(c.buildings[id].get("kind", "")))
	var id := c.place_special("police_station", cell)
	check(id >= 0, "police station placed")
	var b: Dictionary = c.buildings.get(id, {})
	check(b.get("kind") == "police_station" and b.get("name") == "Police Station" and "police" in b.get("tags", []),
		"the entry carries kind, name and tags")
	check(added == ["police_station"], "building_added fires with kind already set")
	check(c.funds == f0 - 4000.0, "it cost $4,000")
	check(b.rot == 2, "it faces the road to the north (rot %d)" % b.rot)
	check(c.zone[c.idx(cell.x, cell.y)] == City.Zone.NONE and c.is_special_cell(c.idx(cell.x, cell.y)), "its tile is unzoned")
	check(c.find_tagged("police").size() == 1 and c.specials_of("police_station").size() == 1, "find_tagged and specials_of")
	check(c.can_place_special("police_station", cell) == "Bulldoze what's there first", "can't stack buildings")
	var far := Vector2i(c.center_cell().x - 6, c.center_cell().y + 6)
	check(c.can_place_special("police_station", far) == "Needs a road alongside", "needs a road alongside")
	check(c.can_place_special("small_park", far) == "", "parks don't need a road")
	var bank_cell := _lot_beside_road(c, 1, cell.x + 2)
	check(c.place_special("bank", bank_cell) >= 0, "bank placed (no progress store: nothing is locked)")
	var bank2 := _lot_beside_road(c, 1, bank_cell.x + 2)
	check(c.can_place_special("bank", bank2) == "The city already has Second National Bank", "only one bank")
	var big := _lot_beside_road(c, 2, bank2.x + 1)
	var pid := c.place_special("police_hq", big)
	check(pid >= 0 and c.bld[c.idx(big.x + 1, big.y + 1)] == pid, "a 2x2 building fills its footprint")
	# Zoning and roads go around catalog buildings.
	c.place_zone(Rect2i(cell.x - 1, cell.y, 3, 2), City.Zone.RES)
	check(c.buildings.has(id), "zoning over it leaves it standing")
	c.place_road(c.road_path(Vector2i(cell.x, cell.y + 1), Vector2i(cell.x, cell.y - 3)))
	check(c.buildings.has(id) and c.road[c.idx(cell.x, cell.y)] == 0, "a road drawn through it skips it")
	# A payphone goes on a road tile, on the sidewalk side that borders a lot.
	var road_cell := Vector2i(cell.x + 1, cell.y - 1)
	check(c.is_road(road_cell.x, road_cell.y), "avenue tile at %s" % road_cell)
	var ph := c.place_special("payphone", road_cell)
	check(ph >= 0 and c.props_at(c.idx(road_cell.x, road_cell.y)) == [ph], "payphone stands on the avenue")
	var at := c.building_center(c.buildings[ph])
	check(absf(at.z - c.cell_center(road_cell.x, road_cell.y).z) > 5.0, "on the sidewalk, not mid-road")
	check(c.can_place_special("payphone", cell) == "It goes on a sidewalk: pick a road", "payphones need a road tile")
	c.bulldoze(Rect2i(road_cell, Vector2i.ONE))
	check(not c.buildings.has(ph), "bulldozing the road takes the payphone")
	# Upkeep and earnings land in the daily books.
	var before := c.funds
	c.last_expense = 0.0
	c._day_tick()
	check(c.last_expense >= 45.0 + 110.0, "daily upkeep includes police ($%d)" % int(c.last_expense))
	check(c.funds != before, "the day's books moved funds")
	c.remove_building(id)
	check(c.find_tagged("police").size() == 1, "removing one leaves the HQ")


func _progress_store() -> void:
	print("Progress store")
	var c := City.new()
	c.build_starter()
	c.funds = 100000.0
	P.begin(c)
	check(P.cash == 0 and P.city_tier == 0 and P.goodness == 0.0, "a new game starts empty")
	check(P.is_unlocked("police_station") and not P.is_unlocked("bank"), "Town buildings are unlocked, the bank isn't")
	var cell := _lot_beside_road(c, 1, 10)
	check(c.can_place_special("bank", cell).ends_with("to unlock it"), "a locked building can't be placed")
	check(c.can_place_special("substation", cell, true) == "", "spawned buildings skip the unlock check")
	var cash_events := []
	P.cash_changed.connect(func(v, d, r): cash_events.append([v, d, r]))
	P.add_cash(500, "start")
	check(not P.spend_cash(600, "car"), "can't spend more than you have")
	check(P.spend_cash(200, "car") and P.cash == 300, "spend cash")
	check(cash_events == [[500, 500, "start"], [300, -200, "car"]], "cash_changed reports value, delta, reason")
	P.add_cash(-1000)
	check(P.cash == 0, "cash never goes below zero")
	P.add_cash(1000)
	var f0: float = c.funds
	check(P.donate(400) and P.cash == 600 and c.funds == f0 + 400.0, "donating moves cash into city funds")
	check(not P.spend_city_funds(1e9) and P.spend_city_funds(100.0) and c.funds == f0 + 300.0, "city wallet")
	P.add_goodness(-60.0, "bank job")
	check(P.goodness == -60.0 and P.goodness_tier() == -2, "goodness -60 is tier -2")
	P.add_goodness(-500.0)
	check(P.goodness == -100.0 and P.goodness_tier() == -4, "goodness stops at -100 (Kingpin)")
	P.set_flag("bunker_upgraded")
	check(P.get_flag("bunker_upgraded") == true and P.get_flag("nope", 7) == 7, "flags")
	check(P.count("banks_robbed") == 1 and P.count("banks_robbed", 2) == 3, "counters")
	P.set_quest("the_bunker", {"state": "active", "step": 1})
	check(P.quest_state("the_bunker") == "active" and P.quest_state("lights_on") == "", "quest state")
	var tiers := []
	P.tier_reached.connect(func(t, n, ids): tiers.append([t, n, ids.size()]))
	c.population = 6000
	P.check_milestones()
	check(P.city_tier == 2 and P.is_unlocked("bank") and P.is_unlocked("payphone"), "6,000 people reach Small city")
	check(tiers.size() == 1 and tiers[0][0] == 2 and tiers[0][1] == "Small city", "one milestone signal for two tiers %s" % [tiers])
	check(not P.is_unlocked("bunker"), "The Bunker waits for tier 3")
	P.set_stats({"income_per_resident": 60000.0})
	P.check_milestones()
	check(P.city_tier == 3 and P.is_unlocked("bunker"), "high income alone reaches City")
	P.unlock("mansion", "goodness:kingpin")
	check(P.unlocks.get("mansion") == "goodness:kingpin", "goodness can unlock a tier-5 building early")
	P.lock("mansion")
	check(not P.is_unlocked("mansion"), "and lose it again")
	check(c.place_special("bank", cell) >= 0, "the bank is placeable once unlocked")


class Section:
	var data := {}
	var loaded := {}
	func to_dict() -> Dictionary:
		return data
	func from_dict(d: Dictionary) -> void:
		loaded = d


func _save_round_trip() -> void:
	print("Save and load")
	var c := City.new()
	c.build_demo(24 * 20)
	P.begin(c)
	c.population = max(c.population, 6000)
	P.check_milestones()
	c._recount()
	var cell := Vector2i(-1, -1)
	# Bulldoze a lot beside a downtown road for the bank.
	for y in range(c.center_cell().y - 8, c.center_cell().y + 8):
		for x in range(c.center_cell().x - 8, c.center_cell().x + 8):
			var i := c.idx(x, y)
			if cell.x < 0 and c.land[i] == 1 and c.road[i] == 0 and c.front_side(Vector2i(x, y), 1) >= 0:
				cell = Vector2i(x, y)
	c.bulldoze(Rect2i(cell, Vector2i.ONE))
	var bank := c.place_special("bank", cell)
	check(bank >= 0, "bank placed downtown")
	c.buildings[bank]["robbed"] = 2  # another thread's key on a building entry
	P.add_cash(1234)
	P.set_goodness(42.5)
	P.set_flag("met_sal", "yes")
	P.count("missions_good", 3)
	P.set_quest("grand_opening", {"state": "done"})
	var sec := Section.new()
	sec.data = {"wanted": 3, "car": "sedan", "list": [1, 2]}
	P.register_section("street", sec)
	c.minutes += 123.5
	var tier: int = P.city_tier
	check(P.save_game("slot2"), "saved to slot 2")
	var saves: Array = P.list_saves()
	check(saves.size() == 1 and saves[0].slot == "slot2" and int(saves[0].population) == c.population,
		"the save list reads the header")
	var data: Dictionary = P.read_save("slot2")
	check(not data.is_empty() and data.slot == "slot2", "read the save back")
	# Rebuild the way main.gd does: a fresh City from the seed, then the saved state.
	var c2 := City.new(int(data.city.seed))
	check(c2.from_dict(data.city), "city restored")
	check(c2.buildings.size() == c.buildings.size() and c2.population == c.population, "same buildings and population (%d)" % c2.population)
	check(c2.road == c.road and c2.zone == c.zone and c2.trees == c.trees and c2.bld == c.bld, "same roads, zones, trees, lots")
	check(c2.funds == c.funds and c2.minutes == c.minutes and c2.tax_rate == c.tax_rate, "same funds and clock")
	var b2: Dictionary = c2.buildings.get(bank, {})
	check(b2.get("kind") == "bank" and b2.get("name") == "Second National Bank" and int(b2.get("robbed", 0)) == 2,
		"the bank keeps its kind, name and other threads' keys")
	check(typeof(b2.x) == TYPE_INT and typeof(b2.variant) == TYPE_INT, "int fields come back as ints")
	check(c2.rng.state == c.rng.state, "the random sequence carries on")
	var diff := ""
	for id in c.buildings:
		var a: Dictionary = c.buildings[id]
		var z: Dictionary = c2.buildings.get(id, {})
		for k in a:
			# Floats may come back one bit off through JSON text (nothing visible), and other
			# threads' numbers come back as floats.
			var num: bool = (a[k] is int or a[k] is float) and z.has(k) and (z[k] is int or z[k] is float)
			var same: bool = is_equal_approx(float(z[k]), float(a[k])) if num \
				else (z.has(k) and typeof(z[k]) == typeof(a[k]) and z[k] == a[k])
			if diff == "" and not same:
				diff = "%d.%s: %s vs %s" % [id, k, a[k], z.get(k)]
	check(diff == "", "every building identical, key by key %s" % diff)
	# Progress comes back through begin(), sections through register_section().
	P.begin(c2, data)
	check(P.cash == 1234 and P.goodness == 42.5 and P.city_tier == tier and tier >= 2, "wallet, goodness and tier restored")
	check(P.get_flag("met_sal") == "yes" and P.counts.get("missions_good") == 3 and typeof(P.counts.missions_good) == TYPE_INT,
		"flags and counters restored")
	check(P.quest_state("grand_opening") == "done" and P.is_unlocked("bank"), "quests and unlocks restored")
	check(P.slot == "slot2", "the game remembers its slot")
	var sec2 := Section.new()
	P.register_section("street", sec2)
	check(int(sec2.loaded.get("wanted", 0)) == 3 and sec2.loaded.get("car") == "sedan", "a section gets its saved data on register")
	var other := Section.new()
	P.register_section("services", other)
	check(other.loaded.is_empty(), "a section the save doesn't have is left alone")
	# Saving again keeps a saved section nobody registered this time.
	P.begin(c2, data)
	check(P.save_game(), "save again to the same slot")
	check(P.read_save("slot2").sections.has("street"), "unclaimed sections survive a re-save")
	check(P.read_save("nope").is_empty(), "a missing save reads as empty")
	var f := FileAccess.open(P.save_dir + "broken.json", FileAccess.WRITE)
	f.store_string("{\"slot\":\"broken\"}\n{not json")
	f.close()
	check(P.read_save("broken").is_empty(), "a broken save is refused, not crashed on")
	P.delete_save("broken")
	check(not P.has_save("broken") and P.has_save("slot2"), "delete a save")
	for file in DirAccess.get_files_at(P.save_dir):
		DirAccess.remove_absolute(P.save_dir + file)
