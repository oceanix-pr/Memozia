#!/bin/bash
# 临时（内存）模式检查：先用 Python fcntl.flock 在锁文件上持有独占锁，再跑 --verify-startup，
# 断言 mode==ephemeral 且未创建可写容器（writableContainerOpened==false），最后释放锁。
#
# 退出码：0 = PASS，1 = FAIL
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP_BIN="$(resolve_app_binary)" || {
  echo "FAIL: 无法定位构建产物（请先构建，或设置 Memozia_APP=/path/to/Memozia）"
  exit 1
}

LOCK_PATH="$("$APP_BIN" --print-db-lock-path 2>/dev/null)"
if [ -z "$LOCK_PATH" ]; then
  echo "FAIL: --print-db-lock-path 无输出"
  exit 1
fi
echo "锁文件: $LOCK_PATH"
mkdir -p "$(dirname "$LOCK_PATH")"

HOLDER_LOG="$(mktemp "${TMPDIR:-/tmp}/Memozia_lock_holder.XXXXXX")"
LOCK_PATH="$LOCK_PATH" python3 - >"$HOLDER_LOG" 2>&1 <<'PY' &
import fcntl
import os
import sys
import time

path = os.environ["LOCK_PATH"]
handle = open(path, "a+")
try:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError as error:
    # 锁已被其他进程（例如正在运行的 Memozia）持有：本检查的断言仍然成立
    print("holder=already-held-by-other-process: %s" % error, flush=True)
    sys.exit(0)
print("holder=acquired", flush=True)
time.sleep(600)
PY
HOLDER=$!

sleep 1
echo "锁持有者状态: $(tr -d '\n' < "$HOLDER_LOG")"

OUT="$("$APP_BIN" --verify-startup 2>/dev/null)"

kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null
rm -f "$HOLDER_LOG"

if [ -z "$OUT" ]; then
  echo "FAIL: --verify-startup 无输出"
  exit 1
fi
echo "实测 JSON: $OUT"

mode="$(json_field "$OUT" mode)"
lockAcquired="$(json_field "$OUT" lockAcquired)"
writableContainerOpened="$(json_field "$OUT" writableContainerOpened)"
reason="$(json_field "$OUT" reason)"
containerOpenMs="$(json_field "$OUT" containerOpenMs)"

echo "  实测: lockAcquired=$lockAcquired mode=$mode writableContainerOpened=$writableContainerOpened" \
     "containerOpenMs=$containerOpenMs reason=$reason"

if [ "$lockAcquired" = "true" ]; then
  echo "FAIL: 锁被外部持有时仍报告已取得独占锁（lockAcquired=true）"
  exit 1
fi
if [ "$mode" != "ephemeral" ]; then
  echo "FAIL: mode=${mode}（期望 ephemeral）"
  exit 1
fi
if [ "$writableContainerOpened" != "false" ]; then
  echo "FAIL: writableContainerOpened=${writableContainerOpened}（期望 false，锁未取得时绝不能打开可写容器）"
  exit 1
fi

echo "PASS: 未取得独占锁时进入临时（内存）模式，且未打开可写容器"
exit 0
