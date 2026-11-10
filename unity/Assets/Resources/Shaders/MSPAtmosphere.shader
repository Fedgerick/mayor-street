// Port of planet/atmosphere.gdshader: a thin blue haze round the planet seen from orbit,
// brightest at the rim on the day side. Additive, unlit.
Shader "MSP/Atmosphere"
{
    SubShader
    {
        Tags { "Queue" = "Transparent" "RenderType" = "Transparent" "RenderPipeline" = "UniversalPipeline" }
        Blend One One
        ZWrite Off
        Cull Back
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            float _Strength;
            float3 _SunWorldU;  // toward the sun, Unity space
            struct A { float4 pos : POSITION; float3 n : NORMAL; };
            struct V { float4 pos : SV_POSITION; float3 n : TEXCOORD0; float3 wp : TEXCOORD1; };
            V vert(A i)
            {
                V o;
                o.wp = TransformObjectToWorld(i.pos.xyz);
                o.pos = TransformWorldToHClip(o.wp);
                o.n = TransformObjectToWorldNormal(i.n);
                return o;
            }
            half4 frag(V i) : SV_Target
            {
                float3 n = normalize(i.n);
                float3 v = normalize(_WorldSpaceCameraPos - i.wp);
                float rim = 1.0 - saturate(dot(n, v));
                float day = smoothstep(-0.35, 0.4, dot(n, _SunWorldU));
                float3 col = lerp(float3(0.25, 0.5, 1.0), float3(0.6, 0.8, 1.0), rim);
                return half4(col * pow(rim, 2.5) * (0.25 + 1.4 * day) * _Strength, 1);
            }
            ENDHLSL
        }
    }
}
