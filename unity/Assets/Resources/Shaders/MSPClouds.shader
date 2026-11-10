// Port of planet/clouds.gdshader: the cloud layer seen from high up. Alpha-blended, unlit.
// Directions are in Godot space (Unity world mirrored across X).
Shader "MSP/Clouds"
{
    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" }
        Blend SrcAlpha OneMinusSrcAlpha
        ZWrite Off
        Cull Back
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            float _Strength, _Drift, _Cover;
            float3 _SunWorld;   // Godot space
            float4 _Storm;      // xyz Godot-space direction, w strength
            struct A { float4 pos : POSITION; };
            struct V { float4 pos : SV_POSITION; float3 dir : TEXCOORD0; };
            float h3(float3 p) { p = frac(p * 0.1031); p += dot(p, p.zyx + 31.32); return frac((p.x + p.y) * p.z); }
            float vnoise3(float3 p)
            {
                float3 i = floor(p); float3 f = frac(p); f = f * f * (3.0 - 2.0 * f);
                return lerp(lerp(lerp(h3(i), h3(i + float3(1, 0, 0)), f.x), lerp(h3(i + float3(0, 1, 0)), h3(i + float3(1, 1, 0)), f.x), f.y),
                    lerp(lerp(h3(i + float3(0, 0, 1)), h3(i + float3(1, 0, 1)), f.x), lerp(h3(i + float3(0, 1, 1)), h3(i + float3(1, 1, 1)), f.x), f.y), f.z);
            }
            V vert(A i)
            {
                V o;
                o.pos = TransformObjectToHClip(i.pos.xyz);
                float3 du = TransformObjectToWorldDir(i.pos.xyz, false);
                o.dir = float3(-du.x, du.y, du.z);
                return o;
            }
            half4 frag(V i) : SV_Target
            {
                float3 d = normalize(i.dir);
                float c = cos(_Drift), s = sin(_Drift);
                float3 p = float3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z) * float3(5.0, 7.5, 5.0);
                float n = 0.0, a = 0.5;
                for (int k = 0; k < 4; k++) { n += a * vnoise3(p); p = p * 2.07 + 11.3; a *= 0.5; }
                float banks = smoothstep(1.0 - _Cover, 1.15 - _Cover * 0.6, n + 0.12);
                float st = _Storm.w * smoothstep(0.80, 0.97, dot(d, normalize(_Storm.xyz)));
                float alpha = clamp(max(banks * 0.8, st * (0.55 + 0.45 * n)), 0.0, 0.95);
                float ds = dot(d, _SunWorld);
                float lit = smoothstep(-0.15, 0.35, ds);
                float3 col = lerp(float3(0.03, 0.035, 0.05), float3(0.97, 0.97, 1.0), lit);
                col = lerp(col, col * float3(0.55, 0.58, 0.65), st);
                col += float3(0.5, 0.25, 0.08) * (1.0 - abs(ds) * 4.0) * step(abs(ds), 0.25) * 0.4;
                return half4(col, alpha * _Strength);
            }
            ENDHLSL
        }
    }
}
