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

	# Clothing styles: free basics, owned ones, hats and hair that clip, old saves.
	var cl := CharacterLook.new()
	check(CharacterLook.style_owned("top", "tee", PackedStringArray()), "tee is free")
	check(not CharacterLook.style_owned("top", "hoodie", PackedStringArray()), "hoodie is not free")
	check(CharacterLook.style_owned("top", "hoodie", PackedStringArray(["top:hoodie"])), "bought hoodie is owned")
	cl.set_hair("afro")
	cl.set_style("hat", "cap")
	check(cl.hair == "short" and cl.hat == "cap", "a hat swaps clipping hair for short hair")
	cl.set_hair("mohawk")
	check(cl.hat == "", "clipping hair takes the hat off")
	var old := CharacterLook.from_dict({"top": 5, "hair": "short"})
	check(old.top_style == "tee" and old.bottom_style == "jeans" and old.shoe_style == "sneakers" and old.hat == "",
		"old saves load as tee, jeans, sneakers")
	check(CharacterLook.from_dict({"hair": "afro", "hat": "cap"}).hat == "", "saved hat on clipping hair is dropped")
	var rl := CharacterLook.random(rng)
	check(CharacterLook.style_owned("top", rl.top_style, PackedStringArray()) and rl.hat == "",
		"random looks only use free clothes")
	var hw := ResidentProfile.new()
	hw.look.top_style = "hoodie"
	hw.save_outfit(0)
	hw.look.top_style = "tee"
	hw.wear_outfit(0)
	check(hw.look.top_style == "tee", "unowned hoodie not worn from a saved outfit")
	hw.owned.append("top:hoodie")
	hw.wear_outfit(0)
	check(hw.look.top_style == "hoodie", "owned hoodie worn from a saved outfit")
	var bl := CharacterLook.new()
	bl.top_style = "jacket"
	bl.hat = "beanie"
	var b2 := ClothingStock.unpaid(bl, PackedStringArray())
	check(b2.ids.has("top:jacket") and b2.ids.has("hat:beanie"), "bill lists the jacket and the beanie")
	bl.top_style = "tee"
	bl.hat = ""
	bl.jacket = 17
	bl.hat_color = 17
	check(ClothingStock.unpaid(bl, PackedStringArray()).total == 0, "unworn jacket and hat colors are not billed")

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
		l.top_style = "hoodie"
		l.shoe_style = "boots"
		l.apply(cm)
		var parts: PackedStringArray = cm.part_names()
		check(parts.has("Hair_afro") and parts.has("Face_shades") and parts.has("Top_hoodie") and parts.has("Shoes_boots"),
			"model wears the chosen styles (%s)" % ", ".join(parts))
		check(cm.colors.Shirt == CharacterLook.CLOTH[5] and cm.colors.Skin == CharacterLook.SKIN[l.skin],
			"model wears the chosen colors")
		check(cm.model.scale.x > 1.1, "heavy body is wider")
		var passes := [0]
		cm.dressed.connect(func(): passes[0] += 1)
		l.apply(cm)
		check(passes[0] == 0, "applying the same look again changes nothing")
		l.hair = "short"
		l.face = "clean"
		l.set_style("hat", "cap")
		l.hat_color = 3
		l.apply(cm)
		check(cm.part_names().has("Hat_cap") and cm.colors.Hat == CharacterLook.CLOTH[3], "hat and hat color applied")
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
		check(street.player.visual.part_names().has("Hair_mohawk"), "street character dressed by the resident")
		street.player.visual.clear_outfit()   # player/ re-dresses from its seed; ours must come back
		await process_frame
		check(street.player.visual.part_names().has("Hair_mohawk") and
			street.player.visual.colors.Shirt == CharacterLook.CLOTH[rs.profile.look.top],
			"look comes back after player/ re-dresses")

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

	# Clothing shop: the bill, the screen, and paying from Progress.
	var sl := CharacterLook.new()
	sl.top = 17
	sl.bottom = 17
	sl.shoes = 19
	var bill := ClothingStock.unpaid(sl, PackedStringArray(["cloth:19"]))
	check(bill.total == ClothingStock.price("cloth:17") and bill.ids == ["cloth:17"], "bill counts each unowned color once")
	check(ClothingStock.unpaid(CharacterLook.new(), PackedStringArray()).total == 0, "free colors cost nothing")
	for i in range(CharacterLook.CLOTH_FREE, CharacterLook.CLOTH.size()):
		check(ClothingStock.price(ClothingStock.cloth_id(i)) > 0, "shop color %d has a price" % i)
	var progd: Node = root.get_node_or_null("Progress")
	if progd:
		progd.unlock(ClothingStock.PERK_DISCOUNT, "test")
		check(ClothingStock.price("cloth:17") == roundi(150 * 0.85), "shop discount perk takes 15% off")
		progd.lock(ClothingStock.PERK_DISCOUNT)
		check(ClothingStock.price("cloth:17") == 150, "full price without the perk")
	if CharacterModel.available():
		var shop := CharacterCreator.new()
		shop.mode = CharacterCreator.Mode.SHOP
		shop.cash = 100
		root.add_child(shop)
		await process_frame
		shop.profile.look.top = 17   # gold, $150
		shop._changed()
		check(shop._done.disabled and shop._done.text.contains("150"), "can't buy what you can't afford")
		shop.profile.look.top = 15   # teal, $75
		shop._changed()
		check(not shop._done.disabled, "can buy what you can afford")
		shop.queue_free()
		var prog: Node = root.get_node_or_null("Progress")
		var buyer := Resident.new()
		root.add_child(buyer)
		buyer.setup(c, null, null)
		if prog:
			prog.add_cash(1000, "test")
			var before: int = prog.cash
			var spent_box := [-1]
			var run := func(): spent_box[0] = await buyer.open_shop()
			run.call()
			await process_frame
			var screen: CharacterCreator = buyer.find_children("*", "CharacterCreator", true, false)[0]
			screen.profile.look.shoes = 16
			screen._done.pressed.emit()
			await process_frame
			check(spent_box[0] == ClothingStock.price("cloth:16"), "shop charges for the new shoes (%d)" % spent_box[0])
			check(prog.cash == before - spent_box[0], "cash went down")
			check(buyer.profile.owned.has("cloth:16") and buyer.profile.look.shoes == 16, "bought shoes are owned and worn")
			check(not paused, "game unpaused after the shop")
		buyer.queue_free()

	print("%d failures" % failures)
	quit(1 if failures else 0)
