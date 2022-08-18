/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "Shared.hlsli"

// Inputs
NRI_RESOURCE( Texture2D<float>, gIn_ViewZ, t, 0, 1 );
NRI_RESOURCE( Texture2D<float>, gIn_Downsampled_ViewZ, t, 1, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Normal_Roughness, t, 2, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_BaseColor_Metalness, t, 3, 1 );
NRI_RESOURCE( Texture2D<float3>, gIn_DirectLighting, t, 4, 1 );
NRI_RESOURCE( Texture2D<float3>, gIn_Ambient, t, 5, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Diff, t, 6, 1 );
NRI_RESOURCE( Texture2D<float4>, gIn_Spec, t, 7, 1 );

#if( NRD_MODE == SH )
    NRI_RESOURCE( Texture2D<float4>, gIn_DiffSh, t, 8, 1 );
    NRI_RESOURCE( Texture2D<float4>, gIn_SpecSh, t, 9, 1 );
#endif

// Outputs
NRI_RESOURCE( RWTexture2D<float4>, gOut_Composed, u, 0, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_ComposedDiff, u, 1, 1 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_ComposedSpec, u, 2, 1 );

float2 GetUpsampleUv( float2 pixelUv, float zReal )
{
    // Set to 1 if you don't use a quarter part of the full texture
    float2 RESOLUTION_SCALE = 0.5 * gRectSize * gInvScreenSize;

    float4 zLow = gIn_Downsampled_ViewZ.GatherRed( gNearestSampler, pixelUv * RESOLUTION_SCALE );
    float4 delta = abs( zReal - zLow ) / zReal;

    float4 offsets = float4( -1.0, 1.0, -1.0, 1.0 ) * gInvRectSize.xxyy;
    float3 d01 = float3( offsets.xw, delta.x );
    float3 d11 = float3( offsets.yw, delta.y );
    float3 d10 = float3( offsets.yz, delta.z );
    float3 d00 = float3( offsets.xz, delta.w );

    d00 = lerp( d01, d00, step( d00.z, d01.z ) );
    d00 = lerp( d11, d00, step( d00.z, d11.z ) );
    d00 = lerp( d10, d00, step( d00.z, d10.z ) );

    float2 invTexSize = 2.0 * gInvRectSize;
    float2 uvNearest = floor( ( pixelUv + d00.xy ) / invTexSize ) * invTexSize + gInvRectSize;

    float2 uv = pixelUv * gRectSize / gScreenSize;
    if( gTracingMode == RESOLUTION_QUARTER )
    {
        float4 cmp = step( 0.01, delta );
        cmp.x = saturate( dot( cmp, 1.0 ) );

        uv = lerp( pixelUv, uvNearest, cmp.x );
        uv *= RESOLUTION_SCALE;
    }

    return uv;
}

[numthreads( 16, 16, 1)]
void main( int2 pixelPos : SV_DispatchThreadId )
{
    // Do not generate NANs for unused threads
    if( pixelPos.x >= gRectSize.x || pixelPos.y >= gRectSize.y )
        return;

    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvRectSize;
    float2 sampleUv = pixelUv + gJitter;

    // Early out - sky
    float3 Ldirect = gIn_DirectLighting[ pixelPos ];
    float viewZ = gIn_ViewZ[ pixelPos ];

    float4 normalAndRoughness = NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos ] );
    float3 N = normalAndRoughness.xyz;
    float roughness = normalAndRoughness.w;

    float z = abs( viewZ ) * NRD_FP16_VIEWZ_SCALE;
    z *= STL::Math::Sign( dot( N, gSunDirection ) );

    if( abs( viewZ ) == INF )
    {
        Ldirect *= float( gOnScreen == SHOW_FINAL );

        gOut_Composed[ pixelPos ] = float4( Ldirect, z );
        gOut_ComposedDiff[ pixelPos ] = float4( 0, 0, 0, z );
        gOut_ComposedSpec[ pixelPos ] = float4( 0, 0, 0, z );

        return;
    }

    // G-buffer
    float3 albedo, Rf0;
    float4 baseColorMetalness = gIn_BaseColor_Metalness[ pixelPos ];
    STL::BRDF::ConvertBaseColorMetalnessToAlbedoRf0( baseColorMetalness.xyz, baseColorMetalness.w, albedo, Rf0 );

    float3 Xv = STL::Geometry::ReconstructViewPosition( sampleUv, gCameraFrustum, viewZ, gOrthoMode );
    float3 X = STL::Geometry::AffineTransform( gViewToWorld, Xv );
    float3 V = gOrthoMode == 0 ? normalize( gCameraOrigin - X ) : gViewDirection;

    // Denoised indirect lighting
    float2 upsampleUv = GetUpsampleUv( pixelUv, viewZ );

    float4 diff = gIn_Diff.SampleLevel( gLinearSampler, upsampleUv, 0 );
    float4 spec = gIn_Spec.SampleLevel( gLinearSampler, upsampleUv, 0 );

    if( gDenoiserType == RELAX )
    {
        diff = RELAX_BackEnd_UnpackRadiance( diff );
        spec = RELAX_BackEnd_UnpackRadiance( spec );

        // RELAX doesn't support AO / SO denoising, set to estimated integrated average
        diff.w = 1.0 / STL::Math::Pi( 1.0 );
        spec.w = 1.0 / STL::Math::Pi( 1.0 );
    }
    else
    {
    #if( NRD_MODE == OCCLUSION )
        diff = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( diff ).xxxx;
        spec = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( spec ).xxxx;
    #elif( NRD_MODE == SH )
        float4 diffSh = gIn_DiffSh.SampleLevel( gLinearSampler, upsampleUv, 0 );
        float4 specSh = gIn_SpecSh.SampleLevel( gLinearSampler, upsampleUv, 0 );

        // Resolve diffuse
        NRD_SH sh = REBLUR_BackEnd_UnpackSh( diff, diffSh );
        diff.w = sh.normHitDist;

        if( gSH )
            diff.xyz = NRD_SH_ResolveColor( sh, N );
        else
            diff.xyz = NRD_SH_ExtractColor( sh );

        // Resolve specular
        float3 D = STL::ImportanceSampling::GetSpecularDominantDirection( N, V, roughness, STL_SPECULAR_DOMINANT_DIRECTION_G1 ).xyz;

        sh = REBLUR_BackEnd_UnpackSh( spec, specSh );
        spec.w = sh.normHitDist;

        if( gSH )
            spec.xyz = NRD_SH_ResolveColor( sh, D );
        else
            spec.xyz = NRD_SH_ExtractColor( sh );
    #else
        diff = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( diff );
        spec = REBLUR_BackEnd_UnpackRadianceAndNormHitDist( spec );
    #endif
    }

    diff.xyz *= gIndirectDiffuse;
    spec.xyz *= gIndirectSpecular;

    // Environment ( pre-integrated ) specular term
    float NoV = abs( dot( N, V ) );
    float3 Fenv = STL::BRDF::EnvironmentTerm_Rtg( Rf0, NoV, roughness );

    // Composition
    float3 diffDemod = ( 1.0 - Fenv ) * albedo;
    float3 specDemod = Fenv;

    float3 Ldiff = diff.xyz * ( gReference ? 1.0 : diffDemod * 0.99 + 0.01 );
    float3 Lspec = spec.xyz * ( gReference ? 1.0 : specDemod * 0.99 + 0.01 );

    // Ambient
    float3 ambient = gIn_Ambient.SampleLevel( gLinearSampler, float2( 0.5, 0.5 ), 0 );
    ambient *= exp2( AMBIENT_FADE * STL::Math::LengthSquared( Xv ) );
    ambient *= gAmbient;

    float specAmbientAmount = gDenoiserType == RELAX ? roughness : GetSpecMagicCurve( roughness );

    Ldiff += ambient * diff.w * ( 1.0 - Fenv ) * albedo;
    Lspec += ambient * spec.w * Fenv * specAmbientAmount;

    float3 Lsum = Ldirect + Ldiff + Lspec;

    // Debug
    if( gOnScreen == SHOW_DENOISED_DIFFUSE )
        Lsum = diff.xyz;
    else if( gOnScreen == SHOW_DENOISED_SPECULAR )
        Lsum = spec.xyz;
    else if( gOnScreen == SHOW_AMBIENT_OCCLUSION )
        Lsum = diff.w;
    else if( gOnScreen == SHOW_SPECULAR_OCCLUSION )
        Lsum = spec.w;
    else if( gOnScreen == SHOW_BASE_COLOR )
        Lsum = baseColorMetalness.xyz;
    else if( gOnScreen == SHOW_NORMAL )
        Lsum = N * 0.5 + 0.5;
    else if( gOnScreen == SHOW_ROUGHNESS )
        Lsum = roughness;
    else if( gOnScreen == SHOW_METALNESS )
        Lsum = baseColorMetalness.w;
    else if( gOnScreen == SHOW_WORLD_UNITS )
        Lsum = frac( X * gUnitToMetersMultiplier );
    else if( gOnScreen != SHOW_FINAL )
        Lsum = gOnScreen == SHOW_MIP_SPECULAR ? spec.xyz : Ldirect.xyz;

    // Output
    gOut_Composed[ pixelPos ] = float4( Lsum, z );
    gOut_ComposedDiff[ pixelPos ] = float4( Ldiff, z );
    gOut_ComposedSpec[ pixelPos ] = float4( Lspec, z );
}