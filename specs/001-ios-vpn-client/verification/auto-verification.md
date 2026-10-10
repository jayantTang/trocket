# 自动验证记录（本机可复现）

**日期**：2026-10-08
**命令**：`./scripts/verify.sh`
**结论**：**PASS** —— 设备 SDK 编译通过（App + 网络扩展），单元测试 29 个全部通过。

## 1. 设备 SDK 编译

```
xcodebuild build -scheme Trocket -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

- 结果：`PASS`（日志：`build/verify/device-build.log`）
- 覆盖：`Trocket`（主 App）与 `TrocketTunnel`（网络扩展）两个 target 都能为真机 arm64 构建；
  链接 `Vendor/Libbox.xcframework`（sing-box 1.14.2）与 `libresolv.tbd` 成功。
- 过程中修掉的两个真实问题（否则真机也构建不出来）：
  1. `libbox` 的 Go net 包需要 `libresolv` 的 `res_9_*` 符号；
  2. naive 出站带来的 Cronet 引用了扩展里不存在的 `UIApplication`（处理见 research.md R9）。

## 2. 模拟器单元测试

```
xcodebuild test -scheme Trocket -destination 'platform=iOS Simulator,name=iPhone 17'
```

- 结果：`PASS` —— `Executed 29 tests, with 0 failures`（日志：`build/verify/simulator-tests.log`）
- 覆盖范围：订阅解析（真实脱敏夹具：sing-box JSON 32 条线路 / Clash YAML 6 条线路）、
  配置整形（inbounds 替换、缺出站与空组报错）、格式嗅探、错误分类、用量头解析与格式化、
  延迟排序与阈值、测速批次（全部回填即结束 / 未回填超时收尾 / 取消后不再回调）、
  状态机文案与非法迁移、App Group 读写与原子覆盖。
- 测试过程中发现并修正的真实缺陷：未回填线路的进度上报曾按"全部完成"收尾（测试先失败后修好）。

## 3. 模拟器界面验证（证据：`verification/images/`）

网络扩展无法在模拟器运行，但**界面与数据链路**可以在模拟器上验：
用 ad-hoc 签名构建 App（`CODE_SIGN_IDENTITY="-"`，并手动带上 App Group entitlement），
把脱敏订阅夹具写进模拟器的 App Group 容器后启动。

| 截图 | 场景 | 观察到什么 |
|---|---|---|
| `images/simulator-empty-state.png` | 无订阅 | 单屏结构：状态卡 + 空状态引导 + 底部连接开关；测速/排序在无线路时置灰 |
| `images/simulator-node-list.png` | 已导入订阅 | 33 条（32 线路 + "自动选择（按延迟）"，默认选中）；顶部显示"已用 1.44 GB / 200 GB 到期 2027-03-04"；未测线路显示 `—` |
| `images/simulator-routing-menu.png` | 菜单展开（默认规则模式） | 「路由模式」分组下两项都在：「规则（国内直连）✓」带对勾、「全局（全部走线路）」不带 |
| `images/simulator-routing-global.png` | 切到全局 | 对勾移到「全局（全部走线路）✓」，列表与开关状态不受影响 |
| `images/simulator-routing-global-after-relaunch.png` | 杀进程重开 | 仍是「全局（全部走线路）✓」——模式通过 App Group 持久化 |
| `images/simulator-routing-rule-restored.png` | 切回规则 | 对勾回到「规则（国内直连）✓」 |

后四张由 `./scripts/verify-ui.sh` 自动产出（`TrocketUITests` 目标，见 2026-10-10 那节）：
仿真器**拒绝启动带 `packet-tunnel-provider` 能力的包**（POSIX 163），脚本会把 entitlements
覆盖成「只有 App Group」再跑，截图从 `.xcresult` 导出（`simctl io screenshot` 只能拍到桌面壁纸）。

界面验证中修掉的一处真实缺陷：本地已有配置但系统尚未建立 VPN 配置时，状态卡显示"未导入订阅"
（与列表内容矛盾），已改为显示"未连接"。

**这套截图不能证明什么**：不能证明能连上、能测出延迟、能切换——那三件事必须真机。

**关于「路由模式」这两张**：只能证明菜单渲染、选项互斥与持久化；
「切全局后所有流量真的走线路」「规则模式下国内真的直连」必须真机（第 8 节第 8–10 项）。

## 4. 未覆盖（必须真机，见宪法第 V 条）

| 项 | 为什么模拟器验不了 |
|---|---|
| 连接/断开、系统 VPN 配置、授权流程 | Packet Tunnel 扩展在模拟器不可用 |
| 测速真实数值、切换线路不闪断、出口 IP 变化 | 同上，且需要真实订阅与网络 |
| 杀进程重开后状态与系统一致 | 同上 |
| SC-006 耗电、SC-008 与商业客户端速率对照 | 需要真机长时间测量 |

真机步骤与记录模板：`quickstart.md` 第 3 节 + `verification/device-verification-template.md`。

## 5. OTA 安装（2026-10-08 生成）

- 签名团队：`<TEAM_ID>`（登录 Xcode 的账号）；Bundle：`com.jayanttang.trocket` / `.tunnel`；
  App Group：`group.com.jayanttang.trocket`；开发描述文件到期 2027-10-08。
- 描述文件内含 2 台设备：`<iPhone UDID>`（iPhone 15，本机配对）、`<iPad UDID>`（iPad）。
- 产物：`build/ota/Trocket.ipa`（42MB，Release，含内嵌网络扩展）。
- 托管：本机 `python3 -m http.server 8899` + `cloudflared tunnel`（临时公网 https，链接随隧道关闭失效）。
- 复现：`TEAM_ID=<TEAM_ID> BUNDLE_PREFIX=com.jayanttang ./scripts/make-ota.sh`。
- 前置条件（本次真实踩到）：① Xcode 登录账号；② 开发者后台同意最新 Program License Agreement，
  否则报 `PLA Update available …`，无法创建带 App Groups/网络扩展能力的描述文件。
- 未验证：手机上是否真正安装成功、首次连接是否成功——需装机人回报。

## 6. 真机反馈与修复（2026-10-08/09）

真机是唯一能暴露下面这些问题的环节；逐条记录现象、根因与修法，避免下次重复踩。

| # | 现象（真机上报） | 根因 | 修法 | 现在的证据 |
|---|---|---|---|---|
| 1 | 状态栏与弹窗都是 `permission denied`（读取/启动隧道都失败） | 主 App 只声明了 App Groups，**缺 `com.apple.developer.networking.networkextension`**；`NETunnelProviderManager` 因此在读取 VPN 配置时被系统拒绝 | `project.yml` 给主 App 目标补上 `packet-tunnel-provider`（与上游 sing-box-for-apple 主 App 一致） | 重新出包后该报错消失；IPA 内 `embedded.mobileprovision` 已含该能力 |
| 2 | 补了权限后开关**灰掉**、无法打开 | 状态文案已按"本地有配置"显示"未连接"，但开关可用性仍用 `TunnelState.canToggle`（`.unconfigured` → false）判断 | 新增 `AppModel.canToggleConnection`（有配置即可开，连接中/切换中除外）；出错后调 `refreshState()` 避免卡在"连接中" | 单测覆盖状态文案；真机待复验 |
| 3 | 连接会因配置加载失败（尚未到达该步，但本地已复现） | 服务商下发的是 **1.11/1.12 旧语法**配置，而内核 1.14.2 已移除旧 DNS 写法、`type=dns` 出站与入站 `sniff`/`domain_strategy` | 新增 `ConfigMigration`：DNS 服务器升格、`dns-out` → `hijack-dns`、入站嗅探 → 路由 `sniff` 动作、`default_domain_resolver`；并去掉出站里的旧字段 | **用真实订阅 + 真实 Swift 代码产出配置，交给 1.14.2 的 `sing-box check`：无错误无警告**（迁移前同一份配置直接 FATAL）；新增 5 个迁移单测 |
| 4 | 订阅体积/语法迁移提示 | — | 导入结果的提示信息合并"跳过线路数"与"迁移处数" | 单测 `SubscriptionInfoTests`/`ConfigShapingTests` 间接覆盖 |

**当前自动验证口径**：`./scripts/verify.sh` → 设备 SDK 编译（App + 扩展）+ 34 个单元测试全过。
**仍未验证**：连接是否真的通、延迟数值、切换是否不闪断 —— 需要真机复验（步骤见 quickstart 第 3 节）。

## 7. 第二轮真机问题与修复（2026-10-09）

| # | 现象 | 根因（证据） | 修法 |
|---|---|---|---|
| 5 | 点开开关后**立刻弹回** | 服务商配置里 DNS 服务器写了 `detour: "direct"`，而 `direct` 出站没有任何选项；内核在**启动服务**时报 `start dns/https[local]: detour to an empty direct outbound makes no sense` 并 FATAL。`sing-box check` 只校验语法，**只有真跑才会炸** —— 本机用同一份配置 `sing-box run` 100% 复现 | `ConfigMigration` 去掉指向"空 direct 出站"的 detour + 回归单测 |
| 6 | （同类隐患，未爆发但必然爆） | 服务商的 remote rule_set 在服务启动时下载，失败即 FATAL；本机实测下载经代理也超时 | `stripUnavailableRemoteRuleSets`：没有本地文件的远端规则集连同引用规则一起摘掉，并在导入提示里告知 |

**仿真器能力边界（有硬证据）**：带 `com.apple.developer.networking.networkextension` 的包，iOS 仿真器
**拒绝启动**（`FBSOpenApplicationServiceErrorDomain code=1 / FBProcessExit code=64 / POSIX 163`）；
把该 entitlement 去掉后立刻能启动（同一份包、同一台仿真器）。因此"在仿真器里运行系统级 VPN"不可行，
仿真器只能验证 App 侧逻辑；真实连接必须真机（见第 3 节与设备日志）。

**验证补强**：新增 38 个单测（含 detour 回归、rule_set 摘除、探针配置、平均时延）；新增
`-TrocketAutoConnect` / `-TrocketAutoLatency` 调试启动参数，用于有线脚本化验证（无需人手点击）。

## 8. 国内直连与「规则 / 全局」开关（2026-10-10）

**问题（用户真机反馈）**：连接后国内流量也走代理。定位见 research.md R11：
订阅里的国内直连规则引用**远端** `rule_set`，内核启动时下载失败即 FATAL，因此过去把
规则集连同引用规则一起摘掉 —— 国内直连规则消失，剩余流量按第一个出站走，于是全部进代理。

**修复**：远端规则集先本地化、拿不到才摘除（`ConfigMigration.localizeRemoteRuleSets`）；
内置 `geosite-cn` / `geoip-cn` 离线保底（`Resources/RuleSets/`，随包分发）；
导入时主 App 并发缓存其余远端规则集进 App Group 容器（`RuleSetStore.prefetch`）；
订阅缺国内直连规则时兜底补一条（`ConfigShaping.ensureChinaDirectRule`）；
新增「规则 / 全局」开关，走内核 Clash 模式，切换不断线（`RoutingMode` + `LibboxCommandClient.setClashMode`）。

**本机证据（不需要设备）**

| 检查 | 命令/方式 | 结果 |
|---|---|---|
| 设备 SDK 编译 + 模拟器单测 | `./scripts/verify.sh` | PASS：设备编译通过；**49 个单测全过**（新增 16 个：规则集改写/兜底/模式开关/Clash 生成） |
| 整形后的真实订阅配置 | `swiftc` 编译 `Sources/Shared/*.swift` + 生成器 → `sing-box check`（1.14.2，本机构建） | **CHECK OK**；规则集已改写为容器内本地文件 |
| Clash 兜底转换路径 | 同上 | **CHECK OK**；生成的配置首次带有国内直连与 `clash_mode` 规则 |
| 最坏情况（订阅无任何规则） | 同上 | **CHECK OK**；自动补出「CN → direct」与 `clash_mode` 规则 |
| 规则集确实被内核读取（反证） | 把 `geosite-cn.srs` 移走后重跑 `check` | **FATAL: open …/rule-set/geosite-cn.srs: no such file or directory**；还原后 OK |
| 仿真器界面：模式菜单 | `./scripts/verify-ui.sh`（新增 `TrocketUITests` 目标 + `Tests/TrocketUITests/RoutingModeMenuUITests.swift`） | **PASS**：菜单两项都在、切换后对勾正确、杀进程重开后保留；截图见第 3 节 `simulator-routing-*.png` |

**仍未验证（需要真机）**：国内站点是否真的直连、切「全局」后出口 IP 是否变化、
国内 App 是否正常 —— 步骤见 quickstart 第 3 节第 8–10 项；结果待补记。
