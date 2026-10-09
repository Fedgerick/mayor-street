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
| mission_crew.gd | `MissionCrew`: armed guards, gangs and hit targets that fight back (group `street_targets`) |
| street_uses.gd | `StreetUses`: which street jobs a building opens (build menu hover, placement news) |
| street_link.gd, progress_link.gd | the only places that touch player/StreetMode and the Progress autoload |
| mission_hud.gd, quest_log.gd | UI |
| contacts.gd | `Contacts`: Marchetti, Ruiz and Hart, respect 0-100, rivals, ranks |
| medals.gd | `Medals`: bronze/silver/gold by time and damage, the replay list |
| city_effects.gd | `CityEffects`: street results that change the city for a while |
| mission_intro.gd | `MissionIntro`: the camera fly-by before story jobs (pauses the game) |
| perk_effects.gd, specials.gd, bribe.gd | goodness perks, spawned specials, bribing police |
| data/templates.json, data/quests.json | the content |

## Templates (data/templates.json)

- `id`, `side` (good/bad), `giver` (radio/payphone/council), `title`, `brief`
- `contact` (default: the giver's), `respect` gained when passed (3, or 8 for story jobs), `needs_respect`
- `after`: a quest id; the job only repeats on its own once that story chapter is done
- `effect` + `effect_at` (a slot): a city effect from city_effects.gd; `par`: medal par seconds for untimed jobs
- `lean`: goodness needed on that side before it is offered (0, 25, 50...)
- `unlock`: a Progress unlock id needed first (e.g. `job:armored_escort`); `quest_only`: only quests hand it out
- `slots`: name -> `{tag, from, min_m, max_m, near_player_m}`. Buildings are found by tag; `from` measures road distance from an earlier slot
- `car`: list of car models, one picked as `{car}`
- `steps`: `goto` / `hold` (`seconds`) at a slot, with `car` true/false/"mission", `radius`, `clean` (no stars);
  `wanted` (`stars`); `chase` (a fleeing car, `escape_m`); `vehicle` (spawn a car at a slot, `steal` marks it stolen);
  `collect` (`count` piles within `spread_m`);
  `fight` at a slot (`count`, `armed` pistol/fists/mixed, `boss` name, `hp`): done when all are down, or the boss is;
  `destroy` (`at`, optional `guards`): wreck the spawned `{car}`;
  `defend` at a slot (`seconds`, `waves`, `per_wave`, `from_m`, `leave_s`): hold off attackers, fail if you leave;
  `race` (`from`, `to`, `every_m`, `base_s`, `per_km_s`): checkpoints along the road route, in a car, against the clock;
  `rampage` (`count`, `seconds`, `weapon`): kills in time. Good-side `fight`/`defend` don't draw stars from your gunfire
- `route`: slots whose road distance sets pay; `pay {base, per_km}`; `time {base, per_km}` (seconds)
- `goodness`, `city_bonus` (city funds), `crime` (counted into Progress counts `job_crime`), `max_wanted`, `stolen_goods` (Hustler perk)

pay = (base + per_km x km) x risk x lean bonus. Risk (bad jobs) grows with land value at the start and police buildings near the route.

## Quests (data/quests.json)

`when` starts it; each step has `until` (conditions) or `job` (a template, `times`); `reward` has cash, funds,
goodness, flag, unlock, note, `respect` {contact: n} and `ending` (hero/kingpin). Conditions are listed at the top
of quest_engine.gd; `unless` drops a quest that is still active.

Story quests have `"story": true`, an `act` (1-3, opened by the Small city, City and Metropolis tiers) and a
`contact`. Their jobs get the fly-by intro and a medal, and show up in the quest log for replay (1-9).

## Minimap and GPS

When navigation/ is wired (a node in group `city_nav`), missions marks its own targets there: `mission:goal`
(the next objective, the ringing payphone, or the car being chased, priority 10), `mission:pileN` for collect
piles, and `mission:special:<id>` for spawned specials. Without it nothing changes.

## City effects for services/

`CityEffects` sits on the City as meta `street_effects`. Casino losses come out of city funds here; crime and
happiness need services/ to read it in `_crime_and_happiness`:

    var fx: Object = city.get_meta("street_effects", null)
    ... cr *= fx.crime_mult(b.x, b.y) ... h += fx.happiness_add(b.x, b.y)

## Stand-ins

Until the Mayor places a real building with a tag, `BuildingTags` lends a big ordinary building and names it
(Second National Bank, The Bunker...), so every job is playable from the start. Placed specials always win.
Quest conditions (`built`) only count real ones. Payphones work the same way: 8 placeholder phones until
the Mayor places some.

## Tests

`godot --headless --path . --script res://missions/tests/test_missions.gd`, `.../test_quests.gd`,
`.../test_specials.gd`, `.../test_story.gd`, `.../test_fights.gd` (new steps, StreetUses) and
`.../test_crew_street.gd` (the crew against the real street_test scene: shots, damage, police)
(on a scratch copy after `--import`).

StreetMode contract for `street_targets`: `trace_shot` asks each node in the group for `targets()` (objects with
`pos`) and `apply_hit` calls `owner.hurt(target, damage, dir, weapon)`; `StreetMode.sanctioned` skips the shots-fired crime.
