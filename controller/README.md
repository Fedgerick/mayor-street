# Controller (gamepad) support

Full game controls on any pad Windows knows: Xbox, PlayStation (DualShock 4, DualSense),
Nintendo Switch Pro and most generic Bluetooth pads (SDL's mapping database, built into Godot 4.5).
The layout is Xbox style by button position; prompts show the right icons for the pad in hand
(auto-detected from its name and vendor id, or picked in the quick menu).

## Files

- `pad_controls.gd` (PadControls): reads the pad and turns it into what the game already
  understands: the street's own `street_*` actions (player/scripts/street_input.gd), plus made-up
  keys and clicks for everything else. No other folder needs to change.
- `pad_hud.gd` (PadHud): button prompts, the pointer ring, the quick menu and the layout card.
- `pad_glyphs.gd` (PadGlyphs): pad family detection and button names.
- `pad_glyph.gd` (PadGlyph): draws one button icon (no image files).
- `tests/controller_test.gd`: drives the real main scene with pad presses.

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
