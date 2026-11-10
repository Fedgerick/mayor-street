// Port of shaders/water.gdshader: light filters down to a sandy bottom with caustics in the
// shallows and fades to deep blue offshore, surf rolls in at the shore, and the surface
// reflects more sky at grazing angles, with a sun glitter path far out.
Shader "MSP/Water"
{
    Properties
    {
        _HeightTex ("Sea floor (R = height / -16)", 2D) = "black" {}
        _HeightRect ("Height rect (xy origin, zw size)", Vector) = (0, 0, 1, 1)
        _WaveA ("Waves A", 2D) = "bump" {}
        _WaveB ("Waves B", 2D) = "bump" {}
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
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
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "MSPCommon.hlsl"
            #include "MSPLit.hlsl"

            TEXTURE2D(_HeightTex); SAMPLER(sampler_HeightTex);
            TEXTURE2D(_WaveA); SAMPLER(sampler_WaveA);
            TEXTURE2D(_WaveB); SAMPLER(sampler_WaveB);
            CBUFFER_START(UnityPerMaterial)
            float4 _HeightRect;
            CBUFFER_END

            static const float3 DEEP = float3(0.02, 0.17, 0.32);
            static const float3 ABSORB = float3(0.9, 0.2, 0.14);
            static const float3 BED = float3(0.7, 0.68, 0.58);

            struct A { float4 pos : POSITION; float3 nrm : NORMAL; };
            struct V { float4 pos : SV_POSITION; float3 wposU : TEXCOORD0; float3 nrmU : TEXCOORD1; float fog : TEXCOORD2; };

            V vert(A i)
            {
                V o;
                o.wposU = TransformObjectToWorld(i.pos.xyz);
                o.pos = TransformWorldToHClip(o.wposU);
                o.nrmU = TransformObjectToWorldNormal(i.nrm);
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            float floor_height(float2 xz)
            {
                float2 huv = (xz - _HeightRect.xy) / _HeightRect.zw;
                if (huv.x > 0.0 && huv.y > 0.0 && huv.x < 1.0 && huv.y < 1.0)
                    return SAMPLE_TEXTURE2D_LOD(_HeightTex, sampler_HeightTex, huv, 0).r * -16.0;
                return -16.0;
            }

            float caustics(float2 p, float t)
            {
                float a = vnoise(p + float2(t * 0.35, t * 0.21));
                float b = vnoise(p * 1.13 + float2(-t * 0.27, t * 0.31) + 17.0);
                return pow(1.0 - abs(a - b), 10.0);
            }

            half4 frag(V i, bool front : SV_IsFrontFace) : SV_Target
            {
                float3 wpos = GodotPos(i.wposU);
                float3 mpos = map_pos(wpos);
                float t = _Time.y;
                float far_k = smoothstep(60.0, 900.0, length(GetCameraPositionWS() - i.wposU));
                float3 na = SAMPLE_TEXTURE2D(_WaveA, sampler_WaveA, mpos.xz * 0.018 + float2(t * 0.012, t * 0.007)).rgb;
                float3 nb = SAMPLE_TEXTURE2D(_WaveB, sampler_WaveB, mpos.xz * 0.041 - float2(t * 0.009, -t * 0.014)).rgb;
                float3 nm = lerp(na, nb, 0.5);
                if (gfx_quality > 0.0)
                {
                    float3 nc = SAMPLE_TEXTURE2D(_WaveB, sampler_WaveB, mpos.xz * 0.19 + float2(t * 0.03, t * 0.021)).rgb;
                    nm = lerp(nm, nc, 0.4 * (1.0 - far_k));
                }

                float depth = max(mpos.y - floor_height(mpos.xz), 0.0);
                float nt = night_at(wpos);
                float day = 1.0 - nt;

                float2 bp = mpos.xz + (nm.xy - 0.5) * min(depth, 4.0) * 0.5;
                float2 fw = fwidth(bp);
                float px = max(fw.x, fw.y);
                float3 sand = BED * (0.86 + 0.22 * vnoise(bp * 0.45));
                sand *= 1.0 - 0.08 * saturate(1.0 - px * 1.5) * smoothstep(0.3, 1.0, sin(dot(bp, float2(2.3, 3.1)) + vnoise(bp * 0.3) * 6.0));
                if (gfx_quality > 0.0)
                {
                    float c = caustics(bp * 0.85, t) + caustics(bp * 1.7 + 9.0, t * 1.3) * 0.5;
                    sand += float3(0.85, 0.95, 1.0) * c * 0.55 * day * saturate(1.0 - px * 3.0) * (1.0 - smoothstep(0.5, 5.0, depth));
                }
                float3 tr = exp(-ABSORB * depth);
                float3 col = sand * tr + DEEP * (1.0 - tr);

                float n = fbm(mpos.xz * 0.35 + float2(t * 0.15, t * 0.1));
                float shore = 1.0 - smoothstep(0.0, 0.25 + n * 0.35, depth);
                float wave = smoothstep(0.8, 0.97, sin(depth * 4.0 - t * 1.4 + n * 4.0)) * (1.0 - smoothstep(0.2, 1.8, depth));
                float2 fp = mpos.xz * 1.5 + float2(t * 0.35, -t * 0.25);
                float bubbles = lerp(0.55, vnoise(fp) * 0.6 + vnoise(fp * 2.7) * 0.4, saturate(1.0 - px * 2.0));
                float foam = saturate(shore + wave * 0.85) * smoothstep(0.3, 0.62, bubbles + shore * 0.35 + n * 0.2);
                col = lerp(col, float3(0.92, 0.96, 1.0), foam);
                col *= lerp(1.0, 0.35, nt);

                // the wave normal map, bent onto the ball's local frame (Godot space)
                float3 up = up_at(wpos);
                float3 east = normalize(cross(float3(0, 1, 0), up) + float3(1e-5, 0, 0));
                float3 south = cross(east, up);
                float k = lerp(0.65, 0.22, far_k) * (1.0 - foam * 0.7);
                float3 tn = nm * 2.0 - 1.0;
                float3 nG = normalize(up * tn.z + (east * tn.x + south * tn.y) * k);
                float3 nU = GodotPos(nG);
                if (!front) nU = -nU;
                float3 viewU = GetWorldSpaceNormalizeViewDir(i.wposU);
                float fres = pow(1.0 - saturate(dot(normalize(i.nrmU) * (front ? 1 : -1), viewU)), 4.0);
                float3 alb = col * (1.0 - fres * 0.75 * (1.0 - foam));
                float rough = lerp(lerp(0.03, 0.13, far_k), 0.6, foam);
                return MSPShade(i.wposU, nU, i.pos, i.fog, alb, rough, 0.0, 0);
            }
            ENDHLSL
        }
    }
}
