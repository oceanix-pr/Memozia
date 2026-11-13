#!/bin/bash
# 运行时验证总入口：构建一次，依次运行各检查，输出 PASS/FAIL/SKIP 汇总，任一 FAIL 以非零码退出。
#
# 用法: run_all.sh
#   可用环境变量：
#     Memozia_MEMORY_MINUTES  benchmark_memory 的分钟列表（默认 "10 40"，完整档 "30 60 120"）
#     Memozia_FILESYNC_COUNT  benchmark_filesync 的条目数（默认 200）
#     Memozia_APP             跳过定位，直接指定应用可执行文件
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

MEMORY_MINUTES="${Memozia_MEMORY_MINUTES:-10 40}"
FILESYNC_COUNT="${Memozia_FILESYNC_COUNT:-200}"

echo "=== Memozia 运行时验证 (run_all) ==="
echo "工程根: $REPO_ROOT"

BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/Memozia_verify_build.XXXXXX")" || {
  echo "无法创建构建日志临时文件"
  exit 1
}
echo ""
echo "===== 构建 (Debug) ====="
if ! DEVELOPER_DIR="${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}" \
     xcodebuild -project "$REPO_ROOT/Memozia.xcodeproj" -scheme Memozia -configuration Debug \
     -destination 'platform=macOS' build >"$BUILD_LOG" 2>&1; then
  echo "构建失败，末尾日志："
  tail -n 40 "$BUILD_LOG"
  exit 1
fi
echo "构建成功（日志：${BUILD_LOG}）"

if ! APP_BIN="$(resolve_app_binary)"; then
  echo "无法定位构建产物"
  exit 1
fi
export Memozia_APP="$APP_BIN"
echo "可执行文件: $APP_BIN"

PASS=0
FAIL=0
SKIP=0
SUMMARY=()

run_check() {
  local name="$1"
  shift
  echo ""
  echo "===== $name ====="
  "$@"
  local code=$?
  if [ "$code" -eq 0 ]; then
    SUMMARY+=("PASS  $name")
    PASS=$((PASS + 1))
  elif [ "$code" -eq 3 ]; then
    SUMMARY+=("SKIP  $name")
    SKIP=$((SKIP + 1))
  else
    SUMMARY+=("FAIL  $name (exit=$code)")
    FAIL=$((FAIL + 1))
  fi
}

run_check "check_startup" bash "$RUNTIME_VERIFY_DIR/check_startup.sh"
run_check "check_ephemeral_mode" bash "$RUNTIME_VERIFY_DIR/check_ephemeral_mode.sh"
# shellcheck disable=SC2086
run_check "benchmark_memory ($MEMORY_MINUTES)" bash "$RUNTIME_VERIFY_DIR/benchmark_memory.sh" $MEMORY_MINUTES
run_check "benchmark_filesync ($FILESYNC_COUNT)" bash "$RUNTIME_VERIFY_DIR/benchmark_filesync.sh" "$FILESYNC_COUNT"

echo ""
echo "===== 汇总 ====="
for line in "${SUMMARY[@]}"; do
  echo "$line"
done
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
