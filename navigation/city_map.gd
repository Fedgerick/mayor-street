class_name CityMap
extends Control
## The full city map: the whole island, north up, with the GPS route, every blip, a legend
## and the names of special buildings under the mouse. Click to set a waypoint, right-click
## to clear it, wheel to zoom, drag to pan. CityNav opens and closes it (V, or the Esc menu).

signal close_requested

const MIN_ZOOM := 1.0
const MAX_ZOOM := 5.0

var nav: Node           # CityNav

var zoom := 1.0
var centre_w := Vector2(City.W * City.TILE * 0.5, City.H * City.TILE * 0.5)  # world XZ in the middle
var _font: Font
var _drag_from := Vector2.INF
var _dragged := false
var _hover_w := Vector2.INF


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	focus_mode = Control.FOCUS_NONE
	process_mode = Node.PROCESS_MODE_ALWAYS


func open_at(w: Vector2) -> void:
	zoom = 1.0
	centre_w = Vector2(City.W * City.TILE * 0.5, City.H * City.TILE * 0.5)
	if w.is_finite():
		zoom = 1.6
		centre_w = w
	_clamp()


func _process(_delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport_rect().size
	position = Vector2.ZERO
	size = vp
	queue_redraw()


func ui_scale() -> float:
	return clampf(get_viewport_rect().size.y / 900.0, 0.7, 1.6)


## The square the whole island fills at zoom 1, in screen pixels.
func base_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var side := minf(vp.y - 120.0 * ui_scale(), vp.x - 340.0 * ui_scale())
	return Rect2((vp - Vector2(side, side)) * 0.5, Vector2(side, side))


func px_per_m() -> float:
	return base_rect().size.x / (maxi(City.W, City.H) * City.TILE) * zoom


func to_screen(w: Vector2) -> Vector2:
	return get_viewport_rect().size * 0.5 + (w - centre_w) * px_per_m()


func to_world(p: Vector2) -> Vector2:
	return centre_w + (p - get_viewport_rect().size * 0.5) / px_per_m()


func _clamp() -> void:
	var world := Vector2(City.W, City.H) * City.TILE
	var half := (get_viewport_rect().size * 0.5) / px_per_m()
	centre_w.x = clampf(centre_w.x, minf(half.x, world.x * 0.5), maxf(world.x - half.x, world.x * 0.5))
	centre_w.y = clampf(centre_w.y, minf(half.y, world.y * 0.5), maxf(world.y - half.y, world.y * 0.5))


func _gui_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb:
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := to_world(mb.position)
			zoom = clampf(zoom * (1.2 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2), MIN_ZOOM, MAX_ZOOM)
			centre_w += before - to_world(mb.position)  # keep the point under the mouse still
			_clamp()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_from = mb.position
				_dragged = false
			else:
				if not _dragged and _drag_from.is_finite():
					nav.set_waypoint(_ground(to_world(mb.position)))
				_drag_from = Vector2.INF
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			nav.clear_waypoint()
		accept_event()
	var mm := e as InputEventMouseMotion
	if mm:
		_hover_w = to_world(mm.position)
		if _drag_from.is_finite() and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT):
			if _dragged or mm.position.distance_to(_drag_from) > 6.0:
				_dragged = true
				centre_w -= mm.relative / px_per_m()
				_clamp()
		accept_event()


static func _ground(w: Vector2) -> Vector3:
	return Vector3(w.x, 0.0, w.y)


func _draw() -> void:
	var vp := get_viewport_rect().size
	var s := ui_scale()
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.03, 0.05, 0.08, 0.94))
	var tl := to_screen(Vector2.ZERO)
	var span := Vector2(City.W, City.H) * City.TILE * px_per_m()
	draw_rect(Rect2(tl, span), MapPainter.SEA)
	if nav.texture:
		draw_texture_rect(nav.texture, Rect2(tl, span), false)
	# GPS route.
	var pts: PackedVector2Array = nav.route_points()
	if pts.size() >= 2:
		var sp := PackedVector2Array()
		for p in pts:
			sp.append(to_screen(p))
		draw_polyline(sp, Blips.OUTLINE, 7.0 * s, true)
		draw_polyline(sp, nav.route_color(), 4.5 * s, true)
	# Blips: places first, then people and targets on top.
	var order := ["place", "phone", "cop", "car", "pickup", "enemy", "home", "job", "waypoint"]
	var r := 6.5 * s * clampf(sqrt(zoom), 1.0, 1.8)
	for kind in order:
		for b: Dictionary in nav.blips:
			if b.kind == kind or (kind == "job" and not b.kind in order):
				Blips.draw(self, b.kind, to_screen(Vector2(b.pos.x, b.pos.z)), b.color, r * (0.7 if kind == "cop" else 1.0))
	if nav.street_active():
		Blips.draw(self, "you", to_screen(Vector2(nav.me.x, nav.me.z)), Blips.YOU, r * 1.2, nav.heading)
	_draw_title(vp, s)
	_draw_legend(vp, s)
	_draw_hover(s)


func _text(p: Vector2, t: String, fs: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	draw_string_outline(_font, p, t, align, w, fs, 5, Blips.OUTLINE)
	draw_string(_font, p, t, align, w, fs, col)


func _draw_title(vp: Vector2, s: float) -> void:
	draw_rect(Rect2(0, 0, vp.x, 58.0 * s), Color(0.03, 0.05, 0.08, 0.75))
	draw_rect(Rect2(0, vp.y - 46.0 * s, vp.x, 46.0 * s), Color(0.03, 0.05, 0.08, 0.75))
	_text(Vector2(0, 40.0 * s), "NEW HARBOR", int(26 * s), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	var keys := "Click  Set waypoint     Right-click  Clear it     Wheel  Zoom     Drag  Move     V or Esc  Close"
	_text(Vector2(0, vp.y - 22.0 * s), keys, int(16 * s), Color(0.8, 0.84, 0.9), HORIZONTAL_ALIGNMENT_CENTER, vp.x)


func _draw_legend(vp: Vector2, s: float) -> void:
	var x := vp.x - 230.0 * s
	var y := 110.0 * s
	var row := 30.0 * s
	var box := Rect2(x - 18.0 * s, y - 34.0 * s, 220.0 * s, row * (Blips.LEGEND.size() + 1) + 30.0 * s)
	draw_rect(box, Color(0.06, 0.08, 0.12, 0.85))
	_text(Vector2(x, y - 8.0 * s), "KEY", int(15 * s), Color(0.75, 0.8, 0.88))
	y += 18.0 * s
	for e in Blips.LEGEND:
		Blips.draw(self, e[0], Vector2(x + 10.0 * s, y), e[1], 7.0 * s)
		_text(Vector2(x + 30.0 * s, y + 6.0 * s), e[2], int(16 * s), Color.WHITE)
		y += row
	var wp: Vector3 = nav.waypoint
	if wp.is_finite():
		var left: float = nav.route_length()
		var txt := "Waypoint set" if left <= 0.0 else ("Waypoint  %d m" % int(left) if left < 1000.0 else "Waypoint  %.1f km" % (left / 1000.0))
		_text(Vector2(x - 8.0 * s, box.end.y + 28.0 * s), txt, int(16 * s), Blips.WAYPOINT)


func _draw_hover(s: float) -> void:
	if not _hover_w.is_finite():
		return
	var name: String = nav.place_name(Vector3(_hover_w.x, 0.0, _hover_w.y))
	if name == "":
		return
	var p := to_screen(_hover_w) + Vector2(16.0, -12.0) * s
	var fs := int(17 * s)
	var w := _font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_rect(Rect2(p - Vector2(8.0, fs + 4.0) * s, Vector2(w + 16.0 * s, fs + 14.0 * s)), Color(0.05, 0.07, 0.1, 0.9))
	_text(p, name, fs, Color.WHITE)
