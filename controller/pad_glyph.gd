class_name PadGlyph
extends Control
## One controller button, drawn (no image files, no font symbols): face buttons as coloured
## discs (PlayStation gets its cross, circle, square and triangle), bumpers and triggers as
## labelled pills, sticks as rings, the d-pad as a cross with the used arm lit.

var family := PadGlyphs.Family.XBOX:
	set(v):
		family = v
		_resize()
		queue_redraw()
var button := JOY_BUTTON_A:
	set(v):
		button = v
		_resize()
		queue_redraw()
var size_px := 30.0:
	set(v):
		size_px = v
		_resize()
		queue_redraw()


static func make(fam: int, b: int, px := 30.0) -> PadGlyph:
	var g := PadGlyph.new()
	g.family = fam
	g.button = b
	g.size_px = px
	return g


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_resize()


func _pill() -> bool:
	return not PadGlyphs.is_face(button) and not PadGlyphs.DPAD_NAMES.has(button) \
		and button not in [PadGlyphs.DPAD, PadGlyphs.LS, PadGlyphs.RS, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK]


func _resize() -> void:
	var w := size_px
	if _pill():
		var f := get_theme_default_font()
		var fs := int(size_px * 0.46)
		w = maxf(size_px * 1.25, f.get_string_size(PadGlyphs.label(family, button), HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + size_px * 0.6)
	custom_minimum_size = Vector2(w, size_px)
	size = custom_minimum_size


func _draw() -> void:
	var s := size_px
	var c := Vector2(size.x * 0.5, s * 0.5)
	var r := s * 0.5 - 1.0
	var dark := Color(0.1, 0.11, 0.14, 0.92)
	var light := Color(0.93, 0.94, 0.96)
	if PadGlyphs.is_face(button):
		var col := PadGlyphs.color(family, button)
		if family == PadGlyphs.Family.PLAYSTATION:
			draw_circle(c, r, dark)
			draw_arc(c, r, 0, TAU, 32, Color(1, 1, 1, 0.25), 1.5, true)
			_ps_symbol(c, r * 0.48, col)
		else:
			draw_circle(c, r, col.darkened(0.15) if family == PadGlyphs.Family.XBOX else dark)
			draw_arc(c, r, 0, TAU, 32, Color(1, 1, 1, 0.3), 1.5, true)
			_text(PadGlyphs.label(family, button), c, int(s * 0.55), light)
	elif PadGlyphs.DPAD_NAMES.has(button) or button == PadGlyphs.DPAD:
		_dpad(c, r)
	elif button in [PadGlyphs.LS, PadGlyphs.RS, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK]:
		draw_circle(c, r, dark)
		draw_arc(c, r * 0.72, 0, TAU, 28, Color(1, 1, 1, 0.45), 2.0, true)
		var t: String = "L" if button in [PadGlyphs.LS, JOY_BUTTON_LEFT_STICK] else "R"
		if button in [JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK]:
			t += "3"
		_text(t, c, int(s * (0.42 if t.length() > 1 else 0.5)), light)
	else:
		var rect := Rect2(Vector2(1, 1), size - Vector2(2, 2))
		var sb := StyleBoxFlat.new()
		sb.bg_color = dark
		sb.border_color = Color(1, 1, 1, 0.3)
		sb.set_border_width_all(1)
		var round := s * (0.5 if button in [JOY_BUTTON_BACK, JOY_BUTTON_START] else 0.3)
		sb.set_corner_radius_all(int(round))
		if button in [PadGlyphs.LT, PadGlyphs.RT, PadGlyphs.LT_RT]:
			sb.corner_radius_bottom_left = 3
			sb.corner_radius_bottom_right = 3
		draw_style_box(sb, rect)
		_text(PadGlyphs.label(family, button), size * 0.5, int(s * 0.46), light)


func _text(t: String, centre: Vector2, fs: int, col: Color) -> void:
	var f := get_theme_default_font()
	var sz := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var base := centre + Vector2(-sz.x * 0.5, f.get_ascent(fs) * 0.5 - f.get_descent(fs) * 0.35)
	draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _ps_symbol(c: Vector2, r: float, col: Color) -> void:
	var w := maxf(2.0, size_px * 0.08)
	match button:
		JOY_BUTTON_A:  # cross
			draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, w, true)
			draw_line(c + Vector2(-r, r), c + Vector2(r, -r), col, w, true)
		JOY_BUTTON_B:  # circle
			draw_arc(c, r, 0, TAU, 28, col, w, true)
		JOY_BUTTON_X:  # square
			draw_rect(Rect2(c - Vector2(r, r) * 0.9, Vector2(r, r) * 1.8), col, false, w)
		JOY_BUTTON_Y:  # triangle
			var p := PackedVector2Array([c + Vector2(0, -r * 1.05), c + Vector2(r * 1.0, r * 0.75),
				c + Vector2(-r * 1.0, r * 0.75), c + Vector2(0, -r * 1.05)])
			draw_polyline(p, col, w, true)


func _dpad(c: Vector2, r: float) -> void:
	var arm := r * 0.42
	var dark := Color(0.1, 0.11, 0.14, 0.92)
	var lit := Color(0.98, 0.85, 0.35)
	draw_rect(Rect2(c - Vector2(arm, r), Vector2(arm * 2, r * 2)), dark)
	draw_rect(Rect2(c - Vector2(r, arm), Vector2(r * 2, arm * 2)), dark)
	var dirs := {JOY_BUTTON_DPAD_UP: Vector2(0, -1), JOY_BUTTON_DPAD_DOWN: Vector2(0, 1),
		JOY_BUTTON_DPAD_LEFT: Vector2(-1, 0), JOY_BUTTON_DPAD_RIGHT: Vector2(1, 0)}
	for b in dirs:
		var d: Vector2 = dirs[b]
		var ctr: Vector2 = c + d * r * 0.62
		var col := lit if (b == button) else Color(1, 1, 1, 0.35)
		draw_rect(Rect2(ctr - Vector2(arm, arm) * 0.6, Vector2(arm, arm) * 1.2), col)
