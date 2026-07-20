//
//  Metaball.metal
//  TrueMetalShader
//
//  融合（gooey / metaball）后处理着色器。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  因此可以包裹 Circle / Rectangle / Text / 图片 等任何内容。
//
//  原理：调用方先对内容做 `.blur`（让相邻形状的 alpha 光晕重叠），
//  本着色器再对 alpha 做平滑阈值(smoothstep) —— 重叠处一起越过阈值，
//  于是形状“粘”在一起，形成融球/黏液效果。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀，避免与宿主 App
//  或其它库的着色器函数重名（它们最终都在同一个 default.metallib 里）。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

[[stitchable]] half4 tms_metaball(float2 position,
                                  SwiftUI::Layer layer,
                                  float threshold,
                                  float softness) {
    half4 c = layer.sample(position);
    half a = c.a;

    // 关键：用 fwidth(a) 得到“每像素 alpha 变化量”，据此把阈值过渡收成 ~1px。
    // 这样无论模糊半径多大，边缘都锐利（实心融球感），只在 1px 内做抗锯齿。
    // softness 是额外的手动羽化（默认 0），想要更柔的边可以调大。
    half aa = fwidth(a) + half(softness) + 0.0008h;
    half lo = half(threshold) - aa;
    half hi = half(threshold) + aa;
    half edge = smoothstep(lo, hi, a);   // alpha 越过阈值的程度

    if (edge <= 0.0h) {
        return half4(0.0h);              // 阈值以下：完全透明
    }

    // layer 采样为预乘 alpha。先还原直通颜色，再按新 alpha 重新预乘，
    // 避免模糊后的边缘因为 alpha 变小而发暗。
    half3 straight = a > 0.001h ? c.rgb / a : c.rgb;
    return half4(straight * edge, edge);
}
