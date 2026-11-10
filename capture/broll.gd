extends SceneTree
## B-roll capture for msp: a fixed list of cinematic shots of the demo city, played through
## once so Godot's movie writer can record it frame by frame.
##
##   godot --path . -s res://capture/broll.gd --write-movie out.avi --fixed-fps 30 \
##       --resolution 1920x1080 -- --demo --nosave --quality=2 [--only=a,b] [--log=shots.json] [--scale=0.1]
##
## --only picks shots by name, --scale shortens every shot (for quick previews). The log lists
## each shot's first and last recorded frame (the settle frames before a shot are left out),
## for the edit. Nothing in the game is changed: this only drives the camera and the clock.

var main: Node
var d: Director


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	while not main.started:
		await process_frame
	d = Director.new()
	d.name = "Director"
	main.add_child(d)
	await d.film(main)
	quit()


class Director extends Benchmark:
	var args := {}
	var only: PackedStringArray = []
	var scale_t := 1.0
	var log_path := "user://broll_shots.json"
	var shots: Array = []
	var film_cam: Camera3D
	var c0: Vector3        # downtown centre, flat metres
	var frame := 0         # frames drawn since filming started
	var _sites: Array = [] # [id, start, rate] for the construction shots

	func film(m: Node) -> void:
		main = m
		for a in OS.get_cmdline_user_args():
			var kv := a.trim_prefix("--").split("=", true, 1)
			args[kv[0]] = kv[1] if kv.size() > 1 else "1"
		only = String(args.get("only", "")).split(",", false)
		scale_t = float(args.get("scale", "1"))
		log_path = args.get("log", log_path)
		running = true
		RenderingServer.frame_pre_draw.connect(_hide_ui)  # after every script has run this frame
		main.bench = self  # main steps traffic and people while a tour runs, with the clock still
		_banner.visible = false
		main.hud.visible = false
		main.menu.show_hint(&"")
		main._set_speed(0)
		main.city.growth_check = func(_x, _y): return false  # the skyline stays as it is
		_hold_arrests(true)
		film_cam = Camera3D.new()
		film_cam.fov = 55.0
		film_cam.near = 0.1
		film_cam.far = 6000.0
		main.add_child(film_cam)
		_shift = main.city.center_cell() - Vector2i(40, 40)
		var cc: Vector2i = main.city.center_cell()
		c0 = main.city.cell_center(cc.x, cc.y)
		_set_weather(Weather.Kind.CLEAR)
		await _frames(20)
		await _mayor_shots()
		await _street_shots()
		_save_log()

	# ------------------------------------------------------------ helpers ---

	func _process(delta: float) -> void:
		super(delta)
		frame += 1

	func _hide_ui() -> void:
		# No HUD, minimap, hints or toasts in the shots.
		for l in _layers(main):
			l.visible = false

	func _layers(n: Node) -> Array:
		var out := []
		for c in n.get_children():
			if c is CanvasLayer:
				out.append(c)
			out.append_array(_layers(c))
		return out

	func want(nm: String) -> bool:
		return only.is_empty() or only.has(nm)

	func shot(nm: String, secs: float, step: Callable, settle := 24) -> void:
		## Settle frames first (sky and shadows catch up after a jump), then the shot itself,
		## calling step(t) with t from 0 to 1 every frame.
		for i in settle:
			step.call(0.0)
			await get_tree().process_frame
		var n := maxi(int(secs * scale_t * 30.0), 2)
		var first := frame
		for i in n:
			step.call(float(i) / float(n - 1))
			await get_tree().process_frame
		shots.append({"name": nm, "first": first, "last": frame - 1, "secs": secs})
		print("shot %s: frames %d-%d" % [nm, first, frame - 1])
		_save_log()

	func _save_log() -> void:
		var f := FileAccess.open(log_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(shots, "  "))

	func mayor(focus: Vector3, dist: float, yaw_deg: float, tilt_deg := 0.0) -> void:
		main.cam.set_view(focus, dist, deg_to_rad(yaw_deg), deg_to_rad(tilt_deg))

	func hour(h: float) -> void:
		_set_hour(h)

	func smooth(t: float) -> float:
		return smoothstep(0.0, 1.0, t)

	func look(from: Vector3, at: Vector3) -> void:
		## The film camera at flat map points: from, looking at at.
		film_cam.make_current()
		var b := Basis.looking_at(at - from, Vector3.UP)
		film_cam.global_transform = Planet.xf_rigid(Transform3D(b, from))

	func use_film(on: bool) -> void:
		if on:
			film_cam.make_current()
			main.life.set_camera(film_cam)
			main.rain_fx.set_camera(film_cam)
		else:
			var c: Camera3D = main.street.camera if main.in_street() else main.cam
			c.make_current()
			main.life.set_camera(c)
			main.rain_fx.set_camera(c)

	func cell(x: int, y: int) -> Vector3:
		## A demo-city cell (island numbering, centre 40, 40) in flat metres.
		return main.city.cell_center(x + _shift.x, y + _shift.y)

	# -------------------------------------------------------- mayor view ---

	func _mayor_shots() -> void:
		var globe := Vector3(c0.x, 0, 216.0)
		if want("globe_day"):
			hour(12.0)
			await shot("globe_day", 14.0, func(t):
				mayor(globe + Vector3(lerpf(300.0, -300.0, t), 0, 0), lerpf(1500.0, 1350.0, t), lerpf(-10.0, 10.0, t)))
		if want("globe_dusk"):
			hour(17.6)
			await shot("globe_dusk", 12.0, func(t):
				mayor(globe + Vector3(lerpf(-200.0, 250.0, t), 0, 0), lerpf(1550.0, 1400.0, t), lerpf(20.0, 0.0, t)), 40)
		if want("globe_night"):
			hour(23.0)
			await shot("globe_night", 12.0, func(t):
				mayor(globe + Vector3(lerpf(250.0, -250.0, t), 0, 0), lerpf(1400.0, 1550.0, t), lerpf(-15.0, 15.0, t)), 40)
		if want("descent"):
			hour(10.5)
			await shot("descent", 14.0, func(t):
				var k := smooth(t)
				mayor(globe.lerp(c0 + Vector3(20, 0, 30), smoothstep(0.0, 0.7, t)),
					exp(lerpf(log(1700.0), log(200.0), k)), lerpf(0.0, -40.0, k), lerpf(0.0, 8.0, k)), 40)
		if want("downtown_orbit"):
			hour(10.8)
			await shot("downtown_orbit", 14.0, func(t):
				mayor(c0 + Vector3(10, 0, 20), 270.0, lerpf(-70.0, 0.0, t), 4.0))
		if want("avenue_flyover"):
			hour(11.2)
			var row := (40 + _shift.y + 0.5) * City.TILE
			await shot("avenue_flyover", 12.0, func(t):
				mayor(Vector3(lerpf(c0.x - 160.0, c0.x + 160.0, t), 0, row), 75.0, -90.0, -14.0))
		if want("construction_wide") or want("construction_close"):
			await _construction()
		if want("day_to_night"):
			await shot("day_to_night", 16.0, func(t):
				hour(lerpf(15.5, 22.5, t))
				mayor(c0 + Vector3(0, 0, 10), 330.0, lerpf(-20.0, 25.0, t), -2.0), 40)
		if want("night_orbit"):
			hour(22.0)
			await shot("night_orbit", 12.0, func(t):
				mayor(c0 + Vector3(-20, 0, 0), lerpf(190.0, 150.0, t), lerpf(120.0, 170.0, t), 10.0), 40)
		if want("night_low"):
			hour(21.5)
			var col := (40 + _shift.x + 0.5) * City.TILE
			await shot("night_low", 10.0, func(t):
				mayor(Vector3(col, 0, lerpf(c0.z + 120.0, c0.z - 120.0, t)), 70.0, 0.0, -18.0), 30)
		if want("ice_cap"):
			hour(12.0)
			await shot("ice_cap", 12.0, func(t):
				mayor(Vector3(c0.x + lerpf(120.0, 260.0, t), 0, -40.0), 420.0, lerpf(170.0, 200.0, t), -20.0), 40)
		if want("belt"):
			hour(13.5)
			await shot("belt", 12.0, func(t):
				mayor(Vector3(c0.x - 30.0 + lerpf(-150.0, 150.0, t), 0, 216.0), 620.0, lerpf(-40.0, -20.0, t)), 30)
		if want("golden_city"):
			hour(18.3)
			await shot("golden_city", 12.0, func(t):
				mayor(c0 + Vector3(30, 0, -10), lerpf(330.0, 260.0, t), lerpf(-30.0, -60.0, t), -28.0), 40)
		if want("rain_city"):
			hour(14.0)
			_set_weather(Weather.Kind.RAIN)
			await shot("rain_city", 12.0, func(t):
				mayor(c0 + Vector3(-10, 0, 10), 140.0, lerpf(30.0, 70.0, t), -6.0), 60)
		if want("fog_morning"):
			hour(7.2)
			_set_weather(Weather.Kind.FOG)
			await shot("fog_morning", 10.0, func(t):
				mayor(c0 + Vector3(0, 0, 20), lerpf(240.0, 200.0, t), lerpf(-110.0, -90.0, t), -12.0), 60)
		_set_weather(Weather.Kind.CLEAR)

	func _construction() -> void:
		## Buildings round downtown go back to being building sites and go up during the shot.
		var city: City = main.city
		hour(10.0)
		var picks := func(cx: int, cy: int, rx: int, ry: int, n: int) -> Array:
			var near: Array = []
			for b in city.buildings.values():
				if b.size >= 1 and not b.has("kind") and absi(b.x - cx) <= rx and absi(b.y - cy) <= ry:
					near.append(b)
			near.sort_custom(func(a, b): return a.size * 10 + a.stage > b.size * 10 + b.stage)
			return near.slice(0, n)
		var re_site := func(list: Array) -> Vector3:
			var focus := Vector3.ZERO
			var i := 0
			for b in list:
				var e: Dictionary = b.duplicate()
				city.remove_building(b.id)
				var id := city.add_building(e.x, e.y, e.size, e.zone, e.stage, e.rot)
				city.sites[id].built = 0.0
				# Staggered: each site starts a little later and some are already under way.
				_sites.append([id, -0.25 * float(i % 4) + (0.2 if i % 3 == 0 else 0.0), 1.15 + 0.1 * float(i % 3)])
				focus += city.building_center(city.sites[id])
				i += 1
			return focus / maxf(i, 1.0)
		var grow := func(t: float) -> void:
			for s in _sites:
				if city.sites.has(s[0]):
					city.sites[s[0]].built = clampf(s[1] + t * s[2], 0.0, 1.0)
			city._advance_sites(0.001)  # finishes the ones that reached 1
		var cc: Vector2i = city.center_cell()
		if want("construction_wide"):
			_sites.clear()
			var f: Vector3 = re_site.call(picks.call(cc.x + 3, cc.y + 2, 4, 3, 12))
			await shot("construction_wide", 16.0, func(t):
				grow.call(t)
				mayor(f, lerpf(190.0, 150.0, t), lerpf(-40.0, 10.0, t), -12.0), 30)
		if want("construction_close"):
			_sites.clear()
			var f: Vector3 = re_site.call(picks.call(cc.x - 6, cc.y - 4, 3, 3, 6))
			await shot("construction_close", 14.0, func(t):
				grow.call(t)
				mayor(f, lerpf(95.0, 75.0, t), lerpf(40.0, 80.0, t), -8.0), 30)

	# ------------------------------------------------------- street level ---

	func _street_shots() -> void:
		var st: Node = main.street
		hour(11.0)
		_set_weather(Weather.Kind.CLEAR)
		var walk_a := _walk_point(0.0)
		# The signature zoom from the mayor view down to the sidewalk.
		main.cam.set_view(walk_a, 70.0, -PI * 0.5)
		await _frames(20)
		var first := frame
		main.go_street()
		await st.street_entered
		if want("dive"):
			shots.append({"name": "dive", "first": first, "last": frame - 1, "secs": 0})
		main._set_speed(0)
		hour(11.0)
		var p: StreetPlayer = st.player
		p.set_controls(false)
		p.set_puppet(true)
		const WALK := 1.7
		var walk := func(t: float, secs: float, speed: float) -> Vector3:
			var at := _walk_point(0.0) + Vector3(t * secs * speed * scale_t, 0, 0)
			p.global_position = Planet.place(at)
			p.face(-PI * 0.5)
			p.visual.animate(get_process_delta_time(), speed, true, 0.0, 0.0)
			return at
		if want("walk_follow"):
			await shot("walk_follow", 14.0, func(t):
				walk.call(t, 14.0, WALK)
				p.rig.yaw = -PI * 0.5 + lerpf(0.5, -0.3, t)
				p.rig.pitch = deg_to_rad(-6.0), 10)
		if want("hero_front"):
			# The redesigned character walking toward the camera, which backs away ahead of them.
			use_film(true)
			await shot("hero_front", 10.0, func(t):
				var at: Vector3 = walk.call(t, 10.0, WALK)
				look(at + Vector3(2.6 - 0.6 * t, 1.45, 0.7), at + Vector3(0, 1.25, 0)), 10)
			use_film(false)
		if want("crowd_corner"):
			use_film(true)
			var corner := cell(43, 40) + Vector3(-7.0, 0, -7.0)
			await shot("crowd_corner", 12.0, func(t):
				var eye := corner + Vector3(lerpf(-3.0, 3.0, t), 1.6, 0)
				look(eye, eye + Vector3(-8.0, -0.4, -10.0)), 60)
			use_film(false)
		if want("traffic"):
			use_film(true)
			var junction := cell(46, 40)
			await shot("traffic", 12.0, func(t):
				var a := lerpf(-0.4, 0.4, t)
				var eye := junction + Vector3(9.0, 7.0, 9.0)
				look(eye, junction + Vector3(-14.0 * cos(a), 0, -14.0 * sin(a) - 4.0)), 60)
			use_film(false)
		# Into a car for the drives.
		await _get_in_car()
		if want("drive_follow"):
			await shot("drive_follow", 15.0, func(_t): pass, 20)
		if want("drive_side"):
			use_film(true)
			await shot("drive_side", 10.0, func(t):
				var cf := Planet.flat(_car.global_position)
				var fwd := _car_fwd()
				var side := fwd.cross(Vector3.UP)
				look(cf - side * 4.8 + fwd * lerpf(3.0, -3.0, t) + Vector3.UP * 1.4, cf + fwd * 1.5 + Vector3.UP * 0.6), 5)
			use_film(false)
		if want("chase") or want("chase_front"):
			_top = CHASE_SPEED
			main.street.set_wanted(CHASE_STARS)
			await _wait(4.0)
			if want("chase"):
				await shot("chase", 18.0, func(_t): _keep_car_whole(), 0)
			if want("chase_front"):
				use_film(true)
				await shot("chase_front", 12.0, func(_t):
					_keep_car_whole()
					var cf := Planet.flat(_car.global_position)
					var fwd := _car_fwd()
					look(cf + fwd * 9.0 + Vector3.UP * 2.2, cf - fwd * 6.0 + Vector3.UP * 0.8), 0)
				use_film(false)
			main.street.set_wanted(0)
			_top = DRIVE_SPEED
			await _wait(3.0)
		if want("golden_drive"):
			hour(18.4)
			await shot("golden_drive", 12.0, func(_t): _keep_car_whole(), 40)
		if want("night_drive"):
			hour(21.8)
			_set_weather(Weather.Kind.RAIN)
			await shot("night_drive", 12.0, func(_t): _keep_car_whole(), 60)
		# Out of the car for the night walk in the rain.
		_driving = false
		await _back_outside()
		if st.car:
			st._leave_car()
			await _frames(45)
		p.set_controls(false)
		p.place(Planet.place(_walk_point(0.0)), -PI * 0.5)
		p.set_puppet(true)
		if want("night_rain_walk"):
			hour(22.0)
			_set_weather(Weather.Kind.RAIN)
			p.rig.snap()
			await shot("night_rain_walk", 14.0, func(t):
				walk.call(t, 14.0, WALK)
				p.rig.yaw = -PI * 0.5 + lerpf(-0.6, 0.2, t)
				p.rig.pitch = deg_to_rad(-4.0), 60)
		if want("rise"):
			# Back up from the street at night, out to the whole planet.
			hour(22.5)
			_set_weather(Weather.Kind.CLEAR)
			main.street.set_wanted(0)
			await _frames(30)
			main.go_mayor()
			while main.in_street():
				await get_tree().process_frame
			var f0: Vector3 = main.cam.focus
			var y0: float = main.cam.yaw
			await shot("rise", 12.0, func(t):
				var k := smooth(t)
				mayor(f0.lerp(Vector3(f0.x, 0, 216.0), k), exp(lerpf(log(140.0), log(1700.0), k)),
					rad_to_deg(y0) + 40.0 * k, 0.0), 0)

	func _car_fwd() -> Vector3:
		var f := Planet.to_local(_car.global_position, _car.global_transform.basis.z)
		return Vector3(f.x, 0, f.z).normalized()

	func _wait(s: float) -> void:
		for i in int(s * 30.0):
			_keep_car_whole()
			await get_tree().process_frame
