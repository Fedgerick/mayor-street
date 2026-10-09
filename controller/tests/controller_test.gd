extends SceneTree
## Gamepad controls on the real main scene: pad presses go in the way Windows delivers them
## (Input.parse_input_event), and the game must react as it does to keys and clicks.
##   godot --headless --path . --fixed-fps 60 --script res://controller/tests/controller_test.gd
## Sticks can't be faked headless (Godot reads axes from the driver), so the pointer is moved
## with PadControls.move_cursor, which is what the left stick calls.

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
	print("Controller tests")
	_glyph_checks()
	await _frames(5)
	pad = main.get("pad") if main.get("pad") else null
	if pad == null:  # until main.gd wires it in
		pad = PadControls.new()
		main.add_child(pad)
		pad.setup(main)
	pad.set_process(true)  # no real pad headless; the tests press for it
	await _frames(2)
	var hud = main.hud

	# Title screen: d-pad jumps the pointer to a button, A clicks it.
	_button(JOY_BUTTON_A, true)
	_button(JOY_BUTTON_A, false)
	await _frames(1)
	check(pad.using_pad, "a pad press switches the prompts to the pad")
	var demo := _find_button(hud.start_panel, "Load the demo city")
	pad.move_cursor(Vector2(5, 5))
	for i in 12:
		if demo.get_global_rect().has_point(pad.cursor):
			break
		_press(JOY_BUTTON_DPAD_DOWN)
		await _frames(1)
	check(demo.get_global_rect().has_point(pad.cursor), "d-pad walks the pointer onto the demo city button")
	_press(JOY_BUTTON_A)
	check(await _until(func(): return main.started, 60), "A clicks it: the demo city starts")
	await _frames(3)
	check(pad.mode == &"mayor", "mode is mayor view")

	# Mayor view: X build menu, B closes it, d-pad picks tools, B drops the tool.
	_press(JOY_BUTTON_X)
	await _frames(2)
	check(hud.build_menu.visible, "X opens the build menu")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not hud.build_menu.visible and not main.menu.is_open, "B closes the build menu, not the Esc menu")
	_press(JOY_BUTTON_DPAD_RIGHT)
	await _frames(2)
	check(main.tool == 1, "d-pad right picks the road tool (tool %d)" % main.tool)
	_press(JOY_BUTTON_DPAD_LEFT)
	_press(JOY_BUTTON_DPAD_LEFT)
	await _frames(3)
	check(main.tool == 5, "d-pad left wraps round to bulldoze (tool %d)" % main.tool)
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(main.tool == 0 and not main.menu.is_open, "B drops the tool")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not main.menu.is_open, "B with nothing in hand does nothing")
	var sp: int = main.speed_index
	_press(JOY_BUTTON_DPAD_UP)
	await _frames(2)
	check(main.speed_index == mini(sp + 1, 3), "d-pad up speeds the city up")
	_press(JOY_BUTTON_DPAD_DOWN)
	await _frames(2)
	check(main.speed_index == sp, "d-pad down slows it again")
	var ov: int = main.overlay
	_press(JOY_BUTTON_Y)
	await _frames(2)
	check(main.overlay == (ov + 1) % 4, "Y steps the overlay")
	_press(JOY_BUTTON_Y)
	_press(JOY_BUTTON_Y)
	_press(JOY_BUTTON_Y)
	await _frames(3)

	# Zone by holding A and dragging the pointer, as with the mouse.
	_press(JOY_BUTTON_DPAD_RIGHT)
	_press(JOY_BUTTON_DPAD_RIGHT)
	await _frames(2)
	check(main.tool == 2, "residential tool")
	var vs: Vector2 = root.get_visible_rect().size
	var c0 = _clear_cell(vs)
	check(c0 != null, "found open ground for a zone")
	if c0 != null:
		var before := _zoned()
		pad.move_cursor(c0)
		await _frames(1)
		_button(JOY_BUTTON_A, true)
		await _frames(2)
		pad.move_cursor(c0 + Vector2(60, 20))
		await _frames(2)
		_button(JOY_BUTTON_A, false)
		await _frames(3)
		check(_zoned() > before, "hold A and drag zones land (%d -> %d cells)" % [before, _zoned()])
	_press(JOY_BUTTON_B)
	await _frames(2)

	# Start: Esc menu; B closes it; Start opens, A on Resume closes.
	_press(JOY_BUTTON_START)
	await _frames(2)
	check(main.menu.is_open, "Start opens the menu")
	check(pad.mode == &"menu", "pointer mode in the menu")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not main.menu.is_open, "B closes the menu")
	_press(JOY_BUTTON_START)
	await _frames(2)
	pad.move_cursor(main.menu._resume.get_global_rect().get_center())
	_press(JOY_BUTTON_A)
	await _frames(2)
	check(not main.menu.is_open and not paused, "A on Resume closes the menu once")

	# Hold View for the quick menu; tap View for the street.
	_button(JOY_BUTTON_BACK, true)
	check(await _until(func(): return pad.hud.quick_open(), 60), "holding View opens the quick menu")
	_button(JOY_BUTTON_BACK, false)
	await _frames(2)
	check(pad.hud.quick_open() and paused, "it stays open and the game waits")
	var n_items: int = pad.hud._quick_items.size()
	_press(JOY_BUTTON_DPAD_UP)
	await _frames(1)
	check(pad.hud._quick_sel == n_items - 1, "d-pad up wraps to the last entry")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not pad.hud.quick_open() and not paused, "B closes the quick menu and the game runs")
	_button(JOY_BUTTON_BACK, true)
	await _frames(2)
	_button(JOY_BUTTON_BACK, false)
	check(await _until(func(): return main.street.active, 900), "a View tap dives to the street")
	await _frames(3)
	check(pad.mode == &"street", "street mode")
	check(main.menu._hint.modulate.a < 0.1, "the keyboard key list fades while the pad is in use")
	check(pad.hud._bar.visible and pad.hud._bar.get_child_count() > 3, "pad prompts show at street level")

	# Street: d-pad right quest log, B closes it; d-pad down opens the map, B closes it.
	_press(JOY_BUTTON_DPAD_RIGHT)
	await _frames(2)
	check(main.missions.log_panel.visible, "d-pad right opens the quest log")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not main.missions.log_panel.visible, "B closes it")
	_press(JOY_BUTTON_DPAD_DOWN)
	await _frames(2)
	check(main.nav.map_open, "d-pad down opens the city map")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not main.nav.map_open, "B closes the map")
	# Y is the street's own interact action and still reaches the game.
	var got := [false]
	main.street.player.interact_requested.connect(func(): got[0] = true)
	_press(JOY_BUTTON_Y)
	await _frames(2)
	check(got[0], "Y still interacts at street level")

	# Layout card from the quick menu.
	_button(JOY_BUTTON_BACK, true)
	await _until(func(): return pad.hud.quick_open(), 60)
	_button(JOY_BUTTON_BACK, false)
	for i in pad.hud._quick_items.size():
		if str(pad.hud._quick_items[pad.hud._quick_sel][0]) == "Controller layout":
			break
		_press(JOY_BUTTON_DPAD_DOWN)
	_press(JOY_BUTTON_A)
	await _frames(2)
	check(pad.hud.card_open() and paused, "the quick menu opens the controller layout")
	_press(JOY_BUTTON_B)
	await _frames(2)
	check(not pad.hud.card_open() and not paused, "B closes it")
	check(pad.last_input.begins_with("button"), "the card's check line saw the press (%s)" % pad.last_input)

	# The Esc menu's Controller button opens the card with the mouse; Esc and a click close it,
	# so a pad that isn't reaching the game can never trap the player.
	pad.hud.open_card()
	await _frames(2)
	check(pad.hud._diag != null and pad.hud._diag.text.contains("Last controller input"), "the card shows what Windows reports")
	_key(KEY_ESCAPE)
	await _frames(2)
	check(not pad.hud.card_open() and not main.menu.is_open, "Esc closes the card (and only the card)")
	pad.hud.open_card()
	await _frames(2)
	_mouse_click(Vector2(5, 5))
	await _frames(2)
	check(not pad.hud.card_open() and not paused, "a click outside closes the card")

	# Keyboard use hands the hints back.
	var k := InputEventKey.new()
	k.keycode = KEY_SHIFT
	k.physical_keycode = KEY_SHIFT
	k.pressed = true
	Input.parse_input_event(k)
	await _frames(1)
	k = k.duplicate()
	k.pressed = false
	Input.parse_input_event(k)
	await _frames(15)
	check(not pad.using_pad and main.menu._hint.modulate.a > 0.9 and not pad.hud._bar.visible, "a key brings the keyboard hints back")

	print("FAILED %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)


func _glyph_checks() -> void:
	check(PadGlyphs.from_name("DualSense Wireless Controller") == PadGlyphs.Family.PLAYSTATION, "DualSense gets PlayStation icons")
	check(PadGlyphs.from_name("PS4 Controller") == PadGlyphs.Family.PLAYSTATION, "PS4 pad gets PlayStation icons")
	check(PadGlyphs.from_name("Xbox Series X Controller") == PadGlyphs.Family.XBOX, "Xbox pad gets Xbox icons")
	check(PadGlyphs.from_name("Nintendo Switch Pro Controller") == PadGlyphs.Family.NINTENDO, "Switch Pro gets Nintendo icons")
	check(PadGlyphs.from_name("Gamepad", {"vendor_id": "1356"}) == PadGlyphs.Family.PLAYSTATION, "Sony vendor id gets PlayStation icons")
	check(PadGlyphs.from_name("8BitDo SN30 Pro") == PadGlyphs.Family.XBOX, "an unknown pad gets Xbox icons")
	check(PadGlyphs.from_name("Stadia Controller rev. A") == PadGlyphs.Family.STADIA, "Stadia pad gets Stadia icons")
	check(PadGlyphs.from_name("Bluetooth Gamepad", {"vendor_id": "6353"}) == PadGlyphs.Family.STADIA, "Google vendor id gets Stadia icons")
	check(PadGlyphs.label(PadGlyphs.Family.NINTENDO, JOY_BUTTON_A) == "B", "Nintendo's bottom button is labelled B")


func _zoned() -> int:
	var n := 0
	for z in main.city.zone:
		if z == 1:
			n += 1
	return n


func _clear_cell(vs: Vector2) -> Variant:
	## A screen point over open ground, so a residential drag can land.
	for gy in range(6, 14):
		for gx in range(3, 17):
			var p := Vector2(vs.x * gx / 20.0, vs.y * gy / 20.0)
			var c = main._cell_at(p)
			if c != null and _open(c.x, c.y):
				return p
	return null


func _open(x: int, y: int) -> bool:
	var i: int = main.city.idx(x, y)
	return main.city.land[i] == 1 and main.city.road[i] == 0 and main.city.zone[i] != 1


func _key(k: Key) -> void:
	for down in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = down
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _mouse_click(p: Vector2) -> void:
	for down in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = down
		e.position = p
		e.global_position = p
		Input.parse_input_event(e)
	Input.flush_buffered_events()


func _press(b: JoyButton) -> void:
	_button(b, true)
	_button(b, false)


func _button(b: JoyButton, down: bool) -> void:
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
	return cond.call()


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var f := _find_button(c, text)
		if f:
			return f
	return null

