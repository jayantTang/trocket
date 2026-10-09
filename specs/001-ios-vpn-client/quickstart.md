# Quickstart: 从零到真机跑通

**前置条件**：macOS + Xcode 26（含 iOS 26 SDK）、付费 Apple 开发者账号、Go 1.25+（仅构建内核需要）、
XcodeGen（`brew install xcodegen`）。

## 0. 一次性准备

```bash
cd /Users/jayanttang/Bspace/project/22_trocket
brew install go xcodegen            # 已装可跳过
./scripts/build-libbox.sh           # 构建 Vendor/Libbox.xcframework（首次约 10–20 分钟）
```

`build-libbox.sh` 做四件事：拉取 sing-box v1.14.2 → 复制一份 GOROOT 并打上"iOS 启用硬件 AES/SHA"补丁
→ 用 sagernet/gomobile 分别构建 `ios/arm64` 与 `iossimulator/arm64` 切片 → 合并为
`Vendor/Libbox.xcframework`。脚本可重复执行；`build/` 目录可随时删除重来。

## 1. 生成工程

```bash
./scripts/bootstrap.sh
open Trocket.xcodeproj
```

`bootstrap.sh` 会检查内核产物是否存在、用 `xcodegen` 依据 `project.yml` 生成工程，
并把本机钥匙串里的开发者 Team ID 写进生成参数（也可显式指定：`TEAM_ID=XXXXXXXXXX ./scripts/bootstrap.sh`）。

## 2. 配置签名与能力（Xcode 内，一次性）

1. 选中 `Trocket` target → Signing & Capabilities → 勾选 **Automatically manage signing**，
   Team 选自己的开发者账号。
2. 确认两个 target 都有 **App Groups** 能力，且值为 `group.<你的前缀>.trocket`。
3. 确认 `TrocketTunnel` target 有 **Network Extensions** 能力（Packet Tunnel 勾选）。
4. 若提示 "Personal Team cannot use Network Extensions"：说明用的不是付费账号，需切换到付费 Team。
5. 真机首次运行：设置 → 通用 → VPN与设备管理 → 信任该开发者。

## 3. 真机跑通（按顺序验收）

| 步骤 | 操作 | 期望结果 |
|---|---|---|
| 1 | 打开 App，粘贴订阅链接，点"导入" | 10 秒内出现线路列表、顶部显示已用流量与到期日 |
| 2 | 点"测速" | 每条线路右侧出现毫秒数；20 秒内全部出结果，期间列表可滚动 |
| 3 | 选一条延迟低的线路，打开底部开关，同意 VPN 授权 | 5 秒内状态变"已连接"，能打开被限制的站点 |
| 4 | 连接状态下点另一条线路 | 状态不闪断，新打开的页面出口 IP 变化 |
| 5 | 选"自动选择（按延迟）" | 状态保持连接 |
| 6 | 杀进程重开 | 列表立即出现（无需联网），仍选中上次的线路，状态与系统一致 |
| 7 | 关闭开关 | 状态变"未连接"，网络恢复直连 |

## 4. 每次改代码后的验证

```bash
./scripts/verify.sh
```

`verify.sh` 依次执行：
1. 设备 SDK 编译（`xcodebuild -sdk iphoneos -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`）——
   证明两个 target（含网络扩展）都能为真机编译；
2. 模拟器编译 + 单元测试（`xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'`）——
   覆盖订阅解析、配置整形、排序与错误文案；
3. 输出通过/失败摘要，失败时打印第一处错误。

**注意**：模拟器**不能**验证连接功能（网络扩展在模拟器不可用）。凡涉及连接、测速、切换的改动，
必须在真机上按第 3 节表格复验，并在 `specs/001-ios-vpn-client/verification/` 下留记录
（设备型号、系统版本、步骤、实际结果、截图）。

## 5. 分发给朋友（Ad Hoc）

1. 让朋友提供设备 UDID（`Finder` 连接设备 → 点序列号可切换显示；或让他在
   `https://udid.tech` 之类页面获取）。
2. 开发者后台 → Devices 添加 UDID（每年上限 100 台）。
3. Xcode → Product → Archive → Distribute App → **Ad Hoc** → 导出 `.ipa`。
4. 把 `.ipa` 与信任步骤发给朋友（设置 → 通用 → VPN与设备管理 → 信任）。
5. 备选：TestFlight 内部测试（最多 100 人，不需要审核；外部测试需过审，VPN 类在中国区会被拒）。

### 5.1 关于"OTA 安装链接"（itms-services）

想让手机点一个链接就装上，需要同时满足三件事，缺一不可：

1. **Xcode 里已登录 Apple ID**（Xcode → Settings → Accounts）。没有账号时 `xcodebuild` 会报
   `No Accounts`，既不能生成描述文件，也不能导出 IPA。
2. **IPA 对应的描述文件包含该手机的 UDID**。Ad Hoc / 开发描述文件都是逐台授权的：
   每个朋友的手机都要先在开发者后台 Devices 里注册（每年 100 台上限）。
   真正"谁点谁装"只有 TestFlight 或企业证书能做到（企业证书给外部人用违反协议，不要碰）。
3. **manifest.plist 与 IPA 通过 HTTPS 提供**（自签证书需要先在手机上安装并信任 CA；
   用 `cloudflared tunnel --url http://127.0.0.1:<port>` 可以拿到带受信证书的公网 https 地址）。

生成方式（登录账号后）：

```bash
xcodebuild build -scheme Trocket -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData-device \
  -allowProvisioningUpdates
mkdir -p build/ota/Payload && cp -R build/DerivedData-device/Build/Products/Release-iphoneos/Trocket.app build/ota/Payload/
(cd build/ota && zip -qry Trocket.ipa Payload)
# 再用 manifest.plist 指向 https://<host>/Trocket.ipa，手机打开：
#   itms-services://?action=download-manifest&url=https://<host>/manifest.plist
```

安装后在手机上还需要：设置 → 通用 → VPN与设备管理 → 信任该开发者
（iOS 16 起还需在 设置 → 隐私与安全性 → 开发者模式 打开一次并重启）。

## 6. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 导入提示 402 | 服务商判定订阅到期/欠费；去面板核对，应用不会覆盖旧配置 |
| 导入返回空体 | User-Agent 未被识别；确认请求头为 `sing-box/1.14.2`（见 `AppConfiguration.kernelUserAgent`） |
| 连接后打不开任何站点 | 先看内核日志（Xcode → Window → Devices → 选择设备 → 查看 `TrocketTunnel` 日志），多为配置里 `stack`/`mtu` 与真机网络不匹配；改 `ConfigShaping` 常量后重试 |
| 开关弹回关闭 | 大概率是系统 VPN 授权被拒或扩展崩溃；到 设置 → 通用 → VPN与设备管理 检查配置是否存在 |
| 测速全部 `—` | 隧道没连上，或服务商封锁 ICMP/测速 URL；先确认能正常上网 |
| 模拟器编译失败找不到 `Libbox` | 未跑 `build-libbox.sh`，或模拟器切片缺失（需 `iossimulator/arm64`） |
| 连接时报 `unknown outbound type: naive` | 内核默认不含 naive 出站；用 `INCLUDE_NAIVE=1 ./scripts/build-libbox.sh` 重建内核 |

## 7. 许可与合规

本仓库因链接 GPL-3.0 的 sing-box 内核而以 **GPL-3.0-or-later** 分发；
把 `.ipa` 分发给他人时需同时提供源码（本仓库地址即可）。详见 `THIRD_PARTY.md`。
