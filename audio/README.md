# Audio

One autoload, `Audio` (`audio_director.gd`), drives all sound. Hook-up: [INTEGRATION.md](INTEGRATION.md).

## What you hear

| Where | Sound |
|---|---|
| Mayor view | City rumble that grows with building density, birds in quiet daytime areas, crickets at night, sea near the coast, wind as you zoom out. The higher the camera, the more muffled the city. Occasional far-off horns. |
| Mayor tools | Click on every button, a tick for tool hotkeys, a roller thump for roads, a pluck for zoning (pitch per zone), a crunch for bulldozing, a chime when a building finishes, a buzz when money runs out. |
| Dive / rise | A whoosh down and a whoosh up, timed to the camera flights. |
| Street, on foot | Footsteps paced by speed, a landing thud, crowd murmur that follows how many people are nearby, the nearest 8 AI cars as positional engine and tyre sound, and stuck drivers who honk. A light street reverb. |
| Street, driving | Door open and close, starter, an engine loop with fake gears (idle and load layers), tyre roll, skids on slides and handbrake turns, the horn on H, crashes from sudden velocity changes. |
| Street action | Pistol and shotgun shots with a slap-back off the buildings, punch swings and hits, bullet impacts and ricochets, metal clanks on cars, cop gunshots, a big explosion with debris, carjack scuffles, a car alarm when a parked car is hit, pickup and weapon-switch clicks. |
| Police and crowds | Up to three cop sirens (wail and yelp) placed on the nearest cop cars, a police radio burst when stars go up, a screaming crowd that grows with how many people are running nearby, Wasted and Busted stings. |
| Missions | Payphone ring, dispatch radio, start / checkpoint / passed / failed stings. The bank alarm goes off when you start on the vault: a bell inside the bank, and ringing from the building outside for 90 s. A fourth music stem (drums, driving bass, string stabs) takes over from the street groove during a mission or a chase of two stars or more. |
| Interiors | The city drops to a murmur, a room tone comes up and footsteps get a small room reverb. |
| Weather | Light and heavy rain that crossfade with how hard it rains, rain drumming on the roof when you're in a car, gusty wind that whistles harder between tall buildings, and thunder after lightning (delayed by distance). Reads the game's weather node; dry until it exists. |
| Between tall buildings | The street reverb gets bigger and wetter and gunshots, doors and footsteps echo off the walls, based on how many tall buildings are within about 36 m. |
| Car radio | Four stations while you drive: KMAY 92.1 (hits, needs the KMAY Radio Tower), Harbor Lo-Fi 88.5, Night Drive 101.7 (synthwave) and BOOM 104.3 (trap). Each has station jingles. C (or D-pad up) switches; after the last station it turns off. The station name shows at the top of the screen. The radio replaces the street music; mission music still plays underneath. |
| Music | Four stems in the same key and tempo, always in sync: a lo-fi electric piano piece for the mayor view, a plucked arpeggio and bass groove for the street, and a drum layer that fades in with car speed. The mayor and street stems crossfade over the dive. At night the mayor music is gently darker. M toggles music. |

## Files

- `sfx/` one-shots and short loops, `ambience/` 24 s beds, `music/` four 83 s stems (92 BPM, A minor).
- `tools/synth_audio.py` regenerates all of them: `pip install numpy scipy soundfile`, then
  `python3 audio/tools/synth_audio.py` (or `--only sfx|missions|action|ambience|music`). About two minutes.
- `tools/synth_round3.py` makes the round-3 sounds: `--only weather|radio` (rain, gusts, thunder, the
  radio tuning burst and the four ~110 s radio stations in `music/radio_*.ogg`).
- `weather_audio.gd` (class WeatherAudio) reads rain and wind and plays thunder; `car_radio.gd` (class CarRadio) is the radio. The director creates both.
- `action_audio.gd` (class ActionAudio) is the round-2 layer: guns, police, alarms, missions, interiors. The director creates it.
- `tests/test_audio.gd`, `tests/test_action_audio.gd` and `tests/test_round3_audio.gd` headless checks: `godot --headless --path . --script res://audio/tests/test_audio.gd`
  (run on a scratch copy of the repo after `--import`).

## Cost

About 16 MB of Ogg Vorbis, streamed (the radio is 6 MB of that, and only one station decodes at a time). At most around 20 voices play at once (4 music, up to 9 ambience,
8 traffic, 3 sirens, the player's car, one-shots); ambience beds that are silent are paused. The per-frame
script work is a few dozen property sets, plus an area scan every 0.5 s and a traffic scan every 0.2 s.
