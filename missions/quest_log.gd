class_name QuestLog
extends PanelContainer
## The quest log (J, in either view): every started quest with its current step and what
## it is waiting on, finished ones greyed out at the bottom, plus the goodness perks held.

var missions: Node  # Missions
var _box: VBoxContainer


func _ready() -> void:
	theme = Hud.make_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(460, 0)
	var scroll := VBoxContainer.new()
	scroll.add_theme_constant_override("separation", 6)
	add_child(scroll)
	_box = scroll
	visible = false


func toggle() -> void:
	visible = not visible
	if visible:
		refresh()


func refresh() -> void:
	for c in _box.get_children():
		c.queue_free()
	_line("QUEST LOG", 22, Color(1.0, 0.82, 0.18))
	var qe: QuestEngine = missions.quests
	var any := false
	var done: Array = []
	for q in qe.quests:
		var st := qe.state(q.id)
		match st.get("state", ""):
			"active":
				any = true
				_line(q.title, 19, MissionHud.BAD if q.role == "bad" else (MissionHud.GOOD if q.role == "good" else Color(0.6, 0.95, 0.6)))
				_line(q.desc, 14, Color(0.75, 0.78, 0.84))
				_line("> " + qe.step_text(q), 16, Color.WHITE)
				var w := qe.waiting_on(q)
				if w != "":
					_line("   " + w, 14, Color(0.7, 0.85, 1.0))
			"done":
				done.append(q)
	if not any:
		_line("No quests yet. They start as the city grows, as special buildings go up, and as you pick a side.", 15, Color(0.8, 0.82, 0.86))
	for q in done:
		_line("Done: " + q.title, 15, Color(0.55, 0.58, 0.62))
	var g: Goodness = missions.goodness
	var perks: Array[String] = []
	for p in Goodness.PERKS:
		if g.has_perk(p[1]):
			perks.append(p[2])
	_line("", 8, Color.WHITE)
	_line("Goodness: %s (%+d)" % [g.title(), int(round(g.value))], 17, Color(1, 1, 1))
	for p in perks:
		_line("  * " + p, 14, Color(0.85, 0.9, 0.7))
	var next_good := g.next_line("good")
	var next_bad := g.next_line("bad")
	_line("Next perk at %s or %s.   J closes" % [("%+d" % next_good) if next_good else "-", ("%+d" % next_bad) if next_bad else "-"],
		13, Color(0.6, 0.64, 0.7))
	var d: MissionDirector = missions.director
	_line("Jobs done: %d good, %d bad.  Failed: %d" % [d.stats.good, d.stats.bad, d.stats.failed], 13, Color(0.6, 0.64, 0.7))


func _line(text: String, size: int, col: Color) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 430
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	_box.add_child(l)


func _process(_delta: float) -> void:
	if visible:
		var vs := get_viewport_rect().size
		position = Vector2(vs.x * 0.5 - size.x * 0.5, vs.y * 0.14)
