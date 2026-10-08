class_name PadGlyphs
extends RefCounted
## Which controller is plugged in, and what each button is called on it.
## Godot names buttons by position (JOY_BUTTON_A is always the bottom face button), so one
## layout works for every pad; only the printed labels and colours differ.

enum Family { XBOX, PLAYSTATION, NINTENDO }

const FAMILY_NAMES := ["Xbox", "PlayStation", "Nintendo"]

const SONY := 0x054C
const NINTENDO := 0x057E
const MICROSOFT := 0x045E

# Pseudo buttons for the sticks and triggers, after the real JOY_BUTTON_* range.
const LS := 100        # left stick (move)
const RS := 101        # right stick (look)
const LT := 102
const RT := 103
const DPAD := 104      # the whole d-pad
const LB_RB := 105     # both bumpers
const LT_RT := 106     # both triggers

# Per family: button -> label. Face buttons by position: A bottom, B right, X left, Y top.
const LABELS := {
	Family.XBOX: {
		JOY_BUTTON_A: "A", JOY_BUTTON_B: "B", JOY_BUTTON_X: "X", JOY_BUTTON_Y: "Y",
		JOY_BUTTON_LEFT_SHOULDER: "LB", JOY_BUTTON_RIGHT_SHOULDER: "RB", LT: "LT", RT: "RT",
		JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", LS: "L", RS: "R",
		JOY_BUTTON_BACK: "View", JOY_BUTTON_START: "Menu", LB_RB: "LB RB", LT_RT: "LT RT",
	},
	Family.PLAYSTATION: {
		JOY_BUTTON_A: "Cross", JOY_BUTTON_B: "Circle", JOY_BUTTON_X: "Square", JOY_BUTTON_Y: "Triangle",
		JOY_BUTTON_LEFT_SHOULDER: "L1", JOY_BUTTON_RIGHT_SHOULDER: "R1", LT: "L2", RT: "R2",
		JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", LS: "L", RS: "R",
		JOY_BUTTON_BACK: "Create", JOY_BUTTON_START: "Options", LB_RB: "L1 R1", LT_RT: "L2 R2",
	},
	Family.NINTENDO: {
		JOY_BUTTON_A: "B", JOY_BUTTON_B: "A", JOY_BUTTON_X: "Y", JOY_BUTTON_Y: "X",
		JOY_BUTTON_LEFT_SHOULDER: "L", JOY_BUTTON_RIGHT_SHOULDER: "R", LT: "ZL", RT: "ZR",
		JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", LS: "L", RS: "R",
		JOY_BUTTON_BACK: "-", JOY_BUTTON_START: "+", LB_RB: "L R", LT_RT: "ZL ZR",
	},
}

const DPAD_NAMES := {
	JOY_BUTTON_DPAD_UP: "Up", JOY_BUTTON_DPAD_DOWN: "Down",
	JOY_BUTTON_DPAD_LEFT: "Left", JOY_BUTTON_DPAD_RIGHT: "Right",
}

# Face button colours by position, for Xbox; PlayStation symbols carry their own colours.
const XBOX_COLORS := {
	JOY_BUTTON_A: Color(0.36, 0.72, 0.25), JOY_BUTTON_B: Color(0.86, 0.22, 0.2),
	JOY_BUTTON_X: Color(0.2, 0.47, 0.9), JOY_BUTTON_Y: Color(0.95, 0.72, 0.1),
}
const PS_COLORS := {
	JOY_BUTTON_A: Color(0.45, 0.62, 0.95), JOY_BUTTON_B: Color(0.95, 0.35, 0.38),
	JOY_BUTTON_X: Color(0.88, 0.5, 0.82), JOY_BUTTON_Y: Color(0.3, 0.82, 0.68),
}


static func detect(device: int) -> Family:
	## Family from the controller's name, then its USB/Bluetooth vendor id. Unknown pads get
	## Xbox labels, since Windows and SDL map them to that layout.
	if device < 0:
		return Family.XBOX
	return from_name(Input.get_joy_name(device), Input.get_joy_info(device))


static func from_name(name: String, info := {}) -> Family:
	var n := name.to_lower()
	for w in ["dualsense", "dualshock", "playstation", "ps3", "ps4", "ps5", "sony", "wireless controller"]:
		if w in n:
			return Family.PLAYSTATION
	for w in ["nintendo", "switch", "pro controller", "joy-con", "joycon"]:
		if w in n:
			return Family.NINTENDO
	for w in ["xbox", "xinput", "microsoft", "x-box"]:
		if w in n:
			return Family.XBOX
	var vendor := int(str(info.get("vendor_id", "0")))
	if vendor == SONY:
		return Family.PLAYSTATION
	if vendor == NINTENDO:
		return Family.NINTENDO
	return Family.XBOX


static func label(family: int, button: int) -> String:
	if DPAD_NAMES.has(button):
		return "D-pad " + DPAD_NAMES[button].to_lower()
	if button == DPAD:
		return "D-pad"
	return LABELS[family].get(button, "?")


static func color(family: int, button: int) -> Color:
	var table: Dictionary = PS_COLORS if family == Family.PLAYSTATION else XBOX_COLORS
	if family == Family.NINTENDO:
		return Color(0.82, 0.84, 0.88)
	return table.get(button, Color(0.82, 0.84, 0.88))


static func is_face(button: int) -> bool:
	return button in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y]
