class_name Resident
extends Node
## Glue for the Resident: runs the creator on a new game, then the home picker; keeps the
## street character dressed; registers the profile as the "resident" save section; and
## turns the home's front door into a stop where E opens the wardrobe and saves the game.
##
##   resident = Resident.new()
##   add_child(resident)
##   resident.setup(city, street, cam)       # after StreetMode exists, before a load's sections
##   resident.use_interiors(interiors)       # optional: the real home room (interiors/)
##   if not resident.profile.loaded:
##       await resident.new_game()           # creator, start cash, home picker
##
## Without interiors/, E at the glowing front door opens a small home menu instead.

signal home_entered        # walked in the front door (autosave already done)

const DOOR_RADIUS := 2.6
const SPOT_RADIUS := 1.7    # how close to the wardrobe or save spot in the home room

var profile := ResidentProfile.new()
var home: ResidentHome
var city: City
var street: Node            # StreetMode (player/)
var map_camera: Camera3D    # the mayor camera, for the home picker

var _door_marker: MeshInstance3D
var _hint_layer: CanvasLayer
var _hint: Label
var _menu: Control
var _ui: Control
var _busy := false
var interiors: Node = null  # InteriorManager (interiors/), when wired
var _home_door: Node = null


func setup(c: City, street_mode: Node, mayor_cam: Camera3D) -> void:
	city = c
	street = street_mode
	map_camera = mayor_cam
	var prog := progress()
	if prog:
		prog.register_section("resident", profile)   # a load calls profile.from_dict right here
	home = ResidentHome.new()
	home.name = "Home"
	add_child(home)
	home.setup(city, profile)
	home.home_changed.connect(func(_c): _place_door_marker())
	home.home_changed.connect(func(_c): _sync_home_door())
	home.home_lost.connect(_on_home_lost)
	if street:
		street.player.interact_requested.connect(_on_interact)
		street.street_entered.connect(dress)
		var vis: Node = street.player.visual
		if vis and vis.has_signal("dressed"):
			vis.dressed.connect(dress)   # player/ re-dresses the crowd look; put ours back
	_build_hint()
	_place_door_marker()
	dress()


## Use the real home room from interiors/: a door on the home building, and in the room the
## wardrobe (M_wardrobe) and save spot (M_save) answer to E.
func use_interiors(im: Node) -> void:
	interiors = im
	im.interior_entered.connect(_on_interior_entered)
	_sync_home_door()
	_place_door_marker()


func _sync_home_door() -> void:
	if interiors == null:
		return
	if _home_door and is_instance_valid(_home_door):
		_home_door.queue_free()
	_home_door = null
	var b := home.building()
	if b.is_empty():
		return
	var d: Vector2i = City.DIRS[b.rot]
	var out := Vector3(d.x, 0, d.y)
	# The door's +Z points out to the street.
	_home_door = interiors.add_door(Transform3D(Basis.looking_at(-out), ResidentHome.door_of(city, b)),
		"home", "Home")


func _on_interior_entered(id: String, _b: Dictionary) -> void:
	if id != "home":
		return
	var prog := progress()
	if prog:
		prog.autosave()
	home_entered.emit()


func _home_spot() -> String:
	## "wardrobe" or "save" when standing at that spot in the home room, else "".
	if interiors == null or street == null or interiors.get("current_id") != "home" or interiors.current == null:
		return ""
	for spot in ["wardrobe", "save"]:
		var m: Node3D = interiors.current.marker(spot)
		if m and street.player.global_position.distance_to(m.global_position) < SPOT_RADIUS:
			return spot
	return ""


func progress() -> Node:
	return get_node_or_null("/root/Progress")


## New game: the creator, starting cash, then choosing a home on the map.
func new_game() -> void:
	_busy = true
	var cc := CharacterCreator.new()
	add_child(cc)
	var p: ResidentProfile = await cc.finished
	if p:
		profile.from_dict(p.to_dict())
		profile.loaded = false
	dress()
	var prog := progress()
	if prog:
		prog.add_cash(ResidentProfile.START_CASH, "start")
	await pick_home()
	_busy = false


## Lets the player pick a home on the map. Returns true when they moved in somewhere.
func pick_home() -> bool:
	if map_camera == null:
		return false
	var hp := HomePicker.new()
	add_child(hp)
	hp.start(city, map_camera, profile.home)
	var cell: Vector2i = await hp.finished
	if cell.x >= 0:
		home.move_in(cell)
		_toast("Moved in: " + home.label())
		return true
	return false


func open_wardrobe() -> void:
	var cc := CharacterCreator.new()
	cc.mode = CharacterCreator.Mode.WARDROBE
	cc.profile = profile
	add_child(cc)
	var p: ResidentProfile = await cc.finished
	if p:
		profile.look = p.look
		profile.outfits = p.outfits
		dress()


## The clothing shop screen: try on shop colors, pay from Progress.cash for what you wear
## out. Returns the dollars spent (0 when you leave or buy nothing).
func open_shop() -> int:
	if _busy:
		return 0
	_busy = true
	var was_paused := get_tree().paused
	get_tree().paused = true
	var prog := progress()
	var cc := CharacterCreator.new()
	cc.mode = CharacterCreator.Mode.SHOP
	cc.profile = profile
	cc.cash = int(prog.cash) if prog else -1
	add_child(cc)
	var p: ResidentProfile = await cc.finished
	var spent := 0
	if p:
		var bill := ClothingStock.unpaid(p.look, profile.owned)
		if bill.total == 0 or prog == null or prog.spend_cash(bill.total, "clothes"):
			spent = bill.total
			for id in bill.ids:
				profile.owned.append(id)
			profile.look = p.look
			dress()
			if spent > 0:
				_flash("Bought for $%d." % spent)
		else:
			_flash("Not enough cash.")
	get_tree().paused = was_paused
	_busy = false
	return spent


## Dress the street character in the profile's look.
func dress() -> void:
	if street and street.player and street.player.visual and street.player.visual.model:
		profile.look.apply(street.player.visual)


## Where to put the player after Wasted, or on loading into the street: outside home.
## Transform3D with an INF origin when there is no home.
func respawn_point() -> Transform3D:
	return home.spawn_transform()


# ----------------------------------------------------------------- the door ---

func _place_door_marker() -> void:
	if _door_marker == null:
		_door_marker = MeshInstance3D.new()
		var m := CylinderMesh.new()
		m.top_radius = 0.55
		m.bottom_radius = 0.55
		m.height = 3.0
		m.cap_top = false
		m.cap_bottom = false
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_color = Color(1.0, 0.8, 0.3, 0.28)
		m.material = mat
		_door_marker.mesh = m
		_door_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_door_marker)
	var sp := home.spawn_transform()
	_door_marker.visible = sp.origin.is_finite() and interiors == null
	if _door_marker.visible:
		_door_marker.global_position = sp.origin + Vector3(0, 1.5, 0)


func _near_door() -> bool:
	if interiors != null or street == null or not street.active or street.car != null:
		return false
	var sp := home.spawn_transform()
	return sp.origin.is_finite() and street.player.global_position.distance_to(sp.origin) < DOOR_RADIUS


func _process(_delta: float) -> void:
	if _hint:
		var spot := _home_spot()
		_hint.text = {"wardrobe": "E  Wardrobe", "save": "E  Save game"}.get(spot, "E  Go inside (wardrobe, save)")
		_hint.visible = _menu == null and not _busy and (spot != "" or _near_door())


func _on_interact() -> void:
	# StreetMode gets the same press and may be getting into a car; look after it has.
	_maybe_enter.call_deferred()


func _maybe_enter() -> void:
	match _home_spot():
		"wardrobe":
			if not _busy and _menu == null:
				_busy = true
				var was_paused := get_tree().paused
				get_tree().paused = true
				await open_wardrobe()
				get_tree().paused = was_paused
				_busy = false
			return
		"save":
			var prog := progress()
			var ok: bool = prog.save_game() if prog else false
			_flash("Game saved." if ok else "Couldn't save the game.")
			return
	if _menu or _busy or street.switching or not _near_door():
		return
	enter_home()


func enter_home() -> void:
	var prog := progress()
	if prog:
		prog.autosave()
	home_entered.emit()
	_open_menu()


func _open_menu() -> void:
	var was_paused := get_tree().paused
	get_tree().paused = true
	_menu = PanelContainer.new()
	_menu.process_mode = Node.PROCESS_MODE_ALWAYS
	_menu.set_anchors_preset(Control.PRESET_CENTER)
	_menu.position = Vector2(-230, -150)
	_menu.custom_minimum_size = Vector2(460, 0)
	_ui.add_child(_menu)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_menu.add_child(v)
	var t := Label.new()
	t.text = "HOME"
	t.add_theme_font_size_override("font_size", 30)
	t.add_theme_color_override("font_color", CharacterCreator.GOLD)
	v.add_child(t)
	var a := Label.new()
	a.text = home.label() + "\nGame saved."
	a.add_theme_color_override("font_color", CharacterCreator.SUB)
	v.add_child(a)
	var close := func():
		if _menu:
			_menu.queue_free()
			_menu = null
		get_tree().paused = was_paused
	for row in [["Wardrobe", func():
				_menu.visible = false
				await open_wardrobe()
				close.call()],
			["Move to another home", func():
				close.call()
				if street.active:
					_toast("Switch to the map view (Tab), then pick a new home.")
					await street.street_exited
				await pick_home()],
			["Leave", close]]:
		var b := Button.new()
		b.text = row[0]
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(row[1])
		v.add_child(b)
	Hud.no_keyboard_focus(_menu)


func _build_hint() -> void:
	_hint_layer = CanvasLayer.new()
	_hint_layer.layer = 6
	_hint_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_hint_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = Hud.make_theme()
	_hint_layer.add_child(root)
	_ui = root
	_hint = Label.new()
	_hint.text = "E  Go inside (wardrobe, save)"
	_hint.add_theme_stylebox_override("normal", Hud.panel_style(Color(0.08, 0.1, 0.14, 0.85), 8))
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.position = Vector2(-150, -150)
	_hint.custom_minimum_size = Vector2(300, 0)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.visible = false
	root.add_child(_hint)


func _flash(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_stylebox_override("normal", Hud.panel_style(Color(0.15, 0.4, 0.25, 0.92), 8))
	l.set_anchors_preset(Control.PRESET_CENTER_TOP)
	l.position = Vector2(-110, 120)
	l.custom_minimum_size = Vector2(220, 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui.add_child(l)
	get_tree().create_timer(2.0, true).timeout.connect(l.queue_free)


func _toast(text: String) -> void:
	if city:
		city.message.emit(text)


func _on_home_lost() -> void:
	_place_door_marker()
	_sync_home_door()
	_toast("Your home was torn down. You'll move into the next home that goes up.")
