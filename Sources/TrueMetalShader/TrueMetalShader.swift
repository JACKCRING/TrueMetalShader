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
//  - RainbowDisplacement（彩虹置换 / 色散）：`.rainbowDisplacementEffect(...)`
//                              波纹置换 + RGB 通道错位，作用于任意视图
//  - RainbowRipple（彩虹水波纹）：`.rainbowRippleEffect(...)`
//                              点击任意位置，从该点扩散一圈圈彩虹色水波
//  - Water（水面 / 透明容器水切面）：`.waterEffect(gravity:level:...)`
//                              水位线随重力倾斜、随时间起伏，水下折射 + 加深
//                              水色，交界处一条高光线；仅 iOS 还有
//                              `.waterGravityEffect(...)`，接 CoreMotion
//                              重力 + 弹簧晃动，端起手机就能晃水
//
//  ------------------------------------------------------------
//  扩展新效果（约定）：
//  1. 在 `Effects/<效果名>/` 下新增 `<效果名>.metal` 与对应的 Swift 封装；
//  2. `[[stitchable]]` 函数统一用 `tms_` 前缀，避免与其它库重名；
//  3. Swift 侧通过 `ShaderLibrary.trueMetal.<函数名>(...)` 访问（见
//     `Internal/ShaderLibrary+Bundle.swift`）；
//  4. 对外只暴露一个 `View` 扩展方法或容器，保持“一句话调用”的体验。
//
