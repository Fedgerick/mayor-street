# Mayor Street Planet: Unity port

A C# port of msp (the Godot game in the rest of this repo) for Unity 6.3 LTS (6000.3.23f1, URP).
Plan: https://claude.ai/artifact/SLwjPQqD3pHzQeSNR1DzkG

- `Assets/Scripts/Core/GMath.cs`: Godot-style `GBasis`/`GXform`. Game logic stays in Godot's
  right-handed space so GDScript ports line for line; `G.U(...)` mirrors across X at the edge
  to Unity's left-handed space (the same mirror glTFast applies to the .glb models).
- `Assets/Scripts/Planet/Planet.cs`: port of planet/planet.gd (flat map metres <-> the ball).
- `Assets/Editor/MSPBuild.cs`: batch setup (copies `../assets/kit/**.glb` into
  `Assets/Resources/Kit`, URP asset, player settings, boot scene) and the Windows build.

Build on Windows:

    "C:\Program Files\Unity\Hub\Editor\6000.3.23f1\Editor\Unity.exe" -batchmode -quit -projectPath unity -executeMethod MSP.EditorTools.MSPBuild.BuildWindows -logFile build.log

Output: `unity/Build/MayorStreetPlanet/MayorStreetPlanet.exe`. Screenshot check:
`MayorStreetPlanet.exe --screenshot=C:\path\shot.png --view=1182,204,230,-35,-30 --hour=10.5`.
