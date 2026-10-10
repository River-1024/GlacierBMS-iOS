#!/usr/bin/env bash
# 从 GitHub Actions 取回最近一次成功的无签名 IPA，归档到本地产出目录。
#
# 用法：
#   scripts/fetch-ipa.sh              # 取最近一次成功的运行
#   scripts/fetch-ipa.sh -r 38022973698   # 取指定 Run ID
#   scripts/fetch-ipa.sh --all        # 取最近一次成功运行的全部 artifact
#
# 归档结构：
#   build/ci/<短提交号>/ANTuRide-unsigned.ipa
#   build/ci/latest/ANTuRide-unsigned.ipa        (始终指向最近一次成功)
#
# 失败即退出，不留残缺文件污染 latest/。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

ARTIFACT_NAME="ANTuRide-unsigned-ipa"
OUT_ROOT="build/ci"
RUN_ID=""
WANT_ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--run) RUN_ID="${2:-}"; shift 2 ;;
    --all) WANT_ALL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "找不到 gh CLI。请先安装 GitHub CLI 并执行 gh auth login。" >&2
  exit 1
fi

# 产物下载走 Azure Blob，偶发 5xx；按「临时超时/5xx 最多重试 2 次」处理。
# 4xx / 权限 / 参数错误不重试（重试也不会成功）。
download_artifact() {
  local dest="$1" attempt=1
  while :; do
    if gh run download "${RUN_ID}" -n "${ARTIFACT_NAME}" -D "${dest}" 2>"${dest}/.gh-err"; then
      return 0
    fi
    local err; err="$(cat "${dest}/.gh-err" 2>/dev/null || true)"
    if printf '%s' "${err}" | grep -qE 'Bad Gateway|502|503|504|timed? ?out|timeout'; then
      if [ "${attempt}" -ge 3 ]; then
        echo "下载失败（已重试 2 次，均为临时性错误）。" >&2
        return 1
      fi
      echo "    临时错误，第 ${attempt} 次重试…" >&2
      attempt=$((attempt + 1))
      sleep 3
      continue
    fi
    printf '%s\n' "${err}" >&2
    return 1
  done
}

die_download() {
  echo "" >&2
  echo "取包失败。常见原因：" >&2
  echo "  1. 该 Run 的 artifact 已过保留期（本仓库设为 7 天）——请换一次更近的成功运行，或不带 -r 让脚本自动选最新。" >&2
  echo "  2. 网络临时抖动——脚本已自动重试；仍失败请稍后再试。" >&2
  echo "  3. 该 Run 未产出 ${ARTIFACT_NAME}——确认它走到了上传产物那一步。" >&2
  exit 1
}

if [ -z "${RUN_ID}" ]; then
  echo "==> 查询最近一次成功的运行"
  RUN_ID="$(gh run list --workflow build.yml --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
  if [ -z "${RUN_ID}" ] || [ "${RUN_ID}" = "null" ]; then
    echo "没有找到成功的运行记录。" >&2
    exit 1
  fi
fi

SHA="$(gh run view "${RUN_ID}" --json headSha --jq '.headSha')"
SHORT_SHA="$(printf '%s' "${SHA}" | cut -c1-7)"
TITLE="$(gh run view "${RUN_ID}" --json displayTitle --jq '.displayTitle')"
DEST_DIR="${OUT_ROOT}/${SHORT_SHA}"
TMP_DIR="${OUT_ROOT}/.tmp-${SHORT_SHA}-$$"

# 前置清理：上次异常中断可能留下临时目录
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
# 无论成败都清掉临时目录，避免残留
finish() { rm -rf "${TMP_DIR}"; }
trap finish EXIT

echo "==> Run ${RUN_ID}  提交 ${SHORT_SHA}  ${TITLE}"

if [ "${WANT_ALL}" = "1" ]; then
  echo "==> 下载全部 artifact 到 ${DEST_DIR}"
  mkdir -p "${DEST_DIR}"
  gh run download "${RUN_ID}" -D "${DEST_DIR}" || die_download
else
  echo "==> 下载 ${ARTIFACT_NAME}"
  download_artifact "${TMP_DIR}" || die_download

  IPA="$(find "${TMP_DIR}" -name '*.ipa' -print -quit)"
  if [ -z "${IPA}" ]; then
    echo "下载结果里没有 .ipa 文件。" >&2
    exit 1
  fi

  echo "==> 校验 IPA 结构"
  if ! unzip -Z1 "${IPA}" | grep -q '^Payload/ANTuRide\.app/ANTuRide$'; then
    echo "IPA 内缺少 Payload/ANTuRide.app/ANTuRide 主二进制。" >&2
    exit 1
  fi
  if unzip -Z1 "${IPA}" | grep -q 'embedded.mobileprovision'; then
    echo "IPA 含 embedded.mobileprovision，不是预期的无签名包。" >&2
    exit 1
  fi

  mkdir -p "${DEST_DIR}" "${OUT_ROOT}/latest"
  mv -f "${IPA}" "${DEST_DIR}/ANTuRide-unsigned.ipa"
  cp -f "${DEST_DIR}/ANTuRide-unsigned.ipa" "${OUT_ROOT}/latest/ANTuRide-unsigned.ipa"
fi

TARGET="${DEST_DIR}/ANTuRide-unsigned.ipa"
echo ""
echo "==> 完成"
echo "    路径   ${REPO_ROOT}/${TARGET}"
echo "    大小   $(wc -c < "${TARGET}") 字节"
if command -v sha256sum >/dev/null 2>&1; then
  echo "    SHA256 $(sha256sum "${TARGET}" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  echo "    SHA256 $(shasum -a 256 "${TARGET}" | cut -d' ' -f1)"
fi
echo "    快捷   ${REPO_ROOT}/${OUT_ROOT}/latest/ANTuRide-unsigned.ipa"
