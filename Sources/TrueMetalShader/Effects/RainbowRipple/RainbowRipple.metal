//
//  RainbowRipple.metal
//  TrueMetalShader
//
//  彩虹水波纹（rainbow ripple）后处理着色器。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上：
//  从一个点击点(origin)向外扩散一圈圈水波，并带彩虹色散描边。
//
//  原理（径向水波 + 色散）：
//  1. 算当前像素到波源的距离 dist；波要“走”到这里需要 dist/speed 的延迟，
//     所以有效时间 t = max(0, time - dist/speed) —— 这就形成了向外扩散的圆环。
//  2. 用阻尼正弦 amplitude * sin(freq*t) * exp(-decay*t) 得到该像素的起伏量，
//     沿半径方向对采样位置做位移（径向置换）→ 水面被波纹推挤的效果。
//  3. R/G/B 三通道用略有差异的位移量采样 → 波纹边缘的彩虹描边（色散）；
//     再按到圆心的距离叠加同心彩虹色。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀，避免与宿主 App
//  或其它库的着色器函数重名（它们最终都在同一个 default.metallib 里）。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 便宜的彩虹调色板（余弦渐变，Inigo Quilez 风格）。t 在 0...1 循环一圈色相。
// 注：static inline = 内部链接，与其它 .metal 里同名的辅助函数互不冲突。
static inline half3 tms_rippleRainbow(float t) {
    float3 c = 0.5 + 0.5 * cos(6.28318530718 * (float3(0.00, 0.33, 0.67) + t));
    return half3(c);
}

[[stitchable]] half4 tms_rainbowRipple(float2 position,
                                       SwiftUI::Layer layer,
                                       float2 origin,
                                       float time,
                                       float amplitude,
                                       float frequency,
                                       float decay,
                                       float speed,
                                       float chromaSpread,
                                       float rainbowIntensity) {
    // 到波源的距离 → 波纹到达该像素的延迟，形成向外扩散的圆环。
    float dist = length(position - origin);
    float delay = dist / max(speed, 1.0);
    float t = max(0.0, time - delay);

    // 阻尼正弦：振幅随时间指数衰减 → 一圈圈逐渐消失的水波。
    float rippleAmount = amplitude * sin(frequency * t) * exp(-decay * t);

    // 沿半径方向做位移（径向置换）。
    float2 dir = dist > 0.0001 ? (position - origin) / dist : float2(0.0);
    float2 disp = dir * rippleAmount;

    // 色散：R/G/B 沿位移方向用略有差异的幅度采样 → 波纹边缘的彩虹描边。
    half4 sr = layer.sample(position + disp * (1.0 + chromaSpread));
    half4 sg = layer.sample(position + disp);
    half4 sb = layer.sample(position + disp * (1.0 - chromaSpread));

    // layer 采样为预乘 alpha：先各自还原成直通颜色，避免边缘因 alpha 变小而发暗。
    half3 straight;
    straight.r = sr.a > 0.001h ? sr.r / sr.a : 0.0h;
    straight.g = sg.a > 0.001h ? sg.g / sg.a : 0.0h;
    straight.b = sb.a > 0.001h ? sb.b / sb.a : 0.0h;
    half a = sg.a;                                   // 用中心（绿）通道的 alpha 定形状

    // 归一化波形（-1...1）：用于明暗立体感 + 彩虹强度调制。
    float wave = rippleAmount / max(amplitude, 0.0001);

    // 原版水波的高光/阴影：波峰略亮、波谷略暗，产生水面起伏的立体感。
    straight += half(0.3 * wave);

    // 同心彩虹环：色相随“到圆心的距离”变化，并随时间向外滚动；
    // 只在有波动的地方（|wave| 大）叠加，静止区域保持原样。
    float hue = fract(dist * 0.004 - time * 0.4);
    half3 tint = tms_rippleRainbow(hue);
    half rainbow = half(abs(wave)) * half(rainbowIntensity);
    straight = clamp(straight + tint * rainbow, 0.0h, 1.0h);

    // 重新按输出 alpha 预乘返回，保持与 SwiftUI 图层一致的预乘语义。
    return half4(straight * a, a);
}
