class_name ShopScreen
extends CanvasLayer
## The Harbor Arms counter: one row per item with its price and a Buy button. Pauses the
## game while open; Esc, B on a pad or the Leave button closes it. GunShop does the buying
## (buy_requested -> try_buy) and says what happened through show_result.

signal buy_requested(id: String)
signal closed

var shop: Node                  # GunShop
var _cash: Label
var _status: Label
var _rows := {}                 # item id -> {button, price}
var _first: Button


func _ready() -> void:
	layer = 95
	process_mode = Node.PROCESS_MODE_ALWAYS
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(760, 640)
	panel.position = -panel.custom_minimum_size * 0.5
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.11, 0.1, 0.96)
	sb.border_color = Color(0.85, 0.62, 0.2)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	dim.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_KEEP_SIZE)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := Label.new()
	title.text = "Harbor Arms & Supply"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.95, 0.75, 0.3))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_cash = Label.new()
	_cash.add_theme_font_size_override("font_size", 22)
	_cash.add_theme_color_override("font_color", Color(0.45, 0.9, 0.45))
	head.add_child(_cash)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	var group := ""
	for it in ShopStock.ITEMS:
		var g := "For your home" if it.kind == "home" else ("Odds and ends" if it.kind == "quest" else "Gear")
		if g != group:
			group = g
			var gl := Label.new()
			gl.text = g
			gl.add_theme_font_size_override("font_size", 18)
			gl.add_theme_color_override("font_color", Color(0.7, 0.72, 0.68))
			list.add_child(gl)
		list.add_child(_row(it))
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 18)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	var leave := Button.new()
	leave.text = "Leave  (Esc)"
	leave.custom_minimum_size = Vector2(0, 40)
	leave.pressed.connect(close)
	box.add_child(leave)
	refresh()
	if _first:
		_first.grab_focus.call_deferred()


func _row(it: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := Label.new()
	nm.text = it.name
	nm.add_theme_font_size_override("font_size", 19)
	text.add_child(nm)
	var d := Label.new()
	d.text = it.desc
	d.add_theme_font_size_override("font_size", 14)
	d.add_theme_color_override("font_color", Color(0.72, 0.74, 0.7))
	d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(d)
	row.add_child(text)
	var b := Button.new()
	b.custom_minimum_size = Vector2(150, 44)
	b.pressed.connect(func() -> void: buy_requested.emit(it.id))
	row.add_child(b)
	_rows[it.id] = b
	if _first == null:
		_first = b
	return row


## Prices, what is already owned, and the cash on hand.
func refresh() -> void:
	if shop == null:
		return
	_cash.text = "$%s" % Catalog.thousands(shop.cash())
	for id in _rows:
		var it := ShopStock.get_item(id)
		var b: Button = _rows[id]
		var why: String = shop.why_not(id)
		b.text = ("$%s" % Catalog.thousands(shop.price_of(id))) if why == "" else why
		b.disabled = why != "" and why != "Can't afford"


func show_result(text: String, good: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", Color(0.5, 0.95, 0.5) if good else Color(1.0, 0.45, 0.35))
	refresh()


func close() -> void:
	closed.emit()
	queue_free()


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel") or (e is InputEventJoypadButton and e.pressed and e.button_index == JOY_BUTTON_B):
		get_viewport().set_input_as_handled()
		close()
