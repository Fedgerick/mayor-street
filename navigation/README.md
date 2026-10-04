# Navigation: minimap, GPS and the city map

Owned by the Minimap and GPS thread (round 3, thread 6). Design: `design/round-3-plan.md` section 3.

- **Minimap**: round, bottom left, at street level only (hidden in the mayor view and indoors). It turns
  with the camera so up is the way you look, zooms out as you drive faster, and shows roads, buildings,
  parks, your home, payphones, cops (flashing red and blue while you are wanted), special buildings and
  targets. Targets out of range sit on the rim. The GPS distance left is beside it.
- **GPS**: a line along the roads to the current target, redrawn as you move. The waypoint wins, then
  the highest-priority mark, then (until missions marks its own) the missions 3D beacon.
- **City map**: **V** in either view (M is music, G is the crew-backup perk), or `open_map()` from the Esc menu. North up, the whole island,
  click to set a waypoint, right-click to clear it, wheel to zoom, drag to move, hover a special building
  for its name, V or Esc to close. It pauses the game while open (unless the Esc menu already had).
- The waypoint is saved in the Progress section `navigation`.

## Wiring (main.gd, City sandbox thread)

In `_start()`, after `resident.use_interiors(interiors)`:

```gdscript
var nav: CityNav   # with the other members

nav = CityNav.new()
nav.name = "Navigation"
add_child(nav)
nav.setup(city, street, {"life": life, "missions": missions, "resident": resident, "interiors": interiors})
```

That's all. Optional:
- An Esc menu button "City map" calling `nav.open_map()`. The map draws on layer 70, above the menu (60);
  Esc or V closes it and you're back in the menu.
- Key lists: add `["V", "City map"]` to `MAYOR_KEYS` and `STREET_KEYS` in game_menu.gd, and to the
  street hints if there is room.
- If the sandbox adds a minimap data hook later, `MapPainter` is the one place that reads City for the
  picture.

## API for missions/ and anyone else

Find it from any node: `var nav := CityNav.find(get_tree())` (null when it isn't wired, so check).

```gdscript
nav.mark(id, where, opts)   # where: Vector3, or a Node3D to follow (a car, a fleeing target)
nav.unmark(id)
nav.unmark_prefix("mission:")
nav.has_mark(id)
```

`opts`, all optional:

| key | default | what |
|---|---|---|
| `color` | yellow | blip and GPS line colour (use MissionHud.GOOD / BAD) |
| `kind` | `"job"` | symbol: `job` (ringed target), `car`, `pickup`, `enemy`, `phone`, `place`, `home` |
| `label` | `""` | name for the city map |
| `gps` | `true` | the GPS line may lead here |
| `priority` | `0` | highest gps mark gets the line; ties go to the newest |
| `radius` | `0` | metres: clears itself when you get this close (0 = never) |

Marking the same id again moves or restyles it without losing its place. Signals: `arrived(id)` (a mark
with a radius or the waypoint was reached), `waypoint_changed(pos)`, `map_toggled(open)`.
Also `nav.route_length()` (metres along the roads), `nav.gps_target_id()`, `nav.set_waypoint(pos)`.

Suggested use in missions.gd `_update_markers()`, where `goal` and `col` are already worked out:

```gdscript
var nav := CityNav.find(get_tree())
if nav:
	if goal == Vector3.INF:
		nav.unmark("mission:goal")
	else:
		var doing: String = m.step().get("do", "") if m else ""
		nav.mark("mission:goal", m.target if doing == "chase" else goal, {"color": col,
			"kind": "car" if doing in ["chase", "vehicle"] else "job", "label": m.title if m else "Payphone"})
```

and `nav.unmark_prefix("mission:")` in `_hide_markers()` when the job ends. Collect piles can each get
`nav.mark("mission:pile%d" % i, p, {"kind": "pickup", "gps": false})`. Any id starting with `mission`
tells navigation that missions marks its own targets, so it stops reading the 3D beacon.

Until then the minimap already follows missions on its own: it reads `missions.phones` for the payphone
blips and the beacon over the next objective (or the ringing payphone) for the target and the GPS.

## Files

| File | What |
|---|---|
| city_nav.gd | `CityNav`: the API, blips, GPS choice, the V key, the save section, owns the two screens |
| map_painter.gd | `MapPainter`: the city as a 960 x 960 picture, repainted a patch at a time |
| gps_route.gd | `GpsRoute`: search over the roads (from the target, cached) and the line's turns |
| minimap.gd | `Minimap`: the round map |
| city_map.gd | `CityMap`: the full screen map |
| blips.gd | `Blips`: the symbols and the legend |

Cost: the first paint about 50 ms when a game starts; a change repaints its patch (under 1 ms) at most
twice a second, and only while a map is on screen. The GPS search runs when the target or the roads
change (under 10 ms); moving just follows the stored arrows. The minimap is a few hundred 2D draws.

## Tests

    godot --headless --path . --script res://navigation/tests/test_navigation.gd
    xvfb-run godot --rendering-driver vulkan --path . --resolution 1600x900 \
      -s res://navigation/tests/nav_shots.gd -- --demo --nav-shots=DIR

Run them on a scratch copy after `--import`.
