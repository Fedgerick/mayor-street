class_name KeyClick
extends RefCounted
## Reading key hints ("Tab  Walk the streets", "E  get in", "B build menu · J quest log")
## and pressing the key they name, so a click on a hint does what the hint says.

## Keys that mean something held or a mouse move: a click can't stand in for them.
const NOT_CLICKABLE := ["wasd", "shift", "click", "mouse", "wheel", "arrows", "right-click", "right-drag",
	"middle-drag", "ctrl", "alt"]

static var _cache := {}  # text -> parsed lines


## The key a key field names: "Tab", "7 / B", "E or F", "Space  ,  .", "F11". KEY_NONE when
## it is a held key, a mouse action or several keys pressed together ("W S", "Q E", "1 to 6").
static func key_of(field: String) -> Key:
	var s := field.strip_edges()
	if s == "":
		return KEY_NONE
	var first := s.split("/", false)[0].strip_edges()
	first = first.split(" or ", false)[0].strip_edges()
	var parts := first.split("  ", false)  # "Space  ,  ." lists separate keys
	first = parts[0].strip_edges() if parts.size() > 0 else ""
	if first.contains(" ") or first == "":
		return KEY_NONE
	return key_named(first)


static func key_named(name: String) -> Key:
	var n := name.to_lower()
	if n in NOT_CLICKABLE:
		return KEY_NONE
	match n:
		"tab": return KEY_TAB
		"esc", "escape": return KEY_ESCAPE
		"space": return KEY_SPACE
		"enter", "return": return KEY_ENTER
		",": return KEY_COMMA
		".": return KEY_PERIOD
	if n.length() == 1:
		var c := n.unicode_at(0)
		if c >= 97 and c <= 122:  # a..z
			return (KEY_A + (c - 97)) as Key
		if c >= 48 and c <= 57:  # 0..9
			return (KEY_0 + (c - 48)) as Key
	if n.length() >= 2 and n[0] == "f" and n.substr(1).is_valid_int():
		var f := n.substr(1).to_int()
		if f >= 1 and f <= 12:
			return (KEY_F1 + f - 1) as Key
	return KEY_NONE


## A hint line split into the parts a click can land on: [{from, to, key}] in characters.
## Strict lines need two spaces after the key ("E  get in"); loose ones (the mayor HUD help)
## take "Space pause · N skip 1 hour".
static func parse_line(line: String, loose: bool) -> Array:
	var ck := line + ("|L" if loose else "|S")
	if _cache.has(ck):
		return _cache[ck]
	var out := []
	var at := 0
	for seg in line.split(" · "):
		var body := seg.strip_edges(true, false)
		var lead := seg.length() - body.length()
		var key := KEY_NONE
		var gap := body.find("  ")
		if gap > 0:
			key = key_of(body.substr(0, gap))
		elif loose:
			var sp := body.find(" ")
			if sp > 0:
				key = key_of(body.substr(0, sp))
		if key != KEY_NONE:
			out.append({"from": at + lead, "to": at + seg.length(), "key": key})
		at += seg.length() + 3
	if _cache.size() > 2000:
		_cache.clear()
	_cache[ck] = out
	return out


## Press and let go of a key as if typed. Device 0, so InputMap actions such as
## street_toggle_view on Tab match it.
static func press(key: Key, tree: SceneTree) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = true
	e.device = 0
	Input.parse_input_event(e)
	var up := e.duplicate() as InputEventKey
	up.pressed = false
	# Let go a few frames later, so code that polls "just pressed" sees the press.
	tree.create_timer(0.08, true, false, true).timeout.connect(func(): Input.parse_input_event(up))
