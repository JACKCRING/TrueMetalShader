//
//  PaperBurn.metal
//  TrueMetalShader
//
//  纸张「裂开→着火→慢慢燃烧」后处理着色器 —— 点哪裂哪、裂缝起火向外啃。
//  ------------------------------------------------------------
//  作为 SwiftUI 的 `.layerEffect` 作用在【已经渲染好】的任意视图图层上。
//
//  每处点击的时序（单处火源，progress 0→1）：
//    1) 裂开：从点击点长出 1~2 条蜿蜒细裂纹（快速出现，沿裂纹向外延伸）；
//    2) 着火：裂纹上随即起火；
//    3) 燃烧：火沿裂纹向【两侧垂直】慢慢蔓延，身后焦黑、再烧穿透出背景。
//  火线(余烬)形状用噪声扰得不规则并带轻微闪烁 → 自然。火的蔓延距离有上限
//  (`burnReach`)，所以是“裂缝在烧、向外啃一圈”，不会一下烧成一大团。
//
//  多火源（累积）：入参是一组火源 `impacts`（每 4 个 float：ox, oy, progress, seed），
//  逐个求“到火线的有符号距离”并取并集(max)。progress 由上层按各自点火时刻推进，
//  seed 让每处裂纹/火形态各异；`time` 供火焰闪烁。
//
//  命名约定：包内 [[stitchable]] 函数统一用 `tms_` 前缀；辅助函数用 static inline。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// MARK: - 噪声

static inline float tms_pb_hash1(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float2 tms_pb_hash2(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)),
               dot(p, float2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

static inline float tms_pb_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = tms_pb_hash1(i + float2(0.0, 0.0));
    float b = tms_pb_hash1(i + float2(1.0, 0.0));
    float c = tms_pb_hash1(i + float2(0.0, 1.0));
    float d = tms_pb_hash1(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float tms_pb_fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 5; i++) {
        v += amp * tms_pb_vnoise(p);
        p *= 2.02;
        amp *= 0.5;
    }
    return v;
}

// MARK: - 主着色器

[[stitchable]] half4 tms_paperBurn(float2 position,
                                   SwiftUI::Layer layer,
                                   float2 size,
                                   device const float *impacts,   // [ox, oy, progress, seed] × N
                                   int impactCount,
                                   float time,          // 连续时间(秒)，供火焰闪烁
                                   float radius,        // 裂纹长度尺度（相对最远角落）
                                   float burnReach,     // 火从裂纹向外蔓延的最大距离（相对格）
                                   float edgeWidth,     // 火线(余烬+焦化)宽度尺度
                                   float glow,          // 余烬发光强度
                                   float tearCount,     // 每处裂纹条数上限（随机 1~2 条）
                                   float irregularity,  // 火/裂纹边缘不规则程度
                                   float flicker) {     // 火焰闪烁强度
    float cs = max(min(size.x, size.y) / 12.0, 1.0);

    // 时序常量：裂纹在前 crackPhase 段快速铺出，其后开始烧。
    const float crackPhase  = 0.18;
    const float igniteDelay = 0.04;

    int nImp = min(max(impactCount, 0) / 4, 16);
    int maxCracks = int(clamp(tearCount, 1.0, 4.0) + 0.5);

    float eMax = -1e18;   // 到火线的有符号距离(px)，取所有火源并集
    float crackDark = 0.0; // 未烧到时的细裂纹暗线（取最强）

    for (int m = 0; m < nImp; m++) {
        float2 org = float2(impacts[m * 4 + 0], impacts[m * 4 + 1]);
        float  prog = impacts[m * 4 + 2];
        float  sd   = impacts[m * 4 + 3];
        if (prog <= 0.0) { continue; }
        if (org.x < 0.0) { org = size * 0.5; }

        float maxReach = length(max(org, size - org)) + 1.0;
        float Rmax = clamp(radius, 0.05, 1.5) * maxReach;   // 裂纹长度尺度

        float2 toP = position - org;
        float  dpx = length(toP);
        float  ang = atan2(toP.y, toP.x);

        // ---- 裂纹几何：从点击点长出 1~2 条蜿蜒射线 ----
        float bestEff = 1e9, bestPerp = 1e9, bestLenF = 0.0, bestCrackLen = 1.0;
        for (int i = 0; i < maxCracks; i++) {
            float2 rc = tms_pb_hash2(float2(float(i) + 1.0, sd) + 0.37);
            float exists = (i == 0) ? 1.0 : step(0.5, rc.x);
            float ang0 = rc.y * 6.28318530718;
            float crackLen = mix(0.55, 1.0, tms_pb_hash1(float2(float(i) + 5.0, sd))) * Rmax;
            float wander = (tms_pb_fbm(float2(dpx / (cs * 3.5), float(i) * 9.0) + sd) - 0.5) * 1.4;
            float crackAng = ang0 + wander;
            float dAng = atan2(sin(ang - crackAng), cos(ang - crackAng));
            float perp = abs(sin(dAng)) * dpx;
            float lenF = (1.0 - smoothstep(crackLen * 0.75, crackLen, dpx)) * exists;
            float eff = perp + (1.0 - lenF) * 1e5;
            if (eff < bestEff) {
                bestEff = eff; bestPerp = perp; bestLenF = lenF; bestCrackLen = crackLen;
            }
        }

        // 裂纹何时“到达”本像素所在半径（裂纹沿长度快速铺出）。
        float tc = clamp(dpx / max(bestCrackLen, 1.0), 0.0, 1.0) * crackPhase;

        // 火/裂纹边缘的不规则扰动（静态可燃性 + 轻微闪烁）。
        float rag = (tms_pb_fbm(position / (cs * 1.3) + sd * 3.7) - 0.5) * cs * 1.2 * irregularity
                  + (tms_pb_fbm(position / (cs * 0.5) + float2(time * 0.8 + sd, sd)) - 0.5) * cs * 0.5 * flicker;
        float perpW = max(bestPerp + rag, 0.0);

        // 火从裂纹向两侧垂直蔓延，距离随时间增长、但有上限（contained）。
        float burnLocal = clamp((prog - tc - igniteDelay) / max(1.0 - crackPhase, 0.1), 0.0, 1.0);
        float burnFront = burnLocal * max(burnReach, 0.1) * cs;
        eMax = max(eMax, burnFront - perpW);

        // 起火前先露出的细裂纹暗线（裂纹前锋扫过即现）。
        float reveal = smoothstep(0.0, 0.05, prog - tc) * bestLenF;
        float cl = (1.0 - smoothstep(0.0, cs * 0.11, perpW)) * reveal;
        crackDark = max(crackDark, cl);
    }

    half4 s = layer.sample(position);

    float ew      = max(edgeWidth, 0.05) * cs;
    float emberW  = ew * 0.6;
    float charW   = ew * 1.3;
    float scorchW = ew * 0.9;

    // 完全没被触及：原样返回。
    if (eMax < -scorchW && crackDark <= 0.001) {
        return s;
    }

    half a = s.a;
    half3 col = a > 0.001h ? s.rgb / a : s.rgb;

    // 0) 未烧到处的细裂纹暗线（被后面的焦化覆盖）。
    float notBurned = 1.0 - smoothstep(-emberW * 0.5, emberW * 0.5, eMax);
    col = mix(col, half3(0.12, 0.10, 0.09), half(crackDark) * 0.75h * half(notBurned));

    // 1) 预热焦黄（火线前一点点）。
    float scorch = smoothstep(-scorchW, 0.0, eMax) * (1.0 - smoothstep(0.0, emberW * 0.5, eMax));
    col = mix(col, half3(0.42, 0.30, 0.11), half(clamp(scorch, 0.0, 1.0)) * 0.5h);

    // 2) 焦化变黑。
    float charAmt = smoothstep(0.0, emberW + charW, eMax);
    col = mix(col, half3(0.05, 0.035, 0.03), half(charAmt));

    // 3) 余烬发光带（火线）：外沿黄白、内侧橙红，带闪烁。
    float band = smoothstep(-emberW * 0.7, 0.0, eMax)
               * (1.0 - smoothstep(emberW * 0.5, emberW + charW * 0.6, eMax));
    float fl = 0.7 + 0.5 * tms_pb_fbm(position / (cs * 0.45) + float2(time * 1.4, -time));
    float t2 = clamp(eMax / max(emberW, 1e-3), 0.0, 1.0);
    half3 fire = mix(half3(1.0, 0.9, 0.5), half3(1.0, 0.32, 0.05), half(t2));
    col = col + fire * half(band * glow * fl);

    // 4) 烧穿：焦化之后 alpha 渐灭。
    a = a * half(1.0 - smoothstep(emberW + charW * 0.5, emberW + charW + ew * 0.7, eMax));

    return half4(clamp(col, 0.0h, 6.0h) * a, a);
}
