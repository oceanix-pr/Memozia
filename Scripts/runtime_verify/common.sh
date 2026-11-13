#!/bin/bash
# 运行时验证脚本共用工具：定位仓库根与构建产物可执行文件。
# 说明：各检查里的阈值均为「暂定、可按机器调整」，可用环境变量覆盖。
set -uo pipefail

# 非 UTF-8 环境下，bash 会把「变量名紧跟多字节字符」的首字节并进变量名导致解析失败；
# 显式给出 UTF-8 默认值（脚本内变量引用也已统一用 ${} 包裹，双重保险）
export LANG="${LANG:-en_US.UTF-8}"
export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"

RUNTIME_VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RUNTIME_VERIFY_DIR/../.." && pwd)"
export RUNTIME_VERIFY_DIR REPO_ROOT

DEFAULT_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# 定位应用可执行文件：优先 $Memozia_APP；否则查 xcodebuild 的 BUILT_PRODUCTS_DIR
resolve_app_binary() {
  if [ -n "${Memozia_APP:-}" ] && [ -x "${Memozia_APP}" ]; then
    printf '%s' "${Memozia_APP}"
    return 0
  fi
  local products
  products="$(DEVELOPER_DIR="${DEVELOPER_DIR:-$DEFAULT_DEVELOPER_DIR}" \
    xcodebuild -project "$REPO_ROOT/Memozia.xcodeproj" -scheme Memozia -configuration Debug \
    -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -n 1)"
  if [ -z "$products" ]; then
    return 1
  fi
  local app="$products/Memozia.app/Contents/MacOS/Memozia"
  if [ ! -x "$app" ]; then
    return 1
  fi
  printf '%s' "$app"
}

# 从单行 JSON 中取字段值（不依赖 jq；布尔值统一输出 true/false）
json_field() {
  local json="$1" key="$2"
  python3 -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or sys.argv[2] not in data:
    sys.exit(0)
value = data[sys.argv[2]]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
' "$json" "$key"
}

# 数值比较：num_lt A B → A < B 返回 0
num_lt() {
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)' "$1" "$2"
}

# 字节转 MB（保留 1 位小数）
bytes_to_mb() {
  python3 -c 'import sys; print("%.1f" % (float(sys.argv[1]) / 1048576.0))' "$1"
}
