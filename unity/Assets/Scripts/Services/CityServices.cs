// Port of services/city_services.gd. City services: power, parks, sanitation, police and fire,
// on a radius model over the City grid. No rendering here (see ServicesView).
//
// Coverage and the power grid are recomputed only when something changes (a road, zone, building
// or power line); the City events mark them dirty and the next read or Update() rebuilds them.
// Garbage, crime, happiness and approval run once per game day and go to Progress stats.
using System;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class CityServices
    {
        public event Action CoverageChanged;        // coverage maps or the power grid were rebuilt
        public event Action StatsChanged;           // the daily numbers were updated
        public event Action FacilitiesChanged;      // a service building was added or removed
        public event Action PoliceStationsChanged;  // the list from PoliceStations() changed

        /// <summary>Street results from missions (a busted crime den, a good Game day), when present.</summary>
        public interface IStreetEffects
        {
            double CrimeMult(int x, int y);
            double HappinessAdd(int x, int y);
        }

        public readonly int N;
        /// <summary>Below this population the city may grow without power, so a new game can get going.</summary>
        public const int POWER_GRACE_POP = 100;
        /// <summary>Days without power (or this unhappy) before a building drops a stage or empties out.</summary>
        public const int DECAY_DAYS = 6;
        public const float UNHAPPY = 0.15f;
        public const int MAX_DECAY_PER_DAY = 12;
        /// <summary>Uncollected garbage above this level (0..1) shows as piles on the street.</summary>
        public const float PILE_LEVEL = 0.34f;

        public enum Overlay { NONE, POWER, PARKS, GARBAGE, POLICE, FIRE, CRIME, HAPPINESS }
        public static readonly string[] OVERLAY_NAMES = { "None", "Power", "Parks", "Garbage", "Police", "Fire", "Crime", "Happiness" };

        public readonly City city;
        /// <summary>Used when there's no Progress store (tests): the Resident's goodness, -100 .. 100.</summary>
        public double goodness;
        public IStreetEffects streetEffects;
        double _supplyScale = 1.0;
        /// <summary>Scales every plant's output (1 = normal). Events like a failing substation can lower it.</summary>
        public double SupplyScale { get => _supplyScale; set { _supplyScale = value; _dirtyPower = true; } }

        public readonly OrderedMap<int, string> facilities = new OrderedMap<int, string>();  // building id -> kind
        public byte[] powerLine;   // 1 = power line on this cell

        // Per-cell maps, all N long.
        public byte[] power;          // 0 nothing, 1 grid or building without power, 2 powered
        public float[] park, police, fire, garbageReach, garbage, crime, fireRisk, happiness;

        // Per-building state (building id -> value).
        public OrderedMap<int, double> backlog = new OrderedMap<int, double>();
        public OrderedMap<int, int> unpoweredDays = new OrderedMap<int, int>();
        public OrderedMap<int, int> unhappyDays = new OrderedMap<int, int>();

        // Daily numbers.
        public double supplyMw, demandMw;
        public double powerPct = 100.0, garbagePct = 100.0, garbageTons;
        public double crimeAvg, happinessAvg = 0.5, approval = 55.0, incomePerResident, lastUpkeep;

        bool _dirtyCov = true, _dirtyPower = true;
        readonly System.Random _shuffle = new System.Random();

        public CityServices(City c)
        {
            city = c;
            N = City.W * City.H;
            powerLine = new byte[N];
            power = new byte[N];
            park = new float[N]; police = new float[N]; fire = new float[N]; garbageReach = new float[N];
            garbage = new float[N]; crime = new float[N]; fireRisk = new float[N]; happiness = new float[N];
            city.CellsChanged += _ => _dirtyPower = true;
            city.BuildingAdded += OnBuildingAdded;
            city.BuildingRemoved += OnBuildingRemoved;
            city.DayPassed += OnDay;
            city.growthCheck = (x, y) => GrowthOk(city.Idx(x, y));
            city.LandValueComputed += OnLandValue;
            Rescan();
        }

        // ------------------------------------------------------------------ events ---

        void OnBuildingAdded(int id, bool animate)
        {
            if (ServiceDefs.Has(city.buildings[id].kind)) Register(id);
            _dirtyPower = true;
        }

        void OnBuildingRemoved(int id)
        {
            backlog.Remove(id);
            unpoweredDays.Remove(id);
            unhappyDays.Remove(id);
            if (facilities.ContainsKey(id)) Unregister(id);
            _dirtyPower = true;
        }

        void Register(int id)
        {
            var b = city.buildings[id];
            facilities[id] = b.kind;
            _dirtyCov = _dirtyPower = true;
            if (ServiceDefs.ServiceOf(b.kind) == "police") PoliceStationsChanged?.Invoke();
            FacilitiesChanged?.Invoke();
        }

        void Unregister(int id)
        {
            string kind = facilities[id];
            facilities.Remove(id);
            _dirtyCov = _dirtyPower = true;
            if (ServiceDefs.ServiceOf(kind) == "police") PoliceStationsChanged?.Invoke();
            FacilitiesChanged?.Invoke();
        }

        /// <summary>Re-reads every service building from City.buildings (after loading a save).</summary>
        public void Rescan()
        {
            facilities.Clear();
            foreach (var b in city.buildings.Each())
                if (ServiceDefs.Has(b.kind)) facilities[b.id] = b.kind;
            _dirtyCov = _dirtyPower = true;
            FacilitiesChanged?.Invoke();
            PoliceStationsChanged?.Invoke();
        }

        /// <summary>Rebuilds whatever is out of date. Cheap when nothing changed; call it every frame or so.</summary>
        public void Update()
        {
            if (!(_dirtyCov || _dirtyPower)) return;
            if (_dirtyCov) ComputeCoverage();
            if (_dirtyPower) ComputePower();
            _dirtyCov = _dirtyPower = false;
            CoverageChanged?.Invoke();
        }

        // ---------------------------------------------------------------- placement ---

        public string CanPlace(string kind, Vector2Int cell, bool free = false) => city.CanPlaceSpecial(kind, cell, free);

        /// <summary>Buys and places a catalog building with its top-left tile at cell. Returns its id, or -1.</summary>
        public int PlaceFacility(string kind, Vector2Int cell, bool free = false)
        {
            int id = city.PlaceSpecial(kind, cell, -1, free);
            Update();
            return id;
        }

        public int LineCost(List<Vector2Int> path)
        {
            int n = 0;
            foreach (var c in path)
            {
                if (!city.Inside(c.x, c.y)) continue;
                int i = city.Idx(c.x, c.y);
                if (city.land[i] == 1 && city.road[i] == 0 && powerLine[i] == 0 && city.bld[i] < 0) n++;
            }
            var d = Catalog.GetDef("power_line");
            return n * (d != null ? d.cost : 5);
        }

        /// <summary>Power lines carry power across land without roads or buildings. Path as from City.RoadPath().</summary>
        public bool PlaceLine(List<Vector2Int> path)
        {
            int cost = LineCost(path);
            if (cost == 0 || !city.Spend(cost)) return false;
            foreach (var c in path)
            {
                if (!city.Inside(c.x, c.y)) continue;
                int i = city.Idx(c.x, c.y);
                if (city.land[i] == 1 && city.road[i] == 0 && city.bld[i] < 0) powerLine[i] = 1;
            }
            _dirtyPower = true;
            Update();
            return true;
        }

        /// <summary>Removes power lines in a rectangle (call it from the bulldoze tool). Returns how many went.</summary>
        public int BulldozeLines(RectInt r)
        {
            int n = 0;
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++)
                    if (city.Inside(x, y) && powerLine[city.Idx(x, y)] == 1)
                    {
                        powerLine[city.Idx(x, y)] = 0;
                        n++;
                    }
            if (n > 0)
            {
                _dirtyPower = true;
                Update();
            }
            return n;
        }

        // ------------------------------------------------------------------ queries ---

        public class Station
        {
            public int id;
            public string kind, name;
            public Vector2Int cell;
            public int size;
            public Vector3 center, door, road;  // Godot-space world points
            public float radiusM;
            public string[] tags;
        }

        /// <summary>Service buildings of one service ("power", "park", "garbage", "police", "fire").</summary>
        public List<Station> Stations(string service)
        {
            var o = new List<Station>();
            foreach (var kv in facilities)
            {
                var d = ServiceDefs.Get(kv.Value);
                if (d == null || d.service != service || !city.buildings.TryGetValue(kv.Key, out var b)) continue;
                o.Add(new Station
                {
                    id = kv.Key, kind = kv.Value, name = b.name ?? "", cell = new Vector2Int(b.x, b.y), size = b.size,
                    center = city.BuildingCenter(b), door = city.DoorPosition(b), road = RoadPoint(b),
                    radiusM = d.radius * City.TILE, tags = b.tags ?? new string[0],
                });
            }
            return o;
        }

        public List<Station> PoliceStations() => Stations("police");
        public List<Station> FireStations() => Stations("fire");
        public List<Station> GarbageDepots() => Stations("garbage");

        /// <summary>The centre of the road tile nearest the building (where vehicles leave from).</summary>
        Vector3 RoadPoint(Building b)
        {
            var best = new Vector2Int(-1, -1);
            float bd = 1e9f;
            int s = b.size;
            var mid = new Vector2(b.x + s * 0.5f, b.y + s * 0.5f);
            for (int y = b.y - 2; y < b.y + s + 2; y++)
                for (int x = b.x - 2; x < b.x + s + 2; x++)
                    if (city.IsRoad(x, y))
                    {
                        float dd = (new Vector2(x + 0.5f, y + 0.5f) - mid).sqrMagnitude;
                        if (dd < bd) { bd = dd; best = new Vector2Int(x, y); }
                    }
            return best.x < 0 ? city.BuildingCenter(b) : city.CellCenter(best.x, best.y);
        }

        int CellOf(Vector3 world)
        {
            var c = city.WorldToCell(world);
            return city.Inside(c.x, c.y) ? city.Idx(c.x, c.y) : -1;
        }

        /// <summary>Coverage 0..1 of "power" (1 if powered), "park", "garbage", "police" or "fire" at a world point.</summary>
        public float CoverageAt(string service, Vector3 world)
        {
            Update();
            int i = CellOf(world);
            if (i < 0) return 0f;
            switch (service)
            {
                case "power": return power[i] == 2 ? 1f : 0f;
                case "park": return park[i];
                case "garbage": return garbageReach[i];
                case "police": return police[i];
                case "fire": return fire[i];
            }
            return 0f;
        }

        public float CrimeAt(Vector3 world)
        {
            int i = CellOf(world);
            return i >= 0 ? crime[i] : 0f;
        }

        public bool IsPowered(int id) => city.buildings.TryGetValue(id, out var b) && b.powered;

        /// <summary>Whether power matters yet: once the city has a plant or passes the grace population.</summary>
        public bool PowerInPlay()
        {
            if (city.population >= POWER_GRACE_POP) return true;
            foreach (var kv in facilities)
                if (ServiceDefs.ServiceOf(kv.Value) == "power") return true;
            return false;
        }

        public bool GrowthOk(int i) => !PowerInPlay() || power[i] == 2;

        /// <summary>What parks, garbage and crime add to land value at cell index i.</summary>
        public float LandValueDelta(int i) => park[i] * 0.18f - garbage[i] * 0.15f - crime[i] * 0.12f;

        void OnLandValue()
        {
            Update();
            for (int i = 0; i < N; i++)
                if (city.land[i] == 1)
                    city.landValue[i] = Mathf.Clamp(city.landValue[i] + LandValueDelta(i), 0f, 1f);
        }

        Progress Store => Progress.I != null && Progress.I.city == city ? Progress.I : null;

        /// <summary>The Resident's goodness from the Progress store, or the local value in tests.</summary>
        public double CurrentGoodness() => Store != null ? Store.goodness : goodness;

        /// <summary>World points (Godot space) for garbage bags and piles on the sidewalk.</summary>
        public List<Vector3> GarbagePiles()
        {
            var o = new List<Vector3>();
            foreach (var kv in backlog)
            {
                if (!city.buildings.TryGetValue(kv.Key, out var b)) continue;
                float lvl = garbage[city.Idx(b.x, b.y)];
                if (lvl < PILE_LEVEL) continue;
                int n = 1 + (int)((lvl - PILE_LEVEL) / (1f - PILE_LEVEL) * 2.99f);
                var dir = City.DIRS[b.rot];
                Vector3 front = city.BuildingCenter(b) + new Vector3(dir.x, 0, dir.y) * (b.size * City.TILE * 0.5f + 0.6f);
                var side = new Vector3(-dir.y, 0, dir.x);
                for (int k = 0; k < n; k++)
                {
                    float h = G.Fposmod((float)(Math.Sin(kv.Key * 7 + k * 13) * 43758.5453), 1f);
                    o.Add(front + side * ((h - 0.5f) * b.size * City.TILE * 0.7f));
                }
            }
            return o;
        }

        /// <summary>The daily numbers; all 0..100 except income and the raw amounts.</summary>
        public Dictionary<string, double> Stats() => new Dictionary<string, double>
        {
            { "power_pct", powerPct }, { "garbage_pct", garbagePct }, { "crime", crimeAvg * 100.0 },
            { "happiness", happinessAvg * 100.0 }, { "approval", approval }, { "income_per_resident", incomePerResident },
            { "supply_mw", supplyMw }, { "demand_mw", demandMw }, { "garbage_tons", garbageTons },
            { "line_upkeep", lastUpkeep },
        };

        /// <summary>Values 0..1 per cell for an Overlay mode, for the map overlay. Null for NONE.</summary>
        public float[] OverlayValues(Overlay mode)
        {
            Update();
            switch (mode)
            {
                case Overlay.POWER:
                {
                    var o = new float[N];
                    for (int i = 0; i < N; i++)
                        o[i] = powerLine[i] == 0 || power[i] != 0 ? (power[i] == 0 ? 0f : power[i] == 1 ? 0.25f : 1f) : 0.6f;
                    return o;
                }
                case Overlay.PARKS: return park;
                case Overlay.POLICE: return police;
                case Overlay.FIRE: return fire;
                // Per-building numbers spread onto the streets around them, so they show between towers.
                case Overlay.GARBAGE: return Spread(garbage);
                case Overlay.CRIME: return Spread(crime);
                case Overlay.HAPPINESS: return Spread(happiness);
            }
            return null;
        }

        /// <summary>Average of the built cells around each cell (radius 1), 0 where nothing is built nearby.</summary>
        float[] Spread(float[] f)
        {
            var built = new float[N];
            for (int i = 0; i < N; i++) if (city.bld[i] >= 0) built[i] = 1f;
            var sum = city.Blur(f, 1);
            var cnt = city.Blur(built, 1);
            var o = new float[N];
            for (int i = 0; i < N; i++) o[i] = cnt[i] > 0.01f ? sum[i] / cnt[i] : 0f;
            return o;
        }

        // ------------------------------------------------------------------ coverage ---

        void ComputeCoverage()
        {
            Array.Clear(park, 0, N); Array.Clear(police, 0, N); Array.Clear(fire, 0, N); Array.Clear(garbageReach, 0, N);
            foreach (var kv in facilities)
            {
                if (!city.buildings.TryGetValue(kv.Key, out var b)) continue;
                var d = ServiceDefs.Get(kv.Value);
                float cx = b.x + b.size * 0.5f, cy = b.y + b.size * 0.5f;
                switch (d.service)
                {
                    case "park": Stamp(park, cx, cy, d.radius, d.strength, false); break;
                    case "police": Stamp(police, cx, cy, d.radius, d.strength, false); break;
                    case "fire": Stamp(fire, cx, cy, d.radius, d.strength, false); break;
                    case "garbage": Stamp(garbageReach, cx, cy, d.radius, 1f, true); break;
                }
            }
            foreach (var f in new[] { park, police, fire, garbageReach })
                for (int i = 0; i < N; i++) f[i] = Mathf.Min(f[i], 1f);
        }

        /// <summary>Adds a radial falloff (or a flat disc with a soft rim) around a point in tile units.</summary>
        void Stamp(float[] field, float cx, float cy, float r, float s, bool flat)
        {
            if (r <= 0f) return;
            int y1 = Math.Min(City.H, Mathf.CeilToInt(cy + r) + 1);
            for (int y = Math.Max(0, Mathf.FloorToInt(cy - r)); y < y1; y++)
            {
                int x0 = Planet.on ? Mathf.FloorToInt(cx - r) : Math.Max(0, Mathf.FloorToInt(cx - r));
                int x1 = Planet.on ? Mathf.CeilToInt(cx + r) + 1 : Math.Min(City.W, Mathf.CeilToInt(cx + r) + 1);
                for (int x = x0; x < x1; x++)
                {
                    float t = new Vector2(x + 0.5f - cx, y + 0.5f - cy).magnitude / r;
                    if (t >= 1f) continue;
                    float v = s * (flat ? Mathf.Clamp((1f - t) * 5f, 0f, 1f) : 1f - t * t);
                    field[y * City.W + G.Posmod(x, City.W)] += v;
                }
            }
        }

        // --------------------------------------------------------------------- power ---

        double Demand(Building b)
        {
            if (b.HasKind)
            {
                if (ServiceDefs.ServiceOf(b.kind) == "power") return 0.0;
                return ServiceDefs.SPECIAL_MW * Math.Max(b.size, 1);
            }
            return City.Capacity(b) * ServiceDefs.MW_PER_CAP[b.zone];
        }

        /// <summary>Plants feed every building connected to them through roads, power lines, zoned land and
        /// other buildings. Each connected network pools its plants' output; when demand is higher, the
        /// buildings nearest a plant get power first.</summary>
        void ComputePower()
        {
            var cond = new byte[N];
            for (int i = 0; i < N; i++)
                if (city.road[i] == 1 || powerLine[i] == 1 || city.bld[i] >= 0 || city.zone[i] != City.NONE) cond[i] = 1;
            var comp = new int[N];
            for (int i = 0; i < N; i++) comp[i] = -1;
            int label = 0;
            var stack = new Stack<int>();
            var nb = new int[4];
            for (int s0 = 0; s0 < N; s0++)
            {
                if (cond[s0] == 0 || comp[s0] >= 0) continue;
                stack.Push(s0);
                comp[s0] = label;
                while (stack.Count > 0)
                {
                    int c = stack.Pop();
                    int k = Neighbours(c, nb);
                    for (int m = 0; m < k; m++)
                    {
                        int j = nb[m];
                        if (cond[j] == 1 && comp[j] < 0) { comp[j] = label; stack.Push(j); }
                    }
                }
                label++;
            }
            var remaining = new Dictionary<int, double>();
            var q = new List<int>();
            var seen = new byte[N];
            supplyMw = 0.0;
            foreach (var kv in facilities)
            {
                var d = ServiceDefs.Get(kv.Value);
                if (d.service != "power" || !city.buildings.TryGetValue(kv.Key, out var b)) continue;
                int lab = comp[city.Idx(b.x, b.y)];
                double mw = d.mw * _supplyScale;
                remaining.TryGetValue(lab, out double had);
                remaining[lab] = had + mw;
                supplyMw += mw;
                for (int dy = 0; dy < b.size; dy++)
                    for (int dx = 0; dx < b.size; dx++)
                    {
                        int i = city.Idx(b.x + dx, b.y + dy);
                        if (seen[i] == 0) { seen[i] = 1; q.Add(i); }
                    }
            }
            var got = new Dictionary<int, bool>();
            demandMw = 0.0;
            foreach (var b in city.buildings.Each()) demandMw += Demand(b);
            double served = 0.0;
            int head = 0;
            while (head < q.Count)
            {
                int c = q[head++];
                int bid = city.bld[c];
                if (bid >= 0 && !got.ContainsKey(bid))
                {
                    double need = Demand(city.buildings[bid]);
                    int lab = comp[c];
                    remaining.TryGetValue(lab, out double left);
                    got[bid] = left >= need;
                    if (left >= need)
                    {
                        remaining[lab] = left - need;
                        served += need;
                    }
                }
                int k = Neighbours(c, nb);
                for (int m = 0; m < k; m++)
                {
                    int j = nb[m];
                    if (cond[j] == 1 && seen[j] == 0) { seen[j] = 1; q.Add(j); }
                }
            }
            foreach (var b in city.buildings.Each())
                b.powered = got.TryGetValue(b.id, out bool on) && on;
            for (int i = 0; i < N; i++)
            {
                int bid = city.bld[i];
                if (bid >= 0) power[i] = (byte)(got.TryGetValue(bid, out bool on) && on ? 2 : 1);
                else if (cond[i] == 1)
                {
                    remaining.TryGetValue(comp[i], out double left);
                    power[i] = (byte)(left > 0.5 && seen[i] == 1 ? 2 : 1);
                }
                else power[i] = 0;
            }
            powerPct = demandMw <= 0.0 ? 100.0 : served / demandMw * 100.0;
        }

        int Neighbours(int c, int[] o)
        {
            int x = c % City.W, y = c / City.W, n = 0;
            if (x > 0) o[n++] = c - 1;
            else if (Planet.on) o[n++] = c + City.W - 1;
            if (x < City.W - 1) o[n++] = c + 1;
            else if (Planet.on) o[n++] = c - City.W + 1;
            if (y > 0) o[n++] = c - City.W;
            if (y < City.H - 1) o[n++] = c + City.W;
            return n;
        }

        // ----------------------------------------------------------------- the day ---

        void OnDay()
        {
            Update();
            GarbageDay();
            CrimeAndHappiness();
            Upkeep();
            Decay();
            // City's day tick just re-derived "connected"; unpowered buildings can't upgrade either.
            if (PowerInPlay())
                foreach (var b in city.buildings.Each())
                    if (!b.powered) b.connected = false;
            var st = Store;
            if (st != null)
            {
                st.SetStat("power_pct", powerPct);
                st.SetStat("garbage_pct", garbagePct);
                st.SetStat("crime", crimeAvg * 100.0);
                st.SetStat("happiness", happinessAvg * 100.0);
                st.SetStat("approval", approval);
                st.SetStat("income_per_resident", incomePerResident);
            }
            StatsChanged?.Invoke();
        }

        class Depot { public float x, y, r; public double left; }

        void GarbageDay()
        {
            var depots = new List<Depot>();
            foreach (var kv in facilities)
            {
                var d = ServiceDefs.Get(kv.Value);
                if (d.service == "garbage" && city.buildings.TryGetValue(kv.Key, out var b))
                    depots.Add(new Depot { x = b.x + b.size * 0.5f, y = b.y + b.size * 0.5f, r = d.radius, left = d.tons });
            }
            Array.Clear(garbage, 0, N);
            double made = 0.0, taken = 0.0;
            var near = new List<KeyValuePair<float, Depot>>();
            foreach (var b in city.buildings.Each())
            {
                double prod = b.HasKind ? ServiceDefs.SPECIAL_TONS * Math.Max(b.size, 1) : City.Capacity(b) * ServiceDefs.TONS_PER_CAP[b.zone];
                if (prod <= 0.0) continue;
                backlog.TryGetValue(b.id, out double old);
                double need = old + prod;
                float bx = b.x + b.size * 0.5f, by = b.y + b.size * 0.5f;
                near.Clear();
                foreach (var dp in depots)
                {
                    float dist = new Vector2(bx - dp.x, by - dp.y).magnitude;
                    if (dist <= dp.r && dp.left > 0.0) near.Add(new KeyValuePair<float, Depot>(dist, dp));
                }
                near.Sort((a, c) => a.Key.CompareTo(c.Key));
                double gotT = 0.0;
                foreach (var e in near)
                {
                    double t = Math.Min(need - gotT, e.Value.left);
                    e.Value.left -= t;
                    gotT += t;
                    if (gotT >= need) break;
                }
                made += prod;
                taken += Math.Min(gotT, prod);
                double left = Math.Min(need - gotT, prod * 10.0);
                if (left > 0.001) backlog[b.id] = left;
                else backlog.Remove(b.id);
                float lvl = (float)Math.Max(0.0, Math.Min(1.0, left / Math.Max(prod * 4.0, 0.05)));
                for (int dy = 0; dy < b.size; dy++)
                    for (int dx = 0; dx < b.size; dx++)
                        garbage[city.Idx(b.x + dx, b.y + dy)] = lvl;
            }
            garbageTons = made;
            garbagePct = made <= 0.0 ? 100.0 : taken / made * 100.0;
        }

        static double Clamp01(double v) => v < 0.0 ? 0.0 : v > 1.0 ? 1.0 : v;

        void CrimeAndHappiness()
        {
            var dens = new float[N];
            foreach (var b in city.buildings.Each())
            {
                if (b.size == 0) continue;
                float c = (float)City.Capacity(b) / (b.size * b.size);
                for (int dy = 0; dy < b.size; dy++)
                    for (int dx = 0; dx < b.size; dx++)
                        dens[city.Idx(b.x + dx, b.y + dy)] = Mathf.Min(c / 140f, 1.5f);
            }
            dens = city.Blur(dens, 2);
            double workers = city.population * 0.55;
            double jobs = city.jobsC + city.jobsI;
            double jobless = workers > 0 ? Clamp01((workers - jobs) / Math.Max(workers, 1.0)) : 0.0;
            double good = CurrentGoodness();
            double goodBias = -good / 100.0 * 0.2;
            double taxPen = Math.Max(city.taxRate - 0.07, 0.0) * 2.5;
            var fx = streetEffects;
            bool inPlay = PowerInPlay();
            Array.Clear(crime, 0, N); Array.Clear(fireRisk, 0, N); Array.Clear(happiness, 0, N);
            double crimeW = 0.0, happyW = 0.0, people = 0.0, resPeople = 0.0;
            foreach (var b in city.buildings.Each())
            {
                if (b.size == 0) continue;
                int i = city.Idx(b.x, b.y);
                double lv = city.landValue[i];
                double dn = Math.Min(dens[i], 1.0);
                double bas = 0.12 + 0.35 * dn + 0.3 * (1.0 - lv) + 0.25 * jobless + goodBias + 0.1 * garbage[i];
                double cr = Clamp01(bas - 0.75 * police[i]);
                if (fx != null) cr *= fx.CrimeMult(b.x, b.y);
                double fr = Clamp01((0.15 + 0.4 * dn + (b.zone == City.IND ? 0.25 : 0.0)) * (1.0 - 0.85 * fire[i]));
                double h = 0.45 + 0.2 * lv + 0.25 * park[i] - 0.35 * cr - 0.25 * garbage[i] - 0.1 * fr - taxPen;
                if (inPlay && !b.powered) h -= 0.35;
                if (fx != null) h += fx.HappinessAdd(b.x, b.y);
                h = Clamp01(h);
                for (int dy = 0; dy < b.size; dy++)
                    for (int dx = 0; dx < b.size; dx++)
                    {
                        int j = city.Idx(b.x + dx, b.y + dy);
                        crime[j] = (float)cr;
                        fireRisk[j] = (float)fr;
                        happiness[j] = (float)h;
                    }
                double cap = City.Capacity(b);
                people += cap;
                crimeW += cr * cap;
                if (b.zone == City.RES)
                {
                    resPeople += cap;
                    happyW += h * cap;
                }
            }
            crimeAvg = people > 0.0 ? crimeW / people : 0.0;
            happinessAvg = resPeople > 0.0 ? happyW / resPeople : 0.5;
            double target = 100.0 * (0.75 * happinessAvg + 0.25 * (0.5 + good / 200.0)) - Math.Max(city.taxRate - 0.09, 0.0) * 300.0;
            approval = Math.Max(0.0, Math.Min(100.0, approval + (target - approval) * 0.3));
            // Income per resident ($ / year): richer homes and more jobs mean a richer city.
            if (city.population > 0)
            {
                double lvSum = 0.0;
                foreach (var b in city.buildings.Each())
                    if (b.zone == City.RES) lvSum += city.landValue[city.Idx(b.x, b.y)] * City.Capacity(b);
                double emp = Clamp01(jobs / Math.Max(workers, 1.0));
                incomePerResident = 22000.0 + 55000.0 * (lvSum / city.population) * emp;
            }
            else incomePerResident = 0.0;
        }

        /// <summary>City charges catalog buildings' upkeep; power lines are services' own.</summary>
        void Upkeep()
        {
            double u = 0.0;
            for (int i = 0; i < N; i++) u += powerLine[i] * ServiceDefs.POWER_LINE_UPKEEP;
            city.funds -= u;
            city.lastExpense += u;
            lastUpkeep = u;
        }

        /// <summary>Buildings without power, or whose people are miserable, slowly empty out.</summary>
        void Decay()
        {
            bool inPlay = PowerInPlay();
            var drop = new List<Building>();
            int dark = 0;
            foreach (var b in city.buildings.Each())
            {
                if (b.HasKind || b.zone == City.NONE) continue;
                int id = b.id;
                if (inPlay && !b.powered)
                {
                    unpoweredDays.TryGetValue(id, out int ud);
                    unpoweredDays[id] = ud + 1;
                    dark++;
                }
                else unpoweredDays.Remove(id);
                if (b.zone == City.RES && happiness[city.Idx(b.x, b.y)] < UNHAPPY)
                {
                    unhappyDays.TryGetValue(id, out int hd);
                    unhappyDays[id] = hd + 1;
                }
                else unhappyDays.Remove(id);
                unpoweredDays.TryGetValue(id, out int u2);
                unhappyDays.TryGetValue(id, out int h2);
                if (u2 >= DECAY_DAYS || h2 >= DECAY_DAYS) drop.Add(b);
            }
            if (dark > 0 && city.GameDay() % 3 == 0)
                city.Say($"{dark} buildings have no power. Build a power plant or more capacity.");
            for (int i = drop.Count - 1; i > 0; i--)
            {
                int j = _shuffle.Next(i + 1);
                (drop[i], drop[j]) = (drop[j], drop[i]);
            }
            for (int k = 0; k < Math.Min(drop.Count, MAX_DECAY_PER_DAY); k++)
            {
                var b = drop[k];
                city.RemoveBuilding(b.id);
                if (b.size == 1 && b.stage > 1)
                    city.AddBuilding(b.x, b.y, 1, b.zone, b.stage - 1, b.rot, false);
            }
        }

        // -------------------------------------------------------------------- demo ---

        static readonly (string kind, int dx, int dy)[] DemoWant =
        {
            ("coal_plant", -26, -22), ("coal_plant", -26, 20), ("coal_plant", 26, -22), ("coal_plant", 26, 20),
            ("gas_plant", -28, 0), ("gas_plant", 28, 0),
            ("garbage_depot", -24, -10), ("garbage_depot", -20, 0), ("garbage_depot", 20, 0),
            ("garbage_depot", 0, -20), ("garbage_depot", 0, 20),
            ("police_station", -12, -10), ("police_station", 12, 10), ("police_station", -12, 12),
            ("police_station", 12, -12), ("police_station", 0, 0),
            ("fire_station", -16, 4), ("fire_station", 16, -4), ("fire_station", 0, -14), ("fire_station", 2, 15),
            ("small_park", -5, -5), ("small_park", 5, 5), ("small_park", -8, 8),
            ("small_park", 8, -8), ("small_park", -18, -12), ("small_park", 18, 12),
        };

        /// <summary>Gives the pre-built demo city enough services to run: plants, depots, police, fire and
        /// parks on free land near the edges of its districts, free of charge and whatever is unlocked.</summary>
        public void BuildDemoServices()
        {
            var c = city.CenterCell();
            foreach (var w in DemoWant)
            {
                var spot = FreeSpotNear(w.kind, c + new Vector2Int(w.dx, w.dy));
                if (spot.x >= 0)
                {
                    TakeLot(w.kind, spot);
                    PlaceFacility(w.kind, spot, true);
                }
            }
            Update();
        }

        /// <summary>Nearest top-left cell where the footprint is land with no road (buildings are bulldozed).</summary>
        Vector2Int FreeSpotNear(string kind, Vector2Int at)
        {
            int s = Catalog.GetDef(kind).size;
            for (int r = 0; r < 8; r++)
                for (int y = at.y - r; y <= at.y + r; y++)
                    for (int x = at.x - r; x <= at.x + r; x++)
                    {
                        if (Math.Max(Math.Abs(x - at.x), Math.Abs(y - at.y)) != r) continue;
                        bool ok = true;
                        for (int dy = 0; dy < s; dy++)
                            for (int dx = 0; dx < s; dx++)
                            {
                                int cx = x + dx, cy = y + dy;
                                if (!city.Inside(cx, cy)) { ok = false; continue; }
                                int i = city.Idx(cx, cy);
                                if (city.land[i] == 0 || city.road[i] == 1 || (city.bld[i] >= 0 && city.buildings[city.bld[i]].HasKind))
                                    ok = false;
                            }
                        if (ok && city.RoadAccessDir(x, y) >= 0) return new Vector2Int(x, y);
                    }
            return new Vector2Int(-1, -1);
        }

        void TakeLot(string kind, Vector2Int at)
        {
            int s = Catalog.GetDef(kind).size;
            for (int dy = 0; dy < s; dy++)
                for (int dx = 0; dx < s; dx++)
                {
                    int bid = city.bld[city.Idx(at.x + dx, at.y + dy)];
                    if (bid >= 0) city.RemoveBuilding(bid);
                }
        }
    }
}
