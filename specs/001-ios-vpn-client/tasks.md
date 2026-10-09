# Tasks: 极简 iOS 代理客户端（订阅加载 / 延迟测试 / 线路选择）

**Feature**: `specs/001-ios-vpn-client` | **Date**: 2026-10-08
**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)
**Constitution**: `.specify/memory/constitution.md` v1.0.0

**图例**：`[P]` = 可与同阶段其它标记任务并行；`[USn]` = 归属用户故事；
`⛔` = 需要真机；`(verify: …)` = 该任务的验证方式。

---

## Phase 1: Setup（工程骨架与构建链）

- [x] **T001** 建仓库骨架：`.gitignore`（忽略 `build/`、`Vendor/`、`*.xcodeproj`、`DerivedData/`）、
  目录 `Sources/{App,Tunnel,Shared}`、`Tests/TrocketTests`、`Resources`、`scripts/`
  (verify: `git status` 干净、目录存在)
- [x] **T002** [P] 许可证与来源声明：`LICENSE`（GPL-3.0 全文）、`THIRD_PARTY.md`
  （sing-box v1.14.2 / GPL-3.0-or-later + 名称条款、XcodeGen MIT、gomobile BSD）
  (verify: 文件存在且含版本号)
- [x] **T003** 内核构建脚本 `scripts/build-libbox.sh`
  (verify: 产出 `Vendor/Libbox.xcframework`，含 `ios-arm64` 与 `iossimulator-arm64` 两个切片)
- [x] **T004** `scripts/bootstrap.sh`：校验内核存在 → 自动探测 Team ID（`security find-identity`，
  可被 `TEAM_ID` 覆盖）→ 调 `xcodegen generate`
  (verify: 无参数运行能生成 `Trocket.xcodeproj`)
- [x] **T005** `scripts/verify.sh`：① 设备 SDK 编译（`CODE_SIGNING_ALLOWED=NO`）
  ② 模拟器单测（iPhone 17）③ 打印判定摘要
  (verify: 输出 `PASS/FAIL` 与失败首行错误)
- [x] **T006** `project.yml`：两个 target（`Trocket` / `TrocketTunnel`）、
  `TrocketTunnel` 的 `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`、
  两个 target 共享 `Sources/Shared`、App Group `group.$(BUNDLE_PREFIX).trocket`、
  链接 `Vendor/Libbox.xcframework`、iOS 15.0、Swift 语言模式 5
  (verify: `xcodegen generate` 成功且 `xcodebuild -list` 能看到两个 scheme)

## Phase 2: Foundational（共享模型，先于所有故事）

- [x] **T007** [P] `Sources/Shared/AppConfiguration.swift`：App Group id、bundle id、
  `kernelUserAgent = "sing-box/1.14.2"`、`configFileName`、`subscriptionFileName`
  (verify: 单测断言 App Group id 以 `group.` 开头且与 `project.yml` 一致)
- [x] **T008** [P] `Sources/Shared/TunnelStatus.swift`：状态枚举 + 合法迁移校验 + 中文文案映射
  (verify: 单测覆盖非法迁移被拒绝、每个状态都有非空文案)
- [x] **T009** [P] `Sources/Shared/NodeList.swift`：`NodeGroup` / `NodeItem`、
  延迟排序（nil/0 排最后、稳定排序）、延迟颜色分级
  (verify: 单测 `NodeSortingTests`)
- [x] **T010** `Sources/Shared/ProfileDocument.swift` + `ConfigShaping`：读取/原子写入 App Group、
  订阅 JSON 整形（替换 inbounds、校验存在 selector/urltest）
  (verify: 单测 `ConfigShapingTests`，用真实订阅样本做固定输入)
- [x] **T011** 测试夹具：把当前订阅的 sing-box JSON（脱敏：去掉 server/password）与
  Clash YAML 片段存为 `Tests/Fixtures/`（verify: 单测可加载）

## Phase 3: US1 — 导入订阅并看到线路列表 (P1) 🎯 MVP

- [x] **T012** [US1] `Sources/App/SubscriptionStore.swift`：HTTP 拉取（UA 见 T007、超时 10/30s）、
  状态码与空体分类、`subscription-userinfo` 解析、原子落盘、失败保留旧配置
  (verify: 单测用 `URLProtocol` stub 覆盖 200 JSON / 200 空 / 402 / 403 / 超时)
- [x] **T013** [US1] sing-box JSON 解析：`outbounds` → 线路组与线路、`selector.selected` 选中项
  (verify: 真实订阅样本解析出 44 条线路，组名含 `节点选择`/`自动选择`)
- [x] **T014** [US1] Clash YAML 兜底：解析 `proxies:` 行内流式映射与简单块式映射（anytls/ss/vmess/vless/trojan），
  生成最小 sing-box 配置，统计跳过条数
  (verify: 单测覆盖 5 种类型 + 块式 1 条可解析 + 不支持类型与缺字段各 1 条被计数)
- [x] **T015** [US1] 界面：`RootView`（状态卡 + 线路列表）、`SubscriptionSheet`（粘贴 + 导入 + 错误展示）
  (verify: 模拟器运行，能看到列表；无订阅时显示引导文案)
- [x] **T016** [US1] 用量展示：已用/总量/到期，缺失时整块隐藏
  (verify: 单测断言缺失 header 时 `userInfo == nil` 且视图模型隐藏该区块)
- [ ] **T017**（⛔ 待真机验证） [US1] ⛔ 真机验收：quickstart 第 3 节步骤 1、6
  (verify: `specs/001-ios-vpn-client/verification/us1-import.md` 记录)

## Phase 4: US2 — 一键连接并正常上网 (P1)

- [x] **T018** [US2] `Sources/Tunnel/PacketTunnelProvider.swift`：`LibboxSetup` →
  `LibboxNewCommandServer` → `startOrReloadService`；`stopTunnel` 反向清理
  (verify: 设备 SDK 编译通过 + 真机日志出现 libbox 启动信息)
- [x] **T019** [US2] `Sources/Tunnel/PlatformInterface.swift`：按 contracts/tunnel-control.md 第 5 节
  实现 `openTun`（`NEPacketTunnelNetworkSettings` + packetFlow 桥接）、日志、
  接口监视、serviceStop/serviceReload
  (verify: 真机连接成功即证明 tun 建立正确；编译期覆盖协议一致性)
- [x] **T020** [US2] `Sources/App/TunnelController.swift`：`NETunnelProviderManager` 装载/保存/
  启动/停止、首次授权、`NEVPNStatusDidChange` 转发
  (verify: 真机开关能改变系统 VPN 状态；模拟器上按钮置灰不崩溃)
- [x] **T021** [US2] `Sources/App/ControlChannel.swift`：`LibboxCommandClient` 订阅 status/group 流，
  实现 `LibboxCommandClientHandlerProtocol`
  (verify: 真机连接后界面显示流量与线路组)
- [x] **T022** [US2] 界面连接开关 + 状态文案 + 失败原因展示
  (verify: 模拟器覆盖文案；真机覆盖成功/拒绝授权两条路径)
- [ ] **T023**（⛔ 待真机验证） [US2] ⛔ 真机验收：quickstart 第 3 节步骤 3、7
  (verify: `verification/us2-connect.md`)

## Phase 5: US3 — 测速与按延迟挑选 (P2)

- [x] **T024** [US3] `Sources/Shared/LatencyRunner.swift`：批次登记与收尾（20s 截止、单条兜底超时、
  可取消、旧批次按 generation 丢弃），发起一次 `urlTest(groupTag:)` 测完整个策略组
  (verify: 单测断言全部回填即结束、未回填按超时收尾、取消后不再回调)
- [x] **T025** [US3] `NodeRow` 延迟展示（`—`/绿/黄/红；不做动画，符合宪法第 VI 条）
  (verify: 单测断言三档阈值；模拟器核对渲染)
- [x] **T026** [US3] 测速按钮、"按延迟排序"动作、进度提示（已测/总数）
  (verify: 单测排序规则；模拟器核对交互)
- [x] **T027** [US3] 测速不影响连接与滚动（回调只在主线程批量刷新，不整表重建）
  (verify: 真机 44 条线路测速期间滚动流畅，连接不中断)
- [ ] **T028**（⛔ 待真机验证） [US3] ⛔ 真机验收：quickstart 第 3 节步骤 2
  (verify: `verification/us3-latency.md`，含"20 秒内出结果"的实测秒数)

## Phase 6: US4 — 切换线路 (P2)

- [x] **T029** [US4] `selectOutbound` 调用 + 失败回滚（保留原选中项并提示）
  (verify: 单测覆盖失败分支；真机切换生效)
- [x] **T030** [US4] "自动选择（按延迟）"条目（对应 `urltest` 组），与手动选中互斥
  (verify: 真机选中后状态保持连接)
- [x] **T031** [US4] 选中项持久化（`UserDefaults(suiteName:)`），重启恢复
  (verify: 单测 + 真机杀进程重开)
- [ ] **T032**（⛔ 待真机验证） [US4] ⛔ 真机验收：quickstart 第 3 节步骤 4、5
  (verify: `verification/us4-switch.md`，含出口 IP 变化证据)

## Phase 7: US5 — 用量与到期 (P3)

- [x] **T033** [US5] 用量格式化（GB/MB、到期日 `yyyy-MM-dd`）与 24 小时自动刷新节流
  (verify: 单测格式化边界：0 字节、缺失、跨月日期)
- [x] **T034** [US5] 启动时按 `importedAt` 判断是否刷新，失败静默（不打扰已连接状态）
  (verify: 单测时间推进；真机改系统时间后确认只刷新一次)

## Phase 8: Polish（收尾与验收）

- [x] **T035** [P] `README.md`：项目定位、架构图、构建步骤、目录说明、限制说明（GPL/真机要求）
- [x] **T036** [P] 一致性检查（/speckit-analyze 等价）：spec 的 FR/SC 逐条对应 tasks 与代码，
  输出 `analysis.md`
- [x] **T037** `scripts/verify.sh` 全量跑通并留结果（设备编译 + 模拟器单测）
- [ ] **T038**（⛔ 待真机验证） ⛔ 交付验收记录：汇总 4 份真机验证记录 + SC-001～SC-008 逐条结论，
  未在真机验证的项明确标注（宪法第 V 条要求）

---

## 依赖关系

- T003 → T004/T006 → 所有编译类任务
- T007–T011 → T012–T016、T018–T026
- T018/T019 → T020/T021 → T022 → T023
- T024 → T025/T026/T027 → T028
- T029/T030/T031 → T032
- 所有 → T036/T037/T038

## MVP 建议

先交付 **T001–T017 + T018–T023**（US1+US2）：能导入、能连上，就已经是可用的最小产品；
US3（测速）与 US4（切换）紧随其后，US5（用量）最后。

## 待真机验证清单（宪法第 V 条）

| 任务 | 依赖条件 |
|---|---|
| T017 / T023 / T028 / T032 / T038 | 付费开发者账号 + 真机 + 有效订阅 + Ad Hoc 或开发签名 |


---

## 执行状态（2026-10-08）

- 已完成：T001–T016、T018–T022、T024–T027、T029–T031、T033–T037（代码 + 自动验证）。
- 待真机：T017、T023、T028、T032、T038 —— 本机无可用设备，按宪法第 V 条**不得**标记为完成。
- 偏差记录：内核默认关闭 `with_naive_outbound`（见 research.md R9）；影响面与开关已写明。
- 自动验证结果与判定见 `verification/auto-verification.md`。
