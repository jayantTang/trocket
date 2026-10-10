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
#   - KEY ID 必须由 APPSTORE_API_KEY_ID 提供（不写入仓库）
#   - Issuer ID 必须提供（App Store Connect → 用户和访问 → 集成 → App Store Connect API）
#
# 前置：App Store Connect 里必须已存在 Bundle ID 对应的 App 记录，否则上传无处可去。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

die() { echo "ERROR: $*" >&2; exit 1; }

# 团队与包前缀默认沿用上一次生成的工程（机器上常装了多个证书，盲猜会换成别的团队）
if [ -f project.generated.yml ]; then
  TEAM_ID="${TEAM_ID:-$(sed -n 's/.*DEVELOPMENT_TEAM: "\([A-Z0-9]\{10\}\)".*/\1/p' project.generated.yml | head -1)}"
  BUNDLE_PREFIX="${BUNDLE_PREFIX:-$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER: "\(.*\)\.trocket".*/\1/p' project.generated.yml | head -1)}"
fi
TEAM_ID="${TEAM_ID:?请设置 TEAM_ID（Apple 开发者团队 ID）}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:?请设置 BUNDLE_PREFIX（包名前缀）}"

# Key ID 只有一个 .p8 时直接取它，省得每次export
if [ -z "${APPSTORE_API_KEY_ID:-}" ]; then
  CANDIDATES=("$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8)
  [ -f "${CANDIDATES[0]}" ] || die "请设置 APPSTORE_API_KEY_ID（~/.appstoreconnect/private_keys 下没有 .p8）"
  KEY_ID="$(basename "${CANDIDATES[0]}" | sed 's/AuthKey_//; s/\.p8//')"
  [ "${#CANDIDATES[@]}" -eq 1 ] || echo "WARNING: 找到多个 .p8，默认用 ${KEY_ID}（可用 APPSTORE_API_KEY_ID 指定）"
else
  KEY_ID="$APPSTORE_API_KEY_ID"
fi
KEY_PATH="${APPSTORE_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
ISSUER="${APPSTORE_API_ISSUER_ID:-${1:-}}"
ARCHIVE="/tmp/Trocket.xcarchive"
EXPORT_DIR="/tmp/Trocket-export"
LOG_DIR="$ROOT/build/appstore"
mkdir -p "$LOG_DIR"

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

# 签名方式：默认**手工签名**（本机分发证书私钥在独立钥匙串里，见 README「分发」）。
# 原因：自动导出会走云签名，而本机没登录 Xcode 账号、API Key 也无云签名权限，实测报
#   error: exportArchive Cloud signing permission error
#   error: exportArchive No signing certificate "iOS Distribution" found
# USE_SESSION_SIGNING=1 时改回 Xcode 账号会话（需先在 Xcode → Settings → Accounts 登录）。
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-$HOME/Library/Keychains/dshbuild.keychain-db}"
SIGNING_KEYCHAIN_PASSWORD="${SIGNING_KEYCHAIN_PASSWORD:-dsh}"
ORIGINAL_KEYCHAINS="$(security list-keychains -d user | tr -d ' "')"
restore_keychains() { security list-keychains -d user -s ${ORIGINAL_KEYCHAINS} >/dev/null 2>&1 || true; }
trap restore_keychains EXIT

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER")

if [ "${USE_SESSION_SIGNING:-0}" = "1" ]; then
  echo "==> 签名方式：Xcode 账号会话（云端签名）"
  EXPORT_OPTIONS="$ROOT/Support/ExportOptions-appstore.plist"
else
  [ -f "$SIGNING_KEYCHAIN" ] || die "找不到分发证书钥匙串 $SIGNING_KEYCHAIN —— 用 USE_SESSION_SIGNING=1，或先按 19_dsh_iosapp/scripts/release/asc-dist-signing.mjs 签一张分发证书"
  echo "==> 签名方式：手工（$(basename "$SIGNING_KEYCHAIN") 中的 Apple Distribution）"
  security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" || die "解锁 $SIGNING_KEYCHAIN 失败"
  security list-keychains -d user -s "$SIGNING_KEYCHAIN" "$HOME/Library/Keychains/login.keychain-db"
  ASC_KEY_ID="$KEY_ID" ASC_ISSUER="$ISSUER" python3 "$ROOT/scripts/asc-profiles.py" ensure \
    || die "App Store 描述文件不齐（scripts/asc-profiles.py）"
  EXPORT_OPTIONS="$ROOT/Support/ExportOptions-appstore-manual.plist"
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

echo "==> 导出 App Store IPA（$(basename "$EXPORT_OPTIONS")）"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH[@]}" > "$LOG_DIR/export.log" 2>&1 || {
    grep -m5 -E "error:" "$LOG_DIR/export.log" >&2 || tail -20 "$LOG_DIR/export.log" >&2
    die "导出失败，日志：$LOG_DIR/export.log"
  }
IPA="$EXPORT_DIR/Trocket.ipa"
[ -f "$IPA" ] || die "导出目录里没有 IPA：$EXPORT_DIR"

if [ "${NO_UPLOAD:-0}" = "1" ]; then
  echo "NO_UPLOAD=1：已停在导出，未上传。IPA: ${IPA}（build ${NEXT}）"
  exit 0
fi

echo "==> 上传 App Store Connect（TestFlight）"
# altool 偶尔会抽风报权限错（实测："The file “Defaults.properties” couldn't be opened because
# you don't have permission to view it."），紧接着重试同样的包就能成功 —— 所以这里重试一次。
upload_ok=0
for attempt in 1 2; do
  if xcrun altool --upload-app -f "$IPA" -t ios \
      --apiKey "$KEY_ID" --apiIssuer "$ISSUER" --apiKeyFile "$KEY_PATH" \
      > "$LOG_DIR/upload.log" 2>&1; then
    upload_ok=1
    break
  fi
  echo "    第 ${attempt} 次上传失败，$( [ "$attempt" = 1 ] && echo '重试一次…' || echo '放弃' )" >&2
  tail -3 "$LOG_DIR/upload.log" >&2
  [ "$attempt" = 1 ] && sleep 5
done

if [ "$upload_ok" != "1" ]; then
  tail -25 "$LOG_DIR/upload.log" >&2
  echo >&2
  echo "常见原因：App Store Connect 里还没有对应的 App 记录，或账号协议/权限未就绪；" >&2
  echo "或账号地区/协议（Program License Agreement）未就绪。" >&2
  die "上传失败，日志：$LOG_DIR/upload.log"
fi

tail -8 "$LOG_DIR/upload.log"
echo
echo "已上传：build ${NEXT}（IPA: ${IPA}）"
echo "下一步：App Store Connect → TestFlight → 等构建处理完成 → 添加测试员（内部测试无需审核）"
