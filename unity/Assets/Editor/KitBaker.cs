// Bakes msp's kit (Assets/Resources/Kit/**.glb, imported by glTFast) into the meshes Kit.cs
// draws: Assets/Resources/KitMeshes/<sub>/<name>.asset plus index.json.
//
// Like msp's Kit._merge: every submesh of a model goes into one, with each vertex's material
// number (Kit.MaterialId of the Blender material name) in uv3.x, so a building is one draw
// call. Cars keep one submesh per material (msp doesn't merge them either). Child transforms
// inside the .glb are baked into the vertices so a mesh sits at its model's origin.
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;

namespace MSP.EditorTools
{
    public static class KitBaker
    {
        const string Src = "Assets/Resources/Kit";
        const string Dst = "Assets/Resources/KitMeshes";

        [System.Serializable]
        class Index { public Kit.Entry[] entries; }

        // top-level kit folders whose names are used bare, as msp's Kit does
        static readonly HashSet<string> BareSubs = new HashSet<string> { "buildings", "roads", "props", "cars" };

        [MenuItem("MSP/Bake kit meshes")]
        public static void Bake()
        {
            if (!AssetDatabase.IsValidFolder(Src))
            {
                Debug.LogWarning("[MSP] KitBaker: no " + Src);
                return;
            }
            Directory.CreateDirectory(Dst);
            var entries = new List<Kit.Entry>();
            string[] guids = AssetDatabase.FindAssets("t:GameObject", new[] { Src });
            int n = 0;
            foreach (string g in guids)
            {
                string path = AssetDatabase.GUIDToAssetPath(g);
                if (!path.EndsWith(".glb")) continue;
                string rel = path.Substring(Src.Length + 1);          // e.g. buildings/r_1_1_a.glb
                string sub = rel.Contains("/") ? rel.Substring(0, rel.IndexOf('/')) : "";
                string file = Path.GetFileNameWithoutExtension(rel);
                string name = BareSubs.Contains(sub) ? file : sub + "/" + file;
                var root = AssetDatabase.LoadAssetAtPath<GameObject>(path);
                if (root == null) continue;
                bool merge = sub != "cars";
                Mesh mesh = Combine(root, merge, out string[] keys);
                if (mesh == null) { Debug.LogWarning("[MSP] KitBaker: no mesh in " + path); continue; }
                mesh.name = name;
                string outDir = Path.Combine(Dst, sub).Replace('\\', '/');
                Directory.CreateDirectory(outDir);
                string outPath = outDir + "/" + file + ".asset";
                var old = AssetDatabase.LoadAssetAtPath<Mesh>(outPath);
                if (old != null)
                {
                    EditorUtility.CopySerialized(mesh, old);
                    EditorUtility.SetDirty(old);
                }
                else AssetDatabase.CreateAsset(mesh, outPath);
                entries.Add(new Kit.Entry
                {
                    name = name,
                    sub = sub,
                    path = outPath.Substring("Assets/Resources/".Length, outPath.Length - "Assets/Resources/".Length - ".asset".Length),
                    merged = merge,
                    keys = merge ? null : keys,
                });
                n++;
            }
            File.WriteAllText(Dst + "/index.json", JsonUtility.ToJson(new Index { entries = entries.ToArray() }, true));
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
            Debug.Log($"[MSP] KitBaker: baked {n} kit meshes");
        }

        static Mesh Combine(GameObject root, bool merge, out string[] keys)
        {
            var verts = new List<Vector3>();
            var norms = new List<Vector3>();
            var cols = new List<Color>();
            var uv = new List<Vector2>();
            var uv2 = new List<Vector2>();
            var ids = new List<Vector2>();
            var subTris = new List<List<int>>();
            var subKeys = new List<string>();
            var keyIndex = new Dictionary<string, int>();
            bool anyColor = false, anyUv2 = false;
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
                var mc = m.colors;
                var mu = m.uv;
                var mu2 = m.uv2;
                if (mc != null && mc.Length == mv.Length) anyColor = true;
                if (mu2 != null && mu2.Length == mv.Length) anyUv2 = true;
                int baseV = verts.Count;
                for (int i = 0; i < mv.Length; i++)
                {
                    verts.Add(xf.MultiplyPoint3x4(mv[i]));
                    norms.Add(mn != null && mn.Length == mv.Length ? nxf.MultiplyVector(mn[i]).normalized : Vector3.up);
                    cols.Add(mc != null && mc.Length == mv.Length ? mc[i] : Color.white);
                    uv.Add(mu != null && mu.Length == mv.Length ? mu[i] : Vector2.zero);
                    uv2.Add(mu2 != null && mu2.Length == mv.Length ? mu2[i] : Vector2.zero);
                    ids.Add(Vector2.zero);
                }
                var mats = mr.sharedMaterials;
                for (int s = 0; s < m.subMeshCount; s++)
                {
                    string key = Kit.CleanName(s < mats.Length && mats[s] != null ? mats[s].name : "Wall");
                    if (!Kit.HasMaterial(key))
                    {
                        Debug.LogWarning($"[MSP] Kit: unknown material {key} in {root.name}");
                        key = "Wall";
                    }
                    if (root.name.StartsWith("car_") && key == "Glass") key = "CarGlass";
                    var tris = m.GetTriangles(s);
                    int id = Kit.MaterialId(key);
                    var desc = m.GetSubMesh(s);
                    for (int i = 0; i < tris.Length; i++) ids[baseV + tris[i]] = new Vector2(id, 0);
                    int target;
                    if (merge) target = 0;
                    else if (!keyIndex.TryGetValue(key, out target))
                    {
                        target = subTris.Count;
                        keyIndex[key] = target;
                        subKeys.Add(key);
                    }
                    while (subTris.Count <= target) subTris.Add(new List<int>());
                    foreach (int t in tris) subTris[target].Add(t + baseV);
                }
            }
            keys = subKeys.ToArray();
            if (verts.Count == 0) return null;
            var mesh = new Mesh { indexFormat = verts.Count > 65000 ? UnityEngine.Rendering.IndexFormat.UInt32 : UnityEngine.Rendering.IndexFormat.UInt16 };
            mesh.SetVertices(verts);
            mesh.SetNormals(norms);
            if (anyColor) mesh.SetColors(cols);
            mesh.SetUVs(0, uv);
            if (anyUv2) mesh.SetUVs(1, uv2);
            mesh.SetUVs(3, ids);
            mesh.subMeshCount = subTris.Count;
            for (int s = 0; s < subTris.Count; s++) mesh.SetTriangles(subTris[s], s);
            mesh.RecalculateBounds();
            mesh.UploadMeshData(false);
            return mesh;
        }
    }
}
