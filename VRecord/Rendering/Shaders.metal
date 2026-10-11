#include <metal_stdlib>
using namespace metal;

struct CameraRasterData {
    float4 position [[position]];
    float2 textureCoordinate;
};

// A single oversized triangle covers the viewport without a diagonal seam.
vertex CameraRasterData vrecord_camera_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(-1.0, 3.0), float2(3.0, -1.0) };
    float2 p = positions[vertexID];
    CameraRasterData result;
    result.position = float4(p, 0.0, 1.0);
    // Camera buffers already have their physical landscape orientation applied.
    result.textureCoordinate = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return result;
}

fragment float4 vrecord_camera_fragment(CameraRasterData in [[stage_in]],
                                       texture2d<float> image [[texture(0)]],
                                       constant float4 &crop [[buffer(0)]]) {
    constexpr sampler cameraSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(cameraSampler, crop.xy + in.textureCoordinate * crop.zw).rgb, 1.0);
}

// Matches Swift's SIMD2<Float> followed by SIMD4<Float>: 32 byte stride.
struct SkeletonVertex {
    float2 position;
    float4 color;
};

struct SkeletonRasterData {
    float4 position [[position]];
    float4 color;
};

vertex SkeletonRasterData vrecord_skeleton_vertex(uint vertexID [[vertex_id]],
                                                  const device SkeletonVertex *vertices [[buffer(0)]]) {
    SkeletonRasterData result;
    result.position = float4(vertices[vertexID].position, 0.0, 1.0);
    result.color = vertices[vertexID].color;
    return result;
}

fragment float4 vrecord_skeleton_fragment(SkeletonRasterData in [[stage_in]]) {
    return in.color;
}

struct IndicatorRasterData {
    float4 position [[position]];
    float2 local;
};

vertex IndicatorRasterData vrecord_indicator_vertex(uint vertexID [[vertex_id]],
                                                    constant float4 &circle [[buffer(0)]]) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    IndicatorRasterData result;
    result.local = corners[vertexID];
    result.position = float4(circle.xy + result.local * circle.zw, 0, 1);
    return result;
}

fragment float4 vrecord_indicator_fragment(IndicatorRasterData in [[stage_in]]) {
    float distance = length(in.local);
    float coverage = 1.0 - smoothstep(1.0 - fwidth(distance), 1.0, distance);
    if (coverage <= 0) discard_fragment();
    return float4(1.0, 0.0, 0.0, 0.72 * coverage);
}
