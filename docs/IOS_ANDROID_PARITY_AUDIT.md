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
| 综合续航预测 | `model/BatteryEnergyCalibration.kt`、RangeAnalysis*、`RangeStatusText.kt` | RangeService + 安卓 seed/legacy 曲线 | 部分/批次CI通过 | 8315235已编译；可配置窗口/完整安卓分析包仍待 |
| 电池学习/历史修订/学习恢复 | `BatteryEnergyCalibration.kt`、`BatteryCalibrationChart.kt` | AndroidEnergyCurve 只读数据 | 按用户决定取消 | 不做iOS学习，复用安卓内置数据；不声称手机私有学习数据库已导入 |
| CSV/JSON 行程/控制器导出 | `ControllerRecordExporter.kt`、主界面导出入口 | iOS 行程详情仅 JSON 临时分享 | 部分 | 增加 CSV、长期可访问导出与核验 |
| 本地删除/重置 | Android 设置与数据入口 | iOS 行程删除；无完整重置 | 部分 | 明确分级删除：行程、校准、日志、全部数据 |
| 控制器 BLE 实时数据 | `MotorControllerBluetoothManager.kt`、`ControllerFeatureScreen.kt` | ControllerBluetoothService/View | 已接线/CI通过/待真机 | 只读查询、分片、超时；前台共享会话，真实车辆待验收 |
| 控制器记录与导出 | `ControllerRecordSession.kt`、`ControllerRecordExporter.kt` | ControllerHistoryStore + 页面 | 部分/CI通过 | JSON/七列CSV，安卓18列/XLSX仍缺 |
| 首页参数自定义/动态底部参数 | `HomeParameterEditor.kt`、`HomeParameterPresentation.kt` | 10卡片已接线；27槽位/39指标施工中 | 部分 | 不将旧10卡片与安卓全布局等价 |
| 普通设置/阈值/采样周期 | `DashboardScreens.kt`、`DashboardSettings` | DrivingSettings/View 23项 + 日志 | 部分/接线施工中 | 21默认值及双连接开关已对照；必须核查消费端真实生效 |
| 加速测试/RPM-GNSS-IMU 融合 | `AccelerationTestScreen.kt`、`acceleration/` | 无 | 缺失 | 先移植纯算法；不宣称专业精度；需真机传感器验收 |
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
