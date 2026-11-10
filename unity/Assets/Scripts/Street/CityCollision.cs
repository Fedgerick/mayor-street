// Port of player/scripts/city_collision.gd: physics for street level, generated from the City
// data: raised sidewalks, building boxes, invisible walls at the shoreline, and the street
// furniture CityView draws from the same data (street lamps, trees, palms, street props).
// Built in 16x16-tile chunks and rebuilt when the city changes. Parks and plazas stay open.
// On msp the sphere terrain (CityView.terrainCollider) is the ground.
//
// Shapes are laid out in Godot space on the flat map, stood up on the ball (Planet.XfRigid),
// then written to Unity transforms through G.Apply. Cylinders become capsules.
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class CityCollision : MonoBehaviour
    {
        public const int CHUNK = 16;
        public const float SIDEWALK_W = 2.25f;
        public const float CURB_H = 0.17f;
        public const float LAMP_X = 4.9f;
        public const float LAMP_Y = 0.17f;
        public const int LAYER = 0;  // static world: Default

        static readonly (string piece, int mask)[] PIECES =
        {
            ("road_straight", 5), ("road_corner", 3), ("road_t", 7), ("road_cross", 15), ("road_end", 1), ("road_single", 0),
        };

        public City city;
        readonly Dictionary<Vector2Int, GameObject> _chunks = new Dictionary<Vector2Int, GameObject>();
        readonly HashSet<Vector2Int> _dirty = new HashSet<Vector2Int>();
        readonly Dictionary<int, (string piece, int rot)> _roadTable = new Dictionary<int, (string, int)>();
        static readonly Dictionary<string, Bounds> _footprints = new Dictionary<string, Bounds>();

        enum Kind { Box, Cyl }
        struct Shape { public Kind kind; public GXform xf; public Vector3 size; public float radius, height; }
        readonly List<Shape> _shapes = new List<Shape>();

        public void Setup(City c)
        {
            city = c;
            foreach (var (piece, mask) in PIECES)
            {
                int m = mask;
                for (int k = 0; k < 4; k++)
                {
                    if (!_roadTable.ContainsKey(m)) _roadTable[m] = (piece, k);
                    m = RotMask(m);
                }
            }
            if (!Planet.on)
            {
                var ground = new GameObject("Ground");
                ground.transform.SetParent(transform, false);
                var bc = ground.AddComponent<BoxCollider>();
                bc.center = new Vector3(0, -0.5f, 0);
                bc.size = new Vector3(100000f, 1f, 100000f);
            }
            city.CellsChanged += OnCellsChanged;
            city.BuildingAdded += (id, a) => MarkBuilding(id);
            int across = Mathf.CeilToInt((float)City.W / CHUNK), down = Mathf.CeilToInt((float)City.H / CHUNK);
            for (int cy = 0; cy < down; cy++)
                for (int cx = 0; cx < across; cx++) _dirty.Add(new Vector2Int(cx, cy));
            RebuildDirty();
        }

        void OnCellsChanged(RectInt r)
        {
            int across = Mathf.CeilToInt((float)City.W / CHUNK);
            for (int cy = Mathf.FloorToInt((float)(r.yMin - 1) / CHUNK); cy <= Mathf.FloorToInt((float)r.yMax / CHUNK); cy++)
                for (int cx = Mathf.FloorToInt((float)(r.xMin - 1) / CHUNK); cx <= Mathf.FloorToInt((float)r.xMax / CHUNK); cx++)
                    _dirty.Add(new Vector2Int(Planet.on ? G.Posmod(cx, across) : cx, cy));
        }

        void MarkBuilding(int id)
        {
            if (city.buildings.TryGetValue(id, out var b)) OnCellsChanged(new RectInt(b.x, b.y, b.size, b.size));
        }

        void FixedUpdate()
        {
            if (_dirty.Count > 0) RebuildDirty();
        }

        public void RebuildDirty()
        {
            foreach (var k in _dirty) Rebuild(k);
            _dirty.Clear();
        }

        void Rebuild(Vector2Int key)
        {
            if (_chunks.TryGetValue(key, out var old))
            {
                Destroy(old);
                _chunks.Remove(key);
            }
            int x0 = key.x * CHUNK, y0 = key.y * CHUNK;
            if (x0 >= City.W || y0 >= City.H || x0 < 0 || y0 < 0) return;
            _shapes.Clear();
            var seen = new HashSet<int>();
            float T = City.TILE, h = T * 0.5f;
            for (int y = y0; y < Mathf.Min(y0 + CHUNK, City.H); y++)
                for (int x = x0; x < Mathf.Min(x0 + CHUNK, City.W); x++)
                {
                    int i = city.Idx(x, y);
                    Vector3 c = city.CellCenter(x, y);
                    if (city.road[i] == 1)
                    {
                        int m = city.RoadMask(x, y);
                        AddLamp(x, y, m);
                        foreach (int pid in city.PropsAt(i)) AddProp(city.buildings[pid]);
                        // Corner squares are always sidewalk; edges are sidewalk where no road continues.
                        foreach (int sx in new[] { -1, 1 })
                            foreach (int sz in new[] { -1, 1 })
                                Box(c + new Vector3(sx * (h - SIDEWALK_W * 0.5f), CURB_H * 0.5f, sz * (h - SIDEWALK_W * 0.5f)), new Vector3(SIDEWALK_W, CURB_H, SIDEWALK_W));
                        float mid = T - SIDEWALK_W * 2f;
                        if ((m & 1) == 0) Box(c + new Vector3(0, CURB_H * 0.5f, -h + SIDEWALK_W * 0.5f), new Vector3(mid, CURB_H, SIDEWALK_W));
                        if ((m & 4) == 0) Box(c + new Vector3(0, CURB_H * 0.5f, h - SIDEWALK_W * 0.5f), new Vector3(mid, CURB_H, SIDEWALK_W));
                        if ((m & 2) == 0) Box(c + new Vector3(h - SIDEWALK_W * 0.5f, CURB_H * 0.5f, 0), new Vector3(SIDEWALK_W, CURB_H, mid));
                        if ((m & 8) == 0) Box(c + new Vector3(-h + SIDEWALK_W * 0.5f, CURB_H * 0.5f, 0), new Vector3(SIDEWALK_W, CURB_H, mid));
                    }
                    else if (city.land[i] == 0)
                    {
                        // Shoreline wall where water meets land.
                        bool shore = false;
                        foreach (var d in City.DIRS)
                            if (city.Inside(x + d.x, y + d.y) && city.land[city.Idx(x + d.x, y + d.y)] == 1)
                            {
                                Box(c + new Vector3(0, 4f, 0), new Vector3(T, 8f, T));
                                shore = true;
                                break;
                            }
                        if (!shore && city.height[i] > 0.055f && Hash(x, y, 40) < 0.35f)
                        {
                            // Beach palms on the sand ring.
                            var p = c + new Vector3(Hash(x, y, 41) * 8f - 4f, 0, Hash(x, y, 42) * 8f - 4f);
                            if (city.Landness(p.x, p.z) > 0.06) Trunk(p, 0.9f + Hash(x, y, 44) * 0.5f, 0.2f);
                        }
                    }
                    int bid = city.bld[i];
                    if (bid >= 0 && seen.Add(bid))
                    {
                        var b = city.buildings[bid];
                        AddBuilding(b);
                        if (b.zone == City.RES && b.stage == 1 && !b.HasKind)
                        {
                            var back = GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f) * new Vector3(Hash(b.x, b.y, 9) * 6f - 3f, 0, -4.4f);
                            AddTree(city.CellCenter(b.x, b.y) + back, b.x, b.y, 5, false);
                        }
                    }
                    else if (bid < 0 && city.road[i] == 0 && city.land[i] == 1)
                    {
                        for (int k = 0; k < city.trees[i]; k++)
                        {
                            var off = new Vector3(Hash(x, y, k) * 9f - 4.5f, 0, Hash(x, y, k + 7) * 9f - 4.5f);
                            AddTree(c + off, x, y, k, city.coastDist[i] <= 2f);
                        }
                    }
                }
            if (_shapes.Count == 0) return;
            var go = new GameObject($"Chunk_{key.x}_{key.y}");
            go.layer = LAYER;
            go.transform.SetParent(transform, false);
            go.isStatic = true;
            foreach (var s in _shapes) Emit(go.transform, s);
            _chunks[key] = go;
        }

        /// <summary>msp: stand a flat-map shape up on the ball. Shapes stay rigid, so a box is
        /// narrowed east-west by cos(latitude) the way the kit meshes are.</summary>
        void Emit(Transform parent, Shape s)
        {
            var t = s.xf;
            var size = s.size;
            if (Planet.on)
            {
                if (s.kind == Kind.Box)
                {
                    float k = Mathf.Cos(Planet.LatOf(t.origin));
                    var east = t.basis.Inverse() * Vector3.right;
                    if (Mathf.Abs(east.x) >= Mathf.Abs(east.z)) size.x *= Mathf.Lerp(1f, k, Mathf.Abs(east.x));
                    else size.z *= Mathf.Lerp(1f, k, Mathf.Abs(east.z));
                }
                t = Planet.XfRigid(t);
            }
            var go = new GameObject(s.kind == Kind.Box ? "Box" : "Cyl");
            go.layer = LAYER;
            go.transform.SetParent(parent, false);
            G.Apply(go.transform, t);
            if (s.kind == Kind.Box) go.AddComponent<BoxCollider>().size = size;
            else
            {
                var cc = go.AddComponent<CapsuleCollider>();
                cc.direction = 1;
                cc.radius = s.radius;
                cc.height = Mathf.Max(s.height, s.radius * 2f);
            }
        }

        void AddBuilding(Building b)
        {
            if (b.HasTag("park") || b.HasTag("plaza")) return;  // open ground: walk (or drive) straight in
            float half = City.TILE * 0.5f * b.size;
            var lot = new Bounds();
            lot.SetMinMax(new Vector3(-half + 0.6f, 0, -half + 0.6f), new Vector3(half - 0.6f, 400f, half - 0.6f));
            var aabb = new Bounds();
            aabb.SetMinMax(lot.min, new Vector3(lot.max.x, 8f, lot.max.z));
            string nm = b.HasKind ? Kit.SpecialMeshName(b.kind, b.size, b.variant) : Kit.BuildingMeshName(b.zone, b.stage, b.size, b.variant);
            var mesh = nm != "" ? Kit.Mesh(nm) : null;
            if (mesh != null)
            {
                // Kit buildings include their lot paving, low walls and yards at ground level;
                // only what stands above head height blocks, kept inside the lot.
                var grown = lot;
                grown.Expand(1.2f);
                if (!Intersection(Footprint(nm, mesh), grown, out aabb)) return;
                if (aabb.size.x < 1f || aabb.size.z < 1f) return;
            }
            var xf = new GXform(GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f), city.BuildingCenter(b));
            aabb = ClearDoor(aabb, xf.Inverse() * city.DoorPosition(b));
            var size = new Vector3(aabb.size.x, Mathf.Max(aabb.max.y, 3f), aabb.size.z);
            var center = aabb.center;
            _shapes.Add(new Shape { kind = Kind.Box, xf = xf * GXform.At(new Vector3(center.x, size.y * 0.5f, center.z)), size = size });
        }

        static bool Intersection(Bounds a, Bounds b, out Bounds o)
        {
            var lo = Vector3.Max(a.min, b.min);
            var hi = Vector3.Min(a.max, b.max);
            o = new Bounds();
            if (lo.x > hi.x || lo.y > hi.y || lo.z > hi.z) return false;
            o.SetMinMax(lo, hi);
            return true;
        }

        /// <summary>Pull the box face nearest the front door back behind it, so awnings, steps and
        /// signs don't keep the player out of the doorway.</summary>
        static Bounds ClearDoor(Bounds box, Vector3 door)
        {
            const float BACK = 0.15f;
            if (door.x <= box.min.x || door.x >= box.max.x || door.z <= box.min.z || door.z >= box.max.z) return box;
            float[] gaps = { door.x - box.min.x, box.max.x - door.x, door.z - box.min.z, box.max.z - door.z };
            int k = 0;
            for (int i = 0; i < 4; i++) if (gaps[i] < gaps[k]) k = i;
            var lo = box.min;
            var hi = box.max;
            switch (k)
            {
                case 0: lo.x = door.x + BACK; break;
                case 1: hi.x = door.x - BACK; break;
                case 2: lo.z = door.z + BACK; break;
                case 3: hi.z = door.z - BACK; break;
            }
            var o = new Bounds();
            o.SetMinMax(lo, hi);
            return o;
        }

        /// <summary>A kit mesh's bounds in Godot space (the X mirror flips the centre).</summary>
        public static Bounds GodotBounds(Mesh m)
        {
            var b = m.bounds;
            return new Bounds(G.FromU(b.center), b.size);
        }

        /// <summary>The XZ extent (Godot space) of a mesh's parts above 1.2 m, full height in Y.</summary>
        public static Bounds Footprint(string nm, Mesh mesh)
        {
            if (_footprints.TryGetValue(nm, out var cached)) return cached;
            var full = GodotBounds(mesh);
            float lx = float.PositiveInfinity, lz = float.PositiveInfinity, hx = float.NegativeInfinity, hz = float.NegativeInfinity;
            if (mesh.isReadable)
                foreach (var vu in mesh.vertices)
                {
                    var v = G.FromU(vu);
                    if (v.y <= 1.2f) continue;
                    lx = Mathf.Min(lx, v.x); lz = Mathf.Min(lz, v.z);
                    hx = Mathf.Max(hx, v.x); hz = Mathf.Max(hz, v.z);
                }
            var o = full;
            if (lx < hx && lz < hz) o.SetMinMax(new Vector3(lx, 0, lz), new Vector3(hx, full.max.y, hz));
            _footprints[nm] = o;
            return o;
        }

        void AddProp(Building b)
        {
            // Payphones and other street props: a box the size of the model.
            var aabb = new Bounds(new Vector3(0, 1.1f, 0), new Vector3(0.8f, 2.2f, 0.6f));
            if (b.HasKind)
            {
                string nm = Kit.SpecialMeshName(b.kind, b.size, b.variant);
                var mesh = nm != "" ? Kit.Mesh(nm) : null;
                if (mesh != null) aabb = GodotBounds(mesh);
            }
            if (aabb.size.x > 4f || aabb.size.z > 4f) aabb = new Bounds(new Vector3(0, 1.1f, 0), new Vector3(0.8f, 2.2f, 0.6f));
            var xf = new GXform(GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f), city.BuildingCenter(b));
            var size = new Vector3(Mathf.Max(aabb.size.x, 0.3f), Mathf.Max(aabb.size.y, 1f), Mathf.Max(aabb.size.z, 0.3f));
            var center = aabb.center;
            _shapes.Add(new Shape { kind = Kind.Box, xf = xf * GXform.At(new Vector3(center.x, CURB_H + size.y * 0.5f, center.z)), size = size });
        }

        /// <summary>Where CityView stands this cell's street lamp, if it has one (base point).</summary>
        public bool LampBase(int x, int y, int mask, out Vector3 basePos)
        {
            basePos = Vector3.zero;
            var entry = _roadTable.TryGetValue(mask, out var e) ? e : ("", 0);
            int n = 0;
            foreach (int bit in new[] { 1, 2, 4, 8 }) if ((mask & bit) != 0) n++;
            if (n >= 3) return false;
            Vector3 local;
            if (entry.Item1 == "road_straight" || entry.Item1 == "road_end")
            {
                if (!((x + y) % 2 == 0 || entry.Item1 == "road_end")) return false;
                local = new Vector3((x + y) % 4 == 0 ? LAMP_X : -LAMP_X, LAMP_Y, 0);
            }
            else if (entry.Item1 == "road_corner") local = new Vector3(-LAMP_X, LAMP_Y, LAMP_X);
            else return false;
            basePos = city.CellCenter(x, y) + GBasis.Rotation(Vector3.up, entry.Item2 * Mathf.PI * 0.5f) * local;
            return true;
        }

        void AddLamp(int x, int y, int mask)
        {
            if (!LampBase(x, y, mask, out var b)) return;
            _shapes.Add(new Shape { kind = Kind.Cyl, xf = GXform.At(b + new Vector3(0, 3f, 0)), radius = 0.14f, height = 6f });
        }

        /// <summary>Is a lamp post within radius of world point p (Godot space)?</summary>
        public bool PoleNear(Vector3 p, float radius)
        {
            p = Planet.Flat(p);
            var o = city.FlatToCell(p);
            for (int y = o.y - 1; y <= o.y + 1; y++)
                for (int x = o.x - 1; x <= o.x + 1; x++)
                {
                    if (!city.Inside(x, y) || !city.IsRoad(x, y)) continue;
                    if (!LampBase(x, y, city.RoadMask(x, y), out var b)) continue;
                    float bx = Planet.on ? p.x + Planet.Dx(p.x, b.x) : b.x;
                    if (new Vector2(bx - p.x, b.z - p.z).magnitude < radius) return true;
                }
            return false;
        }

        public static (string name, Vector3 pos, float scale) TreeAt(Vector3 p, int x, int y, int k, bool coastal)
        {
            float h = Hash(x, y, k + 20);
            string nm = h < 0.4f ? "tree_round_a" : (h < 0.75f ? "tree_round_b" : "tree_pine");
            if (coastal && h < 0.6f) nm = "palm";
            return (nm, p, 0.8f + Hash(x, y, k + 30) * 0.55f);
        }

        void AddTree(Vector3 p, int x, int y, int k, bool coastal)
        {
            var t = TreeAt(p, x, y, k, coastal);
            Trunk(p, t.scale, t.name == "tree_pine" ? 0.28f : 0.22f);
        }

        void Trunk(Vector3 p, float scale, float radius)
        {
            float hgt = 3f * scale;
            _shapes.Add(new Shape { kind = Kind.Cyl, xf = GXform.At(p + new Vector3(0, hgt * 0.5f, 0)), radius = radius * scale, height = hgt });
        }

        static int RotMask(int m)
        {
            int r = 0;
            if ((m & 1) != 0) r |= 8;
            if ((m & 2) != 0) r |= 1;
            if ((m & 4) != 0) r |= 2;
            if ((m & 8) != 0) r |= 4;
            return r;
        }

        /// <summary>CityView's cell hash.</summary>
        public static float Hash(int x, int y, int k) => (GodotHash.Vector3i(x, y, k) & 0xffff) / 65535f;

        void Box(Vector3 pos, Vector3 size) => _shapes.Add(new Shape { kind = Kind.Box, xf = GXform.At(pos), size = size });

        public bool IsLand(Vector3 p)
        {
            var c = city.WorldToCell(p);
            return city.Inside(c.x, c.y) && city.land[city.Idx(c.x, c.y)] == 1;
        }
    }
}
