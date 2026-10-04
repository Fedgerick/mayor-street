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
| Music | Three stems in the same key and tempo, always in sync: a lo-fi electric piano piece for the mayor view, a plucked arpeggio and bass groove for the street, and a drum layer that fades in with car speed. The mayor and street stems crossfade over the dive. At night the mayor music is gently darker. M toggles music. |

## Files

- `sfx/` one-shots and short loops, `ambience/` 24 s beds, `music/` three 83 s stems (92 BPM, A minor).
- `tools/synth_audio.py` regenerates all of them: `pip install numpy scipy soundfile`, then
  `python3 audio/tools/synth_audio.py` (or `--only sfx|missions|ambience|music`). About two minutes.
- `tests/test_audio.gd` headless check: `godot --headless --path . --script res://audio/tests/test_audio.gd`
  (run on a scratch copy of the repo after `--import`).

## Cost

About 6 MB of Ogg Vorbis, streamed. At most around 20 voices play at once (3 music, up to 7 ambience,
8 traffic, the player's car, one-shots); ambience beds that are silent are paused. The per-frame
script work is a few dozen property sets, plus an area scan every 0.5 s and a traffic scan every 0.2 s.
