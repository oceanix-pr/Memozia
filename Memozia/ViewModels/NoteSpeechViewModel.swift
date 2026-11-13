import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class NoteSpeechViewModel {
    let input: SpeechNoteInput
    var voices = SpeechVoiceOption.installed()
    var language = ""
    var voiceID = ""
    var useSummary = false
    var speed = 1.0
    var format: SpeechAudioFormat = .m4a
    let supportsMP3 = SpeechAudioFormat.supportsMP3Encoding
    var preparedText = ""
    var isPreparing = false
    var isBusy = false
    var isPreviewing = false
    var progress = 0.0
    var errorMessage: String?
    var exported = false
    private(set) var artifactIsPreview = false
    private(set) var artifact: SpeechAudioArtifact?
    private(set) var player: AVAudioPlayer?
    @ObservationIgnored private let service = NativeSpeechService()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    init(input: SpeechNoteInput) {
        self.input = input
        useSummary = input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        selectInitialLanguage()
    }

    var languages: [String] {
        Array(Set(voices.map(\.language))).sorted {
            let preferred = ["zh-CN", "zh-TW", "yue-HK", "zh-HK"]
            let left = preferred.firstIndex(of: $0) ?? preferred.count
            let right = preferred.firstIndex(of: $1) ?? preferred.count
            return left == right ? $0 < $1 : left < right
        }
    }

    var filteredVoices: [SpeechVoiceOption] { voices.filter { $0.language == language } }
    var canGenerate: Bool { !isPreparing && !isBusy && !preparedText.isEmpty && !voiceID.isEmpty }

    private func selectInitialLanguage() {
        let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
        language = languages.first(where: { $0 == preferred })
            ?? languages.first(where: { $0 == "zh-CN" }) ?? languages.first ?? ""
        selectVoice()
    }

    func selectVoice() {
        if !filteredVoices.contains(where: { $0.id == voiceID }) {
            // 优先系统自然声音；Eloquence 仍可手动选择，不能仅按名称字母序选中它。
            voiceID = filteredVoices.first(where: { !$0.id.contains("eloquence") })?.id
                ?? filteredVoices.first?.id ?? ""
        }
        invalidate()
    }

    func refreshVoices() {
        voices = SpeechVoiceOption.installed()
        if !languages.contains(language) { selectInitialLanguage() }
        selectVoice()
    }

    func prepare() async {
        invalidate()
        isPreparing = true
        let markdown = useSummary ? input.summary : input.body
        // 只把字符串快照交给后台；不传递 QuickNote / ModelContext。
        let task = Task.detached(priority: .userInitiated) {
            SpeechTextPreparer.prepare(markdown, shouldCancel: { Task.isCancelled })
        }
        let text = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !closed else { return }
        preparedText = text
        isPreparing = false
    }

    func invalidate() {
        player?.stop()
        player = nil
        artifact?.remove()
        artifact = nil
        artifactIsPreview = false
        exported = false
        errorMessage = nil
    }

    func generate(preview: Bool) {
        guard canGenerate, !closed else { return }
        invalidate()
        isBusy = true
        isPreviewing = preview
        progress = 0
        let text = preview ? String(preparedText.prefix(160)) : preparedText
        let selectedVoice = voiceID
        let selectedFormat: SpeechAudioFormat = preview ? .wav : format
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        operation = Task {
            defer {
                isBusy = false
                isPreviewing = false
                operation = nil
            }
            do {
                let result = try await service.synthesize(text: text, voiceID: selectedVoice,
                    rate: rate, format: selectedFormat) { self.progress = $0 }
                guard !Task.isCancelled, !closed else { result.remove(); return }
                artifact = result
                artifactIsPreview = preview
                if preview { try play() }
            } catch is CancellationError {
                // 取消是用户操作；只清理资源，不显示失败告警。
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func play() throws {
        guard let artifact else { return }
        player?.stop()
        let audio = try AVAudioPlayer(contentsOf: artifact.audioURL)
        guard audio.prepareToPlay(), audio.play() else { throw SpeechSynthesisError.noAudio }
        player = audio
    }

    func replay() {
        do { try play() } catch { errorMessage = error.localizedDescription }
    }

    func stopPlayback() { player?.stop() }
    func cancel() { operation?.cancel() }

    func close() {
        closed = true
        operation?.cancel()
        invalidate()
    }

    func exportAudio() {
        guard !isBusy, let artifact else { return }
        player?.stop()
        isBusy = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: artifact.format.rawValue) ?? .audio]
        let safeTitle = input.title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).\(artifact.format.rawValue)"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url, !self.closed else {
                self.isBusy = false
                return
            }
            self.progress = 0
            self.operation = Task {
                defer { self.isBusy = false; self.operation = nil }
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                let staging = destination.deletingLastPathComponent()
                    .appendingPathComponent(".memozia-speech-\(UUID().uuidString).\(artifact.format.rawValue)")
                do {
                    try await AudioConverter.copyFileOffMain(from: artifact.audioURL, to: staging)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: destination)
                    }
                    self.exported = true
                } catch {
                    if FileManager.default.fileExists(atPath: staging.path) {
                        do { try FileManager.default.removeItem(at: staging) }
                        catch { PersistenceReporting.reportSaveFailure(error) }
                    }
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }
}
