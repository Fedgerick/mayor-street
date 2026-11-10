// Port of shaders/site.gdshader: construction site props (scaffolding, cranes, hoardings) in
// vertex colours, cut off above _ClipTop (object space, Godot y) so one mesh serves a building
// at every height. uv.x > 0.5 marks debris netting, drawn as a screen-door weave.
Shader "MSP/Site"
{
    Properties
    {
        _ClipTop ("Clip top", Float) = 1000
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"
        CBUFFER_START(UnityPerMaterial)
        float _ClipTop;
        CBUFFER_END
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }
            Cull Off
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #include "MSPLit.hlsl"

            struct A { float4 pos : POSITION; float3 nrm : NORMAL; float4 col : COLOR; float2 uv : TEXCOORD0; };
            struct V
            {
                float4 pos : SV_POSITION;
                float3 wposU : TEXCOORD0;
                float3 nrmU : TEXCOORD1;
                float4 col : TEXCOORD2;
                float2 uv : TEXCOORD3;
                float oy : TEXCOORD4;
                float fog : TEXCOORD5;
            };

            V vert(A i)
            {
                V o;
                o.wposU = TransformObjectToWorld(i.pos.xyz);
                o.pos = TransformWorldToHClip(o.wposU);
                o.nrmU = TransformObjectToWorldNormal(i.nrm);
                o.col = i.col;
                o.uv = i.uv;
                o.oy = i.pos.y;
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            half4 frag(V i, bool front : SV_IsFrontFace) : SV_Target
            {
                if (i.oy > _ClipTop) discard;
                if (i.uv.x > 0.5)
                {
                    int2 px = int2(i.pos.xy);
                    if (((px.x + px.y) & 1) == 0) discard;
                }
                float3 n = normalize(i.nrmU);
                float3 v = GetWorldSpaceNormalizeViewDir(i.wposU);
                if (dot(n, v) < 0.0) n = -n;  // two-sided
                float3 emit = i.col.rgb * lamp_light(GodotPos(i.wposU), GodotPos(n));
                return MSPShade(i.wposU, n, i.pos, i.fog, i.col.rgb, 0.8, 0.0, emit);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On ZTest LEqual ColorMask 0 Cull Off
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
            float3 _LightDirection;
            float3 _LightPosition;
            struct A { float4 pos : POSITION; float3 nrm : NORMAL; };
            struct V { float4 pos : SV_POSITION; float oy : TEXCOORD0; };
            V vert(A i)
            {
                V o;
                o.oy = i.pos.y;
                float3 wp = TransformObjectToWorld(i.pos.xyz);
                float3 wn = TransformObjectToWorldNormal(i.nrm);
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 ld = normalize(_LightPosition - wp);
                #else
                    float3 ld = _LightDirection;
                #endif
                float4 cs = TransformWorldToHClip(ApplyShadowBias(wp, wn, ld));
                #if UNITY_REVERSED_Z
                    cs.z = min(cs.z, UNITY_NEAR_CLIP_VALUE);
                #else
                    cs.z = max(cs.z, UNITY_NEAR_CLIP_VALUE);
                #endif
                o.pos = cs;
                return o;
            }
            half4 frag(V i) : SV_Target
            {
                if (i.oy > _ClipTop) discard;
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On ColorMask R Cull Off
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            struct A { float4 pos : POSITION; };
            struct V { float4 pos : SV_POSITION; float oy : TEXCOORD0; };
            V vert(A i) { V o; o.oy = i.pos.y; o.pos = TransformObjectToHClip(i.pos.xyz); return o; }
            half4 frag(V i) : SV_Target { if (i.oy > _ClipTop) discard; return 0; }
            ENDHLSL
        }
    }
}
