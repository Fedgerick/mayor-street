class_name MissionHud
extends Control
## Street-level mission HUD, drawn in code like player/StreetHud (which owns the top-right
## corner: stars, cash, health). This draws:
##   top centre   the objective, the timer and what the job pays, plus an arrow and the
##                distance to the next marker
##   top left     the goodness bar (under main's key hint row), from Kingpin to Hero, with the perk lines marked
##   lower centre a call or radio offer, and quest news
##   mid screen   MISSION PASSED / FAILED
##   bottom       the bribe hint (B) while a cop is close and you have 1 to 3 stars
## The quest log (J) is a separate panel, QuestLog.

const GOOD := Color(0.35, 0.75, 1.0)
const BAD := Color(1.0, 0.35, 0.3)
const GOLD := Color(1.0, 0.82, 0.18)

var missions: Node  # Missions
var arrow_angle := 0.0     # radians, 0 = straight ahead
var arrow_dist := -1.0     # metres to the marker, -1 hides the arrow
var _font: Font
var _time := 0.0
var _banner := ""
var _banner_sub := ""
var _banner_col := Color.WHITE
var _banner_t := 99.0
var _news := ""
var _news_t := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func banner(text: String, sub: String, col: Color) -> void:
	_banner = text
	_banner_sub = sub
	_banner_col = col
	_banner_t = 0.0


func news(text: String, seconds := 4.0) -> void:
	_news = text
	_news_t = seconds


func _process(delta: float) -> void:
	var vs := get_viewport_rect().size
	if size != vs:
		position = Vector2.ZERO
		size = vs
	_time += delta
	_banner_t += delta
	_news_t = maxf(0.0, _news_t - delta)
	queue_redraw()


func _text(pos: Vector2, s: String, sz: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0, outline := 6) -> void:
	draw_string_outline(_font, pos, s, align, width, sz, outline, Color(0.02, 0.03, 0.06, 0.85 * col.a))
	draw_string(_font, pos, s, align, width, sz, col)


func _draw() -> void:
	if missions == null:
		return
	var vp := size
	var s := clampf(vp.y / 900.0, 0.7, 1.6)
	_draw_goodness(s)
	var d: MissionDirector = missions.director
	var m := d.active
	if m:
		var col := GOOD if m.side == "good" else BAD
		var y := 74.0 * s  # below the key hint row
		_text(Vector2(0, y), m.title.to_upper(), int(17 * s), col, HORIZONTAL_ALIGNMENT_CENTER, vp.x)
		y += 32.0 * s
		_text(Vector2(0, y), m.objective(), int(26 * s), Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, vp.x)
		y += 30.0 * s
		var info := "$%d" % m.pay
		if m.time_limit > 0.0:
			var t := maxf(0.0, m.time_left)
			info = "%d:%02d     %s" % [int(t) / 60, int(t) % 60, info]
		var warn := m.time_limit > 0.0 and m.time_left < 15.0 and fmod(_time, 0.6) < 0.3
		_text(Vector2(0, y), info, int(22 * s), BAD if warn else Color(0.85, 0.9, 0.95), HORIZONTAL_ALIGNMENT_CENTER, vp.x)
		var step := m.step()
		if step.get("do", "") == "hold" and m.hold > 0.0:
			y += 14.0 * s
			var bw := 220.0 * s
			var r := Rect2(vp.x * 0.5 - bw * 0.5, y, bw, 10.0 * s)
			draw_rect(r.grow(2.0), Color(0.02, 0.03, 0.06, 0.8))
			draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(m.hold / step.seconds, 0.0, 1.0), r.size.y)), col)
		if arrow_dist >= 0.0:
			_draw_arrow(Vector2(vp.x * 0.5, y + 46.0 * s), s, col)
	_draw_offer(vp, s)
	var bh: String = missions.bribe_hint()
	if bh != "":
		_text(Vector2(0, vp.y * 0.92), bh, int(22 * s), GOLD if bh.begins_with("B ") else Color(0.85, 0.85, 0.85),
			HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	if _news_t > 0.0:
		_text(Vector2(0, vp.y * 0.79), _news, int(22 * s), Color(1, 1, 1, minf(_news_t, 1.0)), HORIZONTAL_ALIGNMENT_CENTER, vp.x)
	if _banner_t < 4.0:
		var a := clampf(_banner_t * 3.0, 0.0, 1.0) * clampf((4.0 - _banner_t) * 1.5, 0.0, 1.0)
		var big := int(64 * s)
		var c := _banner_col
		c.a = a
		_text(Vector2(0, vp.y * 0.36), _banner, big, c, HORIZONTAL_ALIGNMENT_CENTER, vp.x, int(12 * s))
		_text(Vector2(0, vp.y * 0.36 + 44.0 * s), _banner_sub, int(26 * s), Color(1, 1, 1, a), HORIZONTAL_ALIGNMENT_CENTER, vp.x)


func _draw_arrow(c: Vector2, s: float, col: Color) -> void:
	var r := 16.0 * s
	var dir := Vector2(sin(arrow_angle), -cos(arrow_angle))
	var side := Vector2(-dir.y, dir.x)
	var tip := c + dir * r
	var pts := PackedVector2Array([tip, c - dir * r * 0.6 + side * r * 0.8, c - dir * r * 0.25, c - dir * r * 0.6 - side * r * 0.8])
	var outline := PackedVector2Array()
	for p in pts:
		outline.append(c + (p - c) * 1.25)
	draw_colored_polygon(outline, Color(0.02, 0.03, 0.06, 0.8))
	draw_colored_polygon(pts, col)
	var txt := "%d m" % int(arrow_dist) if arrow_dist < 1000.0 else "%.1f km" % (arrow_dist / 1000.0)
	_text(c + Vector2(-100.0 * s, r + 24.0 * s), txt, int(18 * s), Color(1, 1, 1, 0.9), HORIZONTAL_ALIGNMENT_CENTER, 200.0 * s)


func _draw_goodness(s: float) -> void:
	var g: Goodness = missions.goodness
	var x := 24.0 * s
	var y := 64.0 * s  # below the key hint row
	var w := 240.0 * s
	var h := 12.0 * s
	var r := Rect2(x, y, w, h)
	draw_rect(r.grow(2.0 * s), Color(0.02, 0.03, 0.06, 0.8))
	# Red (Kingpin) on the left, blue (Hero) on the right, filled from the middle.
	draw_rect(Rect2(x, y, w * 0.5, h), Color(0.35, 0.08, 0.08, 0.7))
	draw_rect(Rect2(x + w * 0.5, y, w * 0.5, h), Color(0.07, 0.17, 0.32, 0.7))
	var mid := x + w * 0.5
	var px := mid + (g.value / Goodness.MAX) * w * 0.5
	if g.value >= 0.0:
		draw_rect(Rect2(mid, y, px - mid, h), GOOD)
	else:
		draw_rect(Rect2(px, y, mid - px, h), BAD)
	for t in [-75, -50, -25, 25, 50, 75]:
		var tx: float = mid + t / Goodness.MAX * w * 0.5
		draw_line(Vector2(tx, y), Vector2(tx, y + h), Color(0, 0, 0, 0.6), 1.5 * s)
	draw_line(Vector2(mid, y - 3.0 * s), Vector2(mid, y + h + 3.0 * s), Color.WHITE, 2.0 * s)
	var col := GOOD if g.value > 0.5 else (BAD if g.value < -0.5 else Color(0.85, 0.85, 0.85))
	_text(Vector2(x, y + h + 22.0 * s), "%s  %+d" % [g.title(), int(round(g.value))], int(17 * s), col)


func _draw_offer(vp: Vector2, s: float) -> void:
	var text: String = missions.offer_text()
	if text == "":
		return
	var w := minf(vp.x * 0.62, 760.0 * s)
	var lines := _font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, w - 32.0 * s, int(20 * s))
	var h := lines.y + 26.0 * s
	var r := Rect2(vp.x * 0.5 - w * 0.5, vp.y * 0.86 - h, w, h)
	var col := BAD if missions.offer_side() == "bad" else GOOD
	draw_style_box(panel_style(Color(0.05, 0.07, 0.1, 0.86), int(12 * s)), r)
	draw_rect(Rect2(r.position, Vector2(5.0 * s, r.size.y)), col)
	draw_multiline_string(_font, r.position + Vector2(18.0 * s, 28.0 * s), text, HORIZONTAL_ALIGNMENT_LEFT,
		w - 32.0 * s, int(20 * s), -1, Color(0.95, 0.96, 0.98))


static func panel_style(c: Color, radius: int) -> StyleBoxFlat:
	## Same look as scripts/hud.gd panels; kept here so missions/ loads without the main HUD.
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb
