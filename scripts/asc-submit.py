#!/usr/bin/env python3
"""App Store Connect 送审小工具：挂载构建、从审核中移除、重新提交。

与 `asc.py` 共用凭据（`ASC_KEY_ID` / `ASC_ISSUER` 与 ~/.appstoreconnect 下的 .p8）。

用法：
  python3 scripts/asc-submit.py status                  # 版本 / 构建 / 评审提交现状
  python3 scripts/asc-submit.py attach-build 4          # 把 build 4 挂到当前版本上
  python3 scripts/asc-submit.py remove-from-review      # 从审核中移除（清掉在审的提交项）
  python3 scripts/asc-submit.py resubmit                # 新建评审提交并送审

为什么需要它：ASC 网页端的"重新提交以供审核"背后是三个 API 动作
（建 reviewSubmission → 挂版本 → PATCH submitted=true），而且有两条硬限制：
  - 一个版本同时只能挂在一个 reviewSubmission 上（否则 409 ITEM_PART_OF_ANOTHER_SUBMISSION）；
  - 未提交的 reviewSubmission 会占并发额度（上限 5），且 **API 不能删除**（DELETE 403），
    只能先在网页端取消或等 7 天自动过期。
遇到这两条时脚本会把原因打出来，不会硬闯。
"""
import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("asc", HERE / "asc.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

APP_ID = asc.APP_ID


def fail(message: str) -> "NoReturn":  # noqa: F821
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def call(method, path, body=None):
    status, payload = asc.call(method, path, body)
    if status >= 300:
        print(f"  HTTP {status} {json.dumps(payload, ensure_ascii=False)[:400]}", file=sys.stderr)
    return status, payload


def current_version():
    status, data = call("GET", f"/v1/apps/{APP_ID}/appStoreVersions?limit=1")
    if status >= 300 or not data.get("data"):
        fail("读不到 appStoreVersions")
    version = data["data"][0]
    return version["id"], version["attributes"]


def submissions():
    status, data = call("GET", f"/v1/apps/{APP_ID}/reviewSubmissions?limit=50")
    return data.get("data", []) if status < 300 else []


def cmd_status():
    version_id, attrs = current_version()
    print(f"版本 {attrs.get('versionString')}：{attrs.get('appStoreState')}（发布方式 {attrs.get('releaseType')}）")
    status, data = call("GET", f"/v1/appStoreVersions/{version_id}/build")
    build = data.get("data")
    if build:
        a = build["attributes"]
        print(f"已挂构建：build {a.get('version')}（{a.get('processingState')}）")
    else:
        print("已挂构建：无")
    for sub in submissions():
        a = sub["attributes"]
        print(f"评审提交 {sub['id'][:8]}：{a.get('state')} 提交时间 {a.get('submittedDate')}")
        st, items = call("GET", f"/v1/reviewSubmissions/{sub['id']}/items?limit=10")
        for item in items.get("data", []):
            print(f"    item {item['id'][:24]}… state={item['attributes'].get('state')}")


def find_build(number: str):
    status, data = call("GET", f"/v1/builds?filter[app]={APP_ID}&limit=50&sort=-uploadedDate")
    for build in data.get("data", []):
        if str(build["attributes"].get("version")) == str(number):
            return build
    return None


def cmd_attach_build(number: str):
    version_id, attrs = current_version()
    build = find_build(number)
    if not build:
        fail(f"找不到 build {number}（可能还在处理中，稍后重试）")
    print(f"build {number} processingState={build['attributes'].get('processingState')}")
    status, _ = call("PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
                     {"data": {"type": "builds", "id": build["id"]}})
    if status >= 300:
        fail("挂载失败")
    print(f"已把 build {number} 挂到版本 {attrs.get('versionString')} 上")


def cmd_remove_from_review():
    """清掉在审/待审提交里的条目：这就是网页端的"从审核中移除"。"""
    version_id, _ = current_version()
    removed = 0
    for sub in submissions():
        if sub["attributes"].get("state") not in ("WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW"):
            continue
        st, items = call("GET", f"/v1/reviewSubmissions/{sub['id']}/items?limit=20")
        for item in items.get("data", []):
            st, _ = call("DELETE", f"/v1/reviewSubmissionItems/{item['id']}")
            if st < 300:
                removed += 1
                print(f"已移除提交项 {item['id'][:24]}…（提交 {sub['id'][:8]}）")
    if not removed:
        print("没有可移除的提交项")
    return removed


def cmd_resubmit():
    version_id, attrs = current_version()
    if attrs.get("appStoreState") == "WAITING_FOR_REVIEW":
        print("该版本已在等待审核，无需重复提交")
        return

    # 版本若还挂在别的提交上，先把它摘出来
    for sub in submissions():
        if sub["attributes"].get("state") not in ("UNRESOLVED_ISSUES", "READY_FOR_REVIEW"):
            continue
        st, items = call("GET", f"/v1/reviewSubmissions/{sub['id']}/items?limit=20")
        for item in items.get("data", []):
            if item.get("relationships", {}).get("appStoreVersion", {}).get("data", {}).get("id") == version_id:
                st, _ = call("DELETE", f"/v1/reviewSubmissionItems/{item['id']}")
                if st < 300:
                    print(f"已把版本从提交 {sub['id'][:8]} 中摘出")

    status, data = call("POST", "/v1/reviewSubmissions",
                        {"data": {"type": "reviewSubmissions",
                                  "attributes": {"platform": "IOS"},
                                  "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}}}})
    if status >= 300:
        fail("创建评审提交失败（并发额度可能已满：先在网页端取消多余的提交）")
    submission_id = data["data"]["id"]
    print(f"已创建评审提交 {submission_id[:8]}")

    status, _ = call("POST", "/v1/reviewSubmissionItems",
                     {"data": {"type": "reviewSubmissionItems",
                               "relationships": {
                                   "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                                   "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    if status >= 300:
        fail("挂载版本失败（若提示 ITEM_PART_OF_ANOTHER_SUBMISSION，先跑 remove-from-review）")

    status, _ = call("PATCH", f"/v1/reviewSubmissions/{submission_id}",
                     {"data": {"type": "reviewSubmissions", "id": submission_id,
                               "attributes": {"submitted": True}}})
    if status >= 300:
        fail("提交失败（若提示 Version is not ready to be submitted yet，稍后重试或改用网页端提交）")
    print("已提交审核")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    command = sys.argv[1]
    if command == "status":
        cmd_status()
    elif command == "attach-build":
        if len(sys.argv) < 3:
            fail("用法：attach-build <build 号>")
        cmd_attach_build(sys.argv[2])
    elif command == "remove-from-review":
        cmd_remove_from_review()
    elif command == "resubmit":
        cmd_resubmit()
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
