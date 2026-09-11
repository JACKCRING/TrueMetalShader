//
//  Water.metal
//  TrueMetalShader
//
//  水面（water surface）后处理着色器 —— “透明杯子里的水”切面效果。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  把该图层当成一个装水的容器。参考真实“手机端着一杯水”的观感——水面
//  几乎是一条平滑的倾斜直线（随重力倾斜），只有很轻微的起伏，边缘是
//  柔和模糊的过渡（不是锐利描边），水面附近有一层淡淡的渐变高光：
//
//  - 水位线角度随重力倾斜，叠加一层极轻微、低频的起伏（不是夸张的波浪，
//    更不能是高频噪声——那样会变成锯齿山峰，不是水面）；
//  - 边界用较宽的 smoothstep 做柔和过渡（`softness` 控制），呈现雾化
//    玻璃后面看水的那种模糊感，而不是刀切般的锐利线；
//  - 水下用很轻微的噪声域扭曲做折射，强度远小于之前版本；折射 + 色散
//    的强度都随离水面的距离指数衰减（`refractionRange` 控制衰减范围）——
//    贴近水面能看清被水面扭曲、带彩边的画面，深一点就只剩平淡的水色，
//    这也更符合真实水光学（越深越难透光看清上方内容）；
//  - 色散：R/G/B 通道用略有差异的位移量采样（`chromaSpread` 控制强度），
//    强度同样随深度衰减，只在贴近水面处出现彩边，模拟光线穿过水面时
//    因波长不同而略微分离的效果；
//  - 水面附近一条淡淡的渐变高光带，模拟表面反光；
//  - 水的不透明度独立于容器原始透明度（`bodyOpacity`），因此即便容器
//    本身画得很淡（近乎透明的玻璃轮廓），水依然清晰可见。
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

// --- 基础噪声：hash → value noise ---
// 只用一层 value noise（不叠 fbm 多阶），保持够“轻”，避免高频细节
// 把平滑的水面轮廓搞成锯齿。

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

// 水位线边界高度场：只负责“轮廓形状”，必须是一条平滑、近乎直的曲线——
// 单一低频正弦（一整个视图宽度大约看到不到一个完整波峰）+ 极轻微的
// 低频噪声，两者振幅都很小，避免出现多个尖峰。tCoord 是沿切向的坐标，
// time 驱动缓慢流动。
static inline float tms_waterHeight(float tCoord,
                                     float time,
                                     float amplitude,
                                     float frequency,
                                     float speed) {
    float swell = sin(tCoord * (frequency * 0.006) + time * speed * 0.6);
    float wobble = tms_noise(float2(tCoord * frequency * 0.004, time * speed * 0.15)) - 0.5;
    return amplitude * (swell * 0.7 + wobble * 0.6);
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
                               half4 highlightColor,
                               float softness,
                               float bodyOpacity,
                               float highlightIntensity,
                               float chromaSpread,
                               float refractionRange) {
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

    // 静止水位线（不含起伏）在重力轴上的投影：level=1 → 贴着最高处
    // （几乎全是水），level=0 → 贴着最低处（几乎全是空气）。
    float restLine = maxP - level * extent;

    float tCoord = dot(position, t);
    float wave = tms_waterHeight(tCoord, time, waveAmplitude, waveFrequency, waveSpeed);
    float boundary = restLine + wave;
    float depth = dot(position, g) - boundary;              // >0 = 水里（沿重力轴，像素）
    float depthFrac = saturate(depth / (extent * 0.6));      // 0（刚过水位线）...1（够深）

    // 有限差分求高度场的切向斜率，得到“水面法线”（用于高光 + 轻微折射）。
    const float eps = 1.0;
    float waveNext = tms_waterHeight(tCoord + eps, time, waveAmplitude, waveFrequency, waveSpeed);
    float slope = (waveNext - wave) / eps;
    float2 normal = normalize(t * (-slope) - g);

    // --- 轻微噪声域扭曲：强度刻意压得很小，只是让水下内容有一点点
    //     “隔着水看”的浮动感，不是强烈的紊乱形变。 ---
    float2 flowP = position * 0.006 + float2(time * 0.05, -time * 0.03);
    float n1 = tms_noise(flowP) - 0.5;
    float n2 = tms_noise(flowP + float2(5.2, 1.3)) - 0.5;
    float2 warp = float2(n1, n2) * 3.0;

    // 折射/色散强度随离水面距离指数衰减：贴近水面（depth 小）时接近 1，
    // 越往深处越接近 0——只有靠近水面才能看清被扭曲、带彩边的画面，
    // 深处基本看不透，这也是真实水下光学的样子。
    float nearSurface = exp(-max(depth, 0.0) / max(refractionRange, 1.0));
    float2 disp = (t * slope * 0.5 + warp) * refractionStrength * nearSurface;

    // --- 原始图层采样：既判断“容器形状”，也用作空气侧内容 ---
    half4 airSample = layer.sample(position);
    half3 airStraight = airSample.a > 0.001h ? half3(airSample.rgb / airSample.a) : half3(0.0h);

    // 容器形状遮罩：只看 alpha 是否“存在”，与容器实际画得多透明无关——
    // 这样低透明度的“玻璃杯”轮廓依然能让水体不透明地显示。
    float shapeAA = fwidth(float(airSample.a)) + 0.0006;
    float shapeMask = smoothstep(0.0002 - shapeAA, 0.0002 + shapeAA, float(airSample.a));

    // --- 水侧：轻微扭曲后的折射采样，R/G/B 用略有差异的位移量分别采样
    //     做色散（chromatic aberration），色散幅度也随 nearSurface 衰减，
    //     只在贴近水面处出现彩边。 ---
    float chroma = chromaSpread * nearSurface;
    half4 sr = layer.sample(position + disp * (1.0 + chroma));
    half4 sg = layer.sample(position + disp);
    half4 sb = layer.sample(position + disp * (1.0 - chroma));
    half3 waterStraight;
    waterStraight.r = sr.a > 0.001h ? half(sr.r / sr.a) : 0.0h;
    waterStraight.g = sg.a > 0.001h ? half(sg.g / sg.a) : 0.0h;
    waterStraight.b = sb.a > 0.001h ? half(sb.b / sb.a) : 0.0h;

    // 水色：贴近水面时只叠很淡的一层（这样被折射/色散的下层内容清晰
    // 可见），随深度增加逐渐叠浓，够深处基本被水色盖住看不透。
    half tintMix = half(saturate(0.12 + depthFrac * 0.75));
    half3 body = mix(waterStraight, tintColor.rgb, tintMix);
    body *= half(1.0 - depthFrac * 0.20);

    // --- 表面渐变高光：贴着水面一条柔和的亮带，随深度快速衰减，
    //     法线越贴合固定光方向越亮，模拟水面附近淡淡的反光渐变
    //     （不是花纹、不是描边，只是一层柔和的亮度渐变）。
    float2 lightDir = normalize(float2(-0.3, -0.95));
    float surfaceBand = exp(-max(depth, 0.0) / max(extent * 0.18, 8.0));
    float spec = (dot(normal, -lightDir) * 0.5 + 0.5);
    body += half3(surfaceBand * spec * highlightIntensity) * half3(highlightColor.rgb);

    body = clamp(body, 0.0h, 1.0h);

    // --- 水/空气的柔和过渡：用较宽的 softness 做模糊边界（而不是锐利
    //     的 1px 抗锯齿），呈现“隔着雾面玻璃看水”的柔和感。 ---
    float blend = max(softness, 0.5) + fwidth(depth);
    half underwater = half(smoothstep(-blend, blend, depth));
    half3 result = mix(airStraight, body, underwater);

    // --- 输出 alpha：空气侧沿用容器原本的透明度；水侧独立用
    //     bodyOpacity，都乘上“容器形状遮罩”，保证水不会溢出容器轮廓 ---
    half waterAlpha = half(saturate(bodyOpacity * (0.75 + depthFrac * 0.25)));
    half a = half(shapeMask) * mix(airSample.a, max(airSample.a, waterAlpha), underwater);

    result = clamp(result, 0.0h, 1.0h);
    return half4(result * a, a);
}

// ============================================================
// tms_waterLens —— “液态水镜片” / Liquid Glass 风格的悬浮水滴透镜。
// ------------------------------------------------------------
// 与上面的 tms_water（模拟容器里的一整片水）不同，这个函数模拟一枚
// 浮在内容上方的水滴/水泡：整块区域都是“凸起的液体表面”（半球形高度
// 场），中心几乎不偏移、只有很轻的镜头感缩放，边缘因为液面坡度最大，
// 折射 + 色散最强烈——这正是真实水滴透镜（以及 Liquid Glass 风格 UI）
// 的光学特征。
//
// 用法：配合 Swift 侧的“把 content 渲染两次”技巧（见 WaterLensEffect.
// swift），第二份 content 铺满整个背景、按镜片位置反向偏移对齐、裁到
// 镜片大小后套上这个着色器，再裁成镜片形状浮在上层——这样镜片挪到哪，
// 就“看透”背景哪一块，效果上就是能扭曲/色散【下层任意内容】的悬浮水镜。
//
// 命名同样遵循 tms_ 前缀约定。
// ============================================================

[[stitchable]] half4 tms_waterLens(float2 position,
                                   SwiftUI::Layer layer,
                                   float time,
                                   float2 lensCenter,
                                   float2 lensRadius,
                                   float refractionStrength,
                                   float chromaSpread,
                                   half4 tintColor,
                                   half4 highlightColor,
                                   float highlightIntensity,
                                   float rippleAmplitude,
                                   float rippleSpeed) {
    // lensCenter / lensRadius 是“镜片”在这个图层坐标系里的位置与半径
    // （不是整个图层的中心/尺寸）——这样镜片可以浮在容器内任意位置，
    // Swift 侧只需要把一份与背景等大、位置对齐的图层套上本着色器，
    // 再用镜片形状裁切出可见范围即可（见 WaterLensEffect.swift）。
    float2 radius = max(lensRadius, float2(1.0));
    float2 p = (position - lensCenter) / radius;      // 归一化到椭圆坐标，中心 (0,0)，边缘 ~1
    float r2 = clamp(dot(p, p), 0.0, 1.0);

    // 半球形液面高度场：中心最高(=1)，边缘最低(=0)，模拟凸起的水滴表面；
    // 叠一点随时间流动的轻微噪声波纹（rippleAmplitude 控制），让水面
    // 不是死的镀膜，而是“液态”在轻轻晃。
    float dome = sqrt(max(0.0, 1.0 - r2));
    float ripple = (tms_noise(p * 3.0 + time * rippleSpeed * 0.4) - 0.5) * rippleAmplitude;
    float height = dome + ripple * (1.0 - dome * 0.6);

    // 有限差分求高度场梯度 → 液面坡度，坡度方向即光线被弯折的方向；
    // 中心坡度≈0（几乎不偏移，只有轻微整体缩放感），边缘坡度最大。
    const float eps = 0.01;
    float heightDx = sqrt(max(0.0, 1.0 - clamp(dot(p + float2(eps, 0.0), p + float2(eps, 0.0)), 0.0, 1.0)))
                    + (tms_noise((p + float2(eps, 0.0)) * 3.0 + time * rippleSpeed * 0.4) - 0.5) * rippleAmplitude;
    float heightDy = sqrt(max(0.0, 1.0 - clamp(dot(p + float2(0.0, eps), p + float2(0.0, eps)), 0.0, 1.0)))
                    + (tms_noise((p + float2(0.0, eps)) * 3.0 + time * rippleSpeed * 0.4) - 0.5) * rippleAmplitude;
    float2 gradient = float2(heightDx - height, heightDy - height) / eps;

    // 折射位移：坡度越大位移越大（边缘强烈弯折，中心几乎不动），换算到
    // 像素单位时用 radius 把归一化坡度转回实际像素尺度。
    float2 disp = gradient * radius * refractionStrength;

    // 色散：坡度幅度驱动 R/G/B 的位移差异——液面越陡（越靠边缘）色散
    // 越明显，这正是水滴透镜边缘常见的彩色描边。
    float slope = length(gradient);
    float chroma = chromaSpread * saturate(slope * 2.0);
    half4 sr = layer.sample(position + disp * (1.0 + chroma));
    half4 sg = layer.sample(position + disp);
    half4 sb = layer.sample(position + disp * (1.0 - chroma));

    half3 straight;
    straight.r = sr.a > 0.001h ? half(sr.r / sr.a) : 0.0h;
    straight.g = sg.a > 0.001h ? half(sg.g / sg.a) : 0.0h;
    straight.b = sb.a > 0.001h ? half(sb.b / sb.a) : 0.0h;
    half a = sg.a;

    // 淡淡的水色叠加，让镜片看起来确实“是水”而不是纯粹的扭曲玻璃。
    half3 tinted = mix(straight, tintColor.rgb, half(tintColor.a));

    // 边缘高光环 + 顶部一小块柔和亮斑：模拟液面的镜面反光，边缘坡度大
    // 处（slope 大）叠加一个高光环，顶部（p.y 小、r 小）叠一块顺光高光。
    float2 lightDir = normalize(float2(-0.35, -0.9));
    float2 normalXY = slope > 0.0001 ? gradient / slope : float2(0.0);
    float rim = pow(saturate(slope * 1.6), 2.0) * saturate(1.0 - r2 * 0.3);
    float sheen = pow(saturate(dot(normalXY, -lightDir) * 0.5 + 0.5), 3.0) * dome;
    half highlight = half(saturate(rim * 0.8 + sheen * 0.6) * highlightIntensity);
    half3 result = clamp(tinted + half3(highlight) * half3(highlightColor.rgb), 0.0h, 1.0h);

    // 镜片整体形状由外部 clipShape 负责裁切；这里只在椭圆之外做一点
    // 柔和收边（避免方形 layer 边角出现未定义的液面）。
    float edgeMask = smoothstep(1.05, 0.95, sqrt(r2));
    a = half(saturate(float(a) * mix(0.0, 1.0, edgeMask)));

    return half4(result * a, a);
}
