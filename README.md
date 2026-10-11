# ANTuRide iOS（安途）

原生 SwiftUI iOS 首版，面向个人签名安装。项目目标是通过 CoreBluetooth 连接 ANT BMS，提供驾驶仪表盘、GPS 速度、实时电池状态和后续行程/续航能力。

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

## 当前功能批次与IPA（北京时间 2026-10-11 10:55:06）

首页27槽位/39指标与真实控制器数据、驾驶设置消费、续航窗口指标、行程CSV/分页和控制器18列CSV/XLSX已接入。新增入口：**设置 → RPM加速测试与历史**。加速仅RPM，默认系数0.0782，车速(km/h)=原始RPM×系数×方向；无GPS/IMU和模拟结果。

此批已提交推送；最终源码5bd1493 / GitHub Actions Run 38106226167完整成功：130项领域测试、269项iOS单测、3项UI测试均0失败，Release设备构建通过。IPA已下载到build/ci/5bd1493/ANTuRide-unsigned.ipa（2161766字节），latest副本已同步。产物为unsigned，需签名后安装；真实硬件/车辆验收、地图轨迹与平台扩展边界见docs/CONSTRUCTION_LOG.md步骤025–030和IOS_ANDROID_PARITY_AUDIT.md最新节。
