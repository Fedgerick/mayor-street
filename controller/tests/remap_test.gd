extends SceneTree
## Remapping rules (PadBindings) and what they do to the game's input map. No scene needed.
##   godot --headless --path . --fixed-fps 60 --script res://controller/tests/remap_test.gd

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		print("  FAIL ", what)
		failures += 1


func _initialize() -> void:
	print("Remap tests")
	var b := PadBindings.new()

	# Keys read by the game: a bound key is translated to the default the game expects.
	check(b.translate_key(&"mayor", KEY_W) == KEY_W, "mayor W is pan up by default")
	check(b.translate_key(&"mayor", KEY_T) == PadBindings.NOT_BOUND, "an unused key passes through")

	b.set_key(&"mayor", &"pan_up", KEY_I)
	check(b.translate_key(&"mayor", KEY_I) == KEY_W, "I now pans up (gives the game W)")
	check(b.translate_key(&"mayor", KEY_W) == KEY_NONE, "W is dropped once pan up moved away")

	# Swaps: binding a key used by another row gives that row the old key.
	b.set_key(&"mayor", &"build", KEY_O)
	check(b.bound_key(&"mayor", &"overlay") == KEY_B, "binding B to build swapped overlay onto B")
	check(b.translate_key(&"mayor", KEY_B) == KEY_O, "B now opens the overlay (gives O)")
	check(b.translate_key(&"mayor", KEY_O) == KEY_B, "O now builds (gives B)")

	# Action rows (InputMap) pass through the translator: their keys are rebound in the InputMap.
	check(b.translate_key(&"street", KEY_SPACE) == PadBindings.NOT_BOUND, "street jump is left to the InputMap")
	b.set_key(&"street", &"jump", KEY_X)
	check(InputMap.action_has_event("street_jump", _key_event(KEY_X)), "street_jump now has X")
	check(not InputMap.action_has_event("street_jump", _key_event(KEY_SPACE)), "street_jump no longer has Space")
	check(InputMap.action_has_event("street_handbrake", _key_event(KEY_X)), "handbrake shares the jump key")
	check(InputMap.action_has_event("street_forward", _key_event(KEY_UP)), "unbound secondary keys stay (arrow up)")

	# Pad: roles follow the physical button they are moved to.
	var p := PadBindings.new()
	check(p.role_of(JOY_BUTTON_Y) == JOY_BUTTON_Y, "Y plays Y by default")
	p.set_pad(JOY_BUTTON_A, JOY_BUTTON_Y)
	check(p.role_of(JOY_BUTTON_Y) == JOY_BUTTON_A, "the Y button now plays A")
	check(p.role_of(JOY_BUTTON_A) == JOY_BUTTON_Y, "the A button was swapped onto Y's role")
	check(p.physical(JOY_BUTTON_A) == JOY_BUTTON_Y, "physical(A) is Y")
	check(p.role_of(JOY_BUTTON_START) == JOY_BUTTON_START, "Start is never remapped")

	# Saved bindings come back as they were.
	var cf := ConfigFile.new()
	b.save_to(cf)
	p.save_to(cf)
	var c := PadBindings.new()
	c.load_from(cf)
	check(c.bound_key(&"mayor", &"build") == KEY_B, "a saved key comes back")
	check(c.physical(JOY_BUTTON_A) == JOY_BUTTON_Y, "a saved pad button comes back")

	b.reset()
	check(b.bound_key(&"mayor", &"build") == KEY_B and b.translate_key(&"mayor", KEY_W) == KEY_W, "reset restores the defaults")

	print("FAILED %d" % failures if failures else "ALL PASSED")
	quit(1 if failures else 0)


func _key_event(k: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = k
	return e
