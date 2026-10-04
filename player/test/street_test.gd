extends Node3D
## Street-level test bed on the real demo city: mayor camera, Tab to dive to the street
## and back, walk, sprint, jump, get into a car (E) and drive.
##
## Command-line options (after `--`):
##   --hour=21          set the clock (night shows headlights and lit windows)
##   --street           start at street level (skips the mayor view)
##   --shots=dir        render a sequence of screenshots into dir, then quit
##   --life             add traffic, people and police (citylife/)
##   --action-shots=dir render the street action set (guns, carjack, HUD, Wasted)

var city: City
var view: CityView
var day_night: DayNight
var cam: MayorCamera
var street: StreetMode
var life: CityLife
var with_life := false
var _args := {}
var _in_street := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	StreetInput.ensure()
	city = City.new()
	day_night = DayNight.new()
	add_child(day_night)
	view = CityView.new()
	add_child(view)
	view.setup(city)
	city.build_demo()
	city.minutes = float(city.game_day()) * 1440.0 + float(_args.get("hour", "16.5")) * 60.0
	view.rebuild_all()
	day_night.update_time(city.time_of_day())
	cam = MayorCamera.new()
	add_child(cam)
	var c := city.cell_center(city.center_cell().x, city.center_cell().y)
	cam.set_view(c + Vector3(0, 0, 30), 260.0, deg_to_rad(-35.0))
	cam.moved.connect(day_night.set_view_distance)
	cam.make_current()
	street = preload("res://player/scenes/street_mode.tscn").instantiate()
	add_child(street)
	street.setup(city)
	street.street_exited.connect(_on_street_exited)
	street.street_entered.connect(func(): day_night.set_view_distance(30.0))
	if with_life or _args.has("life") or _args.has("action-shots"):
		life = CityLife.new()
		add_child(life)
		life.setup(city, cam)
		street.set_life(life)
	if _args.has("action-shots"):
		_action_shots.call_deferred(_args["action-shots"])
	elif _args.has("shots"):
		_shots.call_deferred(_args["shots"])
	elif _args.has("street"):
		go_street.call_deferred()


func _snap(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shots(dir: String) -> void:
	## A scripted run for screenshots: the mayor view, the dive, on foot, and driving.
	DirAccess.make_dir_recursive_absolute(dir)
	var tag: String = _args.get("hour", "16.5")
	await _wait(1.0)
	await _snap("%s/%s_1_mayor.png" % [dir, tag])
	go_street()
	await _wait(street.dive_seconds * 0.55)
	await _snap("%s/%s_2_dive.png" % [dir, tag])
	await street.street_entered
	await _wait(0.5)
	await _snap("%s/%s_3_street.png" % [dir, tag])
	street.player.rig.yaw += PI * 0.75
	Input.action_press("street_forward")
	Input.action_press("street_sprint")
	await _wait(1.2)
	await _snap("%s/%s_4_running.png" % [dir, tag])
	Input.action_release("street_sprint")
	Input.action_release("street_forward")
	var near: DrivableCar = null
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.model == "car_truck":
			continue
		if near == null or v.global_position.distance_to(street.player.global_position) < near.global_position.distance_to(street.player.global_position):
			near = v
	street.player.place(near.exit_point(), near.heading_yaw())
	var d := near.global_position - street.player.global_position
	street.player.rig.yaw = near.heading_yaw() - 1.1
	street.player.rig.pitch = deg_to_rad(-8.0)
	await _wait(0.3)
	await _snap("%s/%s_5_car_door.png" % [dir, tag])
	street.player.rig.pitch = deg_to_rad(-22.0)
	street._enter_car(near)
	await _wait(0.22)
	await _snap("%s/%s_5b_getting_in.png" % [dir, tag])
	await _wait(0.6)
	Input.action_press("street_forward")
	await _wait(2.5)
	await _snap("%s/%s_6_driving.png" % [dir, tag])
	Input.action_release("street_forward")
	get_tree().quit()


func go_street() -> void:
	if _in_street or street.busy:
		return
	_in_street = true
	cam.set_process(false)
	cam.set_process_unhandled_input(false)
	street.enter_street(cam, cam.focus)
	if life:
		life.set_camera(street.camera)


func go_mayor() -> void:
	if not _in_street or street.busy:
		return
	# Frame the mayor view on where the player ended up, looking the same way.
	cam.set_view(street.focus_point(), 140.0, street.view_yaw())
	street.exit_street(cam.global_transform, cam.fov)


func _on_street_exited() -> void:
	_in_street = false
	if life:
		life.set_camera(cam)
	cam.make_current()
	cam.set_process(true)
	cam.set_process_unhandled_input(true)
	day_night.set_view_distance(cam.dist)


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("street_toggle_view"):
		if _in_street:
			go_mayor()
		else:
			go_street()


func _process(delta: float) -> void:
	city.advance(delta, 1.0)
	day_night.update_time(city.time_of_day())


func _yaw_to(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return atan2(-d.x, -d.z)


func _near_ped(max_d := 40.0, min_d := 4.0):
	var best = null
	var bd := max_d
	for q in life.crowd.peds:
		var d: float = q.pos.distance_to(street.player.global_position)
		if d < bd and d > min_d:
			best = q
			bd = d
	return best


func _action_shots(dir: String) -> void:
	## Street action for screenshots: aiming, firing, a carjack, a car blowing up,
	## and the Wasted and Busted cards.
	DirAccess.make_dir_recursive_absolute(dir)
	var tag: String = _args.get("hour", "16.5")
	var p := street.player
	go_street()
	await street.street_entered
	await _wait(3.0)
	street.combat.give(&"pistol")
	p.add_armor(60.0)
	street.set_wanted(2)
	# 1: walking with a pistol, wanted.
	p.rig.pitch = deg_to_rad(-10.0)
	await _wait(0.6)
	await _snap("%s/%s_a1_pistol.png" % [dir, tag])
	# 2: aiming at someone.
	var ped = _near_ped()
	if ped:
		p.rig.yaw = _yaw_to(p.global_position, ped.pos)
		p.face(p.rig.yaw)
	p.rig.pitch = deg_to_rad(-4.0)
	Input.action_press("street_aim")
	await _wait(0.8)
	await _snap("%s/%s_a2_aim.png" % [dir, tag])
	# 3: shotgun blast.
	street.combat.give(&"shotgun")
	street.combat.select(&"shotgun")
	await _wait(0.5)
	street.combat._cool = 0.0
	street.combat.fire()
	await _wait(0.02)
	await _snap("%s/%s_a3_shotgun.png" % [dir, tag])
	Input.action_release("street_aim")
	street.heat.clear()
	await _wait(1.0)
	# 4: a carjack.
	var tc = null
	for k in life.traffic.cars:
		if not k.garbage and k.pos.distance_to(p.global_position) < 200.0:
			tc = k
			break
	if tc:
		var side := Vector3(-tc.fwd.z, 0, tc.fwd.x)
		p.place(tc.pos + side * 2.8 + Vector3.UP * 0.3, 0.0)
		tc.v = 0.0
		street.combat.select(&"fists")
		p.rig.yaw = _yaw_to(tc.pos + side * 2.8, tc.pos) + 1.2
		p.rig.pitch = deg_to_rad(-16.0)
		street._carjack(tc)
		await _wait(0.75)
		await _snap("%s/%s_a4_carjack.png" % [dir, tag])
		await _wait(3.0)
		if street.car:
			street._leave_car()
			await _wait(1.6)
	# 5: a car on fire, then the blast.
	var c := street.spawn_car("car_sedan", p.global_position + p.rig.forward_flat() * 11.0 + Vector3.UP * 0.3, p.rig.yaw + 1.2, Color(0.15, 0.3, 0.7))
	p.rig.yaw = _yaw_to(p.global_position, c.global_position)
	p.rig.pitch = deg_to_rad(-8.0)
	await _wait(0.6)
	c.take_hit(1000.0)
	await _wait(2.5)
	await _snap("%s/%s_a5_burning.png" % [dir, tag])
	await _wait(DrivableCar.BURN_SECONDS - 2.5 + 0.12)
	await _snap("%s/%s_a6_explosion.png" % [dir, tag])
	await _wait(1.5)
	# 6: Wasted.
	p.hurt(1000.0)
	await _wait(2.0)
	await _snap("%s/%s_a7_wasted.png" % [dir, tag])
	await _wait(5.0)
	# 7: Busted.
	street.set_wanted(1)
	street.bust()
	await _wait(1.5)
	await _snap("%s/%s_a8_busted.png" % [dir, tag])
	await _wait(5.0)
	# 8: pickups on the sidewalk.
	for k in Pickup.KINDS.size():
		street.spawn_pickup(Pickup.KINDS[k], p.global_position + p.rig.forward_flat() * (3.0 + k * 1.6) + p.rig.right_flat() * 0.8 - Vector3.UP * 0.1)
	p.rig.pitch = deg_to_rad(-20.0)
	await _wait(0.6)
	await _snap("%s/%s_a9_pickups.png" % [dir, tag])
	get_tree().quit()
