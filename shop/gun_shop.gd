class_name GunShop
extends Node
## Harbor Arms & Supply (catalog "gun_shop"): a door on every one the Mayor places leads
## into a shop room (the pawn shop's, with a gun wall and a sign) where E at the counter
## opens the ShopScreen. Also owns what you buy there that outlives the visit:
##   - med kits carried (H uses one) and a small "Med kits" line on screen;
##   - home items, shown in your home room; the safe halves hospital bills and bail, the
##     weapon locker keeps your guns when Busted, E at the first aid cabinet heals you;
##   - the old harbor map, which sets the flag that starts the X Marks the Spot quest.
## Saved as the "shop" section.
##
## Wiring (scripts/main.gd, after interiors and resident):
##   shop = GunShop.new(); add_child(shop); shop.setup(city, street, interiors)

signal bought(id: String)

const KIND := "gun_shop"
const ROOM := "shop_pawn"
const SPOT_RADIUS := 2.0
const MEDKIT_ACTION := "use_medkit"
const PROP_LAYER := 1 << 19     # Interior.LAYER: rooms draw on their own layer

var city: City
var street: Node                # StreetMode
var interiors: Node             # InteriorManager
var med_kits := 0
var owned: Array[String] = []   # home and quest items bought

var _doors := {}                # building id -> DoorTrigger
var _in_shop := false
var _screen: ShopScreen
var _hint_layer: CanvasLayer
var _hint: Label
var _kits: Label
var _cash_before := -1          # wasted/busted: cash before the bill, for the safe
var _guns_before := {}          # busted: what was carried, for the locker


func setup(c: City, street_mode: Node, interior_manager: Node) -> void:
	city = c
	street = street_mode
	interiors = interior_manager
	var prog := _progress()
	if prog:
		prog.register_section("shop", self)
	if not InputMap.has_action(MEDKIT_ACTION):
		InputMap.add_action(MEDKIT_ACTION)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_H
		InputMap.action_add_event(MEDKIT_ACTION, k)
	_build_hud()
	if street:
		street.player.interact_requested.connect(func() -> void: _on_interact.call_deferred())
		street.wasted.connect(_on_down.bind(false))
		street.busted.connect(_on_down.bind(true))
	if interiors:
		city.building_added.connect(func(id: int, _a: bool) -> void: _sync_door(id))
		city.building_removed.connect(_remove_door)
		for id in city.buildings:
			_sync_door(id)
		interiors.interior_entered.connect(_on_room_entered)
		interiors.interior_exited.connect(func(_id, _b) -> void: _in_shop = false)


func is_open() -> bool:
	return _screen != null and is_instance_valid(_screen)


func cash() -> int:
	var prog := _progress()
	return int(prog.cash) if prog else 0


func has_item(id: String) -> bool:
	return id in owned


func discount() -> bool:
	var prog := _progress()
	return prog != null and prog.get_flag("shop_discount", false) == true


func price_of(id: String) -> int:
	return ShopStock.price(ShopStock.get_item(id), discount())


## Why an item can't be bought right now ("Owned", "Full"...), or "" when it can.
func why_not(id: String) -> String:
	var it := ShopStock.get_item(id)
	if it.is_empty():
		return "Sold out"
	match it.kind:
		"home", "quest":
			if has_item(id):
				return "Owned"
		"medkit":
			if med_kits >= ShopStock.MAX_MEDKITS:
				return "Full"
		"armor":
			if street and street.player.armor >= StreetPlayer.MAX_ARMOR:
				return "Full"
		"weapon", "ammo":
			if street and street.combat:
				var w: Dictionary = StreetCombat.WEAPONS[it.weapon]
				if int(street.combat.ammo[it.weapon]) >= int(w.max_ammo):
					return "Full"
	if cash() < price_of(id):
		return "Can't afford"
	return ""


## Pay for an item and hand it over. Returns what to tell the player and whether it worked.
func try_buy(id: String) -> Array:
	var it := ShopStock.get_item(id)
	var why := why_not(id)
	if why == "Can't afford":
		return ["Not enough cash for the %s." % it.name.to_lower(), false]
	if why != "":
		return ["%s: %s." % [it.name, why.to_lower()], false]
	var prog := _progress()
	var cost := price_of(id)
	if prog and not prog.spend_cash(cost, it.name):
		return ["Not enough cash for the %s." % it.name.to_lower(), false]
	var msg := "Bought: %s." % it.name
	match it.kind:
		"weapon":
			street.combat.give(it.weapon)
		"ammo":
			street.combat.give(it.weapon, int(it.rounds))
		"armor":
			street.player.add_armor(StreetPlayer.MAX_ARMOR)
		"medkit":
			med_kits += 1
			msg = "Bought a med kit (%d carried). Press H to use one." % med_kits
		"home":
			owned.append(id)
			msg = "Bought: %s. It's waiting at home." % it.name
		"count":
			if prog:
				prog.count(str(it.count), int(it.n))
			msg = "Bought %s." % it.name.to_lower()
		"quest":
			owned.append(id)
			if prog:
				prog.set_flag(str(it.flag), true)
			msg = "Bought the %s. Check your quest log (J)." % it.name.to_lower()
	_update_kits()
	bought.emit(id)
	return [msg, true]


## H: patch yourself up with a carried med kit.
func use_medkit() -> bool:
	if med_kits <= 0 or street == null or not street.active or street.down or street.player.dead:
		return false
	if not street.player.heal(ShopStock.MEDKIT_HEAL):
		street.hud.note("Already at full health")
		return false
	med_kits -= 1
	street.hud.note("Med kit used (%d left)" % med_kits)
	_update_kits()
	return true


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed(MEDKIT_ACTION) and street and street.active:
		get_viewport().set_input_as_handled()
		use_medkit()


func _process(_dt: float) -> void:
	if _hint == null:
		return
	var spot := _spot()
	_hint.text = {"counter": "E  Browse Harbor Arms", "heal": "E  First aid cabinet"}.get(spot, "")
	_hint.visible = spot != "" and not is_open()
	_kits.visible = street != null and street.active and med_kits > 0 and not is_open()


# ------------------------------------------------------------------ the shop ---

func open_screen() -> void:
	if is_open():
		return
	_screen = ShopScreen.new()
	_screen.shop = self
	_screen.buy_requested.connect(func(id: String) -> void:
		var r := try_buy(id)
		_screen.show_result(r[0], r[1]))
	var was_paused := get_tree().paused
	var mouse := Input.mouse_mode
	_screen.closed.connect(func() -> void:
		get_tree().paused = was_paused
		Input.mouse_mode = mouse)
	add_child(_screen)
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _sync_door(id: int) -> void:
	_remove_door(id)
	var b: Dictionary = city.buildings.get(id, {})
	if b.get("kind", "") != KIND or not Interior.exists(ROOM):
		return
	var d: Node = interiors.add_door(interiors.door_transform(b), ROOM, String(b.get("name", "Harbor Arms")))
	d.set("building_id", id)
	_doors[id] = d


func _remove_door(id: int) -> void:
	if _doors.has(id):
		if is_instance_valid(_doors[id]):
			_doors[id].queue_free()
		_doors.erase(id)


func _on_room_entered(id: String, _b: Dictionary) -> void:
	_in_shop = false
	if id == ROOM and interiors.get("_door") in _doors.values():
		_in_shop = true
		_dress_shop(interiors.current)
	elif id == "home":
		_dress_home(interiors.current)


func _spot() -> String:
	## What E does where the player stands: "counter" in Harbor Arms, "heal" at home.
	if street == null or interiors == null or interiors.current == null or interiors.busy:
		return ""
	var room: Node = interiors.current
	if _in_shop:
		var m: Node3D = room.marker("counter")
		if m and street.player.global_position.distance_to(m.global_position) < SPOT_RADIUS:
			return "counter"
	elif interiors.current_id == "home" and has_item("med_cabinet"):
		var cab: Node3D = room.get_node_or_null("ShopItem_med_cabinet")
		if cab and street.player.global_position.distance_to(cab.global_position) < SPOT_RADIUS:
			return "heal"
	return ""


func _on_interact() -> void:
	match _spot():
		"counter":
			open_screen()
		"heal":
			if street.player.heal(StreetPlayer.MAX_HEALTH):
				street.hud.note("Patched up: full health")
			else:
				street.hud.note("Already at full health")


# ---------------------------------------------------------- wasted / busted ---

func _on_down(busted: bool) -> void:
	## The safe pays back half the bill; the locker gives the guns back after a bust.
	var safe := has_item("home_safe")
	var locker := busted and has_item("weapon_locker")
	if not safe and not locker:
		return
	_cash_before = cash()
	if locker and street.combat:
		_guns_before = {"ammo": street.combat.ammo.duplicate(), "loaded": street.combat.loaded.duplicate()}
	while street.down:
		await get_tree().process_frame
	if safe:
		var lost := _cash_before - cash()
		var prog := _progress()
		if lost > 0 and prog:
			prog.add_cash(lost / 2, "Home safe")
			street.hud.note("Home safe covered $%d" % (lost / 2))
	if locker and not _guns_before.is_empty():
		for k in _guns_before.ammo:
			street.combat.ammo[k] = _guns_before.ammo[k]
			street.combat.loaded[k] = _guns_before.loaded[k]
		_guns_before = {}
		street.hud.note("Your guns were in the locker at home")


# ------------------------------------------------------------------- props ---

func _dress_shop(room: Node3D) -> void:
	## A gun wall on the long shelf and a sign over the counter.
	if room == null or room.get_node_or_null("GunWall"):
		return
	var wall := Node3D.new()
	wall.name = "GunWall"
	room.add_child(wall)
	var metal := Color(0.13, 0.14, 0.15)
	var wood := Color(0.42, 0.26, 0.14)
	_box(wall, Vector3(0.08, 1.5, 7.0), Vector3(5.05, 1.85, 0.0), Color(0.3, 0.32, 0.3))   # pegboard
	for i in 9:
		var z := -3.2 + i * 0.8
		_box(wall, Vector3(0.06, 1.05, 0.07), Vector3(4.98, 1.85, z), metal)                  # barrel
		_box(wall, Vector3(0.07, 0.38, 0.12), Vector3(4.97, 1.3, z + 0.03), wood if i % 2 == 0 else metal)  # stock
	for i in 6:
		_box(wall, Vector3(0.3, 0.18, 0.4), Vector3(4.85, 0.98, -2.6 + i * 1.0), Color(0.55, 0.45, 0.2))  # ammo boxes
	var sign := Label3D.new()
	sign.text = "HARBOR ARMS & SUPPLY"
	sign.font_size = 64
	sign.pixel_size = 0.004
	sign.modulate = Color(0.98, 0.72, 0.25)
	sign.outline_size = 8
	sign.layers = PROP_LAYER
	sign.position = Vector3(-5.05, 2.5, 0.6)
	sign.rotation.y = PI * 0.5
	wall.add_child(sign)


func _dress_home(room: Node3D) -> void:
	## Whatever the Resident has bought, in its place in the home room.
	if room == null:
		return
	for id in owned:
		if ShopStock.get_item(id).get("kind", "") != "home" or room.get_node_or_null("ShopItem_" + id):
			continue
		var n := Node3D.new()
		n.name = "ShopItem_" + id
		room.add_child(n)
		match id:
			"home_safe":
				n.position = Vector3(-1.3, 0, 3.75)
				_box(n, Vector3(0.7, 0.8, 0.6), Vector3(0, 0.4, 0), Color(0.2, 0.22, 0.24))
				_box(n, Vector3(0.18, 0.18, 0.04), Vector3(0.1, 0.5, -0.32), Color(0.75, 0.7, 0.5))
			"weapon_locker":
				n.position = Vector3(-0.2, 0, 3.8)
				_box(n, Vector3(0.9, 1.9, 0.5), Vector3(0, 0.95, 0), Color(0.27, 0.33, 0.27))
				_box(n, Vector3(0.02, 1.7, 0.02), Vector3(0, 0.95, -0.26), Color(0.12, 0.12, 0.12))
			"med_cabinet":
				n.position = Vector3(0.95, 0, 3.95)
				_box(n, Vector3(0.6, 0.6, 0.18), Vector3(0, 1.35, 0), Color(0.92, 0.92, 0.9))
				_box(n, Vector3(0.36, 0.1, 0.02), Vector3(0, 1.35, -0.1), Color(0.85, 0.12, 0.1))
				_box(n, Vector3(0.1, 0.36, 0.02), Vector3(0, 1.35, -0.1), Color(0.85, 0.12, 0.1))
			"big_tv":
				n.position = Vector3(-1.6, 0, -3.55)
				_box(n, Vector3(1.75, 1.0, 0.07), Vector3(0, 1.15, 0), Color(0.05, 0.05, 0.06))
				_box(n, Vector3(1.62, 0.88, 0.02), Vector3(0, 1.15, 0.04), Color(0.2, 0.45, 0.85), 1.2)
			"arcade":
				n.position = Vector3(-4.55, 0, 1.6)
				n.rotation.y = -PI * 0.5
				_box(n, Vector3(0.75, 1.8, 0.7), Vector3(0, 0.9, 0), Color(0.12, 0.1, 0.35))
				_box(n, Vector3(0.6, 0.45, 0.02), Vector3(0, 1.35, -0.36), Color(0.3, 0.9, 0.6), 1.5)
				_box(n, Vector3(0.7, 0.12, 0.3), Vector3(0, 1.0, -0.4), Color(0.85, 0.2, 0.2))
			"fish_tank":
				n.position = Vector3(-4.75, 0, -0.5)
				_box(n, Vector3(0.5, 0.7, 1.4), Vector3(0, 0.35, 0), Color(0.25, 0.18, 0.12))
				_box(n, Vector3(0.45, 0.55, 1.3), Vector3(0, 0.98, 0), Color(0.25, 0.65, 0.85), 0.8, 0.55)
			"floor_lamp":
				n.position = Vector3(0.15, 0, 1.95)
				_box(n, Vector3(0.05, 1.5, 0.05), Vector3(0, 0.75, 0), Color(0.15, 0.15, 0.15))
				_box(n, Vector3(0.38, 0.3, 0.38), Vector3(0, 1.6, 0), Color(1.0, 0.85, 0.55), 1.0)
				var l := OmniLight3D.new()
				l.light_color = Color(1.0, 0.8, 0.55)
				l.omni_range = 4.0
				l.light_energy = 0.7
				l.layers = PROP_LAYER
				l.light_cull_mask = PROP_LAYER | 1
				l.position = Vector3(0, 1.6, 0)
				n.add_child(l)
			"palm":
				n.position = Vector3(4.45, 0, -0.3)
				_box(n, Vector3(0.45, 0.45, 0.45), Vector3(0, 0.22, 0), Color(0.55, 0.3, 0.2))
				_box(n, Vector3(0.08, 1.2, 0.08), Vector3(0, 1.0, 0), Color(0.4, 0.3, 0.18))
				for a in 5:
					var leaf := _box(n, Vector3(0.9, 0.04, 0.22), Vector3(0, 1.6, 0), Color(0.2, 0.55, 0.2))
					leaf.rotation = Vector3(0, a * TAU / 5.0, -0.35)
					leaf.position += Vector3(cos(a * TAU / 5.0), 0, -sin(a * TAU / 5.0)) * 0.35
			"trophy":
				n.position = Vector3(-3.35, 0, -3.5)
				_box(n, Vector3(0.5, 1.0, 0.5), Vector3(0, 0.5, 0), Color(0.3, 0.22, 0.15))
				_box(n, Vector3(0.12, 0.25, 0.12), Vector3(0, 1.13, 0), Color(0.95, 0.75, 0.2), 0.3)
				_box(n, Vector3(0.32, 0.3, 0.32), Vector3(0, 1.4, 0), Color(0.95, 0.75, 0.2), 0.3)


func _box(parent: Node3D, size: Vector3, pos: Vector3, col: Color, glow := 0.0, alpha := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	mat.roughness = 0.6
	if glow > 0.0:
		mat.emission_enabled = true
		mat.emission = col
		mat.emission_energy_multiplier = glow
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.layers = PROP_LAYER
	mi.position = pos
	parent.add_child(mi)
	return mi


# --------------------------------------------------------------------- hud ---

func _build_hud() -> void:
	_hint_layer = CanvasLayer.new()
	_hint_layer.layer = 40
	add_child(_hint_layer)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_hint.add_theme_constant_override("outline_size", 6)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-120, -170)
	_hint.visible = false
	_hint_layer.add_child(_hint)
	_kits = Label.new()
	_kits.add_theme_font_size_override("font_size", 18)
	_kits.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	_kits.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_kits.add_theme_constant_override("outline_size", 5)
	_kits.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_kits.position = Vector2(-200, 172)
	_kits.visible = false
	_hint_layer.add_child(_kits)
	_update_kits()


func _update_kits() -> void:
	if _kits:
		_kits.text = "Med kits: %d  (H)" % med_kits


# -------------------------------------------------------------------- save ---

func to_dict() -> Dictionary:
	return {"med_kits": med_kits, "owned": owned.duplicate()}


func from_dict(d: Dictionary) -> void:
	med_kits = clampi(int(d.get("med_kits", 0)), 0, ShopStock.MAX_MEDKITS)
	owned.clear()
	for id in d.get("owned", []):
		if not ShopStock.get_item(str(id)).is_empty():
			owned.append(str(id))
	_update_kits()


func _progress() -> Node:
	return get_node_or_null("/root/Progress")
