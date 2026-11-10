// Port of shaders/sky.gdshader (day sky) and planet/space_sky.gdshader (space from orbit),
// as one URP skybox. Directions are worked in msp's Godot space: the Unity view direction is
// mirrored across X, then turned into "sky space" by _SkyRot (PlanetSky sets it: the local
// frame of the view point at street and mayor height, the sun's turn round the axis from orbit).
Shader "MSP/Sky"
{
    Properties
    {
        _Zenith ("Zenith", Color) = (0.08, 0.28, 0.75, 1)
        _Horizon ("Horizon", Color) = (0.5, 0.68, 0.9, 1)
        _Dusk ("Dusk", Color) = (1.0, 0.5, 0.25, 1)
        _Ground ("Ground", Color) = (0.2, 0.2, 0.19, 1)
    }
    SubShader
    {
        Tags { "Queue" = "Background" "RenderType" = "Background" "PreviewType" = "Skybox" "RenderPipeline" = "UniversalPipeline" }
        Cull Off ZWrite Off
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            float4 _Zenith, _Horizon, _Dusk, _Ground;
            float3 _SunLight;     // sun colour x energy, lights clouds
            float3 _SunDirSky;    // toward the sun, sky space
            float3 _MoonDirSky;
            float _Sunset, _Night, _CloudCover, _Pollution, _Detail, _Space;
            float _HorizonDip;    // sin of how far the ball's real horizon sits below the local horizontal (port addition)
            float4x4 _SkyRot;     // Godot world dir -> sky dir

            struct A { float4 pos : POSITION; };
            struct V { float4 pos : SV_POSITION; float3 dir : TEXCOORD0; };

            V vert(A i)
            {
                V o;
                o.pos = TransformObjectToHClip(i.pos.xyz);
                o.dir = TransformObjectToWorldDir(i.pos.xyz, false);
                return o;
            }

            float h21(float2 p) { float3 p3 = frac(p.xyx * 0.1031); p3 += dot(p3, p3.yzx + 33.33); return frac((p3.x + p3.y) * p3.z); }
            float h31(float3 p3) { p3 = frac(p3 * 0.1031); p3 += dot(p3, p3.zyx + 31.32); return frac((p3.x + p3.y) * p3.z); }
            float n2(float2 p)
            {
                float2 i = floor(p), f = frac(p);
                float2 u = f * f * (3.0 - 2.0 * f);
                return lerp(lerp(h21(i), h21(i + float2(1, 0)), u.x), lerp(h21(i + float2(0, 1)), h21(i + float2(1, 1)), u.x), u.y);
            }
            float fbm(float2 p, int oct)
            {
                float s = 0.0, a = 0.5;
                for (int i = 0; i < 6; i++) { if (i >= oct) break; s += n2(p) * a; p = p * 2.03 + float2(17.1, 3.7); a *= 0.5; }
                return s;
            }
            float vn3(float3 p)
            {
                float3 i = floor(p); float3 f = frac(p); f = f * f * (3.0 - 2.0 * f);
                return lerp(lerp(lerp(h31(i), h31(i + float3(1, 0, 0)), f.x), lerp(h31(i + float3(0, 1, 0)), h31(i + float3(1, 1, 0)), f.x), f.y),
                    lerp(lerp(h31(i + float3(0, 0, 1)), h31(i + float3(1, 0, 1)), f.x), lerp(h31(i + float3(0, 1, 1)), h31(i + float3(1, 1, 1)), f.x), f.y), f.z);
            }

            float3 atmosphere(float3 d)
            {
                float h = max(d.y, 0.0);
                float3 col = lerp(_Horizon.rgb, _Zenith.rgb, pow(h, 0.5));
                col = lerp(col, _Horizon.rgb * 1.06, exp(-h * 22.0) * 0.5);
                float2 dh = normalize(d.xz + 1e-5);
                float2 sh = normalize(_SunDirSky.xz + 1e-5);
                float side = 0.5 + 0.5 * dot(dh, sh);
                float band = exp(-h * 5.0) * _Sunset;
                col = lerp(col, _Dusk.rgb, saturate(band * (0.25 + 0.75 * side * side * side)));
                col = lerp(col, col * float3(1.0, 0.82, 1.05), band * (1.0 - side) * 0.5);
                float sd = max(dot(d, _SunDirSky), 0.0);
                float day = 1.0 - _Night;
                col += _Dusk.rgb * pow(sd, 6.0) * (0.12 + 0.9 * _Sunset) * day;
                col += _SunLight * pow(sd, 90.0) * 0.12 * day;
                col += float3(1.0, 0.5, 0.25) * _Pollution * exp(-h * 7.0) * 0.045;
                return lerp(col, _Ground.rgb, smoothstep(0.0, -0.1, d.y));
            }

            float4 clouds(float3 d, int oct)
            {
                if (d.y < 0.005) return 0;
                float t = _Time.y;
                float2 p = d.xz / (d.y + 0.06) * 1.1 + float2(t * 0.0035, t * 0.0015);
                float2 w = float2(fbm(p * 0.5, 3), fbm(p * 0.5 + float2(5.2, 1.3), 3));
                float shape = fbm(p * 0.75 + w * 1.4, oct);
                float lo = 1.0 - _CloudCover;
                float cov = smoothstep(lo - 0.04, lo + 0.22, shape);
                if (cov <= 0.001) return 0;
                float2 toward = normalize(_SunDirSky.xz + 1e-4) * 0.18;
                float ahead = fbm((p + toward) * 0.75 + w * 1.4, oct);
                float lit = saturate(0.62 + (shape - ahead) * 4.0);
                lit *= smoothstep(-0.25, 0.1, _SunDirSky.y);
                float edge = 1.0 - smoothstep(lo, lo + 0.3, shape);
                float3 amb = lerp(_Horizon.rgb, _Zenith.rgb, 0.4) * 0.85 + _Ground.rgb * 0.25;
                float3 col = amb + _SunLight * (0.42 + 0.18 * edge) * lit;
                float sd = max(dot(d, _SunDirSky), 0.0);
                col += _SunLight * pow(sd, 10.0) * edge * 0.5;
                col = lerp(col, amb * 1.6 + float3(0.04, 0.035, 0.045), _Night);
                col += float3(1.0, 0.5, 0.25) * _Pollution * exp(-d.y * 6.0) * 0.06;
                return float4(col, cov * smoothstep(0.005, 0.14, d.y));
            }

            float stars(float3 d, float scale, float keep, float size)
            {
                float3 cell = floor(d * scale);
                float s = h31(cell);
                if (s < keep) return 0.0;
                float3 c = normalize((cell + 0.5 + (float3(h31(cell + 3.1), h31(cell + 5.7), h31(cell + 9.3)) - 0.5) * 0.7) / scale);
                return smoothstep(size, 0.0, length(d - c)) * (0.35 + 0.65 * h31(cell + 7.0));
            }

            float3 space(float3 d)
            {
                float g = dot(d, normalize(float3(0.35, 0.82, 0.45)));
                float band = exp(-g * g * 14.0) * (0.35 + 0.65 * vn3(d * 9.0)) * (0.6 + 0.4 * vn3(d * 23.0));
                float3 col = float3(0.003, 0.004, 0.012) + float3(0.035, 0.03, 0.055) * band;
                float st = stars(d, 220.0, 0.975, 0.0016) * 0.7 + stars(d, 90.0, 0.985, 0.0022) * 1.3
                    + stars(d, 40.0, 0.99, 0.0032) * 2.5 + stars(d * 1.7, 300.0, 0.95, 0.0012) * band * 1.5;
                float3 tint = lerp(float3(0.75, 0.85, 1.0), float3(1.0, 0.9, 0.75), h31(floor(d * 300.0) + 2.0));
                col += st * tint;
                float sd = max(dot(d, normalize(_SunDirSky)), 0.0);
                col += float3(1.0, 0.96, 0.88) * smoothstep(0.99955, 0.99975, sd) * 30.0;
                col += float3(1.0, 0.75, 0.45) * pow(sd, 900.0) * 3.0;
                col += float3(1.0, 0.7, 0.4) * pow(sd, 60.0) * 0.08;
                return col;
            }

            half4 frag(V i) : SV_Target
            {
                float3 du = normalize(i.dir);
                float3 g = float3(-du.x, du.y, du.z);
                float3 d = normalize(mul(_SkyRot, float4(g, 0)).xyz);
                if (_Space > 0.5) return half4(space(d), 1);
                // On a ball this small the horizon seen from the mayor camera dips far below the
                // local horizontal, so lift the sky's horizon down to meet it (msp shows flat
                // ground colour there instead). y' runs from -1 to 1 with y = -dip at the horizon.
                if (_HorizonDip > 0.0)
                {
                    float y = (d.y + _HorizonDip) / (1.0 + _HorizonDip * sign(d.y + _HorizonDip));
                    float2 xz = d.xz;
                    float l = length(xz);
                    d = float3(l > 1e-5 ? xz / l * sqrt(saturate(1.0 - y * y)) : xz, y).xzy;
                }
                float3 col = atmosphere(d);
                float4 cl = clouds(d, _Detail >= 2 ? 6 : 5);
                if (d.y > 0.0)
                {
                    float t = _Time.y;
                    float3 sp = d * 260.0;
                    float3 cell = floor(sp);
                    float hs = h31(cell);
                    if (hs > 0.9965)
                    {
                        float3 f = frac(sp) - 0.5;
                        float tw = 0.65 + 0.35 * sin(t * (1.5 + hs * 3.0) + hs * 80.0);
                        float st = smoothstep(0.3, 0.0, length(f)) * tw * (hs - 0.9965) / 0.0035;
                        col += float3(0.8, 0.88, 1.0) * st * 2.2 * _Night * smoothstep(0.0, 0.2, d.y) * (1.0 - cl.a);
                    }
                    float md = dot(d, _MoonDirSky);
                    if (md > 0.999)
                    {
                        float3 mt = normalize(cross(_MoonDirSky, float3(0, 1, 0)) + 1e-4);
                        float3 mb = cross(mt, _MoonDirSky);
                        float2 mp = float2(dot(d, mt), dot(d, mb)) / 0.026;
                        float disc = 1.0 - smoothstep(0.92, 1.0, length(mp));
                        float mare = 0.82 + 0.18 * smoothstep(0.35, 0.7, n2(mp * 3.0 + 7.0));
                        col = lerp(col, float3(1.3, 1.32, 1.38) * mare, disc * _Night * (1.0 - cl.a * 0.85));
                    }
                    col += float3(0.6, 0.7, 1.0) * pow(max(md, 0.0), 500.0) * 0.6 * _Night;
                    float sdd = dot(d, _SunDirSky);
                    float sdisc = smoothstep(0.99982, 0.99988, sdd);
                    col += _SunLight * 14.0 * sdisc * (1.0 - _Night) * (1.0 - cl.a);
                }
                return half4(lerp(col, cl.rgb, cl.a), 1);
            }
            ENDHLSL
        }
    }
}
