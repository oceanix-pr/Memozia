import SwiftData
import Foundation

/// 队列历史只保存条目与配置标识。每次执行（含重试）从当前存储取得模型和任务句柄。
@MainActor
struct EntryProcessingSteps {
    enum Target { case recording(UUID), note(UUID) }
    enum Operation {
        case summary(asMeeting: Bool?), title, todos, visual
        var kind: TaskKind {
            switch self {
            case .summary: .summary
            case .title: .title
            case .todos: .todoExtraction
            case .visual: .visualAnalysis
            }
        }
    }

    weak var context: ModelContext?
    weak var container: ModelContainer?
    weak var recordings: RecordingViewModel?
    weak var notes: QuickNoteViewModel?
    let persistence: PersistenceGuard

    private final class ActiveStep {
        var cancel: ((StepOutcome) -> Void)?
        var interruption: StepOutcome?

        func stop(_ outcome: StepOutcome) {
            interruption = outcome
            cancel?(outcome)
        }
    }

    private func step(_ kind: TaskKind,
                      run: @escaping @MainActor (ModelContext, StepFailure, ActiveStep) async throws -> StepOutcome) -> TaskCenter.Step {
        var current: ActiveStep?
        return TaskCenter.Step(kind: kind, run: { failure in
            let active = ActiveStep()
            current = active
            defer { if current === active { current = nil } }
            guard let context = context ?? container?.mainContext, persistence.allows(.startProcessing) else { return .failed }
            do {
                try Task.checkCancellation()
                return try await run(context, failure, active)
            } catch is CancellationError { return .cancelled }
            catch {
                failure.code = .unknown
                FileSyncService.logWarning("处理任务读取失败：\(UserFacingError.summary(for: error))")
                return .failed
            }
        }, cancel: { current?.stop(.cancelled) }, onTimeout: { current?.stop(.failed) })
    }

    private func recording(_ id: UUID, in context: ModelContext) throws -> AudioRecording? {
        var fetch = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        return try context.fetch(fetch).first
    }

    func transcription(_ id: UUID, config: STTConfigSnapshot) -> TaskCenter.Step {
        step(.transcription) { context, failure, active in
            guard let recording = try recording(id, in: context) else { failure.code = .inputFileMissing; return .failed }
            let vm = recordings ?? RecordingViewModel()
            let stt: STTConfig
            do throws(BackgroundTaskFailureCode) { stt = try config.restore(for: .foreground) }
            catch {
                FileSyncService.logWarning("转写配置暂不可用：\(error.rawValue)")
                failure.code = .unknown
                return .failed
            }
            let whisper = WhisperLocalService.shared
            if stt.mode == .local, !whisper.isModelLoadedFor(path: stt.modelPath) {
                do { try await whisper.loadModel(fromPath: stt.modelPath) }
                catch is CancellationError { return .cancelled }
                catch { failure.code = .missingLocalModel; return .failed }
            }
            try Task.checkCancellation()
            guard !recording.isDeleted, recording.modelContext != nil else { failure.code = .inputFileMissing; return .failed }
            let task = vm.startTranscription(recording: recording, sttConfig: stt, context: context)
            active.cancel = { vm.cancelTranscription(recordingID: id, ifCurrent: task, outcome: $0) }
            let outcome = await task.value
            if outcome == .failed {
                if !FileManager.default.fileExists(atPath: recording.fileURL.path) { failure.code = .inputFileMissing }
                else if stt.mode == .system { failure.code = .permissionDenied }
                else { failure.code = Self.failureCode(input: nil) }
            }
            return outcome
        }
    }

    func processing(_ target: Target, _ operation: Operation, configID: UUID) -> TaskCenter.Step {
        step(operation.kind) { context, failure, active in
            let config: LLMConfig
            if configID == BuiltInQwenModel.id { config = .builtInQwen }
            else {
                var fetch = FetchDescriptor<LLMConfig>(predicate: #Predicate { $0.id == configID })
                fetch.fetchLimit = 1
                guard let stored = try context.fetch(fetch).first else { failure.code = .unknown; return .failed }
                config = stored
            }
            switch target {
            case .recording(let id):
                guard let r = try recording(id, in: context) else { failure.code = .inputFileMissing; return .failed }
                return await runRecording(operation, r, config, context, failure, active)
            case .note(let id):
                var fetch = FetchDescriptor<QuickNote>(predicate: #Predicate { $0.id == id })
                fetch.fetchLimit = 1
                guard let n = try context.fetch(fetch).first else { failure.code = .inputFileMissing; return .failed }
                return await runNote(operation, n, config, context, failure, active)
            }
        }
    }

    private func runRecording(_ op: Operation, _ r: AudioRecording, _ config: LLMConfig,
                              _ context: ModelContext, _ failure: StepFailure, _ active: ActiveStep) async -> StepOutcome {
        let vm = recordings ?? RecordingViewModel()
        let id = r.id
        let status: ReferenceWritableKeyPath<AudioRecording, ProcessingStatus?>?
        let task: Task<StepOutcome, Never>
        var input: URL?
        switch op {
        case .summary(let meeting):
            status = \.summaryStatus
            task = vm.generateSummary(recording: r, llmConfig: config, context: context, asMeeting: meeting)
            active.cancel = { vm.cancelSummary(recordingID: id, ifCurrent: task, outcome: $0) }
        case .visual:
            status = \.visualStatus
            input = r.videoFileURL
            task = vm.generateVisualNotes(recording: r, llmConfig: config, context: context)
            active.cancel = { _ in vm.cancelVisualNotes(ifCurrent: task) }
        case .todos:
            status = \.todoStatus
            task = vm.extractTodos(from: r, llmConfig: config)
            active.cancel = { _ in vm.cancelTodoExtraction(recordingID: id, ifCurrent: task) }
        case .title:
            status = nil
            task = vm.polishRecordingTitle(r, llmConfig: config, context: context)
            active.cancel = { _ in vm.cancelTitle(recordingID: id, ifCurrent: task) }
        }
        return await finish(task, active: active, kind: op.kind, model: r, status: status, failure: failure, input: input)
    }

    private func runNote(_ op: Operation, _ n: QuickNote, _ config: LLMConfig,
                         _ context: ModelContext, _ failure: StepFailure, _ active: ActiveStep) async -> StepOutcome {
        let vm = notes ?? QuickNoteViewModel()
        let id = n.id
        let status: ReferenceWritableKeyPath<QuickNote, ProcessingStatus?>?
        let task: Task<StepOutcome, Never>
        var input: URL?
        switch op {
        case .summary:
            status = \.summaryStatus
            input = n.hasImage ? n.sourceImageURL : nil
            task = vm.generateSummary(for: n, llmConfig: config, context: context)
            active.cancel = { vm.cancelSummary(noteID: id, ifCurrent: task, outcome: $0) }
        case .todos:
            status = \.todoStatus
            task = vm.extractTodos(from: n, llmConfig: config, context: context)
            active.cancel = { _ in vm.cancelTodoExtraction(noteID: id, ifCurrent: task) }
        case .title:
            status = nil
            task = vm.polishNoteTitle(n, llmConfig: config, context: context)
            active.cancel = { _ in vm.cancelTitle(noteID: id, ifCurrent: task) }
        case .visual: return .failed
        }
        return await finish(task, active: active, kind: op.kind, model: n, status: status, failure: failure, input: input)
    }

    private struct StatusKey: Hashable {
        let id: PersistentIdentifier
        let kind: TaskKind
    }
    private static var statusOwners: [StatusKey: UUID] = [:]

    private func finish<M: PersistentModel>(_ task: Task<StepOutcome, Never>, active: ActiveStep, kind: TaskKind, model: M,
        status: ReferenceWritableKeyPath<M, ProcessingStatus?>?, failure: StepFailure, input: URL?) async -> StepOutcome {
        let key = StatusKey(id: model.persistentModelID, kind: kind)
        let owner = UUID()
        if let status {
            Self.statusOwners[key] = owner
            model[keyPath: status] = .processing
        }
        let result = await task.value
        let outcome = active.interruption ?? result
        if outcome == .failed, failure.code == nil { failure.code = Self.failureCode(input: input) }
        if let status, Self.statusOwners[key] == owner {
            Self.statusOwners[key] = nil
            guard model.modelContext != nil, !model.isDeleted else { return outcome }
            switch outcome {
            case .succeeded: model[keyPath: status] = .completed
            case .failed: model[keyPath: status] = .failed
            case .cancelled: model[keyPath: status] = .pending
            }
        }
        return outcome
    }

    private static func failureCode(input: URL?) -> TaskErrorCode {
        TaskFailureClassifier.classify(primaryInputExists: input.map { FileManager.default.fileExists(atPath: $0.path) } ?? true,
            availableDiskBytes: TaskFailureClassifier.availableDiskBytes(at: AudioRecording.storageDirectory))
    }
}
