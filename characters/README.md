# characters/: the detailed look for people and dogs

Owned by the "Character graphics upgrade" thread. It changes nothing in player/, creator/
or citylife/: HeroLook sits on top of player/'s CharacterModel and swaps its close-up mesh
and materials, and HeroDog is a drop-in mesh and shader for citylife's dog MultiMesh.

Two detail levels for people:
- **Full**, for the player on foot and the character creator's preview: about 2.5x the
  triangles (a full outfit is ~25k instead of ~9k), so faces, hands and clothes are smoother.
- **Mid**, for everyone else close up (crowd heroes, police, mission crews): the same
  sculpt decimated back to the street parts' budget (~10k, a little more than before for
  the face), and the cheap 1.5k-triangle crowd shadow as before.

Both get:
- A sculpted face: eye sockets and lids, lashes, cheekbones, a nose bridge and nostrils,
  two lips and a mouth line, a jawline and chin. Eyes with a coloured iris, pupil and
  catchlight (the iris colour comes from the seed, or `colors.Iris`, or `HeroLook.iris`).
- Clothes trims: ribbed cuffs and hems, a waistband with belt loops and a button, hoodie
  drawstrings, jacket buttons, shoe soles with tread, and laces.
- Painted detail with no textures: knit and fleece, denim twill with wear and orange
  stitching, jacket grain and creases, skirt pleats, hair strands, cap panel seams, ribbed
  knit, and skin with soft wrap lighting, warm cheeks, nose, ears and lips, and lifted
  self-shadows (so the nose doesn't cut a hard dark patch into the face).

Far from the camera nothing changes: HeroLook only acts while its model is on LOD0, and
steps aside at LOD1 (the 1.5k-triangle crowd mesh), and the MultiMesh crowd is citylife's.

Dogs (HeroDog, characters/dogs/): a sculpted dog with floppy ears, eyes, a wet nose, a
tongue, a collar with a tag and fur, in five breeds picked by the dog's existing coat
index (lab, border collie, golden, beagle, husky). ~2.3k triangles at LOD0, ~500 at LOD1,
one draw call for all dogs, same trot animation as before.

## Wiring (City sandbox thread, main.gd)

One line in `main._ready()`, before StreetMode and the creator are made:

```gdscript
HeroLook.install(get_tree())
```

It then upgrades every CharacterModel as it appears: the StreetPlayer's model and the
CharacterCreator preview at full detail, the rest at mid. By hand:
`HeroLook.attach(character_model, crowd)`.

## Wiring (Traffic and pedestrians thread, citylife/crowd.gd)

In `Crowd.setup`, where the dog MultiMesh is made, two lines change:

```gdscript
dm.mesh = HeroDog.build() if HeroDog.available() else DogMesh.build()
dmat.shader = preload("res://characters/dogs/hero_dog.gdshader") if HeroDog.available() else DOG_SHADER
```

The INSTANCE_CUSTOM contract (trot phase, stride, coat) is unchanged. `HeroDog.build(1)` is
the far LOD if the dogs are ever split into near and far MultiMeshes.

Optional: on the Low graphics level set `detail = 0.0` on the HeroLook node
(`street.player.visual.get_node("HeroLook").detail = 0.0`) to drop the painted detail.

## Cost

- Player (full): ~25k triangles and up to ~15 draw calls (one per material) instead of
  ~9k and ~8. Its shadow is the mid shape merged into one surface, one draw per pass.
- Each close-up crowd person (mid): ~10k triangles instead of ~9k, up to ~14 draw calls
  instead of ~8, shadow unchanged. Med allows 12 close-up people, so up to ~70 more draws.
- Dogs: ~2.3k triangles each instead of 130, still one draw call for all of them.
- Script cost: every part's rest pose is baked once when the first model loads (during the
  city load); a re-dress only merges arrays, as CharacterModel already does.
- Measured on the street test bed (cloud, software GPU, 960x540, traffic and people):
  see the commit message for the before/after numbers.

## Files

- `tools/build_dog.py` builds `assets/dog.glb` (~5 s); `dogs/hero_dog.gd` and
  `dogs/hero_dog.gdshader` draw it.
- `test/dog_preview.tscn`: dog renders, `-- --out=DIR [--plain] [--lod=1]`.
- `tools/build_hero.py` builds `assets/hero.glb` (needs the `bpy` pip module, Blender 4.2;
  ~30 s). It imports player/tools/build_character.py for the rig, weighting and base
  shapes, so rerun it after that script changes the rig or the wardrobe.
- `scripts/hero_look.gd` (class HeroLook) merges the outfit and makes the materials.
- `shaders/hero_skin.gdshader`, `shaders/hero_cloth.gdshader` and
  `shaders/hero_common.gdshaderinc`: the materials. Rest-pose positions and normals ride
  in UV, UV2 and COLOR, so painted detail sticks to the body as it moves.
- `test/run_hero_test.gd`: headless checks, `godot --headless -s res://characters/test/run_hero_test.gd`.
- `test/hero_preview.tscn`: before/after renders, `-- --out=DIR [--plain]`.
- `test/hero_perf.tscn`: street draw calls and triangles, `-- --street --life [--hero] [--dogs]`.
