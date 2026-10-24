# 加速测试对齐上游升级方案（P0–P3）

> 参考上游：`D:\daima\bms\GPS_ANT_BMS`（Android/Jetpack Compose，`ui/AccelerationTestScreen.kt` 与 `acceleration/` 包）。
> 本文记录对照结论、逐项方案、明确不采纳项与本批实施状态；施工明细见 `docs/CONSTRUCTION_LOG.md` 步骤 047。
> 方案基线时间：北京时间 2026-10-25。

## 1. 背景与结论

- iOS 现有加速测试的「引擎」与上游 Android v2 完全对齐：静止确认 0.3 km/h × 2 秒、起步判定 ≥1 km/h 且 ≥2 个样本跨度 ≥20 ms、采样间隙 500 ms 上限、起步/运行 30/60 秒超时、样本 20000 硬上限、同通知多帧（合批）时序不可信即失效、RPM 单渠道、手机接收单调时钟计时。**本批不改 `Sources/Domain/Acceleration/` 既有算法与常数**，仅新增一个恢复转换扩展文件。
- 差距集中在呈现层与记录健壮性：入口单一（仅设置页）、无快捷目标、无大字实时读数与总成绩、无达标反馈、无速度/电流曲线、历史无多选删除、开始时无环境快照、崩溃无检查点恢复。
- 原则（用户本轮明确）：**iOS 端只用原生规范、样式与库**——SwiftUI 系统控件、SF Symbols、Apple Swift Charts、UIKit 原生触感、`AppTheme` 语义令牌；不引入第三方 UI/图表库，不自绘控件替代系统控件。

## 2. 能力对照表

| 能力 | 上游 Android | iOS 升级前 | 本批实施 |
|---|---|---|---|
| 入口 | 一级导航 + 控制器功能页首卡 | 仅设置页 | 控制器页 trailing 工具区新增入口（P0） |
| 快捷目标 | 0–50 / 0–80 芯片 + 自定义输入 | 仅手动输入 | segmented Picker「0–50 / 0–80 / 自定义」（P1） |
| 实时读数 | 大字速度 + 当前耗时 + 电流实时/峰值 | List 小字行 | 进行中 hero：大号速度、已用时、电流实时+峰值（P1） |
| 总成绩 | 「0–XX km/h · X.XX s」大字 | 仅详情页分段表 | 测试页结果 hero（达标时 success 色 + checkmark）（P1） |
| 达标反馈 | 全屏闪红 3 次 + 三声蜂鸣 + 递进振动 | 无 | 3 次 `UINotificationFeedbackGenerator(.success)` 触感（P1） |
| 参数锁定 | 进行中折叠为只读一行 | 仅 `.disabled` | 折叠为只读摘要行（P1） |
| 安全警示 | 页面顶部固定橙色横幅 | 仅 Section footer | 顶部警示行（warning 色 + 三角图标）（P1） |
| 速度/电流曲线 | WebView + ECharts 三线同轴（缩放/拖动/选点） | 无 | Swift Charts 双图共享时间轴（P2） |
| 历史删除 | 多选编辑 + 批量删除 + 二次确认 | 详情页单条删除 | `List(selection:)` + `EditButton` + `confirmationDialog`（P3） |
| 开始条件快照 | SOC/电池电压/温度写入记录 | 无 | conditions 注入（P3） |
| 崩溃恢复 | 2 秒 checkpoint，恢复为 INTERRUPTED | 无 | 检查点文件 + 启动恢复（P3） |
| 持久化 | SQLite（摘要列 + JSON payload） | 本机 JSON | 保持 JSON（不迁移） |

## 3. 原生等价物映射（硬性原则）

| 上游实现 | iOS 原生等价物 | 依据 |
|---|---|---|
| 一级导航第 6 项 | 不采纳；控制器 Tab 内 `Button` + `navigationDestination` | MASTER.md §2.1 五 Tab 上限；「仪表盘 → 续航快捷入口」先例 |
| ECharts WebView 曲线 | Swift Charts（`LineMark`/`PointMark`/`RuleMark`） | MASTER.md §6、§12.3；项目已在 Dashboard/Trips 使用 Charts |
| 多选工具条（自绘） | `List(selection:)` + `EditButton()` + `confirmationDialog` | 系统编辑模式与选择圈即 iOS 惯例 |
| 全屏闪红 + 蜂鸣 | 3 次 success 触感；无闪烁动画 | §5.3 动效克制；触感天然兼容「减少动态效果」；系统音效 ID 无稳定公开 API 且受静音键影响 |
| Material3 主题 | `AppTheme` 语义色 + 系统字体/分组背景 | §3 视觉基础令牌 |

## 4. 实施明细（文件级）

### P0 控制器页入口

- `Sources/Features/Controller/ControllerView.swift`：trailing 工具区改为「加速测试」+「记录与历史」两个并列全宽按钮；测试进行中时入口尾部显示 warning 色「测试进行中」（图标 + 颜色 + 文案三重编码）；`controller.acceleration` 标识；沿用 Button + 外层 `navigationDestination` 先例（网格单元格不假定继承 NavigationStack）。
- `design-system/anturide-ios/MASTER.md` §2.1 控制器职责补充快捷入口说明。入口与设置页指向同一测试页，参数仍只在测试页编辑，不产生重复配置入口。

### P1 测试页体验重构（`AccelerationView.swift`）

- 顶部安全警示 Section（常驻）。
- 快捷目标 segmented Picker 与 `@AppStorage` 目标输入双向同步：手动输入 50/80 自动选中对应项；「自定义」不改输入。
- 进行中：参数区折叠为只读摘要行；实时区顶部插入 hero——`.largeTitle` + `.monospacedDigit()` 大号速度、已用时（仅 running 阶段，armed 不显示伪零）、母线/相线电流实时值 + 本次峰值（缺失显示 `--`）。
- 结束后：达标显示「总成绩 0–XX km/h」+ 大字秒数（success 色）；未达标保留阶段与原因行。
- 达标反馈：`onChange` 监听 phase 进入 `.completed` 触发 3 次成功触感（间隔 0.3 秒）。
- 服务层支撑（`AccelerationService.swift`）：`elapsedSeconds`（tick 10 Hz，值不变不重发）、`peakBusCurrentA` / `peakPhaseCurrentA`（按幅值取最大、保留符号——加速放电时母线电流为负，直接 `max` 会丢掉大幅值）。

### P2 详情页 Swift Charts（`AccelerationRecordCharts.swift` 新文件）

- `AccelerationChartSeriesBuilder` 纯函数：时间轴相对 t0（`startTimestamp ?? referenceTimestamp`），t0 之前的等待/静止样本保留为负值不裁剪；接收间隙超过 50 ms 切分为独立连线区间（不跨缺口连线）；每区间降采样至最多 640 点（分桶保留首/末/极值，桶数 = 640/4）；时序不确定（合批）电流只出孤立 `PointMark`。
- 视图：速度图（km/h）与电流图（母线实线 + 相线虚线，图例 + 线型区分，不只靠颜色）上下堆叠共享时间域——iOS 16 Swift Charts 无双 Y 轴，此为记录在案的替代决策；t0 与各达标时刻 `RuleMark`，仅最终目标加文字标注；轴单位、断点策略 caption、样本不足空态；VoiceOver 摘要（`accessibilityLabel` + 同数据文字行）。
- 插入位置：详情页「RPM 分段结果」与「采样质量」之间。

### P3 记录健壮性

- **多选删除**：服务 `delete(_ records:)` 批量接口（进行中/未保存跳过并汇总提示）；历史 Section 系统编辑模式多选 + 「删除所选（n）」+ `confirmationDialog`（文案含对象、影响、不可恢复）。
- **开始条件快照**：服务 init 注入 `conditionsProvider` 闭包；组合根读取 BMS 快照（SOC/总电压/最高温度/MOS 温度）与控制器遥测（电压/控制器温度/电机温度）合并进记录 conditions；**未连接的键不出现或如实记「未连接」，不造值**。
- **崩溃恢复**：`AccelerationCheckpointStore`（新文件）——检查点存独立目录 `Application Support/AccelerationCheckpoint/in-progress.json`（与历史目录隔离，不会被 `loadAll` 误读）；utility 串行队列后台写、只保留最新；`start` 立即写一次、之后 2 秒节流；正常保存成功即清除；启动时 `recover()` 把进行中快照转成 `.interrupted`（「进程退出，测试未完成（恢复自检查点）」）走历史校验落盘，损坏则丢弃并提示。领域侧新增 `AccelerationRecord.interruptedForRecovery(endedAt:reason:)` 扩展（新文件，不改既有算法）。

### 测试

- `Tests/AppTests/AccelerationServiceTests.swift`：新增 6 个用例（条件快照合并与空值过滤、耗时仅 running 阶段 + 峰值幅值语义、检查点恢复/正常清除/损坏丢弃、批量删除守卫）；`withServices` 基建注入隔离检查点目录与新参数。
- `Tests/AppTests/AccelerationChartSeriesTests.swift`（新文件）：断点切分与 t0 前样本保留、降采样上限与首/末/极值保留、合批电流孤立点。
- `Tests/UITests/ANTuRideUITests.swift`：控制器 Tab → 加速测试入口导航往返；快捷目标联动目标输入框。

## 5. 明确不采纳项

| 上游行为 | 不采纳理由 |
|---|---|
| GPS/IMU 融合测速 | AGENTS.md 与 MASTER.md §12.3：加速测试保持 RPM-only，永久边界 |
| ECharts WebView | 第三方 + WebView 图表；MASTER.md §6 业务图表用 Swift Charts |
| 一级第 6 个 Tab | 五 Tab 上限，避免系统 `More` 折叠 |
| 全屏闪红 | 动效克制；驾驶场景闪烁有安全风险；Reduce Motion 适配成本高 |
| 蜂鸣（ToneGenerator） | iOS 系统音效 ID 无稳定公开 API，且受静音键影响不可靠 |
| 控制器功能页「首卡」位置 | iOS 控制器页信息层级以连接状态优先（§5.1），工具入口归入底部工具组 |
| 崩溃后续测 | 单调时钟不能跨启动复用；恢复记录只作「已中断」证据（与记录模型文档一致） |
| 双 Y 轴单图 | iOS 16 Charts 不支持；两图同 X 轴堆叠替代 |

## 6. 验证边界（按 AGENTS.md 分层声明）

- 本轮开发机为 Windows，无 Swift/Xcode 工具链：仅完成源码静态审查与逻辑推演，**不声称编译或测试通过**。
- 编译、既有 280 项 App 测试与 UI 回归依赖 macOS CI；推送后需以精确 SHA 核对。
- 模拟器/真机/车辆验收归 owner，建议至少覆盖：控制器页入口往返与返回手势、进行中入口状态标记、快捷目标与手动输入互切、大字号/横屏下 hero 与曲线布局、VoiceOver 读取曲线摘要、达标触感（含系统触感关闭设置）、多选删除二次确认、杀进程后重启的检查点恢复、真实车辆上 0–50/0–100 成绩与详情曲线。

## 7. 后续可选增强（本轮不做）

- 曲线选点/缩放手势（iOS 16 Charts `chartOverlay`，交互成本较高，先验证只读曲线价值）。
- 历史记录搜索/按目标筛选。
- 分享图片化成绩单（现有 JSON 分享已满足证据需求）。
