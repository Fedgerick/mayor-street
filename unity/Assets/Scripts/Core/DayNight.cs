// Port of scripts/day_night.gd: sun, moon, sky, fog and post-processing, driven by the city
// clock and the graphics level. Directions are Godot space (see GMath.cs); the light's basis
// is kept in Godot space (lightBasis, -Z = the way the light shines) and written to the
// Unity light at the edge. PlanetSky turns it to the local frame of the view each frame.
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace MSP
{
    public class DayNight : MonoBehaviour
    {
        public const float SUNRISE = 6f, SUNSET = 19f, SUN_MAX_ELEV = 55f, SUN_NOON_BEARING = 125f, SUN_SWEEP = 110f;

        // Sun elevation (degrees) -> sunlight colour, energy
        static readonly float[] SUN_E = { -4.5f, 0f, 4f, 10f, 20f, 35f, 60f };
        static readonly Color[] SUN_C =
        {
            new Color(1f, 0.32f, 0.1f), new Color(1f, 0.4f, 0.16f), new Color(1f, 0.52f, 0.27f), new Color(1f, 0.68f, 0.45f),
            new Color(1f, 0.82f, 0.64f), new Color(1f, 0.9f, 0.77f), new Color(1f, 0.93f, 0.84f),
        };
        static readonly float[] SUN_N = { 0f, 0.45f, 1.2f, 1.9f, 2.4f, 2.7f, 2.8f };

        // Sun elevation -> zenith, horizon, dusk tint, ambient energy, exposure
        static readonly float[] SKY_E = { -20f, -9f, -4f, 0f, 5f, 14f, 30f, 60f };
        static readonly Color[] SKY_Z =
        {
            new Color(0.006f, 0.009f, 0.022f), new Color(0.009f, 0.015f, 0.038f), new Color(0.02f, 0.035f, 0.1f), new Color(0.05f, 0.09f, 0.22f),
            new Color(0.08f, 0.17f, 0.4f), new Color(0.08f, 0.24f, 0.6f), new Color(0.07f, 0.27f, 0.72f), new Color(0.06f, 0.26f, 0.74f),
        };
        static readonly Color[] SKY_H =
        {
            new Color(0.022f, 0.026f, 0.045f), new Color(0.04f, 0.043f, 0.08f), new Color(0.15f, 0.11f, 0.16f), new Color(0.48f, 0.34f, 0.3f),
            new Color(0.7f, 0.58f, 0.5f), new Color(0.6f, 0.68f, 0.8f), new Color(0.5f, 0.68f, 0.9f), new Color(0.48f, 0.67f, 0.9f),
        };
        static readonly Color[] SKY_D =
        {
            new Color(0.05f, 0.04f, 0.07f), new Color(0.12f, 0.07f, 0.11f), new Color(0.55f, 0.2f, 0.14f), new Color(1f, 0.4f, 0.15f),
            new Color(1f, 0.52f, 0.24f), new Color(1f, 0.72f, 0.48f), new Color(1f, 0.84f, 0.68f), new Color(1f, 0.86f, 0.72f),
        };
        static readonly float[] SKY_A = { 1.8f, 1.8f, 1.6f, 1.3f, 1.1f, 1f, 1f, 1f };
        static readonly float[] SKY_X = { 1.55f, 1.45f, 1.1f, 0.85f, 0.68f, 0.6f, 0.56f, 0.55f };

        static readonly Color MOON_COLOR = new Color(0.62f, 0.7f, 0.95f);
        const float MOON_ENERGY = 0.16f;

        public Light light;
        public GBasis lightBasis = GBasis.Identity;  // Godot space, in the flat local frame until PlanetSky turns it
        public Material skyMat;
        public Volume volume;
        public int quality = 1;
        public bool streetView;
        public float exposureScale = 1f, ambientScale = 1f;
        public IWeather weather;  // cloud, rain, fog 0..1; null keeps the day-to-day cloud cover

        // the current sky colours, for PlanetSky and ambient
        public Color zenith, horizon, dusk, ground;
        public float ambientEnergy = 1f;
        public Vector3 sunLocal = Vector3.up;  // toward the sun in the local frame (sky space)
        public Vector3 moonLocal = Vector3.up;

        Tonemapping _tone;
        Bloom _bloom;
        ColorAdjustments _adjust;
        Vignette _vignette;
        ColorLookup _lut;
        float _glowNight = 0.22f;
        float _fogBase = 0.0003f;
        float _exposure = 0.6f;

        public interface IWeather { float Cloud { get; } float Fog { get; } float Rain { get; } }

        void Awake()
        {
            skyMat = new Material(Resources.Load<Shader>("Shaders/MSPSky"));
            RenderSettings.skybox = skyMat;
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.fog = true;
            RenderSettings.fogMode = FogMode.Exponential;

            var lgo = new GameObject("Sun");
            lgo.transform.SetParent(transform, false);
            light = lgo.AddComponent<Light>();
            light.type = LightType.Directional;
            light.shadows = LightShadows.Soft;
            light.shadowBias = 0.04f;
            light.shadowNormalBias = 0.6f;
            RenderSettings.sun = light;

            var vgo = new GameObject("PostVolume");
            vgo.transform.SetParent(transform, false);
            volume = vgo.AddComponent<Volume>();
            volume.isGlobal = true;
            var profile = ScriptableObject.CreateInstance<VolumeProfile>();
            volume.sharedProfile = profile;
            _tone = profile.Add<Tonemapping>(true);
            _tone.mode.Override(TonemappingMode.ACES);
            _bloom = profile.Add<Bloom>(true);
            _bloom.threshold.Override(0.95f);
            _bloom.scatter.Override(0.65f);
            _adjust = profile.Add<ColorAdjustments>(true);
            _vignette = profile.Add<Vignette>(true);
            _vignette.intensity.Override(0.28f);
            _vignette.smoothness.Override(0.5f);
            _lut = profile.Add<ColorLookup>(true);
            _lut.texture.Override(MakeGradeLut());
            _lut.contribution.Override(1f);
        }

        // --------------------------------------------------------------- clock ---

        static float Smooth(float t) => t * t * (3f - 2f * t);

        static int Key(float[] keys, float x, out float t)
        {
            t = 0f;
            if (x <= keys[0]) return 0;
            for (int k = 0; k < keys.Length - 1; k++)
                if (x <= keys[k + 1])
                {
                    t = Smooth((x - keys[k]) / (keys[k + 1] - keys[k]));
                    return k;
                }
            t = 1f;
            return keys.Length - 2;
        }

        static float KF(float[] v, int k, float t) => Mathf.Lerp(v[k], v[Mathf.Min(k + 1, v.Length - 1)], t);
        static Color KC(Color[] v, int k, float t) => Color.Lerp(v[k], v[Mathf.Min(k + 1, v.Length - 1)], t);

        /// <summary>Unit vector toward the sun in the flat local frame; below the horizon at night.</summary>
        public static Vector3 SunPosition(float hour)
        {
            float t = (hour - SUNRISE) / (SUNSET - SUNRISE);
            if (t > 1.5f) t -= 24f / (SUNSET - SUNRISE);
            float elev = Mathf.Deg2Rad * (SUN_MAX_ELEV * Mathf.Sin(t * Mathf.PI));
            float bearing = Mathf.Deg2Rad * (SUN_NOON_BEARING + (t - 0.5f) * 2f * SUN_SWEEP);
            return new Vector3(Mathf.Sin(bearing) * Mathf.Cos(elev), Mathf.Sin(elev), -Mathf.Cos(bearing) * Mathf.Cos(elev));
        }

        static float Lum(Color c) => 0.2126f * c.r + 0.7152f * c.g + 0.0722f * c.b;

        public void UpdateTime(float hour, int day = 0)
        {
            Vector3 sun = SunPosition(hour);
            float elev = Mathf.Rad2Deg * Mathf.Asin(sun.y);
            int ks = Key(SUN_E, elev, out float ts);
            int kk = Key(SKY_E, elev, out float tk);
            Color sunCol = KC(SUN_C, ks, ts);
            float sunEnergy = KF(SUN_N, ks, ts);
            float night = 1f - G.Smoothstep(-5f, 9f, elev);
            float cloud = 0f, fog = 0f, rain = 0f;
            if (weather != null)
            {
                cloud = Mathf.Clamp01(weather.Cloud);
                fog = Mathf.Clamp01(weather.Fog);
                rain = Mathf.Clamp01(weather.Rain);
            }
            float overcast = G.Smoothstep(0.1f, 0.9f, Mathf.Max(cloud, fog * 0.8f));
            sunEnergy *= 1f - 0.62f * overcast;
            float moonK = G.Smoothstep(-4.5f, -10f, elev);
            Vector3 moon = new Vector3(-sun.x, 0f, -sun.z);
            moon = moon.magnitude > 0.01f
                ? moon.normalized * Mathf.Cos(38f * Mathf.Deg2Rad) + Vector3.up * Mathf.Sin(38f * Mathf.Deg2Rad)
                : Vector3.up;
            Vector3 toLight;
            if (sunEnergy > 0f)
            {
                Vector3 flat = new Vector3(sun.x, 0f, sun.z).normalized;
                float e = Mathf.Deg2Rad * Mathf.Max(elev, 4f);
                toLight = flat * Mathf.Cos(e) + Vector3.up * Mathf.Sin(e);
                light.color = Color.Lerp(sunCol, new Color(0.9f, 0.93f, 1f), overcast * 0.6f);
                light.intensity = sunEnergy;
            }
            else
            {
                toLight = moon;
                light.color = MOON_COLOR;
                light.intensity = MOON_ENERGY * moonK;
            }
            light.enabled = light.intensity > 0.001f;
            light.shadowStrength = 1f - 0.6f * overcast;
            lightBasis = GBasis.LookingAt(-toLight, Vector3.up);
            sunLocal = sun;
            moonLocal = moon;

            zenith = KC(SKY_Z, kk, tk);
            horizon = KC(SKY_H, kk, tk);
            dusk = KC(SKY_D, kk, tk);
            float ambK = KF(SKY_A, kk, tk);
            _exposure = KF(SKY_X, kk, tk);
            if (overcast > 0f)
            {
                float dim = 1f - 0.25f * rain;
                zenith = Color.Lerp(zenith, Color.white * (Lum(zenith) * 1.15f * dim), overcast * 0.8f);
                horizon = Color.Lerp(horizon, Color.white * (Lum(horizon) * dim), overcast * 0.75f);
                dusk = Color.Lerp(dusk, horizon, overcast * 0.7f);
            }
            float sunset = Mathf.Clamp01(1f - Mathf.Abs(elev - 1f) / 13f);
            sunset = Smooth(sunset);
            ground = Color.Lerp(horizon, new Color(0.36f, 0.35f, 0.32f), 0.5f) * (0.35f + 0.1f * sunEnergy);
            skyMat.SetColor("_Zenith", zenith);
            skyMat.SetColor("_Horizon", horizon);
            skyMat.SetColor("_Dusk", dusk);
            skyMat.SetColor("_Ground", ground);
            Color sl = sunCol * sunEnergy * 0.55f;
            skyMat.SetVector("_SunLight", new Vector3(sl.r, sl.g, sl.b));
            skyMat.SetVector("_SunDirSky", sun);
            skyMat.SetVector("_MoonDirSky", moon);
            skyMat.SetFloat("_Sunset", sunset);
            skyMat.SetFloat("_Night", night);
            skyMat.SetFloat("_Pollution", night);
            float cover = Mathf.Lerp(CloudCover(day), CloudCover(day + 1), hour / 24f);
            skyMat.SetFloat("_CloudCover", Mathf.Lerp(cover, 0.95f, overcast));

            ambientEnergy = ambK * ambientScale * (1f + 0.3f * overcast);
            float grey = Lum(horizon) * 0.6f + Lum(zenith) * 0.4f;
            Color amb = new Color(grey * 1.1f, grey, grey * 0.85f);
            // msp mixes 45% sky into a neutral ambient (light bounced off the sunlit city)
            RenderSettings.ambientSkyColor = Color.Lerp(amb, zenith, 0.45f) * ambientEnergy;
            RenderSettings.ambientEquatorColor = Color.Lerp(amb, horizon, 0.45f) * ambientEnergy;
            RenderSettings.ambientGroundColor = Color.Lerp(amb, ground, 0.45f) * ambientEnergy * 0.7f;
            float glow = quality >= 1 ? Mathf.Lerp(0.05f, _glowNight, night) : 0f;
            _bloom.active = quality >= 1;
            _bloom.intensity.Override(glow * 4f);
            _adjust.postExposure.Override(Mathf.Log(_exposure / (1f - glow) * exposureScale, 2f));
            RenderSettings.fogColor = Color.Lerp(horizon, dusk, sunset * 0.35f);
            RenderSettings.fogDensity = _fogBase * (1f + 9f * fog + 1.5f * rain);

            Shader.SetGlobalFloat("night", night);
            float lit = 0.12f;
            if (hour >= 17f && hour < 23f) lit = Mathf.Lerp(0.25f, 0.42f, G.Smoothstep(17f, 20f, hour));
            else if (hour >= 23f || hour < 5f) lit = 0.22f;
            else if (hour >= 5f && hour < 8f) lit = Mathf.Lerp(0.5f, 0.15f, G.Smoothstep(5f, 8f, hour));
            Shader.SetGlobalFloat("window_lit", lit);
        }

        static float CloudCover(int day)
        {
            float h = G.Fposmod(Mathf.Sin(day * 12.9898f) * 43758.5453f, 1f);
            return Mathf.Lerp(0.3f, 0.52f, h);
        }

        /// <summary>Writes lightBasis (Godot space) to the Unity light.</summary>
        public void ApplyLight()
        {
            light.transform.rotation = G.CameraRot(lightBasis);
            Shader.SetGlobalVector("sun_dir", G.U(lightBasis.z));
        }

        public void SetStreetView(bool on)
        {
            streetView = on;
            ApplyShadowMode();
        }

        void ApplyShadowMode()
        {
            if (GraphicsSettings.defaultRenderPipeline is UniversalRenderPipelineAsset a)
            {
                bool one = quality == 0 || (quality == 1 && streetView);
                a.shadowCascadeCount = one ? 1 : (quality == 1 ? 2 : 4);
            }
        }

        public void SetViewDistance(float dist)
        {
            if (GraphicsSettings.defaultRenderPipeline is UniversalRenderPipelineAsset a)
                a.shadowDistance = Mathf.Clamp(dist * 2.4f, 140f, new[] { 450f, 800f, 1300f }[Mathf.Clamp(quality, 0, 2)]);
            _fogBase = Mathf.Clamp(0.11f / (dist + 300f), 0.0001f, 0.00045f);
            RenderSettings.fogDensity = _fogBase;
        }

        // ------------------------------------------------------------- grading ---

        /// <summary>The final colour grade as a 32^3 LUT strip (1024 x 32) for URP's ColorLookup.</summary>
        static Texture2D MakeGradeLut()
        {
            const int N = 32;
            var tex = new Texture2D(N * N, N, TextureFormat.RGBA32, false, true)
            {
                wrapMode = TextureWrapMode.Clamp,
                filterMode = FilterMode.Bilinear,
            };
            var px = new Color32[N * N * N];
            for (int b = 0; b < N; b++)
                for (int g = 0; g < N; g++)
                    for (int r = 0; r < N; r++)
                    {
                        Vector3 c = Grade(new Vector3(r, g, b) / (N - 1));
                        px[g * N * N + b * N + r] = new Color32(
                            (byte)Mathf.Clamp(Mathf.RoundToInt(c.x * 255f), 0, 255),
                            (byte)Mathf.Clamp(Mathf.RoundToInt(c.y * 255f), 0, 255),
                            (byte)Mathf.Clamp(Mathf.RoundToInt(c.z * 255f), 0, 255), 255);
                    }
            tex.SetPixels32(px);
            tex.Apply(false, false);
            return tex;
        }

        static Vector3 Grade(Vector3 c)
        {
            float luma = Vector3.Dot(c, new Vector3(0.2126f, 0.7152f, 0.0722f));
            Vector3 grey = new Vector3(luma, luma, luma);
            float sat = Mathf.Max(c.x, Mathf.Max(c.y, c.z)) - Mathf.Min(c.x, Mathf.Min(c.y, c.z));
            c = grey + (c - grey) * (1f + 0.3f * (1f - sat));
            float shadows = 4f * luma * (1f - luma) * (1f - luma);
            c += new Vector3(-0.018f, 0f, 0.03f) * shadows + new Vector3(0.03f, 0.012f, -0.025f) * luma * luma;
            c = new Vector3(Mathf.Clamp01(c.x), Mathf.Clamp01(c.y), Mathf.Clamp01(c.z));
            Vector3 curve = Vector3.Scale(Vector3.Scale(c, c), new Vector3(3f, 3f, 3f) - 2f * c);
            return Vector3.Lerp(c, curve, 0.2f);
        }

        // ------------------------------------------------------------- quality ---

        /// <summary>0 low, 1 medium, 2 high.</summary>
        public void ApplyQuality(int level, Camera cam)
        {
            quality = level;
            ApplyShadowMode();
            _vignette.active = level >= 1;
            skyMat.SetFloat("_Detail", level);
            Shader.SetGlobalFloat("gfx_quality", level);
            if (GraphicsSettings.defaultRenderPipeline is UniversalRenderPipelineAsset a)
            {
                a.renderScale = new[] { 0.67f, 0.8f, 1f }[level];
                a.upscalingFilter = UpscalingFilterSelection.FSR;
                a.mainLightShadowmapResolution = level == 0 ? 2048 : 4096;
            }
            light.shadows = level == 0 ? LightShadows.Hard : LightShadows.Soft;
            if (cam != null)
            {
                var data = cam.GetUniversalAdditionalCameraData();
                data.renderPostProcessing = true;
                data.antialiasing = level >= 2 ? AntialiasingMode.SubpixelMorphologicalAntiAliasing : AntialiasingMode.FastApproximateAntialiasing;
            }
        }
    }
}
