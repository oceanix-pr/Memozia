#!/bin/bash
# 动态框架产物收尾与校验（构建后执行）：
# 1. 使用与 App 一致的身份重签构建产物目录下的动态 framework。Xcode 运行/测试时
#    会把 CONFIGURATION_BUILD_DIR 注入 DYLD_LIBRARY_PATH，优先加载这里的副本；
#    pre-build 的 install_name_tool 会使上游签名失效，如果只签 App 内的嵌入副本，
#    测试宿主会在建立 XCTest 连接前被 AMFI 终止。
# 2. 确认所有可能被加载的 SherpaOnnxC 都来自关闭 TTS 的上游构建，
#    并校验其链接的 onnxruntime.framework 实际可用。
#
# 背景：上游产物引用 libonnxruntime.dylib，若 Scripts/fix_onnxruntime_framework.sh
# 没找到产物目录（或 install_name_tool 失败），构建照样成功，但应用启动即
# “Library not loaded: @rpath/libonnxruntime.dylib” 崩溃——只有在跑测试/装包时才发现。
# 这里把校验放在构建链末段：宁可构建失败，也不要产出不可启动的 App。
#
# 注意：SwiftPM 会同时产生 CONFIGURATION_BUILD_DIR 副本与 App 嵌入副本。
# 普通启动主要使用 App 内副本，Xcode 调试/测试可能由 DYLD_LIBRARY_PATH 优先加载
# 构建目录副本，因此存在的两份都必须检查。
set -u

BUILD_PRODUCTS="${CONFIGURATION_BUILD_DIR:-}"
if [ -z "$BUILD_PRODUCTS" ]; then
    BUILD_PRODUCTS="${BUILD_DIR:-}/${CONFIGURATION:-Debug}"
fi
APP="$BUILD_PRODUCTS/Memozia.app"

# 非 App 构建（仅编译依赖等）无需校验
if [ ! -d "$APP" ]; then
    exit 0
fi

APP_FW="$APP/Contents/Frameworks/SherpaOnnxC.framework"
PROD_FW="$BUILD_PRODUCTS/SherpaOnnxC.framework"
if [ -d "$PROD_FW" ] && [ ! -f "$APP_FW/Versions/A/SherpaOnnxC" ]; then
    rm -rf "$APP_FW"
    if ! /usr/bin/ditto "$PROD_FW" "$APP_FW"; then
        echo "error: 无法刷新 App 内嵌的 SherpaOnnxC.framework" >&2
        exit 1
    fi
fi

# Xcode 增量构建可能保留上一份框架。逐一检查可加载副本并替换旧的二进制，再重签。
if [ ! -f "$APP_FW/Versions/A/SherpaOnnxC" ]; then
    echo "error: 缺少 App 内嵌的 SherpaOnnxC.framework" >&2
    exit 1
fi
sherpa_frameworks=("$APP_FW")
sherpa_binaries=("$APP_FW/Versions/A/SherpaOnnxC")
if [ -f "$PROD_FW/Versions/A/SherpaOnnxC" ]; then
    sherpa_frameworks+=("$PROD_FW")
    sherpa_binaries+=("$PROD_FW/Versions/A/SherpaOnnxC")
fi
source_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
package_cache="${MEMOZIA_PACKAGE_CACHE_PATH:-${OBJROOT:-$BUILD_PRODUCTS/..}/../../SourcePackages}"
/bin/bash "$source_root/Scripts/install_sherpa_no_tts.sh" "$package_cache/Memozia" "${sherpa_binaries[@]}" || exit 1

# 修改过 Mach-O 后上游签名已失效。App 内副本由 Xcode 自动重签，但构建目录副本不会；
# 后者却会在 Xcode Run/Test 时被优先加载，所以必须显式重签。
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
    if [ -n "$signing_identity" ]; then
        # ProcessXCFramework 有时早于应用 target 的 pre-build 脚本执行，因此当次的
        # 构建目录副本仍可能保留上游的根目录 Modules。在签名前再幂等地规范一次。
        runtime_framework="$BUILD_PRODUCTS/onnxruntime.framework"
        if [ -d "$runtime_framework/Versions/A" ]; then
            if [ ! -L "$runtime_framework/Versions/Current" ]; then
                rm -rf "$runtime_framework/Versions/Current"
                ln -s A "$runtime_framework/Versions/Current"
            fi
            for name in onnxruntime Headers Resources Modules; do
                if [ -e "$runtime_framework/$name" ] && [ ! -L "$runtime_framework/$name" ]; then
                    if [ ! -e "$runtime_framework/Versions/A/$name" ]; then
                        mv "$runtime_framework/$name" "$runtime_framework/Versions/A/$name"
                    else
                        rm -rf "$runtime_framework/$name"
                    fi
                fi
                if [ -e "$runtime_framework/Versions/A/$name" ] && [ ! -L "$runtime_framework/$name" ]; then
                    rm -rf "$runtime_framework/$name"
                    ln -s "Versions/Current/$name" "$runtime_framework/$name"
                fi
            done
        fi

        timestamp_option="--timestamp=none"
        if [ "${CONFIGURATION:-}" = "Release" ] && [ "$signing_identity" != "-" ]; then
            timestamp_option="--timestamp"
        fi
        for product_framework in "$BUILD_PRODUCTS/SherpaOnnxC.framework" \
                                 "$BUILD_PRODUCTS/onnxruntime.framework" \
                                 "$APP/Contents/Frameworks/SherpaOnnxC.framework"; do
            [ -d "$product_framework" ] || continue
            if ! /usr/bin/codesign --force --sign "$signing_identity" \
                --options runtime "$timestamp_option" "$product_framework"; then
                echo "error: 无法重签构建产物中的动态框架：$product_framework" >&2
                exit 1
            fi
        done
    else
        echo "error: 已启用代码签名，但未获得 EXPANDED_CODE_SIGN_IDENTITY/CODE_SIGN_IDENTITY" >&2
        exit 1
    fi
fi

for framework in "${sherpa_frameworks[@]}"; do
    BIN="$framework/Versions/A/SherpaOnnxC"
    links="$(otool -L "$BIN" 2>/dev/null || true)"

    if printf '%s\n' "$links" | grep -q "libonnxruntime\.dylib"; then
        cat >&2 <<EOF
error: SherpaOnnxC 仍引用 @rpath/libonnxruntime.dylib（${BIN}），应用启动会因
       "Library not loaded" 崩溃。
       请检查构建日志中 "Fix Onnxruntime Framework Layout" 阶段，以及
       Scripts/fix_onnxruntime_framework.sh 是否能
       在本次 DerivedData 的 SourcePackages/artifacts 下找到产物。
EOF
        exit 1
    fi

    # 引用 onnxruntime.framework 时，同一加载位置必须有对应框架。
    if printf '%s\n' "$links" | grep -q "@rpath/onnxruntime\.framework"; then
        if [[ "$framework" == "$APP/Contents/Frameworks/"* ]]; then
            runtime="$APP/Contents/Frameworks/onnxruntime.framework/Versions/A/onnxruntime"
        else
            runtime="$BUILD_PRODUCTS/onnxruntime.framework/Versions/A/onnxruntime"
        fi
        if [ ! -f "$runtime" ]; then
            echo "error: SherpaOnnxC 引用 @rpath/onnxruntime.framework，但同一加载位置没有该框架（${BIN}）" >&2
            exit 1
        fi
    fi

    if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ] && \
       ! /usr/bin/codesign --verify --strict "$framework"; then
        echo "error: 动态框架签名无效：$framework" >&2
        exit 1
    fi

    echo "Verified dynamic framework: SherpaOnnxC no-TTS build, linkage and signature OK (${framework})"
done

# AVKit 加载命令校验（防回归）：
# SwiftUI VideoPlayer 的实现位于 _AVKit_SwiftUI 垫片框架，其表示类型的 ObjC 父类在 AVKit；
# macOS 27 SDK 起仅 import AVKit 不再自动链接 AVKit.framework，若加载命令缺失，首帧构建
# VideoPlayer 时 Swift 运行时在 getSuperclassMetadata 解析不到父类而 fatalError abort
#（见 BUG.txt）。这里断言主可执行文件带有 AVKit 加载命令，避免构建参数改动后“修好又改回去”。
# Debug 构建下 Contents/MacOS/Memozia 只是 Xcode 的 debug dylib 桩（仅链接
# Memozia.debug.dylib），真正包含应用代码与框架依赖的是 Memozia.debug.dylib；
# Release 才把代码放进主可执行文件。因此检查「含代码的那个二进制」。
APP_EXEC="$APP/Contents/MacOS/Memozia"
[ -f "$APP/Contents/MacOS/Memozia.debug.dylib" ] && APP_EXEC="$APP/Contents/MacOS/Memozia.debug.dylib"
if [ -f "$APP_EXEC" ]; then
    app_links="$(otool -L "$APP_EXEC" 2>/dev/null || true)"
    avkit_lines="$(printf '%s\n' "$app_links" | grep -i -E "AVKit" || true)"
    echo "----- AVKit-related dependencies of ${APP_EXEC} -----"
    printf '%s\n' "${avkit_lines:-(none)}"
    echo "-----------------------------------------------------"

    if ! printf '%s\n' "$avkit_lines" | grep -q "AVKit\.framework"; then
        if printf '%s\n' "$app_links" | grep -q "_AVKit_SwiftUI\.framework"; then
            cat >&2 <<EOF
error: 应用代码未链接 AVKit.framework（${APP_EXEC}），但仍链接了 _AVKit_SwiftUI。
       说明产物里仍是 SwiftUI VideoPlayer（它由 _AVKit_SwiftUI 垫片实现，运行时才需要
       AVKit 的父类元数据）。即本次构建没有产出「画面」页改用 AVPlayerView 后的二进制，
       通常是增量构建复用了陈旧产物。请 clean 后重建：
         DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
           -project Memozia.xcodeproj -scheme Memozia -configuration Debug \
           -destination 'platform=macOS' clean build
EOF
        else
            cat >&2 <<EOF
error: 应用代码未链接 AVKit.framework（${APP_EXEC}）。
       上方已打印实际依赖列表。若 AVKit 与 _AVKit_SwiftUI 均未出现，说明链接参数未生效，请确认：
       1) 已运行 xcodegen generate（OTHER_LDFLAGS 在生成时才写入工程）；
       2) project.yml 的 OTHER_LDFLAGS 含 "-Xlinker -needed_framework -Xlinker AVKit"
          （注意：Swift 目标的链接驱动是 swiftc，它不接受 clang 的 "-Wl," 写法）；
       3) 已 clean 重建。
EOF
        fi
        exit 1
    fi
    echo "Verified AVKit linkage: OK (${APP_EXEC})"
fi
