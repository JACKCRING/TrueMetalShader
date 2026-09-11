//
//  WaterLensEffect.swift
//  TrueMetalShader
//
//  “液态水镜片”（liquid water lens）—— 浮在任意内容上方、能扭曲/色散
//  它【下方任意内容】的水滴透镜，视觉上接近系统 Liquid Glass 的悬浮镜片
//  效果，只不过是水滴质感（凸起液面 + 水色 + 更明显的边缘色散）。
//  ------------------------------------------------------------
//  为什么需要这个文件，而不是直接用 `WaterEffect`：
//
//  SwiftUI 的 `.layerEffect`（包括本包所有效果）只能读取“它被挂在哪个
//  view 上”这个 view 自己渲染出的像素，读不到 ZStack 里排在它下面、由
//  别的 view 画出来的内容——这是公开 API 的硬限制，系统 Liquid Glass
//  能读取任意 backdrop 是私有能力，第三方 Metal shader 拿不到。
//
//  本文件用公开 API 下唯一可行的办法达到同等视觉效果：
//
//      ZStack {
//          <你的背景内容 A>
//      }
//      .waterLensEffect(center: pos, size: CGSize(width: 120, height: 120))
//
//  内部会把 `<你的背景内容 A>` 整个再渲染一份（和背景同尺寸、同位置对齐），
//  在这份拷贝上套 `tms_waterLens` 着色器做“凸起液面”折射 + 色散，再用
//  镜片形状（圆 / 圆角矩形）裁出可见范围浮在最上层。镜片挪到哪，就“看
//  透”背景哪一块——效果上就是能扭曲下层任意内容的悬浮水镜。
//
//  代价：背景内容会被渲染两次（SwiftUI 公开 API 下唯一可行的方案），
//  内容越复杂开销越大，不建议在里面放大量子视图或高频重绘的内容。
//
//  想要“镜片跟手指拖动走”的效果，用 `.draggableWaterLensEffect(...)`，
//  内部自己管理拖拽状态；想自己驱动镜片位置（比如跟随别的动画），用
//  `.waterLensEffect(center:...)` 并自己传入变化的 `center`。
//

import SwiftUI

// MARK: - 镜片形状

/// 镜片的可见范围形状：椭圆（`cornerRadius` 达到最大时）或圆角矩形。
private struct WaterLensShape: Shape {
    var center: CGPoint
    var size: CGSize
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let lensRect = CGRect(x: center.x - size.width / 2,
                              y: center.y - size.height / 2,
                              width: size.width,
                              height: size.height)
        let radius = min(cornerRadius, min(size.width, size.height) / 2)
        return Path(roundedRect: lensRect, cornerRadius: radius)
    }
}

// MARK: - 修饰器（位置由外部驱动）

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct WaterLensEffect: ViewModifier {

    /// 镜片中心位置（本视图的 local 坐标，单位：point）。
    public var center: CGPoint
    /// 镜片尺寸。
    public var size: CGSize
    /// 镜片形状的圆角半径；设为 `size` 较短边的一半即得到椭圆/圆形镜片。
    public var cornerRadius: CGFloat

    /// 折射强度：液面坡度 → 采样偏移的换算系数，越大扭曲越明显（边缘
    /// 最强，中心几乎不偏移）。
    public var refractionStrength: CGFloat
    /// 色散强度 0...1，越大镜片边缘彩边越明显。
    public var chromaSpread: Float
    /// 水色（淡淡叠加在镜片上，alpha 控制浓度）。
    public var tint: Color
    /// 液面高光颜色。
    public var highlightColor: Color
    /// 高光强度。
    public var highlightIntensity: Float
    /// 液面轻微波纹幅度（0...1 归一化尺度），让镜片看起来是“活的”液体
    /// 而不是静止的玻璃。
    public var rippleAmplitude: Float
    /// 波纹流动速度。
    public var rippleSpeed: Float
    /// 是否让液面波纹自动流动。
    public var isAnimating: Bool

    public init(center: CGPoint,
                size: CGSize,
                cornerRadius: CGFloat? = nil,
                refractionStrength: CGFloat = 26,
                chromaSpread: Float = 0.8,
                tint: Color = Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.10),
                highlightColor: Color = .white,
                highlightIntensity: Float = 0.6,
                rippleAmplitude: Float = 0.05,
                rippleSpeed: Float = 1.0,
                isAnimating: Bool = true) {
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius ?? (min(size.width, size.height) / 2)
        self.refractionStrength = refractionStrength
        self.chromaSpread = chromaSpread
        self.tint = tint
        self.highlightColor = highlightColor
        self.highlightIntensity = highlightIntensity
        self.rippleAmplitude = rippleAmplitude
        self.rippleSpeed = rippleSpeed
        self.isAnimating = isAnimating
    }

    public func body(content: Content) -> some View {
        content.overlay(
            TimelineView(.animation(paused: !isAnimating)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let time = isAnimating ? Float(seconds.truncatingRemainder(dividingBy: 1000)) : 0
                let lensRadius = CGSize(width: size.width / 2, height: size.height / 2)
                // 采样最远距离：镜片半径 × 折射强度的粗略上界（发生在边缘，
                // 梯度幅度≈1），再乘色散展开倍数，留一点余量。
                let baseReach = max(lensRadius.width, lensRadius.height) * refractionStrength * 0.02
                let reach = baseReach * CGFloat(1 + max(0, chromaSpread)) + 4

                // 关键：把整块背景内容再渲染一份、保持与原背景完全相同的
                // 尺寸和位置对齐（overlay 天然保证这一点），在这份【完整】
                // 拷贝上套着色器——这样着色器采样到的“镜片周围一小圈”
                // 依然是正确的背景像素，而不是被提前裁切掉的空白。
                // 裁切成镜片形状是最后一步，只影响“显示范围”，不影响采样。
                content
                    .compositingGroup()
                    .visualEffect { view, _ in
                        view.layerEffect(
                            ShaderLibrary.trueMetal.tms_waterLens(
                                .float(time),
                                .float2(Float(center.x), Float(center.y)),
                                .float2(Float(lensRadius.width), Float(lensRadius.height)),
                                .float(Float(refractionStrength)),
                                .float(chromaSpread),
                                .color(tint),
                                .color(highlightColor),
                                .float(highlightIntensity),
                                .float(rippleAmplitude),
                                .float(rippleSpeed)
                            ),
                            maxSampleOffset: CGSize(width: reach, height: reach)
                        )
                    }
                    .clipShape(WaterLensShape(center: center, size: size, cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            }
        )
    }
}

// MARK: - View 便捷入口（位置由外部驱动）

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意内容叠加一枚“液态水镜片”，能扭曲 / 色散它【下方】的内容
    /// （原理：把该内容再渲染一份、裁成镜片形状浮在上层，见文件顶部说明）。
    ///
    /// - Parameters:
    ///   - center: 镜片中心位置（local 坐标）。
    ///   - size: 镜片尺寸。
    ///   - cornerRadius: 镜片圆角半径，默认取较短边一半（椭圆/圆形）。
    ///   - refractionStrength: 折射强度，边缘最强、中心几乎不偏移。默认 26。
    ///   - chromaSpread: 色散强度 0...1。默认 0.8。
    ///   - tint: 水色叠加（alpha 控制浓度）。默认淡蓝。
    ///   - highlightColor: 液面高光颜色。默认白。
    ///   - highlightIntensity: 高光强度。默认 0.6。
    ///   - rippleAmplitude: 液面轻微波纹幅度。默认 0.05。
    ///   - rippleSpeed: 波纹流动速度。默认 1.0。
    ///   - isAnimating: 是否自动流动波纹。默认 true。
    func waterLensEffect(center: CGPoint,
                         size: CGSize,
                         cornerRadius: CGFloat? = nil,
                         refractionStrength: CGFloat = 26,
                         chromaSpread: Float = 0.8,
                         tint: Color = Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.10),
                         highlightColor: Color = .white,
                         highlightIntensity: Float = 0.6,
                         rippleAmplitude: Float = 0.05,
                         rippleSpeed: Float = 1.0,
                         isAnimating: Bool = true) -> some View {
        modifier(WaterLensEffect(center: center,
                                 size: size,
                                 cornerRadius: cornerRadius,
                                 refractionStrength: refractionStrength,
                                 chromaSpread: chromaSpread,
                                 tint: tint,
                                 highlightColor: highlightColor,
                                 highlightIntensity: highlightIntensity,
                                 rippleAmplitude: rippleAmplitude,
                                 rippleSpeed: rippleSpeed,
                                 isAnimating: isAnimating))
    }
}

// MARK: - 可拖拽的便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct DraggableWaterLensEffect: ViewModifier {
    var size: CGSize
    var cornerRadius: CGFloat?
    var refractionStrength: CGFloat
    var chromaSpread: Float
    var tint: Color
    var highlightColor: Color
    var highlightIntensity: Float
    var rippleAmplitude: Float
    var rippleSpeed: Float

    @State private var center: CGPoint?
    @GestureState private var dragTranslation: CGSize = .zero

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let restingCenter = center ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let liveCenter = CGPoint(x: restingCenter.x + dragTranslation.width,
                                     y: restingCenter.y + dragTranslation.height)
            content
                .waterLensEffect(center: liveCenter,
                                 size: size,
                                 cornerRadius: cornerRadius,
                                 refractionStrength: refractionStrength,
                                 chromaSpread: chromaSpread,
                                 tint: tint,
                                 highlightColor: highlightColor,
                                 highlightIntensity: highlightIntensity,
                                 rippleAmplitude: rippleAmplitude,
                                 rippleSpeed: rippleSpeed)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            center = CGPoint(x: liveCenter.x, y: liveCenter.y)
                        }
                )
                .onAppear {
                    if center == nil {
                        center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                }
        }
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意内容叠加一枚可以用手指 / 鼠标拖动的“液态水镜片”，拖到哪
    /// 就扭曲 / 色散哪里的下层内容，类似把一枚水滴放在屏幕上拖着走。
    ///
    /// - Parameters:
    ///   - size: 镜片尺寸。默认 120×120。
    ///   - cornerRadius: 镜片圆角半径，默认取较短边一半（圆形）。
    ///   - refractionStrength: 折射强度。默认 26。
    ///   - chromaSpread: 色散强度 0...1。默认 0.8。
    ///   - tint: 水色叠加。默认淡蓝。
    ///   - highlightColor: 液面高光颜色。默认白。
    ///   - highlightIntensity: 高光强度。默认 0.6。
    ///   - rippleAmplitude: 液面轻微波纹幅度。默认 0.05。
    ///   - rippleSpeed: 波纹流动速度。默认 1.0。
    func draggableWaterLensEffect(size: CGSize = CGSize(width: 120, height: 120),
                                  cornerRadius: CGFloat? = nil,
                                  refractionStrength: CGFloat = 26,
                                  chromaSpread: Float = 0.8,
                                  tint: Color = Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.10),
                                  highlightColor: Color = .white,
                                  highlightIntensity: Float = 0.6,
                                  rippleAmplitude: Float = 0.05,
                                  rippleSpeed: Float = 1.0) -> some View {
        modifier(DraggableWaterLensEffect(size: size,
                                          cornerRadius: cornerRadius,
                                          refractionStrength: refractionStrength,
                                          chromaSpread: chromaSpread,
                                          tint: tint,
                                          highlightColor: highlightColor,
                                          highlightIntensity: highlightIntensity,
                                          rippleAmplitude: rippleAmplitude,
                                          rippleSpeed: rippleSpeed))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水镜片 · 拖动扭曲下层网格") {
    Canvas { context, size in
        let step: CGFloat = 24
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.10, green: 0.55, blue: 0.60)))
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
    .frame(width: 320, height: 420)
    .draggableWaterLensEffect(size: CGSize(width: 130, height: 130))
    .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("水镜片 · 浮在文字与图形上方") {
    ZStack {
        LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(spacing: 16) {
            Text("Liquid Water Lens")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(.white.opacity(0.8)).frame(width: 28, height: 28)
                        .overlay(Text("\(i)").font(.caption.bold()))
                }
            }
        }
    }
    .frame(width: 320, height: 300)
    .waterLensEffect(center: CGPoint(x: 160, y: 150), size: CGSize(width: 150, height: 150))
    .background(.black)
}
