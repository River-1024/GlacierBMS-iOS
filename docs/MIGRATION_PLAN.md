# 安途（ANTuRide）原生 iOS 首版总体规划与施工进度

> 更新时间：2026-10-11 15:06:00 +08:00
> 状态：用户要求继续完成全部后续阶段并复核安卓版复刻。G3 与阶段 3/4 正在按纯领域 → 服务 → UI → macOS/真机验收顺序推进；当前已建立安卓版差异矩阵，任何未经过 macOS/iPhone/车辆验证的能力不标记为完成。
> 目标：使用 SwiftUI + CoreBluetooth 建立一款可由个人签名安装的原生 iOS 驾驶仪表盘。

## 1. 已确认产品决策

| 编号 | 决策 | 当前结论 |
|---|---|---|
| D1 | 首版范围 | 先做可用驾驶仪表盘，不在第一版塞入控制器、加速测试等高级功能 |
| D2 | 首版核心功能 | ANT BMS BLE、GPS 速度、首页仪表盘、实时曲线、综合续航、基础设置、行程、日志、本地导出 |
| D3 | 后台行为 | App 切换到后台且未锁屏时，继续记录 GPS 行程和能耗；BMS 允许时低频采样 |
| D4 | 锁屏行为 | 不要求锁屏继续采样；允许暂停，并在回到前台后恢复 |
| D5 | 数据迁移 | 不迁移 Android 历史行程、日志、校准和设置；iOS 从零建立本地数据 |
| D6 | 安装方式 | 用户自己签名安装，不以 App Store/TestFlight 发布为首版目标 |
| D7 | 技术路线 | 原生 SwiftUI + CoreBluetooth + CoreLocation；不采用 Flutter/KMP 作为首版 UI/业务承载 |
| D8 | 设备验收边界 | 协议测试、Swift 编译、Xcode 模拟器测试不能替代真实 iPhone + ANT BMS + 车辆验收 |

## 2. 首版目标

首版不是 Android 全量一比一迁移，而是先交付一个可以在 iPhone 上实际使用的驾驶仪表盘：

- 能扫描并连接 ANT BMS。
- 能解析真实 BMS 状态帧并显示有效数据。
- 能显示 GPS 速度、功率、电量、SOC、剩余 Ah 和综合续航。
- 能在横屏车载支架场景下快速扫读。
- 能记录前台和未锁屏后台的 GPS 行程与能耗。
- 能识别连接中断、数据过期、GPS 无效和锁屏暂停，不用陈旧值伪装实时。
- 所有核心协议和领域计算都有可在 macOS 上运行的测试。

## 3. 首版不包含

以下项目不阻塞首版驾驶仪表盘：

- 电机控制器独立 BLE 会话。
- 控制器实时参数、控制器记录和 XLSX 导出。
- 加速测试、IMU/GNSS 融合和专业精度声明。
- Android 历史数据导入。
- CarPlay、Live Activity、Dynamic Island。
- App Store/TestFlight 发布流程。
- Android 式全局悬浮窗。
- 依赖“静音音频”或“画中画”才能成立的后台保活方案。

画中画、无声音音频等只能作为后台能力的技术实验，不能作为产品行为的唯一保证；实际能力以 macOS/Xcode/iPhone 真机验证为准。

## 4. 分阶段施工计划

### 阶段 0：工程骨架与协议基线（当前）

目标：建立可以在 macOS/Xcode 上继续施工的原生工程，并先锁定协议行为。

交付：

- SwiftUI App 壳和根导航。
- iOS 16 部署目标。
- XcodeGen 工程定义和纯领域 Swift Package 测试入口。
- BMS 数据模型。
- ANT BMS 查询命令。
- `7E A1` / `AA 55` 分片合包。
- `0x11` 状态帧解析。
- CoreBluetooth BMS 服务骨架。
- 协议、合包和模型测试。

完成门槛：

- 真实样本帧、分片帧、短帧和畸形帧有测试。
- 未知或不完整字段不得产生伪造零值。
- Windows 环境只做文件和静态检查；Swift/Xcode 结果必须标记为待 macOS 验证。

### 阶段 1：BMS 真机链路与仪表盘（2026-10-10 真机验收通过，见 §11）

目标：在真实 iPhone 上完成扫描、连接、Notify、周期查询、断开和恢复。

> 2026-10-09 施工记录：扫描/选择/周期查询/新鲜度/重连的代码与 UI 绑定已完成；扫描策略为全量扫描后按 FFE0 广播服务或名称关键字（ant/bms/antu）过滤，兼容不广播 FFE0 的固件；GPS 速度仍属阶段 2。  
> 2026-10-10 真机确认：App 全屏铺满、界面显示正常（含液态玻璃渲染）；剩余待验收项仅 BMS 真机链路。

交付：

- 设备扫描和 RSSI 排序。
- FFE0/FFE1 服务与特征识别。
- Notify 开启后才允许查询。
- 按 CoreBluetooth 最大写入长度分包。
- 回调合包并解析为 `BmsSnapshot`。
- 连接状态、错误和数据新鲜度。
- 首页速度、续航、SOC、Ah、电流、功率和曲线。

验收：

- 真实 ANT BMS 可连接。
- 真实通知能进入解析链路。
- 断开后状态清晰，恢复连接后不重复创建会话。
- iOS 与 Android 同一输入帧输出一致。

### 阶段 2：GPS、行程和后台未锁屏记录

> 2026-10-10 G1 施工记录：领域层已落盘——`Sources/Domain/Trip/TripModels.swift`（`GpsFix` / `TripSegmentKind` 四类区间标记 / `TripSegment` / `TripState` / `Trip`）与 `Sources/Domain/Trip/TripRecorder.swift`（行程记录器状态机：start/setPhase/suspend/resume/finish + GPS 定位摄入 + BMS 功率配对积分）。三条验收红线在领域层落死：暂停显式成 `suspended` 段；GPS 无效计 `invalidLocationCount`、长间隔插 `gap` 段且不追溯里程、BMS 采样间隔 >5s 重置配对基准不补算能耗；前后台切换为同行程段边界。单测 `Tests/UnitTests/TripRecorderTests.swift` 11 例。**里程语义（重要）：定位两端速度可信时按平均速度×Δt 计里程（GPS 速度优先），否则回退 haversine 坐标差分**——首轮 CI（Run `38031999208`）3 例失败即测试误按纯 haversine 断言所致，已修正测试并补速度积分断言（提交 `762368b`）。CI Run `38032277501` 全绿，IPA 归档 `build/ci/762368b/ANTuRide-unsigned.ipa`（1310748 字节）。Windows 侧 Python 移植 8 场景模拟全过。G2（LocationService + 会话接线）、G3（行程 UI）未开始。

目标：把手机定位和 BMS 数据纳入本地行程。

交付：

- 前台 GPS 速度和里程。
- 未锁屏后台继续记录 GPS 行程和能耗。
- 锁屏暂停采样，记录暂停区间。
- 回前台恢复且不重复开始行程。
- 本地行程列表和详情。
- 前台/后台/暂停/数据缺口标记。

验收：

- 不能用旧 BMS 值冒充锁屏期间实时值。
- GPS 无效、BLE 断开和长间隔不会悄悄生成伪造能耗。
- 后台数据与前台数据在同一行程中可追溯。

### G2 / G3 当前验收与施工记录（2026-10-10 17:32:38 +08:00）

用户最新反馈优先于前文历史记录：实测速度显示没有问题，锁屏/后台暂未测试。

| G2 真机项 | 当前状态 |
|---|---|
| GPS 速度显示 | 用户确认正常 |
| 授权弹窗流程 | 未单独确认，不由速度显示结果推定通过 |
| 开始/结束行程 | 待单独确认 |
| 未锁屏切后台继续记录 | 未测试 |
| 锁屏暂停成段 / 解锁恢复 | 未测试 |
| 行程文件核验 | 待验收，可通过 G3 详情导出 JSON 核对 |

G3 本地实现：

- 根导航新增「行程」标签；本地文件按开始时间倒序显示，提供空态。
- 详情展示总里程、记录跨度、已记录净能耗、起止时间及四类采样区间；展示有效/无效 GPS 点数和能耗采样次数。
- 无有效 GPS 时里程显示 `--`；未采样能耗显示 `-- Wh`，采样后的真实零值和负净能耗分别保留。记录跨度包含暂停/缺口，不等于移动时间。
- 补上原会话层遗漏的前后台相位通知接线，调用 `setPhase` 形成区间边界；解锁恢复按当前相位对齐。切相位重置 GPS/BMS 配对基准，不跨边界补算；通知任务按行程 ID 隔离。此接线仍待真机验收。
- 暂停检查点 `endedAt` 保留 `nil`，重启后显示「未完成」，不伪造结束时间；不自动恢复被终止的会话。
- 结束保存失败时在内存保留完整行程，提供重试和详情导出入口，并暂时阻止开始新行程覆盖数据；仍需及时重试/导出，进程退出会丢失未保存内存数据。目录读取失败明确报错，不当作空列表。
- 列表删除需确认，删除失败显示错误；详情可用系统分享面板导出 JSON，保留与本地持久化一致的 Codable 编码。
- 当前模型不存逐点坐标，**不提供地图回放或速度曲线**；旧版本已写为非空 `endedAt` 的暂停检查点无法可靠追溯判定，不做猜测迁移。
- 新增 TripStore / TripFormatters 单测与隔离数据的行程空态、列表到详情返回、四类分段 UI 测试；补上相位切换不跨边界积分、目录读取失败不伪装空列表的回归覆盖。

验证边界：Windows 无 Swift/Xcode，当前仅进行源码/差异静态检查；新增测试尚未在 macOS 上运行，不能复用旧 G2 CI 的通过结果证明 G3 已通过，也没有新 G3 IPA。

G3 真机验收顺序：结束一段行程 → 行程标签列表出现记录 → 进入详情检查时间/里程/分段 → 返回列表 → 导出 JSON 检查字段。删除测试只对可丢弃的测试行程执行；随后补齐上表 G2 后台/锁屏链路。

### 阶段 3：综合续航和本地导出

目标：迁移当前 Android 的续航语义，而不是重新发明算法。

交付：

- 66 V / 0 Ah 与 86 V 满电边界。
- 按额定容量和设备隔离校准。
- 净 Wh/km 窗口。
- 续航状态和不可用原因。
- CSV/JSON 导出。
- 本地数据删除和重置入口。

### 阶段 4：第二批功能

在首版真机链路稳定后再安排：

- 电机控制器 BLE。
- 控制器实时数据和本地记录导出。
- 首页参数自定义。
- 高级续航校准查看。
- 加速测试。
- Live Activity、CarPlay 等 iOS 原生扩展。

## 4.1 全量后续阶段执行边界（2026-10-10）

本轮要求不是把 Android 页面简单改名，而是逐功能复核 Android 的协议、状态语义、持久化和界面行为。执行顺序固定为：

1. G2/G3 收口：后台/锁屏/恢复、行程文件、列表/详情、导出和失败重试。
2. 阶段 3：续航能量区间、Wh/km 窗口、预测状态、设备隔离校准、JSON/CSV 导出、数据重置。
3. 阶段 4：控制器协议/组包/实时模型/记录导出；首页参数配置；高级校准查看；加速测试纯算法与历史。
4. iOS 平台能力：Live Activity/CarPlay 只在 entitlement、macOS/Xcode 和真机条件具备时实现与验证，不用占位页面冒充 Android 浮窗等价。
5. 每一项分别记录：代码、单测、模拟器/CI、真机、真实 BMS/车辆证据。

安卓版差异矩阵见 `docs/IOS_ANDROID_PARITY_AUDIT.md`。该矩阵将“缺失”“部分”“未验证”和“有意平台差异”分开，避免把首版范围决策误报为完整复刻。

## 4.2 本轮全量复核已落地的代码批次（2026-10-10 19:02:23 +08:00）

- 阶段 2：G2/G3 的后台/锁屏相位边界、保存失败重试、目录读取错误、行程详情和分段测试已补强；仍待 macOS/Xcode 和真机验证。
- 阶段 3：新增基础 `BasicRangePredictor`、状态/原因和设备容量设置；已接入续航页面与仪表盘，但这**不是** Android `RangeEnergyEngine` + `RangePredictionEngine` + `BatteryEnergyCalibration` 的完整等价实现，窗口维护、学习曲线、ZIP 分析导出仍缺失。
- 阶段 4：新增首页参数草稿/保存/取消/UserDefaults 模型与设置入口；Dashboard 尚未按配置动态渲染全部卡片。新增控制器纯领域记录/CSV/有界组包模型，但尚未接 CoreBluetooth、实时解析或 XLSX。
- 安卓复刻复核矩阵已写入 `docs/IOS_ANDROID_PARITY_AUDIT.md`，其中代码、测试/CI、真机、BMS/车辆证据分开记录。

## 5. 当前施工进度

### 2026-10-09

- [x] 已完成首版需求收敛，不再继续提问。
- [x] 已确定首版范围为 B：可用驾驶仪表盘。
- [x] 已确定未锁屏后台记录 GPS 行程和能耗。
- [x] 已确定锁屏不要求采样。
- [x] 已确定不迁移 Android 历史数据。
- [x] 已确定个人签名安装。
- [x] 已建立本文档作为总体规划与进度记录。
- [x] 阶段 0 iOS 工程骨架已创建：`iOS/Package.swift`、`iOS/project.yml`、SwiftUI App 壳、主题、领域模型、BMS 协议、CoreBluetooth 服务骨架和测试目录已落盘。
- [x] 阶段 0 已加入协议查询命令、`7E A1`/`AA 55` 分片合包、`0x11` 状态解析和畸形帧防护。
- [x] 已建立独立 `iOS/.git`，避免父 Android 仓库的 `/iOS/` 忽略规则吞掉 iOS 工程。
- [x] Windows 静态检查已完成：关键文件存在、关键协议符号存在、Swift 大括号平衡通过。
- [x] 已新建独立私有仓库 `https://github.com/River-1024/GlacierBMS-iOS` 并推送全部提交；本项目独立创建，不引用、不合并旧 iOS 项目。
- [x] 已在 GitHub-hosted macOS runner 上通过 CI：SwiftPM 测试、iOS 模拟器测试、无签名设备构建。
- [x] 已产出无签名 IPA 产物 `ANTuRide-unsigned-ipa`。
- [x] 已完成隐私与凭据审计，记录于 `docs/PRIVACY_AUDIT.md`。
- [x] 已记录 GitHub 构建结果，记录于 `docs/CI_BUILD_RESULTS.md`。
- [x] 2026-10-09 真机反馈修复：App 仅屏幕中间显示的根因是 `project.yml` 缺少 `UILaunchScreen` 声明，iOS 按旧分辨率信箱化渲染；已加入显式 Info.plist（启动屏、竖/横屏方向、蓝牙与定位用途说明），并将设备家族收敛为 iPhone。
- [x] 2026-10-09 已接入 iOS 26 Liquid Glass：`glassCard`/强调按钮走 `#available(iOS 26.0, *)` 门控，iOS 16–25 回退分组背景；CI 增加最新 Xcode 选择步骤以获得 iOS 26 SDK。注：iOS 25 版本号不存在，液态玻璃属 iOS 26。
- [x] 2026-10-09 阶段 1 代码施工：设备扫描列表（RSSI 排序 + FFE0 服务/名称关键字过滤）、用户选择连接、Notify 后 1 秒周期查询、快照历史 120 条、意外断开自动重连一次、`didFailToConnect` 与发现服务失败状态回退。
- [x] 2026-10-09 阶段 1 UI 绑定：设备页、详情页（单体/温度/MOS/运行时长）、仪表盘实时绑定（电压/电流/功率/SOC/Ah/SOH/状态），Canvas 电流曲线，数据新鲜度徽标（noData/fresh/stale）。
- [x] 2026-10-09 新增 `BmsFreshnessEvaluator` 领域评估器与单元测试；扩展 `0x11` 解析测试锁定电流/SOC/功率偏移。
- [x] 2026-10-10 阶段 1 CI 验证通过：Run `37955477377`（`f1d125e`）在 Xcode 26.3 / iOS 26.2 SDK 上完成 SwiftPM 测试、模拟器测试与无签名设备构建；经两轮修复（`0x11` 功率偏移 @106、视图补 `import ANTuRideDomain`）。
- [x] 2026-10-10 真机确认：全屏铺满显示正常（`UILaunchScreen` 修复生效），液态玻璃界面正常渲染。
- [x] 2026-10-10 项目更名为 `ANTuRide`（显示名「安途」）：Xcode 工程与 4 个 target、Bundle ID、Swift 模块名（`ANTuRideDomain`）、CI 工作流与产物名及全部文档同步替换。详见 `docs/PRIVACY_AUDIT.md` 第 7 节。
- [x] 2026-10-10 扫描过滤改为默认 `["ant", "apt"]`（ant = ANT BMS 电池保护板，apt = APT 电机控制器），并新增可持久化开关 `isKeywordFilterEnabled`（默认开启）；设备页提供 Toggle，关闭后列出附近全部蓝牙设备，切换后自动重启扫描刷新结果。
- [x] 2026-10-10 新增 App 图标：`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`（1024×1024 无透明通道 PNG），`project.yml` 设置 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- [x] 2026-10-10 修复资源打包缺陷：核验 IPA 发现 `Assets.car` 与 `PrivacyInfo.xcprivacy` 均未进包，根因是 `project.yml` 使用了不生效的 target 级 `resources:` 键；改为 `sources:` + `buildPhase: resources`，并补 `CFBundleIconName: AppIcon`。CI 增加 `Verify app bundle contents` 断言步骤防回归。详见 `docs/PRIVACY_AUDIT.md` 第 7.1 节。
- [x] 2026-10-10 更名与资源收尾验证：CI Run `37961690423`（`2e77a27`）全绿（5m52s），产物 1174236 字节、SHA-256 `197584f9dbe3a4481bd518c2eaeb094e0d99cb1ae4320e053c86b8c055312d9c`；解包核验包内已含 `Assets.car`（946264 字节）、`AppIcon60x60@2x.png`（120×120）、`PrivacyInfo.xcprivacy`（397 字节）与 `ANTuRideDomain.framework`，且无 `embedded.mobileprovision`。详见 `docs/CI_BUILD_RESULTS.md`。
- [x] 2026-10-10 用户确认：设备页扫描过滤开关与 App 图标显示均正常（覆盖阶段 1 设备页 UI 与图标集成）。
- [x] 2026-10-10 真机闪退根因定位（静态推演，未改代码）：真机连接 ANT BMS 成功后 1 秒内闪退。根因是 `AntProtocol.parseStatusResponse` 的**索引越界**——第 41 行守卫 `has(offset, temperatureCount * 2 + 4 + 2 + 2 + 2)` 漏算后续 `soc = u16(offset)` 的 `+2`，当帧长度恰为 `offset + tc*2 + 12` 且 ≥100 时守卫放行但真实读取越界；Swift `Data` 越界触发 `fatalError`，`try/catch` 无法捕获，故表现为无日志直接闪退。触发点在 `didUpdateValueFor` 通知回调（`BmsBluetoothService.swift`）。同时确认全仓**无任何日志系统**（`os_log`/`Logger`/`print` 零命中），崩溃现场无证据可查。
- [x] 2026-10-10 新增**日志系统**（本次交付）：`Sources/Services/Logging/` 7 个文件——`LogLevel`（六级：debug/info/notice/warning/error/fault，可比较、可解析）、`LogEntry`（单行序列化 + 往返解析）、`LogFileWriter`（滚动落盘，2MB × 5 文件 ≈ 10MB 上限，每条 `synchronize` 保证崩溃前落盘）、`AppLog`（`os.Logger` 系统日志 + 沙盒文件**双写**门面，带分类入口 ble/protocolParser/ui/lifecycle）、`AppLogBootstrap`（启动安装 + 异常退出标记）、`LogHexDump`（原始帧十六进制转储）、`LogStore`（读取/过滤/导出/清除管理层）。设置页新增「运行日志」入口，支持**查看（等级着色 + 筛选）/ 导出下载 / 复制 / 清空（二次确认）/ 运行时记录阈值调整**。BLE 链路 30 处埋点覆盖扫描、连接、服务发现、Notify、原始帧转储、合包产出、解析成功/失败与全部状态迁移。
- [x] 2026-10-10 日志系统 CI 验证通过：经 4 次迭代修复后，Run `38022252771`（`4ab1c9b`）全绿（10m4s）。修复项：① `Tests/UnitTests` 被 SwiftPM 与 Xcode 测试目标共享导致 `import ANTuRide` 失败 → 新增 `Tests/AppTests` 目录隔离；② `LogStore` public 引用 internal `LogFileWriter` → 降为 internal；③ 废弃通知常量名 → 改用 `UIApplication.didEnterBackgroundNotification`；④ 测试方法与 `XCTestCase.testCaseCount` 同名 → 改名。测试基线：SwiftPM 12 例、模拟器 22+1 例全通过、0 失败。产物 1292490 字节、SHA-256 `eade32c5311d6ce0c569ca034c3ec7e38838a4a7d739dc8bf24fff1079c5718c`；包内日志系统 10 个类型符号齐全。详见 `docs/CI_BUILD_RESULTS.md` 第 4 节。
- [x] 2026-10-10 阶段 1 真机验收通过（14:14）：连接不再闪退、SOC/电压等数据正常显示（见 §11.2.5）。
- [x] 2026-10-10 阶段 2 G1 领域层施工完成（见 §4 阶段 2 施工记录）：行程模型 + 记录器状态机 + 单测 + Python 8 场景模拟预验证；CI Run `38032277501` 全绿。
- [x] 2026-10-10 阶段 2 G2 采集/会话服务层施工完成：`LocationService`（WhenInUse + 后台定位更新，automotiveNavigation，禁自动暂停）、`TripSessionService`（定位+BMS 快照接入记录器；锁屏经 protectedData 通知显式 suspend/resume；暂停/结束即落盘）、`TripStore`（Application Support/Trips JSON 持久化）、领域模型补 Codable + `liveSegments` 实时视图、AppLog 新增 location 分类；仪表盘接入实时 GPS 速度（km/h + 精度）与行程控制卡（开始/结束/实时里程能耗/暂停徽标）；`project.yml` 增 `UIBackgroundModes: [location]`。提交 `f4e331b`/`4fe3b99`/`4092171` + 3 个修复（`953c52b` TripStore 可见性、`cd9d89b` 锁屏通知常量与 skipsHiddenFiles 拼写、`26e86f8` FormatStyle 插值）。
- [x] 2026-10-10 阶段 2 G2 CI 验证通过：Run `38034738345` 全绿，模拟器 39 例 0 失败（含 TripRecorderTests 12 例）；IPA 归档 `build/ci/26e86f8/ANTuRide-unsigned.ipa`（1371090 字节）。
- [ ] 阶段 2 真机验收未开始：授权弹窗、GPS 速度显示、开始/结束行程、切后台继续记录、锁屏暂停成段、解锁恢复、行程文件落盘核验。
- [ ] 阶段 2 G3 已落地行程列表/详情/删除/JSON 导出及测试；本轮 CI 与真机验收待闭环（详见 CONSTRUCTION_LOG）。
- [ ] 阶段 0/1 协议和合包测试以 CI（GitHub macOS runner）结果为准；本机 Windows 无法执行 Swift。

## 5.1 阶段 0 当前施工清单

| 施工项 | 状态 | 文件/证据 |
|---|---|---|
| iOS 16 工程定义 | 已完成 | `iOS/project.yml` |
| 纯领域 Swift Package | 已完成 | `iOS/Package.swift` |
| SwiftUI 根壳与导航 | 已完成 | `iOS/Sources/App/` |
| BMS 快照模型 | 已完成 | `iOS/Sources/Domain/Models/BmsSnapshot.swift` |
| 查询命令 | 已完成 | `iOS/Sources/Domain/Protocol/AntProtocol.swift` |
| 分片合包 | 已完成 | `iOS/Sources/Domain/Protocol/BmsFrameAssembler.swift` |
| `0x11` 状态解析 | 已完成 | `iOS/Sources/Domain/Protocol/AntProtocol.swift` |
| CoreBluetooth 连接骨架 | 已完成 | `iOS/Sources/Services/BmsBluetoothService.swift` |
| 日志系统（六级 + 落盘 + 导出/清除/复制） | 已完成（未编译） | `iOS/Sources/Services/Logging/`（7 文件） |
| 设置页与日志管理 UI | 已完成（未编译） | `iOS/Sources/Features/Settings/`（2 文件） |
| 首页占位仪表盘 | 已完成 | `iOS/Sources/Features/Dashboard/DashboardView.swift` |
| 单元测试 | 已完成（未执行） | `iOS/Tests/UnitTests/`（22 例，含日志层 10 例） |
| Xcode 编译/Swift 测试 | 待 macOS | 本机无 Swift/Xcode |
| 真实 iPhone/BMS 验收 | 未开始 | 需要设备 |

## 6. 验证与报告规则

每个阶段都要分别报告：

1. 修改了哪些文件。
2. 运行了哪些命令。
3. 哪些测试真实通过。
4. 哪些只完成静态检查。
5. 哪些需要 macOS、Xcode、iPhone 或真实 BMS。
6. 下一步施工项和明确阻塞。

禁止把以下证据混写成“设备已验证”：

- Swift 单元测试通过。
- 模拟器启动通过。
- BLE 写入回调成功。
- UI 显示已连接。
- Android 端已有协议测试。

## 7. macOS 首次验证命令

在 macOS 上进入 `iOS/` 后，预计执行：

```bash
xcodegen generate
swift test
xcodebuild -project ANTuRide.xcodeproj \
  -scheme ANTuRide \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO test
```

个人签名安装时，再使用 Xcode 选择个人 Team 和真实 iPhone；签名配置不写入仓库，不提交证书、描述文件或私钥。

## 8. 风险记录

- Windows 无法运行 Xcode、CoreBluetooth 真机测试和个人签名安装。
- iOS 后台执行受系统生命周期约束，不能预先保证静音音频或画中画保活长期稳定。
- ANT BMS 的真实通知分片、设备权限和不同固件字段需要真机确认。
- 当前 Android 工作区存在未提交改动；iOS 施工不得修改或回退这些改动。
## 9. 新仓库与 GitHub 编译服务

- 新建 GitHub 私有仓库：`https://github.com/River-1024/GlacierBMS-iOS`。
- 本项目完全独立创建，不导入、不合并、不引用旧 iOS 仓库代码。
- 项目名称：`ANTuRide`；App 显示名称：`安途`；Bundle ID：`com.zjsf.anturide`。
- 隐私审计结果：未发现 Token、密钥、证书、描述文件、真实 BLE 地址、GPS 轨迹、本机路径或媒体文件；当前首版不声明摄像头、麦克风、照片或音频权限。完整记录见 `docs/PRIVACY_AUDIT.md`。
- GitHub Actions 工作流：`.github/workflows/build.yml`。
- GitHub-hosted macOS 编译验证：当前 `main`（`f1d125e`）对应的 Run `37955477377` 已成功完成 SwiftPM 测试、iOS 模拟器测试和无签名设备构建，运行环境为 Xcode 26.3 / iOS 26.2 SDK（液态玻璃 API 首次编译通过）；完整运行历史见 `docs/CI_BUILD_RESULTS.md`。
- CI 产物名称：`ANTuRide-unsigned-ipa`，保留 7 天；从最新成功运行页面的 Artifacts 下载。
- 无签名 IPA 不能直接安装；后续如要让 GitHub 自动输出可安装包，需要用户自行配置 Apple 签名证书、Provisioning Profile 和 GitHub Secrets。
- 工作树状态：`main` 与 `origin/main` 一致，工作树干净，无凭据与旧项目引用；`.workbuddy/`、`build/`（CI 产物本地下载目录）与 `Support/Info.plist`（XcodeGen 生成）均已加入 `.gitignore`，不进入仓库。
- 当前 HEAD：`c8853e7`（更名与图标批次：`a5ca7f8` 更名 + 图标 + 过滤开关，`2e77a27` 资源打包修复，`c8853e7` 构建记录）。

## 10. 日志系统（2026-10-10 新增）

### 10.1 为什么自建而非引入第三方

调研了 CocoaLumberjack（13.3k★）、SwiftyBeaver、swift-log、XCGLogger 与 Apple 原生 `os.Logger`。结论：**没有任何库同时开箱满足「持久化 + 下载 + 清除 + 复制 + 明确分级」**——它们都是采集层，第 2–4 项属管理 UI 层，仍需自行实现。故采用：

- **采集**：`os.Logger`（Apple 原生，零依赖，分级规范，真机不连 Xcode 也能用 Console.app 抓取）。
- **持久化与管理**：自建 `LogFileWriter` + `LogStore`，承载滚动落盘与导出/清除/复制。

未引入第三方依赖，避免增加 CI 失败面与二进制体积。

### 10.2 文件构成

| 文件 | 职责 |
|---|---|
| `LogLevel.swift` | 六级等级：`debug/info/notice/warning/error/fault`；可比较、可解析（兼容 WARN/CRITICAL 别名） |
| `LogEntry.swift` | 单行序列化（`时间 \| 等级 \| 分类 \| 消息`）与往返解析；换行转义保证一行一记录 |
| `LogFileWriter.swift` | 滚动写入：单文件 2 MB、保留 5 个（≈10 MB 上限）；**每条写入后 `synchronize`** 保证崩溃前落盘；失败静默降级 |
| `AppLog.swift` | 门面：`os.Logger` + 文件**双写**；分类入口 `ble` / `protocolParser` / `ui` / `lifecycle`；运行时等级阈值持久化 |
| `AppLogBootstrap.swift` | 启动安装 + 异常退出标记（下次启动报告「上次可能闪退」） |
| `LogHexDump.swift` | 原始帧十六进制转储（协议排障必需） |
| `LogStore.swift` | 读取 / 按等级过滤 / 导出文本 / 生成导出文件 / 清除；后台队列读取，主线程发布 |

存储位置：`Application Support/Logs/`（不用 Documents/Caches——前者不被系统清理，也不暴露给「文件」App 被误删）。

### 10.3 界面能力（设置 → 运行日志）

| 能力 | 实现 |
|---|---|
| 查看 | 列表按等级着色（DEBUG 灰 / INFO 蓝 / NOTICE 绿 / WARN 橙 / ERROR 红 / FAULT 紫） |
| 筛选 | Picker 选择「某等级及以上」，只影响显示不改记录行为 |
| 下载/导出 | 生成 `.log` 临时文件 → 系统分享面板（含「存储到文件」） |
| 复制 | 一键复制全部（含头部环境信息）；长按单条复制 |
| 清除 | 带二次确认的「清空全部日志」 |
| 阈值调整 | 设置页可改运行时最低记录等级并持久化 |

### 10.4 BLE 链路埋点

`BmsBluetoothService` 共 30 处埋点，覆盖：扫描启动/停止、名称过滤切换、设备发现与过滤、发起连接、连接成功、连接失败、意外断开与重连决策、服务 FFE0 发现、特征 FFE1 发现（含属性位文本）、Notify 开启、**收到的每个原始通知十六进制转储**、合包器产出帧数、**每个待解析帧的十六进制**、解析成功（含 SOC/电压/单体数/温度数/未解析尾部字节）与**解析返回 `nil` 的帧原文**、周期查询跳过原因。

### 10.5 已知限制

- 本机 Windows 无 Swift/Xcode，**全部代码未经编译**，需 CI（macOS runner）验证。
- `fatalError`（越界 trap）本身无法被捕获；日志系统只能在终止前落盘已有记录，无法记录 trap 发生后的栈。
- 日志文件上限约 10 MB，超出自动滚动淘汰最旧文件。

## 11. 真机闪退根因分析（2026-10-10）

### 11.0 第一轮真机日志取证结论（12:38 更新）——原假设被证据推翻

**原始假设**：`AntProtocol.parseStatusResponse` 守卫漏算 `+2`，收到状态帧时越界 trap。

**取证材料**：真机导出日志 `anturide-20261010-123246.log`（116 条，Debug 构建，等级阈值 debug）。

**关键时间线**（两次连接，均在无任何用户操作下复现）：

| 会话 | ready | 最后一条日志 | 重启检测到异常退出 |
|---|---|---|---|
| 第 1 次 | 12:27:26.638 | 12:27:26.793（收到 3 条 **0 字节**通知） | 12:27:28.850 |
| 第 2 次 | 12:27:59.128 | 12:27:59.128（ready 本条，此后**零日志**） | 12:28:01.647 |

**证据推出的五个事实**：

1. **原假设被推翻**：两次会话均无任何「待解析帧 / 解析返回 nil / 解析成功」日志——解析器从未被调用（第 1 次收到的通知是 0 字节，凑不齐帧头；第 2 次一条通知都没有）。`AntProtocol` 不是本次崩溃的触发点。
2. **设备未断连**：断连回调会打 WARNING「意外断开」（`BmsBluetoothService.swift:274`），日志中不存在。
3. **周期查询在正常发送**：「跳过本次查询：canSendWriteWithoutResponse=false」为 DEBUG 级，若发生必然留痕；日志中不存在 → 每秒写入在静默成功执行。
4. **崩溃与用户操作无关**：用户明确反馈连接后未触碰手机即闪退；ready 后约 2.2–2.5 秒死亡（含人工重开 App 的延迟，实际死亡点更早）。
5. **运行环境为 iOS 27.2 Beta**（Build 24B5099f，日志头部 `系统: Version 27.2`）；App 在 iOS 26+ 启用 Liquid Glass（`AppTheme.swift` `glassEffect` / `.glassProminent`）。

**应用层代码全量排除清单**（已逐一审查，无可崩溃点）：BLE 服务全路径（扫描/连接/发现/Notify/断连/重连/周期查询）、`BmsFrameAssembler`（空数据 `guard count >= 2` 直接 break）、`AntProtocol`（未执行）、`BmsFreshnessEvaluator`（纯函数）、四个页面全部视图代码（仪表盘 / 设备 / 详情 / 设置）、`BmsFormatters`（Double 运算）、`AppTheme`（glass 修饰器）。全仓 grep 无 `fatalError` / `precondition` / `as!` / `try!` / 强解包 / 整数除零。

**剩余两个假设**（静态分析已穷尽，需崩溃报告裁决）：

- **假设 A（倾向）**：iOS 27.2 Beta 的系统层崩溃——SwiftUI/Liquid Glass 渲染或 CoreBluetooth 内部，触发点为 ready 状态切换后的渲染事务或 `writeValue(.withoutResponse)` 调用。Beta 系统（小写 `f` build 后缀）+ 新材质 API 是已知高风险组合。
- **假设 B（低概率）**：应用代码外的运行时问题（如日志高频 `Logger` 实例创建），但无证据支持。

**下一步取证（不需要改代码）**：从 iPhone 导出系统崩溃报告——设置 → 隐私与安全性 → 分析与改进 → 分析数据 → 找 `ANTuRide-2026-10-10-*.ips`，其中 `exception type` 与崩溃线程栈帧可一锤定音。

**原始假设的处置**：`AntProtocol` 守卫漏算 `+2` 仍是一个真实存在的潜在缺陷（静态推演成立，只是未被本次真机数据触发），修复方案保留，待崩溃真相水落石出后一并处理。

### 11.0.1 崩溃报告裁决（12:50 更新）——真凶锁定：`BmsFrameAssembler.append`

**取证材料**：三份系统崩溃报告 `ANTuRide-2026-10-10-1227{10,28,59}.ips`（bug_type 309，iOS 27.2 Beta 24B5099f，iPhone19,7）。

**三份报告完全一致的崩溃签名**：

| 项 | 值 |
|---|---|
| Exception Type | `EXC_BREAKPOINT (SIGTRAP)`——Swift 运行时 trap（越界/precondition 一类），非内存越权 |
| 崩溃线程 | 主线程（`com.apple.main-thread`） |
| 帧 0 | `ANTuRideDomain` `BmsFrameAssembler.append(_:)` **+4352**（三份偏移一致） |
| 帧 1 | `ANTuRide` `closure #1 in BmsBluetoothService.peripheral(_:didUpdateValueFor:error:)` |
| 帧 5 | `completeTaskWithClosure`（Task { @MainActor } 桥接） |
| ANTuRideDomain UUID | `67722708-ce53-35dd-84d7-fabdf8527581` |

**崩溃点即收到 BLE 通知后调用的合包器**，与 11.0 的时间线完全吻合，并解开两个疑点：

1. **导出日志崩溃前空白的原因**：`收到原始通知` 的 DEBUG 行走异步写盘队列，trap 在落盘前发生，最后一行永远丢失。真实顺序：通知到达 → 日志入队 → `append` trap。
2. **「没收到通知也崩」的假象**：第三份报告 `procLaunch 12:27:28.83` 对应日志 12:27:28.850 的重启；其崩溃 capture 12:27:59.2869，即 ready（59.128）后仅 **160ms**——通知确实到了（栈帧 1 证明），只是日志没来得及写盘。

**`append` 静态核查结论**：源码中每个下标均有前置守卫（`count>=2`→`buffer[0]/[1]`、`count>=6`→`buffer[5]`、`count>=frameLength`→`candidate[frameLength-2/-1]`），且 `buffer` 恒为 0 基 `Data`（所有再赋值均经 `Data(...)` 重定基）。可见逻辑推演不出越界路径。trap 偏移 +4352 深入函数体，落在 `Data` 下标 / `firstIndex(of:)` 等泛型内联展开区。结合 **iOS 27.2 Beta（build 后缀 `f`）**，两个可能：

- **假设 A（倾向）**：iOS 27.2 Beta 的 Foundation/stdlib `Data` 切片或 Collection 算法回归，在特定输入（如 0 字节通知后紧跟分片）触发。
- **假设 B**：我们未推演到的输入形态触发了某个内联守卫（无法在 Windows 侧复现验证）。

**修复落地（2026-10-10 13:05，提交 `0f6e9e1`）**：`BmsFrameAssembler.append` 已重写——入口把 `Data` 转为 `[UInt8]`，用显式整数下标与自管 `pos` 游标实现扫描，**不再使用 Data 切片、`dropFirst`、`firstIndex(of:)` 等泛型算法**；每个读取点显式判界，任何异常形态一律滑动/丢弃并返回已产出帧。消费语义与原实现逐分支等价。fuzz 测试（提交 `fc48a86`）：200 轮随机流（含 0 字节块）+ 100 轮噪声嵌帧 + 逐字节送达，断言永不 trap 且产出帧必为 `7E A1` 头 / `AA 55` 尾 / 帧长 = 8 + 声明长度。

**更正（重要）**：本节原先连带怀疑的 `AntProtocol` 守卫缺陷（§11.1「漏算 +2」）经 Python 按当前源码逐字节模拟核验为**误判**——守卫 `tc*2 + 4 + 2 + 2 + 2` 恰好精确覆盖到 `soc` 读取结束，在全部 tc/cc 组合（含极值 16/64）下守卫边界 == 最后读取字节位，无一越界。`AntProtocol` 无需修改；§11.1 保留作分析过程留档，结论以本段为准。

### 11.1 原静态分析（第一轮，假设未获证实且守卫结论已被更正，留档）

**结论：`AntProtocol.parseStatusResponse` 索引越界，非 UI 或连接逻辑问题。**

- **现象**：真机连接 ANT BMS 成功后约 1 秒内闪退。
- **根因位置**：`Sources/Domain/Protocol/AntProtocol.swift`。第 41 行守卫
  `guard has(offset, temperatureCount * 2 + 4 + 2 + 2 + 2)` 只覆盖到 `offset + tc*2 + 12`，
  但紧随其后 `offset += 4`（MOS/均衡温度）与 `offset += 2`（总电压）之后，`current = i16(offset)` 实际读到 `offset + tc*2 + 14`，`soc = u16(offset)` 读到 `offset + tc*2 + 16`。
- **触发判据（可静态计算）**：帧满足 `count == offset + tc*2 + 12` 且 `count >= 100` 时守卫放行、真实读取越界。
- **为何无日志可查**：Swift `Data` 下标越界触发 `fatalError`，是不可捕获 trap，`try/catch` 无效；且全仓无日志系统，崩溃前无任何上下文。
- **修复方案（尚未实施）**：修正守卫常量覆盖到 `soc` 读取结束，并在 `current`/`soc` 读取前各加 `has()` 检查；补 fuzz 测试断言「永不 trap」。
- **执行顺序**：先加日志取证（本次已完成）→ 真机复现取原始帧证据（已完成，结论见 11.0）→ 系统崩溃报告裁决 → 再动刀。


### 11.2 闪退修复后「数据空白」根因分析（13:35 更新）——合包器帧界定与真机协议不匹配

**现象**：修复合包器（提交 `0f6e9e1`）后连接不再闪退，但仪表盘无任何数据。新日志 `anturide-20261010-132031.log`（49 行）显示链路健康：13:20:04 连接 ANT@BLE-RLY01，13:20:06 ready，之后每秒 1 条 **174 字节**通知，帧头 `7E A1 11 00 00 A4 01 01 02 14 ...`（[2]=0x11 状态帧，[5]=0xA4=164 声明长度，[8]=0x02 温度数，[9]=0x14=20 串单体，单体电压可见 `32 0E`/`57 0E` = 3634/3671 mV）。**`protocolParser` 分类日志 0 条**——合包器没有产出任何帧，`待解析帧`/`解析成功`/`解析返回 nil` 全部缺席。

#### 11.2.1 逐字节推演（代码证据）

当前合包器按**声明长度**界定帧：`frameLength = 6 + buffer[5] + 2 = 6 + 164 + 2 = 172`。对 174 字节通知：

1. `remaining(174) >= 172`，取 `buffer[170..171]` 校验尾标识 `AA 55`；
2. 真机帧实际在 **[172]/[173]** 才是 `AA 55`（174 字节帧的最后两字节），[170]/[171] 是数据字节 → 校验失败 → `pos += 2`；
3. `buffer[2]=0x11 ≠ 0x7E`，向后扫描找不到下一个 `7E`（帧尾 0x55 结尾）→ `pos = buffer.count` → 退出循环，**0 帧产出**。

即：**帧长字段（[5]）与真实帧长不匹配——声明 172，实际 174，差 2 字节。** 佐证：App 自身查询命令 `7E A1 01 00 00 BE 18 55 AA 55` 的 [5]=0xBE=190 也与 10 字节实际长度毫不相干，说明该固件系列根本没把 [5] 当有效载荷长度用。

#### 11.2.2 Android 参考实现（与同一台设备正常工作的对照基准）

- `BmsBluetoothManager.kt` `handleIncomingData`：**只用头尾标识界定帧**——收到以 `7E A1` 开头的数据先清空缓冲（新帧开始）；缓冲以 `AA 55` 结尾时**整段缓冲作为一帧交付**并清空；>512 字节溢出保护。**完全不使用声明长度**。
- `AntProtocol.kt` `processAntData`：要求 `size >= 100`、`data[2] == 0x11`，按固定偏移直接解析（单体电压从 [34] 起、电流/SOC 等靠 `hasBytes` 软尾部扩展），同样**不校验声明长度**。

#### 11.2.3 iOS 侧现状核查

- `AntProtocol.parseStatusResponse`（`Sources/Domain/Protocol/AntProtocol.swift`）：对真实 174 字节帧**全部守卫可放行**——`count>=100` ✓、头 `7E A1 11` ✓、尾 `AA 55` ✓、`6 + 164 + 2 = 172 <= 174` ✓，字段解析按偏移走（20 串 × 2B 从 [34] 起共 40B，2 温度 + MOS/均衡温 + 跳过总压 + 电流 + SOC），尾部扩展块靠 `has()` 软判定。**解析器无需改动**。
- `BmsFrameAssembler`（`Sources/Domain/Protocol/BmsFrameAssembler.swift`）：**唯一堵点**。按声明长度界定帧的思路与该固件实际发送方式（每条状态帧=一条完整通知，头 `7E A1` 尾 `AA 55`，声明长度字段不可信）不匹配。
- 测试连带项：`Tests/UnitTests/BmsFrameAssemblerTests.swift` 的 fuzz 断言 `frame.count == 8 + frame[5]` 基于声明长度语义，真机帧违反该不变量，改界定规则后须同步调整。

#### 11.2.4 修复方案（待批准）

对齐 Android 行为，把合包器改为**头尾界定**：

1. `append` 产出规则改为：缓冲中以 `7E A1` 为帧起点（起点前的噪声字节丢弃，保留 `7E` 结尾的悬挂字节），扫到最近的 `AA 55` 尾即交付 `起点..<尾+2` 整段为一帧；单帧超过 `maximumFrameLength`(512) 判为坏帧丢弃重新同步；**不再读取/信任 [5] 声明长度**。
2. `AntProtocol` 保持不动（其守卫已兼容真机帧）。
3. fuzz/单测不变量同步更新：产出帧改为「`7E A1` 开头、`AA 55` 结尾、长度 ≤512」三断言，删除 `count == 8 + frame[5]`；补充「真机 174 字节形态（声明长度≠实际长度）可产出」回归用例。
4. 交付链路不变：`fix:` 合包器 + `test:` 用例 + `docs:` 本节，推 CI → `scripts/fetch-ipa.sh` 取包 → 真机复验 SOC/电压/电流显示。

**风险**：头尾界定在极端情况下可能把数据字节中的 `AA 55` 误判为帧尾，与 Android 行为一致（Android 同样有此特性且实机工作正常）；CRC8 校验（0x8C）可作后续增强，首版不做。

#### 11.2.5 修复落地与真机验收（14:10 更新，已通过）

- 提交：`a37ddd4`（fix 合包器头尾界定）/ `c12d060`（test 回归用例）/ `bd63793`（docs 本节）。
- Windows 侧 Python 移植新算法预验证 7 场景全过：真机 174 字节帧、逐字节分片、噪声嵌帧、双帧连发、超限坏帧恢复、悬挂 `AA` 拼接、500 轮随机流 fuzz。
- CI Run `38029185052` 绿灯；IPA 归档 `build/ci/bd63793/ANTuRide-unsigned.ipa`（1 290 506 B，SHA-256 `3fba3f96…727`），包内 13 条目核验通过。
- **真机验收（14:14 用户确认）：连接不再闪退、不再空白，SOC/电压等数据正常显示。** 阶段 1 BMS 真机链路验收通过。

## 每步施工记录要求

按用户最新要求，每步施工均同步输出到 `docs/CONSTRUCTION_LOG.md`，不得只在聊天中汇报或等阶段结束再补记。子任务完成后需记录主线程集成核对和验证结论；无法执行的测试和未验收硬件行为明确保留。总体阶段状态以本文为准，详细过程以施工记录为准。

## 2026-10-10 后续执行范围修订（2026-10-10 20:43:02 +0800）

按用户最新决定，取消 iOS 电池学习/历史修订/学习恢复；复用安卓固定能量数据。续航窗口与新鲜度判断仍须实现。编译走 GitHub macOS CI，而非等待本地 macOS。每步实际进展和验证均追加到 CONSTRUCTION_LOG.md；完整复刻状态以 IOS_ANDROID_PARITY_AUDIT.md 为准，不能将源码存在或旧 CI 成功当作整体验收。

### 2026-10-11 接续复核：Dashboard 集成阻塞已修复

本次接续首先复核未提交工作树，发现首页重构文件存在明确的源码截断：`DashboardView.body` 缺少闭合结构，原有卡片组件不完整，旧版布局分支引用缺失的 `parameterCard`。已恢复闭合结构、既有卡片组件并补上旧布局适配；详见 `docs/CONSTRUCTION_LOG.md` 步骤 019。

当前验证边界：Windows 工作区没有 Swift/Xcode/XcodeGen，已通过 `git diff --check` 和源码结构复核，尚无本批 macOS CI/模拟器/XCTest 证据。未提交、未推送；G2 后台/锁屏与 G3 真机行程文件验收仍待执行。

## 当前施工批次更新（2026-10-11 10:24:39 +08:00）

本轮按“先补功能、用户再真机测试”推进。加速测试范围以最新决定为准：**RPM 单渠道，默认系数 0.0782；速度(km/h)=rawRPM×系数×方向**，不接入 GPS/IMU/融合或模拟结果，不要求输入轮周长/减速比。

首页 27 槽位/39 指标与控制器真实数据、驾驶设置消费、续航窗口平均速度/km/Ah、行程逐点 CSV/分页及控制器 18 列 CSV/XLSX 已在当前未提交工作树接入。具体施工与测试边界见 CONSTRUCTION_LOG 步骤 020–023。

上述本批工作树尚无对应 macOS CI / Xcode 编译 / XCTest 运行结果，不能套用 ced33b3 的旧 CI。G2 后台/锁屏、真实控制器与加速车辆测试仍由真机验收证明；地图轨迹、Live Activity/CarPlay 尚未实现。取消的电池学习与 Android 私有历史导入不重新纳入。未自动提交、推送或部署。

## 本批GitHub验证与IPA交付（北京时间 2026-10-11 10:55:06）

此节覆盖上文“当前未提交/待CI”的历史状态，不改变真机验收边界。
- 分支：codex/ios-parity-20261010；功能批次c584c42，最终已验证源码提交5bd14933f13814811e95c89a83a5616aa8c783c7。
- GitHub Actions： https://github.com/River-1024/GlacierBMS-iOS/actions/runs/38106226167 ，全部成功。
- SwiftPM领域测试130项、iOS模拟器单元测试269项、UI测试3项，全部0失败；Release设备构建及包资源校验成功。
- 本地IPA：build/ci/5bd1493/ANTuRide-unsigned.ipa；latest副本同步。大小2161766字节。
- SHA-256：b3b6ff01eb4198fef4331fa5e46b54e6b03aa769c5a9866d84dea86a048aeebe。
- 下载后ZIP CRC、Assets.car、PrivacyInfo.xcprivacy、图标、Bundle ID和显示名核验通过；无embedded.mobileprovision及_CodeSignature。
- build/ci/5bd1493/保存run.json、ci.log和artifact-verification.json；生成物不入Git。
- unsigned IPA仍需签名后安装；不代表真实iPhone/BMS/控制器或车辆加速验收。地图轨迹、Live Activity/CarPlay仍未实现。

## 本批安装进度更新（北京时间 2026-10-11 11:00:21 +08:00）

- 用户在当前对话明确反馈：**安装成功**。本批交付的安装环节标记为用户确认通过，接续源码5bd1493 / GitHub Actions Run 38106226167的IPA交付记录。
- 记录时间为本次反馈登记时间，不推断实际安装时间、签名方式、设备型号或系统版本；GitHub原始产物仍为unsigned，不因安装反馈改写产物属性。
- 已完成：功能批次提交与推送、GitHub原生编译测试、IPA产出与本地核验、用户确认安装成功。
- 待验收：本批首页/驾驶设置交互、续航与行程记录/导出、控制器真实链路与导出、后台/锁屏行为、RPM加速车辆测试。安装成功不等于上述功能全部通过。
- 加速范围保持RPM单渠道、默认系数0.0782；地图轨迹、Live Activity/CarPlay仍未实现。

## 设置导航整理（北京时间 2026-10-11 11:31:48 +08:00）

- 当前工作树固定五标签：仪表盘 / 设备 / 详情 / 行程 / 设置；不再保留造成系统 More 的第六个续航标签。
- 全部配置由设置总入口进入；综合续航窗口/刷新只在综合续航设置编辑，容量按设备 UUID 保存；结果和导出从仪表盘右上角综合续航进入。
- 普通驾驶页的保存/局部恢复默认不再覆盖续航配置；续航窗口/刷新单独确认恢复默认。原存储格式、旧配置与设备数据保留。
- Android 共用默认值 23 项及三个周期范围对照通过；仍不实现方向锁、Android 专用入口或已排除的学习/完整分析包。
- 本批状态：Windows 源码检查 6/6 与 diff 检查通过；新增 4 个 App 测试和 4 个 UI 测试待 macOS 执行。未提交/未发布/未产出新 IPA，不沿用前批 CI 成功作为本批证明。

## 12. 首页重排确认与后续施工边界（北京时间 2026-10-11 13:11:19 +08:00）

本节是本轮最新需求记录，保留上文历史。已确认的是目标方案，不将需求确认写成 UI 完工或验收通过；施工记录见 `CONSTRUCTION_LOG.md` 步骤 033。

### 已确认方案

1. Dashboard 去掉“安途”标题、顶部空白和独立 BMS 状态卡。BMS 扫描/连接管理仍在设备 Tab；首页参数必须保留有效、过期、缺失和错误的区别。
2. 首页去掉行程控制；开始/结束行程、当前会话与错误反馈移入现有行程 Tab，与历史、详情、曲线及导出形成同一入口。
3. 用户配置的参数尽量利用首页可用区域，保留合理的信息层级；不以小字号、裁剪或压缩触控区域换取“填满”。
4. Dashboard 的业务趋势图改用系统 Swift Charts，不再以 Canvas 承载业务曲线；保留单位、时间范围、空数据/断点语义和可访问文本摘要。
5. 滚动内容获得导航栏区域的全屏视觉，不保留标题空白；系统安全区域、工具栏和原生返回交互仍须可用，不把全屏视觉解释为遮挡内容或隐藏所有导航能力。
6. 其余 UI 自适应、语义字号、原生 SwiftUI 组件与无障碍约束继续，具体以 `design-system/anturide-ios/MASTER.md` §12 为准。

### 已施工 / 待施工

- 本轮已施工仅是三份指定文档的追加更新；未修改源代码或测试。
- 只读源码快照：五项 Tab、可配置参数布局与行程列表/详情已存在，行程详情已使用 Swift Charts；Dashboard 仍有“安途”导航标题、独立 BMS 状态卡、行程控制和 Canvas 电流/功率曲线，行程开始/结束尚在首页。不要把行程详情图表的实现当作 Dashboard 迁移证据。
- 待施工：完成首页减项与参数重排、行程控制移入行程 Tab、Dashboard Swift Charts 迁移、导航栏区域全屏滚动视觉；后续以实际集成差异更新施工状态，不把其他线程的并行进展提前标为完成。

### 分层验证与未修改范围

| 验证层级 | 本轮状态 | 后续证明范围 |
|---|---|---|
| Windows 静态检查 | 仅文档内容、追加完整性与差异空白检查；源码只读查看 | 不能证明 Swift 编译、UI 行为或设备链路 |
| macOS CI / 模拟器 | 本轮未执行，待验证 | 准确源码提交的编译、XCTest/XCUITest、不同屏幕/横竖屏/字号、图表与导航回归 |
| 真机 / BMS / 车辆 | 本轮未执行，待验收 | 实际 iPhone 滚动视觉与安全区域、行程流程、真实数据与断连/过期状态；不由 CI 代替 |

- 既往 CI、IPA 和安装成功记录仍按原批次留档，不套用为本轮首页方案通过。
- 未修改范围：`Sources/`、`Tests/` 及其他文件；BMS/BLE 协议、参数持久化、行程存储、RPM-only 范围和本机隐私边界未改变。不新增 Tab、第三方 UI/图表依赖或 Android 像素级布局要求。
- 本次交付到文档更新与静态核对为止，未提交、推送或生成新 IPA；macOS 编译和真机/BMS 验收明确保留为待验证。

## 13. Dashboard 根页导航栏与续航入口最终补充（北京时间 2026-10-11 13:16:49 +08:00）

本节补充 §12，取代其关于 Dashboard 根页保留工具栏的宽泛表述；详情页继续使用系统导航。既有历史不删除。

- Dashboard 根页隐藏整条 `navigationBar`，不能仅隐藏背景；无标题、无固定 header，不保留导航栏占位或额外顶部空白。
- 续航详情入口移到现有卡片或图表标题行的内容区，随该内容滚动，不额外占顶端一行；不再依赖根页导航栏右上角入口。
- 续航详情恢复系统导航栏、返回按钮与返回手势；根页隐藏导航栏只作用于根页，往返详情时须保持正确导航行为。
- `ScrollView` 连续滚动到顶部安全区，仍尊重状态栏/刘海与底部五项 Tab；不通过固定 header 或额外顶行制造新的空白。
- `dashboard-wireframe.svg` / `dashboard-wireframe.png` 是被本次决定替代的历史方案，不再作为当前施工或验收依据；MASTER 已明确其历史状态，文件保留不改。
- 已施工仅为文档补充，源码/测试未在本任务中修改；UI 实现与验证仍待后续施工证据。其余首页布局、行程入口、Swift Charts、字号、自适应、原生组件和无障碍约束继续。
- Windows 验证仅限文档静态检查；macOS CI/模拟器待验证根页无导航栏占位、内容区入口、详情导航恢复和返回；真机/BMS 待验证状态栏/刘海安全区域、滚动、五 Tab 与真实续航数据。本轮无编译或验收通过声明，不沿用旧 CI/安装结果。
- 未修改范围：源代码、测试、旧线框图和其他文件；仅追加三份指定文档，保留其他未提交改动。

### 顶部续航 toolbar 旧方案替代与交付说明（北京时间 2026-10-11 13:21:11 +08:00）

本补充与 §13 一并作为当前决定，优先于上文旧顶部续航入口/工具栏表述。

- 旧版“保留 Dashboard 顶部续航 toolbar”的方案已被替代，不再作为当前施工依据：Dashboard 根页隐藏整条 `navigationBar`，不是仅隐藏背景；无标题、无固定 header、无导航栏高度占位。
- 续航详情入口移到现有卡片/图表标题行的内容区，随内容滚动，不额外占顶端一行；详情页恢复系统导航栏、返回按钮及返回手势，隐藏范围只限 Dashboard 根页。
- `ScrollView` 连续滚动到顶部安全区，仍尊重状态栏/刘海与底部五 Tab；其余自适应、字号、原生组件、Swift Charts 和无障碍约束继续。
- 旧 `dashboard-wireframe.svg` / `dashboard-wireframe.png` 仅为被本次决定替代的历史示意，不作当前施工或验收依据，不据旧图恢复顶部 toolbar、标题或固定 header；图文件保持不变。
- 本次已完成需求文档补写，不等待源码实施。实施完成后的实际验证由用户后续追加；本轮仅验证文档，不推断实现状态，不声称 Windows 静态检查等于 macOS CI/模拟器或真机/BMS 通过。未修改源代码、测试或其他文件，保留其他未提交改动。


## 本轮实施状态（北京时间 2026-10-11 14:05:05 +08:00）

Dashboard 减项、行程 Tab 归位、根页隐藏导航栏与 Swift Charts 迁移已落地到当前工作树；验证状态以 `docs/CONSTRUCTION_LOG.md` 步骤 036 为准。新增源码级契约和图表点生成测试尚未经过 macOS Xcode 编译/模拟器执行；不得将 Windows 语法检查视为 iOS UI 验收。


## 最新 UI 批次交付（北京时间 2026-10-11 15:06:00 +08:00）

设置五 Tab、唯一续航编辑入口、Dashboard 根页整栏隐藏/高密度自适应、行程归位和 Swift Charts 已提交，并通过本批准确源码 macOS CI。此前“未提交/未生成新 IPA”为历史状态，以本节及施工步骤 037–039 为准。

- 构建源码：`414d8b0a188767796dc58901ab7bfe583ffdafba`（`414d8b0`）；分支 `codex/ios-parity-20261010`。后续文档提交不改变源码，本 IPA 不宣称基于文档提交重新构建。
- GitHub Actions：Run `38119495743`，结论 `success`；2026-10-11 14:52:52 +08:00 启动，14:59:25 +08:00 完成。准确 headSha 已核对；Xcode 26.3 / Swift 6.2.4。
- 测试：SwiftPM 130 项、iOS XCTest 280 项、XCUITest 9 项，全部零失败；Release 设备构建、资源校验、产物上传全部成功。
- CI 源码契约：Dashboard 6/6；设置 4 项通过、2 项 Android 对照因独立 checkout 无父仓库明确跳过。本机设置 6/6（含 Android 对照）和 Dashboard 6/6 已通过。
- IPA：`build/ci/414d8b0/ANTuRide-unsigned.ipa`；`build/ci/latest/ANTuRide-unsigned.ipa` 为字节一致副本。大小 `2210282` 字节，SHA-256 `1999c55ec46705c9b26d0b0b70668eba9a315445ac9254400520e5afc0b86ef3`。
- 校验：ZIP 全部条目 CRC 通过；主二进制、Assets.car、PrivacyInfo.xcprivacy、AppIcon 存在；标识 `com.zjsf.anturide`、显示名“安途”、版本 0.1.0 (1)；无 embedded.mobileprovision 和 _CodeSignature 目录，产物为 unsigned，需要另行签名后安装。
- 本地证据：版本目录和 latest 均保存 `run.json`、`ci.log`、`artifact-verification.json`，均在忽略的 build 目录，不提交二进制/日志。

本批已完成源码/CI/产物交付；真实 iPhone 安装与 UI/VoiceOver/BMS/车辆验收仍待验证，不将 Android 差异清单整体标记完成。

## 电池与控制器分离实施状态（北京时间 2026-10-11 22:34:47 +08:00）

方案已实现并通过 macOS CI，不再是待施工项。源码 `01aec26` 已推送；Run `38147063235` 精确 SHA 成功，SwiftPM 137、iOS 测试 327、UI 测试 12 均零失败，unsigned IPA 已下载校验。产品行为与设备端验收清单见 `docs/BATTERY_CONTROLLER_SEPARATION.md`；IPA/日志/Run 证据见 `build/ci/01aec26/`。

未完成项仅为需要真实 iPhone/BLE/车辆的验收；未签名 IPA 必须先用个人证书签名。文档提交不改变已构建源码，也不意味着对文档版本重新构建。

## 续航驾驶窗口算法对齐与 IPA 交付（北京时间 2026-10-12 12:30:00 +08:00）

**范围：核心驾驶窗口算法已对齐 Android，但不是包含学习、审计和所有显示行为的完整复刻。** 保持不变的既有行为：最终公式「剩余可用 Wh ÷ 窗口净 Wh/km」、固定 Android seed/legacy 能量曲线、现有额定容量设置方式、不新增电池学习且不恢复 Android 校准数据。

已对齐 8 项（有效驾驶判定、预测门槛 30 s/200 m/5 Wh 放电/5 Wh 净能耗、按累计有效驾驶时长的 FIFO 窗口、净 Wh = 放电 − 移动再生、电压×电流跨零分别积分、部分区间按时间比例裁剪后重积分、窗口缓存配合最新 BMS 剩余量、按 UUID 恢复证据且不存坐标）与新增异常处理（容量跳变、时钟/样本回退、坏区间只排除不清空、重复重叠不累计）见 `docs/CONSTRUCTION_LOG.md` 步骤 041；核心代码 `Sources/Domain/Range/RangeDrivingWindow.swift`、`Sources/Services/RangeService.swift`。

仍保留的差异：过期/断连时 iOS 撤下预测（Android 保留旧数值并标记暂停）；iOS 保留更严格的数据有效性检查；Android 原始区间审计、排除原因记录与回放体系未移植。

源码 `60101a4d826418fec9879ca33400e13130208c13`（`60101a4`）已推送 `codex/ios-parity-20261010`；Run `38202579046` 精确 SHA 成功，14 个具名步骤全部通过，SwiftPM 161、iOS XCTest 364、XCUITest 12 全部零失败，四项源码契约 33 例通过。unsigned IPA 2276667 字节、SHA-256 `f2ee0df32452450e6158d5abcba8b78043c4095ed6545cdb4f75dc6ca256e797`，已归档 `build/ci/60101a4/` 并由 `build/ci/latest/` 同步（四份文件同指该 Run）。4 轮 CI 迭代的失败定位与修复见 `docs/CI_BUILD_RESULTS.md` 第 1、4 节。交付文档提交 `e81449c` 的连带运行 `38204388224` 同样成功（9m31s），仅用于证明文档改动不破坏构建；其产物归档 `build/ci/e81449c/`，因源码与 `60101a4` 相同而未替换 `latest`。

未完成项仍是需要真实 iPhone + BLE + 车辆的验收（真实 GPS 漂移、断连重连、后台锁屏、容量跳变、VoiceOver/大字号）；未签名 IPA 必须先用个人证书签名。文档提交不改变已构建源码，也不意味着对文档版本重新构建。
