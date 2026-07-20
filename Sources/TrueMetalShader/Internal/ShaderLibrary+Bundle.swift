//
//  ShaderLibrary+Bundle.swift
//  TrueMetalShader
//
//  访问本 SPM 包内编译好的 Metal 着色器库。
//  ------------------------------------------------------------
//  SwiftPM 会把本 target 里所有 .metal 文件编译进 `Bundle.module` 的
//  default.metallib。默认的 `ShaderLibrary.default` 指向的是【宿主 App】
//  的主 bundle，拿不到包内的着色器，所以必须显式用 `.bundle(.module)`。
//
//  未来新增任意着色器（.metal）时，都会进入同一个 metallib，
//  统一通过 `ShaderLibrary.trueMetal.<函数名>(...)` 调用即可。
//
//  关于 SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE：
//  - Xcode 构建 SPM 时会编译 .metal 生成资源包，并自动定义该编译条件，
//    此时 `Bundle.module` 存在，走 `.bundle(.module)`。
//  - 命令行 `swift build` 目前不编译 .metal、也不生成资源包，该条件未定义，
//    退回 `.default` 以保证包本身仍能通过编译（真正的 Metal 运行时在 App/Xcode 侧）。
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, *)
extension ShaderLibrary {
    /// 本包内所有 `[[stitchable]]` 着色器所在的库。
    static let trueMetal: ShaderLibrary = {
        #if SWIFT_MODULE_RESOURCE_BUNDLE_AVAILABLE
        return .bundle(.module)
        #else
        return .default
        #endif
    }()
}
