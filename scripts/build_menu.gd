class_name BuildMenu
extends PanelContainer
## The Mayor's build menu: every catalog building by group. Locked ones stay visible,
## greyed out, with the goal that unlocks them, so the next milestone is always in view.

signal chosen(kind: String)

const ENTRY_SIZE := Vector2(214, 80)

var city: City
var group := "power"
var _tabs := {}       # group -> Button
var _grid: GridContainer
var _desc: Label
var _goal: Label


func _ready() -> void:
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -500.0
	offset_right = 500.0
	offset_bottom = -92.0
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	var t := Label.new()
	t.text = "BUILD"
	t.add_theme_font_size_override("font_size", 20)
	t.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	top.add_child(t)
	_goal = Label.new()
	_goal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_goal.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_goal.add_theme_font_size_override("font_size", 14)
	_goal.add_theme_color_override("font_color", Color(0.7, 0.76, 0.85))
	top.add_child(_goal)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	v.add_child(tabs)
	for g in Catalog.GROUPS:
		var b := Button.new()
		b.text = Catalog.GROUP_NAMES[g]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 38)
		b.pressed.connect(func(): show_group(g))
		tabs.add_child(b)
		_tabs[g] = b
	_grid = GridContainer.new()
	_grid.columns = 4
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	v.add_child(_grid)
	_desc = Label.new()
	_desc.add_theme_font_size_override("font_size", 14)
	_desc.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	_desc.custom_minimum_size = Vector2(0, 22)
	v.add_child(_desc)
	Hud.progress().unlocked.connect(func(_id, _s): _refresh_if_open())
	Hud.progress().tier_reached.connect(func(_t, _n, _ids): _refresh_if_open())
	visible = false


func open() -> void:
	visible = true
	show_group(group)


func show_group(g: String) -> void:
	group = g
	for k in _tabs:
		_tabs[k].set_pressed_no_signal(k == g)
	for c in _grid.get_children():
		c.queue_free()
	for id in Catalog.ids(g):
		_grid.add_child(_entry(id))
	var t: int = Hud.progress().city_tier
	var next := Catalog.goal_text(t + 1)
	_goal.text = "%s%s" % [Catalog.TIERS[t].name, "   Next milestone: " + next if next != "" else ""]
	_desc.text = ""
	Hud.no_keyboard_focus(self)


func _refresh_if_open() -> void:
	if visible:
		show_group(group)


func _entry(id: String) -> Button:
	var d := Catalog.get_def(id)
	var b := Button.new()
	b.custom_minimum_size = ENTRY_SIZE
	var built: bool = d.unique and city != null and not city.specials_of(id).is_empty()
	var unlocked: bool = Hud.progress().is_unlocked(id)
	var open_: bool = unlocked and not built
	b.disabled = not open_
	if not open_:
		b.add_theme_stylebox_override("disabled", Hud.panel_style(Color(0.11, 0.12, 0.15, 0.7), 10))
	# Name on top, then the price (or what unlocks it) in smaller type.
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 12.0
	v.offset_right = -10.0
	v.offset_top = 8.0
	v.offset_bottom = -6.0
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
	var detail := "Already built" if built else (Catalog.lock_text(id) if not unlocked else _price(d))
	_line(v, d.name, 15, d.accent.lerp(Color.WHITE, 0.55) if open_ else Color(0.56, 0.59, 0.66))
	_line(v, detail, 13, Color(0.78, 0.82, 0.9) if open_ else Color(0.5, 0.53, 0.6))
	b.mouse_entered.connect(func(): _desc.text = d.desc)
	b.pressed.connect(func():
		visible = false
		chosen.emit(id))
	return b


static func _line(parent: Control, text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## "$1,500 · 1x1" over "earns $8 a day".
static func _price(d: Dictionary) -> String:
	var cost := "$" + Catalog.thousands(int(d.cost))
	if d.placement == "line":
		return cost + " a tile, dragged like a road"
	var size := "on a sidewalk" if d.size == 0 else "%dx%d" % [d.size, d.size]
	var up := int(d.upkeep)
	var per_day := ""
	if up > 0:
		per_day = "\n$%d a day to run" % up
	elif up < 0:
		per_day = "\nearns $%d a day" % -up
	return "%s  ·  %s%s" % [cost, size, per_day]
