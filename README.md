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

## 当前施工阶段

阶段 0：SwiftUI App 壳、协议解析、分片合包、BMS 模型、CoreBluetooth 服务骨架和测试。

阶段 1（全屏适配与液态玻璃真机验证通过；BMS 真机链路待验收）：设备扫描与选择、周期查询、实时仪表盘绑定、详情页、数据新鲜度与断开重连；iOS 26 设备自动启用 Liquid Glass 液态玻璃材质，旧系统回退普通材质。

阶段 1 及以后的真机验收需要真实 iPhone + ANT BMS，不能用 GitHub Actions 或 Windows 静态检查代替。
