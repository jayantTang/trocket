#!/usr/bin/env python3
"""App Store Connect API 小工具（Trocket 用）

用法：
  python3 scripts/asc.py call GET /v1/apps
  python3 scripts/asc.py agerating          # 年龄分级全部填「无」
  python3 scripts/asc.py screenshots <目录>  # 上传 6.7 英寸截图（目录内按文件名排序）
  python3 scripts/asc.py status             # 打印当前元数据填充状态

凭据：~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8（默认 <ASC_KEY_ID>）
Issuer：环境变量 ASC_ISSUER，默认 <ASC_ISSUER_ID>
"""
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

KEY_ID = os.environ.get("ASC_KEY_ID", "<ASC_KEY_ID>")
ISSUER = os.environ.get("ASC_ISSUER", "<ASC_ISSUER_ID>")
APP_ID = "6820968247"
INFO_ID = "1cf4ae91-e18d-499f-8881-ca9446d48ecc"
KEY_PATH = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")
API = "https://api.appstoreconnect.apple.com"


def token() -> str:
    key = serialization.load_pem_private_key(open(KEY_PATH, "rb").read(), password=None)
    b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
    hdr = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}, separators=(",", ":")).encode())
    pl = b64(json.dumps({"iss": ISSUER, "iat": int(time.time()), "exp": int(time.time()) + 900,
                         "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    si = hdr + b"." + pl
    r, s = decode_dss_signature(key.sign(si, ec.ECDSA(hashes.SHA256())))
    return (si + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()


TOK = token()


def call(method: str, path: str, body=None, retries: int = 4):
    data = json.dumps(body).encode() if body else None
    last = None
    for attempt in range(retries):
        req = urllib.request.Request(API + path, data=data, method=method,
                                     headers={"Authorization": f"Bearer {TOK}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read().decode()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read().decode() or "{}")
        except (urllib.error.URLError, ssl.SSLError, TimeoutError) as e:  # 网络抖动重试
            last = e
            time.sleep(2 + attempt * 2)
    raise SystemExit(f"请求失败：{method} {path}：{last}")


def version_id() -> str:
    _, d = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=1")
    return d["data"][0]["id"]


def age_rating():
    _, d = call("GET", f"/v1/appInfos/{INFO_ID}/ageRatingDeclaration")
    ar = d.get("data", {})
    arid = ar.get("id")
    skip = {"kidsAgeBand", "developerAgeRatingInfoUrl", "ageRatingOverride", "ageRatingOverrideV2",
            "koreaAgeRatingOverride", "gracRatingClassificationNumber"}
    fields = [k for k in (ar.get("attributes") or {}) if k not in skip]
    bools = {"advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
             "parentalControls", "unrestrictedWebAccess", "ageAssurance", "socialMedia",
             "socialMediaAgeRestricted", "userGeneratedContent"}
    types = {k: ("BOOL" if k in bools else "STR") for k in fields}
    for _ in range(25):
        attrs = {k: (False if types[k] == "BOOL" else "NONE") for k in fields}
        st, d = call("PATCH", f"/v1/ageRatingDeclarations/{arid}",
                     {"data": {"type": "ageRatingDeclarations", "id": arid, "attributes": attrs}})
        if st < 300:
            return "年龄分级：已全部填「无」"
        changed = False
        for e in d.get("errors", []):
            f = (e.get("source") or {}).get("pointer", "").split("/")[-1]
            det = e.get("detail", "")
            if f in types and "Expected a STRING" in det and types[f] != "STR":
                types[f] = "STR"; changed = True
            elif f in types and "Expected a BOOLEAN" in det and types[f] != "BOOL":
                types[f] = "BOOL"; changed = True
        if not changed:
            return f"年龄分级：失败 {json.dumps(d.get('errors', [])[:1], ensure_ascii=False)[:200]}"
    return "年龄分级：超过重试次数"


def status():
    _, d = call("GET", f"/v1/appInfos/{INFO_ID}/appInfoLocalizations")
    for L in d.get("data", []):
        a = L["attributes"]
        print(f"名称/副标题({a.get('locale')}): {a.get('name')} / {a.get('subtitle')} | 隐私政策: {bool(a.get('privacyPolicyUrl'))}")
    vid = version_id()
    _, d = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    for L in d.get("data", []):
        a = L["attributes"]
        print(f"描述 {len(a.get('description') or '')} 字 | 关键词 {len(a.get('keywords') or '')} | "
              f"支持URL {bool(a.get('supportUrl'))} | 宣传文本 {len(a.get('promotionalText') or '')}")
        _, s = call("GET", f"/v1/appStoreVersionLocalizations/{L['id']}/appScreenshotSets")
        print("  截图集:", [(x["attributes"].get("screenshotDisplayType"),
                            len(x.get("relationships", {}).get("appScreenshots", {}).get("data", []) or []))
                           for x in s.get("data", [])] or "（空）")
    _, d = call("GET", f"/v1/appStoreVersions/{vid}")
    print("版权:", d["data"]["attributes"].get("copyright"), "| 发布方式:", d["data"]["attributes"].get("releaseType"),
          "| 状态:", d["data"]["attributes"].get("appStoreState"))


def upload_screenshots(folder: str):
    """上传 6.7 英寸（1290×2796）截图。"""
    files = sorted(f for f in os.listdir(folder) if f.lower().endswith(".png"))
    if not files:
        raise SystemExit(f"{folder} 里没有 PNG")
    vid = version_id()
    _, d = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")
    lid = d["data"][0]["id"]
    _, d = call("GET", f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets")
    display = "APP_IPHONE_67"
    sid = next((x["id"] for x in d.get("data", []) if x["attributes"].get("screenshotDisplayType") == display), None)
    if not sid:
        st, d = call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})
        if st >= 300:
            raise SystemExit(f"建截图集失败：{st} {json.dumps(d)[:200]}")
        sid = d["data"]["id"]
    print("截图集:", sid)

    for name in files:
        path = os.path.join(folder, name)
        size = os.path.getsize(path)
        st, d = call("POST", "/v1/appScreenshots", {"data": {"type": "appScreenshots",
            "attributes": {"fileSize": size, "fileName": name},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sid}}}}})
        if st >= 300:
            print(f"  {name}: 建记录失败 {st} {json.dumps(d)[:160]}"); continue
        shot = d["data"]["id"]
        for op in d["data"]["attributes"].get("uploadOperations", []):
            with open(path, "rb") as fh:
                fh.seek(op["offset"])
                chunk = fh.read(op["length"])
            req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
            for h in op.get("requestHeaders", []):
                req.add_header(h["name"], h["value"])
            try:
                with urllib.request.urlopen(req, timeout=180) as resp:
                    resp.read()
            except urllib.error.HTTPError as e:
                print(f"  {name}: 分片上传失败 {e.code}"); break
        st, d = call("PATCH", f"/v1/appScreenshots/{shot}", {"data": {"type": "appScreenshots",
            "id": shot, "attributes": {"uploaded": True, "sourceFileChecksum": None}}})
        print(f"  {name}: {'已上传' if st < 300 else f'提交失败 {st} {json.dumps(d)[:160]}'}")


def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    cmd = sys.argv[1]
    if cmd == "call":
        st, d = call(sys.argv[2], sys.argv[3], json.loads(sys.argv[4]) if len(sys.argv) > 4 else None)
        print(st, json.dumps(d, ensure_ascii=False)[:1500])
    elif cmd == "agerating":
        print(age_rating())
    elif cmd == "status":
        status()
    elif cmd == "screenshots":
        upload_screenshots(sys.argv[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
