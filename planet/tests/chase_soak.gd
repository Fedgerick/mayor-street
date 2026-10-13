extends SceneTree
## msp police chase soak: boot the planet demo, get in a car, take five stars and keep
## driving, and look for anything that goes non-finite (a NaN transform can crash a GPU).
## godot --path . -s planet/tests/chase_soak.gd -- --demo --nosave [--seconds=60]

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _wait(s: float) -> void:
	await create_timer(s).timeout


func _bad_nodes(n: Node, out: Array) -> void:
	if n is Node3D and n.is_inside_tree():
		var t: Transform3D = (n as Node3D).global_transform
		if not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite() and t.basis.z.is_finite()):
			out.append(n.get_path())
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh:
		var mm := (n as MultiMeshInstance3D).multimesh
		var count := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
		if mm.transform_format == MultiMesh.TRANSFORM_3D:
			for i in count:
				var t := mm.get_instance_transform(i)
				if not (t.origin.is_finite() and t.basis.x.is_finite() and t.basis.y.is_finite() and t.basis.z.is_finite()):
					out.append("%s[%d]" % [n.get_path(), i])
					break
	for c in n.get_children():
		_bad_nodes(c, out)


func _run() -> void:
	var seconds := 60.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seconds="):
			seconds = float(a.get_slice("=", 1))
	print("msp chase soak, %d s" % seconds)
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait(1.0)
	main.go_street()
	var street: StreetMode = main.street
	while not street.active:
		await process_frame
	var p := street.player
	var at := p.global_position + Planet.up(p.global_position) * 0.6
	var car := street.spawn_car("car_sedan", at, 0.0, Color(0.8, 0.2, 0.2))
	await _wait(0.5)
	street._enter_car(car)
	while street.switching:
		await process_frame
	street.set_wanted(5)
	var t := 0.0
	var worst := []
	var max_cops := 0
	var steer_t := 0.0
	Input.action_press("street_forward")
	while t < seconds:
		await _wait(0.5)
		t += 0.5
		steer_t += 0.5
		if street.wanted < 3:
			street.set_wanted(5)
		if street.car == null and not street.switching and not street.down:
			# Got knocked out of it or wrecked: take a new car where we stand.
			var w := street.player.global_position + Planet.up(street.player.global_position) * 0.6
			var c := street.spawn_car("car_sedan", w, 0.0, Color(0.2, 0.3, 0.8))
			await _wait(0.3)
			street._enter_car(c)
			while street.switching:
				await process_frame
		# Weave: left, straight, right.
		var phase := int(steer_t / 3.0) % 4
		Input.action_release("street_left")
		Input.action_release("street_right")
		if phase == 1:
			Input.action_press("street_left")
		elif phase == 3:
			Input.action_press("street_right")
		if street.car:
			street.car.health = DrivableCar.MAX_HEALTH
		street.player.health = StreetPlayer.MAX_HEALTH
		var police = main.life.get("police")
		if police:
			max_cops = maxi(max_cops, police.cars.size())
		if int(t * 2) % 20 == 0:
			print("    %4.0f s  frames %d  buffer MB %.1f  video MB %.1f  tex MB %.1f" % [t, Engine.get_frames_drawn(),
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) / 1048576.0,
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
				RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0])
			print("    %4.0f s  nodes %d  resources %d  objects %d  cops %d  stars %d" % [t,
				Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
				Performance.get_monitor(Performance.OBJECT_COUNT),
				police.cars.size() if police else -1, street.wanted])
		if int(t * 2) % 4 == 0:
			var bad := []
			_bad_nodes(main, bad)
			if not bad.is_empty() and worst.is_empty():
				worst = bad
				print("    non-finite at %.1f s: %s" % [t, bad.slice(0, 8)])
	Input.action_release("street_forward")
	print("    most police cars at once: %d" % max_cops)
	check(max_cops > 0, "the police came")
	check(worst.is_empty(), "every transform stayed finite (%d bad)" % worst.size())
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(fails)
