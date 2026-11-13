#!/bin/bash
# 修复 sherpa-onnx shared 产物的两个上游打包问题（构建前执行，幂等）：
# 1. csukuangfj/onnxruntime-libs 的 shared xcframework 用实体目录/文件复制代替标准
#    符号链接（Versions/Current 为实体目录、顶层存在重复的二进制与 Info.plist），
#    Xcode 嵌入后 codesign --verify --strict 会报 "invalid Info.plist"；
# 2. SherpaOnnxC 二进制引用 @rpath/libonnxruntime.dylib，而实际嵌入的是
#    onnxruntime.framework（install name 为 @rpath/onnxruntime.framework/Versions/A/onnxruntime），
#    导致启动时 dyld 报 Library missing 崩溃。
#
# 产物目录只定位「本次构建所用的」DerivedData：BUILD_DIR / BUILD_ROOT 均为
# …/DerivedData/<工程>/Build/Products（**不含**配置目录），故 SourcePackages/artifacts
# 是其兄弟目录，路径为 ../../SourcePackages/artifacts。旧实现写 ../../../、多退一级后
# 落到 DerivedData 根，自定义 DerivedData 与 CI 上会静默找不到产物（应用照旧嵌错引用），
# 当时靠遍历 ~/Library/Developer/Xcode/DerivedData/* 兜底，代价是会扫描并改写其他工程的
# 产物，现改为只认本次构建目录 + 仓库内 .packages（-packageCachePath 场景）。
set -eu
shopt -s nullglob

roots=()
add_root() {
    local candidate="$1"
    [ -n "$candidate" ] && [ -d "$candidate" ] || return 0
    for existing in "${roots[@]:-}"; do
        [ "$existing" = "$candidate" ] && return 0
    done
    roots+=("$candidate")
}

# 发布脚本显式传入的本次 SwiftPM 路径；不扫描其他项目的缓存。
if [ -n "${MEMOZIA_PACKAGE_CACHE_PATH:-}" ]; then
    add_root "$MEMOZIA_PACKAGE_CACHE_PATH/artifacts"
fi

# 仓库内产物（构建时指定 -packageCachePath .packages 的场景）
add_root "${SRCROOT:-}/.packages/artifacts"
# 本次构建的 DerivedData：BUILD_DIR / BUILD_ROOT 指向 …/Build/Products，
# OBJROOT 指向 …/Build/Intermediates.noindex，两者上溯两级即 DerivedData 工程目录
add_root "${BUILD_DIR:-}/../../SourcePackages/artifacts"
add_root "${BUILD_ROOT:-}/../../SourcePackages/artifacts"
add_root "${OBJROOT:-}/../../SourcePackages/artifacts"

if [ "${#roots[@]}" -eq 0 ]; then
    echo "WARNING: 未找到 SourcePackages/artifacts 产物目录，跳过产物修复；后续 'Verify Embedded Frameworks' 阶段会校验嵌入结果" >&2
fi

layout_fixed=0
dylib_fixed=0
dylib_failed=0

for root in "${roots[@]:-}"; do
    for fw in "$root"/onnxruntime-libs/*/onnxruntime.xcframework/*/onnxruntime.framework \
              "$root"/extract/onnxruntime-libs/*/onnxruntime.xcframework/*/onnxruntime.framework; do
        [ -d "$fw/Versions/A" ] || continue
        changed=0
        if [ ! -L "$fw/Versions/Current" ]; then
            rm -rf "$fw/Versions/Current"
            ln -s A "$fw/Versions/Current"
            changed=1
        fi
        for name in onnxruntime Headers Resources Modules; do
            # 上游的 Modules 只在 framework 根目录，而其他内容可能在
            # 根目录和 Versions/A 同时存在。先把唯一副本移入 A，再统一建立符号链接。
            if [ -e "$fw/$name" ] && [ ! -L "$fw/$name" ]; then
                if [ ! -e "$fw/Versions/A/$name" ]; then
                    mv "$fw/$name" "$fw/Versions/A/$name"
                else
                    rm -rf "$fw/$name"
                fi
                changed=1
            fi
            if [ -e "$fw/Versions/A/$name" ]; then
                if [ ! -L "$fw/$name" ]; then
                    rm -rf "$fw/$name"
                    ln -s "Versions/Current/$name" "$fw/$name"
                    changed=1
                fi
            fi
        done
        if [ "$changed" -eq 1 ]; then
            layout_fixed=$((layout_fixed + 1))
            echo "Normalized framework layout: $fw"
        fi
    done

    # 修复 SherpaOnnxC 对 libonnxruntime.dylib 的错误引用（指向 onnxruntime.framework 的真实路径）
    for fw in "$root"/sherpa-onnx/*/sherpa-onnx.xcframework/*/SherpaOnnxC.framework \
              "$root"/extract/sherpa-onnx/*/sherpa-onnx.xcframework/*/SherpaOnnxC.framework; do
        bin="$fw/Versions/A/SherpaOnnxC"
        [ -f "$bin" ] || continue
        if otool -L "$bin" 2>/dev/null | grep -q "libonnxruntime.dylib"; then
            if install_name_tool -change "@rpath/libonnxruntime.dylib" \
                "@rpath/onnxruntime.framework/Versions/A/onnxruntime" "$bin" 2>/dev/null; then
                dylib_fixed=$((dylib_fixed + 1))
                echo "Fixed dylib reference: $bin"
            else
                # 改不动就必须让构建失败：继续下去会产出一个启动即崩溃的 App，
                # 旧实现只打 WARNING 并 exit 0
                echo "error: install_name_tool 修复失败，产物仍引用 libonnxruntime.dylib: $bin" >&2
                dylib_failed=$((dylib_failed + 1))
            fi
        fi
    done
done

if [ "$dylib_failed" -gt 0 ]; then
    echo "error: $dylib_failed 个 SherpaOnnxC 产物的 dylib 引用未能修复，中止构建" >&2
    exit 1
fi

echo "onnxruntime 产物修复完成：规范布局 $layout_fixed 个，dylib 引用 $dylib_fixed 个，产物目录 ${#roots[@]} 个"

# 注意：这里**不再删除** App 内嵌副本。
# 实测 Xcode 的「Embed Frameworks」不会仅仅因为该文件被删除就重新拷贝（它认为输出已是
# 最新，Debug 使用 debug dylib 时尤其明显），删除反而会让 App 缺失 SherpaOnnxC、
# 启动即 “Library not loaded”。内嵌副本的刷新与重签统一交给构建末段的
# Verify Embedded Frameworks 阶段处理（那里能拿到签名身份，也能一并做校验）。

exit 0
