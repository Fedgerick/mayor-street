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
