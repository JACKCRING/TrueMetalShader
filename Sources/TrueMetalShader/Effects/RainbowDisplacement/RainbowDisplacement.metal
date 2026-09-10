//
//  RainbowDisplacement.metal
//  TrueMetalShader
//
//  彩虹置换（rainbow displacement / 色散）后处理着色器。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  因此可以作用于 Circle / Rectangle / Text / 图片 等任何内容。
//
//  原理：
//  1. 用一条沿固定方向传播的正弦波，按像素位置算出一个“置换偏移量”
//     （dot(position, dir) 让偏移随位置流动，所以无需指定原点，作用于整张图）。
//  2. R / G / B 三个通道用略有差异的偏移量分别采样 —— 通道错位就形成了
//     彩虹描边（chromatic aberration，即“色散”）。
//  3. 再叠一层随相位流动的彩虹色（screen 混合），强化“彩虹”观感。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀，避免与宿主 App
//  或其它库的着色器函数重名（它们最终都在同一个 default.metallib 里）。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 便宜的彩虹调色板（余弦渐变，Inigo Quilez 风格）。t 在 0...1 循环一圈色相。
static inline half3 tms_rainbow(float t) {
    float3 c = 0.5 + 0.5 * cos(6.28318530718 * (float3(0.00, 0.33, 0.67) + t));
    return half3(c);
}

[[stitchable]] half4 tms_rainbowDisplace(float2 position,
                                         SwiftUI::Layer layer,
                                         float time,
                                         float strength,
                                         float frequency,
                                         float chromaSpread,
                                         float rainbowIntensity) {
    // 沿固定方向传播的正弦波 → 置换偏移量。dot(position, dir) 让偏移随位置变化，
    // 因此作用于任意内容、无需指定原点；减去 time 让波纹随时间流动。
    float2 dir = normalize(float2(0.7, 0.3));
    float phase = dot(position, dir) * (frequency * 0.01) - time;
    float2 offset = float2(sin(phase), cos(phase)) * strength;

    // 色散：R/G/B 三通道用略微不同的位移量采样 → 彩虹描边。
    half4 sr = layer.sample(position + offset * (1.0 + chromaSpread));
    half4 sg = layer.sample(position + offset);
    half4 sb = layer.sample(position + offset * (1.0 - chromaSpread));

    // layer 采样为预乘 alpha：先各自还原成直通颜色，避免边缘因 alpha 变小而发暗。
    half3 straight;
    straight.r = sr.a > 0.001h ? sr.r / sr.a : 0.0h;
    straight.g = sg.a > 0.001h ? sg.g / sg.a : 0.0h;
    straight.b = sb.a > 0.001h ? sb.b / sb.a : 0.0h;
    half a = sg.a;                                   // 用中心（绿）通道的 alpha 定形状

    // 叠加一层随相位流动的彩虹色（screen 混合），增强“彩虹”观感。
    float hue = fract(phase / 6.28318530718 + 0.5);
    half3 tint = tms_rainbow(hue) * half(rainbowIntensity);
    half3 mixed = 1.0h - (1.0h - straight) * (1.0h - tint);

    // 重新按输出 alpha 预乘返回，保持与 SwiftUI 图层一致的预乘语义。
    return half4(mixed * a, a);
}
