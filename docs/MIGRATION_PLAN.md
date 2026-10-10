# 安途（ANTuRide）原生 iOS 首版总体规划与施工进度

> 更新时间：2026-10-10 12:10（北京时间）  
> 状态：阶段 1 代码完成；项目更名 `ANTuRide`（安途）已落地，全屏适配、液态玻璃、设备页过滤开关与 App 图标均已确认正常；**真机连接 BMS 后闪退已定位根因（解析器越界），日志系统已落地并通过 CI（Run `38022252771`），待真机取证**  
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

### 阶段 1：BMS 真机链路与仪表盘（代码已完成，待真机验收）

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
- [ ] 阶段 1 真实 iPhone 与 ANT BMS 验收未开始（扫描、连接、Notify 分片、周期查询、断开恢复需真机）。
- [ ] 阶段 1 解析器越界修复**未实施**（本次只加日志取证，不改协议逻辑，遵循「先取证后动刀」）。
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
