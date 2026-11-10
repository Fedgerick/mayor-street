// Copies msp's round-3 car kit (../vehicles/assets/*.glb and specs.json) into the project and
// bakes each model into Assets/Resources/VehicleMeshes/<name>.asset: one mesh, submesh 0 the
// body (every VehBody part) and 1 the glass (VehGlass), keeping uv and uv2, which carry the part
// id, palette and wheel centres the vehicle shader reads. The .glb files go outside Resources so
// the build only carries the baked meshes.
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace MSP.EditorTools
{
    public static class VehicleBaker
    {
        const string Src = "Assets/MSPImport/Vehicles";
        const string Dst = "Assets/Resources/VehicleMeshes";
        const string SpecDir = "Assets/Resources/Vehicles";

        public static void CopyVehicles()
        {
            string src = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "vehicles", "assets"));
            if (!Directory.Exists(src)) { Debug.LogWarning("[MSP] no msp vehicles at " + src); return; }
            string dst = Path.GetFullPath(Path.Combine(Application.dataPath, "..", Src));
            Directory.CreateDirectory(dst);
            int n = 0;
            foreach (var f in Directory.GetFiles(src, "*.glb"))
            {
                string to = Path.Combine(dst, Path.GetFileName(f));
                if (File.Exists(to) && File.GetLastWriteTimeUtc(to) >= File.GetLastWriteTimeUtc(f)) continue;
                File.Copy(f, to, true);
                n++;
            }
            string spec = Path.Combine(src, "specs.json");
            if (File.Exists(spec))
            {
                string sd = Path.GetFullPath(Path.Combine(Application.dataPath, "..", SpecDir));
                Directory.CreateDirectory(sd);
                File.Copy(spec, Path.Combine(sd, "specs.json"), true);
            }
            AssetDatabase.Refresh();
            Debug.Log($"[MSP] vehicles: {n} .glb copied");
        }

        [MenuItem("MSP/Bake vehicle meshes")]
        public static void Bake()
        {
            if (!AssetDatabase.IsValidFolder(Src)) { Debug.LogWarning("[MSP] VehicleBaker: no " + Src); return; }
            Directory.CreateDirectory(Dst);
            int n = 0;
            foreach (string g in AssetDatabase.FindAssets("t:GameObject", new[] { Src }))
            {
                string path = AssetDatabase.GUIDToAssetPath(g);
                if (!path.EndsWith(".glb")) continue;
                var root = AssetDatabase.LoadAssetAtPath<GameObject>(path);
                if (root == null) continue;
                string name = Path.GetFileNameWithoutExtension(path);
                var mesh = Combine(root);
                if (mesh == null) { Debug.LogWarning("[MSP] VehicleBaker: no mesh in " + path); continue; }
                mesh.name = name;
                string outPath = Dst + "/" + name + ".asset";
                var old = AssetDatabase.LoadAssetAtPath<Mesh>(outPath);
                if (old != null)
                {
                    EditorUtility.CopySerialized(mesh, old);
                    EditorUtility.SetDirty(old);
                }
                else AssetDatabase.CreateAsset(mesh, outPath);
                n++;
            }
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Debug.Log($"[MSP] VehicleBaker: baked {n} vehicle meshes");
        }

        static Mesh Combine(GameObject root)
        {
            var verts = new List<Vector3>();
            var norms = new List<Vector3>();
            var uv = new List<Vector2>();
            var uv2 = new List<Vector2>();
            var body = new List<int>();
            var glass = new List<int>();
            Matrix4x4 toRoot = root.transform.worldToLocalMatrix;
            foreach (var mf in root.GetComponentsInChildren<MeshFilter>(true))
            {
                var m = mf.sharedMesh;
                var mr = mf.GetComponent<MeshRenderer>();
                if (m == null || mr == null) continue;
                Matrix4x4 xf = toRoot * mf.transform.localToWorldMatrix;
                Matrix4x4 nxf = xf.inverse.transpose;
                var mv = m.vertices;
                var mn = m.normals;
                var mu = m.uv;
                var mu2 = m.uv2;
                int baseV = verts.Count;
                for (int i = 0; i < mv.Length; i++)
                {
                    verts.Add(xf.MultiplyPoint3x4(mv[i]));
                    norms.Add(mn != null && mn.Length == mv.Length ? nxf.MultiplyVector(mn[i]).normalized : Vector3.up);
                    uv.Add(mu != null && mu.Length == mv.Length ? mu[i] : Vector2.zero);
                    uv2.Add(mu2 != null && mu2.Length == mv.Length ? mu2[i] : Vector2.zero);
                }
                var mats = mr.sharedMaterials;
                for (int s = 0; s < m.subMeshCount; s++)
                {
                    string mat = s < mats.Length && mats[s] != null ? mats[s].name : "";
                    var to = mat.Contains("VehGlass") ? glass : body;
                    foreach (int t in m.GetTriangles(s)) to.Add(t + baseV);
                }
            }
            if (verts.Count == 0) return null;
            var mesh = new Mesh { indexFormat = verts.Count > 65000 ? UnityEngine.Rendering.IndexFormat.UInt32 : UnityEngine.Rendering.IndexFormat.UInt16 };
            mesh.SetVertices(verts);
            mesh.SetNormals(norms);
            mesh.SetUVs(0, uv);
            mesh.SetUVs(1, uv2);
            mesh.subMeshCount = 2;
            mesh.SetTriangles(body, 0);
            mesh.SetTriangles(glass, 1);
            mesh.RecalculateBounds();
            mesh.UploadMeshData(false);
            return mesh;
        }
    }
}
