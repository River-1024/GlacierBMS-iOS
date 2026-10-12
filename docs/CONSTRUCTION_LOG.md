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

### 步骤028：第二轮CI类型检查修复（北京时间 2026-10-11 10:37:11）
- Run 38105557309 Swift package tests通过；iOS编译在续航CSV字段组合表达式发生类型推断超时。
- 拆分可选指标字符串、显式[String]数组和转义阶段，不改变CSV列/数据/转义语义；继续原生CI。

### 步骤029：真实XCTest结果与修复（北京时间 2026-10-11 10:46:17）
- Run 38105742081 App及测试已编译；269项单测出现3处失败，3项UI测试通过，22项加速服务测试通过。
- 修复真实CSV缺陷：Swift将CRLF视作一个Character，改为Unicode scalar检查换行后正确加引号。保留原回归断言。
- JSON十进制浮点往返产生约1e-18差异，两处Ah精确相等断言改为1e-12绝对容差；不修改能耗算法。

### 步骤030：完整CI成功与产物核验（北京时间 2026-10-11 10:55:06）

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

### 步骤031：用户确认安装成功（北京时间 2026-10-11 11:00:21 +08:00）

## 本批安装进度更新（北京时间 2026-10-11 11:00:21 +08:00）

- 用户在当前对话明确反馈：**安装成功**。本批交付的安装环节标记为用户确认通过，接续源码5bd1493 / GitHub Actions Run 38106226167的IPA交付记录。
- 记录时间为本次反馈登记时间，不推断实际安装时间、签名方式、设备型号或系统版本；GitHub原始产物仍为unsigned，不因安装反馈改写产物属性。
- 已完成：功能批次提交与推送、GitHub原生编译测试、IPA产出与本地核验、用户确认安装成功。
- 待验收：本批首页/驾驶设置交互、续航与行程记录/导出、控制器真实链路与导出、后台/锁屏行为、RPM加速车辆测试。安装成功不等于上述功能全部通过。
- 加速范围保持RPM单渠道、默认系数0.0782；地图轨迹、Live Activity/CarPlay仍未实现。

### 步骤032：设置总入口与续航重复项整理（北京时间 2026-10-11 11:31:48 +08:00）

- 用户要求：最后 More 标签变成设置，设置集中，续航不重复编辑，并对照 Android 功能。
- 定位：RootView 原有六标签导致系统折叠；DrivingSettingsView 与 RangeSettingsView 编辑同一份窗口/刷新；设置页先进入续航结果页后再进入设置，且两页重复导出。
- 改动：固定五标签、设置直达分类配置；续航结果与导出转到仪表盘入口，续航设置只保留一处编辑。清除窗口/重置容量文案明确真实作用域，不冒充安卓版学习重置。
- 配置安全：持久化 key 与模型不变；驾驶页范围限定保存/重置保留最新续航字段及独立数据；续航独立恢复默认带确认。日志默认等级按钮改为与构建默认比较，不再始终禁用。
- 文件：Sources/App/{RootView,ANTuRideApp}.swift、Features/Dashboard/DashboardView.swift、Features/Settings/{SettingsView,DrivingSettingsView,RangeSettingsView}.swift、Features/Range/RangeView.swift、Tests/AppTests/DrivingSettingsStoreTests.swift、Tests/UITests/ANTuRideUITests.swift、scripts/check_settings_contract.py、.github/workflows/build.yml。
- Android 对照：父工程只读，23 个共用配置默认值一致；窗口 3–60 分钟、刷新 10–60 秒、BMS 查询 100–60000 ms 一致。保留 iOS 严格拒绝非法输入。屏幕方向锁和 Android 专用入口未移植；不扩展既定不学习/不做完整分析包的范围。
- 验证：源码契约检查 6/6 通过（先复现 4 个导航/重复项失败，再整改通过）；git diff --check 通过。新增 App 测试 4 项、UI 测试 4 项尚未运行；Windows 无 Swift/Xcode，不等同编译、模拟器或真机通过。
- 独立审查未发现确定业务回归；补充续航局部恢复的保存/服务应用与确认/取消回归，以及实际横竖屏尺寸等待。UI 种子仅在 DEBUG 隔离设置套件使用，双自动连接关闭，不修改真实配置。
- 本批为未提交源码；没有推送或新 IPA，前批安装成功仍仅指前批产物。保留本轮开始前四份文档的未提交安装记录，父工程 tools 下无关未跟踪文件未改动。
- 入口/完整对照及剩余差异见 docs/IOS_ANDROID_PARITY_AUDIT.md 的“设置入口整理与安卓版对照”节；下一验证是本批 macOS 编译、XCTest/UI 测试和 iPhone 横竖屏设置操作。

## 步骤 033：首页层级、行程入口与 Swift Charts 需求确认（北京时间 2026-10-11 13:11:19 +08:00）

- 记录性质：用户已确认目标方案；本步骤完成文档施工，不代表目标 UI 已实现或通过验收。
- 用户确认：移除首页“安途”标题及顶部空白、独立 BMS 状态卡和首页行程控制；参数尽量填满首页可用区域；行程控制与当前会话移入行程 Tab；Dashboard 图表改用 Swift Charts；滚动内容获得导航栏区域的全屏视觉。其余 UI 自适应、字号、原生组件与无障碍约束继续有效。

### 已施工与当前只读核对

- 本轮已施工：仅向 `docs/CONSTRUCTION_LOG.md`、`docs/MIGRATION_PLAN.md`、`design-system/anturide-ios/MASTER.md` 追加需求、进度与验证边界；保留已有历史和未提交改动。
- 已有代码基础（只读核对，不视为本轮实现）：五项顶层 Tab、首页可配置参数布局、行程列表/详情已存在；行程详情图表已使用 Swift Charts。
- 本轮目标仍待施工：当前 `DashboardView` 仍含“安途”导航标题、`ConnectionStatusCard`、`TripControlCard` 和 Canvas 电流/功率曲线；行程开始/结束控制仍在首页。行程详情使用 Charts 不等于 Dashboard 已迁移。此处仅是记录时的源码快照，不替其他施工线程作完成结论。

### 待施工与待验证

- 待施工：按用户确认重排 Dashboard，移除标题留白、BMS 状态卡和首页行程控制；行程 Tab 接入开始/结束、当前会话和错误反馈；Dashboard 业务曲线迁移至 Swift Charts；实现导航栏区域的全屏滚动视觉。
- 参数填满以合理利用空间为目标，不用缩小字号、固定尺寸或压缩触控区域换取密度；仍须支持小屏/横屏、Dynamic Type、VoiceOver、浅色/深色与减少动态效果。全屏视觉不允许内容或操作被系统安全区域/导航控件遮挡。
- Windows 静态检查：本轮只做文档内容、追加完整性和差异空白检查；源码仅只读查看，未运行 Swift 编译或测试。
- macOS CI/模拟器：待针对完成后的准确源码提交执行编译、XCTest/XCUITest、图表与布局回归；本轮未运行，不声称通过。
- 真机/BMS/车辆：待验收真实 iPhone 滚动与导航、行程开始/结束及数据新鲜度/断连行为；本轮未进行，不声称通过。旧 CI 和既往安装成功不能作为本轮方案的验收证据。

### 未修改范围

- 本轮未改 `Sources/`、`Tests/` 或其他文件，不改 BMS/BLE 协议、参数与行程存储格式，不回退其他人的改动；未提交、推送或生成新 IPA。
- 五项 Tab、系统返回手势、iOS 16 最低版本、语义主题、原生组件、44pt 触控、缺失/过期值不冒充零值及现有本机隐私边界继续有效；RPM 加速仍为 RPM-only。
- 完成标准：三份文档准确追加决策与状态，并验证写入范围和历史保留；UI 施工与 macOS/真机验收不属于本次文档交付。

## 步骤 034：Dashboard 根页导航栏与续航入口决定补充（北京时间 2026-10-11 13:16:49 +08:00）

- 用户明确决定：Dashboard 根页隐藏整条 `navigationBar`，仅隐藏导航栏背景不足以消除顶部空白；根页无标题、无固定 header，也不以空白占位保留导航栏高度。此决定补充步骤 033，并取代其中对根页工具栏保留的宽泛表述。
- 续航详情入口放入现有卡片或图表标题行的内容区，随内容滚动，不额外占据顶部一行；打开详情后恢复系统导航栏与原生返回按钮/手势，根页隐藏范围不得泄漏到详情。
- `ScrollView` 连续滚动到顶部安全区，不留导航栏占位；仍尊重状态栏/刘海和底部五项 Tab 的安全区域及交互，不用固定 header 或额外顶行替代导航栏。
- 旧 `dashboard-wireframe.svg` / `dashboard-wireframe.png` 已被本次决定替代，仅作为历史方案留存，不再作为当前施工或验收依据；该声明同步追加至 MASTER，未编辑或删除线框图文件。
- 已施工：仅追加三份指定文档，未修改源码或测试；本条记录产品决定，不宣称 UI 已实现。既有首页减项、行程移入行程 Tab、Swift Charts、自适应/字号/原生组件与无障碍约束继续有效。
- 待验证：Windows 仅执行文档追加完整性与差异检查；完成 UI 施工后，macOS CI/模拟器需验证根页整栏隐藏、内容区入口、详情恢复导航、返回根页与旋转布局；真实 iPhone/BMS 验收需确认安全区域、滚动、五 Tab 及续航真实数据状态。本次未运行编译、测试或真机/BMS 验收。
- 未修改范围：`Sources/`、`Tests/`、线框图和其余文件；不回退其他未提交改动，不提交/推送或生成新 IPA。

## 步骤 035：旧顶部续航 toolbar 方案替代与文档交付边界（北京时间 2026-10-11 13:21:11 +08:00）

本条承接步骤 034，明确第一版旧方案与最新决定的关系，不改写历史。

- 旧版“保留 Dashboard 顶部续航 toolbar”的方案已被替代，不再作为当前施工依据：Dashboard 根页隐藏整条 `navigationBar`，不是仅隐藏背景；无标题、无固定 header、无导航栏高度占位。
- 续航详情入口移到现有卡片/图表标题行的内容区，随内容滚动，不额外占顶端一行；详情页恢复系统导航栏、返回按钮及返回手势，隐藏范围只限 Dashboard 根页。
- `ScrollView` 连续滚动到顶部安全区，仍尊重状态栏/刘海与底部五 Tab；其余自适应、字号、原生组件、Swift Charts 和无障碍约束继续。
- 旧 `dashboard-wireframe.svg` / `dashboard-wireframe.png` 仅为被本次决定替代的历史示意，不作当前施工或验收依据，不据旧图恢复顶部 toolbar、标题或固定 header；图文件保持不变。
- 本次已完成需求文档补写，不等待源码实施。实施完成后的实际验证由用户后续追加；本轮仅验证文档，不推断实现状态，不声称 Windows 静态检查等于 macOS CI/模拟器或真机/BMS 通过。未修改源代码、测试或其他文件，保留其他未提交改动。


## 步骤 036：Dashboard 减项、行程归位与 Swift Charts 施工（北京时间 2026-10-11 14:05:05 +08:00）

本步骤按用户最新确认实施，源码和测试已修改；文档中的步骤 033–035 保留为需求决策历史，不再作为“尚未施工”的当前状态。

### 已施工

- `Sources/Features/Dashboard/DashboardView.swift`
  - 移除 Dashboard 根页“安途”标题、导航栏占位、独立 BMS 连接状态卡和首页行程控制卡。
  - 根页使用 `.toolbar(.hidden, for: .navigationBar)`；没有用 `.ignoresSafeArea()` 覆盖状态栏/刘海，内容仍使用单一 `ScrollView` 连续滚动。
  - 续航入口移入首个参数卡的内容区；进入 `RangeView` 时恢复系统导航栏，返回根页再次隐藏。
  - 保留首页槽位配置与 27 个默认槽位；横屏、Dynamic Type、用户字号比例较大时自动减少列数/改为单列，取消主要布局对固定宽高的依赖。
  - 电流/功率业务曲线从 `Canvas` 迁移到 iOS 16 Swift Charts `Chart`/`LineMark`/`PointMark`，保留真实电流与真实功率语义、单位、接收时间轴、样本摘要、断点和无效数据处理。
- `Sources/Features/Trips/TripHistoryView.swift`
  - 在“行程”Tab 顶部增加当前行程会话区，承载开始/结束、暂停状态、实时里程/净能耗、错误和待保存恢复入口。
  - 继续使用共享 `TripSessionService`，未复制或改变锁屏、分段、保存和导出语义；新增稳定标识 `trip-session.card/start/stop`。
- `Sources/App/RootView.swift`
  - 保持五项顶层 Tab，仅将 Dashboard 初始化改为无设备跳转参数，设备连接仍由“设备”Tab承载。
- 回归覆盖
  - `Tests/UITests/ANTuRideUITests.swift` 增加 Dashboard 无标题/无行程按钮、行程 Tab 有开始按钮、横屏最大字号可滚动到底部参数的 UI 契约。
  - `Tests/AppTests/BmsHistoryChartTests.swift` 增加曲线点生成测试：真实零值/负功率、缺失/非有限值、5 秒断点边界、乱序时间、单点/空数据及电流功率语义隔离。
  - `scripts/check_dashboard_contract.py` 增加源码级 Dashboard 约束检查，不替代 Xcode 编译或 UI 运行。
  - `design-system/anturide-ios/pages/dashboard.md` 写入页面级施工和验收约束。

### 当前验证证据

- Tree-sitter Swift 语法解析：`Sources/` 与 `Tests/` 全部通过，未发现语法错误。
- `python scripts/check_settings_contract.py`：6/6 通过。
- `python scripts/check_dashboard_contract.py`：6/6 通过。
- `git diff --check`：通过；未执行清理、回退或提交。

### 尚未验证 / 风险边界

- 当前 Windows 工作区没有 Swift/Xcode/XcodeGen，未运行 `swift test`、Xcode 类型检查、XCTest 或 XCUITest；新增 AppTests/UITests 仍需 macOS CI/模拟器执行。
- 需要在 macOS 模拟器验证 `.toolbar(.hidden)` 的真实导航栏占位是否消失、打开续航详情后的导航恢复、返回根页、375pt/横屏/最大 Dynamic Type 及图表渲染。
- 需要在真机验证状态栏/刘海、底部 Tab、VoiceOver、减少动态效果、真实 BMS 断连/过期数据和行程开始/结束；既往 CI/安装成功不覆盖本步骤。
- 未提交、未推送、未生成新 IPA；工作区其它未提交改动保持不变。


## 步骤 037：全部项目改动提交与 macOS IPA 构建启动（北京时间 2026-10-11 14:23:36 +08:00）

- 用户明确授权：提交本 iOS 项目全部改动、构建 IPA，并将进度写入文档；本步骤覆盖此前“未提交、未推送、未生成新 IPA”的交付边界。
- 范围：现有设置入口整理、五 Tab、Dashboard/行程 UI、Swift Charts、相关测试、项目设计约束及文档，保留所有前序改动；不修改 Android 父仓库。
- 构建补充：将 Dashboard 源码契约加入既有 macOS CI，与设置源码契约、SwiftPM、XCTest/XCUITest、Release 无签名设备构建及资源包校验顺序执行。
- 生成物边界：`.playwright-mcp/` 为本地浏览器 404 控制台日志，加入忽略并保留本地；`build/` 下 CI 日志、IPA 和校验结果不提交。未删除用户文件。
- 本地验证、准确源码 SHA、GitHub Run 和产物结果将在后续步骤追加；Windows 无 Xcode，不声称本机编译通过。
- 预定交付：当前分支提交推送后显式触发 workflow_dispatch，只有准确源码 SHA 的全部 CI 检查成功并下载校验 IPA 后才标记构建交付完成；真机/BMS/车辆验收仍单独待验证。

- 提交前本地证据：设置契约 6/6、Dashboard 契约 6/6、Tree-sitter Swift 72 文件零语法错误、`git diff --check` 通过；24 个项目改动文件的常见凭据模式扫描零发现。以上仅为静态检查，不替代 Xcode/模拟器。

- 提交/推送已完成（北京时间 2026-10-11 14:32:43 +08:00）：源码 `21b0127ee0c9ab7d04ca41f8e875062063238dd8`（短 SHA `21b0127`），24 个项目文件；分支 `codex/ios-parity-20261010` 已同步 origin。
- 已触发本次构建：GitHub Actions Run `38118261599`，workflow_dispatch；核对 headSha 与上述源码完全一致。项目生成、设置/Dashboard 契约和 SwiftPM 测试步骤已通过；Xcode 模拟器测试进行中，设备 IPA 尚未产出，不能提前称构建成功。


## 步骤 038：首轮 CI 失败定位与无障碍边界修复（北京时间 2026-10-11 14:42:14 +08:00）

- 首轮源码 `21b0127` / Run `38118261599`：SwiftPM 和两组源码契约通过；Xcode 模拟器 App 编译及 280 项 iOS 单测通过；9 项 UI 测试中续航入口测试发生 2 个断言失败（同一案例），其余案例通过。设备构建被测试失败阻止，未产出 IPA。
- 精确失败证据：UI 预期 `dashboard.range` 按钮，但无障碍树显示按钮标识为 `dashboard.slot.top_speed`、标签为“综合续航”；父 VStack 的标识覆盖了嵌套 NavigationLink。失败日志保留在 `build/ci/21b0127/failed.log`，不入 Git。
- 修复：为槽位和旧卡片容器使用 `.accessibilityElement(children: .contain)`，保留父卡片标识和内部按钮标识/语义，不削弱测试为按标签绕过。续航 UI 回归增加返回 Dashboard 后按钮仍在且导航栏全部隐藏的断言。
- 设计审计附带收敛：旧布局的状态内容卡使用 `AppTheme.card` 普通背景，移除不符合内容层约束的玻璃材质。未改 BLE/行程协议或隐私边界。
- 后续：本地契约/语法检查后提交推送修复，运行完整 CI，准确源码 SHA 和产物结果在下一步骤记录。后续进度文档将在最终文档提交中一并推送，不把它声称已包含在首轮源码提交中。

- 修复提交 `414d8b0a188767796dc58901ab7bfe583ffdafba` 已发布到同一远程分支（北京时间 2026-10-11 14:53:53 +08:00）。普通 HTTPS Git 推送连续遇连接重置/443 连接失败，改用已认证 GitHub Git database API 上传完全相同的 blob/tree/commit；逐个核对 SHA 与本地对象完全相同，只做非 force 快进，不重写历史。
- 第二轮 Run `38119495743` 已启动并核对 headSha 为 `414d8b0`；项目生成及两组源码契约通过，完整测试/设备构建继续中。


## 步骤 039：完整 CI 成功、IPA 交付与文档收尾（北京时间 2026-10-11 15:06:00 +08:00）

### 准确版本与验证证据

- 构建源码：`414d8b0a188767796dc58901ab7bfe583ffdafba`（`414d8b0`）；分支 `codex/ios-parity-20261010`。后续文档提交不改变源码，本 IPA 不宣称基于文档提交重新构建。
- GitHub Actions：Run `38119495743`，结论 `success`；2026-10-11 14:52:52 +08:00 启动，14:59:25 +08:00 完成。准确 headSha 已核对；Xcode 26.3 / Swift 6.2.4。
- 测试：SwiftPM 130 项、iOS XCTest 280 项、XCUITest 9 项，全部零失败；Release 设备构建、资源校验、产物上传全部成功。
- CI 源码契约：Dashboard 6/6；设置 4 项通过、2 项 Android 对照因独立 checkout 无父仓库明确跳过。本机设置 6/6（含 Android 对照）和 Dashboard 6/6 已通过。
- IPA：`build/ci/414d8b0/ANTuRide-unsigned.ipa`；`build/ci/latest/ANTuRide-unsigned.ipa` 为字节一致副本。大小 `2210282` 字节，SHA-256 `1999c55ec46705c9b26d0b0b70668eba9a315445ac9254400520e5afc0b86ef3`。
- 校验：ZIP 全部条目 CRC 通过；主二进制、Assets.car、PrivacyInfo.xcprivacy、AppIcon 存在；标识 `com.zjsf.anturide`、显示名“安途”、版本 0.1.0 (1)；无 embedded.mobileprovision 和 _CodeSignature 目录，产物为 unsigned，需要另行签名后安装。
- 本地证据：版本目录和 latest 均保存 `run.json`、`ci.log`、`artifact-verification.json`，均在忽略的 build 目录，不提交二进制/日志。

### UI 回归覆盖与验收边界

- 本次 UI 测试实际通过：Dashboard 无导航栏/无行程按钮、Trips 有开始入口、最大辅助字号横屏可滚动至底部控制器故障槽位、五 Tab 可见、设置入口与唯一续航编辑器、续航恢复默认确认/取消、续航入口进入详情并返回后根页整条导航栏仍隐藏、空历史/保存行程导航。
- 280 项 App 测试包含新 7 项图表点生成边界测试和 4 项设置回归。没有把等待样本、零/负值、缺失与断点改成模拟曲线；图表的真实硬件数据渲染仍待真机验收。
- macOS 模拟器通过不代表所有 iPhone 屏幕、VoiceOver、减少动态效果、真实 BMS 通信、断连/过期行为、锁屏行程或车辆安全验收；前批安装反馈也不证明本批安装成功。
- GitHub 工作流有 actions v4 的 Node.js 20 兼容/强制 Node.js 24 提示和 macOS 容量提示，不影响本次成功；本次不额外升级依赖。
- 最终文档提交将同步 README、总体进度、CI 证据、差异矩阵与设计规则，记录首轮失败/第二轮成功，不修改此次已构建源码。

## 步骤 040：电池/控制器分离实现与签名外 IPA 交付（北京时间 2026-10-11 22:34:47 +08:00）

- 落地五个 Tab（仪表盘/电池/控制器/行程/设置）；电池与控制器数据详情隔离，连接管理统一到设置的蓝牙设备页，两角色各自过滤、记忆 UUID、自动连接、断开及忘记；控制器历史/导出保留在二级页面。
- 构建源码提交 `01aec26313dad2eece77f5db431c6e7c61986f8a`（`01aec26`），已推送至 `codex/ios-parity-20261010`。后续本步骤文档提交不修改源码，不重建 IPA。
- Run `38145563196`（源码 `92a631e`）SwiftPM 通过，但两项 UI 断言未通过，因此未生成包。复核为 UI 自动化应点按 Toggle 实际控件区域并等待状态变化，另一项查询与 `LabeledContent` 的无障碍元素类型不匹配；修订测试点按及状态等待，并给记忆设备行增加稳定无障碍标识。
- 后续准确源码 Run `38147063235`（workflow_dispatch，head SHA 与 `01aec26` 完全一致）全部成功：SwiftPM 137 项、模拟器 iOS 测试 327 项、XCUITest 12 项，零失败；Release 设备构建、bundle 校验和 IPA 上传均通过。Xcode 26.3 / Swift 6.2.4。
- 下载并校验产物：`build/ci/01aec26/ANTuRide-unsigned.ipa`，2,247,761 字节，SHA-256 `95476b8eb519d0984732383d2d70ed8d5836ada32eca6058a6a5169d24d5943c`。ZIP CRC 正常；bundle ID `com.zjsf.anturide`、显示名“安途”、版本 0.1.0 (1)；Assets.car、AppIcon、PrivacyInfo.xcprivacy 齐全；没有嵌入 provisioning profile、`_CodeSignature` 或 Mach-O 签名数据，确认为 unsigned。`build/ci/latest/` 的 IPA SHA 相同。
- 证据 `run.json`、完整 `ci.log`、`artifact-verification.json` 与两个 IPA 均保存在被忽略的 `build/ci/01aec26/`、`build/ci/latest/`，不进入 Git。
- 本地三个静态契约检查：蓝牙 10/10、设置 6/6、Dashboard 6/6；`git diff --check` 通过。此为 Windows 静态检查；Xcode 编译/测试证据来自上述 macOS CI。
- 尚待真实 iPhone：签名安装、实际双 BLE 同时连接/独立断开/自动重连、权限和前后台行为、VoiceOver 与车辆数据核验。CI 通过和 unsigned IPA 生成不等于硬件验收。未修改 Android 父仓库。

## 步骤 041：续航驾驶窗口算法对齐与签名外 IPA 交付（北京时间 2026-10-12 12:30:00 +08:00）

### 范围边界

用户确认的范围是：**核心驾驶窗口算法已对齐 Android，但不是包含学习、审计和所有显示行为的完整复刻。**

保持不变的既有行为：最终公式仍为「剩余可用 Wh ÷ 窗口净 Wh/km」；继续使用 Android seed/legacy 固定能量曲线；额定容量仍由现有设置方式管理；仍不新增电池学习，也不恢复 Android 校准数据。

### 已对齐的 8 项

| 项目 | 对齐后的实现 |
|---|---|
| 有效驾驶判定 | 区间位移 ÷ 区间时长，平均速度 ≥ 3 km/h；不用瞬时 GPS 速度判定 |
| 预测最低门槛 | 同时满足 30 秒、200 米、5 Wh 放电、5 Wh 净能耗 |
| 窗口维护 | 按**累计有效驾驶时长** FIFO；停车与时间流逝不挤出旧驾驶证据 |
| 再生扣除 | `净 Wh = 放电 Wh − 移动再生 Wh` |
| 功率积分 | 使用 `电压 × 电流`，跨零时分别积分放电与再生 |
| 部分区间裁剪 | 距离与测量 Ah 按时间比例裁剪，功率插值后重新积分 |
| 刷新周期 | 缓存驾驶窗口；剩余 Ah/Wh 取最新 BMS；展示 Wh/km 与预测使用同一批窗口 |
| 数据恢复 | 按设备 UUID 本机恢复驾驶证据；不恢复旧实时采样端点，不保存坐标 |

核心代码：`Sources/Domain/Range/RangeDrivingWindow.swift`（窗口与积分）、`Sources/Services/RangeService.swift`（采样、配对与恢复）。

### 新增异常处理

- 容量异常跳变：超过「平均绝对电流可解释 Ah + BMS 容量的 1%」时清理驾驶窗口。
- 系统时钟、BMS/GPS 样本时间回退：清理旧时间基准，避免连接跨回退区间。
- 过大缺口、坏电气数据、功率符号冲突、坏 GPS 区间：只排除对应区间，**普通坏区间不清空其他有效历史**。
- 重复、重叠区间不重复累计；修复容量跳变后旧「停车充电」标记可能残留的问题。
- 复核阶段统一了 Android 的距离计算常量，并修复续航静态检查脚本在独立 iOS CI 无父项目源码时无法运行的问题（改为回退 pinned 基线）。

### 仍保留的差异

除上述明确保留项外：Android 在部分过期/断连状态下保留旧预测数值并标记暂停，iOS 仍撤下预测并显示不可用状态；iOS 保留现有更严格的数据有效性检查；Android 的完整原始区间审计、排除原因记录及回放体系没有整体移植。这些差异本轮未扩展。

### CI 迭代与最终结果

4 轮 `workflow_dispatch` 迭代（工作流 `push` 触发只覆盖 `main`，特性分支必须手动派发）：

| Run | 提交 | 结论 | 失败点与修复 |
|---|---|---|---|
| 38200256694 | `b617a78` | 失败 | `RangeServiceTests:913` 漏传 `longitude`（编译错误）；补参为 `5bc519e` |
| 38200692584 | `5bc519e` | 失败 | `testNetAh` 步长笔误致位移超 2 km 上限、区间全拒；`testColdRestoration` 缺断连 flush 前置；修复为 `c7004b1` |
| 38201483521 | `c7004b1` | 失败 | 单元测试全过；界面开关 `bluetooth.battery.filter` 偶发丢 tap；条件重试加固为 `60101a4` |
| 38202579046 | `60101a4` | 成功 | 14 个具名步骤全部成功，作业 04:08:42 → 04:17:35 UTC（8m53s） |

- 交付文档提交 `e81449c`（本步骤 041 的落档提交）连带运行 `38204388224` 同样成功，作业 04:35:20 → 04:44:51 UTC（9m31s）；它只证明文档改动不破坏构建，不是新的交付构建，产物归档 `build/ci/e81449c/`。

- 三项修复均未改动实现代码。`Tests/AppTests` 不参与 `swift test`，其编译与语义错误只能在 `xcodebuild` 真执行时暴露，前两轮失败属测试夹具问题；第三轮以同一 App 二进制的两次运行对照（UI 套件 193 s，首点坐标与通过运行时一致）判定为时序不稳，加固仍保留「两次点击后依然失败」的真实故障检出能力。
- 测试基线（Run `38202579046`）：SwiftPM 161、iOS XCTest 364、XCUITest 12，全部零失败；四项源码契约 33 例通过（设置 6，其中 2 例 Android 对照在独立 checkout 显式跳过；Dashboard 6；蓝牙 10；续航 11）。
- 回归覆盖：`RangeDrivingWindowTests` 24 例（窗口与积分）、`RangeServiceTests` 41 例（服务、配对、持久化与恢复）。

### 交付产物

- 构建源码提交 `60101a4d826418fec9879ca33400e13130208c13`（`60101a4`），已推送 `codex/ios-parity-20261010`。
- IPA：`build/ci/60101a4/ANTuRide-unsigned.ipa`，2276667 字节，SHA-256 `f2ee0df32452450e6158d5abcba8b78043c4095ed6545cdb4f75dc6ca256e797`；`build/ci/latest/` 已同步为同字节副本。
- 核验：13 个 ZIP 条目、CRC 全通过；主二进制 4531352 字节，含 `RangeDrivingWindow` / `RangeElectricalSpan` / `RangeDrivingInterval` / `RangeService` 符号；`Assets.car` 946264、`PrivacyInfo.xcprivacy` 397、`ANTuRideDomain.framework/ANTuRideDomain` 927568 字节。
- 标识：`com.zjsf.anturide`、显示名「安途」、版本 0.1.0 (1)、`CFBundleIconName = AppIcon`、`MinimumOSVersion = 16.0`、`UIBackgroundModes = [location]`；无 `embedded.mobileprovision`、无 `_CodeSignature`、主二进制 47 条加载命令中无 `LC_CODE_SIGNATURE`，确认为 unsigned，须个人签名后安装。
- 证据 `run.json`、`ci.log`（878676 字节）、`artifact-verification.json` 与 IPA 均保存在被忽略的 `build/ci/60101a4/`、`build/ci/latest/`，不进入 Git；`latest/` 的四个文件已统一指向 Run `38202579046`，不再混用上一批 `01aec26` 的元数据。
- `latest/` 语义据此明确为「最近一次**被采纳交付**的成功构建」：`e81449c` 是同一源码的纯文档提交重建，内层 `.ipa` 2276667 字节、13 条目与逐条目尺寸和 `60101a4` 完全一致，但 SHA-256 不同（`4b3aff93…`）、artifact 容器大小差 2 字节，故不替换 `latest`，避免交付物与已核验证据脱钩。跨 Run 可比量只有内层 `.ipa` 大小与包内条目清单，容器大小与 SHA 都不可比。
- 本地静态检查：四项契约 33/33（续航 11/11）与 `git diff --check` 通过，均为 Windows 静态结果；编译与测试证据来自上述 macOS CI。
- 尚待真实 iPhone + BLE + 车辆：真实 GPS 漂移、断连重连、后台锁屏、容量跳变下的窗口表现，以及 VoiceOver/大字号显示。CI 通过和 unsigned IPA 不代表硬件验收。


## 步骤 042：自动读取 BMS 容量与单一首页槽位布局（北京时间 2026-10-12 13:19:07 +08:00）

### 本轮决定与实现

- 续航总容量取当前新鲜、有效 BMS `capacityAh`，剩余量取同帧 `remainingAh`；不再依赖本机手动额定容量。旧容量偏好不读取、不删除其他设备数据；设置/详情显示“BMS 总容量”，不可用显示 `--`。
- 校验总容量有限、`0 < Ah <= 10000`，剩余 Ah 有限且在 `[0, capacityAh]`；无效、断连、采样重启或过期时撤下实时容量/预测。134Ah 使用 Android seed，其余容量使用 Android legacy，不硬编码默认容量，不扩大电池学习或隐私范围。
- 总容量变化清除旧驾驶窗口和配对端点，重新积累有效驾驶证据。持久化升级 `android-driving-window-v2-bms-capacity`，保存容量仅用于恢复校验，不当作当前容量；重连/冷启动仍需新 BMS/GPS。旧无容量元数据窗口无法证明匹配，首次升级会重新积累。
- JSON schemaVersion 升级为 4，新增 capacitySource；保留既有 nominalCapacityAh 键及 CSV 容量列作为兼容导出字段，其值现在表示有效实时 BMS 容量，而不是手动偏好。
- 首页固定使用槽位布局，删除旧十卡片 UI 和样式开关。旧卡片偏好只作解码迁移，首页加载迁移为默认槽位；已有合法定制和动态归还槽保留。
- 首页参数仍从「设置 → 首页参数」编辑，候选页使用原生 NavigationLink；删除旧排序造成的全局 active editMode，选择只改变草稿，保存生效，取消不保存，恢复默认需确认。仪表盘仍为只读驾驶页，不新增顶部编辑栏或覆盖原生导航。
- 删除手填容量、保存容量、容量重置入口，保留窗口/刷新与单一清除窗口动作；五 Tab、Dashboard 根页无导航栏、续航详情返回、RPM-only 与本地数据边界保持。

### 回归与验证边界

- 新增/更新 Swift 服务测试：自动容量、忽略旧偏好、134 seed/其他容量 legacy、无效容量与剩余量、变化重建、设备隔离、过期、断连重连和持久化容量匹配。
- 新增首页模型迁移/定制/保存取消/重启测试及 HomeParameterEditingUITests；更新续航 UI 测试验证无手填容量。
- Windows 源码契约检查通过：续航 13、设置 7、Dashboard 6、蓝牙 10，共 36 项；`git diff --check` 通过。此处均为静态源码检查，不是 Swift 编译或运行证明。
- 静态独立审阅容量服务/设置/详情未发现可操作缺陷；最终 12 个修改/新增 Swift 文件经 Tree-sitter Swift 扫描无 ERROR/missing 节点。语法树检查不等于类型检查或 iOS 编译。
- 本机未检测到 Swift/Xcode 工具；本轮尚未运行 SwiftPM、iOS XCTest/XCUITest、macOS CI 或真实 iPhone/BMS/车辆验证。既往 CI/IPA 不覆盖本轮改动。
- 未提交、推送、部署或生成新 IPA；源码与回归测试保持本地待验证，不能把旧 IPA 当成本轮交付。
