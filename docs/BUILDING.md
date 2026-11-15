# Build Memozia from source

For the ready-to-run app, use [Releases](https://github.com/oceanix-pr/Memozia/releases). The downloadable preview does not require Xcode. This page is for contributors building the macOS project.

## Development requirements

- A Mac with the SDK required by the current source; `project.yml` specifies Xcode 27.1 and Swift 6.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- Access to Swift Package Manager dependency downloads on the first build.

The app's minimum runtime is macOS 15. The development SDK requirement is separate from that minimum. The current downloadable preview targets Apple Silicon; source availability does not imply that an Intel release has been validated.

## Generate and build

Run these commands at the repository root, adjusting the Xcode path if necessary:

```sh
xcodegen generate

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Memozia.xcodeproj -scheme Memozia \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

`project.yml` is the project configuration source. Regenerate after adding or removing Swift files, changing dependencies or project settings, or editing a build script embedded by XcodeGen. Do not hand-edit the generated `.xcodeproj`.

The scheme's framework preparation and **Verify Embedded Frameworks** phases are required. They repair and verify the ONNX Runtime/Sherpa framework layout, dynamic-library references, and signatures. Keep them enabled when diagnosing a build failure.

## Validate a contribution

```sh
python3 Scripts/check_l10n.py

TEST_RUNNER_MEMOZIA_EPHEMERAL_TEST_ENCRYPTION=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Memozia.xcodeproj -scheme Memozia \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:MemoziaTests
```

Choose checks that match the change. UI tests need a graphical macOS session and the relevant system permissions. Visual regression tests also need reviewed baseline images; a successful build does not establish that recording, permissions, or update recovery work on a particular device.

For detailed testing controls, dependency repair, and runtime diagnostics, see the [build and run reference](wiki/13-构建与运行.md).

## Models and permissions

Speech and language models are not bundled with the source. Use the app's model preparation or configure a local model folder. Local summaries require a running compatible language-model service; see the [local setup guide](articles/local-meeting-notes.md).

Use fictional sample material for development. Microphone, screen recording, speech recognition, and Reminders permissions are requested when their corresponding features are used. Keep API keys and encryption keys in Keychain.

## 中文说明

普通用户请直接下载预览包，不需要安装 Xcode。开发者以 `project.yml` 为准配置 Xcode 27.1、Swift 6 与 XcodeGen；增删源文件、修改工程或构建脚本后重新生成工程。保留 ONNX 修复和嵌入框架校验。详细命令、模型准备、图形界面测试与运行验收边界见[构建与运行](wiki/13-构建与运行.md)。
