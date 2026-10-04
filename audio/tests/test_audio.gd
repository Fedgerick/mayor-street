extends SceneTree
## Headless checks for the audio director on the demo city:
##   godot --headless --path . --script res://audio/tests/test_audio.gd
## Exits with code 1 on any failure.

var fails := 0
var audio: AudioDirector


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func wait(sec: float) -> void:
	await create_timer(sec).timeout


func _run() -> void:
	# Use the real autoload if project.godot has it, otherwise make one.
	audio = root.get_node_or_null("Audio")
	if audio == null:
		audio = load("res://audio/audio_director.gd").new()
		audio.name = "Audio"
		root.add_child(audio)
	await process_frame
	var total := AudioDirector.SFX.size() + AudioDirector.AMBIENCE.size() + AudioDirector.MUSIC.size()
	var loaded := 0
	for k in AudioDirector.SFX + AudioDirector.AMBIENCE + AudioDirector.MUSIC:
		if audio.stream(k) != null:
			loaded += 1
	check(loaded == total, "all %d sounds load (%d)" % [total, loaded])
	check((audio.stream("engine_idle_loop") as AudioStreamOggVorbis).loop, "engine loop is set to loop")
	check(not (audio.stream("door_close") as AudioStreamOggVorbis).loop, "one-shots don't loop")
	var a: float = audio.stream("music_mayor").get_length()
	var b: float = audio.stream("music_street").get_length()
	var c: float = audio.stream("music_drive").get_length()
	check(absf(a - b) < 0.01 and absf(a - c) < 0.01, "music stems are the same length (%.2f %.2f %.2f)" % [a, b, c])
	for bus in ["Music", "Ambience", "SFX", "UI"]:
		check(AudioServer.get_bus_index(bus) >= 0, "bus %s exists" % bus)

	# Title screen: no city yet, mayor music.
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await wait(0.5)
	check(audio.main == main, "finds the main scene by itself")
	check(audio.music_weights.x > 0.1 and audio.music_weights.y == 0.0, "title plays the mayor stem")

	main._start(true)
	await wait(0.3)
	var city: City = main.city
	var mid := city.center_cell()
	main.cam.set_view(city.cell_center(mid.x, mid.y), 120.0, 0.0)
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0
	await wait(1.2)
	check(audio.density > 0.1, "downtown reads as built up (density %.2f)" % audio.density)
	check(audio.night == 0.0, "noon is day")
	check(audio._amb_target["amb_city_day"] > 0.2, "day city bed is up (%.2f)" % audio._amb_target["amb_city_day"])
	check(audio._amb_target["amb_crickets"] == 0.0, "no crickets at noon")
	var cut_low: float = audio._amb_lp.cutoff_hz
	main.cam.set_view(city.cell_center(mid.x, mid.y), 900.0, 0.0)
	await wait(1.2)
	check(audio._amb_lp.cutoff_hz < cut_low, "ambience gets duller with height (%d -> %d Hz)" % [cut_low, audio._amb_lp.cutoff_hz])
	check(audio._amb_target["amb_wind"] > 0.5, "wind rises up high (%.2f)" % audio._amb_target["amb_wind"])
	main.cam.set_view(city.cell_center(mid.x, mid.y), 120.0, 0.0)
	city.minutes = float(city.game_day()) * 1440.0 + 23.0 * 60.0
	await wait(0.8)
	check(audio.night == 1.0, "23:00 is night")
	check(audio._amb_target["amb_city_night"] > 0.1 and audio._amb_target["amb_city_day"] == 0.0, "night bed replaces day bed")

	# Mayor tools: a drag release in the same frame as the build.
	main._set_tool(1)
	await wait(0.1)
	check(audio.played.get("ui_select", 0) >= 1, "tool hotkey change clicks")
	var n_road: int = audio.played.get("build_road", 0)
	audio._release_frame = Engine.get_process_frames()
	city.place_road(city.road_path(mid + Vector2i(-20, -20), mid + Vector2i(-14, -20)))
	check(audio.played.get("build_road", 0) == n_road + 1, "road placement sound")
	city.spend(city.funds + 1000.0)
	check(audio.played.get("error", 0) >= 1, "not-enough-money buzz")
	main._set_tool(0)

	# Dive to the street: whoosh, then street music.
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0
	main.go_street()
	await wait(0.2)
	check(audio.played.get("whoosh_down", 0) == 1, "dive whoosh")
	await main.street.street_entered
	await wait(1.5)
	check(audio.music_weights.y > 0.9 and audio.music_weights.x < 0.1, "street stem has taken over (%s)" % str(audio.music_weights))
	check(audio.height < 10.0, "listener is at street level (%.1f m)" % audio.height)
	check(AudioServer.is_bus_effect_enabled(AudioServer.get_bus_index("SFX"), 0), "street reverb on")

	var steps := 0
	for i in 4:
		steps += audio.played.get("step_%d" % (i + 1), 0)
	Input.action_press("street_forward")
	await wait(1.5)
	Input.action_release("street_forward")
	var steps2 := 0
	for i in 4:
		steps2 += audio.played.get("step_%d" % (i + 1), 0)
	check(steps2 - steps >= 2, "footsteps while walking (%d)" % (steps2 - steps))

	# Car: doors, engine start, engine loop, drive stem.
	var street: StreetMode = main.street
	# A car right next to us (the nearest parked one can be anywhere on the map).
	var spot: Vector3 = street.player.global_position + street.player.global_basis.x * 3.0 + Vector3.UP * 0.3
	var best: Node3D = street.spawn_car("car_sedan", spot, street.player.facing_yaw(), Color(0.8, 0.1, 0.1))
	await wait(0.5)
	check(best != null, "a car to get into")
	if best:
		street._enter_car(best)
		await wait(0.5)
		for i in 40:
			if not street.get("switching"):
				break
			await wait(0.1)
		await wait(1.0)
		check(audio.played.get("door_open", 0) >= 1 and audio.played.get("door_close", 0) >= 1, "door sounds on entering")
		check(audio.played.get("engine_start", 0) == 1, "engine starts")
		check(audio._eng_idle.playing, "engine loop running")
		Input.action_press("street_forward")
		await wait(3.0)
		var v: float = absf(best.speed())
		var rpm: float = audio._rpm
		check(audio._eng_idle.pitch_scale > 0.8, "engine revs with throttle (v %.1f, pitch %.2f)" % [v, audio._eng_idle.pitch_scale])
		check(v < 3.0 or audio.music_weights.z > 0.0, "drive stem fades in with speed (%.2f)" % audio.music_weights.z)
		Input.action_release("street_forward")
		Input.action_press("street_horn")
		await wait(0.2)
		check(audio._horn.playing, "horn while H is held")
		Input.action_release("street_horn")
		await wait(0.2)
		check(not audio._horn.playing, "horn stops on release")
		print("      rpm %.2f  drive %.2f" % [rpm, audio.music_weights.z])
		street._leave_car()
		await wait(1.0)
		for i in 40:
			if not street.get("switching"):
				break
			await wait(0.1)
		check(audio._engine_target == 0.0 and not audio._eng_idle.playing, "engine off after getting out")

	# Back up.
	main.go_mayor()
	await wait(0.2)
	check(audio.played.get("whoosh_up", 0) == 1, "rise whoosh")
	await main.street.street_exited
	await wait(3.0)
	check(audio.music_weights.x > 0.9, "mayor stem back (%s)" % str(audio.music_weights))

	print("audio tests: %s" % ("all passed" if fails == 0 else "%d failed" % fails))
	quit(1 if fails else 0)
