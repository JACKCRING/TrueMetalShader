//
//  MetaballEffect.swift
//  TrueMetalShader
//
//  融球 / 融合（metaball / gooey）效果的公开 API。
//  ------------------------------------------------------------
//  用法一 · 修饰器（作用在已有的 ZStack / 布局上）：
//
//      ZStack {
//          Circle().frame(width: 100, height: 100).offset(x: -30)
//          Circle().frame(width: 100, height: 100).offset(x: 70)
//      }
//      .metaballEffect(radius: 10)
//      .frame(width: 400, height: 300)
//
//  用法二 · 容器（把子视图叠在一起并整体融合）：
//
//      MetaballContainer(radius: 20) {
//          Circle().fill(.pink).frame(width: 120, height: 120).offset(x: -45)
//          Circle().fill(.pink).frame(width: 120, height: 120).offset(x: 45)
//      }
//
//  内部实现：先把内容拍平(compositingGroup)并 `.blur`，让相邻内容的 alpha
//  光晕重叠，再用 Metaball.metal 里的 `tms_metaball` 着色器对 alpha 做阈值，
//  于是靠近的形状会融合成有机的一坨。适用于任何能渲染出 alpha 的内容。
//

import SwiftUI

// MARK: - 修饰器

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct MetaballEffect: ViewModifier {

    /// 模糊半径：越大，形状之间“够得越远”就能融合。
    public var radius: CGFloat

    /// alpha 阈值：决定融合体的“胖瘦”，范围通常 0...1。越低越“胖”。
    public var threshold: Float

    /// 额外羽化（默认 0 = 靠 fwidth 自动 1px 锐利抗锯齿）。调大 = 边缘更柔。
    public var softness: Float

    public init(radius: CGFloat = 18,
                threshold: Float = 0.5,
                softness: Float = 0) {
        self.radius = radius
        self.threshold = threshold
        self.softness = softness
    }

    public func body(content: Content) -> some View {
        content
            // 关键：先把所有子视图拍平成一层，模糊才会作用在“合并后的图”上，
            // 相邻形状的 alpha 才能叠加、越过阈值、连成脖子。
            // 缺了这句 = 各自模糊各自阈值 = 不融合。
            .compositingGroup()
            .blur(radius: radius)
            .layerEffect(
                ShaderLibrary.trueMetal.tms_metaball(.float(threshold), .float(softness)),
                maxSampleOffset: .zero
            )
    }
}

// MARK: - View 便捷入口

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public extension View {
    /// 给任意视图（通常是一个 ZStack）套上融球 / 融合效果。
    ///
    /// - Parameters:
    ///   - radius: 模糊半径，越大越容易“隔空”融合。默认 18。
    ///   - threshold: alpha 阈值，越低融合体越“胖”。默认 0.5。
    ///   - softness: 额外羽化，默认 0（边缘锐利）。
    func metaballEffect(radius: CGFloat = 18,
                        threshold: Float = 0.5,
                        softness: Float = 0) -> some View {
        modifier(MetaballEffect(radius: radius, threshold: threshold, softness: softness))
    }
}

// MARK: - 容器

/// 融合容器：把 `@ViewBuilder` 里的内容叠在一起并整体融合。
/// 子视图之间用 `.offset` / `.position` 摆位即可，靠近的会粘连。
@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
public struct MetaballContainer<Content: View>: View {

    private let radius: CGFloat
    private let threshold: Float
    private let softness: Float
    private let content: Content

    public init(radius: CGFloat = 18,
                threshold: Float = 0.5,
                softness: Float = 0,
                @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.threshold = threshold
        self.softness = softness
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
        }
        .metaballEffect(radius: radius, threshold: threshold, softness: softness)
    }
}

// MARK: - 预览

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("修饰器") {
    ZStack {
        Circle()
            .fill(.pink)
            .frame(width: 100, height: 100)
            .offset(x: -30)
        Circle()
            .fill(.pink)
            .frame(width: 100, height: 100)
            .offset(x: 70)
    }
    .metaballEffect(radius: 10)
    .frame(width: 400, height: 300)
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
#Preview("容器") {
    MetaballContainer(radius: 20, threshold: 0.5) {
        Circle()
            .fill(.pink)
            .frame(width: 130, height: 130)
            .offset(x: -45)
        RoundedRectangle(cornerRadius: 24)
            .fill(.pink)
            .frame(width: 130, height: 130)
            .offset(x: 45)
    }
    .frame(width: 360, height: 360)
    .background(.black)
}
