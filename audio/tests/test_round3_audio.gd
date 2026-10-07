extends SceneTree
## Headless checks for round-3 audio (rain, wind, thunder, street echo, car radio):
##   godot --headless --path . --script res://audio/tests/test_round3_audio.gd
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
	audio = root.get_node_or_null("Audio")
	if audio == null:
		audio = load("res://audio/audio_director.gd").new()
		audio.name = "Audio"
		root.add_child(audio)
	await process_frame
	for k in ["amb_rain_light", "amb_rain_heavy", "amb_rain_roof", "amb_gusts", "thunder_1", "thunder_2", "radio_tune"]:
		check(audio.stream(k) != null, "%s loads" % k)
	var radio: CarRadio = audio.radio
	check(radio._streams.size() == 4, "four radio stations load (%d)" % radio._streams.size())

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await wait(0.3)
	main._start(true)
	await wait(0.5)
	var city: City = main.city
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0

	# Weather: the game's own main.weather when it's wired, else a stand-in node in the "weather" group.
	var w = main.get("weather")
	if w == null:
		var src := GDScript.new()
		src.source_code = "extends Node\nsignal lightning(pos: Vector3)\nvar rain := 0.0\nvar wind := 0.0\n"
		src.reload()
		w = src.new()
		w.add_to_group("weather")
		main.add_child(w)
	await wait(1.2)
	var wa: WeatherAudio = audio.weather_audio
	check(wa.source == w, "finds the weather node (%s)" % str(wa.source))
	wa.rain_override = 1.0
	wa.wind_override = 0.8
	audio.rain = 0.95  # skip the slow fade
	audio.wind = 0.75
	await wait(0.6)
	check(audio._amb_target["amb_rain_heavy"] > 0.3 and audio._amb_target["amb_rain_light"] < 0.1,
		"downpour plays the heavy rain (heavy %.2f, light %.2f)" % [audio._amb_target["amb_rain_heavy"], audio._amb_target["amb_rain_light"]])
	check(audio._amb_target["amb_gusts"] > 0.2, "wind brings gusts (%.2f)" % audio._amb_target["amb_gusts"])
	var strike: Vector3 = (main.cam.global_position if main.get("cam") else Vector3.ZERO) + Vector3(100, 0, 0)
	if w.has_signal("lightning"):
		w.lightning.emit(strike)
	else:
		wa._on_lightning(strike)
	await wait(0.8)
	check(audio.played.get("thunder_1", 0) == 1, "lightning 100 m away thunders after its travel time")
	wa.rain_override = 0.3
	audio.rain = 0.3
	await wait(0.6)
	check(audio._amb_target["amb_rain_light"] > 0.2 and audio._amb_target["amb_rain_heavy"] < 0.05, "light rain plays the light loop")
	wa.rain_override = 0.0
	wa.wind_override = 0.0
	audio.rain = 0.0
	audio.wind = 0.0

	main.go_street()
	await main.street.street_entered
	await wait(0.8)
	var street: StreetMode = main.street

	# Echo between tall buildings.
	check(audio.canyon >= 0.0 and audio.canyon <= 1.0, "canyon measured (%.2f)" % audio.canyon)
	audio.canyon = 1.0
	audio._update_street_space(true)
	var si := AudioServer.get_bus_index("SFX")
	check(AudioServer.is_bus_effect_enabled(si, 1) and audio._sfx_reverb.wet > 0.18, "echo and a bigger reverb between towers")
	audio.canyon = 0.0
	audio._update_street_space(true)
	check(not AudioServer.is_bus_effect_enabled(si, 1), "no echo in the open")
	var tower := -1
	for id in city.buildings:
		var b: Dictionary = city.buildings[id]
		if b.get("stage", 1) >= 3:
			tower = id
			break
	if tower >= 0:
		var b: Dictionary = city.buildings[tower]
		var cv: float = audio._canyon(Vector2i(b.x, b.y), true, city.land, city.bld, City.SIZE)
		check(cv > 0.0, "a tall building counts toward the canyon (%.2f)" % cv)

	# A bus pulling in at a stop.
	var traffic = main.life.traffic
	if traffic.has_signal("bus_stopped") and traffic.cars.size() > 0:
		var stops: int = audio.played.get("bus_stop", 0)
		traffic.bus_stopped.emit(traffic.cars[0], null)
		check(audio.played.get("bus_stop", 0) == stops + 1, "air brakes and doors when a bus stops")

	# Pickups emit taken(kind).
	var ps := GDScript.new()
	ps.source_code = "extends Node3D\nsignal taken(kind: StringName)\n"
	ps.reload()
	var pk: Node3D = ps.new()
	main.add_child(pk)
	pk.global_position = street.player.global_position
	await process_frame
	var picks: int = audio.played.get("pickup", 0)
	pk.taken.emit(&"cash")
	check(audio.played.get("pickup", 0) == picks + 1, "pickup sound")
	pk.queue_free()

	# Reloads.
	if street.combat.has_signal("reloading"):
		street.combat.reloading.emit(&"shotgun")
		street.combat.reloading.emit(&"pistol")
		check(audio.played.get("reload_shotgun", 0) == 1 and audio.played.get("reload_pistol", 0) == 1, "reload sounds")

	# Car radio.
	var spot: Vector3 = street.player.global_position + street.player.global_basis.x * 3.0 + Vector3.UP * 0.3
	var car: Node3D = street.spawn_car("car_sedan", spot, street.player.facing_yaw(), Color(0.2, 0.3, 0.8))
	await wait(0.5)
	check(car != null, "a car to get into")
	if car:
		check(not radio.available().has(0), "KMAY is off air before the radio tower is built")
		street._enter_car(car)
		await wait(0.5)
		for i in 40:
			if not street.get("switching"):
				break
			await wait(0.1)
		await wait(2.0)
		check(radio.in_car() and radio.gain > 0.9 and radio._player.playing, "radio plays once the engine runs (%s, gain %.2f)" % [radio.current_name(), radio.gain])
		check(radio.station == 1, "starts on Harbor Lo-Fi without the tower (%s)" % radio.current_name())
		await wait(2.0)
		check(audio.music_weights.y < 0.2, "street music steps aside for the radio (%s)" % str(audio.music_weights))
		check(radio._label.text.begins_with("Harbor Lo-Fi"), "station name shows (%s)" % radio._label.text.replace("\n", " / "))
		var tunes: int = audio.played.get("radio_tune", 0)
		var ev := InputEventAction.new()
		ev.action = CarRadio.ACTION
		ev.pressed = true
		Input.parse_input_event(ev)
		await wait(0.2)
		check(radio.station == 2 and audio.played.get("radio_tune", 0) == tunes + 1, "C flips to the next station (%s)" % radio.current_name())
		check(radio._label.visible, "new station name on screen")
		radio.next_station()
		radio.next_station()
		await wait(0.4)
		check(radio.station == -1 and radio.gain < 0.2, "after the last station the radio is off")
		radio.next_station()
		await wait(1.2)
		check(radio.station == 1 and radio._player.playing, "and back on")
		if car.has_signal("crashed"):
			audio._crash_cool = 0.0
			var crashes: int = audio.played.get("crash", 0)
			car.crashed.emit(0.8)
			check(audio.played.get("crash", 0) == crashes + 1, "crash sound from the car's own crashed signal")
		# Rain on the roof while driving.
		wa.rain_override = 0.8
		audio.rain = 0.8
		await wait(0.3)
		check(audio._amb_target["amb_rain_roof"] > 0.5, "rain drums on the car roof")
		wa.rain_override = -1.0
		wa.wind_override = -1.0
		audio.rain = 0.0
		street._leave_car()
		await wait(1.0)
		for i in 40:
			if not street.get("switching"):
				break
			await wait(0.1)
		await wait(0.5)
		check(radio.gain == 0.0 and not radio._player.playing, "radio off after getting out")

	print("round-3 audio tests: %s" % ("all passed" if fails == 0 else "%d failed" % fails))
	quit(1 if fails else 0)
