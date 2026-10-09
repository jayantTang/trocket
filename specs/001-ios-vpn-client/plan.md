# Implementation Plan: 极简 iOS 代理客户端（订阅加载 / 延迟测试 / 线路选择）

**Branch**: `001-ios-vpn-client` | **Date**: 2026-10-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-ios-vpn-client/spec.md`

## Summary

做一个单屏 iOS 应用：粘贴订阅链接 → 拉取线路 → 测延迟 → 选线路 → 一键连接。
技术上不自研协议，直接把网络扩展（Packet Tunnel）架在 **sing-box 1.14.2（libbox）** 之上：
扩展进程内启动 libbox 服务并用 `LibboxCommandServer` 托管，主 App 用 `LibboxCommandClient`
经 App Group 内的本地通道读取状态/线路组、触发测速与切换。订阅走服务商提供的
"面向 sing-box 内核的 JSON 配置"（请求时带内核版本 User-Agent），Clash YAML 作兜底。
工程由 XcodeGen 生成，内核由仓库内脚本从源码构建为 `Vendor/Libbox.xcframework`。

## Technical Context

**Language/Version**: Swift（Xcode 26.x 工具链，语言模式 5）、Shell（构建脚本）、Go 1.27（仅用于构建内核）

**Primary Dependencies**: `Libbox.xcframework`（sing-box v1.14.2，GPL-3.0-or-later）、NetworkExtension、
SwiftUI；构建期依赖 XcodeGen、Go + sagernet/gomobile v0.1.13。运行时无其他第三方库。

**Storage**: App Group 容器（`group.<team-prefix>.trocket`）下的 `profile.json`（整形后的内核配置）、
`subscription.json`（订阅链接与用量元数据）；`UserDefaults(suiteName:)` 存订阅链接与选中线路。

**Testing**: XCTest 单元测试（订阅解析、配置整形、延迟排序、错误文案）在模拟器运行；
连接/测速/切换按宪法第 V 条在真机验收并记录。

**Target Platform**: iOS 15.0+（arm64 真机 + arm64 模拟器），iPhone 竖屏。

**Project Type**: mobile-app（单 App + 一个 App Extension）

**Performance Goals**: 冷启动到可交互 ≤1s（有缓存）/ ≤3s（无缓存）；44 条线路一次测速 ≤20s；
连接状态变化 ≤5s 反映到界面；列表滚动 60fps。

**Constraints**: 无第三方上报；单订阅；订阅内容可能含 3500+ 条分流规则（必须原样透传给内核，
不在 Swift 侧解析规则）；网络扩展内存受限，不做常驻大缓存。

**Scale/Scope**: 1 个主界面 + 1 个订阅抽屉；线路数 44（当前订阅）～500（预留）；
代码规模约 1500～2000 行 Swift + 约 300 行脚本。

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| 宪法条款 | 本方案的落实方式 | 结论 |
|---|---|---|
| I. 本地优先，凭证不出机 | 订阅链接与配置只写 App Group 容器；无第三方 SDK；日志默认关闭且脱敏 | PASS |
| II. 极简可用优先 | 单屏四件事；无规则编辑、无多订阅、无主题系统 | PASS |
| III. 内核不重造 | 协议与 TUN 栈全部由 libbox 承担；版本固定 v1.14.2 并由脚本构建 | PASS |
| IV. 许可证合规 | 仓库根 `LICENSE`（GPL-3.0）+ `THIRD_PARTY.md` 声明内核来源与版本 | PASS |
| V. 真机验证优先于模拟器 | 连接/测速/切换列为"待真机验证"项，模拟器只跑解析与 UI | PASS |
| VI. 简约即性能 | 无动效堆砌；测速并发+可取消；列表用 `List` 懒加载 | PASS |

无违反项，Complexity Tracking 留空。

## Project Structure

### Documentation (this feature)

```text
specs/001-ios-vpn-client/
├── plan.md              # 本文件
├── research.md          # Phase 0：技术选型与证据
├── data-model.md        # Phase 1：数据模型
├── quickstart.md        # Phase 1：从零到真机跑通
├── contracts/           # Phase 1：对外/对内接口契约
│   ├── subscription-fetch.md
│   └── tunnel-control.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2（/speckit-tasks 生成）
```

### Source Code (repository root)

```text
22_trocket/
├── project.yml                     # XcodeGen 工程定义（两个 target）
├── Vendor/
│   └── Libbox.xcframework          # 由 scripts/build-libbox.sh 产出（不入库）
├── scripts/
│   ├── build-libbox.sh             # 从 sing-box 源码构建内核（含 Go 1.27 补丁）
│   ├── bootstrap.sh                # 检查内核 + xcodegen 生成工程
│   └── verify.sh                   # 设备 SDK 编译 + 模拟器单测（一次命令跑完）
├── Sources/
│   ├── Shared/                     # 两个 target 共用
│   │   ├── AppConfiguration.swift  # App Group / bundle id / 内核 UA
│   │   ├── ProfileDocument.swift   # 订阅原始文档与整形后的内核配置
│   │   ├── NodeList.swift          # 线路模型与排序
│   │   └── TunnelStatus.swift      # 隧道状态枚举与文案
│   ├── App/                        # 主 App（SwiftUI）
│   │   ├── TrocketApp.swift
│   │   ├── TunnelController.swift  # NETunnelProviderManager 封装
│   │   ├── SubscriptionStore.swift # 拉取、解析、落盘、错误分类
│   │   ├── ControlChannel.swift    # LibboxCommandClient 封装（状态/组/测速/切换）
│   │   ├── NodeListViewModel.swift
│   │   └── Views/
│   │       ├── RootView.swift      # 单屏：状态卡 + 线路列表 + 底部连接开关
│   │       ├── NodeRow.swift
│   │       └── SubscriptionSheet.swift
│   └── Tunnel/                     # 网络扩展
│       ├── PacketTunnelProvider.swift
│       └── PlatformInterface.swift # LibboxPlatformInterfaceProtocol 最小实现
├── Tests/
│   └── TrocketTests/
│       ├── SubscriptionParsingTests.swift
│       ├── ConfigShapingTests.swift
│       └── NodeSortingTests.swift
├── Resources/
│   └── Assets.xcassets
├── LICENSE                         # GPL-3.0
└── THIRD_PARTY.md
```

**Structure Decision**: 采用"单仓库 + 两 target（App / Network Extension）+ 共享 `Sources/Shared`"结构。
不使用 Swift Package 拆分：只有两个 target、共享面很小，拆包反而增加工程复杂度与构建时间。
内核以二进制 xcframework 形式放在 `Vendor/`（`.gitignore` 忽略），保证源码仓库体积小、内核构建可重复。

## Complexity Tracking

> 无宪法违反项，本节留空。
