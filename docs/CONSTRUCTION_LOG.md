# iOS 逐步施工记录

> 创建时间：2026-10-10 19:46:19 +08:00
> 用途：记录每个施工步骤的目标、实际改动、验证证据、未完成项及下一步。
> 当前基线：iOS HEAD `11f091f`；Android HEAD `e1dd220`；包含尚未提交的工作树改动。

## 记录规则

1. 每个施工步骤开始时记录目标和文件范围；结束时补充实际结果和验证。
2. 时间使用北京时间，格式为 `YYYY-MM-DD HH:mm:ss +08:00`。
3. 代码已落地、测试已编写、测试执行通过、CI/模拟器通过、真机通过分别标记，不能互相替代。
4. 保存命令及结果摘要；失败、修复、恢复路径和剩余风险也必须记录。
5. 子任务返回后，主线程完成集成检查才更新状态；子任务报告不能直接当作整工程验证结果。
6. 文档随每个步骤更新，不等到阶段结束才补记。不自动提交、推送、部署或修改长期记忆。
7. 本文记录施工过程；总体进度见 `MIGRATION_PLAN.md`，安卓版差异见 `IOS_ANDROID_PARITY_AUDIT.md`，CI 证据见 `CI_BUILD_RESULTS.md`。

## 步骤 001：G2/G3 行程代码补强（历史补记）

- 记录时间：2026-10-10 19:46:19 +08:00。
- 说明：补记本任务先前步骤，不将此时间伪装为原始施工时间。
- 目标：列表/详情、区间展示、JSON 导出、确认删除及保存/读取失败处理。
- 范围：`Sources/Features/Trips/TripHistoryView.swift`、`Sources/Services/TripSessionService.swift`、`TripStore.swift`、`Sources/Domain/Trip/TripRecorder.swift`、`Sources/DesignSystem/TripFormatters.swift`、相应测试与 App 接入。
- 实际改动：增加行程列表与详情、四类区间和采样计数；未采样值显示不可用；暂停检查点保留未结束语义；失败保存保留内存重试/导出路径；读取目录失败明确报错。
- 复核修复：相位切换重置配对基准，避免倒置区间；通知按行程 ID 隔离；删除不清除无关保存失败提示。
- 证据：已有定向 XCTest/UI 测试代码；此前 `git diff --check` 通过。尚无对应当前工作树的 Swift/Xcode 执行结果。
- 真机状态：用户确认 GPS 速度显示正常；未锁屏后台、锁屏暂停、解锁恢复、行程文件仍待真机验收。
- 状态：代码落地；集成编译/测试和真机未闭环。

## 步骤 002：安卓版功能与界面差异盘点（历史补记）

- 记录时间：2026-10-10 19:46:19 +08:00。
- 目标：核对当前 iOS 是否完整复刻 Android。
- 范围：Android `app/src/main`、iOS `Sources` 和 `docs/IOS_ANDROID_PARITY_AUDIT.md`。
- 结论：尚未完整复刻。缺口包括逐点行程与窗口曲线、完整续航学习/分析包、控制器 BLE/实时解析/记录、首页动态布局、加速三路算法、设置覆盖以及平台扩展。
- 复核注意：Android 控制器为 XLSX 导出，续航为 ZIP 分析包；Overlay 浮窗不等同画中画。iOS 界面存在也不能证明行为等价。
- 状态：首轮代码盘点已记录；细分矩阵和 UI 运行比较仍待继续。

## 步骤 003：续航领域、服务与页面接入（历史补记 / 待集成）

- 记录时间：2026-10-10 19:46:19 +08:00。
- 范围：`Sources/Domain/Range/RangeModels.swift`、`Sources/Services/RangeService.swift`、`Sources/Features/Range/RangeView.swift`、`Sources/Features/Settings/RangeSettingsView.swift`、`Tests/UnitTests/RangeModelsTests.swift`、`Tests/AppTests/RangeServiceTests.swift`。
- 领域结果：基础预测状态与 66–86 Wh/Ah 边界、不可用原因和测试已写入。不是 Android 完整学习校准算法。
- 服务结果：子任务返回了基于稳定设备 UUID、共享 BMS/GPS、有效区间窗口、JSON/CSV 导出和容量设置的服务与页面；禁止用设备名称或行程总量冒充有效窗口。
- 当前核对：`RangeService` 已采用 `init(bms:location:)` 与 `setDeviceID(_:)`；旧 `init(bms:trips:)` 兼容入口仅保持空态。App 仍需改用共享定位入口，BLE 服务仍需暴露稳定 UUID。
- 风险：子任务与早期主线程接口发生过变化，必须重新核对 Dashboard、App、页面与领域类型，不能宣称接入已完成。
- 验证：子任务报告静态检查/语法解析通过；当前整工程无原生 Swift/Xcode 编译或 XCTest 执行证据。
- 下一步：完成 UUID/定位接线、过期刷新、导出与设置集成，再运行可用验证。
- 状态：文件已落地，集成待完成。

## 步骤 004：首页参数模型与编辑器（历史补记 / 待集成）

- 记录时间：2026-10-10 19:46:19 +08:00。
- 范围：`Sources/Features/Home/HomeParameterModels.swift`、`HomeParameterEditorView.swift`、`Tests/AppTests/HomeParameterTests.swift`。
- 实际改动：10 类卡片稳定 ID、排序/显隐、版本化偏好、草稿保存/取消和默认恢复；设置页已有编辑入口。
- 待复核：枚举集合接口、排序 API 的框架依赖、默认恢复用例与真实草稿语义；Dashboard 动态卡片渲染尚未接入。
- Android 等价边界：尚未移植 27 槽位及控制器动态归还规则。
- 状态：模型/编辑器落地；编译、实际显示和安卓版布局等价未闭环。

## 步骤 005：控制器协议纠错（进行中）

- 开始记录时间：2026-10-10 19:46:19 +08:00。
- 原问题：早期组包模型错误采用 `0x0D` 作为帧尾，未依据 Android 的 LEN 响应语义；不得用于真机链路。
- 目标：按 Android `MotorControllerProtocol.kt` / `MotorControllerFrameAssembler.kt` 核对并移植 `6 + LEN + 2`、LEN=0x1D/0x1F、37/39 字节响应、查询命令与校验表。
- 写入范围：`Sources/Domain/Controller/`、`Tests/UnitTests/ControllerModelsTests.swift`。
- 预期验证：分片/噪声、载荷含 0x0D、37/39 字节、短帧/坏长度/边界和记录 CSV。
- 当前状态：纠错子任务执行中；结果待集成，不标为协议实现完成。

## 步骤 006：建立每步文档输出约定

- 时间：2026-10-10 19:46:19 +08:00。
- 用户要求：每步施工记录都要输出到文档。
- 改动：创建本文，并在总体计划和 README 添加入口与施工记录要求。
- 验证：检查文件存在、UTF-8 内容及差异空白。
- 状态：文档约定落地；下一步继续步骤 003–005 的集成纠错并逐项追加实际结果。

## 步骤 007：区分代码完成度与真机验收状态

- 时间：2026-10-10 19:52:27 +08:00。
- 用户问题：除实际验收外，复刻功能和界面代码是否全部完成。
- 核查：当前 App 仍用 `RangeService(bms:trips:)` 兼容空态入口；Dashboard 尚无首页配置动态渲染；根导航暂无控制器和加速页面。控制器协议文件已产生，尚需主线程集成审查。
- 结论：没有全部完成，且不只是缺少实际验收。续航共享定位/稳定 UUID 接线、完整校准/分析包、首页布局、逐点行程曲线、控制器服务/UI、加速算法/页面和设置覆盖仍有代码缺口。
- 证据：本步只读检查 App/RootView/Dashboard/RangeService 与当前施工记录；没有运行编译、测试或真机。
- 状态：完成现状核查；不得将模型/编辑器存在等同功能已接通，也不得把静态括号检查当作编译通过。

## 步骤 008：范围调整与本轮接线施工

- 时间：2026-10-10 20:40:49 +0800。
- 用户决定：iOS 不需要电池学习、历史校准修订与学习恢复；复用当前安卓内置能量数据，不代表已读取安卓手机私有学习数据库。
- 数据基线：BatteryEnergySeedCurve.kt 的 d1-ah-seed-20260909-v1 与 BatteryEnergyCalibration.seedEnergy 的后备公式；134 Ah 数据不任意缩放到其他电池。
- 编译路径：现有 GitHub macOS CI；只验证包含本轮修改的提交，不拿旧主干 Run 作为工作树证据。
- 当前施工：共享 GPS/BMS UUID 接线、固定曲线预测、首页配置实际渲染、行程曲线及控制器只读服务并行补齐。所有结果分别标明源码/测试/CI/真机证据。
- 状态：进行中；原步骤 007 的完整校准缺口按本次用户决定从目标移除，其他代码缺口仍须补齐。

## 步骤 009：首页真实渲染与控制器协议复核

- 时间：2026-10-10 20:43:02 +0800。
- 首页：10 类卡片按已保存显隐/顺序渲染；AppStorage 接收编辑保存，固定保留连接与行程控制，窄屏单列/宽屏双列。排序不再依赖 SwiftUI Array.move，14 项 XCTest 已写入。
- 主线程复核：删除首页重复触发续航 refresh 的回调，续航服务已有内部 1 秒刷新；Timeline 仅负责显示数据新鲜度。
- 控制器：只读查询 A8 02 01 24 01 1F 3E 4F；LEN=0x1D/0x1F 对应 37/39 字节，小端/符号/倍率对照安卓；37 字节不存在的刹车电压保留 nil。
- 子任务证据：Python 对照 512 校验表项、74 分片位置及 1000 组混合流；首页排序独立模拟 11264 组合。上述不是 Swift XCTest 执行。
- 验证：本轮 git diff --check 无空白错误；尚未提交本轮 CI。
- 边界：首页尚非安卓 27 槽位完整等价；控制器响应头/响应校验验证与安卓一致未新增，BLE/UI/历史另步施工。

## 步骤 010：固定安卓能量曲线集成及首批 CI 提交

- 时间：2026-10-10 20:46:56 +0800。
- 改动：110 个原始 Wh/Ah 系数与安卓 seedEnergy 后备公式原样移植；RangeService 将曲线剩余 Wh 注入预测，不再固定乘 66；导出标明数据版本。
- 接线：App 共用定位服务；BLE 提供 UUID，断连/换设备清除旧样本，续航容量按 UUID 读取；Published 用事件值和 combineLatest，避免读到旧状态。
- 测试：新增曲线 11 个 XCTest、预测能量注入/非法输入和窗口服务用例；子任务 Python 对照 20000 随机输入最大误差 3.64e-12 Wh。不是 Swift 测试执行。
- 静态检查纠正：git diff --check 不包含未跟踪文件；本次暂存检查发现两个新文件空白问题并修正后重检。
- 提交策略：独立 codex/ios-parity-20261010 分支先提交完成的续航批次，其他并行施工文件不纳入该提交。GitHub workflow_dispatch 验证此分支；不合并主干、不签名、不发布商店。
- 状态：源码/测试已落地；本步骤 CI 结果待后续记录。

## 步骤 011：GitHub 首轮编译失败与修复

- 时间：2026-10-10 20:49:53 +0800。
- 提交 c521b2e，CI Run 38053238996：SwiftPM 编译失败，未执行模拟器/设备构建，无新 IPA。
- 真实错误：测试中的 24.0.nextDown、66.0.nextDown 等数字字面量成员访问触发 expected named member of numeric literal。
- 修复：两处测试文件统一为 Double(...).nextDown/nextUp；保留原浮点边界测试含义。
- 验证：暂存差异空白检查后提交并再次触发同分支 CI；结果另步记录。

## 步骤 012：续航批次 GitHub CI 闭环与控制器导航接线

- 时间：2026-10-10 20:58:05 +0800。
- CI：8315235 / Run 38053408454 全绿；SwiftPM 测试、iOS 模拟器测试、Release 未签名设备构建、资源/隐私包核验和 IPA 上传成功。仅证明该提交，不涵盖后续未提交施工。
- 产物：ANTuRide-unsigned-ipa，GitHub artifact ID 11670023061；本地归档 build/ci/8315235，未签名不能直接作为正常签名安装包。
- 后续接线：App 注入独立 ControllerBluetoothService；Root 按 scenePhase 管理前台只读轮询，控制器页面不关闭首页/加速共享会话；设备/设置增加控制器导航入口。设备选择状态用 UUID 而非重名名称判断。
- 状态：续航提交编译通过；新控制器/首页/行程/加速批次待单独 CI，真机验收未做。

## 步骤 013：按用户要求进行仓库公开前审计

- 时间：2026-10-10 21:02:49 +0800。
- 结果：158 个历史 blob + 当前源码/测试/文档、41 个 Actions 日志未发现真实凭据；Git author 为 noreply；无 Issue/Release/Wiki/Pages。本轮未签名 IPA 解包无签名材料或现场数据。
- 修正：历史审计文档存在通用开发目录，当前去除；旧历史仍保留此目录（无个人用户名/凭据）。未擅自改写 Git 历史。App 分享数据可能含位置/UUID，PRIVACY.md 补充提醒。
- 限制：旧 23 个 unsigned artifact 未逐包扫描；模式扫描不构成零风险保证。详细证据与公开边界见 PUBLIC_RELEASE_PRIVACY_AUDIT.md。
- 下一步：仅将独立 iOS 仓库设为 PUBLIC，保留主干不合并，继续构建施工分支。

## 步骤 014：公开完成与行程/控制器批次编译

- 时间：2026-10-10 21:03:24 +0800。
- 可见性：GitHub API 实查 isPrivate=false、visibility=PUBLIC；仅 River-1024/GlacierBMS-iOS 已公开，未修改父安卓项目。
- 行程：逐点证据保存于 TripSegment.samples，旧 JSON optional兼容；四指标曲线、1/3/5/10分钟覆盖窗口、Services 重建保点，33项领域 XCTest待编译执行。净能耗明确沿用右端矩形积分，不将共同覆盖与总跨度混淆。
- 控制器：FFE0/FF00按安卓候选顺序、write+notify/indicate特征、单请求在途、超时清空、前台全局轮询；独立历史JSON/CSV及21项 AppTests；无控制参数写入、无后台承诺、XLSX/18列导出仍缺。
- 提交：只纳入已结束的行程/控制器与导航施工；首页完整槽位、驾驶设置、加速仍在并行修改，不能混入半成品提交。
- 状态：公开后继续 workflow_dispatch 编译；新 Run 结果将单独记录。

## 步骤 015：公开后 CI 的重复扩展编译纠错

- 时间：2026-10-10 21:06:31 +0800。
- cf2a5eb / Run 38054275235：SwiftPM通过，但 iOS模块编译报 RangePredictionStatus.localizedName 重复声明，模拟器测试取消，未生成本批 IPA。
- 根因：TripFormatters 与 RangeService 各声明同一扩展成员，属于跨批次集成问题，静态语法解析无法证明无重复定义。
- 修复：删除 TripFormatters 中无关的重复续航扩展，保留 RangeService 单一实现，行程格式接口不变；重新提交编译。

## 步骤 016：网络重试与准确提交编译

- 时间：2026-10-10 21:14:13 +0800。
- 故障：HTTPS Git push 多次 443/连接重置失败；首次失败后误触发远端旧 cf2a5eb 的 Run 38054483565，实查 headSha 后立即取消，不作为修复证据。
- 替代：通过 GitHub Git Database API 上传两个变更 blob、tree、commit；逐一验证与本地 Git 对象 SHA 完全一致，非 force 更新施工分支至 ced33b3。不改主干历史。
- 准确编译：确认远端 ced33b3683adb26156d13c1c42c174b072dff5f0 后触发 Run 38054889610。结果待实查；后续派发前必须验证 push 成功与 SHA。

## 步骤 017：公开仓库的行程/控制器批次编译通过

- 时间：2026-10-10 21:24:36 +0800。
- ced33b3 / Run 38054889610 全绿：SwiftPM、iOS模拟器测试、Release未签名设备构建、包资源核验与 IPA 上传均通过。
- 本地归档：build/ci/ced33b3，包含 CI 日志与 ANTuRide-unsigned.ipa。不把该产物说成已签名或真机验收通过。
- 结论：用户本次“审计后公开并继续编译”已执行成功；此前全量复刻要求仍在推进，首页全槽位/设置消费者/加速融合等未完成部分不套用本次绿色CI。

## 步骤 018：产物归档与剩余施工状态

- 时间：2026-10-10 21:59:23 +0800。
- 实际归档 ced33b3 的 IPA 1717550 字节；模拟器单元测试161项与UI测试3项均0失败，CI日志已保存 build/ci/ced33b3/ci.log。
- 当前公开仓库及新CI成功状态再次实查；不将账号额度故障的具体原因猜测为已诊断。
- 后续风险：首页/复核子任务收到模型不可用错误（gpt-6.1-sol not supported with ChatGPT account），待提交源码必须由主线程接续复核；不把部分写入当完成。驾驶设置接线与加速领域仍在施工，无本批CI证据。

## 步骤 019：继续接续后修复 Dashboard 未提交集成阻塞

- 时间：2026-10-11 09:05:54 +08:00。
- 触发：接续任务后复核当前未提交工作树；此前交接只记录了 G3 与阶段 3/4 的源码施工，未提供本批 macOS/Xcode 证据。
- 发现：`Sources/Features/Dashboard/DashboardView.swift` 的新首页重构在 `body` 中途截断，缺少 `ScrollView`/`TimelineView`/`NavigationStack` 闭合；同时旧版连接、速度、行程、指标、状态和曲线卡片定义被截断，旧版布局分支还引用了不存在的 `parameterCard`。这是明确的源码级编译阻塞。
- 修复：恢复 `body` 的完整闭合结构；从当前基线恢复未改变语义的卡片组件；补充兼容旧十卡片布局的 `parameterCard`，保留新版槽位布局、控制器占位和无数据显示为 `--` 的边界。
- 验证：`git diff --check` 通过；Sources 下粗略括号检查不再报告 `DashboardView.swift`；未发现本机 `swift`、`xcodebuild` 或 `xcodegen`，因此尚未执行 Swift 编译、XCTest、模拟器测试或 macOS CI。
- 状态：本地源码阻塞已修复；当前工作树仍有未提交改动，未提交、未推送；G3 真机和后台/锁屏验收仍未完成。下一步应在 macOS CI 对本批工作树对应提交执行编译/测试，再按 G3 顺序验收。

## 步骤 020：真实首页与驾驶设置消费接线

- 时间：2026-10-11 10:24:39 +08:00。
- 新决定：继续完成可操作功能后由用户做真机测试；加速仅 RPM 单渠道，系数默认 0.0782，公式 km/h = rawRPM × 系数 × forwardSign。1000 RPM、正向默认换算为 78.2 km/h；不代表已实车校准。
- 首页：27 槽位/39 指标模型接入运行页面，控制器 18 项不再无条件占位；读取独立控制器实时流，过期/暂停显示 --。RSSI 通过 BMS readRSSI 只读请求获取，10 秒过期撤下。底部故障框实际占两列。
- 设置消费：字号比例、文字描述、功率条/真实功率曲线、放/充电功率基数、SOC/压差/温度颜色阈值、探头来源、速度满格及阈值生效；App 注入共享服务，两个启动自动连接开关分别消费，独立 UUID 记忆，手动动作抑制自动连接。
- 集成修复：探头输入 Int.min 不再 index-1 溢出；曲线消费真实功率而非把电流冒充功率；控制器记录不再 nextUp 改接收时间，拒绝重复/倒退行并保存时序警告。
- 回归：新增首页槽位/39 指标、动态归还持久化、故障跨列、不可用控制器、温度选择/Int.min 与阈值测试；加速领域新增单渠道/默认系数换算断言。
- 证据：主线程 API/调用静态核对及 git diff --check；Tree-sitter 可做语法证明，但不是 Swift 类型检查、XCTest 或 iOS 运行证据。

## 步骤 021：续航完整窗口指标与可操作页面

- 时间：2026-10-11 10:24:39 +08:00。
- 范围：RangeService、RangeView、RangeSettingsView、RangeServiceTests。
- 实现：averageSpeedKmh 使用同一有效窗口距离/时长；referenceKmPerAh 使用同区间真实放电电流的梯形 Ah 积分并裁剪到 GPS 边界，不以 Wh/电压或总行程替代。安全状态即时撤下无效指标，节流仅用于预测。
- 页面：显示实际窗口/刷新配置、额定容量、有效距离/能耗/Ah、平均速度及 km/Ah，提供 JSON/CSV、分享、可见错误和设备 UUID 隔离的确认重置。
- 验证：子任务 4 文件语法检查、14 列 CSV 契约及积分数值复核通过；新增 8 项本轮回归用例。主线程已核对 Dashboard 接线。XCTest/原生编译尚未执行。

## 步骤 022：行程逐样本 CSV 与分页

- 时间：2026-10-11 10:24:39 +08:00。
- 范围：TripStore、TripHistoryView、TripStoreTests。
- 实现：逐样本 CSV 保留 TripSample 的真实字段/区间类别/有效性，缺失或非有限值留空，不造坐标；JSON/CSV 独立导出保存 Documents/Exports，关闭分享与删除源记录不删除副本。区间内每页 100 样本，曲线只绘当前页；窗口摘要每页 20 条。
- 保留：旧 JSON、待保存行程导出、删除确认和失败重试。地图回放未实现，当前无逐点坐标数据。
- 验证：新增 11 项回归测试；子任务语法/CSV 标准读写交叉核验、5000 组分页边界及10001样本无重复遗漏的模型复核通过。主线程已检查分享生命周期。XCTest/原生编译尚未执行。

## 步骤 023：控制器 18 列 CSV/XLSX 和历史操作

- 时间：2026-10-11 10:24:39 +08:00。
- 范围：ControllerModels/ControllerProtocol/ControllerWorkbook、ControllerHistoryStore、ControllerView、相应领域/App 测试；主线程 ControllerBluetoothService 采样接线。
- 实现：ControllerSample 可选完整 telemetry 兼容旧 JSON；18 列字段/顺序按 Android 导出核对，提供 CSV 和 OOXML XLSX；ZIP stored/CRC32，无 App 第三方依赖。JSON 保持原记录。所有 XLSX 单元格为文本，不执行公式。旧记录缺字段不补造，车速没有确认协议来源仍不可用。
- 页面：导出 JSON/CSV/XLSX、独立分享快照、未保存内存记录导出、确认删除、读取失败提示、时序警告。完整遥测由蓝牙采样入口传入。
- 证据：8 文件语法解析/静态契约通过；源码驱动 ZIP/CRC/XML/openpyxl 格式检查通过，但不是 Swift 二进制执行。主线程已核对 telemetry/timingWarning 接口。XCTest、Xcode 和真机分享未执行。

## 步骤 024：RPM-only 加速服务、页面与最终集成复核

- 时间：2026-10-11 10:27:32 +08:00。
- 文件：Domain/Acceleration 两个文件、Services/AccelerationService、Features/Acceleration 两个页面、AccelerationServiceTests/AccelerationTests、App/Root/Settings 接入口。
- 范围：仅控制器 RPM，默认系数 0.0782；可调整系数/目标/方向并保存本机偏好，会话开始后冻结配置。App 注入共享只读控制器服务，页面不建立另一条蓝牙链路，不生成模拟样本。
- 界面：等待连续静止 2 秒、起步/目标分段、实时 RPM/车速/母线/相峰值电流、已确认累计/分段计时与距离、样本频率/间隙质量、历史详情、JSON 分享、确认删除、保存失败内存保留及重试。
- 时序：计时使用手机收到完整快照事件时的单调时钟，不是硬件测量时刻；拒绝重复/倒退时钟、500ms 缺样、合批多帧时序歧义。控制器断连/暂停、App 离开前台中止并保存部分分段，不冒充已达标。
- 回归：新增22项服务/存储 XCTest，含事件参数willSet、默认/编辑系数、开始前缓存、静止/分段、断连/后台/缺样/合批、保存失败/重试、旧ISO8601、路径保护与导出失败等。测试代码已写入，未原生执行。
- 集成主线程核对：App 环境注入、Settings 导航、Root 生命周期与 stop(reason:) 参数一致；controller history telemetry/timingWarning 和首页窗口指标接口一致。只读审查发现的温度索引溢出、电流冒充功率、nextUp 人工时序已修复并二次复核。
- 全工作树证据：71 个 Swift 文件 Tree-sitter 解析0语法错误；7个关键源码契约通过。报告 build/verification/current-worktree-static.json 明确 executedSwiftCompiler=false、executedXCTest=false。本机无Swift/Xcode；本批未生成IPA、未提交/推送，不套用旧CI。

### 步骤025：提交并启动本批原生CI（北京时间 2026-10-11 10:31:14）
- 用户授权提交、推送施工分支并在GitHub编译测试直到产出IPA。
- 本批包含RPM单渠道（默认0.0782）、首页/驾驶设置、续航、行程和控制器导出及回归测试；静态检查通过，原生编译与XCTest等待本次CI。
- 不改Android父仓库、不合并main；产物为unsigned IPA，真机验收仍独立。

### 步骤026：功能批次已提交推送并派发CI（北京时间 2026-10-11 10:31:51）
- 提交 c584c42cce836c9269f851a4f2e047e766290464；远端分支SHA与本地一致。
- GitHub Actions Run 38105445575 已派发，等待原生测试/Release构建与IPA产物。

### 步骤027：首轮CI失败修复（北京时间 2026-10-11 10:33:34）
- Run 38105445575领域源码编译通过，AccelerationTests使用Optional/数组浮点accuracy断言导致测试编译失败。
- 修复为XCTUnwrap及逐项浮点容差断言，保留完整目标数组断言；重新提交并运行原生CI。
