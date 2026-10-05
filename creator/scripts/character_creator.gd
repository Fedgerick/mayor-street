class_name CharacterCreator
extends CanvasLayer
## The new-game character creator, and the same screen as the wardrobe at home.
##   var cc := CharacterCreator.new()          # mode CREATE: name, background, look, clothes
##   cc.mode = CharacterCreator.Mode.WARDROBE  # look, clothes and saved outfits only
##   cc.mode = CharacterCreator.Mode.SHOP      # clothing shop: try on and buy (cc.cash = wallet)
##   cc.profile = existing_profile             # optional; edited on a copy
##   add_child(cc)
##   var p: ResidentProfile = await cc.finished   # null when cancelled
## The preview is a live CharacterModel (player/) in its own little world, dressed with
## CharacterLook.apply, so what you see is exactly what walks the streets.

signal finished(profile: ResidentProfile)

enum Mode { CREATE, WARDROBE, SHOP }

const GOLD := Color(1.0, 0.85, 0.45)
const SUB := Color(0.62, 0.68, 0.78)

var mode := Mode.CREATE
var cash := -1          # SHOP: what the Resident can spend; -1 = no limit
var profile: ResidentProfile

var _rng := RandomNumberGenerator.new()
var _root: Control
var _tabs: HBoxContainer
var _page: VBoxContainer
var _page_name := ""
var _done: Button
var _viewport: SubViewport
var _pivot: Node3D
var _cam: Camera3D
var _model: Node3D
var _yaw := 0.0
var _spin := 0.0
var _dragging := false
var _cam_close := 0.0   # 0 full body, 1 face
var _cam_t := 0.0


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	if profile == null:
		profile = ResidentProfile.new()
		profile.name = ResidentProfile.NAMES[_rng.randi() % ResidentProfile.NAMES.size()]
		profile.look = CharacterLook.random(_rng)
		profile.background = ResidentProfile.BACKGROUND_ORDER[_rng.randi() % 4]
	else:
		profile = ResidentProfile.parse(profile.to_dict())
	_build()
	_show_page({Mode.CREATE: "You", Mode.WARDROBE: "Look", Mode.SHOP: "Shop"}[mode])
	_refresh_model()


# ----------------------------------------------------------------- layout ---

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = Hud.make_theme()
	add_child(_root)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.06, 0.09)
	_root.add_child(bg)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 0)
	_root.add_child(row)

	# Left: the options.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 0)
	var ps := Hud.panel_style(Color(0.08, 0.1, 0.14, 0.97), 0)
	ps.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", ps)
	row.add_child(panel)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 12)
	panel.add_child(left)
	var title := Label.new()
	title.text = {Mode.CREATE: "WHO ARE YOU?", Mode.WARDROBE: "WARDROBE", Mode.SHOP: "CLOTHING SHOP"}[mode]
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", GOLD)
	left.add_child(title)
	var sub := Label.new()
	sub.text = {Mode.CREATE: "The Mayor builds the city. You live in it.",
		Mode.WARDROBE: "Change your look, or save outfits to switch between.",
		Mode.SHOP: "Try anything on. You only pay for what you walk out wearing."}[mode]
	sub.add_theme_color_override("font_color", SUB)
	left.add_child(sub)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	left.add_child(_tabs)
	var names: Array = {Mode.CREATE: ["You", "Look", "Clothes"], Mode.WARDROBE: ["Look", "Clothes", "Outfits"],
		Mode.SHOP: ["Shop"]}[mode]
	for n in names:
		var b := Button.new()
		b.text = n
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(120, 40)
		b.pressed.connect(_show_page.bind(n))
		_tabs.add_child(b)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 10)
	scroll.add_child(_page)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	left.add_child(bottom)
	var rnd := Button.new()
	rnd.text = "Randomize"
	rnd.custom_minimum_size = Vector2(0, 48)
	rnd.pressed.connect(_randomize)
	if mode != Mode.SHOP:
		bottom.add_child(rnd)
	if mode != Mode.CREATE:
		var cancel := Button.new()
		cancel.text = "Cancel" if mode == Mode.WARDROBE else "Leave"
		cancel.custom_minimum_size = Vector2(0, 48)
		cancel.pressed.connect(func(): _close(null))
		bottom.add_child(cancel)
	_done = Button.new()
	_done.text = "Next: choose a home" if mode == Mode.CREATE else "Wear this"
	_done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_done.custom_minimum_size = Vector2(0, 48)
	_done.add_theme_stylebox_override("normal", Hud.panel_style(Color(0.2, 0.5, 0.3, 0.95), 10))
	_done.add_theme_stylebox_override("hover", Hud.panel_style(Color(0.26, 0.6, 0.36, 1.0), 10))
	_done.pressed.connect(func(): _close(profile))
	bottom.add_child(_done)
	_update_done()

	# Right: the live preview.
	var box := SubViewportContainer.new()
	box.stretch = true
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.gui_input.connect(_preview_input)
	row.add_child(box)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	box.add_child(_viewport)
	_build_stage()
	var hint := Label.new()
	hint.text = "Drag to turn · scroll to zoom"
	hint.add_theme_color_override("font_color", Color(0.75, 0.8, 0.9, 0.7))
	hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.position = Vector2(-260, -40)
	_root.add_child(hint)
	Hud.no_keyboard_focus(_root)


func _build_stage() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.13, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.6, 0.72)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.4
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-38), deg_to_rad(-30), 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	_viewport.add_child(sun)
	var rim := DirectionalLight3D.new()
	rim.rotation = Vector3(deg_to_rad(-15), deg_to_rad(160), 0)
	rim.light_color = Color(0.6, 0.75, 1.0)
	rim.light_energy = 0.9
	_viewport.add_child(rim)
	var floor_mi := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.1
	disc.bottom_radius = 1.15
	disc.height = 0.06
	floor_mi.mesh = disc
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.13, 0.15, 0.2)
	fm.roughness = 0.6
	floor_mi.material_override = fm
	floor_mi.position.y = -0.03
	_viewport.add_child(floor_mi)
	_pivot = Node3D.new()
	_viewport.add_child(_pivot)
	_cam = Camera3D.new()
	_cam.fov = 32.0
	_viewport.add_child(_cam)
	_place_camera()


func _refresh_model() -> void:
	if _model == null:
		if not ResourceLoader.exists("res://player/assets/character.glb"):
			return
		_model = (load("res://player/scripts/character_model.gd") as GDScript).new()
		_model.set("auto_idle", false)   # no folded arms or looking around in the preview
		_pivot.add_child(_model)
	profile.look.apply(_model)


func _process(delta: float) -> void:
	if _model:
		_model.call("animate", delta, 0.0, true, 0.0, 0.0)
	if not _dragging:
		_spin = lerpf(_spin, 0.0, 1.0 - exp(-3.0 * delta))
		_yaw += _spin * delta
	# The model faces -Z (the game's forward); the camera sits on +Z, so turn it around.
	_pivot.rotation.y = PI + _yaw
	_cam_t = lerpf(_cam_t, _cam_close, 1.0 - exp(-6.0 * delta))
	_place_camera()


func _place_camera() -> void:
	var h := profile.look.height if profile else 1.0
	var far_pos := Vector3(0, 1.05 * h, 4.4)
	var far_at := Vector3(0, 0.92 * h, 0)
	var near_pos := Vector3(0, 1.5 * h, 2.4)
	var near_at := Vector3(0, 1.36 * h, 0)
	_cam.position = far_pos.lerp(near_pos, _cam_t)
	_cam.look_at(far_at.lerp(near_at, _cam_t))


func _preview_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			_dragging = e.pressed
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_close = clampf(_cam_close + 0.15, 0.0, 1.0)
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_close = clampf(_cam_close - 0.15, 0.0, 1.0)
	elif e is InputEventMouseMotion and _dragging:
		_yaw += e.relative.x * 0.01
		_spin = e.relative.x * 0.6


func _unhandled_input(e: InputEvent) -> void:
	# Keep the game underneath from reacting while the creator is up.
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE and mode != Mode.CREATE:
		_close(null)
	get_viewport().set_input_as_handled()


func _close(p: ResidentProfile) -> void:
	if p:
		p.name = ResidentProfile.clean_name(p.name)
	finished.emit(p)
	queue_free()


func _randomize() -> void:
	var keep_bg := profile.background
	profile.look = CharacterLook.random(_rng)
	if mode == Mode.CREATE and _page_name == "You":
		profile.name = ResidentProfile.NAMES[_rng.randi() % ResidentProfile.NAMES.size()]
		profile.background = ResidentProfile.BACKGROUND_ORDER[_rng.randi() % 4]
	else:
		profile.background = keep_bg
	_refresh_model()
	_show_page(_page_name)


# ------------------------------------------------------------------ pages ---

func _show_page(n: String) -> void:
	_page_name = n
	if n == "Look" and _cam_close == 0.0:
		_cam_close = 1.0
	elif n != "Look":
		_cam_close = 0.0
	for b in _tabs.get_children():
		(b as Button).button_pressed = (b as Button).text == n
	for c in _page.get_children():
		_page.remove_child(c)
		c.queue_free()
	match n:
		"You": _page_you()
		"Look": _page_look()
		"Clothes": _page_clothes()
		"Outfits": _page_outfits()
		"Shop": _page_shop()
	_update_done()
	Hud.no_keyboard_focus(_page)
	for le in _page.find_children("*", "LineEdit", true, false):
		(le as LineEdit).focus_mode = Control.FOCUS_ALL


func _heading(t: String) -> void:
	var l := Label.new()
	l.text = t.to_upper()
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", SUB)
	_page.add_child(l)


func _changed() -> void:
	_refresh_model()
	_show_page(_page_name)


func _page_you() -> void:
	_heading("Name")
	var h := HBoxContainer.new()
	_page.add_child(h)
	var le := LineEdit.new()
	le.text = profile.name
	le.max_length = 24
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 42)
	le.text_changed.connect(func(t): profile.name = t)
	h.add_child(le)
	var dice := Button.new()
	dice.text = "Random name"
	dice.pressed.connect(func():
		profile.name = ResidentProfile.NAMES[_rng.randi() % ResidentProfile.NAMES.size()]
		le.text = profile.name)
	h.add_child(dice)
	_heading("Background")
	for id in ResidentProfile.BACKGROUND_ORDER:
		var bgd: Dictionary = ResidentProfile.BACKGROUNDS[id]
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = profile.background == id
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.text = "%s\n%s\nPerk: %s" % [bgd.label, bgd.blurb, bgd.perk]
		b.custom_minimum_size = Vector2(0, 92)
		b.pressed.connect(func():
			profile.background = id
			_show_page("You"))
		_page.add_child(b)


func _choices(keys: Array, labels: Callable, selected: String, cols: int, on_pick: Callable) -> void:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	_page.add_child(g)
	for k in keys:
		var b := Button.new()
		b.text = labels.call(k)
		b.toggle_mode = true
		b.button_pressed = k == selected
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 40)
		b.pressed.connect(func():
			on_pick.call(k)
			_changed())
		g.add_child(b)


func _swatches(colors: Array, selected: int, on_pick: Callable, locked := -1) -> void:
	var g := GridContainer.new()
	g.columns = 10
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	_page.add_child(g)
	for i in colors.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(42, 42)
		var is_locked: bool = locked >= 0 and not CharacterLook.cloth_owned(i, profile.owned)
		var for_sale := is_locked and mode == Mode.SHOP
		var st := Hud.panel_style(colors[i] if not is_locked or for_sale else colors[i].darkened(0.6), 8)
		if i == selected:
			st.set_border_width_all(3)
			st.border_color = Color.WHITE
		for s in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			b.add_theme_stylebox_override(s, st)
		if for_sale:
			var id := ClothingStock.cloth_id(i)
			b.text = "$"
			b.tooltip_text = "%s, $%d" % [ClothingStock.item_name(id), ClothingStock.price(id)]
		elif is_locked:
			b.disabled = true
			b.text = "$"
			b.tooltip_text = "Sold in clothing shops"
		b.pressed.connect(func():
			on_pick.call(i)
			_changed())
		g.add_child(b)


func _page_look() -> void:
	var l := profile.look
	_heading("Body")
	_choices(CharacterLook.BODY_ORDER, func(k): return CharacterLook.BODIES[k].label, l.body, 4,
		func(k): l.body = k)
	_heading("Height")
	var sl := HSlider.new()
	sl.min_value = 0.92
	sl.max_value = 1.08
	sl.step = 0.01
	sl.value = l.height
	sl.custom_minimum_size = Vector2(0, 30)
	sl.value_changed.connect(func(v):
		l.height = v
		_refresh_model())
	_page.add_child(sl)
	_heading("Skin")
	_swatches(CharacterLook.SKIN, l.skin, func(i): l.skin = i)
	_heading("Hair")
	_choices(CharacterLook.HAIR_ORDER, func(k): return CharacterLook.HAIR_STYLES[k], l.hair, 4,
		func(k): l.set_hair(k))
	_heading("Hair color")
	_swatches(CharacterLook.HAIR_COLORS, l.hair_color, func(i): l.hair_color = i)
	_heading("Face")
	_choices(CharacterLook.FACE_ORDER, func(k): return CharacterLook.FACES[k], l.face, 3,
		func(k): l.face = k)


func _page_clothes() -> void:
	_clothes_sections()
	var note := Label.new()
	note.text = "Items marked $ are sold in clothing shops once the city unlocks them."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", SUB)
	_page.add_child(note)


## Style and color pickers for every piece of clothing. In the shop, unowned items can be
## tried on; elsewhere they are greyed out with a $.
func _clothes_sections() -> void:
	var l := profile.look
	_style_choices("top", "Top")
	_swatches(CharacterLook.CLOTH, l.top, func(i): l.top = i, 1)
	if l.top_style == "jacket":
		_heading("Jacket color")
		_swatches(CharacterLook.CLOTH, l.jacket, func(i): l.jacket = i, 1)
	_style_choices("bottom", "Bottom")
	_swatches(CharacterLook.CLOTH, l.bottom, func(i): l.bottom = i, 1)
	_style_choices("shoes", "Shoes")
	_swatches(CharacterLook.CLOTH, l.shoes, func(i): l.shoes = i, 1)
	_style_choices("hat", "Hat")
	if l.hat != "":
		_heading("Hat color")
		_swatches(CharacterLook.CLOTH, l.hat_color, func(i): l.hat_color = i, 1)
	elif l.hair in CharacterLook.NO_HAT_HAIR:
		var n := Label.new()
		n.text = "Hats need short hair: pick Short, Buzz cut, Bald or Ponytail first."
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.add_theme_color_override("font_color", SUB)
		_page.add_child(n)


func _style_choices(slot: String, title: String) -> void:
	_heading(title)
	var g := GridContainer.new()
	g.columns = 3
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	_page.add_child(g)
	var l := profile.look
	for style in CharacterLook.STYLE_ORDER[slot]:
		var b := Button.new()
		var owned := CharacterLook.style_owned(slot, style, profile.owned)
		var id := "%s:%s" % [slot, style]
		b.text = CharacterLook.STYLES[slot][style]
		if not owned:
			b.text += "  $" + (str(ClothingStock.price(id)) if mode == Mode.SHOP else "")
			b.tooltip_text = "Sold in clothing shops"
		b.toggle_mode = true
		b.button_pressed = l.get_style(slot) == style
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 40)
		b.disabled = not owned and mode != Mode.SHOP
		b.pressed.connect(func():
			l.set_style(slot, style)
			_changed())
		g.add_child(b)


func _page_outfits() -> void:
	_heading("Saved outfits")
	for slot in ResidentProfile.WARDROBE_SLOTS:
		var has := slot < profile.outfits.size() and not profile.outfits[slot].is_empty()
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		_page.add_child(h)
		var lbl := Label.new()
		lbl.text = "Outfit %d" % (slot + 1)
		lbl.custom_minimum_size = Vector2(90, 0)
		h.add_child(lbl)
		var chips := HBoxContainer.new()
		chips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(chips)
		if has:
			var o := CharacterLook.from_dict(profile.outfits[slot])
			for c in [CharacterLook.CLOTH[o.top], CharacterLook.CLOTH[o.bottom], CharacterLook.CLOTH[o.shoes],
					CharacterLook.HAIR_COLORS[o.hair_color]]:
				var r := ColorRect.new()
				r.color = c
				r.custom_minimum_size = Vector2(26, 26)
				chips.add_child(r)
		else:
			var e := Label.new()
			e.text = "empty"
			e.add_theme_color_override("font_color", SUB)
			chips.add_child(e)
		var wear := Button.new()
		wear.text = "Wear"
		wear.disabled = not has
		wear.pressed.connect(func():
			profile.wear_outfit(slot)
			_changed())
		h.add_child(wear)
		var save := Button.new()
		save.text = "Save current"
		save.pressed.connect(func():
			profile.save_outfit(slot)
			_show_page("Outfits"))
		h.add_child(save)


func _update_done() -> void:
	if _done == null:
		return
	if mode == Mode.CREATE:
		_done.text = "Next: choose a home"
		return
	var bill := ClothingStock.unpaid(profile.look, profile.owned)
	if bill.total == 0:
		_done.text = "Wear this"
		_done.disabled = false
		return
	# Only a shop can sell; elsewhere a look with unpaid colors can't be worn.
	_done.disabled = mode != Mode.SHOP or (cash >= 0 and bill.total > cash)
	_done.text = ("Buy and wear ($%d)" % bill.total) if mode == Mode.SHOP else "Not owned"


func _page_shop() -> void:
	var l := profile.look
	if cash >= 0:
		var c := Label.new()
		c.text = "Cash: $%d" % cash
		c.add_theme_font_size_override("font_size", 22)
		c.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
		_page.add_child(c)
	_clothes_sections()
	_heading("In the basket")
	var bill := ClothingStock.unpaid(l, profile.owned)
	var lines := []
	for id in bill.ids:
		lines.append("%s  $%d" % [ClothingStock.item_name(id), ClothingStock.price(id)])
	var b := Label.new()
	b.text = "\n".join(lines) if not lines.is_empty() else "Nothing new. Try on anything marked $."
	if cash >= 0 and bill.total > cash:
		b.text += "\nYou're $%d short." % (bill.total - cash)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_color_override("font_color", SUB if lines.is_empty() else Color(0.93, 0.95, 0.98))
	_page.add_child(b)
