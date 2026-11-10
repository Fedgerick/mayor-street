// Port of planet/planet_sky.gd. msp: one sun for the whole ball. The game clock is the time
// at the starter town; east of it the day is further on (LocalHour), so street level anywhere
// looks like the flat game at its own hour. From orbit the real sun lights the ball, so its day
// and night sides sweep round with the clock, and the stars turn with the sun. Adds the
// atmosphere shell and the cloud layer, and swaps to the starry space sky high up.
// Feed DayNight.UpdateTime() LocalHour() of the view, then call Follow() each frame.
using UnityEngine;

namespace MSP
{
    public class PlanetSky : MonoBehaviour
    {
        public const float SUN_TILT = -0.2f;
        public const float SPACE_AMBIENT = 0.22f;
        public const float CLOUD_HEIGHT = 70f;
        public const float CLOUD_DRIFT = 0.35f;
        public const float STORM_DEG_PER_HOUR = 12f;

        public DayNight dayNight;
        public IPlanetWeather weather;  // weather/ Weather once ported; null: clear skies
        Material _atmo, _cloudMat;
        GameObject _clouds;

        /// <summary>What the cloud layer needs from Weather (weather/weather.gd).</summary>
        public interface IPlanetWeather
        {
            float Minutes { get; }
            float Cloud { get; }
            float Rain { get; }
            bool RainScheduledAt(float minutes);
        }

        public void Setup(DayNight dn)
        {
            dayNight = dn;
            _atmo = new Material(Resources.Load<Shader>("Shaders/MSPAtmosphere"));
            var shell = MeshUtil.Sphere(Planet.R * 1.07f, 96, 48);
            var a = MeshUtil.Show(transform, "Atmosphere", shell, _atmo);
            a.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            _cloudMat = new Material(Resources.Load<Shader>("Shaders/MSPClouds"));
            var cs = MeshUtil.Sphere(Planet.R + CLOUD_HEIGHT, 96, 48);
            _clouds = MeshUtil.Show(transform, "Clouds", cs, _cloudMat);
            _clouds.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            _clouds.SetActive(false);
        }

        /// <summary>Longitude of the starter town (the clock's own meridian): halfway round the map.</summary>
        public static float TownLon() => Planet.LonOf(new Vector3(Planet.Circumference() * 0.5f, 0f, Planet.V0));

        static float Wrapf(float v, float lo, float hi) => lo + G.Fposmod(v - lo, hi - lo);

        /// <summary>The hour at a (Godot-space) world point when the clock says `clock` at the town.</summary>
        public static float LocalHour(float clock, Vector3 where)
        {
            float lon = Mathf.Atan2(where.x, where.z);
            return G.Fposmod(clock + Wrapf(lon - TownLon(), -Mathf.PI, Mathf.PI) * 24f / G.TAU, 24f);
        }

        /// <summary>World direction toward the sun at clock time `clock`.</summary>
        public static Vector3 SunWorld(float clock) => Planet.DirAt(SUN_TILT, TownLon() - (clock - 12f) / 24f * G.TAU);

        /// <summary>where: the Godot-space world point the view is about; eye: the camera (Godot space).</summary>
        public void Follow(Vector3 where, Vector3 eye, float clock = 12f)
        {
            var q = Planet.FrameWorld(where);
            float alt = eye.magnitude - Planet.R;
            float space = G.Smoothstep(350f, 900f, alt);
            var sky = dayNight.skyMat;
            GBasis skyRot; // sky space -> world (Godot), as Godot's env.sky_rotation
            if (space > 0.5f)
            {
                Vector3 sun = SunWorld(clock);
                dayNight.lightBasis = GBasis.LookingAt(-sun, Mathf.Abs(sun.y) < 0.99f ? Vector3.up : Vector3.right);
                dayNight.light.color = new Color(1f, 0.97f, 0.92f);
                dayNight.light.intensity = 1.25f;
                dayNight.light.enabled = true;
                skyRot = GBasis.Rotation(Vector3.up, -(clock - 12f) / 24f * G.TAU);
                RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Flat;
                RenderSettings.ambientLight = new Color(0.35f, 0.38f, 0.45f) * SPACE_AMBIENT;
                sky.SetVector("_SunDirSky", skyRot.Inverse() * dayNight.lightBasis.z);
            }
            else
            {
                dayNight.lightBasis = q * dayNight.lightBasis;
                skyRot = q;
                RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Trilight;
            }
            dayNight.ApplyLight();
            sky.SetFloat("_Space", space > 0.5f ? 1f : 0f);
            sky.SetMatrix("_SkyRot", ToMatrix(skyRot.Inverse()));
            Shader.SetGlobalFloat("orbit_view", space > 0.5f ? 1f : 0f);
            RenderSettings.fog = space < 0.5f;
            _atmo.SetFloat("_Strength", G.Smoothstep(250f, 700f, alt));
            _atmo.SetVector("_SunWorldU", G.U(dayNight.lightBasis.z));
            UpdateClouds(alt);
        }

        static Matrix4x4 ToMatrix(GBasis b)
        {
            var m = Matrix4x4.identity;
            m.SetColumn(0, b.x);
            m.SetColumn(1, b.y);
            m.SetColumn(2, b.z);
            return m;
        }

        void UpdateClouds(float alt)
        {
            float k = G.Smoothstep(500f, 950f, alt);
            _clouds.SetActive(k > 0f);
            if (k <= 0f) return;
            var w = weather;
            float minutes = w != null ? w.Minutes : 720f;
            _cloudMat.SetFloat("_Strength", k);
            _cloudMat.SetVector("_SunWorld", dayNight.lightBasis.z);
            _cloudMat.SetFloat("_Drift", -minutes / 1440f * CLOUD_DRIFT);
            _cloudMat.SetFloat("_Cover", 0.3f + 0.25f * (w != null ? w.Cloud : 0f));
            float lon = TownLon();
            float power = 0f;
            if (w != null)
            {
                power = Mathf.Max(w.Rain, 0f);
                if (power < 0.3f)
                {
                    float next = (Mathf.Floor(minutes / 360f) + 1f) * 360f;
                    if (w.RainScheduledAt(next))
                    {
                        float hours = (next - minutes) / 60f;
                        lon -= Mathf.Deg2Rad * (hours * STORM_DEG_PER_HOUR);
                        power = Mathf.Max(power, 1f - hours / 6f * 0.6f);
                    }
                }
            }
            Vector3 at = Planet.DirAt(0f, lon);
            _cloudMat.SetVector("_Storm", new Vector4(at.x, at.y, at.z, power));
        }
    }
}
