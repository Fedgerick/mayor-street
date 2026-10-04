# Missions and quests

Owned by the Missions and quests thread. Design: `design/round-2-plan.md` sections 6 to 8.

## Wiring (main.gd)

```gdscript
missions = Missions.new()
add_child(missions)
missions.setup(city, street)   # after street.set_life(); registers the "missions" save section
```

Keys: J quest log (both views); at street level Y takes a dispatch-radio job, K abandons a job.

## Files

| File | What |
|---|---|
| missions.gd | `Missions` node: payphones, dispatch radio, HUD, quest log, markers, save section |
| mission_director.gd | `MissionDirector`: templates to jobs, pricing, running steps |
| mission.gd | `Mission`: one job's data and state |
| goodness.gd | `Goodness`: the -100..100 scale, perks, daily drift, street actions |
| quest_engine.gd | `QuestEngine`: quests from data, conditions, rewards |
| building_tags.gd | `BuildingTags`: buildings by tag, display names, stand-ins |
| road_router.gd | `RoadRouter`: BFS routes and distances over road tiles |
| chase_car.gd | `ChaseCar`: a kinematic car that flees the player |
| street_link.gd, progress_link.gd | the only places that touch player/StreetMode and the Progress autoload |
| mission_hud.gd, quest_log.gd | UI |
| data/templates.json, data/quests.json | the content |

## Templates (data/templates.json)

- `id`, `side` (good/bad), `giver` (radio/payphone), `title`, `brief`
- `lean`: goodness needed on that side before it is offered (0, 25, 50...)
- `unlock`: a Progress unlock id needed first (e.g. `job:armored_escort`); `quest_only`: only quests hand it out
- `slots`: name -> `{tag, from, min_m, max_m, near_player_m}`. Buildings are found by tag; `from` measures road distance from an earlier slot
- `car`: list of car models, one picked as `{car}`
- `steps`: `goto` / `hold` (`seconds`) at a slot, with `car` true/false/"mission", `radius`, `clean` (no stars);
  `wanted` (`stars`); `chase` (a fleeing car, `escape_m`); `vehicle` (spawn a car at a slot, `steal` marks it stolen);
  `collect` (`count` piles within `spread_m`)
- `route`: slots whose road distance sets pay; `pay {base, per_km}`; `time {base, per_km}` (seconds)
- `goodness`, `city_bonus` (city funds), `crime` (counted into Progress counts `job_crime`), `max_wanted`, `stolen_goods` (Hustler perk)

pay = (base + per_km x km) x risk x lean bonus. Risk (bad jobs) grows with land value at the start and police buildings near the route.

## Quests (data/quests.json)

`when` starts it; each step has `until` (conditions) or `job` (a template, `times`); `reward` has cash, funds,
goodness, flag, unlock, note. Conditions are listed at the top of quest_engine.gd.

## Stand-ins

Until the Mayor places a real building with a tag, `BuildingTags` lends a big ordinary building and names it
(Second National Bank, The Bunker...), so every job is playable from the start. Placed specials always win.
Quest conditions (`built`) only count real ones. Payphones work the same way: 8 placeholder phones until
the Mayor places some.

## Tests

`godot --headless --path . --script res://missions/tests/test_missions.gd` and `.../test_quests.gd`
(on a scratch copy after `--import`).
