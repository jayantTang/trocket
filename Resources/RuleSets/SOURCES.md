# 内置分流规则集

这里是随包内置的 sing-box 二进制规则集（SRS），用于「国内直连」的离线保底：
内核只从本地文件加载规则集，不在服务启动时联网下载（远端下载失败会让内核直接 FATAL）。

| 文件 | 内容 | 来源 | 大小 |
|---|---|---|---|
| `geosite-cn.srs` | 国内域名 | https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs | 56 KB |
| `geoip-cn.srs` | 国内 IP 网段 | https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs | 34 KB |

拉取日期：2026-10-10。更新方式：

```bash
curl -fsSL -o Resources/RuleSets/geosite-cn.srs \
  https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs
curl -fsSL -o Resources/RuleSets/geoip-cn.srs \
  https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs
```

更新后必须重新出包（内置文件按字节数变化触发拷贝，见 `RuleSetStore.ensureBundled`）。
订阅里引用的其它远端规则集不在这里，而是导入时由主 App 下载进 App Group 容器的 `rule-set/` 目录。

> 国内网络访问 GitHub raw 通常不可达，所以这两个文件必须随包分发，不能依赖运行时下载。
