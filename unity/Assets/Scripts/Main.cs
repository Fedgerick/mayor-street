// The boot object in Assets/Scenes/Main.unity: builds the whole game in code, as msp's
// scripts/main.gd does.
//
// Milestone 1: msp's city on the planet. The demo city (the same one msp grows, lot for lot),
// or with --starter the empty starter town, drawn by CityView; the city clock runs. Options
// (after the exe name):
//   --starter                        the starter roads instead of the demo city
//   --view=x,z,dist,yawdeg,tiltdeg   camera framing over flat map metres
//   --hour=10.5                      clock (sun position)
//   --quality=0|1|2                  low, medium, high
//   --screenshot=path.png            render, save, quit
//   --nohud                          hide the HUD
//   --overlay=power                  start with a service overlay on
//   --street                         dive to street level at the camera focus right away
//   --drive=3                        (with --street) take the nearest parked car, full throttle 3 s
// Keys: 1-6 tools (inspect, road, R, C, I zones, bulldoze), 7 or B the build menu, Space
// pause, comma and full stop slower and faster, N skip 10 game minutes, O overlays (zones,
// traffic, land value), [ and ] an hour back or on. Left-drag uses the tool. Tab: down to the
// street and back up (WASD walk, Shift sprint, Space jump, mouse look, Esc frees the mouse).
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace MSP
{
    public class Main : MonoBehaviour
    {
        public const int PLANET_COLS = 192;
        public const int PLANET_ROWS = 36;
        static readonly float[] SPEED_VALUES = { 0f, 1f, 3f, 10f };
        static readonly float[] PLANET_MAYOR_DETAIL = { 400f, 600f, 1000f };
        static readonly float[] PLANET_STREET_DETAIL = { 130f, 180f, 400f };  // past ~180 m the curve hides all but tall buildings

        public enum Tool { INSPECT, ROAD, RES, COM, IND, BULLDOZE, BUILD }

        public City city;
        public CityView view;
        public Hud hud;
        public CityServices services;  // power, parks, garbage, police, fire
        public ServicesView servicesView;
        ServicesPanel servicesPanel;
        public StreetMode street;
        int _speedBeforeStreet = 1;
        bool InStreet => street != null && (street.active || street.busy);
        Tool tool = Tool.INSPECT;
        string buildKind = "";
        bool dragging;
        Vector2Int dragStart, hover = new Vector2Int(-1, -1);
        MayorCamera cam;
        DayNight dayNight;
        PlanetSky planetSky;
        int speedIndex = 1;
        int overlay;
        int quality = 1;

        void Awake()
        {
            Application.targetFrameRate = 60;
            Planet.Configure(PLANET_COLS, PLANET_ROWS);  // before the City: it sizes the grid
            Physics.gravity = Vector3.zero; // planet bodies apply their own pull toward the centre
        }

        void Start()
        {
            quality = Mathf.Clamp(Args.GetI("quality", 1), 0, 2);
            var t0 = Time.realtimeSinceStartup;
            city = new City();
            bool demo = !Args.Has("starter");
            if (demo) city.BuildDemo();
            else city.BuildStarter();
            Debug.Log($"[MSP] city: {(demo ? "demo" : "starter")}, {city.buildings.Count} buildings, population {city.population} ({(Time.realtimeSinceStartup - t0) * 1000f:F0} ms)");
            dayNight = new GameObject("DayNight").AddComponent<DayNight>();
            dayNight.transform.SetParent(transform);
            planetSky = new GameObject("PlanetSky").AddComponent<PlanetSky>();
            planetSky.transform.SetParent(transform);
            planetSky.Setup(dayNight);
            view = new GameObject("CityView").AddComponent<CityView>();
            view.transform.SetParent(transform);
            view.Setup(city);
            services = new CityServices(city);  // sets city.growthCheck and adjusts land value itself
            view.services = services;
            services.CoverageChanged += view.MarkMapDirty;  // power changes light or darken windows
            if (demo) services.BuildDemoServices();  // plants, depots, police, fire and parks for the demo
            if (Args.Has("hour")) city.minutes = city.GameDay() * 1440.0 + Args.GetF("hour", 10.5f) * 60.0;
            var camGo = new GameObject("MayorCamera");
            camGo.transform.SetParent(transform);
            cam = camGo.AddComponent<MayorCamera>();
            cam.bounds = new Rect(0, -300, City.W * City.TILE, City.H * City.TILE + 500);
            cam.Moved += dayNight.SetViewDistance;
            dayNight.ApplyQuality(quality, cam.cam);
            view.SetDetailDistance(PLANET_MAYOR_DETAIL[quality]);
            var cc = city.CenterCell();
            var c = city.CellCenter(cc.x, cc.y);
            cam.SetView(c + new Vector3(0, 0, 30), demo ? 260f : 330f, -35f * Mathf.Deg2Rad, 0f);
            if (Args.Has("view"))
            {
                float[] v = { 1182f, 204f, 230f, -35f, 0f };
                string[] parts = Args.Get("view").Split(',');
                for (int i = 0; i < parts.Length && i < v.Length; i++)
                    float.TryParse(parts[i], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v[i]);
                cam.SetView(new Vector3(v[0], 0f, v[1]), v[2], v[3] * Mathf.Deg2Rad, v[4] * Mathf.Deg2Rad);
            }
            Progress.I.Begin(city);
            hud = new GameObject("Hud").AddComponent<Hud>();
            hud.transform.SetParent(transform);
            hud.Setup(city);
            hud.ToolSelected += OnToolButton;
            hud.OverlaySelected += SetOverlay;
            hud.SpeedSelected += SetSpeed;
            hud.QualitySelected += SetQuality;
            hud.BuildingChosen += ChooseBuilding;
            city.Message += t => hud.ShowToast(t);
            Progress.I.Notice += t => hud.ShowToast(t, true);
            servicesView = new GameObject("ServicesView").AddComponent<ServicesView>();
            servicesView.transform.SetParent(transform);
            servicesView.Setup(services);
            servicesPanel = new GameObject("ServicesPanel").AddComponent<ServicesPanel>();
            servicesPanel.transform.SetParent(transform);
            servicesPanel.Setup(hud.root, services);
            servicesPanel.OverlaySelected += OnServiceOverlay;
            street = new GameObject("StreetMode").AddComponent<StreetMode>();
            street.transform.SetParent(transform);
            street.Setup(city, cam.cam, null);
            street.StreetEntered += OnStreetEntered;
            street.StreetExited += OnStreetExited;
            Progress.I.Started();
            SetTool(Tool.INSPECT);
            SetSpeed(1);
            SetOverlay(0);
            hud.SetQuality(quality);
            city.construction = true;  // from here on, what is built goes up over time
            view.RebuildAll();
            if (Args.Has("nohud")) hud.gameObject.SetActive(false);
            if (Args.Has("overlay"))  // a service overlay by name (power, parks, garbage, police, fire, crime, happiness)
            {
                int oi = System.Array.FindIndex(CityServices.OVERLAY_NAMES, n => n.ToLowerInvariant() == Args.Get("overlay").ToLowerInvariant());
                if (oi > 0) { servicesPanel.SetOverlay((CityServices.Overlay)oi); OnServiceOverlay((CityServices.Overlay)oi); }
            }
            if (Args.Has("street")) GoStreet();
            if (Args.Has("screenshot"))
            {
                cam.inputEnabled = false;
                SetSpeed(0);
                StartCoroutine(Screenshot(Args.Get("screenshot")));
            }
        }

        void Update()
        {
            if (hud == null) return;
            if (StreetInput.ToggleViewPressed && !Args.Has("screenshot"))
            {
                if (InStreet) GoMayor();
                else GoStreet();
            }
            if (InStreet)
            {
                city.Advance(Time.deltaTime, SPEED_VALUES[speedIndex]);
                services.Update();
                return;
            }
            if (Input.GetKeyDown(KeyCode.Space)) SetSpeed(speedIndex == 0 ? 1 : 0);
            if (Input.GetKeyDown(KeyCode.Comma)) SetSpeed(Mathf.Max(speedIndex - 1, 0));
            if (Input.GetKeyDown(KeyCode.Period)) SetSpeed(Mathf.Min(speedIndex + 1, 3));
            if (Input.GetKeyDown(KeyCode.N)) city.Advance(10.0, 1.0);
            for (int k = 0; k < 6; k++)
                if (Input.GetKeyDown(KeyCode.Alpha1 + k)) SetTool((Tool)k);
            if (Input.GetKeyDown(KeyCode.Alpha7) || Input.GetKeyDown(KeyCode.B)) hud.ToggleBuildMenu();
            if (Input.GetKeyDown(KeyCode.Escape)) { if (hud.BuildMenuOpen) hud.CloseBuildMenu(); else SetTool(Tool.INSPECT); }
            MouseTools();
            if (Input.GetKeyDown(KeyCode.O)) SetOverlay((overlay + 1) % 4);
            if (Input.GetKeyDown(KeyCode.LeftBracket)) city.minutes = System.Math.Max(city.minutes - 60.0, 0.0);
            if (Input.GetKeyDown(KeyCode.RightBracket)) city.minutes += 60.0;
            int hourBefore = (int)(city.minutes / 60.0);
            city.Advance(Time.deltaTime, SPEED_VALUES[speedIndex]);
            services.Update();
            if ((int)(city.minutes / 60.0) != hourBefore) view.MarkMapDirty();
        }

        // ------------------------------------------------------------ street level ---

        /// <summary>Dive from the mayor view to a character on the sidewalk under the camera focus.</summary>
        void GoStreet()
        {
            if (InStreet) return;
            SetTool(Tool.INSPECT);
            hud.ShowTip(Vector2.zero, "");
            hud.CloseBuildMenu();
            hud.gameObject.SetActive(false);
            // The design keeps the street at 1x; the mayor speed comes back on the way up.
            _speedBeforeStreet = speedIndex;
            SetSpeed(1);
            cam.enabled = false;
            street.EnterStreet(cam.GodotXf, cam.cam.fieldOfView, Planet.Place(cam.focus));
        }

        void GoMayor()
        {
            if (street == null || !street.active || street.busy || !street.CanExit()) return;
            // Frame the mayor view on where the player ended up, looking the same way.
            var f = Planet.Flat(street.FocusPoint());
            var keep = cam.cam.transform.position;
            var keepRot = cam.cam.transform.rotation;
            cam.SetView(new Vector3(f.x, 0f, f.z), 140f, street.ViewYaw());
            cam.cam.transform.SetPositionAndRotation(keep, keepRot);  // the street camera flies there itself
            street.ExitStreet(cam.GodotXf, 45f);
        }

        void OnStreetEntered()
        {
            dayNight.SetViewDistance(30f);
            dayNight.SetStreetView(true);
            view.SetDetailDistance(PLANET_STREET_DETAIL[quality]);
            dayNight.exposureScale = 1.25f;
            dayNight.ambientScale = 1.4f;
        }

        void OnStreetExited()
        {
            cam.enabled = true;
            cam.Apply();
            cam.cam.fieldOfView = 45f;
            dayNight.SetViewDistance(cam.dist);
            dayNight.SetStreetView(false);
            view.SetDetailDistance(PLANET_MAYOR_DETAIL[quality]);
            dayNight.exposureScale = 1f;
            dayNight.ambientScale = 1f;
            if (!Args.Has("nohud")) hud.gameObject.SetActive(true);
            SetSpeed(_speedBeforeStreet);
        }

        void SetOverlay(int o)
        {
            overlay = o;
            hud?.SetOverlay(o);
            Shader.SetGlobalFloat("overlay_mode", o);
            if (o != 0 && servicesPanel != null)  // one overlay at a time: the zone ones or the service ones
            {
                servicesPanel.SetOverlay(CityServices.Overlay.NONE);
                servicesView.SetOverlay(CityServices.Overlay.NONE);
            }
        }

        void OnServiceOverlay(CityServices.Overlay o)
        {
            servicesView.SetOverlay(o);
            if (o != CityServices.Overlay.NONE)
            {
                overlay = 0;
                hud.SetOverlay(0);
                Shader.SetGlobalFloat("overlay_mode", 0);
            }
        }

        void SetSpeed(int i)
        {
            speedIndex = i;
            hud?.SetSpeed(i);
        }

        void SetQuality(int q)
        {
            quality = q;
            hud.SetQuality(q);
            dayNight.ApplyQuality(q, cam.cam);
            view.SetDetailDistance((InStreet ? PLANET_STREET_DETAIL : PLANET_MAYOR_DETAIL)[q]);
            Shader.SetGlobalFloat("gfx_quality", q);
        }

        // -------------------------------------------------------------- tools ---

        void OnToolButton(int t)
        {
            if ((Tool)t == Tool.BUILD)
            {
                hud.SetTool((int)tool);  // the Build button opens the menu; the tool comes from the menu
                hud.ToggleBuildMenu();
            }
            else SetTool((Tool)t);
        }

        void SetTool(Tool t)
        {
            tool = t;
            dragging = false;
            if (tool != Tool.BUILD) buildKind = "";
            hud.CloseBuildMenu();
            hud.SetTool((int)t);
            hud.ShowTip(Vector2.zero, "");
            view.SetPreview(new Vector2Int[0], Color.white);
            Shader.SetGlobalFloat("grid_alpha", tool == Tool.INSPECT ? 0f : 1f);
        }

        void ChooseBuilding(string kind)
        {
            buildKind = kind;
            SetTool(Tool.BUILD);
            UpdatePreview();
        }

        Catalog.Def BuildDef() => Catalog.GetDef(buildKind);

        /// <summary>The footprint's top-left tile, with the cursor near its middle.</summary>
        Vector2Int BuildCell(Vector2Int c)
        {
            int s = BuildDef()?.size ?? 1;
            return s > 1 ? c - new Vector2Int((s - 1) / 2, (s - 1) / 2) : c;
        }

        bool CellAt(Vector2 screen, out Vector2Int c)
        {
            c = default;
            if (!cam.GroundPoint(screen, out Vector3 p)) return false;
            c = city.FlatToCell(p);
            return city.Inside(c.x, c.y);
        }

        int ZoneForTool() => tool == Tool.RES ? City.RES : tool == Tool.COM ? City.COM : tool == Tool.IND ? City.IND : 0;

        void MouseTools()
        {
            if (!cam.inputEnabled) return;
            Vector2 mp = Input.mousePosition;
            bool overUi = Hud.PointerOverUI();
            bool haveCell = CellAt(mp, out var c) && !overUi;
            var cc = haveCell ? c : new Vector2Int(-1, -1);
            if (cc != hover)
            {
                hover = cc;
                UpdatePreview();
            }
            UpdateTip(mp);
            if (Input.GetMouseButtonDown(0) && haveCell)
            {
                if (tool == Tool.INSPECT) Inspect(c);
                else if (tool == Tool.BUILD && BuildDef() != null && BuildDef().placement != "line") PlaceBuilding(c);
                else
                {
                    dragStart = c;
                    dragging = true;
                }
                UpdatePreview();
            }
            else if (Input.GetMouseButtonUp(0) && dragging)
            {
                dragging = false;
                if (haveCell) Apply(dragStart, c);
                UpdatePreview();
            }
            else if (Input.GetMouseButtonDown(1) && dragging)
            {
                dragging = false;
                UpdatePreview();
            }
        }

        void Apply(Vector2Int a, Vector2Int b)
        {
            switch (tool)
            {
                case Tool.ROAD: city.PlaceRoad(city.RoadPath(a, b)); break;
                case Tool.RES: case Tool.COM: case Tool.IND: city.PlaceZone(city.RectCells(a, b), ZoneForTool()); break;
                case Tool.BULLDOZE:
                    city.Bulldoze(city.RectCells(a, b));
                    services.BulldozeLines(city.RectCells(a, b));
                    break;
                case Tool.BUILD: services.PlaceLine(city.RoadPath(a, b)); break;  // power lines, drawn like roads
            }
        }

        List<Vector2Int> PreviewCells()
        {
            var o = new List<Vector2Int>();
            if (hover.x < 0 || tool == Tool.INSPECT) return o;
            var a = dragging ? dragStart : hover;
            var d = BuildDef();
            if (tool == Tool.ROAD || (tool == Tool.BUILD && d != null && d.placement == "line")) return city.RoadPath(a, hover);
            if (tool == Tool.BUILD)
            {
                if (d == null) return o;
                var at = BuildCell(hover);
                for (int y = 0; y < Mathf.Max(d.size, 1); y++)
                    for (int x = 0; x < Mathf.Max(d.size, 1); x++)
                        if (city.Inside(at.x + x, at.y + y)) o.Add(at + new Vector2Int(x, y));
                return o;
            }
            var r = city.RectCells(a, hover);
            for (int y = r.yMin; y < r.yMax; y++)
                for (int x = r.xMin; x < r.xMax; x++) o.Add(new Vector2Int(x, y));
            return o;
        }

        void UpdatePreview()
        {
            var col = new Color(0.4f, 0.8f, 1f);
            switch (tool)
            {
                case Tool.RES: col = new Color(0.3f, 1f, 0.45f); break;
                case Tool.COM: col = new Color(0.35f, 0.65f, 1f); break;
                case Tool.IND: col = new Color(1f, 0.75f, 0.2f); break;
                case Tool.BULLDOZE: col = new Color(1f, 0.3f, 0.25f); break;
                case Tool.BUILD:
                    var d = BuildDef();
                    bool ok = d == null || d.placement == "line" || hover.x < 0 || city.CanPlaceSpecial(buildKind, BuildCell(hover)) == "";
                    col = ok ? new Color(0.35f, 1f, 0.5f) : new Color(1f, 0.3f, 0.25f);
                    break;
            }
            view.SetPreview(PreviewCells(), col);
        }

        void UpdateTip(Vector2 pos)
        {
            if (hover.x < 0 || tool == Tool.INSPECT)
            {
                hud.ShowTip(pos, "");
                return;
            }
            var a = dragging ? dragStart : hover;
            int cost = 0;
            switch (tool)
            {
                case Tool.ROAD: cost = city.RoadCost(city.RoadPath(a, hover)); break;
                case Tool.RES: case Tool.COM: case Tool.IND: cost = city.ZoneCost(city.RectCells(a, hover), ZoneForTool()); break;
                case Tool.BULLDOZE: cost = city.BulldozeCost(city.RectCells(a, hover)); break;
                case Tool.BUILD:
                    var d = BuildDef();
                    if (d == null) break;
                    string text = d.name;
                    if (d.placement == "line")
                    {
                        cost = services.LineCost(city.RoadPath(a, hover));
                        if (cost > 0) text += "\n$" + cost;
                    }
                    else
                    {
                        string why = city.CanPlaceSpecial(buildKind, BuildCell(hover));
                        text += "\n" + (why != "" ? why : "$" + Catalog.Thousands(d.cost));
                    }
                    hud.ShowTip(pos, text);
                    return;
            }
            hud.ShowTip(pos, cost > 0 ? "$" + cost : "");
        }

        void PlaceBuilding(Vector2Int c)
        {
            int id = city.PlaceSpecial(buildKind, BuildCell(c));
            if (id >= 0 && BuildDef().unique) SetTool(Tool.INSPECT);  // only one of these; put the tool down
        }

        void Inspect(Vector2Int c)
        {
            int i = city.Idx(c.x, c.y);
            string t = $"Tile {c.x}, {c.y}\nLand value {(int)(city.landValue[i] * 100f)}%";
            if (city.road[i] == 1)
            {
                t = $"Road\nTraffic {(int)(city.traffic[i] * 100f)}%";
                foreach (int pid in city.PropsAt(i)) t += "\n" + city.buildings[pid].name;
            }
            else if (city.bld[i] >= 0 && city.buildings[city.bld[i]].HasKind)
            {
                var b = city.buildings[city.bld[i]];
                var d = Catalog.GetDef(b.kind);
                int up = (int)d.upkeep;
                t = $"{b.name}\n" + (up > 0 ? $"Costs ${up} a day" : up < 0 ? $"Earns ${-up} a day" : "");
                if (d.desc != "") t += "\n" + d.desc;
            }
            else if (city.bld[i] >= 0)
            {
                var b = city.buildings[city.bld[i]];
                string what = b.zone == City.RES ? "residents" : "jobs";
                t = $"{City.ZONE_NAMES[b.zone]}, stage {b.stage}\n{City.Capacity(b)} {what}\nLand value {(int)(city.landValue[i] * 100f)}%" +
                    (b.connected ? "" : "\nNo route to jobs/workers!");
            }
            else if (city.siteAt[i] >= 0)
            {
                var sb = city.sites[city.siteAt[i]];
                double left = (1.0 - sb.built) * sb.dur / 60.0;
                t = $"{sb.name ?? $"{City.ZONE_NAMES[sb.zone]}, stage {sb.stage}"}\nUnder construction, {(int)(sb.built * 100.0)}% built\nAbout {(int)System.Math.Ceiling(left)} hours to go";
            }
            else if (city.zone[i] != 0)
                t += $"\n{City.ZONE_NAMES[city.zone[i]]} zone, " + (city.RoadAccessDir(c.x, c.y) >= 0 ? "waiting to grow" : "needs a road within 2 tiles");
            else if (city.land[i] == 0) t = "Shoreline (can't build)";
            hud.info.text = t;
        }

        void LateUpdate()
        {
            // as main.gd _follow_planet_sky: the sky follows the mayor focus round the ball
            Vector3 where = Planet.Warp(cam.focus);
            Vector3 eye = cam.Eye;
            if (InStreet)
            {
                where = street.FocusPoint();
                eye = G.FromU(cam.cam.transform.position);
            }
            float clock = (float)city.TimeOfDay();
            dayNight.UpdateTime(PlanetSky.LocalHour(clock, where), city.GameDay());
            planetSky.Follow(where, eye, clock);
        }

        IEnumerator Screenshot(string path)
        {
            for (int i = 0; i < 20; i++) yield return null;
            if (Args.Has("street"))
            {
                while (!street.active) yield return null;   // the dive takes a few seconds
                SetSpeed(0);
                if (Args.Has("drive"))
                {
                    for (int i = 0; i < 30; i++) yield return null;   // parked cars settle on their springs
                    bool got = street.TakeNearestCar();
                    Debug.Log("[MSP] --drive: " + (got ? street.car.model : "no car near"));
                    StreetInput.autoThrottle = 1f;
                    yield return new WaitForSeconds(Args.GetF("drive", 3f));
                    StreetInput.autoThrottle = 0f;
                    if (got) Debug.Log($"[MSP] --drive: {street.car.Speed() * 3.6f:F0} km/h, in contact {street.car.InContact()}");
                }
                for (int i = 0; i < 30; i++) yield return null;
            }
            float t = Time.realtimeSinceStartup;
            for (int i = 0; i < 60; i++) yield return null;
            Debug.Log($"[MSP] frame time {(Time.realtimeSinceStartup - t) / 60f * 1000f:F1} ms over 60 frames");
            if (Args.Has("debug")) Debug.Log("[MSP] view " + view.DebugStats());
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(path);
            Debug.Log("[MSP] screenshot " + path);
            for (int i = 0; i < 5; i++) yield return null;
            Application.Quit();
        }
    }
}
