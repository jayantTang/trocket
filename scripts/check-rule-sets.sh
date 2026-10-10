#!/usr/bin/env bash
# 校验内置规则集的判定是否符合预期：国内容器命中、境外不命中。
#
# 用内核自带的 `sing-box rule-set match`（与隧道里跑的是同一套匹配实现），
# 因此这是"国内直连到底能不能认出来"的本机证据；分流是否真的生效仍需真机复验。
#
# 用法：
#   SING_BOX=/tmp/sing-box/sing-box ./scripts/check-rule-sets.sh
#   （不指定时依次尝试 PATH 里的 sing-box、build/sing-box/sing-box）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

die() { echo "ERROR: $*" >&2; exit 1; }

SING_BOX="${SING_BOX:-$(command -v sing-box || true)}"
if [ -z "${SING_BOX}" ] || [ ! -x "${SING_BOX}" ]; then
  for candidate in "${ROOT}/build/sing-box/sing-box" /tmp/sing-box/sing-box; do
    [ -x "${candidate}" ] && SING_BOX="${candidate}" && break
  done
fi
[ -n "${SING_BOX}" ] && [ -x "${SING_BOX}" ] || die "找不到 sing-box 可执行文件；用 SING_BOX=<路径> 指定
（可从 build/sing-box 源码构建：cd build/sing-box && go build -o /tmp/sing-box/sing-box ./cmd/sing-box）"

GEOSITE="${ROOT}/Resources/RuleSets/geosite-cn.srs"
GEOIP="${ROOT}/Resources/RuleSets/geoip-cn.srs"
for file in "${GEOSITE}" "${GEOIP}"; do
  [ -f "${file}" ] || die "缺少规则集：${file}"
done

FAIL=0
expect() { # <规则集文件> <值> <yes|no> <说明>
  local file="$1" value="$2" want="$3" label="$4"
  local out
  out="$("${SING_BOX}" rule-set match -f binary "${file}" "${value}" 2>&1 | tail -1)"
  local got="no"
  [ -n "${out}" ] && got="yes"
  if [ "${got}" = "${want}" ]; then
    printf '  PASS  %-18s %s\n' "${value}" "${label}"
  else
    printf '  FAIL  %-18s %s（期望 %s，实际 %s）\n' "${value}" "${label}" "${want}" "${got}"
    FAIL=1
  fi
}

echo "== 域名（$(basename "${GEOSITE}")）"
for domain in taobao.com www.baidu.com qq.com weibo.com jd.com bilibili.com 12306.cn; do
  expect "${GEOSITE}" "${domain}" yes "国内域名应命中"
done
for domain in google.com youtube.com github.com; do
  expect "${GEOSITE}" "${domain}" no "境外域名不应命中"
done

echo "== IP（$(basename "${GEOIP}")）"
for ip in 223.5.5.5 114.114.114.114 180.101.49.11; do
  expect "${GEOIP}" "${ip}" yes "国内 IP 应命中"
done
for ip in 8.8.8.8 1.1.1.1 140.82.121.4; do
  expect "${GEOIP}" "${ip}" no "境外 IP 不应命中"
done

echo
if [ "${FAIL}" -eq 0 ]; then
  echo "判定：规则集判定符合预期（内核匹配实现，与隧道内一致）。"
else
  echo "判定：有不符合预期的项，见上面 FAIL。" >&2
fi
exit "${FAIL}"
