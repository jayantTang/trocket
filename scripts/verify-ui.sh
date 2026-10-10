#!/usr/bin/env bash
# 仿真器界面验证：跑 TrocketUITests 并把截图附件导出到 build/ui-shots/
#
# 为什么需要单独的脚本：仿真器**拒绝启动带 packet-tunnel-provider 能力的包**
# （FBSOpenApplicationServiceErrorDomain code=1 / POSIX 163，实测），
# 所以这里把 entitlements 覆盖成「只有 App Group」再跑界面用例。
# 连接、测速、分流是否真的生效必须真机验证（网络扩展在仿真器不可用）。
#
# 用法：
#   ./scripts/verify-ui.sh
#   SIMULATOR="iPhone 16" ./scripts/verify-ui.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SIMULATOR="${SIMULATOR:-iPhone 17}"
RESULT_BUNDLE="${ROOT}/build/ui-tests.xcresult"
SHOT_DIR="${ROOT}/build/ui-shots"
LOG="${ROOT}/build/verify/ui-tests.log"
mkdir -p "$(dirname "${LOG}")"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d Trocket.xcodeproj ] || die "缺少 Trocket.xcodeproj —— 先运行 ./scripts/bootstrap.sh"

APP_GROUP="group.$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path('project.generated.yml' if pathlib.Path('project.generated.yml').exists() else 'project.yml').read_text()
m = re.search(r'TrocketAppGroup:\s*group\.@?([A-Za-z0-9._-]*?)\.trocket', text) or re.search(r'group\.([A-Za-z0-9]+)\.trocket', text)
print(m.group(1) if m else 'com.jayanttang')
PY
).trocket"

ENTITLEMENTS="$(mktemp -t trocket-sim-ent).plist"
cat > "${ENTITLEMENTS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>${APP_GROUP}</string>
  </array>
</dict>
</plist>
PLIST
trap 'rm -f "${ENTITLEMENTS}"' EXIT

echo "==> 仿真器：${SIMULATOR} | App Group：${APP_GROUP}"
rm -rf "${RESULT_BUNDLE}" "${SHOT_DIR}"

if xcodebuild test \
    -project Trocket.xcodeproj \
    -scheme Trocket \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=${SIMULATOR}" \
    -derivedDataPath "${ROOT}/build/DerivedData-sim-ui" \
    -only-testing:TrocketUITests \
    -resultBundlePath "${RESULT_BUNDLE}" \
    CODE_SIGN_ENTITLEMENTS="${ENTITLEMENTS}" \
    > "${LOG}" 2>&1; then
  echo "PASS  界面用例（日志：${LOG}）"
else
  echo "FAIL  界面用例（首处错误如下，完整日志：${LOG}）"
  grep -m8 -E "error:|XCTAssert|failed" "${LOG}" || tail -25 "${LOG}"
  exit 1
fi

# XCUITest 驱动的 App 不在仿真器可见屏幕上，simctl 截图只能拍到桌面壁纸，
# 所以证据一律从 .xcresult 里导出（见 ios-sim-testing skill）。
mkdir -p "${SHOT_DIR}"
xcrun xcresulttool export attachments \
  --path "${RESULT_BUNDLE}" \
  --output-path "${SHOT_DIR}" >/dev/null 2>&1 || {
    echo "WARNING: 截图导出失败，用 xcrun xcresulttool get --legacy 手工检查" >&2
  }

echo
echo "截图：${SHOT_DIR}"
ls -1 "${SHOT_DIR}" 2>/dev/null | head -20
