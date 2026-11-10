// Port of shaders/terrain.gdshader: grass, beach, sea floor, the polar ice, zone hints, tool
// previews and lamp pools. Vertex colour: r = landness, g = ice (PlanetGround).
Shader "MSP/Terrain"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "MSPCommon.hlsl"
        ENDHLSL

        Pass
        {
            Name "ForwardLit"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            HLSLPROGRAM
            #pragma target 3.5
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _SHADOWS_SOFT _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH
            #pragma multi_compile_fragment _ _SCREEN_SPACE_OCCLUSION
            #include "MSPLit.hlsl"

            struct A { float4 pos : POSITION; float3 nrm : NORMAL; float4 col : COLOR; };
            struct V
            {
                float4 pos : SV_POSITION;
                float3 wposU : TEXCOORD0;
                float3 nrmU : TEXCOORD1;
                float2 li : TEXCOORD2;   // landness, ice
                float fog : TEXCOORD3;
            };

            V vert(A i)
            {
                V o;
                o.wposU = TransformObjectToWorld(i.pos.xyz);
                o.pos = TransformWorldToHClip(o.wposU);
                o.nrmU = TransformObjectToWorldNormal(i.nrm);
                o.li = i.col.rg;
                o.fog = ComputeFogFactor(o.pos.z);
                return o;
            }

            half4 frag(V i) : SV_Target
            {
                float3 wpos = GodotPos(i.wposU);
                float landness = i.li.x, ice = i.li.y;
                float3 mpos = map_pos(wpos);
                float g = fbm(mpos.xz * 0.012);
                float g2 = fbm(mpos.xz * 0.09 + 11.0);
                float3 grass = lerp(float3(0.12, 0.25, 0.06), float3(0.23, 0.36, 0.1), g);
                grass = lerp(grass, float3(0.4, 0.38, 0.16), smoothstep(0.6, 0.8, g2) * 0.55);
                grass = lerp(grass, float3(0.06, 0.17, 0.04), smoothstep(0.62, 0.78, fbm(mpos.xz * 0.03 + 5.0)) * 0.5);
                float2 fw = fwidth(mpos.xz * 1.3);
                grass *= lerp(1.0, 0.88 + 0.24 * vnoise(mpos.xz * 1.3), saturate(1.0 - max(fw.x, fw.y) * 1.6));
                float3 sand = lerp(float3(0.84, 0.75, 0.55), float3(0.76, 0.67, 0.47), vnoise(mpos.xz * 0.5));
                float3 wet = float3(0.6, 0.53, 0.38);
                float3 seabed = float3(0.45, 0.48, 0.36);
                float beach = 1.0 - smoothstep(0.065, 0.1, landness + (g2 - 0.5) * 0.02);
                float3 alb = lerp(grass, sand, beach);
                alb = lerp(alb, wet, smoothstep(-0.35, -0.62, mpos.y) * 0.8);
                alb = lerp(alb, seabed, smoothstep(-1.5, -5.0, mpos.y));
                if (ice > 0.0)
                {
                    float3 tundra = lerp(float3(0.42, 0.4, 0.3), float3(0.5, 0.48, 0.4), g2);
                    float3 snow = float3(0.92, 0.95, 1.0) * (0.92 + 0.08 * vnoise(mpos.xz * 0.2));
                    float3 glacier = lerp(float3(0.7, 0.85, 0.95), float3(0.85, 0.93, 1.0), fbm(mpos.xz * 0.02));
                    alb = lerp(alb, tundra, smoothstep(0.0, 0.25, ice));
                    alb = lerp(alb, snow, smoothstep(0.25, 0.55, ice + (g - 0.5) * 0.15));
                    alb = lerp(alb, glacier, smoothstep(0.7, 1.0, ice + (g2 - 0.5) * 0.2));
                }

                int2 c = cell_of(wpos);
                float4 cm = city_at(c);
                int z = zone_of(cm);
                float2 f = frac(mpos.xz / max(tile_size, 0.001));
                float edge = max(abs(f.x - 0.5), abs(f.y - 0.5));
                float3 emit = 0;
                if (z > 0 && !built_of(cm))
                {
                    float border = smoothstep(0.4, 0.47, edge);
                    alb = lerp(alb, zone_rgb(z) * 0.8, 0.28 + border * 0.5);
                }
                if (grid_alpha > 0.0 && cm.r < 0.5 && mpos.y > -0.1)
                    alb *= 1.0 - smoothstep(0.475, 0.497, edge) * 0.35 * grid_alpha;
                if (overlay_mode > 0.5)
                {
                    float lum = dot(alb, float3(0.3, 0.59, 0.11));
                    float3 grey = lum * 0.6 + 0.25;
                    if (overlay_mode < 1.5) alb = z > 0 ? lerp(grey, zone_rgb(z), 0.6) : grey;
                    else if (overlay_mode > 2.5 && mpos.y > -0.1) alb = lerp(grey, heat(1.0 - cm.a), 0.6);
                    else alb = grey;
                }
                float rough = lerp(lerp(0.95, 0.6, smoothstep(-0.3, -0.8, mpos.y)), 0.35, smoothstep(0.6, 1.0, ice));
                float3 nG = GodotPos(normalize(i.nrmU));
                emit += alb * lamp_light(wpos, nG);
                emit += preview_tint(wpos);
                return MSPShade(i.wposU, i.nrmU, i.pos, i.fog, alb, rough, 0.0, emit);
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On ColorMask R Cull Back
            HLSLPROGRAM
            #pragma vertex MSPDepthVert
            #pragma fragment MSPDepthFrag
            #include "MSPLit.hlsl"
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormals" }
            ZWrite On Cull Back
            HLSLPROGRAM
            #pragma vertex MSPDepthVert
            #pragma fragment MSPDepthNormalsFrag
            #include "MSPLit.hlsl"
            ENDHLSL
        }
    }
}
