# Contract: 隧道与命令通道

**Version**: 1.0.0 | **Owner**: 主 App（`TunnelController` / `ControlChannel`）+ 扩展（`PacketTunnelProvider`）

## 1. 隧道启动参数（App → 扩展）

`NETunnelProviderProtocol.providerConfiguration`：

| 键 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `configContent` | String | 是 | `profile.json` 的完整文本（整形后的 sing-box 配置） |
| `locale` | String | 否 | 固定 `zh-Hans`，供内核日志本地化 |
| `tunnelVersion` | String | 否 | 内核版本，扩展据此判断配置是否为当前内核生成 |

App 侧每次启动前重新读取 `profile.json` 并写入上述键，避免使用过期配置。
`NETunnelProviderManager.isEnabled = true`、`localizedDescription = "Trocket"`，
首次启动由系统弹出 VPN 授权。

## 2. 扩展启动顺序（`PacketTunnelProvider.startTunnel`）

1. 读取 `providerConfiguration["configContent"]`；缺失 → 抛错"配置缺失，请重新导入订阅"。
2. `LibboxSetupOptions`：`basePath` = App Group 容器路径、`workingPath`/`tempPath` = 其子目录、
   `logMaxLines = 3000`、`debug = false`、`appVersion` = CFBundleVersion。
3. `LibboxSetup(options, &error)`；失败 → 抛错并带上 libbox 的 `localizedDescription`。
4. `LibboxNewCommandServer(platformInterface, platformInterface, &error)` → `start()`。
5. `commandServer.startOrReloadService(configContent, options: LibboxOverrideOptions())`。
6. 之后通过 `platformInterface.openTun` 创建 tun（由 libbox 回调驱动，见第 5 节）。

`stopTunnel`：`commandServer.closeService()` → `platformInterface.reset()` → `commandServer.close()`。

## 3. 命令通道（App ↔ 扩展）

- 扩展侧：`LibboxCommandServer`（由 `LibboxSetup` 的 `basePath` 决定本地通道位置，App Group 内）。
- App 侧：`LibboxNewCommandClient(handler, LibboxCommandClientOptions())`，订阅以下流：
  `LibboxCommandStatus`（状态与流量）、`LibboxCommandGroup`（线路组与延迟）、`LibboxCommandLog`（可选，默认不开）。
- 断开：`client.disconnect()`。

**App 发起的操作**

| 操作 | libbox 调用 | 前置条件 | 失败处理 |
|---|---|---|---|
| 切换线路 | `client.selectOutbound(groupTag, outboundTag:)` | 隧道已连接、组 `selectable` | 界面提示"切换失败：<原因>"，保留原选中项 |
| 测速（整组） | `client.urlTest(groupTag:)`：对 selector/urltest 组会遍历其全部成员，一次调用测完整组 | 隧道已连接 | 未回填的线路标记为 `—`（单条兜底 8s，整体 20s 收尾） |
| 收起/展开组 | `client.setGroupExpand(groupTag, isExpand:)` | 可选 | 忽略错误 |
| 服务重载 | `client.serviceReload()` | 导入新订阅后 | 失败则提示需要重连 |

**扩展推给 App 的事件**（经 `LibboxCommandClientHandlerProtocol`）：
`connected()` / `disconnected(message)` / `writeStatus(LibboxStatusMessage)` /
`writeGroups(LibboxOutboundGroupIterator)`。App 侧只在这些回调里更新 `NodeGroup` 与流量数字，
不做轮询。

## 4. 状态一致性

- App 进入前台、以及 `NETunnelProviderSession` 状态变化通知（`NEVPNStatusDidChange`）时，
  必须重新读取 `manager.connection.status` 刷新 `TunnelState`；命令通道的 `connected/disconnected`
  仅用于补充流量与线路数据。
- 隧道未连接时，命令通道不可用属**正常情况**：不得弹出错误提示，测速/切换按钮置灰。

## 5. 平台接口最小实现（`LibboxPlatformInterfaceProtocol`）

必须实现（其余按协议默认实现留空）：

| 方法 | 实现要点 |
|---|---|
| `openTun(options:ret0_:)` | 由 libbox 传入 tun 参数：构造 `NEPacketTunnelNetworkSettings`（IPv4/IPv6 地址、MTU、DNS、路由），`setTunnelNetworkSettings` 成功后用 `packetFlow` 桥接读写（`LibboxTun` 实现），返回 fd 0 |
| `writeLog(message:)` | 仅在 `debug` 打开时写入 `os_log`；不得写入节点凭据 |
| `underNetworkExtension()` | 返回 `true` |
| `useProcFS()` | 返回 `false` |
| `findConnectionOwner(...)` | 抛"不支持"（iOS 无 procfs；不影响功能） |
| `startDefaultInterfaceMonitor` / `closeDefaultInterfaceMonitor` | 用 `NWPathMonitor` 汇报默认接口，供内核做策略路由 |
| `serviceStop()` / `serviceReload()` | 转发给 `PacketTunnelProvider`（停止/重载服务） |
| `getInterfaces()` | 返回空迭代器（iOS 上内核不依赖） |
| `includeAllNetworks()` | 返回 `false` |

## 6. 内存与稳定性约束

- 扩展内存受限：`logMaxLines = 3000`、不做连接列表的历史缓存、测速并发 ≤8。
- 任何 libbox 抛出错误都必须转成用户可读中文，**不得**直接把 Go 的错误栈贴到界面。
- 连续崩溃保护：若系统在 60 秒内两次以 `NEProviderStopReason.crash` 停止扩展，
  App 下次启动时提示"内核启动失败，请重新导入订阅"，并保留配置不自动重连。
