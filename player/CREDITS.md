# Player credits

All street-player assets are original to this project and free to use. Nothing in this
folder is third-party.

- **Character** (`assets/character.glb`): modelled, rigged and animated by script in
  Blender 4.2 (`tools/build_character.py`). Animations: Idle, Walk, Run, Jump, Fall, Sit,
  EnterCar, ExitCar. Rebuild with `python3 player/tools/build_character.py` (pip `bpy`).
- **Cars**: the city kit's Blender-generated car meshes (`assets/kit/cars/`).

Considered and not used: KayKit Adventurers (CC0, Kay Lousberg) was the only rigged
character pack reachable from the cloud, but its knights and mages don't fit a modern city.
Quaternius, Kenney, Mixamo and Poly Haven aren't reachable from the cloud build machine.
A CC0 pack such as Quaternius's Universal Animation Library could replace the
character later with the same `CharacterModel` API.
