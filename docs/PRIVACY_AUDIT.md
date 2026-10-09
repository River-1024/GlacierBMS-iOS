# GlacierBMS iOS 隐私与凭据审计记录

> 审计时间：2026-10-09 23:10（北京时间）
> 审计对象：`D:\daima\bms\GPS_ANT_BMS\iOS`（独立仓库 `GlacierBMS-iOS`）
> 审计范围：仓库全部已跟踪文件与工作树内容
> 审计目的：确认新仓库不包含凭据、真实设备数据、个人轨迹或媒体文件，且不引用旧 iOS 项目。

## 1. 审计结论

首版仓库通过隐私与凭据审计。未发现 Token、私钥、证书、描述文件、Apple Team ID、真实 BLE 地址、GPS 轨迹、本机路径或个人媒体文件；未发现对旧 iOS 仓库的任何代码或文本引用。

当前首版不声明摄像头、麦克风、照片或音频权限，隐私清单明确关闭追踪。

## 2. 审计范围

已跟踪文件共 21 个，全部为源码、配置或文档：

| 类别 | 路径 |
|---|---|
| CI 工作流 | `.github/workflows/build.yml` |
| 忽略规则 | `.gitignore` |
| 隐私/安全文档 | `PRIVACY.md`、`SECURITY.md` |
| 工程定义 | `Package.swift`、`project.yml` |
| 隐私清单 | `Resources/PrivacyInfo.xcprivacy` |
| App 壳 | `Sources/App/GlacierBMSApp.swift`、`Sources/App/RootView.swift` |
| 主题 | `Sources/DesignSystem/AppTheme.swift` |
| 领域模型 | `Sources/Domain/Models/BmsSnapshot.swift` |
| 协议 | `Sources/Domain/Protocol/AntProtocol.swift`、`BmsFrameAssembler.swift` |
| 服务 | `Sources/Services/BmsBluetoothService.swift` |
| 界面 | `Sources/Features/Dashboard/DashboardView.swift` |
| 测试 | `Tests/UnitTests/*.swift`、`Tests/UITests/GlacierBMSTests.swift` |
| 规划文档 | `docs/MIGRATION_PLAN.md` |

未跟踪但存在于工作树的构建产物已被 `.gitignore` 排除（`.build/`、`DerivedData/`、`xcuserdata/`、`*.xcuserstate`、`.DS_Store`）。

## 3. 检查项与证据

### 3.1 凭据与密钥扫描

对源码、文档、工作流与 plist 扫描 `teamid`、`team_id`、`BEGIN (RSA|EC|PRIVATE)`、`mobileprovision`、`password`、`secret`、`token`、`api_key` 等关键模式。

结果：仅命中“禁止提交凭据”的说明性文字与 CI 中的 `embedded.mobileprovision` 断言（用于确认无签名产物不含描述文件），未发现任何真实凭据。

### 3.2 旧项目引用扫描

对源码、文档、工作流与 plist 扫描旧 iOS 仓库名称与路径关键字。

结果：无任何命中。本项目独立创建，未导入、未合并、未引用旧 iOS 项目代码或文本。

### 3.3 真实设备地址扫描

源码中不含任何真实 BLE MAC 地址或设备序列号；服务 UUID 仅使用 ANT BMS 公开的 `FFE0` / `FFE1`，属于协议标识而非个人数据。

### 3.4 个人路径与媒体文件扫描

已跟踪文件中不含 Windows/macOS 绝对个人路径，不含 `.png`、`.jpg`、`.mp4`、`.wav` 等媒体文件。

### 3.5 隐私清单核对

`Resources/PrivacyInfo.xcprivacy` 内容：

- `NSPrivacyTracking` = `false`
- `NSPrivacyTrackingDomains` = 空
- `NSPrivacyCollectedDataTypes` = 空
- `NSPrivacyAccessedAPITypes` = 空

工程未声明摄像头、麦克风、照片、音频等权限；仅声明蓝牙与定位用途说明文案。

### 3.6 权限用途说明

`project.yml` 中声明的用途说明：

| 键 | 值 |
|---|---|
| `NSBluetoothAlwaysUsageDescription` | 连接 ANT BMS 读取电池状态 |
| `NSLocationWhenInUseUsageDescription` | 记录速度、里程和行程能耗 |

## 4. 数据流向结论

首版代码不包含账号系统、广告 SDK、分析 SDK、云同步、HTTP API 或 WebSocket 上报。蓝牙、定位、日志与行程数据按设计在本机沙盒内处理，不主动上传。

## 5. 已知限制

- 本次审计为静态内容审计，不构成对 GitHub 仓库历史、fork 或本地未跟踪文件的完整凭据扫描。
- 当前主分支历史为首次创建以来的提交，未发现历史中曾提交后删除的凭据。
- 若后续加入签名材料、GitHub Secrets 或导出分享能力，需要重新审计。
- 本机无 macOS，无法用 Xcode 的隐私报告工具做二次交叉验证。

## 6. 复现命令

```bash
# 旧项目引用
grep -rni "GPSAntBMS\|GPS_ANT\|River-1024/GPS" . \
  --include='*.swift' --include='*.md' --include='*.yml' \
  --include='*.json' --include='*.plist' --include='*.xcprivacy'

# 凭据模式
grep -rniE "teamid|team_id|BEGIN (RSA|EC|PRIVATE)|mobileprovision|password|secret|token|api[_-]?key" . \
  --include='*.swift' --include='*.md' --include='*.yml' \
  --include='*.json' --include='*.plist' --include='*.xcprivacy' --include='*.pbxproj'

# 已跟踪文件清单
git ls-files
```
