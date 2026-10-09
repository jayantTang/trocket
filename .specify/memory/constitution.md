<!--
Sync Impact Report
- Version change: (none) → 1.0.0 (initial ratification)
- Modified principles: n/a (initial)
- Added sections: Core Principles (I–VI), 技术约束, 开发流程与验证门槛, Governance
- Removed sections: none
- Follow-up TODOs: none
-->

# Trocket Constitution

## Core Principles

### I. 本地优先，凭证不出机 (NON-NEGOTIABLE)

订阅链接、节点凭据、流量信息 MUST 只保存在本机（App Group 容器与 Keychain），
MUST NOT 上报任何第三方服务，MUST NOT 集成统计/分析/崩溃上报 SDK。
诊断日志 MUST 默认关闭，开启后也 MUST 对凭据字段脱敏。

理由：订阅链接本身就是账号凭证，泄露等同账号被他人使用；这是该类工具唯一的不可逆风险。

### II. 极简可用优先 (YAGNI)

首版界面 MUST 保持单屏，只做四件事：加载订阅、测试延迟、选择线路、连接/断开。
MUST NOT 加入规则编辑器、多订阅管理、分流自定义、主题系统等首版外功能。
新增任何界面元素前 MUST 先回答：删掉它，用户还能不能完成上述四件事。

理由：目标是"自己与朋友够用"，功能每多一项都会延长真机验证周期。

### III. 内核不重造

代理协议与 TUN 栈 MUST 复用 sing-box（libbox）现成实现，MUST NOT 自研协议实现或用户态 TCP/IP 栈。
内核版本 MUST 固定并在构建脚本中显式声明；升级内核 MUST 视为独立变更并重新跑真机验证。

理由：自研协议栈是数倍工作量且性能更差；复用内核才能达到"与商业客户端同档"的性能目标。

### IV. 许可证合规

本项目因链接 GPL-3.0 的 sing-box 而以 GPL-3.0 分发。
MUST 在仓库根保留 LICENSE 与上游来源声明（内核版本、仓库地址、许可证）。
MUST NOT 在公开分发版本中去掉上述声明或以自身名义暗示与上游官方产品存在关联。

理由：GPL 是分发前提，不是可选项；违反即失去分发权。

### V. 真机验证优先于模拟器

网络扩展（Packet Tunnel）无法在 iOS 模拟器运行，因此：
涉及连接行为、延迟测试、线路切换的改动 MUST 在真机上完成端到端验证后才算完成；
模拟器只允许用于界面渲染与订阅解析逻辑的验证。
每次真机验证 MUST 记录：设备型号、系统版本、所用订阅、每一步的实际结果。

理由：模拟器"通过"不能证明能连上；把模拟器结论当成验收结论是本项目最容易犯的错。

### VI. 简约即性能

界面 MUST 无多余动效与装饰；冷启动到可交互 MUST 在 1 秒内完成（不含系统动画）。
节点列表 MUST 使用轻量渲染方式，节点数达到 500 条时滚动 MUST 保持流畅。
延迟测试 MUST 并发执行且有明确上限，MUST NOT 阻塞界面。

理由：用户对这类工具的全部感受就是"快"；任何一处卡顿都会被直接归因为"软件不行"。

## 技术约束

- 平台：iOS 15.0 及以上（与内核最低版本对齐），Swift + SwiftUI。
- 工程文件：由 XcodeGen 从 `project.yml` 生成，MUST NOT 手工维护 `.xcodeproj`。
- 内核：sing-box `v1.14.2`，经 `scripts/build-libbox.sh` 构建为 `Vendor/Libbox.xcframework`，
  包含 `ios/arm64` 与 `iossimulator/arm64` 两个切片。
- 目标结构：主 App（`Trocket`）+ 网络扩展（`TrocketTunnel`），二者通过 App Group 共享配置。
- 订阅格式：以 sing-box profile JSON 为主路径（请求时带 sing-box 内核版本的 User-Agent）；
  Clash YAML 作为兜底解析路径。
- 构建产物 MUST NOT 提交进仓库；构建脚本 MUST 可重复执行。

## 开发流程与验证门槛

- 遵循 spec-kit 阶段流：constitution → specify → plan → tasks → analyze → implement；
  每阶段产物落在 `specs/NNN-*/` 下，实现前 MUST 通过 analyze 一致性检查。
- 每个任务完成后 MUST 至少通过一项自动验证：编译（设备 SDK）、单元测试、或脚本自检。
- 涉及连接行为的任务 MUST 附真机验证记录；无真机记录时该任务状态 MUST 记为"待真机验证"，
  MUST NOT 标记为完成。
- 交付版本 MUST 附带真机安装说明（签名方式、App Group、扩展能力配置）。

## Governance

本宪法优先于其它开发习惯；与之冲突的实现方案 MUST 先修宪再落地。
修订流程：提出修订 → 说明影响面（原则增删/重定义 vs 澄清）→ 更新版本号 → 同步受影响的 spec/plan/tasks。
版本策略：MAJOR＝移除或重定义原则；MINOR＝新增原则或实质扩展；PATCH＝措辞澄清。
所有 spec、plan、tasks 与实现评审 MUST 逐条核对本宪法；违反项 MUST 在合并前修正或显式记录豁免理由。

**Version**: 1.0.0 | **Ratified**: 2026-10-08 | **Last Amended**: 2026-10-08
