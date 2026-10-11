# ANTuRide iOS 项目约束

## UI 与布局（强制）

任何 SwiftUI 页面、导航、组件、主题、排版、图表或交互改动，先阅读并遵循 [`design-system/anturide-ios/MASTER.md`](design-system/anturide-ios/MASTER.md)。页面级规则只能补充或收紧主约束，不能降低可访问性、数据可信度或系统交互要求。

- 项目最低版本为 iOS 16；原生 SwiftUI / Apple 系统组件优先。未经明确的产品/依赖决策，不添加第三方 UI 组件库。
- 维持现有五项顶层 Tab 与各 Tab 的原生导航行为；不要加第六项导致系统 `More`，不要覆盖系统返回手势。
- 复用 `Sources/DesignSystem/AppTheme.swift` 中的语义主题入口；不要在 Feature 页面散落原始颜色、固定字体和无规律间距。
- 所有可操作元素须有原生语义、可读标签、至少 44pt 触控区域和清楚的禁用/加载/错误反馈。
- UI 必须覆盖浅色/深色、Dynamic Type、VoiceOver、减少动态效果、小屏与横屏；实时数值不得把缺失/过期误显示为真实零值。
- 优先做小而可验证的改动。UI 变更后跑相关 Swift 测试/XCUITest；报告中区分静态检查、CI/模拟器与真实设备验收。

## 领域边界

- iOS 页面遵循 iOS 交互惯例，不为追求 Android 视觉像素级相似而替换系统导航或控件。
- RPM 加速测试的数据来源保持 RPM-only，不把 GPS/IMU 融合加入 UI。
- BLE、定位、日志与行程数据的现有本机隐私边界不可因 UI 设计而扩张。
