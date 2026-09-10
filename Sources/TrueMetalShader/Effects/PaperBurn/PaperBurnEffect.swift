//
//  PaperBurnEffect.swift
//  TrueMetalShader
//
//  纸张燃烧蔓延（paper burn）效果的公开 API —— 点哪烧哪、火自然向外蔓延。
//  ------------------------------------------------------------
//  和库里其它效果一样是“一句话”修饰器，套在【任意视图】上即可：
//
//      struct DemoView: View {
//          @State private var ignite = false
//          var body: some View {
//              Image("paperFigure")
//                  .frame(width: 200, height: 300)
//                  .paperBurn(trigger: $ignite)   // 点纸面任意处从该点起火蔓延
//          }
//      }
//
//  **可连点多处、各自蔓延**：每次点击在该处点一处火，火线从各火源向外扩张、相遇后
//  连成一片，最终把纸烧穿（透出背景）。修饰器内部维护火源列表，用 `TimelineView`
//  驱动连续时钟，把所有火源（各自位置/进度/随机 seed）+ 全局时间打包喂给
//  PaperBurn.metal 的 `tms_paperBurn` 逐点求火前、取并集上色。全部烧完后时钟自动
//  暂停（定格保留烧尽状态），零开销；视图消失即随 SwiftUI 释放。
//
//  `trigger` 由外部置 true 也会新增一处火（以视图中心为火源），随后自动写回 false，
//  可反复触发；`onComplete` 在每处火烧完时回调。
//

import SwiftUI

// MARK: - 火源

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct BurnSource: Identifiable {
    let id = UUID()
    var origin: CGPoint   // (-1,-1) 表示用视图中心
    var start: Date
    var seed: Float
}

// MARK: - 修饰器

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct PaperBurnEffect: ViewModifier {
    /// 置 true 新增一处（以视图中心为火源的）火；随后自动写回 false，可反复触发。
    @Binding var trigger: Bool

    /// 每处火烧完时的回调。
    var onComplete: (() -> Void)?

    // 进阶可调项，均有合理默认值。
    var duration: TimeInterval
    var radius: Float
    var burnReach: Float
    var edgeWidth: Float
    var glow: Float
    var tearCount: Float
    var irregularity: Float
    var flicker: Float
    var seed: Float

    /// 累积的火源列表（连点多处，各自蔓延）。
    @State private var sources: [BurnSource] = []
    /// 仍在蔓延中的火源数量：>0 时时钟运行，归 0 时暂停（烧尽状态定格）。
    @State private var activeCount: Int = 0

    private let maxSources = 16

    public init(trigger: Binding<Bool>,
                duration: TimeInterval = 3.0,
                radius: Float = 0.5,
                burnReach: Float = 2.5,
                edgeWidth: Float = 1.0,
                glow: Float = 0.85,
                tearCount: Float = 2,
                irregularity: Float = 1.0,
                flicker: Float = 1.0,
                seed: Float = 0,
                onComplete: (() -> Void)? = nil)
    {
        self._trigger = trigger
        self.duration = duration
        self.radius = radius
        self.burnReach = burnReach
        self.edgeWidth = edgeWidth
        self.glow = glow
        self.tearCount = tearCount
        self.irregularity = irregularity
        self.flicker = flicker
        self.seed = seed
        self.onComplete = onComplete
    }

    public func body(content: Content) -> some View {
        // 快照参数为局部值，供 @Sendable 闭包安全捕获。
        let radius = radius
        let burnReach = burnReach
        let edgeWidth = edgeWidth
        let glow = glow
        let tearCount = tearCount
        let irregularity = irregularity
        let flicker = flicker
        let duration = duration
        let sourcesSnap = sources
        // 没有火在烧时暂停时钟（烧尽状态定格），静止时不空转。
        let paused = activeCount == 0

        return TimelineView(.animation(paused: paused)) { timeline in
            let nowRef = timeline.date.timeIntervalSinceReferenceDate
            // 火焰闪烁用的连续时间，取模避免大数值下精度抖动。
            let time = Float(nowRef.truncatingRemainder(dividingBy: 10000))

            var packed: [Float] = []
            packed.reserveCapacity(sourcesSnap.count * 4)
            for src in sourcesSnap {
                let elapsed = nowRef - src.start.timeIntervalSinceReferenceDate
                let p = Float(min(max(elapsed / duration, 0), 1))
                packed.append(Float(src.origin.x))
                packed.append(Float(src.origin.y))
                packed.append(p)
                packed.append(src.seed)
            }
            let hasFire = !packed.isEmpty
            let safePacked = hasFire ? packed : [Float](repeating: 0, count: 4)

            return content.visualEffect { view, proxy in
                let size = proxy.size
                return view.layerEffect(
                    ShaderLibrary.trueMetal.tms_paperBurn(
                        .float2(size),
                        .floatArray(safePacked),
                        .float(time),
                        .float(radius),
                        .float(burnReach),
                        .float(edgeWidth),
                        .float(glow),
                        .float(tearCount),
                        .float(irregularity),
                        .float(flicker)
                    ),
                    maxSampleOffset: .zero,
                    isEnabled: hasFire
                )
            }
        }
        // 让整块区域（含透明处）都可点击 → 点哪烧哪，可连点多处。
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { value in ignite(at: value.location) }
        )
        .onChange(of: trigger) { _, isOn in
            guard isOn else { return }
            ignite(at: nil)      // 程序化触发：以视图中心为火源
            trigger = false
        }
    }

    /// 新增一处火并启动它的计时（累积，不重置已有火）。
    @MainActor
    private func ignite(at location: CGPoint?) {
        let src = BurnSource(origin: location ?? CGPoint(x: -1, y: -1),
                             start: Date(),
                             seed: seed + Float.random(in: 0 ..< 128))
        sources.append(src)
        if sources.count > maxSources {
            sources.removeFirst(sources.count - maxSources)
        }
        activeCount += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            activeCount = max(0, activeCount - 1)
            onComplete?()
        }
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意视图套上纸张燃烧蔓延（点哪烧哪）效果。
    ///
    /// **点哪起火，且可连点多处**：每次点击在该处点一处火，火线向外蔓延、相遇连片，
    /// 最终把纸烧穿透出背景。也可由外部把 `trigger` 置 true 触发（以视图中心为火源），
    /// 随后自动写回 false，可反复触发。
    ///
    /// - Parameters:
    ///   - trigger: 置 true 新增一处（中心）火；随后自动写回 false。
    ///   - onComplete: 每处火烧完时的回调。
    func paperBurn(trigger: Binding<Bool>,
                   onComplete: (() -> Void)? = nil) -> some View
    {
        modifier(PaperBurnEffect(trigger: trigger, onComplete: onComplete))
    }

    /// 进阶入口：可细调蔓延范围/速度、火线宽度、发光、边缘不规则与闪烁、时长等。
    ///
    /// - Parameters:
    ///   - trigger: 置 true 新增一处（中心）火；随后自动写回 false。
    ///   - duration: 单处火从裂开到烧完的时长（秒）。默认 3.0。
    ///   - radius: 裂纹长度尺度（相对最远角落比例，越小裂纹越短、破坏越集中）。默认 0.5。
    ///   - burnReach: 火从裂纹向外蔓延的最大距离（相对一格，越大烧掉的范围越大）。默认 2.5。
    ///   - edgeWidth: 火线（余烬+焦化）宽度尺度（越大火线越宽）。默认 1.0。
    ///   - glow: 余烬发光强度。默认 0.85。
    ///   - tearCount: 每处裂纹条数上限（每次随机 1~2 条）。默认 2。
    ///   - irregularity: 火/裂纹边缘不规则程度（越大越蜿蜒）。默认 1.0。
    ///   - flicker: 火焰闪烁强度。默认 1.0。
    ///   - seed: 随机种子基准。每处火在此基础上再叠加随机量，所以每处/每次都不同。默认 0。
    ///   - onComplete: 每处火烧完时的回调。
    func paperBurn(trigger: Binding<Bool>,
                   duration: TimeInterval = 3.0,
                   radius: Float = 0.5,
                   burnReach: Float = 2.5,
                   edgeWidth: Float = 1.0,
                   glow: Float = 0.85,
                   tearCount: Float = 2,
                   irregularity: Float = 1.0,
                   flicker: Float = 1.0,
                   seed: Float = 0,
                   onComplete: (() -> Void)? = nil) -> some View
    {
        modifier(PaperBurnEffect(trigger: trigger,
                                 duration: duration,
                                 radius: radius,
                                 burnReach: burnReach,
                                 edgeWidth: edgeWidth,
                                 glow: glow,
                                 tearCount: tearCount,
                                 irregularity: irregularity,
                                 flicker: flicker,
                                 seed: seed,
                                 onComplete: onComplete))
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
private struct PaperBurnPreview: View {
    @State private var ignite = false
    var body: some View {
        VStack(spacing: 32) {
            Text("连点多处，火各自蔓延")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.95))
                Text("人")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .frame(width: 240, height: 320)
            .paperBurn(trigger: $ignite)

            Button("从中心点火") { ignite = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 420, height: 600)
        .background(
            LinearGradient(colors: [.black, Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("纸张燃烧 · 连点蔓延") {
    PaperBurnPreview()
}
