// Shared URP lighting and depth passes for the ported msp shaders that aren't the kit shader
// (terrain, sea, stand-ins). Include after Core.hlsl and MSPCommon.hlsl.
#ifndef MSP_LIT_INCLUDED
#define MSP_LIT_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

// Lit colour for a surface given in Godot terms (albedo, roughness, metallic, emission).
// wposU and nrmU are Unity world space.
half4 MSPShade(float3 wposU, float3 nrmU, float4 posCS, float fog, float3 alb, float rough, float metal, float3 emit)
{
    InputData input = (InputData)0;
    input.positionWS = wposU;
    input.normalWS = normalize(nrmU);
    input.viewDirectionWS = GetWorldSpaceNormalizeViewDir(wposU);
    input.shadowCoord = TransformWorldToShadowCoord(wposU);
    input.fogCoord = fog;
    input.bakedGI = SampleSH(input.normalWS);
    input.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(posCS);
    input.shadowMask = half4(1, 1, 1, 1);
    SurfaceData s = (SurfaceData)0;
    s.albedo = alb;
    s.metallic = metal;
    s.smoothness = 1.0 - rough;
    s.occlusion = 1.0;
    s.emission = emit;
    s.alpha = 1.0;
    s.normalTS = float3(0, 0, 1);
    half4 c = UniversalFragmentPBR(input, s);
    c.rgb = MixFog(c.rgb, fog);
    return c;
}

struct MSPDepthAttr { float4 pos : POSITION; float3 nrm : NORMAL; };
struct MSPDepthV { float4 pos : SV_POSITION; float3 n : TEXCOORD0; };

MSPDepthV MSPDepthVert(MSPDepthAttr i)
{
    MSPDepthV o;
    o.pos = TransformObjectToHClip(i.pos.xyz);
    o.n = TransformObjectToWorldNormal(i.nrm);
    return o;
}

half4 MSPDepthFrag(MSPDepthV i) : SV_Target { return 0; }
half4 MSPDepthNormalsFrag(MSPDepthV i) : SV_Target { return half4(NormalizeNormalPerPixel(i.n), 0.0); }

#endif
