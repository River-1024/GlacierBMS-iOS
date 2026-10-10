# 仓库公开前隐私复核

- 时间：2026-10-10 21:02:49 +0800（北京时间）。
- 用户明确要求：检查隐私后将 River-1024/GlacierBMS-iOS 改为公开，继续 GitHub 编译。
- 范围：独立 iOS 仓库，不包含安卓父仓库；main 与 codex/ios-parity-20261010 两个远端分支，无 tags。

## 已执行检查

1. 所有本地 Git refs 的 158 个唯一历史 blob，扫描私钥、GitHub token、云 access key、凭据赋值、签名/密钥/日志文件、个人路径/邮箱/MAC；另外扫描当前 Sources/Tests/docs 待提交内容。未发现真实凭据、签名材料、真实设备地址或轨迹文件。
2. 命中复核：邮件模式实际命中 AppIcon60x60@2x.png 资源名，并非邮箱；提交作者仅使用 GitHub noreply 邮箱。历史隐私审计曾写通用开发目录（无 Windows 用户名或凭据），当前文档去除目录；旧 Git 历史仍可见此通用目录，不声称历史零路径。
3. 41 个已完成 Actions Run 日志全部下载并扫描强凭据模式，无 token/私钥命中。运行日志仅 CI 证据；未把手机现场日志提交。
4. 无公开 Issue、Release、Wiki、Pages 或 Discussion 内容。24 个未过期 Actions artifact 名称均为 unsigned IPA；本轮 8315235 IPA 实际解包 13 个条目，无证书/描述文件/私钥/运行日志/行程目录，仅蓝牙与定位权限。旧 23 个 artifact 未逐包二进制审计，不将名称检查等同逐包扫描。
5. build/、.build/、DerivedData/ 已忽略，不提交本地现场文件。App 数据留沙盒，用户主动分享可能包含位置、设备 UUID 和遥测；不是自动网络上报。

## 审计边界

静态规则无法数学证明零敏感内容，也不等同第三方安全审计。公开后源码、Git 历史和工作流日志可被其他人复制；不存在通过再改私有收回外部副本的保证。该操作在用户明确授权范围内，不改安卓仓库可见性，不公开 Actions Secrets、不改签名、不发布 App Store。

## 执行结果

可见性切换及新 CI Run 结果另在 CONSTRUCTION_LOG.md 逐步记录。
