//
//  WaterEffect.swift
//  TrueMetalShader
//
//  水面（water）效果的公开 API —— 核心、跨平台、无传感器依赖部分。
//  ------------------------------------------------------------
//  参考真实“手机端着一杯水”的观感来做：水面几乎是一条平滑的倾斜直线
//  （随重力倾斜），只有很轻微的低频起伏，边缘是柔和模糊的过渡（不是
//  锐利描边），水面附近有一层淡淡的渐变高光。折射 + 色散只在贴近水面
//  的一段距离内明显，越往深处越平淡（`refractionRange` 控制这段距离）——
//  这更符合真实水下光学：贴着水面能看清被扭曲、带彩边的画面，深一点
//  基本就看不透了。刻意不做夸张的波浪 / 高频花纹——那样会显得像连绵的
//  山峰，不像真实水面。
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

    /// 起伏 / 高光流动速度。
    public var waveSpeed: Float

    /// 折射强度（贴近水面处的最大值）：水面坡度 + 轻微噪声 → 采样偏移的
    /// 换算系数。保持较小，折射应该是隐约的，不是强烈扭曲。
    public var refractionStrength: CGFloat

    /// 折射 + 色散强度随深度衰减的范围（像素）：离水面这个距离内强度从
    /// 满值衰减到接近 0。越大，能看清折射画面的“透光层”越厚。
    public var refractionRange: CGFloat

    /// 色散（chromatic aberration）强度 0...1：R/G/B 通道采样位移量的
    /// 差异幅度，越大水面附近的彩边越明显。同样随深度衰减。
    public var chromaSpread: Float

    /// 水色（水下叠加的颜色）。
    public var tint: Color

    /// 水面附近渐变高光的颜色。
    public var highlightColor: Color

    /// 水/空气边界的柔和过渡宽度（像素）。越大边缘越模糊柔和（雾面玻璃
    /// 感），越小越接近锐利边缘。
    public var softness: CGFloat

    /// 水体不透明度 0...1，独立于容器原始透明度。这是让“水看得见”的关键：
    /// 即便容器本身画得很淡（近乎透明的玻璃轮廓），水依然按这个值显示。
    public var bodyOpacity: Double

    /// 表面渐变高光强度。
    public var highlightIntensity: Float

    /// 是否让水面自动起伏流动。关闭后水面完全静止（只由 `gravity` / `level` 决定形状）。
    public var isAnimating: Bool

    public init(gravity: CGVector = CGVector(dx: 0, dy: 1),
                level: CGFloat = 0.5,
                waveAmplitude: CGFloat = 3,
                waveFrequency: Float = 4,
                waveSpeed: Float = 1.0,
                refractionStrength: CGFloat = 22,
                refractionRange: CGFloat = 60,
                chromaSpread: Float = 0.6,
                tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                highlightColor: Color = Color(red: 0.75, green: 0.92, blue: 1.0),
                softness: CGFloat = 6,
                bodyOpacity: Double = 0.7,
                highlightIntensity: Float = 0.35,
                isAnimating: Bool = true) {
        self.gravity = gravity
        self.level = level
        self.waveAmplitude = waveAmplitude
        self.waveFrequency = waveFrequency
        self.waveSpeed = waveSpeed
        self.refractionStrength = refractionStrength
        self.refractionRange = refractionRange
        self.chromaSpread = chromaSpread
        self.tint = tint
        self.highlightColor = highlightColor
        self.softness = softness
        self.bodyOpacity = bodyOpacity
        self.highlightIntensity = highlightIntensity
        self.isAnimating = isAnimating
    }

    /// 折射最远采样距离：噪声扭曲 + 边界坡度的粗略上界，乘以色散展开的
    /// 最大倍数（1 + chromaSpread），再加上 softness 留出的柔化边余量。
    private var maxSampleOffset: CGSize {
        let warpReach = 0.6 * refractionStrength
        let slopeReach = waveAmplitude * CGFloat(waveFrequency) * 0.01 * refractionStrength
        let reach = (warpReach + slopeReach) * CGFloat(1 + max(0, chromaSpread)) + softness + CGFloat(4)
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
                        .float(chromaSpread),
                        .float(Float(refractionRange))
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
    /// 直线），只有很轻微的低频起伏，边缘柔和模糊过渡；折射 + 色散只在
    /// 贴近水面的一段距离内明显（越往深处越平淡，`refractionRange` 控制
    /// 这段距离），并叠加一层淡淡的渐变高光。水的不透明度独立于容器本身
    /// 透明度，因此即便容器画得很淡，水依然清晰可见。
    ///
    /// - Parameters:
    ///   - gravity: 重力 / “下”方向，(0,1) 为竖直向下（水面持平）。默认 (0, 1)。
    ///   - level: 水位 0...1，0 = 空杯，1 = 满杯。默认 0.5。
    ///   - waveAmplitude: 水面起伏幅度（像素），保持较小。默认 3。
    ///   - waveFrequency: 起伏密度。默认 4。
    ///   - waveSpeed: 起伏 / 高光流动速度。默认 1.0。
    ///   - refractionStrength: 折射强度（贴近水面处的最大值）。默认 22。
    ///   - refractionRange: 折射 + 色散强度衰减到接近 0 的距离（像素）。默认 60。
    ///   - chromaSpread: 色散强度 0...1，越大彩边越明显。默认 0.6。
    ///   - tint: 水色。默认深青蓝。
    ///   - highlightColor: 表面渐变高光颜色。默认浅青白。
    ///   - softness: 水/空气边界柔和过渡宽度（像素），越大越模糊。默认 6。
    ///   - bodyOpacity: 水体不透明度 0...1，独立于容器透明度。默认 0.7。
    ///   - highlightIntensity: 表面渐变高光强度。默认 0.35。
    ///   - isAnimating: 是否自动起伏流动。默认 true。
    func waterEffect(gravity: CGVector = CGVector(dx: 0, dy: 1),
                     level: CGFloat = 0.5,
                     waveAmplitude: CGFloat = 3,
                     waveFrequency: Float = 4,
                     waveSpeed: Float = 1.0,
                     refractionStrength: CGFloat = 22,
                     refractionRange: CGFloat = 60,
                     chromaSpread: Float = 0.6,
                     tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                     highlightColor: Color = Color(red: 0.75, green: 0.92, blue: 1.0),
                     softness: CGFloat = 6,
                     bodyOpacity: Double = 0.7,
                     highlightIntensity: Float = 0.35,
                     isAnimating: Bool = true) -> some View {
        modifier(WaterEffect(gravity: gravity,
                              level: level,
                              waveAmplitude: waveAmplitude,
                              waveFrequency: waveFrequency,
                              waveSpeed: waveSpeed,
                              refractionStrength: refractionStrength,
                              refractionRange: refractionRange,
                              chromaSpread: chromaSpread,
                              tint: tint,
                              highlightColor: highlightColor,
                              softness: softness,
                              bodyOpacity: bodyOpacity,
                              highlightIntensity: highlightIntensity,
                              isAnimating: isAnimating))
    }
}

// MARK: - 预览辅助

/// 一个有明显纹理的网格背景（类似瓷砖），专门用来让折射/色散效果“看得出来”——
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
#Preview("水面 · 折射瓷砖背景（能明显看出扭曲/色散）") {
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
                refractionStrength: 26,
                refractionRange: 70,
                chromaSpread: 0.7,
                softness: 10)
    .background(.black)
}
