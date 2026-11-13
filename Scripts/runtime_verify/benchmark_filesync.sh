#!/bin/bash
# 磁盘对账基准：生成条目后跑 --verify-filesync，打印耗时 / 条目数 / 磁盘访问数 / 主线程阻塞。
#
# 用法: benchmark_filesync.sh [count] [months]   默认 count=200 months=3
# 退出码：0 = PASS，1 = FAIL
#
# 基线（Apple Silicon 本机，Debug，2026-09；绝对值随机器变化，仅供相对回归对照）：
#   生产同构（持久容器，Memozia_FILESYNC_DB=<dir>）——回归优先用这个口径：
#     count=200  首轮 elapsed 223ms maxBlock 2ms | 次轮 119ms maxBlock 6ms   over50 0
#     count=1000 首轮 elapsed 750ms maxBlock 3ms | 次轮 303ms maxBlock 23ms  over50 0
#     count=10000 首轮 elapsed 6.7s maxBlock 33ms over50 0   ← 逐条存在性查询合批后（合批前 41.9s / 558ms / 82）
#                次轮 elapsed 2.60s maxBlock 34ms over50 0
# 结论：规模决定一切，但各规模均已达标——≤10k 条目下单次主线程阻塞 ≤34ms、0 次 ≥50ms。
# 次轮阻塞已按「主线程上按条/按表堆同步调用」的根因逐项修掉：
#   ① 镜像修复循环的逐条 stat → 后台批量探测；
#   ② 主线程 `.map` 构建 10k 探测目标（每条 3 个 URL × 一次 `resolveFolderURL` 的
#      `fileExists` ≈ 4 万次系统调用，实测 ~415ms）→ 只带 folderName 到后台解析（415ms → 202ms）；
#   ③ 单次 `context.fetch` 物化 10k 模型（实测 201ms）→ 按 folderName keyset 分页（202ms → 34ms）。
# 另有两个已修掉的 harness 假象：① 内存容器（与真实 SQLite 文件成本不同）；
#   ② harness 曾在主线程内联跑 TodoCountIndex 的逐目录 stat（生产在 detached，已同步改后台）。
# 环境变量：
#   Memozia_FILESYNC_ITERATIONS 覆盖轮次（>1 会覆盖「库非空 → 镜像修复循环」那一轮）
#   Memozia_FILESYNC_DB         持久容器目录（生产同构口径）
#   Memozia_MAINBLOCK_THRESHOLD_MS 设置后把「主线程单次阻塞」升级为门禁（基线未达标前请勿在 CI 开启）
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP_BIN="$(resolve_app_binary)" || {
  echo "FAIL: 无法定位构建产物（请先构建，或设置 Memozia_APP=/path/to/Memozia）"
  exit 1
}

COUNT="${1:-200}"
MONTHS="${2:-3}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/Memozia_verify_filesync.XXXXXX")"
DATA_ROOT="$WORK/data"
mkdir -p "$DATA_ROOT"
echo "工作目录: $WORK"
echo "生成条目: count=$COUNT months=$MONTHS"

if ! python3 "$RUNTIME_VERIFY_DIR/gen_sample_entries.py" "$COUNT" "$DATA_ROOT" --months "$MONTHS" >/dev/null; then
  echo "FAIL: 生成条目失败"
  exit 1
fi

# Memozia_FILESYNC_ITERATIONS 可设 >1 以覆盖「库非空 → 镜像修复循环」那一轮
# Memozia_FILESYNC_DB 指向一个目录 → 用持久容器（多次运行共享同一份库，可验写方向）
# 注意：macOS 自带 bash 3.2 在 `set -u` 下展开**空数组**会报 unbound，
#       因此用一个始终非空的数组累加参数（不要写成可空的 "${X[@]}"）。
RUN_ARGS=(--verify-filesync "$DATA_ROOT")
if [ -n "${Memozia_FILESYNC_ITERATIONS:-}" ]; then
  RUN_ARGS+=(--iterations "$Memozia_FILESYNC_ITERATIONS")
fi
if [ -n "${Memozia_FILESYNC_DB:-}" ]; then
  RUN_ARGS+=(--db "$Memozia_FILESYNC_DB")
fi
OUT="$("$APP_BIN" "${RUN_ARGS[@]}" 2>/dev/null)"
if [ -z "$OUT" ]; then
  echo "FAIL: --verify-filesync 无输出"
  exit 1
fi
echo "实测 JSON: $OUT"

elapsedMs="$(json_field "$OUT" elapsedMs)"
discovered="$(json_field "$OUT" discoveredEntries)"
inserted="$(json_field "$OUT" insertedEntries)"
statCalls="$(json_field "$OUT" todoIndexStatCalls)"
parsedDirs="$(json_field "$OUT" todoIndexParsedDirs)"
saveFailed="$(json_field "$OUT" saveFailed)"
maxBlockMs="$(json_field "$OUT" mainThreadMaxBlockMs)"
blockedOver="$(json_field "$OUT" mainThreadBlockedOverThreshold)"
probeSamples="$(json_field "$OUT" mainThreadSamples)"
dbMode="$(json_field "$OUT" dbMode)"
flushComplete="$(json_field "$OUT" mirrorFlushComplete)"

echo "  实测: elapsedMs=$elapsedMs discoveredEntries=$discovered insertedEntries=$inserted" \
     "todoIndexStatCalls=$statCalls todoIndexParsedDirs=$parsedDirs saveFailed=$saveFailed"
# 注意：变量后紧跟多字节字符时必须用 ${} 包裹，否则非 UTF-8 环境下首字节会被并进变量名
echo "  主线程: maxBlockMs=${maxBlockMs}（单次最大同步阻塞）" \
     "blockedOverThreshold=${blockedOver} / samples=${probeSamples}"
echo "  容器: dbMode=${dbMode} mirrorFlushComplete=${flushComplete}"
# 阈值（暂定、可按机器调整）：单轮对账耗时上限
FILESYNC_THRESHOLD_MS="${Memozia_FILESYNC_THRESHOLD_MS:-20000}"
# 主线程单次阻塞上限：默认只在设置 Memozia_MAINBLOCK_THRESHOLD_MS 时作为门禁（基线未校准前不阻断）
MAINBLOCK_THRESHOLD_MS="${Memozia_MAINBLOCK_THRESHOLD_MS:-}"

if [ -n "$MAINBLOCK_THRESHOLD_MS" ] && ! num_lt "$maxBlockMs" "$MAINBLOCK_THRESHOLD_MS"; then
  echo "FAIL: mainThreadMaxBlockMs=${maxBlockMs} 超过阈值 ${MAINBLOCK_THRESHOLD_MS}ms（主线程单次阻塞过长）"
  exit 1
fi
if [ -z "$MAINBLOCK_THRESHOLD_MS" ]; then
  echo "  提示: 未设置 Memozia_MAINBLOCK_THRESHOLD_MS，主线程阻塞仅记录不拦截（用于采集基线）"
fi

if [ "$discovered" != "$COUNT" ]; then
  echo "WARN: discoveredEntries=$discovered 与生成条目数 $COUNT 不一致（检查存储布局/月份目录）"
fi
if [ -z "$inserted" ] || [ "$inserted" -le 0 ] 2>/dev/null; then
  echo "FAIL: insertedEntries=$inserted（期望 > 0；占位音频应被判为可播放并入库）"
  exit 1
fi
if [ "$saveFailed" = "true" ]; then
  echo "FAIL: 对账后保存数据库失败（saveFailed=true）"
  exit 1
fi
if ! num_lt "$elapsedMs" "$FILESYNC_THRESHOLD_MS"; then
  echo "FAIL: elapsedMs=$elapsedMs 超过阈值 ${FILESYNC_THRESHOLD_MS}ms"
  exit 1
fi

echo "PASS: 磁盘对账完成（发现 ${discovered}，入库 ${inserted}，待办索引 stat=${statCalls} 解析=${parsedDirs}）"
echo "工作目录保留：$WORK"
exit 0
