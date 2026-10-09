#!/usr/bin/env bash
# 生成 Trocket.xcodeproj：替换 project.yml 里的 Team / Bundle 前缀，然后调用 xcodegen。
#
# 用法：
#   ./scripts/bootstrap.sh
#   TEAM_ID=XXXXXXXXXX BUNDLE_PREFIX=com.example ./scripts/bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

FRAMEWORK="Vendor/Libbox.xcframework"

if [ ! -d "${FRAMEWORK}" ]; then
  echo "缺少 ${FRAMEWORK} —— 先运行 ./scripts/build-libbox.sh 构建内核（首次约 10–20 分钟）" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null; then
  echo "缺少 xcodegen —— brew install xcodegen" >&2
  exit 1
fi

if [ -z "${TEAM_ID:-}" ]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*Apple Development: .*(\([A-Z0-9]\{10\}\))".*/\1/p' \
    | head -1)"
fi

if [ -z "${TEAM_ID:-}" ]; then
  cat >&2 <<'MSG'
无法自动探测 Apple 开发团队 ID。
请在 Xcode → Settings → Accounts 里确认已登录付费开发者账号，然后：
  TEAM_ID=你的10位TeamID ./scripts/bootstrap.sh
或先跑一次 `security find-identity -v -p codesigning` 查看证书里的括号内容。
MSG
  exit 1
fi

BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.${TEAM_ID}}"

echo "Team ID      : ${TEAM_ID}"
echo "Bundle 前缀  : ${BUNDLE_PREFIX}"
echo "App Group    : group.${BUNDLE_PREFIX}.trocket"

sed -e "s/@TEAM_ID@/${TEAM_ID}/g" \
    -e "s/@BUNDLE_PREFIX@/${BUNDLE_PREFIX}/g" \
    project.yml > project.generated.yml

xcodegen generate --spec project.generated.yml

echo
echo "已生成 Trocket.xcodeproj。"
echo "下一步：open Trocket.xcodeproj → 选自己的 Team → 真机运行（网络扩展在模拟器不可用）。"
