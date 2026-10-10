#!/usr/bin/env python3
"""新建一个 App Store 版本并复制上一版的商店信息（走 App Store Connect API）。

什么时候用：上一版**已经过审/上架**时不能再往它上面挂新构建，只能开新版本；
本脚本把「版本 + 本地化文案 + 截图 + App 审核信息」一次复制过去，省掉在网页上重填。

用法：
  python3 scripts/asc-new-version.py plan 1.1        # 只读：看看会复制什么
  python3 scripts/asc-new-version.py create 1.1      # 真正创建（会写 App Store Connect）

截图默认从 promo/out 取（`promo/make_promo.py` 生成的 1290×2796 三张），可用
SCREENSHOT_DIR 覆盖。创建后还需要：挂构建（asc-submit.py attach-build）→ 送审（resubmit）。
"""
import base64
import importlib.util
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("asc", HERE / "asc.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

APP_ID = asc.APP_ID
COPY_FIELDS = ["description", "keywords", "supportUrl", "marketingUrl", "promotionalText"]
REVIEW_FIELDS = ["contactFirstName", "contactLastName", "contactPhone", "contactEmail",
                 "demoAccountName", "demoAccountPassword", "demoAccountRequired", "notes"]
DISPLAY_TYPE = "APP_IPHONE_67"


def fail(message: str) -> "NoReturn":  # noqa: F821
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def call(method, path, body=None):
    status, payload = asc.call(method, path, body)
    if status >= 300:
        print(f"  HTTP {status} {json.dumps(payload, ensure_ascii=False)[:400]}", file=sys.stderr)
    return status, payload


def versions():
    status, data = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=10")
    return data.get("data", []) if status < 300 else []


def source_version():
    items = versions()
    if not items:
        fail("读不到任何版本")
    return items[0]


def localizations(version_id):
    status, data = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")
    return data.get("data", []) if status < 300 else []


def screenshots(localization_id):
    status, data = call("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets")
    result = []
    for screenshot_set in data.get("data", []):
        if screenshot_set["attributes"].get("screenshotDisplayType") != DISPLAY_TYPE:
            continue
        st, shots = call("GET", f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots")
        result.extend(shots.get("data", []))
    return result


def review_detail(version_id):
    status, data = call("GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    return data.get("data") if status < 300 else None


def screenshot_dir():
    return Path(os.environ.get("SCREENSHOT_DIR", HERE.parent / "promo/out"))


def cmd_plan(version_string: str):
    source = source_version()
    a = source["attributes"]
    print(f"模板版本：{a.get('versionString')}（{a.get('appStoreState')}）")
    print(f"将创建：{version_string}（releaseType={a.get('releaseType')}，copyright={a.get('copyright')}）")
    for loc in localizations(source["id"]):
        la = loc["attributes"]
        shots = screenshots(loc["id"])
        print(f"  本地化 {la.get('locale')}：描述 {len(la.get('description') or '')} 字，"
              f"关键词 {len(la.get('keywords') or '')} 字，截图 {len(shots)} 张")
    detail = review_detail(source["id"])
    if detail:
        notes = (detail["attributes"].get("notes") or "")
        print(f"  App 审核信息：联系人 {detail['attributes'].get('contactFirstName')}，备注 {len(notes)} 字")
    directory = screenshot_dir()
    files = sorted(p.name for p in directory.glob("appstore-*.png")) if directory.exists() else []
    print(f"  截图来源：{directory} → {files}")
    if not files:
        print("  WARNING: 本地没有截图，create 时不会上传截图（商店提交需要至少一张）")


def ensure_screenshot_set(localization_id: str) -> str:
    status, data = call("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets")
    for item in data.get("data", []):
        if item["attributes"].get("screenshotDisplayType") == DISPLAY_TYPE:
            return item["id"]
    status, data = call("POST", "/v1/appScreenshotSets",
                        {"data": {"type": "appScreenshotSets",
                                  "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
                                  "relationships": {"appStoreVersionLocalization": {
                                      "data": {"type": "appStoreVersionLocalizations", "id": localization_id}}}}})
    if status >= 300:
        fail("创建截图集失败")
    return data["data"]["id"]


def upload_screenshot(set_id: str, path: Path):
    size = path.stat().st_size
    status, data = call("POST", "/v1/appScreenshots",
                        {"data": {"type": "appScreenshots",
                                  "attributes": {"fileSize": size, "fileName": path.name},
                                  "relationships": {"appScreenshotSet": {
                                      "data": {"type": "appScreenshotSets", "id": set_id}}}}})
    if status >= 300:
        fail(f"创建截图记录失败：{path.name}")
    screenshot_id = data["data"]["id"]
    payload = path.read_bytes()
    for op in data["data"]["attributes"].get("uploadOperations", []):
        chunk = payload[op["offset"]:op["offset"] + op["length"]]
        import urllib.request
        request = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request, timeout=180) as response:
            response.read()
    call("PATCH", f"/v1/appScreenshots/{screenshot_id}",
         {"data": {"type": "appScreenshots", "id": screenshot_id,
                   "attributes": {"uploaded": True, "sourceFileChecksum": None}}})
    print(f"    截图已上传：{path.name}")


def cmd_create(version_string: str):
    existing = [v["attributes"].get("versionString") for v in versions()]
    if version_string in existing:
        fail(f"版本 {version_string} 已存在（现有：{', '.join(existing)}）")

    source = source_version()
    sa = source["attributes"]
    status, data = call("POST", "/v1/appStoreVersions",
                        {"data": {"type": "appStoreVersions",
                                  "attributes": {"platform": "IOS",
                                                 "versionString": version_string,
                                                 "releaseType": sa.get("releaseType") or "MANUAL",
                                                 "copyright": sa.get("copyright")},
                                  "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    if status >= 300:
        fail("创建版本失败")
    new_id = data["data"]["id"]
    print(f"已创建版本 {version_string}（{new_id}）")

    files = sorted(screenshot_dir().glob("appstore-*.png"))
    for loc in localizations(source["id"]):
        la = loc["attributes"]
        attributes = {"locale": la.get("locale")}
        for field in COPY_FIELDS:
            if la.get(field) is not None:
                attributes[field] = la[field]
        status, data = call("POST", "/v1/appStoreVersionLocalizations",
                            {"data": {"type": "appStoreVersionLocalizations", "attributes": attributes,
                                      "relationships": {"appStoreVersion": {
                                          "data": {"type": "appStoreVersions", "id": new_id}}}}})
        if status >= 300:
            fail(f"复制本地化失败：{la.get('locale')}")
        new_loc_id = data["data"]["id"]
        print(f"  已复制本地化 {la.get('locale')}")
        if files:
            set_id = ensure_screenshot_set(new_loc_id)
            for path in files:
                upload_screenshot(set_id, path)

    detail = review_detail(source["id"])
    if detail:
        attributes = {field: detail["attributes"].get(field) for field in REVIEW_FIELDS
                      if detail["attributes"].get(field) is not None}
        status, _ = call("POST", "/v1/appStoreReviewDetails",
                         {"data": {"type": "appStoreReviewDetails", "attributes": attributes,
                                   "relationships": {"appStoreVersion": {
                                       "data": {"type": "appStoreVersions", "id": new_id}}}}})
        print("  已复制 App 审核信息" if status < 300 else "  WARNING: 复制 App 审核信息失败（可在网页补）")

    print()
    print("下一步：")
    print(f"  1) 上传构建：APPSTORE_API_ISSUER_ID=... ./scripts/upload-testflight.sh")
    print(f"  2) 挂构建并送审：python3 scripts/asc-submit.py attach-build <N> && python3 scripts/asc-submit.py resubmit")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    command, version_string = sys.argv[1], sys.argv[2]
    if command == "plan":
        cmd_plan(version_string)
    elif command == "create":
        cmd_create(version_string)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
