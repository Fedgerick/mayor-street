extends SceneTree
## End to end through the real main scene: start the demo city from the title screen, place
## the bank, change both wallets and the camera, save to a slot, load it (the scene restarts)
## and check that the city, Progress and every thread's save section come back. Then saves
## and lists through the Esc menu's save panel.
##   godot --headless --path . --script res://tests/save_load_test.gd
## Exits with code 1 on any failure.

const DIR := "user://test_saves_e2e/"

var fails := 0
var P: Node


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	P = root.get_node("Progress")
	P.save_dir = DIR
	_clear()
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await frames(3)
	check(main.hud.start_panel != null, "title screen first")
	main.hud._close_start(true)  # "Load the demo city"
	await frames(10)
	check(main.started and P.playing, "the demo city starts from the title screen")
	var city: City = main.city
	for k in ["services", "street", "missions", "resident", "mayor"]:
		check(P.get_section(k) != null, "section %s registered" % k)

	# --- Play a little: the bank, both wallets, a flag, the camera ----------------------
	P.unlock("bank", "test")
	city.funds = maxf(city.funds, 60000.0)
	var cell := _lot_for_bank(city)
	check(cell.x >= 0, "a downtown lot beside a road for the bank")
	var bank := city.place_special("bank", cell)
	check(bank >= 0, "bank placed for its price")
	var funds0 := city.funds
	await create_timer(1.3).timeout  # the quest engine looks once a second
	check(P.quest_state("grand_opening") == "done" and is_equal_approx(city.funds, funds0 + 5000.0),
		"the bank finishes Grand Opening, which pays the city $5,000")
	P.add_cash(777, "test")
	P.set_goodness(-30.0, "test")
	P.set_flag("e2e", "yes")
	main.cam.set_view(Vector3(400, 0, 500), 180.0, 0.7)
	main._set_overlay(2)
	main._set_speed(0)  # paused, so the clock in the save is the clock we compare with
	var before_city: Dictionary = city.to_dict()
	var before := {}
	for k in P._sections:
		before[k] = P._sections[k].to_dict()
	check(P.save_game("slot2"), "saved to slot 2")
	var saves: Array = P.list_saves()
	check(saves.size() == 1 and saves[0].slot == "slot2" and int(saves[0].cash) == P.cash,
		"the save list shows it with the Resident's cash")
	var funds_before := city.funds
	var cash_before: int = P.cash

	# Change things after saving, so the load visibly puts them back.
	city.bulldoze(Rect2i(cell, Vector2i.ONE))
	P.add_cash(5000, "test")
	P.set_flag("e2e", "no")

	# --- Load: the scene restarts and builds the game from the save ---------------------
	check(P.load_game("slot2"), "load slot 2")
	await frames(12)
	var main2: Node = current_scene
	check(main2 != null and main2 != main and main2.started, "a fresh game scene runs the save")
	check(not is_instance_valid(main), "the old scene is gone")
	check(main2.hud.start_panel == null, "no title screen when loading")
	var city2: City = main2.city
	var b: Dictionary = city2.buildings.get(bank, {})
	check(b.get("kind") == "bank" and b.get("name") == "Second National Bank", "the bank is back")
	check(city2.specials_of("bank").size() == 1, "only one bank")
	check(is_equal_approx(city2.funds, funds_before), "city funds restored ($%d, saved $%d)" % [int(city2.funds), int(funds_before)])
	check(P.cash == cash_before and is_equal_approx(P.goodness, -30.0) and P.get_flag("e2e") == "yes",
		"cash, goodness and flags restored ($%d)" % P.cash)
	check(P.is_unlocked("bank") and P.slot == "slot2", "unlocks and slot restored")
	check(P.quest_state("grand_opening") == "done", "the finished quest stays finished")
	var c2: Dictionary = city2.to_dict()
	# "connected" is worked out again on load (roads now, power on the next day's tick).
	for e in before_city.buildings + c2.buildings:
		e.erase("connected")
		e.erase("powered")
	var city_diff := _diff(before_city, c2, "city")
	check(city_diff == "", "the city matches the save %s" % city_diff)
	check(main2.speed_index == 0 and main2.overlay == 2, "speed and overlay restored")
	check(main2.cam.focus.distance_to(Vector3(400, 0, 500)) < 0.5 and absf(main2.cam.dist - 180.0) < 0.5,
		"the mayor camera is where it was")
	for k in before:
		var o = P.get_section(k)
		check(o != null, "section %s registered again" % k)
		if o:
			var d := _diff(before[k], o.to_dict(), k)
			check(d == "", "section %s comes back the same %s" % [k, d])
	check(main2.resident.profile.loaded, "the Resident counts as loaded (no creator)")

	# --- Esc menu: save into slot 3, then the load list -----------------------------------
	main2.menu.open()
	await frames(2)
	main2.menu._show_saves(true)
	await frames(2)
	var panel: SavePanel = main2.menu._saves
	check(panel.visible and panel.saving, "the save panel opens from the Esc menu")
	panel._pick("slot3")
	await frames(3)
	check(P.has_save("slot3") and P.slot == "slot3", "saved to slot 3 from the menu")
	main2.menu._show_saves(false)
	await frames(2)
	var listed := 0
	for c in panel._list.get_children():
		if c is Button and not c.is_queued_for_deletion():
			listed += 1
	check(listed == 2, "the load list shows both saves (%d)" % listed)
	main2.menu.close()
	check(P.autosave(), "autosave")
	check(P.has_save("autosave"), "autosave file written")

	_clear()
	print("OK: all passed" if fails == 0 else "FAILED: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)


func _lot_for_bank(c: City) -> Vector2i:
	## A built-up lot beside a road near downtown, bulldozed for the bank.
	var m := c.center_cell()
	for r in range(1, 20):
		for y in range(m.y - r, m.y + r + 1):
			for x in range(m.x - r, m.x + r + 1):
				var i := c.idx(x, y)
				if c.land[i] == 1 and c.road[i] == 0 and not c.is_special_cell(i) \
						and c.front_side(Vector2i(x, y), 1) >= 0:
					if c.bld[i] >= 0 and c.buildings[c.bld[i]].size > 1:
						continue  # keep the towers
					c.bulldoze(Rect2i(Vector2i(x, y), Vector2i.ONE))
					if c.can_place_special("bank", Vector2i(x, y)) == "":
						return Vector2i(x, y)
	return Vector2i(-1, -1)


func _diff(a: Variant, b: Variant, path: String) -> String:
	## "" when the same. Numbers compare within a hair: JSON text can round the last bit,
	## and ints come back as floats.
	var num_a := a is int or a is float
	var num_b := b is int or b is float
	if num_a and num_b:
		return "" if absf(float(a) - float(b)) <= 1e-6 * maxf(1.0, absf(float(a))) else "(%s: %s vs %s)" % [path, a, b]
	if a is Dictionary and b is Dictionary:
		for k in a:
			if not b.has(k):
				return "(%s.%s missing)" % [path, k]
			var d := _diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		for k in b:
			if not a.has(k):
				return "(%s.%s extra)" % [path, k]
		return ""
	if a is Array and b is Array:
		if a.size() != b.size():
			return "(%s: %d items vs %d)" % [path, a.size(), b.size()]
		for i in a.size():
			var d := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if typeof(a) == typeof(b) and a == b:
		return ""
	if (a is String or a is StringName) and (b is String or b is StringName) and str(a) == str(b):
		return ""
	return "(%s: %s vs %s)" % [path, str(a).left(60), str(b).left(60)]


func _clear() -> void:
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR + f)
