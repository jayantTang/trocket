# 第三方组件与来源声明

本仓库以 **GPL-3.0-or-later**（见 `LICENSE`）分发，原因是它链接了 GPL-3.0 的 sing-box 内核。
把编译产物（含 `.ipa`）分发给任何人时，必须同时提供本仓库的完整源码。

## 运行时组件

| 组件 | 版本 | 用途 | 许可证 |
|---|---|---|---|
| [SagerNet/sing-box](https://github.com/SagerNet/sing-box)（`libbox`，Apple 平台静态框架） | v1.14.2 | 代理协议实现与 TUN 栈（本项目的全部网络核心） | GPL-3.0-or-later，另有附加条款：**不得使用其名称或暗示与本项目存在官方关联** |
| [anytls/anytls-go](https://github.com/anytls/anytls-go) | 协议规范（`docs/protocol.md`） | AnyTLS 协议规范参考（**未引用其代码**；该仓库未声明许可证，因此不能复制其源码） | 未声明许可证（默认保留所有权利） |

## 随包数据

| 数据 | 来源 | 用途 |
|---|---|---|
| `Resources/RuleSets/geosite-cn.srs`、`geoip-cn.srs` | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite)、[SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip)（sing-box 官方规则集仓库） | 国内域名 / IP 的离线直连判定，版本与更新方式见 `Resources/RuleSets/SOURCES.md` |

`libbox` 以静态 xcframework 形式由 `scripts/build-libbox.sh` 从源码构建，不提交进仓库。
本项目未修改 sing-box 源码；唯一改动的是 Go 工具链的一份**副本**（`build/goroot-ios`，
用于在 iOS 上启用 ARM64 硬件 AES/SHA），不属于 sing-box 的一部分。

## 构建期工具（不进入产物）

| 工具 | 版本 | 许可证 |
|---|---|---|
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.46.0 | MIT |
| [sagernet/gomobile](https://github.com/sagernet/gomobile) | v0.1.13 | BSD-3-Clause |
| Go | 1.27.1 | BSD-3-Clause |

## 名称与商标

应用名称 Trocket 与本项目与 SagerNet、sing-box、Shadowrocket 等均无关联，
不表示其作者对本项目的认可或背书。
