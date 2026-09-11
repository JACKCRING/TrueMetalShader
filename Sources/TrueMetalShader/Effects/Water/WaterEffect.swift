//
//  WaterEffect.swift
//  TrueMetalShader
//
//  水面（water）效果的公开 API —— 核心、跨平台、无传感器依赖部分。
//  ------------------------------------------------------------
//  参考真实“手机端着一杯水”的观感来做：水面几乎是一条平滑的倾斜直线
//  （随重力倾斜），只有很轻微的低频起伏，边缘是锐利的（只做 1px 抗
//  锯齿，不是模糊的雾面过渡）。折射效果是经典的“插入水里的筷子看起来
//  断开错位”——跨过水位线后，内容整体沿切向产生一段【恒定】的侧向
//  位移（`refractionRange` 只控制从 0 过渡到恒定值的窄条宽度）。紧贴
//  水位线水下一侧有一条内发光（inner glow），亮度只随离水位线的距离
//  衰减、与坡度朝向无关，所以整条曲线上的辉光是均匀的。刻意不做夸张
//  的波浪 / 高频花纹、也不做色散——那样会显得像连绵的山峰或彩虹描边，
//  不像真实水面。
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

    /// 水面起伏幅度（像素）：应保持较小，模拟真实水面的轻微起伏，不是
    /// 夸张的波浪。
    public var waveAmplitude: CGFloat

    /// 起伏密度：越大起伏越密集（仍是低频，不会变成花纹）。
    public var waveFrequency: Float

    /// 起伏流动速度。
    public var waveSpeed: Float

    /// 折射强度（像素）：跨过水位线后，内容沿切向整体挪动的【恒定】
    /// 距离——这是“插入水里的筷子看起来断开错位”那道错位的宽度。
    public var refractionStrength: CGFloat

    /// 位移从 0 过渡到恒定值所跨越的窄条宽度（像素），只影响水位线附近
    /// 那道“阶跃”本身的软硬程度，不影响位移是否随深度继续变化（不会，
    /// 过渡完之后一直保持恒定）。越小这道错位越像硬边缘，越大越柔和。
    public var refractionRange: CGFloat

    /// 水色（水下叠加的颜色）。
    public var tint: Color

    /// 内发光（inner glow）颜色，紧贴水位线水下一侧的那条辉光。
    public var highlightColor: Color

    /// 水/空气边界的锐利度：只做 1px 抗锯齿的额外柔化余量（像素），
    /// 保持很小的值（默认 0）以呈现锐利边缘；调大会让边缘变模糊。
    public var softness: CGFloat

    /// 水体不透明度 0...1，独立于容器原始透明度。这是让“水看得见”的关键：
    /// 即便容器本身画得很淡（近乎透明的玻璃轮廓），水依然按这个值显示。
    public var bodyOpacity: Double

    /// 内发光强度：越大辉光越亮越明显。
    public var highlightIntensity: Float

    /// 内发光衰减范围（像素）：离水位线这个距离后辉光基本消失，越大
    /// 辉光带越厚。
    public var highlightRange: CGFloat

    /// 是否让水面自动起伏流动。关闭后水面完全静止（只由 `gravity` / `level` 决定形状）。
    public var isAnimating: Bool

    public init(gravity: CGVector = CGVector(dx: 0, dy: 1),
                level: CGFloat = 0.5,
                waveAmplitude: CGFloat = 3,
                waveFrequency: Float = 4,
                waveSpeed: Float = 1.0,
                refractionStrength: CGFloat = 18,
                refractionRange: CGFloat = 4,
                tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                highlightColor: Color = .white,
                softness: CGFloat = 0,
                bodyOpacity: Double = 0.7,
                highlightIntensity: Float = 0.9,
                highlightRange: CGFloat = 14,
                isAnimating: Bool = true) {
        self.gravity = gravity
        self.level = level
        self.waveAmplitude = waveAmplitude
        self.waveFrequency = waveFrequency
        self.waveSpeed = waveSpeed
        self.refractionStrength = refractionStrength
        self.refractionRange = refractionRange
        self.tint = tint
        self.highlightColor = highlightColor
        self.softness = softness
        self.bodyOpacity = bodyOpacity
        self.highlightIntensity = highlightIntensity
        self.highlightRange = highlightRange
        self.isAnimating = isAnimating
    }

    /// 折射最远采样距离：恒定位移量 refractionStrength（含 slope 调制
    /// 最多 ±60%，噪声抖动幅度很小），再加上 softness 留出的柔化边余量。
    private var maxSampleOffset: CGSize {
        let reach = refractionStrength * 1.6 + softness + CGFloat(4)
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
                        .color(highlightColor),
                        .float(Float(softness)),
                        .float(Float(bodyOpacity)),
                        .float(highlightIntensity),
                        .float(Float(refractionRange)),
                        .float(Float(highlightRange))
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
    /// 给任意视图套上“透明容器里的水”效果：水位线随重力倾斜（近乎平滑
    /// 直线），只有很轻微的低频起伏，边缘锐利；跨过水位线后内容整体
    /// 产生一段恒定的折射侧移，紧贴水位线水下一侧有一条均匀的内发光。
    /// 水的不透明度独立于容器本身透明度，因此即便容器画得很淡，水依然
    /// 清晰可见。
    ///
    /// - Parameters:
    ///   - gravity: 重力 / “下”方向，(0,1) 为竖直向下（水面持平）。默认 (0, 1)。
    ///   - level: 水位 0...1，0 = 空杯，1 = 满杯。默认 0.5。
    ///   - waveAmplitude: 水面起伏幅度（像素），保持较小。默认 3。
    ///   - waveFrequency: 起伏密度。默认 4。
    ///   - waveSpeed: 起伏流动速度。默认 1.0。
    ///   - refractionStrength: 折射强度（像素），跨过水位线后的恒定侧移
    ///     距离。默认 18。
    ///   - refractionRange: 位移从 0 过渡到恒定值的窄条宽度（像素），
    ///     越小这道错位越像硬边缘。默认 4。
    ///   - tint: 水色。默认深青蓝。
    ///   - highlightColor: 内发光颜色。默认白。
    ///   - softness: 边界额外柔化余量（像素），保持很小以呈现锐利边缘。默认 0。
    ///   - bodyOpacity: 水体不透明度 0...1，独立于容器透明度。默认 0.7。
    ///   - highlightIntensity: 内发光强度。默认 0.9。
    ///   - highlightRange: 内发光衰减范围（像素）。默认 14。
    ///   - isAnimating: 是否自动起伏流动。默认 true。
    func waterEffect(gravity: CGVector = CGVector(dx: 0, dy: 1),
                     level: CGFloat = 0.5,
                     waveAmplitude: CGFloat = 3,
                     waveFrequency: Float = 4,
                     waveSpeed: Float = 1.0,
                     refractionStrength: CGFloat = 18,
                     refractionRange: CGFloat = 4,
                     tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                     highlightColor: Color = .white,
                     softness: CGFloat = 0,
                     bodyOpacity: Double = 0.7,
                     highlightIntensity: Float = 0.9,
                     highlightRange: CGFloat = 14,
                     isAnimating: Bool = true) -> some View {
        modifier(WaterEffect(gravity: gravity,
                              level: level,
                              waveAmplitude: waveAmplitude,
                              waveFrequency: waveFrequency,
                              waveSpeed: waveSpeed,
                              refractionStrength: refractionStrength,
                              refractionRange: refractionRange,
                              tint: tint,
                              highlightColor: highlightColor,
                              softness: softness,
                              bodyOpacity: bodyOpacity,
                              highlightIntensity: highlightIntensity,
                              highlightRange: highlightRange,
                              isAnimating: isAnimating))
    }
}

// MARK: - 预览辅助

/// 一个有明显纹理的网格背景（类似瓷砖），专门用来让折射效果“看得出来”——
/// 纯色背景被扭曲后还是纯色，肉眼分辨不出位移，必须要有规则纹理做参照物。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct TiledPreviewBackground: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 24
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.10, green: 0.55, blue: 0.60)))
            var x: CGFloat = 0
            while x <= size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(.black.opacity(0.6)), lineWidth: 1.5)
                y += step
            }
        }
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 折射瓷砖背景（能明显看出扭曲）") {
    TiledPreviewBackground()
        .frame(width: 320, height: 420)
        .waterEffect(gravity: CGVector(dx: 0.3, dy: 1), level: 0.7)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 玻璃杯半杯水（瓷砖背景）") {
    TiledPreviewBackground()
        .frame(width: 160, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.4), lineWidth: 2))
        .waterEffect(level: 0.5)
        .padding(60)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 倾斜晃动（瓷砖背景）") {
    TiledPreviewBackground()
        .frame(width: 200, height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.3), lineWidth: 2))
        .waterEffect(gravity: CGVector(dx: 0.5, dy: 0.85), level: 0.6)
        .padding(60)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 文字下层被折射") {
    ZStack {
        TiledPreviewBackground()
        Text("TrueMetalShader")
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }
    .frame(width: 320, height: 420)
    .waterEffect(gravity: CGVector(dx: 0.35, dy: 1),
                level: 0.75,
                refractionStrength: 24)
    .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水面 · 插入水中的矩形（错位折射 + 内发光）") {
    ZStack {
        Color(red: 0.72, green: 0.85, blue: 0.90)
        RoundedRectangle(cornerRadius: 4)
            .fill(.black)
            .frame(width: 90, height: 160)
            .offset(y: -60)
    }
    .frame(width: 320, height: 400)
    .waterEffect(gravity: CGVector(dx: 0, dy: 1),
                level: 0.55,
                waveAmplitude: 14,
                waveFrequency: 3,
                refractionStrength: 26,
                tint: Color(red: 0.72, green: 0.90, blue: 0.95).opacity(0.35),
                bodyOpacity: 0.5,
                highlightIntensity: 1.0,
                highlightRange: 16)
    .background(.black)
}
