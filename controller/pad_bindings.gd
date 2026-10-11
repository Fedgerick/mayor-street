class_name PadBindings
extends RefCounted
## Which key or pad button each remappable control uses. Saved in user://controller.cfg.
##
## Two kinds of key row:
## - Read by the game's own key checks (mayor pan, missions, the map). PadControls turns a
##   press of the bound key into the default key the game expects (pad_controls.gd).
## - An InputMap action (the street's own input, the car radio). Its keys are rebound in the
##   InputMap itself (apply_input_map), so the street code needs no change.
## Each mode's rows are a swap: binding a key that another row uses gives that row the old key.
## The pad works the same way: each button is given the role (the Xbox name it plays by default).

const NOT_BOUND := -1  # translate_key: the key is not remapped, pass it through

## Keyboard rows: [id, label, default key, InputMap actions (empty when the game reads the key)].
const ROWS := {
	&"global": [
		[&"music", "Music", KEY_M, []],
		[&"view", "Street / mayor view", KEY_TAB, ["street_toggle_view"]],
	],
	&"mayor": [
		[&"pan_up", "Pan up", KEY_W, []],
		[&"pan_left", "Pan left", KEY_A, []],
		[&"pan_down", "Pan down", KEY_S, []],
		[&"pan_right", "Pan right", KEY_D, []],
		[&"rotate_left", "Rotate left", KEY_Q, []],
		[&"rotate_right", "Rotate right", KEY_E, []],
		[&"zoom_in", "Zoom in", KEY_PAGEUP, []],
		[&"zoom_out", "Zoom out", KEY_PAGEDOWN, []],
		[&"fast", "Faster pan (hold)", KEY_SHIFT, []],
		[&"tool_1", "Inspect tool", KEY_1, []],
		[&"tool_2", "Road tool", KEY_2, []],
		[&"tool_3", "Residential zone", KEY_3, []],
		[&"tool_4", "Commercial zone", KEY_4, []],
		[&"tool_5", "Industrial zone", KEY_5, []],
		[&"tool_6", "Bulldoze", KEY_6, []],
		[&"build", "Build menu", KEY_B, []],
		[&"overlay", "Next overlay", KEY_O, []],
		[&"faster", "City speed up", KEY_PERIOD, []],
		[&"slower", "City speed down, pause", KEY_COMMA, []],
		[&"pause", "Pause", KEY_SPACE, []],
	],
	&"street": [
		[&"forward", "Forward", KEY_W, ["street_forward"]],
		[&"back", "Back", KEY_S, ["street_back"]],
		[&"left", "Left", KEY_A, ["street_left"]],
		[&"right", "Right", KEY_D, ["street_right"]],
		[&"sprint", "Sprint", KEY_SHIFT, ["street_sprint"]],
		[&"jump", "Jump, handbrake", KEY_SPACE, ["street_jump", "street_handbrake"]],
		[&"interact", "Enter, carjack, get out", KEY_E, ["street_interact"]],
		[&"reload", "Reload, flip the car", KEY_R, ["street_reset", "street_reload"]],
		[&"horn", "Horn", KEY_H, ["street_horn"]],
		[&"lights", "Headlights", KEY_L, ["street_lights"]],
		[&"weapon_next", "Next weapon", KEY_Q, ["street_next_weapon"]],
		[&"weapon_1", "Weapon 1", KEY_1, ["street_weapon_1"]],
		[&"weapon_2", "Weapon 2", KEY_2, ["street_weapon_2"]],
		[&"weapon_3", "Weapon 3", KEY_3, ["street_weapon_3"]],
		[&"radio", "Car radio", KEY_C, ["audio_radio_next"]],
		[&"quests", "Quest log", KEY_J, []],
		[&"map", "City map", KEY_V, []],
		[&"bribe", "Bribe a cop", KEY_B, []],
		[&"job", "Take a job", KEY_Y, []],
		[&"crew", "Crew backup (perk)", KEY_G, []],
	],
}

## Pad rows: the buttons that can change role. Start always opens the Esc menu.
const PAD := [
	JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y,
	JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK,
	JOY_BUTTON_BACK,
]

const PAD_ROLE_NAMES := {
	JOY_BUTTON_A: "Select, jump, handbrake",
	JOY_BUTTON_B: "Back, take a job, bribe",
	JOY_BUTTON_X: "Build menu, reload, flip the car",
	JOY_BUTTON_Y: "Next overlay, enter, get out",
	JOY_BUTTON_LEFT_SHOULDER: "Rotate (mayor), horn (street)",
	JOY_BUTTON_RIGHT_SHOULDER: "Rotate (mayor), next weapon",
	JOY_BUTTON_LEFT_STICK: "Faster pan, run",
	JOY_BUTTON_RIGHT_STICK: "Level the camera",
	JOY_BUTTON_BACK: "Street / mayor view, quick menu",
}

var keys := {}  # mode -> {row id -> bound key}
var pad := {}   # role button -> the physical button it is on
var _installed := {}  # InputMap action -> key currently installed for it


func _init() -> void:
	reset()


func reset() -> void:
	keys.clear()
	for mode in ROWS:
		var m := {}
		for row in ROWS[mode]:
			m[row[0]] = row[2]
		keys[mode] = m
	pad.clear()
	for b in PAD:
		pad[b] = b


static func default_key(mode: StringName, id: StringName) -> int:
	for row in ROWS.get(mode, []):
		if row[0] == id:
			return row[2]
	return KEY_NONE


static func row_of(mode: StringName, id: StringName) -> Array:
	for row in ROWS.get(mode, []):
		if row[0] == id:
			return row
	return []


func bound_key(mode: StringName, id: StringName) -> int:
	return keys.get(mode, {}).get(id, KEY_NONE)


## Bind a row to a key. A key another row uses goes to that row (a swap).
func set_key(mode: StringName, id: StringName, key: int) -> void:
	var m: Dictionary = keys[mode]
	for other in m:
		if other != id and m[other] == key:
			m[other] = m[id]
			break
	m[id] = key
	apply_input_map()


## What the game should be given for a physical key in this mode: the default key of the
## row bound to it. NOT_BOUND when the key is not one of ours; KEY_NONE drops the press
## (its default row was moved away and nothing else took it).
func translate_key(mode: StringName, physical: int) -> int:
	for set_name in [&"global", mode]:
		var m: Dictionary = keys.get(set_name, {})
		for id in m:
			if m[id] == physical:
				var row := row_of(set_name, id)
				return row[2] if row[3].is_empty() else NOT_BOUND
	for set_name in [&"global", mode]:
		for row in ROWS.get(set_name, []):
			if row[2] == physical and row[3].is_empty():
				return KEY_NONE
	return NOT_BOUND


## The role (the default button) a physical pad button currently plays.
func role_of(physical: int) -> int:
	for role in pad:
		if pad[role] == physical:
			return role
	return physical


## The physical button a role is on now.
func physical(role: int) -> int:
	return pad.get(role, role)


func set_pad(role: int, physical_button: int) -> void:
	for other in pad:
		if other != role and pad[other] == physical_button:
			pad[other] = pad[role]
			break
	pad[role] = physical_button
	apply_input_map()


## Rebinds the InputMap actions used by the street and the car radio.
func apply_input_map() -> void:
	StreetInput.ensure()
	for mode in ROWS:
		for row in ROWS[mode]:
			var actions: Array = row[3]
			for action in actions:
				_set_key_action(action, row[2], bound_key(mode, row[0]))
	for action in StreetInput.BUTTONS:
		_set_pad_action(action)


const EXTRA_PAD := {"audio_radio_next": JOY_BUTTON_DPAD_UP}  # actions made here, with their pad button


func _set_key_action(action: String, default_key: int, key: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
		if EXTRA_PAD.has(action):
			var j := InputEventJoypadButton.new()
			j.button_index = EXTRA_PAD[action]
			InputMap.action_add_event(action, j)
	var was: int = _installed.get(action, default_key)
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and ((ev as InputEventKey).physical_keycode == was or (ev as InputEventKey).physical_keycode == default_key):
			InputMap.action_erase_event(action, ev)
	var e := InputEventKey.new()
	e.physical_keycode = key as Key
	InputMap.action_add_event(action, e)
	_installed[action] = key


func _set_pad_action(action: String) -> void:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			InputMap.action_erase_event(action, ev)
	for b in StreetInput.BUTTONS[action]:
		var e := InputEventJoypadButton.new()
		e.button_index = physical(b) as JoyButton
		InputMap.action_add_event(action, e)


func save_to(cf: ConfigFile) -> void:
	for mode in keys:
		for id in keys[mode]:
			cf.set_value("keys", "%s.%s" % [mode, id], keys[mode][id])
	for role in pad:
		cf.set_value("pad_buttons", str(role), pad[role])


func load_from(cf: ConfigFile) -> void:
	reset()
	for mode in keys:
		for id in keys[mode]:
			var k: int = int(cf.get_value("keys", "%s.%s" % [mode, id], keys[mode][id]))
			keys[mode][id] = k
	for role in pad.keys():
		pad[role] = int(cf.get_value("pad_buttons", str(role), role))
	apply_input_map()
