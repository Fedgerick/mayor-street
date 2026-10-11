extends SceneTree
## Pictures of the City history window, one per page, for look-dev:
##   xvfb-run godot --rendering-driver vulkan --path . --script res://ui/tests/chart_shots.gd -- --out=DIR

var main: Node3D


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.skip_creator = true
	root.add_child(main)
	_run.call_deferred()


func _run() -> void:
	var out := "user://chart_shots"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	root.size = Vector2i(1600, 900)
	await process_frame
	var ui = main.get_node_or_null(^"ClickableUI")
	if ui == null:
		ui = load("res://ui/clickable_ui.gd").install(main)
	main.hud._close_start(true)  # the title's demo button
	for d in 30:  # a month of growth, a snapshot a day
		main.city.simulate_hours(24)
	for p in 3:
		ui.charts.open(p)
		for i in 6:
			await process_frame
		root.get_texture().get_image().save_png(out.path_join("chart_%d.png" % p))
	ui.charts.close()
	# The mayor HUD with the mouse over the demand bars: brighter, hand cursor.
	var m := InputEventMouseMotion.new()
	m.position = main.hud.bars[0].get_global_rect().get_center()
	root.push_input(m, true)
	for i in 4:
		await process_frame
	root.get_texture().get_image().save_png(out.path_join("hud_hover.png"))
	quit()
