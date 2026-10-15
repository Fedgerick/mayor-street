extends SceneTree
## Headless checks for HeroLook:  godot --headless -s res://characters/test/run_hero_test.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		failures += 1


func _init() -> void:
	print("Hero look tests")
	await process_frame   # the root enters the tree on the first frame
	check(HeroLook.available(), "hero.glb is built")
	var cm := CharacterModel.new()
	cm.lod = 0
	root.add_child(cm)
	await process_frame
	cm.set_outfit({"top": "hoodie", "bottom": "jeans", "shoes": "sneakers", "hat": "", "hair": "short", "face": "glasses"})
	var street_tris := cm.triangle_count()
	var street_mesh := cm.body.mesh
	var h := HeroLook.attach(cm)
	await process_frame
	check(cm.body.mesh != street_mesh and cm.body.mesh == h._mesh, "the close-up mesh is the hero mesh")
	check(cm.body.skin == HeroLook._skin, "bound to the hero skin")
	var tris := cm.triangle_count()
	check(tris > street_tris * 2 and tris < 32000, "hero outfit %d triangles (street %d, cap 32k)" % [tris, street_tris])
	check(cm.body.mesh.get_surface_count() <= 16, "%d surfaces (draw calls)" % cm.body.mesh.get_surface_count())
	var names := []
	for s in cm.body.mesh.get_surface_count():
		names.append(cm.body.mesh.surface_get_name(s))
		var m: Material = cm.body.get_surface_override_material(s)
		check(m is ShaderMaterial, "surface %s has a hero material" % names[-1])
	for want in ["Skin", "Shirt", "Trim", "Pants", "Iris", "Frame", "Sole", "Laces"]:
		check(want in names, "outfit draws %s" % want)
	check(not ("Lens" in names), "plain glasses have no lens")
	check(cm.shadow_body.visible and cm.shadow_body.mesh == h._shadow and cm.shadow_body.skin == HeroLook._skin
		and cm.shadow_body.mesh.get_surface_count() == 1, "the shadow is the hero shape in one draw call")

	h.detail = 0.0
	check(cm.body.get_surface_override_material(0).get_shader_parameter("detail") == 0.0, "detail 0 applies at once")
	h.detail = 1.0

	# Re-dressing rebuilds the hero mesh for the new outfit.
	cm.set_outfit({"top": "tank", "face": "shades", "hat": "cap"})
	await process_frame
	names.clear()
	for s in cm.body.mesh.get_surface_count():
		names.append(cm.body.mesh.surface_get_name(s))
	check(cm.body.mesh == h._mesh and "Lens" in names and "Hat" in names, "re-dress keeps the hero look (shades, cap)")
	check(not ("Trim" in names), "a tank top has no ribbed trim")

	# Far away the crowd mesh takes over with the street skin; back close, the hero look returns.
	cm.lod = 1
	cm._update_lod(0.1)
	await process_frame
	await process_frame
	check(cm.current_lod() == 1 and cm.body.mesh != h._mesh, "LOD1 uses the crowd mesh")
	check(cm.body.skin == CharacterModel._skin and cm.shadow_body.skin == CharacterModel._skin, "LOD1 is back on the street skin")
	cm.lod = 0
	cm._update_lod(0.1)
	await process_frame
	await process_frame
	check(cm.body.mesh == h._mesh, "back at LOD0 the hero mesh returns")

	# install() finds the player's model and leaves the crowd alone.
	HeroLook.install(self)
	var crowd := CharacterModel.new()
	root.add_child(crowd)
	var sp := StreetPlayer.new()
	root.add_child(sp)
	await process_frame
	await process_frame
	check(sp.visual != null and sp.visual.has_node("HeroLook"), "install() upgrades the street player")
	check(sp.visual.get_node("HeroLook").mid == false, "the player gets full detail")
	check(crowd.has_node("HeroLook") and crowd.get_node("HeroLook").mid, "crowd models get mid detail")
	crowd.lod = 0
	crowd.set_outfit({"top": "jacket", "bottom": "jeans", "hair": "long", "face": "beard", "hat": ""})
	await process_frame
	var plain := CharacterModel._merged_mesh(crowd.part_names(), 0)
	var plain_tris := 0
	for s in plain.get_surface_count():
		plain_tris += plain.surface_get_array_index_len(s) / 3
	check(crowd.triangle_count() < plain_tris * 1.25, "crowd hero %d triangles vs street %d" % [crowd.triangle_count(), plain_tris])
	check(crowd.shadow_body.mesh != crowd.get_node("HeroLook")._shadow, "crowd keeps the crowd mesh's cheap shadow")
	var cnames := []
	for s in crowd.body.mesh.get_surface_count():
		cnames.append(crowd.body.mesh.surface_get_name(s))
	check(not ("Lashes" in cnames), "crowd lashes share the brows' draw call")

	# A long session's crowd: outfit meshes hold GPU buffers, so the caches must stay capped.
	for i in 200:
		var walker := CharacterModel.new()
		walker.seed_value = 1000 + i * 7919
		walker.lod = 0
		root.add_child(walker)
		await process_frame
		walker.queue_free()
	await process_frame
	check(CharacterModel._merged.size() <= CharacterModel.MERGED_MAX and HeroLook._built.size() <= HeroLook.BUILT_MAX,
		"200 crowd outfits leave %d street and %d close-up meshes cached" % [CharacterModel._merged.size(), HeroLook._built.size()])

	# Dogs: a drop-in for citylife's DogMesh.
	check(HeroDog.available(), "dog.glb is built")
	var d0 := HeroDog.build(0)
	var d1 := HeroDog.build(1)
	check(d0.get_surface_count() == 1 and d1.get_surface_count() == 1, "one draw call per dog LOD")
	check(HeroDog.triangle_count(0) < 3000 and HeroDog.triangle_count(1) < HeroDog.triangle_count(0) / 3,
		"dog LOD0 %d, LOD1 %d triangles" % [HeroDog.triangle_count(0), HeroDog.triangle_count(1)])
	var a := d0.surface_get_arrays(0)
	var parts := {}
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for i in (a[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size():
		parts[int(a[Mesh.ARRAY_TEX_UV][i].x + 0.5)] = true
		lo = lo.min(a[Mesh.ARRAY_VERTEX][i])
		hi = hi.max(a[Mesh.ARRAY_VERTEX][i])
	check(parts.size() == 7, "all seven parts tagged for the trot (%d)" % parts.size())
	check(absf(lo.y) < 0.02 and hi.y > 0.55 and hi.y < 0.75 and lo.z < -0.55 and hi.z > 0.3,
		"dog size and facing match DogMesh (%s .. %s)" % [lo, hi])

	# Animation still drives the hero mesh: the hand moves when the arm does.
	var bone := cm.skeleton.find_bone("LowerArm.L")
	var before := cm.skeleton.get_bone_global_pose(bone).origin
	cm.skeleton.set_bone_pose_rotation(cm.skeleton.find_bone("UpperArm.L"), Quaternion(Vector3.FORWARD, 1.0))
	check(cm.skeleton.get_bone_global_pose(bone).origin.distance_to(before) > 0.05, "skeleton poses still apply")

	print("hero look tests: %d failures" % failures)
	quit(1 if failures else 0)
