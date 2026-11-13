# 13 · Build and Run

[← Home](Home.md)

## 1. Project and environment

[project.yml](../../../project.yml) is the XcodeGen source of truth for deployment target, Swift language mode, Xcode project version, targets, signing, and packages. It declares macOS 15 minimum deployment, Swift 6, and Xcode 27 project compatibility. The build toolchain must also include SDK APIs referenced by source. Minimum supported runtime is not the same as minimum development environment; the old macOS 13/Xcode 16 assumption is obsolete.

`Memozia`, Swift Testing target `MemoziaTests`, and XCUITest target `MemoziaUITests` are macOS-only. iOS and its sharing extension were removed.

### Application display name

The application file and system display name are always `Memozia`. Keep `PRODUCT_NAME` and `INFOPLIST_KEY_CFBundleDisplayName` in `project.yml` consistent with `CFBundleName` and `CFBundleDisplayName` in `InfoPlist.xcstrings`. Simplified and Traditional Chinese localizations must not override the Finder or Dock name. Verify the built app's base Info.plist and localized InfoPlist.strings, rather than only source configuration.


## 2. Build and test

Run from the repository root. Adjust `DEVELOPER_DIR` if Xcode is installed elsewhere; an `xcode-select` pointing only to Command Line Tools does not provide the full SDK.

```sh
# First generation, source add/remove, dependency/configuration changes
xcodegen generate

# Debug build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' build

# Swift Testing unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' test -only-testing:MemoziaTests

# UI smoke tests, accessibility, localization/RTL/pseudolocalization baselines
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' test -only-testing:MemoziaUITests
```

Do not edit the generated `.xcodeproj` manually. Configure an available signing team locally and regenerate when needed. `TEST_HOST` explicitly points to the app's `Contents/MacOS` executable. Changes to build scripts under `Scripts/` also require regeneration: XcodeGen embeds their contents, so otherwise Xcode runs an old copy. Documentation-only changes do not require generation.

## 3. Models and first run

- Consent precedes experience-specific onboarding. Onboarding no longer includes a model download page; prepare models on first use or manage them in Pro settings. Request microphone, speech, screen recording, Accessibility, and Reminders permissions as required by the chosen feature.
- On macOS 26+, `SystemTranscription`/`SystemTranscriptionService` use SpeechAnalyzer with system-managed language assets, independent of Whisper folders. `STTMode.defaultMode` and experience resolution select according to system capability; older systems retain WhisperKit.
- Local Whisper uses a selected folder, defaulted by `WhisperModelFolder.defaultPath`; CoreML/tokenizer files must be complete. Loading resolves nested model folders.
- Model downloads use `WhisperModelOption.catalog` and the chosen Hugging Face/HF-Mirror source (mirror default). Pass the endpoint explicitly to `WhisperKit.download`, then move `<folder>/models/<repo>/<tier>` to `<folder>/<tier>` and load it. `TaskCenter.whisperDownloadJob` supports genuine pause/resume by preserving downloaded pieces and `.cache` metadata on cancellation.
- `Resources/Models/**` is excluded from the app. Do not assume tiny/base/small/medium models are bundled.
- Diarization uses segmentation.onnx and embedding.onnx. Models may be downloaded or supplied in settings; first use calls `ensureModelsReady`. The URLSession download preserves `.resume` data on cancellation and uses `downloadTask(withResumeData:)` when restarting.
- LLM configuration accepts OpenAI-compatible services. Preserve URL validation; the loopback HTTP exception does not authorize arbitrary LAN/remote plaintext endpoints.

## 4. Scripts and resources

| Script | Purpose |
|---|---|
| [fix_onnxruntime_framework.sh](../../../Scripts/fix_onnxruntime_framework.sh) | Pre-build framework layout/reference repair |
| [verify_embedded_frameworks.sh](../../../Scripts/verify_embedded_frameworks.sh) | Re-sign build-product frameworks used by Xcode Run/Test and verify SherpaOnnxC references/signatures |
| [bump_build_number.sh](../../../Scripts/bump_build_number.sh) | Manually allocate a build number before release; never auto-increment on build |
| [bump_version.sh](../../../Scripts/bump_version.sh) | Manual patch/minor/major marketing-version changes, followed by generation |

### ONNX output repair and verification

Upstream dynamic binaries have two packaging problems: framework directories replace required symlinks, and SherpaOnnxC references absent `@rpath/libonnxruntime.dylib`. The first breaks strict embedded signing; the second prevents launch.

Repair locates only this build's artifacts. `BUILD_DIR`/`BUILD_ROOT` end at `Build/Products`, with SourcePackages/artifacts two levels above; explicit `MEMOZIA_PACKAGE_CACHE_PATH`, `OBJROOT`, and repository `.packages` are also supported. Do not scan unrelated DerivedData or ignore `install_name_tool` errors.

SwiftPM produces both configuration-directory and app-embedded copies. Xcode Run/Test prefers the former via `DYLD_LIBRARY_PATH`; modifying load commands invalidates their signatures. The post-build script signs them with the app identity and verifies both locations, preventing an apparently successful build from being killed by AMFI at launch. Do not disable or weaken this check.

`Memozia` disables `ENABLE_USER_SCRIPT_SANDBOXING` specifically because these scripts modify dynamically hashed binary paths and recursively inspect framework extended attributes. This setting does not disable the app's Hardened Runtime or final code signing. The explicit unnotarized-preview override is a separate release behavior.

### Localization and assets

`Scripts/add_*l10n*.py` are one-off maintenance tools, not required build steps. `fill_empty_l10n.py` statically parses their `add(source, [translations])` calls without importing/executing them, because some mutate files at import time. It fills missing translations/source entries only, preserves existing text, checks placeholder type/count, and lists uncovered keys.

UI text lives in `Localizable.xcstrings`; supported regions come from actual resources and `knownRegions`. Keep placeholder types consistent across languages. Inspect current icon source/Assets references before generating sizes rather than assuming an old `icon.png` path.

## 5. Validation boundaries

- `MemoziaTests.swift`: duration/configuration/status, import/video naming, keyframe fingerprints/events/budgets, document exports.
- `KeyframeExtractorTests.swift`: representative-frame deduplication/refill across time windows and `LLMService.visualChunks` batching.
- `StabilityRegressionTests.swift`: watchdogs, cancellation gates, streaming batches, timeout budgets, disk pacing, unique directories, failure reporting, dictionary scanning.
- `WhisperModelDownloadTests.swift`: catalog naming/glob uniqueness, repository tiers, endpoints/defaults, `HF_ENDPOINT`, three-component readiness, tier isolation; no network.
- Consult current source/results instead of recording test counts or permanent passing claims in the Wiki.
- Type checking does not cover linking, signing, or runtime behavior. Audio devices, permissions, Keychain, windows, recovery, and worker takeover require relevant [regression scenarios](../../TECH_DEBT.md). UI tests need a graphical macOS session and permissions.

## 6. SDK compatibility

AudioConverter uses provider/receiver async APIs on macOS 26+ and retains Reader/Writer fallbacks. System capture uses SampleBufferReceiver; microphone capture has a read-only tap path on macOS 27+. Guard SDK additions with availability checks instead of raising minimum deployment merely to silence deprecations. The valid XcodeGen key is `deploymentTarget`; the old incorrect `deploymentTargets` failed to generate minimum versions correctly.

## 7. Debugging

| Scenario | Entry point |
|---|---|
| Diarization calibration | Executable `--calibrate-diarization <audio> [threshold or centroid/refine mode] [model-folder]`; follow DiarizationCalibrator arguments |
| Background worker | `--background-worker` consumes the real queue; use isolated test data only; see Architecture §3 |
| Reminders URL | `reminders_url_diagnostic` enables RemindersURLDiagnostic; output is not permanent documentation context |
| Long-recording save failure | File descriptors, free disk, PersistenceReporting; ProcessLimits raises startup limits |
| Silent system capture | Screen permission/restart and initial packet PTS alignment |
| Shortcuts/language | Saved combinations, system conflicts, AppleLanguages and restart |
| TCC diagnostics | Explicit development troubleshooting only; no automatic production permission reset |

Before distribution, configure the update feed, public key, signing identity and contact channel; see the [Release Checklist](../../RELEASE_CHECKLIST.md).
