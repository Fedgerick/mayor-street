class_name Updater
extends CanvasLayer
## Checks the public builds repo (latest.json there) for a newer build when the title screen opens and offers
## "Update now": it downloads the installer, starts it silently (it closes this game, installs
## over it and starts the new version) and quits.
##   --update-url=URL   read another latest.json (tests use a local server)
##   --update-test      run the check off Windows and stop after the download

## {"version": "0.3.5", "file": "MayorStreetPlanet-Setup.exe"}; the file sits next to it in the repo.
const RELEASES := "https://raw.githubusercontent.com/Fedgerick/mayor-street-builds/main/latest.json"
const ASSET := "MayorStreetPlanet-Update.exe"  # saved under user://

signal finished(state: String)  # "none", "offered", "downloaded", "failed"; for tests

static var _checked := false  # once per launch; loads and the benchmark reload the main scene

var url := RELEASES
var test_mode := false
var latest := ""
var _asset_url := ""
var _http: HTTPRequest
var _panel: PanelContainer
var _label: Label
var _bar: ProgressBar
var _buttons: HBoxContainer
var _update_btn: Button


static func should_check(args: Dictionary) -> bool:
	if _checked:
		return false
	if args.has("update-test"):
		return true
	return OS.get_name() == "Windows" and not OS.has_feature("editor")


func _ready() -> void:
	layer = 60
	_checked = true
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 15.0
	add_child(_http)
	_build_panel()
	_http.request_completed.connect(_on_release)
	if _http.request(url, ["User-Agent: MayorStreetPlanet", "Cache-Control: no-cache"]) != OK:
		_done("failed")


func _process(_delta: float) -> void:
	if _bar.visible and _http.get_body_size() > 0:
		_bar.value = 100.0 * _http.get_downloaded_bytes() / _http.get_body_size()


## "0.4.18" < "0.4.19" < "0.5.0"; a leading v is ignored.
static func is_newer(tag: String, current: String) -> bool:
	var a := tag.trim_prefix("v").split(".")
	var b := current.trim_prefix("v").split(".")
	for i in maxi(a.size(), b.size()):
		var x := int(a[i]) if i < a.size() else 0
		var y := int(b[i]) if i < b.size() else 0
		if x != y:
			return x > y
	return false


func _on_release(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_http.request_completed.disconnect(_on_release)
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_done("failed")
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		_done("failed")
		return
	latest = str(data.get("version", ""))
	var file := str(data.get("file", ""))
	if file != "":
		_asset_url = file if file.begins_with("http") else url.get_base_dir().path_join(file)
	var current := str(ProjectSettings.get_setting("application/config/version", "0"))
	if _asset_url == "" or not is_newer(latest, current):
		_done("none")
		return
	_label.text = "Mayor Street Planet %s is out (you have %s)." % [latest.trim_prefix("v"), current]
	_panel.show()
	_update_btn.grab_focus()  # so the pad's A button picks it
	finished.emit("offered")


func update_now() -> void:
	_buttons.hide()
	_bar.show()
	_label.text = "Downloading %s..." % latest.trim_prefix("v")
	_http.download_file = OS.get_user_data_dir().path_join(ASSET)
	_http.timeout = 0.0
	_http.request_completed.connect(_on_downloaded)
	if _http.request(_asset_url, ["User-Agent: MayorStreetPlanet"]) != OK:
		_fail()


func _on_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail()
		return
	if test_mode:
		_done("downloaded")
		return
	_label.text = "Installing. The game starts again by itself."
	var progress := get_node_or_null("/root/Progress")  # autoload; absent in test scripts
	if progress:
		progress.autosave()
	# /S: no windows; the installer closes this game if it is still open, then starts the new one.
	if OS.create_process(_http.download_file, ["/S"]) == -1:
		_fail()
		return
	get_tree().quit()


func _fail() -> void:
	_bar.hide()
	_label.text = "The update didn't download. Check your internet and try again next launch."
	_buttons.show()
	_update_btn.hide()
	finished.emit("failed")


func _done(state: String) -> void:
	finished.emit(state)
	if state != "offered":
		queue_free()


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_panel.position.y = 24
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.1, 0.14, 0.92)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	_panel.add_child(box)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 20)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_label)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(360, 18)
	_bar.hide()
	box.add_child(_bar)
	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons.add_theme_constant_override("separation", 12)
	box.add_child(_buttons)
	_update_btn = Button.new()
	_update_btn.text = "Update now"
	_update_btn.custom_minimum_size = Vector2(150, 40)
	_update_btn.pressed.connect(update_now)
	_buttons.add_child(_update_btn)
	var later := Button.new()
	later.text = "Later"
	later.custom_minimum_size = Vector2(110, 40)
	later.pressed.connect(func(): queue_free())
	_buttons.add_child(later)
	_panel.hide()
	add_child(_panel)
