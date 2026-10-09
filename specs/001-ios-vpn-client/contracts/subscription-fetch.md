# Contract: 订阅拉取与配置整形

**Version**: 1.0.0 | **Owner**: 主 App（`SubscriptionStore`）

## 请求

```http
GET <用户粘贴的订阅链接>
User-Agent: sing-box/1.14.2
Accept: */*
```

- 不做重定向以外的改写；不允许非 `http/https`。
- 超时：连接 10s、整体 30s。
- 不携带任何设备标识、不附带统计参数；**不**把链接转发到任何第三方。

## 响应判定

| 响应 | `sourceFormat` | 后续处理 |
|---|---|---|
| `Content-Type: application/json` 且能 `JSONSerialization` 解析、含 `outbounds` | `.singboxJSON` | 直接整形（见下） |
| 其他 2xx 且首字符为 `{` 且含 `outbounds` | `.singboxJSON` | 同上（部分服务商 Content-Type 不准） |
| 2xx 且文本含 `proxies:` | `.clashYAML` | 走兜底解析：抽取 `proxies:` 下的行内映射，生成最小 sing-box 配置 |
| 2xx 且空体 | — | 报错"该链接未返回内容" |
| 非 2xx | — | 按状态码报错（402/403/404 等） |

## 响应头（可选，用于用量展示）

```
subscription-userinfo: upload=<bytes>; download=<bytes>; total=<bytes>; expire=<unix-seconds>
profile-update-interval: 24
```

缺失时 `userInfo` 为 `nil`，界面隐藏用量区域（**不得**显示 0）。

## 整形规则（`shaping`）

1. 保留 `dns`、`route`、`experimental`、`outbounds` 原样。
2. **先迁移旧语法**（`ConfigMigration`，规则见 research.md R10）：
   内核 1.13/1.14 已移除旧 DNS 写法、`type=dns` 出站与入站 `sniff`/`domain_strategy` 字段，
   服务商目前仍在下发这些写法，不迁移会直接加载失败。迁移必须在替换入站**之前**做，
   因为 `sniff` 写在入站里、要转成 `route.rules[0] = {"action":"sniff"}`。
3. **替换** `inbounds` 为 iOS 专用集合：
   - `tun-in`：`type=tun`、`address=["172.19.0.1/30"]`、`mtu=4064`、`auto_route=true`、
     `strict_route=false`、`stack="gvisor"`、`endpoint_independent_nat=true`。
     注意：**不含** `sniff` / `sniff_override_destination` / `domain_strategy`（1.13 起入站不再支持，
     嗅探与域名解析策略移到路由层）。
   - 不保留服务商给的 `127.0.0.1:2333/2334` 本地入站（iOS 上无消费者，且会多开监听）。
4. 校验必须存在至少一个 `type=selector` 或 `type=urltest` 的出站；否则判定"订阅中没有可用线路"。
5. 输出为紧凑 JSON（无空白美化），写入 App Group `profile.json`（原子写）。
6. 整形失败时**不得**覆盖已有 `profile.json`；迁移发生时应把迁移条目数带回界面提示。

## Clash YAML 兜底（`clashYAML`）

只支持 Clash 系常见的行内流式映射（`- { name: ..., type: ..., server: ..., port: ... }`）：

- 提取字段：`name`、`type`、`server`、`port`、`password`、`uuid`、`cipher`、`sni`、
  `skip-cert-verify`、`udp`。
- 支持类型到 sing-box 出站的映射：`anytls`、`ss`、`vmess`、`vless`、`trojan`。
- 生成的配置使用本项目默认 `dns`（阿里/腾讯 DoH + fake-ip）与 `route`（`final: 节点选择`），
  生成一个 `selector` 组 `节点选择` 与一个 `urltest` 组 `自动选择`。
- 无法识别的行（缩进块格式、YAML 锚点/别名）跳过并计数；跳过数 > 0 时在导入结果里提示
  "有 N 条线路无法解析"。

## 失败契约

任何失败都必须：① 返回可读中文原因（见 data-model 错误分类表）；② 保留上一次成功的配置；
③ 不改变当前选中线路与连接状态。
