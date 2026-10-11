extends SceneTree
## Remapping in the real main scene: a remapped key or pad button must do what its new
## control does, and the old one must do nothing.
##   godot --headless --path . --fixed-fps 60 --script res://controller/tests/remap_scene_test.gd

var failures := 0
var main: Node3D
var pad: PadControls


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
	print("Remap scene tests")
	await _frames(5)
	pad = main.get("pad") if main.get("pad") else null
	if pad == null:
		pad = PadControls.new()
		main.add_child(pad)
		pad.setup(main)
	pad.set_process(true)
	await _frames(2)
	var hud = main.hud
	var binds := pad.binds
	binds.reset()

	# Start the demo city with the pad, as a player would.
	_press(JOY_BUTTON_A)
	await _frames(2)
	var demo := _find_button(hud.start_panel, "Load the demo city")
	pad.move_cursor(Vector2(5, 5))
	for i in 12:
		if demo and demo.get_global_rect().has_point(pad.cursor):
			break
		_press(JOY_BUTTON_DPAD_DOWN)
		await _frames(1)
	if demo:
		_press(JOY_BUTTON_A)
	check(await _until(func(): return main.started, 60), "the demo city starts")
	await _frames(3)

	# Keyboard: B is moved to the overlay key and O takes the build menu.
	binds.set_key(&"mayor", &"build", KEY_O)
	pad.save_settings()
	_key(KEY_B)
	await _frames(2)
	check(not hud.build_menu.visible, "B no longer opens the build menu")
	_key(KEY_O)
	await _frames(2)
	check(hud.build_menu.visible, "O opens the build menu after the remap")
	_key(KEY_ESCAPE)
	await _frames(2)
	binds.reset()
	pad.save_settings()

	# Pad: the X button is moved onto Y, so the physical Y opens the build menu.
	binds.set_pad(JOY_BUTTON_X, JOY_BUTTON_Y)
	await _frames(1)
	_press(JOY_BUTTON_Y)
	await _frames(2)
	check(hud.build_menu.visible, "the Y button opens the build menu after the remap")
	_press(JOY_BUTTON_B)
	await _frames(2)
	_press(JOY_BUTTON_X)
	await _frames(2)
	check(not hud.build_menu.visible, "the X button no longer opens it")
	binds.reset()
	binds.apply_input_map()

	# The controls screen opens from the layout card and comes back to it.
	pad.hud.open_card()
	pad.hud.open_remap()
	await _frames(2)
	check(pad.hud.remap_open() and not pad.hud.card_open(), "Change buttons and keys opens the controls screen")
	pad.hud.remap.close()
	await _frames(1)
	check(not pad.hud.remap_open() and pad.hud.card_open(), "closing the screen brings the layout card back")
	pad.hud.close_card()

	print("FAILED %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)


func _key(k: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = down
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _press(b: JoyButton) -> void:
	for down in [true, false]:
		var e := InputEventJoypadButton.new()
		e.button_index = b
		e.pressed = down
		e.device = 0
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _until(cond: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await process_frame
	return false


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var f := _find_button(c, text)
		if f:
			return f
	return null
