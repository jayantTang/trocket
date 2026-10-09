#!/usr/bin/env bash
# 归档 → 导出 App Store IPA → 上传 App Store Connect（TestFlight）
#
# 用法：
#   APPSTORE_API_ISSUER_ID=<issuer-uuid> ./scripts/upload-testflight.sh
#   # 或
#   ./scripts/upload-testflight.sh <issuer-uuid>
#
# 凭据：
#   - API Key 文件默认取 ~/.appstoreconnect/private_keys/AuthKey_${APPSTORE_API_KEY_ID}.p8
#   - KEY ID 默认 <ASC_KEY_ID>（可用 APPSTORE_API_KEY_ID 覆盖）
#   - Issuer ID 必须提供（App Store Connect → 用户和访问 → 集成 → App Store Connect API）
#
# 前置：App Store Connect 里必须已存在 Bundle ID 对应的 App 记录，否则上传无处可去。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

TEAM_ID="${TEAM_ID:-<TEAM_ID>}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.jayanttang}"
KEY_ID="${APPSTORE_API_KEY_ID:-<ASC_KEY_ID>}"
KEY_PATH="${APPSTORE_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
ISSUER="${APPSTORE_API_ISSUER_ID:-${1:-}}"
ARCHIVE="/tmp/Trocket.xcarchive"
EXPORT_DIR="/tmp/Trocket-export"
LOG_DIR="$ROOT/build/appstore"
mkdir -p "$LOG_DIR"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$ISSUER" ] || die "缺少 Issuer ID：APPSTORE_API_ISSUER_ID=<uuid> $0"
[ -f "$KEY_PATH" ] || die "找不到 API Key 文件：$KEY_PATH"
command -v xcodebuild >/dev/null || die "缺少 Xcode"

echo "==> 递增 build 号"
CURRENT=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed 's/.*"\([0-9]*\)".*/\1/')
[ -n "$CURRENT" ] || die "无法从 project.yml 读出 CURRENT_PROJECT_VERSION"
NEXT=$((CURRENT + 1))
/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \"${CURRENT}\"/CURRENT_PROJECT_VERSION: \"${NEXT}\"/" project.yml
echo "    build ${CURRENT} → ${NEXT}"
TEAM_ID="$TEAM_ID" BUNDLE_PREFIX="$BUNDLE_PREFIX" ./scripts/bootstrap.sh >/dev/null

# 签名方式：默认用 App Store Connect API Key；USE_SESSION_SIGNING=1 时改用
# Xcode → Settings → Accounts 里登录的账号会话（云端签名）。
if [ "${USE_SESSION_SIGNING:-0}" = "1" ]; then
  echo "==> 签名方式：Xcode 账号会话（云端签名）"
  AUTH=(-allowProvisioningUpdates)
else
  echo "==> 签名方式：App Store Connect API Key（${KEY_ID}）"
  AUTH=(-allowProvisioningUpdates
        -authenticationKeyPath "$KEY_PATH"
        -authenticationKeyID "$KEY_ID"
        -authenticationKeyIssuerID "$ISSUER")
fi

echo "==> 归档"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
  -project Trocket.xcodeproj -scheme Trocket -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  "${AUTH[@]}" > "$LOG_DIR/archive.log" 2>&1 || {
    grep -m5 -E "error:" "$LOG_DIR/archive.log" >&2 || tail -20 "$LOG_DIR/archive.log" >&2
    die "归档失败，日志：$LOG_DIR/archive.log"
  }

echo "==> 导出 App Store IPA"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Support/ExportOptions-appstore.plist \
  "${AUTH[@]}" > "$LOG_DIR/export.log" 2>&1 || {
    grep -m5 -E "error:" "$LOG_DIR/export.log" >&2 || tail -20 "$LOG_DIR/export.log" >&2
    die "导出失败，日志：$LOG_DIR/export.log"
  }
IPA="$EXPORT_DIR/Trocket.ipa"
[ -f "$IPA" ] || die "导出目录里没有 IPA：$EXPORT_DIR"

echo "==> 上传 App Store Connect（TestFlight）"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER" --apiKeyFile "$KEY_PATH" \
  > "$LOG_DIR/upload.log" 2>&1 || {
    tail -25 "$LOG_DIR/upload.log" >&2
    echo >&2
    echo "常见原因：App Store Connect 里还没有对应的 App 记录，或账号协议/权限未就绪；" >&2
    echo "或账号地区/协议（Program License Agreement）未就绪。" >&2
    die "上传失败，日志：$LOG_DIR/upload.log"
  }

tail -8 "$LOG_DIR/upload.log"
echo
echo "已上传：build ${NEXT}（IPA: ${IPA}）"
echo "下一步：App Store Connect → TestFlight → 等构建处理完成 → 添加测试员（内部测试无需审核）"
