# characters/: the player's high-detail look

Owned by the "Character graphics upgrade" thread. It changes nothing in player/ or creator/:
HeroLook sits on top of player/'s CharacterModel and swaps its close-up mesh and materials.

What the player gets, on foot and in the character creator's preview:
- About 2.5x the triangles (a full outfit is ~25k instead of ~9k), so faces, hands and
  clothes are smoother.
- A sculpted face: eye sockets and lids, lashes, cheekbones, a nose bridge and nostrils,
  two lips and a mouth line, a jawline and chin. Eyes with a coloured iris, pupil and
  catchlight (the iris colour comes from the seed, or `colors.Iris`, or `HeroLook.iris`).
- Clothes trims: ribbed cuffs and hems, a waistband with belt loops and a button, hoodie
  drawstrings, jacket buttons, shoe soles with tread, and laces.
- Painted detail with no textures: knit and fleece, denim twill with wear and orange
  stitching, jacket grain and creases, skirt pleats, hair strands, cap panel seams, ribbed
  knit, and skin with soft wrap lighting, warm cheeks, nose, ears and lips, and lifted
  self-shadows (so the nose doesn't cut a hard dark patch into the face).

Crowd people, police and the player far from the camera are untouched: HeroLook only acts
while its model is on LOD0, and steps aside at LOD1.

## Wiring (City sandbox thread, main.gd)

One line in `main._ready()`, before StreetMode and the creator are made:

```gdscript
HeroLook.install(get_tree())
```

It then upgrades the StreetPlayer's model and the CharacterCreator preview whenever they
appear. To upgrade some other model by hand: `HeroLook.attach(character_model)`.

Optional: on the Low graphics level set `detail = 0.0` on the HeroLook node
(`street.player.visual.get_node("HeroLook").detail = 0.0`) to drop the painted detail.

## Cost

One model: ~25k triangles and up to ~15 draw calls (one per material) instead of ~9k and
~8. Its shadow is the hero shape merged into one surface, still one draw call per shadow
pass. Street totals with and without are in the commit that added this folder.

## Files

- `tools/build_hero.py` builds `assets/hero.glb` (needs the `bpy` pip module, Blender 4.2;
  ~30 s). It imports player/tools/build_character.py for the rig, weighting and base
  shapes, so rerun it after that script changes the rig or the wardrobe.
- `scripts/hero_look.gd` (class HeroLook) merges the outfit and makes the materials.
- `shaders/hero_skin.gdshader`, `shaders/hero_cloth.gdshader` and
  `shaders/hero_common.gdshaderinc`: the materials. Rest-pose positions and normals ride
  in UV, UV2 and COLOR, so painted detail sticks to the body as it moves.
- `test/run_hero_test.gd`: headless checks, `godot --headless -s res://characters/test/run_hero_test.gd`.
- `test/hero_preview.tscn`: before/after renders, `-- --out=DIR [--plain]`.
- `test/hero_perf.tscn`: street draw calls and triangles, `-- --street --life [--hero]`.
