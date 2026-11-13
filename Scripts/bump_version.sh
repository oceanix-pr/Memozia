#!/bin/bash
# 发布版本号手动升级脚本（仅在发布新版本时手动调用，不参与构建流程）
#
# 用法：
#   Scripts/bump_version.sh patch   # 2.0.4 → 2.0.5
#   Scripts/bump_version.sh minor   # 2.0.4 → 2.1.0
#   Scripts/bump_version.sh major   # 2.0.4 → 3.0.0
#   Scripts/bump_version.sh 2.5.0   # 直接指定版本号
#
# 设计说明：
# - 营销版本号（MARKETING_VERSION / CFBundleShortVersionString）面向用户，
#   只在发布时变化，因此只允许手动升级，绝不在构建中自动递增
# - project.yml 是唯一事实源（xcodegen 据此生成 pbxproj），
#   本脚本只改 project.yml，改完需执行 xcodegen generate 生效
# - 每次构建唯一性由构建号（CURRENT_PROJECT_VERSION）保证，
#   见 Scripts/bump_build_number.sh

set -e

if [ -z "$SRCROOT" ]; then
    SRCROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
PROJECT_YML="${SRCROOT}/project.yml"

if [ ! -f "$PROJECT_YML" ]; then
    echo "错误：未找到 ${PROJECT_YML}" >&2
    exit 1
fi

# 读取当前营销版本号（唯一事实源：project.yml）
CURRENT=$(sed -n 's/.*MARKETING_VERSION: "\([0-9.]*\)".*/\1/p' "$PROJECT_YML" | head -1)
if [ -z "$CURRENT" ]; then
    echo "错误：无法从 project.yml 解析 MARKETING_VERSION" >&2
    exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}

case "${1:-}" in
    patch)
        PATCH=$((PATCH + 1))
        ;;
    minor)
        MINOR=$((MINOR + 1)); PATCH=0
        ;;
    major)
        MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0
        ;;
    "")
        echo "用法：$0 patch|minor|major|<版本号>（当前版本 ${CURRENT}）" >&2
        exit 1
        ;;
    *)
        # 直接指定版本号，校验格式
        if ! echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "错误：版本号格式应为 X.Y.Z，收到：$1" >&2
            exit 1
        fi
        MAJOR=$(echo "$1" | cut -d. -f1)
        MINOR=$(echo "$1" | cut -d. -f2)
        PATCH=$(echo "$1" | cut -d. -f3)
        ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"

sed -i '' "s/MARKETING_VERSION: \"[0-9.]*\"/MARKETING_VERSION: \"${NEW_VERSION}\"/" "$PROJECT_YML"

echo "营销版本号：${CURRENT} → ${NEW_VERSION}"
echo "提示：请执行 xcodegen generate 使新版本号写入工程文件"
