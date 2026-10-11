class_name PadControls
extends Node
## Full game controls on a gamepad (Xbox, PlayStation, Nintendo or any pad Windows/SDL knows).
##
## Nothing else in the game has to change: the street already reads its own "street_*"
## actions, which have pad buttons (player/scripts/street_input.gd). Everything else here is
## turned into the keys and clicks the game already understands:
##   - menus, the title screen, the creator, the city map: a pad cursor on the left stick,
##     A clicks, X right-clicks, B is Esc, the d-pad jumps between buttons, the right stick scrolls
##   - the mayor view: the same cursor (A places and drags), right stick pans, triggers zoom,
##     bumpers rotate, X build menu, Y overlay, d-pad tools and sim speed
##   - the street: B answers a job offer or bribes, d-pad down map, d-pad right quest log
##   - everywhere: View/Back tap switches mayor and street (Tab), hold it for the quick menu
##
## Wiring (main.gd), after menu, missions, nav and street exist:
##   pad = PadControls.new(); add_child(pad); pad.setup(self)
## Costs nothing without a pad: _process only runs while one is connected.

signal using_pad_changed(on: bool)
signal family_changed(family: int)

const SYNTH := -7            # device id on the clicks made here, so they are not "the mouse"
const DEAD := 0.2
const CURSOR_SPEED := 1250.0 # px per second at full tilt, in the 1920x1080 canvas
const EDGE := 6.0            # cursor this close to the screen edge pans the mayor camera
const HOLD := 0.4            # seconds on View/Back that open the quick menu instead of switching view
const CONFIG := "user://controller.cfg"

var main: Node
var hud: PadHud
var family := PadGlyphs.Family.XBOX
var icons := -1              # -1 follows the pad; else a PadGlyphs.Family the player picked
var vibration := true
var using_pad := false
var device := 0
var cursor := Vector2(960, 540)
var mode := &"menu"          # menu, mayor, street, bench

var last_input := ""         # the last pad button or stick seen, for the layout card's check line
var _now := 0.0
var _back_since := -1.0
var _a_down := false
var _x_down := false
var _release := []           # keys to let go next frame
var _slot := 0             # the d-pad's place on the tool bar (6 is Build)
var _tool_seen := 0
var _sprint_on := false       # street: L3 toggles sprinting
var _r3_down := false        # right stick click held (tilt while held, level on a plain tap)
var _r3_tilted := false
var _scroll_acc := Vector2.ZERO
var _mine: Array[InputEvent] = []  # keys made here, on their way through (keys keep device 0:
                                   # InputMap only matches actions on their own device)
var _quiet: Array[InputEvent] = [] # releases made here to clear a key the game must not see held
var _held := {}                    # physical key -> the key the game was given for it
var binds := PadBindings.new()     # remapped keys and pad buttons (pad_bindings.gd)


func setup(m: Node) -> void:
	main = m
	_load()
	hud = PadHud.new()
	hud.pad = self
	add_child(hud)
	Input.joy_connection_changed.connect(_on_joy)
	_log("game started, %d controller(s): %s" % [Input.get_connected_joypads().size(),
		", ".join(Input.get_connected_joypads().map(func(d): return "%d %s %s" % [d, Input.get_joy_name(d), Input.get_joy_guid(d)]))])
	_pick_device()
	_hook_rumble.call_deferred()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Read the pad before every other node's _input, so a press the cursor uses is not also
	# taken by the GUI's own focus keys (ui_accept on A) or by a second handler.
	_to_front.call_deferred()


func _to_front() -> void:
	var p := get_parent()
	if p:
		p.move_child(self, -1)


# ------------------------------------------------------------------ devices ---

func _on_joy(id: int, connected: bool) -> void:
	_log("%s controller %d: %s %s" % ["connected" if connected else "disconnected", id, Input.get_joy_name(id), Input.get_joy_guid(id)])
	_pick_device()


func _log(line: String) -> void:
	## user://controller_log.txt (on Windows %APPDATA%/MayorStreet/controller_log.txt): what Windows reported.
	var f := FileAccess.open("user://controller_log.txt", FileAccess.READ_WRITE if FileAccess.file_exists("user://controller_log.txt") else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line("%s  %s" % [Time.get_datetime_string_from_system(), line])


func _pick_device() -> void:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		_set_using(false)
		set_process(false)
		return
	if device not in pads:
		device = pads[0]
	set_process(true)
	_update_family()


func _update_family() -> void:
	var f: int = icons if icons >= 0 else PadGlyphs.detect(device)
	if f != family:
		family = f
		family_changed.emit(family)
	elif hud:
		hud.refresh()


func pad_name() -> String:
	return Input.get_joy_name(device) if device in Input.get_connected_joypads() else ""


func set_icons(f: int) -> void:
	icons = f
	_update_family()
	_save()


func set_vibration(on: bool) -> void:
	vibration = on
	_save()


func _set_using(on: bool) -> void:
	if on == using_pad:
		return
	using_pad = on
	if on:
		cursor = get_viewport().get_mouse_position()
	using_pad_changed.emit(on)


func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CONFIG) == OK:
		icons = int(cf.get_value("pad", "icons", -1))
		vibration = bool(cf.get_value("pad", "vibration", true))
		binds.load_from(cf)
	else:
		binds.apply_input_map()


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("pad", "icons", icons)
	cf.set_value("pad", "vibration", vibration)
	binds.save_to(cf)
	cf.save(CONFIG)


func save_settings() -> void:
	## Called by the remap screen after each change.
	_save()


# --------------------------------------------------------------------- mode ---

func current_mode() -> StringName:
	if main == null:
		return &"menu"
	var bench = main.get("bench")
	if bench and bench.get("running"):
		return &"bench"
	if get_tree().paused or not main.get("started"):
		return &"menu"
	var res = main.get("resident")
	if res and (res.get("_busy") == true or res.get("_menu") != null):
		return &"menu"
	var nav = main.get("nav")
	if nav and nav.get("map_open"):
		return &"menu"
	if main.has_method("in_street") and main.in_street():
		return &"street"
	return &"mayor"


func driving() -> bool:
	var st = main.get("street") if main else null
	return st != null and st.get("active") and st.get("car") != null


# -------------------------------------------------------------------- input ---

func _input(e: InputEvent) -> void:
	if e.device == SYNTH:
		return
	if e is InputEventKey:
		if _quiet.has(e):
			_quiet.erase(e)
			get_viewport().set_input_as_handled()
			return
		if _mine.has(e):
			_mine.erase(e)
			return
		if _translate_key(e as InputEventKey):
			get_viewport().set_input_as_handled()
			return
	if e is InputEventJoypadButton and e.pressed:
		last_input = "button %d on controller %d" % [(e as InputEventJoypadButton).button_index, e.device]
	elif e is InputEventJoypadMotion and absf((e as InputEventJoypadMotion).axis_value) > 0.5:
		last_input = "stick/trigger axis %d on controller %d" % [(e as InputEventJoypadMotion).axis, e.device]
	if e is InputEventJoypadButton or (e is InputEventJoypadMotion and absf((e as InputEventJoypadMotion).axis_value) > 0.5):
		if e.device != device and e.device in Input.get_connected_joypads():
			device = e.device
			_update_family()
		_set_using(true)
	elif e is InputEventKey or e is InputEventMouseButton:
		_set_using(false)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		# Moving the cursor ourselves makes the OS send a motion back: that is not the mouse.
		if mm.position.distance_to(cursor) > 3.0 and mm.relative.length() > 1.5:
			_set_using(false)
			cursor = mm.position
	if not (e is InputEventJoypadButton):
		if e is InputEventJoypadMotion and mode in [&"menu", &"mayor"]:
			get_viewport().set_input_as_handled()  # the cursor reads the sticks; keep GUI focus still
		return
	var jb := e as InputEventJoypadButton
	mode = current_mode()
	var role := binds.role_of(jb.button_index)  # the button's role, whatever it is remapped to
	if hud.handle_button(role, jb.pressed):
		get_viewport().set_input_as_handled()
		return
	if _button(role, jb.pressed):
		get_viewport().set_input_as_handled()


func _button(b: int, down: bool) -> bool:
	## True when this press is taken here (and kept from the rest of the game).
	if b == JOY_BUTTON_START:
		return false  # main.gd and GameMenu open and close the Esc menu on Start
	if mode == &"bench":
		if b == JOY_BUTTON_B and down:
			tap(KEY_ESCAPE)
		return b == JOY_BUTTON_B
	if b == JOY_BUTTON_BACK and mode in [&"mayor", &"street"]:
		if down:
			_back_since = _now
		elif _back_since >= 0.0:
			_back_since = -1.0
			tap(KEY_TAB)
		return true
	match mode:
		&"menu":
			return _menu_button(b, down)
		&"mayor":
			return _mayor_button(b, down)
		&"street":
			return _street_button(b, down)
	return false


func _menu_button(b: int, down: bool) -> bool:
	match b:
		JOY_BUTTON_A:
			var intro = _intro()
			if intro and down:
				tap(KEY_SPACE)
			elif down != _a_down:
				_a_down = down
				click(MOUSE_BUTTON_LEFT, down)
		JOY_BUTTON_X:
			if down != _x_down:
				_x_down = down
				click(MOUSE_BUTTON_RIGHT, down)
		JOY_BUTTON_B:
			if down:
				var nav = main.get("nav") if main else null
				if nav and nav.get("map_open"):
					nav.close_map()
				else:
					tap(KEY_ESCAPE)
		JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT:
			if down:
				jump_cursor(_dpad_dir(b))
		JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER:
			# Bumpers step through the buttons, like the d-pad's up and down (the right stick scrolls).
			if down:
				jump_cursor(Vector2.UP if b == JOY_BUTTON_LEFT_SHOULDER else Vector2.DOWN)
		_:
			return b != JOY_BUTTON_BACK
	return true


func _mayor_button(b: int, down: bool) -> bool:
	match b:
		JOY_BUTTON_A:
			if down != _a_down:
				_a_down = down
				click(MOUSE_BUTTON_LEFT, down)
		JOY_BUTTON_X:
			if down:
				tap(KEY_B)  # build menu
		JOY_BUTTON_Y:
			if down:
				tap(KEY_O)  # next map overlay
		JOY_BUTTON_B:
			if down and _mayor_has_something_in_hand():
				tap(KEY_ESCAPE)  # drops the drag, the build menu, then the tool
		JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT:
			if down:
				# The tool bar's seven slots: Inspect, Road, Res, Com, Ind, Bulldoze, Build (key 7).
				# Keeps its place on Build, which doesn't change the tool; a key press moves it.
				var tool_now := int(main.get("tool"))
				if tool_now != _tool_seen:
					_slot = tool_now
				var slot := (_slot + (1 if b == JOY_BUTTON_DPAD_RIGHT else -1) + 7) % 7
				_slot = slot
				if slot == 6:
					tap(KEY_7)  # Build opens the build menu, as the key does
				else:
					tap((KEY_1 + slot) as Key)
				_tool_seen = int(main.get("tool"))
		JOY_BUTTON_DPAD_UP:
			if down:
				tap(KEY_PERIOD)  # faster
		JOY_BUTTON_DPAD_DOWN:
			if down:
				tap(KEY_COMMA)  # slower, down to paused
		JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK:
			pass  # read in _process (rotate, fast pan)
		_:
			return false
	return true


func _mayor_has_something_in_hand() -> bool:
	var hud_node = main.get("hud")
	var bm = hud_node.get("build_menu") if hud_node else null
	return main.get("_dragging") == true or (bm != null and bm.visible) or int(main.get("tool")) != 0


func _street_button(b: int, down: bool) -> bool:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and down:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED  # the Esc menu left the cursor out
	match b:
		JOY_BUTTON_B:
			if down:
				var k := respond_key()
				if k != KEY_NONE:
					tap(k)
			return true
		JOY_BUTTON_DPAD_DOWN:
			if down:
				tap(KEY_V)  # city map
			return true
		JOY_BUTTON_LEFT_STICK:
			# A click toggles sprinting on and off (street_sprint is held here, not by the stick).
			if down:
				_sprint_on = not _sprint_on
				if _sprint_on:
					Input.action_press(&"street_sprint")
				else:
					Input.action_release(&"street_sprint")
			return true
		JOY_BUTTON_DPAD_RIGHT:
			if down:
				tap(KEY_J)  # quest log
			return true
	return false  # the street's own actions (street_input.gd) take the rest


func respond_key() -> Key:
	## What B does at street level right now: close the quest log, bribe, or take the job.
	var ms = main.get("missions") if main else null
	if ms == null:
		return KEY_NONE
	var log_panel = ms.get("log_panel")
	if log_panel and log_panel.visible:
		return KEY_J
	if str(ms.get("_bribe_state")) != "":
		return KEY_B
	if ms.get("_radio_offer") != null or ms.get("_council_offer") != null:
		return KEY_Y
	return KEY_NONE


func _intro() -> Object:
	var ms = main.get("missions") if main else null
	var intro = ms.get("intro") if ms else null
	return intro if intro and intro.get("playing") else null


static func _dpad_dir(b: int) -> Vector2:
	match b:
		JOY_BUTTON_DPAD_UP: return Vector2.UP
		JOY_BUTTON_DPAD_DOWN: return Vector2.DOWN
		JOY_BUTTON_DPAD_LEFT: return Vector2.LEFT
	return Vector2.RIGHT


# ---------------------------------------------------------- made-up events ---

func tap(key: Key) -> void:
	## A key press now and its release next frame, as if typed.
	_key(key, true)
	_release.append(key)


func _key(key: Key, down: bool, quiet := false) -> void:
	var k := InputEventKey.new()
	k.keycode = key
	k.physical_keycode = key
	k.pressed = down
	var list: Array[InputEvent] = _quiet if quiet else _mine
	list.append(k)
	if list.size() > 16:
		list.pop_front()
	Input.parse_input_event(k)


func _translate_key(k: InputEventKey) -> bool:
	## A remapped key becomes the key the game expects for that control. True when taken here.
	var phys: Key = k.physical_keycode
	var emit: int = binds.translate_key(current_mode(), phys)
	if emit == PadBindings.NOT_BOUND or emit == phys:
		return false
	if k.pressed:
		if k.echo:
			return true
		_held[phys] = emit
		_key(phys, false, true)  # the game's polling (WASD pan, Shift) sees this key let go
		if emit != KEY_NONE:
			_key(emit as Key, true)
	else:
		var out: int = _held.get(phys, KEY_NONE)
		_held.erase(phys)
		if out != KEY_NONE:
			_key(out as Key, false)
	return true


func _window_pos(p: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * p


func click(button: MouseButton, down: bool) -> void:
	var mb := InputEventMouseButton.new()
	mb.button_index = button
	mb.pressed = down
	mb.position = _window_pos(cursor)
	mb.global_position = mb.position
	mb.button_mask = _mask()
	mb.device = SYNTH
	Input.parse_input_event(mb)


func wheel(button: MouseButton, factor := 1.0) -> void:
	for down in [true, false]:
		var mb := InputEventMouseButton.new()
		mb.button_index = button
		mb.pressed = down
		mb.factor = factor
		mb.position = _window_pos(cursor)
		mb.global_position = mb.position
		mb.device = SYNTH
		Input.parse_input_event(mb)


func _mask() -> int:
	return (MOUSE_BUTTON_MASK_LEFT if _a_down else 0) | (MOUSE_BUTTON_MASK_RIGHT if _x_down else 0)


func move_cursor(to: Vector2) -> void:
	var vs := get_viewport().get_visible_rect().size
	to = to.clamp(Vector2.ZERO, vs - Vector2.ONE)
	var rel := to - cursor
	cursor = to
	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		get_viewport().warp_mouse(cursor)
	_motion(rel)


func _motion(rel: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = _window_pos(cursor)
	mm.global_position = mm.position
	mm.relative = rel
	mm.button_mask = _mask()
	mm.device = SYNTH
	Input.parse_input_event(mm)


func jump_cursor(dir: Vector2) -> void:
	## D-pad in menus: hop to the nearest button, slider or field that way.
	var best: Control = null
	var best_score := INF
	for c in _targets(get_tree().root):
		var r := c.get_global_rect()
		var to := r.get_center() - cursor
		if to.length() < 4.0:
			continue
		var along := to.dot(dir)
		if along <= 2.0:
			continue
		var across := absf(to.dot(Vector2(-dir.y, dir.x)))
		var score := along + across * 2.5
		if score < best_score:
			best_score = score
			best = c
	if best:
		move_cursor(best.get_global_rect().get_center())


func _targets(n: Node, out: Array[Control] = []) -> Array[Control]:
	if n is CanvasItem and not (n as CanvasItem).visible:
		return out
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return out
	if n is Control:
		var c := n as Control
		if (c is BaseButton and not (c as BaseButton).disabled) or c is Range and c is not ProgressBar \
				or c is LineEdit or c is ItemList or c is Tree:
			if c.mouse_filter != Control.MOUSE_FILTER_IGNORE and c.is_visible_in_tree() and c.size.x > 4.0:
				out.append(c)
	for ch in n.get_children():
		_targets(ch, out)
	return out


# ---------------------------------------------------------------- per frame ---

func _process(delta: float) -> void:
	_now += delta
	for k in _release:
		_key(k, false)
	_release.clear()
	mode = current_mode()
	if mode != &"street" and _sprint_on:
		_sprint_on = false
		Input.action_release(&"street_sprint")
	if _back_since >= 0.0 and _now - _back_since >= HOLD:
		_back_since = -1.0
		hud.open_quick()
	if not using_pad or hud.quick_open() or hud.card_open():
		return
	match mode:
		&"menu":
			_cursor_step(delta, true)
			_scroll_step(delta)
		&"mayor":
			_cursor_step(delta, false)
			_camera_step(delta)


func _stick(ax: JoyAxis, ay: JoyAxis) -> Vector2:
	var v := Vector2(Input.get_joy_axis(device, ax), Input.get_joy_axis(device, ay))
	var l := v.length()
	if l < DEAD:
		return Vector2.ZERO
	return v / l * pow(inverse_lerp(DEAD, 1.0, minf(l, 1.0)), 1.6)


func _cursor_step(delta: float, _menu: bool) -> void:
	var v := _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
	if v == Vector2.ZERO:
		return
	var speed := CURSOR_SPEED * (0.35 if _a_down and mode == &"menu" else 1.0)
	move_cursor(cursor + v * speed * delta)


func _scroll_step(delta: float) -> void:
	var v := _stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	var trig := Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)
	if absf(trig) > 0.2:
		v.y -= trig  # triggers zoom the city map like the wheel
	_scroll_acc += v * delta * 12.0
	while absf(_scroll_acc.y) >= 1.0:
		wheel(MOUSE_BUTTON_WHEEL_DOWN if _scroll_acc.y > 0.0 else MOUSE_BUTTON_WHEEL_UP)
		_scroll_acc.y -= signf(_scroll_acc.y)
	if v.y == 0.0:
		_scroll_acc.y = 0.0


func _camera_step(delta: float) -> void:
	var cam = main.get("cam")
	if cam == null or cam.get("_focus_goal") == null:
		return
	var moved := false
	var fast := 2.5 if Input.is_joy_button_pressed(device, binds.physical(JOY_BUTTON_LEFT_STICK)) else 1.0
	var r3 := Input.is_joy_button_pressed(device, binds.physical(JOY_BUTTON_RIGHT_STICK))
	# Pan: right stick, or the cursor pushed into the screen edge.
	var pan := _stick(binds.pan_axis, (binds.pan_axis + 1) as JoyAxis)
	var vs := get_viewport().get_visible_rect().size
	var ls := _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
	if ls != Vector2.ZERO:
		if (cursor.x <= EDGE and ls.x < 0.0) or (cursor.x >= vs.x - 1.0 - EDGE and ls.x > 0.0):
			pan.x += ls.x
		if (cursor.y <= EDGE and ls.y < 0.0) or (cursor.y >= vs.y - 1.0 - EDGE and ls.y > 0.0):
			pan.y += ls.y
	if r3:
		pan.y = 0.0  # held R3: the right stick's up and down tilt instead
	if pan != Vector2.ZERO:
		var yaw: float = cam._yaw_goal
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
		var right := Vector3(cos(yaw), 0, -sin(yaw))
		cam._focus_goal += (right * pan.x - fwd * pan.y) * float(cam._dist_goal) * 1.1 * fast * delta
		moved = true
	# Zoom: right trigger in, left trigger out.
	var z := Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT) - Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)
	if absf(z) > 0.12:
		cam._dist_goal = clampf(float(cam._dist_goal) * (1.0 - z * delta * 1.6), MayorCamera.MIN_DIST, MayorCamera.MAX_DIST)
		moved = true
	# Rotate: bumpers.
	var rot := float(Input.is_joy_button_pressed(device, binds.physical(JOY_BUTTON_LEFT_SHOULDER))) \
		- float(Input.is_joy_button_pressed(device, binds.physical(JOY_BUTTON_RIGHT_SHOULDER)))
	if rot != 0.0:
		cam._yaw_goal += rot * delta * 1.6
		moved = true
	# Tilt: hold R3 and push the right stick up or down. A plain tap of R3 levels the camera.
	if r3:
		var ty := Input.get_joy_axis(device, (binds.pan_axis + 1) as JoyAxis)
		if absf(ty) > DEAD:
			cam._tilt_goal = clampf(float(cam._tilt_goal) - ty * delta * 1.2, -0.35, 0.5)
			_r3_tilted = true
			moved = true
	elif _r3_down and not _r3_tilted and absf(float(cam._tilt_goal)) > 0.001:
		cam._tilt_goal = 0.0
		moved = true
	if not r3:
		_r3_tilted = false
	_r3_down = r3
	if moved:
		_motion(Vector2.ZERO)  # the ground under the cursor changed: update the build preview


# ------------------------------------------------------------------- rumble ---

func _hook_rumble() -> void:
	var st = main.get("street") if main else null
	if st == null:
		return
	if st.has_signal("vehicle_changed"):
		st.vehicle_changed.connect(_on_vehicle)
	var pl = st.get("player")
	if pl and pl.has_signal("damaged"):
		pl.damaged.connect(func(amount: float, _from: Vector3) -> void:
			rumble(clampf(amount / 40.0, 0.25, 1.0), 0.18))
	if st.has_signal("wasted"):
		st.wasted.connect(func() -> void: rumble(1.0, 0.6))


func _on_vehicle(car) -> void:
	if car and car.has_signal("crashed") and not car.crashed.is_connected(_on_crash):
		car.crashed.connect(_on_crash)


func _on_crash(strength: float) -> void:
	if driving():
		rumble(clampf(strength, 0.2, 1.0), 0.12 + strength * 0.25)


func rumble(strength: float, seconds: float) -> void:
	if vibration and using_pad:
		Input.start_joy_vibration(device, strength * 0.6, strength, seconds)
