extends SceneTree
## Look-dev shots of the pad prompts, the quick menu and the layout card.
##   xvfb-run godot --rendering-driver vulkan --path . --script res://controller/tests/pad_shots.gd -- --out=DIR

var main: Node3D
var out := "user://pad_shots"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	main = load("res://scenes/main.tscn").instantiate()
	main.skip_creator = true
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	await _frames(5)
	main.hud.start_panel.get_parent()  # title screen up
	var pad: PadControls = main.get("pad")
	if pad == null:
		pad = PadControls.new()
		main.add_child(pad)
		pad.setup(main)
	pad.set_process(true)
	var demo: Button = _find_button(main.hud.start_panel, "Load the demo city")
	demo.pressed.emit()
	await _until(func(): return main.started, 600)
	await _frames(30)
	pad._set_using(true)
	pad.move_cursor(Vector2(900, 520))
	await _frames(20)
	await _shot("mayor_xbox")
	pad.set_icons(PadGlyphs.Family.PLAYSTATION)
	pad.hud.open_card()
	await _frames(10)
	await _shot("card_playstation")
	pad.hud.handle_button(JOY_BUTTON_B, true)
	pad.set_icons(PadGlyphs.Family.XBOX)
	pad.hud.open_quick()
	await _frames(10)
	await _shot("quick_xbox")
	pad.hud.close_quick()
	main.go_street()
	await _until(func(): return main.street.active, 900)
	await _frames(40)
	pad.set_icons(PadGlyphs.Family.NINTENDO)
	await _frames(20)
	await _shot("street_nintendo")
	pad.set_icons(-1)
	quit(0)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(out.path_join(name + ".png"))
	print("shot ", name)


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
