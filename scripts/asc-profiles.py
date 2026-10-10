#!/usr/bin/env python3
"""App Store 描述文件：列出 / 补齐 / 安装到本机（走 App Store Connect API）。

为什么需要：这台机器没有登录 Xcode 账号，云签名走不通（见 README「分发」一节），
导出只能用手工签名，而手工签名要求本机装有对应的 **App Store 描述文件**。
团队里此前只有 DSH 那套（bundle id 不同，不能通用），Trocket 的两张由本脚本创建。

用法：
  python3 scripts/asc-profiles.py list      # 列出现有描述文件（含类型与 uuid）
  python3 scripts/asc-profiles.py ensure    # 缺哪张建哪张，并安装到本机

凭据与 asc.py 相同：ASC_KEY_ID / ASC_ISSUER 与 ~/.appstoreconnect 下的 .p8。
"""
import base64
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("asc", HERE / "asc.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

# 需要 App Store 描述文件的目标：bundle id → 描述文件名（导出配置按名字引用）
TARGETS = [
    ("com.jayanttang.trocket", "Trocket App Store"),
    ("com.jayanttang.trocket.tunnel", "Trocket Tunnel App Store"),
]
PROFILE_DIR = Path.home() / "Library/MobileDevice/Provisioning Profiles"
LOCAL_PROFILE_DIR = Path(__file__).resolve().parent.parent / "build/appstore/profiles"


def fail(message: str) -> "NoReturn":  # noqa: F821
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def call(method, path, body=None):
    status, payload = asc.call(method, path, body)
    if status >= 300:
        print(f"  HTTP {status} {json.dumps(payload, ensure_ascii=False)[:400]}", file=sys.stderr)
    return status, payload


def distribution_certificate():
    status, data = call("GET", "/v1/certificates?limit=50")
    if status >= 300:
        fail("读不到证书列表")
    certs = [c for c in data.get("data", [])
             if c["attributes"].get("certificateType") == "DISTRIBUTION"]
    if not certs:
        fail("团队里没有分发证书：先按 19_dsh_iosapp/scripts/release/asc-dist-signing.mjs 签一张")
    return certs[0]


def bundle_id(identifier: str) -> str:
    status, data = call("GET", f"/v1/bundleIds?filter[identifier]={identifier}")
    for item in data.get("data", []):
        if item["attributes"].get("identifier") == identifier:
            return item["id"]
    fail(f"App Store Connect 里没有 bundle id {identifier}")


def profiles():
    status, data = call("GET", "/v1/profiles?limit=100")
    return data.get("data", []) if status < 300 else []


def install_profile(content_b64: str, uuid: str, identifier: str) -> Path:
    raw = base64.b64decode(content_b64)
    LOCAL_PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    local = LOCAL_PROFILE_DIR / f"{identifier}.mobileprovision"
    local.write_bytes(raw)
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    installed = PROFILE_DIR / f"{uuid}.mobileprovision"
    installed.write_bytes(raw)
    return installed


def cmd_list():
    for profile in profiles():
        a = profile["attributes"]
        print(f"{a.get('name')} | {a.get('profileType')} | {a.get('profileState')} | {a.get('uuid')}")


def cmd_ensure():
    cert = distribution_certificate()
    print(f"分发证书：{cert['attributes'].get('displayName')}（{cert['id']}，{cert['attributes'].get('expirationDate')} 到期）")
    existing = {(p["attributes"].get("name"), p["attributes"].get("profileType")): p for p in profiles()}
    for identifier, name in TARGETS:
        profile = existing.get((name, "IOS_APP_STORE"))
        if profile is None:
            body = {"data": {"type": "profiles",
                             "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                             "relationships": {
                                 "bundleId": {"data": {"type": "bundleIds", "id": bundle_id(identifier)}},
                                 "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}}
            status, data = call("POST", "/v1/profiles", body)
            if status >= 300:
                fail(f"创建描述文件失败：{identifier}")
            profile = data["data"]
            print(f"已创建描述文件：{name}")
        a = profile["attributes"]
        path = install_profile(a["profileContent"], a["uuid"], identifier)
        print(f"已安装 {name} → {path}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    command = sys.argv[1]
    if command == "list":
        cmd_list()
    elif command == "ensure":
        cmd_ensure()
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
