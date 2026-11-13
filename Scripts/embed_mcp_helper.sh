#!/bin/sh
set -eu

# Xcode target dependency 保证 helper 已构建、已签名，再嵌入主应用。
helper_source="${BUILT_PRODUCTS_DIR}/memozia-mcp"
helper_destination="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
test -x "$helper_source"
mkdir -p "$helper_destination"
ditto "$helper_source" "${helper_destination}/memozia-mcp"
