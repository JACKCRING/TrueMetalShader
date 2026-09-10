//
//  RainbowDisplacementEffect.swift
//  TrueMetalShader
//
//  彩虹置换 / 色散（rainbow displacement）效果的公开 API。
//  ------------------------------------------------------------
//  和融球（metaball）一样，这是一个“一句话”修饰器：套在【任意视图】上即可，
//  会对整张已渲染的图层做波纹置换 + RGB 通道错位，形成流动的彩虹色散。
//
//      Image("palm_tree")
//          .resizable()
//          .scaledToFit()
//          .rainbowDisplacementEffect()          // 默认自动流动
//
//      Text("Hello")
//          .font(.largeTitle)
//          .rainbowDisplacementEffect(strength: 8, rainbowIntensity: 0.7)
//
//  想要静止（自己用滑块/动画驱动相位）时把 isAnimating 设为 false，
//  并通过 `phase` 手动控制波纹位置。
//
//  内部实现：用 `TimelineView(.animation)` 驱动一个时间量，交给
//  RainbowDisplacement.metal 里的 `tms_rainbowDisplace` 着色器，
//  通过 `.layerEffect` 作用在内容图层上。适用于任何能渲染出像素的内容。
//

import SwiftUI

// MARK: - 修饰器

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct RainbowDisplacementEffect: ViewModifier {

    /// 置换强度（像素）：波纹把内容“推开”多少。越大越扭曲。
    public var strength: CGFloat

    /// 波纹密度：越大波纹越细密。
    public var frequency: Float

    /// 色散强度（0...1）：R/G/B 三通道错位的幅度，越大彩虹描边越明显。
    public var chromaSpread: Float

    /// 彩虹叠色浓度（0...1）：0 = 只有通道错位的天然色散，1 = 明显的彩虹流光。
    public var rainbowIntensity: Float

    /// 流动速度：波纹随时间移动的快慢（仅在 `isAnimating` 为 true 时生效）。
    public var speed: Float

    /// 是否自动流动。false 时用固定的 `phase` 作为时间量（可自行做动画）。
    public var isAnimating: Bool

    /// 静止时的相位（`isAnimating == false` 时生效），可自行绑定滑块/动画。
    public var phase: Float

    public init(strength: CGFloat = 6,
                frequency: Float = 12,
                chromaSpread: Float = 0.5,
                rainbowIntensity: Float = 0.5,
                speed: Float = 1.5,
                isAnimating: Bool = true,
                phase: Float = 0) {
        self.strength = strength
        self.frequency = frequency
        self.chromaSpread = chromaSpread
        self.rainbowIntensity = rainbowIntensity
        self.speed = speed
        self.isAnimating = isAnimating
        self.phase = phase
    }

    /// 着色器最远采样距离：波纹幅度 × 最大色散通道，额外留一点余量，
    /// 否则边缘会被裁掉、采样不到内容。
    private var maxSampleOffset: CGSize {
        let reach = strength * CGFloat(1 + max(0, chromaSpread)) + 2
        return CGSize(width: reach, height: reach)
    }

    public func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isAnimating)) { timeline in
            // 把绝对时间取模到一个有界区间，避免 float 在大数值下精度抖动。
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let time = isAnimating
                ? Float(seconds.truncatingRemainder(dividingBy: 1000)) * speed
                : phase

            content
                .layerEffect(
                    ShaderLibrary.trueMetal.tms_rainbowDisplace(
                        .float(time),
                        .float(Float(strength)),
                        .float(frequency),
                        .float(chromaSpread),
                        .float(rainbowIntensity)
                    ),
                    maxSampleOffset: maxSampleOffset
                )
        }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意视图套上彩虹置换 / 色散效果（默认自动流动）。
    ///
    /// - Parameters:
    ///   - strength: 置换强度（像素），越大越扭曲。默认 6。
    ///   - frequency: 波纹密度，越大波纹越细密。默认 12。
    ///   - chromaSpread: 色散强度 0...1，越大彩虹描边越明显。默认 0.5。
    ///   - rainbowIntensity: 彩虹叠色浓度 0...1。默认 0.5。
    ///   - speed: 流动速度（`isAnimating` 为 true 时生效）。默认 1.5。
    ///   - isAnimating: 是否自动流动。默认 true。
    ///   - phase: 静止时的相位（`isAnimating` 为 false 时生效）。默认 0。
    func rainbowDisplacementEffect(strength: CGFloat = 6,
                                   frequency: Float = 12,
                                   chromaSpread: Float = 0.5,
                                   rainbowIntensity: Float = 0.5,
                                   speed: Float = 1.5,
                                   isAnimating: Bool = true,
                                   phase: Float = 0) -> some View {
        modifier(RainbowDisplacementEffect(strength: strength,
                                           frequency: frequency,
                                           chromaSpread: chromaSpread,
                                           rainbowIntensity: rainbowIntensity,
                                           speed: speed,
                                           isAnimating: isAnimating,
                                           phase: phase))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("彩虹置换 · 文字") {
    Text("Rainbow")
        .font(.system(size: 64, weight: .black, design: .rounded))
        .foregroundStyle(.white)
        .padding(40)
        .rainbowDisplacementEffect(strength: 8, rainbowIntensity: 0.7)
        .frame(width: 400, height: 240)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("彩虹置换 · 形状") {
    RoundedRectangle(cornerRadius: 32)
        .fill(.cyan)
        .frame(width: 180, height: 180)
        .rainbowDisplacementEffect(strength: 10, frequency: 18, chromaSpread: 0.7)
        .frame(width: 360, height: 360)
        .background(.black)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("彩虹波点击 · 文字") {
    Text("JACKCRING")
        .font(.system(size: 64, weight: .black, design: .rounded))
        .foregroundStyle(.white)
        .padding(40)
        .rainbowRippleEffect(amplitude: 100,chromaSpread: 0.1,rainbowIntensity:20)
        .frame(width: 400, height: 240)
        .background(.black)
}

