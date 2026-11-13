# 09 · System Integration and Updates

[← Home](Home.md) · Source: Memozia/Services

## 1. MenuBarController

[MenuBarController.swift](../../../Memozia/Services/MenuBarController.swift) is a MainActor singleton built on `NSStatusBar.system.statusItem`, keeping actions available when the main window/Dock is hidden or during screen sharing.

### 1.1 Responsibility

Provide recording, capture, input-device, note, language, settings, window, and exit controls without requiring the main window.

### 1.2 Menu structure

| Entry | Behavior |
|---|---|
| Start/stop recording | Notifications to RootView/RecordingViewModel. Screen recording changes status/action text and shares the stop pipeline |
| Capture Screen | Region/window/full-screen screenshots; session toolbar can switch to recording. Full-screen recording starts directly on the pointer's screen; region/window recording opens a capture session with record intent and a three-second countdown. Source/quality use independent `screen_recording_source/quality` preferences shared with Capture settings |
| Microphone | Lists all `MicrophoneDeviceRegistry` inputs including virtual/loopback devices, current selection, and a disconnected-device placeholder. Shares `microphone_device_uid` with settings, capture toolbar, and recording badge. Also offers live mute and the shared `MicrophoneStartMutePreference` for starting muted |
| Hide Main Window | `.accessory` activation policy hides window/Dock while preserving the status item |
| New Note from Clipboard | Notification routes to QuickNoteViewModel; naming comes from AppCommandCatalog |
| Language | Write AppleLanguages and ask whether to restart |
| Settings | `menuBarOpenSettings` |
| Quit | If recording, send the unified stop notification and wait for `menuBarStopRecordingCompleted`, with stopped/not-merging fallback and a bounded timeout. Do not stop the service separately and bypass ViewModel finalization/indexing. Normal termination performs cleanup and uses `_exit` to avoid ONNX static destructors |

Names, shortcuts, and settings destinations come from `AppCommandCatalog`/`AppCommandDescriptor`, shared with application menus, help, and settings search. Global shortcut labels read the live GlobalHotkeyManager values.

### 1.3 Windows

`showMainWindow()` restores/minimization state idempotently through the tracked `mainWindows` and makeKeyAndOrderFront. `applyInterfaceLanguage(_:)` clears overrides for system-following or saves a language and asks to restart. `availableLanguages` uses native self-names. The custom SF Symbol renders the selected folded note and waveform as a monochrome template, following system light/dark appearance; recording/mute state is conveyed in menu text.

### 1.4 Dock visibility

Switch `.regular`/`.accessory` activation policy and use AppDelegate reopen/become-active fallbacks so opening from the Dock restores the window. See [Architecture](02-Architecture.md), §3.

## 2. GlobalHotkeyManager

[GlobalHotkeyManager.swift](../../../Memozia/Services/GlobalHotkeyManager.swift) is a MainActor singleton.

### 2.1 Implementation

Carbon `RegisterEventHotKey` receives shortcuts while the application is inactive.

### 2.2 Defaults and validation

| Shortcut | Action | Availability |
|---|---|---|
| `⌃⌘R` | Toggle meeting recording | Both experiences |
| `⌃⌘S` | Region/default-mode screenshot | Both experiences |
| `⌃⌘W` | Direct full-screen capture | Pro only |

Combinations persist in UserDefaults and register on `start()`. The dedicated `HotkeySettingsView` is available in both experiences; Standard hides the direct full-screen row.

If default `⌃⌘R` is occupied, `recordingFallbackCombination` may use `⇧⌃⌘R`. Do not replace an explicitly customized combination. The fallback remains in memory (`recordingHotkeyFellBack`) and is explained in settings, while persistent storage retains user intent so the default can recover next launch.

Non-function keys require modifiers; F1–F20 may stand alone. Reject duplicate app combinations and reserved `⌃⌘F`. Configuration functions return explicit failure reasons. Register each shortcut independently, preserving successful ones when another fails; record `unregisteredHotkeys`, log errors, and show the failure in settings.

### 2.4 Dispatch

The Carbon EventHandler selects the shortcut ID and sends notifications: recording calls RootView `toggleMeetingRecording()`, screenshots resolve `screenshotDefaultMode` into `startCapture(mode:)`, and direct full screen calls `captureFullScreenDirect()`. Preference changes unregister before re-registering.

## 3. MainActor AppKit bridge

Source: [MainActor+AssumeOnMainThread.swift](../../../Memozia/Services/MainActor+AssumeOnMainThread.swift).

```swift
extension MainActor {
    static func assumeOnMainThread(_ body: @MainActor () -> Void)
}
```

Synchronous AppKit callbacks such as `applicationDidFinishLaunching` have no Task context. Direct `MainActor.assumeIsolated` can trip macOS 26 executor assertions; this helper checks the main thread before entering MainActor context. AppDelegate callbacks consistently use it.

## 4. Reminders URL diagnostics

[RemindersURLDiagnostic.swift](../../../Memozia/Services/RemindersURLDiagnostic.swift) is an opt-in, one-time tool controlled by `reminders_url_diagnostic`. It tests EKReminder URL writes, writes `~/Documents/Memozia/url_diagnostic.txt`, and clears its preference. See [AI Features](06-AI-Features.md), §4.

## 5. Permissions and entitlements

| Permission | Use |
|---|---|
| Microphone | Meeting audio, TCC prompt |
| Speech recognition | System transcription, requested for that feature |
| Screen recording | SCStream and screenshots; system settings and app restart after approval |
| Accessibility | AX meeting-app mute observation |
| Reminders | EKReminder writes, TCC prompt |
| Network client | Cloud API and model downloads |
| User-selected file read/write | Import and export |

[Memozia.entitlements](../../../Memozia/Resources/Memozia.entitlements) contains audio-input, network.client, and files.user-selected.read-write. App Sandbox is disabled for direct Documents storage, and `cs.disable-library-validation` is not enabled. The iOS App Group entitlement was removed with the extension. Formal builds retain Hardened Runtime; preview packaging has a separate explicit override.

## 6. Application updates

Sources: [AppUpdateService.swift](../../../Memozia/Services/AppUpdateService.swift), [UpdateInstallationCoordinator.swift](../../../Memozia/Services/UpdateInstallationCoordinator.swift).

- Start Sparkle only in the main app after privacy consent and persistent-container startup; never in the worker, unit tests, or UI tests.
- This source copy has no update feed or public key, so the updater does not start and update controls are hidden. Once a trusted feed is configured, automatic checks remain opt-in and installation still requires confirmation.
- Before replacement, reject active capture/import/reconciliation/processing resources, save ModelContext, stop the old worker, and await `EntryMirrorStore.flush()`. Recheck idle state after async barriers. Failure cancels termination with a visible retry message.
- Update termination does not spawn an old worker. The new version uses normal startup takeover. `_exit` remains necessary for ONNX destructor avoidance.
- The new brand has no update channel yet. A future release must configure and verify its own stable feed, signature and notarization.
- Real two-version replacement, relaunch, and permission continuity need runtime acceptance testing; builds/unit tests do not establish those behaviors. See the [Release Checklist](../../RELEASE_CHECKLIST.md).
