class_name GameMenu
extends CanvasLayer
## The Esc menu (resume, full screen, quit, and every control) plus the small key hint in a
## corner. It keeps running while the game is paused and owns the keys that must work
## everywhere: F11 and Alt+Enter switch full screen, Esc or Start closes the menu.

const MAYOR_KEYS := [
	["Tab", "Walk the streets"],
	["WASD / arrows", "Pan"],
	["Q E / right-drag", "Rotate"],
	["Wheel / middle-drag", "Zoom / grab"],
	["1 to 6", "Inspect, road, zones, bulldoze"],
	["7 / B", "Build menu"],
	["J", "Quest log"],
	["O", "Overlays"],
	["Space  ,  .", "Pause, slower, faster"],
	["N", "Skip an hour"],
	["M", "Music on or off"],
	["F3", "Frame rate"],
]
const STREET_KEYS := [
	["Tab", "Back to the mayor view"],
	["WASD + mouse", "Walk and look"],
	["Shift / Space", "Run / jump"],
	["E or F", "Get in or out of a car, or carjack"],
	["Click / right-click", "Attack / aim"],
	["Q / wheel / 1 to 3", "Switch weapon"],
	["W S / A D", "Drive / steer"],
	["Space", "Handbrake"],
	["H", "Horn"],
	["R", "Put the car back on its wheels"],
	["Y / K", "Take a radio job / give up a job"],
	["J", "Quest log"],
]
# The corner hint for each situation: key, what it does.
const HINTS := {
	&"mayor": [["B", "Build"], ["Tab", "Walk the streets"], ["Esc", "Menu"]],
	&"foot": [["WASD", "Walk"], ["Shift", "Run"], ["Space", "Jump"], ["E", "Car / carjack"],
		["Click", "Attack"], ["Q", "Weapon"], ["Tab", "Mayor view"], ["Esc", "Menu"]],
	&"car": [["W S", "Drive"], ["A D", "Steer"], ["Space", "Handbrake"], ["H", "Horn"], ["E", "Get out"],
		["Tab", "Mayor view"], ["Esc", "Menu"]],
}

var is_open := false
var _theme: Theme
var _menu: Control
var _panel: PanelContainer
var _saves: SavePanel
var _save_btn: Button
var _resume: Button
var _screen: Button
var _hint: PanelContainer
var _hint_rows := {}
var _hint_kind := &""
var _mouse_before := Input.MOUSE_MODE_VISIBLE
var _windowed := Rect2i()  # the last window size and place, to go back to


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 60
	_theme = Hud.make_theme()
	var ring := StyleBoxFlat.new()  # the menu is keyboard driven too, so show where focus is
	ring.draw_center = false
	ring.set_border_width_all(2)
	ring.border_color = Color(1.0, 0.85, 0.45)
	ring.set_corner_radius_all(10)
	_theme.set_stylebox("focus", "Button", ring)
	_build_hint()
	_build_menu()


func _input(e: InputEvent) -> void:
	var k := e as InputEventKey
	var key := k.keycode if k and k.pressed and not k.echo else KEY_NONE
	if key == KEY_F11 or (k and k.alt_pressed and (key == KEY_ENTER or key == KEY_KP_ENTER)):
		toggle_fullscreen()
		get_viewport().set_input_as_handled()
	elif is_open and (key == KEY_ESCAPE or e.is_action_pressed("ui_cancel") or is_start_button(e)):
		if _saves.visible:
			_saves.close()  # back to the menu
		else:
			close()
		get_viewport().set_input_as_handled()


static func is_start_button(e: InputEvent) -> bool:
	return e is InputEventJoypadButton and e.pressed and (e as InputEventJoypadButton).button_index == JOY_BUTTON_START


func open() -> void:
	## Pause everything and show the menu with the mouse free.
	if is_open:
		return
	is_open = true
	_mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = true
	_screen.text = "Play in a window" if is_fullscreen() else "Full screen"
	_hint.visible = false
	_menu.visible = true
	_saves.visible = false
	_panel.visible = true
	_save_btn.disabled = not Hud.progress().playing
	_resume.grab_focus()


func close() -> void:
	if not is_open:
		return
	is_open = false
	get_viewport().gui_release_focus()  # so no menu button is left holding the keyboard
	_menu.visible = false
	get_tree().paused = false
	Input.mouse_mode = _mouse_before
	show_hint(_hint_kind)


func is_fullscreen() -> bool:
	var w := get_window()
	if w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		return true
	# Some setups report a screen-filling window as windowed a moment after going full screen
	# (seen under Wine), so also go by what the player sees: a window covering the whole screen.
	var screen := DisplayServer.screen_get_size(w.current_screen)
	return w.size.x >= screen.x - 4 and w.size.y >= screen.y - 4


func toggle_fullscreen() -> void:
	var w := get_window()
	if is_fullscreen():
		w.mode = Window.MODE_WINDOWED
		if _windowed.size == Vector2i.ZERO:
			# The game starts full screen, so there is no window to go back to yet: make one
			# that leaves room for the title bar and the taskbar.
			var r := DisplayServer.screen_get_usable_rect(w.current_screen)
			w.size = Vector2i(Vector2(r.size) * 0.8)
			w.move_to_center()
		else:
			w.size = _windowed.size
			w.position = _windowed.position
		_screen.text = "Full screen"
	else:
		_windowed = Rect2i(w.position, w.size)
		w.mode = Window.MODE_FULLSCREEN
		_screen.text = "Play in a window"


# ------------------------------------------------------------------ key hint ---

func show_hint(kind: StringName) -> void:
	## "mayor", "foot", "car", or "" to hide it.
	_hint_kind = kind
	for k in _hint_rows:
		_hint_rows[k].visible = k == kind
	_hint.visible = kind != &"" and not is_open
	# Mayor view: bottom left, beside the tool bar. Street: top left, clear of the street HUD.
	var bottom := kind == &"mayor"
	_hint.anchor_top = 1.0 if bottom else 0.0
	_hint.anchor_bottom = _hint.anchor_top
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN if bottom else Control.GROW_DIRECTION_END
	_hint.offset_top = -26.0 if bottom else 18.0
	_hint.offset_bottom = _hint.offset_top
	_hint.reset_size()


func _build_hint() -> void:
	_hint = PanelContainer.new()
	_hint.theme = _theme
	_hint.add_theme_stylebox_override("panel", Hud.panel_style(Color(0.07, 0.09, 0.13, 0.66), 10))
	_hint.offset_left = 16.0
	_hint.visible = false
	add_child(_hint)
	for kind in HINTS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 18)
		row.visible = false
		for pair in HINTS[kind]:
			var h := HBoxContainer.new()
			h.add_theme_constant_override("separation", 7)
			h.add_child(_keycap(pair[0]))
			var l := Label.new()
			l.text = pair[1]
			l.add_theme_font_size_override("font_size", 16)
			l.add_theme_color_override("font_color", Color(0.85, 0.88, 0.94))
			h.add_child(l)
			row.add_child(h)
		_hint.add_child(row)
		_hint_rows[kind] = row
	_ignore_mouse(_hint)  # never in the way of a click on the city


static func _keycap(key: String) -> Label:
	var k := Label.new()
	k.text = key
	k.add_theme_font_size_override("font_size", 15)
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.12)
	s.border_color = Color(1, 1, 1, 0.5)
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.content_margin_left = 7
	s.content_margin_right = 7
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	k.add_theme_stylebox_override("normal", s)
	return k


static func _ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_mouse(c)


# ---------------------------------------------------------------------- menu ---

func _build_menu() -> void:
	_menu = Control.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.theme = _theme
	_menu.visible = false
	add_child(_menu)
	var dim := ColorRect.new()  # also stops clicks reaching the city underneath
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.05, 0.62)
	_menu.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu.add_child(center)
	var panel := PanelContainer.new()
	_panel = panel
	var ps := Hud.panel_style(Color(0.07, 0.09, 0.13, 0.94), 16)
	ps.content_margin_left = 40
	ps.content_margin_right = 40
	ps.content_margin_top = 28
	ps.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	panel.add_child(v)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	v.add_child(title)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	_resume = _button(row, "Resume", close)
	_screen = _button(row, "Play in a window", toggle_fullscreen)
	_button(row, "Quit to desktop", quit_game)
	var row2 := HBoxContainer.new()
	row2.alignment = BoxContainer.ALIGNMENT_CENTER
	row2.add_theme_constant_override("separation", 14)
	v.add_child(row2)
	_save_btn = _button(row2, "Save game", func(): _show_saves(true))
	_button(row2, "Load game", func(): _show_saves(false))
	v.add_child(_small("F11 or Alt+Enter also switch between full screen and a window", HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(HSeparator.new())

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 56)
	v.add_child(cols)
	cols.add_child(_key_table("MAYOR VIEW", MAYOR_KEYS))
	cols.add_child(_key_table("STREET LEVEL", STREET_KEYS))
	v.add_child(_small("Mayor Street %s" % ProjectSettings.get_setting("application/config/version", ""),
		HORIZONTAL_ALIGNMENT_RIGHT))
	_saves = SavePanel.new()
	center.add_child(_saves)
	_saves.closed.connect(func():
		_panel.visible = true
		_resume.grab_focus())


func _show_saves(saving: bool) -> void:
	_panel.visible = false
	_saves.open(saving)


func quit_game() -> void:
	## Quit to desktop, keeping the game in the autosave slot.
	Hud.progress().autosave()
	get_tree().quit()


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(250, 54)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


static func _small(text: String, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	return l


static func _key_table(title: String, keys: Array) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 13)
	t.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	v.add_child(t)
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 22)
	g.add_theme_constant_override("v_separation", 5)
	v.add_child(g)
	for r in keys:
		var k := Label.new()
		k.text = r[0]
		k.add_theme_font_size_override("font_size", 16)
		k.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
		g.add_child(k)
		var d := Label.new()
		d.text = r[1]
		d.add_theme_font_size_override("font_size", 16)
		g.add_child(d)
	return v
