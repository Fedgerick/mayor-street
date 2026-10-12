# Planet: making New Harbor a sphere

Fedge's ask (2026-10-12): the world becomes a ball like Dyson Sphere Program, with one pole an ice cap and the other water, so the squeezed grid near the poles is never buildable.

## The shape

- The buildable grid is a **belt around the equator**. It wraps east to west, so you can drive or build all the way round and come back where you started.
- North of the belt the land turns to tundra and then a **polar ice cap**. South of it are beaches and then a **polar ocean**. Nothing near either pole is ever on the grid.
- Every row of tiles is the same 12 m deep. Going away from the equator the tiles get narrower east to west (on a ball the lines of longitude close in). At the belt's edge (about 34 degrees) they are 17% narrower, and buildings there are squeezed by that much to fit. Near the equator nothing changes.
- DSP solves the poles by changing the tile count per latitude band, which leaves seams in the grid. Our roads are a strict grid, so one belt plus the two caps is the cleaner fit, and it is exactly what Fedge asked for.

## Size (the one real dial)

| Planet | Tiles around x deep | Tiles | Radius | Horizon at eye height | Feel |
|---|---|---|---|---|---|
| Small | 160 x 30 | 4,800 | 306 m | 32 m | Very DSP, streets visibly curve away |
| **Medium (recommended)** | 192 x 36 | 6,912 | 367 m | 35 m | DSP-like, about today's 6,400 tiles |
| Large | 288 x 52 | 14,976 | 550 m | 43 m | Flatter streets, twice the city to fill and simulate |

Bigger planets cost more simulation and memory with the square of their size. Towers stay visible past the horizon (a 50 m tower shows from about 230 m on Medium).

## How it works: flat map, curved world

Almost every system (City, roads, zones, traffic routes, missions, police, saves, minimap, GPS) thinks in grid metres on a flat map. That stays. One new class, `Planet`, converts between the flat map and the ball and gives the local up, east and north at any point:

- **Drawing**: buildings, roads, trees and props are already placed with one transform each. Those transforms go through `Planet` and land on the ball, standing upright. Terrain and water become sphere meshes.
- **Shaders**: the city shaders read the zone, traffic and lamp maps by world position. A small helper turns a world position on the ball back into flat map metres first.
- **Physics**: Godot has point gravity built in, so cars, ragdolls and pickups fall toward the centre with no code. The walking character uses the local up as its floor direction.
- **Cameras**: the mayor camera orbits the globe and dives down to street level. Street cameras use the local up instead of straight up.
- **Sky and sun**: the sky and sun are turned to match the spot under the camera, so street level at noon looks exactly like today. From orbit you see the day side and the night side.

## What each part of the game needs

| Part | Change | Size |
|---|---|---|
| City (scripts/city.gd) | 80x80 square becomes W x H, east-west wrap for neighbours and paths, belt land generator with ice cap and ocean | Large |
| CityView, terrain, water, sky | Transforms through `Planet`, sphere terrain and sea, sky turned to the local up | Medium |
| Shaders (common.gdshaderinc) | World position to map metres before map lookups | Small |
| Mayor camera, build tools | Orbit the globe, pick tiles by ray against the ball | Medium |
| Street player, cars, collisions | Local up, point gravity, collision boxes placed on the ball | Medium |
| Traffic, crowd, police, tow trucks | Move in flat metres as today, convert at the final position write; wrap at the seam | Medium |
| Minimap, city map, GPS | Already flat; wrap at the seam, show the caps | Small |
| Missions, interiors, services, saves | Mostly unchanged (they use cells); saves get a planet version number | Small |

## Performance

Likely a help, not a cost: at street level the horizon hides most of the planet (the 5700U's biggest cost is drawing buildings), and from orbit you only ever see one side. The per-frame up-vector maths is tiny. The risk to watch is shadow maps on a curved surface.

## Steps

1. **Prototype (this thread, branch `claude/spherical-planet-n25b02`)**: a separate planet scene that reuses the game's buildings, cars, sky and sun. Orbit the globe, paint roads and zones, watch buildings grow, drop to the street, walk and drive all the way round. Fedge's current builds are untouched.
2. Fedge plays it and picks the size.
3. City goes W x H with wrap-around (City sandbox thread), then each system thread converts its part using `Planet`.
4. Merge into main once every test suite passes on the planet.
