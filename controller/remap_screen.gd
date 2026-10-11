class_name RemapScreen
extends Control
## The controls screen: change any key or pad button. Opened from the layout card.
## Pick a row, then press the key (or the pad button, on the pad tab). Whatever already used
## that key or button moves to the old one, so two controls never share a key.
## Esc (or B on the pad) closes the screen; Esc, Start or a click cancels a pick in progress.

signal closed

const TABS := [[&"mayor", "Mayor view"], [&"street", "On foot and driving"], [&"global", "Anywhere"], [&"pad", "Pad buttons"]]

var pad: PadControls
var _tab := &"mayor"
var _pick := {}  # the row being changed: {"mode", "id"} for a key, {"role"} for a pad button
var _tabs: HBoxContainer
var _list: VBoxContainer
var _note: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.6)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.1, 0.12, 0.97)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(780, 560)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	var title := Label.new()
	title.text = "CONTROLS"
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	v.add_child(_tabs)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 360)
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	_note = Label.new()
	_note.add_theme_font_size_override("font_size", 14)
	_note.modulate = Color(0.75, 0.9, 1.0)
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(_note)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	v.add_child(foot)
	var reset := Button.new()
	reset.text = "Reset to defaults"
	reset.pressed.connect(_reset)
	foot.add_child(reset)
	var done := Button.new()
	done.text = "Done"
	done.custom_minimum_size = Vector2(120, 36)
	done.pressed.connect(close)
	foot.add_child(done)


func open() -> void:
	visible = true
	_pick = {}
	_rebuild()


func close() -> void:
	if not visible:
		return
	visible = false
	_pick = {}
	closed.emit()


func _rebuild() -> void:
	for c in _tabs.get_children():
		c.queue_free()
	for t in TABS:
		var b := Button.new()
		b.text = t[1]
		b.toggle_mode = true
		b.button_pressed = t[0] == _tab
		b.pressed.connect(_pick_tab.bind(t[0]))
		_tabs.add_child(b)
	for c in _list.get_children():
		c.queue_free()
	if _tab == &"pad":
		for role in PadBindings.PAD:
			var on_pad: bool = _pick.get("role", -1) == role
			var text := "Press a button..." if on_pad else PadGlyphs.label(pad.family, pad.binds.physical(role))
			_list.add_child(_row(PadBindings.PAD_ROLE_NAMES[role], text, _start_pad.bind(role)))
	else:
		for row in PadBindings.ROWS[_tab]:
			var on_key: bool = _pick.get("id", &"") == row[0] and _pick.get("mode", &"") == _tab
			var text := "Press a key..." if on_key else OS.get_keycode_string(pad.binds.bound_key(_tab, row[0]) as Key)
			_list.add_child(_row(row[1], text, _start_key.bind(_tab, row[0])))
	_show_note()


func _row(label: String, value: String, on_press: Callable) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 16)
	h.add_child(l)
	var b := Button.new()
	b.text = value
	b.custom_minimum_size = Vector2(200, 34)
	b.pressed.connect(on_press)
	h.add_child(b)
	return h


func _show_note() -> void:
	if _pick.is_empty():
		_note.text = "Pick a control, then press the key or button to use for it. Esc closes this."
	elif _pick.has("role"):
		_note.text = "Press the button to use for this. Start cancels."
	else:
		_note.text = "Press the key to use for this. Esc cancels. Pad buttons can't set keys; use the keyboard here."


func _pick_tab(tab: StringName) -> void:
	_tab = tab
	_pick = {}
	_rebuild()


func _start_key(mode: StringName, id: StringName) -> void:
	_pick = {"mode": mode, "id": id}
	_rebuild()


func _start_pad(role: int) -> void:
	_pick = {"role": role}
	_rebuild()


func _cancel() -> void:
	_pick = {}
	_rebuild()


func _done() -> void:
	_pick = {}
	pad.save_settings()
	_rebuild()


func _reset() -> void:
	pad.binds.reset()
	pad.binds.apply_input_map()
	_done()


func _input(e: InputEvent) -> void:
	if not visible:
		return
	if not _pick.is_empty():
		# Picking: this takes the press before the pad or the game sees it.
		if e is InputEventKey and e.pressed and not e.echo:
			var k := e as InputEventKey
			if k.keycode != KEY_ESCAPE and not _pick.has("role") and k.physical_keycode != KEY_NONE:
				pad.binds.set_key(_pick.mode, _pick.id, k.physical_keycode)
				_done()
			elif k.keycode == KEY_ESCAPE:
				_cancel()
			get_viewport().set_input_as_handled()
		elif e is InputEventJoypadButton and e.pressed:
			var b := (e as InputEventJoypadButton).button_index
			if b == JOY_BUTTON_START:
				_cancel()
			elif _pick.has("role"):
				pad.binds.set_pad(_pick.role, b)
				_done()
			get_viewport().set_input_as_handled()
		elif e is InputEventMouseButton and e.pressed:
			_cancel()  # not taken: the click still goes to whatever it hit
		return
	if e is InputEventKey and e.pressed and not e.echo and (e as InputEventKey).keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
