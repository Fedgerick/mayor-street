class_name PadHud
extends CanvasLayer
## What the player sees while playing on a pad: button prompts drawn for the pad in hand
## (Xbox, PlayStation or Nintendo), a ring on the pad cursor, the quick menu (hold View/Back)
## and the controller layout card. Shown only while the pad is the last thing used; the
## keyboard hints come back the moment a key or the mouse is touched.

const LAYER := 80            # above the city map (70) and the Esc menu (60)
const CHECK := 0.2           # seconds between prompt refreshes

var pad: PadControls
var _root: Control
var _bar: HBoxContainer      # bottom-right prompts for the current mode
var _context: HBoxContainer  # bottom-centre: get in, take the job, bribe...
var _ring: Control
var _quick: PanelContainer
var _quick_list: VBoxContainer
var _quick_items: Array = []  # [label, Callable]
var _quick_sel := 0
var _card: PanelContainer
var _paused_by_us := false
var _sig := ""
var _ctx_sig := ""
var _t := 0.0
var _hidden: Array[CanvasItem] = []  # keyboard hints faded out while the pad is in use
var _stick_ready := true
var _diag: Label
var remap: RemapScreen        # the controls screen: keys and pad buttons
var _card_was_open := false


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_bar = _row()
	_context = _row()
	_ring = _Ring.new()
	_ring.hud = self
	_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_ring)
	_build_quick()
	remap = RemapScreen.new()
	remap.pad = pad
	remap.closed.connect(_on_remap_closed)
	_root.add_child(remap)
	pad.using_pad_changed.connect(func(_on: bool) -> void: refresh())
	pad.family_changed.connect(func(_f: int) -> void: refresh())
	refresh()


func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 14)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(h)
	return h


func refresh() -> void:
	_sig = ""
	_ctx_sig = ""
	_t = CHECK


func _process(delta: float) -> void:
	if pad.using_pad:
		_ring.queue_redraw()
	_t += delta
	if card_open() and _t >= CHECK:
		_update_diag()
	if _t < CHECK:
		_stick_quick()
		return
	_t = 0.0
	var show := pad.using_pad and pad.mode != &"bench"
	_fade_keyboard_hints(show)
	_bar.visible = show and not quick_open() and not card_open()
	_context.visible = _bar.visible
	if not _bar.visible:
		return
	var rows := prompts(pad.mode)
	var sig := "%s|%d|%s" % [pad.mode, pad.family, str(rows)]
	if sig != _sig:
		_sig = sig
		_fill(_bar, rows, 22.0)
	var ctx := context_prompts()
	var csig := "%d|%s" % [pad.family, str(ctx)]
	if csig != _ctx_sig:
		_ctx_sig = csig
		_fill(_context, ctx, 32.0, 21)
	_place()
	_stick_quick()


func _place() -> void:
	## Sized to their contents each check: bottom-right row, and the context row centred above it.
	var vs := _root.get_viewport_rect().size
	_bar.size = _bar.get_combined_minimum_size()
	_bar.position = vs - _bar.size - Vector2(18, 14)
	if pad.mode == &"mayor":
		_bar.position.y = 84.0  # under the top bar; the tool bar and services panel own the bottom
	_context.size = _context.get_combined_minimum_size()
	_context.position = Vector2((vs.x - _context.size.x) * 0.5, vs.y - 112.0 - _context.size.y)


func _fill(box: HBoxContainer, rows: Array, px: float, fs := 15) -> void:
	for c in box.get_children():
		c.queue_free()
	for r in rows:
		var item := HBoxContainer.new()
		item.alignment = BoxContainer.ALIGNMENT_CENTER
		item.add_theme_constant_override("separation", 6)
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for b in r[0]:
			item.add_child(PadGlyph.make(pad.family, pad.binds.physical(b), px))
		var l := Label.new()
		l.text = r[1]
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", 5)
		item.add_child(l)
		box.add_child(item)
	_place.call_deferred()


# ------------------------------------------------------------------ prompts ---

func prompts(mode: StringName) -> Array:
	## Bottom-right row: [[buttons], what it does].
	match mode:
		&"mayor":
			return [[[JOY_BUTTON_A], "Select / build"], [[JOY_BUTTON_X], "Build menu"], [[JOY_BUTTON_Y], "Overlay"],
				[[PadGlyphs.RS], "Pan"], [[PadGlyphs.LT_RT], "Zoom"], [[PadGlyphs.LB_RB], "Rotate"],
				[[JOY_BUTTON_BACK], "Street (hold: quick menu)"], [[JOY_BUTTON_START], "Menu"]]
		&"street":
			if pad.driving():
				return [[[PadGlyphs.RT], "Gas"], [[PadGlyphs.LT], "Brake"], [[JOY_BUTTON_A], "Handbrake"],
					[[JOY_BUTTON_LEFT_SHOULDER], "Horn"], [[JOY_BUTTON_DPAD_UP], "Radio"], [[JOY_BUTTON_X], "Flip car"],
					[[JOY_BUTTON_BACK], "Mayor (hold: quick menu)"]]
			return [[[PadGlyphs.RT], "Attack"], [[PadGlyphs.LT], "Aim"], [[JOY_BUTTON_A], "Jump"],
				[[JOY_BUTTON_LEFT_STICK], "Run"], [[JOY_BUTTON_RIGHT_SHOULDER], "Weapon"], [[JOY_BUTTON_X], "Reload"],
				[[JOY_BUTTON_DPAD_DOWN], "Map"], [[JOY_BUTTON_DPAD_RIGHT], "Quests"],
				[[JOY_BUTTON_BACK], "Mayor (hold: quick menu)"]]
		&"menu":
			return [[[PadGlyphs.LS], "Pointer"], [[PadGlyphs.DPAD], "Next button"], [[JOY_BUTTON_A], "Select"],
				[[JOY_BUTTON_B], "Back"], [[PadGlyphs.RS], "Scroll"]]
	return []


func context_prompts() -> Array:
	## Bottom-centre: the action that fits right now, read off the game's own hints.
	if pad.mode != &"street":
		return []
	var out := []
	var m = pad.main
	var st = m.get("street") if m else null
	for src in [st.get("_hint") if st else null, m.get("resident").get("_hint") if m and m.get("resident") else null]:
		if src is Label and (src as Label).is_visible_in_tree() and (src as Label).text.begins_with("E  "):
			out.append([[JOY_BUTTON_Y], (src as Label).text.substr(3)])
	var k := pad.respond_key()
	if k == KEY_Y:
		out.append([[JOY_BUTTON_B], "Take the job"])
	elif k == KEY_B:
		out.append([[JOY_BUTTON_B], "Bribe the cop"])
	return out


func _fade_keyboard_hints(pad_on: bool) -> void:
	## The game's own "E  get in" style hints and the corner key list read wrong on a pad;
	## fade them while the pad is in use (ours show instead), bring them back for the keyboard.
	var want: Array[CanvasItem] = []
	if pad_on and pad.main:
		var m = pad.main
		var st = m.get("street")
		var res = m.get("resident")
		var menu = m.get("menu")
		for n in [st.get("_hint") if st else null, res.get("_hint") if res else null, menu.get("_hint") if menu else null]:
			if n is CanvasItem:
				want.append(n)
	for n in _hidden:
		if is_instance_valid(n) and n not in want:
			n.modulate.a = 1.0
	for n in want:
		n.modulate.a = 0.0
	_hidden = want


# --------------------------------------------------------------- quick menu ---

func quick_open() -> bool:
	return _quick != null and _quick.visible


func card_open() -> bool:
	return _card != null and _card.visible


func remap_open() -> bool:
	return remap != null and remap.visible


func open_remap() -> void:
	## The card steps aside while the controls screen is up, then comes back.
	_card_was_open = card_open()
	if _card:
		_card.visible = false
	_root.move_child(remap, -1)
	if _ring:
		_root.move_child(_ring, -1)
	remap.open()


func _on_remap_closed() -> void:
	if _card and _card_was_open:
		_card.visible = true
	_card_was_open = false
	refresh()


func _build_quick() -> void:
	_quick = PanelContainer.new()
	_quick.add_theme_stylebox_override("panel", _panel_style())
	_quick.set_anchors_preset(Control.PRESET_CENTER)
	_quick.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_quick.grow_vertical = Control.GROW_DIRECTION_BOTH
	_quick.custom_minimum_size = Vector2(440, 0)
	_quick.visible = false
	_root.add_child(_quick)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_quick.add_child(v)
	var t := Label.new()
	t.text = "QUICK MENU"
	t.add_theme_font_size_override("font_size", 22)
	v.add_child(t)
	_quick_list = VBoxContainer.new()
	_quick_list.add_theme_constant_override("separation", 2)
	v.add_child(_quick_list)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	foot.name = "Foot"
	v.add_child(foot)


static func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.13, 0.94)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(18)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	return sb


func quick_entries() -> Array:
	## [label, Callable] for the quick menu, by where the player is.
	var out := []
	var m = pad.main
	var street := pad.mode == &"street"
	if street:
		var k := pad.respond_key()
		if k == KEY_Y:
			out.append(["Take the job on offer", pad.tap.bind(KEY_Y)])
		elif k == KEY_B:
			out.append(["Bribe the cop", pad.tap.bind(KEY_B)])
	out.append(["Quest log", pad.tap.bind(KEY_J)])
	if m and m.get("nav"):
		out.append(["City map", pad.tap.bind(KEY_V)])
	var ms = m.get("missions") if m else null
	if street and ms:
		var perks = ms.get("perks")
		if perks and perks.has_method("has"):
			if perks.has(&"black_market"):
				for item in PerkEffects.SHOP:
					out.append(["Black market: %s  $%d" % [item[1], item[2]], _buy.bind(item[0])])
			if perks.has(&"crew_backup"):
				out.append(["Call the crew", pad.tap.bind(KEY_G)])
		var dir = ms.get("director")
		if dir and dir.get("active") != null:
			out.append(["Give up this job", pad.tap.bind(KEY_K)])
	if not street:
		out.append(["Pause / resume the city", pad.tap.bind(KEY_SPACE)])
		out.append(["Skip one hour", pad.tap.bind(KEY_N)])
	out.append(["Music on / off", pad.tap.bind(KEY_M)])
	out.append(["Controller layout", open_card])
	var icon_name: String = ("Auto (%s)" % PadGlyphs.FAMILY_NAMES[pad.family]) if pad.icons < 0 else PadGlyphs.FAMILY_NAMES[pad.icons]
	out.append(["Button icons: " + icon_name, _next_icons])
	out.append(["Vibration: " + ("on" if pad.vibration else "off"), func() -> void: pad.set_vibration(not pad.vibration)])
	return out


func _buy(key: Key) -> void:
	## The black market phone takes number keys while it is open: open, buy, hang up.
	var ms = pad.main.get("missions")
	var perks = ms.get("perks") if ms else null
	var was_open: bool = perks != null and perks.get("phone_open") == true
	if not was_open:
		pad.tap(KEY_P)
		await get_tree().process_frame
		await get_tree().process_frame
	pad.tap(key)
	if not was_open:
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().create_timer(1.2, true).timeout
		if perks and perks.get("phone_open") == true:
			pad.tap(KEY_P)


func _next_icons() -> void:
	# Auto, then each family in turn.
	pad.set_icons(pad.icons + 1 if pad.icons + 1 < PadGlyphs.FAMILY_NAMES.size() else -1)
	_fill_quick()


func open_quick() -> void:
	if quick_open() or card_open():
		return
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	_quick_sel = 0
	_fill_quick()
	_quick.visible = true
	refresh()


func close_quick() -> void:
	_quick.visible = false
	_unpause()
	refresh()


func _unpause() -> void:
	if _paused_by_us and not quick_open() and not card_open():
		_paused_by_us = false
		get_tree().paused = false


func _fill_quick() -> void:
	_quick_items = quick_entries()
	_quick_sel = clampi(_quick_sel, 0, _quick_items.size() - 1)
	for c in _quick_list.get_children():
		c.queue_free()
	for i in _quick_items.size():
		var l := Label.new()
		l.text = ("›  " if i == _quick_sel else "    ") + str(_quick_items[i][0])
		l.add_theme_font_size_override("font_size", 19)
		l.modulate = Color(1.0, 0.86, 0.4) if i == _quick_sel else Color(0.92, 0.93, 0.95)
		_quick_list.add_child(l)
	var foot: HBoxContainer = _quick.get_child(0).get_node("Foot")
	for c in foot.get_children():
		c.queue_free()
	for r in [[[PadGlyphs.DPAD], "Choose"], [[JOY_BUTTON_A], "OK"], [[JOY_BUTTON_B], "Close"]]:
		var g := PadGlyph.make(pad.family, r[0][0], 24.0)
		foot.add_child(g)
		var l := Label.new()
		l.text = r[1] + "   "
		foot.add_child(l)


func _move_quick(d: int) -> void:
	if _quick_items.is_empty():
		return
	_quick_sel = (_quick_sel + d + _quick_items.size()) % _quick_items.size()
	_fill_quick()


func _stick_quick() -> void:
	## The left stick also walks the quick menu, one step per push.
	if not quick_open():
		return
	var y := Input.get_joy_axis(pad.device, JOY_AXIS_LEFT_Y)
	if absf(y) < 0.35:
		_stick_ready = true
	elif absf(y) > 0.6 and _stick_ready:
		_stick_ready = false
		_move_quick(1 if y > 0.0 else -1)


func handle_button(b: int, down: bool) -> bool:
	## Called by PadControls first; true when the quick menu or the card took the press.
	if remap_open():
		if down and b == JOY_BUTTON_B:
			remap.close()
			return true
		return false  # the pointer reads the pad here: d-pad moves it, A clicks
	if card_open():
		if down and b in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_START, JOY_BUTTON_BACK]:
			close_card()
		return true
	if not quick_open():
		return false
	if not down:
		return true
	match b:
		JOY_BUTTON_DPAD_UP:
			_move_quick(-1)
		JOY_BUTTON_DPAD_DOWN:
			_move_quick(1)
		JOY_BUTTON_A:
			var item: Array = _quick_items[_quick_sel]
			var keep: bool = item[1] == _next_icons or str(item[0]).begins_with("Vibration")
			if not keep:
				close_quick()
			(item[1] as Callable).call()
			if keep:
				_fill_quick()
		JOY_BUTTON_B, JOY_BUTTON_BACK, JOY_BUTTON_START:
			close_quick()
	return true


# ------------------------------------------------------------ layout card ---

const LAYOUT := {
	"Mayor view": [
		[[PadGlyphs.LS], "Move the pointer (push the edge to scroll)"],
		[[PadGlyphs.RS], "Pan the city"], [[JOY_BUTTON_LEFT_STICK], "Hold to pan faster"],
		[[PadGlyphs.RT], "Zoom in"], [[PadGlyphs.LT], "Zoom out"], [[PadGlyphs.LB_RB], "Rotate"],
		[[JOY_BUTTON_RIGHT_STICK], "Level the camera"],
		[[JOY_BUTTON_A], "Select, place, hold and drag to zone"], [[JOY_BUTTON_B], "Drop the tool"],
		[[JOY_BUTTON_X], "Build menu"], [[JOY_BUTTON_Y], "Next overlay"],
		[[JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT], "Tools"],
		[[JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN], "City speed (down to pause)"],
	],
	"On foot": [
		[[PadGlyphs.LS], "Walk"], [[PadGlyphs.RS], "Look"], [[JOY_BUTTON_LEFT_STICK], "Run"],
		[[JOY_BUTTON_A], "Jump"], [[JOY_BUTTON_Y], "Enter a car or building, carjack"],
		[[PadGlyphs.RT], "Attack / shoot"], [[PadGlyphs.LT], "Aim"], [[JOY_BUTTON_X], "Reload"],
		[[JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_DPAD_LEFT], "Next / last weapon"],
		[[JOY_BUTTON_B], "Take a job, bribe a cop"],
		[[JOY_BUTTON_DPAD_DOWN], "City map"], [[JOY_BUTTON_DPAD_RIGHT], "Quest log"],
	],
	"Driving": [
		[[PadGlyphs.LS], "Steer"], [[PadGlyphs.RT], "Gas"], [[PadGlyphs.LT], "Brake and reverse"],
		[[JOY_BUTTON_A], "Handbrake"], [[JOY_BUTTON_Y], "Get out"], [[JOY_BUTTON_LEFT_SHOULDER], "Horn"],
		[[JOY_BUTTON_X], "Flip the car back over"], [[JOY_BUTTON_DPAD_UP], "Radio station"],
		[[PadGlyphs.RS], "Look around"],
	],
	"Everywhere": [
		[[JOY_BUTTON_START], "Pause menu, saves"], [[JOY_BUTTON_BACK], "Tap: mayor / street"],
		[[JOY_BUTTON_BACK], "Hold: quick menu (map, music, perks)"],
		[[PadGlyphs.LS], "Menus: move the pointer"], [[PadGlyphs.DPAD], "Menus: jump to the next button"],
		[[JOY_BUTTON_A], "Menus: select (hold to drag sliders)"], [[JOY_BUTTON_B], "Menus: back"],
		[[PadGlyphs.RS], "Menus and map: scroll, zoom"],
	],
}


func close_card() -> void:
	if _card:
		_card.visible = false
	_unpause()
	refresh()


func _input(e: InputEvent) -> void:
	## The card and the quick menu also close from the keyboard and mouse, so they can never
	## trap someone whose pad isn't reaching the game.
	if not card_open() and not quick_open():
		return
	var esc: bool = e is InputEventKey and e.pressed and not e.echo and (e as InputEventKey).keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	var click: bool = e is InputEventMouseButton and e.pressed and e.device != PadControls.SYNTH
	if card_open() and (esc or (click and not _card.get_global_rect().has_point((e as InputEventMouseButton).position))):
		close_card()
		get_viewport().set_input_as_handled()
	elif quick_open() and (esc or click):
		close_quick()
		get_viewport().set_input_as_handled()


func _update_diag() -> void:
	if _diag == null or not is_instance_valid(_diag):
		return
	var pads := Input.get_connected_joypads()
	var lines: Array[String] = []
	if pads.is_empty():
		lines.append("No controller found: Windows isn't passing one to the game. Check it's paired, then press a button on it.")
	for d in pads:
		lines.append("Controller %d: %s   (%s icons, id %s)" % [d, Input.get_joy_name(d),
			PadGlyphs.FAMILY_NAMES[PadGlyphs.detect(d)], Input.get_joy_guid(d)])
	lines.append("Last controller input: " + (pad.last_input if pad.last_input != "" else "none yet, press a button or move a stick"))
	_diag.text = "\n".join(lines)


func open_card() -> void:
	if _card:
		_card.queue_free()
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", _panel_style())
	_card.set_anchors_preset(Control.PRESET_CENTER)
	_card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_root.add_child(_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_card.add_child(v)
	var t := Label.new()
	var nm := pad.pad_name()
	t.text = "CONTROLLER  ·  %s buttons%s" % [PadGlyphs.FAMILY_NAMES[pad.family], ("  ·  " + nm) if nm != "" else ""]
	t.add_theme_font_size_override("font_size", 22)
	v.add_child(t)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 34)
	v.add_child(cols)
	for section in LAYOUT:
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 5)
		cols.add_child(col)
		var h := Label.new()
		h.text = section.to_upper()
		h.add_theme_font_size_override("font_size", 16)
		h.modulate = Color(1.0, 0.86, 0.4)
		col.add_child(h)
		for r in LAYOUT[section]:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 5)
			for b in r[0]:
				row.add_child(PadGlyph.make(pad.family, pad.binds.physical(b), 24.0))
			var l := Label.new()
			l.text = " " + r[1]
			l.add_theme_font_size_override("font_size", 14)
			row.add_child(l)
			col.add_child(row)
	# What Windows hands the game, live: the first thing to check when a pad does nothing.
	_diag = Label.new()
	_diag.add_theme_font_size_override("font_size", 14)
	_diag.modulate = Color(0.75, 0.9, 1.0)
	v.add_child(_diag)
	_update_diag()
	var foot_row := HBoxContainer.new()
	foot_row.add_theme_constant_override("separation", 16)
	v.add_child(foot_row)
	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(120, 36)
	close.pressed.connect(close_card)
	var keys := Button.new()
	keys.text = "Change buttons and keys"
	keys.custom_minimum_size = Vector2(230, 36)
	keys.pressed.connect(open_remap)
	foot_row.add_child(keys)
	foot_row.add_child(close)
	var foot := Label.new()
	foot.text = "Esc, a click or any face button closes this. Button icons can be switched in the quick menu."
	foot.modulate = Color(1, 1, 1, 0.6)
	foot_row.add_child(foot)
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	_card.visible = true
	refresh()


# ------------------------------------------------------------- pad cursor ---

class _Ring extends Control:
	var hud: PadHud

	func _draw() -> void:
		var p := hud.pad
		if not p.using_pad or p.mode not in [&"menu", &"mayor"] or hud.quick_open() or hud.card_open():
			return
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			return
		var c := p.cursor
		draw_arc(c, 15.0, 0, TAU, 32, Color(0, 0, 0, 0.55), 5.0, true)
		draw_arc(c, 15.0, 0, TAU, 32, Color(1.0, 0.86, 0.4, 0.95), 2.5, true)
