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
// Keys: Space pause, comma and full stop slower and faster, N skip 10 game minutes,
// O overlays (zones, traffic, land value), [ and ] an hour back or on.
using System.Collections;
using UnityEngine;

namespace MSP
{
    public class Main : MonoBehaviour
    {
        public const int PLANET_COLS = 192;
        public const int PLANET_ROWS = 36;
        static readonly float[] SPEED_VALUES = { 0f, 1f, 3f, 10f };
        static readonly float[] PLANET_MAYOR_DETAIL = { 400f, 600f, 1000f };

        public City city;
        public CityView view;
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
            city.construction = true;  // from here on, what is built goes up over time
            view.RebuildAll();
            if (Args.Has("screenshot"))
            {
                cam.inputEnabled = false;
                speedIndex = 0;
                StartCoroutine(Screenshot(Args.Get("screenshot")));
            }
        }

        void Update()
        {
            if (Input.GetKeyDown(KeyCode.Space)) speedIndex = speedIndex == 0 ? 1 : 0;
            if (Input.GetKeyDown(KeyCode.Comma)) speedIndex = Mathf.Max(speedIndex - 1, 0);
            if (Input.GetKeyDown(KeyCode.Period)) speedIndex = Mathf.Min(speedIndex + 1, 3);
            if (Input.GetKeyDown(KeyCode.N)) city.Advance(10.0, 1.0);
            if (Input.GetKeyDown(KeyCode.O)) SetOverlay((overlay + 1) % 4);
            if (Input.GetKeyDown(KeyCode.LeftBracket)) city.minutes = System.Math.Max(city.minutes - 60.0, 0.0);
            if (Input.GetKeyDown(KeyCode.RightBracket)) city.minutes += 60.0;
            int hourBefore = (int)(city.minutes / 60.0);
            city.Advance(Time.deltaTime, SPEED_VALUES[speedIndex]);
            if ((int)(city.minutes / 60.0) != hourBefore) view.MarkMapDirty();
        }

        void SetOverlay(int o)
        {
            overlay = o;
            Shader.SetGlobalFloat("overlay_mode", o);
        }

        void LateUpdate()
        {
            // as main.gd _follow_planet_sky: the sky follows the mayor focus round the ball
            Vector3 where = Planet.Warp(cam.focus);
            float clock = (float)city.TimeOfDay();
            dayNight.UpdateTime(PlanetSky.LocalHour(clock, where), city.GameDay());
            planetSky.Follow(where, cam.Eye, clock);
        }

        IEnumerator Screenshot(string path)
        {
            for (int i = 0; i < 20; i++) yield return null;
            float t = Time.realtimeSinceStartup;
            for (int i = 0; i < 60; i++) yield return null;
            Debug.Log($"[MSP] frame time {(Time.realtimeSinceStartup - t) / 60f * 1000f:F1} ms over 60 frames");
            yield return new WaitForEndOfFrame();
            ScreenCapture.CaptureScreenshot(path);
            Debug.Log("[MSP] screenshot " + path);
            for (int i = 0; i < 5; i++) yield return null;
            Application.Quit();
        }
    }
}
