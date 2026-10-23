# ANTuRide 实时活动与灵动岛方案（v2：锁屏续记 + 远程数据源预留）

> 状态：**方案评审稿 v2，未修改任何源码**。本文不构成"已实现/已验收"声明。
> v1（2026-10-22 15:13）以"锁屏必须暂停"为硬前提，给出 A1/A2/A3 三个选项；本轮用户已明确"锁屏暂停是无奈之举，续记更好"，**v1 的该前提与三选项全部作废**，v2 据此重写。
> 基准：`project.yml`、`LocationService.swift`、`TripSessionService.swift`、`TripStore.swift`、`BmsBluetoothService.swift`、`DrivingSettings.swift`。

---

## 0. 结论先行

1. **锁屏续记可行，而且缺口比预期小。** 现有代码已经具备后台定位能力，缺的只有 `UIBackgroundModes` 里的 `bluetooth-central` 声明和一处主动 `suspend`。真正的问题不是"能不能"，而是下面第 2 条。
2. **有一个必须先正视的反向风险**：`persistLive()` 当前**唯一**的触发点是 `handleDeviceLocked()`。一旦锁屏不再暂停，整段行程只在内存里跑，App 被系统回收就全丢。所以"锁屏续记"必须同时补定期落盘，否则这次改动的实质是**用数据安全换实时性**。
3. **推荐方案 B**：锁屏续记 + 单活动 + 数据源抽象 + `pushType: .token` 预留。远程数据源本期不实现，但接口和活动类型一次做到位。
4. **`pushType` 是请求时锁定、事后不可改的字段**。这是本期最重要的前瞻决策：现在不定 `.token`，将来远程要驱动活动就只能让所有用户重建活动。

---

## 1. 锁屏续记：逐条代码核查

| 能力 | 代码证据 | 结论 |
|---|---|---|
| 后台定位 | `LocationService.swift:85-86` `allowsBackgroundLocationUpdates = demand.allowsBackgroundUpdates`；`LocationUpdateDemand.swift:9` `= isRecordingTrip` | 行程中已开启，**无需改动** |
| 系统自动暂停定位 | `LocationService.swift:42` `pausesLocationUpdatesAutomatically = false` | 已关闭，**无需改动** |
| 定位精度与间隔 | `kCLLocationAccuracyBest` + `distanceFilter = 5`（`LocationService.swift:17,39-41`） | 5 米距离过滤，静止不产点，功耗可控 |
| 后台 BLE | `project.yml:61-62` `UIBackgroundModes: [location]`，**无 `bluetooth-central`** | **必须补** |
| BLE 状态恢复 | `BmsBluetoothService.swift:104` `CBCentralManager(delegate: nil, queue: .main)`，未用 `CBCentralManagerOptionRestoreIdentifierKey` | 进程被杀后无法恢复连接；锁屏场景有定位保活可接受，但要记入限制 |
| 周期查询 | `BmsBluetoothService.swift:484` 主线程 `Timer`，`effectiveQueryInterval` 默认 1s | 进程不被挂起即正常；锁屏有定位保活 → 正常 |
| 锁屏主动暂停 | `TripSessionService.swift:153-160` `handleDeviceLocked()` → `recorder.suspend()` + `state = .suspended` | **纯产品选择，非系统限制**，可移除 |
| 锁屏期间落盘 | `TripSessionService.swift:159` `persistLive()` 仅在此调用 | **唯一定期落盘点，移除 suspend 后必须新补** |
| 文件保护 | `TripStore.swift:28` `data.write(to: url, options: .atomic)`，未显式指定 protection | 默认通常锁屏可写，但**不应依赖默认值** |
| 网络层 | `Sources/` 全量无 `URLSession` | 远程数据源需要新建整个链路 |

一句话结论：**改 4 处 + 新增 1 处**。

---

## 2. 锁屏续记的 5 项配套改动

### 2.1 补 `bluetooth-central`（必做）

```yaml
UIBackgroundModes:
  - location
  - bluetooth-central
```

这是"允许后台保持 BLE 连接并接收通知"的声明。缺它时锁屏后 BLE 会断流，而且**失败是静默的**——活动卡片还在、数字不动，用户不会知道数据已经停了。必须配合 `staleDate` 让系统把过期状态显性化。

### 2.2 移除 suspend，锁屏转为 background 段

`handleDeviceLocked()` 不再 `suspend`，改为 `updatePhase(.background)`，与 `didEnterBackgroundNotification` 的语义合并。

- `TripSegmentKind.suspended` **保留枚举值**（旧档案 Codable 兼容），但新行程不再产生。
- 锁屏期间的真实缺口（低电量模式暂停定位、BLE 断连）由 `TripRecorder` 现有长间隔规则落为 `gap`，不伪造连续。
- 需同步更新 `docs/MIGRATION_PLAN.md` 与验收红线文字：由"锁屏暂停"改为"锁屏续记，缺口如实标记"。

### 2.3 补定期落盘（**本次最重要的配套**）

建议每 **30 秒**或累计 **30 个采样点**落盘一次（先到者触发），继续走 `TripStore.save` 的原子写。

- 不做这步：锁屏 1 小时后 App 被回收，整段行程全丢——**比现状更糟**。
- 做了这步：崩溃/被杀的丢失面从"上次暂停之后"缩小到"最近 30 秒"，顺带改善现有体验。

### 2.4 显式文件保护

```swift
try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
```

目的：不依赖 App 默认 protection 推断锁屏可写性。**不要**用 `.completeFileProtection`，那会让锁屏后写入失败——正好是本次要解决的场景。

### 2.5 后台降频

锁屏 + 1s BLE + 后台 GPS + 定期落盘，功耗会明显上升。建议锁屏期间把查询周期降到 **2.5s**，回前台恢复用户设置值（`DrivingSettings.bluetoothRefreshIntervalMs`）。`BmsBluetoothService.swift:126-127` 已有周期应用入口，改动成本一行级。

GPS 侧不需要再降：`distanceFilter = 5` 已经是距离驱动。

---

## 3. 功耗与降级路径（诚实预期）

| 场景 | 行为 |
|---|---|
| 低电量模式 | 系统可能暂停后台定位 → 进程被挂起 → 活动停在最后值，`staleDate` 过期，卡片显示"数据过期" |
| 定位权限被收回 | `reconcileUpdates` 停止更新，行程落 gap，活动显示 `noData` |
| BLE 断连 | `latestSnapshot = nil`（`BmsBluetoothService.swift:469`），活动显示 `noData`，行程落 gap |
| 活动时长上限 | 活跃约 8 小时，之后最多再保留 4 小时，系统结束 |
| 用户强杀 App | 活动不会立即消失，靠 `staleDate` 兜底 + 下次启动清理 |
| 无 `bluetooth-central` | 锁屏后 BLE 静默断流，**必须靠日志与 stale 态暴露** |

功耗预期：1 小时锁屏骑行（BLE 2.5s + GPS 5m）粗估 8–15%，**必须真机实测后才可对外表述**，现在只能作为预算上限。

---

## 4. 远程数据源：本期只做抽象

### 4.1 为什么不能等接远程时再改

三个硬耦合点：

- `TripSessionService.init(locationService:bmsService:store:)` 直接接收 `BmsBluetoothService`
- `RangeService.init(bms:location:defaults:)` 同样
- Live Activity 协调器若直接订阅 `$latestSnapshot`，也会绑死

将来换远程源 = 改 3 个服务的构造签名 + 全部测试构造点 + 活动重建。

### 4.2 抽象草案（零侵入，仅加 extension）

```swift
// Sources/Services/Telemetry/TelemetrySource.swift
public enum TelemetryAvailability: Equatable, Sendable {
    case localBLE
    case remote(ageSeconds: TimeInterval)
    case offline
}

public protocol TelemetrySource: AnyObject {
    var latestSnapshot: BmsSnapshot? { get }
    var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> { get }
    var telemetryAvailability: TelemetryAvailability { get }
}

extension BmsBluetoothService: TelemetrySource {
    public var snapshotPublisher: AnyPublisher<BmsSnapshot?, Never> {
        $latestSnapshot.eraseToAnyPublisher()
    }
    public var telemetryAvailability: TelemetryAvailability { .localBLE }
}
```

`latestSnapshot` 已是 `@Published public private(set)`（`BmsBluetoothService.swift:57`），所以 BLE 侧**不需要改一行现有代码**，只加 extension。

`TripSessionService` / `RangeService` / `LiveActivityCoordinator` 的入参类型改为 `TelemetrySource`。未来 `RemoteTelemetrySource` 实现同一协议，`FusedTelemetrySource` 按"本地优先、远程兜底"合并。

### 4.3 远程链路的三个前置条件（当前都不具备）

1. **接口契约**：字段、单位、上报频率、时间戳语义（设备时间 vs 服务端时间）
2. **鉴权与设备绑定**：当前 App 零账号、零网络请求，远程必须要用户体系
3. **可信度分级**：远程延迟 1–10s 是正常的，UI 与活动必须标注来源与数据年龄，不能和本地 BLE 混为一谈

结论：远程数据源是一个独立项目（后端 + 鉴权 + 客户端），Live Activity 只是它的末端消费者。本期**不做实现**，只留接口。

---

## 5. `pushType: .token` 的锁定效应

```swift
let activity = try Activity.request(
    attributes: attrs,
    content: .init(state: initial, staleDate: Date().addingTimeInterval(30)),
    pushType: .token
)
```

- 本地 BLE 场景下 `.token` 不影响本地 `update()`，只额外要求处理 `pushTokenUpdates` 序列。
- 本期无服务端 → 拿到 token 后仅记录日志即可，不影响功能。
- 未来接远程时，服务端可直接对**已存在**的活动推 `content-state`，用户无需重建活动。
- 代价：需处理 token 刷新，真机需验证能取到 token（模拟器/无签名环境可能取不到，但不影响编译与本地更新）。

**不选 `.token` 的后果**：将来远程更新只能要求用户重新开始一次行程来生成新活动，体验断层。这是我认为值得现在多写约 30 行的唯一理由。

---

## 6. 方案对比（v2）

| | A 锁屏续记 + 单活动 | **B A + 数据源抽象 + token 预留** | C B + 远程实现 | D 远程优先重构 |
|---|---|---|---|---|
| 锁屏续记 | ✓ | ✓ | ✓ | ✓ |
| 灵动岛 / 锁屏卡片 | ✓ | ✓ | ✓ | ✓ |
| 远程数据源 | 无 | 接口预留 | 实现 | 唯一数据源 |
| `pushType: .token` | 否 | **是** | 是 | 是 |
| 本期可交付 | ✓ | ✓ | ✗（无契约/鉴权/后端） | ✗ |
| 新增文件 | 4 | 6 | 8+ | 15+ |
| 未来接远程返工 | 大（改 3 服务 + 重建活动） | 小（只加实现类） | — | — |
| 主要风险 | 功耗与数据安全需实测 | 同 A + 抽象需一次设计到位 | 无法验证 | 不适用 |
| 建议 | 可接受 | **推荐** | 暂缓 | 不适用 |

---

## 7. Live Activity 形态（沿用 v1 结论）

四种呈现一套 `ActivityConfiguration`：

| 形态 | 内容 |
|---|---|
| compact | 左 SOC 图标 + `78%`；右 `1.2 kW` |
| minimal | 单个数字 `42` |
| expanded | 左 `42 km/h`、右 `78%`、底部 `1.2 kW · 12.4 km · 00:23` |
| 锁屏卡片 | 4 列：速度 / SOC / 功率 / 里程 |

关键约束：
- 时长用 `Text(timerInterval:)` 自走，**不占更新预算**。
- payload 上限 4KB，只传聚合标量，**不传单体电压数组**。
- `freshness` 四值在锁屏续记后调整：`fresh` / `stale`（>5s 未更新）/ `noData` / `offline`（低电量模式或后台被挂起）。v1 的 `paused` 语义随 suspend 移除而消失。
- 只用 SF Symbols，不用 emoji；数字 `.monospacedDigit()`。

---

## 8. 更新节流

现状是 BLE 1s 轮询 + `$latestSnapshot` 每秒推送，不能 1:1 调 `update()`：

```
最小间隔：前台 1s，锁屏 2.5s（与后台降频一致）
变化阈值（任一满足才推）：SOC ≥0.5pt | 速度 ≥1km/h | 功率 ≥50W | 里程 ≥10m | freshness 变化
时间流逝不触发更新
```

节流器写成纯函数，放 `Sources/Services/LiveActivity/`，在 `Tests/AppTests` 单测，不依赖 WidgetKit 与真机。

---

## 9. 改动面清单（方案 B）

| 文件 | 改动 |
|---|---|
| `project.yml` | 新增 `ANTuRideLiveActivity`（`app-extension`，16.1）；app `dependencies` 加该 target；UIBackgroundModes 加 `bluetooth-central`；`NSSupportsLiveActivities: true`；app/extension 版本统一 16.1 |
| `Sources/LiveActivity/RideActivityAttributes.swift` | 新建。attributes + ContentState（含 `source` 字段），iOS only，**不进 Package.swift** |
| `Sources/Widgets/LiveActivity/*.swift` | 新建。`@main WidgetBundle` + `ActivityConfiguration` + 四态视图 |
| `Sources/Services/LiveActivity/RideLiveActivityCoordinator.swift` | 新建。request/update/end/残留清理/可用性检查，依赖 `TelemetrySource` |
| `Sources/Services/LiveActivity/LiveActivityUpdatePolicy.swift` | 新建。纯函数节流 |
| `Sources/Services/Telemetry/TelemetrySource.swift` | 新建。协议 + `BmsBluetoothService` extension |
| `Sources/Services/TripSessionService.swift` | 注入类型改 `TelemetrySource`；移除 suspend；新增定期落盘；锁屏 phase 改 background |
| `Sources/Services/RangeService.swift` | 入参改 `TelemetrySource`（签名级） |
| `Sources/Services/TripStore.swift` | 显式 `completeFileProtectionUntilFirstUserAuthentication` |
| `Sources/Domain/Settings/DrivingSettings.swift` | 新增 `liveActivityEnabled` + `normalized()` |
| `Sources/Features/Settings/SettingsView.swift` | 新增「锁屏实时活动」开关与系统关闭时的降级说明 |
| `.github/workflows/build.yml` | 断言 `PlugIns/*.appex/Info.plist`、`NSSupportsLiveActivities`、extension 自带 `PrivacyInfo.xcprivacy` |
| `docs/MIGRATION_PLAN.md` | 登记锁屏语义变更（暂停 → 续记 + gap） |
| `docs/PRIVACY_AUDIT.md` / `PRIVACY.md` | 登记锁屏可见性边界变化 |

目录归属红线：`Sources/Widgets/` **只能**给 extension。里面是 `@main WidgetBundle`，进 app target 会和 `ANTuRideApp` 的 `@main` 直接冲突。

---

## 10. 七个坑

1. **Domain 包不能 import ActivityKit**：`Package.swift` 声明 `.macOS(.v13)`，`swift test` 会先红。
2. **extension deploymentTarget 不能高于 App**：要 16.1 就两边一起提。
3. **`@main` 冲突**：WidgetBundle 目录不能进 app target 的 `sources`。
4. **payload 4KB**：只传聚合标量。
5. **活动残留**：冷启动必须清理 `Activity.activities` 中非当前会话的活动。
6. **锁屏续记后必须定期落盘**（本次新增）：否则数据安全倒退，这是最容易漏的一条。
7. **`bluetooth-central` 缺失导致静默断流**（本次新增）：失败无报错，只能靠 `staleDate` 与日志暴露。

---

## 11. 验收分层

| 层 | 内容 | 现状 |
|---|---|---|
| 静态 | 目录归属、`project.yml` 解析、`Package.swift` 未被污染 | 可在 Windows 完成 |
| 单测 | 节流策略、state 编解码、freshness 映射、定期落盘计数 | macOS CI `swift test` + XCTest |
| 构建 | appex 存在、`NSSupportsLiveActivities`、extension 隐私清单 | macOS CI，需新增断言 |
| 模拟器 | 请求/更新/结束、四态布局、iPhone 14 Pro 展开态 | XCUITest 无法操作灵动岛，靠 Preview + 人工截图 |
| 真机 | **锁屏 30 分钟长测**：BLE 是否断流、落盘是否正常、电量消耗、活动是否被系统结束；另需一台非挖孔机型验证锁屏卡片 | **必须**，CI 不能替代 |

---

## 12. 待你决策

1. **锁屏 BLE 降频到 2.5s** 是否接受（省电 vs 数据密度）？
2. **定期落盘间隔 30s** 是否合适？
3. **`pushType: .token` 是否现在就上**（我的建议：上，成本约 30 行，避免未来重建活动）？
4. **`liveActivityEnabled` 默认开还是默认关**（锁屏可见 = 速度/电量/里程未解锁即可见）？

确认后我出施工顺序与逐文件 diff。本轮未动代码。

---

## 13. v3 施工记录（北京时间 2026-10-22 15:25:44 +08:00）

用户确认全部推荐项，并明确数据源优先级：**本地蓝牙有新鲜数据时用蓝牙，蓝牙没数据才请求远程**。

### 13.1 已定参数

| 项 | 取值 |
|---|---|
| 锁屏 BLE 降频 | 基础间隔 × 2.5，上限 60s |
| 进行中落盘 | 30 秒或 30 个采样，先到者触发；锁屏边界强制一次 |
| `pushType` | `.token`（本期拿到 token 仅记录，不接服务端） |
| `liveActivityEnabled` | 默认**开启**；仅行程记录期间存在，结束即消失，设置页可关 |
| 最低版本 | App 与 extension 一起提到 16.1（Phase 3 执行） |

### 13.2 已完成（Phase 1 数据层 + Phase 2 锁屏续记）

| 文件 | 状态 |
|---|---|
| `Sources/Services/Telemetry/TelemetrySource.swift` | 新增。协议、`TelemetryLinkState`、`TelemetryAvailability`、BLE 零侵入遵循 |
| `Sources/Services/Telemetry/RemoteTelemetryProviding.swift` | 新增。按需拉取协议 + `DisabledRemoteTelemetryProvider` |
| `Sources/Services/Telemetry/FusedTelemetrySource.swift` | 新增。本地优先融合、10s 冷却、不覆盖新值、后台保持转发 |
| `Sources/Services/BmsBluetoothService.swift` | 改。`sustainsBackgroundTelemetry`、2.5 倍降频、放开 3 处 `isForeground` 硬守卫 |
| `Sources/Services/TripSessionService.swift` | 改。移除锁屏 `suspend`、锁屏转 `.background`、30s/30 采样落盘、注入 `TelemetrySource` |
| `Sources/Services/TripStore.swift` | 改。显式 `completeFileProtectionUntilFirstUserAuthentication` |
| `Sources/Services/RangeService.swift` | 改。新增 `telemetry:` init，旧 `bms:` 保留转发 |
| `Sources/App/ANTuRideApp.swift` | 改。装配 `FusedTelemetrySource` |
| `project.yml` | 改。`UIBackgroundModes` 增加 `bluetooth-central` |
| `Tests/AppTests/TelemetryFusionTests.swift` | 新增。6 项融合策略 + 1 项后台降频 |

### 13.3 尚未执行（Phase 3：Live Activity 本体）

1. `project.yml` 新增 `ANTuRideLiveActivity` target（`app-extension`，16.1），并把 App 的 deploymentTarget 一起提到 16.1。
2. `Sources/LiveActivity/RideActivityAttributes.swift`（iOS only，不进 `Package.swift`）。
3. `Sources/Widgets/LiveActivity/`：`@main WidgetBundle`、`ActivityConfiguration`、紧凑/最小/展开/锁屏四态。
4. `Sources/Services/LiveActivity/`：`RideLiveActivityCoordinator`（`pushType: .token`、残留清理、`staleDate`）与 `LiveActivityUpdatePolicy`（纯函数节流）。
5. `DrivingSettings.liveActivityEnabled` + 设置页开关与降级说明。
6. CI 断言：`PlugIns/*.appex/Info.plist`、`NSSupportsLiveActivities`、extension 自带 `PrivacyInfo.xcprivacy`。

**为什么分两批**：Phase 1/2 改的是记录行为与数据源，Phase 3 改的是 target 结构。混在一次 CI 里失败时无法二分定位；且 Windows 无法编译，必须让 CI 先验证行为层。

### 13.4 验证边界

本轮**未执行**任何 Swift/Xcode 编译、SwiftPM、XCTest/XCUITest、macOS CI 或真机验证。Windows 侧仅做静态检查。Phase 1/2 的完成状态是"源码已写、待 CI"，不是"已验证"。

---

## 14. Phase 3 施工记录：实时活动本体（北京时间 2026-10-22 16:32:01 +08:00）

### 14.1 已完成

| 文件 | 说明 |
|---|---|
| `project.yml` | App/全 target 提到 16.1；新增 `ANTuRideLiveActivity`（`app-extension`）；App 增加 `Sources/LiveActivity`、`NSSupportsLiveActivities`、对 extension 的依赖；scheme 加入新 target |
| `Sources/LiveActivity/RideActivityAttributes.swift` | 静态属性 + `ContentState`（速度/SOC/功率/里程/freshness/isCharging/source） |
| `Sources/Widgets/LiveActivity/ANTuRideWidgetBundle.swift` | `@main WidgetBundle`，只属于 extension |
| `Sources/Widgets/LiveActivity/RideLiveActivityWidget.swift` | 紧凑/最小/展开/锁屏四态 + extension 内最小格式化 |
| `Sources/Services/LiveActivity/LiveActivityUpdatePolicy.swift` | 纯函数节流：状态变化立即推；运动 1s / 静止 5s；阈值 SOC 0.5pt / 速度 1km/h / 功率 50W / 里程 10m |
| `Sources/Services/LiveActivity/RideLiveActivityCoordinator.swift` | 观察式协调：`.token`、16.1/16.2 API 分支、`staleDate` 30s、残留清理、令牌仅记录 |
| `Sources/Services/TripSessionService.swift` | 新增 `ActiveTripContext` / `activeTripContext`，避免从 `@Published` 反推旧值 |
| `Sources/App/ANTuRideApp.swift` | 装配 coordinator |
| `Sources/Features/Settings/DrivingSettingsView.swift` | 「锁屏与灵动岛」开关 + 系统关闭时的降级说明 |
| `Resources/LiveActivity/PrivacyInfo.xcprivacy` | extension 独立隐私清单 |
| `Tests/AppTests/LiveActivityUpdatePolicyTests.swift` | 8 项节流断言 |
| `.github/workflows/build.yml` | 5 条新断言：`NSSupportsLiveActivities`、appex 存在于 `PlugIns`、appex 隐私清单、`NSExtensionPointIdentifier`、appex bundle id |

### 14.2 四个关键取舍

1. **开关不放进 `DrivingSettings`**。版本化 JSON 新增非可选字段会让旧存档解码失败并回退默认值——等于清空用户全部驾驶偏好。改用独立 key `com.zjsf.anturide.liveActivityEnabled`，与既有 `isKeywordFilterEnabled` 模式一致。
2. **不设 `widgetURL`**。Live Activity 点击默认打开宿主 App，注册 URL scheme 是额外改动，本期不需要。
3. **`pushType: .token` 已启用**。本期无服务端，令牌只记日志；将来接远程推送无需用户重建活动。
4. **灵动岛使用固定字号**。岛内区域固定、Dynamic Type 不可用，语义字号在最大辅助字号下会被裁切。这是对 `MASTER.md`「禁止固定字号」的显式例外，作用范围仅限 Widget extension。

### 14.3 验证边界与已知风险

- 本轮仍未执行编译/CI/真机。Windows 侧仅做括号平衡、XML 合法性与目录归属检查。
- **最高风险的三个编译点**：`@MainActor` 协议与 `Combine` 闭包的隔离、`Activity.end` 在 16.1/16.2 的重载选择、XcodeGen 对 `app-extension` 的 `PlugIns` 嵌入。
- 真机必须验证：活动创建/结束、锁屏 30 分钟更新、iPhone 14 Pro 展开态、非挖孔机型锁屏卡片、系统关闭实时活动后的降级、以及行程结束后卡片确实消失。

## 15. 收尾记录与真机移交（北京时间 2026-10-23 14:50:00 +08:00）

§14.3 的「本轮仍未执行编译/CI」已作废。本节为准。

### 15.1 代码状态

功能已全部落地并合入 `codex/ios-parity-20261010`，相关提交（按时间）：

| 提交 | 内容 |
| --- | --- |
| `3e50e38` | 锁屏续记：`TelemetrySource` 抽象、`FusedTelemetrySource`、蓝牙后台闸门与 2.5 倍降频、30s/30 采样节流落盘、文件保护等级 |
| `9816cd9` | 实时活动本体：attributes、Widget extension、协调器、节流策略、设置开关、`project.yml`、CI 断言 |
| `4bc4e29` | 协调器整类 `@MainActor`；偏好键移出隔离类型 |
| `e720295` | 扩展补齐 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`；CI 断言 appex 版本等于宿主 |
| `49d6233` | 探测定时器不再无条件触发 `@Published` |
| `e30c529` / `6f086b9` / `c54c8c4` | UI 断言修正（等待、陈旧标识符、可点击性） |
| `980afed` | CI job 预算 60 → 90 分钟 |

### 15.2 CI 已证实的部分

- Release 设备构建通过；包内断言全绿（含新增 5 条实时活动断言 + 2 条版本一致性断言）。
- SwiftPM 与 iOS 单元测试全绿，包含 `TelemetryFusionTests`（6 项融合 + 1 项后台降频）与 `LiveActivityUpdatePolicyTests`（8 项节流）。
- UI 用例：13 个 `ANTuRideUITests` 通过 12 个；`HomeParameterEditingUITests` 13 个通过 12 个 + 1 个经定向运行单独通过。**未做最后一次全量回归**。

### 15.3 真机移交清单

前置：使用自己的证书签名后安装；设置里允许「实时活动」。

1. **创建/结束**：开始行程 → 锁屏立即出现卡片；结束行程 → 卡片消失。冷启动 App 后确认无残留卡片。
2. **锁屏续记（核心）**：连接 BMS 与控制器后开始行程，锁屏 30 分钟。预期：`DEBUG` 日志出现「进入后台：行程记录中，保留 BMS 查询（间隔 2.5s）」；锁屏数字持续更新；解锁后行程里程覆盖锁屏时段。
3. **过期语义**：锁屏期间断掉 BMS 电源，30 秒内卡片应转为过期态并显示「数据已过期」，**不得**继续显示旧数字当作实时值。
4. **灵动岛**：iPhone 14 Pro 及以后机型验证紧凑态（电量图标 + SOC）、最小态、展开态（速度/来源/功率/里程/计时 + 过期提示）。
5. **非挖孔机型**：确认锁屏卡片布局不溢出，四个指标在同一行可读。
6. **系统关闭实时活动**（设置 → 安途 → 实时活动）：App 内开关打开不应崩溃；设置页应显示橙色降级说明。
7. **耗电抽样**：锁屏 30 分钟前后记录电量百分比，作为后续调参基线。
8. **优先级说明**：远程数据源本期只有协议（`RemoteTelemetryProviding`）与 `DisabledRemoteTelemetryProvider`，生产装配未接远程，锁屏断连时不会回填云端数据——这是预期行为。

### 15.4 已知风险（真机才会暴露）

- `bluetooth-central` 后台模式若被系统回收，锁屏数字会停更；靠 `staleDate` 30 秒兜底转灰，不会伪造实时值。
- 后台 2.5 倍降频是能耗与新鲜度的折中，若真机出现明显滞后可调整 `backgroundQueryIntervalMultiplier`。
- 活动更新预算：策略已按运动 1s / 静止 5s 节流，但极端长时间记录（>2 小时）仍建议观察是否触发系统降频。
