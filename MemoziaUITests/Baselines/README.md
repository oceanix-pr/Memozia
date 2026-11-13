# 截图基线目录

`*.png` 为 XCUITest 主窗口截图基线，覆盖多语言 / RTL / 伪本地化配置，随测试 bundle 打包只读比对。

> **当前状态：暂无基线 PNG，待重录。** 空状态文案变更（「从左侧列表选择，或导入音视频、新建笔记」）使旧基线失效，旧图已删除；请按下方流程重录并提交。在补齐之前，正常快照用例会明确失败，不能当作视觉回归已通过。

使用方：[LocalizationSnapshotUITests.swift](../LocalizationSnapshotUITests.swift) 与
[MemoziaSmokeUITests.swift](../MemoziaSmokeUITests.swift)（经 `UITestSupport.swift` 的
`verifyScreenshot(_:named:)`）。

- 基线文件名：`main_window_<语言或配置>.png`（见 `UITestLanguage.baselineName` 与
  `UITestLaunchConfiguration.name`）。
- 比对：等比缩放到固定宽度后，统计单通道差值超阈值的像素占比，超过 2% 即失败。
- 基线缺失：失败，并保留当前截图附件供排查。只在显式设置 `UPDATE_UI_BASELINES=1` 且不在 CI 时录制。
- CI 每次运行启动冒烟；严格视觉回归由手动触发 CI 的 `visual_regression` 开关启用。缺少基线或误启录制均失败，不自动接受截图。

## 记录 / 更新基线

UI 测试 runner 受沙盒 + TCC 限制，无法写入受保护的项目目录，且其容器外部不可读，
因此通过**结果包附件**导出（与 `UITestSupport.swift` 顶部说明一致）：

```sh
# 1. 固定系统、屏幕缩放、主题和窗口尺寸，显式录制并落结果包
TEST_RUNNER_UPDATE_UI_BASELINES=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug \
  -destination 'platform=macOS' test -only-testing:MemoziaUITests \
  -resultBundlePath /tmp/ui.xcresult

# 2. 导出截图附件
xcrun xcresulttool export attachments --path /tmp/ui.xcresult --output-path /tmp/ui-attach

# 3. 按 /tmp/ui-attach/manifest.json 的建议名，把 PNG 拷回本目录并提交
```

如需强制重录已有基线，可在 scheme 的 Test action 里设置环境变量
`UPDATE_UI_BASELINES=1`（可另设可写目录 `Memozia_UI_BASELINE_DIR`）；
shell 里直接 `export` 不会透传给 runner。
