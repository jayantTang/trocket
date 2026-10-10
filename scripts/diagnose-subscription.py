#!/usr/bin/env python3
"""对比同一订阅链接在不同客户端 UA 下返回的节点/分组差异，定位"某些地区的节点看不到"。

用法：
  python3 scripts/diagnose-subscription.py '<订阅链接>'

为什么会不一样：服务商按 UA 返回不同模板（我们带 `sing-box/1.14.2`，Shadowrocket 走 Clash 格式），
模板里的节点集与分组可能不同；另外我们只把**第一个可手选分组**铺到界面上，
若美国/德国节点在别的分组里，界面就看不到。

只读：只发两次 GET，不写任何东西；链接是凭证，用完可在服务商后台重置。
"""
import json
import re
import subprocess
import sys
from collections import Counter

# 与 Sources/Shared/ClashYAML.swift 的 makeOutbound 保持一致
CLASH_SUPPORTED = {"anytls", "ss", "shadowsocks", "vmess", "vless", "trojan"}
GROUP_TYPES = {"selector", "urltest", "direct", "block", "dns"}


def fetch(url: str, ua: str, timeout: int = 40) -> tuple[int, str, str]:
    """用 curl 拉（本机 python 的 TLS 会被代理中途重置，curl 正常）。"""
    out = subprocess.run(
        ["curl", "-g", "-sS", "--max-time", str(timeout), "-A", ua, "-o", "/tmp/.diag-sub", "-w", "%{http_code}|%{content_type}", url],
        capture_output=True, text=True)
    if out.returncode != 0:
        return 0, "", out.stderr.strip()[:200]
    status, _, content_type = out.stdout.partition("|")
    body = open("/tmp/.diag-sub", "rb").read().decode("utf-8", errors="replace")
    return int(status or 0), content_type, body


def region_of(tag: str) -> str:
    cleaned = re.sub(r"\[[^\]]*\]", "", tag).strip()
    return cleaned.split()[0] if cleaned.split() else tag


def analyze_json(body: str, label: str):
    data = json.loads(body)
    outbounds = data.get("outbounds") or []
    types = Counter(o.get("type") for o in outbounds)
    groups = [o for o in outbounds if o.get("type") in ("selector", "urltest")]
    nodes = [o for o in outbounds if o.get("type") not in GROUP_TYPES]
    member_tags = set()
    for g in groups:
        member_tags.update(g.get("outbounds") or [])
    orphan = [n.get("tag") for n in nodes if n.get("tag") not in member_tags]

    print(f"—— {label}（sing-box JSON，{len(outbounds)} 个出站）——")
    print("  类型分布:", dict(types))
    for g in groups:
        regions = Counter(region_of(t) for t in (g.get("outbounds") or []))
        summary = "、".join(f"{name}×{count}" for name, count in regions.most_common(8))
        print(f"  分组 {g.get('tag')}（{g.get('type')}）成员 {len(g.get('outbounds') or [])}：{summary}")
    print("  节点地区（全部）:", dict(Counter(region_of(n.get('tag', '')) for n in nodes)))
    if orphan:
        print("  ⚠️ 不属于任何分组的节点:", orphan)

    primary = next((g for g in groups if g.get("type") == "selector"), groups[0] if groups else None)
    if primary:
        members = primary.get("outbounds") or []
        shown = [t for t in members if t in {n.get("tag") for n in nodes}]
        print(f"  → 我们界面显示的是分组「{primary.get('tag')}」的 {len(shown)} 条线路，地区:",
              dict(Counter(region_of(t) for t in shown)))
        hidden = [n.get("tag") for n in nodes if n.get("tag") not in set(members)]
        if hidden:
            print(f"  ⚠️ 有 {len(hidden)} 条节点不在该分组里（界面看不到）:", hidden[:10])
    return {"nodes": [n.get("tag") for n in nodes], "primary": list(primary.get("outbounds") or []) if primary else []}


def analyze_clash(body: str, label: str):
    # 只看 proxies: 段（proxy-groups 里的 select/url-test 是分组，不是节点）
    match = re.search(r"(?ms)^proxies:\s*(.*?)(?=^\S|\Z)", body)
    block = match.group(1) if match else body
    pairs = re.findall(r"-\s*\{\s*name:\s*['\"]?([^,'\"]+)['\"]?\s*,\s*type:\s*([a-z0-9-]+)", block)
    if not pairs:
        pairs = re.findall(r"name:\s*['\"]?([^'\"\n]+)['\"]?.*?type:\s*([a-z0-9-]+)", block)
    group_types = {"select", "url-test", "fallback", "load-balance", "relay"}
    names = [(n.strip(), t) for n, t in pairs if t not in group_types]
    print(f"—— {label}（Clash YAML，proxies 段 {len(names)} 个节点）——")
    print("  类型分布:", dict(Counter(t for _, t in names)))
    unsupported = [(n, t) for n, t in names if t.split("-")[0] not in CLASH_SUPPORTED]
    if unsupported:
        print(f"  ⚠️ 我们不支持的协议 {len(unsupported)} 条（会被跳过）:", unsupported[:10])
    print("  地区:", dict(Counter(region_of(n) for n, _ in names)))
    return {"nodes": [n for n, _ in names], "unsupported": unsupported}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    url = sys.argv[1]
    results = {}
    for label, ua in [("我们（sing-box UA）", "sing-box/1.14.2"),
                      ("Shadowrocket（Clash UA）", "Shadowrocket/2.2.40 (iPhone; iOS 18.0)")]:
        status, content_type, body = fetch(url, ua)
        if status != 200 or not body:
            print(f"—— {label}: 拉取失败 status={status} {content_type} {body[:120]}")
            continue
        print(f"—— {label}: HTTP {status} | {content_type} | {len(body)} 字节")
        text = body.lstrip()
        if text.startswith("{"):
            results[label] = analyze_json(body, label)
        else:
            results[label] = analyze_clash(body, label)
        print()

    keys = list(results)
    if len(keys) == 2:
        ours, theirs = results[keys[0]]["nodes"], results[keys[1]]["nodes"]
        missing = [n for n in theirs if n not in ours]
        print("== 结论 ==")
        print(f"  我们有 {len(ours)} 条，Shadowrocket 那份有 {len(theirs)} 条；差集 {len(missing)} 条: {missing[:10]}")
        primary = results[keys[0]].get("primary") or []
        in_primary = [n for n in missing if n in primary]
        if missing and not in_primary and primary:
            print("  差集里没有一条落在我们界面的主分组里 → 多半是「只显示主分组」的问题")
        elif missing:
            print("  差集落在主分组里 → 更可能是我们解析/整形环节丢了节点")


if __name__ == "__main__":
    main()
