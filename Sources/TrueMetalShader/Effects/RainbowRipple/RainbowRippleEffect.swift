//
//  RainbowRippleEffect.swift
//  TrueMetalShader
//
//  彩虹水波纹（rainbow ripple）—— 点哪里，哪里就散开一圈圈彩虹色水波。
//  ------------------------------------------------------------
//  和融球 / 彩虹置换一样是“一句话”修饰器，套在【任意视图】上即可：
//
//      Image("photo")
//          .resizable()
//          .scaledToFit()
//          .rainbowRippleEffect()          // 点击视图任意位置 → 从该点扩散水波
//
//  它内部自己处理点击手势（跨平台：iOS 轻点 / macOS 点击，用 SpatialTapGesture，
//  不依赖 UIKit），记录点击点作为波源，再用 keyframeAnimator 把“已经过时间”
//  从 0 动画到 duration，交给 RainbowRipple.metal 的 `tms_rainbowRipple`
//  着色器做径向置换 + 色散。
//
//  想手动控制波纹进度（例如自己用滑块 / 动画驱动、或统一驱动多处波纹）时，
//  直接用底层的 `RainbowRippleModifier(origin:elapsedTime:duration:...)`。
//

import SwiftUI

// MARK: - 着色器修饰器（手动控制波纹进度）

/// 只负责“把水波着色器贴到内容上”。你需要自己提供波源 `origin` 与已经过时间
/// `elapsedTime`（通常配合动画驱动）。想要“点击自动扩散”，用下面的
/// `RainbowRippleEffect` / `.rainbowRippleEffect()` 即可。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct RainbowRippleModifier: ViewModifier {

    /// 波源（点击点），与视图 local 坐标一致（单位：point）。
    public var origin: CGPoint
    /// 已经过的时间，驱动波纹向外扩散并衰减。
    public var elapsedTime: TimeInterval
    /// 单次波纹的总时长（超过后自动关闭着色器）。
    public var duration: TimeInterval
    /// 波纹起伏幅度（像素）。
    public var amplitude: Double
    /// 波纹密度（一圈圈的疏密）。
    public var frequency: Double
    /// 衰减速度，越大水波消失越快。
    public var decay: Double
    /// 扩散速度（像素/秒），越大圈扩得越快。
    public var speed: Double
    /// 色散强度 0...1，越大波纹边缘彩虹描边越明显。
    public var chromaSpread: Float
    /// 彩虹叠色浓度 0...1。
    public var rainbowIntensity: Float

    public init(origin: CGPoint,
                elapsedTime: TimeInterval,
                duration: TimeInterval,
                amplitude: Double = 12,
                frequency: Double = 15,
                decay: Double = 8,
                speed: Double = 1200,
                chromaSpread: Float = 0.5,
                rainbowIntensity: Float = 0.6) {
        self.origin = origin
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.amplitude = amplitude
        self.frequency = frequency
        self.decay = decay
        self.speed = speed
        self.chromaSpread = chromaSpread
        self.rainbowIntensity = rainbowIntensity
    }

    public func body(content: Content) -> some View {
        let shader = ShaderLibrary.trueMetal.tms_rainbowRipple(
            .float2(origin),
            .float(Float(elapsedTime)),
            .float(Float(amplitude)),
            .float(Float(frequency)),
            .float(Float(decay)),
            .float(Float(speed)),
            .float(chromaSpread),
            .float(rainbowIntensity)
        )
        // 采样最远距离：波幅 × 最大色散通道 + 余量，避免边缘被裁掉、采样不到内容。
        let reach = amplitude * Double(1 + max(0, chromaSpread)) + 2
        let maxSampleOffset = CGSize(width: reach, height: reach)
        let elapsedTime = elapsedTime
        let duration = duration
        return content.visualEffect { view, _ in
            view.layerEffect(
                shader,
                maxSampleOffset: maxSampleOffset,
                // 只有在波纹进行中才启用着色器，静止时零开销、零副作用。
                isEnabled: 0 < elapsedTime && elapsedTime < duration
            )
        }
    }
}

// MARK: - 交互修饰器（点击自动扩散）

/// 点击视图任意位置，从该点扩散一圈圈彩虹色水波。自己管理波源与动画，
/// 直接套在任意视图上即可用。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct RainbowRippleEffect: ViewModifier {

    public var amplitude: Double
    public var frequency: Double
    public var decay: Double
    public var speed: Double
    public var duration: TimeInterval
    public var chromaSpread: Float
    public var rainbowIntensity: Float

    @State private var origin: CGPoint = .zero
    @State private var counter: Int = 0

    public init(amplitude: Double = 12,
                frequency: Double = 15,
                decay: Double = 8,
                speed: Double = 1200,
                duration: TimeInterval = 3,
                chromaSpread: Float = 0.5,
                rainbowIntensity: Float = 0.6) {
        self.amplitude = amplitude
        self.frequency = frequency
        self.decay = decay
        self.speed = speed
        self.duration = duration
        self.chromaSpread = chromaSpread
        self.rainbowIntensity = rainbowIntensity
    }

    public func body(content: Content) -> some View {
        // 在（主线程隔离的）body 里先把当前波源与参数快照成局部值，
        // 供下面 @Sendable 的动画闭包安全捕获（避免直接引用 @State / 主线程隔离成员）。
        // 每次点击都会更新 origin 与 counter → body 重跑 → 闭包捕获到最新波源。
        let rippleOrigin = origin
        let amplitude = amplitude
        let frequency = frequency
        let decay = decay
        let speed = speed
        let duration = duration
        let chromaSpread = chromaSpread
        let rainbowIntensity = rainbowIntensity
        // 采样最远距离：波幅 × 最大色散通道 + 余量，避免边缘被裁掉、采样不到内容。
        let reach = amplitude * Double(1 + max(0, chromaSpread)) + 2
        let maxSampleOffset = CGSize(width: reach, height: reach)

        return content
            // 让整块区域（含透明处）都可点击，实现“点哪里都散开”。
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        origin = value.location
                        counter &+= 1
                    }
            )
            // 每次点击 counter 变化 → 把 elapsedTime 从 0 线性动画到 duration。
            .keyframeAnimator(initialValue: 0.0, trigger: counter) { view, elapsedTime in
                view.visualEffect { proxyView, _ in
                    proxyView.layerEffect(
                        ShaderLibrary.trueMetal.tms_rainbowRipple(
                            .float2(rippleOrigin),
                            .float(Float(elapsedTime)),
                            .float(Float(amplitude)),
                            .float(Float(frequency)),
                            .float(Float(decay)),
                            .float(Float(speed)),
                            .float(chromaSpread),
                            .float(rainbowIntensity)
                        ),
                        maxSampleOffset: maxSampleOffset,
                        // 只有在波纹进行中才启用着色器，静止时零开销、零副作用。
                        isEnabled: 0 < elapsedTime && elapsedTime < duration
                    )
                }
            } keyframes: { _ in
                MoveKeyframe(0)
                LinearKeyframe(duration, duration: duration)
            }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 点击视图任意位置，从该点扩散一圈圈彩虹色水波纹。
    ///
    /// - Parameters:
    ///   - amplitude: 波纹起伏幅度（像素）。默认 12。
    ///   - frequency: 波纹密度。默认 15。
    ///   - decay: 衰减速度，越大水波消失越快。默认 8。
    ///   - speed: 扩散速度（像素/秒）。默认 1200。
    ///   - duration: 单次水波总时长（秒）。默认 3。
    ///   - chromaSpread: 色散强度 0...1。默认 0.5。
    ///   - rainbowIntensity: 彩虹叠色浓度 0...1。默认 0.6。
    func rainbowRippleEffect(amplitude: Double = 12,
                             frequency: Double = 15,
                             decay: Double = 8,
                             speed: Double = 1200,
                             duration: TimeInterval = 3,
                             chromaSpread: Float = 0.5,
                             rainbowIntensity: Float = 0.6) -> some View {
        modifier(RainbowRippleEffect(amplitude: amplitude,
                                     frequency: frequency,
                                     decay: decay,
                                     speed: speed,
                                     duration: duration,
                                     chromaSpread: chromaSpread,
                                     rainbowIntensity: rainbowIntensity))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("彩虹水波纹 · 点击扩散") {
    ZStack {
        LinearGradient(colors: [.blue, .indigo, .purple, .pink],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        Text("点我")
            .font(.system(size: 44, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
    }
    .frame(width: 360, height: 360)
    .clipShape(RoundedRectangle(cornerRadius: 28))
    .rainbowRippleEffect()
    .padding()
}
