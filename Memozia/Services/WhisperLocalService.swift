import Foundation
import Observation
import WhisperKit
import os.log

/// 统一日志（替代 print 调试输出，生产日志走系统统一收集）
private let whisperLogger = Logger(subsystem: "app.memozia", category: "WhisperLocal")

/// 同步统计目录内文件总字节数（供后台任务调用）。
/// DirectoryEnumerator 的迭代不可在异步上下文直接使用（makeIterator 标记 noasync），
/// 必须封装在同步函数体内执行；maxEntries 兑底巨大目录，避免无界枚举
private func folderSizeBytes(at folderURL: URL, maxEntries: Int) -> Int64 {
    var totalBytes: Int64 = 0
    var visited = 0
    if let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let fileURL as URL in enumerator {
            visited += 1
            if visited > maxEntries { break }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += Int64(size)
        }
    }
    return totalBytes
}

/// 进行中转写的外部取消标志容器：
/// transcribe 开始时生成新标志并登记（旧标志全部作废），结束时移除；
/// 取消入口把所有在册标志置位，回调检测到即中断 WhisperKit 解码
private final class ActiveCancelFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [ObjectIdentifier: TranscriptionCancelFlag] = [:]

    func beginNew() -> TranscriptionCancelFlag {
        let flag = TranscriptionCancelFlag()
        lock.lock()
        defer { lock.unlock() }
        active[ObjectIdentifier(flag)] = flag
        return flag
    }

    func finish(_ flag: TranscriptionCancelFlag) {
        lock.lock()
        defer { lock.unlock() }
        active.removeValue(forKey: ObjectIdentifier(flag))
    }

    func cancelAll() {
        lock.lock()
        let flags = Array(active.values)
        lock.unlock()
        for flag in flags { flag.cancel() }
    }
}

/// 单次转写的取消标志（线程安全布尔）
final class TranscriptionCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

/// 本地 WhisperKit 语音转写服务
@MainActor
@Observable
final class WhisperLocalService {

    /// 共享实例，确保设置页和转写流程使用同一服务
    static let shared = WhisperLocalService()

    var isModelLoaded = false
    var isTranscribing = false
    var progress: Float = 0.0
    var isLoadingModel = false
    /// 最近的错误信息
    var lastError: String?

    @ObservationIgnored
    nonisolated private let modelBox = ModelBox()
    /// 转写串行门：WhisperKit 单实例不支持并发 transcribe，
    /// 批量转写的多路任务在此排队串行执行，避免 CoreML 管线竞态崩溃/结果错乱；
    /// 用可取消的 `CancellableGate`：旧版排队不响应取消，持锁者挂起时全部排队者一起悬挂
    @ObservationIgnored
    nonisolated private let transcribeGate = CancellableGate()
    /// 进行中转写的外部取消标志：进度回调未必运行在调用方 Task 上下文，
    /// 仅靠 Task.isCancelled 检测取消不可靠；取消时由调用方（VM）显式置位
    @ObservationIgnored
    nonisolated private let activeCancelFlagBox = ActiveCancelFlagBox()
    /// 已加载模型的实际文件夹路径（resolve 后的标准路径）
    private var loadedModelPath: String?
    /// 模型加载单飞任务（同一模型并发加载时共享，不同模型请求时先取消旧任务）
    private var loadTask: Task<Void, Error>?
    /// loadTask 正在加载的模型路径（用于判断能否复用进行中的加载任务）
    private var loadingModelPath: String?

    /// 检查指定模型文件夹的模型是否已加载
    func isModelLoadedFor(path: String) -> Bool {
        guard isModelLoaded, let loaded = loadedModelPath else { return false }
        return loaded == Self.standardizePath(path)
    }

    /// 是否有模型已加载（供退出流程判断是否需要卸载）
    nonisolated var hasLoadedModel: Bool {
        modelBox.model != nil
    }

    /// 卸载当前模型，释放 CoreML 内存/显存（应用退出时调用）
    func unloadModel() async {
        // 先阻止新的加载/转写，并等待当前转写真正让出串行门。
        // 旧实现直接 take 后 unload，正在执行的 transcribe 仍持有同一 WhisperKit 强引用，
        // 会与 unloadModels() 并发触碰 CoreML 管线。
        cancelModelLoad()
        cancelActiveTranscription()
        do {
            try await transcribeGate.acquire()
        } catch {
            whisperLogger.warning("等待转写结束时卸载任务被取消，保留模型避免并发卸载")
            return
        }

        // 原子取出并清空：避免并发调用对同一实例重复 unloadModels()。
        guard let whisperKit = modelBox.take() else {
            await transcribeGate.release()
            return
        }
        loadedModelPath = nil
        isModelLoaded = false
        isLoadingModel = false
        progress = 0.0
        await whisperKit.unloadModels()
        await transcribeGate.release()
        whisperLogger.info("模型已卸载")
    }

    /// 同步阻塞卸载：仅用于 iOS applicationWillTerminate（回调返回后进程即退出，
    /// 必须阻塞等待卸载完成）。卸载在 detached 任务中执行，不受主线程阻塞影响
    nonisolated func unloadModelBlocking() {
        modelBox.unloadSynchronously()
    }

    /// 取消正在进行的模型加载
    func cancelModelLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadingModelPath = nil
        isLoadingModel = false
        progress = 0.0
    }

    /// 从用户指定的文件夹加载 Whisper 模型
    ///
    /// 文件夹可直接包含模型文件（AudioEncoder/MelSpectrogram/TextDecoder 的 .mlmodelc
    /// 及 tokenizer 文件），也可只包含一个模型子文件夹（自动探测第一个含模型的子目录）。
    ///
    /// 单飞去重：启动预热/设置页/转写入口的并发加载共享同一任务，
    /// 避免多路 `WhisperKit(config)` 同时初始化引发 CoreML 编译竞态；
    /// 请求不同模型时先取消进行中的加载再切换。
    func loadModel(fromPath path: String) async throws {
        let standardPath = Self.standardizePath(path)
        if isModelLoaded, loadedModelPath == standardPath { return }

        // 同一模型正在加载：直接等待该任务结果
        if loadingModelPath == standardPath, let existing = loadTask {
            try await existing.value
            return
        }

        // 切换模型：取消进行中的加载
        loadTask?.cancel()
        loadTask = nil
        loadingModelPath = standardPath

        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { throw CancellationError() }
            try await self.performLoadModel(fromPath: standardPath)
        }
        loadTask = task
        defer {
            // 仅当 loadTask 仍指向本次任务时才清理（可能已被新请求替换）
            if loadTask == task {
                loadTask = nil
                loadingModelPath = nil
            }
        }
        try await task.value
    }

    /// 实际的模型加载逻辑（单飞任务体）
    private func performLoadModel(fromPath path: String) async throws {
        progress = 0.0
        isLoadingModel = true
        defer { isLoadingModel = false }
        lastError = nil

        // 解析实际模型文件夹（支持直接含模型文件或含单个模型子文件夹）。
        // 文件夹探测移出主线程：路径指向掉线的网络卷/未挂载的外置盘时，
        // 同步 FileManager 调用会把主线程堵死（整个应用无响应）
        let modelFolder: String
        do {
            modelFolder = try await Task.detached(priority: .userInitiated) { () -> String in
                try Self.resolveModelFolder(at: path)
            }.value
        } catch let error as WhisperLocalError {
            lastError = error.errorDescription
            throw error
        }

        whisperLogger.info("从用户文件夹加载模型: \(modelFolder)")
        let modelFolderURL = URL(fileURLWithPath: modelFolder)

        // 模型文件夹缺 tokenizer.json 时 WhisperKit 会回退联网取 tokenizer，
        // 该路径的 HubApi 读进程级 HF_ENDPOINT，这里按用户选择的下载源刷新
        WhisperModelSourceStore.applyCurrentAsHubEnvironment()

        do {
            try Task.checkCancellation()
            let box = LoadResultBox()
            let abandoned = LockedBox<Bool>(false)
            // 旧实现用 withThrowingTaskGroup 竞跑，但结构化并发的 group 离开作用域前
            // 必须 join 所有子任务：WhisperKit 初始化（CoreML 编译/隐式联网）不响应取消时，
            // 600s 看门狗依旧走不出来，单飞 loadTask 永不释放、后续加载全部排队。
            // RacingWatchdog 的定时子任务是可取消的 Task.sleep，因此超时能真正脱离。
            let finished = await RacingWatchdog.race(
                name: "WhisperKit 模型加载",
                timeout: Self.modelLoadTimeoutSeconds,
                onTimeout: { abandoned.value = true },
                onCancel: { abandoned.value = true }
            ) {
                do {
                    let kit = try await WhisperKit(
                        WhisperKitConfig(
                            modelFolder: modelFolder,
                            tokenizerFolder: modelFolderURL
                        )
                    )
                    if abandoned.value {
                        // 超时后才建好的孤儿实例：就地卸载，不让 CoreML 内存/显存无人回收
                        await kit.unloadModels()
                        box.set(error: WhisperLocalError.modelLoadTimeout)
                    } else {
                        box.set(model: kit)
                    }
                } catch {
                    box.set(error: error)
                }
            }
            guard finished else {
                if Task.isCancelled { throw CancellationError() }
                throw WhisperLocalError.modelLoadTimeout
            }
            if let error = box.error { throw error }
            guard let whisperKit = box.model else {
                throw WhisperLocalError.modelLoadFailed(String(localized: "模型初始化未返回结果"))
            }
            do {
                try Task.checkCancellation()
            } catch {
                await whisperKit.unloadModels()
                throw error
            }

            // 模型切换也与转写共用同一把门：旧模型正在转写时不得替换并卸载它。
            // 等待门期间若本次加载被取消，新建模型由本路径立即卸载，不留下孤儿 CoreML 实例。
            do {
                try await transcribeGate.acquire()
            } catch {
                await whisperKit.unloadModels()
                throw error
            }
            let previousModel = modelBox.replace(with: whisperKit)
            loadedModelPath = path
            isModelLoaded = true
            progress = 1.0
            await transcribeGate.release()
            if let previousModel, previousModel !== whisperKit {
                await previousModel.unloadModels()
            }
            whisperLogger.info("模型加载成功")
        } catch let error as WhisperLocalError {
            whisperLogger.error("模型加载失败: \(error)")
            lastError = error.errorDescription
            throw error
        } catch is CancellationError {
            whisperLogger.info("模型加载已取消")
            throw CancellationError()
        } catch {
            whisperLogger.error("模型加载失败: \(error)")
            let errorMsg = String(format: String(localized: "模型加载失败：%@。请检查模型文件夹内容是否完整"), UserFacingError.summary(for: error))
            lastError = errorMsg
            throw WhisperLocalError.modelLoadFailed(errorMsg)
        }
    }

    /// 标准化路径：展开 ~ 并去除末尾斜杠，便于比较
    static func standardizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// 解析实际模型文件夹：
    /// 1. 文件夹本身直接包含 AudioEncoder.mlmodelc → 直接使用
    /// 2. 否则取第一个包含 AudioEncoder.mlmodelc 的子文件夹（按名称排序，结果稳定）。
    /// nonisolated：纯文件系统探测、无状态，供后台任务调用（主线程不做同步 FS 操作）
    nonisolated static func resolveModelFolder(at path: String) throws -> String {
        let fm = FileManager.default
        let folderURL = URL(fileURLWithPath: path)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WhisperLocalError.modelFolderMissing(path)
        }

        // 方式1：文件夹直接包含模型文件
        if fm.fileExists(atPath: folderURL.appendingPathComponent("AudioEncoder.mlmodelc").path) {
            return folderURL.path
        }

        // 方式2：查找第一个含模型的子文件夹
        if let subURLs = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for subURL in subURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? subURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }
                if fm.fileExists(atPath: subURL.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                    return subURL.path
                }
            }
        }

        throw WhisperLocalError.modelFolderIncomplete(path)
    }

    /// 模型加载超时上限（秒）：WhisperKit 初始化偶发长时间无响应（模型文件不完整触发
    /// 联网下载、CoreML 编译卡住等），超时后放弃本次加载并给出明确错误，
    /// 避免 UI 永远停留在“加载中”且后续调用在单飞队列上无限排队
    nonisolated static let modelLoadTimeoutSeconds: TimeInterval = 600

    /// 估算模型文件夹占用的内存量级（MB），用于批量转写并发数计算。
    /// 以 mlmodelc 权重文件总大小近似（CoreML 加载后内存占用与权重量级相当）。
    /// 枚举在后台执行并限制条目数：路径指向巨大/慢速目录时避免冻结主线程
    static func estimateModelMemoryMB(at path: String) async -> Int {
        let standard = standardizePath(path)
        return await Task.detached(priority: .userInitiated) { () -> Int in
            guard let folder = try? resolveModelFolder(at: standard) else { return 2048 }
            let totalBytes = folderSizeBytes(at: URL(fileURLWithPath: folder), maxEntries: 100_000)
            let mb = Int(totalBytes / (1024 * 1024))
            // 保底 1GB，避免除零或并发数过大
            return max(mb, 1024)
        }.value
    }

    /// 转写音频文件
    /// - Parameters:
    ///   - audioURL: 音频文件 URL
    ///   - language: 语言代码（nil 为自动检测）
    ///   - onProgress: 原始窗口进度回调（0.0~1.0），区间映射由调用方负责
    nonisolated func transcribe(
        audioURL: URL,
        language: String? = nil,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> [TranscriptionResult] {
        // 验证音频文件是否存在（不依赖模型，先做快失败预检）
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            whisperLogger.error("转写失败: 音频文件不存在 \(audioURL.path)")
            throw WhisperLocalError.audioFileNotFound
        }

        // 获取音频时长以估算进度
        let audioDuration = try? await AudioConverter.getDuration(of: audioURL)
        let estimatedWindows = max(1, Int(ceil((audioDuration ?? 30) / 30.0)))
        whisperLogger.info("开始转写: \(audioURL.lastPathComponent), 语言: \(language ?? "自动检测"), 预估窗口数: \(estimatedWindows)")

        // 串行排队（可取消）：拿到执行权后才取模型，避免排队期间被 unloadModel 抢先卸载
        try await transcribeGate.acquire()

        // 通过线程安全的 ModelBox 访问 whisperKit
        guard let whisperKit = modelBox.model else {
            await transcribeGate.release()
            whisperLogger.error("转写失败: whisperKit 为 nil")
            throw WhisperLocalError.modelNotLoaded
        }

        // 模型加载状态检查（@MainActor 属性）
        let isModelLoadedValue = await MainActor.run { self.isModelLoaded }
        guard isModelLoadedValue else {
            await transcribeGate.release()
            whisperLogger.error("转写失败: 模型未加载")
            throw WhisperLocalError.modelNotLoaded
        }

        // 登记本次转写的外部取消标志；回调同时检查标志与 Task.isCancelled，
        // 双保险覆盖“回调不在调用方 Task 上下文”的情形
        let cancelFlag = activeCancelFlagBox.beginNew()

        do {
            // 排队期间可能已被取消
            try Task.checkCancellation()

            await MainActor.run { isTranscribing = true }

            let options = DecodingOptions(
                task: .transcribe,
                language: language,
                temperature: 0.0
            )

            // WhisperKit 回调：通过 windowId 估算转写进度
            // 返回 false 让 WhisperKit 停止解码，实现真正的中途取消
            let callback: ((TranscriptionProgress) -> Bool?) = { progress in
                if Task.isCancelled || cancelFlag.isCancelled {
                    return false // 中断转写
                }
                let windowProgress = Float(progress.windowId + 1) / Float(estimatedWindows)
                // 只上报原始 0...1 窗口进度，进度区间映射交给编排层
                // （旧实现在此映射到 0.1~0.9，调用方又乘一次系数，区间含义被叠加）
                onProgress?(min(max(windowProgress, 0), 1))
                return nil // nil = 继续
            }

            let results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options,
                callback: callback
            )

            // 被取消时 WhisperKit 返回部分结果，此处统一抛 CancellationError
            try Task.checkCancellation()

            guard !results.isEmpty else {
                whisperLogger.error("转写为空")
                throw WhisperLocalError.transcriptionFailed
            }

            whisperLogger.info("转写完成, 共 \(results.count) 个结果")

            let mapped = results.flatMap { result -> [TranscriptionResult] in
                result.segments.map { segment in
                    TranscriptionResult(
                        text: Self.cleanWhisperTokens(segment.text),
                        startTime: TimeInterval(segment.start),
                        endTime: TimeInterval(segment.end)
                    )
                }
            }

            await MainActor.run { isTranscribing = false }
            activeCancelFlagBox.finish(cancelFlag)
            await transcribeGate.release()
            return mapped
        } catch {
            whisperLogger.error("转写异常: \(error.localizedDescription)")
            await MainActor.run { isTranscribing = false }
            activeCancelFlagBox.finish(cancelFlag)
            await transcribeGate.release()
            throw error
        }
    }

    /// 取消当前进行中的转写（外部取消入口，VM 的取消路径调用）
    func cancelActiveTranscription() {
        activeCancelFlagBox.cancelAll()
    }

    /// 清理 Whisper 输出中的特殊 token（如 <|startoftranscript|>、<|zh|>、<|0.00|> 等）
    /// 这些 token 是 Whisper 模型的内部控制标记，不应展示给用户
    private nonisolated static func cleanWhisperTokens(_ text: String) -> String {
        // 匹配所有 <|...|> 格式的 Whisper 特殊 token
        var cleaned = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        // 清理可能残留的特殊标记（如 [BLANK_AUDIO]、[music] 等方括号标记）
        cleaned = cleaned.replacingOccurrences(
            of: #"\[[A-Z_]+\]"#,
            with: "",
            options: .regularExpression
        )
        // 去除首尾多余空白
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TranscriptionResult: Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// 说话人标签（由说话人分离流程回填，如“说话人 1”）
    var speaker: String?

    init(text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
    }
}

enum WhisperLocalError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed
    case modelLoadFailed(String)
    case modelLoadTimeout
    case modelFolderMissing(String)
    case modelFolderIncomplete(String)
    case audioFileNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return String(localized: "Whisper 模型尚未加载，请先在设置中加载模型")
        case .transcriptionFailed:
            return String(localized: "转写失败，请检查音频文件格式是否受支持（支持 m4a、mp3、wav）")
        case .modelLoadFailed(let detail):
            return detail
        case .modelLoadTimeout:
            return String(localized: "模型加载超时。请确认模型文件夹所在磁盘/网络卷可访问、模型文件完整后重试。")
        case .modelFolderMissing(let path):
            return String(format: String(localized: "模型文件夹不存在：%@。请在「设置 → 语音转写」中检查模型文件夹路径"), path)
        case .modelFolderIncomplete(let path):
            return String(format: String(localized: "模型文件夹中未找到完整的 Whisper 模型：%@。请确保文件夹（或其子文件夹）直接包含 AudioEncoder.mlmodelc、MelSpectrogram.mlmodelc、TextDecoder.mlmodelc 及 tokenizer 文件"), path)
        case .audioFileNotFound:
            return String(localized: "音频文件不存在，可能已被移动或删除")
        }
    }
}

// MARK: - 线程安全的 WhisperKit 包装

/// 模型加载看门狗的结果盒：WhisperKit 非 Sendable，用 @unchecked 盒跨任务传递。
/// 加载子任务写入，超时路径丢弃结果（孤儿任务自然结束后由 ARC 释放）
private final class LoadResultBox: @unchecked Sendable {
    /// 加锁保护：改用 RacingWatchdog 后，孤儿任务仍可能在调用方已返回后写入本盒，
    /// 无锁的裸属性会变成跨线程写读的真实数据竞争
    private let lock = NSLock()
    private var _model: WhisperKit?
    private var _error: (any Error)?

    func set(model: WhisperKit?) {
        lock.lock(); defer { lock.unlock() }; _model = model
    }

    func set(error: (any Error)?) {
        lock.lock(); defer { lock.unlock() }; _error = error
    }

    var model: WhisperKit? {
        lock.lock(); defer { lock.unlock() }; return _model
    }

    var error: (any Error)? {
        lock.lock(); defer { lock.unlock() }; return _error
    }
}

/// 包装非 Sendable 的 WhisperKit，使其可在 nonisolated 方法中安全访问。
/// model 属性通过内部 NSLock 保护，确保 loadModel（MainActor）与 transcribe（nonisolated）的并发安全。
private final class ModelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _model: WhisperKit?

    var model: WhisperKit? {
        get { lock.lock(); defer { lock.unlock() }; return _model }
        set { lock.lock(); defer { lock.unlock() }; _model = newValue }
    }

    /// 原子地取出并清空当前模型（“谁取走谁负责卸载”），消除读后置 nil 的竞态窗口
    func take() -> WhisperKit? {
        lock.lock(); defer { lock.unlock() }
        let current = _model
        _model = nil
        return current
    }

    /// 原子替换模型并把旧实例交给调用方卸载。
    func replace(with model: WhisperKit) -> WhisperKit? {
        lock.lock(); defer { lock.unlock() }
        let previous = _model
        _model = model
        return previous
    }

    /// 同步卸载（阻塞当前线程直到卸载完成，仅用于进程退出前）
    func unloadSynchronously() {
        lock.lock()
        let current = _model
        _model = nil
        lock.unlock()
        guard let current else { return }
        // 用 @unchecked Sendable 盒子携带非 Sendable 的 WhisperKit 进入 detached 任务
        let box = UncheckedModelBox(current)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await box.model.unloadModels()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

/// 仅用于退出卸载路径的 Sendable 包装盒
private struct UncheckedModelBox: @unchecked Sendable {
    let model: WhisperKit
    init(_ model: WhisperKit) { self.model = model }
}

// MARK: - 转写串行门

/// 串行门实现已统一收敛到 `RacingWatchdog.swift` 的 `CancellableGate`：
/// 旧版本地实现用不响应取消的 `withCheckedContinuation` 排队，持锁任务一旦永久挂起，
/// 所有排队转写会一起悬挂并泄漏各自的 URL 与回调闭包。
