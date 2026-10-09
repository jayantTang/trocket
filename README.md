# Trocket

一个极简的 iOS 代理客户端：粘贴订阅链接 → 测延迟 → 选线路 → 一键连接。
网络核心使用 [sing-box](https://github.com/SagerNet/sing-box) 的 `libbox`（v1.14.2），
不做协议自研；界面只有一个屏。

> **要求**：iOS 15+、付费 Apple 开发者账号（网络扩展能力需要）、真机验证
> （网络扩展无法在 iOS 模拟器运行）。

## 现在能做什么

| 能力 | 状态 |
|---|---|
| 导入订阅链接（自动按内核标识拉取配置） | ✅ |
| 展示线路列表（含 emoji/倍率名）、显示用量与到期 | ✅ |
| 一键连接 / 断开（系统 VPN 配置，状态以系统为准） | ✅ |
| 全部线路并发测延迟（20 秒收尾、可取消、按延迟排序） | ✅ |
| 连接中切换线路（不重新拨号）、"自动选择（按延迟）" | ✅ |
| 冷启动秒开、离线可用（读取本地缓存配置） | ✅ |

不做的（有意为之，见 `.specify/memory/constitution.md` 第 II 条）：
规则编辑器、多订阅管理、分流自定义、macOS/tvOS/Android 版本。

## 架构

```
┌─────────────────────── App（Trocket） ───────────────────────┐
│  SwiftUI 单屏：状态卡 / 线路列表 / 连接开关                    │
│  SubscriptionService ──► 拉订阅(UA: sing-box/1.14.2)          │
│                         识别 sing-box JSON 或 Clash YAML       │
│                         整形(替换 inbounds) ──► profile.json   │
│  TunnelController ──► NETunnelProviderManager（系统 VPN）      │
│  ControlChannel ──► LibboxCommandClient ─┐                    │
└──────────────────────────────────────────┼────────────────────┘
                    App Group 容器          │ unix socket: command.sock
        profile.json / subscription.json    │
┌──────────────────────────────────────────┼────────────────────┐
│  Network Extension（TrocketTunnel）       ▼                    │
│  PacketTunnelProvider ──► LibboxSetup + LibboxCommandServer    │
│                        └─► libbox 服务（AnyTLS 等协议 + TUN）  │
│  TunnelPlatformInterface ──► openTun（NEPacketTunnelNetwork）  │
└───────────────────────────────────────────────────────────────┘
```

设计取舍与实测证据写在 `specs/001-ios-vpn-client/research.md`；接口契约写在
`specs/001-ios-vpn-client/contracts/`。

## 构建

当前这台机器上生成并通过 OTA 安装的版本使用：
`TEAM_ID=<TEAM_ID>`、`BUNDLE_PREFIX=com.jayanttang`（bundle `com.jayanttang.trocket`，
App Group `group.com.jayanttang.trocket`）。换机器或换账号时用环境变量覆盖即可。

```bash
brew install go xcodegen
./scripts/build-libbox.sh     # 首次约 10–20 分钟，产出 Vendor/Libbox.xcframework
./scripts/bootstrap.sh        # 生成 Trocket.xcodeproj（自动探测 Team ID）
open Trocket.xcodeproj
```

**注意**：自动验证（设备 SDK 编译 + 单元测试）看 `./scripts/verify.sh`；
真机连接/测速/切换必须按 `specs/001-ios-vpn-client/quickstart.md` 第 3 节人工复验，
网络扩展在模拟器里跑不起来。

内核默认**不**编译 naive 出站：它会引入 Chromium Cronet（每切片约 42MB，且引用了 App Extension
里不存在的 `UIApplication`）。AnyTLS / Shadowsocks / VMess / VLESS / Trojan / Hysteria2 / TUIC /
WireGuard 均不受影响。确实需要时：`INCLUDE_NAIVE=1 ./scripts/build-libbox.sh`
（详见 `specs/001-ios-vpn-client/research.md` R9）。

## 目录

```
Sources/Shared/   两个 target 共用的模型与解析（无 libbox 依赖，可单测）
Sources/App/      主 App：订阅、隧道控制、命令通道、单屏 UI
Sources/Tunnel/   网络扩展：libbox 启动与平台接口
Tests/            单元测试（订阅解析、配置整形、排序、测速调度、状态机）
scripts/          内核构建 / 工程生成 / 验证
specs/            spec-kit 产物（spec / plan / research / contracts / tasks）
```

## 安全与隐私

订阅链接等同账号凭证：只写入本机 App Group 容器，不上报任何第三方；
应用不集成任何统计或崩溃上报 SDK；内核日志默认关闭。

## 许可

本项目以 **GPL-3.0-or-later** 分发（因为链接 GPL-3.0 的 sing-box）。
把 `.ipa` 分发给他人时需同时提供本仓库源码。第三方组件清单见 `THIRD_PARTY.md`。
本项目与 SagerNet / sing-box / Shadowrocket 均无关联。
