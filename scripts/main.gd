extends Node3D
## Wires the city sandbox together: sim, renderer, day/night, mayor camera, tools, HUD.
##
## Command-line options (after `--`):
##   --demo                 start straight into the demo city (no character creator)
##   --hour=21.5            set the clock
##   --view=x,z,dist,yawdeg camera framing
##   --overlay=1            0 none, 1 zones, 2 traffic, 3 land value
##   --screenshot=path.png  render a few frames, save, quit
##   --quality=0|1|2
##   --street               dive to street level right away
##   --shots=dir            render the LOOK_SHOTS set into dir and quit (--only=day,night picks some)
##   --nohud                hide the HUD
##   --perf                 show the frame rate readout (F3)
##   --benchmark            run the two-minute benchmark tour, write benchmark.txt and quit
##   --weather=rain         fix the weather: clear, cloudy, rain or fog

enum Tool { INSPECT, ROAD, RES, COM, IND, BULLDOZE, BUILD }

var city: City
var view: CityView
var day_night: DayNight
var cam: MayorCamera
var hud: Hud
var life: CityLife  # traffic and pedestrians (citylife/), created when a game starts
var street: StreetMode  # street-level player (player/), created when a game starts
var menu: GameMenu  # Esc menu and the corner key hint; keeps running while the game is paused
var services: CityServices  # power, parks, garbage, police, fire (services/)
var services_view: ServicesView
var services_panel: ServicesPanel
var interiors: InteriorManager  # enterable buildings (interiors/)
var missions: Missions  # jobs, payphones, goodness and quests (missions/)
var resident: Resident  # the character you create, and their home (creator/)
var weather: Weather  # clear, cloudy, rain and fog on a calendar (weather/)
var rain_fx: RainFX  # rain and splashes around the street camera
var dresser: StreetDresser  # trees, benches, signs, shop fronts near the street camera (art/dresser/)
var nav: CityNav  # minimap, GPS route and the city map on V (navigation/)
var bench: Benchmark  # the benchmark tour, while one runs
var pad: PadControls  # gamepad controls and button prompts (controller/)
var skip_creator := false  # no character creator; test scripts, --demo and look-dev runs skip it too
var _dive_home := false  # after the creator, the first dive lands outside the Resident's front door
var _gliding := false
var _benchmark_run := false  # this game is the benchmark's demo city

var tool := Tool.INSPECT
var build_kind := ""  # the catalog building in hand while tool is BUILD
var overlay := 0
var speed_index := 1
var quality := 1
var started := false
var _drag_start := Vector2i(-1, -1)
var _dragging := false
var _hover := Vector2i(-1, -1)
var _args := {}
var _speed_before_street := 1
var _perf: Label  # F3 frame rate readout, for judging graphics levels on real hardware
var _perf_t := 0.0

const SPEED_VALUES := [0.0, 1.0, 3.0, 10.0]
# Standard views for judging the look: name, hour, focus x, focus z, distance, yaw, tilt (degrees).
# Shots named street* are taken at street level from that focus, so they go last.
const LOOK_SHOTS := [
	["day", 10.5, 400.0, 610.0, 230.0, -35.0, 0.0],
	["close", 11.0, 430.0, 650.0, 75.0, -35.0, -8.0],
	["golden", 18.4, 486.0, 640.0, 300.0, -35.0, -32.0],
	["sunset", 18.7, 560.0, 470.0, 300.0, 125.0, -32.0],
	["island", 13.5, 480.0, 480.0, 850.0, -30.0, 0.0],
	["coast", 15.0, 480.0, 880.0, 200.0, 160.0, -4.0],
	["night", 21.5, 400.0, 610.0, 230.0, -35.0, 0.0],
	["night_close", 22.0, 430.0, 650.0, 75.0, -35.0, -8.0],
	["street", 11.0, 562.0, 612.0, 80.0, 0.0, 0.0],
	["street_dusk", 19.2, 562.0, 612.0, 80.0, 0.0, 0.0],
	["street_night", 22.0, 562.0, 612.0, 80.0, 0.0, 0.0],
]
const LIFE_DENSITY := [0.55, 1.0, 1.25]  # cars and people per graphics level
const HERO_MAX := [6, 12, 24]  # close-up people on the full rigged model, per graphics level
# Where buildings, trees and props give way to box stand-ins (CityView.detail_distance), per
# graphics level; 0 never. The street sees less of the city past the first blocks.
const STREET_DETAIL := [250.0, 400.0, 700.0]
const MAYOR_DETAIL := [600.0, 1000.0, 0.0]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	# A load restarts this scene with the save waiting in Progress.
	var save := Progress.take_pending_load()
	city = City.new(int(save.city.get("seed", 1337))) if not save.is_empty() else City.new()
	city.message.connect(func(t): hud.show_toast(t))
	day_night = DayNight.new()
	add_child(day_night)
	view = CityView.new()
	add_child(view)
	cam = MayorCamera.new()
	add_child(cam)
	var size := City.SIZE * City.TILE
	cam.bounds = Rect2(-100, -100, size + 200, size + 200)
	hud = Hud.new()
	hud.city = city
	add_child(hud)
	hud.tool_selected.connect(_on_tool_button)
	hud.overlay_selected.connect(_set_overlay)
	hud.speed_selected.connect(_set_speed)
	hud.quality_selected.connect(_set_quality)
	hud.start_chosen.connect(_start)
	hud.load_chosen.connect(func(slot): Progress.load_game(slot))
	hud.build_menu.chosen.connect(_choose_building)
	hud.benchmark_chosen.connect(_begin_benchmark)
	cam.moved.connect(day_night.set_view_distance)
	menu = GameMenu.new()
	add_child(menu)
	menu.benchmark_requested.connect(_benchmark_from_menu)
	menu.map_requested.connect(func(): if nav: nav.open_map())
	menu.controller_requested.connect(func(): if pad: pad.hud.open_card())
	# Gamepad controls work from the title screen on; it moves itself to main's last child,
	# so it reads the pad before the rest of the game.
	pad = PadControls.new()
	pad.name = "PadControls"
	add_child(pad)
	pad.setup(self)

	quality = int(_args.get("quality", "1"))
	if Benchmark.pending_quality >= 0:
		quality = Benchmark.pending_quality  # the level the game was played at
		Benchmark.pending_quality = -1
	var benchmark := Benchmark.pending or _args.has("benchmark")
	Benchmark.pending = false
	_set_quality(quality)
	_set_tool(Tool.INSPECT)
	_set_overlay(int(_args.get("overlay", "0")))
	_set_speed(1)

	if not save.is_empty():
		_start(false, save)
	elif benchmark:
		_begin_benchmark()
	elif _args.has("demo") or _args.has("screenshot"):
		_start(_args.has("demo"))
	else:
		# Title screen: the island slowly orbits behind the menu.
		view.setup(city)
		var c := city.cell_center(city.center_cell().x, city.center_cell().y)
		cam.set_view(c, 620.0, deg_to_rad(-30.0))
		cam.auto_orbit = 0.05
		hud.show_start()
	day_night.update_time(city.time_of_day(), city.game_day())


## A new game (demo or empty island), or a saved one when save holds what
## Progress.take_pending_load() returned.
func _start(demo: bool, save := {}) -> void:
	if not save.is_empty():
		city.from_dict(save.city)
	elif demo:
		city.build_demo()
	else:
		city.build_starter()
	if view.city == null:
		view.setup(city)
	Progress.begin(city, save)
	Progress.notice.connect(_on_notice)
	if _args.has("screenshot") or _args.has("shots") or _args.has("nosave") or _benchmark_run:
		Progress.autosave_enabled = false
	services = CityServices.new(city)  # sets city.growth_check and adjusts land value itself
	Progress.register_section("services", services)
	view.services = services
	services.coverage_changed.connect(view.mark_map_dirty)  # power changes light or darken windows
	if demo and save.is_empty():
		services.build_demo_services()  # plants, depots, police, fire and parks for the demo
	services_view = ServicesView.new()
	add_child(services_view)
	services_view.setup(services)
	services_panel = ServicesPanel.new()
	hud.root.add_child(services_panel)
	services_panel.setup(services)
	services_panel.overlay_selected.connect(_on_service_overlay)
	Hud.no_keyboard_focus(services_panel)
	if _args.has("hour"):
		city.minutes = float(city.game_day()) * 1440.0 + float(_args["hour"]) * 60.0
	view.rebuild_all()
	var c := city.cell_center(city.center_cell().x, city.center_cell().y)
	cam.auto_orbit = 0.0
	cam.set_view(c + Vector3(0, 0, 30), 260.0 if demo else 330.0, deg_to_rad(-35.0))
	if _args.has("view"):
		var p: PackedStringArray = _args["view"].split(",")
		cam.set_view(Vector3(float(p[0]), 0, float(p[1])), float(p[2]), deg_to_rad(float(p[3])),
			deg_to_rad(float(p[4])) if p.size() > 4 else 0.0)
	life = CityLife.new()
	life.density = LIFE_DENSITY[quality]
	life.auto_step = false  # stepped from _process so it freezes while the game is paused
	add_child(life)
	life.setup(city, cam)
	life.crowd.hero_max = HERO_MAX[quality]
	life.crowd.prewarm_heroes(HERO_MAX[quality])  # load the close-up people now, not mid-street
	street = preload("res://player/scenes/street_mode.tscn").instantiate()
	add_child(street)
	street.setup(city)  # registers its own save section, "street"
	street.set_life(life)  # carjacking, people and cops as targets, police chases
	interiors = InteriorManager.new()
	interiors.name = "Interiors"
	add_child(interiors)
	interiors.setup(city, street)
	street.busted_wake = func(): await interiors.enter("police", null, "busted")
	missions = Missions.new()
	missions.name = "Missions"
	add_child(missions)
	missions.setup(city, street)  # registers "missions"
	resident = Resident.new()
	resident.name = "Resident"
	add_child(resident)
	resident.setup(city, street, cam)  # registers "resident"; a load fills it here
	resident.use_interiors(interiors)
	weather = Weather.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup(city)  # follows city.minutes, so game speed and pause apply
	day_night.weather = weather  # grey skies, a weaker sun and thicker fog
	if _args.has("weather"):
		weather.set_weather(["clear", "cloudy", "rain", "fog"].find(String(_args["weather"])), true)
	life.set_weather(weather)  # rain thins the crowd, opens umbrellas and slows the traffic
	Progress.register_section("weather", weather)
	rain_fx = RainFX.new()
	rain_fx.name = "RainFX"
	add_child(rain_fx)
	rain_fx.setup(weather, cam)
	rain_fx.set_quality(quality)
	dresser = StreetDresser.new()
	dresser.name = "StreetDresser"
	add_child(dresser)
	dresser.setup(city, services, life.spots)  # hides itself above 70 m camera height
	nav = CityNav.new()
	nav.name = "Navigation"
	add_child(nav)
	nav.setup(city, street, {"life": life, "missions": missions, "resident": resident, "interiors": interiors})
	move_child(pad, -1)  # still the last child, after everything a game adds
	street.street_entered.connect(_on_street_entered)
	street.street_exited.connect(_on_street_exited)
	street.vehicle_changed.connect(func(_car): _update_hint())
	started = true
	if _args.has("screenshot"):
		_set_speed(0)
		_shoot.call_deferred(_args["screenshot"])
	if _args.has("shots"):
		_set_speed(0)
		_lookdev.call_deferred(_args["shots"])
	if _args.has("nohud"):
		hud.visible = false
	if _args.has("perf"):
		_toggle_perf()
	if _args.has("street"):
		go_street.call_deferred()
	Progress.register_section("mayor", self)
	Progress.started()
	_update_hint()
	var look_dev := _args.has("screenshot") or _args.has("shots") or _args.has("street") or _args.has("demo") \
		or _benchmark_run
	var test_run: bool = get_tree().get_script() != null  # a test script drives the game
	if save.is_empty() and not resident.profile.loaded and not look_dev and not test_run and not skip_creator:
		# A new game: create the Resident and pick a home while the clock waits.
		var speed := speed_index
		_set_speed(0)
		hud.visible = false
		menu.show_hint(&"")
		await resident.new_game()
		_dive_home = resident.profile.has_home()
		hud.visible = true
		_set_speed(speed)
		_update_hint()


func _begin_benchmark() -> void:
	## The benchmark tour on the demo city: from the title screen, the Esc menu (which
	## restarts the scene) or --benchmark (which quits when it's done).
	_benchmark_run = true
	_start(true)
	bench = Benchmark.new()
	bench.name = "Benchmark"
	bench.quit_when_done = _args.has("benchmark") and not _args.has("bench-render-thread")
	bench.render_thread = _args.get("bench-render-thread", "")
	bench.shots_dir = _args.get("bench-shots", "")
	add_child(bench)
	bench.run.call_deferred(self)


func _benchmark_from_menu() -> void:
	## Save the game, then restart into the benchmark. Continue on the title screen brings
	## the game back afterwards.
	Progress.autosave()
	Progress.playing = false
	Benchmark.pending = true
	Benchmark.pending_quality = quality
	get_tree().paused = false
	get_tree().reload_current_scene()


## The mayor's view, for saves: camera, speed and overlay.
func to_dict() -> Dictionary:
	return {"focus": [cam.focus.x, cam.focus.z], "dist": cam.dist, "yaw": cam.yaw, "tilt": cam.tilt,
		"speed": speed_index, "overlay": overlay}


func from_dict(d: Dictionary) -> void:
	var f: Array = d.get("focus", [])
	if f.size() == 2:
		cam.set_view(Vector3(float(f[0]), 0.0, float(f[1])), float(d.get("dist", cam.dist)),
			float(d.get("yaw", cam.yaw)), float(d.get("tilt", 0.0)))
	_set_speed(clampi(int(d.get("speed", 1)), 0, SPEED_VALUES.size() - 1))
	_set_overlay(clampi(int(d.get("overlay", 0)), 0, 3))

func _shoot(path: String) -> void:
	if _args.has("street"):
		await street.street_entered
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("saved ", path)
	get_tree().quit()


func _lookdev(dir: String) -> void:
	## Renders LOOK_SHOTS in one run, so before/after sets match exactly.
	DirAccess.make_dir_recursive_absolute(dir)
	var only := String(_args.get("only", "")).split(",", false)
	for s in LOOK_SHOTS:
		var nm: String = s[0]
		if not only.is_empty() and not only.has(nm):
			continue
		if not nm.begins_with("street"):
			cam.set_view(Vector3(s[2], 0, s[3]), s[4], deg_to_rad(s[5]), deg_to_rad(s[6]))
		elif not in_street():
			cam.set_view(Vector3(s[2], 0, s[3]), s[4], deg_to_rad(s[5]))
			go_street()
			await street.street_entered
			_set_speed(0)
		city.minutes = float(city.game_day()) * 1440.0 + float(s[1]) * 60.0
		# The sky's light is refiltered a layer per frame, so after a jump in the time of day the
		# ambient lags the sky for up to two passes. Wait those out before taking the picture.
		for i in 24:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(dir.path_join(nm + ".png"))
		# What the GPU was asked to draw, which is what matters on a laptop iGPU, and the time
		# per frame here (a software renderer, so only the ratios between levels mean much).
		var rs := RenderingServer
		var draws := rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var tris := rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var t0 := Time.get_ticks_usec()
		for i in 4:
			await RenderingServer.frame_post_draw
		print("saved %s: %d draw calls, %dk triangles, %.0f ms/frame, %d cars, %d people (%s rigged)" % [nm,
			draws, tris / 1000, (Time.get_ticks_usec() - t0) / 4000.0,
			life.traffic.cars.size(), life.crowd.peds.size(), str(life.crowd.get("_hero_count"))])
	get_tree().quit()


# ------------------------------------------------------------ street level ---

func in_street() -> bool:
	return street != null and (street.active or street.busy)


func go_street() -> void:
	## Dive from the mayor view to a character on the sidewalk under the camera focus.
	if not started or in_street() or _gliding:
		return
	_set_tool(Tool.INSPECT)
	hud.show_tip(Vector2.ZERO, "")
	var at := cam.focus
	if _dive_home:
		# A new game starts outside your own front door: swing round to face it from the
		# street, then dive to the sidewalk there.
		_dive_home = false
		var b: Dictionary = resident.home.building()
		if not b.is_empty():
			var d: Vector2i = City.DIRS[b.rot]
			at = resident.home.door_position()
			_gliding = true
			cam.glide_to(at, 90.0, atan2(float(d.x), float(d.y)))
			await get_tree().create_timer(0.8).timeout
			_gliding = false
			if not started or in_street():
				return
	hud.visible = false
	# The design keeps the street at 1x; the mayor speed comes back on the way up.
	_speed_before_street = speed_index
	_set_speed(1)
	cam.set_process(false)
	cam.set_process_unhandled_input(false)
	street.enter_street(cam, at)
	life.set_camera(street.camera)
	rain_fx.set_camera(street.camera)
	_update_hint()


func go_mayor() -> void:
	if street == null or not street.active or street.busy:
		return
	if not street.can_exit():
		street.exit_street(cam.global_transform, cam.fov)  # shows why ("Lose the cops first")
		return
	if interiors and interiors.is_inside():
		# Rooms sit high above the map: walk out of the building first, then fly up.
		if interiors.busy:
			return
		await interiors.exit()
		if not street.active or street.busy or not street.can_exit():
			return
	# Frame the mayor view on where the player ended up, looking the same way.
	cam.set_view(street.focus_point(), 140.0, street.view_yaw())
	street.exit_street(cam.global_transform, cam.fov)
	_update_hint()


func _update_detail() -> void:
	if view:
		view.set_detail_distance((STREET_DETAIL if in_street() else MAYOR_DETAIL)[quality])


func _on_street_entered() -> void:
	day_night.set_view_distance(30.0)
	view.set_detail_distance(STREET_DETAIL[quality])
	day_night.exposure_scale = 1.25
	day_night.ambient_scale = 1.4
	_update_hint()


func _on_street_exited() -> void:
	cam.make_current()
	cam.set_process(true)
	cam.set_process_unhandled_input(true)
	day_night.set_view_distance(cam.dist)
	view.set_detail_distance(MAYOR_DETAIL[quality])
	day_night.exposure_scale = 1.0
	day_night.ambient_scale = 1.0
	life.set_camera(cam)
	rain_fx.set_camera(cam)
	hud.visible = true
	_set_speed(_speed_before_street)
	_update_hint()


func _update_hint() -> void:
	## The corner key hint follows where the player is; it hides during the zooms.
	var kind := &""
	if started and not _args.has("nohud") and not (bench and bench.running):
		if street.active:
			kind = &"car" if street.car else &"foot"
		elif not street.busy:
			kind = &"mayor"
	menu.show_hint(kind)


# ---------------------------------------------------------------- settings ---

func _on_tool_button(t: int) -> void:
	if t == Tool.BUILD:
		hud.set_tool(tool)  # the Build button opens the menu; the tool comes from the menu
		_toggle_build_menu()
	else:
		_set_tool(t)


func _on_notice(text: String) -> void:
	hud.show_toast(text, true)


func _set_tool(t: int) -> void:
	tool = t as Tool
	_dragging = false
	if tool != Tool.BUILD:
		build_kind = ""
	hud.build_menu.visible = false
	hud.set_tool(t)
	hud.show_tip(Vector2.ZERO, "")  # the next mouse move brings back a tip for the new tool
	if view.city:
		view.set_preview([], Color.WHITE)
	RenderingServer.global_shader_parameter_set("grid_alpha", 0.0 if tool == Tool.INSPECT else 1.0)


func _set_overlay(o: int) -> void:
	overlay = o
	hud.set_overlay(o)
	RenderingServer.global_shader_parameter_set("overlay_mode", o)
	if o != 0 and services_panel:  # one overlay at a time: the zone ones or the service ones
		services_panel.set_overlay(0)
		services_view.set_overlay(0)


func _on_service_overlay(o: int) -> void:
	services_view.set_overlay(o)
	if o != 0:
		overlay = 0
		hud.set_overlay(0)
		RenderingServer.global_shader_parameter_set("overlay_mode", 0)


func _set_speed(i: int) -> void:
	speed_index = i
	hud.set_speed(i)


func _set_quality(q: int) -> void:
	quality = q
	day_night.apply_quality(q)
	hud.set_quality(q)
	_update_detail()
	if life:
		life.density = LIFE_DENSITY[q]
		life.crowd.hero_max = HERO_MAX[q]
	if rain_fx:
		rain_fx.set_quality(q)


# ------------------------------------------------------------------- input ---

func _input(e: InputEvent) -> void:
	## Keys that must always reach the game, read before the HUD gets them: a clicked HUD
	## button used to keep the keyboard and swallow Tab. F11 and Alt+Enter live in GameMenu.
	var key := _pressed_key(e)
	var alt := e is InputEventWithModifiers and (e as InputEventWithModifiers).alt_pressed
	if bench and bench.running:
		return  # the tour drives itself; Benchmark._input takes every key and click
	if resident and resident.get("_busy") == true and not menu.is_open:
		return  # the character creator or the home picker has the keyboard (Esc skips there)
	if street and not _dragging and not alt and e.is_action_pressed("street_toggle_view"):
		get_viewport().set_input_as_handled()
		if street.active:
			go_mayor()
		else:
			go_street()
	elif key == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		# Esc first drops whatever is in hand (a drag, then the build tool), then opens the menu.
		if _dragging:
			_dragging = false
			_update_preview()
		elif hud.build_menu.visible:
			hud.build_menu.visible = false
		elif tool != Tool.INSPECT:
			_set_tool(Tool.INSPECT)
		else:
			menu.open()
	elif GameMenu.is_start_button(e):
		get_viewport().set_input_as_handled()
		menu.open()
	elif key == KEY_F3:
		get_viewport().set_input_as_handled()
		_toggle_perf()


static func _pressed_key(e: InputEvent) -> Key:
	var k := e as InputEventKey
	return k.keycode if k and k.pressed and not k.echo else KEY_NONE


func _unhandled_input(e: InputEvent) -> void:
	if in_street():
		return  # the street has its own controls
	if e is InputEventKey and e.pressed and not e.echo:
		var k := (e as InputEventKey).keycode
		if k >= KEY_1 and k <= KEY_6:
			_set_tool(k - KEY_1)
		elif (k == KEY_7 or k == KEY_B) and started:
			_toggle_build_menu()
		elif k == KEY_SPACE:
			_set_speed(1 if speed_index == 0 else 0)
		elif k == KEY_N and started:
			city.advance(10.0, 1.0)
		elif k == KEY_O:
			_set_overlay((overlay + 1) % 4)
		elif k == KEY_COMMA:
			_set_speed(maxi(speed_index - 1, 0))
		elif k == KEY_PERIOD:
			_set_speed(mini(speed_index + 1, 3))
	if not started:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			var c = _cell_at(mb.position)
			if mb.pressed and c != null:
				if tool == Tool.INSPECT:
					_inspect(c)
				elif tool == Tool.BUILD and _build_def().placement != "line":
					_place_building(c)
				else:
					_drag_start = c
					_dragging = true
			elif not mb.pressed and _dragging:
				_dragging = false
				if c != null:
					_apply(_drag_start, c)
			_update_preview()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and _dragging:
			_dragging = false
			_update_preview()
	elif e is InputEventMouseMotion:
		var c = _cell_at((e as InputEventMouseMotion).position)
		var cc: Vector2i = c if c != null else Vector2i(-1, -1)
		if cc != _hover:
			_hover = cc
			_update_preview()
		_update_tip((e as InputEventMouseMotion).position)


func _cell_at(screen: Vector2) -> Variant:
	var p = cam.ground_point(screen)
	if p == null:
		return null
	var c := city.world_to_cell(p)
	return c if city.inside(c.x, c.y) else null


func _zone_for_tool() -> int:
	match tool:
		Tool.RES: return City.Zone.RES
		Tool.COM: return City.Zone.COM
		Tool.IND: return City.Zone.IND
	return 0


func _apply(a: Vector2i, b: Vector2i) -> void:
	match tool:
		Tool.ROAD:
			city.place_road(city.road_path(a, b))
		Tool.RES, Tool.COM, Tool.IND:
			city.place_zone(city.rect_cells(a, b), _zone_for_tool())
		Tool.BULLDOZE:
			city.bulldoze(city.rect_cells(a, b))
			if services:
				services.bulldoze_lines(city.rect_cells(a, b))
		Tool.BUILD:  # power lines, drawn like roads by services/
			var sv := Progress.get_section("services")
			if sv and sv.has_method("place_power_line"):
				sv.place_power_line(city.road_path(a, b))


func _preview_cells() -> Array:
	if _hover.x < 0 or tool == Tool.INSPECT:
		return []
	var a := _drag_start if _dragging else _hover
	if tool == Tool.ROAD or (tool == Tool.BUILD and _build_def().placement == "line"):
		return city.road_path(a, _hover)
	if tool == Tool.BUILD:
		var d := _build_def()
		var at := _build_cell(_hover)
		var out := []
		for y in maxi(d.size, 1):
			for x in maxi(d.size, 1):
				if city.inside(at.x + x, at.y + y):
					out.append(at + Vector2i(x, y))
		return out
	var out := []
	var r := city.rect_cells(a, _hover)
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			out.append(Vector2i(x, y))
	return out


func _update_preview() -> void:
	var col := Color(0.4, 0.8, 1.0)
	match tool:
		Tool.RES: col = Color(0.3, 1.0, 0.45)
		Tool.COM: col = Color(0.35, 0.65, 1.0)
		Tool.IND: col = Color(1.0, 0.75, 0.2)
		Tool.BULLDOZE: col = Color(1.0, 0.3, 0.25)
		Tool.BUILD:
			var ok: bool = _build_def().placement == "line" or _hover.x < 0 \
				or city.can_place_special(build_kind, _build_cell(_hover)) == ""
			col = Color(0.35, 1.0, 0.5) if ok else Color(1.0, 0.3, 0.25)
	view.set_preview(_preview_cells(), col)


func _update_tip(pos: Vector2) -> void:
	if _hover.x < 0 or tool == Tool.INSPECT:
		hud.show_tip(pos, "")
		return
	var a := _drag_start if _dragging else _hover
	var cost := 0
	match tool:
		Tool.ROAD: cost = city.road_cost(city.road_path(a, _hover))
		Tool.RES, Tool.COM, Tool.IND: cost = city.zone_cost(city.rect_cells(a, _hover), _zone_for_tool())
		Tool.BULLDOZE: cost = city.bulldoze_cost(city.rect_cells(a, _hover))
		Tool.BUILD:
			var d := _build_def()
			var text: String = d.name
			if d.placement == "line":
				var sv := Progress.get_section("services")
				if sv and sv.has_method("line_cost"):
					cost = sv.line_cost(city.road_path(a, _hover))
					text += "\n$%d" % cost if cost > 0 else ""
				else:
					text += "\nComes with city services"
			else:
				var why := city.can_place_special(build_kind, _build_cell(_hover))
				text += "\n" + (why if why != "" else "$" + Catalog.thousands(int(d.cost)))
			hud.show_tip(pos, text)
			return
	hud.show_tip(pos, "$%d" % cost if cost > 0 else "")


# ------------------------------------------------------------- build menu ---

func _toggle_build_menu() -> void:
	if hud.build_menu.visible:
		hud.build_menu.visible = false
	else:
		hud.build_menu.open()


func _choose_building(kind: String) -> void:
	build_kind = kind
	_set_tool(Tool.BUILD)
	_update_preview()


func _build_def() -> Dictionary:
	return Catalog.get_def(build_kind) if build_kind != "" else Catalog.DEFAULTS


func _build_cell(c: Vector2i) -> Vector2i:
	## The footprint's top-left tile, with the cursor near its middle.
	var s: int = _build_def().size
	return c - Vector2i((s - 1) / 2, (s - 1) / 2) if s > 1 else c


func _place_building(c: Vector2i) -> void:
	var id := city.place_special(build_kind, _build_cell(c))
	if id >= 0:
		if _build_def().unique:
			_set_tool(Tool.INSPECT)  # only one of these; put the tool down


func _inspect(c: Vector2i) -> void:
	var i := city.idx(c.x, c.y)
	var t := "Tile %d, %d\nLand value %d%%" % [c.x, c.y, int(city.land_value[i] * 100.0)]
	if city.road[i] == 1:
		t = "Road\nTraffic %d%%" % int(city.traffic[i] * 100.0)
		for pid in city.props_at(i):
			t += "\n" + city.buildings[pid].name
	elif city.bld[i] >= 0 and city.buildings[city.bld[i]].has("kind"):
		var b: Dictionary = city.buildings[city.bld[i]]
		var d := Catalog.get_def(b.kind)
		var up := int(d.upkeep)
		t = "%s\n%s" % [b.name, ("Costs $%d a day" % up) if up > 0 else ("Earns $%d a day" % -up) if up < 0 else ""]
		if d.desc != "":
			t += "\n" + d.desc
	elif city.bld[i] >= 0:
		var b: Dictionary = city.buildings[city.bld[i]]
		var what := "residents" if b.zone == City.Zone.RES else "jobs"
		t = "%s, stage %d\n%d %s\nLand value %d%%%s" % [City.ZONE_NAMES[b.zone], b.stage, city.capacity(b), what,
			int(city.land_value[i] * 100.0), "" if b.connected else "\nNo route to jobs/workers!"]
	elif city.zone[i] != 0:
		t += "\n%s zone, %s" % [City.ZONE_NAMES[city.zone[i]], "waiting to grow" if city.road_access_dir(c.x, c.y) >= 0 else "needs a road within 2 tiles"]
	elif city.land[i] == 0:
		t = "Shoreline (can't build)"
	hud.info.text = t


func _process(delta: float) -> void:
	if started:
		var hour_before := int(city.minutes / 60.0)
		city.advance(delta, SPEED_VALUES[speed_index])
		if int(city.minutes / 60.0) != hour_before:
			view._map_dirty = true
		# Cars and people move in real time at every sim speed, and stop when paused
		# (screenshots pause the clock but still let traffic settle).
		if speed_index > 0 or _args.has("screenshot") or _args.has("shots") or (bench and bench.running):
			life.step(minf(delta, 0.1))
	day_night.update_time(city.time_of_day(), city.game_day())
	if _perf != null and _perf.visible:
		_perf_t -= delta
		if _perf_t <= 0.0:
			_perf_t = 0.25
			var rs := RenderingServer
			_perf.text = "%d fps  %.1f ms  %s\n%d draw calls  %dk triangles" % [
				Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0),
				["Low", "Med", "High"][quality],
				rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
				rs.get_rendering_info(rs.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000]


func _toggle_perf() -> void:
	if _perf == null:
		var layer := CanvasLayer.new()
		layer.layer = 50
		add_child(layer)
		_perf = Label.new()
		_perf.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_perf.position = Vector2(-250, 64)
		_perf.custom_minimum_size = Vector2(236, 0)
		_perf.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_perf.add_theme_font_size_override("font_size", 15)
		_perf.add_theme_constant_override("outline_size", 5)
		_perf.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		_perf.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(_perf)
		_perf.visible = false
	_perf.visible = not _perf.visible
	_perf_t = 0.0
