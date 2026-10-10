# Phase 0 Research: 极简 iOS 代理客户端

**输入**：订阅链接 `https://<订阅域名>/link/<令牌>`（用户提供，等同账号凭证）
**日期**：2026-10-08

## R1. 内核选型：sing-box libbox

**决定**：使用 sing-box `v1.14.2` 的 `libbox`（Apple 平台库），以二进制 xcframework 形式嵌入。

**证据**（实测该订阅服务商的响应，见 R2）：
订阅内容中 **44 个节点全部是 `anytls` 协议**（15 台服务器，端口 1443/777）。
AnyTLS 是 2025 年出现的公开协议（参考实现 [anytls/anytls-go](https://github.com/anytls/anytls-go)，
规范文档给出 TLS 1.3 之上的帧格式与 padding 方案，并明确欢迎第三方实现）。
客户端支持面：sing-box ≥1.12 内置 `anytls` 出站；mihomo（Clash.Meta）同样支持；
Shadowrocket 2.2.78 更新日志中亦有 anytls 相关条目。

**备选方案**：
- mihomo：同样 GPL-3.0，但要自己写 NE 桥接与命令通道；libbox 已经提供官方 Apple 集成
  （`LibboxPlatformInterfaceProtocol` / `LibboxCommandServer` / `LibboxCommandClient`），
  且 sing-box-for-apple 就是可读的参考实现，因此选 libbox。
- 自研 AnyTLS + 用户态 TCP/IP 栈：规范只有约 10 条命令，协议本身不算复杂，
  但 TLS 1.3 客户端 + TUN 用户态 TCP/IP 栈要从零实现，工作量数倍且性能更差，否决。
- 仅用 AnyTLS 的 Go 参考实现：其仓库未挂任何许可证（默认保留所有权利），不能直接引用代码。

**内核构建方式**：上游 `Makefile` 提供 `lib_install`（安装 sagernet/gomobile v0.1.13）与
`go run ./cmd/internal/build_libbox -target apple -platform <target>`。
本项目脚本在此基础上构建 `ios/arm64` 与 `iossimulator/arm64` 两个切片并用上游
`merge_apple_xcframework` 合并为一个 `Libbox.xcframework`。

**踩到的坑（已解决）**：上游 `.github/go_ios_cpu_features.patch` 在 Go 1.27 上只能应用一半——
补丁第二个 hunk 依赖 `cpu_arm64_other.go` 的旧 build tag（Go 1.27 增加了 `&& !windows`），
结果 `osInit` 重复定义导致 `go build` 失败。处理方式：脚本改为直接写入 `cpu_arm64_ios.go`
并把 `cpu_arm64_other.go` 的 tag 改成 `!darwin`，随后用
`GOOS=ios go list internal/cpu` 断言 `cpu_arm64_ios.go` 已生效（否则 iOS 上 AES/SHA 退回软件实现，性能明显下降）。

## R2. 订阅获取格式与 User-Agent

**决定**：请求订阅链接时带 `User-Agent: sing-box/1.14.2`，拿"面向 sing-box 内核的 JSON 配置"；
若返回内容不是 JSON，则按 Clash YAML 解析（兜底）。

**证据**（对同一 URL 更换 User-Agent 的实测结果）：

| User-Agent | HTTP | Content-Type | 体量 | 内容 |
|---|---|---|---|---|
| `curl/8.0`（默认） | 402 | text/html | 16 B | `Payment Required` |
| `Shadowrocket/2.2.60` | 200 | text/yaml | 219 KB | Clash YAML：44 节点、11 策略组、3528 条规则 |
| `ClashforWindows/0.20.39` | 200 | text/yaml | 219 KB | 同上 |
| `sing-box/1.12.0` | 200 | application/json | 13.7 KB | sing-box 配置：`dns`/`inbounds`/`outbounds`/`route`/`experimental` |
| `Surge/5.0` / `Stash/2.5` | 200 | — | — | Surge 配置 / Stash YAML |
| `v2rayN` / `Quantumult X` / `Loon` | 200 | text/plain | 0 B | 不支持该客户端，返回空 |
| `Mozilla/5.0 (iPhone)` | 402 | text/html | 16 B | 与默认一致 |

结论：服务商按 User-Agent 分发配置；只要带上 sing-box 标识就能拿到**可直接喂给内核的完整 JSON**，
客户端几乎不需要做格式翻译。响应头另含 `subscription-userinfo`（upload/download/total/expire）
与 `profile-update-interval: 24`，用于"用量/到期"与自动刷新节流。

## R3. iOS 侧配置整形

**决定**：拿到内核配置后，**替换 `inbounds`** 为 iOS 专用入站（tun + 本地 mixed 端口），
`dns`/`route`/`outbounds`/`experimental` 原样透传。

**理由**：服务商给的 `inbounds` 是给桌面端用的（`address: 172.19.0.1/30`、`mtu: 9000`、
`stack: system`、`auto_route: true`、`strict_route: true`、另有 `127.0.0.1:2333/2334` 的 socks/mixed 入站）。
iOS 上 tun 由网络扩展创建，地址段/路由由系统与 libbox 平台接口协商，直接用桌面参数会起不来或不稳。
整形后的入站固定为：

```json
[
  {"type":"tun","tag":"tun-in","address":["172.19.0.1/30"],"mtu":4064,"auto_route":true,
   "strict_route":false,"stack":"gvisor","sniff":true,"sniff_override_destination":true,
   "endpoint_independent_nat":true,"domain_strategy":"prefer_ipv4"}
]
```

`stack` 采用 `gvisor`：iOS 上没有内核 TCP/IP 栈可用，`system` 栈依赖的
`NEPacketTunnelFlow` 转发路径由平台接口实现，`gvisor` 是上游 Apple 客户端的默认选择，行为最可预期。
`mtu` 取 4064（保守值，避免蜂窝网络下的分片问题）；两项都做成常量，真机验证时可调。

## R4. App ↔ 扩展的控制通道

**决定**：扩展内用 `LibboxSetup` + `LibboxNewCommandServer` 托管服务；
主 App 用 `LibboxNewCommandClient` 订阅状态/线路组，并调用
`selectOutbound(groupTag:outboundTag:)`、`urlTest(outboundTag:)` 完成切换与测速。

**证据**：上游 sing-box-for-apple 的 iOS 客户端就是这一结构——
`ExtensionProvider.startTunnel` 里 `LibboxSetup` → `LibboxNewCommandServer` → `commandServer.start()` →
`commandServer.startOrReloadService(configContent, options:)`；
App 侧 `CommandClient.performConnection` 用 `LibboxNewCommandClient(handler, clientOptions)` 连接，
`commandServerPort/secret` 只在 tvOS 上使用，说明 iOS 侧走的是 App Group 容器内的本地通道。
`LibboxCommandClient` 暴露 `SelectOutbound`、`URLTest`、`ServiceReload`、`SetGroupExpand` 等方法，
恰好覆盖本特性的"选线路 / 测延迟"。

**备选方案（否决）**：用 `sendProviderMessage` 自定义 JSON 协议在扩展里做切换与测速。
可行但要在扩展内再造一层命令分发，且拿不到 libbox 的状态/连接流；
上游通道已现成，故不用。

## R5. 延迟测试的实现口径

**决定**：一次"测速"= 对当前策略组（服务商给的 `节点选择`）发**一次**
`urlTest(groupTag:)`；结果通过 `LibboxCommandGroup` 流里的
`LibboxOutboundGroupItem.urlTestDelay` / `urlTestTime` 按条回流。客户端并发 0（由内核控制），
单条兜底超时 8 秒，整体 20 秒收尾，可取消。

**证据**：`daemon/started_service.go` 的 `URLTest` 实现：
若目标是 `group.URLTest` 则 `CheckOutbounds()`；若是任意 `adapter.OutboundGroup`（含 selector）
则对该组 `All()` 的**全部成员**执行 `group.URLTestOutbounds(...)`；只有对单个出站才只测那一个。
上游 Apple 客户端也是按组调用（`ApplicationLibrary/Views/Groups/GroupListViewModel.doURLTest(tag:)`、
`MacLibrary/StatusBarController` 中的 `isURLTestingAll` 遍历的是**组**tag）。

**修正记录**：本方案初稿按"每条线路各发一次 urlTest"设计（并发上限 8）。核对内核实现后改为"一次测整组"：
44 条线路只需一次调用，既避免 44 次握手把扩展的连接表打满，也不会重复测同一个节点
（`节点选择` 与 `自动选择` 的成员是同一批节点）。

**排序规则**：`urlTestDelay` 升序；`0` 视为"未测/超时"，排在最后；测速过程中按实时结果更新，
不整表重排（避免列表跳动），仅在用户点"按排序"时重排。

## R6. 线路切换的生效方式

**决定**：切换 = 对策略组调用 `selectOutbound(groupTag:outboundTag:)`，**不重启隧道**。

**理由**：`selector` 出站在内核里是热切换，新连接立即走新线路，已建立的连接保持；
若改为改写配置并 `startOrReloadService`，会造成重新拨号（用户可感知"断线"），违反 spec 的 US4。
"自动选择"由服务商配置里已有的 `urltest` 分组承担（本次订阅含 `自动选择`），客户端只需选中它。

## R7. 签名、能力与分发

**决定**：Ad Hoc 分发（收集测试设备 UDID）+ TestFlight 内部测试作为备选。

**要求**：
- 付费 Apple 开发者账号（用户已具备）。
- 两个 target 均需开启 **Network Extensions** 能力；扩展 target 的 `NSExtensionPointIdentifier`
  为 `com.apple.networkextension.packet-tunnel`。
- App Group（`group.<prefix>.trocket`）需在开发者后台注册，两个 target 共用，用于放配置与命令通道。
- 真机调试：网络扩展**无法在 iOS 模拟器运行**（模拟器只有 App 本体可跑），连接/测速/切换必须真机验证。

## R8. 许可证合规

**决定**：本仓库以 **GPL-3.0-or-later** 分发（因链接 GPL-3.0 的 libbox）。
`THIRD_PARTY.md` 记录：sing-box（SagerNet/sing-box v1.14.2，GPL-3.0-or-later，
附"不得用其名称暗示关联"条款）、anytls 协议规范（协议文本，实现不引用）、
构建期工具 XcodeGen（MIT）、gomobile（BSD）。
分发（含把 IPA 传给朋友）时需一并提供本仓库源码。

## R9. 与上游默认标签集的偏差：默认关闭 naive 出站

**决定**：构建内核时默认移除 `with_naive_outbound` 标签（`scripts/build-libbox.sh`，可用
`INCLUDE_NAIVE=1` 打开）。

**理由**（实测）：
naive（naiveproxy）出站会链入 `github.com/sagernet/cronet-go` 预编译的 Chromium Cronet 静态库，
每个切片约 42MB，是内核体积的主要来源；并且 `libcronet.a` 里的
`base::ios::ScopedCriticalAction` 引用了 `UIApplication` 与 `UIBackgroundTaskInvalid`，
这两个符号在 App Extension 中不可用，导致网络扩展链接失败：

```
Undefined symbols for architecture arm64:
  "_OBJC_CLASS_$_UIApplication", referenced from: ... scoped_critical_action.o
  "_UIBackgroundTaskInvalid", referenced from: ...
```

上游 sing-box-for-apple 之所以不受影响，是因为它的扩展链接的是自家动态框架，
未定义符号推迟到运行期解析；本项目扩展直接静态链接 libbox，因此必须在链接期解决。

**影响面**：仅 `naive` 出站不可用。AnyTLS / Shadowsocks / VMess / VLESS / Trojan / Hysteria2 /
TUIC / WireGuard 等仍全部可用（本次订阅为纯 AnyTLS）。
若将来需要 naive，用 `INCLUDE_NAIVE=1 ./scripts/build-libbox.sh` 重建
（`project.yml` 已为扩展保留 `-Wl,-U,_OBJC_CLASS_$_UIApplication` 与 `-Wl,-U,_UIBackgroundTaskInvalid`，
代价是内核体积回升约 84MB 且依赖"该后台任务代码路径不会被调用"这一前提）。

## R10. 服务商配置是旧语法，必须迁移到内核 1.14 的新语法

**问题（真机首次连接时暴露，随后在本地复现）**：服务商对 `sing-box/1.12.0` 与 `sing-box/1.14.2`
返回**同一份旧语法配置**，直接用 1.14.2 内核加载会连续报错：

```
dns.servers[0]: legacy DNS server formats are deprecated in sing-box 1.12.0 and removed in sing-box 1.14.0
outbounds[3]: dns outbound is deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0
initialize inbound[0]: legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0
```

关键判断：**降级内核不是出路**。1.13 已移除 `dns` 出站，1.14 又移除了旧 DNS 与旧入站字段，
而服务商的配置同时用了这三样 —— 只有 1.12 能原样吃下，但 1.12 已停止维护。
因此选择**保留 1.14.2 内核 + 在整形阶段做迁移**（宪法第 II/III 条：内核不重造，代价放在我们这侧）。

**迁移规则**（`Sources/Shared/ConfigMigration.swift`，逐条对照官方 migration 文档）：

| 旧写法 | 新写法 |
|---|---|
| `dns.servers[].address: "https://1.1.1.1/dns-query"` | `{"type":"https","server":"1.1.1.1","path":"…"}`（`/dns-query` 为默认值，省略） |
| `address: "tls://8.8.8.8:853"` / 纯 IP / `local` | `{"type":"tls"\|"udp"\|"local", …}` |
| `address: "rcode://success"`（无新语法等价物） | 丢弃；若被 `dns.rules` 引用，则同时丢弃该规则 |
| `dns.rules[].outbound: ["any"]` | `route.default_domain_resolver: {server: "local", strategy: …}` |
| 出站 `{"type":"dns","tag":"dns-out"}` | 删除，并清理分组里的引用与 `default` |
| 路由规则 `{"outbound":"dns-out","protocol":"dns"}` | `{"protocol":"dns","action":"hijack-dns"}` |
| 入站字段 `sniff` / `sniff_override_destination` / `domain_strategy` 等 | `route.rules[0] = {"action":"sniff"}` + `default_domain_resolver.strategy` |

**验证方式（本机可复现，不需要设备）**：
把 `Sources/Shared/*.swift` 编成一个 macOS 小程序，用真实订阅跑 `ConfigShaping.shape`，
再把输出交给 1.14.2 内核自带的校验器：

```bash
swiftc -O -o /tmp/shapedgen Sources/Shared/*.swift /tmp/main.swift   # main.swift 调 shape 并写文件
(cd build/sing-box && go run -tags "with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api" \
   ./cmd/sing-box check -c /tmp/swift-shaped-real.json)
```

结果：**无错误、无警告**（迁移前同一份配置直接 `FATAL`）。这条校验已作为发版前的固定步骤。

**已知取舍**：`rcode://success`（服务商用来"黑洞"某些域名）在新语法里没有等价服务器类型，
该服务器本身未被任何规则引用，故丢弃；若将来服务商引用了它，需要改用路由 `reject` 动作。

## R11. 国内直连：规则集必须落本地，缺失时兜底补规则

**问题（用户真机反馈）**：连接后国内流量也走代理。定位到三个叠加原因：

1. 应用自己不生成任何分流规则，完全沿用订阅下发的规则；
2. 订阅里的国内直连规则（`rule_set: [geosite-cn, geoip-cn] → direct`）引用的是**远端规则集**
   （GitHub raw），而远端 `rule_set` 由内核在**服务启动时**下载，失败即 FATAL ——
   为不炸，`ConfigMigration` 过去把这类规则集**连同引用它的整条规则**一起摘掉，
   国内直连规则因此消失；
3. 摘除后 `route.final` 缺省，内核按第一个出站（`节点选择`）走，于是全部流量进代理。

**决策**：远端规则集不再一律摘除，而是**先本地化，拿不到才摘除**，并补三层保底：

| 层 | 内容 | 位置 |
|---|---|---|
| 内置保底 | `geosite-cn.srs`、`geoip-cn.srs`（合计 90KB）随包分发 | `Resources/RuleSets/` |
| 联网缓存 | 导入订阅时，主 App 把其余远端规则集并发下载进 App Group 容器（最多 8 个） | `RuleSetStore.prefetch` |
| 兜底规则 | 整形后若没有任何「CN 规则集 → direct」规则，就在规则末尾补一条 | `ConfigShaping.ensureChinaDirectRule` |

改写发生在 `ConfigMigration.localizeRemoteRuleSets`：把 `type: remote` 换成
`{"type":"local","format":"binary","path":"<容器绝对路径>"}`；只有本地确实没有文件时才摘除并提示。
**必须内置的原因**：这两个源在 GitHub raw，国内网络基本不可达，联网下载不能作为唯一路径。

**路径会失效这件事必须处理**：App Group 容器的绝对路径在"删除后重装"时会变，
而 profile.json 里存的是绝对路径 —— 老路径失效会让国内直连规则被静默摘掉（又回到全局代理）。
所以本地化时会先按**文件名**在当前容器里找同名文件修复路径（`RuleSetStore.repairedPath`）；
联网缓存的那些规则集则由 24 小时一次的订阅刷新重新下载并改写。

**路由开关**：菜单提供「规则 / 全局」，走内核 Clash 模式（`LibboxCommandClient.setClashMode`），
不断线生效。订阅一般自带 `clash_mode` 规则，没有的由 `ConfigShaping.ensureClashModeRules` 补
（含 DNS 侧的 `clash_mode: global → remote`）。扩展侧**没有** `setClashMode` 绑定，
所以隧道重启后由两处兜底：主 App 在命令通道连上时补推一次
（`AppModel.pushRoutingModeToKernel`），以及扩展自己在启动服务后自连命令通道下发一次
（`Sources/Tunnel/RoutingModeRestorer.swift`）——后者覆盖"扩展被系统回收后重启、App 不在前台"
这一情形（此时内核会回到默认 `rule`，「全局」会悄悄失效）。启动日志里会留一行
`clash mode restored: rule|global`，真机排查看它即可。

**判定边界（已知限制）**：域名库按域名匹配、IP 库按解析后的地址匹配，国内域名解析到境外 CDN
时会判成"境外"而走代理，反之亦然；DNS 侧同步分流（国内域名用 `223.5.5.5` 直连解析）以降低误判。

**验证方式**：沿用 R10 的本机校验管线（swiftc 生成整形后的配置 → `sing-box check`），
确认内核接受本地规则集与补出来的规则；分流是否真的生效仍需真机按
`specs/001-ios-vpn-client/quickstart.md` 复验。

## R12. 服务商按 UA 返回不同节点集：必须补拉 Clash 模板

**问题（用户反馈）**：同一条订阅链接，Shadowrocket 能列出美国/德国节点，我们列不出。

**实测（同一链接，两次 GET）**：

| 请求 UA | 返回 | 节点 |
|---|---|---|
| `sing-box/1.14.2`（我们的） | sing-box JSON | **32 条**：香港 13、日本 10、新加坡 9 |
| `ClashforWindows/0.20.39` | Clash YAML | **44 条**：同上 + **美国 6、德国 6** |

也就是说：**不是解析问题**——服务商的 sing-box 模板里根本没有那 12 条；
两边共有节点的名字完全一致（所以按 tag 合并是安全的）。

**做法**（`Sources/Shared/NodeSupplement.swift`）：仍以 sing-box 模板为准（保留服务商的分流规则与 DNS），
导入时用 Clash UA 再拉一次，只把 JSON 里没有的节点补进 `outbounds`，
并挂到主选择组（第一个 `selector`）与自动选择组（第一个 `urltest`）上，使它们可选、可测速。
补拉失败、或服务商无视 UA 仍返回 JSON，都只是"没补到"，不影响导入。

**验证**：真实订阅上 32 → 44 条，12 条新节点都在主分组里，合并后的配置通过 `sing-box check`（1.14.2）；
单测 `NodeSupplementTests`（4 项）覆盖合并、去重、无新增、以及"只动 outbounds 不动服务商规则"。
`scripts/diagnose-subscription.py` 可随时复现这个对比。
