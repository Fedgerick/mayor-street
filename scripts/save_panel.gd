class_name SavePanel
extends PanelContainer
## Save slots: pick a slot to save into, or a save to load. The title screen and the Esc
## menu both use it.

signal closed

const SLOTS := ["slot1", "slot2", "slot3"]  # as in progress.gd
const AUTOSAVE := "autosave"

var saving := false
var _title: Label
var _list: VBoxContainer
var _back: Button


func _ready() -> void:
	var ps := Hud.panel_style(Color(0.07, 0.09, 0.13, 0.95), 16)
	ps.content_margin_left = 32
	ps.content_margin_right = 32
	ps.content_margin_top = 24
	ps.content_margin_bottom = 20
	add_theme_stylebox_override("panel", ps)
	custom_minimum_size = Vector2(620, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	add_child(v)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	v.add_child(_title)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 8)
	v.add_child(_list)
	_back = Button.new()
	_back.text = "Back"
	_back.custom_minimum_size = Vector2(0, 46)
	_back.pressed.connect(close)
	v.add_child(_back)
	visible = false


func open(save_mode: bool) -> void:
	saving = save_mode
	visible = true
	refresh()


func close() -> void:
	visible = false
	closed.emit()


func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	_title.text = "SAVE GAME" if saving else "LOAD GAME"
	var saves: Array = Hud.progress().list_saves()
	var by_slot := {}
	for h in saves:
		by_slot[h.slot] = h
	var slots: Array = SLOTS.duplicate()
	if not saving:
		# Newest first, with the autosave wherever its date puts it.
		slots = []
		for h in saves:
			slots.append(h.slot)
	for s in slots:
		var h: Dictionary = by_slot.get(s, {})
		var b := Button.new()
		b.custom_minimum_size = Vector2(0, 62)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s\n%s" % [slot_name(s), describe(h) if not h.is_empty() else "Empty"]
		b.pressed.connect(_pick.bind(s))
		_list.add_child(b)
	if slots.is_empty():
		var l := Label.new()
		l.text = "No saved games yet"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", Color(0.6, 0.66, 0.76))
		_list.add_child(l)
	if _list.get_child_count() > 0 and _list.get_child(0) is Button:
		(_list.get_child(0) as Button).grab_focus.call_deferred()
	else:
		_back.grab_focus.call_deferred()


func _pick(s: String) -> void:
	if saving:
		if Hud.progress().save_game(s):
			_title.text = "SAVED TO %s" % slot_name(s).to_upper()
			for c in _list.get_children():
				c.queue_free()
			close.call_deferred()
	else:
		Hud.progress().load_game(s)


static func slot_name(s: String) -> String:
	if s == AUTOSAVE:
		return "Autosave"
	if s.begins_with("slot"):
		return "Slot " + s.trim_prefix("slot")
	return s


## "Alex Rivera  ·  Day 12  ·  3,450 people  ·  Oct 4, 14:02"
static func describe(h: Dictionary) -> String:
	var parts: Array[String] = []
	if str(h.get("title", "")) != "":
		parts.append(str(h.title))
	parts.append("Day %d" % (int(h.get("day", 0)) + 1))
	parts.append("%s people" % Catalog.thousands(int(h.get("population", 0))))
	parts.append(when(int(h.get("saved_at", 0))))
	return "  ·  ".join(parts)


static func when(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d, %02d:%02d" % [MONTHS[clampi(int(d.month) - 1, 0, 11)], d.day, d.hour, d.minute]
