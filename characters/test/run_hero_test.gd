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
	check(not crowd.has_node("HeroLook"), "install() leaves crowd models alone")

	# Animation still drives the hero mesh: the hand moves when the arm does.
	var bone := cm.skeleton.find_bone("LowerArm.L")
	var before := cm.skeleton.get_bone_global_pose(bone).origin
	cm.skeleton.set_bone_pose_rotation(cm.skeleton.find_bone("UpperArm.L"), Quaternion(Vector3.FORWARD, 1.0))
	check(cm.skeleton.get_bone_global_pose(bone).origin.distance_to(before) > 0.05, "skeleton poses still apply")

	print("hero look tests: %d failures" % failures)
	quit(1 if failures else 0)
