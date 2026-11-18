#!/bin/bash
# Keep SwiftPM's framework module and headers, and install the matching upstream
# macOS dylib built with SHERPA_ONNX_ENABLE_TTS=OFF.
set -euo pipefail

release="v1.13.6"
asset="sherpa-onnx-$release-osx-universal2-shared-no-tts-lib"
checksum="812b144d199fd9a5b8ccbe4a5d81df8b8f55fc28212523b9dee9cacbc9fc5a76"
expected_uuids=$'754A70D6-44F7-3529-BC17-BF18D87A5608 (arm64)\nF3FA86CE-C5C0-394C-8604-527EF17F0EAC (x86_64)'
framework_id="@rpath/SherpaOnnxC.framework/Versions/A/SherpaOnnxC"
runtime_id="@rpath/onnxruntime.framework/Versions/A/onnxruntime"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 cache-directory path/to/SherpaOnnxC [...]" >&2
    exit 1
fi
cache_dir="$1"
shift

is_prepared() {
    local uuids links
    uuids="$(/usr/bin/dwarfdump --uuid "$1" | awk '{print $2, $3}' | LC_ALL=C sort)" || return 1
    [ "$uuids" = "$expected_uuids" ] || return 1
    links="$(/usr/bin/otool -L "$1")" || return 1
    [[ "$links" == *"$framework_id"* && "$links" == *"$runtime_id"* && "$links" != *"libonnxruntime.dylib"* ]]
}

pending=()
for binary in "$@"; do
    if [ ! -f "$binary" ]; then
        echo "error: Missing SherpaOnnxC binary at $binary" >&2
        exit 1
    fi
    if ! is_prepared "$binary"; then
        pending+=("$binary")
    fi
done
[ "${#pending[@]}" -gt 0 ] || exit 0

verify_archive() {
    local actual
    [ -f "$1" ] || return 1
    actual="$(/usr/bin/shasum -a 256 < "$1")" || return 1
    [ "${actual%% *}" = "$checksum" ]
}

mkdir -p "$cache_dir"
work_dir="$(mktemp -d "$cache_dir/.sherpa-no-tts.XXXXXX")"
pending_file=""
trap 'rm -rf "$work_dir"; if [ -n "$pending_file" ]; then rm -f "$pending_file"; fi' EXIT

archive="${MEMOZIA_SHERPA_NO_TTS_ARCHIVE:-$cache_dir/$asset.tar.bz2}"
if ! verify_archive "$archive"; then
    if [ -n "${MEMOZIA_SHERPA_NO_TTS_ARCHIVE:-}" ]; then
        echo "error: Invalid Sherpa no-TTS archive at $archive (expected SHA-256 $checksum)" >&2
        exit 1
    fi
    echo "Downloading the Sherpa $release macOS build without TTS"
    download="$work_dir/$asset.tar.bz2"
    /usr/bin/curl --http1.1 --fail --silent --show-error --location \
        --retry 2 --retry-all-errors --connect-timeout 20 --max-time 600 \
        --output "$download" \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/$release/$asset.tar.bz2"
    if ! verify_archive "$download"; then
        echo "error: Sherpa no-TTS archive did not match SHA-256 $checksum" >&2
        exit 1
    fi
    mv -f "$download" "$archive"
fi

replacement="$work_dir/SherpaOnnxC"
/usr/bin/tar -xOf "$archive" "$asset/lib/libsherpa-onnx-c-api.dylib" > "$replacement"
/usr/bin/install_name_tool -id "$framework_id" \
    -change "@rpath/libonnxruntime.dylib" "$runtime_id" "$replacement"
if ! is_prepared "$replacement"; then
    echo "error: Sherpa no-TTS binary failed its UUID or linkage check" >&2
    exit 1
fi
/usr/bin/codesign --force --sign - --timestamp=none "$replacement"

for binary in "${pending[@]}"; do
    pending_file="$(mktemp "$binary.XXXXXX")"
    /usr/bin/install -m 755 "$replacement" "$pending_file"
    mv -f "$pending_file" "$binary"
    pending_file=""
    echo "Installed Sherpa $release without TTS: $binary"
done
