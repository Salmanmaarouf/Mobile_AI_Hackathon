#include <metal_stdlib>
using namespace metal;

// Gentle water ripple for the lower (lake) portion of the background image.
// `horizonY` (0...1, fraction of image height) marks where the ripple fades
// in — the sky/mountains above it stay undistorted. The primary wave uses
// an angular frequency of 2π/4s to match the orb's 4-second breathing cycle.
[[ stitchable ]] float2 waterRipple(float2 position, float2 size, float time, float amplitude, float horizonY) {
    float2 uv = position / size;
    float belowHorizon = smoothstep(horizonY, horizonY + 0.08, uv.y);

    float wave = sin(uv.x * 22.0 + time * 1.5708) * amplitude;
    wave += sin(uv.x * 9.0 - time * 0.7854) * amplitude * 0.5;

    return position + float2(0.0, wave * belowHorizon);
}
