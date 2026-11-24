import SwiftUI
import AppKit
import Observation

/// One consent window serves all foreground requests. Each caller can cancel its
/// own wait. Dismissing the window cancels the download and all remaining requests.
@MainActor
@Observable
final class BuiltInModelAccess: NSObject, NSWindowDelegate {
    static let shared = BuiltInModelAccess()
    var source = BuiltInQwenModel.defaultSource
    var progress = 0.0
    var isDownloading = false
    var errorMessage: String?
    var isInstalled = BuiltInQwenModel.isReady()
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadID: UUID?
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func ensureAvailable() async throws {
        if isCancelling, let downloadTask { await downloadTask.value }
        try Task.checkCancellation()
        if BuiltInQwenModel.isReady() {
            isInstalled = true
            return
        }
        isInstalled = false
        // A resumed background job can use installed weights, but cannot obtain
        // consent or silently start a new multi-gigabyte download.
        guard !CommandLine.arguments.contains(BackgroundWorker.launchFlag),
              !AppRuntime.isRunningTests else { throw BuiltInModelError.notDownloaded }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                showWindow()
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                if self.waiters.isEmpty { self.cancel() }
            }
        }
        try Task.checkCancellation()
    }

    func requestDownload() {
        Task {
            do { try await ensureAvailable() }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        source = BuiltInQwenModel.defaultSource
        errorMessage = nil
        progress = 0
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = String(localized: "下载内置模型")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: BuiltInModelDownloadView(access: self))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func confirmDownload() {
        guard downloadTask == nil else { return }
        isDownloading = true
        errorMessage = nil
        let selectedSource = source
        let id = UUID()
        downloadID = id
        downloadTask = Task {
            do {
                try await BuiltInModelDownloader.download(source: selectedSource) { value in
                    Task { @MainActor in
                        if self.downloadID == id { self.progress = value }
                    }
                }
                try Task.checkCancellation()
                isInstalled = true
                finish()
            } catch is CancellationError {
                finish(error: CancellationError())
            } catch {
                // Keep pending operations and allow retry with either source.
                errorMessage = error.localizedDescription
                isDownloading = false
                downloadTask = nil
                downloadID = nil
            }
        }
    }

    func cancel() {
        isCancelling = downloadTask != nil
        downloadTask?.cancel()
        // The task keeps ownership of its download until URLSession has stopped.
        // Its completion clears downloadTask, preventing an overlapping retry.
        finish(error: CancellationError(), downloadFinished: false)
    }

    private func finish(error: (any Error)? = nil, downloadFinished: Bool = true) {
        if downloadFinished {
            isDownloading = false
            downloadTask = nil
            downloadID = nil
            isCancelling = false
        }
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
        let closingWindow = window
        window = nil
        closingWindow?.delegate = nil
        closingWindow?.close()
    }

    func windowWillClose(_ notification: Notification) { cancel() }
}

private struct BuiltInModelDownloadView: View {
    @Bindable var access: BuiltInModelAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("下载 Qwen3.5-2B？", systemImage: "arrow.down.circle")
                .font(.title3.bold())
            Text("下载约 1.8 GB，完成后将自动继续当前操作。文字总结和图片理解均在本机完成，无需 API Key。")
                .fixedSize(horizontal: false, vertical: true)
            Picker("下载源", selection: $access.source) {
                ForEach(WhisperModelSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .accessibilityIdentifier("builtInModelDownloadSource")
            .disabled(access.isDownloading)
            if access.isDownloading {
                ProgressView(value: access.progress)
                Text(access.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if let error = access.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("取消") { access.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelBuiltInModelDownload")
                Spacer()
                Button(access.errorMessage == nil ? String(localized: "下载并使用") : String(localized: "重试下载")) {
                    access.confirmDownload()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirmBuiltInModelDownload")
                .disabled(access.isDownloading)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct BuiltInModelSettingsSection: View {
    let settingsVM: SettingsViewModel
    let isActive: Bool
    @State private var access = BuiltInModelAccess.shared

    var body: some View {
        Section("内置模型") {
            Button {
                settingsVM.setActiveLLMConfig(.builtInQwen)
            } label: {
                HStack {
                    Image(systemName: "desktopcomputer")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("内置 Qwen3.5-2B")
                        Text("文字总结与图片理解 · 本机运行")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
            if access.isInstalled {
                Label("模型已下载", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button(access.isDownloading ? String(localized: "查看下载进度") : String(localized: "下载模型（约 1.8 GB）")) {
                    settingsVM.setActiveLLMConfig(.builtInQwen)
                    access.requestDownload()
                }
            }
        }
    }
}
