# ANTuRide iOS GitHub 构建结果记录

> 记录时间：2026-10-12 12:30（北京时间，最近一次更新）
> 仓库：`https://github.com/River-1024/GlacierBMS-iOS`（私有）
> 工作流：`.github/workflows/build.yml`
> 说明：本机（Windows）无 Swift/Xcode，iOS 编译与测试全部在 GitHub-hosted macOS runner 上执行。
> 本文档为收尾时点快照；此后仅文档类提交不改变构建语义。

## 1. 结论

**最近一次更新（2026-10-12 12:30）：** 续航驾驶窗口算法对齐 Android（effective-driving FIFO）经 4 轮 CI 迭代后全绿：Run `38202579046`（提交 `60101a4`，`workflow_dispatch`）14 个具名步骤全部成功（作业 04:08:42 → 04:17:35 UTC，8m53s），产物 2276667 字节，已归档 `build/ci/60101a4/`。测试基线：SwiftPM 161、iOS XCTest 364、XCUITest 12，全部零失败；四项源码契约 33 例通过（设置 6（含 2 例 Android 对照显式跳过）、Dashboard 6、蓝牙 10、续航 11）。迭代修复：① 编译级漏参（`RangeServiceTests:913` 缺 `longitude`，`Tests/AppTests` 不参与 `swift test`，静态检查无法发现）；② 测试语义与实现不符（`testNetAh` 步长笔误致区间全拒、`testColdRestoration` 缺断连 flush 前置）；③ UI 测试时序不稳（`bluetooth.battery.filter` 高负载偶发丢 tap，条件重试加固）。交付文档提交 `e81449c` 及其连带运行 `38204388224` 同样成功（9m31s），用于证明文档改动不破坏构建；其产物归档 `build/ci/e81449c/`，因源码与 `60101a4` 相同而未替换 `latest`。

**上一轮（2026-10-10 12:15）：** 新增本地取包脚本 `scripts/fetch-ipa.sh`（详见第 7.1 节），构建产物从此按提交号归档到 `build/ci/<短SHA>/`，并由 `build/ci/latest/` 指向最近一次成功。

**上一轮（2026-10-10 12:10）：** 新增日志系统（`Sources/Services/Logging/` 7 文件）与设置页日志管理 UI 后，运行 `38022252771`（提交 `4ab1c9b`）在 Xcode 26.3 / iOS 26.2 SDK 上全绿（10m4s），全部 12 个步骤成功，产物 1292490 字节。随后 `b32508a`（文档提交）连带运行 `38022973698` 同样全绿，产物同尺寸。

本轮共经 4 次迭代修复（详见第 4 节），暴露并解决了 4 类此前未触发的构建缺陷：SwiftPM 与 Xcode 测试目标共享目录导致的模块可见性冲突、public 类型引用 internal 类型、废弃的通知常量名、测试方法与 `XCTestCase` 属性同名。

测试基线：`swift test` 执行 **12 例全通过**；iOS 模拟器 `xcodebuild test` 执行 **22 例 + 1 例 UI 测试全通过，0 失败**（含新增日志层 `LogLevelTests` 5 例、`LogEntryTests` 5 例）。

包内资源核验：`Assets.car`（946264 字节）、`PrivacyInfo.xcprivacy`（397 字节）、`AppIcon60x60@2x.png`（19248 字节）均在；app 自身 `Info.plist` 的 `CFBundleDisplayName = 安途`、`CFBundleIdentifier = com.zjsf.anturide`、`CFBundleIconName = AppIcon`、`UILaunchScreen = {}`、蓝牙与定位用途说明齐全；`CFBundleIcons` 已生成。主二进制（1206688 字节）中日志系统 10 个类型符号全部存在。

工作流已稳定通过。阶段 1 收尾提交 `f1d125e` 对应的运行 `37955477377` 成功完成以下四件事：

1. SwiftPM 领域测试（`swift test`），含新鲜度评估与 `0x11` 偏移锁定测试。
2. iOS 模拟器测试（`xcodebuild test`，`CODE_SIGNING_ALLOWED=NO`）。
3. 无签名设备构建（`xcodebuild build -configuration Release`），并产出无签名 IPA 产物。
4. 首次在 Xcode 26 SDK 上编译通过 Liquid Glass（`glassEffect` / `glassProminent`）代码。

## 2. 运行环境

| 项 | 值 |
|---|---|
| Runner | `macos-15`（GitHub-hosted，macOS arm64） |
| Xcode 选择 | 动态选择最新：`Xcode 26.3`（Build 17C529） |
| SDK | iOS 26.2（iphoneos26.2 / iphonesimulator26.2） |
| 工作流超时 | 30 分钟 |
| 工程生成 | `brew install xcodegen` + `xcodegen generate` |
| 签名 | 全程 `CODE_SIGNING_ALLOWED=NO`，不接触证书与描述文件 |

## 3. 运行历史

| Run ID | 提交 | 结论 | 说明 |
|---|---|---|---|
| 38204388224 | `e81449c` | 成功 | 文档提交连带验证（不改源码）；作业 04:35:20 → 04:44:51 UTC（9m31s）；内层 .ipa 2276667 字节、13 条目与 `60101a4` 完全一致 |
| 38202579046 | `60101a4` | 成功 | 续航驾驶窗口对齐全量验证；SwiftPM 161、iOS XCTest 364、XCUITest 12 零失败；产物 2276667 字节，归档 `build/ci/60101a4/` |
| 38201483521 | `c7004b1` | 失败 | 单元测试全过；UI 用例 `bluetooth.battery.filter` 偶发丢 tap（同二进制对照证实时序不稳） |
| 38200692584 | `5bc519e` | 失败 | 新增回归测试首次真实执行：`testNetAh` 步长笔误、`testColdRestoration` 缺断连前置 |
| 38200256694 | `b617a78` | 失败 | `RangeServiceTests:913` 漏传 `longitude`（编译错误；`Tests/AppTests` 首次由 xcodebuild 编译暴露） |
| 38034738345 | `26e86f8` | 成功 | 阶段 2 G2 全量验证（定位/会话/持久化/仪表盘行程控制）；模拟器 39 例 0 失败；产物 1371090 字节，归档 `build/ci/26e86f8/` |
| 38034546734 | `cd9d89b` | 失败 | `UIApplication.protectedData*Notification` 无 Swift 成员（改自建 NSNotification.Name）；`skidHiddenFiles` 误拼 |
| 38034293526 | `953c52b` | 失败 | `TripStore` internal 被 public init 默认参数引用（可见性冲突，错误台账第 2 类坑复发） |
| 38033655465 | `4092171` | 失败 | 同上可见性冲突首次暴露 |
| 38032277501 | `762368b` | 成功 | 阶段 2 G1 里程语义修正后全绿；IPA 归档 `build/ci/762368b/`（1310748 字节） |
| 38031999208 | `2388029` | 失败 | TripRecorderTests 3 例失败：测试误按纯 haversine 断言（实现为速度积分优先） |
| 38029185052 | `bd63793` | 成功 | 合包器头尾界定修复（fix/test/docs 三提交）；产物 1290506 字节，归档 `build/ci/bd63793/`；真机验收通过：数据正常显示 |
| 38026505099 | `ae7d0b7` | 成功 | 合包器重写（防 iOS 27.2 Beta trap）+ fuzz 测试；产物 1290454 字节，归档 `build/ci/ae7d0b7/`；真机验证不再闪退 |
| 38022973698 | `b32508a` | 成功 | 文档提交连带验证；产物 1292490 字节（与 `4ab1c9b` 同尺寸） |
| 38022252771 | `4ab1c9b` | 成功 | 日志系统 + 设置页日志 UI 全量验证；22+1 例模拟器测试、12 例 SwiftPM 测试全通过；产物 1292490 字节 |
| 38022065769 | `1ad726e` | 失败 | 通知常量旧式命名（`UIApplicationDidEnterBackgroundNotification`）编译失败 |
| 38021922182 | `7fcf343` | 失败 | `LogStore` public init 引用 internal `LogFileWriter`，可见性冲突 |
| 38021758433 | `fd39983` | 失败 | `Tests/UnitTests` 同时被 SwiftPM 与 Xcode 测试目标编译，`import ANTuRide` 在 `swift test` 下报 no such module |
| 38021637086 | `cbd9430` | 失败 | 日志系统首次提交，暴露上述测试目录共享问题 |
| 37961690423 | `2e77a27` | 成功 | 资源打包修复（`sources` + `buildPhase: resources`）；新增资源断言通过；产物 1174236 字节 |
| 37960334513 | `a5ca7f8` | 成功 | 更名 `ANTuRide` 与新增 App 图标后首次构建；核验发现 `Assets.car` / `PrivacyInfo.xcprivacy` 缺失 |
| 37955477377 | `f1d125e` | 成功 | 阶段 1 + Liquid Glass 全量验证，Xcode 26.3 / iOS 26.2 SDK |
| 37955009497 | `a727064` | 失败 | 视图引用领域类型缺少 `import ANTuRideDomain` |
| 37954671402 | `697d003` | 失败 | `0x11` 功率偏移测试修正前（功率实际在 @106） |
| 37954407098 | `e4be94d` | 失败 | 阶段 1 首轮（功率偏移与 domain 导入问题暴露） |
| 37949795350 | `15f4a79` | 成功 | 收尾提交，隐私审计与构建结果文档 |
| 37946393492 | `1899dcc` | 成功 | 加入隐私清单 |
| 37944659806 | `7741bcd` | 成功 | 记录隐私审计与构建服务文档 |
| 37941766064 | `e593258` | 成功 | 首次产出无签名 IPA 产物 |
| 37940171462 | `5e4d4fa` | 成功 | 修复领域 framework plist 生成 |
| 37937641485 | `a7dd985` | 失败 | 修复 App plist 生成（修复前） |
| 37936848106 | `b200880` | 失败 | 加固 BMS 合包（修复前） |
| 37936425378 | `cddf2b4` | 失败 | 初始骨架（CI 首跑，修复前） |

## 4. 日志系统迭代记录（2026-10-10）

本轮 4 次失败均为**首次触发的构建约束**，非逻辑缺陷，逐条记录以备后续复用：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `no such module 'ANTuRide'` | `Package.swift` 将 `Tests/UnitTests` 声明为 SwiftPM 的 `ANTuRideDomainTests` 路径，该目录所有文件被 `swift test` 编译，而 SwiftPM 看不到 app target | 新增 `Tests/AppTests` 承载依赖 app 模块的测试；`project.yml` 的 `ANTuRideTests` 声明两个 source |
| 2 | `initializer cannot be declared public because its parameter uses an internal type` | `LogStore` 为 public，其 init 参数 `LogFileWriter` 为 internal | `LogStore` 降为 internal（仅模块内使用） |
| 3 | `'UIApplicationDidEnterBackgroundNotification' has been renamed to ...` | 旧式全局通知常量在新 SDK 中已重命名，属硬错误 | 改用 `UIApplication.didEnterBackgroundNotification` / `.willTerminateNotification` |
| 4 | `method 'testCaseCount()' conflicts with getter for 'testCaseCount' from superclass 'XCTest'` | 测试方法名与 `XCTestCase` 既有属性同名 | 重命名为 `testAllCasesCount` |

**关键教训**：`Tests/UnitTests` 目录是 SwiftPM 与 Xcode 测试目标的共享区，只能放仅依赖 `ANTuRideDomain` 的测试；任何 `import ANTuRide` 的测试必须放在 `Tests/AppTests`。

## 4.1 阶段 2 迭代记录（2026-10-10 下午）

本轮 G1+G2 共 6 次运行（2 次因测试预期错误、3 次因编译约束，最后全绿），新增教训：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | TripRecorderTests 3 例失败 | 测试误按纯 haversine 断言里程；实现语义为「速度可信时平均速度×Δt 优先」（正确） | 测试改用 `speed: -1` 走 haversine 路径；补速度积分断言 |
| 2 | `initializer cannot be declared public...` | `TripSessionService.init` 默认参数引用 internal `TripStore`（与第 4 节 #2 同类坑复发） | `TripStore` 类型与 init 提升为 public |
| 3 | `Type 'UIApplication' has no member 'protectedDataDidBecomeUnavailableNotification'` | 锁屏通知在 iOS 26.2 SDK 无该 Swift 成员（通知常量坑变种） | 用文档化常量字符串自建 `NSNotification.Name` |
| 4 | `no member 'skidHiddenFiles'` | 拼写错误 | `.skipsHiddenFiles` |
| 5 | `extra argument 'format' in call` | FormatStyle 插值（`.number(precision:)`）在普通 String autoclosure 中不可用且 API 形态错误 | 改 `String(format:)` |

## 5. CI 产物

| 产物名 | 来源运行 | 大小 | 保留 | 状态 |
|---|---|---|---|---|
| `ANTuRide-unsigned-ipa` | `38204388224`（`e81449c`） | 2276667 字节 | 7 天 | 已归档 `build/ci/e81449c/`；纯文档提交，源码同 `60101a4`，未替换 `latest` |
| `ANTuRide-unsigned-ipa` | `38202579046`（`60101a4`） | 2276667 字节 | 7 天 | 已取回本地 `build/ci/60101a4/`（当前 latest） |
| `ANTuRide-unsigned-ipa` | `38022973698`（`b32508a`） | 1292490 字节 | 7 天 | 已取回本地 `build/ci/b32508a/` |
| `ANTuRide-unsigned-ipa` | `38022252771`（`4ab1c9b`） | 1292490 字节 | 7 天 | 未过期 |
| `ANTuRide-unsigned-ipa` | `37961690423`（`2e77a27`） | 1174236 字节 | 7 天 | 已过期 |
| `ANTuRide-unsigned-ipa` | `37955477377`（`f1d125e`） | 196412 字节 | 7 天 | 已过期 |

产物为 `ANTuRide.ipa`（内部 `Payload/ANTuRide.app`），已包含阶段 1 界面、液态玻璃样式、App 图标与隐私清单；工作流断言不含 `embedded.mobileprovision`。体积变化：阶段 0 为 75224 字节，阶段 1 为 196412 字节（+UI 与样式），资源修复后为 1174236 字节（+`Assets.car` 946264 字节、图标 PNG 与 `PrivacyInfo.xcprivacy`）。

最新产物内容（运行 `38202579046` / `60101a4`，本机下载后核验）：

| 条目 | 大小 |
|---|---|
| `ANTuRide.app/ANTuRide` | 4531352 字节 |
| `ANTuRide.app/Assets.car` | 946264 字节 |
| `ANTuRide.app/AppIcon60x60@2x.png` | 19248 字节 |
| `ANTuRide.app/PrivacyInfo.xcprivacy` | 397 字节 |
| `ANTuRide.app/Info.plist` | 1398 字节 |
| `ANTuRide.app/Frameworks/ANTuRideDomain.framework/ANTuRideDomain` | 927568 字节 |

标识 `com.zjsf.anturide`、显示名「安途」、`CFBundleIconName = AppIcon`、`MinimumOSVersion = 16.0`；主二进制含 `RangeDrivingWindow` / `RangeElectricalSpan` / `RangeDrivingInterval` / `RangeService` 符号（本轮驾驶窗口改动已入包）；无 `embedded.mobileprovision`。SHA-256 `f2ee0df32452450e6158d5abcba8b78043c4095ed6545cdb4f75dc6ca256e797`（仅核对本次下载完整性）。

上一批产物内容（运行 `37961690423`，本机下载后核验）：

| 条目 | 大小 |
|---|---|
| `ANTuRide.app/ANTuRide` | 768408 字节 |
| `ANTuRide.app/Assets.car` | 946264 字节 |
| `ANTuRide.app/AppIcon60x60@2x.png` | 19248 字节（120×120，Apple CgBI 优化 PNG） |
| `ANTuRide.app/AppIcon76x76@2x~ipad.png` | 29028 字节 |
| `ANTuRide.app/PrivacyInfo.xcprivacy` | 397 字节 |
| `ANTuRide.app/Frameworks/ANTuRideDomain.framework/ANTuRideDomain` | 121672 字节 |

核验命令（推荐用脚本，见第 7.1 节）：

```bash
scripts/fetch-ipa.sh -r 37961690423
```

等价的原始命令：

```bash
gh run download 37961690423 -R River-1024/GlacierBMS-iOS -n ANTuRide-unsigned-ipa -D build/ci
```

SHA-256：`197584f9dbe3a4481bd518c2eaeb094e0d99cb1ae4320e053c86b8c055312d9c`

## 6. 产物可用性边界

- 无签名 IPA 不能直接安装到 iPhone。
- 若要安装，需用个人 Apple 开发者 Team 重新签名，或在本机 Xcode 中选择个人 Team 后直接构建安装。
- 若希望 GitHub 自动产出可安装包，需要用户自行配置 Apple 签名证书、Provisioning Profile 与 GitHub Secrets；在用户明确要求前，仓库不写入任何签名材料。

## 7. 复现方式

在 GitHub Actions 页面打开对应 Run，从其 Artifacts 区域下载 `ANTuRide-unsigned-ipa`；或使用命令行：

```bash
scripts/fetch-ipa.sh -r 37955477377
```

### 7.1 一键取回产物的本地约定（2026-10-10 起）

手工逐次敲 `gh run download` 既费事、也没有版本归档，改为脚本化：

```bash
scripts/fetch-ipa.sh                  # 自动选最近一次成功的运行
scripts/fetch-ipa.sh -r 38022973698   # 指定 Run ID
scripts/fetch-ipa.sh --all            # 取该次运行的全部 artifact
```

归档结构：

```
build/ci/<短提交号>/ANTuRide-unsigned.ipa
build/ci/latest/ANTuRide-unsigned.ipa    # 指向最近一次被采纳交付的成功构建（源码相同的纯文档提交连带构建另存按提交号目录，不替换它）
```

**脚本内建校验**（杜绝拿到半截包或拿错包）：

1. 先落到临时目录，校验通过才 `mv` 进归档目录 —— 失败不污染 `latest/`。
2. 断言 IPA 内存在 `Payload/ANTuRide.app/ANTuRide` 主二进制。
3. 断言不含 `embedded.mobileprovision`（本工作流只出无签名包）。
4. 落盘后打印路径、字节数与 SHA-256，用于核对**本次下载是否完整**。

**健壮性**：产物下载走 Azure Blob，偶发 502/503/504 与超时。脚本对这类临时错误自动重试 2 次（间隔 3 秒）；4xx、权限与参数错误不重试（重试无意义）。重试仍失败时打印三类常见原因（产物过期 / 网络抖动 / 该 Run 无此产物）而非甩原始报错。实测已遇到一次持续 502，重试机制按预期生效并在网络恢复后取包成功。

> **注意**：无签名 IPA 的 SHA-256 **跨 Run 不可比**——即使源码无变化，dSYM UUID 与打包时间戳也会让字节流不同。哈希只用于校验「下载完整性」（同一次 Run 重复下载应一致），不作为跨提交的等价判据。跨 Run 可比的是**解出的 `.ipa` 文件大小**与**包内条目清单（含各条目尺寸）**，**不是** artifact 容器大小。
>
> 2026-10-12 实测（`60101a4` 与纯文档提交 `e81449c`：源码仅差 README/docs 的两次构建）：内层 `.ipa` 均为 2276667 字节，13 条目与逐条目尺寸**完全一致**；但两次 SHA-256 不同（`f2ee0df3…` / `4b3aff93…`），artifact **容器**大小也不同（2267760 / 2267762 字节）。容器是外层压缩包，受打包时间戳与压缩差异影响，用它比对会得出「源码相同却体积不同」的假结论。

`build/` 已在仓库 `.gitignore` 内，本地产出目录不会被提交。脚本位置 `scripts/fetch-ipa.sh`，随仓库跟踪。

### 7.2 本地 macOS 复现构建

```bash
brew install xcodegen
xcodegen generate
swift test
xcodebuild test \
  -project ANTuRide.xcodeproj \
  -scheme ANTuRide \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
```

## 8. 与真机验收的边界

以下不属于本工作流的能力范围，必须在 macOS + Xcode + 真实 iPhone + 真实 ANT BMS 上完成：

- 个人签名安装在真实 iPhone。
- CoreBluetooth 真实扫描、连接、Notify 与分片合包。
- GPS 实采与后台未锁屏记录。
- 真实车辆仪表盘数据核验。

GitHub 构建通过仅代表工程可编译、可测试，不构成设备已验证。


## 9. 设置与 Dashboard UI 批次（北京时间 2026-10-11 15:06:00 +08:00）

- 构建源码：`414d8b0a188767796dc58901ab7bfe583ffdafba`（`414d8b0`）；分支 `codex/ios-parity-20261010`。后续文档提交不改变源码，本 IPA 不宣称基于文档提交重新构建。
- GitHub Actions：Run `38119495743`，结论 `success`；2026-10-11 14:52:52 +08:00 启动，14:59:25 +08:00 完成。准确 headSha 已核对；Xcode 26.3 / Swift 6.2.4。
- 测试：SwiftPM 130 项、iOS XCTest 280 项、XCUITest 9 项，全部零失败；Release 设备构建、资源校验、产物上传全部成功。
- CI 源码契约：Dashboard 6/6；设置 4 项通过、2 项 Android 对照因独立 checkout 无父仓库明确跳过。本机设置 6/6（含 Android 对照）和 Dashboard 6/6 已通过。
- IPA：`build/ci/414d8b0/ANTuRide-unsigned.ipa`；`build/ci/latest/ANTuRide-unsigned.ipa` 为字节一致副本。大小 `2210282` 字节，SHA-256 `1999c55ec46705c9b26d0b0b70668eba9a315445ac9254400520e5afc0b86ef3`。
- 校验：ZIP 全部条目 CRC 通过；主二进制、Assets.car、PrivacyInfo.xcprivacy、AppIcon 存在；标识 `com.zjsf.anturide`、显示名“安途”、版本 0.1.0 (1)；无 embedded.mobileprovision 和 _CodeSignature 目录，产物为 unsigned，需要另行签名后安装。
- 本地证据：版本目录和 latest 均保存 `run.json`、`ci.log`、`artifact-verification.json`，均在忽略的 build 目录，不提交二进制/日志。

首轮 `21b0127` / Run `38118261599`：App 编译与 280 单测通过，9 UI 测试发生 2 个断言失败（同一续航入口案例），因此不产包。修复父卡片无障碍容器后第二轮全部成功，并额外验证续航详情返回根页无导航栏；完整过程见施工步骤 037–039。

复现下载：`scripts/fetch-ipa.sh -r 38119495743`。当前原始产物无签名，需要用户个人签名，不新增或提交签名材料。

## 10. 电池/控制器分离批次（北京时间 2026-10-11 22:34:47 +08:00）

- 构建源码：`01aec26313dad2eece77f5db431c6e7c61986f8a`（`01aec26`），分支 `codex/ios-parity-20261010`；后续文档提交不改变此构建源码。
- GitHub Actions Run `38147063235`（workflow_dispatch）成功，Run head SHA 已与源码完全核对。macOS runner 使用 Xcode 26.3 / Swift 6.2.4。
- 验证：源码契约通过；SwiftPM 137 项、iOS XCTest 327 项、XCUITest 12 项均零失败；Release 设备构建、bundle 检查、IPA 上传均通过。
- 前序 Run `38145563196` 在 UI 测试阶段失败，没有产包；修正 UI 自动化对 Toggle 的点按/等待和记忆设备 `LabeledContent` 的稳定无障碍查询后，本 Run 全部通过。
- 产物：`build/ci/01aec26/ANTuRide-unsigned.ipa`，2,247,761 字节，SHA-256 `95476b8eb519d0984732383d2d70ed8d5836ada32eca6058a6a5169d24d5943c`；`build/ci/latest/ANTuRide-unsigned.ipa` 与其哈希一致。ZIP CRC、包标识/显示名/图标、Assets.car、PrivacyInfo.xcprivacy 均核验通过。无 provisioning profile、`_CodeSignature` 和 Mach-O 签名数据，属于 unsigned IPA，须自行签名安装。
- 本机静态检查：蓝牙契约 10/10、设置 6/6、Dashboard 6/6、`git diff --check` 通过。
- Run 元数据、CI 完整日志、产物校验报告和 IPA 保存在忽略目录 `build/ci/01aec26/` 及 `build/ci/latest/`；不提交生成物或签名材料。
- 尚未完成真实 iPhone 安装、双 BLE 并发与独立断开/重连、VoiceOver 和车辆验收；不能用模拟器结果替代硬件结论。

## 11. 实时活动 / 锁屏续记批次（北京时间 2026-10-23 14:50:00 +08:00）

- 构建源码：`980afed`（仅 CI 超时调整），功能代码等价于 `c54c8c4`；分支 `codex/ios-parity-20261010`。
- 产物：`build/ci/980afed/ANTuRide-unsigned.ipa`，`2,424,254` 字节，SHA-256 `6b1c37265d5ed2807e949bccb4fc0d3e232c0868b1bed8661d38026f6d224455`；`build/ci/latest/` 为同源副本。
- 包内校验（逐项解包确认，非仅看 CI 绿灯）：App `0.1.0 (1)`、`MinimumOSVersion 16.1`、`NSSupportsLiveActivities = true`、`UIBackgroundModes = [location, bluetooth-central]`；`PlugIns/ANTuRideLiveActivity.appex` 内 `CFBundleVersion` 与短版本号与宿主一致、`NSExtensionPointIdentifier = com.apple.widgetkit-extension`；`Assets.car` 与两份 `PrivacyInfo.xcprivacy` 均在包内；无 `_CodeSignature`、无 `embedded.mobileprovision`，属 unsigned，需自行签名。

### 11.1 本轮 CI 收敛过程（六轮，逐轮根因）

| Run | 结论 | 根因与处置 |
| --- | --- | --- |
| `39809236764` | 失败 | 8 处 `main actor-isolated property can not be referenced from a nonisolated context`。协调器缺 `@MainActor`；整类标注后修复，三处 `Task { }` 补显式 `self` |
| `39809758307` | 失败 | 设备构建与包校验通过，模拟器**安装**失败：`bundleVersion must be set in placeholder attributes`。appex 缺 `CFBundleVersion`/短版本号——`GENERATE_INFOPLIST_FILE` 只在目标自身定义 `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` 时才写入 |
| `39814788383` | 失败 | 单元测试全绿；4 个 XCUITest 失败，整轮耗时 48 分钟。根因：`FusedTelemetrySource` 每 2 秒无条件给 `@Published` 赋值，整棵视图树反复失效，长按菜单与拖拽被打断 |
| `39823774218` | 失败 | 失败数 4 → 2，「菜单动作不可点击」3 例全部消失，验证上一条判断成立；剩余 2 例是断言写法问题 |
| `39902076071` / `39903152399` | 定向失败 | `range.save.settings` 早在 `533b33f` 就被移除，测试未同步；另一例是大字号横屏下「先滚到顶」方向反了 |
| `39904602825` | 定向成功 | 只跑大字号横屏用例，`231s` → 通过 |

### 11.2 两个必须记住的教训

1. **能编译、能打包 ≠ 能安装**。appex 缺版本号只在安装阶段暴露，模拟器直接拒绝；这类缺陷必须在包校验步骤断言，本轮已把「appex 版本必须等于宿主」加入 CI。
2. **IPA-only 运行会让 UI 测试长期失修**。`533b33f` 改了设置页语义、`d149742` 加入参数编辑测试，之后两次 CI 都是 `build_only`（跳过测试），于是 12 天没人发现断言引用了已删除的标识符。UI 测试要么进默认流水线，要么在改动契约时同步更新断言。

### 11.3 未完成项（本轮明确移交）

- 全量 UI 用例在最后一次断言修正后**未再跑通**（`39906108735` 被 60 分钟 job 上限取消，`39912155852` 按用户要求取消）。已通过的部分：13 个 `ANTuRideUITests` 中 12 个、`HomeParameterEditingUITests` 中 13 个；剩余 1 例经定向运行单独通过。合并前需要一次完整回归。
- 真机验收全部未做：实时活动创建/结束、锁屏 30 分钟续记、灵动岛展开态、非挖孔机型锁屏卡片、系统关闭实时活动后的降级、行程结束后卡片消失。模拟器与 CI 结果不能替代这些结论。

## 12. 加速测试升级批次（北京时间 2026-10-25）

- 提交：`495b5fb`（feat 批次）→ `9597ab1`（修 CI 编译错）→ `f6613bf`（修测试拼写），分支 `codex/ios-parity-20261010`。
- 三次 workflow_dispatch：`40122599455`（4 分钟失败：`downsample` 参数重声明、`Chart(_:content:background:)` 形态不可用、`peakPhaseCurrentA` 拼写，共 4 处编译错）；`40123074356`（App 编译通过，测试 target 编译因同一拼写失败）；`40123559965`（编译与包校验通过，IPA 已上传后按所有者要求取消模拟器测试阶段）。
- 本轮教训再次验证：Windows 本机无法替代 CI 编译——静态审查漏掉的参数名冲突、Charts API 形态与跨文件拼写只能靠真实编译暴露。
- 交付 IPA：`build/ci/f6613bf/ANTuRide-unsigned.ipa`，2,521,105 字节，SHA-256 `8eba272520cd542e74f12467b7318078986165c27a3187760157a6565580160c`；`artifact-verification.json` 同目录。包校验通过：`com.zjsf.anturide` / 安途 / 0.1.0 (1) / MinimumOSVersion 16.1（project.yml 全 target 16.1，`verify_ipa.py` 的 16.0 断言已同步修正为 16.1）/ arm64 / 无签名与描述文件 / 含 ANTuRideDomain 框架 / 后台模式 location + bluetooth-central。
- 边界：模拟器测试未完成（所有者取消），280 项 App 测试、3 项图表新测试、6 项服务新测试与 2 项 UI 新测试在本次运行中未得出结论；真机/车辆验收项见 `docs/ACCELERATION_PARITY_UPGRADE_PLAN.md` 第 6 节。不能以编译与包校验替代测试与实机结论。
