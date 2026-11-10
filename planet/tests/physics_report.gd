extends SceneTree
## msp: a detailed physics test on the real game. Boots the planet demo, clears the traffic,
## and measures how the cars and the character on foot actually behave on the ball: getting
## going, stopping, cornering, the handbrake, drops, kerbs, rough ground, crashes into a wall,
## into each other and into the player, a lap of the globe, and walking, sprinting, jumping
## and stepping up. Every case prints its numbers; cases with a target print PASS or FAIL.
##   godot --headless --path . -s planet/tests/physics_report.gd -- --demo --nosave [--quick] [--out=FILE]
## --quick runs three models instead of eight. The report is also written to --out.

const MODELS := ["car_sedan", "car_hatch", "car_sports", "car_police", "car_pickup", "car_van", "car_truck", "car_bus"]
const QUICK := ["car_sedan", "car_sports", "car_bus"]
const G := 9.8

var fails := 0
var lines: PackedStringArray = []
var main: Node
var city: City
var street: Node
var drv := Node.new()
var row := 0          # the equator highway's row of tiles
var x0 := 0.0         # flat x where the open-road tests start
var _cars: Array = []
var _extra: Array = []


func say(s: String) -> void:
	print(s)
	lines.append(s)


func check(ok: bool, what: String) -> void:
	say(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func tick(n := 1) -> void:
	for i in n:
		await physics_frame


func secs(s: float) -> void:
	await tick(int(s * 60.0))


func release_all() -> void:
	for a in ["street_forward", "street_back", "street_left", "street_right", "street_handbrake", "street_sprint", "street_jump", "street_throttle", "street_brake"]:
		if InputMap.has_action(a):
			Input.action_release(a)


func ground(fx: float, fz: float, lift := 0.0) -> Vector3:
	return Planet.warp(Vector3(fx, city.terrain_height(fx, fz) + lift, fz))


func height_over_ground(w: Vector3) -> float:
	var f := Planet.flat(w)
	return w.length() - Planet.R - city.terrain_height(f.x, f.z)


func car(model: String, fx: float, fz: float, yaw := PI * 0.5, lift := 0.45) -> Node:
	## A car on the road at flat (fx, fz). yaw PI/2 faces east, along the highway.
	var c: Node = street.spawn_car(model, ground(fx, fz, lift), yaw, Color(0.8, 0.1, 0.1))
	_cars.append(c)
	return c


func clear() -> void:
	release_all()
	for c in _cars:
		if is_instance_valid(c):
			c.queue_free()
	for e in _extra:
		if is_instance_valid(e):
			e.queue_free()
	_cars.clear()
	_extra.clear()
	await tick(3)


func up_dot(c: Node3D) -> float:
	return c.global_basis.y.dot(Planet.up(c.global_position))


func heading(c: Node3D) -> float:
	## Degrees off due east on the map (north is negative).
	var f := Planet.to_local(c.global_position, c.global_basis.z)
	return rad_to_deg(atan2(f.z, f.x))


func clear_trees(x_from: float, x_to: float, row_from: int, row_to: int) -> void:
	## Open country with nothing to hit, for the off-road run.
	var a := int(x_from / City.TILE)
	var b := int(x_to / City.TILE)
	for y in range(row_from, row_to + 1):
		for x in range(a, b + 1):
			city.trees[city.idx(posmod(x, City.W), y)] = 0
	city.cells_changed.emit(Rect2i(a, row_from, b - a + 1, row_to - row_from + 1))


func wall(fx: float, fz: float, size: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.collision_layer = 1
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = size
	cs.shape = s
	b.add_child(cs)
	street.add_child(b)
	b.global_transform = Planet.xf_rigid(Transform3D(Basis.IDENTITY, Vector3(fx, city.terrain_height(fx, fz) + size.y * 0.5, fz)))
	_extra.append(b)
	return b


func _run() -> void:
	var quick := false
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a == "--quick":
			quick = true
		if a.begins_with("--out="):
			out = a.trim_prefix("--out=")
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await create_timer(1.0).timeout
	city = main.city
	main.go_street()
	street = main.street
	while not street.active:
		await process_frame
	# An empty world: no traffic, people or police to get in the way of the measurements.
	var life: Node = main.life
	life.traffic.max_cars = 0
	life.traffic.cars.clear()
	life.process_mode = Node.PROCESS_MODE_DISABLED
	city.growth_check = func(_x, _y): return false
	main._set_speed(0)
	street.player.set_controls(false)
	# Four times faster than life, still in 1/60 s steps: Godot stretches each physics step by
	# time_scale, so the tick rate goes up with it.
	Engine.time_scale = 4.0
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 32
	row = City.H / 2
	x0 = (city.center_cell().x + 44) * City.TILE     # well east of the town, on the open highway
	var z0: float = city.cell_center(0, row).z
	# The player waits out of the way.
	street.player.place(ground(x0 - 200.0, z0 + 4.6, 0.1), 0.0)
	await secs(0.5)

	say("msp physics report (Godot %s, 60 Hz physics, radius %.0f m)" % [Engine.get_version_info().string, Planet.R])
	var models: Array = QUICK if quick else MODELS

	# ------------------------------------------------------------------ cars ---
	say("\n== 1. At rest: a parked car stays put ==")
	for m in models:
		var c := car(m, x0, z0)
		var peak := -INF
		var start: Vector3 = c.global_position
		for i in 120:
			await physics_frame
			if i > 40:   # after the drop from where it was put down
				peak = maxf(peak, height_over_ground(c.global_position))
		var settled: Vector3 = c.global_position
		var rest_h := height_over_ground(settled)
		await secs(4.0)
		var creep: float = c.global_position.distance_to(settled)
		say("  %-11s settles %.2f m above the road (peak %.2f), creeps %.3f m in 4 s, lean %.1f deg, %s" % [m, rest_h, peak, creep,
			rad_to_deg(acos(clampf(up_dot(c), -1.0, 1.0))), "asleep" if c.sleeping else "awake"])
		check(creep < 0.05 and peak - rest_h < 0.25 and up_dot(c) > 0.998, "%s sits still and level" % m)
		await clear()

	say("\n== 2. Getting going: full throttle from a standstill ==")
	var top := {}
	for m in models:
		var c := car(m, x0, z0)
		c.set_driver(drv)
		await secs(1.0)
		Input.action_press("street_forward")
		var t30 := -1.0
		var t60 := -1.0
		var t := 0.0
		var max_pitch := 0.0
		var z_start := Planet.flat(c.global_position).z
		var v8 := 0.0
		var dist := 0.0
		while t < 30.0:
			await physics_frame
			t += 1.0 / 60.0
			var v: float = c.speed()
			dist += v / 60.0
			if t30 < 0.0 and v >= 13.4:
				t30 = t
			if t60 < 0.0 and v >= 26.8:
				t60 = t
			if absf(t - 8.0) < 0.01:
				v8 = v
			max_pitch = maxf(max_pitch, absf(c.global_basis.z.dot(Planet.up(c.global_position))))
		var vmax: float = c.speed()
		top[m] = vmax
		var drift := absf(Planet.flat(c.global_position).z - z_start)
		var spec_top: float = c._top_speed
		say("  %-11s 0-30 mph %s, 0-60 mph %s, %.1f m/s after 8 s, %.1f m/s (%.0f km/h) after 30 s = %.0f%% of its top speed; nose lift %.1f deg; drifts %.2f m sideways in %.0f m" % [m,
			("%.1f s" % t30) if t30 > 0 else "never", ("%.1f s" % t60) if t60 > 0 else "never", v8, vmax, vmax * 3.6, 100.0 * vmax / spec_top,
			rad_to_deg(asin(clampf(max_pitch, 0.0, 1.0))), drift, dist])
		check(vmax > spec_top * 0.93, "%s reaches its top speed within 30 s" % m)
		check(drift < 1.0, "%s runs straight with no steering" % m)
		release_all()
		await clear()

	say("\n== 3. Stopping: full brake from 25 m/s (90 km/h) ==")
	for m in models:
		var c := car(m, x0, z0)
		c.set_driver(drv)
		await secs(1.0)
		var v0 := minf(25.0, c._top_speed * 0.9)
		c.linear_velocity = c.forward() * v0
		await tick(2)
		Input.action_press("street_back")
		var t := 0.0
		var dist := 0.0
		var z_start := Planet.flat(c.global_position).z
		var yaw_dev := 0.0
		var h0 := heading(c)
		while c.speed() > 0.3 and t < 12.0:
			await physics_frame
			t += 1.0 / 60.0
			dist += c.speed() / 60.0
			yaw_dev = maxf(yaw_dev, absf(heading(c) - h0))
		Input.action_release("street_back")
		var decel := v0 * v0 / (2.0 * maxf(dist, 0.01))
		say("  %-11s from %.0f m/s: stops in %.1f m and %.1f s (%.2f g), swings %.1f deg, %.2f m off line" % [m, v0, dist, t, decel / G,
			yaw_dev, absf(Planet.flat(c.global_position).z - z_start)])
		# A road car on dry tarmac brakes at 0.8 to 1.1 g; a loaded bus at 0.5 to 0.7 g.
		var heavy: bool = c.mass > 5000.0
		check(decel / G > (0.45 if heavy else 0.7) and decel / G < (0.9 if heavy else 1.25), "%s brakes like a %s (%.2f g)" % [m, "heavy vehicle" if heavy else "car", decel / G])
		check(yaw_dev < 2.0, "%s stays straight under braking" % m)
		await clear()

	say("\n== 4. Coasting: off the throttle at 20 m/s ==")
	for m in models.slice(0, 3):
		var c := car(m, x0, z0)
		c.set_driver(drv)
		await secs(1.0)
		c.linear_velocity = c.forward() * 20.0
		await secs(5.0)
		var v5: float = c.speed()
		say("  %-11s 20 m/s -> %.1f m/s after 5 s of coasting (%.2f m/s2)" % [m, v5, (20.0 - v5) / 5.0])
		check(v5 > 12.0 and v5 < 18.5, "%s slows gently when coasting" % m)
		await clear()

	say("\n== 5. Cornering: full lock held at a steady speed ==")
	for m in models:
		for v_in in [10.0, 20.0]:
			var c := car(m, x0, z0)
			c.set_driver(drv)
			await secs(1.0)
			c.linear_velocity = c.forward() * v_in
			Input.action_press("street_forward")
			Input.action_press("street_left")
			var min_up := 1.0
			var lat_peak := 0.0
			var yaw_rate := 0.0
			var v_sum := 0.0
			var n := 0
			var slip_peak := 0.0
			for i in 240:
				await physics_frame
				min_up = minf(min_up, up_dot(c))
				if i > 90:
					var w: float = absf(c.angular_velocity.dot(Planet.up(c.global_position)))
					var v: float = c.linear_velocity.length()
					yaw_rate += w
					v_sum += v
					lat_peak = maxf(lat_peak, w * v)
					n += 1
					var lv: Vector3 = c.global_basis.inverse() * c.linear_velocity
					slip_peak = maxf(slip_peak, rad_to_deg(absf(atan2(lv.x, absf(lv.z)))))
			yaw_rate /= n
			var v_avg := v_sum / n
			say("  %-11s at %2.0f m/s: radius %.0f m, %.2f g sideways, slides at %.0f deg, speed held %.0f m/s, leans to %.0f deg" % [m, v_in,
				v_avg / maxf(yaw_rate, 0.001), yaw_rate * v_avg / G, slip_peak, v_avg, rad_to_deg(acos(clampf(min_up, -1.0, 1.0)))])
			check(min_up > 0.9, "%s keeps its wheels down at %.0f m/s" % [m, v_in])
			var limit: float = c.GRIP * c._feel.grip * 1.2
			check(yaw_rate * v_avg / G < limit, "%s corners at a believable %.2f g (its tyres give %.2f)" % [m, yaw_rate * v_avg / G, c.GRIP * c._feel.grip])
			check(v_avg > v_in * 0.45, "%s keeps its speed up through the turn" % m)
			release_all()
			await clear()

	say("\n== 6. Handbrake turn at 18 m/s ==")
	for m in models.slice(0, 3):
		var c := car(m, x0, z0)
		c.set_driver(drv)
		await secs(1.0)
		c.linear_velocity = c.forward() * 18.0
		var f0: Vector3 = c.forward()
		Input.action_press("street_left")
		Input.action_press("street_handbrake")
		var min_up := 1.0
		var turned := 0.0
		for i in 120:
			await physics_frame
			min_up = minf(min_up, up_dot(c))
			turned += absf(c.angular_velocity.dot(Planet.up(c.global_position))) / 60.0
		say("  %-11s swings %.0f deg in 2 s, ends at %.1f m/s, leans to %.0f deg" % [m, rad_to_deg(turned), c.linear_velocity.length(),
			rad_to_deg(acos(clampf(min_up, -1.0, 1.0)))])
		check(rad_to_deg(turned) > (45.0 if c.mass > 5000.0 else 70.0) and min_up > 0.85, "%s can be thrown round with the handbrake" % m)
		release_all()
		await clear()

	say("\n== 7. A drop of 2 m ==")
	var droppers: Array = models.slice(0, 3)
	if not droppers.has("car_bus"):
		droppers.append("car_bus")
	for m in droppers:
		var c := car(m, x0, z0, PI * 0.5, 2.4)
		var landed := false
		var rebound := 0.0
		var rest := 0.0
		var t := 0.0
		var t_still := -1.0
		var lowest := 99.0
		while t < 6.0:
			await physics_frame
			t += 1.0 / 60.0
			var h := height_over_ground(c.global_position)
			var rising: bool = c.linear_velocity.dot(Planet.up(c.global_position)) > 0.0
			if not landed and h < 0.75 and rising:
				landed = true   # the springs have taken the hit and it is coming back up
			if not landed:
				lowest = minf(lowest, h)
			else:
				rebound = maxf(rebound, h)
				if t_still < 0.0 and c.linear_velocity.length() < 0.1 and t > 1.0:
					t_still = t
		rest = height_over_ground(c.global_position)
		say("  %-11s sinks to %.2f m on landing, bounces back to %.2f m (rests at %.2f), still after %.1f s, lean %.1f deg" % [m, lowest, rebound, rest, t_still, rad_to_deg(acos(clampf(up_dot(c), -1.0, 1.0)))])
		check(rebound - rest < 0.35 and t_still > 0.0 and t_still < 3.0, "%s lands and settles without bouncing about" % m)
		await clear()

	say("\n== 8. Head-on into a wall ==")
	for m in models.slice(0, 3):
		for v_in in [8.0, 16.0, 28.0]:
			var c := car(m, x0, z0)
			c.set_driver(drv)
			wall(x0 + 30.0, z0, Vector3(2.0, 4.0, 12.0))
			await secs(1.0)
			c.linear_velocity = c.forward() * v_in
			var nose: float = c._aabb.size.z * 0.5
			var hit := false
			var peak_h := 0.0
			var rebound := 0.0
			var min_up := 1.0
			var t := 0.0
			var hp0: float = c.health
			while t < 6.0:
				await physics_frame
				t += 1.0 / 60.0
				if not hit:
					if Planet.flat(c.global_position).x + nose < x0 + 29.0 - v_in / 30.0:
						c.linear_velocity += c.forward() * (v_in - c.speed())   # arrive at exactly this speed
					elif c.speed() < v_in * 0.5:
						hit = true
				if hit:
					peak_h = maxf(peak_h, height_over_ground(c.global_position))
					rebound = maxf(rebound, -c.speed())
					min_up = minf(min_up, up_dot(c))
			say("  %-11s at %2.0f m/s: bounces back at %.1f m/s (%.0f%%), lifts to %.2f m, tips to %.0f deg, loses %.0f of %d health" % [m, v_in,
				rebound, 100.0 * rebound / v_in, peak_h, rad_to_deg(acos(clampf(min_up, -1.0, 1.0))), hp0 - c.health, int(c.MAX_HEALTH)])
			check(hit and rebound < v_in * 0.3, "%s crumples instead of bouncing off at %.0f m/s" % [m, v_in])
			check(peak_h < 0.9 and min_up > 0.8, "%s stays on the ground in a %.0f m/s crash" % [m, v_in])
			release_all()
			await clear()

	say("\n== 9. Car into car ==")
	for pair in [["car_sedan", "car_sedan", 15.0], ["car_sedan", "car_bus", 15.0], ["car_bus", "car_sedan", 15.0], ["car_sports", "car_hatch", 28.0]]:
		var a := car(pair[0], x0, z0)
		var b := car(pair[1], x0 + 30.0, z0)
		a.set_driver(drv)
		await secs(1.0)
		var v_in: float = pair[2]
		a.linear_velocity = a.forward() * v_in
		var p_before: float = a.mass * v_in
		var hit_t := -1.0
		var peak_h := 0.0
		var t := 0.0
		var va := 0.0
		var vb := 0.0
		var e_peak := 0.0
		var fw: Vector3 = a.forward()
		while t < 5.0:
			await physics_frame
			t += 1.0 / 60.0
			if hit_t < 0.0 and b.linear_velocity.length() > 0.5:
				hit_t = t
			if hit_t >= 0.0:
				peak_h = maxf(peak_h, maxf(height_over_ground(a.global_position), height_over_ground(b.global_position)))
				var e: float = 0.5 * a.mass * a.linear_velocity.length_squared() + 0.5 * b.mass * b.linear_velocity.length_squared()
				e_peak = maxf(e_peak, e)
				if absf(t - hit_t - 0.25) < 0.009:
					va = a.linear_velocity.dot(fw)
					vb = b.linear_velocity.dot(fw)
		var p_after: float = a.mass * va + b.mass * vb
		var e_before: float = 0.5 * a.mass * v_in * v_in
		say("  %s (%.0f kg) at %.0f m/s into a parked %s (%.0f kg): after the hit %.1f and %.1f m/s; momentum kept %.0f%%; energy never above %.0f%% of what went in; highest %.2f m" % [
			pair[0].trim_prefix("car_"), a.mass, v_in, pair[1].trim_prefix("car_"), b.mass, va, vb, 100.0 * p_after / p_before, 100.0 * e_peak / e_before, peak_h])
		check(hit_t > 0.0 and e_peak <= e_before * 1.02, "no energy from nowhere (%s into %s)" % [pair[0], pair[1]])
		check(p_after / p_before > 0.5 and p_after / p_before < 1.05, "momentum carries through (%s into %s)" % [pair[0], pair[1]])
		check(peak_h < 1.0, "nobody is thrown into the air (%s into %s)" % [pair[0], pair[1]])
		await clear()

	say("\n== 10. Kerbs: onto the sidewalk at 25 degrees ==")
	for m in models.slice(0, 3):
		for v_in in [6.0, 14.0]:
			var c := car(m, x0, z0, PI * 0.5 - deg_to_rad(25.0))
			c.set_driver(drv)
			await secs(1.0)
			c.linear_velocity = c.forward() * v_in
			Input.action_press("street_forward")
			var peak_h := 0.0
			var min_up := 1.0
			var v_min: float = v_in
			for i in 150:
				await physics_frame
				peak_h = maxf(peak_h, height_over_ground(c.global_position))
				min_up = minf(min_up, up_dot(c))
				v_min = minf(v_min, c.linear_velocity.length())
			var off := absf(Planet.flat(c.global_position).z - z0)
			say("  %-11s at %2.0f m/s: slows to %.1f m/s, lifts to %.2f m, leans to %.0f deg, ends %.1f m off the centre line" % [m, v_in, v_min, peak_h,
				rad_to_deg(acos(clampf(min_up, -1.0, 1.0))), off])
			check(off > 5.0, "%s climbs the kerb at %.0f m/s" % [m, v_in])
			check(min_up > 0.9 and peak_h < 1.0, "%s takes the kerb without being thrown" % m)
			release_all()
			await clear()

	say("\n== 11. Rough ground: across open country at speed ==")
	clear_trees(x0 - 24.0, x0 + 420.0, row - 7, row - 3)
	await secs(0.3)
	for m in models.slice(0, 3):
		var c := car(m, x0, z0 - 60.0)
		c.set_driver(drv)
		await secs(1.0)
		c.linear_velocity = c.forward() * 18.0
		Input.action_press("street_forward")
		var air := 0
		var peak_h := 0.0
		var min_up := 1.0
		for i in 600:
			await physics_frame
			var contact := false
			for w in c._wheels:
				if w.is_in_contact():
					contact = true
			air += 0 if contact else 1
			peak_h = maxf(peak_h, height_over_ground(c.global_position))
			min_up = minf(min_up, up_dot(c))
		say("  %-11s 10 s off road: in the air %.0f%% of the time, highest %.2f m, leans to %.0f deg, ends at %.0f m/s" % [m, air / 6.0, peak_h,
			rad_to_deg(acos(clampf(min_up, -1.0, 1.0))), c.speed()])
		check(min_up > 0.8 and peak_h < 1.6 and c.speed() > 10.0, "%s holds together off road" % m)
		release_all()
		await clear()

	say("\n== 12. Round the world: a lap of the equator highway, hands off the wheel ==")
	if true:
		var c := car("car_sedan", x0, z0)
		c.set_driver(drv)
		await secs(1.0)
		Input.action_press("street_forward")
		var t := 0.0
		var dist := 0.0
		var worst_z := 0.0
		var worst_h := 0.0
		var min_up := 1.0
		var lap: float = Planet.circumference()
		while dist < lap and t < 150.0:
			await physics_frame
			t += 1.0 / 60.0
			dist += c.speed() / 60.0
			worst_z = maxf(worst_z, absf(Planet.flat(c.global_position).z - z0))
			worst_h = maxf(worst_h, absf(height_over_ground(c.global_position) - 0.5))
			min_up = minf(min_up, up_dot(c))
		say("  sedan: %.0f m in %.0f s (average %.0f km/h); never more than %.2f m off the centre line or %.2f m off its ride height; leans to %.1f deg" % [dist, t,
			dist / t * 3.6, worst_z, worst_h, rad_to_deg(acos(clampf(min_up, -1.0, 1.0)))])
		check(dist >= lap and worst_z < 1.5, "a car driven straight stays on the highway all the way round")
		check(min_up > 0.97 and worst_h < 0.6, "gravity keeps it flat on the road the whole lap")
		release_all()
		await clear()

	say("\n== 13. Away from the equator: an east-west street is a circle of latitude ==")
	for dz in [-10, 10]:
		var r2: int = row + dz
		var zc: float = city.cell_center(0, r2).z
		var c := car("car_sedan", x0, zc)
		c.set_driver(drv)
		await secs(1.0)
		c.linear_velocity = c.forward() * 15.0
		Input.action_press("street_forward")
		await secs(6.0)
		var f := Planet.flat(c.global_position)
		var lat := rad_to_deg(Planet.lat_of(Vector3(x0, 0, zc)))
		say("  %d tiles %s of the equator (latitude %.0f deg): after 6 s hands off, %.1f m toward the %s" % [absi(dz), "north" if dz < 0 else "south", absf(lat),
			absf(f.z - zc), "equator" if (f.z - zc) * dz < 0 else "pole"])
		check(absf(f.z - zc) < 0.8, "a car driven straight stays in its lane away from the equator")
		release_all()
		await clear()

	# ---------------------------------------------------------------- on foot ---
	var p: Node = street.player
	say("\n== 14. On foot: walking and sprinting ==")
	if true:
		p.place(ground(x0, z0, 0.3), 0.0)
		p.rig.yaw = -PI * 0.5      # the camera looks east, so forward is along the road
		p.set_controls(true)
		await secs(1.0)
		var h_stand := height_over_ground(p.global_position)
		for sprint in [false, true]:
			if sprint:
				Input.action_press("street_sprint")
			Input.action_press("street_forward")
			var t := 0.0
			var t90 := -1.0
			var goal: float = p.sprint_speed if sprint else p.walk_speed
			while t < 3.0:
				await physics_frame
				t += 1.0 / 60.0
				if t90 < 0.0 and p.velocity.length() >= goal * 0.9:
					t90 = t
			var v: float = p.velocity.length()
			var at: Vector3 = p.global_position
			Input.action_release("street_forward")
			Input.action_release("street_sprint")
			await secs(1.5)
			say("  %s: %.2f m/s (%.1f km/h), up to speed in %.2f s, stops in %.2f m; stands %.2f m above the ground, upright %.4f" % ["sprint" if sprint else "walk  ", v, v * 3.6,
				t90, p.global_position.distance_to(at), height_over_ground(p.global_position), up_dot(p)])
			check(absf(v - goal) < 0.2 and t90 > 0.0 and t90 < 0.6, "%s speed and pick-up" % ("sprint" if sprint else "walk"))
		check(absf(height_over_ground(p.global_position) - h_stand) < 0.05 and up_dot(p) > 0.999, "the character stays on the ground, upright")

	say("\n== 15. On foot: jumping ==")
	if true:
		for sprint in [false, true]:
			p.place(ground(x0, z0, 0.3), 0.0)
			p.rig.yaw = -PI * 0.5
			await secs(0.6)
			var h0 := height_over_ground(p.global_position)
			if sprint:
				Input.action_press("street_sprint")
				Input.action_press("street_forward")
				await secs(1.2)
			var at: Vector3 = p.global_position
			Input.action_press("street_jump")
			await tick(2)
			Input.action_release("street_jump")
			var apex := 0.0
			var t := 0.0
			var air := 0.0
			var landed_at: Vector3 = at
			while t < 2.0:
				await physics_frame
				t += 1.0 / 60.0
				apex = maxf(apex, height_over_ground(p.global_position) - h0)
				if not p.is_on_floor():
					air += 1.0 / 60.0
					landed_at = p.global_position
				elif air > 0.2:
					break   # down again
			release_all()
			say("  %s jump: %.2f m high, %.2f s in the air%s" % ["running" if sprint else "standing", apex, air,
				(", %.1f m long" % landed_at.distance_to(at)) if sprint else ""])
			# A fit adult clears about half a metre standing; games stretch that, but not to a car roof.
			check(apex > 0.45 and apex < 1.0, "the %s jump is a person's jump (%.2f m)" % ["running" if sprint else "standing", apex])
			await secs(0.5)

	say("\n== 16. On foot: kerbs and steps ==")
	if true:
		# From the roadway up onto the sidewalk (a 17 cm kerb), walking straight at it.
		p.place(ground(x0 + 9.0, z0 + 1.5, 0.2), 0.0)
		p.rig.yaw = PI             # the camera looks south, toward the kerb
		await secs(0.6)
		var h0 := height_over_ground(p.global_position)
		Input.action_press("street_forward")
		var v_min := 99.0
		var t := 0.0
		while t < 1.15:
			await physics_frame
			t += 1.0 / 60.0
			if t > 0.4:
				v_min = minf(v_min, p.velocity.length())
		release_all()
		var rise := height_over_ground(p.global_position) - h0
		var went := Planet.flat(p.global_position).z - (z0 + 1.5)
		say("  walking at the kerb: ends %.2f m higher, %.1f m on, slowest %.2f m/s" % [rise, went, v_min])
		check(rise > 0.1 and went > 2.6 and v_min > 2.0, "the character steps up a kerb without stopping")
		for hgt in [0.25, 0.45, 0.8]:
			p.place(ground(x0 + 20.0, z0, 0.2), 0.0)
			p.rig.yaw = -PI * 0.5
			wall(x0 + 27.0, z0, Vector3(10.0, hgt * 2.0, 3.0)).position += Planet.up(ground(x0 + 27.0, z0)) * -hgt
			await secs(0.6)
			h0 = height_over_ground(p.global_position)
			Input.action_press("street_forward")
			await secs(1.5)
			release_all()
			rise = height_over_ground(p.global_position) - h0
			say("  a %.0f cm step: %s" % [hgt * 100.0, "climbed" if rise > hgt * 0.8 else "blocked"])
			check((rise > hgt * 0.8) == (hgt <= p.step_height + 0.001), "a %.0f cm step is %s" % [hgt * 100.0, "climbed" if hgt <= p.step_height else "too high to walk up"])
			await clear()

	say("\n== 17. On foot: a fall ==")
	if true:
		for hgt in [3.0, 8.0, 14.0]:
			p.place(ground(x0 + 40.0, z0, hgt), 0.0)
			p.health = p.MAX_HEALTH
			p.dead = false
			await tick(2)
			var t := 2.0 / 60.0
			while not p.is_on_floor() and t < 4.0:
				await physics_frame
				t += 1.0 / 60.0
			await secs(0.3)
			say("  from %.0f m: lands after %.2f s (free fall would be %.2f s), health %.0f of %.0f" % [hgt, t, sqrt(2.0 * hgt / G), p.health, p.MAX_HEALTH])
			check(t > 0.3 and t < sqrt(2.0 * hgt / G) * 1.15 and absf(height_over_ground(p.global_position)) < 0.25, "a %.0f m fall ends on the ground" % hgt)
			check((p.health < p.MAX_HEALTH) == (hgt > 5.0), "a %.0f m fall %s" % [hgt, "hurts" if hgt > 5.0 else "is shrugged off"])

	say("\n== 18. Pushing a parked car on foot ==")
	if true:
		p.place(ground(x0 + 80.0, z0, 0.2), 0.0)
		p.rig.yaw = -PI * 0.5
		var c := car("car_hatch", x0 + 84.0, z0)
		await secs(1.0)
		var at: Vector3 = c.global_position
		Input.action_press("street_sprint")
		Input.action_press("street_forward")
		await secs(3.0)
		release_all()
		say("  sprinting into a parked hatchback for 3 s moves it %.2f m; the person ends %.1f m from where they began" % [c.global_position.distance_to(at),
			Planet.flat(p.global_position).x - (x0 + 80.0)])
		check(c.global_position.distance_to(at) < 1.5, "a person can't shove a car down the road")
		await clear()

	say("\n== 19. A car against the person on foot ==")
	if true:
		for v_in in [3.0, 8.0, 16.0]:
			p.place(ground(x0 + 60.0, z0, 0.2), 0.0)
			p.health = p.MAX_HEALTH
			p.dead = false
			await secs(0.4)
			var at: Vector3 = p.global_position
			var c := car("car_sedan", x0 + 45.0, z0)
			await secs(0.8)
			c.linear_velocity = c.forward() * v_in
			var v_after: float = v_in
			var t := 0.0
			var hit := false
			var v_car_min: float = v_in
			while t < 4.0:
				await physics_frame
				t += 1.0 / 60.0
				if not hit:
					c.linear_velocity += c.forward() * (v_in - c.speed())   # hold the speed up to the hit (it is parked: no engine)
					if c.global_position.distance_to(p.global_position) < 3.2:
						hit = true
				else:
					v_car_min = minf(v_car_min, c.linear_velocity.length())
			say("  sedan at %2.0f m/s into the person: the car drops to %.1f m/s, the person is moved %.1f m, health %.0f of %.0f" % [v_in, v_car_min,
				p.global_position.distance_to(at), p.health, p.MAX_HEALTH])
			check(p.health < p.MAX_HEALTH or v_in < 4.0, ("being hit at %.0f m/s hurts" if v_in >= 4.0 else "a nudge at %.0f m/s does no harm") % v_in)
			check(v_car_min > v_in * 0.3 or v_in < 4.0, "a person doesn't stop a car dead at %.0f m/s (it is parked, so its brake is on)" % v_in)
			await clear()

	p.set_controls(false)
	say("\n%s" % ("ALL PASSED" if fails == 0 else "%d FAILED" % fails))
	if out != "":
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_string("\n".join(lines) + "\n")
	Engine.time_scale = 1.0
	quit(1 if fails > 0 else 0)
