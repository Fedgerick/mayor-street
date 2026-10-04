extends SceneTree
## Headless check of street action on the demo city with traffic, people and police:
##   godot --headless -s res://player/test/run_action_test.gd
## Pickups, fists and guns against people, wanted stars, armor, car fire and explosions,
## Wasted, Busted, carjacking and parked-car theft. Exits with code 1 on any failure.

var fails := 0
var t: Node3D
var crimes: Array[StringName] = []
var actions: Array[StringName] = []
var got_wasted := 0
var got_busted := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		fails += 1


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func _run() -> void:
	var scene: PackedScene = load("res://player/test/street_test.tscn")
	t = scene.instantiate()
	t.with_life = true
	root.add_child(t)
	await frames(10)
	var street: StreetMode = t.street
	var p: StreetPlayer = street.player
	var life: CityLife = t.life
	street.crime.connect(func(k): crimes.append(k))
	street.goodness_action.connect(func(k): actions.append(k))
	street.wasted.connect(func(): got_wasted += 1)
	street.busted.connect(func(): got_busted += 1)
	t.go_street()
	await frames(int(street.dive_seconds * 60.0) + 40)
	check(street.active, "on the street with city life running")
	check(life.police.suspect == street, "police chase the street player")
	await frames(120)   # let people fill in around the camera

	# --- Wanted stars ----------------------------------------------------------------
	var seen_levels: Array[int] = []
	street.wanted_changed.connect(func(n): seen_levels.append(n))
	street.set_wanted(2)
	check(street.wanted == 2 and street.wanted_stars == 2 and seen_levels == [2], "set_wanted shows 2 stars")
	check(not street.can_exit(), "can't go up to the mayor view while wanted")
	street.heat.clear()
	check(street.wanted == 0 and street.can_exit(), "stars clear")
	actions.clear()

	# --- Pickups ---------------------------------------------------------------------
	var pk := street.spawn_pickup(&"pistol", p.global_position, 30.0)
	await frames(10)
	check(street.combat.current == &"pistol" and street.combat.ammo[&"pistol"] == 34, "pistol pickup arms the player (34 rounds)")
	check(not pk.available(), "pickup waits to respawn")
	var gun_tip := street.combat.muzzle_point()
	check(street.combat._gun != null and street.combat._gun.visible, "pistol model in the hand")
	check(gun_tip.distance_to(p.global_position) < 2.0 and gun_tip.y > p.global_position.y + 0.3, "gun is held in the hand (%s from feet)" % (gun_tip - p.global_position))
	street.spawn_pickup(&"armor", p.global_position + Vector3(0.3, 0, 0), 0.0)
	await frames(10)
	check(p.armor == StreetPlayer.MAX_ARMOR, "armor pickup")
	street.damage_player(30.0)
	check(p.health > 85.0 and p.armor < StreetPlayer.MAX_ARMOR, "armor soaks most of a hit (health %.0f, armor %.0f)" % [p.health, p.armor])
	street.spawn_pickup(&"health", p.global_position + Vector3(-0.3, 0, 0), 0.0)
	await frames(10)
	check(p.health == StreetPlayer.MAX_HEALTH, "health pickup heals")

	# --- Shooting people -------------------------------------------------------------
	var ped = null
	for q in life.crowd.peds:
		if q.flee <= 0.0 and q.pos.distance_to(p.global_position) < 120.0:
			ped = q
			break
	check(ped != null, "found a pedestrian to test on")
	if ped:
		var dir := Vector3(1, 0, 0)
		var from: Vector3 = ped.pos - dir * 8.0 + Vector3.UP * 1.3
		var hit := street.trace_shot(from, dir, 70.0)
		check(hit.kind == &"ped", "a shot lines up on a person (%s)" % hit.kind)
		if hit.kind == &"ped":
			ped = hit.target
		var n := life.crowd.peds.size()
		street.apply_hit(hit, 25.0, dir, &"pistol")
		check(life.crowd.peds.has(ped) and &"assault" in crimes, "first shot wounds (assault)")
		hit = street.trace_shot(from, dir, 70.0)
		street.apply_hit(hit, 25.0, dir, &"pistol")
		check(not life.crowd.peds.has(ped) and life.crowd.peds.size() == n - 1, "second shot kills; the person is gone from the crowd")
		check(&"murder" in crimes and street.wanted >= 2, "murder: %d stars" % street.wanted)
		check(street._corpses.size() == 1, "a body lies where they fell")
		check(&"kill_person" in actions, "goodness hears kill_person")
		await frames(30)
		check(street.heat.level >= 2, "police notice")
	# Real firing through the camera.
	var ammo0: int = street.combat.ammo[&"pistol"]
	crimes.clear()
	street.combat._cool = 0.0
	street.combat.fire()
	check(street.combat.ammo[&"pistol"] == ammo0 - 1, "firing uses a round")
	check(&"shots_fired" in crimes, "gunfire is a crime")
	# A punch.
	street.combat.select(&"fists")
	var ped2 = null
	for q in life.crowd.peds:
		if q.pos.distance_to(p.global_position) < 150.0:
			ped2 = q
			break
	if ped2:
		var back: Vector3 = ped2.fwd
		p.place(ped2.pos + back * 0.9 + Vector3.UP * 0.2, atan2(back.x, back.z))
		ped2.pause = 2.0
		crimes.clear()
		street.combat._cool = 0.0
		street.combat.fire()
		await frames(20)
		check(street._hp.has(ped2) or not life.crowd.peds.has(ped2), "a punch lands")

	# --- Car fire and explosion -------------------------------------------------------
	street.heat.clear()
	var c := street.spawn_car("car_sedan", p.global_position + Vector3(0, 0.3, 0) + p.rig.right_flat() * 6.0, 0.0, Color.RED)
	await frames(60)
	var exploded := [false]
	c.exploded.connect(func(_c): exploded[0] = true)
	var h0 := p.health
	c.take_hit(650.0)
	check(c._smoke != null and not c.burning, "a damaged car smokes")
	c.take_hit(650.0)
	check(c.burning, "a wrecked car catches fire")
	await frames(int(DrivableCar.BURN_SECONDS * 60.0) + 10)
	check(exploded[0] and c.wrecked, "then explodes")
	check(p.health < h0, "the blast hurts the player nearby (%.0f -> %.0f)" % [h0, p.health])
	p.place(c.global_position + Vector3(0, 0.2, 2.5), 0.0)
	check(street._free_car_near() != c, "a burnt-out car can't be driven")
	p.heal(100.0)

	# --- Wasted ------------------------------------------------------------------------
	var cash0 := street.cash()
	street.set_wanted(1)
	p.hurt(500.0)
	await frames(5)
	check(got_wasted == 1 and street.down and p.dead, "WASTED")
	await frames(60 * 6)
	check(not street.down and not p.dead and p.health == StreetPlayer.MAX_HEALTH, "respawns at the hospital with full health")
	check(street.cash() < cash0, "hospital bill paid ($%d -> $%d)" % [cash0, street.cash()])
	check(street.wanted == 0, "stars cleared")
	check(street.combat.ammo[&"pistol"] > 0, "keeps weapons after Wasted")
	check(p.controls_enabled, "control is back")

	# --- Busted ------------------------------------------------------------------------
	cash0 = street.cash()
	street.combat.give(&"shotgun")
	street.set_wanted(2)
	street.bust()
	await frames(5)
	check(got_busted == 1 and street.down, "BUSTED")
	await frames(60 * 6)
	check(not street.down and street.combat.ammo[&"shotgun"] == 0 and street.combat.ammo[&"pistol"] == 0, "the police keep your guns")
	check(street.cash() < cash0 or cash0 == 0, "bail paid ($%d -> $%d)" % [cash0, street.cash()])
	check(street.wanted == 0 and street.combat.current == &"fists", "free to go, no stars")

	# --- Regeneration with the Medic perk ------------------------------------------------
	p.heal_rate = 1.5
	p.hurt(90.0)
	var low := p.health
	await frames(60 * 8)
	check(p.health > low + 2.0 and p.health <= StreetPlayer.REGEN_TO * 1.5 + 0.01, "a Medic slowly heals back up (%.0f -> %.0f, capped at 60)" % [low, p.health])
	p.heal_rate = 1.0
	p.heal(100.0)

	# --- Police chase ------------------------------------------------------------------
	street.set_wanted(2)
	await frames(60 * 4)
	check(life.police.cop_count() > 0, "cops are dispatched for 2 stars (%d cars)" % life.police.cop_count())
	street.heat.clear()

	# --- Carjacking ----------------------------------------------------------------------
	crimes.clear()
	actions.clear()
	var tc = null
	for k in life.traffic.cars:
		if not k.garbage and k.pos.distance_to(p.global_position) < 150.0:
			tc = k
			break
	check(tc != null, "found a car in traffic")
	if tc:
		var model: String = life.traffic.MODELS[tc.model]
		var count := life.traffic.cars.size()
		var side := Vector3(-tc.fwd.z, 0, tc.fwd.x)
		p.place(tc.pos + side * 2.6 + Vector3.UP * 0.3, 0.0)
		tc.v = 0.0
		check(street._traffic_car_near() == tc, "a stopped car is close enough to carjack")
		street._carjack(tc)
		await frames(5)
		check(not life.traffic.cars.has(tc), "the car leaves traffic")
		check(&"carjack" in crimes and &"steal_car" in actions, "carjacking is a crime (goodness: steal_car)")
		await frames(60 * 4)
		check(street.car != null and street.car.model == model, "player drives off in the same %s" % model)
		check(p.in_vehicle and not street.switching, "seated")
		street._leave_car()
		await frames(90)
		street.heat.clear()

	# --- Parked car theft --------------------------------------------------------------
	crimes.clear()
	var parked: DrivableCar = null
	for v in root.get_tree().get_nodes_in_group("vehicles"):
		if v.get_meta("parked", false) and not v.get_meta("player_owned", false) and not v.wrecked:
			parked = v
			break
	if parked:
		street._enter_car(parked)
		await frames(110)
		check(&"car_theft" in crimes, "taking a parked car is car theft")
	else:
		check(false, "found a parked car")

	print("OK: %d failure(s)" % fails if fails == 0 else "FAILED: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)
