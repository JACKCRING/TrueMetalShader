//
//  WaterMotion.swift
//  TrueMetalShader
//
//  “水位线跟着手机重力左右晃”的便捷入口（仅 iOS，依赖 CoreMotion）。
//  ------------------------------------------------------------
//  `WaterEffect` 本身只接受一个 `gravity` 方向，不读任何传感器，保持
//  跨平台。本文件在此基础上加一层：
//
//  1. 用 CMMotionManager 读设备重力向量的 x/y 分量；
//  2. 不直接把重力怼给着色器（那样水会“贴着”倾斜角度瞬间跟上，像刚体
//     斜面，没有液体感）——而是过一个欠阻尼弹簧，让水位角度带一点
//     过冲、回弹，再逐渐稳定，这才是“晃”的关键；
//  3. 每帧把弹簧的当前角度喂给 `WaterEffect`。
//
//  用法：
//
//      Image("photo")
//          .waterGravityEffect(level: 0.6)     // 端起手机试试左右倾斜
//
//  想要更细的控制（自己的水色、起伏参数等），把 `WaterGravitySource`
//  的 `gravity` 接到 `.waterEffect(gravity:...)` 上即可，两者可以自由
//  组合。
//

import SwiftUI

#if canImport(CoreMotion) && os(iOS)
import CoreMotion

// MARK: - 重力 + 弹簧晃动的观察对象

/// 读取设备重力方向，并用弹簧模型模拟“端着一杯水”的过冲/回弹晃动。
/// 仅 iOS 可用（依赖 CMMotionManager）。
@available(iOS 17.0, *)
@MainActor
public final class WaterGravitySource: ObservableObject {

    /// 喂给 `WaterEffect(gravity:)` 的当前晃动方向（已过弹簧平滑，非原始重力）。
    @Published public private(set) var gravity: CGVector = CGVector(dx: 0, dy: 1)

    private let motionManager = CMMotionManager()
    private var displayLink: CADisplayLink?

    // 弹簧状态：angle 是当前角度（弧度，0 = 正下方，逆时针为正），
    // velocity 是角速度。target 是设备重力换算出的目标角度。
    private var angle: CGFloat = 0
    private var angularVelocity: CGFloat = 0

    /// 弹簧刚度：越大，追赶目标角度越快。
    public var stiffness: CGFloat
    /// 弹簧阻尼：越小，过冲/回弹越明显（更“晃”）；越大越快稳定。
    public var damping: CGFloat
    /// 晃动幅度上限（弧度），避免设备大幅翻转时水面转过头。
    public var maxAngle: CGFloat

    public init(stiffness: CGFloat = 90, damping: CGFloat = 9, maxAngle: CGFloat = .pi * 0.42) {
        self.stiffness = stiffness
        self.damping = damping
        self.maxAngle = maxAngle
    }

    /// 开始读取重力并驱动弹簧。多次调用是安全的（不会重复启动）。
    public func start() {
        guard motionManager.isDeviceMotionAvailable, displayLink == nil else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 停止读取重力，释放传感器与显示链接。
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        motionManager.stopDeviceMotionUpdates()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let motion = motionManager.deviceMotion else { return }

        // CMMotionManager 的重力向量：z 朝屏幕外，x 向右为正，y 向上为正。
        // 屏幕坐标 y 向下为正，所以这里要翻转 y。
        let g = motion.gravity
        let targetAngle = (CGFloat(atan2(g.x, -g.y))).clamped(to: -maxAngle...maxAngle)

        // 显式欧拉积分的阻尼弹簧：把 angle 拉向 targetAngle，
        // 但带惯性与阻尼 → 过冲再回弹，而不是瞬间贴合。
        let dt: CGFloat = 1.0 / 60.0
        let displacement = angle - targetAngle
        let springForce = -stiffness * displacement
        let dampingForce = -damping * angularVelocity
        angularVelocity += (springForce + dampingForce) * dt
        angle += angularVelocity * dt

        gravity = CGVector(dx: sin(angle), dy: cos(angle))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - 修饰器

@available(iOS 17.0, *)
public struct WaterGravityEffect: ViewModifier {

    @StateObject private var source: WaterGravitySource

    public var level: CGFloat
    public var waveAmplitude: CGFloat
    public var waveFrequency: Float
    public var waveSpeed: Float
    public var refractionStrength: CGFloat
    public var tint: Color
    public var highlightColor: Color
    public var softness: CGFloat
    public var bodyOpacity: Double
    public var highlightIntensity: Float

    public init(level: CGFloat = 0.5,
                waveAmplitude: CGFloat = 3,
                waveFrequency: Float = 4,
                waveSpeed: Float = 1.0,
                refractionStrength: CGFloat = 4,
                tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                highlightColor: Color = Color(red: 0.75, green: 0.92, blue: 1.0),
                softness: CGFloat = 6,
                bodyOpacity: Double = 0.75,
                highlightIntensity: Float = 0.35,
                stiffness: CGFloat = 90,
                damping: CGFloat = 9) {
        self.level = level
        self.waveAmplitude = waveAmplitude
        self.waveFrequency = waveFrequency
        self.waveSpeed = waveSpeed
        self.refractionStrength = refractionStrength
        self.tint = tint
        self.highlightColor = highlightColor
        self.softness = softness
        self.bodyOpacity = bodyOpacity
        self.highlightIntensity = highlightIntensity
        _source = StateObject(wrappedValue: WaterGravitySource(stiffness: stiffness, damping: damping))
    }

    public func body(content: Content) -> some View {
        content
            .waterEffect(gravity: source.gravity,
                        level: level,
                        waveAmplitude: waveAmplitude,
                        waveFrequency: waveFrequency,
                        waveSpeed: waveSpeed,
                        refractionStrength: refractionStrength,
                        tint: tint,
                        highlightColor: highlightColor,
                        softness: softness,
                        bodyOpacity: bodyOpacity,
                        highlightIntensity: highlightIntensity)
            .onAppear { source.start() }
            .onDisappear { source.stop() }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, *)
public extension View {
    /// 给任意视图套上“透明容器里的水”效果，水位线跟着手机重力左右晃
    /// （带过冲/回弹的液体手感，而不是瞬间贴合的斜面）。仅 iOS 可用。
    ///
    /// - Parameters:
    ///   - level: 水位 0...1，0 = 空杯，1 = 满杯。默认 0.5。
    ///   - waveAmplitude: 水面起伏幅度（像素），保持较小。默认 3。
    ///   - waveFrequency: 起伏密度。默认 4。
    ///   - waveSpeed: 起伏 / 高光流动速度。默认 1.0。
    ///   - refractionStrength: 折射强度，保持较小。默认 4。
    ///   - tint: 水色。默认深青蓝。
    ///   - highlightColor: 表面渐变高光颜色。默认浅青白。
    ///   - softness: 水/空气边界柔和过渡宽度（像素）。默认 6。
    ///   - bodyOpacity: 水体不透明度 0...1，独立于容器透明度。默认 0.75。
    ///   - highlightIntensity: 表面渐变高光强度。默认 0.35。
    ///   - stiffness: 晃动弹簧刚度，越大追赶越快。默认 90。
    ///   - damping: 晃动弹簧阻尼，越小越晃、越大越快稳定。默认 9。
    func waterGravityEffect(level: CGFloat = 0.5,
                            waveAmplitude: CGFloat = 3,
                            waveFrequency: Float = 4,
                            waveSpeed: Float = 1.0,
                            refractionStrength: CGFloat = 4,
                            tint: Color = Color(red: 0.05, green: 0.35, blue: 0.55),
                            highlightColor: Color = Color(red: 0.75, green: 0.92, blue: 1.0),
                            softness: CGFloat = 6,
                            bodyOpacity: Double = 0.75,
                            highlightIntensity: Float = 0.35,
                            stiffness: CGFloat = 90,
                            damping: CGFloat = 9) -> some View {
        modifier(WaterGravityEffect(level: level,
                                    waveAmplitude: waveAmplitude,
                                    waveFrequency: waveFrequency,
                                    waveSpeed: waveSpeed,
                                    refractionStrength: refractionStrength,
                                    tint: tint,
                                    highlightColor: highlightColor,
                                    softness: softness,
                                    bodyOpacity: bodyOpacity,
                                    highlightIntensity: highlightIntensity,
                                    stiffness: stiffness,
                                    damping: damping))
    }
}

#endif
