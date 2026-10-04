class_name StreetHud
extends Control
## The street-level HUD, drawn in code: wanted stars, cash, health and armor bars and the
## current weapon in the top-right corner, a crosshair while a gun is up, a red edge when
## hurt, short pickup notes, and the big WASTED / BUSTED cards.

var street: Node   # StreetMode
var flash := 0.0   # 0..1 red damage edge, decays
var _banner := ""
var _banner_col := Color.WHITE
var _banner_t := 0.0
var _note := ""
var _note_t := 0.0
var _black := 0.0
var _time := 0.0
var _shown_cash := 0.0
var _font: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


func banner(text: String, col: Color) -> void:
	_banner = text
	_banner_col = col
	_banner_t = 0.0


func clear_banner() -> void:
	_banner = ""


func note(text: String) -> void:
	_note = text
	_note_t = 2.2


func hurt(amount: float) -> void:
	flash = clampf(flash + amount / 40.0, 0.25, 1.0)


func set_black(a: float) -> void:
	_black = clampf(a, 0.0, 1.0)


func _process(delta: float) -> void:
	# Under a CanvasLayer the anchors have no parent rect, so follow the viewport.
	var vs := get_viewport_rect().size
	if size != vs:
		position = Vector2.ZERO
		size = vs
	_time += delta
	flash = maxf(flash - delta * 1.6, 0.0)
	_note_t = maxf(_note_t - delta, 0.0)
	_banner_t += delta
	if street:
		_shown_cash = move_toward(_shown_cash, float(street.cash()), maxf(absf(street.cash() - _shown_cash) * delta * 6.0, 1.0))
	queue_redraw()


func _text(pos: Vector2, s: String, size: int, col: Color, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0, outline := 6) -> void:
	draw_string_outline(_font, pos, s, align, width, size, outline, Color(0.02, 0.03, 0.06, 0.85 * col.a))
	draw_string(_font, pos, s, align, width, size, col)


static func _star(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 10:
		var a := -PI * 0.5 + i * PI / 5.0
		var rr := r if i % 2 == 0 else r * 0.45
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	return pts


func _draw() -> void:
	if street == null:
		return
	var vp := size
	var s := clampf(vp.y / 900.0, 0.7, 1.6)   # scale with resolution
	var p: StreetPlayer = street.player

	# Red edge when hurt or low on health.
	var low := 0.0 if p.dead else clampf((30.0 - p.health) / 30.0, 0.0, 1.0) * (0.35 + 0.15 * sin(_time * 6.0))
	var edge := maxf(flash, low)
	if edge > 0.01:
		var w := 90.0 * s
		var c0 := Color(0.75, 0.0, 0.0, 0.55 * edge)
		var c1 := Color(0.75, 0.0, 0.0, 0.0)
		for r in [[Vector2(0, 0), Vector2(vp.x, w), true], [Vector2(0, vp.y - w), Vector2(vp.x, w), false]]:
			var a: Vector2 = r[0]
			var sz: Vector2 = r[1]
			var top: bool = r[2]
			draw_polygon(PackedVector2Array([a, a + Vector2(sz.x, 0), a + sz, a + Vector2(0, sz.y)]),
				PackedColorArray([c0 if top else c1, c0 if top else c1, c1 if top else c0, c1 if top else c0]))
		for r in [[Vector2(0, 0), true], [Vector2(vp.x - w, 0), false]]:
			var a: Vector2 = r[0]
			var left: bool = r[1]
			draw_polygon(PackedVector2Array([a, a + Vector2(w, 0), a + Vector2(w, vp.y), a + Vector2(0, vp.y)]),
				PackedColorArray([c0 if left else c1, c1 if left else c0, c1 if left else c0, c0 if left else c1]))

	# Top right: stars, then cash, then health/armor, then weapon.
	var right := vp.x - 28.0 * s
	var y := 34.0 * s
	var lvl: int = street.wanted
	var fade: float = street.heat.fade_progress()
	var r := 15.0 * s
	for i in 5:
		var c := Vector2(right - r - i * (r * 2.3), y)
		var star := 4 - i   # leftmost is star 1
		var on := star < lvl
		var col := Color(1.0, 0.82, 0.18) if on else Color(0.1, 0.1, 0.12, 0.45)
		if on and star == lvl - 1 and fade > 0.5 and fmod(_time, 0.5) < 0.25:
			col = Color(1.0, 0.82, 0.18, 0.35)   # about to lose it: blink
		if on and street.heat.is_seen() and fmod(_time * 2.0, 1.0) < 0.5:
			col = col.lerp(Color(1, 0.3, 0.25), 0.55)   # cops see you: red-blue flash
		var pts := _star(c, r)
		draw_colored_polygon(_star(c, r + 2.0 * s), Color(0.02, 0.03, 0.06, 0.8))
		draw_colored_polygon(pts, col)
	y += r + 30.0 * s
	_text(Vector2(0, y), "$%s" % _commas(int(round(_shown_cash))), int(30 * s), Color(0.45, 0.95, 0.45), HORIZONTAL_ALIGNMENT_RIGHT, right)
	y += 16.0 * s
	var bw := 200.0 * s
	var bh := 11.0 * s
	_bar(Rect2(right - bw, y, bw, bh), p.health / StreetPlayer.MAX_HEALTH, Color(0.9, 0.18, 0.15))
	y += bh + 5.0 * s
	if p.armor > 0.0:
		_bar(Rect2(right - bw, y, bw, bh), p.armor / StreetPlayer.MAX_ARMOR, Color(0.3, 0.55, 1.0))
		y += bh + 5.0 * s
	var cb: StreetCombat = street.combat
	y += 26.0 * s
	var wtxt := cb.weapon_name()
	if cb.ammo_text() != "":
		wtxt += "   " + cb.ammo_text()
	_text(Vector2(0, y), wtxt, int(22 * s), Color(1, 1, 1, 0.95), HORIZONTAL_ALIGNMENT_RIGHT, right)

	# Crosshair.
	if cb.show_crosshair() and not p.dead:
		var c := vp * 0.5
		var g := (6.0 if cb.current == &"pistol" else 14.0) * s
		var l := 9.0 * s
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			draw_line(c + d * g, c + d * (g + l), Color(0, 0, 0, 0.6), 4.0 * s)
			draw_line(c + d * g, c + d * (g + l), Color(1, 1, 1, 0.95), 2.0 * s)
		draw_circle(c, 1.6 * s, Color(1, 1, 1, 0.9))

	# Pickup note.
	if _note_t > 0.0:
		_text(Vector2(0, vp.y * 0.72), _note, int(26 * s), Color(1, 1, 1, minf(_note_t, 1.0)), HORIZONTAL_ALIGNMENT_CENTER, vp.x)

	# Fade to black for respawns.
	if _black > 0.0:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0, 0, 0, _black))

	# WASTED / BUSTED.
	if _banner != "":
		var a := clampf(_banner_t * 2.5, 0.0, 1.0)
		var big := int(96 * s * (1.0 + 0.25 * (1.0 - a)))
		var col := _banner_col
		col.a = a
		_text(Vector2(0, vp.y * 0.5 + big * 0.35), _banner, big, col, HORIZONTAL_ALIGNMENT_CENTER, vp.x, int(14 * s))


func _bar(r: Rect2, k: float, col: Color) -> void:
	draw_rect(r.grow(2.0), Color(0.02, 0.03, 0.06, 0.8))
	draw_rect(r, col.darkened(0.7))
	draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(k, 0.0, 1.0), r.size.y)), col)


static func _commas(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out
