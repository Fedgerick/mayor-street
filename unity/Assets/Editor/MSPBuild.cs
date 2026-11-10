// Batch-mode setup and Windows build for the Unity port of msp.
//
//   Unity.exe -batchmode -quit -projectPath unity -executeMethod MSP.EditorTools.MSPBuild.Setup
//   Unity.exe -batchmode -quit -projectPath unity -executeMethod MSP.EditorTools.MSPBuild.BuildWindows
//
// Setup copies msp's .glb kit from ../assets/kit into Assets/Resources/Kit (glTFast imports
// them), makes the URP asset, sets the player settings and writes the one boot scene.
// BuildWindows runs Setup, then builds unity/Build/MayorStreetPlanet/MayorStreetPlanet.exe.
using System.IO;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace MSP.EditorTools
{
    public static class MSPBuild
    {
        const string ScenePath = "Assets/Scenes/Main.unity";
        const string UrpDir = "Assets/Settings";

        [MenuItem("MSP/Setup project")]
        public static void Setup()
        {
            // URP first: glTFast picks its shaders from the active pipeline when it imports a
            // .glb, so a kit imported before the URP asset is set gets built-in shaders that URP
            // only draws in the shadow pass (invisible buildings with shadows).
            MakeUrp();
            CopyKit();
            CopyCharacters();
            ReimportKitIfBuiltIn();
            KitBaker.Bake();
            MakeTemplateMaterials();
            PlayerSetup();
            MakeScene();
            AssetDatabase.SaveAssets();
            Debug.Log("[MSP] setup done");
        }

        [MenuItem("MSP/Build Windows")]
        public static void BuildWindows()
        {
            Setup();
            string outDir = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "Build", "MayorStreetPlanet"));
            Directory.CreateDirectory(outDir);
            var opts = new BuildPlayerOptions
            {
                scenes = new[] { ScenePath },
                locationPathName = Path.Combine(outDir, "MayorStreetPlanet.exe"),
                target = BuildTarget.StandaloneWindows64,
                options = BuildOptions.None,
            };
            BuildReport r = BuildPipeline.BuildPlayer(opts);
            Debug.Log($"[MSP] build {r.summary.result}: {r.summary.totalErrors} errors, {r.summary.totalSize / 1e6:F1} MB -> {outDir}");
            if (Application.isBatchMode)
                EditorApplication.Exit(r.summary.result == BuildResult.Succeeded ? 0 : 1);
        }

        /// <summary>msp's street person (../player/assets/character.glb) -> Assets/Resources/Characters,
        /// imported with legacy animation clips (CharacterModel blends them on an Animation component).</summary>
        static void CopyCharacters()
        {
            string src = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "player", "assets", "character.glb"));
            string dstDir = Path.Combine(Application.dataPath, "Resources", "Characters");
            const string asset = "Assets/Resources/Characters/character.glb";
            if (!File.Exists(src))
            {
                Debug.LogWarning("[MSP] no msp character at " + src);
                return;
            }
            Directory.CreateDirectory(dstDir);
            string to = Path.Combine(dstDir, "character.glb");
            if (!File.Exists(to) || File.GetLastWriteTimeUtc(to) < File.GetLastWriteTimeUtc(src))
            {
                File.Copy(src, to, true);
                AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
            }
            SetLegacyAnimation(asset);
            // A failed import leaves only glTFast's ImportLog (glTFast 6.14.1 threw a job-safety
            // error in SortAndNormalizeBoneWeightsJob on this skinned model; 6.20.0 is fine): retry.
            if (AssetDatabase.LoadAssetAtPath<GameObject>(asset) == null)
            {
                Debug.LogWarning("[MSP] character.glb has no model after import; reimporting");
                AssetDatabase.ImportAsset(asset, ImportAssetOptions.ForceUpdate);
                if (AssetDatabase.LoadAssetAtPath<GameObject>(asset) == null)
                    Debug.LogError("[MSP] character.glb failed to import (see its Import Logs)");
            }
        }

        /// <summary>glTFast's importer setting for animation clips, set to Legacy by reflection (so this
        /// file doesn't need glTFast's editor assembly to compile). Reimports when it changed.</summary>
        static void SetLegacyAnimation(string path)
        {
            var imp = AssetImporter.GetAtPath(path);
            if (imp == null) { Debug.LogWarning("[MSP] no importer for " + path); return; }
            const System.Reflection.BindingFlags F = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic;
            object settings = null;
            System.Reflection.FieldInfo holder = null;
            foreach (var name in new[] { "importSettings", "editorImportSettings", "m_ImportSettings" })
            {
                holder = imp.GetType().GetField(name, F);
                if (holder != null) { settings = holder.GetValue(imp); break; }
            }
            if (settings == null) { Debug.LogWarning($"[MSP] {imp.GetType().Name} has no import settings field; check the character's animation import by hand"); return; }
            var field = settings.GetType().GetField("animationMethod", F);
            var prop = field == null ? settings.GetType().GetProperty("AnimationMethod", F) : null;
            System.Type et = field != null ? field.FieldType : prop?.PropertyType;
            if (et == null || !et.IsEnum) { Debug.LogWarning("[MSP] glTFast import settings have no animationMethod"); return; }
            object legacy = System.Enum.Parse(et, "Legacy");
            object now = field != null ? field.GetValue(settings) : prop.GetValue(settings);
            if (Equals(now, legacy)) return;
            if (field != null) field.SetValue(settings, legacy); else prop.SetValue(settings, legacy);
            if (settings.GetType().IsValueType) holder.SetValue(imp, settings);
            EditorUtility.SetDirty(imp);
            imp.SaveAndReimport();
            Debug.Log($"[MSP] {path}: animation import set to Legacy (was {now})");
        }

        /// <summary>msp's kit (../assets/kit/**.glb) -> Assets/Resources/Kit, keeping the folders.</summary>
        static void CopyKit()
        {
            string src = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "assets", "kit"));
            string dst = Path.Combine(Application.dataPath, "Resources", "Kit");
            if (!Directory.Exists(src))
            {
                Debug.LogWarning("[MSP] no msp kit at " + src);
                return;
            }
            int n = 0;
            foreach (string f in Directory.GetFiles(src, "*.glb", SearchOption.AllDirectories))
            {
                string rel = Path.GetRelativePath(src, f);
                string to = Path.Combine(dst, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                if (!File.Exists(to) || File.GetLastWriteTimeUtc(to) < File.GetLastWriteTimeUtc(f))
                {
                    File.Copy(f, to, true);
                    n++;
                }
            }
            AssetDatabase.Refresh();
            Debug.Log($"[MSP] kit: {n} .glb copied");
        }

        /// <summary>Reimports Assets/Resources/Kit when its models carry glTFast's built-in RP
        /// shaders (they were imported before URP was the active pipeline).</summary>
        static void ReimportKitIfBuiltIn()
        {
            const string kit = "Assets/Resources/Kit";
            if (!AssetDatabase.IsValidFolder(kit)) return;
            string[] guids = AssetDatabase.FindAssets("t:GameObject", new[] { kit });
            if (guids.Length == 0) return;
            var go = AssetDatabase.LoadAssetAtPath<GameObject>(AssetDatabase.GUIDToAssetPath(guids[0]));
            var r = go != null ? go.GetComponentInChildren<Renderer>() : null;
            var sh = r != null && r.sharedMaterial != null ? r.sharedMaterial.shader : null;
            if (sh == null || !sh.name.StartsWith("glTF/")) return;
            Debug.Log($"[MSP] kit was imported with built-in shader {sh.name}; reimporting for URP");
            AssetDatabase.ImportAsset(kit, ImportAssetOptions.ImportRecursive | ImportAssetOptions.ForceUpdate);
        }

        static void MakeUrp()
        {
            Directory.CreateDirectory(UrpDir);
            string rendererPath = UrpDir + "/MSP_Renderer.asset";
            string assetPath = UrpDir + "/MSP_URP.asset";
            var asset = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>(assetPath);
            if (asset == null)
            {
                var data = ScriptableObject.CreateInstance<UniversalRendererData>();
                AssetDatabase.CreateAsset(data, rendererPath);
                asset = UniversalRenderPipelineAsset.Create(data);
                AssetDatabase.CreateAsset(asset, assetPath);
            }
            // msp Med on the 5700U: one cascade-friendly shadow distance, MSAA off (FXAA in post), HDR on
            asset.shadowDistance = 150f;
            asset.shadowCascadeCount = 2;
            asset.msaaSampleCount = 1;
            asset.supportsHDR = true;
            asset.renderScale = 1f;
            EditorUtility.SetDirty(asset);
            GraphicsSettings.defaultRenderPipeline = asset;
            for (int i = 0; i < QualitySettings.names.Length; i++)
            {
                QualitySettings.SetQualityLevel(i, false);
                QualitySettings.renderPipeline = asset;
            }
        }

        static void MakeTemplateMaterials()
        {
            Directory.CreateDirectory("Assets/Resources/Mats");
            void Save(string name, string shader)
            {
                string path = "Assets/Resources/Mats/" + name + ".mat";
                if (AssetDatabase.LoadAssetAtPath<Material>(path) != null) return;
                var m = new Material(Shader.Find(shader)) { enableInstancing = true };
                AssetDatabase.CreateAsset(m, path);
            }
            Save("Lit", "Universal Render Pipeline/Lit");
            Save("Unlit", "Universal Render Pipeline/Unlit");
        }

        static void PlayerSetup()
        {
            PlayerSettings.companyName = "Fedge";
            PlayerSettings.productName = "Mayor Street Planet (Unity)";
            PlayerSettings.bundleVersion = MSP.Version.Number;
            PlayerSettings.fullScreenMode = FullScreenMode.FullScreenWindow;
            PlayerSettings.defaultIsNativeResolution = true;
            PlayerSettings.runInBackground = true;
            PlayerSettings.colorSpace = ColorSpace.Linear;
            PlayerSettings.SetGraphicsAPIs(BuildTarget.StandaloneWindows64, new[] { GraphicsDeviceType.Direct3D11, GraphicsDeviceType.Vulkan });
            string icon = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "assets", "icon", "icon.png"));
            string iconDst = "Assets/Icon/icon.png";
            if (File.Exists(icon) && !File.Exists(iconDst))
            {
                Directory.CreateDirectory("Assets/Icon");
                File.Copy(icon, iconDst);
                AssetDatabase.ImportAsset(iconDst);
            }
            var tex = AssetDatabase.LoadAssetAtPath<Texture2D>(iconDst);
            if (tex != null)
                PlayerSettings.SetIcons(UnityEditor.Build.NamedBuildTarget.Unknown, new[] { tex }, IconKind.Any);
            KeepInstancingVariants();
        }

        /// <summary>The city's kit, beacon and other instanced materials are made at runtime, so no
        /// material asset in the build has GPU instancing on. With Graphics settings' default
        /// "Strip Unused" the INSTANCING_ON variants are left out of the player, and every
        /// Graphics.RenderMeshInstanced draw comes out invisible (no error). Keep them all.</summary>
        static void KeepInstancingVariants()
        {
            var gs = AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/GraphicsSettings.asset");
            if (gs == null || gs.Length == 0) { Debug.LogWarning("[MSP] no GraphicsSettings asset"); return; }
            var so = new SerializedObject(gs[0]);
            var p = so.FindProperty("m_InstancingStripping");
            if (p == null) { Debug.LogWarning("[MSP] GraphicsSettings has no m_InstancingStripping"); return; }
            const int KeepAll = 2; // InstancingStripping: StripUnused 0, StripAll 1, KeepAll 2
            if (p.intValue != KeepAll)
            {
                p.intValue = KeepAll;
                so.ApplyModifiedPropertiesWithoutUndo();
                AssetDatabase.SaveAssets();
                Debug.Log("[MSP] Graphics settings: keep all instancing variants");
            }
        }

        static void MakeScene()
        {
            if (File.Exists(ScenePath)) return;
            Directory.CreateDirectory("Assets/Scenes");
            var scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            var boot = new GameObject("Main");
            boot.AddComponent<MSP.Main>();
            EditorSceneManager.SaveScene(scene, ScenePath);
            EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
        }
    }
}
