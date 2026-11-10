extends SceneTree
## Look-dev: construction sites at several stages downtown, from the mayor view and the street.
##   xvfb-run -a godot --rendering-driver vulkan --resolution 1280x720 --path . -s planet/tests/site_shots.gd -- --demo --nosave --out=DIR

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var out := "/tmp"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.5).timeout
	var city: City = main.city
	main._set_speed(0)
	city.growth_check = func(_x, _y): return false
	var c := city.center_cell()
	# The buildings nearest the centre, biggest first, go back to being sites.
	var near: Array = []
	for b in city.buildings.values():
		if b.size >= 1 and not b.has("kind") and absi(b.x - c.x) <= 5 and absi(b.y - c.y) <= 4:
			near.append(b)
	near.sort_custom(func(a, b): return a.size * 10 + a.stage > b.size * 10 + b.stage)
	var steps := [0.04, 0.2, 0.4, 0.6, 0.78, 0.86, 0.95, 0.3, 0.5, 0.7]
	var focus := Vector3.ZERO
	var n := 0
	for b in near.slice(0, steps.size()):
		var e: Dictionary = b.duplicate()
		city.remove_building(b.id)
		var id := city.add_building(e.x, e.y, e.size, e.zone, e.stage, e.rot)
		city.sites[id].built = steps[n]
		focus += city.building_center(city.sites[id])
		n += 1
	focus /= maxf(n, 1.0)
	print("sites: ", n, " at ", focus)
	main.cam.set_view(focus, 150.0, deg_to_rad(-30.0), deg_to_rad(42.0))
	for i in 40:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join("sites_mayor.png"))
	main.cam.set_view(focus, 70.0, deg_to_rad(60.0), deg_to_rad(25.0))
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out.path_join("sites_close.png"))
	print("saved")
	quit()
