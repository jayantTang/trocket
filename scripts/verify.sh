#!/usr/bin/env bash
# 一次命令跑完全部自动验证：
#   1) 设备 SDK 编译（证明 App 与网络扩展都能为真机构建，不需要签名证书）
#   2) 模拟器单元测试（订阅解析 / 配置整形 / 排序 / 报错文案）
# 连接、测速、切换不在此脚本覆盖范围内（网络扩展无法在模拟器运行），见 specs 下的真机验证记录。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

SIMULATOR="${SIMULATOR:-iPhone 17}"
LOG_DIR="${ROOT}/build/verify"
mkdir -p "${LOG_DIR}"

DEVICE_LOG="${LOG_DIR}/device-build.log"
TEST_LOG="${LOG_DIR}/simulator-tests.log"
RESULT=0

if [ ! -d Trocket.xcodeproj ]; then
  echo "缺少 Trocket.xcodeproj —— 先运行 ./scripts/bootstrap.sh" >&2
  exit 1
fi

echo "=== [1/2] 设备 SDK 编译（App + 网络扩展，无签名） ==="
if xcodebuild build \
    -project Trocket.xcodeproj \
    -scheme Trocket \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${ROOT}/build/DerivedData-device" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    > "${DEVICE_LOG}" 2>&1; then
  echo "PASS  设备 SDK 编译"
else
  echo "FAIL  设备 SDK 编译（首处错误如下，完整日志：${DEVICE_LOG}）"
  grep -m5 -E "error:" "${DEVICE_LOG}" || tail -20 "${DEVICE_LOG}"
  RESULT=1
fi

echo
echo "=== [2/2] 模拟器单元测试（${SIMULATOR}） ==="
if xcodebuild test \
    -project Trocket.xcodeproj \
    -scheme Trocket \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=${SIMULATOR}" \
    -derivedDataPath "${ROOT}/build/DerivedData-sim" \
    -only-testing:TrocketTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    > "${TEST_LOG}" 2>&1; then
  SUMMARY="$(grep -E "Executed [0-9]+ test" "${TEST_LOG}" | tail -1)"
  echo "PASS  单元测试 ${SUMMARY:-}"
else
  echo "FAIL  单元测试（首处错误如下，完整日志：${TEST_LOG}）"
  grep -m10 -E "error:|failed" "${TEST_LOG}" || tail -20 "${TEST_LOG}"
  RESULT=1
fi

echo
if [ "${RESULT}" -eq 0 ]; then
  echo "判定：自动验证通过。真机连接/测速/切换需按 specs/001-ios-vpn-client/quickstart.md 第 3 节人工复验。"
else
  echo "判定：自动验证失败，见上面日志。"
fi
exit "${RESULT}"
