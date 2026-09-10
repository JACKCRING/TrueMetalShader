//
//  ParticleEffect.swift
//  TrueMetalShader
//
//  粒子消散 / 汇聚（particle dissolve / gather）效果的公开 API —— 让任意视图
//  「碎成粒子飘散」或「由粒子汇聚成它真实的样子」。
//  ------------------------------------------------------------
//  和库里其它效果一样是“一句话”修饰器，套在【任意视图】上即可。最常用的是
//  自驱动的 `particleDissolve(isVisible:)`：跟着一个布尔值双向播放——
//
//      struct DemoView: View {
//          @State private var shown = true
//          var body: some View {
//              VStack {
//                  Image("avatar")
//                      .resizable().scaledToFit()
//                      .frame(width: 200, height: 200)
//                      .particleDissolve(isVisible: shown)   // false→碎散，true→汇聚
//                  Button(shown ? "消散" : "汇聚") { shown.toggle() }
//              }
//          }
//      }
//
//  - `isVisible == true`：粒子汇聚成视图真实的样子（progress 1 → 0）。
//  - `isVisible == false`：视图碎成粒子飞散消失（progress 0 → 1）。
//  切换时会从“当前进度”接续播放，来回打断也顺滑。
//
//  进阶：`particleEffect(progress:)` 直接给 0...1 的进度（0 完好、1 全散），
//  该修饰器是 `Animatable` 的，可用 `withAnimation` 平滑驱动，或绑定滑块自控。
//
//  内部：把参数打包喂给 Particle.metal 的 `tms_particle`，通过 `.layerEffect`
//  作用在内容图层上。完好(progress≈0)时自动 `isEnabled=false` 零开销；完全
//  散尽(progress≈1)时把内容 `opacity` 置 0，省下 GPU。
//
//  关于「飞出边框」：粒子默认可以飞到 view 边框**外面**去（`ParticleConfig.margin`），
//  且**不改变 view 在布局中占用的尺寸**——内部先用正 padding 把着色器画布撑大给粒子
//  留出飞散空间，再用等量负 padding 把布局尺寸缩回原样，外溢部分照常绘制（SwiftUI
//  默认不裁剪）。设 `margin: 0` 可退回“裁在原边框内”的旧行为。
//

import SwiftUI

// MARK: - 参数打包

/// 粒子效果的全部可调项（均有合理默认值）。作为内部载体，避免各入口重复罗列。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct ParticleConfig: Equatable, Sendable {
    /// 粒子尺寸（点）：越小粒子越细、越多，细节越好但开销越大。默认 10。
    public var cellSize: Float
    /// 飞散距离（相对格数）：粒子最多飞多远（以自身尺寸为单位）。默认 3。
    public var travel: Float
    /// 全局风向（未归一化亦可）：粒子整体飘向。默认 (0, -0.6) 略微向上。
    public var direction: CGVector
    /// 跟随风向的强度 0...1。默认 0.35。
    public var driftAmount: Float
    /// 重力（相对格数，正值向下）：让飞散带点抛物线感。默认 0.4。
    public var gravity: Float
    /// 起飞时刻错开程度 0...1：越大粒子越是“先后”散开而非齐飞。默认 0.35。
    public var spread: Float
    /// 方向随机度 0...1：0=纯向外扩散，1=完全随机方向。默认 0.6。
    public var randomness: Float
    /// 自转幅度（弧度）：粒子飞散时的旋转。默认 1.5。
    public var spin: Float
    /// 末态缩放 0...1：粒子飞到尽头时缩到多小（0=缩没）。默认 0.15。
    public var shrink: Float
    /// 粒子形状 0...1：0 = 方形（矩），1 = 圆形（圆），中间为圆角方形。默认 0（方形）。
    public var roundness: Float
    /// 飞散时的余辉强度：>0 时飞行中的粒子带一点暖色自发光。默认 0.35。
    public var glow: Float
    /// 飘忽抖动（相对格数）：飞行中的细微游走，更“灵动”。默认 0.4。
    public var flutter: Float
    /// 生命中开始淡出的位置 0...1：越小越早开始变淡。默认 0.35。
    public var fade: Float
    /// 随机种子：换一个数就换一套散开形态。默认 0。
    public var seed: Float
    /// 允许粒子飞出 view 边框外多远（点）。
    /// - `nil`（默认）= 自动：正好等于粒子的最大飞散距离，粒子会完整飞出边框并在框外淡尽；
    /// - `0` = 不外溢，裁在原边框内（旧行为）；
    /// - 具体数值 = 自定义可外溢的范围。
    ///
    /// 关键：外溢**只影响绘制**，不改变 view 在布局中占用的尺寸（内部用等量正/负
    /// padding 实现）。但若祖先是 `ScrollView`/`List` 或用了 `.clipped()`，外溢仍会被
    /// 裁掉——那种情况在祖先上加 `.scrollClipDisabled()`（iOS 17+）即可放行。
    public var margin: CGFloat?

    public init(cellSize: Float = 10,
                travel: Float = 3,
                direction: CGVector = CGVector(dx: 0, dy: -0.6),
                driftAmount: Float = 0.35,
                gravity: Float = 0.4,
                spread: Float = 0.35,
                randomness: Float = 0.6,
                spin: Float = 1.5,
                shrink: Float = 0.15,
                roundness: Float = 0,
                glow: Float = 0.35,
                flutter: Float = 0.4,
                fade: Float = 0.35,
                seed: Float = 0,
                margin: CGFloat? = nil)
    {
        self.cellSize = cellSize
        self.travel = travel
        self.direction = direction
        self.driftAmount = driftAmount
        self.gravity = gravity
        self.spread = spread
        self.randomness = randomness
        self.spin = spin
        self.shrink = shrink
        self.roundness = roundness
        self.glow = glow
        self.flutter = flutter
        self.fade = fade
        self.seed = seed
        self.margin = margin
    }

    /// 粒子相对出发点的最大位移（点）。着色器搜索窗封顶 5 格，故此处同样封顶。
    var maxDisplacement: CGFloat {
        let cells = min(Double(travel) + abs(Double(gravity)) + Double(flutter) + 1.0, 5.0)
        return CGFloat(cells) * CGFloat(cellSize)
    }

    /// 着色器最远采样距离：粒子逆变换会采到离本像素最多约“最大位移”远的源，
    /// 必须留够余量，否则飞散的粒子会被裁掉。
    var maxSampleOffset: CGSize {
        CGSize(width: maxDisplacement, height: maxDisplacement)
    }

    /// 实际外溢余量（点）：`margin` 为 nil 时取“最大位移”，让粒子正好完整飞出框外。
    var resolvedMargin: CGFloat {
        max(margin ?? maxDisplacement, 0)
    }
}

// MARK: - 内部：套用着色器图层

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private extension View {
    /// 按给定进度/时间套上粒子着色器。progress: 0=完好，1=全散。
    @ViewBuilder
    func particleLayer(progress: Double, time: Float, config: ParticleConfig) -> some View {
        let p = min(max(progress, 0), 1)
        let hidden = p >= 0.999 // 完全散尽：隐藏内容省 GPU
        let showShader = p > 0.001 && !hidden // 完好时不启用着色器（零开销）
        let m = config.resolvedMargin // 外溢余量：撑大画布让粒子飞出框，最后再缩回布局
        // 先用正 padding 把着色器画布撑大（内容居中、四周透明），粒子便有地方飞出原边框。
        padding(m)
            .visualEffect { view, proxy in
                let size = proxy.size // = 原尺寸 + 2m
                return view.layerEffect(
                    ShaderLibrary.trueMetal.tms_particle(
                        .float2(size),
                        .float(Float(p)),
                        .float(time),
                        .float(config.cellSize),
                        .float(config.travel),
                        .float2(CGSize(width: config.direction.dx,
                                       height: config.direction.dy)),
                        .float(config.driftAmount),
                        .float(config.gravity),
                        .float(config.spread),
                        .float(config.randomness),
                        .float(config.spin),
                        .float(config.shrink),
                        .float(config.roundness),
                        .float(config.glow),
                        .float(config.flutter),
                        .float(config.fade),
                        .float(config.seed)
                    ),
                    maxSampleOffset: config.maxSampleOffset,
                    isEnabled: showShader
                )
            }
            // 等量负 padding：把布局尺寸缩回原样；外溢的粒子照常绘制（SwiftUI 默认不裁剪）。
            .padding(-m)
            .opacity(hidden ? 0 : 1)
    }
}

// MARK: - 进度驱动（进阶）

/// 直接以 0...1 进度驱动的粒子修饰器（0 = 完好，1 = 完全碎散）。
///
/// 本修饰器是 `Animatable` 的：用 `withAnimation` 改变 `progress` 即可平滑
/// 播放消散/汇聚，也可把 `progress` 绑到滑块上手动控制。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct ParticleEffect: ViewModifier, @preconcurrency Animatable {
    /// 0 = 完好的原视图；1 = 完全碎散消失。
    public var progress: Double
    public var config: ParticleConfig

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    public init(progress: Double, config: ParticleConfig = ParticleConfig()) {
        self.progress = progress
        self.config = config
    }

    public func body(content: Content) -> some View {
        // 用当前时钟提供飘忽/余辉所需的连续时间；withAnimation 逐帧重算时会随之推进。
        let time = Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10000))
        return content.particleLayer(progress: progress, time: time, config: config)
    }
}

// MARK: - 布尔自驱动（推荐）

/// 跟随一个布尔值双向播放的粒子修饰器：可见则汇聚成真实视图，不可见则碎散消失。
/// 内部用 `TimelineView` 自驱动连续时钟，切换时从当前进度接续，静止时自动暂停。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct ParticleDissolveEffect: ViewModifier {
    /// true = 汇聚（progress→0，显示真实视图）；false = 消散（progress→1，碎散消失）。
    public var isVisible: Bool
    /// 单次消散/汇聚时长（秒）。默认 1.2。
    public var duration: TimeInterval
    public var config: ParticleConfig

    // 动画状态：在 from→to 之间随时间插值；切换时以“当前进度”为新的 from 接续。
    @State private var from: Double = 0
    @State private var to: Double = 0
    @State private var start: Date = .init()
    @State private var running: Bool = false
    @State private var didInit: Bool = false

    public init(isVisible: Bool,
                duration: TimeInterval = 1.2,
                config: ParticleConfig = ParticleConfig())
    {
        self.isVisible = isVisible
        self.duration = duration
        self.config = config
    }

    /// 缓入缓出（smoothstep）。
    private func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// 给定时刻的插值进度。
    private func progress(at date: Date) -> Double {
        guard duration > 0 else { return to }
        let e = min(max(date.timeIntervalSince(start) / duration, 0), 1)
        return from + (to - from) * ease(e)
    }

    public func body(content: Content) -> some View {
        let paused = !running
        return TimelineView(.animation(paused: paused)) { timeline in
            let now = timeline.date
            let p = progress(at: now)
            let time = Float(now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10000))
            content.particleLayer(progress: p, time: time, config: config)
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            // 初始不播放动画，直接定格在对应状态（可见=0 完好，不可见=1 散尽）。
            let settled: Double = isVisible ? 0 : 1
            from = settled
            to = settled
        }
        .onChange(of: isVisible) { _, visible in
            let now = Date()
            from = progress(at: now) // 从当前进度接续，来回打断也顺滑
            to = visible ? 0 : 1
            start = now
            running = true
            // 到时停钟（定格在终态），静止时不空转。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1000000000))
                running = false
            }
        }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 跟随布尔值双向播放的粒子消散 / 汇聚效果（推荐，一句话调用）。
    ///
    /// - `isVisible == true`：粒子汇聚成视图真实的样子；
    /// - `isVisible == false`：视图碎成粒子飞散消失。
    ///
    /// 切换时从当前进度接续播放，反复来回也顺滑。
    ///
    /// - Parameters:
    ///   - isVisible: 目标可见性。true 汇聚显现，false 碎散消失。
    ///   - duration: 单次时长（秒）。默认 1.2。
    ///   - config: 粒子细节参数（尺寸/飞散/风向/重力/余辉等）。默认一套自然的飘散。
    func particleDissolve(isVisible: Bool,
                          duration: TimeInterval = 1.2,
                          config: ParticleConfig = ParticleConfig()) -> some View
    {
        modifier(ParticleDissolveEffect(isVisible: isVisible,
                                        duration: duration,
                                        config: config))
    }

    /// 以 0...1 进度直接驱动的粒子效果（进阶）：0 = 完好，1 = 完全碎散。
    ///
    /// 该修饰器 `Animatable`，可用 `withAnimation` 平滑播放，或把 `progress`
    /// 绑到滑块上手动控制“消散/汇聚”的中间态。
    ///
    /// - Parameters:
    ///   - progress: 碎散进度。0 完好、1 全散。
    ///   - config: 粒子细节参数。默认一套自然的飘散。
    func particleEffect(progress: Double,
                        config: ParticleConfig = ParticleConfig()) -> some View
    {
        modifier(ParticleEffect(progress: progress, config: config))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct ParticleDissolvePreview: View {
    @State private var shown = true
    var body: some View {
        VStack(spacing: 40) {
            Text(shown ? "点下面按钮 → 碎散消失" : "再点一次 → 汇聚显现")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(
                        LinearGradient(colors: [.pink, .orange],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                Text("粒子")
                    .font(.system(size: 96, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 260, height: 260)
//            .particleDissolve(isVisible: shown)
            .particleDissolve(isVisible: shown,
                              config: ParticleConfig(cellSize: 2,shrink: 10, roundness: 1))

            Button(shown ? "消散" : "汇聚") {
                withAnimation { shown.toggle() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 420, height: 560)
        .background(
            LinearGradient(colors: [.black, Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("粒子 · 消散/汇聚") {
    ParticleDissolvePreview()
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct ParticleSliderPreview: View {
    @State private var progress = 0.0
    var body: some View {
        VStack(spacing: 40) {
            Text("拖动滑块看中间态（0 完好 → 1 全散）")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Image(systemName: "swift")
                .font(.system(size: 140))
                .foregroundStyle(.orange)
                .frame(width: 240, height: 240)
                .particleEffect(progress: progress,
                                config: ParticleConfig(cellSize: 8, travel: 4,
                                                       roundness: 1, glow: 0.6))

            Slider(value: $progress, in: 0 ... 1)
                .frame(width: 260)
        }
        .padding(40)
        .frame(width: 420, height: 520)
        .background(.black)
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("粒子 · 进度滑块") {
    ParticleSliderPreview()
}
