# ANTuRide iOS（安途）

原生 SwiftUI iOS 首版，面向个人签名安装。通过 CoreBluetooth 独立连接 ANT BMS 与电机控制器，提供驾驶仪表盘、GPS 速度、电池/控制器实时数据、行程与续航能力。

## 隐私边界

当前版本不包含账号、云同步、广告、分析 SDK、HTTP 上报、摄像头或麦克风能力。蓝牙、定位、日志和行程数据按首版规划在本机处理。详见 [PRIVACY.md](PRIVACY.md)。

## 构建

本机没有 macOS 时，使用仓库内 GitHub Actions 在 GitHub-hosted macOS runner 上完成工程生成、SwiftPM 测试和 iOS 模拟器测试。

```bash
brew install xcodegen
xcodegen generate
swift test
```

在 macOS/Xcode 上进行个人签名安装时，选择个人 Team。不要把签名材料、Team ID 或描述文件提交到仓库。

### 取回构建产物

CI 每次成功运行都会产出无签名 IPA。用脚本一键拉回本地产出目录：

```bash
scripts/fetch-ipa.sh                 # 取最近一次成功的运行
scripts/fetch-ipa.sh -r <Run ID>     # 取指定运行
```

归档结构（`build/` 已在 `.gitignore` 内，不会误提交）：

```
build/ci/<短提交号>/ANTuRide-unsigned.ipa
build/ci/latest/ANTuRide-unsigned.ipa    # 始终指向最近一次成功
```

## 当前施工阶段

阶段 0：SwiftUI App 壳、协议解析、分片合包、BMS 模型、CoreBluetooth 服务骨架和测试。

阶段 1（全屏适配与液态玻璃真机验证通过；BMS 真机链路待验收）：设备扫描与选择、周期查询、实时仪表盘绑定、详情页、数据新鲜度与断开重连；iOS 26 设备自动启用 Liquid Glass 液态玻璃材质，旧系统回退普通材质。

阶段 1 及以后的真机验收需要真实 iPhone + ANT BMS，不能用 GitHub Actions 或 Windows 静态检查代替。

阶段 2：GPS 与行程领域/会话层已接入；用户已确认真机速度显示正常。G3 本地行程列表、详情、分段展示、JSON 导出与确认删除已实现，新增代码待 macOS 编译/模拟器验证。后台、锁屏暂停/解锁恢复及行程文件仍待真机验收，详见 `docs/MIGRATION_PLAN.md` 的 G2/G3 记录。

2026-10-10 19:02:23 +08:00 后续阶段复核：已接入基础续航预测页、首页参数编辑模型、控制器记录领域模型，并生成安卓版差异矩阵。当前仍不能称为安卓版完整复刻：续航完整校准/分析导出、控制器 BLE 实时链路、加速测试、动态首页渲染、Live Activity/CarPlay 尚未完成或验证；详见 `docs/IOS_ANDROID_PARITY_AUDIT.md`。

## 逐步施工记录

每个施工步骤同步更新 `docs/CONSTRUCTION_LOG.md`，记录文件范围、实际结果、验证命令/证据、失败与剩余风险。代码、测试、CI/模拟器及真机验收分别标记，不用旧 CI 证明当前工作树。

## 前批功能与 IPA（历史记录：北京时间 2026-10-11 10:55:06）

首页27槽位/39指标与真实控制器数据、驾驶设置消费、续航窗口指标、行程CSV/分页和控制器18列CSV/XLSX已接入。新增入口：**设置 → RPM加速测试与历史**。加速仅RPM，默认系数0.0782，车速(km/h)=原始RPM×系数×方向；无GPS/IMU和模拟结果。

此批已提交推送；最终源码5bd1493 / GitHub Actions Run 38106226167完整成功：130项领域测试、269项iOS单测、3项UI测试均0失败，Release设备构建通过。IPA已下载到build/ci/5bd1493/ANTuRide-unsigned.ipa（2161766字节），latest副本已同步。产物为unsigned，需签名后安装；真实硬件/车辆验收、地图轨迹与平台扩展边界见docs/CONSTRUCTION_LOG.md步骤025–030和IOS_ANDROID_PARITY_AUDIT.md最新节。

**安装进度（北京时间 2026-10-11 11:00:21 +08:00）：用户已确认本批安装成功。** 安装环节通过；GitHub原始IPA仍为unsigned。此反馈不代表本批功能、真实硬件或车辆验收全部通过，详细待验收项见施工记录步骤031。

## 当前本地导航与设置入口（电池/控制器分离改动尚未经过 macOS CI）

底部固定 **仪表盘 / 电池 / 控制器 / 行程 / 设置** 五项，避免六标签折叠到系统 More。
- **电池**：仅 BMS 电池包、单体、温度、MOS、均衡及通讯详情；断开/过期/缺失不显示为真实零值。
- **控制器**：仅控制器详细实时数据、状态和故障；「记录与历史」为二级页面。
- **设置 → 蓝牙设备**：电池 ant / 控制器 apt 名称分别过滤，分别扫描、连接、重试、断开、忘记；自动连接开关独立保存。
- **设置 → 驾驶与显示设置**：主题、字号、功率图、阈值和 BMS 查询周期，不再重复编辑连接开关。
- **设置 → 首页参数与布局**：首页槽位/显示配置，草稿保存或取消。
- **设置 → 综合续航设置**：窗口、刷新、设备容量与范围明确的清除/重置。
- **仪表盘「续航」 → 综合续航**：结果、窗口指标与 JSON/CSV 导出。
- RPM-only 加速、控制器记录/历史及诊断日志保留设置入口。

启动和真正从后台返回前台，电池/控制器各有一次有限的记忆 UUID 连接尝试；手动断开抑制本次进程自动连接，重启仍保留记忆，忘记才删除连接记忆。名称仅筛选手动候选；记忆设备改名仍按 UUID 尝试并验证协议，不能改连同名设备。

本地新增改动的验证与实机验收边界见 `docs/BATTERY_CONTROLLER_SEPARATION.md`。下面的 CI/IPA 记录只适用于其标注的历史提交，不代表当前未提交改动已经通过构建或真机验证。


## 最新 UI 批次与 IPA（北京时间 2026-10-11 15:06:00 +08:00）

- 已提交全部项目更改并发布到 `codex/ios-parity-20261010`：首批 `21b0127`，无障碍回归修复 `414d8b0`。
- 准确源码 `414d8b0` / GitHub Actions Run `38119495743` 全部成功：130 领域测试、280 iOS 单测、9 UI 测试零失败，Release 设备构建通过。
- 首页删除标题/顶部导航栏空白、独立 BMS 连接卡与行程控制；保留高密度 27 槽位/旧偏好，连续滚动且尊重系统安全区；行程控制归位行程 Tab，曲线使用 Swift Charts。
- IPA：`build/ci/414d8b0/ANTuRide-unsigned.ipa`，latest 已同步；2210282 字节，SHA-256 `1999c55ec46705c9b26d0b0b70668eba9a315445ac9254400520e5afc0b86ef3`。原始包 unsigned，需要签名后安装。
- 完整进度、首轮 UI 测试失败与修复、证据和待真机验收见 `docs/CONSTRUCTION_LOG.md` 步骤 037–039、`docs/CI_BUILD_RESULTS.md` §9。后续文档提交不改变已构建源码，不表示重新构建了文档提交。

## 电池/控制器分离与最新 IPA（北京时间 2026-10-11 22:34:47 +08:00）

本节更新并取代上面的旧 IPA 批次状态：电池与控制器独立展示、独立名称过滤/记忆/自动连接；扫描、手动连接、断开和忘记统一在“设置 → 蓝牙设备”。控制器记录与导出位于二级页。

- 源码已提交并推送到 `codex/ios-parity-20261010`，构建源码提交 `01aec26313dad2eece77f5db431c6e7c61986f8a`（`01aec26`）。
- GitHub Actions Run `38147063235` 对应 SHA 完全一致且成功；Xcode 26.3 / Swift 6.2.4。SwiftPM 137 项、iOS 测试 327 项、XCUITest 12 项全部零失败；Release unsigned 设备构建、包检查和上传成功。
- IPA：`build/ci/01aec26/ANTuRide-unsigned.ipa`；`build/ci/latest/ANTuRide-unsigned.ipa` 为校验后副本。2,247,761 字节，SHA-256 `95476b8eb519d0984732383d2d70ed8d5836ada32eca6058a6a5169d24d5943c`。
- IPA 未签名、无 provisioning profile，须用个人 Apple 开发者签名后安装。模拟器和 CI 不代表真实 iPhone 双设备 BLE、独立断开/重连或车辆验收通过。
- 详细实施、失败修复及证据见 `docs/CONSTRUCTION_LOG.md` 步骤 040、`docs/CI_BUILD_RESULTS.md` §10 和 `docs/BATTERY_CONTROLLER_SEPARATION.md`。后续文档提交不改变已构建源码，也不声称重新构建。
