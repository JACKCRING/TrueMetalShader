//
//  Particle.metal
//  TrueMetalShader
//
//  粒子消散 / 汇聚（particle dissolve / gather）后处理着色器 —— 让任意视图
//  「碎成一片粒子飘散」或「由粒子汇聚成视图的真实样子」。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上，
//  因此对 Text / 图片 / 形状 / 任意容器都成立。
//
//  思路（纯片元着色器里的“伪粒子系统”）：
//  1. 把整张图按 `cellSize` 切成网格，每个格子就是一颗“粒子”，它保留自己
//     原始位置那一小块的图像内容（所以汇聚完成后能还原出视图的真实样子）。
//  2. 每颗粒子按其格子坐标做哈希，得到一组随机量：飞散方向、速度、起飞延迟、
//     自转、缩小、飘忽扰动。随 `progress` 推进，粒子从原位出发，一边位移
//     （向外扩散 + 全局风向 drift + 重力 gravity + 抖动 flutter）、一边缩小、
//     自转、最后淡出。
//  3. 输出像素时并不是“正向散射”（那样会产生空洞/重叠），而是在该像素周围
//     有界地遍历可能覆盖到它的粒子（邻域大小由最大位移推出并封顶），做逆变换
//     判断命中、取最“实”的一颗着色，缝隙处透出背景 —— 于是呈现出真正的
//     粒子云观感，且无空洞/无越界。
//
//  progress 语义：0 = 完好的原视图；1 = 完全碎散消失。
//  - 「消散」= progress 0 → 1；
//  - 「汇聚」= progress 1 → 0（同一套数学，仅时间方向相反，故本着色器只需 progress）。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀；辅助函数用 static inline。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// MARK: - 哈希

// 每颗粒子取 3 个互不相关的随机量：方向角 / 速度·缩放 / 自转·相位。
static inline float3 tms_pt_hash3(float2 p) {
    float3 q = float3(dot(p, float2(127.1, 311.7)),
                      dot(p, float2(269.5, 183.3)),
                      dot(p, float2(419.2, 371.9)));
    return fract(sin(q) * 43758.5453);
}

// MARK: - 旋转

static inline float2 tms_pt_rot(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// 邻域搜索半径上限（格）：决定单像素最坏遍历量 (2R+1)^2，用于封顶开销。
constant int TMS_PT_MAXR = 5;

// MARK: - 主着色器

[[stitchable]] half4 tms_particle(float2 position,
                                  SwiftUI::Layer layer,
                                  float2 size,
                                  float progress,      // 0 = 完好，1 = 完全碎散
                                  float time,          // 连续时间(秒)，供飘忽/闪烁
                                  float cellSize,      // 粒子尺寸(点)
                                  float travel,        // 飞散距离（相对格数）
                                  float2 drift,        // 全局风向（未归一化亦可）
                                  float driftAmount,   // 跟随风向的强度 0...1
                                  float gravity,       // 重力（相对格数，正=向下）
                                  float spread,        // 起飞时刻错开程度 0...1
                                  float randomness,    // 方向随机度 0...1
                                  float spin,          // 自转幅度（弧度）
                                  float shrink,        // 末态缩放 0...1（0=缩没）
                                  float roundness,     // 粒子形状 0...1（0=方形，1=圆形）
                                  float glow,          // 飞散时的余辉强度
                                  float flutter,       // 飘忽抖动（相对格数）
                                  float fade,          // 生命中开始淡出的位置 0...1
                                  float seed) {        // 随机种子
    // progress<=0：完好原图，直接返回（配合 Swift 侧 isEnabled，静止时零开销）。
    if (progress <= 0.0) {
        return layer.sample(position);
    }

    float cs = max(cellSize, 2.0);
    float2 center = size * 0.5;

    float sp = clamp(spread, 0.0, 0.95);
    float invWin = 1.0 / max(1e-3, 1.0 - sp);

    float travelPx  = max(travel, 0.0) * cs;
    float gravityPx = gravity * cs;
    float flutterPx = max(flutter, 0.0) * cs;

    // 邻域半径：能覆盖到本像素的粒子，其出发格必在最大位移范围内。
    float maxDisp = travelPx + abs(gravityPx) + flutterPx;
    int R = int(clamp(ceil(maxDisp / cs) + 1.0, 1.0, float(TMS_PT_MAXR)));
    float clampDisp = (float(R) - 0.25) * cs;   // 把位移夹在搜索窗内，避免越界弹出

    float2 driftN = (dot(drift, drift) > 1e-6) ? normalize(drift) : float2(0.0);
    int2 baseCell = int2(floor(position / cs));

    half4  bestCol = half4(0.0);   // 预乘颜色
    float  bestKey = 0.0;          // 命中优先级（覆盖度 × alpha）
    float  glowAcc = 0.0;          // 余辉累积

    for (int dy = -R; dy <= R; dy++) {
        for (int dx = -R; dx <= R; dx++) {
            int2 cell = baseCell + int2(dx, dy);
            float2 cc = (float2(cell) + 0.5) * cs;    // 粒子原始中心

            float3 h = tms_pt_hash3(float2(cell) + seed * 7.0 + 0.5);

            // 起飞时刻错开 → 生命进度 life ∈ 0...1。
            float delay = h.x * sp;
            float life = clamp((progress - delay) * invWin, 0.0, 1.0);

            // 运动方向：向外扩散，按 randomness 混入随机角，再按 driftAmount 拉向风向。
            float ang = h.y * 6.28318530718;
            float2 rnd = float2(cos(ang), sin(ang));
            float2 outward = cc - center;
            outward = (dot(outward, outward) > 1e-4) ? normalize(outward) : rnd;
            float2 dir = normalize(mix(outward, rnd, clamp(randomness, 0.0, 1.0)));
            if (driftAmount > 0.0 && (driftN.x != 0.0 || driftN.y != 0.0)) {
                dir = normalize(mix(dir, driftN, clamp(driftAmount, 0.0, 1.0)));
            }

            float speed = mix(0.65, 1.0, h.z);

            // 位移：主飞散 + 重力(随 life² 加速) + 飘忽抖动。
            float2 D = dir * (speed * life * travelPx);
            D += float2(0.0, gravityPx * life * life);
            if (flutterPx > 0.0) {
                float ph = h.x * 6.2831853;
                D += float2(sin(time * 3.0 + ph),
                            cos(time * 2.3 + ph * 1.7)) * (flutterPx * life);
            }
            float dl = length(D);
            if (dl > clampDisp) { D *= clampDisp / dl; }

            float scale = mix(1.0, clamp(shrink, 0.0, 1.0), life);
            float rot   = (h.z * 2.0 - 1.0) * spin * life;

            // 逆变换：把输出像素 position 变回该粒子“原始格”里的采样点 Pprime。
            // 正向：screen = cc + D + scale · Rot(rot) · (Pprime - cc)
            float2 q  = position - (cc + D);
            q = tms_pt_rot(q, -rot);
            float2 ql = q / max(scale, 1e-3);         // 相对格中心的原始局部坐标
            float2 Pprime = cc + ql;

            // 命中测试：Pprime 是否落在该格的足迹内。用圆角方形有符号距离场(SDF)：
            // roundness=0 → 方形，1 → 圆形，中间为圆角方形；带 ~1px 抗锯齿。
            float hcs = cs * 0.5;
            float rr = clamp(roundness, 0.0, 1.0) * hcs;   // 圆角半径
            float2 dq = abs(ql) - (hcs - rr);
            float sdf = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0) - rr;
            float aa = 0.75;
            float cov = 1.0 - smoothstep(0.0, aa, sdf);
            if (cov <= 0.0) { continue; }

            // 生命后段淡出。
            float al = 1.0 - smoothstep(clamp(fade, 0.0, 0.99), 1.0, life);
            float coverage = cov * al;
            if (coverage <= 0.0) { continue; }

            half4 s = layer.sample(Pprime);           // 预乘 alpha
            float key = coverage * float(s.a);

            // 余辉：生命中段最亮（起飞不久、尚未淡尽时）。
            glowAcc += key * life * (1.0 - life) * 4.0;

            if (key > bestKey) {
                bestKey = key;
                bestCol = s * half(coverage);         // 预乘颜色整体缩放，保持预乘语义
            }
        }
    }

    // 余辉（自发光，暖色），按命中的 alpha 附着，缝隙处不发光。
    if (glow > 0.0 && glowAcc > 0.0 && bestCol.a > 0.001h) {
        half3 ember = half3(1.0, 0.6, 0.28) * half(min(glowAcc, 1.0) * glow);
        bestCol.rgb = min(bestCol.rgb + ember * bestCol.a, half3(6.0));
    }

    return bestCol;
}
