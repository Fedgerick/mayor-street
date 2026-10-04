# creator/: character creation, home and wardrobe

Owned by the "Character creation and home" thread. main.gd and the builds belong to the
City sandbox thread, which wires this in.

## Wiring into main.gd

In `_start(demo)`, after StreetMode is created and set up:

```gdscript
var resident: Resident   # with the other members

resident = Resident.new()
resident.name = "Resident"
add_child(resident)
resident.setup(city, street, cam)     # registers Progress section "resident"; a load fills it here
resident.use_interiors(interiors)     # after InteriorManager.setup: door on the home, wardrobe + save spots inside
if not resident.profile.loaded and not (_args.has("screenshot") or _args.has("shots") or _args.has("street")):
	await resident.new_game()         # creator screen, $500 start cash, then pick a home on the map
```

That is all that is required. The creator covers the screen and eats input until Done, but
the city keeps ticking behind it, so you may want speed 0 until it returns. The look-dev and
screenshot flags skip it.

Optional:
- `resident.open_wardrobe()` from a HUD button, and `resident.pick_home()` to move.
- Going to the street the first time: `street.enter_street(cam, resident.home.door_position())`
  starts you outside your home (check `resident.profile.has_home()` first).
- Wasted respawn (player/): `resident.respawn_point()` is a Transform3D outside the front
  door, facing the street; its origin is INF when there is no home.
- `resident.home_entered` fires when the player walks into the home room (interiors/
  "home"). It already calls `Progress.autosave()`. Inside, E at M_wardrobe opens the
  wardrobe and E at M_save saves. Without `use_interiors`, E at a glowing front door opens
  a small home menu (wardrobe, move home, leave) instead.

## What's in here

| File | Class | What |
|---|---|---|
| scripts/character_look.gd | CharacterLook | Body, height, skin, 8 hair styles, hair color, 6 faces, outfit colors. `apply(character_model)` dresses a player/ CharacterModel without changing player/. |
| scripts/resident_profile.gd | ResidentProfile | Name, look, background and perk, home cell, saved outfits, owned shop colors. The Progress section `resident`. `perk("car_handling", 1.0)`. |
| scripts/resident_home.gd | ResidentHome | The home building by cell (survives tower merges), door, spawn point, auto move-in, `home_lost`. |
| scripts/home_picker.gd | HomePicker | Map mode: pins on homes, hover shows the address, click moves in, Esc skips. |
| scripts/character_creator.gd | CharacterCreator | The creator screen (and the wardrobe, `Mode.WARDROBE`), with a live 3D preview. |
| scripts/resident.gd | Resident | The glue above. |

Background perks, for whoever applies them: Cabbie `car_handling` 1.15, Ex-cop
`free_bribes_per_day` 1, Hustler `stolen_goods_price` 1.25, Medic `heal_rate` 1.5. Read
them with `Progress.get_section("resident").perk(key, default)`.

Clothing shops: `profile.owned.append("cloth:<i>")` unlocks shop color i
(`CharacterLook.CLOTH_FREE` and up).

## Tests and screenshots

    godot --headless --path . --script res://creator/tests/run_creator_tests.gd
    xvfb-run godot --rendering-driver vulkan --path . --resolution 1600x900 \
      -s res://creator/tests/creator_shots.gd -- --shots=DIR

Run them on a scratch copy, not the shared folder.
