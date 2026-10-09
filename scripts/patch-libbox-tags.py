#!/usr/bin/env python3
"""从 sing-box 的 build_libbox 工具里摘掉 with_naive_outbound（Apple 构建用）。

原因见 specs/001-ios-vpn-client/research.md R9：naive 出站会链入 Chromium Cronet，
既让内核体积翻倍，又引用 App Extension 里不存在的 UIApplication / UIBackgroundTaskInvalid。

用法：patch-libbox-tags.py <path/to/cmd/internal/build_libbox/main.go>
幂等：已经摘掉时返回 0 并提示。
"""
import pathlib
import re
import sys

TAG = '"with_naive_outbound"'


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch-libbox-tags.py <main.go>", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    lines = path.read_text().splitlines(keepends=True)
    patched = False
    for index, line in enumerate(lines):
        if "sharedTags = append(sharedTags" in line and TAG in line:
            lines[index] = re.sub(r"\s*" + re.escape(TAG) + r",?", "", line, count=1)
            patched = True
            break
    if not patched:
        remaining = any("sharedTags = append(sharedTags" in line and TAG in line for line in lines)
        if remaining:
            print("cannot patch with_naive_outbound", file=sys.stderr)
            return 1
        print("with_naive_outbound already removed")
        return 0
    path.write_text("".join(lines))
    print("removed with_naive_outbound from sharedTags")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
