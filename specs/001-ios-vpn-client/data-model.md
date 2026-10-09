# Phase 1 Data Model: 极简 iOS 代理客户端

存储位置：App Group 容器 `group.<prefix>.trocket`（两个 target 共享）。
运行时内存模型只在主 App 进程；扩展进程只持有 libbox 服务与启动参数。

## 1. SubscriptionRecord（订阅元数据）

| 字段 | 类型 | 说明 | 校验 |
|---|---|---|---|
| `url` | String | 用户粘贴的订阅链接 | 必须能解析为 `http`/`https`；否则导入前拒绝 |
| `importedAt` | Date | 最近一次成功导入时间 | 用于 24 小时自动刷新节流 |
| `sourceFormat` | enum | `.singboxJSON` / `.clashYAML` | 由响应 Content-Type 与内容嗅探决定 |
| `userInfo.upload` | Int64 | 已上传字节（响应头 `subscription-userinfo`） | ≥0；缺失则整块为 nil |
| `userInfo.download` | Int64 | 已下载字节 | 同上 |
| `userInfo.total` | Int64 | 套餐总量字节 | 同上 |
| `userInfo.expire` | Date | 到期时间（Unix 秒换算） | 同上 |
| `nodeCount` | Int | 解析出的线路数 | >0 才算导入成功 |

持久化：`subscription.json`。**不存**原始订阅内容（原始内容整形后写入 `profile.json`，避免重复占空间）。

## 2. KernelProfile（喂给内核的配置）

| 字段 | 类型 | 说明 |
|---|---|---|
| `json` | Data | 整形后的 sing-box 配置（inbounds 已替换为 iOS 版，见 contracts/subscription-fetch.md） |
| `writtenAt` | Date | 落盘时间 |
| `kernelVersion` | String | 生成时的内核版本（`1.14.2`），升级内核后旧配置作废重建 |

持久化：`profile.json`（原子写：先写临时文件再 `replaceItemAt`，避免半写坏配置）。
启动隧道时整段文本经 `NETunnelProviderProtocol.providerConfiguration["configContent"]` 传给扩展。

## 3. NodeGroup / NodeItem（线路组与线路）

来自 libbox 命令流的 `LibboxOutboundGroup` / `LibboxOutboundGroupItem`，只保留界面需要的字段。

**NodeGroup**

| 字段 | 类型 | 说明 |
|---|---|---|
| `tag` | String | 组名，如 `节点选择`、`自动选择` |
| `type` | String | `selector` / `urltest` |
| `selected` | String | 当前选中项 tag |
| `selectable` | Bool | 是否允许用户切换 |
| `items` | [NodeItem] | 组内线路 |

**NodeItem**

| 字段 | 类型 | 说明 |
|---|---|---|
| `tag` | String | 线路名，如 `[Normal x0.5] 香港 01` |
| `type` | String | 出站类型（本订阅为 `anytls`） |
| `delay` | UInt16? | 最近一次延迟毫秒；`nil`/`0` 表示未测或超时 |
| `testedAt` | Date? | 该延迟的采集时间 |

界面只展示**用户可选的组**：优先 `selector` 且 `selectable == true` 的组（本订阅为 `节点选择`），
`urltest` 组（`自动选择`）作为列表里的一个特殊条目"自动选择（按延迟）"呈现。

**派生规则**：
- 排序：`delay` 升序，`nil`/超时排最后，同延迟按原始顺序稳定排序。
- 展示：`delay == nil` → `—`；`1...200` → 绿；`201...500` → 黄；`>500` → 红。
- 选中：`group.selected == item.tag`。

## 4. TunnelState（隧道状态）

```text
unconfigured  ← 无订阅或配置缺失
disconnected
connecting
connected(connectedAt: Date, upload: Int64, download: Int64)
reasserting   ← 系统重建隧道（切网）
failed(message: String)
```

**状态来源**：以 `NETunnelProviderManager.connection.status` 为准，命令通道的流量数据仅作补充。
界面文本映射：`unconfigured`→"未导入订阅"、`disconnected`→"未连接"、`connecting`→"连接中"、
`connected`→"已连接 · 已用 1.2 MB"、`reasserting`→"网络切换中"、`failed`→具体原因。

**合法迁移**：`disconnected → connecting → connected|failed`；`connected → disconnected`（用户关闭或系统回收）；
`connected → reasserting → connected`。任何非法迁移（如没有 `connecting` 直接 `connected`）
由 `TunnelState` 的构造函数拒绝并记录日志。

## 5. LatencyRun（一次测速）

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID | 批次标识，用于丢弃过期回调 |
| `startedAt` | Date | 开始时间 |
| `groupTag` | String | 被测的策略组 |
| `pending` | Set<String> | 尚未回填的线路 tag（逐条超时兜底 8s） |
| `issuedGroup` | String? | 已发起测速的策略组 tag（客户端只发一次，并发由内核控制） |
| `deadline` | Date | `startedAt + 20s`，到点后未回的项标记超时 |
| `cancelled` | Bool | 用户取消或界面离开 |

同一时间**只允许一个** `LatencyRun`；发起新的会取消旧的（旧批次的回调按 `id` 丢弃）。

## 6. 校验与错误分类

| 场景 | 判定 | 用户可见文案 |
|---|---|---|
| URL 非法 | 本地校验 | 订阅链接格式不正确 |
| 网络不可达 | `URLError` | 网络不可用，请检查连接 |
| HTTP 402 | 状态码 | 服务商返回 402：订阅已到期或欠费 |
| HTTP 403/404 | 状态码 | 服务商拒绝访问（403/404），请核对链接 |
| 200 但空体 | 解析 | 该链接未返回内容，可能不支持当前客户端标识 |
| 内容无法解析 | 解析 | 订阅内容无法识别（既不是 sing-box JSON 也不是 Clash 配置） |
| 线路数为 0 | 解析 | 订阅中没有可用线路 |
| 模板缺失 `outbounds` | 整形 | 订阅内容缺少线路定义 |

失败时**保留**上一次成功的 `profile.json` 与 `subscription.json`，并把失败原因放入 `lastError` 供界面展示。
