// Port of scripts/city.gd (msp 014beac, construction over time included): the city's data and
// simulation, no rendering. The map is a W x H grid of 12 m tiles; grid x is flat map +X and
// grid y flat map +Z. On the planet (Planet.on) the grid is a belt round the equator and x
// wraps. Same seed, same calls, same city as msp: Godot's RNG and noise are reproduced.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class City
    {
        public event Action<RectInt> CellsChanged;
        public event Action<int, bool> BuildingAdded;
        public event Action<int> BuildingRemoved;
        public event Action<int> SiteStarted;
        public event Action<int, bool> SiteEnded;
        public event Action DayPassed;
        public event Action<string> Message;
        public event Action LandValueComputed;

        public static int W = 80;
        public static int H = 80;
        public const float TILE = 12f;
        public const int ROAD_COST = 25;
        public const int ZONE_COST = 10;
        public const int BULLDOZE_COST = 10;
        public const double ROAD_UPKEEP = 0.5;
        public const double MINUTES_PER_SECOND = 6.0;

        public const int NONE = 0, RES = 1, COM = 2, IND = 3;
        public static readonly string[] ZONE_NAMES = { "None", "Residential", "Commercial", "Industrial" };
        public static readonly string[] ZONE_KEYS = { "", "r", "c", "i" };

        static readonly int[][] CAP = { new[] { 0, 0, 0, 0 }, new[] { 0, 6, 32, 140 }, new[] { 0, 6, 28, 110 }, new[] { 0, 10, 32, 70 } };
        static readonly int[] CAP_BIG = { 0, 640, 520, 280 };
        static readonly int[] STAGE_POP = { 0, 0, 120, 1400 };
        static readonly double[] STAGE_LV = { 0.0, 0.0, 0.3, 0.6 };

        public byte[] land, road, zone, trees;
        public float[] height, traffic, landValue, coastDist;
        public int[] bld, siteAt;

        public readonly OrderedMap<int, Building> buildings = new OrderedMap<int, Building>();
        public readonly OrderedMap<int, Building> sites = new OrderedMap<int, Building>();
        /// <summary>true in the live game: new buildings go up over time.</summary>
        public bool construction;
        int _nextId = 1;
        readonly Dictionary<int, List<int>> _props = new Dictionary<int, List<int>>();

        public double funds = 50000.0;
        public double taxRate = 0.09;
        public double minutes = 7.0 * 60.0;
        public int population, jobsC, jobsI;
        public double[] demand = { 0.0, 1.0, 0.4, 0.8 };
        public double lastIncome, lastExpense;
        public readonly GodotRng rng = new GodotRng();
        public bool animateGrowth = true;
        public readonly GodotNoise noise = new GodotNoise();
        public int mapSeed = 1337;
        /// <summary>Building unlocks are checked against it (Progress, once ported).</summary>
        public Func<string, bool> isUnlocked;
        /// <summary>From services: asked before a zone lot grows. False holds it back.</summary>
        public Func<int, int, bool> growthCheck;

        public City(int seedValue = 1337)
        {
            if (Planet.on) { W = Planet.W; H = Planet.H; }
            mapSeed = seedValue;
            rng.Seed = (ulong)(long)seedValue;
            noise.Seed = seedValue;
            noise.Frequency = 0.0035f;
            noise.Octaves = 4;
            int n = W * H;
            land = new byte[n];
            height = new float[n];
            road = new byte[n];
            zone = new byte[n];
            bld = new int[n];
            Array.Fill(bld, -1);
            siteAt = new int[n];
            Array.Fill(siteAt, -1);
            trees = new byte[n];
            traffic = new float[n];
            landValue = new float[n];
            coastDist = new float[n];
            MakeIsland();
        }

        // ------------------------------------------------------------ terrain ---

        /// <summary>Landness at a flat map XZ point: above 0 is land.</summary>
        public double Landness(double wx, double wz)
        {
            if (Planet.on) return PlanetLandness(wx, wz);
            double c = W * TILE * 0.5;
            double dx = (wx - c) / (c * 1.02);
            double dz = (wz - c) / (c * 0.96);
            double r = Math.Sqrt(dx * dx + dz * dz);
            double nn = noise.Get2D((float)wx, (float)wz);
            return 1.0 - r + nn * 0.32 - 0.04;
        }

        public double TerrainHeight(double wx, double wz)
        {
            if (Planet.on) return PlanetHeight(wx, wz);
            double l = Landness(wx, wz);
            if (l > 0.05) return 0.0;
            return Clamp((l - 0.05) * 60.0, -14.0, 0.0);
        }

        double PlanetCoast(double wx)
        {
            double a = wx / (W * TILE) * Math.PI * 2;
            return (H - 3.0 + noise.Get2D((float)(Math.Cos(a) * 300.0), (float)(Math.Sin(a) * 300.0)) * 2.5) * TILE;
        }

        double PlanetLandness(double wx, double wz) => Clamp((PlanetCoast(wx) - wz) / 260.0 + 0.05, -1.0, 1.0);

        double PlanetHeight(double wx, double wz)
        {
            double l = PlanetLandness(wx, wz);
            if (l <= 0.05) return Clamp((l - 0.05) * 60.0, -14.0, 0.0);
            if (wz >= 0.0) return 0.0;
            double a = wx / (W * TILE) * Math.PI * 2;
            double hill = noise.Get3D((float)(Math.Cos(a) * 400.0), (float)(Math.Sin(a) * 400.0), (float)(wz * 2.0)) * 0.5 + 0.5;
            return SmoothD(0.0, -90.0, wz) * (2.0 + hill * 5.0) + SmoothD(-120.0, -360.0, wz) * 6.0;
        }

        /// <summary>0 below the ice line .. 1 deep in the planet's north ice cap.</summary>
        public double Ice(double wx, double wz)
        {
            if (!Planet.on || wz > 0.0) return 0.0;
            double a = wx / (W * TILE) * Math.PI * 2;
            double nn = noise.Get2D((float)(Math.Cos(a) * 500.0 + 31.0), (float)(Math.Sin(a) * 500.0)) * 40.0;
            return Clamp((-wz - 6.0 + nn) / 140.0, 0.0, 1.0);
        }

        static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

        // Godot's smoothstep, including a reversed range (from > to)
        static double SmoothD(double from, double to, double s)
        {
            if (from == to) return s < from ? 0.0 : 1.0;
            double t = Clamp((s - from) / (to - from), 0.0, 1.0);
            return t * t * (3.0 - 2.0 * t);
        }

        void MakeIsland()
        {
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    int i = y * W + x;
                    double l = Landness((x + 0.5) * TILE, (y + 0.5) * TILE);
                    bool ok = l > 0.11;
                    for (int c = 0; c < 4; c++)
                        if (Landness((x + (c & 1)) * TILE, (y + (c >> 1)) * TILE) <= 0.075) ok = false;
                    land[i] = (byte)(ok ? 1 : 0);
                    height[i] = (float)l;
                }
            Array.Fill(coastDist, 99f);
            var q = new List<int>();
            for (int i = 0; i < W * H; i++)
                if (land[i] == 0) { coastDist[i] = 0f; q.Add(i); }
            int head = 0;
            while (head < q.Count)
            {
                int i = q[head++];
                int x = i % W, y = i / W;
                foreach (var d in DIRS4)
                {
                    int nx = x + d.x, ny = y + d.y;
                    if (!Inside(nx, ny)) continue;
                    int j = Idx(nx, ny);
                    if (coastDist[j] > coastDist[i] + 1f)
                    {
                        coastDist[j] = coastDist[i] + 1f;
                        q.Add(j);
                    }
                }
            }
            var wood = new GodotNoise { Seed = noise.Seed + 7, Frequency = 0.02f };
            for (int i = 0; i < W * H; i++)
            {
                if (land[i] != 1) continue;
                float w = wood.Get2D(i % W, i / W);
                if (w > 0.12f) trees[i] = (byte)(w > 0.35f ? 3 : 2);
                else if (rng.Randf() < 0.06f) trees[i] = 1;
            }
        }

        static readonly Vector2Int[] DIRS4 = { new Vector2Int(1, 0), new Vector2Int(-1, 0), new Vector2Int(0, 1), new Vector2Int(0, -1) };

        // ------------------------------------------------------------ helpers ---

        public int Idx(int x, int y) => y * W + G.Posmod(x, W);
        public bool Inside(int x, int y) => y >= 0 && y < H && (Planet.on || (x >= 0 && x < W));
        public bool IsRoad(int x, int y) => Inside(x, y) && road[Idx(x, y)] == 1;

        /// <summary>Bits: N (y-1) = 1, E (x+1) = 2, S (y+1) = 4, W (x-1) = 8.</summary>
        public int RoadMask(int x, int y)
        {
            int m = 0;
            if (IsRoad(x, y - 1)) m |= 1;
            if (IsRoad(x + 1, y)) m |= 2;
            if (IsRoad(x, y + 1)) m |= 4;
            if (IsRoad(x - 1, y)) m |= 8;
            return m;
        }

        /// <summary>rot 0..3 = S, E, N, W</summary>
        public static readonly Vector2Int[] DIRS = { new Vector2Int(0, 1), new Vector2Int(1, 0), new Vector2Int(0, -1), new Vector2Int(-1, 0) };

        /// <summary>Rotation (0..3) toward the nearest road within 2 tiles, or -1.</summary>
        public int RoadAccessDir(int x, int y)
        {
            for (int dist = 1; dist <= 2; dist++)
                for (int r = 0; r < 4; r++)
                    if (IsRoad(x + DIRS[r].x * dist, y + DIRS[r].y * dist)) return r;
            return -1;
        }

        /// <summary>Flat map metres of a cell's centre (Planet.Warp puts it on the ball).</summary>
        public Vector3 CellCenter(int x, int y) => new Vector3((x + 0.5f) * TILE, 0f, (y + 0.5f) * TILE);

        /// <summary>The cell under a (Godot-space) world position.</summary>
        public Vector2Int WorldToCell(Vector3 p)
        {
            if (Planet.on)
            {
                p = Planet.Unwarp(p);
                return new Vector2Int(G.Posmod(Mathf.FloorToInt(p.x / TILE), W), Mathf.FloorToInt(p.z / TILE));
            }
            return new Vector2Int(Mathf.FloorToInt(p.x / TILE), Mathf.FloorToInt(p.z / TILE));
        }

        public Vector2Int FlatToCell(Vector3 p) =>
            new Vector2Int(Planet.on ? G.Posmod(Mathf.FloorToInt(p.x / TILE), W) : Mathf.FloorToInt(p.x / TILE), Mathf.FloorToInt(p.z / TILE));

        /// <summary>Posts a message to the HUD (for services and other systems).</summary>
        public void Say(string text) => Message?.Invoke(text);

        public int GameDay() => (int)(minutes / 1440.0);

        /// <summary>Hours, 0..24.</summary>
        public double TimeOfDay() => (minutes % 1440.0) / 60.0;

        public bool Spend(double amount)
        {
            if (funds < amount)
            {
                Message?.Invoke($"Not enough money (${(int)amount} needed)");
                return false;
            }
            funds -= amount;
            return true;
        }

        void Changed(RectInt r) => CellsChanged?.Invoke(r);
        static RectInt Grow(RectInt r, int n) => new RectInt(r.x - n, r.y - n, r.width + 2 * n, r.height + 2 * n);

        static RectInt Expand(RectInt r, Vector2Int c)
        {
            int x0 = Math.Min(r.xMin, c.x), y0 = Math.Min(r.yMin, c.y);
            int x1 = Math.Max(r.xMax, c.x + 1), y1 = Math.Max(r.yMax, c.y + 1);
            return new RectInt(x0, y0, x1 - x0, y1 - y0);
        }

        // ------------------------------------------------------------ editing ---

        /// <summary>L-shaped path: along the longer axis first.</summary>
        public List<Vector2Int> RoadPath(Vector2Int a, Vector2Int b)
        {
            var o = new List<Vector2Int>();
            int dx = b.x - a.x, dy = b.y - a.y;
            var corner = Math.Abs(dx) >= Math.Abs(dy) ? new Vector2Int(b.x, a.y) : new Vector2Int(a.x, b.y);
            foreach (var (p, q) in new[] { (a, corner), (corner, b) })
            {
                var step = new Vector2Int(Math.Sign(q.x - p.x), Math.Sign(q.y - p.y));
                var c = p;
                while (true)
                {
                    if (o.Count == 0 || o[o.Count - 1] != c) o.Add(c);
                    if (c == q) break;
                    c += step;
                }
            }
            return o;
        }

        public int RoadCost(List<Vector2Int> path)
        {
            int n = 0;
            foreach (var c in path)
                if (Inside(c.x, c.y) && land[Idx(c.x, c.y)] == 1 && road[Idx(c.x, c.y)] == 0 && !IsSpecialCell(Idx(c.x, c.y))) n++;
            return n * ROAD_COST;
        }

        public bool PlaceRoad(List<Vector2Int> path)
        {
            int cost = RoadCost(path);
            if (cost == 0 || !Spend(cost)) return false;
            var r = new RectInt(path[0], Vector2Int.one);
            foreach (var c in path)
            {
                if (!Inside(c.x, c.y) || land[Idx(c.x, c.y)] == 0 || IsSpecialCell(Idx(c.x, c.y))) continue;
                int i = Idx(c.x, c.y);
                if (bld[i] >= 0) RemoveBuilding(bld[i]);
                if (siteAt[i] >= 0) CancelSite(siteAt[i]);
                road[i] = 1;
                zone[i] = NONE;
                trees[i] = 0;
                r = Expand(r, c);
            }
            _zonedDirty = true;
            Changed(Grow(r, 2));
            return true;
        }

        public RectInt RectCells(Vector2Int a, Vector2Int b)
        {
            var p = new Vector2Int(Math.Min(a.x, b.x), Math.Min(a.y, b.y));
            var q = new Vector2Int(Math.Max(a.x, b.x), Math.Max(a.y, b.y));
            if (Planet.on)
            {
                int dx = G.Posmod(b.x - a.x + W / 2, W) - W / 2;
                p.x = a.x + Math.Min(dx, 0);
                q.x = a.x + Math.Max(dx, 0);
                p.y = Mathf.Clamp(p.y, 0, H - 1);
                q.y = Mathf.Clamp(q.y, 0, H - 1);
                return new RectInt(p, q - p + Vector2Int.one);
            }
            p.Clamp(Vector2Int.zero, new Vector2Int(W - 1, H - 1));
            q.Clamp(Vector2Int.zero, new Vector2Int(W - 1, H - 1));
            return new RectInt(p, q - p + Vector2Int.one);
        }

        public int ZoneCost(RectInt r, int z)
        {
            int n = 0;
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                {
                    int i = Idx(x, y);
                    if (land[i] == 1 && road[i] == 0 && zone[i] != z && !IsSpecialCell(i)) n++;
                }
            return n * ZONE_COST;
        }

        public bool PlaceZone(RectInt r, int z)
        {
            int cost = ZoneCost(r, z);
            if (cost == 0 || !Spend(cost)) return false;
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                {
                    int i = Idx(x, y);
                    if (land[i] == 0 || road[i] == 1 || zone[i] == z || IsSpecialCell(i)) continue;
                    if (bld[i] >= 0) RemoveBuilding(bld[i]);
                    if (siteAt[i] >= 0) CancelSite(siteAt[i]);
                    zone[i] = (byte)z;
                    trees[i] = 0;
                }
            _zonedDirty = true;
            Changed(Grow(r, 1));
            return true;
        }

        public int BulldozeCost(RectInt r)
        {
            int n = 0;
            var seen = new HashSet<int>();
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                {
                    int i = Idx(x, y);
                    if (road[i] == 1) n += 1 + PropsAt(i).Count;
                    else if (bld[i] >= 0 && seen.Add(bld[i])) n++;
                    else if (siteAt[i] >= 0 && seen.Add(siteAt[i])) n++;
                }
            return n * BULLDOZE_COST;
        }

        public bool Bulldoze(RectInt r)
        {
            int cost = BulldozeCost(r);
            bool anyZone = false;
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                    if (zone[Idx(x, y)] != NONE) anyZone = true;
            if (cost == 0 && !anyZone) return false;
            if (cost > 0 && !Spend(cost)) return false;
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                {
                    int i = Idx(x, y);
                    if (bld[i] >= 0) RemoveBuilding(bld[i]);
                    if (siteAt[i] >= 0) CancelSite(siteAt[i]);
                    foreach (int pid in new List<int>(PropsAt(i))) RemoveBuilding(pid);
                    road[i] = 0;
                    zone[i] = NONE;
                }
            _zonedDirty = true;
            Changed(Grow(r, 2));
            return true;
        }

        // ---------------------------------------------------------- buildings ---

        public static int Capacity(Building b) => b.size == 2 ? CAP_BIG[b.zone] : CAP[b.zone][b.stage];

        /// <summary>setup: fills in the extra keys (kind, name, tags...) before BuildingAdded fires.</summary>
        public int AddBuilding(int x, int y, int size, int z, int stage, int rot, bool animate = true, Action<Building> setup = null)
        {
            int id = _nextId++;
            var b = new Building
            {
                id = id, x = x, y = y, size = size, zone = z, stage = stage, rot = rot,
                variant = rng.Randi(), seed = rng.Randf(), born = minutes,
            };
            b.tint = (int)(rng.Randi() % 8);
            b.tint2 = (int)(rng.Randi() % 8);
            setup?.Invoke(b);
            if (animate && construction && size > 0)
            {
                StartSite(b);
                return id;
            }
            Insert(b);
            BuildingAdded?.Invoke(id, animate);
            return id;
        }

        // ------------------------------------------------------- construction ---

        public static readonly double[] BUILD_HOURS = { 0.0, 6.0, 14.0, 30.0 };
        public const double TOWER_HOURS = 48.0;

        public static double BuildMinutes(Building b)
        {
            if (b.HasKind) return 60.0 * (12.0 * b.size - 2.0);
            if (b.size == 2) return 60.0 * TOWER_HOURS;
            return 60.0 * BUILD_HOURS[Mathf.Clamp(b.stage, 1, 3)];
        }

        void StartSite(Building b)
        {
            b.built = 0.0;
            b.dur = BuildMinutes(b);
            sites[b.id] = b;
            for (int dy = 0; dy < b.size; dy++)
                for (int dx = 0; dx < b.size; dx++)
                    siteAt[Idx(b.x + dx, b.y + dy)] = b.id;
            SiteStarted?.Invoke(b.id);
            if (b.HasKind) Message?.Invoke($"Work starts on {b.name ?? "the building"}: about {(int)(b.dur / 60.0)} hours");
            Changed(new RectInt(b.x, b.y, b.size, b.size));
        }

        void ClearSite(Building b)
        {
            sites.Remove(b.id);
            for (int dy = 0; dy < b.size; dy++)
                for (int dx = 0; dx < b.size; dx++)
                    siteAt[Idx(b.x + dx, b.y + dy)] = -1;
        }

        /// <summary>Stops a job and clears its lot.</summary>
        public void CancelSite(int id)
        {
            if (!sites.TryGetValue(id, out var b)) return;
            ClearSite(b);
            SiteEnded?.Invoke(id, false);
            Changed(new RectInt(b.x, b.y, b.size, b.size));
        }

        void FinishSite(int id)
        {
            var b = sites[id];
            ClearSite(b);
            b.built = 0;
            b.dur = 0;
            b.born = minutes;
            Insert(b);
            SiteEnded?.Invoke(id, true);
            BuildingAdded?.Invoke(id, false);
            if (b.HasKind) Message?.Invoke($"{b.name ?? "The building"} is finished");
            Changed(Grow(new RectInt(b.x, b.y, b.size, b.size), 1));
        }

        void AdvanceSites(double gameMinutes)
        {
            if (sites.Count == 0 || gameMinutes <= 0.0) return;
            foreach (int id in sites.Keys())
            {
                var b = sites[id];
                b.built += gameMinutes / Math.Max(b.dur, 1.0);
                if (b.built >= 1.0) FinishSite(id);
            }
        }

        /// <summary>The site on a cell, or null.</summary>
        public Building SiteOn(int x, int y)
        {
            if (!Inside(x, y)) return null;
            int id = siteAt[Idx(x, y)];
            return id >= 0 ? sites[id] : null;
        }

        void Insert(Building b)
        {
            buildings[b.id] = b;
            if (b.size == 0)
            {
                int i = Idx(b.x, b.y);
                if (!_props.TryGetValue(i, out var l)) _props[i] = l = new List<int>();
                l.Add(b.id);
            }
            for (int dy = 0; dy < b.size; dy++)
                for (int dx = 0; dx < b.size; dx++)
                    bld[Idx(b.x + dx, b.y + dy)] = b.id;
            Count(b, 1);
        }

        public void RemoveBuilding(int id)
        {
            if (!buildings.TryGetValue(id, out var b)) return;
            for (int dy = 0; dy < b.size; dy++)
                for (int dx = 0; dx < b.size; dx++)
                    bld[Idx(b.x + dx, b.y + dy)] = -1;
            if (b.size == 0)
            {
                int i = Idx(b.x, b.y);
                _props[i].Remove(id);
                if (_props[i].Count == 0) _props.Remove(i);
            }
            buildings.Remove(id);
            Count(b, -1);
            BuildingRemoved?.Invoke(id);
            Changed(b.Rect);
        }

        void Count(Building b, int sign)
        {
            int c = Capacity(b) * sign;
            switch (b.zone)
            {
                case RES: population += c; break;
                case COM: jobsC += c; break;
                case IND: jobsI += c; break;
            }
        }

        void Recount()
        {
            population = jobsC = jobsI = 0;
            foreach (var b in buildings.Each()) Count(b, 1);
        }

        public Vector3 BuildingCenter(Building b)
        {
            if (b.size == 0)
            {
                var f = DIRS[b.rot];
                return CellCenter(b.x, b.y) - new Vector3(f.x, 0f, f.y) * PROP_OFFSET;
            }
            return new Vector3((b.x + b.size * 0.5f) * TILE, 0f, (b.y + b.size * 0.5f) * TILE);
        }

        /// <summary>The model's door spot for catalog buildings, otherwise the middle of the
        /// side facing the road (flat map, Godot space).</summary>
        public Vector3 DoorPosition(Building b)
        {
            var c = BuildingCenter(b);
            if (b.size == 0) return c;
            var basis = GBasis.Rotation(Vector3.up, b.rot * Mathf.PI * 0.5f);
            if (b.HasKind)
            {
                var door = Catalog.GetDef(b.kind)?.door;
                if (door != null) return c + basis * new Vector3(door.x, 0f, door.z);
            }
            return c + basis * new Vector3(0f, 0f, b.size * TILE * 0.5f - 0.6f);
        }

        // --------------------------------------------------- special buildings ---

        public const float PROP_OFFSET = 5.6f;
        static readonly List<int> NoProps = new List<int>();

        public List<int> PropsAt(int i) => _props.TryGetValue(i, out var l) ? l : NoProps;

        public bool IsSpecialCell(int i) => bld[i] >= 0 && buildings[bld[i]].HasKind;

        /// <summary>"" when the catalog building can go at cell, otherwise why not.</summary>
        public string CanPlaceSpecial(string kind, Vector2Int cell, bool free = false)
        {
            var d = Catalog.GetDef(kind);
            if (d == null) return "Unknown building";
            if (d.placement == "line") return "Drag power lines like a road";
            if (!free && isUnlocked != null && !isUnlocked(kind)) return Catalog.LockText(kind) + " to unlock it";
            if (d.unique && SpecialsOf(kind).Count > 0) return $"The city already has {d.name}";
            if (d.unique)
                foreach (var sb in sites.Each())
                    if (sb.kind == kind) return $"{d.name} is already being built";
            if (!Inside(cell.x, cell.y)) return "Off the map";
            if (d.placement == "street")
            {
                int i = Idx(cell.x, cell.y);
                if (road[i] == 0) return "It goes on a sidewalk: pick a road";
                if (_props.ContainsKey(i)) return "There's already one on this block";
            }
            else
            {
                int s = d.size;
                for (int y = cell.y; y < cell.y + s; y++)
                    for (int x = cell.x; x < cell.x + s; x++)
                    {
                        if (!Inside(x, y) || land[Idx(x, y)] == 0) return "Needs flat land";
                        if (road[Idx(x, y)] == 1) return "Can't build on a road";
                        if (bld[Idx(x, y)] >= 0) return "Bulldoze what's there first";
                        if (siteAt[Idx(x, y)] >= 0) return "Something is being built there";
                    }
                if (d.needsRoad && FrontSide(cell, s) < 0) return "Needs a road alongside";
            }
            if (!free && funds < d.cost) return $"Not enough money (${Catalog.Thousands(d.cost)} needed)";
            return "";
        }

        /// <summary>Buys and places a catalog building: its id, or -1 after a message saying why
        /// not. rot is the side the front faces (DIRS); -1 picks the road side.</summary>
        public int PlaceSpecial(string kind, Vector2Int cell, int rot = -1, bool free = false)
        {
            string why = CanPlaceSpecial(kind, cell, free);
            if (why != "")
            {
                Message?.Invoke(why);
                return -1;
            }
            var d = Catalog.GetDef(kind);
            if (!free && d.cost > 0 && !Spend(d.cost)) return -1;
            int s = d.size;
            if (d.placement == "street")
            {
                if (rot < 0) rot = (SidewalkSide(cell) + 2) % 4;
            }
            else
            {
                for (int y = cell.y; y < cell.y + s; y++)
                    for (int x = cell.x; x < cell.x + s; x++)
                    {
                        zone[Idx(x, y)] = NONE;
                        trees[Idx(x, y)] = 0;
                    }
                _zonedDirty = true;
                if (rot < 0) rot = Math.Max(FrontSide(cell, s), 0);
            }
            int id = AddBuilding(cell.x, cell.y, s, NONE, 1, rot, animateGrowth && !free, b =>
            {
                b.kind = kind;
                b.name = d.name;
                b.tags = (string[])d.tags.Clone();
            });
            Changed(Grow(new RectInt(cell, new Vector2Int(Math.Max(s, 1), Math.Max(s, 1))), 1));
            return id;
        }

        public List<Building> FindTagged(string tag)
        {
            var o = new List<Building>();
            foreach (var b in buildings.Each()) if (b.HasTag(tag)) o.Add(b);
            return o;
        }

        public List<Building> SpecialsOf(string kind)
        {
            var o = new List<Building>();
            foreach (var b in buildings.Each()) if (b.kind == kind) o.Add(b);
            return o;
        }

        /// <summary>The side of a size x size lot with the most road along it, or -1.</summary>
        public int FrontSide(Vector2Int cell, int s)
        {
            int best = -1, most = 0;
            for (int r = 0; r < 4; r++)
            {
                int n = 0;
                for (int k = 0; k < s; k++)
                {
                    Vector2Int p;
                    switch (r)
                    {
                        case 0: p = new Vector2Int(cell.x + k, cell.y + s); break;
                        case 1: p = new Vector2Int(cell.x + s, cell.y + k); break;
                        case 2: p = new Vector2Int(cell.x + k, cell.y - 1); break;
                        default: p = new Vector2Int(cell.x - 1, cell.y + k); break;
                    }
                    if (IsRoad(p.x, p.y)) n++;
                }
                if (n > most) { most = n; best = r; }
            }
            return best;
        }

        /// <summary>The side of a road tile whose sidewalk borders a lot.</summary>
        public int SidewalkSide(Vector2Int c)
        {
            for (int r = 0; r < 4; r++)
            {
                var n = c + DIRS[r];
                if (Inside(n.x, n.y) && land[Idx(n.x, n.y)] == 1 && road[Idx(n.x, n.y)] == 0) return r;
            }
            return 0;
        }

        // --------------------------------------------------------- simulation ---

        /// <summary>Advance the clock. True when at least one hour ticked.</summary>
        public bool Advance(double realSeconds, double speed)
        {
            int before = (int)(minutes / 60.0);
            minutes += realSeconds * MINUTES_PER_SECOND * speed;
            AdvanceSites(realSeconds * MINUTES_PER_SECOND * speed);
            int after = (int)(minutes / 60.0);
            for (int h = before + 1; h <= after; h++)
            {
                HourTick();
                if (h % 24 == 0) DayTick();
                else if (h % 24 == 12) ComputeLandValue();
            }
            return after > before;
        }

        void UpdateDemand()
        {
            double workers = population * 0.55;
            double jobs = jobsC + jobsI;
            double taxPen = (taxRate - 0.09) * 6.0;
            demand[RES] = Clamp(((jobs * 1.1 + 80.0) - workers) / Math.Max(40.0, workers * 0.2) - taxPen, -1.0, 1.0);
            double wantC = population * 0.24 + 15.0;
            demand[COM] = Clamp((wantC - jobsC) / Math.Max(25.0, wantC * 0.3) - taxPen, -1.0, 1.0);
            double wantI = population * 0.34 + 40.0;
            demand[IND] = Clamp((wantI - jobsI) / Math.Max(30.0, wantI * 0.3) - taxPen, -1.0, 1.0);
        }

        readonly List<int> _zonedCache = new List<int>();
        bool _zonedDirty = true;

        List<int> ZonedCells()
        {
            if (_zonedDirty)
            {
                _zonedCache.Clear();
                for (int i = 0; i < W * H; i++) if (zone[i] != NONE) _zonedCache.Add(i);
                _zonedDirty = false;
            }
            return _zonedCache;
        }

        public void MarkZonesDirty() => _zonedDirty = true;

        void HourTick()
        {
            UpdateDemand();
            var cells = ZonedCells();
            if (cells.Count == 0) return;
            int tries = Math.Min(cells.Count, 24 + cells.Count / 12);
            for (int t = 0; t < tries; t++)
            {
                int i = cells[(int)(rng.Randi() % cells.Count)];
                TryGrow(i % W, i / W);
            }
        }

        void TryGrow(int x, int y)
        {
            int i = Idx(x, y);
            int z = zone[i];
            if (z == NONE || road[i] == 1) return;
            double d = demand[z];
            if (d <= 0.02) return;
            if (growthCheck != null && !growthCheck(x, y)) return;
            int rot = RoadAccessDir(x, y);
            if (bld[i] < 0)
            {
                if (rot < 0 || siteAt[i] >= 0) return;
                if (rng.Randf() < 0.45 * d) AddBuilding(x, y, 1, z, 1, rot, animateGrowth);
                return;
            }
            var b = buildings[bld[i]];
            if (b.stage >= 3 || b.size == 2) return;
            if (minutes - b.born < 60.0 * 30.0) return;
            int next = b.stage + 1;
            bool lvOk = z == IND || landValue[i] >= STAGE_LV[next];
            if (population < STAGE_POP[next] || !lvOk || !b.connected) return;
            if (rng.Randf() > 0.18 * d) return;
            if (next == 3 && TryMerge(b)) return;
            RemoveBuilding(b.id);
            AddBuilding(x, y, 1, z, next, rot >= 0 ? rot : b.rot, animateGrowth);
        }

        static readonly Vector2Int[] MERGE_OFFS = { new Vector2Int(0, 0), new Vector2Int(-1, 0), new Vector2Int(0, -1), new Vector2Int(-1, -1) };

        /// <summary>Grow a 2x2 tower when the three neighbouring lots are the same zone at stage >= 2.</summary>
        bool TryMerge(Building b)
        {
            if (rng.Randf() > 0.5) return false;
            foreach (var off in MERGE_OFFS)
            {
                int ox = b.x + off.x, oy = b.y + off.y;
                bool ok = true;
                var ids = new List<int>();
                for (int dy = 0; dy < 2 && ok; dy++)
                    for (int dx = 0; dx < 2; dx++)
                    {
                        int cx = ox + dx, cy = oy + dy;
                        if (!Inside(cx, cy)) { ok = false; break; }
                        int j = Idx(cx, cy);
                        if (zone[j] != b.zone || road[j] == 1 || bld[j] < 0) { ok = false; break; }
                        var nb = buildings[bld[j]];
                        if (nb.size != 1 || nb.stage < 2) { ok = false; break; }
                        if (!ids.Contains(nb.id)) ids.Add(nb.id);
                    }
                if (!ok) continue;
                int rot = -1;
                for (int dy = 0; dy < 2; dy++)
                    for (int dx = 0; dx < 2; dx++)
                    {
                        int r = RoadAccessDir(ox + dx, oy + dy);
                        if (r >= 0 && rot < 0) rot = r;
                    }
                if (rot < 0) continue;
                foreach (int id in ids) RemoveBuilding(id);
                AddBuilding(ox, oy, 2, b.zone, 3, rot, animateGrowth);
                return true;
            }
            return false;
        }

        void DayTick()
        {
            ComputeTraffic();
            double income = (population + (jobsC + jobsI) * 0.8) * taxRate * 3.0;
            int roads = 0;
            for (int i = 0; i < W * H; i++) roads += road[i];
            double expense = roads * ROAD_UPKEEP;
            foreach (var b in buildings.Each())
            {
                if (!b.HasKind) continue;
                double u = Catalog.GetDef(b.kind)?.upkeep ?? 0f;
                if (u >= 0.0) expense += u;
                else income -= u;
            }
            funds += income - expense;
            lastIncome = income;
            lastExpense = expense;
            DayPassed?.Invoke();
        }

        /// <summary>Commuter traffic: a multi-source BFS over roads from every job site, then
        /// one pass back up the BFS order carries each home's commuters along its route.</summary>
        public void ComputeTraffic()
        {
            int n = W * H;
            var flow = new float[n];
            var parent = new int[n];
            Array.Fill(parent, -2);
            var cellsOf = new Dictionary<int, List<int>>();
            foreach (var b in buildings.Each()) cellsOf[b.id] = BuildingRoadCells(b);
            var q = new List<int>();
            foreach (var b in buildings.Each())
            {
                if (b.zone == RES) continue;
                foreach (int c in cellsOf[b.id])
                    if (parent[c] == -2) { parent[c] = -1; q.Add(c); }
            }
            int head = 0;
            while (head < q.Count)
            {
                int c = q[head++];
                int cx = c % W, cy = c / W;
                foreach (var d in DIRS)
                {
                    int nx = cx + d.x, ny = cy + d.y;
                    if (!IsRoad(nx, ny)) continue;
                    int j = Idx(nx, ny);
                    if (parent[j] == -2) { parent[j] = c; q.Add(j); }
                }
            }
            foreach (var b in buildings.Each())
            {
                if (b.zone != RES) continue;
                int start = -1;
                foreach (int c in cellsOf[b.id])
                    if (parent[c] != -2) { start = c; break; }
                b.connected = start >= 0 || population < 60;
                if (start >= 0) flow[start] += (float)(Capacity(b) * 0.55);
            }
            for (int k = q.Count - 1; k >= 0; k--)
            {
                int c = q[k];
                if (parent[c] >= 0) flow[parent[c]] += flow[c];
            }
            // Job sites are "connected" when their road network also reaches some home.
            var comp = new int[n];
            Array.Fill(comp, -1);
            int label = 0;
            var stack = new List<int>();
            for (int s0 = 0; s0 < n; s0++)
            {
                if (road[s0] == 0 || comp[s0] >= 0) continue;
                stack.Clear();
                stack.Add(s0);
                comp[s0] = label;
                while (stack.Count > 0)
                {
                    int c = stack[stack.Count - 1];
                    stack.RemoveAt(stack.Count - 1);
                    int cx = c % W, cy = c / W;
                    foreach (var d in DIRS)
                    {
                        int nx = cx + d.x, ny = cy + d.y;
                        if (!IsRoad(nx, ny)) continue;
                        int j = Idx(nx, ny);
                        if (comp[j] < 0) { comp[j] = label; stack.Add(j); }
                    }
                }
                label++;
            }
            var homeComps = new HashSet<int>();
            foreach (var b in buildings.Each())
                if (b.zone == RES)
                    foreach (int c in cellsOf[b.id]) homeComps.Add(comp[c]);
            foreach (var b in buildings.Each())
            {
                if (b.zone == RES) continue;
                bool ok = population < 60;
                foreach (int c in cellsOf[b.id])
                    if (homeComps.Contains(comp[c])) { ok = true; break; }
                b.connected = ok;
            }
            for (int i = 0; i < n; i++) traffic[i] = road[i] == 1 ? (float)(flow[i] / 900.0) : 0f;
        }

        /// <summary>Road cells 1 or 2 tiles straight out from each side of the lot.</summary>
        List<int> BuildingRoadCells(Building b)
        {
            var o = new List<int>();
            int s = b.size, bx = b.x, by = b.y;
            for (int dist = 1; dist <= 2; dist++)
                for (int k = 0; k < s; k++)
                {
                    AddRoadCell(o, bx + k, by - dist);
                    AddRoadCell(o, bx + k, by + s - 1 + dist);
                    AddRoadCell(o, bx - dist, by + k);
                    AddRoadCell(o, bx + s - 1 + dist, by + k);
                }
            return o;
        }

        void AddRoadCell(List<int> o, int x, int y)
        {
            if (Inside(x, y) && road[Idx(x, y)] == 1) o.Add(Idx(x, y));
        }

        public void ComputeLandValue()
        {
            int n = W * H;
            var com = new float[n];
            var ind = new float[n];
            var res = new float[n];
            var green = new float[n];
            var traf = new float[n];
            foreach (var b in buildings.Each())
            {
                float w = (float)(b.stage * (b.size == 2 ? 2.0 : 1.0));
                int i = Idx(b.x, b.y);
                switch (b.zone)
                {
                    case COM: com[i] += w; break;
                    case IND: ind[i] += w; break;
                    case RES: res[i] += w; break;
                }
            }
            for (int i = 0; i < n; i++)
            {
                green[i] = trees[i];
                traf[i] = Math.Min(traffic[i], 2f);
            }
            com = Blur(com, 6);
            ind = Blur(ind, 5);
            res = Blur(res, 5);
            green = Blur(green, 3);
            traf = Blur(traf, 2);
            for (int i = 0; i < n; i++)
            {
                if (land[i] == 0) { landValue[i] = 0f; continue; }
                double v = 0.28;
                v += Math.Min(com[i] * 0.9, 0.3);
                v += Math.Min(res[i] * 0.5, 0.15);
                v += Math.Min(green[i] * 0.5, 0.12);
                v += 0.18 * Clamp(1.0 - (coastDist[i] - 2.0) / 6.0, 0.0, 1.0);
                v -= Math.Min(ind[i] * 1.6, 0.4) * (zone[i] == IND ? 0.4 : 1.0);
                v -= Math.Max(traf[i] - 0.6, 0.0) * 0.6;
                landValue[i] = (float)Clamp(v, 0.0, 1.0);
            }
            LandValueComputed?.Invoke();
        }

        /// <summary>Separable box blur over a (2r+1)^2 window; wraps east to west on a planet.</summary>
        public float[] Blur(float[] src, int r)
        {
            var tmp = new float[src.Length];
            var o = new float[src.Length];
            double k = 1.0 / (2 * r + 1);
            bool wrap = Planet.on;
            for (int y = 0; y < H; y++)
            {
                double acc = 0.0;
                for (int x = -r; x <= r; x++)
                    if (wrap || (x >= 0 && x < W)) acc += src[y * W + G.Posmod(x, W)];
                for (int x = 0; x < W; x++)
                {
                    tmp[y * W + x] = (float)(acc * k);
                    int xo = x - r, xi = x + r + 1;
                    if (wrap || xo >= 0) acc -= src[y * W + G.Posmod(xo, W)];
                    if (wrap || xi < W) acc += src[y * W + G.Posmod(xi, W)];
                }
            }
            for (int x = 0; x < W; x++)
            {
                double acc = 0.0;
                for (int y = -r; y <= r; y++)
                    if (y >= 0 && y < H) acc += tmp[y * W + x];
                for (int y = 0; y < H; y++)
                {
                    o[y * W + x] = (float)(acc * k);
                    int yo = y - r, yi = y + r + 1;
                    if (yo >= 0) acc -= tmp[yo * W + x];
                    if (yi < H) acc += tmp[yi * W + x];
                }
            }
            return o;
        }

        /// <summary>Fast-forward without animation (demo city, tests).</summary>
        public void SimulateHours(int hours)
        {
            for (int h = 0; h < hours; h++)
            {
                minutes += 60.0;
                AdvanceSites(60.0);
                HourTick();
                int hh = (int)(minutes / 60.0) % 24;
                if (hh == 0) DayTick();
                else if (hh == 12) ComputeLandValue();
            }
        }

        // ----------------------------------------------------------- starters ---

        /// <summary>A land cell near the middle (on the planet, half way round from the seam).</summary>
        public Vector2Int CenterCell()
        {
            var c = Planet.on ? new Vector2Int(W / 2, H / 2 - 3) : new Vector2Int(W / 2, H / 2);
            for (int r = 0; r < 20; r++)
                for (int y = c.y - r; y <= c.y + r; y++)
                    for (int x = c.x - r; x <= c.x + r; x++)
                        if (Inside(x, y) && land[Idx(x, y)] == 1) return new Vector2Int(x, y);
            return c;
        }

        int Dxc(int a, int b) => Planet.on ? G.Posmod(b - a + W / 2, W) - W / 2 : b - a;

        void FreeRoad(int x, int y)
        {
            if (Inside(x, y) && land[Idx(x, y)] == 1)
            {
                road[Idx(x, y)] = 1;
                trees[Idx(x, y)] = 0;
            }
        }

        /// <summary>A main avenue crossing the island with a short cross street: free starter roads.</summary>
        public void BuildStarter()
        {
            var c = CenterCell();
            if (Planet.on) c.y = H / 2;
            for (int x = 0; x < W; x++) FreeRoad(x, c.y);
            for (int y = c.y - 12; y <= c.y + 12; y++) FreeRoad(c.x, y);
            ComputeLandValue();
            Changed(new RectInt(0, 0, W, H));
        }

        /// <summary>A pre-planned city: a street grid of 2-deep blocks, downtown commercial in the
        /// middle, homes around it, industry on the west side.</summary>
        public void BuildDemo(int growHours = 24 * 45)
        {
            var c = CenterCell();
            if (Planet.on)
                for (int x = 0; x < W; x++) FreeRoad(x, H / 2);
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    int dx = Dxc(c.x, x), dy = y - c.y;
                    if (Math.Abs(dx) > 30 || Math.Abs(dy) > 27) continue;
                    if (G.Posmod(dx, 6) == 0 || G.Posmod(dy, 3) == 0) FreeRoad(x, y);
                }
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                {
                    int i = Idx(x, y);
                    if (land[i] == 0 || road[i] == 1) continue;
                    int dx = Dxc(c.x, x), dy = y - c.y;
                    if (Math.Abs(dx) > 30 || Math.Abs(dy) > 27) continue;
                    double r = Math.Sqrt(dx * dx + dy * dy * 1.3);
                    int z = RES;
                    if (r < 11.0) z = COM;
                    else if (dx < -17) z = IND;
                    else if (r < 17.0 && rng.Randf() < 0.3) z = COM;
                    zone[i] = (byte)z;
                    trees[i] = 0;
                }
            MarkZonesDirty();
            funds = 250000.0;
            ComputeLandValue();
            bool was = animateGrowth;
            animateGrowth = false;
            for (int h = 0; h < growHours; h++)
            {
                minutes += 60.0;
                UpdateDemand();
                var cells = ZonedCells();
                for (int t = 0; t < 120; t++)
                {
                    int i = cells[(int)(rng.Randi() % cells.Count)];
                    TryGrow(i % W, i / W);
                }
                if (h % 24 == 0) DayTick();
                else if (h % 24 == 12) ComputeLandValue();
            }
            animateGrowth = was;
            minutes = GameDay() * 1440.0 + 17.5 * 60.0;
            Changed(new RectInt(0, 0, W, H));
        }
    }
}
