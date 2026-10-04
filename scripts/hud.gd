class_name Hud
extends CanvasLayer
## Mayor view UI: stats bar, RCI demand, tools, overlays, speed, graphics quality.

signal tool_selected(tool: int)
signal overlay_selected(mode: int)
signal speed_selected(speed: int)
signal quality_selected(level: int)
signal start_chosen(demo: bool)
signal load_chosen(slot: String)

const TOOLS := ["Inspect", "Road", "Residential", "Commercial", "Industrial", "Bulldoze", "Build"]
const TOOL_COLORS := [Color(0.85, 0.88, 0.95), Color(0.75, 0.78, 0.85), Color(0.3, 0.85, 0.4),
	Color(0.3, 0.6, 1.0), Color(1.0, 0.75, 0.2), Color(1.0, 0.35, 0.3), Color(1.0, 0.85, 0.45)]
const OVERLAYS := ["None", "Zones", "Traffic", "Land value"]
const SPEEDS := ["II", "1x", "3x", "10x"]

var city: City
var root: Control
var lbl_funds: Label
var lbl_pop: Label
var lbl_jobs: Label
var lbl_time: Label
var lbl_income: Label
var bars := []
var tool_buttons := []
var overlay_buttons := []
var speed_buttons := []
var quality_buttons := []
var tip: Label
var info: Label
var toast: Label
var _toast_t := 0.0
var start_panel: Control
var tax_label: Label
var lbl_tier: Label
var build_menu: BuildMenu
var _toast_bad: StyleBoxFlat
var _toast_good: StyleBoxFlat


func _ready() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = make_theme()
	add_child(root)
	_build_top()
	_build_bottom()
	_build_side()
	tip = Label.new()
	tip.add_theme_stylebox_override("normal", panel_style(Color(0.08, 0.1, 0.14, 0.85), 6))
	tip.visible = false
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(tip)
	toast = Label.new()
	toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast.position = Vector2(-310, 90)
	toast.size = Vector2(620, 40)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_bad = panel_style(Color(0.6, 0.15, 0.12, 0.92), 10)
	_toast_good = panel_style(Color(0.12, 0.38, 0.24, 0.94), 10)
	toast.add_theme_stylebox_override("normal", _toast_bad)
	toast.visible = false
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(toast)
	build_menu = BuildMenu.new()
	build_menu.city = city
	root.add_child(build_menu)
	no_keyboard_focus(root)


## The Progress autoload, looked up at run time. Naming it directly would stop this class
## compiling in test scripts, which load before the autoloads exist.
static func progress() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null(^"Progress") if tree else null


static func no_keyboard_focus(n: Node) -> void:
	## A clicked button would otherwise keep the keyboard: Tab then only moves focus to the
	## next button and Space presses it again, so neither reaches the game.
	if n is Control:
		(n as Control).focus_mode = Control.FOCUS_NONE
	for c in n.get_children():
		no_keyboard_focus(c)


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 17
	var btn := panel_style(Color(0.16, 0.19, 0.25, 0.92), 10)
	var hov := panel_style(Color(0.24, 0.28, 0.36, 0.95), 10)
	var prs := panel_style(Color(0.3, 0.55, 0.95, 1.0), 10)
	t.set_stylebox("normal", "Button", btn)
	t.set_stylebox("hover", "Button", hov)
	t.set_stylebox("pressed", "Button", prs)
	t.set_stylebox("hover_pressed", "Button", prs)
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Color(0.92, 0.94, 0.98))
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_hover_pressed_color", "Button", Color.WHITE)
	t.set_color("font_color", "Label", Color(0.93, 0.95, 0.98))
	t.set_stylebox("panel", "PanelContainer", panel_style(Color(0.07, 0.09, 0.13, 0.82), 14))
	return t


static func panel_style(c: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(radius)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


func _stat(parent: Control, title: String) -> Label:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 22)
	v.add_child(t)
	v.add_child(l)
	parent.add_child(v)
	return l


func _build_top() -> void:
	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_CENTER_TOP)
	p.position = Vector2(-430, 12)
	p.custom_minimum_size = Vector2(860, 0)
	root.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 26)
	p.add_child(h)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", -2)
	h.add_child(nv)
	var name_l := Label.new()
	name_l.text = "NEW HARBOR"
	name_l.add_theme_font_size_override("font_size", 20)
	name_l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	nv.add_child(name_l)
	lbl_tier = Label.new()
	lbl_tier.add_theme_font_size_override("font_size", 12)
	lbl_tier.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	nv.add_child(lbl_tier)
	lbl_funds = _stat(h, "FUNDS")
	lbl_income = _stat(h, "PER DAY")
	lbl_pop = _stat(h, "POPULATION")
	lbl_jobs = _stat(h, "JOBS")
	lbl_time = _stat(h, "TIME")
	var sp := HBoxContainer.new()
	sp.add_theme_constant_override("separation", 4)
	h.add_child(sp)
	for i in SPEEDS.size():
		var b := Button.new()
		b.text = SPEEDS[i]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(48, 40)
		b.pressed.connect(func(): speed_selected.emit(i))
		sp.add_child(b)
		speed_buttons.append(b)


func _build_bottom() -> void:
	var p := PanelContainer.new()
	p.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	p.position = Vector2(-578, -78)
	root.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	p.add_child(h)
	for i in TOOLS.size():
		var b := Button.new()
		b.text = "%d  %s" % [i + 1, TOOLS[i]]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 46)
		b.add_theme_color_override("font_color", TOOL_COLORS[i])
		b.pressed.connect(func(): tool_selected.emit(i))
		h.add_child(b)
		tool_buttons.append(b)
	var sep := VSeparator.new()
	h.add_child(sep)
	for i in OVERLAYS.size():
		var b := Button.new()
		b.text = OVERLAYS[i]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 46)
		b.pressed.connect(func(): overlay_selected.emit(i))
		h.add_child(b)
		overlay_buttons.append(b)


func _build_side() -> void:
	# RCI demand bars, tax, quality, help: left side.
	var p := PanelContainer.new()
	p.position = Vector2(14, 12)
	root.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	var t := Label.new()
	t.text = "DEMAND"
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	v.add_child(t)
	var hb := HBoxContainer.new()
	hb.custom_minimum_size = Vector2(0, 90)
	hb.add_theme_constant_override("separation", 10)
	v.add_child(hb)
	for i in 3:
		var col := VBoxContainer.new()
		var bar := ProgressBar.new()
		bar.fill_mode = ProgressBar.FILL_BOTTOM_TO_TOP
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(26, 70)
		bar.min_value = -1.0
		bar.max_value = 1.0
		bar.step = 0.01
		var fill := panel_style(TOOL_COLORS[i + 2], 4)
		bar.add_theme_stylebox_override("fill", fill)
		bar.add_theme_stylebox_override("background", panel_style(Color(0.2, 0.22, 0.28, 0.8), 4))
		col.add_child(bar)
		var l := Label.new()
		l.text = ["R", "C", "I"][i]
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", TOOL_COLORS[i + 2])
		col.add_child(l)
		hb.add_child(col)
		bars.append(bar)
	var tx := HBoxContainer.new()
	v.add_child(tx)
	var minus := Button.new()
	minus.text = "-"
	minus.custom_minimum_size = Vector2(32, 30)
	minus.pressed.connect(func(): _tax(-0.01))
	tax_label = Label.new()
	tax_label.custom_minimum_size = Vector2(80, 0)
	tax_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var plus := Button.new()
	plus.text = "+"
	plus.custom_minimum_size = Vector2(32, 30)
	plus.pressed.connect(func(): _tax(0.01))
	tx.add_child(minus)
	tx.add_child(tax_label)
	tx.add_child(plus)
	var q := Label.new()
	q.text = "GRAPHICS"
	q.add_theme_font_size_override("font_size", 12)
	q.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
	v.add_child(q)
	var qh := HBoxContainer.new()
	v.add_child(qh)
	for i in 3:
		var b := Button.new()
		b.text = ["Low", "Med", "High"][i]
		b.toggle_mode = true
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(func(): quality_selected.emit(i))
		qh.add_child(b)
		quality_buttons.append(b)
	info = Label.new()
	info.add_theme_font_size_override("font_size", 14)
	info.add_theme_color_override("font_color", Color(0.8, 0.85, 0.92))
	info.custom_minimum_size = Vector2(170, 0)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD
	v.add_child(info)
	var help := Label.new()
	help.text = "Tab  dive to the street and back\nWASD pan · Q/E or right-drag rotate\nwheel zoom · middle-drag grab\nSpace pause · N skip 1 hour\nF11 full screen · Esc menu"
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	v.add_child(help)


func _tax(d: float) -> void:
	city.tax_rate = clampf(city.tax_rate + d, 0.0, 0.2)


func show_start() -> void:
	start_panel = PanelContainer.new()
	start_panel.set_anchors_preset(Control.PRESET_CENTER)
	start_panel.position = Vector2(-260, -150)
	start_panel.custom_minimum_size = Vector2(520, 0)
	root.add_child(start_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	start_panel.add_child(v)
	var t := Label.new()
	t.text = "MAYOR / STREET"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 40)
	t.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	v.add_child(t)
	var s := Label.new()
	s.text = "City sandbox · build roads, zone land, watch New Harbor grow"
	s.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	s.add_theme_color_override("font_color", Color(0.7, 0.76, 0.85))
	v.add_child(s)
	var saves: Array = progress().list_saves()
	if not saves.is_empty():
		var c := Button.new()
		c.text = "Continue\n" + SavePanel.describe(saves[0])
		c.custom_minimum_size = Vector2(0, 64)
		c.pressed.connect(func(): load_chosen.emit(saves[0].slot))
		v.add_child(c)
		var l := Button.new()
		l.text = "Load a saved game"
		l.custom_minimum_size = Vector2(0, 46)
		l.pressed.connect(_show_load)
		v.add_child(l)
	var a := Button.new()
	a.text = "Start on an empty island"
	a.custom_minimum_size = Vector2(0, 52)
	a.pressed.connect(func(): _close_start(false))
	v.add_child(a)
	var b := Button.new()
	b.text = "Load the demo city"
	b.custom_minimum_size = Vector2(0, 52)
	b.pressed.connect(func(): _close_start(true))
	v.add_child(b)
	var q := Button.new()
	q.text = "Quit"
	q.custom_minimum_size = Vector2(0, 40)
	q.pressed.connect(func(): get_tree().quit())
	v.add_child(q)
	no_keyboard_focus(start_panel)


func _show_load() -> void:
	start_panel.visible = false
	var sp := SavePanel.new()
	sp.set_anchors_preset(Control.PRESET_CENTER)
	sp.position = Vector2(-310, -220)
	root.add_child(sp)
	sp.open(false)
	no_keyboard_focus(sp)
	sp.closed.connect(func():
		sp.queue_free()
		start_panel.visible = true)


func _close_start(demo: bool) -> void:
	start_panel.queue_free()
	start_panel = null
	start_chosen.emit(demo)


func set_tool(i: int) -> void:
	for k in tool_buttons.size():
		tool_buttons[k].set_pressed_no_signal(k == i)


func set_overlay(i: int) -> void:
	for k in overlay_buttons.size():
		overlay_buttons[k].set_pressed_no_signal(k == i)


func set_speed(i: int) -> void:
	for k in speed_buttons.size():
		speed_buttons[k].set_pressed_no_signal(k == i)


func set_quality(i: int) -> void:
	for k in quality_buttons.size():
		quality_buttons[k].set_pressed_no_signal(k == i)


func show_tip(pos: Vector2, text: String) -> void:
	tip.visible = text != ""
	tip.text = text
	tip.position = pos + Vector2(18, 18)


func show_toast(text: String, good := false) -> void:
	## Red for problems ("Not enough money"), green for good news (milestones, saves).
	toast.text = text
	toast.add_theme_stylebox_override("normal", _toast_good if good else _toast_bad)
	toast.size = Vector2(620, 0)  # height follows the wrapped text
	toast.visible = true
	_toast_t = 4.0 if good else 2.5


func is_over_ui(pos: Vector2) -> bool:
	var hovered := root.get_viewport().gui_get_hovered_control()
	return hovered != null and hovered != root


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			toast.visible = false
	if city == null:
		return
	lbl_funds.text = "$" + _fmt(int(city.funds))
	var net := city.last_income - city.last_expense
	lbl_income.text = ("+$" if net >= 0 else "-$") + _fmt(int(absf(net)))
	lbl_income.add_theme_color_override("font_color", Color(0.5, 0.95, 0.55) if net >= 0 else Color(1, 0.45, 0.4))
	lbl_pop.text = _fmt(city.population)
	lbl_jobs.text = _fmt(city.jobs_c + city.jobs_i)
	var h := city.time_of_day()
	lbl_time.text = "Day %d  %02d:%02d" % [city.game_day() + 1, int(h), int(fmod(h, 1.0) * 60.0)]
	for i in 3:
		bars[i].value = city.demand[i + 1]
	tax_label.text = "Tax %d%%" % int(round(city.tax_rate * 100.0))
	lbl_tier.text = Catalog.TIERS[progress().city_tier].name.to_upper()


static func _fmt(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
