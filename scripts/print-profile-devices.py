#!/usr/bin/env python3
"""打印描述文件里的设备列表，并检查目标设备是否在列。

用法：print-profile-devices.py <embedded.plist> [目标UDID]

Ad Hoc / 开发描述文件都是逐台授权的：目标手机不在列表里，OTA 安装一定失败，
所以这里在打包前先把情况说清楚，避免在手机上看到含糊的"无法安装"。
"""
import plistlib
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: print-profile-devices.py <embedded.plist> [target-udid]", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as handle:
        profile = plistlib.load(handle)
    devices = profile.get("ProvisionedDevices") or []
    entitlements = profile.get("Entitlements") or {}

    print(f"    描述文件: {profile.get('Name')}")
    print(f"    团队: {profile.get('TeamIdentifier')} | 到期: {profile.get('ExpirationDate')}")
    print(f"    能力: {', '.join(sorted(k for k in entitlements if k.startswith('com.apple.developer')))}")
    print(f"    包含设备: {len(devices)} 台")
    for device in devices:
        print(f"      {device}")

    if len(sys.argv) >= 3:
        target = sys.argv[2]
        if not devices:
            print("    WARNING: 这是 App Store/企业类型描述文件，没有设备列表")
        elif target not in devices:
            print(f"    WARNING: 本机这台 iPhone（{target}）不在描述文件里，装到它上面会失败")
        else:
            print(f"    OK: 目标设备 {target} 已在描述文件里")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
