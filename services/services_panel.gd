class_name ServicesPanel
extends PanelContainer
## A small HUD panel: the service overlay buttons and the city's service numbers.
## main.gd adds it to the HUD and connects overlay_selected to ServicesView.set_overlay.
##
##   var panel := ServicesPanel.new()
##   hud.root.add_child(panel)
##   panel.setup(services)
##   panel.overlay_selected.connect(services_view.set_overlay)

signal overlay_selected(mode: int)

const TIPS := {
	"Power": "Yellow has power, red is on the grid without it",
	"Parks": "Parks raise land value and happiness nearby",
	"Garbage": "Uncollected garbage. Garbage depots pick it up",
	"Police": "Police station coverage. Crime drops inside it",
	"Fire": "Fire station coverage",
	"Crime": "Crime. More police, jobs and nicer streets bring it down",
	"Happiness": "How happy people are in each building",
}

var services: CityServices
var buttons: Array[Button] = []
var lines := {}  # key -> Label


func setup(s: CityServices) -> void:
	services = s
	s.stats_changed.connect(_refresh)
	s.coverage_changed.connect(_refresh)
	_refresh()


func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.1, 0.14, 0.85)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(8)
	add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	add_child(box)
	var title := Label.new()
	title.text = "City services"
	title.add_theme_font_size_override("font_size", 15)
	box.add_child(title)
	for key in [["power", "Power"], ["garbage", "Garbage collected"], ["crime", "Crime"],
			["happiness", "Happiness"], ["approval", "Approval"]]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", 13)
		l.text = key[1]
		lines[key[0]] = l
		box.add_child(l)
	var grid := GridContainer.new()
	grid.columns = 4
	box.add_child(grid)
	for i in range(1, CityServices.OVERLAY_NAMES.size()):
		var nm: String = CityServices.OVERLAY_NAMES[i]
		var b := Button.new()
		b.text = nm
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = TIPS.get(nm, "")
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_button.bind(i))
		grid.add_child(b)
		buttons.append(b)
	_place.call_deferred()


## Bottom right, above the tool bar.
func _place() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_top -= 56
	offset_bottom -= 56


func _on_button(mode: int) -> void:
	var on := buttons[mode - 1].button_pressed
	set_overlay(mode if on else CityServices.Overlay.NONE)
	overlay_selected.emit(mode if on else CityServices.Overlay.NONE)


## Shows which overlay is on (when it's switched from elsewhere, like a hotkey).
func set_overlay(mode: int) -> void:
	for k in buttons.size():
		buttons[k].set_pressed_no_signal(k + 1 == mode)


func _refresh() -> void:
	if services == null or lines.is_empty():
		return
	var s := services.stats()
	lines.power.text = "Power  %d%%   %d / %d MW" % [roundi(s.power_pct), roundi(s.demand_mw), roundi(s.supply_mw)]
	lines.garbage.text = "Garbage collected  %d%%" % roundi(s.garbage_pct)
	lines.crime.text = "Crime  %d" % roundi(s.crime)
	lines.happiness.text = "Happiness  %d" % roundi(s.happiness)
	lines.approval.text = "Approval  %d%%" % roundi(s.approval)
	lines.power.modulate = Color(1, 0.55, 0.5) if s.power_pct < 95.0 else Color.WHITE
	lines.garbage.modulate = Color(1, 0.55, 0.5) if s.garbage_pct < 80.0 else Color.WHITE
