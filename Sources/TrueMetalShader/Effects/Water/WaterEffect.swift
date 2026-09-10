//
//  WaterEffect.swift
//  TrueMetalShader
//
//  水面（water）效果的公开 API —— 核心、跨平台、无传感器依赖部分。
//  ------------------------------------------------------------
//  模拟“透明杯子里的水”这个切面，参照真实水下摄影的视觉线索来做：
//
//  - 水位线随重力方向倾斜、随时间起伏（低频“大浪” + fbm 噪声紊乱层）；
//  - 水面本身是一条“有厚度的紊乱大理石纹路带”（`turbulenceWidth` 控制
//    宽度），蓝白花纹流动、几乎遮住带内容——不是一条细描边；
//  - 水下折射用噪声域扭曲（domain warp），扭曲感是紊乱的，不是规则正弦
//    那种“布料在抖”的手感；
//  - 水下叠加沿重力轴拉伸的方向性焦散光束，随水面扰动摆动，模拟阳光
//    透过水面折射出的光斑网；
//  - 水的不透明度独立于容器原始透明度（`bodyOpacity`），因此即便容器
//    本身画得很淡（近乎透明的玻璃轮廓），水依然清晰可见。
//
//  套在【任意视图】上即可，那个视图就是“容器”：
//
//      RoundedRectangle(cornerRadius: 24)
//          .fill(.white.opacity(0.06))
//          .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.3)))
//          .frame(width: 160, height: 220)
//          .waterEffect(level: 0.5)          // 半杯水，水面持平
//
//  “水位线跟着手机重力左右晃”这件事分两层：
//  - 本文件的 `gravity` 只是一个二维方向输入，纯函数式，不读传感器，
//    保持跨平台（iOS / macOS / tvOS / visionOS）都能用；
//  - 真正“接手机重力 + 过冲回弹的晃动手感”在 `WaterMotion.swift`（仅
//    iOS，用 CoreMotion + 弹簧动画），对外是 `.waterGravityEffect()`。
//
//  想自己接摇杆、陀螺仪、鼠标位置等任意输入源，直接用本文件的
//  `.waterEffect(gravity:...)` 并自己驱动 `gravity` 即可。
//
//  内部实现见 Water.metal 里的 `tms_water` 着色器，通过 `.layerEffect`
//  作用在内容图层上。
//

import SwiftUI

// MARK: - 修饰器

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct WaterEffect: ViewModifier {

    /// 重力 / 倾斜方向（“下”是哪边）。(0, 1) = 正常竖直向下，水面持平；
    /// (1, 0) = 重力指向右边，水会整体倒向右边。长度会被内部归一化。
    public var gravity: CGVector

    /// 水位：0 = 空杯（几乎全是空气），1 = 满杯（几乎全是水）。默认 0.5。
    public var level: CGFloat

    /// 水面波浪幅度（像素）：水位线本身的起伏幅度（大浪 + 紊乱层的总强度）。
    public var waveAmplitude: CGFloat

    /// 波浪密度：越大波浪越细密。
    public var waveFrequency: Float

    /// 波浪 / 花纹流动速度。
    public var waveSpeed: Float

    /// 折射强度：噪声扭曲 + 边界弯折 → 采样偏移的换算系数，越大水下扭曲越明显。
    public var refractionStrength: CGFloat

    /// 水色（水下深处叠加的颜色）。
    public var tint: Color

    /// 水面表层花纹的亮色（大理石纹路里较浅的部分，也用作焦散偏色基础）。
    public var foam: Color

    /// 水面表层紊乱大理石纹路带的宽度（像素）。越大这条“看得出是水面”
    /// 的花纹带越厚，越小越接近一条描边。
    public var turbulenceWidth: CGFloat

    /// 水体不透明度 0...1，独立于容器原始透明度。这是让“水看得见”的关键：
    /// 即便容器本身画得很淡（近乎透明的玻璃轮廓），水依然按这个值显示。
    public var bodyOpacity: Double

    /// 波面高光强度：水面粼粼反光的亮度。
    public var highlightIntensity: Float

    /// 焦散光束强度：水下方向性光斑网的强度，0 = 关闭。
    public var causticIntensity: Float

    /// 是否让波浪 / 花纹自动流动。关闭后水面完全静止（只由 `gravity` / `level` 决定形状）。
    public var isAnimating: Bool

    public init(gravity: CGVector = CGVector(dx: 0, dy: 1),
                level: CGFloat = 0.5,
                waveAmplitude: CGFloat = 10,
                waveFrequency: Float = 10,
                waveSpeed: Float = 1.0,
                refractionStrength: CGFloat = 10,
                tint: Color = Color(red: 0.02, green: 0.30, blue: 0.45),
                foam: Color = Color(red: 0.55, green: 0.85, blue: 0.95),
                turbulenceWidth: CGFloat = 26,
                bodyOpacity: Double = 0.85,
                highlightIntensity: Float = 0.30,
                causticIntensity: Float = 0.35,
                isAnimating: Bool = true) {
        self.gravity = gravity
        self.level = level
        self.waveAmplitude = waveAmplitude
        self.waveFrequency = waveFrequency
        self.waveSpeed = waveSpeed
        self.refractionStrength = refractionStrength
        self.tint = tint
        self.foam = foam
        self.turbulenceWidth = turbulenceWidth
        self.bodyOpacity = bodyOpacity
        self.highlightIntensity = highlightIntensity
        self.causticIntensity = causticIntensity
        self.isAnimating = isAnimating
    }

    /// 折射最远采样距离：噪声扭曲幅度（固定换算为 ±2）+ 边界弯折的粗略
    /// 上界，两者都乘以 refractionStrength，再留一点余量。
    private var maxSampleOffset: CGSize {
        let warpReach = 2.0 * refractionStrength
        let slopeReach = waveAmplitude * CGFloat(waveFrequency) * 0.02 * refractionStrength
        let reach = warpReach + slopeReach + CGFloat(4)
        return CGSize(width: reach, height: reach)
    }

    public func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isAnimating)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let time = isAnimating
                ? Float(seconds.truncatingRemainder(dividingBy: 1000))
                : 0

            let maxSampleOffset = maxSampleOffset
            content.visualEffect { view, proxy in
                view.layerEffect(
                    ShaderLibrary.trueMetal.tms_water(
                        .float(time),
                        .float2(proxy.size),
                        .float2(Float(gravity.dx), Float(gravity.dy)),
                        .float(Float(level)),
                        .float(Float(waveAmplitude)),
                        .float(waveFrequency),
                        .float(waveSpeed),
                        .float(Float(refractionStrength)),
                        .color(tint),
                        .color(foam),
                        .float(Float(turbulenceWidth)),
                        .float(Float(bodyOpacity)),
                        .float(highlightIntensity),
                        .float(causticIntensity)
                    ),
                    maxSampleOffset: maxSampleOffset
                )
            }
        }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意视图套上“透明容器里的水”效果：水位线随重力倾斜、随时间起伏，
    /// 水面本身是一条紊乱大理石纹路带（不是描边），水下噪声折射 + 方向性
    /// 焦散光束 + 波面高光；水的不透明度独立于容器本身透明度，因此即便
    /// 容器画得很淡，水依然清晰可见。
    ///
    /// - Parameters:
    ///   - gravity: 重力 / “下”方向，(0,1) 为竖直向下（水面持平）。默认 (0, 1)。
    ///   - level: 水位 0...1，0 = 空杯，1 = 满杯。默认 0.5。
    ///   - waveAmplitude: 水面起伏幅度（像素）。默认 10。
    ///   - waveFrequency: 波浪密度。默认 10。
    ///   - waveSpeed: 波浪 / 花纹流动速度。默认 1.0。
    ///   - refractionStrength: 折射强度，越大水下扭曲越明显。默认 10。
    ///   - tint: 水色（深处颜色）。默认深青蓝。
    ///   - foam: 表层花纹亮色 / 焦散偏色。默认浅青。
    ///   - turbulenceWidth: 表层紊乱花纹带宽度（像素）。默认 26。
    ///   - bodyOpacity: 水体不透明度 0...1，独立于容器透明度。默认 0.85。
    ///   - highlightIntensity: 波面高光强度。默认 0.30。
    ///   - causticIntensity: 焦散光束强度，0 关闭。默认 0.35。
    ///   - isAnimating: 是否自动流动波浪 / 花纹。默认 true。
    func waterEffect(gravity: CGVector = CGVector(dx: 0, dy: 1),
                     level: CGFloat = 0.5,
                     waveAmplitude: CGFloat = 10,
                     waveFrequency: Float = 10,
                     waveSpeed: Float = 1.0,
                     refractionStrength: CGFloat = 10,
                     tint: Color = Color(red: 0.02, green: 0.30, blue: 0.45),
                     foam: Color = Color(red: 0.55, green: 0.85, blue: 0.95),
                     turbulenceWidth: CGFloat = 26,
                     bodyOpacity: Double = 0.85,
                     highlightIntensity: Float = 0.30,
                     causticIntensity: Float = 0.35,
                     isAnimating: Bool = true) -> some View {
        modifier(WaterEffect(gravity: gravity,
                              level: level,
                              waveAmplitude: waveAmplitude,
                              waveFrequency: waveFrequency,
                              waveSpeed: waveSpeed,
                              refractionStrength: refractionStrength,
                              tint: tint,
                              foam: foam,
                              turbulenceWidth: turbulenceWidth,
                              bodyOpacity: bodyOpacity,
                              highlightIntensity: highlightIntensity,
                              causticIntensity: causticIntensity,
                              isAnimating: isAnimating))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 玻璃杯半杯水") {
    RoundedRectangle(cornerRadius: 20)
        .fill(.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.4), lineWidth: 2)
        )
        .frame(width: 160, height: 220)
        .waterEffect(level: 0.5)
        .padding(60)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 倾斜晃动") {
    ZStack {
        Text("💧")
            .font(.system(size: 80))
    }
    .frame(width: 200, height: 260)
    .background(.white.opacity(0.05))
    .clipShape(RoundedRectangle(cornerRadius: 24))
    .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.3), lineWidth: 2))
    .waterEffect(gravity: CGVector(dx: 0.5, dy: 0.85), level: 0.6)
    .padding(60)
    .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 大容器泳池感") {
    Color.clear
        .frame(width: 360, height: 420)
        .background(.black)
        .waterEffect(level: 0.72, waveAmplitude: 14, turbulenceWidth: 34, causticIntensity: 0.45)
}
