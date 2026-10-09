#!/usr/bin/env bash
# Build Libbox.xcframework (sing-box core for Apple platforms) from source.
#
# Produces: Vendor/Libbox.xcframework with ios/arm64 + iossimulator/arm64 slices.
# Requires: go (>= sing-box go.mod requirement), xcodebuild/Command Line Tools, network.
#
# Notes:
#  - GOPROXY defaults to goproxy.cn because proxy.golang.org is unreachable here.
#  - Go's internal/cpu does not detect ARM64 crypto features on GOOS=ios, so
#    AES/SHA fall back to generic code. We apply upstream's patch to a *copy* of
#    GOROOT (never to the Homebrew-managed one) to keep hardware AES.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SING_BOX_VERSION="${SING_BOX_VERSION:-v1.14.2}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/build}"
SRC_DIR="${BUILD_DIR}/sing-box"
GOROOT_COPY="${BUILD_DIR}/goroot-ios"
SLICES="${BUILD_DIR}/libbox-slices"
OUT="${ROOT}/Vendor/Libbox.xcframework"
TARGETS=("ios/arm64" "iossimulator/arm64")

export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB=off
export GOTOOLCHAIN=local

log() { printf '\n=== %s ===\n' "$*"; }

command -v go >/dev/null || { echo "go not found (brew install go)"; exit 1; }

log "clone sing-box ${SING_BOX_VERSION}"
if [ ! -d "${SRC_DIR}/.git" ]; then
  mkdir -p "${BUILD_DIR}"
  git clone --depth 1 --branch "${SING_BOX_VERSION}" https://github.com/SagerNet/sing-box "${SRC_DIR}"
fi

log "prepare patched GOROOT copy (hardware AES/SHA on iOS)"
REAL_GOROOT="$(go env GOROOT)"
if [ ! -f "${GOROOT_COPY}/src/internal/cpu/cpu_arm64_ios.go" ]; then
  rm -rf "${GOROOT_COPY}"
  cp -R "${REAL_GOROOT}" "${GOROOT_COPY}"
  CPU_DIR="${GOROOT_COPY}/src/internal/cpu"
  # Upstream's patch adds this file; it is not in Go 1.27 yet.
  cat > "${CPU_DIR}/cpu_arm64_ios.go" <<'GO'
// Copyright 2020 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

//go:build arm64 && ios

package cpu

func osInit() {
	ARM64.HasAES = true
	ARM64.HasPMULL = true
	ARM64.HasSHA1 = true
	ARM64.HasSHA2 = true
}
GO
  # ... and changes the generic fallback tag, which gained "&& !windows" in Go 1.27,
  # so the upstream .patch file no longer applies. Do the equivalent edit here.
  python3 - "${CPU_DIR}/cpu_arm64_other.go" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(r"(?m)^//go:build arm64 && !linux && !freebsd && !android && \(!darwin \|\| ios\) && !openbsd( && !windows)?$")
new_text, count = pattern.subn(lambda m: "//go:build arm64 && !linux && !freebsd && !android && !darwin && !openbsd" + (m.group(1) or ""), text)
if count != 1:
    sys.exit("cannot locate the arm64 fallback build tag in cpu_arm64_other.go")
path.write_text(new_text)
PY
fi
export GOROOT="${GOROOT_COPY}"
go version
IOS_CPU_FILES="$(GOOS=ios GOARCH=arm64 CGO_ENABLED=0 go list -f '{{.GoFiles}}' internal/cpu)"
case "${IOS_CPU_FILES}" in
  *cpu_arm64_ios.go*) echo "ios internal/cpu: hardware crypto enabled" ;;
  *) echo "ERROR: ios internal/cpu patch ineffective: ${IOS_CPU_FILES}" >&2; exit 1 ;;
esac

log "install gomobile (sagernet fork)"
make -C "${SRC_DIR}" lib_install
export PATH="${PATH}:$(go env GOPATH)/bin"
command -v gomobile

# naive 出站会把 Chromium Cronet（每个切片约 42MB 静态库）链进内核，而它是唯一引用了
# UIApplication / UIBackgroundTaskInvalid 的组件 —— 网络扩展里这两个符号不可用，
# 链接会失败。本项目默认不编译 naive 出站（AnyTLS/SS/VLESS/VMess/Trojan/Hysteria2 等不受影响）。
# 需要时用 INCLUDE_NAIVE=1 打开（同时需要 project.yml 里给扩展预留的 -U 链接选项）。
if [ "${INCLUDE_NAIVE:-0}" != "1" ]; then
  python3 "${ROOT}/scripts/patch-libbox-tags.py" "${SRC_DIR}/cmd/internal/build_libbox/main.go"
  if grep -q '"with_naive_outbound", "with_clash_api"' "${SRC_DIR}/cmd/internal/build_libbox/main.go"; then
    echo "ERROR: with_naive_outbound 仍在内核标签里" >&2
    exit 1
  fi
  echo "naive 出站已禁用（INCLUDE_NAIVE=1 可重新开启）"
else
  if ! grep -q "with_naive_outbound" "${SRC_DIR}/cmd/internal/build_libbox/main.go"; then
    echo "WARNING: 需要 naive 出站，但源码里的 tag 已被移除；请先 rm -rf build/sing-box 后重跑" >&2
  fi
fi

for target in "${TARGETS[@]}"; do
  slice="${target//\//-}"
  log "build libbox slice: ${target}"
  (cd "${SRC_DIR}" && go run ./cmd/internal/build_libbox -target apple -platform "${target}")
  rm -rf "${SLICES}/${slice}"
  mkdir -p "${SLICES}/${slice}"
  mv "${SRC_DIR}/Libbox.xcframework" "${SLICES}/${slice}/Libbox.xcframework"
done

log "merge slices -> ${OUT}"
rm -rf "${OUT}"
mkdir -p "$(dirname "${OUT}")"
(
  cd "${SRC_DIR}"
  inputs=()
  for target in "${TARGETS[@]}"; do
    inputs+=("${SLICES}/${target//\//-}/Libbox.xcframework")
  done
  go run ./cmd/internal/merge_apple_xcframework -output "${OUT}" "${inputs[@]}"
)

log "result"
find "${OUT}" -maxdepth 2 -name "*.framework" -o -maxdepth 2 -name "Info.plist" | head -20
echo "OK: ${OUT}"
