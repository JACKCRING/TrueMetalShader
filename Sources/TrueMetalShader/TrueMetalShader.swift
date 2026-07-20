// The Swift Programming Language
// https://docs.swift.org/swift-book
//
//  TrueMetalShader
//  ============================================================
//  一组开箱即用的 SwiftUI + Metal 视觉效果集合。
//  以极简的调用方式给任意视图添加着色器效果，例如：
//
//      import TrueMetalShader
//
//      ZStack {
//          Circle().frame(width: 100, height: 100).offset(x: -30)
//          Circle().frame(width: 100, height: 100).offset(x: 70)
//      }
//      .metaballEffect(radius: 10)   // 融球 / 融合效果
//      .frame(width: 400, height: 300)
//
//  已包含的效果：
//  - Metaball（融球 / gooey）：`.metaballEffect(radius:threshold:softness:)`
//                              或容器 `MetaballContainer { ... }`
//
//  ------------------------------------------------------------
//  扩展新效果（约定）：
//  1. 在 `Effects/<效果名>/` 下新增 `<效果名>.metal` 与对应的 Swift 封装；
//  2. `[[stitchable]]` 函数统一用 `tms_` 前缀，避免与其它库重名；
//  3. Swift 侧通过 `ShaderLibrary.trueMetal.<函数名>(...)` 访问（见
//     `Internal/ShaderLibrary+Bundle.swift`）；
//  4. 对外只暴露一个 `View` 扩展方法或容器，保持“一句话调用”的体验。
//
