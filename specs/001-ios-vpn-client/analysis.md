# Analysis Report: 极简 iOS 代理客户端

**Feature**: `specs/001-ios-vpn-client` | **Date**: 2026-10-08
**Artifacts**: spec.md · plan.md · tasks.md · contracts/ · data-model.md · research.md
**Constitution**: `.specify/memory/constitution.md` v1.0.0

## Findings

| ID | 类别 | 严重度 | 位置 | 问题 | 处理 |
|---|---|---|---|---|---|
| A1 | 任务与实现不一致 | 中 | tasks.md T014 ↔ ClashYAML.swift | 任务写"块式格式被跳过并计数"，实际实现支持简单块式映射（可解析），跳过的只有"不支持类型"与"缺字段"两种 | 已修正 tasks.md T014 的描述与断言口径（跳过数=2） |
| A2 | 需求未覆盖测量 | 中 | spec.md SC-006 / SC-008 | 耗电占比、与商业客户端的速率对照，均无对应任务与可复现测量步骤 | 已在 tasks.md T038 与 verification 模板中列为"待真机 + 对照客户端"，未验证前不得视为达标 |
| A3 | 覆盖缺口（测试） | 中 | spec.md FR-012、FR-009 | `AppModel` 属于 App target，未纳入单元测试；线路记忆与状态以系统为准这两条只有真机验证覆盖 | 保留为真机验收项（quickstart 第 3 节步骤 6/7），在 T038 中逐条核对 |
| A4 | 覆盖缺口（测试） | 低 | spec.md FR-016 | 24 小时自动刷新：`SubscriptionRecord.needsRefresh` 已单测；`SubscriptionService.refreshIfNeeded` 的调度路径未单测（依赖 store 与网络） | 记录为已知覆盖缺口，不影响验收；后续可注入 fake store 补测 |
| A5 | 任务描述超出实现 | 低 | tasks.md T025 | 任务要求"测速中的脉冲态"动画，实现只有"已测/总数"进度文本 —— 与宪法第 VI 条"无多余动效"冲突 | 已修正 T025 为进度文本，去掉脉冲态要求 |
| A6 | 术语一致性 | 低 | data-model.md §3 ↔ 实现 | 文档用"NodeItem.delay"，实现同名；"线路/节点"两种叫法在中文文案里混用 | 界面统一用"线路"，文档保留 `Node*` 类型名，不改代码 |
| A7 | 契约与实现一致性 | 通过 | contracts/tunnel-control.md §2 | 扩展启动顺序与 `PacketTunnelProvider.startTunnel` 逐步一致（Setup → CommandServer → start → startOrReloadService） | 无需处理 |
| A8 | 契约与实现一致性 | 通过 | contracts/subscription-fetch.md | UA、超时、格式嗅探、整形规则、失败保留旧配置均与 `SubscriptionService` / `ConfigShaping` 一致 | 无需处理 |
| A9 | 宪法第 V 条 | 阻塞验收 | tasks.md T017/T023/T028/T032/T038 | 连接、测速、切换、杀进程恢复必须在真机验证；本机无设备连接，无法由 agent 完成 | 已在这些任务上标注"待真机验证"，交付说明中明确列出 |
| A12 | 真机暴露的缺失能力 | 高 | project.yml ↔ 主 App entitlements | 主 App 未声明 `com.apple.developer.networking.networkextension`，`NETunnelProviderManager` 直接 `permission denied` | 已修复并重新出包（见 verification/auto-verification.md §6-1） |
| A13 | 真机暴露的界面逻辑 bug | 中 | AppModel/RootView | 开关可用性用 `TunnelState.canToggle` 判断，而系统尚无 VPN 配置时状态是 `.unconfigured`，导致开关永远灰掉 | 已改为 `canToggleConnection`（§6-2） |
| A14 | 内核升级导致的配置不兼容 | 高 | ConfigShaping / ConfigMigration | 服务商仍下发 1.11/1.12 旧语法，内核 1.14.2 已移除相关字段，直接加载 FATAL | 新增迁移并用 `sing-box check` 验证（§6-3、research R10） |
| A11 | 设计在实现阶段修正 | 中 | spec/plan 初稿 ↔ LatencyRunner.swift | 初稿按"每条线路各发一次 urlTest（并发 8）"设计；核对内核 `URLTest` 实现后发现对 selector/urltest 组会遍历全部成员，改为一次调用测完整组 | research R5 重写、contracts/data-model/tasks 同步；单元测试改为断言"全部回填即结束/未回填超时收尾" |
| A10 | 内核构建偏差 | 中 | research.md R1 ↔ scripts/build-libbox.sh | 内核标签集与上游默认不同：默认移除 `with_naive_outbound`（Cronet，每切片 42MB，且引用扩展不可用的 UIApplication） | 已在 research.md R9 记录偏差、理由与开关（`INCLUDE_NAIVE=1`）；THIRD_PARTY/README 同步说明 |

## Requirement → Task → Artifact 覆盖

| 需求 | 覆盖任务 | 实现产物 | 验证方式 | 状态 |
|---|---|---|---|---|
| FR-001 粘贴与保存链接 | T012, T015 | `SubscriptionService`、`SubscriptionSheet` | 单测（错误分类）+ 真机 | 部分（真机待验证） |
| FR-002 拉取并给可读原因、不覆盖旧配置 | T012 | `SubscriptionService`、`TrocketError` | 单测（402/403/空体/超时/无法识别） | 已覆盖 |
| FR-003 兼容 sing-box JSON 与 Clash YAML | T012–T014 | `ConfigShaping`、`ClashYAML` | 单测（真实夹具 32/6 条线路） | 已覆盖 |
| FR-004 提取线路与用量 | T013, T016 | `ConfigShaping.catalog`、`SubscriptionUserInfo` | 单测 | 已覆盖 |
| FR-005 列表与选中态 | T015, T029 | `RootView`、`NodeRow` | 模拟器 + 真机 | 部分 |
| FR-006 并发测速 20 秒内 | T024 | `LatencyRunner` | 单测（并发上限、收尾）+ 真机计时 | 部分 |
| FR-007 测速不阻塞、可取消 | T024, T027 | `LatencyRunner`、`AppModel` | 单测（取消后不再回调） | 已覆盖（交互手感待真机） |
| FR-008 连接开关 | T018–T022 | `TunnelController`、`PacketTunnelProvider` | 真机 | 待真机验证 |
| FR-009 状态以系统为准 | T020 | `TunnelController.refreshState` | 真机（杀进程/后台恢复） | 待真机验证 |
| FR-010 连接中切换不闪断 | T029 | `ControlChannel.selectOutbound` | 真机（出口 IP 变化） | 待真机验证 |
| FR-011 自动选择 | T030 | `NodeCatalog.automaticGroup` + selector 切换 | 真机 | 待真机验证 |
| FR-012 记住选中线路 | T031 | `AppModel`（UserDefaults） | 真机重启 | 待真机验证 |
| FR-013 系统 VPN 配置表现 | T020 | `NETunnelProviderManager` | 真机（设置 → VPN） | 待真机验证 |
| FR-014 不上报第三方 | T007, T012 | 无第三方 SDK；仅请求订阅链接 | 代码审查 | 已覆盖 |
| FR-015 500 条线路流畅 | T025, T027 | `List` 懒加载 + 单行更新 | 真机（当前订阅 44 条） | 未测（无 500 条样本） |
| FR-016 手动/自动刷新 | T033, T034 | `needsRefresh`、`refreshIfNeeded` | 单测（窗口计算） | 部分 |
| SC-001…SC-005 | 见上 | — | 真机计时 | 待真机验证 |
| SC-006 耗电、SC-008 速率对照 | — | — | 真机 + 对照客户端 | 待验证（A2） |

## 宪法对齐

| 条款 | 结论 |
|---|---|
| I 本地优先 | 通过：无第三方 SDK；订阅内容只写 App Group；日志默认关闭 |
| II 极简可用 | 通过：单屏四件事；T025 的动画要求已删除（A5） |
| III 内核不重造 | 通过（含偏差 A10：仅移除 naive 出站，协议核心未改） |
| IV 许可证合规 | 通过：`LICENSE` + `THIRD_PARTY.md`；分发需附源码 |
| V 真机验证优先 | **未完成**：T017/T023/T028/T032/T038 待真机，交付中显式标注 |
| VI 简约即性能 | 通过：无动效堆砌、并发上限、批量刷新 |

## Metrics

- 需求覆盖：16 条 FR 中 9 条已有自动化覆盖，7 条需真机或存在部分缺口
- 任务完成度：33 个任务中 24 个完成（代码与自动验证），5 个真机任务待执行，4 个前置任务已完成
- 术语一致性：通过（A6 已在文案层统一）
- 契约一致性：通过（A7/A8）
- 未决问题：0 个（无 [NEEDS CLARIFICATION]）

## 结论

自动验证范围内无阻塞项；**唯一未完成的是宪法第 V 条要求的真机端到端验证**
（连接、测速、切换、重启恢复），本机无可用设备，必须由持有人按 quickstart 第 3 节执行。
在此之前的交付状态应描述为"编译与单元测试通过，真机待验证"，不得描述为"已验证可用"。
