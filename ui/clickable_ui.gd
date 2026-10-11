class_name ClickableUI
extends Node
## Makes the words and graphics on screen clickable, on top of what each part of the game
## already draws, without changing their code:
##   - every key hint does what it says: "Tab  Walk the streets", "Esc  Menu", "E  get in",
##     the mayor HUD help lines, the Esc menu's key tables. A click presses that key.
##   - the RCI demand bars open the City history window on its Zones page (each zone over
##     time, split into light, medium and heavy), population and jobs open the People page,
##     funds and per-day money the Money page. The city name and tier open the build menu
##     (where the milestones are), the clock pauses or restarts time.
##   - the City services lines switch on their overlay; the minimap opens the city map.
## Hovering anything clickable brightens it and shows a hand cursor. Clicks only count where
## the thing is really on top (not under the Esc menu) and while the mouse cursor is shown.
##
## Wiring, in main._ready once hud, menu and pad exist:  ClickableUI.install(self)
## It hooks the rest itself when a game starts (Progress.game_started) and saves the zone
## history in the "city_history" save section.

const HOT_TINT := Color(1.35, 1.3, 1.1)

var main: Node
var charts: CityCharts
var history: CityHistory
var _labels: Array[Label] = []
var _targets: Array[Dictionary] = []  # {item: CanvasItem, hit: Callable(pos) -> bool, act: Callable}
var _hot := {}  # what the mouse is over: {item, key} or a target
var _hot_tint := Color.WHITE
var _down := {}  # what the left button went down on
var _move_at := Vector2(-1, -1)  # the latest mouse move, looked at once a frame


static func install(m: Node) -> ClickableUI:
	var c := ClickableUI.new()
	c.name = "ClickableUI"
	c.main = m
	m.add_child(c)
	return c


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # the Esc menu's key tables work while paused
	charts = CityCharts.new()
	charts.name = "CityCharts"
	add_child(charts)
	get_tree().node_added.connect(_on_node_added)
	_scan(get_tree().root)
	var p := get_node_or_null(^"/root/Progress")
	if p:
		p.game_started.connect(_on_game_started)
	_hook_hud()


func _on_node_added(n: Node) -> void:
	if n is Label:
		_labels.append(n)


func _scan(n: Node) -> void:
	if n is Label:
		_labels.append(n)
	for c in n.get_children():
		_scan(c)


# --------------------------------------------------------------------- hooks ---

func _hook_hud() -> void:
	var hud = main.get("hud")
	if hud == null:
		return
	var bars: Array = hud.bars
	if not bars.is_empty():
		var demand: Control = bars[0].get_parent().get_parent()  # the R, C, I columns
		_add_rect(demand, func(): open_charts(0))
		_add_rect(demand.get_parent().get_child(demand.get_index() - 1), func(): open_charts(0))  # "DEMAND"
	for l in [hud.lbl_pop, hud.lbl_jobs]:
		_add_rect(l.get_parent(), func(): open_charts(1))
	for l in [hud.lbl_funds, hud.lbl_income]:
		_add_rect(l.get_parent(), func(): open_charts(2))
	_add_rect(hud.lbl_tier.get_parent(), func(): press_key(KEY_B))
	_add_rect(hud.lbl_time.get_parent(), func(): press_key(KEY_SPACE))
	# The help lines under the side panel read "Space pause · N skip 1 hour".
	var side: Node = hud.info.get_parent()
	for c in side.get_children():
		if c is Label and (c as Label).text.contains(" · "):
			c.set_meta(&"ui_loose_keys", true)


func _on_game_started(_loaded: bool) -> void:
	var city: City = main.get("city")
	if city == null:
		return
	history = CityHistory.new()
	history.name = "CityHistory"
	add_child(history)
	get_node(^"/root/Progress").register_section("city_history", history)  # a load fills it here
	history.setup(city)
	charts.history = history
	_hook_services()
	_hook_minimap()


func _hook_services() -> void:
	var sp = main.get("services_panel")
	if sp == null:
		return
	var names := {"power": "Power", "garbage": "Garbage", "crime": "Crime", "happiness": "Happiness"}
	for key in sp.lines:
		var b: Button = null
		for btn in sp.buttons:
			if btn.text == names.get(key, ""):
				b = btn
		if b:
			_add_rect(sp.lines[key], func():
				b.button_pressed = not b.button_pressed
				b.pressed.emit())


func _hook_minimap() -> void:
	var nav = main.get("nav")
	var mm = nav.get("minimap") if nav else null
	if mm == null:
		return
	_targets.append({"item": mm, "hit": func(p: Vector2) -> bool:
		return p.distance_to(mm.centre()) <= mm.radius_px(),
		"act": func(): nav.open_map()})


func _add_rect(c: Control, act: Callable) -> void:
	if c == null:
		return
	_targets.append({"item": c, "hit": func(p: Vector2) -> bool: return c.get_global_rect().has_point(p), "act": act})


# ------------------------------------------------------------------- actions ---

func open_charts(page: int) -> void:
	if history:
		charts.open(page)


## Press a key for the player. With the Esc menu open, a key from its tables closes the menu
## first so the key reaches the game.
func press_key(key: Key) -> void:
	var menu = main.get("menu")
	if menu and menu.is_open and key != KEY_ESCAPE:
		menu.close()
		await get_tree().process_frame
	KeyClick.press(key, get_tree())


# --------------------------------------------------------------------- input ---

func _input(e: InputEvent) -> void:
	if charts.visible and (e.is_action_pressed(&"ui_cancel") or (e is InputEventKey and e.pressed
			and (e as InputEventKey).keycode == KEY_ESCAPE)):
		charts.close()
		get_viewport().set_input_as_handled()
		return
	var mm := e as InputEventMouseMotion
	var mb := e as InputEventMouseButton
	if mm == null and (mb == null or mb.button_index != MOUSE_BUTTON_LEFT):
		return
	if not _cursor_shown() or _busy():
		_set_hot({})
		return
	if mm:
		_move_at = mm.position  # hover is worked out once a frame in _process, however fast the mouse
		return
	var hit := find_at(mb.position)
	if mb.pressed:
		if not hit.is_empty():
			_down = hit
			get_viewport().set_input_as_handled()
	elif not _down.is_empty():
		var was := _down
		_down = {}
		get_viewport().set_input_as_handled()
		if not hit.is_empty() and hit.item == was.item and hit.get("key") == was.get("key"):
			_activate(was)


func _process(_delta: float) -> void:
	if _move_at.x < 0.0:
		return
	_set_hot(find_at(_move_at) if _cursor_shown() and not _busy() else {})
	_move_at = Vector2(-1, -1)


func _activate(t: Dictionary) -> void:
	if t.has("act"):
		t.act.call()
	elif t.has("key"):
		press_key(t.key)


func _cursor_shown() -> bool:
	var m := Input.mouse_mode
	return m == Input.MOUSE_MODE_VISIBLE or m == Input.MOUSE_MODE_CONFINED


func _busy() -> bool:
	var b = main.get("bench")
	return b != null and is_instance_valid(b) and b.get("running") == true


## What a click at this screen point would do: {} for nothing, else {item, key} for a key
## hint or a target with act.
func find_at(pos: Vector2) -> Dictionary:
	var hovered := get_viewport().gui_get_hovered_control()
	for t in _targets:
		var it = t.item
		if is_instance_valid(it) and it.is_visible_in_tree() and t.hit.call(pos) and _on_top(it, hovered):
			return t
	var k := 0
	while k < _labels.size():
		var l := _labels[k]
		if not is_instance_valid(l):
			_labels.remove_at(k)
			continue
		k += 1
		if not l.is_visible_in_tree() or l.text == "" or l.get_viewport() != get_viewport():
			continue
		if not l.get_global_rect().has_point(pos) or charts.is_ancestor_of(l) or not _on_top(l, hovered):
			continue
		var key := label_key_at(l, pos)
		if key != KEY_NONE:
			return {"item": l, "key": key}
	return {}


## Nothing else is drawn over it: the control under the mouse is it, inside it, or holds it.
static func _on_top(c: CanvasItem, hovered: Control) -> bool:
	if hovered == null:
		return true
	return hovered == c or c.is_ancestor_of(hovered) or hovered.is_ancestor_of(c)


func _set_hot(t: Dictionary) -> void:
	var same: bool = not t.is_empty() and not _hot.is_empty() and t.item == _hot.item
	if not same:
		if not _hot.is_empty() and is_instance_valid(_hot.item):
			_hot.item.self_modulate = _hot_tint
		_hot = t
		if not t.is_empty():
			_hot_tint = t.item.self_modulate
			t.item.self_modulate = _hot_tint * HOT_TINT
	if not _hot.is_empty():
		# After the GUI has set its own cursor for this mouse move.
		DisplayServer.cursor_set_shape.call_deferred(DisplayServer.CURSOR_POINTING_HAND)


# -------------------------------------------------------------- label hints ---

## The key under this screen point of a label, or KEY_NONE.
static func label_key_at(l: Label, pos: Vector2) -> Key:
	var local := l.get_global_transform().affine_inverse() * pos
	var pair := pair_key(l)
	if pair != KEY_NONE:
		return pair
	var lines := l.text.split("\n")
	var loose := l.has_meta(&"ui_loose_keys")
	var font := l.get_theme_font(&"font")
	var fs := l.get_theme_font_size(&"font_size")
	if font == null:
		return KEY_NONE
	if l.autowrap_mode != TextServer.AUTOWRAP_OFF and l.get_line_count() != lines.size():
		# Wrapped text: only a one-line hint, taken as a whole.
		var segs := KeyClick.parse_line(l.text, loose) if lines.size() == 1 else []
		return segs[0].key if segs.size() == 1 else KEY_NONE
	var sb := l.get_theme_stylebox(&"normal")
	var ml := sb.get_margin(SIDE_LEFT) if sb else 0.0
	var mt := sb.get_margin(SIDE_TOP) if sb else 0.0
	var cw := l.size.x - ml - (sb.get_margin(SIDE_RIGHT) if sb else 0.0)
	var ch := l.size.y - mt - (sb.get_margin(SIDE_BOTTOM) if sb else 0.0)
	var lh := font.get_height(fs) + l.get_theme_constant(&"line_spacing")
	var th := lh * lines.size()
	var y0 := mt
	match l.vertical_alignment:
		VERTICAL_ALIGNMENT_CENTER: y0 += (ch - th) * 0.5
		VERTICAL_ALIGNMENT_BOTTOM: y0 += ch - th
	var li := floori((local.y - y0) / lh)
	if li < 0 or li >= lines.size():
		return KEY_NONE
	var line: String = lines[li]
	var segs := KeyClick.parse_line(line, loose)
	if segs.is_empty():
		return KEY_NONE
	var lw := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x0 := ml
	match l.horizontal_alignment:
		HORIZONTAL_ALIGNMENT_CENTER: x0 += (cw - lw) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT: x0 += cw - lw
	for s in segs:
		var sx := x0 + font.get_string_size(line.substr(0, s.from), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var ex := x0 + font.get_string_size(line.substr(0, s.to), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if local.x >= sx - 6.0 and local.x <= ex + 6.0:
			return s.key
	return KEY_NONE


## A key cap and its words side by side (the corner hint: [Tab] Walk the streets), or a row
## of a two-column key table (the Esc menu): either half presses the key.
static func pair_key(l: Label) -> Key:
	var p := l.get_parent()
	if p == null or l.text.contains("\n"):
		return KEY_NONE
	var i := l.get_index()
	if p is GridContainer and (p as GridContainer).columns == 2:
		var kl := l if i % 2 == 0 else p.get_child(i - 1)
		return KeyClick.key_of((kl as Label).text) if kl is Label else KEY_NONE
	if p is HBoxContainer and p.get_child_count() == 2 and p.get_child(0) is Label and p.get_child(1) is Label:
		var key := KeyClick.key_of((p.get_child(0) as Label).text)
		if key != KEY_NONE and KeyClick.key_of((p.get_child(1) as Label).text) == KEY_NONE:
			return key
	return KEY_NONE
