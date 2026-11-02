extends SceneTree
## msp: the salvage yard (tow trucks belong to yards, tow jobs) and Harbor Arms (the shop,
## med kits, home items, the harbor map quest), on the real game.
##   godot --headless --path . -s shop/tests/test_salvage_shop.gd -- --demo --nosave

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _wait(s: float) -> void:
	await create_timer(s).timeout


func _free_lot(city: City, kind: String, near: Vector2i, skip: Array) -> Vector2i:
	for r in range(1, 14):
		for y in range(near.y - r, near.y + r + 1):
			for x in range(near.x - r, near.x + r + 1):
				var c := Vector2i(posmod(x, City.W), y)
				if c in skip or maxi(absi(x - near.x), absi(y - near.y)) != r:
					continue
				if city.can_place_special(kind, c, true) == "" and city.front_side(c, 1) >= 0:
					return c
	return Vector2i(-1, -1)


func _run() -> void:
	print("salvage yard and shop tests")
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait(1.0)
	var city: City = main.city
	var prog: Node = root.get_node("/root/Progress")

	# ---- catalog and unlocks
	var yd := Catalog.get_def("salvage_yard")
	var gd := Catalog.get_def("gun_shop")
	check(int(yd.tier) == 1 and Catalog.goal_text(1).contains("1,000"), "the salvage yard comes with the 1,000-people milestone")
	check(int(gd.unlock_pop) == 2500 and Catalog.lock_text("gun_shop") == "Reach 2,500 people", "the shop is locked until 2,500 people")
	prog.unlocks.erase("gun_shop")
	var pop0 := city.population
	city.population = 2400
	prog.check_milestones()
	check(not prog.is_unlocked("gun_shop"), "not unlocked at 2,400 people")
	city.population = 2600
	prog.check_milestones()
	check(prog.is_unlocked("gun_shop"), "unlocked at 2,600 people")
	city.population = pop0

	# ---- the yard and its trucks
	main.go_street()
	var street: StreetMode = main.street
	while not street.active:
		await process_frame
	var p := street.player
	var here := city.flat_to_cell(Planet.flat(p.global_position))
	var ycell := _free_lot(city, "salvage_yard", here, [])
	check(ycell.x >= 0, "found a lot for a salvage yard near the player")
	var yid := city.place_special("salvage_yard", ycell, -1, true)
	await _wait(1.2)
	var yards: SalvageYards = main.yards
	var tow: TowService = main.tow
	check(yards.ids().has(yid) and yards.free_trucks() == 2, "the yard has two trucks (%d)" % yards.free_trucks())
	var parked := 0
	for v in root.get_tree().get_nodes_in_group("vehicles"):
		if v.get_meta("yard_truck", -1) == yid and v.model == "car_tow":
			parked += 1
	check(parked == 2, "both trucks are parked out front (%d)" % parked)
	check(tow.capacity() == 2, "two trucks can be out at once")

	# A wreck nearby: a yard truck comes for it, and brings it back.
	var at := p.global_position + p.global_basis.z * 10.0
	var wreck := street.spawn_car("car_sedan", at, 0.0, Color.GRAY)
	await _wait(0.3)
	wreck._set_damage(3)
	wreck.wrecked = true
	check(tow.request(wreck), "a truck is sent for a wreck")
	check(yards.free_trucks() == 1 and yards.out_trucks() == 1, "one truck left the yard")
	var tr: TowService.Truck = tow.trucks[0]
	check(tr.yard == yid, "the truck is the yard's")
	var gate := yards.gate_cell(yid)
	check(gate.x >= 0 and city.flat_to_cell(tr.path[0]) == gate, "it pulls out of the yard's gate")
	wreck.set_meta("on_deck", true)
	tr.car = wreck
	var funds0: float = city.funds
	tow._finish(tr, true)
	check(tow.delivered_count == 1 and city.funds > funds0, "a wreck brought in pays the city ($%d)" % int(city.funds - funds0))
	check(yards.free_trucks() == 2, "the truck is home again")
	tow.enabled = false

	# ---- a tow job
	var dir: MissionDirector = main.missions.director
	var m: Mission = dir.generate("tow_call", Planet.flat(p.global_position))
	check(m != null, "a tow job is offered with a real yard")
	if m:
		dir.start(m)
		check(m.step().do == "vehicle", "first: take a tow truck")
		var truck: DrivableCar = m.mission_car
		check(truck != null and truck.model == "car_tow", "the job lends a tow truck")
		street._enter_car(truck)
		while street.switching:
			await process_frame
		await _wait(0.3)
		check(m.step().do == "tow", "next: hook the car (%s)" % m.step().get("do", ""))
		var target: DrivableCar = m.tow_car
		check(target != null and target.damage_stage >= 2, "the car to tow is smashed")
		var beside := target.global_position + Planet.up(target.global_position) * 0.3 + target.global_basis.x * 3.5
		truck.global_transform = Transform3D(target.global_basis, beside)
		truck.linear_velocity = Vector3.ZERO
		await _wait(3.0)
		check(m.tow_on and m.step().do == "goto", "stopping beside it hooks it on")
		await _wait(0.2)
		var deck := truck.global_transform * (MissionDirector.TOW_BED + Vector3(0, 0.15, 0))
		check(target.global_position.distance_to(deck) < 0.5, "the car rides on the deck")
		var home := Planet.place(m.slots.start.pos) + Planet.up(Planet.place(m.slots.start.pos)) * 0.5
		truck.global_transform = Transform3D(Planet.basis(home), home)
		truck.linear_velocity = Vector3.ZERO
		var cash0: int = prog.cash
		await _wait(1.0)
		check(dir.active == null and prog.cash > cash0, "hauling it to the yard pays ($%d)" % (prog.cash - cash0))
		street._leave_car()
		while street.switching:
			await process_frame

	# ---- Harbor Arms
	here = city.flat_to_cell(Planet.flat(p.global_position))
	var scell := _free_lot(city, "gun_shop", here, [ycell])
	var sid := city.place_special("gun_shop", scell, -1, true)
	await _wait(0.3)
	var shop: GunShop = main.shop
	check(shop._doors.has(sid), "the shop has a door")
	check(main.missions.director.generate("arms_shipment", Planet.flat(p.global_position)) != null, "the shop hands out jobs")
	prog.cash = 20000
	street.combat.strip()
	var r: Array = shop.try_buy("shotgun")
	check(r[1] and street.combat.has_weapon(&"shotgun") and prog.cash == 20000 - 750, "buying a shotgun: %s" % r[0])
	r = shop.try_buy("shotgun_ammo")
	check(r[1], "buying shells: %s" % r[0])
	r = shop.try_buy("med_kit")
	check(r[1] and shop.med_kits == 1, "buying a med kit")
	p.health = 30.0
	check(shop.use_medkit() and p.health == 80.0 and shop.med_kits == 0, "H uses a med kit (+50 health)")
	r = shop.try_buy("lock_picks")
	check(r[1] and int(prog.counts.get("lock_picks", 0)) == 3, "lock picks go to the Progress count")
	r = shop.try_buy("harbor_map")
	main.missions.quests.update()
	check(r[1] and prog.get_flag("item:harbor_map", false) and main.missions.quests.is_active("harbor_map"),
		"the harbor map starts its quest")
	check(shop.why_not("harbor_map") == "Owned", "the map is bought once")
	for id in ["home_safe", "weapon_locker", "med_cabinet", "big_tv", "arcade", "fish_tank", "floor_lamp", "palm", "trophy"]:
		shop.try_buy(id)
	check(shop.owned.size() == 10, "home items bought (%d owned)" % shop.owned.size())
	prog.cash = 0
	check(shop.why_not("armor") == "Can't afford" and not shop.try_buy("armor")[1], "no cash, no sale")

	# Walk in through the shop's door: the counter opens the screen.
	var interiors: InteriorManager = main.interiors
	await interiors.enter("shop_pawn", shop._doors[sid])
	check(shop._in_shop and interiors.current.get_node_or_null("GunWall") != null, "inside Harbor Arms, with its gun wall")
	var counter: Node3D = interiors.current.marker("counter")
	p.global_position = counter.global_position + Vector3(0, 0.1, 0)
	await _wait(0.2)
	check(shop._spot() == "counter", "E at the counter opens the shop")
	shop.open_screen()
	await process_frame
	check(shop.is_open() and paused, "the shop screen pauses the game")
	shop._screen.close()
	await process_frame
	check(not shop.is_open() and not paused, "leaving closes it")
	interiors.exit()
	while interiors.busy:
		await process_frame

	# Home: the items are there; the safe and the locker work.
	await interiors.enter("home")
	var room: Node3D = interiors.current
	var shown := 0
	for id in shop.owned:
		shown += 1 if room.get_node_or_null("ShopItem_" + id) else 0
	check(shown == 9, "the home room shows the 9 home items (%d)" % shown)
	var cab: Node3D = room.get_node_or_null("ShopItem_med_cabinet")
	p.global_position = cab.global_position + Vector3(0, 0.1, -0.8)
	p.health = 20.0
	await _wait(0.2)
	shop._on_interact()
	check(p.health == StreetPlayer.MAX_HEALTH, "E at the first aid cabinet heals fully")
	interiors.exit()
	while interiors.busy:
		await process_frame
	prog.cash = 1000
	street.combat.give(&"pistol")
	street.set_wanted(1)
	street.bust()
	while not street.down:
		await process_frame
	while street.down:
		await process_frame
	await _wait(0.2)
	check(street.combat.has_weapon(&"pistol"), "the weapon locker keeps your guns after Busted")
	check(prog.cash == 900, "the home safe pays half the bail back ($%d left)" % prog.cash)
	if interiors.is_inside():
		interiors.exit()

	# Save and load the shop section.
	var d := shop.to_dict()
	var shop2 := GunShop.new()
	shop2.from_dict(d)
	check(shop2.owned == shop.owned and shop2.med_kits == shop.med_kits, "the shop section saves and loads")
	shop2.free()
	print("ALL PASSED" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails > 0 else 0)
