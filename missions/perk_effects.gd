class_name PerkEffects
extends Node3D
## What each goodness perk actually does (round-3 plan section 4). Goodness decides which
## perks are held (goodness.gd); this node makes them matter on the street:
##   black_market (-25)       P opens the black market phone: weapons, armor, lock picks,
##                            delivered at your feet
##   crew_backup (-75)        G during a bad job calls a getaway car with a driver
##   emergency_vehicles (+75) the city pays a daily stipend (driving them without stars
##                            is player/'s check on perk:emergency_vehicles)
##   hero (+100)              a statue of your character in Central Park, a plaza or a park
##   kingpin (-100)           the Mansion on the Hill unlocks early; once built it is your
##                            hideout, with a save spot at the door and a car in the drive
## Lock picks are a Progress count, "lock_picks"; player/ spends one to take a parked car
## quietly.

const SHOP := [
	# key, label, price, pickup kind or item
	[KEY_1, "Pistol", 300, &"pistol"],
	[KEY_2, "Shotgun", 700, &"shotgun"],
	[KEY_3, "Body armor", 400, &"armor"],
	[KEY_4, "Lock picks (3)", 250, &"lock_picks"],
]
const STIPEND := 250
const CREW_COOLDOWN := 90.0

var missions: Node  # Missions
var phone_open := false
var _crew_t := 0.0
var _crew_called := false     # once per job
var _statue: Node3D = null
var _mansion_day := -1        # last game day the mansion handed out a car
var _mansion_saved := false   # saved on this visit already


func setup(m: Node) -> void:
	missions = m
	m.city.day_passed.connect(_on_day)
	m.director.started.connect(func(_j): _crew_called = false)
	m.goodness.perk_gained.connect(_on_perk_gained)
	_on_perk_gained.call_deferred(&"", "")  # a loaded game may already hold perks


func has(perk: StringName) -> bool:
	return missions.goodness.has_perk(perk)


# --------------------------------------------------------------- daily, perks ---

func _on_day() -> void:
	if has(&"emergency_vehicles"):
		missions.progress.add_cash(STIPEND, "city stipend")
		missions.hud.news("City stipend: $%d" % STIPEND, 3.0)


func _on_perk_gained(_perk: StringName, _text: String) -> void:
	if has(&"kingpin"):
		missions.progress.unlock("mansion", "goodness:kingpin")
	if has(&"hero"):
		_place_statue()


# --------------------------------------------------------------- per frame ---

func tick(delta: float) -> void:
	_crew_t = maxf(0.0, _crew_t - delta)
	if has(&"hero") and _statue == null:
		_place_statue()  # waits for a park to exist
	if _statue and not has(&"hero"):
		_statue.queue_free()
		_statue = null
	_tick_mansion()


func handle_key(k: int) -> bool:
	## Street-level keys; true when used.
	var link: StreetLink = missions.link
	if phone_open:
		if k == KEY_P:
			phone_open = false
			return true
		for item in SHOP:
			if k == item[0]:
				_buy(item)
				return true
		return false
	if k == KEY_P and has(&"black_market"):
		phone_open = true
		missions._play_ui("phone_ring", "ui_select")
		return true
	if k == KEY_G and has(&"crew_backup"):
		var d: MissionDirector = missions.director
		if d.active == null or d.active.side != "bad":
			missions.hud.news("The crew only rolls out for a job", 2.5)
		elif _crew_called:
			missions.hud.news("The crew already came once this job", 2.5)
		elif link.car() != null:
			missions.hud.news("You already have wheels", 2.0)
		else:
			_call_crew()
		return true
	return false


func phone_text() -> String:
	## The black market phone, drawn by the HUD's offer box.
	if not phone_open:
		return ""
	var lines := ["BLACK MARKET   (P hangs up)"]
	for item in SHOP:
		lines.append("%s  %s   $%d" % [OS.get_keycode_string(item[0]), item[1], item[2]])
	lines.append("Cash $%d    Lock picks: %d" % [missions.progress.cash(), missions.progress.get_count("lock_picks")])
	return "\n".join(lines)


func _buy(item: Array) -> void:
	var p: ProgressLink = missions.progress
	var price: int = item[2]
	if p.cash() < price:
		missions.hud.news("Not enough cash for %s" % item[1], 2.5)
		return
	p.add_cash(-price, "black market")
	if item[3] == &"lock_picks":
		p.count("lock_picks", 3)
		missions.hud.news("Three lock picks: parked cars open quietly", 3.0)
	else:
		var st: Node = missions.street
		var at: Vector3 = missions.link.position()
		if st and st.has_method("spawn_pickup"):
			st.spawn_pickup(item[3], at + Vector3(1.2, 0.3, 0.0), 0.0)
		missions.hud.news("%s dropped at your feet" % item[1], 2.5)
	missions._play_ui("cash", "ui_select")


func _call_crew() -> void:
	## A getaway car pulls up at the nearest kerb a little way off, engine running.
	var c: City = missions.city
	var router: RoadRouter = missions.director.router
	var me: Vector3 = missions.link.position()
	var cell := router.nearest_road(c.flat_to_cell(me))
	if cell.x < 0:
		missions.hud.news("No road for the crew to reach you", 2.5)
		return
	var center := c.cell_center(cell.x, cell.y)
	var along_x := (c.road_mask(cell.x, cell.y) & 10) != 0
	var pos := center + (Vector3(0, 0.15, 2.75) if along_x else Vector3(2.75, 0.15, 0))
	var car: Object = missions.link.spawn_car("car_sedan", pos, PI * 0.5 if along_x else 0.0, Color(0.08, 0.08, 0.09))
	if car is Node:
		car.set_meta("player_owned", true)
	_crew_called = true
	missions.hud.news("Crew's here. Black sedan at the kerb, keys in it", 3.5)
	missions._play_at("horn_distant", pos, "notify")


# ------------------------------------------------------------------ statue ---

func _place_statue() -> void:
	if _statue or not CharacterModel.available():
		return
	var spot := _park_spot()
	if spot == Vector3.INF:
		return
	var root := Node3D.new()
	root.name = "HeroStatue"
	root.position = spot
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.62, 0.6, 0.56)
	stone.roughness = 0.9
	var base := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.8, 1.4, 1.8)
	base.mesh = bm
	base.position.y = 0.7
	base.material_override = stone
	root.add_child(base)
	var plaque := Label3D.new()
	plaque.text = "%s\nHero of the City" % _resident_name()
	plaque.font_size = 28
	plaque.pixel_size = 0.006
	plaque.position = Vector3(0, 0.8, 0.92)
	plaque.modulate = Color(0.95, 0.85, 0.5)
	root.add_child(plaque)
	var figure := CharacterModel.new()
	figure.position.y = 1.4
	figure.scale = Vector3.ONE * 1.35
	root.add_child(figure)
	add_child(root)
	_statue = root
	_bronze.call_deferred(figure)
	missions.hud.news("The city put up a statue of you", 5.0)


func _bronze(figure: CharacterModel) -> void:
	## Your look, cast in bronze, frozen mid-stride.
	var res: Object = missions.progress.store.get_section("resident") if missions.progress.store else null
	var look = res.get("look") if res else null
	if look and look.has_method("apply"):
		look.apply(figure)
	var bronze := StandardMaterial3D.new()
	bronze.albedo_color = Color(0.55, 0.38, 0.2)
	bronze.metallic = 0.85
	bronze.roughness = 0.35
	for mi in figure.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).material_override = bronze
	if figure.tree:
		figure.tree.active = false
	if figure.anim and figure.anim.has_animation("Walk"):
		figure.anim.play("Walk")
		figure.anim.seek(0.35, true)
		figure.anim.pause()


func _resident_name() -> String:
	var res: Object = missions.progress.store.get_section("resident") if missions.progress.store else null
	return String(res.get("name")) if res and res.get("name") else "Our Hero"


func _park_spot() -> Vector3:
	## Central Park first, then a plaza, then any park.
	var c: City = missions.city
	for want in ["city_park", "plaza", ""]:
		for b in missions.progress.find_tagged("park"):
			if want == "" or b.get("kind", "") == want:
				return c.building_center(b)
	return Vector3.INF


# ------------------------------------------------------------------ mansion ---

func mansion() -> Dictionary:
	for b in missions.progress.find_tagged("mansion"):
		return b
	return {}


func _tick_mansion() -> void:
	if not has(&"kingpin"):
		return
	var b := mansion()
	if b.is_empty() or not missions.link.active():
		return
	var link: StreetLink = missions.link
	var door: Vector3 = missions.city.building_center(b)
	if link.interiors:
		door = link.interiors.door_transform(b).origin
	var near := MissionDirector.flat_dist(link.position(), door) < 7.0
	if not near:
		_mansion_saved = false
		return
	if _mansion_saved or link.wanted() > 0 or link.car() != null:
		return
	_mansion_saved = true
	var day: int = missions.city.game_day()
	if day != _mansion_day:
		_mansion_day = day
		var cell: Vector2i = missions.director.router.access_cell(b)
		if cell.x >= 0:
			var c: City = missions.city
			var p := c.cell_center(cell.x, cell.y) + Vector3(2.75, 0.15, 0)
			var car: Object = link.spawn_car("car_sedan", p, 0.0, Color(0.55, 0.1, 0.15))
			if car is Node:
				car.set_meta("player_owned", true)
	var saved: bool = missions.progress.store.autosave() if missions.progress.store else false
	missions.hud.news("The Mansion: game saved, your car is in the drive" if saved else "The Mansion: your car is in the drive", 3.5)


func to_dict() -> Dictionary:
	return {"mansion_day": _mansion_day}


func from_dict(d: Dictionary) -> void:
	_mansion_day = int(d.get("mansion_day", -1))
