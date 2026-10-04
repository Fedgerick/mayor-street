# City services (services/)

Power, parks, sanitation, police and fire on a radius model over the 80x80 grid, plus the
daily city numbers (power %, garbage %, crime, happiness, approval, income per resident).
No water system. Owned by the City services thread.

## Files

| File | What |
|---|---|
| `city_services.gd` | `class_name CityServices` (RefCounted). The engine, headless. |
| `service_defs.gd` | `ServiceDefs`: MW, radius, strength and tons per catalog id. Everything else comes from `Catalog`. |
| `services_view.gd` | `ServicesView` (Node3D): map overlays, power line poles and wires, garbage bags on sidewalks. |
| `services_panel.gd` | `ServicesPanel` (PanelContainer): the numbers and seven overlay buttons, bottom right. |
| `tests/test_services.gd` | `godot --headless --path . --script res://services/tests/test_services.gd` |

## Wiring (main.gd, City sandbox thread)

```gdscript
services = CityServices.new(city)          # after City exists; sets city.growth_check and
                                           # connects city.land_value_computed itself
Progress.register_section("services", services)
if demo:
    services.build_demo_services()         # plants, depots, police, fire, parks for the demo city
services_view = ServicesView.new()
add_child(services_view)
services_view.setup(services)
services_panel = ServicesPanel.new()
hud.root.add_child(services_panel)
services_panel.setup(services)
services_panel.overlay_selected.connect(services_view.set_overlay)
```

- Build menu: catalog service buildings go through `City.place_special` as usual. Nothing
  else is needed; services sees them through `building_added` (`kind` key).
- Power line tool (catalog `placement: "line"`): drag like a road, preview
  `city.road_path(a, b)`, cost `services.line_cost(path)`, place `services.place_power_line(path)`.
- Bulldoze tool: also call `services.bulldoze_lines(rect)`.
- Pick one overlay system: when a service overlay is on, set the old `overlay_mode` to 0, and
  the reverse (call `services_panel.set_overlay(0)` and `services_view.set_overlay(0)`).
- Daily stats go to `Progress.set_stats` (power_pct, garbage_pct, crime, happiness,
  approval, income_per_resident) through `city.progress`. Goodness is read from
  `city.progress.goodness`.
- Only power-line upkeep is charged here; City charges catalog upkeep.
- Night lights: buildings get `b.powered` (bool). Unpowered ones should go dark at night
  (CityView, street lamps). Not done yet, a sandbox change.

## Rules

- **Power.** Plants feed everything connected to them through roads, power lines, zoned
  land and buildings. Each connected network pools its plants' MW; when demand is higher,
  buildings nearest a plant get power first. Coal 80 MW, gas 160, solar 60, wind 10.
  Demand per resident 0.004 MW, per commercial job 0.006, per industrial job 0.01, other
  catalog buildings 0.4 per tile. `supply_scale` (default 1) scales every plant, for events.
- **Growth.** Until the city has a plant or 100 people, lots grow without power. After that a
  lot grows or upgrades only with power (`City.growth_check`). Six days without power, or
  six very unhappy days for homes, and a building drops a stage or empties out (at most 12
  a day).
- **Coverage.** Parks, police and fire stamp a falloff disc; garbage depots a flat disc with a
  soft rim. Recomputed only when a service building is added or removed.
- **Garbage.** Every building makes garbage daily; depots in range collect up to their tons a
  day, nearest first. Uncollected garbage builds up and shows as bags on the sidewalk.
- **Land value** (after each City recompute): + parks 0.18, - garbage 0.15, - crime 0.12.
- **Crime** per building: density, low land value, joblessness, garbage and the Resident's
  goodness push it up; police coverage takes off up to 0.75.
- **Happiness** per building: land value, parks, minus crime, garbage, fire risk, taxes over
  7%, and no power. City happiness is the residents' average. **Approval** eases daily
  toward 75% happiness plus 25% goodness, minus taxes over 9%.
- **Income per resident** ($ a year) = 22,000 + 55,000 x homes' land value x employment.

## For other threads

```gdscript
services.police_stations() -> Array[Dictionary]   # also fire_stations(), garbage_depots(), stations("power")
# each: id, kind, name, cell (top-left), size, center, door (City.door_position), road (nearest
# road tile centre, where cars leave from), radius_m, tags
signal police_stations_changed
services.coverage_at("police", world_pos) -> float  # 0..1; also "power", "park", "garbage", "fire"
services.crime_at(world_pos) -> float               # 0..1
services.garbage_piles() -> Array[Vector3]           # sidewalk spots with uncollected garbage
services.is_powered(building_id) -> bool
services.stats() -> Dictionary
```

Find the live object with `Progress.get_section("services")`.
