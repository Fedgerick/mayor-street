extends SceneTree
## Look-dev pictures of the minimap, the GPS line and the city map, in the real game scene:
##     xvfb-run godot --rendering-driver vulkan --path . --resolution 1600x900 \
##       -s res://navigation/tests/nav_shots.gd -- --demo --nav-shots=DIR
## Adds its own CityNav when main.gd doesn't have one yet.

var main: Node
var dir := "user://nav_shots"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--nav-shots="):
			dir = a.trim_prefix("--nav-shots=")
	DirAccess.make_dir_recursive_absolute(dir)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(dir.path_join(name + ".png"))
	print("saved ", name)


func _run() -> void:
	await _frames(5)
	var city: City = main.city
	var nav: CityNav = main.get("nav") if main.get("nav") != null else null
	if nav == null:
		nav = CityNav.new()
		nav.name = "Navigation"
		main.add_child(nav)
		nav.setup(city, main.street, {"life": main.life, "missions": main.missions,
			"resident": main.resident, "interiors": main.interiors})
	main.go_street()
	await main.street.street_entered
	main._set_speed(0)
	city.minutes = float(city.game_day()) * 1440.0 + 14.0 * 60.0
	# A job target a few blocks away, so the GPS line has turns to follow.
	var me: Vector3 = main.street.player_position()
	var gps := GpsRoute.new(city)
	var start := gps.nearest_road(city.world_to_cell(me))
	var goal := start
	var best := 0
	for y in City.SIZE:
		for x in City.SIZE:
			if city.is_road(x, y):
				var d := absi(x - start.x) + absi(y - start.y)
				if d > best and d < 16 and absi(x - start.x) > 4 and absi(y - start.y) > 4:
					best = d
					goal = Vector2i(x, y)
	nav.mark("mission:demo", city.cell_center(goal.x, goal.y), {"color": Color(0.95, 0.3, 0.25), "label": "Demo job"})
	await _frames(30)
	await _shot("minimap_foot")
	# Far target: pinned to the rim.
	nav.mark("mission:demo", city.cell_center(City.SIZE - start.x, City.SIZE - start.y), {"color": Color(0.95, 0.3, 0.25)})
	await _frames(10)
	await _shot("minimap_far")
	nav.open_map()
	nav.map_screen._hover_w = Vector2(me.x, me.z)
	await _shot("city_map")
	nav.set_waypoint(city.cell_center(goal.x, goal.y))
	nav.map_screen.zoom = 2.5
	nav.map_screen.centre_w = Vector2(me.x, me.z)
	await _shot("city_map_zoom")
	nav.close_map()
	quit()
