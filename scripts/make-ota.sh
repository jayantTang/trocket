#!/usr/bin/env bash
# 生成 OTA 安装链接：Release 构建 → 打包 IPA → 起本地 HTTP 服务 → cloudflared 公网 HTTPS → manifest.plist
#
# 前置条件（缺一不可，脚本会检查并给出明确报错）：
#   1. Xcode 里已登录 Apple ID（Xcode → Settings → Accounts）。否则 xcodebuild 报 "No Accounts"。
#   2. 目标手机的 UDID 已在开发者账号里注册（Ad Hoc / 开发描述文件都是逐台授权）。
#   3. 已安装 cloudflared（brew install cloudflared）。
#
# 用法：
#   ./scripts/make-ota.sh                 # 用当前 project.generated.yml 的 Team
#   TEAM_ID=XXXXXXXXXX ./scripts/make-ota.sh   # 指定 Team 重新生成工程
#
# 输出：最后一行是手机可直接打开的 itms-services 链接（保持本脚本运行，链接才有效）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

PORT="${PORT:-8899}"
KERNEL_VERSION="${KERNEL_VERSION:-1.14.2}"
BUILD_DIR="${ROOT}/build/ota"
DEVICE_DERIVED="${ROOT}/build/DerivedData-device"
SERVER_LOG="${BUILD_DIR}/server.log"
TUNNEL_LOG="${BUILD_DIR}/tunnel.log"

mkdir -p "${BUILD_DIR}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v cloudflared >/dev/null || die "缺少 cloudflared：brew install cloudflared"
command -v xcodebuild >/dev/null || die "缺少 Xcode 命令行工具"

if [ -n "${TEAM_ID:-}" ]; then
  echo "==> 用 TEAM_ID=${TEAM_ID} 重新生成工程"
  TEAM_ID="${TEAM_ID}" "${ROOT}/scripts/bootstrap.sh" >/dev/null
fi

BUNDLE_ID="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path('project.generated.yml' if pathlib.Path('project.generated.yml').exists() else 'project.yml').read_text()
m = re.search(r'PRODUCT_BUNDLE_IDENTIFIER:\s*"?([^"\n]+\.trocket)"?', text)
print(m.group(1) if m else '')
PY
)"
[ -n "${BUNDLE_ID}" ] || die "无法从 project.yml 解析主 App 的 bundle id；先跑 ./scripts/bootstrap.sh"
echo "==> Bundle ID: ${BUNDLE_ID}"

echo "==> 构建 Release（允许自动更新描述文件）"
if ! xcodebuild build \
  -project Trocket.xcodeproj \
  -scheme Trocket \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DEVICE_DERIVED}" \
  -allowProvisioningUpdates \
  > "${BUILD_DIR}/device-build.log" 2>&1; then
  echo "构建失败，首处错误：" >&2
  grep -m5 -E "error:" "${BUILD_DIR}/device-build.log" >&2 || tail -20 "${BUILD_DIR}/device-build.log" >&2
  if grep -q "No Accounts" "${BUILD_DIR}/device-build.log"; then
    die "Xcode 未登录 Apple ID：打开 Xcode → Settings → Accounts 登录后重跑本脚本"
  fi
  if grep -q "doesn't include the current device\|not registered" "${BUILD_DIR}/device-build.log"; then
    die "目标手机 UDID 未在该 Team 注册：把手机连到本机并在 Xcode 里添加设备，或换 TEAM_ID"
  fi
  exit 1
fi

APP_PATH="${DEVICE_DERIVED}/Build/Products/Release-iphoneos/Trocket.app"
[ -d "${APP_PATH}" ] || die "找不到 Release 产物：${APP_PATH}"

echo "==> 检查描述文件包含哪些设备"
if security cms -D -i "${APP_PATH}/embedded.mobileprovision" -o "${BUILD_DIR}/embedded.plist" 2>/dev/null; then
  python3 "${ROOT}/scripts/print-profile-devices.py" "${BUILD_DIR}/embedded.plist" "${OTA_TEST_UDID:-}"
else
  echo "    WARNING: 读不出 embedded.mobileprovision，跳过检查"
fi

echo "==> 打包 IPA"
rm -rf "${BUILD_DIR}/Payload" "${BUILD_DIR}/Trocket.ipa"
mkdir -p "${BUILD_DIR}/Payload"
cp -R "${APP_PATH}" "${BUILD_DIR}/Payload/"
(cd "${BUILD_DIR}" && zip -qry Trocket.ipa Payload)
echo "    ${BUILD_DIR}/Trocket.ipa ($(du -h "${BUILD_DIR}/Trocket.ipa" | cut -f1))"

echo "==> 起本地静态服务 :${PORT}"
( cd "${BUILD_DIR}" && nohup python3 -m http.server "${PORT}" --bind 127.0.0.1 > "${SERVER_LOG}" 2>&1 & echo $! > "${BUILD_DIR}/server.pid" )
sleep 2

echo "==> 开 cloudflared 隧道（等待分配 https 地址，最多 60 秒）"
: > "${TUNNEL_LOG}"
nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" --no-autoupdate > "${TUNNEL_LOG}" 2>&1 &
echo $! > "${BUILD_DIR}/tunnel.pid"

PUBLIC_URL=""
for _ in $(seq 1 60); do
  PUBLIC_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" | head -1 || true)"
  [ -n "${PUBLIC_URL}" ] && break
  sleep 1
done
[ -n "${PUBLIC_URL}" ] || die "cloudflared 未返回地址，看 ${TUNNEL_LOG}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Info.plist" 2>/dev/null || echo 1.0)"

echo "==> 写 manifest.plist（${PUBLIC_URL}）"
cat > "${BUILD_DIR}/manifest.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${PUBLIC_URL}/Trocket.ipa</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>Trocket</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> 写安装引导页 index.html"
cat > "${BUILD_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>安装 Trocket</title>
<style>
 body{font-family:-apple-system,"PingFang SC",sans-serif;margin:0;padding:40px 24px;background:#f7f7f8;color:#111}
 h1{font-size:22px;margin:0 0 6px} p,li{color:#555;font-size:14px;line-height:1.8}
 a.btn{display:block;text-align:center;margin:28px 0;padding:16px;border-radius:14px;background:#007aff;color:#fff;text-decoration:none;font-size:17px;font-weight:600}
 ol{padding-left:20px}
</style></head><body>
 <h1>Trocket 1.0</h1>
 <p>极简代理客户端 · 内核 sing-box ${KERNEL_VERSION}</p>
 <a class="btn" href="itms-services://?action=download-manifest&amp;url=${PUBLIC_URL}/manifest.plist">安装 Trocket</a>
 <ol>
  <li>点上面的按钮，系统提示"要安装此 App 吗"时选 <b>安装</b>。</li>
  <li>装完到 <b>设置 → 通用 → VPN与设备管理</b> 信任对应的开发者证书。</li>
  <li>若提示需要开发者模式：<b>设置 → 隐私与安全性 → 开发者模式</b> 打开并重启一次。</li>
  <li>打开 Trocket：粘贴订阅链接 → 导入 → 测速 → 选线路 → 打开开关。</li>
 </ol>
 <p style="margin-top:32px;font-size:12px;color:#999">此链接为临时隧道，装完即可关闭；开发签名有效期至描述文件到期日。</p>
</body></html>
HTML

# 空文件是无法察觉的故障（页面会白屏），这里显式拦住
for artifact in manifest.plist index.html Trocket.ipa; do
  if [ ! -s "${BUILD_DIR}/${artifact}" ]; then
    die "${artifact} 为空，OTA 会白屏或安装失败"
  fi
done

MANIFEST_URL="${PUBLIC_URL}/manifest.plist"
OTA_URL="itms-services://?action=download-manifest&url=${MANIFEST_URL}"

echo
echo "手机（同一网络即可，不必与 Mac 同网）用 Safari 打开下面这个链接："
echo
echo "${OTA_URL}"
echo
echo "安装后在手机上：设置 → 通用 → VPN与设备管理 → 信任该开发者；"
echo "iOS 16+ 还需 设置 → 隐私与安全性 → 开发者模式 打开并重启一次。"
echo
echo "停止服务：kill \$(cat ${BUILD_DIR}/tunnel.pid) \$(cat ${BUILD_DIR}/server.pid)"
