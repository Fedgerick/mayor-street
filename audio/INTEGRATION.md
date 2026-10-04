# Audio: integration

Everything lives in `audio/`. The director is one autoload that finds the main scene by itself and
listens to what the other modules already expose, so turning it on is one line.

## Status

The autoload line below is in `project.godot`. Round 2 needs nothing new from main.gd: the action layer
(`action_audio.gd`) finds `main.missions` and `main.interiors` by name when they exist.

## Required (City sandbox thread, `project.godot`)

```ini
[autoload]

Kit="*res://scripts/kit.gd"
Audio="*res://audio/audio_director.gd"
```

That's all. With it registered the game gets ambience, music, traffic, footsteps, car sounds, UI
clicks and tool sounds. Tested headless with the line added: the city, street player, city life and
audio tests all pass.

Suggested README line for the mayor controls table: `| Music | M toggles music on and off |`.

## Round 2: what the action layer reads

| From | Read |
|---|---|
| `scripts/main.gd` | `missions`, `interiors` (optional; skipped when absent) |
| `StreetMode` | `combat` (`fired`, `weapon_changed`), `wanted` / `wanted_changed`, `wasted`, `busted`, optional `hit_landed(kind, pos, weapon)` |
| `StreetPlayer` | `damaged(amount, from_pos)` |
| `DrivableCar` (any node with `exploded` + `damaged`) | `exploded`, `damaged`, `driver`, `wrecked` |
| `Pickup` (any node with `taken`) | `taken` |
| `CityLife` | `police.siren_list()`, optional `police.officer_fired(pos)`, `traffic.car_taken`, `crowd.peds[].flee` |
| `Missions` | `director.started / passed / failed / step_changed`; a step with `"marker": "vault"` sets off the bank alarm at the step's slot `pos` |
| `InteriorManager` | `interior_entered(id, building)`, `interior_exited` |

`StreetMode.hit_landed` (eec246f) and `Police.officer_fired` (75e9db0) are live; impact sounds are
capped at three per frame because a shotgun reports every pellet.

## What the director reads (please keep these names, or tell the audio thread)

| From | Read |
|---|---|
| `scripts/main.gd` (the current scene) | `city`, `cam` (`.focus`), `street`, `life`, `started`, `tool`, `overlay`, `speed_index` |
| `City` | `land`, `bld`, `buildings`, `SIZE`, `time_of_day()`, `world_to_cell()`, `building_center()`; signals `cells_changed`, `building_added`, `message` |
| `StreetMode` (player/) | `active`, `busy`, `player`, signal `vehicle_changed` |
| `StreetPlayer` | `velocity`, `is_on_floor()` |
| `DrivableCar` | `speed()`, `throttle`, `linear_velocity`; input actions `street_horn`, `street_handbrake` |
| `CityLife` (citylife/) | `traffic.cars[i].pos / .v / .stuck`, `crowd.peds[i].pos` |

Tool sounds work out which tool was used from `main.tool` when `cells_changed` fires in the same
frame as a left mouse release, so `main._apply()` needs no call. Every `BaseButton` added to the tree
clicks automatically.

## Optional calls for later features

```gdscript
Audio.play_ui("cash")                              # job payout lands in the treasury
Audio.play_ui("notify")                            # a new job or event
var siren := Audio.attach_loop("siren_loop", fire_truck)   # follows the node, freed with it
Audio.play_at("crash", pos)                        # any impact the director doesn't see itself
Audio.set_volume("Music", 0.7)                     # buses: Music, Ambience, SFX, UI (linear 0..1)
Audio.music_enabled = false
```

Sound names are the file names in `audio/sfx/` without `.ogg`.
