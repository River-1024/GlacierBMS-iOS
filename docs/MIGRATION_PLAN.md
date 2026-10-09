# 冰川智舱 原生 iOS 首版总体规划与施工进度

> 更新时间：2026-10-10 00:20（北京时间）  
> 状态：阶段 1 代码完成；全屏适配与液态玻璃真机验证通过，BMS 真机链路待验收  
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

> 2026-10-09 施工记录：扫描/选择/周期查询/新鲜度/重连的代码与 UI 绑定已完成；扫描策略为全量扫描后按 FFE0 广播服务或名称关键字（ant/bms/glacier）过滤，兼容不广播 FFE0 的固件；GPS 速度仍属阶段 2。  
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
- [x] 已产出无签名 IPA 产物 `GlacierBMS-unsigned-ipa`。
- [x] 已完成隐私与凭据审计，记录于 `docs/PRIVACY_AUDIT.md`。
- [x] 已记录 GitHub 构建结果，记录于 `docs/CI_BUILD_RESULTS.md`。
- [x] 2026-10-09 真机反馈修复：App 仅屏幕中间显示的根因是 `project.yml` 缺少 `UILaunchScreen` 声明，iOS 按旧分辨率信箱化渲染；已加入显式 Info.plist（启动屏、竖/横屏方向、蓝牙与定位用途说明），并将设备家族收敛为 iPhone。
- [x] 2026-10-09 已接入 iOS 26 Liquid Glass：`glassCard`/强调按钮走 `#available(iOS 26.0, *)` 门控，iOS 16–25 回退分组背景；CI 增加最新 Xcode 选择步骤以获得 iOS 26 SDK。注：iOS 25 版本号不存在，液态玻璃属 iOS 26。
- [x] 2026-10-09 阶段 1 代码施工：设备扫描列表（RSSI 排序 + FFE0 服务/名称关键字过滤）、用户选择连接、Notify 后 1 秒周期查询、快照历史 120 条、意外断开自动重连一次、`didFailToConnect` 与发现服务失败状态回退。
- [x] 2026-10-09 阶段 1 UI 绑定：设备页、详情页（单体/温度/MOS/运行时长）、仪表盘实时绑定（电压/电流/功率/SOC/Ah/SOH/状态），Canvas 电流曲线，数据新鲜度徽标（noData/fresh/stale）。
- [x] 2026-10-09 新增 `BmsFreshnessEvaluator` 领域评估器与单元测试；扩展 `0x11` 解析测试锁定电流/SOC/功率偏移。
- [x] 2026-10-10 阶段 1 CI 验证通过：Run `37955477377`（`f1d125e`）在 Xcode 26.3 / iOS 26.2 SDK 上完成 SwiftPM 测试、模拟器测试与无签名设备构建；经两轮修复（`0x11` 功率偏移 @106、视图补 `import GlacierBMSDomain`）。
- [x] 2026-10-10 真机确认：全屏铺满显示正常（`UILaunchScreen` 修复生效），液态玻璃界面正常渲染。
- [ ] 阶段 1 真实 iPhone 与 ANT BMS 验收未开始（扫描、连接、Notify 分片、周期查询、断开恢复需真机）。
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
| 首页占位仪表盘 | 已完成 | `iOS/Sources/Features/Dashboard/DashboardView.swift` |
| 单元测试 | 已完成（未执行） | `iOS/Tests/UnitTests/` |
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
xcodebuild -project GlacierBMS.xcodeproj \
  -scheme GlacierBMS \
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
- 项目名称：`GlacierBMS`；App 显示名称：`冰川智舱`；Bundle ID：`com.zjsf.glacierbms`。
- 隐私审计结果：未发现 Token、密钥、证书、描述文件、真实 BLE 地址、GPS 轨迹、本机路径或媒体文件；当前首版不声明摄像头、麦克风、照片或音频权限。完整记录见 `docs/PRIVACY_AUDIT.md`。
- GitHub Actions 工作流：`.github/workflows/build.yml`。
- GitHub-hosted macOS 编译验证：当前 `main`（`f1d125e`）对应的 Run `37955477377` 已成功完成 SwiftPM 测试、iOS 模拟器测试和无签名设备构建，运行环境为 Xcode 26.3 / iOS 26.2 SDK（液态玻璃 API 首次编译通过）；完整运行历史见 `docs/CI_BUILD_RESULTS.md`。
- CI 产物名称：`GlacierBMS-unsigned-ipa`，保留 7 天；从最新成功运行页面的 Artifacts 下载。
- 无签名 IPA 不能直接安装；后续如要让 GitHub 自动输出可安装包，需要用户自行配置 Apple 签名证书、Provisioning Profile 和 GitHub Secrets。
- 工作树状态：`main` 与 `origin/main` 一致，工作树干净，无凭据与旧项目引用；`.workbuddy/` 已加入 `.gitignore`，不进入仓库。
