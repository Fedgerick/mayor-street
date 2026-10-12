extends Node3D
## Planet prototype: New Harbor on a ball (planet/PLAN.md). Orbit the globe as the mayor,
## paint roads and zones and watch the city grow, then drop to the street (Tab) to walk
## and drive all the way round. Runs on its own scene so the real game is untouched.
##
## Mayor: WASD / arrows or middle-drag pan, right-drag or Q/E turn, wheel zoom (out to
## the whole globe). Tools: 1 road, 2 homes, 3 shops, 4 industry, 5 bulldoze, 0 none.
## Street: Tab, WASD walk, Shift run, Space jump, E get in or out of a car, Tab back up.
## T skips two hours. Command line: --planet-size=small|medium|large (Fedge picked large),
## --shots=DIR.

enum Mode { MAYOR, WALK, DRIVE }
enum Tool { NONE, ROAD, RES, COM, IND, BULLDOZE }

const SIZES := {"small": [160, 30], "medium": [192, 36], "large": [288, 52]}
const TOOL_NAMES := ["None", "Road", "Homes", "Shops", "Industry", "Bulldoze"]
const TOOL_COLORS := [Color.WHITE, Color(0.9, 0.9, 0.9), Color(0.25, 0.85, 0.35), Color(0.25, 0.55, 1.0), Color(1.0, 0.75, 0.15), Color(1.0, 0.25, 0.2)]
const MIN_DIST := 25.0
const MAX_DIST := 2400.0

var grid: PlanetGrid
var view: PlanetView
var day_night: DayNight
var cam: Camera3D
var walker: PlanetWalker
var car: PlanetCar = null
var cars: Array[PlanetCar] = []
var mode := Mode.MAYOR
var tool := Tool.NONE
var hour := 10.0
var day := 0

# Mayor camera: a flat focus point, heading (0 = north) and distance.
var focus := Vector3.ZERO
var heading := 0.0
var dist := 260.0
var _goal_dist := 260.0
# Street camera: heading and pitch in the player's local frame.
var s_yaw := 0.0
var s_pitch := -0.2
var _s_idle := 0.0
var _s_target := Vector3.ZERO
var _drag_start := Vector2i(-9999, -9999)
var _dragging := false
var _hud: Label
var _help: Label
var _fps_t := 0.0
var _shots_dir := ""
var _atmo: ShaderMaterial
var _space_sky: Sky
var _day_sky: Sky


func _ready() -> void:
	var size := "large"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--planet-size="):
			size = a.get_slice("=", 1)
		elif a.begins_with("--shots="):
			_shots_dir = a.get_slice("=", 1)
	var dims: Array = SIZES.get(size, SIZES["medium"])
	Planet.configure(dims[0], dims[1])
	StreetInput.ensure()
	_gravity()
	day_night = DayNight.new()
	add_child(day_night)
	day_night.apply_quality(1)
	grid = PlanetGrid.new()
	grid.build_starter()
	view = PlanetView.new()
	add_child(view)
	view.setup(grid)
	cam = Camera3D.new()
	cam.near = 0.1
	cam.far = 6000.0
	cam.fov = 60.0
	add_child(cam)
	cam.current = true
	focus = grid.cell_center(0, grid.h / 2 - 3)
	heading = 0.0
	walker = PlanetWalker.new()
	walker.name = "Walker"
	_park_cars()
	_make_space()
	_make_hud()
	_update_mayor_cam(0.0)
	view.flush()
	if _shots_dir != "":
		_run_shots()


func _gravity() -> void:
	## Point gravity toward the centre for everything physical (cars, falling things): the
	## space's own default area pulls toward the origin instead of down -Y.
	var space := get_world_3d().space
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_IS_POINT, true)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, Vector3.ZERO)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY_POINT_UNIT_DISTANCE, 0.0)
	PhysicsServer3D.area_set_param(space, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.8)


func _make_space() -> void:
	var shell := SphereMesh.new()
	shell.radius = Planet.R * 1.07
	shell.height = Planet.R * 2.14
	shell.radial_segments = 96
	shell.rings = 48
	_atmo = ShaderMaterial.new()
	_atmo.shader = preload("res://planet/atmosphere.gdshader")
	shell.material = _atmo
	var mi := MeshInstance3D.new()
	mi.name = "Atmosphere"
	mi.mesh = shell
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_space_sky = Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://planet/space_sky.gdshader")
	_space_sky.sky_material = sm
	_day_sky = day_night.env.sky


func _park_cars() -> void:
	var models := ["car_sedan", "car_sports", "car_taxi", "car_pickup", "car_hatch", "car_police", "car_van"]
	var eq := grid.h / 2
	var k := 0
	# Along the equator highway, every 16 tiles round the planet.
	for x in range(0, grid.w, 16):
		_add_car(models[k % models.size()], grid.cell_center(x + 2, eq) + Vector3(0, 0, 3.2), PI * 0.5)
		k += 1
	# A couple by the drop-in point.
	_add_car("car_sports", grid.cell_center(1, eq) + Vector3(0, 0, -3.2), -PI * 0.5)
	_add_car("car_police", grid.cell_center(5, grid.h / 2 - 5) + Vector3(-3.2, 0, 0), 0.0)


func _add_car(model: String, flat: Vector3, yaw: float) -> void:
	var c := PlanetCar.new()
	c.model = model
	c.tint = Kit.CAR_TINTS[randi() % Kit.CAR_TINTS.size()] if model != "car_police" else Color(0.1, 0.1, 0.12)
	add_child(c)
	# Our cars drive along +Z; yaw is the heading in the flat map (0 = south).
	var p := flat + Vector3(0, 0.55, 0)
	c.global_transform = Transform3D(Planet.frame(p) * Basis(Vector3.UP, yaw), Planet.warp(p))
	cars.append(c)


# ------------------------------------------------------------------- input ---

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		match e.physical_keycode:
			KEY_TAB:
				if mode == Mode.MAYOR:
					_enter_street()
				else:
					_leave_street()
				return
			KEY_T:
				hour += 2.0
			KEY_E:
				if mode == Mode.WALK:
					_try_enter_car()
				elif mode == Mode.DRIVE:
					_exit_car()
			KEY_ESCAPE:
				if mode != Mode.MAYOR:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
				else:
					_set_tool(Tool.NONE)
		if mode == Mode.MAYOR:
			match e.physical_keycode:
				KEY_1: _set_tool(Tool.ROAD)
				KEY_2: _set_tool(Tool.RES)
				KEY_3: _set_tool(Tool.COM)
				KEY_4: _set_tool(Tool.IND)
				KEY_5: _set_tool(Tool.BULLDOZE)
				KEY_0: _set_tool(Tool.NONE)
	if mode == Mode.MAYOR:
		_mayor_input(e)
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		s_yaw -= e.relative.x * 0.0025
		s_pitch = clampf(s_pitch - e.relative.y * 0.0025, -1.2, 0.5)
		_s_idle = 0.0


func _mayor_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_goal_dist = maxf(_goal_dist / 1.15, MIN_DIST)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_goal_dist = minf(_goal_dist * 1.15, MAX_DIST)
		elif e.button_index == MOUSE_BUTTON_LEFT and tool != Tool.NONE:
			var c = _cell_under(e.position)
			if e.pressed and c != null:
				_drag_start = c
				_dragging = true
				_preview(c)
			elif not e.pressed and _dragging:
				_dragging = false
				if c != null:
					_apply_tool(_drag_start, c)
				view.set_preview([], Color.WHITE)
	elif e is InputEventMouseMotion:
		if e.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			heading -= e.relative.x * 0.005
		elif e.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan(Vector2(-e.relative.x, e.relative.y) * dist * 0.0018)
		elif _dragging:
			var c = _cell_under(e.position)
			if c != null:
				_preview(c)


func _set_tool(t: Tool) -> void:
	tool = t
	_dragging = false
	view.set_preview([], Color.WHITE)
	RenderingServer.global_shader_parameter_set("grid_alpha", 0.0 if t == Tool.NONE else 1.0)


func _cell_under(screen: Vector2) -> Variant:
	var from := cam.project_ray_origin(screen)
	var dir := cam.project_ray_normal(screen)
	var hit = Planet.ray_hit(from, dir, 0.0)
	if hit == null:
		return null
	var c := grid.world_to_cell(Planet.unwarp(hit))
	return c if grid.inside(c.x, c.y) else null


func _cells_for(a: Vector2i, b: Vector2i) -> Array:
	return grid.road_path(a, b) if tool == Tool.ROAD else grid.rect_cells(a, b)


func _preview(c: Vector2i) -> void:
	view.set_preview(_cells_for(_drag_start, c), TOOL_COLORS[tool])


func _apply_tool(a: Vector2i, b: Vector2i) -> void:
	var cells := _cells_for(a, b)
	match tool:
		Tool.ROAD: grid.place_road(cells)
		Tool.RES: grid.place_zone(cells, 1)
		Tool.COM: grid.place_zone(cells, 2)
		Tool.IND: grid.place_zone(cells, 3)
		Tool.BULLDOZE: grid.bulldoze(cells)


func _pan(v: Vector2) -> void:
	## v: metres right and forward on the ground.
	var lat := Planet.lat_of(focus)
	var d := Basis(Vector3.UP, heading) * Vector3(v.x, 0.0, -v.y)
	focus.x = Planet.wrap_x(focus.x + d.x / maxf(cos(lat), 0.2))
	focus.z = clampf(focus.z + d.z, -Planet.R * 1.2, grid.h * Planet.TILE + Planet.R * 1.2)


# ------------------------------------------------------------------ street ---

func _enter_street() -> void:
	# Drop onto the nearest road to the middle of the view.
	var c := grid.world_to_cell(focus)
	var best := Vector2i(-1, -1)
	var bd := 1e9
	for dy in range(-8, 9):
		for dx in range(-8, 9):
			var n := Vector2i(c.x + dx, c.y + dy)
			if grid.is_road(n.x, n.y) and dx * dx + dy * dy < bd:
				bd = dx * dx + dy * dy
				best = n
	var flat := grid.cell_center(best.x, best.y) if best.x >= 0 else focus
	flat.y = maxf(grid.ground_height(flat.x, flat.z), 0.0) + 0.3
	if walker.get_parent() == null:
		add_child(walker)
	walker.visible = true
	walker.process_mode = Node.PROCESS_MODE_INHERIT
	walker.place(Planet.warp(flat + Vector3(3.5, 0, 0)), heading)
	s_yaw = heading
	s_pitch = -0.2
	_s_target = walker.global_position
	mode = Mode.WALK
	_set_tool(Tool.NONE)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _leave_street() -> void:
	if mode == Mode.DRIVE:
		_exit_car()
	focus = Planet.unwarp(walker.global_position)
	focus.y = 0.0
	heading = s_yaw
	dist = 140.0
	_goal_dist = 260.0
	walker.visible = false
	walker.process_mode = Node.PROCESS_MODE_DISABLED
	mode = Mode.MAYOR
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _try_enter_car() -> void:
	var best: PlanetCar = null
	var bd := 5.0
	for c in cars:
		var d := c.global_position.distance_to(walker.global_position)
		if d < bd and not c.wrecked:
			bd = d
			best = c
	if best == null:
		return
	car = best
	walker.visible = false
	walker.process_mode = Node.PROCESS_MODE_DISABLED
	walker.collision_layer = 0
	car.set_driver(walker)
	mode = Mode.DRIVE


func _exit_car() -> void:
	if car == null:
		return
	var p := car.exit_point()
	car.set_driver(null)
	walker.collision_layer = 1
	walker.visible = true
	walker.process_mode = Node.PROCESS_MODE_INHERIT
	walker.place(p, s_yaw)
	car = null
	mode = Mode.WALK


# ----------------------------------------------------------------- per frame ---

func _process(delta: float) -> void:
	hour += delta / 30.0
	if hour >= 24.0:
		hour -= 24.0
		day += 1
	grid.advance(delta)
	if mode == Mode.MAYOR:
		var mv := Input.get_vector("ui_left", "ui_right", "ui_down", "ui_up")
		if Input.is_physical_key_pressed(KEY_A): mv.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D): mv.x += 1.0
		if Input.is_physical_key_pressed(KEY_W): mv.y += 1.0
		if Input.is_physical_key_pressed(KEY_S): mv.y -= 1.0
		if mv != Vector2.ZERO:
			_pan(mv.limit_length(1.0) * dist * 1.1 * delta)
		if Input.is_physical_key_pressed(KEY_Q): heading += 1.6 * delta
		if Input.is_physical_key_pressed(KEY_E): heading -= 1.6 * delta
		_update_mayor_cam(delta)
	else:
		_update_street_cam(delta)
	_update_sky()
	_fps_t -= delta
	if _fps_t <= 0.0:
		_fps_t = 0.25
		_update_hud()


func _mayor_pitch(d: float) -> float:
	return deg_to_rad(lerpf(-34.0, -89.0, smoothstep(90.0, 1500.0, d)))


func _update_mayor_cam(delta: float) -> void:
	dist = lerpf(dist, _goal_dist, 1.0 - exp(-8.0 * delta)) if delta > 0.0 else _goal_dist
	var q := Planet.frame(focus)
	var target := Planet.warp(focus)
	var p := _mayor_pitch(dist)
	var hb := Basis(Vector3.UP, heading)
	var back := hb * Vector3(0, 0, 1)
	var offset := back * cos(p) * dist + Vector3.UP * sin(-p) * dist
	var pos := target + q * offset
	_aim(pos, target, q * (hb * Vector3.RIGHT))
	day_night.set_view_distance(dist)


func _aim(pos: Vector3, target: Vector3, right: Vector3) -> void:
	var z := (pos - target).normalized()
	var y := z.cross(right).normalized()
	var x := y.cross(z)
	cam.global_transform = Transform3D(Basis(x, y, z), pos)


func _update_street_cam(delta: float) -> void:
	var body: Node3D = car if mode == Mode.DRIVE else walker
	var q := Planet.frame_world(body.global_position)
	_s_idle += delta
	var st := StreetInput.look_stick()
	if st != Vector2.ZERO:
		s_yaw -= st.x * 2.6 * delta
		s_pitch = clampf(s_pitch - st.y * 1.8 * delta, -1.2, 0.5)
		_s_idle = 0.0
	var height := 1.55
	var boom := 3.6
	if mode == Mode.DRIVE:
		height = 2.0
		boom = 7.5
		# Swing round behind the car when the mouse is left alone.
		var f := q.inverse() * car.forward()
		var car_yaw := atan2(-f.x, -f.z)
		if _s_idle > 1.0 and car.speed() > 2.0:
			s_yaw = lerp_angle(s_yaw, car_yaw, 1.0 - exp(-3.0 * delta))
			s_pitch = lerpf(s_pitch, -0.2, 1.0 - exp(-1.5 * delta))
	walker.cam_yaw = s_yaw
	var goal := body.global_position + q.y * height
	_s_target = _s_target.lerp(goal, 1.0 - exp(-18.0 * delta))
	var dirl := Basis(Vector3.UP, s_yaw) * Basis(Vector3.RIGHT, s_pitch) * Vector3(0, 0, 1)
	var want := _s_target + q * dirl * boom
	# Pull in so walls don't get between the camera and the player.
	var space := get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(_s_target, want, 1)
	ray.exclude = [walker.get_rid()] if mode == Mode.WALK else [car.get_rid()]
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		want = _s_target + (hit.position - _s_target) * 0.9
	_aim(want, _s_target, q * (Basis(Vector3.UP, s_yaw) * Vector3.RIGHT))
	day_night.set_view_distance(60.0)


## Sun and sky follow the spot under the camera: street level looks like the flat game,
## and from orbit the far side of the ball falls into night.
func _update_sky() -> void:
	var where: Vector3 = Planet.warp(focus) if mode == Mode.MAYOR else (car if mode == Mode.DRIVE else walker).global_position
	var q := Planet.frame_world(where)
	day_night.update_time(hour, day)
	day_night.light.basis = q * day_night.light.basis
	RenderingServer.global_shader_parameter_set("sun_dir", day_night.light.basis.z)
	var env := day_night.env
	env.sky_rotation = q.get_euler()
	var alt := cam.global_position.length() - Planet.R
	var space := smoothstep(350.0, 900.0, alt)
	env.fog_enabled = space < 0.5
	var want_sky := _space_sky if space > 0.5 else _day_sky
	if env.sky != want_sky:
		env.sky = want_sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR if space > 0.5 else Environment.AMBIENT_SOURCE_SKY
	if space > 0.5:
		env.ambient_light_color = Color(0.35, 0.38, 0.45)
		env.ambient_light_energy = 0.6
	_atmo.set_shader_parameter("strength", smoothstep(250.0, 700.0, alt))
	_atmo.set_shader_parameter("sun_world", day_night.light.basis.z)


# --------------------------------------------------------------------- HUD ---

func _make_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(18, 14)
	_hud.add_theme_font_size_override("font_size", 20)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(_hud)
	_help = Label.new()
	_help.anchor_top = 1.0
	_help.anchor_bottom = 1.0
	_help.offset_top = -60
	_help.offset_left = 18
	_help.add_theme_font_size_override("font_size", 16)
	_help.add_theme_color_override("font_outline_color", Color.BLACK)
	_help.add_theme_constant_override("outline_size", 5)
	layer.add_child(_help)


func _update_hud() -> void:
	var where := Planet.unwarp(cam.global_position)
	var lat := rad_to_deg(Planet.lat_of(where))
	var lon := rad_to_deg(Planet.lon_of(where))
	_hud.text = "PLANET PROTOTYPE   %d x %d tiles, radius %d m\nPopulation %d   Jobs %d   %02d:%02d   %d fps\nLat %.1f%s  Lon %.1f   Tool: %s" % [
		Planet.W, Planet.H, roundi(Planet.R), grid.population, grid.jobs, int(hour), int(fmod(hour, 1.0) * 60.0),
		Engine.get_frames_per_second(), absf(lat), "N" if lat >= 0.0 else "S", lon, TOOL_NAMES[tool]]
	if mode == Mode.MAYOR:
		_help.text = "WASD pan   Q/E or right-drag turn   wheel zoom (out to the globe)\n1 road  2 homes  3 shops  4 industry  5 bulldoze  0 none   drag to build   Tab walk   T +2 hours"
	elif mode == Mode.WALK:
		_help.text = "WASD walk   Shift run   Space jump   mouse look   E get in a car   Tab back to mayor\nFollow the equator highway all the way round, or head north to the ice cap or south to the sea"
	else:
		_help.text = "W/S drive   A/D steer   Space handbrake   R flip upright   E get out   Tab back to mayor"


# ------------------------------------------------------------------- shots ---

## Look-dev: fixed views saved as PNGs, then quit (--shots=DIR).
func _run_shots() -> void:
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	await _settle(10)
	var views := [
		["globe", Vector3(0, 0, grid.h * 6.0), 0.4, 1400.0],
		["orbit", Vector3(0, 0, grid.h * 6.0), 0.3, 900.0],
		["city", grid.cell_center(0, grid.h / 2), 0.6, 260.0],
		["low", grid.cell_center(2, grid.h / 2), 0.9, 70.0],
		["icecap", Vector3(0, 0, -120.0), 3.1, 500.0],
		["sea", Vector3(Planet.circumference() * 0.25, 0, grid.h * Planet.TILE + 60.0), 0.0, 400.0],
	]
	for v in views:
		focus = v[1]
		heading = v[2]
		_goal_dist = v[3]
		dist = v[3]
		_update_mayor_cam(0.0)
		await _settle(8)
		await _shot(v[0])
	_enter_street()
	walker.place(Planet.warp(grid.cell_center(1, grid.h / 2) + Vector3(0, 0.5, 4.0)), PI * 0.5)
	s_yaw = PI * 0.5
	s_pitch = -0.12
	await _settle(40)
	await _shot("street")
	s_yaw = 0.0
	await _settle(20)
	await _shot("street_north")
	walker.place(cars[0].global_position + Planet.up_at(cars[0].global_position) * 0.5 + Planet.frame_world(cars[0].global_position).z * 2.5, 0.0)
	await _settle(5)
	_try_enter_car()
	await _settle(30)
	var start := Planet.unwarp(car.global_position)
	Input.action_press("street_forward")
	await _settle(150)
	Input.action_release("street_forward")
	var moved := Planet.dx(start.x, Planet.unwarp(car.global_position).x)
	print("DRIVE moved %.1f m east, upright %.2f, height %.2f, speed %.1f" % [moved,
		car.global_basis.y.dot(Planet.up_at(car.global_position)), Planet.unwarp(car.global_position).y, car.speed()])
	await _shot("drive")
	print("PLANET_SHOTS_DONE visible chunks %d of %d, buildings %d, pop %d" % [view.visible_chunks(), view.chunks.size(), grid.buildings.size(), grid.population])
	get_tree().quit()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _shot(nm: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shots_dir.path_join(nm + ".png"))
	print("shot %s  fps %d  draws %d  tris %d" % [nm, Engine.get_frames_per_second(),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
