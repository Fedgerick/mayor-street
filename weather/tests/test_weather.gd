extends SceneTree
## Headless checks for the weather: the calendar, easing, wet streets, and what rain does
## to the crowd and the traffic.
## godot --headless --path . --script res://weather/tests/test_weather.gd

var failures := 0


func check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)


func _initialize() -> void:
	await process_frame
	if not root.has_node("Kit"):
		var kit: Node = load("res://scripts/kit.gd").new()
		kit.name = "Kit"
		root.add_child(kit)
	print("weather tests")
	var city := City.new(1337)
	city.build_demo(24 * 12)
	city.compute_traffic()
	city.compute_land_value()
	var w := Weather.new()
	w.auto_step = false
	root.add_child(w)
	w.setup(city)

	# --- the calendar --------------------------------------------------------------
	var counts := [0, 0, 0, 0]
	var fog_by_day := 0
	for q in 400:
		var k := w.scheduled(q * 360.0 + 10.0)
		counts[k] += 1
		if k == Weather.Kind.FOG and posmod(q, 4) >= 2:
			fog_by_day += 1
	print("  100 days: clear %d, cloudy %d, rain %d, fog %d" % counts)
	check(counts[0] > 100 and counts[1] > 50 and counts[2] > 30 and counts[3] > 10, "all four kinds of weather come round")
	check(fog_by_day == 0, "fog only at night and in the morning")
	check(w.scheduled(5000.0) == w.scheduled(5000.0) and w.scheduled(5000.0) == w.scheduled(5030.0), "the same time gets the same weather")
	var other := City.new(99)
	var w2 := Weather.new()
	w2.city = other
	other.map_seed = 99
	var differs := 0
	for q in 40:
		if w2.scheduled(q * 360.0) != w.scheduled(q * 360.0):
			differs += 1
	check(differs > 5, "another city has other weather (%d of 40 quarters differ)" % differs)

	# --- easing and wet streets -------------------------------------------------------
	w.set_weather(Weather.Kind.CLEAR, true)
	check(w.rain == 0.0 and w.wet == 0.0, "clear and dry")
	w.set_weather(Weather.Kind.RAIN)
	w.advance(5.0)
	var early := w.rain
	w.advance(60.0)
	check(early > 0.0 and early < w.rain and w.rain > 0.4, "rain builds up (%.2f then %.2f)" % [early, w.rain])
	check(w.wet > 0.9, "streets get wet in the rain (%.2f)" % w.wet)
	check(w.grip() < 0.75, "less grip on wet roads (%.2f)" % w.grip())
	check(w.umbrella_share() > 0.5, "umbrellas up (%.2f)" % w.umbrella_share())
	w.set_weather(Weather.Kind.CLEAR)
	w.advance(60.0)
	var damp := w.wet
	check(w.rain < 0.05 and damp > 0.3, "rain stops but the streets stay wet a while (%.2f)" % damp)
	w.advance(240.0)
	check(w.wet < 0.05, "and then dry out (%.2f)" % w.wet)
	w.set_weather(Weather.Kind.FOG)
	w.advance(90.0)
	check(w.fog > 0.9 and w.visibility() < 0.35, "fog rolls in (%.2f)" % w.fog)
	w.set_weather(-1)
	check(w.forced == -1, "back to the calendar")
	var d := w.to_dict()
	w.set_weather(Weather.Kind.RAIN, true)
	w.from_dict(d)
	check(w.forced == -1, "save and load keep the calendar")

	# --- rain on the street -------------------------------------------------------------
	city.minutes = float(city.game_day()) * 1440.0 + 12.5 * 60.0
	var life := CityLife.new()
	life.auto_step = false
	root.add_child(life)
	life.setup(city, null)
	var dt := 1.0 / 30.0
	for f in 30 * 60:
		life.step(dt)
	var dry_peds := life.want_peds
	var dry_sit := life.crowd.count_act(Crowd.Act.SIT)
	life.set_weather(w)
	w.set_weather(Weather.Kind.RAIN, true)
	w.intensity = 1.0
	w.set_weather(Weather.Kind.RAIN, true)
	var gaps_dry := _mean_speed(life)
	for f in 30 * 90:
		life.step(dt)
	print("  rain: %d people wanted (dry %d), %d umbrellas, %d sitting (dry %d), mean car speed %.1f (dry %.1f)" % [life.want_peds, dry_peds, life.crowd.umbrella_count(), life.crowd.count_act(Crowd.Act.SIT), dry_sit, _mean_speed(life), gaps_dry])
	check(life.want_peds < dry_peds, "fewer people out in the rain")
	check(life.crowd.umbrella_count() > life.crowd.peds.size() / 3, "most people walk under umbrellas (%d of %d)" % [life.crowd.umbrella_count(), life.crowd.peds.size()])
	check(life.crowd.count_act(Crowd.Act.SIT) < maxi(dry_sit / 3, 2), "nobody sits on wet benches")
	check(life.traffic.wet > 0.9, "traffic knows the roads are wet")

	# --- rain effect node -----------------------------------------------------------------
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = city.cell_center(40, 40) + Vector3(0, 1.7, 0)
	var fx := RainFX.new()
	root.add_child(fx)
	fx.setup(w, cam)
	fx._process(0.016)
	check(fx.visible and fx._drops.emitting, "rain falls around the street camera")
	cam.global_position.y = 400.0
	fx._process(0.016)
	check(not fx.visible, "no rain particles from the mayor view")
	cam.global_position.y = 2501.0
	fx._process(0.016)
	check(not fx.visible, "no rain inside buildings")

	print("weather: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures > 0 else 0)


func _mean_speed(life: CityLife) -> float:
	var v := 0.0
	for c in life.traffic.cars:
		v += c.v
	return v / maxf(life.traffic.cars.size(), 1)
