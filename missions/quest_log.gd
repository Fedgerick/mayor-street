class_name QuestLog
extends PanelContainer
## The quest log (J, in either view): every started quest with its current step and what
## it is waiting on, finished ones greyed out at the bottom, plus the goodness perks held,
## respect with the three contacts, the story act, and passed story jobs with their medals
## (1-9 replays one at street level).

const ACT_NAMES := ["", "Act I", "Act II", "Act III"]

var missions: Node  # Missions
var _box: VBoxContainer


func _ready() -> void:
	add_theme_stylebox_override("panel", MissionHud.panel_style(Color(0.07, 0.09, 0.13, 0.9), 14))
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
	_story_header()
	var any := false
	var done: Array = []
	for q in qe.quests:
		var st := qe.state(q.id)
		match st.get("state", ""):
			"active":
				any = true
				var head: String = q.title
				if q.get("story", false):
					head = "%s: %s  (%s)" % [ACT_NAMES[int(q.act)], q.title, Contacts.PEOPLE[q.contact].short]
				_line(head, 19, MissionHud.BAD if q.role == "bad" else (MissionHud.GOOD if q.role == "good" else MissionHud.COUNCIL))
				_line(q.desc, 15, Color(0.75, 0.78, 0.84))
				_line("> " + qe.step_text(q), 16, Color.WHITE)
				var w := qe.waiting_on(q)
				if w != "":
					_line("   " + w, 15, Color(0.7, 0.85, 1.0))
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
		_line("  * " + p, 15, Color(0.85, 0.9, 0.7))
	var next_good := g.next_line("good")
	var next_bad := g.next_line("bad")
	_line("Next perk at %s or %s.   J closes" % [("%+d" % next_good) if next_good else "-", ("%+d" % next_bad) if next_bad else "-"],
		13, Color(0.6, 0.64, 0.7))
	_replays()
	var d: MissionDirector = missions.director
	_line("Jobs done: %d good, %d bad.  Failed: %d" % [d.stats.good, d.stats.bad, d.stats.failed], 14, Color(0.6, 0.64, 0.7))


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
		position = Vector2(vs.x * 0.5 - size.x * 0.5, vs.y * 0.2)


func _story_header() -> void:
	## The act reached, what opens the next one, and respect with each contact.
	var a: int = missions.act()
	var ending = missions.progress.get_flag("ending", false)
	if ending is String:
		_line("Story: finished. You are the %s of New Harbor" % ("Hero" if ending == "hero" else "Kingpin"), 16, MissionHud.GOLD)
	elif a == 0:
		_line("Story: opens when the city reaches %s" % Catalog.TIERS[Missions.ACT_TIERS[0]].name, 15, Color(0.8, 0.82, 0.86))
	elif a < 3:
		_line("Story: %s.  %s opens at %s" % [ACT_NAMES[a], ACT_NAMES[a + 1], Catalog.TIERS[Missions.ACT_TIERS[a]].name], 15, Color(0.8, 0.82, 0.86))
	else:
		_line("Story: Act III. Hero or Kingpin, it's up to you", 15, Color(0.8, 0.82, 0.86))
	var c: Contacts = missions.contacts
	for who in Contacts.ORDER:
		var v := c.get_respect(who)
		var bar := "|".repeat(int(v / 5.0)) + ".".repeat(20 - int(v / 5.0))
		_line("%-18s %s  %d  %s" % [Contacts.PEOPLE[who].name, bar, int(v), c.rank(who)], 14, Contacts.PEOPLE[who].color)
	_line("", 4, Color.WHITE)


func _replays() -> void:
	var list: Array = missions.medals.replays()
	if list.is_empty():
		return
	_line("", 6, Color.WHITE)
	_line("Story jobs (press 1-9 at street level to replay)", 16, Color(1, 1, 1))
	for i in mini(list.size(), 9):
		var e: Dictionary = list[i][1]
		var t := float(e.time)
		_line("%d  %s   %s  %d:%02d" % [i + 1, e.title, Medals.NAMES[int(e.medal)], int(t) / 60, int(t) % 60], 15,
			Medals.COLORS[int(e.medal)])
