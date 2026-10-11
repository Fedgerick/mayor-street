class_name CityCharts
extends CanvasLayer
## The City history window, opened by clicking the demand bars or the city numbers on the
## mayor HUD. Three pages:
##   Zones   residential, commercial and industrial buildings over time, each split into
##           light, medium and heavy (growth stages 1, 2 and 3; the 2x2 towers are heavy)
##   People  population and jobs over time
##   Money   city funds and each day's income less upkeep
## Hovering a chart reads out that day. Esc, Close or a click outside closes it.

signal closed

const PAGES := ["Zones", "People", "Money"]
const ZONE_KEYS := ["r", "c", "i"]
const ZONE_TITLES := ["Residential", "Commercial", "Industrial"]
const ZONE_COLORS := [Color(0.3, 0.85, 0.4), Color(0.3, 0.6, 1.0), Color(1.0, 0.75, 0.2)]
const DIM := Color(0.6, 0.66, 0.76)
const GRID := Color(1, 1, 1, 0.08)

var history: CityHistory
var page := 0
var _panel: PanelContainer
var _plot: Control
var _readout: Label
var _tabs: Array[Button] = []
var _data: Array[Dictionary] = []
var _hover := -1  # index into _data under the mouse, or -1
var _refresh_t := 0.0


func _ready() -> void:
	layer = 55  # over the HUD (and the street HUD), under the Esc menu
	visible = false
	var shade := ColorRect.new()  # a click outside the window closes it
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.02, 0.03, 0.05, 0.45)
	shade.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			close())
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.theme = Hud.make_theme()
	var ps := Hud.panel_style(Color(0.07, 0.09, 0.13, 0.96), 16)
	ps.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", ps)
	center.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_panel.add_child(v)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	var t := Label.new()
	t.text = "CITY HISTORY"
	t.add_theme_font_size_override("font_size", 24)
	t.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	top.add_child(t)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(gap)
	for i in PAGES.size():
		var b := Button.new()
		b.text = PAGES[i]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(110, 40)
		b.pressed.connect(func(): show_page(i))
		top.add_child(b)
		_tabs.append(b)
	var x := Button.new()
	x.text = "Close"
	x.custom_minimum_size = Vector2(100, 40)
	x.pressed.connect(close)
	top.add_child(x)

	_plot = Control.new()
	_plot.custom_minimum_size = Vector2(1100, 470)
	_plot.mouse_filter = Control.MOUSE_FILTER_STOP
	_plot.draw.connect(_draw_plot)
	_plot.gui_input.connect(_plot_input)
	_plot.mouse_exited.connect(func():
		_hover = -1
		_update_readout()
		_plot.queue_redraw())
	v.add_child(_plot)
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 15)
	_readout.add_theme_color_override("font_color", Color(0.85, 0.88, 0.94))
	_readout.custom_minimum_size = Vector2(1100, 66)
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_readout)
	Hud.no_keyboard_focus(self)


func open(which := -1) -> void:
	if which >= 0:
		page = which
	visible = true
	_refresh()
	show_page(page)


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func show_page(i: int) -> void:
	page = clampi(i, 0, PAGES.size() - 1)
	for k in _tabs.size():
		_tabs[k].set_pressed_no_signal(k == page)
	_hover = -1
	_update_readout()
	_plot.queue_redraw()


func _refresh() -> void:
	_data = history.series() if history else ([] as Array[Dictionary])
	_hover = mini(_hover, _data.size() - 1)


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:  # today's numbers move as the city grows
		_refresh_t = 1.0
		_refresh()
		_update_readout()
		_plot.queue_redraw()


# ------------------------------------------------------------------ drawing ---

func _font() -> Font:
	return ThemeDB.fallback_font


## The chart areas on the current page.
func _areas() -> Array[Rect2]:
	var s := _plot.size
	var out: Array[Rect2] = []
	if page == 0:
		var w := (s.x - 40.0) / 3.0
		for k in 3:
			out.append(Rect2(k * (w + 20.0) + 44.0, 64.0, w - 52.0, s.y - 112.0))
	else:
		out.append(Rect2(70.0, 40.0, s.x - 90.0, s.y - 76.0))
	return out


func _x_at(area: Rect2, k: int) -> float:
	if _data.size() <= 1:
		return area.position.x + area.size.x
	return area.position.x + area.size.x * float(k) / float(_data.size() - 1)


func _draw_plot() -> void:
	if _data.is_empty():
		return
	if page == 0:
		var areas := _areas()
		for z in 3:
			_draw_zone(areas[z], z)
	elif page == 1:
		_draw_lines(_areas()[0], [["pop", "Population", Color(0.3, 0.85, 0.4)],
			["jc", "Commercial jobs", Color(0.3, 0.6, 1.0)], ["ji", "Industrial jobs", Color(1.0, 0.75, 0.2)]])
	else:
		_draw_money(_areas()[0])


func _shade(z: int, st: int) -> Color:
	var c: Color = ZONE_COLORS[z]
	return [c.lightened(0.45), c, c.darkened(0.4)][st]


func _draw_zone(a: Rect2, z: int) -> void:
	var f := _font()
	var key: String = ZONE_KEYS[z]
	var now: Array = _data[_hover if _hover >= 0 else _data.size() - 1][key]
	var total := int(now[0]) + int(now[1]) + int(now[2])
	_plot.draw_string(f, Vector2(a.position.x, 22), ZONE_TITLES[z], HORIZONTAL_ALIGNMENT_LEFT, -1, 19, ZONE_COLORS[z])
	_plot.draw_string(f, Vector2(a.position.x, 44), "%d buildings" % total, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, DIM)
	var top := 1
	for d in _data:
		top = maxi(top, int(d[key][0]) + int(d[key][1]) + int(d[key][2]))
	top = _nice(top)
	_axis(a, top, false)
	# Stacked areas, light at the bottom, heavy on top.
	var base := PackedFloat32Array()
	base.resize(_data.size())
	for st in 3:
		var pts := PackedVector2Array()
		var low := PackedVector2Array()
		for k in _data.size():
			var y0 := base[k]
			var y1 := y0 + float(_data[k][key][st])
			base[k] = y1
			pts.append(Vector2(_x_at(a, k), a.end.y - a.size.y * y1 / top))
			low.append(Vector2(_x_at(a, k), a.end.y - a.size.y * y0 / top))
		_fill_band(pts, low, _shade(z, st))
	# Legend, heavy first so it reads like the stack.
	var lx := a.position.x - 30.0
	var ly := a.end.y + 36.0
	for st: int in [2, 1, 0]:
		var txt := "%s %d" % [CityHistory.STAGES[st], int(now[st])]
		_plot.draw_rect(Rect2(lx, ly - 11, 12, 12), _shade(z, st))
		_plot.draw_string(f, Vector2(lx + 17, ly), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.88, 0.94))
		lx += 17.0 + f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 16.0
	_hover_line(a)


func _fill_band(top_pts: PackedVector2Array, low_pts: PackedVector2Array, c: Color) -> void:
	if top_pts.size() == 1:  # a single day: a bar
		var x := top_pts[0].x
		_plot.draw_rect(Rect2(x - 8, top_pts[0].y, 8, low_pts[0].y - top_pts[0].y), c)
		return
	# One quad per day so bands that touch zero stay valid polygons.
	for k in top_pts.size() - 1:
		var quad := PackedVector2Array([top_pts[k], top_pts[k + 1], low_pts[k + 1], low_pts[k]])
		if absf(quad[0].y - quad[3].y) + absf(quad[1].y - quad[2].y) < 0.01:
			continue
		_plot.draw_colored_polygon(quad, c)


func _draw_lines(a: Rect2, series: Array) -> void:
	var f := _font()
	var top := 1
	for d in _data:
		for s in series:
			top = maxi(top, int(d[s[0]]))
	top = _nice(top)
	_axis(a, top, false)
	var at := _hover if _hover >= 0 else _data.size() - 1
	for j in series.size():
		var s: Array = series[j]
		var pts := PackedVector2Array()
		for k in _data.size():
			pts.append(Vector2(_x_at(a, k), a.end.y - a.size.y * float(_data[k][s[0]]) / top))
		if pts.size() > 1:
			_plot.draw_polyline(pts, s[2], 3.0, true)
		_plot.draw_circle(pts[at], 5.0, s[2])
		var lx := a.position.x + j * 230.0
		_plot.draw_rect(Rect2(lx, 12, 14, 14), s[2])
		_plot.draw_string(f, Vector2(lx + 20, 25), "%s  %s" % [s[1], Hud._fmt(int(_data[at][s[0]]))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.88, 0.9, 0.95))
	_hover_line(a)


func _draw_money(a: Rect2) -> void:
	var f := _font()
	var lo := 0
	var hi := 1
	for d in _data:
		lo = mini(lo, int(d.funds))
		hi = maxi(hi, int(d.funds))
	hi = _nice(hi)
	var span := float(hi - lo)
	_axis(a, hi, true, lo)
	var y_of := func(v: float) -> float: return a.end.y - a.size.y * (v - lo) / span
	# Each day's net as a bar along the bottom fifth, green up, red down.
	var net_top := 1
	for d in _data:
		net_top = maxi(net_top, absi(int(d.inc) - int(d.exp)))
	var mid := a.end.y - a.size.y * 0.1
	var bw := maxf(1.0, a.size.x / maxf(1.0, _data.size()) - 1.0)
	for k in _data.size():
		var n := int(_data[k].inc) - int(_data[k].exp)
		var h := a.size.y * 0.09 * float(absi(n)) / net_top
		var c := Color(0.5, 0.95, 0.55, 0.55) if n >= 0 else Color(1, 0.45, 0.4, 0.6)
		_plot.draw_rect(Rect2(_x_at(a, k) - bw * 0.5, mid - h if n >= 0 else mid, bw, h), c)
	var pts := PackedVector2Array()
	for k in _data.size():
		pts.append(Vector2(_x_at(a, k), y_of.call(float(_data[k].funds))))
	if pts.size() > 1:
		_plot.draw_polyline(pts, Color(1.0, 0.85, 0.45), 3.0, true)
	var at := _hover if _hover >= 0 else _data.size() - 1
	_plot.draw_circle(pts[at], 5.0, Color(1.0, 0.85, 0.45))
	var net := int(_data[at].inc) - int(_data[at].exp)
	_plot.draw_rect(Rect2(a.position.x, 12, 14, 14), Color(1.0, 0.85, 0.45))
	_plot.draw_string(f, Vector2(a.position.x + 20, 25), "Funds  $%s" % Hud._fmt(int(_data[at].funds)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.88, 0.9, 0.95))
	_plot.draw_rect(Rect2(a.position.x + 250, 12, 14, 14), Color(0.5, 0.95, 0.55, 0.7))
	_plot.draw_string(f, Vector2(a.position.x + 270, 25), "Per day  %s$%s  (income $%s, upkeep $%s)" % [
		"+" if net >= 0 else "-", Hud._fmt(absi(net)), Hud._fmt(int(_data[at].inc)), Hud._fmt(int(_data[at].exp))],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.88, 0.9, 0.95))
	_hover_line(a)


func _axis(a: Rect2, top: int, money: bool, bottom := 0) -> void:
	var f := _font()
	for g in 5:
		var y := a.end.y - a.size.y * g / 4.0
		_plot.draw_line(Vector2(a.position.x, y), Vector2(a.end.x, y), GRID, 1.0)
		var v := bottom + (top - bottom) * g / 4
		var txt := ("$" if money else "") + _short(v)
		_plot.draw_string(f, Vector2(a.position.x - 8 - f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x, y + 4),
			txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
	var d0 := int(_data[0].day) + 1
	var d1 := int(_data[-1].day) + 1
	_plot.draw_string(f, Vector2(a.position.x, a.end.y + 14), "Day %d" % d0, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
	_plot.draw_string(f, Vector2(a.end.x - 60, a.end.y + 14), "Day %d" % d1, HORIZONTAL_ALIGNMENT_RIGHT, 60, 12, DIM)


func _hover_line(a: Rect2) -> void:
	if _hover < 0:
		return
	var x := _x_at(a, _hover)
	_plot.draw_line(Vector2(x, a.position.y), Vector2(x, a.end.y), Color(1, 1, 1, 0.5), 1.0)


static func _nice(n: int) -> int:
	## Round an axis top up so it and its quarters are round numbers.
	var p := 1
	while p * 10 <= n:
		p *= 10
	for m in [1.0, 1.2, 1.6, 2.0, 2.4, 3.2, 4.0, 6.0, 8.0, 10.0]:
		if ceili(m * p) >= n:
			return ceili(m * p)
	return n


static func _short(n: int) -> String:
	if absi(n) >= 1000000:
		return "%.1fM" % (n / 1000000.0)
	if absi(n) >= 10000:
		return "%dk" % (n / 1000)
	return str(n)


# -------------------------------------------------------------------- hover ---

func _plot_input(e: InputEvent) -> void:
	if not e is InputEventMouseMotion or _data.is_empty():
		return
	var p := (e as InputEventMouseMotion).position
	var found := -1
	for a in _areas():
		if p.x >= a.position.x - 10 and p.x <= a.end.x + 10:
			found = clampi(roundi((p.x - a.position.x) / maxf(1.0, a.size.x) * (_data.size() - 1)), 0, _data.size() - 1)
	if found != _hover:
		_hover = found
		_update_readout()
		_plot.queue_redraw()


func _update_readout() -> void:
	if _data.is_empty():
		_readout.text = ""
		return
	var d: Dictionary = _data[_hover if _hover >= 0 else _data.size() - 1]
	var when := "Day %d" % (int(d.day) + 1) + ("" if _hover >= 0 and _hover < _data.size() - 1 else " (today)")
	match page:
		0:
			var parts := []
			for z in 3:
				var s: Array = d[ZONE_KEYS[z]]
				parts.append("%s %d light, %d medium, %d heavy" % [ZONE_TITLES[z], s[0], s[1], s[2]])
			_readout.text = when + ":  " + ".  ".join(parts) + \
				".\nLight, medium and heavy are the three growth stages. Lots grow when demand is up, land value is high enough and the city is big enough."
		1:
			_readout.text = "%s:  %s people, %s jobs (%s commercial, %s industrial)." % [when, Hud._fmt(int(d.pop)),
				Hud._fmt(int(d.jc) + int(d.ji)), Hud._fmt(int(d.jc)), Hud._fmt(int(d.ji))]
		2:
			_readout.text = "%s:  funds $%s. The bars along the bottom are each day's income less upkeep." % [
				when, Hud._fmt(int(d.funds))]
