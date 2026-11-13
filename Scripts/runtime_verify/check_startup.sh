#!/bin/bash
# 启动接管检查：构建后跑 --verify-startup，断言「取得独占锁 + 可写容器 + 总耗时低于阈值」。
#
# 退出码：0 = PASS，1 = FAIL，3 = SKIP（例如本机已有 Memozia 实例占用数据库独占锁）
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 阈值（暂定、可按机器调整）：接管总耗时上限（毫秒）
STARTUP_THRESHOLD_MS="${Memozia_STARTUP_THRESHOLD_MS:-5000}"

APP_BIN="$(resolve_app_binary)" || {
  echo "FAIL: 无法定位构建产物（请先构建，或设置 Memozia_APP=/path/to/Memozia）"
  exit 1
}

OUT="$("$APP_BIN" --verify-startup 2>/dev/null)"
if [ -z "$OUT" ]; then
  echo "FAIL: --verify-startup 无输出"
  exit 1
fi
echo "实测 JSON: $OUT"

lockAcquired="$(json_field "$OUT" lockAcquired)"
mode="$(json_field "$OUT" mode)"
totalMs="$(json_field "$OUT" totalMs)"
workerWaitMs="$(json_field "$OUT" workerWaitMs)"
lockWaitMs="$(json_field "$OUT" lockWaitMs)"
containerOpenMs="$(json_field "$OUT" containerOpenMs)"
reason="$(json_field "$OUT" reason)"

echo "  阈值(暂定、可按机器调整): totalMs < ${STARTUP_THRESHOLD_MS}ms"
echo "  实测: workerWaitMs=$workerWaitMs lockAcquired=$lockAcquired lockWaitMs=$lockWaitMs" \
     "containerOpenMs=$containerOpenMs totalMs=$totalMs mode=$mode reason=$reason"

if [ "$lockAcquired" != "true" ]; then
  echo "SKIP: 未取得数据库独占锁（reason=${reason}）——本机很可能已有 Memozia 实例在运行，"
  echo "      「接管成功 → 可写容器」路径无法在不影响运行实例的前提下验证；"
  echo "      请先退出 Memozia（以及后台 worker），再重跑本脚本。"
  exit 3
fi

if [ "$mode" != "writable" ]; then
  echo "FAIL: lockAcquired=true 但 mode=$mode（期望 writable）"
  exit 1
fi

if ! num_lt "$totalMs" "$STARTUP_THRESHOLD_MS"; then
  echo "FAIL: totalMs=$totalMs 超过阈值 ${STARTUP_THRESHOLD_MS}ms"
  exit 1
fi

echo "PASS: 启动接管成功（持锁 → 可写容器），totalMs=$totalMs < ${STARTUP_THRESHOLD_MS}ms"
exit 0
