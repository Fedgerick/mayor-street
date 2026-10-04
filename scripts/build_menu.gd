class_name BuildMenu
extends PanelContainer
## The Mayor's build menu: every catalog building by group. Locked ones stay visible,
## greyed out, with the goal that unlocks them, so the next milestone is always in view.

signal chosen(kind: String)

const ENTRY_SIZE := Vector2(214, 74)

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
	Progress.unlocked.connect(func(_id, _s): _refresh_if_open())
	Progress.tier_reached.connect(func(_t, _n, _ids): _refresh_if_open())
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
	var t := Progress.city_tier
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
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", 15)
	var built: bool = d.unique and city != null and not city.specials_of(id).is_empty()
	var open_: bool = Progress.is_unlocked(id) and not built
	var line2 := ""
	if built:
		line2 = "Already built"
	elif not Progress.is_unlocked(id):
		line2 = Catalog.lock_text(id)
	else:
		line2 = _price(d)
	b.text = "%s\n%s" % [d.name, line2]
	b.disabled = not open_
	if not open_:
		b.add_theme_color_override("font_disabled_color", Color(0.55, 0.58, 0.64))
		b.add_theme_stylebox_override("disabled", Hud.panel_style(Color(0.12, 0.13, 0.16, 0.85), 10))
	else:
		b.add_theme_color_override("font_color", d.accent.lerp(Color.WHITE, 0.55))
	b.tooltip_text = ""
	b.mouse_entered.connect(func(): _desc.text = d.desc)
	b.pressed.connect(func():
		visible = false
		chosen.emit(id))
	return b


static func _price(d: Dictionary) -> String:
	var cost := "$" + Catalog.thousands(int(d.cost))
	if d.placement == "line":
		return cost + " a tile"
	var size := "sidewalk" if d.size == 0 else "%dx%d" % [d.size, d.size]
	var up := int(d.upkeep)
	var per_day := ""
	if up > 0:
		per_day = "  ·  $%d a day" % up
	elif up < 0:
		per_day = "  ·  earns $%d a day" % -up
	return "%s  ·  %s%s" % [cost, size, per_day]
