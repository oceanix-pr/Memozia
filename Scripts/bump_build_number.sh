#!/bin/bash
# 仅在发布前手动分配构建号；构建阶段不再修改源码或产物。
set -euo pipefail
if [ -n "${CONFIGURATION:-}" ]; then
    echo "error: 构建期间不能分配版本号，请在打 tag 前运行本脚本" >&2
    exit 1
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$project_root/project.yml" "${1:-}" <<'PYBUILD'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
s = path.read_text()
m = re.search(r'CURRENT_PROJECT_VERSION: "([0-9]+)"', s)
if not m: raise SystemExit('未找到构建号')
current = int(m[1])
new = int(sys.argv[2]) if sys.argv[2] else current + 1
if new <= current: raise SystemExit('新构建号必须大于当前构建号')
path.write_text(s[:m.start(1)] + str(new) + s[m.end(1):])
print(f'构建号：{current} → {new}；请重新生成工程、提交后打 tag')
PYBUILD
