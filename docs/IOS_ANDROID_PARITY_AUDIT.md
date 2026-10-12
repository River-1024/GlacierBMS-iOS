# iOS 与安卓版功能/界面复刻复核

> 复核日期：2026-10-10（北京时间）
> 基线：Android `app/src/main` 与 iOS 当前工作树；iOS 工作树含未提交修改，旧 CI 不证明本工作树。
> 结论：当前 iOS 不是安卓版的完整复刻；已完成的是首版 BMS 仪表盘与阶段 2 行程基础链路。后续阶段必须按证据逐项迁移，不能把 Swift 编译或 UI 占位视为安卓版等价。

## 状态定义

- **已实现**：iOS 有对应代码和本地测试；真机能力仍单列。
- **部分**：核心能力存在，但语义、数据源或界面仍少于 Android。
- **缺失**：iOS 当前没有可用实现。
- **未验证**：代码存在，但需要 macOS/Xcode、iPhone、BMS 或车辆证据。

## 功能矩阵

| 功能/页面 | 安卓证据 | iOS 当前证据 | 状态 | 后续动作 |
|---|---|---|---|---|
| BMS BLE 扫描/连接/Notify/重连 | `app/src/main/.../bluetooth/BmsBluetoothManager.kt`、`BleScanner.kt` | `Sources/Services/BmsBluetoothService.swift`、`Features/Devices/DeviceView.swift` | 部分/未验证 | 对照真实通知与断连重连验收 |
| ANT 协议、分片合包、状态帧 | `protocol/AntProtocol.kt`、`BmsBluetoothManager.kt` | `Sources/Domain/Protocol/` | 已实现/未验证 | 用同一原始帧做跨端字段快照测试 |
| 首页速度、SOC、电压、电流、功率、曲线 | `ui/HomeDashboardScreen.kt`、`DashboardScreens.kt` | `Features/Dashboard/DashboardView.swift` | 部分 | 对照 Android 参数布局、颜色阈值、缺失/过期态 |
| GPS 权限、速度、里程 | `location/LocationHelper.kt`、`MainActivity.kt` | `Services/LocationService.swift`、`Domain/Trip/` | 部分/未验证 | 完成 G2 后台/锁屏/文件验收 |
| 行程列表/详情/分段 | `ui/TripDetailsLayout.kt`、`TripTimeEnergyReview.kt` | `Features/Trips/TripHistoryView.swift` | 部分 | 已新增逐点证据及四指标曲线；地图回放、缩放选点仍缺 |
| 行程能耗、Wh/km 时间窗口、样本分页 | `TripEnergyReview.kt`、相关 Trip 模型 | TripSample + 1/3/5/10 分钟窗口摘要 | 部分/CI通过 | 共同覆盖分母/暂停缺口已测试；分页/完整安卓图表仍待 |
| 综合续航预测 | `model/BatteryEnergyCalibration.kt`、RangeAnalysis*、`RangeStatusText.kt` | RangeService + RangeDrivingWindow + 安卓 seed/legacy 曲线 | 部分/CI通过（窗口算法已对齐） | `60101a4` 起有效驾驶判定/FIFO 窗口/门槛/再生扣除/区间裁剪已对齐；可配置窗口与完整安卓分析、审计包仍待，过期断连显示策略保留差异 |
| 电池学习/历史修订/学习恢复 | `BatteryEnergyCalibration.kt`、`BatteryCalibrationChart.kt` | AndroidEnergyCurve 只读数据 | 按用户决定取消 | 不做iOS学习，复用安卓内置数据；不声称手机私有学习数据库已导入 |
| CSV/JSON 行程/控制器导出 | `ControllerRecordExporter.kt`、主界面导出入口 | iOS 行程详情仅 JSON 临时分享 | 部分 | 增加 CSV、长期可访问导出与核验 |
| 本地删除/重置 | Android 设置与数据入口 | iOS 行程删除；无完整重置 | 部分 | 明确分级删除：行程、校准、日志、全部数据 |
| 控制器 BLE 实时数据 | `MotorControllerBluetoothManager.kt`、`ControllerFeatureScreen.kt` | ControllerBluetoothService/View | 已接线/CI通过/待真机 | 只读查询、分片、超时；前台共享会话，真实车辆待验收 |
| 控制器记录与导出 | `ControllerRecordSession.kt`、`ControllerRecordExporter.kt` | ControllerHistoryStore + 页面 | 部分/CI通过 | JSON/七列CSV，安卓18列/XLSX仍缺 |
| 首页参数自定义/动态底部参数 | `HomeParameterEditor.kt`、`HomeParameterPresentation.kt` | 10卡片已接线；27槽位/39指标施工中 | 部分 | 不将旧10卡片与安卓全布局等价 |
| 普通设置/阈值/采样周期 | `DashboardScreens.kt`、`DashboardSettings` | DrivingSettings/View 23项 + 日志 | 部分/接线施工中 | 21默认值及双连接开关已对照；必须核查消费端真实生效 |
| 加速测试（最新范围 RPM 单渠道） | `AccelerationTestScreen.kt`、`acceleration/` | RPM Domain + AccelerationService/View/历史 | 本批代码接入/待CI | 系数默认0.0782；接收时序计时，不接GPS/IMU，不宣称硬件精度 |
| 日志查看/复制/导出/清除 | `SoftwareLog*`、浏览器控制台 | `Sources/Services/Logging/`、Settings | 部分 | 对齐日志字段、筛选、导出和现场取证 |
| 浮窗/画中画 | `FloatingWindowService.kt` | iOS 无对应通用浮窗 | 平台差异 | 不伪造等价；评估 Live Activity/CarPlay 替代 |
| 浏览器调试控制台 | `browser/` | 无 | 缺失/非首版 | 明确不纳入首版或另立诊断功能 |
| Android 历史数据导入 | Android 本地数据 | iOS 计划明确不迁移 | 有意不等价 | 保留产品决策，不算缺陷 |
| Live Activity/CarPlay | Android 无直接等价 | iOS 计划项 | 未实现 | 需要 Apple entitlement、macOS/Xcode 和设备验证 |

## 复核字段边界

| 证据层 | 含义 |
|---|---|
| Android 代码 | 仅证明安卓版存在实现，不等于当前行为已在设备复核 |
| iOS 代码 | 仅证明源码存在，不等于编译通过 |
| iOS 测试/CI | 必须对应当前提交或工作树，不可套用旧 Run |
| iPhone/BMS/车辆 | 只有真实设备链路和车辆结果才能证明现场能力 |

## 结论与验收边界

1. “完整复刻安卓版”不能由现有阶段计划自动推出：Android 已包含控制器、加速、动态首页和诊断控制台；iOS 部分迁移仍在施工。学习校准已由用户取消，不再算代码待办。
2. 用户已确认 iOS 真机 GPS 速度显示正常；后台未锁屏、锁屏暂停/解锁恢复、行程文件核验仍没有真机证据。
3. GitHub macOS CI 可证明工程编译/测试，不可证明 CoreBluetooth、定位后台、锁屏、控制器或车辆表现。
4. 本矩阵不是“已完成”清单；每个条目要在代码、测试、模拟器/真机和协议证据之间分别闭环。

## 本轮范围覆盖更新（2026-10-10 20:43:02 +0800）

- 用户取消 iOS 电池学习、校准历史修订与恢复；改为复用安卓内置固定能量曲线和后备公式。原矩阵中的完整学习校准不再是待实现目标，不等同已经导入手机私有学习数据库。
- 首页：已接通 10 类卡片真实渲染、顺序/显隐、保存/取消和宽窄屏；安卓 27 槽位和动态归还仍不等价。
- 续航：App 已改用共享 LocationService，BMS 提供外设 UUID，设置按 UUID 隔离；曲线领域数据正在集成。
- 控制器协议：已核对 37/39 字节、查询命令、字段和校验表；BLE/页面/历史施工中。
- GitHub 构建验证必须对应新提交；上次 11f091f 的成功 Run 不代表本轮代码通过。

## 已验证提交边界

- 8315235 / Run 38053408454：续航曲线/服务批次编译测试通过。
- ced33b3 / Run 38054889610：行程逐点/曲线/窗口、控制器只读服务/页面/历史、导航批次编译测试通过。
- 待提交首页完整槽位、驾驶设置消费接线、加速领域施工不在上述证据范围内。

## 当前工作树接线更新（2026-10-11 10:24:39 +08:00）

此节覆盖前文旧快照，不更改旧提交的验证事实。

| 项目 | 当前源码状态 | 仍需验证/边界 |
|---|---|---|
| 首页 | 27槽位/39指标、动态接管/归还、横竖屏、故障两列；真实控制器18项与RSSI已接入 | 本批编译/布局与真机；不把缺失值补零 |
| 普通驾驶设置 | 主题/字号/描述/阈值/功率图/探头、窗口/刷新/BMS周期、双启动连接策略已消费 | 保存偏好不代表已连接成功；只读查询不修改硬件参数 |
| 续航 | 有效窗口平均速度及真实电流Ah积分km/Ah、JSON/CSV、确认重置 | 不学习；取消的学习/分析包不算缺口 |
| 行程 | JSON/逐样本CSV长期导出、100样本/20窗口分页 | 地图逐点坐标和回放仍缺；后台/锁屏待真机 |
| 控制器导出 | JSON/18列CSV/XLSX、完整可选telemetry、确认删除、时序警告 | 旧档案字段缺失保持不可用，XLSX为文本型；真实控制器待验收 |
| 加速 | RPM唯一渠道，默认0.0782，状态机/真实流/记录/详情/导出/删除/失败重试 | 手机接收单调时钟非硬件时钟；断连/超时/后台/合批时序不可信则中止；待本批CI与车辆 |

全部“本批代码接入”均非当前可安装包或真机验收证明。

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

## 设置入口整理与安卓版对照（北京时间 2026-10-11 11:31:48 +08:00）

本节覆盖此前的六标签/重复续航入口说明；这是当前工作树改动，不属于前文 5bd1493 的已验证 IPA。

### 新入口与配置边界

- 顶层固定五项：**仪表盘、设备、详情、行程、设置**。去掉独立续航标签，避免六项 TabView 让系统生成 More；不是仅给 More 改文字。
- 设置为配置总入口：驾驶与显示设置、首页参数与布局、综合续航设置、RPM 加速测试与历史、控制器与历史记录、运行日志/记录等级。工具与配置按分组区分，不新增硬件写配置能力。
- **综合续航设置**直接编辑窗口、刷新、当前设备额定容量；窗口和刷新不再出现在驾驶与显示设置中。窗口/刷新仍使用原 driving_settings_v1 两字段，所有设备共用；容量仍按稳定外设 UUID 隔离，不迁移或清空旧配置。
- 综合续航结果、有效窗口指标与 JSON/CSV 导出从**仪表盘右上角 → 综合续航**查看。结果页不再提供第二个设置入口；设置页不再重复提供导出。
- 驾驶与显示的保存及局部恢复默认保留当前续航窗口/刷新、首页布局、设备 UUID、容量、历史和日志；旧驾驶草稿不能回写续航页后来保存的新配置。续航窗口/刷新有独立确认恢复默认操作；缩短窗口会剔除超出窗口的有效区间。
- 清除有效窗口保留本设备容量；重置容量与窗口仅影响当前设备，不改全局窗口/刷新、不删其他设备容量或历史。二者不是安卓版学习/校准重置。
- 日志默认等级按钮原来以当前记录等级作为禁用比较值，导致始终禁用；现改为与构建默认等级比较。

### 当前 Android 源码对照

对照父工程 app/src/main/java/com/zjsf/gps_ant_bms/model/DashboardModels.kt 的 DashboardSettings、DashboardUiState 与 normalized()，并检查 ui/DashboardScreens.kt 的设置表单。Android 工程仅只读，无代码修改或 APK 重建。

| 共用配置 | 两端当前默认值 | 范围/说明 |
|---|---|---|
| 综合续航窗口 / 刷新 | 15 分钟 / 10 秒 | 整数 3–60 分钟 / 10–60 秒 |
| BMS 查询周期 | 1000 ms | 整数 100–60000 ms，非控制器查询周期 |
| 数值比例 / 首页描述 | 1.0 / 关闭 | 比例 0.5–2.0 |
| 功率图 / 主题 / 温度来源 | 曲线 / 跟随系统 / 自动 | 保持相同选项语义 |
| 放电 / 充电功率条基数 | 6000 W / 2500 W | 不小于 1 W |
| 功率黄 / 红 | 0.55 / 0.90 | 0–1，黄不大于红 |
| SOC 红 / 黄 | 10% / 20% | 0–100%，红不大于黄 |
| 压差绿 / 黄 | 20 / 50 mV | 非负，绿不大于黄 |
| 温度绿 / 黄 | 39 / 45 °C | -50–150 °C，绿不大于黄 |
| 速度满格 / 中速 / 高速 | 80 / 30 / 60 km/h | 满格 1–300，中速不大于高速、不大于满格 |
| BMS / 控制器启动自动连接 | 分别开启 | 独立策略，保存不立即连接或断开 |

23 个共用配置的默认值一致；窗口、刷新、BMS 查询的三个范围由脚本直接对照。iOS 对非法输入明确拒绝，Android 表单包含规范化夹取；本次保留 iOS 严格校验，不为界面相似降低安全性。

仍未对等的项目：屏幕方向锁（iOS 当前自动横竖屏）；Android 悬浮窗/隐藏最近任务/浏览器控制台入口未移植。学习、完整续航分析包按既有产品范围不实现，不因本次设置整理重新扩展。地图轨迹、Live Activity/CarPlay 仍维持此前状态；本次不宣称所有 Android 功能已对等。

### 验证状态

- Windows 已运行 python scripts/check_settings_contract.py：6 项源码契约检查全部通过，包括直接对照 23 个默认值和 3 个周期范围；这些是静态检查，不是 Swift 运行测试。
- git diff --check 通过；独立代码审查及增量复核未发现确定问题。Swift 语法树 ERROR 扫描无匹配，但不等同类型检查或编译通过。
- 新增 4 项 App XCTest：旧草稿保存不覆盖新续航配置、驾驶局部默认重置保留独立配置、非法输入不写存储或发布事件、续航局部恢复后重载设置/服务配置并保留独立数据；新增 4 项 UI XCTest：五标签/横竖屏设置可见、唯一续航编辑器、仪表盘结果入口、续航恢复默认的确认/取消及保留驾驶偏好。
- CI 工作流增加源码契约检查；独立 iOS checkout 无 Android 目录时，两项 Android 对照会明确跳过，其余导航检查继续运行。
- 续航页使用可回归测试的范围限定保存方法；恢复默认 UI 测试仅在 DEBUG 隔离 UserDefaults 套件中预置配置，双自动连接关闭，不写用户真实配置。横竖屏测试等待实际应用尺寸改变，并显式验证回到竖屏。
- 本机无 swift/xcodebuild；新增 XCTest、SwiftUI 编译、模拟器和真机运行均未执行。未提交、未推送、未生成新 IPA；旧 CI 或安装成功反馈不能验证本批修改。


### 本批 macOS/交付状态更新（北京时间 2026-10-11 15:06:00 +08:00）

- 上文“未提交、未运行 Xcode/未生成 IPA”保留为前期历史：设置与 Dashboard 本批源码 `414d8b0` 已发布，Run `38119495743` 全部成功（130 SwiftPM / 280 App XCTest / 9 XCUITest）。IPA 已下载校验，latest 已同步；准确版本和哈希见施工步骤 039。
- 首页保留指标和布局偏好，按 iOS 原生交互删除顶栏/固定辅助卡，行程控制移动至行程 Tab、图表迁移系统 Swift Charts；不追求 Android 顶部布局像素级一致。
- 真实设备/BMS/车辆验收与既有平台/算法差异继续保留，未扩展 RPM-only 或宣称 Android 全面对等。


### 续航驾驶窗口算法对齐（北京时间 2026-10-12 12:30:00 +08:00）

- 用户确认范围：**核心驾驶窗口算法已对齐 Android，但不是包含学习、审计和所有显示行为的完整复刻**；上方功能矩阵「综合续航预测」行的状态据此更新为「部分/CI通过（窗口算法已对齐）」。
- 已对齐：有效驾驶判定（区间位移÷时长 ≥ 3 km/h，不用瞬时 GPS 速度）、预测门槛（30 秒/200 米/5 Wh 放电/5 Wh 净能耗同时满足）、窗口按累计有效驾驶时长 FIFO、净 Wh = 放电 − 移动再生、`电压 × 电流` 跨零分别积分、部分区间按时间比例裁剪后重积分、窗口缓存配合最新 BMS 剩余量、按设备 UUID 恢复证据且不保存坐标。
- 有意保留的差异：过期/断连时 iOS 撤下预测并显示不可用，Android 保留旧数值并标记暂停；iOS 保留更严格的数据有效性检查；Android 原始区间审计、排除原因记录与回放体系未移植；仍不学习、不恢复 Android 校准数据，沿用 seed/legacy 曲线与现有容量设置。
- 验证：Run `38202579046`（`60101a4`）全部步骤成功，SwiftPM 161 / iOS XCTest 364 / XCUITest 12 零失败，续航源码契约 11 例通过；unsigned IPA 2276667 字节已核验，详见 `docs/CI_BUILD_RESULTS.md` 与 `docs/CONSTRUCTION_LOG.md` 步骤 041。
- 真机续航窗口验收仍待 iPhone + BMS + 车辆：真实 GPS 漂移、断连重连、后台锁屏与容量跳变场景不能用 CI/模拟器替代。
