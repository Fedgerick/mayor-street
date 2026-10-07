class_name StreetInput
extends RefCounted
## Registers the street-level input actions at runtime, so the player folder works
## without edits to project.godot. Every action is prefixed "street_" to stay clear of
## the mayor view's controls. Keyboard + mouse and a standard gamepad are both mapped.

const KEYS := {
	"street_forward": [KEY_W, KEY_UP],
	"street_back": [KEY_S, KEY_DOWN],
	"street_left": [KEY_A, KEY_LEFT],
	"street_right": [KEY_D, KEY_RIGHT],
	"street_sprint": [KEY_SHIFT],
	"street_jump": [KEY_SPACE],
	"street_handbrake": [KEY_SPACE],
	"street_interact": [KEY_E, KEY_F],
	"street_toggle_view": [KEY_TAB],
	"street_reset": [KEY_R],
	"street_reload": [KEY_R],     # on foot; R flips the car back over when driving
	"street_horn": [KEY_H],
	"street_lights": [KEY_L],
	"street_next_weapon": [KEY_Q],
	"street_weapon_1": [KEY_1],
	"street_weapon_2": [KEY_2],
	"street_weapon_3": [KEY_3],
}

const MOUSE := {
	"street_fire": [MOUSE_BUTTON_LEFT],
	"street_aim": [MOUSE_BUTTON_RIGHT],
	"street_next_weapon": [MOUSE_BUTTON_WHEEL_UP],
	"street_prev_weapon": [MOUSE_BUTTON_WHEEL_DOWN],
}

const BUTTONS := {
	"street_jump": [JOY_BUTTON_A],
	"street_handbrake": [JOY_BUTTON_A],
	"street_interact": [JOY_BUTTON_Y],
	"street_sprint": [JOY_BUTTON_LEFT_STICK],
	"street_toggle_view": [JOY_BUTTON_BACK],
	"street_reset": [JOY_BUTTON_X],
	"street_reload": [JOY_BUTTON_X],
	"street_horn": [JOY_BUTTON_LEFT_SHOULDER],
	"street_next_weapon": [JOY_BUTTON_RIGHT_SHOULDER],
	"street_prev_weapon": [JOY_BUTTON_DPAD_LEFT],
}

# action: [axis, sign]
const AXES := {
	"street_forward": [JOY_AXIS_LEFT_Y, -1.0],
	"street_back": [JOY_AXIS_LEFT_Y, 1.0],
	"street_left": [JOY_AXIS_LEFT_X, -1.0],
	"street_right": [JOY_AXIS_LEFT_X, 1.0],
	"street_throttle": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"street_brake": [JOY_AXIS_TRIGGER_LEFT, 1.0],
	"street_fire": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
	"street_aim": [JOY_AXIS_TRIGGER_LEFT, 1.0],
}

static var _done := false


static func ensure() -> void:
	if _done:
		return
	_done = true
	for action in KEYS:
		_add(action)
		for k in KEYS[action]:
			var e := InputEventKey.new()
			e.physical_keycode = k
			InputMap.action_add_event(action, e)
	for action in BUTTONS:
		_add(action)
		for b in BUTTONS[action]:
			var e := InputEventJoypadButton.new()
			e.button_index = b
			InputMap.action_add_event(action, e)
	for action in MOUSE:
		_add(action)
		for b in MOUSE[action]:
			var e := InputEventMouseButton.new()
			e.button_index = b
			InputMap.action_add_event(action, e)
	for action in AXES:
		_add(action)
		var e := InputEventJoypadMotion.new()
		e.axis = AXES[action][0]
		e.axis_value = AXES[action][1]
		InputMap.action_add_event(action, e)


static func _add(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)


static func move_vector() -> Vector2:
	## x = right, y = forward. Length is at most 1.
	return Input.get_vector("street_left", "street_right", "street_back", "street_forward")


static func look_stick() -> Vector2:
	var v := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	return v if v.length() > 0.15 else Vector2.ZERO
