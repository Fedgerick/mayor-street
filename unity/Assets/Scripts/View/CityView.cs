// Port of scripts/city_view.gd: draws the City. On the planet: the ground and sea
// (PlanetGround), and per chunk of 8x8 cells instanced draws of roads, buildings, lamps, trees
// and props, plus box stand-ins for distant buildings and red beacons on tall towers. Owns the
// data textures the shaders read (city_map: zones, traffic, land value; lamp_map; preview_map).
//
// msp's MultiMeshes become Graphics.RenderMeshInstanced calls issued every frame, one per
// (chunk, kit mesh, submesh), with the instance colours in a MaterialPropertyBlock.
using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace MSP
{
    public class CityView : MonoBehaviour
    {
        public const int CHUNK = 4;
        public const int PLANET_CHUNK = 8;
        public const float GROW_TIME = 1.4f;
        public const float BEACON_HEIGHT = 40f;
        public const float DETAIL_MARGIN = 40f;
        const int N = 1, E = 2, S = 4, W = 8;
        static readonly (string piece, int mask)[] PIECES =
        {
            ("road_straight", 5), ("road_corner", 3), ("road_t", 7), ("road_cross", 15), ("road_end", 1), ("road_single", 0),
        };
        const float REBUILD_MS = 3f;
        const float TALLEST = 90f;
        const float FULL_IN = 60f;
        const float FULL_OUT = 160f;
        const int MAX_BATCH = 1023;

        public City city;
        int _chunk = CHUNK;
        public object services;  // CityServices once ported: unpowered buildings go dark at night

        /// <summary>Past this, buildings, trees and props give way to box stand-ins (0: never).</summary>
        public float detailDistance;
        /// <summary>Full-detail chunks further than this stop casting sun shadows (0: all cast).</summary>
        public float shadowReach;

        class Batch
        {
            public string name;
            public Mesh mesh;
            public Material[] mats;
            public Matrix4x4[] xf;
            public MaterialPropertyBlock mpb;
            public bool shadow, road;
        }

        class Chunk
        {
            public readonly List<Batch> batches = new List<Batch>();
            public Bounds bounds;
            public bool visible = true, full, cast = true, detailShown = true;
            public GameObject standin;
            public Matrix4x4[] beacons;
            public List<Vector3> lamps = new List<Vector3>();
        }

        readonly Dictionary<Vector2Int, Chunk> chunks = new Dictionary<Vector2Int, Chunk>();
        readonly List<Vector2Int> dirtyOrder = new List<Vector2Int>();
        readonly HashSet<Vector2Int> dirty = new HashSet<Vector2Int>();
        readonly HashSet<Vector2Int> detailDirty = new HashSet<Vector2Int>();
        readonly Dictionary<Vector2Int, bool> wantFull = new Dictionary<Vector2Int, bool>();
        readonly Dictionary<int, float> growing = new Dictionary<int, float>();
        readonly Dictionary<int, (string piece, int rot)> roadTable = new Dictionary<int, (string, int)>();
        readonly Dictionary<string, Vector3> _tops = new Dictionary<string, Vector3>();

        Texture2D cityTex, lampTex, previewTex;
        Color32[] _cityPx, _lampPx;
        byte[] _previewPx;
        bool _mapDirty, _lampDirty;
        float _cullT;
        Material _standinMat, _beaconMat;
        Mesh _beaconMesh;
        MaterialPropertyBlock _growMpb;
        public MeshCollider terrainCollider;

        public void Setup(City c)
        {
            city = c;
            _chunk = Planet.on ? PLANET_CHUNK : CHUNK;
            city.CellsChanged += r => { MarkRect(r); _mapDirty = true; };
            city.BuildingAdded += OnBuildingAdded;
            city.BuildingRemoved += OnBuildingRemoved;
            city.DayPassed += () => _mapDirty = true;
            BuildRoadTable();
            MakeTextures();
            Kit.Install();
            if (Planet.on)
                terrainCollider = PlanetGround.Build(transform, City.H, city.TerrainHeight, city.Landness, city.Ice);
            for (int cy = 0; cy < Mathf.CeilToInt((float)City.H / _chunk); cy++)
                for (int cx = 0; cx < Mathf.CeilToInt((float)City.W / _chunk); cx++)
                    MarkDirty(new Vector2Int(cx, cy));
            detailDirty.Clear();
            RefreshMap();
            sites = new GameObject("ConstructionSites").AddComponent<ConstructionSites>();
            sites.transform.SetParent(transform, false);
            sites.Setup(city, this);
        }

        /// <summary>Buildings going up (City.sites).</summary>
        public ConstructionSites sites;

        void MarkDirty(Vector2Int k)
        {
            if (dirty.Add(k)) dirtyOrder.Add(k);
        }

        // ------------------------------------------------------------ textures ---

        void MakeTextures()
        {
            cityTex = new Texture2D(City.W, City.H, TextureFormat.RGBA32, false, true) { name = "city_map", filterMode = FilterMode.Point, wrapMode = TextureWrapMode.Clamp };
            lampTex = new Texture2D(City.W, City.H, TextureFormat.RGBA32, false, true) { name = "lamp_map", filterMode = FilterMode.Point, wrapMode = TextureWrapMode.Clamp };
            previewTex = new Texture2D(City.W, City.H, TextureFormat.R8, false, true) { name = "preview_map", filterMode = FilterMode.Point, wrapMode = TextureWrapMode.Clamp };
            _cityPx = new Color32[City.W * City.H];
            _lampPx = new Color32[City.W * City.H];
            _previewPx = new byte[City.W * City.H];
            lampTex.SetPixels32(_lampPx);
            lampTex.Apply(false);
            previewTex.SetPixelData(_previewPx, 0);
            previewTex.Apply(false);
            Shader.SetGlobalTexture("city_map", cityTex);
            Shader.SetGlobalTexture("lamp_map", lampTex);
            Shader.SetGlobalTexture("preview_map", previewTex);
            Shader.SetGlobalVector("map_size", new Vector4(City.W, City.H, 0, 0));
            Shader.SetGlobalFloat("tile_size", City.TILE);
        }

        public void RefreshMap()
        {
            int n = City.W * City.H;
            for (int i = 0; i < n; i++)
            {
                int bid = city.bld[i];
                int built = bid >= 0 ? 32 : 0;
                int dark = 0;
                if (bid >= 0 && city.buildings[bid].Get("powered", true) == false && services != null) dark = 16;
                _cityPx[i] = new Color32(
                    (byte)(city.road[i] == 1 ? 255 : 0),
                    (byte)(city.zone[i] * 64 + built + dark),
                    (byte)Mathf.Clamp((int)(city.traffic[i] * 127f), 0, 255),
                    (byte)Mathf.Clamp((int)(city.landValue[i] * 255f), 0, 255));
            }
            cityTex.SetPixels32(_cityPx);
            cityTex.Apply(false);
            _mapDirty = false;
        }

        public void MarkMapDirty() => _mapDirty = true;

        public void SetPreview(IEnumerable<Vector2Int> cells, Color color)
        {
            Array.Clear(_previewPx, 0, _previewPx.Length);
            foreach (var c in cells)
                if (city.Inside(c.x, c.y)) _previewPx[c.y * City.W + G.Posmod(c.x, City.W)] = 255;
            previewTex.SetPixelData(_previewPx, 0);
            previewTex.Apply(false);
            Shader.SetGlobalVector("preview_color", color);
        }

        // --------------------------------------------------------------- roads ---

        static int RotMask(int m)
        {
            int r = 0;
            if ((m & N) != 0) r |= W;
            if ((m & E) != 0) r |= N;
            if ((m & S) != 0) r |= E;
            if ((m & W) != 0) r |= S;
            return r;
        }

        void BuildRoadTable()
        {
            foreach (var (piece, mask) in PIECES)
            {
                int m = mask;
                for (int k = 0; k < 4; k++)
                {
                    if (!roadTable.ContainsKey(m)) roadTable[m] = (piece, k);
                    m = RotMask(m);
                }
            }
        }

        // -------------------------------------------------------------- chunks ---

        void MarkRect(RectInt r)
        {
            if (Planet.on)
            {
                int across = Mathf.CeilToInt((float)City.W / _chunk);
                int y0 = Math.Max(r.yMin, 0) / _chunk;
                int y1 = Math.Min(r.yMax, City.H - 1) / _chunk;
                for (int cy = y0; cy <= y1; cy++)
                    for (int cx = Mathf.FloorToInt((float)r.xMin / _chunk); cx <= Mathf.FloorToInt((float)r.xMax / _chunk); cx++)
                    {
                        var k = new Vector2Int(G.Posmod(cx, across), cy);
                        MarkDirty(k);
                        detailDirty.Remove(k);
                    }
                return;
            }
            var a = new Vector2Int(Math.Max(r.xMin, 0) / _chunk, Math.Max(r.yMin, 0) / _chunk);
            var b = new Vector2Int(Math.Min(r.xMax, City.W - 1) / _chunk, Math.Min(r.yMax, City.H - 1) / _chunk);
            for (int cy = a.y; cy <= b.y; cy++)
                for (int cx = a.x; cx <= b.x; cx++)
                {
                    var k = new Vector2Int(cx, cy);
                    MarkDirty(k);
                    detailDirty.Remove(k);
                }
        }

        void OnBuildingAdded(int id, bool animate)
        {
            var b = city.buildings[id];
            _mapDirty = true;
            if (animate && isActiveAndEnabled) growing[id] = 0f;
            else MarkRect(new RectInt(b.x, b.y, b.size, b.size));
        }

        void OnBuildingRemoved(int id)
        {
            growing.Remove(id);
            _mapDirty = true;
        }

        void Update()
        {
            if (city == null) return;
            if (growing.Count > 0)
                foreach (int id in new List<int>(growing.Keys))
                {
                    float t = growing[id] + Time.deltaTime / GROW_TIME;
                    if (t >= 1f || !city.buildings.ContainsKey(id))
                    {
                        growing.Remove(id);
                        if (city.buildings.TryGetValue(id, out var b)) MarkRect(new RectInt(b.x, b.y, b.size, b.size));
                    }
                    else growing[id] = t;
                }
            // A few chunks a frame, and no more than REBUILD_MS of them after the first.
            int budget = 4;
            if (Planet.on && dirtyOrder.Count > 1)
            {
                // chunks coming into full detail first: they are next to the camera
                var sorted = new List<Vector2Int>(dirtyOrder);
                sorted.Sort((a, b) => (WantFull(b) ? 1 : 0).CompareTo(WantFull(a) ? 1 : 0));
                dirtyOrder.Clear();
                dirtyOrder.AddRange(sorted);
            }
            var sw = System.Diagnostics.Stopwatch.StartNew();
            while (dirtyOrder.Count > 0)
            {
                if (budget <= 0 || (budget < 4 && sw.Elapsed.TotalMilliseconds > REBUILD_MS)) break;
                var key = dirtyOrder[0];
                dirtyOrder.RemoveAt(0);
                dirty.Remove(key);
                RebuildChunk(key);
                budget--;
                _lampDirty = true;
                if (!detailDirty.Contains(key)) _mapDirty = true;
                detailDirty.Remove(key);
            }
            if (_mapDirty) RefreshMap();
            if (_lampDirty)
            {
                lampTex.SetPixels32(_lampPx);
                lampTex.Apply(false);
                _lampDirty = false;
            }
            if (Planet.on)
            {
                _cullT -= Time.deltaTime;
                if (_cullT <= 0f)
                {
                    _cullT = 0.1f;
                    Cull();
                }
            }
            Draw();
        }

        /// <summary>Whether the chunk holding cell (x, y) is in sight (not behind the horizon).</summary>
        public bool CellVisible(int x, int y) =>
            !chunks.TryGetValue(new Vector2Int(G.Posmod(x, City.W) / _chunk, y / _chunk), out var ch) || ch.visible;

        public int ChunkSize => _chunk;

        bool WantFull(Vector2Int k) => wantFull.TryGetValue(k, out bool v) && v;

        static Vector3 EyeGodot()
        {
            var cam = Camera.main;
            return cam != null ? G.FromU(cam.transform.position) : Vector3.zero;
        }

        /// <summary>msp: hide the chunks behind the horizon, and give full detail only to the near ones.</summary>
        void Cull()
        {
            var cam = Camera.main;
            if (!Planet.on || cam == null) return;
            Vector3 eye = G.FromU(cam.transform.position);
            Vector3 fe = Planet.Flat(eye);
            float reach = detailDistance > 0f ? detailDistance : float.PositiveInfinity;
            float half = _chunk * City.TILE * 0.7f;
            foreach (var kv in chunks)
            {
                var key = kv.Key;
                var ch = kv.Value;
                var c = new Vector3((key.x * _chunk + _chunk * 0.5f) * City.TILE, 0f, (key.y * _chunk + _chunk * 0.5f) * City.TILE);
                ch.visible = Planet.AboveHorizon(eye, Planet.Warp(c), TALLEST + half);
                float d = new Vector3(Planet.Fdx(fe.x, c.x), fe.y, c.z - fe.z).magnitude;
                bool was = WantFull(key);
                bool want = ch.visible && d < reach + half + (was ? FULL_OUT : FULL_IN);
                wantFull[key] = want;
                if (want != ch.full && !dirty.Contains(key))
                {
                    MarkDirty(key);
                    detailDirty.Add(key);
                }
                ch.cast = shadowReach <= 0f || d < shadowReach + half;
                // the stand-in takes over from the detail at detailDistance (msp: visibility ranges)
                ch.detailShown = detailDistance <= 0f || d < detailDistance + half + DETAIL_MARGIN;
                if (ch.standin != null) ch.standin.SetActive(ch.visible && detailDistance > 0f && (!ch.full || !ch.detailShown));
            }
        }

        public void SetDetailDistance(float d)
        {
            if (Mathf.Approximately(d, detailDistance)) return;
            detailDistance = d;
            _cullT = 0f;
        }

        public void RebuildAll()
        {
            foreach (var key in new List<Vector2Int>(dirtyOrder)) RebuildChunk(key);
            dirtyOrder.Clear();
            dirty.Clear();
            RefreshMap();
            lampTex.SetPixels32(_lampPx);
            lampTex.Apply(false);
            Cull();
        }

        // ------------------------------------------------------------ drawing ---

        void Draw()
        {
            foreach (var ch in chunks.Values)
            {
                if (!ch.visible) continue;
                foreach (var bt in ch.batches)
                {
                    if (!bt.road && !ch.detailShown) continue;
                    var rp = new RenderParams(bt.mats[0])
                    {
                        worldBounds = ch.bounds,
                        matProps = bt.mpb,
                        shadowCastingMode = bt.shadow && ch.cast ? ShadowCastingMode.On : ShadowCastingMode.Off,
                        receiveShadows = true,
                        layer = gameObject.layer,
                    };
                    for (int s = 0; s < bt.mesh.subMeshCount; s++)
                    {
                        rp.material = bt.mats[Math.Min(s, bt.mats.Length - 1)];
                        Graphics.RenderMeshInstanced(rp, bt.mesh, s, bt.xf);
                    }
                }
                if (ch.beacons != null && ch.beacons.Length > 0)
                {
                    var rp = new RenderParams(BeaconMat()) { worldBounds = ch.bounds, shadowCastingMode = ShadowCastingMode.Off, receiveShadows = false, layer = gameObject.layer };
                    Graphics.RenderMeshInstanced(rp, BeaconMesh(), 0, ch.beacons);
                }
            }
            foreach (var kv in growing) DrawGrowing(kv.Key, kv.Value);
        }

        void DrawGrowing(int id, float k)
        {
            if (!city.buildings.TryGetValue(id, out var b)) return;
            string nm = BuildingMesh(b);
            var mesh = Kit.Mesh(nm);
            if (mesh == null) return;
            float e = 1f - Mathf.Pow(1f - k, 3f);
            var xf = BuildingXform(b);
            xf.basis = xf.basis * GBasis.Scaled(new Vector3(1f, Mathf.Max(e, 0.02f), 1f));
            _growMpb ??= new MaterialPropertyBlock();
            _growMpb.SetVector("_InstColor", WallTint(b));
            _growMpb.SetVector("_InstCustom", Accent(b));
            var mats = Kit.MaterialsFor(nm);
            var m = G.M(Planet.Xf(xf));
            for (int s = 0; s < mesh.subMeshCount; s++)
            {
                var rp = new RenderParams(mats[Math.Min(s, mats.Length - 1)]) { matProps = _growMpb, shadowCastingMode = ShadowCastingMode.On, receiveShadows = true };
                Graphics.RenderMesh(rp, mesh, s, m);
            }
        }

        Material BeaconMat() => _beaconMat ??= new Material(Resources.Load<Shader>("Shaders/MSPBeacon")) { name = "Beacon", enableInstancing = true };

        Mesh BeaconMesh()
        {
            if (_beaconMesh != null) return _beaconMesh;
            _beaconMesh = MeshUtil.Sphere(0.35f, 8, 4);
            return _beaconMesh;
        }

        // ------------------------------------------------------------ helpers ---

        public string BuildingMesh(Building b) =>
            b.HasKind ? Kit.SpecialMeshName(b.kind, b.size, b.variant) : Kit.BuildingMeshName(b.zone, b.stage, b.size, b.variant);

        public GXform BuildingXform(Building b) => new GXform(GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f), city.BuildingCenter(b));

        public static Color WallTint(Building b)
        {
            var pal = Kit.WALLS[b.zone];
            var c = pal[b.tint % pal.Length];
            float s = (float)b.seed;
            float v = 0.9f + 0.2f * G.Fposmod(s * 7.31f, 1f);
            float warm = (G.Fposmod(s * 13.7f, 1f) - 0.5f) * 0.08f;
            return new Color(c.r * v * (1f + warm), c.g * v, c.b * v * (1f - warm), 1f);
        }

        public static Color Accent(Building b)
        {
            Color c = b.HasKind ? (Catalog.GetDef(b.kind)?.accent ?? Color.white) : Kit.ACCENTS[b.tint2 % Kit.ACCENTS.Length];
            c.a = (float)b.seed;
            return c;
        }

        static float CellHash(int x, int y, int k) => (GodotHash.Vector3i(x, y, k) & 0xffff) / 65535f;

        class Group
        {
            public readonly List<GXform> xf = new List<GXform>();
            public readonly List<Vector4> col = new List<Vector4>();
            public readonly List<Vector4> custom = new List<Vector4>();
            public bool shadow;
        }

        void Push(Dictionary<string, Group> groups, List<string> order, string nm, GXform xf, Color col, Color custom, bool shadow)
        {
            if (!groups.TryGetValue(nm, out var g))
            {
                groups[nm] = g = new Group { shadow = shadow };
                order.Add(nm);
            }
            g.xf.Add(xf);
            g.col.Add(col);
            g.custom.Add(custom);
        }

        void RebuildChunk(Vector2Int key)
        {
            if (chunks.TryGetValue(key, out var old) && old.standin != null) Destroy(old.standin);
            var ch = new Chunk();
            if (old != null)
            {
                ch.visible = old.visible;
                ch.cast = old.cast;
                ch.detailShown = old.detailShown;
            }
            chunks[key] = ch;
            var groups = new Dictionary<string, Group>();
            var order = new List<string>();
            var beacons = new List<Vector3>();
            var boxes = new List<(Vector3 lo, Vector3 hi, Color c, float seed)>();
            bool full = !Planet.on || WantFull(key);
            ch.full = full;
            int x0 = key.x * _chunk, y0 = key.y * _chunk;
            for (int y = y0; y < Math.Min(y0 + _chunk, City.H); y++)
                for (int x = x0; x < Math.Min(x0 + _chunk, City.W); x++)
                {
                    int i = city.Idx(x, y);
                    _lampPx[y * City.W + x] = new Color32(0, 0, 0, 0);
                    var center = city.CellCenter(x, y);
                    if (city.road[i] == 1)
                    {
                        AddRoad(groups, order, ch.lamps, x, y, center);
                        foreach (int pid in city.PropsAt(i))
                        {
                            var pb = city.buildings[pid];
                            if (!growing.ContainsKey(pid)) Push(groups, order, BuildingMesh(pb), BuildingXform(pb), WallTint(pb), Accent(pb), true);
                        }
                        continue;
                    }
                    int bid = city.bld[i];
                    if (bid >= 0)
                    {
                        var b = city.buildings[bid];
                        if (b.x == x && b.y == y && !growing.ContainsKey(bid))
                        {
                            string nm = BuildingMesh(b);
                            if (nm != "")
                            {
                                var bx = BuildingXform(b);
                                Push(groups, order, nm, bx, WallTint(b), Accent(b), true);
                                var mesh = Kit.Mesh(nm);
                                if (mesh != null)
                                {
                                    var (lo, hi) = XformAabb(bx, mesh.bounds);
                                    boxes.Add((lo, hi, WallTint(b), G.Fposmod((float)b.seed, 1f)));
                                }
                                var top = TopOf(nm);
                                if (top.y > BEACON_HEIGHT) beacons.Add(bx * (top + new Vector3(0f, 0.35f, 0f)));
                            }
                            if (b.zone == City.RES && b.stage == 1)
                            {
                                var back = GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f) * new Vector3(CellHash(x, y, 9) * 6f - 3f, 0f, -4.4f);
                                AddTree(groups, order, center + back, x, y, 5, false);
                            }
                        }
                        continue;
                    }
                    if (city.siteAt[i] >= 0) continue; // ConstructionSites draws it
                    if (city.land[i] == 1)
                    {
                        for (int k = 0; k < city.trees[i]; k++)
                        {
                            var off = new Vector3(CellHash(x, y, k) * 9f - 4.5f, 0f, CellHash(x, y, k + 7) * 9f - 4.5f);
                            AddTree(groups, order, center + off, x, y, k, city.coastDist[i] <= 2f);
                        }
                        if (city.zone[i] == 0 && CellHash(x, y, 31) < 0.12f)
                        {
                            var off = new Vector3(CellHash(x, y, 32) * 8f - 4f, 0f, CellHash(x, y, 33) * 8f - 4f);
                            Push(groups, order, "bush", new GXform(GBasis.Rotation(Vector3.up, CellHash(x, y, 34) * G.TAU), center + off),
                                Kit.LEAF_TINTS[(int)(CellHash(x, y, 35) * 5.99f)], new Color(0, 0, 0, 0), true);
                        }
                    }
                    else if (city.height[i] > 0.055f && CellHash(x, y, 40) < 0.35f)
                    {
                        // beach palms on the sand ring
                        var off = new Vector3(CellHash(x, y, 41) * 8f - 4f, 0f, CellHash(x, y, 42) * 8f - 4f);
                        var p = center + off;
                        if (city.Landness(p.x, p.z) > 0.06)
                        {
                            float sc = 0.9f + CellHash(x, y, 44) * 0.5f;
                            Push(groups, order, "palm", new GXform(GBasis.Rotation(Vector3.up, CellHash(x, y, 43) * G.TAU) * GBasis.Scaled(Vector3.one * sc), p),
                                Kit.LEAF_TINTS[(int)(CellHash(x, y, 45) * 5.99f)], new Color(0, 0, 0, 0), true);
                        }
                    }
                }
            var bmin = new Vector3(float.MaxValue, float.MaxValue, float.MaxValue);
            var bmax = -bmin;
            foreach (var nm in order)
            {
                var g = groups[nm];
                bool road = nm.StartsWith("road_");
                if (!full && !road) continue; // far away: the stand-in boxes draw it
                var mesh = Kit.Mesh(nm);
                if (mesh == null) continue;
                var mats = Kit.MaterialsFor(nm);
                for (int start = 0; start < g.xf.Count; start += MAX_BATCH)
                {
                    int n = Math.Min(MAX_BATCH, g.xf.Count - start);
                    var bt = new Batch { name = nm, mesh = mesh, mats = mats, xf = new Matrix4x4[n], mpb = new MaterialPropertyBlock(), shadow = g.shadow, road = road };
                    for (int k = 0; k < n; k++)
                    {
                        bt.xf[k] = G.M(Planet.Xf(g.xf[start + k]));  // flat map -> the ball on msp
                        Vector3 o = bt.xf[k].GetColumn(3);
                        bmin = Vector3.Min(bmin, o);
                        bmax = Vector3.Max(bmax, o);
                    }
                    bt.mpb.SetVectorArray("_InstColor", g.col.GetRange(start, n));
                    bt.mpb.SetVectorArray("_InstCustom", g.custom.GetRange(start, n));
                    ch.batches.Add(bt);
                }
            }
            if (beacons.Count > 0)
            {
                ch.beacons = new Matrix4x4[beacons.Count];
                for (int k = 0; k < beacons.Count; k++)
                    ch.beacons[k] = Matrix4x4.Translate(G.U(Planet.Place(beacons[k])));
            }
            if (boxes.Count > 0)
            {
                ch.standin = MeshUtil.Show(transform, $"StandIn_{key.x}_{key.y}", StandinMesh(boxes), StandinMat());
                ch.standin.GetComponent<MeshRenderer>().shadowCastingMode = ShadowCastingMode.Off;
                ch.standin.SetActive(Planet.on && ch.visible && detailDistance > 0f && (!full || !ch.detailShown));
            }
            if (bmin.x > bmax.x)
            {
                var c = G.U(Planet.Place(new Vector3((x0 + _chunk * 0.5f) * City.TILE, 0f, (y0 + _chunk * 0.5f) * City.TILE)));
                bmin = bmax = c;
            }
            var bounds = new Bounds((bmin + bmax) * 0.5f, bmax - bmin);
            bounds.Expand(2f * (TALLEST + City.TILE));
            ch.bounds = bounds;
        }

        Material StandinMat() => _standinMat ??= new Material(Resources.Load<Shader>("Shaders/MSPStandin")) { name = "StandIn" };

        /// <summary>The axis-aligned box (flat map, Godot space) around a kit mesh placed at xf.
        /// Mesh bounds are in Unity object space (mirrored in x).</summary>
        static (Vector3 lo, Vector3 hi) XformAabb(GXform xf, Bounds ub)
        {
            Vector3 mn = ub.min, mx = ub.max;
            var lo = new Vector3(-mx.x, mn.y, mn.z);
            var hi = new Vector3(-mn.x, mx.y, mx.z);
            var rmin = new Vector3(float.MaxValue, float.MaxValue, float.MaxValue);
            var rmax = -rmin;
            for (int k = 0; k < 8; k++)
            {
                var p = new Vector3((k & 1) != 0 ? hi.x : lo.x, (k & 2) != 0 ? hi.y : lo.y, (k & 4) != 0 ? hi.z : lo.z);
                var w = xf * p;
                rmin = Vector3.Min(rmin, w);
                rmax = Vector3.Max(rmax, w);
            }
            return (rmin, rmax);
        }

        /// <summary>Four walls and a roof per building, with wall metres in uv for the window grid.</summary>
        static Mesh StandinMesh(List<(Vector3 lo, Vector3 hi, Color c, float seed)> boxes)
        {
            var v = new List<Vector3>();
            var n = new List<Vector3>();
            var uv = new List<Vector2>();
            var uv2 = new List<Vector2>();
            var col = new List<Color>();
            var idx = new List<int>();
            foreach (var (lo, hi, c, sd) in boxes)
            {
                float h = hi.y - lo.y;
                Vector3[] corners = { new Vector3(lo.x, 0, lo.z), new Vector3(hi.x, 0, lo.z), new Vector3(hi.x, 0, hi.z), new Vector3(lo.x, 0, hi.z) };
                for (int k = 0; k < 4; k++)
                {
                    var p0 = corners[k];
                    var p1 = corners[(k + 1) % 4];
                    float w = Vector3.Distance(p0, p1);
                    var nrm = Vector3.Cross(Vector3.up, p1 - p0).normalized;
                    int b = v.Count;
                    foreach (var (p, u, hh) in new[] { (p0, 0f, 0f), (p1, w, 0f), (p1, w, h), (p0, 0f, h) })
                    {
                        v.Add(p + new Vector3(0, lo.y + hh, 0));
                        n.Add(nrm);
                        uv.Add(new Vector2(u, hh));
                        uv2.Add(new Vector2(sd, 0));
                        col.Add(c);
                    }
                    idx.AddRange(new[] { b, b + 1, b + 2, b, b + 2, b + 3 });
                }
                int r = v.Count;
                foreach (var p in corners)
                {
                    v.Add(new Vector3(p.x, hi.y, p.z));
                    n.Add(Vector3.up);
                    uv.Add(new Vector2(0, -1));
                    uv2.Add(new Vector2(sd, 0));
                    col.Add(c);
                }
                idx.AddRange(new[] { r, r + 1, r + 2, r, r + 2, r + 3 });
            }
            for (int k = 0; k < v.Count; k++)
            {
                if (Planet.on)
                {
                    n[k] = Planet.Frame(v[k]) * n[k];
                    v[k] = Planet.Warp(v[k]);
                }
                n[k] = G.U(n[k]);
                v[k] = G.U(v[k]);  // Godot's triangle order is kept (see MeshUtil)
            }
            var m = new Mesh { name = "StandIn", indexFormat = IndexFormat.UInt32 };
            m.SetVertices(v);
            m.SetNormals(n);
            m.SetUVs(0, uv);
            m.SetUVs(1, uv2);
            m.SetColors(col);
            m.SetTriangles(idx, 0);
            m.RecalculateBounds();
            return m;
        }

        /// <summary>The highest point of a kit mesh (spire, antenna or roof corner), Godot mesh space.</summary>
        Vector3 TopOf(string nm)
        {
            if (_tops.TryGetValue(nm, out var t)) return t;
            var top = new Vector3(0, -1, 0);
            var mesh = Kit.Mesh(nm);
            if (mesh != null && mesh.bounds.max.y > BEACON_HEIGHT && mesh.isReadable)
                foreach (var vv in mesh.vertices)
                    if (vv.y > top.y) top = G.FromU(vv);
            _tops[nm] = top;
            return top;
        }

        void AddTree(Dictionary<string, Group> groups, List<string> order, Vector3 p, int x, int y, int k, bool coastal)
        {
            float h = CellHash(x, y, k + 20);
            string nm = h < 0.4f ? "tree_round_a" : (h < 0.75f ? "tree_round_b" : "tree_pine");
            if (coastal && h < 0.6f) nm = "palm";
            float s = 0.8f + CellHash(x, y, k + 30) * 0.55f;
            var basis = GBasis.Rotation(Vector3.up, CellHash(x, y, k + 40) * G.TAU) * GBasis.Scaled(Vector3.one * s);
            var tint = Kit.LEAF_TINTS[(int)(CellHash(x, y, k + 50) * 5.99f)];
            Push(groups, order, nm, new GXform(basis, p), tint, new Color(0, 0, 0, 0), true);
        }

        void AddRoad(Dictionary<string, Group> groups, List<string> order, List<Vector3> lamps, int x, int y, Vector3 center)
        {
            int mask = city.RoadMask(x, y);
            var (piece, rot) = roadTable[mask];
            var basis = GBasis.Rotation(Vector3.up, rot * Mathf.PI * 0.5f);
            Push(groups, order, piece, new GXform(basis, center), Color.white, new Color(0, 0, 0, 0), false);
            int neighbours = 0;
            foreach (int bit in new[] { N, E, S, W }) if ((mask & bit) != 0) neighbours++;
            if (neighbours >= 3) return; // junctions get live signal heads from CityLife, and no lamp
            var local = Vector3.zero;
            bool place = false;
            if (piece == "road_straight" || piece == "road_end")
            {
                place = (x + y) % 2 == 0 || piece == "road_end";
                local = new Vector3((x + y) % 4 == 0 ? 4.9f : -4.9f, 0.17f, 0f);
            }
            else if (piece == "road_corner")
            {
                place = true;
                local = new Vector3(-4.9f, 0.17f, 4.9f);
            }
            if (!place) return;
            // the lamp arm points toward -X; turn it to face the road centre
            float face = local.x > 0f ? 0f : Mathf.PI;
            if (piece == "road_corner") face = -Mathf.PI * 0.25f + Mathf.PI;
            var lb = basis * GBasis.Rotation(Vector3.up, face);
            var bse = center + basis * local;
            Push(groups, order, "street_lamp", new GXform(lb, bse), Color.white, new Color(0, 0, 0, 0), true);
            var head = bse + lb * new Vector3(-1.4f, 6f, 0f);
            lamps.Add(Planet.Place(head));
            var hc = city.FlatToCell(head);
            if (city.Inside(hc.x, hc.y))
            {
                int px = G.Posmod(hc.x, City.W);
                _lampPx[hc.y * City.W + px] = new Color32((byte)Mathf.Clamp((head.x / City.TILE - hc.x) * 255f, 0, 255),
                    (byte)Mathf.Clamp((head.z / City.TILE - hc.y) * 255f, 0, 255), 255, 255);
            }
        }

        /// <summary>Lamp heads (world, Godot space) of the chunks near p, for real lights.</summary>
        public IEnumerable<Vector3> LampsNear(Vector3 flat, float radius)
        {
            foreach (var ch in chunks.Values)
                foreach (var l in ch.lamps)
                    if (Planet.Fdist(Planet.Flat(l), flat) < radius) yield return l;
        }
    }
}
