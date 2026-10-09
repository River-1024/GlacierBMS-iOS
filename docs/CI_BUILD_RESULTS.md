# ANTuRide iOS GitHub 构建结果记录

> 记录时间：2026-10-10 00:55（北京时间，最近一次更新）
> 仓库：`https://github.com/River-1024/GlacierBMS-iOS`（私有）
> 工作流：`.github/workflows/build.yml`
> 说明：本机（Windows）无 Swift/Xcode，iOS 编译与测试全部在 GitHub-hosted macOS runner 上执行。
> 本文档为收尾时点快照；此后仅文档类提交不改变构建语义。

## 1. 结论

**最近一次更新（2026-10-10 00:55）：** 项目更名为 `ANTuRide`（显示名「安途」）并加入 App 图标后，运行 `37961690423`（提交 `2e77a27`）在 Xcode 26.3 / iOS 26.2 SDK 上全绿，并首次通过新增的 `Verify app bundle contents` 断言步骤：`Assets.car`（946264 字节）与 `PrivacyInfo.xcprivacy`（397 字节）均在包内，`CFBundleIconName = AppIcon`、`CFBundleIdentifier = com.zjsf.anturide`、`CFBundleDisplayName = 安途`。该步骤同时修复了一个此前未被发现的缺陷——旧的 target 级 `resources:` 键不生效，导致资源与隐私清单从未进包（详见 `docs/PRIVACY_AUDIT.md` 第 7.1 节）。

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

## 4. CI 产物

| 产物名 | 来源运行 | 大小 | 保留 | 状态 |
|---|---|---|---|---|
| `ANTuRide-unsigned-ipa` | `37961690423`（`2e77a27`） | 1174236 字节 | 7 天 | 未过期 |
| `ANTuRide-unsigned-ipa` | `37955477377`（`f1d125e`） | 196412 字节 | 7 天 | 已过期 |

产物为 `ANTuRide.ipa`（内部 `Payload/ANTuRide.app`），已包含阶段 1 界面、液态玻璃样式、App 图标与隐私清单；工作流断言不含 `embedded.mobileprovision`。体积变化：阶段 0 为 75224 字节，阶段 1 为 196412 字节（+UI 与样式），资源修复后为 1174236 字节（+`Assets.car` 946264 字节、图标 PNG 与 `PrivacyInfo.xcprivacy`）。

产物内容（运行 `37961690423`，本机下载后核验）：

| 条目 | 大小 |
|---|---|
| `ANTuRide.app/ANTuRide` | 768408 字节 |
| `ANTuRide.app/Assets.car` | 946264 字节 |
| `ANTuRide.app/AppIcon60x60@2x.png` | 19248 字节（120×120，Apple CgBI 优化 PNG） |
| `ANTuRide.app/AppIcon76x76@2x~ipad.png` | 29028 字节 |
| `ANTuRide.app/PrivacyInfo.xcprivacy` | 397 字节 |
| `ANTuRide.app/Frameworks/ANTuRideDomain.framework/ANTuRideDomain` | 121672 字节 |

核验命令：

```bash
gh run download 37961690423 -R River-1024/GlacierBMS-iOS -n ANTuRide-unsigned-ipa -D build/ci
```

SHA-256：`197584f9dbe3a4481bd518c2eaeb094e0d99cb1ae4320e053c86b8c055312d9c`

## 5. 产物可用性边界

- 无签名 IPA 不能直接安装到 iPhone。
- 若要安装，需用个人 Apple 开发者 Team 重新签名，或在本机 Xcode 中选择个人 Team 后直接构建安装。
- 若希望 GitHub 自动产出可安装包，需要用户自行配置 Apple 签名证书、Provisioning Profile 与 GitHub Secrets；在用户明确要求前，仓库不写入任何签名材料。

## 6. 复现方式

在 GitHub Actions 页面打开对应 Run，从其 Artifacts 区域下载 `ANTuRide-unsigned-ipa`；或使用命令行：

```bash
gh run download 37955477377 -R River-1024/GlacierBMS-iOS -n ANTuRide-unsigned-ipa
```

本地 macOS 复现：

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

## 7. 与真机验收的边界

以下不属于本工作流的能力范围，必须在 macOS + Xcode + 真实 iPhone + 真实 ANT BMS 上完成：

- 个人签名安装在真实 iPhone。
- CoreBluetooth 真实扫描、连接、Notify 与分片合包。
- GPS 实采与后台未锁屏记录。
- 真实车辆仪表盘数据核验。

GitHub 构建通过仅代表工程可编译、可测试，不构成设备已验证。
