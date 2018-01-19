#version 140
#extension GL_EXT_shader_texture_lod: enable
#extension GL_OES_standard_derivatives : enable
out vec4 fragColor;
#if defined(S_TANGENTS) && defined(S_NORMALMAP)
in mat3 vTBN;
#else
in vec3 vNormal;
#endif
in vec2 vUV;
in vec3 vWsPos;
in vec3 vLightDir[SI_LIGHTS];

uniform vec4 g_lightColorRange[SI_LIGHTS];
uniform vec4 color;
uniform vec4 metallicRoughness;
uniform vec4 g_cameraPos;
uniform sampler2D tex;
#ifdef S_METALROUGHNESSMAP
uniform sampler2D mrTex;
#endif
#ifdef S_NORMALMAP
uniform sampler2D normalTex;
uniform float normalScale;
#endif
#ifdef S_EMISSIVEMAP
uniform sampler2D emissiveTex;
uniform vec4 emissiveFactor;
#endif
#ifdef S_OCCLUSIONMAP
uniform sampler2D occlusionTex;
uniform float occlusionStrength;
#endif
#ifdef S_IBL
uniform samplerCube diffuseEnvCube;
uniform samplerCube specularEnvCube;
uniform sampler2D brdfLUT;
#endif
#ifdef S_VERTEX_COLOR
in vec4 vColor;
#endif

#pragma include "normalmap_incl.glsl"

vec4 SRGBtoLINEAR(vec4 srgbIn)
{
    #ifdef MANUAL_SRGB
    #ifdef SRGB_FAST_APPROXIMATION
    float gamma = 2.2;
    vec3 linOut = pow(srgbIn.xyz,vec3(gamma));
    #else //SRGB_FAST_APPROXIMATION
    vec3 bLess = step(vec3(0.04045),srgbIn.xyz);
    vec3 linOut = mix( srgbIn.xyz/vec3(12.92), pow((srgbIn.xyz+vec3(0.055))/vec3(1.055),vec3(2.4)), bLess );
    #endif //SRGB_FAST_APPROXIMATION
    return vec4(linOut,srgbIn.w);
    #else //MANUAL_SRGB
    return srgbIn;
    #endif //MANUAL_SRGB
}


// Encapsulate the various inputs used by the various functions in the shading equation
// We store values in this struct to simplify the integration of alternative implementations
// of the shading terms, outlined in the Readme.MD Appendix.
struct PBRInfo
{
    float NdotL;                  // cos angle between normal and light direction
    float NdotV;                  // cos angle between normal and view direction
    float NdotH;                  // cos angle between normal and half vector
    float LdotH;                  // cos angle between light direction and half vector
    float VdotH;                  // cos angle between view direction and half vector
    float perceptualRoughness;    // roughness value, as authored by the model creator (input to shader)
    float metalness;              // metallic value at the surface
    vec3 reflectance0;            // full reflectance color (normal incidence angle)
    vec3 reflectance90;           // reflectance color at grazing angle
    float alphaRoughness;         // roughness mapped to a more linear change in the roughness (proposed by [2])
    vec3 diffuseColor;            // color contribution from diffuse lighting
    vec3 specularColor;           // color contribution from specular lighting
};

const float M_PI = 3.141592653589793;
const float c_MinRoughness = 0.04;

// The following equation models the Fresnel reflectance term of the spec equation (aka F())
// Implementation of fresnel from [4], Equation 15
vec3 specularReflection(PBRInfo pbrInputs)
{
    return pbrInputs.reflectance0 + (pbrInputs.reflectance90 - pbrInputs.reflectance0) * pow(clamp(1.0 - pbrInputs.VdotH, 0.0, 1.0), 5.0);
}

// Basic Lambertian diffuse
// Implementation from Lambert's Photometria https://archive.org/details/lambertsphotome00lambgoog
// See also [1], Equation 1
vec3 diffuse(PBRInfo pbrInputs)
{
    return pbrInputs.diffuseColor / M_PI;
}

#ifdef S_IBL
// Calculation of the lighting contribution from an optional Image Based Light source.
// Precomputed Environment Maps are required uniform inputs and are computed as outlined in [1].
// See our README.md on Environment Maps [3] for additional discussion.
vec3 getIBLContribution(PBRInfo pbrInputs, vec3 n, vec3 reflection)
{
    float mipCount = 9.0; // resolution of 512x512
    float lod = (pbrInputs.perceptualRoughness * mipCount);
    // retrieve a scale and bias to F0. See [1], Figure 3
    vec3 brdf = SRGBtoLINEAR(texture(brdfLUT, vec2(pbrInputs.NdotV, 1.0 - pbrInputs.perceptualRoughness))).rgb;
    vec3 diffuseLight = SRGBtoLINEAR(texture(diffuseEnvCube, n)).rgb;

#ifdef S_USE_TEX_LOD
    vec3 specularLight = SRGBtoLINEAR(textureLod(specularEnvCube, reflection, lod)).rgb;
#else
    vec3 specularLight = SRGBtoLINEAR(texture(specularEnvCube, reflection)).rgb;
#endif

    vec3 diffuse = diffuseLight * pbrInputs.diffuseColor;
    vec3 specular = specularLight * (pbrInputs.specularColor * brdf.x + brdf.y);

    return diffuse + specular;
}
#endif

// This calculates the specular geometric attenuation (aka G()),
// where rougher material will reflect less light back to the viewer.
// This implementation is based on [1] Equation 4, and we adopt their modifications to
// alphaRoughness as input as originally proposed in [2].
float geometricOcclusion(PBRInfo pbrInputs)
{
    float NdotL = pbrInputs.NdotL;
    float NdotV = pbrInputs.NdotV;
    float r = pbrInputs.alphaRoughness;

    float attenuationL = 2.0 * NdotL / (NdotL + sqrt(r * r + (1.0 - r * r) * (NdotL * NdotL)));
    float attenuationV = 2.0 * NdotV / (NdotV + sqrt(r * r + (1.0 - r * r) * (NdotV * NdotV)));
    return attenuationL * attenuationV;
}

// The following equation(s) model the distribution of microfacet normals across the area being drawn (aka D())
// Implementation from "Average Irregularity Representation of a Roughened Surface for Ray Reflection" by T. S. Trowbridge, and K. P. Reitz
// Follows the distribution function recommended in the SIGGRAPH 2013 course notes from EPIC Games [1], Equation 3.
float microfacetDistribution(PBRInfo pbrInputs)
{
    float roughnessSq = pbrInputs.alphaRoughness * pbrInputs.alphaRoughness;
    float f = (pbrInputs.NdotH * roughnessSq - pbrInputs.NdotH) * pbrInputs.NdotH + 1.0;
    return roughnessSq / (M_PI * f * f);
}

void main(void)
{
    float perceptualRoughness = metallicRoughness.y;
    float metallic = metallicRoughness.x;

#ifdef S_METALROUGHNESSMAP
    // Roughness is stored in the 'g' channel, metallic is stored in the 'b' channel.
    // This layout intentionally reserves the 'r' channel for (optional) occlusion map data
    vec4 mrSample = texture(mrTex, vUV);
    perceptualRoughness = mrSample.g * perceptualRoughness;
    metallic = mrSample.b * metallic;
#endif
    perceptualRoughness = clamp(perceptualRoughness, c_MinRoughness, 1.0);
    metallic = clamp(metallic, 0.0, 1.0);
    // Roughness is authored as perceptual roughness; as is convention,
    // convert to material roughness by squaring the perceptual roughness [2].
    float alphaRoughness = perceptualRoughness * perceptualRoughness;

#ifndef S_NO_BASECOLORMAP
    vec4 baseColor = SRGBtoLINEAR(texture(tex, vUV)) * color;
#else
    vec4 baseColor = color;
#endif
#ifdef S_VERTEX_COLOR
    baseColor = baseColor * vColor;
#endif

    vec3 f0 = vec3(0.04);
    vec3 diffuseColor = baseColor.rgb * (vec3(1.0) - f0);
    diffuseColor *= 1.0 - metallic;
    vec3 specularColor = mix(f0, baseColor.rgb, metallic);

    // Compute reflectance.
    float reflectance = max(max(specularColor.r, specularColor.g), specularColor.b);

    // For typical incident reflectance range (between 4% to 100%) set the grazing reflectance to 100% for typical fresnel effect.
    // For very low reflectance range on highly diffuse objects (below 4%), incrementally reduce grazing reflectance to 0%.
    float reflectance90 = clamp(reflectance * 25.0, 0.0, 1.0);
    vec3 specularEnvironmentR0 = specularColor.rgb;
    vec3 specularEnvironmentR90 = vec3(1.0, 1.0, 1.0) * reflectance90;
    vec3 color = vec3(0.0,0.0,0.0);
    vec3 n = getNormal();                             // Normal at surface point
    vec3 v = normalize(g_cameraPos.xyz - vWsPos.xyz); // Vector from surface point to camera
    for (int i=0;i<SI_LIGHTS;i++) {
        vec3 l = normalize(vLightDir[i]);                 // Vector from surface point to light
        vec3 h = normalize(l+v);                          // Half vector between both l and v
        vec3 reflection = -normalize(reflect(v, n));

        float NdotL = clamp(dot(n, l), 0.0001, 1.0);
        float NdotV = abs(dot(n, v)) + 0.0001;
        float NdotH = clamp(dot(n, h), 0.0, 1.0);
        float LdotH = clamp(dot(l, h), 0.0, 1.0);
        float VdotH = clamp(dot(v, h), 0.0, 1.0);

        PBRInfo pbrInputs = PBRInfo(
            NdotL,
            NdotV,
            NdotH,
            LdotH,
            VdotH,
            perceptualRoughness,
            metallic,
            specularEnvironmentR0,
            specularEnvironmentR90,
            alphaRoughness,
            diffuseColor,
            specularColor
        );

        // Calculate the shading terms for the microfacet specular shading model
        vec3 F = specularReflection(pbrInputs);
        float G = geometricOcclusion(pbrInputs);
        float D = microfacetDistribution(pbrInputs);

        // Calculation of analytical lighting contribution
        vec3 diffuseContrib = (1.0 - F) * diffuse(pbrInputs);
        vec3 specContrib = F * G * D / (4.0 * NdotL * NdotV);
        color += NdotL * g_lightColorRange[i].xyz * (diffuseContrib + specContrib);
    }

    // Calculate lighting contribution from image based lighting source (IBL)
#ifdef S_IBL
    color += getIBLContribution(pbrInputs, n, reflection);
#endif
    // Apply optional PBR terms for additional (optional) shading
#ifdef S_OCCLUSIONMAP
    float ao = texture(occlusionTex, vUV).r;
    color = mix(color, color * ao, occlusionStrength);
#endif
#ifdef S_EMISSIVEMAP
    vec3 emissive = SRGBtoLINEAR(texture(emissiveTex, vUV)).rgb * emissiveFactor.xyz;
    color += emissive;
#endif
#ifdef SI_FRAMEBUFFER_SRGB
    fragColor = vec4(color,baseColor.a);
#else
    float gamma = 2.2;
    fragColor = vec4(pow(color,vec3(1.0/gamma)), baseColor.a); // gamma correction
#endif

}