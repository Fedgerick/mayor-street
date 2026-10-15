extends SceneTree
## Headless check that feet stay planted: a CharacterModel walks, jogs and runs forward
## at a range of speeds, and while a foot is down (lowest, near the ground) it should hardly
## move over the ground. Also checks the seat moves: the feet stay put while the origin
## slides onto the seat with SitDown and back off it with StandUp.
##   godot --headless -s res://player/test/run_gait_test.gd
## Exits with code 1 on any failure.

const SPEEDS := [1.1, 1.4, 2.4, 3.6, 5.0, 7.2]
const MAX_SLIDE := 0.25   # m/s of the planted foot over the ground (was ~2 m/s before the rework)

var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func _foot(m: CharacterModel, side: String) -> Vector3:
	var sk := m.skeleton
	var i := sk.find_bone("Foot." + side)
	return (sk.global_transform * sk.get_bone_global_pose(i)).origin


func _run() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var m := CharacterModel.new()
	m.lod = 1
	m.auto_idle = false
	root.add_child(m)
	await process_frame
	m.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	var dt := 1.0 / 60.0
	for v in SPEEDS:
		m.position = Vector3.ZERO
		for i in 90:   # settle into the gait
			m.animate(dt, v, true, 0.0, 0.0)
			m.position.z -= v * dt
			m.tree.advance(dt)
		var slide := 0.0
		var n := 0
		var prev := {}
		for i in 240:
			m.animate(dt, v, true, 0.0, 0.0)
			m.position.z -= v * dt
			m.tree.advance(dt)
			for side in ["L", "R"]:
				var f := _foot(m, side)
				if prev.has(side) and f.y < 0.104 and prev[side].y < 0.104:
					var d := Vector2(f.x - prev[side].x, f.z - prev[side].z).length() / dt
					slide += d
					n += 1
				prev[side] = f
		var avg := slide / maxf(n, 1)
		check(n > 20 and avg < MAX_SLIDE, "%.1f m/s: planted foot slides %.2f m/s over %d frames" % [v, avg, n])
	# Sitting down: origin slides SEAT_SHIFT back along seat_k, feet stay where they are.
	m.position = Vector3.ZERO
	m.rotation = Vector3.ZERO
	for i in 30:
		m.animate(dt, 0.0, true, 0.0, 0.0)
		m.tree.advance(dt)
	var start := m.position
	var seat := start + Vector3(0, 0, CharacterModel.SEAT_SHIFT)   # behind: the model faces -Z
	m.sit_down()
	var dur := m.clip_length("SitDown")
	var t := 0.0
	var f0 := {}
	var worst := 0.0
	while t < dur:
		t += dt
		m.position = start.lerp(seat, CharacterModel.seat_k(minf(t / dur, 1.0)))
		m.animate(dt, 0.0, true, 0.0, 0.0)
		m.tree.advance(dt)
		for side in ["L", "R"]:
			var f := _foot(m, side)
			if not f0.has(side):
				f0[side] = f
			worst = maxf(worst, Vector2(f.x - f0[side].x, f.z - f0[side].z).length())
	check(worst < 0.12, "sitting down: feet move %.2f m" % worst)
	for i in 60:
		m.animate(dt, 0.0, true, 0.0, 0.0)
		m.tree.advance(dt)
	var hips := m.skeleton.global_transform * m.skeleton.get_bone_global_pose(m.skeleton.find_bone("Hips"))
	check(absf(hips.origin.y - 0.47) < 0.06, "seated: hips at %.2f m, a 0.45 m seat" % hips.origin.y)
	m.stand_up()
	dur = m.clip_length("StandUp")
	t = 0.0
	f0.clear()
	worst = 0.0
	while t < dur:
		t += dt
		m.position = seat.lerp(start, CharacterModel.seat_k(minf(t / dur, 1.0)))
		m.animate(dt, 0.0, true, 0.0, 0.0)
		m.tree.advance(dt)
		for side in ["L", "R"]:
			var f := _foot(m, side)
			if not f0.has(side):
				f0[side] = f
			worst = maxf(worst, Vector2(f.x - f0[side].x, f.z - f0[side].z).length())
	check(worst < 0.12, "standing up: feet move %.2f m" % worst)
	for i in 30:
		m.animate(dt, 0.0, true, 0.0, 0.0)
		m.tree.advance(dt)
	hips = m.skeleton.global_transform * m.skeleton.get_bone_global_pose(m.skeleton.find_bone("Hips"))
	check(hips.origin.y > 0.85, "stood up: hips at %.2f m" % hips.origin.y)
	print("gait test: %d failures" % fails)
	quit(1 if fails else 0)
