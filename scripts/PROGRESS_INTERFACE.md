# Progress, saves and the building catalog

The shared foundation from round-2 plan phase 0. Code against this page. The City sandbox
thread owns everything here (`scripts/`). If you need something that isn't on this page,
send a note through the coordinator instead of working around it.

Status 2026-10-04: everything on this page is in the code, with tests in
`tests/progress_test.gd`. Names on this page will not change without a note.

## The short version

- **`Progress`** is an autoload (`scripts/progress.gd`). It holds what the whole game
  shares: the Resident's cash, goodness, unlock flags, milestone tier, city stats, story
  flags, counters and quest state. It also saves and loads games.
- **Sections**: anything else that must be saved registers an object with
  `to_dict()` / `from_dict(d)`, the convention every thread already uses.
- **`Catalog`** (`scripts/catalog.gd`, static) lists every building the Mayor can buy:
  service buildings and specials, with size, cost, upkeep, unlock tier, tags, model and
  interior. It also holds the milestone tier table.
- **`City.place_special(kind, cell)`** places one. It lands in `City.buildings` like any
  other building, with `kind`, `name` and `tags` keys added.
- City funds stay in `City.funds`. The Resident's cash is `Progress.cash`.

## Progress (autoload)

```gdscript
# Wallets
var cash: int                                         # the Resident's money
func add_cash(n: int, reason := "") -> void           # n may be negative; never goes below 0
func spend_cash(n: int, reason := "") -> bool         # false (and nothing taken) when short
func add_city_funds(n: float, reason := "") -> void   # into City.funds
func spend_city_funds(n: float, reason := "") -> bool # City.spend(): false plus a message when short
func donate(n: int) -> bool                           # Resident cash into city funds
signal cash_changed(cash: int, delta: int, reason: String)
signal city_funds_changed(funds: float, delta: float, reason: String)  # only changes made through Progress

# Goodness: -100 Kingpin .. +100 Hero
var goodness: float
func add_goodness(delta: float, reason := "") -> void  # clamped
func set_goodness(v: float, reason := "") -> void
func goodness_tier() -> int                           # -4..4, one step per 25 points
signal goodness_changed(value: float, delta: float, reason: String)

# Unlock flags. Building ids are catalog ids; anything else takes a prefix:
# "job:armored_escort", "perk:black_market", "item:lock_pick".
var unlocks: Dictionary                               # id -> source: "start", "tier:2", "quest:lights_on", "goodness:kingpin"
func unlock(id: String, source := "") -> bool         # true when newly unlocked; buildings also pop a message
func lock(id: String) -> void                         # e.g. a perk lost by dropping back over its line
func is_unlocked(id: String) -> bool
signal unlocked(id: String, source: String)
signal locked(id: String)

# Milestones. Progress checks Catalog.TIERS once a game day (on City.day_passed), using
# City.population and stats.income_per_resident. Reaching a tier unlocks every catalog
# building of that tier and pops "Milestone: Small city".
var city_tier: int                                    # 0 Town .. 5 Metropolis
func reach_tier(t: int) -> void                       # for tests and quests; the daily check calls it
signal tier_reached(tier: int, tier_name: String, ids: Array)

# City stats, updated once a game day. City fills population and jobs; services/ fills the rest.
var stats: Dictionary  # population, jobs, income_per_resident ($ a year), power_pct, garbage_pct,
                       # crime, happiness, approval (all 0..100)
func set_stats(d: Dictionary) -> void                 # merges, then emits once
signal stats_changed(stats: Dictionary)

# Story flags, lifetime counters, quests
var flags: Dictionary                                 # any JSON-safe value
func set_flag(key: String, value: Variant = true) -> void
func get_flag(key: String, default: Variant = null) -> Variant
signal flag_changed(key: String, value: Variant)
var counts: Dictionary                                # "missions_good", "banks_robbed", "cash_earned"...
func count(key: String, n := 1) -> int                # adds, returns the new total
var quests: Dictionary  # quest id -> {"state": "active" | "done" | "failed", ...anything missions/ needs}
func set_quest(id: String, d: Dictionary) -> void
func quest_state(id: String) -> String                # "" when never started
signal quest_changed(id: String)

# Good news for the HUD (green toast): milestones, unlocks, saves. Problems stay on City.message.
signal notice(text: String)
```

Goodness rules (perks, drift toward zero, what moves it) belong to missions/. Missions keeps
its own logic and reads and writes `Progress.goodness`. Services reads it for crime and
approval.

## Saving and loading

```gdscript
func register_section(key: String, obj: Object) -> void  # obj has to_dict() -> Dictionary and from_dict(d)
func get_section(key: String) -> Object                  # another thread's live object, or null
func save_game(slot := "") -> bool       # "" = the slot this game was last saved to or loaded from
func autosave() -> bool                  # slot "autosave"
func load_game(slot: String) -> void     # restarts the main scene from the save
func list_saves() -> Array               # newest first: {slot, title, saved_at, day, population, cash, funds, version}
func has_save(slot: String) -> bool
func delete_save(slot: String) -> void
var slot: String
signal saved(slot: String)
signal game_started(loaded: bool)        # City and every section are in place
```

What to know:
- **A load rebuilds the main scene.** City is restored first, then main.gd creates every
  thread's objects as it does for a new game, so nobody needs a reset handler. Don't keep
  references to City or game nodes in an autoload or a static across a load.
- **Register when main.gd creates your object.** When a save is being loaded,
  `register_section` calls your `from_dict` right away with your saved data. A new game
  never calls `from_dict`. Section keys so far: `services`, `missions`, `resident`,
  `street`. Saves with a missing section skip it, so old saves keep loading.
- **JSON-safe data only**: bool, String, numbers, Array, Dictionary. Numbers come back as
  floats, so cast with `int()` (your tests already round-trip through JSON).
- **City.buildings entries are saved whole**, including keys you add (`kind`, `powered`...),
  as long as they're JSON-safe. City casts its own int fields back on load.
- Autosave runs every 3 game days and on Quit to desktop. creator/ calls
  `Progress.autosave()` when the Resident walks in the front door at home.
- Files are `user://saves/<slot>.json`, which on Windows is `%APPDATA%\MayorStreet\saves`.

## The building catalog

```gdscript
Catalog.get_def(id) -> Dictionary       # {} for an unknown id
Catalog.ids(group := "") -> Array       # in menu order
Catalog.with_tag(tag) -> Array          # ids carrying a tag
Catalog.GROUPS                          # build menu tabs, in order
Catalog.TIERS                           # [{name, goals: {pop, income}, any}]
Catalog.goal_text(tier) -> String       # "Reach 5,000 people"
Catalog.lock_text(id) -> String         # what a greyed-out menu entry shows
```

Entry fields: `name`, `group`, `size` (tiles, square; 0 is a street prop), `cost`,
`upkeep` ($ a day; negative earns money; City charges it daily, so don't charge it yourself),
`tier` (0 to 5; -1 means only a quest or goodness unlocks it), `tags`, `unique` (only one
allowed), `needs_road`, `placement` ("lot", "street" for a sidewalk prop, or "line" for
power lines), `menu` (false for spawned-only buildings), `interior`, `model`, `door`,
`desc`, plus `color` and `height` for the placeholder block drawn while a model is missing.

Models and doors come from the art thread's `art/specials.json` and
`assets/kit/specials/<id>.glb`, so the names here match the name signs on the models.
Service numbers (MW, radius, tons, strength) stay in `services/service_defs.gd`, keyed by
the same ids. Name, size, cost, upkeep, tier and tags come from the catalog.

| id | Name | Group | Size | Tier | Tags | Interior |
|---|---|---|---|---|---|---|
| coal_plant | Coal Power Plant | power | 2 | 0 | power_plant, industrial | |
| power_line | Power Line | power | line | 0 | power_line | |
| small_park | Small Park | parks | 1 | 0 | park, meeting_spot | |
| garbage_depot | Garbage Depot | garbage | 1 | 0 | garbage_depot, industrial | |
| landfill | Landfill | garbage | 2 | 0 | garbage_depot, landfill | |
| police_station | Police Station | safety | 1 | 0 | police | police |
| fire_station | Fire Station | safety | 1 | 0 | fire_station, emergency | |
| gas_station | Gas 'n' Go | business | 1 | 1 | shop, gas_station, robbable | shop |
| pawn_shop | Lucky Pawn | business | 1 | 1 | shop, pawn_shop, fence, robbable | shop |
| diner | Starlite Diner | business | 1 | 1 | shop, diner, robbable | shop |
| payphone | Payphone | street | 0 | 1 | payphone | |
| bank | Second National Bank | business | 1 | 2 | bank, robbable, landmark | bank |
| nightclub | Club Voltage | business | 1 | 2 | nightclub, nightlife | nightclub |
| chop_shop | Eddie's Auto Body | business | 1 | 2 | chop_shop, garage | |
| warehouse | Pier 4 Warehouse | business | 1 | 2 | warehouse, industrial | |
| plaza | Civic Plaza | parks | 1 | 2 | park, plaza, meeting_spot | |
| bunker | The Bunker | landmarks | 1 | 3 | hideout, bunker | bunker |
| police_hq | Police Headquarters | safety | 2 | 3 | police, police_hq | police |
| hospital | General Hospital | safety | 2 | 3 | hospital, emergency | |
| gas_plant | Gas Power Plant | power | 1 | 3 | power_plant, industrial | |
| recycling_center | Recycling Center | garbage | 1 | 3 | garbage_depot, green | |
| sports_field | Municipal Sports Field | parks | 2 | 3 | park, sports, meeting_spot | |
| casino | The Golden Ace Casino | business | 2 | 4 | casino, nightlife, robbable, landmark | |
| stadium | City Stadium | landmarks | 3 | 4 | stadium, sports, landmark, meeting_spot | |
| city_park | Central Park | parks | 2 | 4 | park, landmark, meeting_spot | |
| solar_farm | Solar Farm | power | 2 | 4 | power_plant, green | |
| wind_turbine | Wind Turbine | power | 1 | 4 | power_plant, green | |
| airfield | Municipal Airfield | landmarks | 3 | 4 | airfield, escape, landmark | |
| radio_tower | KMAY Radio Tower | landmarks | 1 | 4 | radio_tower, landmark | |
| federal_reserve | Federal Reserve | landmarks | 2 | 5 | bank, vault, robbable, landmark | bank |
| mansion | Mansion on the Hill | landmarks | 2 | 5 | mansion, hideout | |
| landmark_tower | Mayor's Tower | landmarks | 2 | 5 | landmark | |
| substation | Substation | power | 1 | -1 | substation (spawned only) | |

Sizes follow the models the art thread already built. Missions find buildings by tag,
never by id: `bank` and `hideout` cover the bank job, for example. A new tag is fine; add it
to this table through a note. Ordinary zone buildings carry no tags; missions/
`BuildingTags` gives them `home`, `shop` and `industrial` from their zone.

Milestone tiers (same numbers as services/milestones.gd had, which this replaces):

| Tier | Name | Goal |
|---|---|---|
| 0 | Town | start |
| 1 | Village | 1,000 people |
| 2 | Small city | 5,000 people |
| 3 | City | 15,000 people, or $52,000 income per resident |
| 4 | Big city | 40,000 people and $48,000 income per resident |
| 5 | Metropolis | 70,000 people and $58,000 income per resident |

## Placing buildings (City)

```gdscript
City.can_place_special(kind: String, cell: Vector2i, free := false) -> String  # "" when OK, else the reason
City.place_special(kind: String, cell: Vector2i, rot := -1, free := false) -> int  # building id, or -1 plus a message
City.find_tagged(tag: String) -> Array[Dictionary]   # placed buildings carrying the tag
City.specials_of(kind: String) -> Array[Dictionary]
City.door_position(b: Dictionary) -> Vector3          # the model's door spot, or the middle of the road side
City.props_at(cell_index: int) -> Array               # ids of street props (payphones) on a road tile
City.building_center(b) -> Vector3                    # for a payphone: its spot on the sidewalk
```

- `cell` is the top-left tile of the footprint. For a street prop (payphone) it's the road
  tile, and `rot` picks the sidewalk side.
- `rot` is the side the front door faces (`City.DIRS`: 0 south, 1 east, 2 north, 3 west).
  -1 picks the side with a road.
- Checks: unlocked, `unique`, on land, no road, no building in the way, a road alongside
  when `needs_road`, and enough funds. `free = true` skips the unlock check and the cost,
  for spawned specials and quest rewards.
- The new entry has the usual keys plus `kind`, `name` and `tags`, with `zone` NONE. Its
  tiles are unzoned. Zone growth never touches it, and bulldozing removes it like any
  building. `building_added` fires after those keys are set.
- services/ wraps this for its own placement rules. Power lines stay services/' own grid
  and tool. main.gd wires the build menu and the line tool to it.

## Hooks in City for services/

- `City.growth_check: Callable`. When set, `func(x: int, y: int) -> bool` is asked before
  a zone lot grows a building or a stage. Return false to hold it back (no power, say).
- `signal land_value_computed`. It fires after City recomputes land value, so parks,
  garbage and crime can adjust `City.land_value` in place.

## Who calls what

| Thread | Uses |
|---|---|
| services/ | `Catalog` for building data, `City.place_special`, the two hooks, `Progress.set_stats` daily, section `services` |
| missions/ | `Progress` wallets, goodness, flags, counts, quests, unlocks; `City.find_tagged`; section `missions` |
| creator/ | section `resident` (the ResidentProfile); `Progress.autosave()` on entering home; start cash via `Progress.add_cash` |
| player/ | `Progress.cash` for Wasted and Busted losses; section `street` if it keeps anything |
| art/ | model and door per catalog id in `art/specials.json`; interiors by the `interior` key |
