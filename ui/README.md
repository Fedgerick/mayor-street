# ui/ — clickable screen text and the City history charts

Everything on screen that isn't part of the 3D world can be clicked:

- **Key hints press their key.** The corner hint (`[Tab] Walk the streets`, `[Esc] Menu`),
  the mayor HUD help lines (`Space pause · N skip 1 hour`, each half on its own), the Esc
  menu's key tables (the menu closes, then the key goes to the game), and labels such as
  `E  get in` or `E  Go inside`. Held keys and mouse actions (WASD, Shift, wheel, Click,
  `1 to 6`) are left alone. The key is typed the same way PadControls types its keys
  (`Input.parse_input_event`, device 0).
- **Mayor HUD numbers.** The R C I demand bars open **City history** on its Zones page,
  population and jobs open People, funds and per day open Money, the city name and tier open
  the build menu (B), the clock pauses or restarts time (Space).
- **City services lines** switch their overlay (Power, Garbage, Crime, Happiness).
- **The minimap** opens the city map, whenever the cursor is shown.

Hovering anything clickable brightens it and shows a hand cursor. A click only counts where
that thing is really on top (not under the Esc menu or another window) and while the mouse
cursor is shown, so street-level aiming is never affected. It reads the existing nodes at run
time; no other folder changed.

## City history (`CityCharts`, `CityHistory`)

One snapshot per game day (`City.day_passed`): for residential, commercial and industrial,
how many buildings stand at each growth stage — **light** (stage 1), **medium** (stage 2),
**heavy** (stage 3, and the 2x2 towers) — plus population, jobs, funds and the day's income
and upkeep. Catalog buildings (services, specials) are left out. Saved in the
`city_history` section; a save from before this starts its history on the day it loads.
After 400 days the older half is thinned to every other day.

Pages: Zones (three stacked charts), People (lines), Money (funds line and daily net bars).
Hover reads out that day. Esc, Close or a click outside closes it.

## Wiring

One line in `main._ready`, after `pad.setup(self)`:

    ClickableUI.install(self)

It hooks the HUD at once and the rest (history, services panel, minimap) on
`Progress.game_started`.

## Tests

    godot --headless --path . --fixed-fps 60 --script res://ui/tests/clickable_test.gd
    xvfb-run godot --rendering-driver vulkan --path . --script res://ui/tests/chart_shots.gd -- --out=DIR

Both install their own ClickableUI when main.gd hasn't yet.
