extends SceneTree
## Look-dev shots of the Mayor's side on the demo city: the title screen with a save to
## continue, the build menu tabs, a building under the cursor, special buildings by day and
## night, blocks gone dark without power, the save panel and the Esc menu. Needs a renderer, so not headless:
##   xvfb-run -a -s "-screen 0 1920x1080x24" godot --rendering-driver vulkan --resolution 1920x1080 \
##       --path . --script res://tests/ui_shots.gd -- --out=/tmp/ui_shots

const SPECIALS := ["bank", "casino", "police_hq", "hospital", "nightclub", "diner", "gas_station",
	"radio_tower", "landmark_tower", "pawn_shop", "fire_station", "plaza", "bunker", "chop_shop"]

var out := "user://ui_shots"
var P: Node


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func shot(name: String) -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join(name + ".png"))
	print("shot ", name)


func wait(sec: float) -> void:
	await create_timer(sec).timeout


func _run() -> void:
	P = root.get_node("Progress")
	P.save_dir = "user://ui_shot_saves/"
	P.autosave_enabled = false
	# A first game, saved, so the title screen has something to continue.
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	main.hud._close_start(true)
	await wait(0.5)
	P.save_game("slot1")
	main.queue_free()
	await process_frame
	await process_frame

	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await wait(2.0)
	await shot("01_title")
	main.hud._close_start(true)
	await wait(1.0)
	var city: City = main.city
	city.minutes = float(city.game_day()) * 1440.0 + 13.0 * 60.0
	main._set_speed(0)
	var m := city.center_cell()
	main.cam.set_view(city.cell_center(m.x, m.y), 300.0, deg_to_rad(-35.0))
	await wait(4.0)
	await shot("02_city")

	# Build menu, a few tabs.
	main._toggle_build_menu()
	await wait(0.3)
	await shot("03_build_power")
	main.hud.build_menu.show_group("business")
	await shot("04_build_business")
	main.hud.build_menu.show_group("landmarks")
	await shot("05_build_landmarks")
	main._toggle_build_menu()

	# The bank in hand over a free downtown lot.
	var lot := _free_lot(city, "bank", m + Vector2i(13, 6))
	main._choose_building("bank")
	main.cam.set_view(city.cell_center(lot.x, lot.y), 190.0, deg_to_rad(-35.0))
	await wait(1.0)
	var ev := InputEventMouseMotion.new()
	ev.position = main.cam.unproject_position(city.cell_center(lot.x, lot.y))
	ev.global_position = ev.position
	Input.parse_input_event(ev)
	await wait(0.3)
	await shot("06_place_bank")
	main._place_building(lot)
	main._set_tool(0)

	# A district of special buildings, day and night.
	var placed: Array[Vector3] = []
	for kind in SPECIALS:
		if kind == "bank":
			continue
		var c := _free_lot(city, kind, m + Vector2i(15, 12))
		if c.x >= 0 and city.place_special(kind, c, -1, true) >= 0:
			var b: Dictionary = city.buildings[city.bld[city.idx(c.x, c.y)]]
			placed.append(city.building_center(b))
	var mid := Vector3.ZERO
	for p in placed:
		mid += p
	mid /= maxf(1.0, placed.size())
	print("placed %d specials around %s" % [placed.size(), mid])
	main.cam.set_view(mid, 210.0, deg_to_rad(-35.0))
	await wait(3.0)
	await shot("07_specials_day")
	main.cam.set_view(mid, 120.0, deg_to_rad(150.0))
	await wait(2.0)
	await shot("08_specials_close")
	city.minutes = float(city.game_day()) * 1440.0 + 21.5 * 60.0
	main.cam.set_view(mid, 210.0, deg_to_rad(-35.0))
	await wait(3.0)
	await shot("09_specials_night")

	# Short of power: the buildings that lose it go dark.
	main.services.supply_scale = 0.35
	main.services._dirty_power = true
	main.services.update()
	main.cam.set_view(city.cell_center(m.x, m.y), 560.0, deg_to_rad(-35.0))
	await wait(3.0)
	await shot("10_no_power_night")
	main.services.supply_scale = 1.0
	main.services._dirty_power = true
	main.services.update()

	# Esc menu and the save panel.
	main.menu.open()
	await wait(0.3)
	await shot("11_esc_menu")
	main.menu._show_saves(true)
	await wait(0.3)
	await shot("12_save_panel")
	main.menu._show_saves(false)
	await wait(0.3)
	await shot("13_load_panel")
	main.menu.close()

	for f in DirAccess.get_files_at(P.save_dir):
		DirAccess.remove_absolute(P.save_dir + f)
	quit(0)


func _free_lot(c: City, kind: String, near: Vector2i) -> Vector2i:
	## The nearest spot where kind fits, bulldozing small buildings (not roads) in the way.
	var s: int = Catalog.get_def(kind).size
	for r in range(0, 26):
		for y in range(near.y - r, near.y + r + 1):
			for x in range(near.x - r, near.x + r + 1):
				if maxi(absi(x - near.x), absi(y - near.y)) != r:
					continue
				var cell := Vector2i(x, y)
				var why := c.can_place_special(kind, cell, true)
				if why == "":
					return cell
				if why == "Bulldoze what's there first" and _only_small(c, cell, s):
					c.bulldoze(Rect2i(cell, Vector2i(s, s)))
					if c.can_place_special(kind, cell, true) == "":
						return cell
	return Vector2i(-1, -1)


func _only_small(c: City, cell: Vector2i, s: int) -> bool:
	for y in range(cell.y, cell.y + s):
		for x in range(cell.x, cell.x + s):
			if not c.inside(x, y):
				return false
			var i := c.idx(x, y)
			if c.road[i] == 1 or c.is_special_cell(i):
				return false
			if c.bld[i] >= 0 and c.buildings[c.bld[i]].size > 1:
				return false
	return true
