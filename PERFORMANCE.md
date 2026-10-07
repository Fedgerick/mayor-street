# Performance: the budget, the shares and how to measure

Owned by the City sandbox thread. Every graphics change is checked against these numbers, and
every thread that puts things on screen stays inside its share. The design is in
`design/round-3-plan.md` section 1.

## The target

Fedge's laptop: a Ryzen 7 5700U with integrated Radeon graphics (8 GPU cores sharing system
memory). **Med at 1080p, 30 fps or better everywhere.** Med draws the 3D at 80% and upscales
it with FSR, with FXAA, SSAO, glow and two sun shadow splits. Low (67%, one shadow map, no
SSAO or glow) is the fallback; High is for faster computers.

These are starting numbers. They get retuned when the first benchmark from the laptop comes in.

| View | Draw calls | Triangles |
|---|---|---|
| Street level: on foot, driving, chases, night, rain | under **2,000** | under **4 million** |
| Mayor view | under **2,500** | under **6 million** |

How Godot counts them (the F3 readout and the benchmark use the same counters):

- A **draw call** is one mesh surface (one material) drawn once in one pass. On Med a visible
  surface is drawn in the depth prepass, in the colour pass and once more for each sun shadow
  split it falls in, so one material on a shadow-casting model costs up to **4 draw calls**.
- A **MultiMesh** costs the same as a single mesh, however many instances it holds. Its whole
  bounding box is culled as one, so a MultiMesh that spans the city is always drawn.
- **Triangles** are counted in every pass too, shadows included.
- The 2D HUD counts as well: about 30 draw calls at street level, 80 in the mayor view.

## Shares of the street-level budget (Med, all passes)

Measured 2026-10-07 on Med with `tests/perf_breakdown.gd` (each group drawn alone, all passes), build 0.4.1:

| Street level (the benchmark's walk) | Draw calls | Triangles | Budget share |
|---|---|---|---|
| Buildings and their shadows (kit, 4-tile cells) | 594 | 3.2M | the big one: **2.4M by day** at most, retune after the laptop numbers |
| Roads, sidewalks, lamps, signals | 140 | 0.04M | |
| Terrain and sea | 6 | 0.3M | |
| Traffic and parked cars (2-3 LODs per model) | about 60 | about 0.1M | cars: 6k / 1.5k / 300 triangles |
| People (crowd) | about 25 | about 0.2M | 1,500 per person |
| Street dressing (art/dresser, hides above 70 m) | about 75 | about 0.3M | agreed with the Art thread |
| Player, street spots, missions, rain | about 60 | about 0.1M | |
| 2D HUD and minimap | about 170 | | |
| **Total** | **1,380** | **4.45M** | under 2,000 and 4M |

Rule of thumb for what is left: about 600 draw calls, and about 0 triangles (buildings are over the limit by themselves). A thread that adds triangles has to take them out of somewhere else, or ask the sandbox thread for room (distant stand-ins are next).

## Rules for every new model

| Model | LOD0 | LOD1 | LOD2 | Switch at |
|---|---|---|---|---|
| Car (traffic, parked, the player's) | 6,000 | 1,500 | 300 | 28 m, 80 m (`VehicleKit.lod_for`) |
| Crowd person | 1,500 | 600 | 150 | 25 m, 60 m |
| The player | 10,000 | | | |
| Street prop (bench, bin, hydrant, sign) | 400 | 100 | gone | 30 m, 70 m |
| Tree | 3,000 | 800 | 150 | 40 m, 120 m |

- **One material per model.** Pack the look into UVs or vertex data, as vehicles/ does, so a
  model costs one draw call per pass instead of one per part. Glass may be a second one.
- **Draw repeated things through MultiMeshes**, one per mesh and LOD, and split them by area
  (a block or a chunk) rather than one for the whole city, so off-screen ones get culled.
- **Flat and small things cast no shadow**: roads, decals, puddles, ground clutter, anything
  under about 1 m tall, and far LODs (LOD2 of cars and people).
- **Small things end with distance**: set `visibility_range_end` (props 70 m, decals 50 m,
  people LOD2 150 m) so they stop costing anything out there.
- Lights: no shadow-casting omni or spot lights. Lamps are faked in the kit shader (`lamp_map`).
- Particles: GPU particles, at most two systems near the camera (rain uses its two).

## How to measure

- **On a real computer**: Benchmark on the title screen or in the Esc menu (90 seconds), or
  `MayorStreet.exe -- --benchmark`, which quits when it's done. The report is saved as
  `benchmark.txt` next to the saves (`%APPDATA%\MayorStreet` on Windows), every run is added to
  `benchmark-history.txt`, and the results screen has a Copy button. It flies the same tour
  every time: the island from above, downtown on foot, a drive through traffic, a police chase,
  and downtown at night in the rain, with fps, 1% lows, draw calls, triangles and GPU, render
  thread and script time for each part.
- **F3** in the game shows fps, draw calls and triangles live.
- **In the cloud** there is no real GPU (a software renderer), so fps there means nothing, but
  draw calls and triangles are exact:
  - `xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver vulkan --resolution 1280x720 --path . --script res://tests/perf_breakdown.gd`
    prints each group's draw calls and triangles on its own, split into colour, shadow and 2D,
    over downtown and at the benchmark's street spot.
  - `godot --path . -- --benchmark --bench-shots=DIR` runs the tour and saves a frame of each part.
  - `godot --path . -- --demo --shots=DIR --only=street,street_night --weather=rain` renders the
    look-dev set with the counts per shot.
- **Post before-and-after numbers and screenshots** with every graphics change, in your thread.

## Today

Median tour numbers from the cloud's software renderer (fps there means nothing; draw calls and triangles are exact), Med, 1280x720:

| View | Before the merge (0.4.0 + round 3) | Now (0.4.1) | Budget |
|---|---|---|---|
| Street, on foot | 2,913 draws, 6.0M triangles | **1,379 draws, 4.45M** | 2,000 / 4M |
| Mayor view at 260 m | 3,788 draws, 7.6M triangles | **1,629 draws, 6.3M** | 2,500 / 6M |
| Island from above (850 m) | 6,481 draws, 9.4M triangles | 3,100 draws, 9.7M | 2,500 |

What changed: every kit mesh is one surface (a material number per vertex in CUSTOM0 picks a row of tables in `kit.gdshader`, so a building is one draw call per pass instead of about five), and the draw cells shrank from 16 to 4 tiles so shadow and view culling skip most of the city. `Kit.merge_surfaces = false` brings the old per-material surfaces back for comparing.

What is still over: triangles. Street-level buildings are 3.2M of the 4.45M, because high-rises are 7k to 22k triangles each (`godot --headless --script res://tests/kit_stats.gd` lists them) and the island view draws everything. Next: distant box stand-ins, fewer shadow casters, and chunkier but cheaper kit buildings. The first real benchmark from the laptop retunes all of this.
