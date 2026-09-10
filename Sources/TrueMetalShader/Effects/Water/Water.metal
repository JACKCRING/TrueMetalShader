//
//  Water.metal
//  TrueMetalShader
//
//  水面（water surface）后处理着色器 —— “透明杯子里的水”切面效果。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  把该图层当成一个装水的容器：
//
//  - 容器里有一条“水位线”，其角度由重力方向 `gravity` 决定（重力往哪边斜，
//    水位线就往哪边倾斜，就像端着一杯水去晃），水位高低由 `level` 决定；
//  - 水位线上叠加三层不同方向/频率的正弦波，做出水面的晃动/波纹；
//  - 水位线以下：按波浪坡度做折射位移，并按深度加重水色（水越深越沉、
//    吸光越多）；
//  - 水位线以上：原样透出（杯子里的“空气”部分不处理）；
//  - 水位线附近：一条高光/泡沫细线，是“看到水面”的关键视觉线索。
//
//  “水位线随重力晃”不是本文件的事——這裡 `gravity` 只是输入向量，
//  保证着色器本身跨平台、无传感器依赖。真正“接手机重力、带过冲回弹”的
//  体验由 Swift 侧的 `WaterGravitySource`（仅 iOS，见 WaterMotion.swift）
//  驱动，本着色器只管“给定一个重力方向该长什么样”。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀，避免与宿主 App
//  或其它库的着色器函数重名（它们最终都在同一个 default.metallib 里）。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 水位线在“沿重力方向”上的波浪扰动（像素单位）：三层不同方向/频率/相位的
// 正弦波叠加，避免看起来像规则的正弦布纹，用切向坐标 tCoord 驱动。
static inline float tms_waterWave(float tCoord,
                                   float time,
                                   float amplitude,
                                   float frequency,
                                   float speed) {
    float w = 0.0;
    w += amplitude * 0.55 * sin(tCoord * (frequency * 0.030) + time * speed * 1.30);
    w += amplitude * 0.30 * sin(tCoord * (frequency * 0.070) + time * speed * 0.85 + 1.7);
    w += amplitude * 0.15 * sin(tCoord * (frequency * 0.130) + time * speed * 2.10 + 3.1);
    return w;
}

[[stitchable]] half4 tms_water(float2 position,
                               SwiftUI::Layer layer,
                               float time,
                               float2 size,
                               float2 gravity,
                               float level,
                               float waveAmplitude,
                               float waveFrequency,
                               float waveSpeed,
                               float refractionStrength,
                               half4 tintColor,
                               half4 foamColor,
                               float foamWidth) {
    // 重力方向（“下”），退化时兜底为正下方，避免除零。
    float2 g = length(gravity) > 0.0001 ? normalize(gravity) : float2(0.0, 1.0);
    // 切向：与重力垂直，水位线沿这个方向延展。
    float2 t = float2(-g.y, g.x);

    // 把容器的四个角投影到重力轴上，得到这个视图沿“下”方向的范围，
    // 用来把 position 换算成“在容器里有多深”的 0...1 比例，以及把
    // 像素振幅换算成同一量纲，这样容器旋转（重力转向）时水位线跟着转。
    float2 corners[4] = { float2(0.0, 0.0), float2(size.x, 0.0),
                          float2(0.0, size.y), float2(size.x, size.y) };
    float minP = dot(corners[0], g);
    float maxP = minP;
    for (int i = 1; i < 4; i++) {
        float p = dot(corners[i], g);
        minP = min(minP, p);
        maxP = max(maxP, p);
    }
    float extent = max(maxP - minP, 1.0);

    // 静止水位线（不含波浪）在重力轴上的投影值：level=1 → 贴着“最高处”
    // （几乎全是水）；level=0 → 贴着“最低处”（几乎全是空气）。
    float restLine = maxP - level * extent;

    // 该像素沿切向的坐标，驱动水位线的波浪扰动。
    float tCoord = dot(position, t);
    float wave = tms_waterWave(tCoord, time, waveAmplitude, waveFrequency, waveSpeed);

    // 该像素处“真实”水位线在重力轴上的投影值，以及该像素与它的距离
    // （沿重力轴，>0 = 在水位线下方 = 水里，单位：像素）。
    float boundary = restLine + wave;
    float depth = dot(position, g) - boundary;

    // 用有限差分求水位线的切向斜率，作为折射的位移方向：水面越陡，
    // 光线被“掰”得越厉害。
    const float eps = 1.0;
    float waveNext = tms_waterWave(tCoord + eps, time, waveAmplitude, waveFrequency, waveSpeed);
    float slope = (waveNext - wave) / eps;
    float2 disp = t * slope * refractionStrength;

    // --- 空气侧：原样透出 ---
    half4 airSample = layer.sample(position);
    half3 airStraight = airSample.a > 0.001h ? half3(airSample.rgb / airSample.a) : half3(0.0h);

    // --- 水侧：折射采样 + 按深度加重水色 ---
    half4 waterSample = layer.sample(position + disp);
    half3 waterStraight = waterSample.a > 0.001h ? half3(waterSample.rgb / waterSample.a) : half3(0.0h);

    float depthFrac = saturate(depth / extent);           // 0（刚过水位线）...1（容器底部）
    half tintMix = half(saturate(0.35 + depthFrac * 0.55)) * half(tintColor.a);
    half3 tinted = mix(waterStraight, tintColor.rgb, tintMix);
    tinted *= half(1.0 - depthFrac * 0.30);                // 越深越暗，模拟吸光

    // --- 按 depth 做水/空气的锐利过渡（用 fwidth 收成 ~1px 抗锯齿边） ---
    float aa = fwidth(depth) + 0.6;
    half underwater = half(smoothstep(-aa, aa, depth));
    half3 body = mix(airStraight, tinted, underwater);

    // --- 水位线高光/泡沫细线：贴着 depth == 0 的一条窄带，两侧都露一点 ---
    half foamBand = half(1.0 - smoothstep(0.0, max(foamWidth, 0.5), abs(depth)));
    half3 result = mix(body, half3(foamColor.rgb), foamBand * half(foamColor.a));

    // --- 输出 alpha：用未位移采样的 alpha，保持容器轮廓不被折射带偏 ---
    half a = airSample.a;
    result = clamp(result, 0.0h, 1.0h);
    return half4(result * a, a);
}
