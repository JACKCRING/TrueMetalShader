//
//  Water.metal
//  TrueMetalShader
//
//  水面（water surface）后处理着色器 —— “透明杯子里的水”切面效果。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  把该图层当成一个装水的容器。参考真实水下摄影的三个关键视觉线索来做：
//
//  1. 水面不是一条细线，而是一条“有厚度的紊乱大理石纹路带”——用 fbm
//     （分形布朗运动噪声）驱动，蓝白花纹随水面晃动而流动，遮住带内的
//     容器内容（水面本身不透明，你看不穿水面看到水下）；
//  2. 水下折射用噪声域扭曲（domain warp），而不是规则正弦波——规则正弦
//     波位移出来的效果像布料在抖，噪声驱动的形变才像水的紊乱感；
//  3. 水下叠加方向性的“光束状”焦散条纹（沿重力轴拉伸的 fbm），随时间
//     缓慢滑动、随水面扰动一起摆动，越靠近水面越亮，模拟阳光透过水面
//     折射出的光斑网。
//
//  “水位线角度随重力晃”不是本文件的事——这里 `gravity` 只是输入向量，
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

// --- 基础噪声：hash → value noise → fbm ---
// 标准“便宜噪声”三部曲，用于制造紊乱但连续的花纹（水面大理石纹、
// 焦散光束、折射扭曲都基于它），不追求物理精确，只求视觉可信。

static inline float tms_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float tms_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = tms_hash(i);
    float b = tms_hash(i + float2(1.0, 0.0));
    float c = tms_hash(i + float2(0.0, 1.0));
    float d = tms_hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);   // smoothstep 插值，避免格子感
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 4 阶 fbm，每阶旋转一点角度再放大频率，避免噪声呈现出轴对齐的条纹感。
static inline float tms_fbm(float2 p) {
    float sum = 0.0;
    float amp = 0.5;
    const float2x2 rot = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
    for (int i = 0; i < 4; i++) {
        sum += amp * tms_noise(p);
        p = rot * p * 2.02;
        amp *= 0.5;
    }
    return sum; // 大致落在 0...1
}

// 水位线高度场：低频正弦“大浪”（让整体随重力平滑起伏）+ fbm 紊乱层
// （水面真正的花纹感来源）叠加。tCoord 是沿切向的坐标，time 驱动流动。
static inline float tms_waterHeight(float tCoord,
                                     float time,
                                     float amplitude,
                                     float frequency,
                                     float speed) {
    float swell = sin(tCoord * (frequency * 0.020) + time * speed * 1.10) * 0.55
                + sin(tCoord * (frequency * 0.045) + time * speed * 0.70 + 2.0) * 0.30;
    float turbulence = tms_fbm(float2(tCoord * frequency * 0.012, time * speed * 0.30)) - 0.5;
    return amplitude * (swell * 0.7 + turbulence * 1.8);
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
                               float turbulenceWidth,
                               float bodyOpacity,
                               float highlightIntensity,
                               float causticIntensity) {
    // 重力方向（“下”），退化时兜底为正下方，避免除零。
    float2 g = length(gravity) > 0.0001 ? normalize(gravity) : float2(0.0, 1.0);
    // 切向：与重力垂直，水位线沿这个方向延展。
    float2 t = float2(-g.y, g.x);

    // 把容器四角投影到重力轴上，得到这个视图沿“下”方向的范围，用来把
    // 位置换算成“容器里有多深”的比例，容器旋转（重力转向）时水位线跟着转。
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

    // 静止水位线（不含波浪/紊乱）在重力轴上的投影：level=1 → 贴着最高处
    // （几乎全是水），level=0 → 贴着最低处（几乎全是空气）。
    float restLine = maxP - level * extent;

    float tCoord = dot(position, t);
    float wave = tms_waterHeight(tCoord, time, waveAmplitude, waveFrequency, waveSpeed);
    float boundary = restLine + wave;
    float depth = dot(position, g) - boundary;              // >0 = 水里（沿重力轴，像素）
    float depthFrac = saturate(depth / (extent * 0.6));      // 0（刚过水位线）...1（够深）

    // 有限差分求高度场的切向斜率，得到“水面法线”（用于高光 + 边界弯折）。
    const float eps = 1.0;
    float waveNext = tms_waterHeight(tCoord + eps, time, waveAmplitude, waveFrequency, waveSpeed);
    float slope = (waveNext - wave) / eps;
    float2 normal = normalize(t * (-slope) - g);

    // --- 噪声域扭曲（domain warp）：整张水下区域的折射位移都基于这个
    //     流动的噪声场，而不是规则正弦——这是“看起来紊乱像水”的关键。
    float2 flowP = position * 0.014 + float2(time * 0.12, -time * 0.08);
    float n1 = tms_fbm(flowP) - 0.5;
    float n2 = tms_fbm(flowP + float2(5.2, 1.3)) - 0.5;
    float2 warp = float2(n1, n2) * 2.0;

    // 折射位移 = 边界弯折（沿切向） + 噪声紊乱形变，两者叠加。
    float2 disp = (t * slope * 0.6 + warp) * refractionStrength;

    // --- 原始图层采样：既判断“容器形状”，也用作空气侧内容 ---
    half4 airSample = layer.sample(position);
    half3 airStraight = airSample.a > 0.001h ? half3(airSample.rgb / airSample.a) : half3(0.0h);

    // 容器形状遮罩：只看 alpha 是否“存在”，与容器实际画得多透明无关——
    // 这样低透明度的“玻璃杯”轮廓依然能让水体不透明地显示。
    float shapeAA = fwidth(float(airSample.a)) + 0.0006;
    float shapeMask = smoothstep(0.0002 - shapeAA, 0.0002 + shapeAA, float(airSample.a));

    // --- 水侧：噪声扭曲后的折射采样 ---
    half4 waterSample = layer.sample(position + disp);
    half3 waterStraight = waterSample.a > 0.001h ? half3(waterSample.rgb / waterSample.a) : half3(0.0h);

    // 水色：越深叠得越浓 + 略微吸光变暗，但始终透一点被折射的内容。
    half tintMix = half(saturate(0.45 + depthFrac * 0.4));
    half3 body = mix(waterStraight, tintColor.rgb, tintMix);
    body *= half(1.0 - depthFrac * 0.22);

    // --- 方向性焦散光束：沿重力轴拉伸采样噪声（各向异性），模拟阳光
    //     透过起伏水面折射出的光束网；用 warp 让光束跟着水面扰动摆动，
    //     离水面越近越亮，随深度逐渐减弱但不会完全消失。
    float2 rayP = float2(tCoord * 0.010 + n1 * 1.5,
                         (dot(position, g) - boundary) * 0.006 - time * waveSpeed * 0.35 + n2 * 1.5);
    float rayField = tms_fbm(rayP);
    float rays = pow(saturate(rayField * 1.3 - 0.25), 3.0);
    float rayFalloff = saturate(1.0 - depthFrac * 0.55);
    half caustic = half(rays * rayFalloff * causticIntensity);
    body += half3(caustic, caustic * 1.05h, caustic * 1.1h); // 焦散略偏冷白

    // --- 波面高光：法线越贴合固定光方向越亮，只在贴近水面的浅层出现 ---
    float2 lightDir = normalize(float2(-0.35, -0.9));
    float surfaceBand = 1.0 - saturate(depth / (waveAmplitude * 3.0 + 10.0));
    float spec = pow(saturate(dot(normal, -lightDir) * 0.5 + 0.5), 8.0) * surfaceBand;
    body += half3(spec * highlightIntensity);

    body = clamp(body, 0.0h, 1.0h);

    // --- 水/空气过渡（用 fwidth 收成 ~1px 抗锯齿边）---
    float aa = fwidth(depth) + 0.6;
    half underwater = half(smoothstep(-aa, aa, depth));
    half3 tintedColor = mix(airStraight, body, underwater);

    // --- 表层紊乱大理石纹路带：贴着 depth ≈ 0 的一条“有厚度的带”，
    //     用高频 fbm + 上面的 warp 再扭一下做出花纹，蓝白花纹混合，
    //     几乎完全遮住带内容——这是“看得出是水面”而不是“一条描边”的
    //     关键，宽度由 turbulenceWidth 控制，带的下边缘用 smoothstep
    //     羽化过渡回清澈水体。
    float bandWidth = max(turbulenceWidth, 1.0);
    float bandTop = -bandWidth * 0.25;                 // 带略微往水面上方露一点
    float bandBottom = bandWidth * 0.75;
    float bandMask = smoothstep(bandTop - aa, bandTop + aa, depth)
                    * (1.0 - smoothstep(bandBottom - bandWidth * 0.4, bandBottom + bandWidth * 0.4, depth));

    float2 marbleP = position * 0.05 + warp * 2.5 + float2(time * 0.25, time * 0.12);
    float marble = tms_fbm(marbleP);
    float marbleVein = tms_fbm(marbleP * 2.3 + 4.0);
    half3 deepMarble = half3(tintColor.rgb) * 0.7h;
    half3 lightMarble = mix(half3(foamColor.rgb), half3(0.75, 0.9, 1.0), 0.4h);
    half3 marbleColor = mix(deepMarble, lightMarble, half(smoothstep(0.35, 0.75, marble)));
    marbleColor = mix(marbleColor, half3(1.0h), half(smoothstep(0.75, 0.95, marbleVein)) * 0.5h);

    half3 result = mix(tintedColor, marbleColor, half(bandMask) * half(underwater));

    // --- 输出 alpha：空气侧沿用容器原本的透明度；水侧（含表层带）独立
    //     用 bodyOpacity，都乘上“容器形状遮罩”，保证水不会溢出容器轮廓 ---
    half waterAlpha = half(saturate(bodyOpacity * (0.7 + depthFrac * 0.3)));
    waterAlpha = max(waterAlpha, half(bandMask) * half(saturate(bodyOpacity * 1.3)));
    half a = half(shapeMask) * mix(airSample.a, max(airSample.a, waterAlpha), underwater);

    result = clamp(result, 0.0h, 1.0h);
    return half4(result * a, a);
}
