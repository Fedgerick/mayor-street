extends SceneTree
## The keys that must always work, on the real main scene, driven the way a player does it:
## click the title button and some HUD buttons, then press Tab, Space and Esc.
##   godot --headless --path . --fixed-fps 60 --script res://tests/input_test.gd
## Regression: a clicked HUD button used to keep the keyboard, so Tab only moved focus.

var failures := 0
var main: Node3D


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	print("Input tests")
	await _frames(5)
	var hud: Hud = main.hud
	var demo := _find_button(hud.start_panel, "Load the demo city")
	check(demo != null, "title screen offers the demo city")
	check(_find_button(hud.start_panel, "Quit") != null, "title screen has a Quit button")
	_click(demo)
	await _frames(5)
	check(main.started, "the title button starts the demo city")
	check(main.menu._hint_kind == &"mayor", "mayor view shows the key hint")

	# Click HUD buttons the way a player does, then use the keyboard.
	_click(hud.quality_buttons[0])
	_click(hud.speed_buttons[2])
	await _frames(2)
	check(main.speed_index == 2, "speed buttons still work by mouse")
	check(root.gui_get_focus_owner() == null, "clicked HUD buttons don't keep the keyboard")
	_key(KEY_SPACE)
	await _frames(1)
	check(main.speed_index == 0, "Space pauses time after clicking a speed button")
	_key(KEY_SPACE)

	# Even with a focused button, Tab is read before the HUD and reaches the game.
	var b: Button = hud.tool_buttons[1]
	b.focus_mode = Control.FOCUS_ALL
	b.grab_focus()
	_key(KEY_TAB)
	await _frames(1)
	check(main.in_street(), "Tab dives to the street even while a HUD button has focus")
	b.focus_mode = Control.FOCUS_NONE
	check(await _until(func(): return main.street.active, 900), "the dive lands on the street")
	check(main.menu._hint_kind == &"foot", "street hint shows on foot")

	# Esc pauses with the menu; Tab inside the menu stays in the menu.
	_key(KEY_ESCAPE)
	await _frames(1)
	check(main.menu.is_open and paused, "Esc on the street opens the menu and pauses")
	check(root.gui_get_focus_owner() == main.menu._resume, "the menu puts keyboard focus on Resume")
	_key(KEY_TAB)
	await _frames(2)
	check(main.street.active and not main.street.busy, "Tab while paused doesn't leave the street")
	_key(KEY_ESCAPE)
	await _frames(1)
	check(not main.menu.is_open and not paused, "Esc again resumes")
	check(root.gui_get_focus_owner() == null, "closing the menu frees the keyboard")

	_key(KEY_TAB)
	check(await _until(func(): return not main.in_street(), 900), "Tab flies back to the mayor view")
	check(hud.visible and main.menu._hint_kind == &"mayor", "mayor HUD and hint are back")

	# Esc drops a build tool first, then opens the menu; the mouse can resume.
	_key(KEY_2)
	await _frames(1)
	check(main.tool == 1, "2 picks the road tool")
	_key(KEY_ESCAPE)
	await _frames(1)
	check(main.tool == 0 and not main.menu.is_open, "Esc drops the road tool first")
	_key(KEY_ESCAPE)
	await _frames(1)
	check(main.menu.is_open, "a second Esc opens the menu")
	_click(main.menu._resume)
	await _frames(1)
	check(not main.menu.is_open and not paused, "clicking Resume closes the menu")

	_key(KEY_TAB, true)
	await _frames(1)
	check(not main.in_street(), "Alt+Tab is left to the system")
	print("FAILED %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var f := _find_button(c, text)
		if f:
			return f
	return null


func _click(c: Control) -> void:
	var p := c.get_global_rect().get_center()
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


func _key(k: Key, alt := false) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.alt_pressed = alt
		e.pressed = pressed
		root.push_input(e)
