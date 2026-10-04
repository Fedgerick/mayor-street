extends SceneTree
## Headless checks for character creation and the home:
##   godot --headless --path . --script res://creator/tests/run_creator_tests.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	print("  ok   " if cond else "  FAIL ", what)
	if not cond:
		failures += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Creator tests")
	# Looks and profiles round-trip through JSON, the way a save file stores them.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var p := ResidentProfile.new()
	p.name = "  Vic Vance  "
	p.look = CharacterLook.random(rng)
	p.background = "medic"
	p.home = Vector2i(12, 30)
	p.save_outfit(2)
	p.owned.append("cloth:14")
	var d = JSON.parse_string(JSON.stringify(p.to_dict()))
	var q := ResidentProfile.parse(d)
	check(q.name == "Vic Vance", "name trimmed and kept (%s)" % q.name)
	check(q.look.to_dict() == p.look.to_dict(), "look survives JSON")
	check(q.home == Vector2i(12, 30), "home cell survives JSON")
	check(q.outfits.size() == 3 and CharacterLook.from_dict(q.outfits[2]).to_dict() == p.look.to_dict(), "wardrobe slot kept")
	check(q.owned.has("cloth:14"), "owned shop items kept")
	check(is_equal_approx(float(q.perk("heal_rate", 1.0)), 1.5), "medic heals faster")
	check(q.perk("car_handling", 1.0) == 1.0, "medic has no car perk")
	check(ResidentProfile.parse({"background": "pirate", "look": {"hair": "wig", "skin": 99}}).background == "cabbie",
		"unknown background falls back")
	var bad := CharacterLook.from_dict({"hair": "wig", "skin": 99, "height": 3.0})
	check(bad.hair == "short" and bad.skin == CharacterLook.SKIN.size() - 1 and bad.height == 1.08,
		"bad look values are clamped")
	for id in ResidentProfile.BACKGROUND_ORDER:
		check(not ResidentProfile.BACKGROUNDS[id].perks.is_empty(), "background %s has a perk" % id)

	# Shop colors can't be worn from a saved outfit once not owned.
	var w := ResidentProfile.new()
	w.look.top = 0
	w.outfits.append({"top": 15})
	w.wear_outfit(0)
	check(w.look.top == 0, "locked shop color not worn")
	w.owned.append("cloth:15")
	w.wear_outfit(0)
	check(w.look.top == 15, "owned shop color worn")

	# Every hair and face combination makes pieces near the head.
	var all_ok := true
	for h in CharacterLook.HAIR_ORDER:
		for f in CharacterLook.FACE_ORDER:
			for pc in CharacterLook.pieces(h, f):
				if pc.pos.distance_to(Vector3(0, 1.66, 0)) > 0.3:
					all_ok = false
	check(all_ok, "hair and face pieces sit on the head")

	# Homes: auto move-in, describe, door, survives a merge, lost on bulldoze.
	var c := City.new()
	c.build_starter()
	var mid := c.center_cell()
	var home := ResidentHome.new()
	var prof := ResidentProfile.new()
	root.add_child(home)
	home.setup(c, prof)
	check(not prof.has_home(), "no home on an empty island")
	var lost := [0]
	home.home_lost.connect(func(): lost[0] += 1)
	c.add_building(mid.x + 1, mid.y + 1, 1, City.Zone.COM, 1, 2, false)
	check(not prof.has_home(), "shops are not homes")
	var id := c.add_building(mid.x + 2, mid.y + 1, 1, City.Zone.RES, 1, 2, false)
	check(prof.home == Vector2i(mid.x + 2, mid.y + 1), "moved into the first house")
	check(home.label().begins_with("House"), "home described (%s)" % home.label())
	var door := home.door_position()
	var road_z := c.cell_center(mid.x, mid.y).z
	check(absf(door.z - road_z) < City.TILE, "door faces the road")
	var sp := home.spawn_transform()
	check(sp.origin.distance_to(door) < 2.5, "spawn just outside the door")
	# Merge-style replacement: remove and re-add over the same cell in one go.
	c.remove_building(id)
	c.add_building(mid.x + 2, mid.y + 1, 2, City.Zone.RES, 3, 2, false)
	await process_frame
	check(prof.has_home() and lost[0] == 0, "home survives becoming a tower")
	c.remove_building(c.bld[c.idx(mid.x + 2, mid.y + 1)])
	await process_frame
	check(not prof.has_home() and lost[0] == 1, "bulldozed home is lost")
	check(not home.move_in(Vector2i(mid.x + 1, mid.y + 1)), "can't move into a shop")
	check(HomePicker.candidates(c).is_empty(), "picker lists no homes now")

	# The glue node works without a street (map-only, or before StreetMode exists).
	var res := Resident.new()
	root.add_child(res)
	res.setup(c, null, null)
	var hb := c.add_building(mid.x + 4, mid.y + 1, 1, City.Zone.RES, 1, 2, false)
	check(res.profile.has_home() and res.respawn_point().origin.is_finite(), "resident moves in and has a respawn point")
	check(not res.profile.loaded, "a new game is not a loaded one")
	c.remove_building(hb)
	await process_frame
	check(not res.respawn_point().origin.is_finite(), "no respawn point without a home")
	res.queue_free()

	# Dressing a real CharacterModel.
	if CharacterModel.available():
		var cm := CharacterModel.new()
		root.add_child(cm)
		var l := CharacterLook.new()
		l.hair = "afro"
		l.face = "shades"
		l.body = "heavy"
		l.top = 5
		l.apply(cm)
		var mi: MeshInstance3D = cm.model.find_children("*", "MeshInstance3D", true, false)[0]
		var names := []
		for s in mi.mesh.get_surface_count():
			names.append(mi.mesh.surface_get_material(s).resource_name)
		check(not names.has("Hair"), "afro drops the hair cap (%s)" % str(names))
		var shirt_ok := false
		for s in mi.mesh.get_surface_count():
			if names[s] == "Shirt":
				shirt_ok = mi.get_surface_override_material(s).albedo_color == CharacterLook.CLOTH[5]
		check(shirt_ok, "shirt dressed in the chosen color")
		var extra := cm.model.find_child(CharacterLook.EXTRA, true, false)
		check(extra != null and extra.get_child_count() == CharacterLook.pieces("afro", "shades").size(),
			"head pieces attached")
		check(cm.model.scale.x > 1.1, "heavy body is wider")
		l.hair = "short"
		l.face = "clean"
		l.apply(cm)
		await process_frame
		names.clear()
		for s in mi.mesh.get_surface_count():
			names.append(mi.mesh.surface_get_material(s).resource_name)
		check(names.has("Hair"), "short hair brings the cap back")
		check(cm.model.find_children(CharacterLook.EXTRA, "", true, false).size() == 1, "re-dressing replaces pieces")
		cm.animate(0.016, 2.0, true, 0.0, 0.0)
		check(true, "animates after dressing")

		# With the real street mode: the player character wears the profile's look.
		var street = load("res://player/scenes/street_mode.tscn").instantiate()
		root.add_child(street)
		street.setup(c)
		var cam3 := Camera3D.new()
		root.add_child(cam3)
		var rs := Resident.new()
		root.add_child(rs)
		rs.profile.look.hair = "mohawk"
		rs.setup(c, street, cam3)
		check(street.player.visual.model.find_child(CharacterLook.EXTRA, true, false) != null,
			"street character dressed by the resident")
		street.player.visual._dress()
		await process_frame
		var shirt2 := false
		var mi2: MeshInstance3D = street.player.visual.model.find_children("*", "MeshInstance3D", true, false)[0]
		for s in mi2.mesh.get_surface_count():
			if mi2.mesh.surface_get_material(s).resource_name == "Shirt":
				shirt2 = mi2.get_surface_override_material(s).albedo_color == CharacterLook.CLOTH[rs.profile.look.top]
		check(shirt2, "look comes back after player/ re-dresses")

		# The real home room from interiors/, when it's there.
		if ResourceLoader.exists("res://interiors/interior_manager.gd"):
			rs.profile.home = Vector2i(-1, -1)
			c.add_building(mid.x + 6, mid.y + 1, 1, City.Zone.RES, 1, 2, false)
			var im = load("res://interiors/interior_manager.gd").new()
			root.add_child(im)
			im.setup(c, street)
			rs.use_interiors(im)
			check(rs._home_door != null and is_instance_valid(rs._home_door), "home gets a door into the home room")
			var entered := [0]
			rs.home_entered.connect(func(): entered[0] += 1)
			street.active = true
			await im.enter("home", rs._home_door)
			check(entered[0] == 1, "walking in counts as entering home")
			var wm: Node3D = im.current.marker("wardrobe")
			check(wm != null, "home room has a wardrobe spot")
			if wm:
				street.player.global_position = wm.global_position
				check(rs._home_spot() == "wardrobe", "standing at the wardrobe is noticed")
			street.active = false

		var cc := CharacterCreator.new()
		root.add_child(cc)
		await process_frame
		check(cc.profile != null and cc._model != null, "creator opens with a preview model")
		for page in ["You", "Look", "Clothes"]:
			cc._show_page(page)
		check(cc._page.get_child_count() > 0, "creator pages build")
		var got := []
		cc.finished.connect(func(pp): got.append(pp))
		cc._done.pressed.emit()
		check(got.size() == 1 and got[0] is ResidentProfile, "Done hands back a profile")
		var ww := CharacterCreator.new()
		ww.mode = CharacterCreator.Mode.WARDROBE
		ww.profile = q
		root.add_child(ww)
		await process_frame
		ww._show_page("Outfits")
		check(ww._page.get_child_count() == ResidentProfile.WARDROBE_SLOTS + 1, "wardrobe shows outfit slots")
		ww.queue_free()
	else:
		print("  skip character dressing (character.glb not imported)")

	print("%d failures" % failures)
	quit(1 if failures else 0)
