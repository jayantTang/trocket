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
  # 优先沿用上一次生成的团队/前缀：机器上常装了多个开发者证书，
  # 盲取第一个身份会悄悄换成另一个团队的 Bundle ID（App 记录对不上，上传才发现）。
  if [ -f project.generated.yml ]; then
    TEAM_ID="$(sed -n 's/.*DEVELOPMENT_TEAM: "\([A-Z0-9]\{10\}\)".*/\1/p' project.generated.yml | head -1)"
  fi
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

if [ -z "${BUNDLE_PREFIX:-}" ] && [ -f project.generated.yml ]; then
  # 同样沿用上一次的前缀。默认值 com.<TeamID> 与 App Store 记录里已有的
  # com.jayanttang.trocket 不一致，悄悄换掉会导致归档上传时"找不到 App 记录"。
  BUNDLE_PREFIX="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: "\(.*\)\.trocket".*/\1/p' project.generated.yml | head -1)"
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
