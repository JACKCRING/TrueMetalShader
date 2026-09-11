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
//  - 边界是锐利的（只做 1px 抗锯齿，`softness` 只用来做极轻微的柔化，
//    默认值很小），不是模糊的雾面过渡——水面轮廓应该看得清清楚楚；
//  - 水下折射是经典的“插入水里的筷子看起来断开错位”效果：跨过水位线
//    后，内容整体沿一个固定方向产生一段【恒定】的侧向位移（不随深度
//    衰减），只在贴着水位线的窄条内快速从 0 过渡到满值——视觉上就是
//    “东西一插进水里，水下的部分整体挪了一截”，而不是越往下越模糊；
//  - 内发光（inner glow）：紧贴水位线的水下一侧，有一条均匀的辉光带，
//    强度只随“离水位线的距离”指数衰减（`highlightRange` 控制衰减范围），
//    与局部法线朝向无关——这样辉光沿整条曲线均匀浮现，不会因为坡度朝向
//    不同而忽明忽暗；
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
                               float refractionRange,
                               float highlightRange) {
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

    // 有限差分求高度场的切向斜率，作为折射位移方向的自然调制来源。
    const float eps = 1.0;
    float waveNext = tms_waterHeight(tCoord + eps, time, waveAmplitude, waveFrequency, waveSpeed);
    float slope = (waveNext - wave) / eps;

    // --- 极轻微的噪声抖动：只是让水下位移不是死板的纯几何值，带一点
    //     “活的”液体感，幅度远小于主位移，不是折射的主要来源。 ---
    float2 flowP = position * 0.006 + float2(time * 0.05, -time * 0.03);
    float n1 = tms_noise(flowP) - 0.5;
    float n2 = tms_noise(flowP + float2(5.2, 1.3)) - 0.5;
    float2 warp = float2(n1, n2) * 0.4;

    // 折射位移 ramp：跨过水位线后，在一条窄条（宽度由 refractionRange
    // 控制）内快速从 0 过渡到 1，过渡完之后保持恒定的 1——不随深度继续
    // 衰减。这是复刻“筷子插入水里看起来断开错位”的关键：水下内容整体
    // 沿切向产生一段【恒定】的侧向位移，不是越往下越模糊、也不是被
    // 水面本身很小的坡度拖累到几乎看不见——固定方向的位移量直接取
    // refractionStrength 本身，slope 只用来叠加一点跟随水面起伏的自然
    // 变化（用 clamp 限制在 ±60% 范围内，不会让位移消失或反向太多）。
    float rampWidth = max(refractionRange, 1.0);
    float ramp = smoothstep(-rampWidth, rampWidth, depth);
    float slopeMod = clamp(slope * 6.0, -0.6, 0.6);
    float2 disp = (t * (1.0 + slopeMod) + warp) * refractionStrength * ramp;

    // --- 原始图层采样：既判断“容器形状”，也用作空气侧内容 ---
    half4 airSample = layer.sample(position);
    half3 airStraight = airSample.a > 0.001h ? half3(airSample.rgb / airSample.a) : half3(0.0h);

    // 容器形状遮罩：只看 alpha 是否“存在”，与容器实际画得多透明无关——
    // 这样低透明度的“玻璃杯”轮廓依然能让水体不透明地显示。
    float shapeAA = fwidth(float(airSample.a)) + 0.0006;
    float shapeMask = smoothstep(0.0002 - shapeAA, 0.0002 + shapeAA, float(airSample.a));

    // --- 水侧：折射采样，单点采样、无色散——干净的位移错位效果。 ---
    half4 waterSample = layer.sample(position + disp);
    half3 waterStraight = waterSample.a > 0.001h ? half3(waterSample.rgb / waterSample.a) : half3(0.0h);

    // 水色：贴近水面时只叠很淡的一层（这样被折射/色散的下层内容清晰
    // 可见），随深度增加逐渐叠浓，够深处基本被水色盖住看不透。
    half tintMix = half(saturate(0.12 + depthFrac * 0.75));
    half3 body = mix(waterStraight, tintColor.rgb, tintMix);
    body *= half(1.0 - depthFrac * 0.20);

    // --- 内发光（inner glow）：紧贴水位线水下一侧的一条均匀辉光带。
    //     只用 |depth|（离水位线的距离）驱动指数衰减，不依赖 normal /
    //     光照方向——这样辉光沿整条曲线亮度均匀，不会因坡度朝向不同
    //     而忽明忽暗，符合“边界自身在发光”的观感。只在水下一侧出现
    //     （depth > 0 时才有），空气侧没有。 ---
    float glowBand = exp(-max(depth, 0.0) / max(highlightRange, 1.0));
    body += half3(glowBand * highlightIntensity) * half3(highlightColor.rgb);

    body = clamp(body, 0.0h, 1.0h);

    // --- 水/空气的边界：锐利过渡，只用 fwidth 做 ~1px 抗锯齿（softness
    //     可以叠加极轻微的额外柔化，默认应保持很小）。 ---
    float blend = max(softness, 0.0) + fwidth(depth) + 0.5;
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
