extends SceneTree
## Clicking key hints, the HUD numbers and the RCI demand bars, on the real main scene.
##   godot --headless --path . --fixed-fps 60 --script res://ui/tests/clickable_test.gd
## Works before main.gd wires ClickableUI in: it installs its own when main has none.

var failures := 0
var main: Node3D
var ui: Node


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.skip_creator = true
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	print("Clickable UI tests")
	_unit()
	await _frames(3)
	ui = main.get_node_or_null(^"ClickableUI")
	if ui == null:
		ui = load("res://ui/clickable_ui.gd").install(main)
	await _frames(2)
	var hud = main.hud
	var demo := _find_button(hud.start_panel, "Load the demo city")
	_click_at(demo.get_global_rect().get_center())
	await _frames(5)
	check(main.started, "the demo city starts")
	check(ui.history != null and ui.history.days.size() >= 1, "zone history starts with today")

	# The corner hint: [Esc] Menu opens the menu, a key table row closes it and does its key.
	var row: Node = main.menu._hint_rows[&"mayor"]
	var esc_cap: Label = row.get_child(1).get_child(0)
	check(esc_cap.text == "Esc", "the mayor hint ends with Esc")
	_click_at(esc_cap.get_global_rect().get_center())
	await _frames(3)
	check(main.menu.is_open, "clicking the Esc key cap opens the menu")
	var hl: Label = _help_label(hud)
	_move_to(_segment_pos(hl, "N skip 1 hour"))
	await _frames(1)
	check(ui.find_at(_segment_pos(hl, "N skip 1 hour")).is_empty(), "the HUD under the Esc menu isn't clickable")
	var n_row := _find_label(main.menu._menu, "Skip an hour")
	check(n_row != null, "the Esc menu lists N")
	var before: float = main.city.minutes
	_click_at(n_row.get_global_rect().get_center())
	await _frames(8)
	check(not main.menu.is_open, "a key table row closes the menu")
	check(main.city.minutes > before + 30.0, "and presses its key (N skips an hour)")

	# The help lines: "Space pause · N skip 1 hour", each half its own key.
	before = main.city.minutes
	_click_at(_segment_pos(hl, "N skip 1 hour"))
	await _frames(4)
	check(main.city.minutes > before + 30.0, "clicking 'N skip 1 hour' in the help skips an hour")
	var speed: int = main.speed_index
	_click_at(_segment_pos(hl, "Space pause"))
	await _frames(4)
	check(main.speed_index != speed, "clicking 'Space pause' pauses or restarts time")
	_click_at(hud.lbl_time.get_global_rect().get_center())
	await _frames(4)
	check(main.speed_index == speed, "clicking the clock does the same")
	check(ui.find_at(_segment_pos(hl, "WASD pan")).is_empty(), "WASD in the help isn't a click")

	# RCI demand opens the zone history; Esc closes it without opening the menu.
	_click_at(hud.bars[1].get_global_rect().get_center())
	await _frames(3)
	check(ui.charts.visible and ui.charts.page == 0, "clicking the demand bars opens Zones")
	var snap: Dictionary = ui.history.snapshot()
	var zoned := 0
	for b in main.city.buildings.values():
		if not b.has("kind") and b.size > 0 and b.zone >= 1:
			zoned += 1
	var counted := 0
	for k in ["r", "c", "i"]:
		counted += snap[k][0] + snap[k][1] + snap[k][2]
	check(counted == zoned and zoned > 0, "light, medium and heavy add up to every zone building (%d)" % zoned)
	check(snap.r[0] + snap.r[1] + snap.r[2] > 0, "the demo city has residential buildings")
	_key(KEY_ESCAPE)
	await _frames(2)
	check(not ui.charts.visible and not main.menu.is_open, "Esc closes the chart, not into the menu")
	_click_at(hud.lbl_pop.get_global_rect().get_center())
	await _frames(2)
	check(ui.charts.visible and ui.charts.page == 1, "population opens the People page")
	ui.charts.show_page(2)
	await _frames(2)
	ui.charts.close()
	_click_at(hud.lbl_funds.get_global_rect().get_center())
	await _frames(2)
	check(ui.charts.page == 2, "funds open the Money page")
	ui.charts.close()

	# A day a snapshot; saves keep them.
	var n0: int = ui.history.days.size()
	main.city.simulate_hours(24 * 3)
	check(ui.history.days.size() >= n0 + 2, "each game day adds a snapshot")
	var copy = load("res://ui/city_history.gd").new()
	copy.from_dict(JSON.parse_string(JSON.stringify(ui.history.to_dict())))
	check(copy.days.size() == ui.history.days.size() and copy.days[-1].r == ui.history.days[-1].r,
		"history survives a save as JSON")
	copy.free()
	ui.charts.open(0)
	await _frames(2)
	ui.charts.close()

	# City services lines switch their overlay.
	var sp = main.services_panel
	if sp:
		var power: Label = sp.lines.power
		_click_at(power.get_global_rect().get_center())
		await _frames(2)
		check(sp.buttons[0].button_pressed, "clicking the Power line turns on the power overlay")

	print("Clickable UI tests: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures else 0)


func _unit() -> void:
	var kc = load("res://ui/key_click.gd")
	check(kc.key_of("Tab") == KEY_TAB and kc.key_of("Esc") == KEY_ESCAPE, "Tab and Esc read as keys")
	check(kc.key_of("7 / B") == KEY_7 and kc.key_of("E or F") == KEY_E, "'7 / B' and 'E or F' take the first")
	check(kc.key_of("Space  ,  .") == KEY_SPACE and kc.key_of("F11") == KEY_F11, "Space and F11")
	check(kc.key_of("WASD") == KEY_NONE and kc.key_of("W S") == KEY_NONE and kc.key_of("1 to 6") == KEY_NONE,
		"held keys and ranges aren't clicks")
	check(kc.key_of("Click / right-click") == KEY_NONE and kc.key_of("Shift / Space") == KEY_NONE, "mouse and Shift aren't")
	var segs: Array = kc.parse_line("Space pause · N skip 1 hour", true)
	check(segs.size() == 2 and segs[0].key == KEY_SPACE and segs[1].key == KEY_N, "help line splits into two keys")
	check(kc.parse_line("Space pause", false).is_empty(), "strict lines need two spaces after the key")
	check(kc.parse_line("E  get in", false).size() == 1, "'E  get in' is a hint")


func _help_label(hud) -> Label:
	for c in hud.info.get_parent().get_children():
		if c is Label and c.text.contains(" · "):
			return c
	return null


## The screen point over a part of a label's text.
func _segment_pos(l: Label, part: String) -> Vector2:
	var font := l.get_theme_font(&"font")
	var fs := l.get_theme_font_size(&"font_size")
	var lines := l.text.split("\n")
	var lh := font.get_height(fs) + l.get_theme_constant(&"line_spacing")
	var sb := l.get_theme_stylebox(&"normal")
	var ml := sb.get_margin(SIDE_LEFT) if sb else 0.0
	var mt := sb.get_margin(SIDE_TOP) if sb else 0.0
	for i in lines.size():
		var at := lines[i].find(part)
		if at >= 0:
			var x := font.get_string_size(lines[i].substr(0, at), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			return l.get_global_position() + Vector2(ml + x + 12.0, mt + lh * (i + 0.5))
	return Vector2(-1, -1)


func _find_label(n: Node, text: String) -> Label:
	if n is Label and (n as Label).text == text:
		return n
	for c in n.get_children():
		var f := _find_label(c, text)
		if f:
			return f
	return null


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var f := _find_button(c, text)
		if f:
			return f
	return null


func _move_to(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	root.push_input(m, true)


func _click_at(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = p
	m.global_position = p
	root.push_input(m, true)
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		e.pressed = pressed
		e.position = p
		e.global_position = p
		root.push_input(e, true)


func _key(k: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = pressed
		root.push_input(e)


func _frames(n: int) -> void:
	for i in n:
		await process_frame
