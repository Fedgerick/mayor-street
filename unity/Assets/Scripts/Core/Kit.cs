// Port of scripts/kit.gd: msp's Blender kit with every Blender material swapped for one
// stylized shader (MSP/Kit), so the whole city renders with a handful of materials.
//
// Models with several materials are merged into one submesh carrying each vertex's material
// number (uv3.x), so a building is one draw call (msp PERFORMANCE.md). The merging happens at
// build time in the editor (Editor/KitBaker.cs writes Resources/KitMeshes), because imported
// meshes are not readable in a player.
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public static class Kit
    {
        /// <summary>One row of msp's MATS table.</summary>
        public struct Mat
        {
            public Color baseColor; public int tintSrc; public float tintAmount; public int pattern; public int kind;
            public float rough, metal, spec; public bool groundLevel;
            public Mat(Color c, int ts, float ta, int p, int k, float r, float m, float s, bool g)
            { baseColor = c; tintSrc = ts; tintAmount = ta; pattern = p; kind = k; rough = r; metal = m; spec = s; groundLevel = g; }
        }

        // name: base colour, tint_src, tint_amount, pattern, kind, roughness, metallic, specular, ground_level
        public static readonly (string name, Mat m)[] MATS =
        {
            ("Wall", new Mat(new Color(0.84f, 0.81f, 0.76f), 1, 1.0f, 1, 0, 0.9f, 0f, 0.4f, false)),
            ("Accent", new Mat(new Color(0.74f, 0.7f, 0.66f), 1, 0.8f, 3, 0, 0.85f, 0f, 0.4f, false)),
            ("Brick", new Mat(new Color(0.78f, 0.42f, 0.32f), 1, 0.35f, 2, 0, 0.92f, 0f, 0.3f, false)),
            ("Concrete", new Mat(new Color(0.6f, 0.59f, 0.57f), 0, 0f, 3, 0, 0.9f, 0f, 0.4f, false)),
            ("Trim", new Mat(new Color(0.8f, 0.79f, 0.75f), 0, 0f, 0, 0, 0.7f, 0f, 0.5f, false)),
            ("Roof", new Mat(new Color(0.42f, 0.42f, 0.43f), 0, 0f, 11, 0, 0.95f, 0f, 0.3f, false)),
            ("RoofTile", new Mat(new Color(0.62f, 0.36f, 0.3f), 2, 0.45f, 5, 0, 0.8f, 0f, 0.4f, false)),
            ("Glass", new Mat(new Color(0.1f, 0.14f, 0.18f), 0, 0f, 0, 1, 0.05f, 0.1f, 0.8f, false)),
            ("Door", new Mat(new Color(0.55f, 0.4f, 0.3f), 2, 0.6f, 0, 0, 0.6f, 0f, 0.5f, false)),
            ("Metal", new Mat(new Color(0.55f, 0.58f, 0.61f), 0, 0f, 4, 0, 0.45f, 0.45f, 0.5f, false)),
            ("Awning", new Mat(new Color(0.85f, 0.85f, 0.85f), 2, 1.0f, 9, 0, 0.8f, 0f, 0.3f, false)),
            ("Sign", new Mat(new Color(1f, 1f, 1f), 2, 1.0f, 0, 2, 0.4f, 0f, 0.5f, false)),
            ("Grass", new Mat(new Color(0.35f, 0.55f, 0.2f), 0, 0f, 7, 0, 0.95f, 0f, 0.2f, true)),
            ("Paving", new Mat(new Color(0.6f, 0.58f, 0.55f), 0, 0f, 6, 0, 0.85f, 0f, 0.4f, true)),
            ("Asphalt", new Mat(new Color(0.19f, 0.19f, 0.2f), 0, 0f, 8, 0, 0.88f, 0f, 0.35f, true)),
            ("Sidewalk", new Mat(new Color(0.58f, 0.57f, 0.55f), 0, 0f, 10, 0, 0.85f, 0f, 0.4f, true)),
            ("Curb", new Mat(new Color(0.66f, 0.66f, 0.64f), 0, 0f, 0, 0, 0.8f, 0f, 0.4f, true)),
            ("Marking", new Mat(new Color(0.85f, 0.85f, 0.82f), 0, 0f, 0, 0, 0.6f, 0f, 0.5f, true)),
            ("MarkingYellow", new Mat(new Color(0.95f, 0.75f, 0.2f), 0, 0f, 0, 0, 0.6f, 0f, 0.5f, true)),
            ("Bark", new Mat(new Color(0.4f, 0.29f, 0.2f), 0, 0f, 0, 0, 0.95f, 0f, 0.2f, false)),
            ("Leaves", new Mat(new Color(1f, 1f, 1f), 1, 1.0f, 0, 4, 0.9f, 0f, 0.25f, false)),
            ("Lamp", new Mat(new Color(1f, 0.95f, 0.85f), 0, 0f, 0, 3, 0.4f, 0f, 0.5f, false)),
            ("CarBody", new Mat(new Color(1f, 1f, 1f), 1, 1.0f, 0, 0, 0.3f, 0.25f, 0.7f, false)),
            ("Tire", new Mat(new Color(0.07f, 0.07f, 0.08f), 0, 0f, 0, 0, 0.9f, 0f, 0.2f, false)),
            ("Headlight", new Mat(new Color(1f, 1f, 0.95f), 0, 0f, 0, 5, 0.2f, 0f, 0.8f, false)),
            ("Water", new Mat(new Color(0.2f, 0.55f, 0.7f), 0, 0f, 0, 7, 0.05f, 0f, 0.8f, false)),
            ("Taillight", new Mat(new Color(0.7f, 0.05f, 0.05f), 0, 0f, 0, 6, 0.3f, 0f, 0.6f, false)),
        };

        // Wall tints per zone (instance colour) and accent tints (instance custom).
        public static readonly Color[][] WALLS =
        {
            new[] { new Color(1, 1, 1) },
            new[] { new Color(0.98f, 0.93f, 0.82f), new Color(0.86f, 0.93f, 0.98f), new Color(0.93f, 0.85f, 0.72f), new Color(0.82f, 0.9f, 0.8f),
                    new Color(0.98f, 0.82f, 0.74f), new Color(1.0f, 0.98f, 0.95f), new Color(0.85f, 0.85f, 0.88f), new Color(0.96f, 0.9f, 0.6f) },
            new[] { new Color(0.95f, 0.95f, 0.95f), new Color(0.85f, 0.87f, 0.9f), new Color(0.93f, 0.88f, 0.78f), new Color(0.8f, 0.62f, 0.5f),
                    new Color(0.7f, 0.78f, 0.88f), new Color(0.98f, 0.96f, 0.9f), new Color(0.75f, 0.75f, 0.75f), new Color(0.9f, 0.8f, 0.7f) },
            new[] { new Color(0.75f, 0.75f, 0.73f), new Color(0.62f, 0.66f, 0.7f), new Color(0.7f, 0.55f, 0.45f), new Color(0.62f, 0.68f, 0.58f),
                    new Color(0.8f, 0.78f, 0.7f), new Color(0.55f, 0.6f, 0.68f), new Color(0.68f, 0.68f, 0.66f), new Color(0.75f, 0.65f, 0.5f) },
        };
        public static readonly Color[] ACCENTS =
        {
            new Color(0.85f, 0.22f, 0.2f), new Color(0.1f, 0.6f, 0.62f), new Color(0.18f, 0.3f, 0.6f), new Color(0.95f, 0.55f, 0.12f),
            new Color(0.25f, 0.6f, 0.3f), new Color(0.55f, 0.3f, 0.65f), new Color(0.95f, 0.8f, 0.2f), new Color(0.55f, 0.35f, 0.22f),
        };
        public static readonly Color[] LEAF_TINTS =
        {
            new Color(0.36f, 0.6f, 0.22f), new Color(0.3f, 0.52f, 0.2f), new Color(0.45f, 0.62f, 0.22f), new Color(0.26f, 0.46f, 0.22f),
            new Color(0.55f, 0.62f, 0.2f), new Color(0.32f, 0.56f, 0.3f),
        };
        public static readonly Color[] CAR_TINTS =
        {
            new Color(0.85f, 0.12f, 0.1f), new Color(0.95f, 0.95f, 0.95f), new Color(0.12f, 0.12f, 0.14f), new Color(0.15f, 0.3f, 0.7f),
            new Color(0.7f, 0.72f, 0.75f), new Color(0.95f, 0.75f, 0.1f), new Color(0.1f, 0.45f, 0.3f), new Color(0.55f, 0.1f, 0.15f),
        };

        public static readonly Dictionary<string, string[]> NAMES = new Dictionary<string, string[]>
        {
            { "buildings", new[] { "r_1_1", "r_2_1", "r_3_1", "r_3_2", "c_1_1", "c_2_1", "c_3_1", "c_3_2", "i_1_1", "i_2_1", "i_3_1", "i_3_2" } },
            { "roads", new[] { "road_straight", "road_corner", "road_t", "road_cross", "road_end", "road_single" } },
            { "props", new[] { "street_lamp", "traffic_light", "tree_round_a", "tree_round_b", "tree_pine", "palm", "bush" } },
            { "cars", new[] { "car_sedan", "car_hatch", "car_van", "car_truck" } },
        };

        // ------------------------------------------------------------ materials ---

        static Dictionary<string, int> _ids;
        static List<(string name, Mat m, int kindOverride, bool wind)> _rows;

        /// <summary>The merged-table rows: msp's MATS plus LeavesWind and CarGlass.</summary>
        static void BuildRows()
        {
            if (_rows != null) return;
            _rows = new List<(string, Mat, int, bool)>();
            _ids = new Dictionary<string, int>();
            foreach (var (name, m) in MATS) _rows.Add((name, m, -1, false));
            _rows.Add(("LeavesWind", Find("Leaves"), -1, true));
            _rows.Add(("CarGlass", Find("Glass"), 7, false));
            for (int i = 0; i < _rows.Count; i++) _ids[_rows[i].name] = i;
        }

        static Mat Find(string name)
        {
            foreach (var (n, m) in MATS) if (n == name) return m;
            return MATS[0].m;
        }

        /// <summary>Row number of a material name (the uv3.x a merged mesh stores), Wall if unknown.</summary>
        public static int MaterialId(string name)
        {
            BuildRows();
            return _ids.TryGetValue(name, out int id) ? id : 0;
        }

        public static bool HasMaterial(string name)
        {
            BuildRows();
            return _ids.ContainsKey(name);
        }

        /// <summary>A Blender material name as glTFast imports it ("Wall.001" -> "Wall").</summary>
        public static string CleanName(string n)
        {
            if (string.IsNullOrEmpty(n)) return "Wall";
            int dot = n.IndexOf('.');
            if (dot > 0) n = n.Substring(0, dot);
            return n.Trim();
        }

        static Material _merged;
        static readonly Dictionary<string, Material> _single = new Dictionary<string, Material>();
        static Shader _shader;

        static Shader KitShader => _shader ??= Resources.Load<Shader>("Shaders/MSPKit");

        /// <summary>Pushes the material tables to the shaders (globals _MatA/_MatB/_MatC).</summary>
        public static void Install()
        {
            BuildRows();
            var a = new Vector4[32];
            var b = new Vector4[32];
            var c = new Vector4[32];
            for (int i = 0; i < _rows.Count && i < 32; i++)
            {
                var (_, m, ko, wind) = _rows[i];
                a[i] = new Vector4(m.baseColor.r, m.baseColor.g, m.baseColor.b, m.tintAmount);
                b[i] = new Vector4(m.rough, m.metal, m.spec, m.tintSrc);
                c[i] = new Vector4(m.pattern, ko < 0 ? m.kind : ko, wind ? 1f : 0f, m.groundLevel ? 1f : 0f);
            }
            Shader.SetGlobalVectorArray("_MatA", a);
            Shader.SetGlobalVectorArray("_MatB", b);
            Shader.SetGlobalVectorArray("_MatC", c);
            Shader.SetGlobalFloat("tile_size", Planet.TILE);
        }

        /// <summary>The one material every merged kit mesh uses.</summary>
        public static Material Merged
        {
            get
            {
                if (_merged != null) return _merged;
                _merged = new Material(KitShader) { name = "Merged", enableInstancing = true };
                _merged.SetFloat("_Merged", 1f);
                return _merged;
            }
        }

        /// <summary>A per-surface material (cars keep one per surface), msp's materials[name].</summary>
        public static Material Single(string name)
        {
            if (_single.TryGetValue(name, out var mat)) return mat;
            BuildRows();
            var row = _rows[MaterialId(name)];
            var m = row.m;
            mat = new Material(KitShader) { name = name, enableInstancing = true };
            mat.SetFloat("_Merged", 0f);
            mat.SetColor("_UBase", m.baseColor);
            mat.SetFloat("_UTintSrc", m.tintSrc);
            mat.SetFloat("_UTintAmount", m.tintAmount);
            mat.SetFloat("_UPattern", m.pattern);
            mat.SetFloat("_UKind", row.kindOverride < 0 ? m.kind : row.kindOverride);
            mat.SetFloat("_URough", m.rough);
            mat.SetFloat("_UMetal", m.metal);
            mat.SetFloat("_UWind", row.wind ? 1f : 0f);
            mat.SetFloat("_UGround", m.groundLevel ? 1f : 0f);
            _single[name] = mat;
            return mat;
        }

        // --------------------------------------------------------------- meshes ---

        /// <summary>What KitBaker wrote for one model.</summary>
        [System.Serializable]
        public class Entry
        {
            public string name;      // "r_1_1_a", "road_straight", "special/bank"
            public string sub;       // buildings, roads, props, cars, specials, civic, street
            public string path;      // Resources path of the baked Mesh
            public bool merged;      // one submesh with uv3 ids, drawn with Kit.Merged
            public string[] keys;    // per-submesh material names when not merged
        }

        [System.Serializable]
        class Index { public Entry[] entries; }

        static Dictionary<string, Entry> _entries;
        static readonly Dictionary<string, Mesh> _meshes = new Dictionary<string, Mesh>();
        static readonly Dictionary<string, List<string>> _variants = new Dictionary<string, List<string>>();

        static void LoadIndex()
        {
            if (_entries != null) return;
            _entries = new Dictionary<string, Entry>();
            var ta = Resources.Load<TextAsset>("KitMeshes/index");
            if (ta == null)
            {
                Debug.LogWarning("[MSP] no baked kit (Resources/KitMeshes/index.json): run MSP/Setup project");
                return;
            }
            var idx = JsonUtility.FromJson<Index>(ta.text);
            foreach (var e in idx.entries) _entries[e.name] = e;
            foreach (var basename in NAMES["buildings"])
            {
                var list = new List<string>();
                foreach (var v in new[] { "a", "b", "c", "d", "e", "f" })
                    if (_entries.ContainsKey(basename + "_" + v)) list.Add(basename + "_" + v);
                _variants[basename] = list;
            }
        }

        public static bool Has(string nm)
        {
            LoadIndex();
            return _entries.ContainsKey(nm) || _meshes.ContainsKey(nm);
        }

        public static Entry Info(string nm)
        {
            LoadIndex();
            return _entries.TryGetValue(nm, out var e) ? e : null;
        }

        /// <summary>The baked mesh for a kit name, or null.</summary>
        public static Mesh Mesh(string nm)
        {
            if (_meshes.TryGetValue(nm, out var m)) return m;
            LoadIndex();
            if (!_entries.TryGetValue(nm, out var e)) return null;
            m = Resources.Load<Mesh>(e.path);
            _meshes[nm] = m;
            return m;
        }

        /// <summary>Materials to draw a kit mesh with, one per submesh.</summary>
        public static Material[] MaterialsFor(string nm)
        {
            var e = Info(nm);
            if (e == null || e.merged || e.keys == null) return new[] { Merged };
            var mats = new Material[e.keys.Length];
            for (int i = 0; i < mats.Length; i++) mats[i] = Single(e.keys[i]);
            return mats;
        }

        public static List<string> Variants(string key)
        {
            LoadIndex();
            return _variants.TryGetValue(key, out var l) ? l : new List<string>();
        }

        public static readonly string[] ZONE_KEYS = { "", "r", "c", "i" };

        public static string BuildingMeshName(int zone, int stage, int size, long variant)
        {
            var list = Variants($"{ZONE_KEYS[zone]}_{stage}_{size}");
            if (list.Count == 0) return "";
            return list[(int)(variant % list.Count)];
        }

        /// <summary>The mesh for a catalog building: its own model, else a zone model of its
        /// stand-in kind, else a plain block (msp's Kit.special_mesh_name).</summary>
        public static string SpecialMeshName(string kind, int size, long variant)
        {
            var d = Catalog.GetDef(kind);
            if (d == null) return "";
            if (d.Model != "") return d.Model;
            var list = Variants($"{d.standIn}_{size}");
            if (list.Count == 0 && size <= 2) list = Variants(size == 2 ? "c_3_2" : "c_2_1");
            if (list.Count > 0) return list[(int)(variant % list.Count)];
            return Block("special/" + kind, d.size, d.height);
        }

        /// <summary>A plain block (msp's Kit._block) registered under nm: a stand-in for a missing model.</summary>
        public static string Block(string nm, float sizeTiles, float height)
        {
            if (_meshes.ContainsKey(nm)) return nm;
            float w = Mathf.Max(sizeTiles, 1f) * Planet.TILE - 2f;
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
            var src = go.GetComponent<MeshFilter>().sharedMesh;
            Object.Destroy(go);
            var verts = src.vertices;
            for (int i = 0; i < verts.Length; i++) verts[i] = new Vector3(verts[i].x * w, verts[i].y * height + height * 0.5f, verts[i].z * w);
            var ids = new Vector2[verts.Length];
            int cid = MaterialId("Concrete");
            for (int i = 0; i < ids.Length; i++) ids[i] = new Vector2(cid, 0);
            var m = new Mesh { name = nm, vertices = verts, normals = src.normals, uv = src.uv, triangles = src.triangles };
            m.SetUVs(3, ids);
            m.RecalculateBounds();
            _meshes[nm] = m;
            return nm;
        }
    }
}
