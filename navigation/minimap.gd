class_name Minimap
extends Control
## The round street-level minimap, bottom left. It turns with the camera so up is the way
## you look, zooms out as you drive faster, and shows roads, buildings, the GPS line, your
## home, payphones, cops, special buildings and targets. Targets out of range sit on the rim.
## Everything it shows comes from CityNav (nav), which owns the data.

const RADIUS := 105.0   # on-screen radius in pixels at 900 px tall
const MARGIN := 26.0    # from the screen's bottom-left corner

var nav: Node           # CityNav

var _clip: Control      # draws the round mask; its child is clipped to it
var _content: Control   # map picture, GPS line and blips inside the circle
var _ring: Control      # rim, north marker, pinned targets and you, on top
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	_clip = Control.new()
	_clip.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clip)
	_clip.draw.connect(_draw_mask)
	_content = Control.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_clip.add_child(_content)
	_content.draw.connect(_draw_content)
	_ring = Control.new()
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ring)
	_ring.draw.connect(_draw_ring)


func scale_factor() -> float:
	return clampf(get_viewport_rect().size.y / 900.0, 0.7, 1.6)


func radius_px() -> float:
	return RADIUS * scale_factor()


func centre() -> Vector2:
	var vp := get_viewport_rect().size
	var r := radius_px()
	var m := MARGIN * scale_factor()
	return Vector2(m + r, vp.y - m - r)


func _process(_delta: float) -> void:
	if not visible:
		return
	var vp := get_viewport_rect().size
	for c: Control in [self, _clip, _content, _ring]:
		c.position = Vector2.ZERO
		c.size = vp
	_clip.queue_redraw()
	_content.queue_redraw()
	_ring.queue_redraw()


## World XZ to screen: the map turns so the camera's facing points up.
func to_screen(w: Vector2) -> Vector2:
	var me := Vector2(nav.me.x, nav.me.z)
	var k: float = radius_px() / nav.radius_m
	return centre() + (w - me).rotated(-nav.view_angle) * k


func _draw_mask() -> void:
	_clip.draw_circle(centre(), radius_px(), Color.WHITE)


func _draw_content() -> void:
	var r := radius_px()
	var c := centre()
	_content.draw_circle(c, r, MapPainter.SEA)
	var tex: Texture2D = nav.texture
	if tex:
		var k: float = r / nav.radius_m
		var me := Vector2(nav.me.x, nav.me.z)
		var world := City.SIZE * City.TILE
		_content.draw_set_transform(c, -nav.view_angle, Vector2(k, k))
		_content.draw_texture_rect(tex, Rect2(-me, Vector2(world, world)), false)
		# GPS line along the roads, in world metres under the same transform.
		var pts: PackedVector2Array = nav.route_points()
		if pts.size() >= 2:
			var shifted := PackedVector2Array()
			for p in pts:
				shifted.append(p - me)
			_content.draw_polyline(shifted, Blips.OUTLINE, 9.0 / k, true)
			_content.draw_polyline(shifted, nav.route_color(), 6.0 / k, true)
		_content.draw_set_transform_matrix(Transform2D.IDENTITY)
	var s := scale_factor()
	for b: Dictionary in nav.blips:
		if b.get("edge", false):
			continue  # drawn on the rim layer so they stay on top
		var p := to_screen(Vector2(b.pos.x, b.pos.z))
		if p.distance_to(c) > r + 8.0 * s:
			continue
		Blips.draw(_content, b.kind, p, b.color, (4.0 if b.kind == "cop" else 6.0) * s)
	# A soft dark rim inside the circle.
	_content.draw_arc(c, r - 3.0 * s, 0.0, TAU, 64, Color(0, 0, 0, 0.35), 6.0 * s, true)


func _draw_ring() -> void:
	var r := radius_px()
	var c := centre()
	var s := scale_factor()
	_ring.draw_arc(c, r + 1.5 * s, 0.0, TAU, 72, Blips.OUTLINE, 5.0 * s, true)
	_ring.draw_arc(c, r + 1.5 * s, 0.0, TAU, 72, Color(0.85, 0.88, 0.92, 0.85), 2.0 * s, true)
	# North: a letter on the rim where north is.
	var n := Vector2(0, -1).rotated(-nav.view_angle)
	var np := c + n * (r + 1.5 * s)
	_ring.draw_circle(np, 10.0 * s, Blips.OUTLINE)
	var fs := int(14 * s)
	_ring.draw_string(_font, np + Vector2(-10.0 * s, fs * 0.36), "N", HORIZONTAL_ALIGNMENT_CENTER, 20.0 * s, fs, Color.WHITE)
	# Targets: inside the circle, or pinned to the rim pointing their way.
	var t := Time.get_ticks_msec() * 0.001
	for b: Dictionary in nav.blips:
		if not b.get("edge", false):
			continue
		var p := to_screen(Vector2(b.pos.x, b.pos.z))
		var d := p - c
		var limit := r - 8.0 * s
		var pinned := d.length() > limit
		if pinned:
			p = c + d.normalized() * limit
		var size := 7.0 * s * (0.85 if pinned else 1.0 + 0.12 * sin(t * 5.0))
		Blips.draw(_ring, b.kind, p, b.color, size)
	Blips.draw(_ring, "you", c, Blips.YOU, 7.5 * s, nav.heading - nav.view_angle)
	# Distance left on the GPS route, beside the map.
	var left: float = nav.route_length()
	if left > 0.0:
		var txt := "%d m" % int(left) if left < 1000.0 else "%.1f km" % (left / 1000.0)
		var tfs := int(16 * s)
		var tp := c + Vector2(r * 0.8 + 6.0 * s, r * 0.8 + tfs * 0.5)  # just outside the rim, lower right
		_ring.draw_string_outline(_font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, 5, Blips.OUTLINE)
		_ring.draw_string(_font, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs, nav.route_color())
