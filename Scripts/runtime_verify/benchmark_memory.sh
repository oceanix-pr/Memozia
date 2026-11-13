#!/bin/bash
# 内存与取消延迟基准：生成 WAV 后跑 --verify-memory，对照「整段模式 vs 分段模式」。
#
# 用法: benchmark_memory.sh [minutes...]   默认 30 60 120
# 退出码：0 = PASS，1 = FAIL
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP_BIN="$(resolve_app_binary)" || {
  echo "FAIL: 无法定位构建产物（请先构建，或设置 Memozia_APP=/path/to/Memozia）"
  exit 1
}

MINUTES=("$@")
if [ "${#MINUTES[@]}" -eq 0 ]; then
  MINUTES=(30 60 120)
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/Memozia_verify_memory.XXXXXX")"
echo "工作目录: $WORK"
echo "阈值(不适用，仅记录): 峰值常驻内存与取消延迟为观测量，无通过/失败阈值"

printf '%-9s %-10s %-14s %-12s %-14s %-10s %s\n' \
  "分钟" "加载模式" "峰值RSS(MB)" "耗时(ms)" "取消延迟(ms)" "规划段数" "plannerMode"

FAILED=0
for minutes in "${MINUTES[@]}"; do
  WAV="$WORK/long_${minutes}min.wav"
  if ! python3 "$RUNTIME_VERIFY_DIR/gen_long_audio.py" "$minutes" "$WAV" >/dev/null; then
    echo "FAIL: 生成 ${minutes} 分钟 WAV 失败"
    FAILED=1
    continue
  fi

  WHOLE="$("$APP_BIN" --verify-memory "$WAV" 2>/dev/null)"
  wholePeak="$(json_field "$WHOLE" peakRSSBytes)"
  wholeElapsed="$(json_field "$WHOLE" elapsedMs)"
  wholeCancel="$(json_field "$WHOLE" cancelLatencyMs)"
  segCount="$(json_field "$WHOLE" segmentCount)"
  plannerMode="$(json_field "$WHOLE" plannerMode)"
  duration="$(json_field "$WHOLE" durationSeconds)"

  if [ -z "$wholePeak" ]; then
    echo "FAIL: --verify-memory 对 ${minutes} 分钟音频无有效输出: $WHOLE"
    FAILED=1
    continue
  fi

  printf '%-9s %-10s %-14s %-12s %-14s %-10s %s\n' \
    "$minutes" "whole" "$(bytes_to_mb "$wholePeak")" "$wholeElapsed" "$wholeCancel" "$segCount" "$plannerMode"
  echo "  （时长 ${duration}s，整段估算采样内存 $(bytes_to_mb "$(json_field "$WHOLE" estimatedSampleBytes)") MB，" \
       "实际采样数 $(json_field "$WHOLE" sampleCount)，取消被观察=$(json_field "$WHOLE" cancellationObserved)）"

  # 规划段数 > 1 时才做「分段模式」对照：加载全部分段，峰值应显著低于整段
  if [ -n "$segCount" ] && [ "$segCount" -gt 1 ] 2>/dev/null; then
    SEGMENTED="$("$APP_BIN" --verify-memory "$WAV" --segments "$segCount" 2>/dev/null)"
    segPeak="$(json_field "$SEGMENTED" peakRSSBytes)"
    segElapsed="$(json_field "$SEGMENTED" elapsedMs)"
    segCancel="$(json_field "$SEGMENTED" cancelLatencyMs)"
    segPlanned="$(json_field "$SEGMENTED" segmentCount)"
    segmentsLoaded="$(json_field "$SEGMENTED" segmentsLoaded)"
    printf '%-9s %-10s %-14s %-12s %-14s %-10s %s\n' \
      "$minutes" "segmented" "$(bytes_to_mb "$segPeak")" "$segElapsed" "$segCancel" "$segPlanned" \
      "$(json_field "$SEGMENTED" loadMode)"
    echo "  （分段加载 ${segmentsLoaded} 段，取消延迟=$(json_field "$SEGMENTED" cancelLatencyMs)ms，" \
         "取消被观察=$(json_field "$SEGMENTED" cancellationObserved)）"
  else
    echo "  （规划段数=${segCount}，未超过分段阈值，无分段模式对照）"
  fi
done

echo "工作目录保留：$WORK"
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo "PASS: --verify-memory 全部样本完成（实测数值见上表）"
exit 0
