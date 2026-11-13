# 07 · Screenshots and OCR

[← Home](Home.md) · Sources: ScreenshotManager and Memozia/Views/Screenshot

The capture subsystem uses AppKit panels/views, decoupled from SwiftUI by notifications: trigger → freeze → select region/window → annotate → copy/file/pin/OCR/note. The same session toolbar can record the chosen live screen target, sharing the meeting-recording stop path.

## 1. Components

```text
GlobalHotkeyManager / MenuBarController / Pro capture toolbar / app menu
→ NotificationCenter → ScreenshotManager
→ ScreenshotOverlayController.RegionSelectionController
   ├─ Freeze displays, excluding the app's own windows
   ├─ OverlayPanel per screen → OverlayAnnotationView
   ├─ RecordCountdownPanel.RecordCountdownController
   ├─ ReannotatePanel
   └─ PinnedWindowSession
→ Outcome
   ├─ Confirmed PNG → RootView → image QuickNote → OCR / summary / tasks
   └─ recordRequested → screenRecordingTargetRequested
      → RootView.startScreenRecording → RecordingViewModel
```

See [Audio Capture](04-Audio-Capture.md) for the recording/video pipeline and [System Integration](09-System-Integration.md) for shortcut scope.

## 2. ScreenshotManager

Source: [ScreenshotManager.swift](../../../Memozia/Services/ScreenshotManager.swift), MainActor singleton.

### 2.1 Modes

```swift
enum CaptureMode: String { case region, window, fullscreen }
```

The shortcut reads UserDefaults `screenshotDefaultMode`.

### 2.2 Operations

| Method | Contract |
|---|---|
| `startCapture(mode:intent:)` | Preflight permission, begin unified session, select/annotate. Record intent automatically counts down after target selection |
| `startCapture(mode:delay:)` | Delayed screenshot, normally three seconds |
| `captureFullScreenDirect()` | Capture pointer display directly, encode PNG, publish screenshotCaptureSaved, bypass overlays. A watchdog/generation invalidates a capture that exceeds directCaptureTimeout and rejects late capture/encoding output instead of permanently leaving the busy flag set |

### 2.3 Permissions

Preflight with `CGPreflightScreenCaptureAccess`, request with `CGRequestScreenCaptureAccess`, and notify RootView via screenshotPermissionNeeded/screenshotErrorOccurred. Screen-recording approval requires restarting the app.

### 2.4 Rejected requests

If a visible capture/reannotation session is already open, repeated triggers only log: a lower-level alert would be hidden by the screenSaver-level panels. A non-idle session with no visible window indicates stuck startup and produces a visible error. If the main window is hidden, permission/error presentation uses an independent NSAlert rather than an invisible RootView-hosted alert.

## 3. RegionSelectionController

Source: [ScreenshotOverlayController.swift](../../../Memozia/Views/Screenshot/ScreenshotOverlayController.swift), MainActor singleton.

### 3.1 Session

1. Enumerate displays/windows with SCShareableContent; exclude app windows using SCContentFilter; freeze at display resolution/scale. Order selectable windows using the authoritative front-to-back CGWindowListCopyWindowInfo sequence, not undocumented SCShareableContent.windows ordering. Keep window IDs for upgrading to independent-window recording.
2. Create one overlay panel per screen. Full capture sessions enable recording; record intent arms automatic recording on selection.
3. Reclaim panels and restore the previously key window before delivering Outcome to avoid a main-window flash.
4. Direct capture bypasses overlays.
5. A startup watchdog ends a frozen capture attempt after startupTimeout, restores idle state, reports failure, and discards late generation results. Never depend only on completion callbacks to clear busy state.

### 3.2 Outcomes

| Outcome | Meaning |
|---|---|
| saved(originalPNG, markedPNG, dimensions, captureMode) | Confirmed note; actual user selection determines region/window/fullscreen mode, independent of entry mode |
| copied | Clipboard only; no note |
| savedToDisk(path) | Desktop PNG |
| pinned(png) | Rasterized selection including annotations; open a topmost session |
| pinnedWithOCR(png) | Pin with editable text panel |
| recordRequested(target) | Untouched picked window → window target; full display → display(nil); other selections → display(region), in display-local top-left-origin points. Notify RootView and show explicit busy/session errors |
| cancelled | Escape, right-click, cancel |
| failed(String) | Permission/capture error |

### 3.3 AnnotationSessionHost

The canvas reports results through this protocol, shared by full-screen RegionSelectionController and PinnedWindowSession. Pinned screenshots can be reannotated; their pin control remains selected and cannot pin recursively.

## 4. OverlayAnnotationView

Source: [OverlayAnnotationView.swift](../../../Memozia/Views/Screenshot/OverlayAnnotationView.swift), an NSView/NSTextFieldDelegate.

### 4.1 State machine

Selecting supports region dragging or window hover; annotating shows tools and allows moving/resizing selection, drawing, and editing text.

### 4.2 Tools

AnnotationTool contains none, select, rect, ellipse, arrow, pen, text, and mosaic. Model data includes kind/color/lineWidth/points/text/fontSize/isBold/isItalic. Line widths are 2/4/6; text sizes 14/24/36 with bold/italic options. Limit text to 500 characters to avoid synchronous large-text layout hangs on macOS 26.

### 4.3 Drawing and interaction

Draw frozen image → outside-selection mask → annotations → selection border → window hover → size/hints. Support selection, window capture, drawing, move/resize/delete, undo/redo, Escape cancellation, Enter confirmation, Space/tool shortcuts.

The shared 36×36 SF Symbol toolbar includes copy, save, pin, OCR, record, microphone, cancel, and confirm. Recording appears only for supported full capture sessions. The microphone button follows recording visibility and hides for system-audio-only source; its menu shares the same device registry/preferences as settings and menu bar.

Recording resolves `makeRecordTarget`, suspends overlays, and shows a red target border with 3-2-1 countdown, selected quality/source/microphone. Click/Enter starts immediately; Escape resumes annotation in place. Completion produces recordRequested. Annotation marks are not burned into video because recording captures the live screen.

`saveToDesktop()` renders annotations into a PNG with the existing localized timestamp filename and ends with savedToDisk.

### 4.4 Accessibility

The canvas supplies an accessible screenshot-annotation label and appropriate role.

## 5. VisionOCRService

[VisionOCRService.swift](../../../Memozia/Services/VisionOCRService.swift) decodes PNG/JPEG to CGImage and performs VNRecognizeTextRequest with Chinese/English recognition and language correction. `OneShotThrowingBox<Value>` uses Sendable constraints and exactly-once continuation completion for concurrency safety.

## 6. Confirmed screenshot → image note

RootView handles screenshotCaptureSaved and prefers markedPNG over originalPNG, creates the QuickNote through `createQuickNote(fromImage:context:)`, then selects it. Existing note actions provide OCR with encrypted text storage, vision summaries through `generateSummaryFromImage` when supportsVision is enabled, and task extraction. See [RootView.swift](../../../Memozia/Views/RootView.swift).

## 7. Notifications

[ScreenshotNotifications.swift](../../../Memozia/Services/ScreenshotNotifications.swift) centralizes screenshotCaptureSaved, screenshotPermissionNeeded, screenshotErrorOccurred, and related names. ScreenshotManager sends; RootView receives.

## 8. User flow

Trigger region capture → permission check → freeze all displays → select region/window/full screen → annotate. Copy leaves clipboard data only; save writes the desktop file; pin opens a topmost reannotatable session; confirm creates/selects an image note and enables optional OCR/summary/tasks. The recording exit instead starts live screen recording through the shared pipeline after countdown.
