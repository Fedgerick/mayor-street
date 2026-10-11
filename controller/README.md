# Controller (gamepad) support

Full game controls on any pad Windows knows: Xbox, PlayStation (DualShock 4, DualSense),
Nintendo Switch Pro, Google Stadia and most generic Bluetooth pads (SDL's mapping database, built into Godot 4.5).
The layout is Xbox style by button position; prompts show the right icons for the pad in hand
(auto-detected from its name and vendor id, or picked in the quick menu).

## Files

- `pad_controls.gd` (PadControls): reads the pad and turns it into what the game already
  understands: the street's own `street_*` actions (player/scripts/street_input.gd), plus made-up
  keys and clicks for everything else. No other folder needs to change.
- `pad_hud.gd` (PadHud): button prompts, the pointer ring, the quick menu and the layout card.
- `pad_glyphs.gd` (PadGlyphs): pad family detection and button names.
- `pad_glyph.gd` (PadGlyph): draws one button icon (no image files).
- `pad_bindings.gd` (PadBindings): every remappable key and pad button, the swap rules, and
  what they do to the game's InputMap. Saved in `user://controller.cfg`.
- `remap_screen.gd` (RemapScreen): the controls screen, opened from the layout card's
  "Change buttons and keys" button.
- `tests/controller_test.gd`: drives the real main scene with pad presses.
- `tests/remap_test.gd`: remap rules and saved bindings, no scene.
- `tests/remap_scene_test.gd`: remapped keys and buttons in the real main scene.

## Remapping

Everything in the Mayor view and on foot/driving can be changed (Pad buttons, and the
keys on the Mayor view, Foot and driving, Anywhere tabs). Pick a row, then press the new key or
button. Whatever used that key before moves to the old one, so two controls never share a key.

Two ways a remap reaches the game, because the game reads its keys in two ways:
- Keys the game checks by hand (the mayor's pan and tools, the quest log, the map, the
  bribe and job keys): PadControls turns a press of the new key into the key the game expects,
  and clears the old key so the game's polling doesn't see it held.
- InputMap actions (the street's controls, the car radio): their keys are rebound in the
  InputMap itself. Secondary keys that aren't on the screen (arrow keys for walking) stay.

Pad buttons: each physical button is given the role it plays (A, B, X, Y, the bumpers, the
stick clicks, View). The street's InputMap is rebound to the physical buttons, so both paths
agree. Start always opens the Esc menu, and the d-pad always moves between buttons.

Not remapped: the mouse, the sticks and triggers, arrow keys, Esc, the number keys in menus,
and the keys the game shows as hints on screen (those hints still show the default keys).

## Wiring (main.gd)

```gdscript
var pad: PadControls  # gamepad controls and prompts (controller/)
...
# in _start, after menu, street, missions, nav and resident exist:
pad = PadControls.new()
add_child(pad)
pad.setup(self)
```

PadControls moves itself to the end of main's children so its `_input` runs first.
Settings (icons, vibration) are in `user://controller.cfg`.

Optional, for the Esc menu's controls list: a "Controller layout" button calling
`pad.hud.open_card()`.

## Layout

| | Mayor view | On foot | Driving | Menus |
|---|---|---|---|---|
| Left stick | Pointer (edge scrolls) | Walk | Steer | Pointer |
| Right stick | Pan | Look | Look | Scroll / zoom map |
| A | Select, place, hold + drag to zone | Jump | Handbrake | Click (hold to drag) |
| B | Drop tool / close build menu | Take job, bribe, close quest log | same | Back (Esc) |
| X | Build menu | Reload | Flip car | Right-click |
| Y | Next overlay | Enter car or building, carjack | Get out | |
| LB / RB | Rotate | Horn / next weapon | Horn / | Scroll |
| LT / RT | Zoom out / in | Aim / attack | Brake / gas | Zoom map |
| L3 | Hold: fast pan | Run | | |
| R3 | Level camera | | | |
| D-pad | Left/right tools, up/down speed | Up radio, left last weapon, right quests, down map | same | Jump to next button |
| View / Back | Tap: street, hold: quick menu | Tap: mayor, hold: quick menu | same | |
| Start | Pause menu | Pause menu | Pause menu | Close menu |

Quick menu (hold View): take a job or bribe, quest log, city map, black market buys and crew
(with those perks), give up a job, pause or skip an hour (mayor), music, controller layout,
button icons, vibration.

Rumble on hits, crashes and Wasted.

## Cost

`_process` only runs while a pad is connected: a few axis reads per frame. Prompts rebuild
only when the mode, pad or context changes (checked 5 times a second). The d-pad button search
walks the GUI tree only on a press in a menu.

## Known limits

- Typing a name in the character creator needs the keyboard (Godot has no on-screen keyboard
  on Windows); the creator's random button works with A.
- Quest log story-job replays (keys 1-9) are keyboard only.
- A pad Windows reports with no mapping at all (rare cheap clones) shows up as raw buttons.
