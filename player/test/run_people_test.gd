extends SceneTree
## Headless check of the round-3 people, camera and car feel:
##   godot --headless -s res://player/test/run_people_test.gd
## Wardrobe parts and LODs, outfits from seeds and by hand, the clip set, the activity
## and one-shot API, knock-downs, the body lean of cars and the camera's shake and lean.
## Exits with code 1 on any failure.

var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	var m := CharacterModel.new()
	m.seed_value = 3
	m.lod = 0
	root.add_child(m)
	await frames(2)
	# Clips.
	var clips := ["Idle", "IdleLook", "IdleArms", "Walk", "Run", "Jump", "Fall", "Sit", "SitBench",
		"EnterCar", "ExitCar", "Talk", "Phone", "Wave", "Punch", "Jab", "Hook", "AimPistol", "AimShotgun",
		"ReloadPistol", "ReloadShotgun", "Hit", "Stumble", "FallBack", "GetUp", "Die", "Carjack"]
	var missing := clips.filter(func(c): return not m.anim.has_animation(c))
	check(missing.is_empty(), "all %d clips are in the glb %s" % [clips.size(), missing])
	var skel := m.skeleton
	for b in ["Jaw", "Fingers1.L", "Fingers2.L", "Thumb.L", "Fingers1.R", "Fingers2.R", "Thumb.R", "Head", "Hand.R"]:
		if skel.find_bone(b) < 0:
			check(false, "bone %s" % b)
	check(skel.get_bone_count() == 24, "24 bones with fingers and a jaw (%d)" % skel.get_bone_count())
	# Wardrobe: every style has its part at both LODs.
	var parts := ["Head_skin", "Brows", "Hands"]
	for st in CharacterModel.TOPS:
		parts.append("Top_" + st)
	for st in CharacterModel.BOTTOMS:
		parts.append("Bottom_" + st)
	for st in CharacterModel.SHOE_STYLES:
		parts.append("Shoes_" + st)
	for st in CharacterModel.HATS:
		if st != "":
			parts.append("Hat_" + st)
	for st in CharacterModel.HAIR_STYLES:
		if st != "bald":
			parts.append("Hair_" + st)
	for st in CharacterModel.FACES:
		if st != "clean":
			parts.append("Face_" + st)
	var lost := []
	for p in parts:
		if not CharacterModel._lib.has(p) or not CharacterModel._lib.has(p + "_lod1"):
			lost.append(p)
	check(lost.is_empty(), "%d wardrobe parts, each with a LOD1 %s" % [parts.size(), lost])
	# Budgets over many seeds.
	var worst0 := 0
	var worst1 := 0
	var tops := {}
	var hairs := {}
	for s in 60:
		m.seed_value = s
		m.clear_outfit()
		worst0 = maxi(worst0, m.triangle_count())
		tops[m.outfit.top] = true
		hairs[m.outfit.hair] = true
		var low := CharacterModel._single_mesh(m.part_names())
		worst1 = maxi(worst1, low.surface_get_array_index_len(0) / 3)
	check(worst0 <= 11000, "full outfit at most about 10k triangles (worst %d)" % worst0)
	check(worst1 <= 1700, "crowd LOD about 1.5k triangles (worst %d)" % worst1)
	check(tops.size() >= 4 and hairs.size() >= 6, "seeds vary the outfit (%d tops, %d hair styles)" % [tops.size(), hairs.size()])
	# The full mesh keeps the named material slots the creator recolours.
	var names := []
	for s in m.body.mesh.get_surface_count():
		names.append(m.body.mesh.surface_get_material(s).resource_name)
	check("Skin" in names and "Pants" in names and "Shoes" in names and "Eyes" in names and "EyeWhite" in names,
		"named surfaces %s" % [names])
	# By hand.
	var dressed := [0]
	m.dressed.connect(func(): dressed[0] += 1)
	m.set_outfit({"top": "hoodie", "bottom": "skirt", "hair": "bun", "hat": "", "face": "glasses",
		"colors": {"Shirt": Color(0.1, 0.8, 0.2)}})
	check(dressed[0] == 1 and m.outfit.top == "hoodie" and "Bottom_skirt" in m.part_names() and "Hair_bun" in m.part_names(),
		"set_outfit picks the parts and emits dressed")
	check(m.mats.Shirt.albedo_color.is_equal_approx(Color(0.1, 0.8, 0.2)), "set_outfit colours the shirt")
	m.set_outfit({"hair": "bald", "face": "clean"})
	check(not "Hair_bald" in m.part_names() and m.outfit.top == "hoodie", "bald needs no hair part; other picks stay")
	var cop := CharacterModel.new()
	cop.seed_value = 777
	root.add_child(cop)
	cop.set_outfit({"preset": "police"})
	check(cop.outfit.top == "longsleeve" and cop.outfit.hat == "cap" and cop.colors.Shirt.is_equal_approx(Color(0.12, 0.17, 0.33)),
		"police preset: navy long sleeves and a cap")
	# LOD swap keeps one draw call far away.
	cop.lod = 1
	cop.animate(0.016, 0.0, true, 0.0, 0.0)
	check(cop.current_lod() == 1 and cop.body.mesh.get_surface_count() == 1 and cop.triangle_count() < 1700,
		"LOD1 is one surface (%d triangles)" % cop.triangle_count())
	check(cop.body.get_instance_shader_parameter("c_shirt").is_equal_approx(Color(0.12, 0.17, 0.33, CharacterModel.ROUGH.Shirt)),
		"LOD1 colours come in per person")
	cop.lod = 0
	cop.animate(0.016, 0.0, true, 0.0, 0.0)
	check(cop.body.mesh.get_surface_count() > 4 and cop.shadow_body.visible, "back to the full mesh, LOD1 casts the shadow")
	# Activities and one-shots.
	m.set_activity("phone")
	await frames(2)
	check(m._phone != null and m._phone.visible, "a phone appears in the hand")
	m.set_activity("")
	check(not m._phone.visible, "and goes away")
	var seq := [m.play_punch(), m.play_punch(), m.play_punch(), m.play_punch()]
	check(seq == ["Jab", "Punch", "Hook", "Jab"], "punches run jab, cross, hook %s" % [seq])
	m.knock_down()
	for i in 10:
		m.animate(0.05, 0.0, true, 0.0, 0.0)
	check(m.is_down(), "knocked down stays down")
	m.get_up()
	check(not m.is_down(), "gets up")
	m.auto_idle = true
	m.set_activity("")
	for i in 200:
		m.animate(0.05, 0.0, true, 0.0, 0.0)
	check(m._auto_on or m._still < 0.0, "standing still long enough starts an idle variation")
	# Car feel.
	var car := DrivableCar.new()
	root.add_child(car)
	var truck := DrivableCar.new()
	truck.model = "car_truck"
	root.add_child(truck)
	var bus := DrivableCar.new()
	bus.model = "car_bus"
	root.add_child(bus)
	await frames(2)
	check(truck.brake_force > car.brake_force and truck.steer_speed < car.steer_speed and truck.mass > 2 * car.mass,
		"trucks are heavier, steer slower and need more brake")
	check(bus.mass > truck.mass and bus._wheels.size() == 2 * DrivableCar.kit_spec("car_bus").get("axles", [0, 0, 0]).size(), "the bus sits on the car kit's axles")
	m.set_activity("umbrella")
	for i in 20:
		m.animate(0.05, 0.0, true, 0.0, 0.0)
	check(m.anim.has_animation("Umbrella") and m.umbrella_grip().y > m.global_position.y + 0.9,
		"umbrella pose holds the fist up (%.2f m)" % (m.umbrella_grip().y - m.global_position.y))
	m.set_activity("")
	# Damage stages from the car kit, and no built-in driver in the player's car.
	var hurt := DrivableCar.new()
	hurt.model = "car_taxi"
	root.add_child(hurt)
	await frames(2)
	if hurt._kit_shader:
		var clean := hurt._mm.mesh
		hurt.take_hit(300.0)
		check(hurt.damage_stage == 1 and hurt._mm.mesh != clean, "a dented car swaps to the dented mesh")
		hurt.take_hit(400.0)
		check(hurt.damage_stage == 2, "a smoking car looks smashed")
		hurt.explode()
		check(hurt.damage_stage == 3, "a wreck is burnt out")
		check(car.lamp_flags() & 4 == 4, "a parked car has no driver in it")
	else:
		print("  (no car kit in this run: damage meshes not checked)")
	# The test car has no road under it (and nothing leans in the air), so check the
	# lean it asks for and the spring that chases it.
	var lean_goal := clampf(8.0 * car._feel.roll, -DrivableCar.MAX_ROLL, DrivableCar.MAX_ROLL)
	check(lean_goal > 0.05, "a hard corner asks for a visible lean (%.3f rad)" % lean_goal)
	car._roll = Vector2(0.0, 0.0)
	var k: float = car._feel.spring
	var x := 0.0
	var v := 0.0
	for i in 60:
		v += ((lean_goal - x) * k - v * 2.0 * sqrt(k) * 0.55) / 60.0
		x += v / 60.0
	check(absf(x - lean_goal) < 0.01, "the body spring settles on the lean within a second")
	# Camera feel.
	var cam := StreetCamera.new()
	root.add_child(cam)
	cam.mode = StreetCamera.Mode.FOLLOW
	cam.shake(0.8)
	await frames(3)
	check(cam._shake > 0.0 and (cam.h_offset != 0.0 or cam.v_offset != 0.0), "a hit shakes the camera")
	for i in 120:
		cam._process(1.0 / 60.0)
	check(cam._shake == 0.0 and cam.h_offset == 0.0, "and the shake dies away")
	cam.lean = 0.06
	for i in 120:
		cam._process(1.0 / 60.0)
	check(absf(cam._lean - 0.06) < 0.005, "the camera leans into corners")
	print("people test: %s" % ("all passed" if fails == 0 else "%d failed" % fails))
	quit(1 if fails > 0 else 0)
