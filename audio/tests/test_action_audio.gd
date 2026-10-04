extends SceneTree
## Headless checks for the round-2 action audio (guns, police, alarms, missions, interiors):
##   godot --headless --path . --script res://audio/tests/test_action_audio.gd
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


func n(sound: String) -> int:
	return audio.played.get(sound, 0)


func _run() -> void:
	audio = root.get_node_or_null("Audio")
	if audio == null:
		audio = load("res://audio/audio_director.gd").new()
		audio.name = "Audio"
		root.add_child(audio)
	await process_frame
	for k in ["gun_pistol", "explosion", "siren_yelp_loop", "bank_alarm_loop", "car_alarm_loop", "amb_panic", "amb_room", "music_action"]:
		check(audio.stream(k) != null, "%s loads" % k)
	check(absf(audio.stream("music_action").get_length() - audio.stream("music_street").get_length()) < 0.01, "action stem matches the other stems")

	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await wait(0.3)
	main._start(true)
	await wait(0.5)
	var city: City = main.city
	city.minutes = float(city.game_day()) * 1440.0 + 12.0 * 60.0
	main.go_street()
	await main.street.street_entered
	await wait(0.5)
	var street = main.street
	var act: ActionAudio = audio.action_audio

	# Guns.
	if street.combat.has_method("give"):
		street.combat.give(&"pistol", 20)
		street.combat.select(&"pistol")
		await wait(0.1)
		check(n("weapon_switch") >= 1, "weapon switch click")
		street.combat.fire()
		await wait(0.1)
		check(n("gun_pistol") == 1, "pistol shot")
		street.combat.select(&"fists")
		await wait(0.6)
		street.combat.fire()
		await wait(0.1)
		check(n("punch_swing") >= 1, "punch swing")

	# Wanted: police radio, action music, sirens.
	street.set_wanted(2)
	await wait(0.2)
	check(n("radio_static") >= 1, "police radio when stars go up")
	check(audio.action == 1.0, "two stars ask for action music")
	await wait(2.5)
	check(audio.music_weights.w > 0.8 and audio.music_weights.y < 0.2, "action stem takes over (%s)" % str(audio.music_weights))
	var sirens := false
	for i in 40:
		for p in act._sirens:
			if p.playing:
				sirens = true
		if sirens:
			break
		await wait(0.25)
	check(sirens, "a cop car's siren is playing")
	street.set_wanted(0)
	await wait(0.3)
	check(audio.action == 0.0 or act.mission_on, "no stars, no action music")

	# Cars: alarm on a parked car, explosion.
	var cars: Array = []
	for v in get_nodes_in_group("vehicles"):
		if v.get("driver") == null:
			cars.append(v)
	check(cars.size() >= 2, "parked cars to test with (%d)" % cars.size())
	if cars.size() >= 2:
		cars[0].take_hit(5.0)
		await wait(0.1)
		var alarm := false
		for c in cars[0].get_children():
			if c is AudioStreamPlayer3D and c.stream == audio.stream("car_alarm_loop"):
				alarm = true
		check(alarm, "parked car alarm goes off when hit")
		cars[1].explode()
		await wait(0.1)
		check(n("explosion") == 1, "car explosion")

	# Carjack, as citylife reports it.
	main.life.traffic.car_taken.emit(street.player.global_position + Vector3(3, 0, 0), Vector3.FORWARD)
	check(n("carjack") == 1, "carjack scuffle")

	# Missions: a job starts the action music; the vault step sets off the bank alarm.
	var m := Mission.new()
	m.steps = [{"do": "hold", "at": "start", "marker": "vault"}]
	m.slots = {"start": {"pos": street.player.global_position + Vector3(30, 0, 0)}}
	if main.get("missions"):
		main.missions.director.started.emit(m)
		await wait(0.1)
		check(act.mission_on and audio.action == 1.0, "a mission starts the action music")
		main.missions.director.step_changed.emit(m)
	else:
		act._on_step(m)
	await wait(0.2)
	check(act.bank_alarm > 0.0 and act._bank_out.playing, "bank alarm rings outside")
	if main.get("interiors"):
		main.interiors.interior_entered.emit("bank", {})
		await wait(0.2)
		check(audio.indoors, "inside an interior")
		check(act._bank_in.playing and not act._bank_out.playing, "bank alarm switches to the inside bell")
		check(audio._amb_target["amb_room"] > 0.5 and audio._amb_target["amb_city_day"] < 0.2, "room tone up, city down indoors")
		main.interiors.interior_exited.emit("bank", {})
		await wait(0.2)
		check(not audio.indoors, "back outside")
	if main.get("missions"):
		main.missions.director.passed.emit(m)
		await wait(0.1)
		check(not act.mission_on, "mission over, action music released")

	street.wasted.emit()
	await wait(0.1)
	check(n("wasted") == 1, "wasted sting")

	print("action audio tests: %s" % ("all passed" if fails == 0 else "%d failed" % fails))
	quit(1 if fails else 0)
