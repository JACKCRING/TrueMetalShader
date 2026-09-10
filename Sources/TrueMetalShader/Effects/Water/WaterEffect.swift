//
//  WaterEffect.swift
//  TrueMetalShader
//
//  水面（water）效果的公开 API —— 核心、跨平台、无传感器依赖部分。
//  ------------------------------------------------------------
//  模拟“透明杯子里的水”这个切面：容器里有一条水位线，随重力方向倾斜、
//  随时间起伏，水位线以下折射 + 加深水色，以上原样透出，交界处一条
//  高光/泡沫细线。套在【任意视图】上即可，那个视图就是“容器”：
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
//  内部实现：着色器把容器四角投影到重力轴上，算出水位线的静止位置，
//  叠加三层不同方向/频率的正弦波做水面起伏，用起伏的切向斜率做折射
//  位移，按深度加重水色，交给 Water.metal 里的 `tms_water` 着色器，
//  通过 `.layerEffect` 作用在内容图层上。
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

    /// 水面波浪幅度（像素）：水位线本身的细碎起伏。
    public var waveAmplitude: CGFloat

    /// 波浪密度：越大波纹越细密。
    public var waveFrequency: Float

    /// 波浪流动速度。
    public var waveSpeed: Float

    /// 折射强度：水面坡度 → 采样偏移的换算系数，越大水下内容扭曲越明显。
    public var refractionStrength: CGFloat

    /// 水色（水下叠加的颜色，alpha 控制浓度）。
    public var tint: Color

    /// 水位线高光 / 泡沫色。
    public var foam: Color

    /// 泡沫细线的宽度（像素）。
    public var foamWidth: CGFloat

    /// 是否让波浪自动流动。关闭后水面完全静止（只由 `gravity` / `level` 决定形状）。
    public var isAnimating: Bool

    public init(gravity: CGVector = CGVector(dx: 0, dy: 1),
                level: CGFloat = 0.5,
                waveAmplitude: CGFloat = 4,
                waveFrequency: Float = 10,
                waveSpeed: Float = 1.0,
                refractionStrength: CGFloat = 6,
                tint: Color = Color(red: 0.15, green: 0.55, blue: 0.85).opacity(0.35),
                foam: Color = .white.opacity(0.85),
                foamWidth: CGFloat = 2,
                isAnimating: Bool = true) {
        self.gravity = gravity
        self.level = level
        self.waveAmplitude = waveAmplitude
        self.waveFrequency = waveFrequency
        self.waveSpeed = waveSpeed
        self.refractionStrength = refractionStrength
        self.tint = tint
        self.foam = foam
        self.foamWidth = foamWidth
        self.isAnimating = isAnimating
    }

    /// 折射最远采样距离：波浪坡度的粗略上界 × 折射强度，留一点余量。
    private var maxSampleOffset: CGSize {
        let maxSlope = waveAmplitude * CGFloat(waveFrequency) * 0.03
        let reach = maxSlope * refractionStrength + CGFloat(4)
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
                        .float(Float(foamWidth))
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
    /// 水位线以下折射 + 加深水色，以上原样透出，交界处一条高光细线。
    ///
    /// - Parameters:
    ///   - gravity: 重力 / “下”方向，(0,1) 为竖直向下（水面持平）。默认 (0, 1)。
    ///   - level: 水位 0...1，0 = 空杯，1 = 满杯。默认 0.5。
    ///   - waveAmplitude: 水面波浪幅度（像素）。默认 4。
    ///   - waveFrequency: 波浪密度。默认 10。
    ///   - waveSpeed: 波浪流动速度。默认 1.0。
    ///   - refractionStrength: 折射强度，越大水下扭曲越明显。默认 6。
    ///   - tint: 水色（alpha 控制浓度）。默认半透明蓝。
    ///   - foam: 水位线高光 / 泡沫色。默认半透明白。
    ///   - foamWidth: 泡沫细线宽度（像素）。默认 2。
    ///   - isAnimating: 是否自动流动波浪。默认 true。
    func waterEffect(gravity: CGVector = CGVector(dx: 0, dy: 1),
                     level: CGFloat = 0.5,
                     waveAmplitude: CGFloat = 4,
                     waveFrequency: Float = 10,
                     waveSpeed: Float = 1.0,
                     refractionStrength: CGFloat = 6,
                     tint: Color = Color(red: 0.15, green: 0.55, blue: 0.85).opacity(0.35),
                     foam: Color = .white.opacity(0.85),
                     foamWidth: CGFloat = 2,
                     isAnimating: Bool = true) -> some View {
        modifier(WaterEffect(gravity: gravity,
                              level: level,
                              waveAmplitude: waveAmplitude,
                              waveFrequency: waveFrequency,
                              waveSpeed: waveSpeed,
                              refractionStrength: refractionStrength,
                              tint: tint,
                              foam: foam,
                              foamWidth: foamWidth,
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
