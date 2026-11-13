import Foundation
import os.log

/// 转写镜像的纯值快照；编码在镜像 worker 中执行，不占用 MainActor。
struct TranscriptMirrorItem: Codable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let text: String
}

/// 条目镜像写入器：把「转写 / 总结 / 画面要点」的加密副本写进条目文件夹。
///
/// 为什么需要独立入口：镜像此前是 `Task.detached` 一把火就走的写入，调用方无从等待。
/// 序号守卫只解决「旧写覆盖新写」，解决不了：
/// - App 刚保存完就退出、被系统终止或崩溃 → 最后一次修改永久丢失；
/// - 流式总结/连续转写期间同一文件被反复整篇重写，写入风暴且互相竞争。
///
/// 这里把写入收敛到一处：**同一条目同一类型的连续写入合并为「只写最新一份」**，
/// 并暴露 `flush()` 供退出流程等待关键写入落盘、`writeNow(...)` 供「写入成功后才能做
/// 后续破坏性动作」的场景（例如画面要点写入成功才允许删除分析检查点）。
///
/// 设计取舍：`submit` 必须是**同步**的。若提交本身要 `await`（actor 方案），调用方只能包一层
/// `Task`，退出流程的 `flush()` 就可能看不见「刚提交但还没轮到执行」的内容——正是要修的丢写窗口。
/// 因此状态用 `NSLock` 保护，并遵循本工程既有约定：锁只出现在**同步辅助方法**里
/// （`NSLock` 不能在 async 上下文中直接使用），async 方法只负责编排。
///
/// 文件系统是权威源，镜像写失败不能只留一条日志：失败会经 `PersistenceReporting` 上报
/// （每次失败记 fault，用户提示每次运行最多一次），并可由磁盘对账的增量修复补写。
final class EntryMirrorStore: @unchecked Sendable {

    static let shared = EntryMirrorStore()

    /// 临时模式门控：只读时不再写入任何镜像文件。由应用启动时注入；
    /// 默认 readWrite（后台 worker 与单测不受影响）
    private let capabilityLock = NSLock()
    private var _capability: PersistenceCapability = .readWrite

    /// 当前持久化能力（线程安全）
    var capability: PersistenceCapability {
        get {
            capabilityLock.lock(); defer { capabilityLock.unlock() }
            return _capability
        }
        set {
            capabilityLock.lock(); _capability = newValue; capabilityLock.unlock()
        }
    }

    /// 镜像类型：决定日志/上报文案（目标 URL 由调用方给出）
    enum Kind: String, Sendable {
        case transcript
        case summary
        case visual

        var displayName: String {
            switch self {
            case .transcript: return "转写"
            case .summary: return "总结"
            case .visual: return "画面要点"
            }
        }
    }

    private struct Key: Hashable, Sendable {
        let kind: Kind
        let folderName: String

        var description: String { "\(kind.rawValue)/\(folderName)" }
    }

    private struct PendingWrite {
        enum Payload: Sendable {
            case text(String)
            case transcript([TranscriptMirrorItem])
        }

        let payload: Payload
        let url: URL
        let generation: UInt64
        /// `writeNow` 提交的内容是屏障写入，不能被后续普通 submit 合并掉。
        let requiresResult: Bool
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "EntryMirror")
    private let writer: @Sendable (String, URL) throws -> Void

    private let lock = NSLock()
    /// 待写内容：同 key 只保留最新一份（这就是「合并连续写入」）
    private var pending: [Key: [PendingWrite]] = [:]
    /// 每个 key 的在途写者：同一 key 任意时刻至多一个
    private var workers: [Key: Task<Void, Never>] = [:]
    /// `writeNow` 屏障写入的完成结果；普通 submit 不记录，避免长期增长。
    private var generationResults: [Key: [UInt64: Bool]] = [:]
    /// 等待方已取消或超时的屏障；worker 后到时不得再把无人消费的结果留在字典里。
    private var abandonedGenerations: [Key: Set<UInt64>] = [:]
    private var nextGeneration: UInt64 = 0
    /// 各 key 最近一次失败原因（nil 表示最近一次成功）
    private var failures: [Key: String] = [:]
    /// 成功/失败写入计数（供 flush 结构化汇报，自 store 生命周期累计）
    private var successCount = 0
    private var failureCount = 0

    init(writer: @escaping @Sendable (String, URL) throws -> Void = EntryMirrorStore.streamingEncryptedWriter) {
        self.writer = writer
    }

    // MARK: - flush 结构化结果

    /// 退出 flush 的结构化结果：调用方据此得知哪些目标未落盘、失败原因是什么，
    /// 而不再只有一个布尔或数量。
    struct FlushResult: Sendable {
        /// 成功落盘的写入次数（自 store 生命周期累计）
        let succeeded: Int
        /// 失败的写入次数（自 store 生命周期累计）
        let failed: Int
        /// 超时仍未落盘的目标（"kind/folderName" 描述），空表示全部落盘
        let remaining: [String]
        /// 各目标最近一次写入失败原因（key 为 "kind/folderName"）
        let errors: [String: String]

        /// 是否全部落盘且无失败：调用方可据此决定是否提示「有内容未写入」
        var isComplete: Bool { failed == 0 && remaining.isEmpty }

        static let empty = FlushResult(succeeded: 0, failed: 0, remaining: [], errors: [:])
    }

    // MARK: - 对外接口

    /// 提交一次镜像写入（**同步返回**，写入在后台任务上完成）。
    /// 同一 key 的连续提交只保留最新内容：中间态不会各写一遍
    func submit(_ content: String, kind: Kind, folderName: String, to url: URL) {
        guard capability.allowsContentMutation else { return }
        guard !folderName.isEmpty else { return }
        enqueue(payload: .text(content), url: url, requiresResult: false,
                for: Key(kind: kind, folderName: folderName))
    }

    func submitTranscript(_ items: [TranscriptMirrorItem], folderName: String, to url: URL) {
        guard capability.allowsContentMutation else { return }
        guard !folderName.isEmpty else { return }
        enqueue(
            payload: .transcript(items), url: url, requiresResult: false,
            for: Key(kind: .transcript, folderName: folderName)
        )
    }

    /// 立即写入并等待结果：供「写入成功后才允许执行破坏性后续动作」的调用方使用
    /// （画面要点写入成功才删分析检查点）
    /// - Parameters:
    ///   - timeout: 最长等待时间；超时或调用方取消均返回 false，写者可在后台自行收尾。
    /// - Returns: 本次内容是否已成功落盘
    func writeTranscriptNow(_ items: [TranscriptMirrorItem], folderName: String, to url: URL) async -> Bool {
        guard capability.allowsContentMutation, !folderName.isEmpty else { return false }
        let key = Key(kind: .transcript, folderName: folderName)
        let generation = enqueue(payload: .transcript(items), url: url, requiresResult: true, for: key)
        return await waitForResult(of: generation, for: key, timeout: .seconds(30))
    }

    func writeNow(
        _ content: String,
        kind: Kind,
        folderName: String,
        to url: URL,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        guard capability.allowsContentMutation else { return false }
        guard !folderName.isEmpty else { return false }
        let key = Key(kind: kind, folderName: folderName)
        let generation = enqueue(payload: .text(content), url: url, requiresResult: true, for: key)
        return await waitForResult(of: generation, for: key, timeout: timeout)
    }

    /// 等待所有在途与待写内容落盘（退出流程调用）
    /// - Parameter timeout: 最长等待时长；到点即返回，不阻塞退出（未落盘内容记 fault）
    /// - Returns: 结构化结果：成功/失败计数 + 超时未落盘的目标 + 各目标最近一次失败原因。
    ///   调用方据此记录哪些条目未完成（而不是只有一个布尔）；未落盘目标已留下恢复标记，
    ///   下次启动由磁盘对账补写
    @discardableResult
    func flush(timeout: Duration = .seconds(10)) async -> FlushResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while busyCount() > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let snapshot = flushSnapshot()
        if !snapshot.remaining.isEmpty {
            Self.logger.fault(
                "条目镜像 flush 超时，仍有 \(snapshot.remaining.count) 个目标未落盘：\(snapshot.remaining.joined(separator: ", "), privacy: .public)"
            )
        }
        if !snapshot.errors.isEmpty {
            Self.logger.fault("条目镜像 flush 结束仍有 \(snapshot.errors.count) 个目标最近一次写入失败（下次启动由磁盘对账补写）")
        }
        return snapshot
    }

    /// 最近一次失败的描述（诊断用；成功会清空对应 key）
    var failureDescriptions: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: failures.map { ($0.key.description, $0.value) })
    }

    // MARK: - 写者循环

    /// 消费某个 key 的待写内容：每轮取最新一份写入；写入期间到来的新内容留待下一轮
    private func drain(_ key: Key) async {
        while true {
            guard let item = takePending(for: key) else {
                // takePending 与这里之间可能有新提交；只有仍为空时才摘掉 worker，
                // 否则继续循环，避免留下“有 pending、无 worker”的孤儿写入。
                if finishWorkerIfIdle(for: key) { return }
                continue
            }
            // 写前落下恢复标记：进程在写入中途被杀/被系统终止时标记残留，
            // 下次启动由磁盘对账（FileSyncService）据标记强制补写；
            // 写入成功后立即删除；标记失败不阻断写入（best-effort）
            Self.writePendingMarker(for: item.url)
            var succeeded = false
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    let content: String
                    switch item.payload {
                    case .text(let text):
                        content = text
                    case .transcript(let items):
                        let data = try JSONEncoder().encode(items)
                        guard let encoded = String(data: data, encoding: .utf8) else {
                            throw EntryMirrorStoreError(reason: "转写 JSON 无法转换为 UTF-8")
                        }
                        content = encoded
                    }
                    try writer(content, item.url)
                    succeeded = true
                    break
                } catch {
                    lastError = error
                    if attempt < 2 {
                        try? await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 250))
                    }
                }
            }
            if succeeded {
                Self.discardPendingMarker(for: item.url)
                markCompleted(item, for: key, succeeded: true, reason: nil)
            } else {
                let reason = lastError?.localizedDescription ?? "未知错误"
                markCompleted(item, for: key, succeeded: false, reason: reason)
                Self.logger.fault("条目镜像写入失败（\(key.description)）：\(reason, privacy: .public)")
                PersistenceReporting.reportSaveFailure(
                    EntryMirrorStoreError(
                        reason: "\(key.kind.displayName)写入磁盘失败（\(key.folderName)）：\(reason)"
                    )
                )
            }
        }
    }

    private func waitForResult(
        of generation: UInt64,
        for key: Key,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let result = takeResult(of: generation, for: key) { return result }
            if Task.isCancelled {
                abandonResult(of: generation, for: key)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                abandonResult(of: generation, for: key)
                return false
            }
        }
        abandonResult(of: generation, for: key)
        Self.logger.fault("条目镜像 writeNow 超时（\(key.description)）")
        return false
    }

    // MARK: - 同步持锁辅助（NSLock 不能在 async 上下文中直接使用）

    /// 存下待写内容，必要时登记写者：**同一把锁内**完成两步，
    /// 否则两个线程可能同时判定「无写者」而各起一个写者，回到并发写同一文件的旧问题
    /// （锁内创建 Task 是安全的：任务体要拿同一把锁，会等本次解锁后再进入 drain）
    @discardableResult
    private func enqueue(
        payload: PendingWrite.Payload, url: URL, requiresResult: Bool, for key: Key
    ) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        nextGeneration &+= 1
        let generation = nextGeneration
        let item = PendingWrite(
            payload: payload, url: url, generation: generation, requiresResult: requiresResult
        )
        var queue = pending[key] ?? []
        // 普通提交只合并普通尾项；writeNow 是必须真正落盘的屏障。
        if !requiresResult, queue.last?.requiresResult == false {
            queue[queue.count - 1] = item
        } else {
            queue.append(item)
        }
        pending[key] = queue
        guard workers[key] == nil else { return generation }
        workers[key] = Task(priority: .utility) { [weak self] in
            await self?.drain(key)
        }
        return generation
    }

    private func takePending(for key: Key) -> PendingWrite? {
        lock.lock(); defer { lock.unlock() }
        guard var queue = pending[key], !queue.isEmpty else { return nil }
        let item = queue.removeFirst()
        if queue.isEmpty { pending[key] = nil } else { pending[key] = queue }
        return item
    }

    private func finishWorkerIfIdle(for key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending[key]?.isEmpty != false else { return false }
        workers[key] = nil
        return true
    }

    private func markCompleted(
        _ item: PendingWrite, for key: Key, succeeded: Bool, reason: String?
    ) {
        lock.lock(); defer { lock.unlock() }
        failures[key] = reason
        if succeeded { successCount &+= 1 } else { failureCount &+= 1 }
        if item.requiresResult {
            if abandonedGenerations[key]?.remove(item.generation) != nil {
                if abandonedGenerations[key]?.isEmpty == true { abandonedGenerations[key] = nil }
            } else {
                generationResults[key, default: [:]][item.generation] = succeeded
            }
        }
    }

    private func takeResult(of generation: UInt64, for key: Key) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard let result = generationResults[key]?[generation] else { return nil }
        generationResults[key]?[generation] = nil
        if generationResults[key]?.isEmpty == true { generationResults[key] = nil }
        return result
    }

    private func abandonResult(of generation: UInt64, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        // 完成与超时可能同时发生：先删除已经落入结果表的值；若尚未完成，登记给 worker 清理。
        if generationResults[key]?.removeValue(forKey: generation) != nil {
            if generationResults[key]?.isEmpty == true { generationResults[key] = nil }
            return
        }
        abandonedGenerations[key, default: []].insert(generation)
    }

    /// pending 与 workers 取并集：worker 已取走 item 后 pending 为空，但写入仍未完成。
    private func busyCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Set(pending.keys).union(workers.keys).count
    }

    /// 一次性读取 flush 上报所需的全部状态
    private func flushSnapshot() -> FlushResult {
        lock.lock(); defer { lock.unlock() }
        let remaining = Set(pending.keys).union(workers.keys)
            .map(\.description).sorted()
        let errors = Dictionary(
            uniqueKeysWithValues: failures.map { ($0.key.description, $0.value) }
        )
        return FlushResult(
            succeeded: successCount,
            failed: failureCount,
            remaining: remaining,
            errors: errors
        )
    }

    // MARK: - 默认写入器（流式临时文件 + 原子 rename）

    /// 流式写入的分块大小（1MB）：避免一次性构造整份密文的 `Data` 拷贝
    private static let streamChunkBytes = 1 << 20

    /// 默认写入器：加密后把密文**流式**写入目标同目录的临时文件，fsync 后原子替换目标。
    /// 同目录保证替换在同一卷、可原子；维持「连续写入合并为最新一份」的语义不变
    /// （合并发生在 enqueue 阶段，此处只负责把最新一份安全落盘）
    static func streamingEncryptedWriter(_ content: String, to url: URL) throws {
        let encrypted = try EncryptionService.encrypt(content)
        try writeStreamingAtomically(encrypted, to: url)
    }

    /// 把文本按 1MB 分块写入目标同目录的隐藏临时文件，`synchronize()` 后原子替换目标。
    /// 目标旧内容在替换前保持不变；任何失败都清理临时文件并保持旧内容不变。
    static func writeStreamingAtomically(_ content: String, to url: URL) throws {
        let fm = FileManager.default
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tempURL.path, contents: nil) else {
            throw EntryMirrorStoreError(reason: "无法创建镜像临时文件：\(tempURL.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                var buffer = Data()
                buffer.reserveCapacity(streamChunkBytes)
                for byte in content.utf8 {
                    buffer.append(byte)
                    if buffer.count >= streamChunkBytes {
                        try handle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // 原子替换：目标存在用 replaceItemAt（同卷原子），否则直接改名
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - 待写恢复标记

    /// 恢复标记文件名后缀：与目标同目录的隐藏文件，标记「该目标最后一次写入可能未完成」
    private static let pendingMarkerSuffix = ".mirror-pending"

    /// 目标对应的恢复标记 URL（与目标同目录，隐藏文件，不污染枚举）
    static func pendingMarkerURL(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent)\(pendingMarkerSuffix)")
    }

    /// 目标是否残留恢复标记（启动时磁盘对账据此强制补写）
    static func hasPendingMarker(for target: URL) -> Bool {
        FileManager.default.fileExists(atPath: pendingMarkerURL(for: target).path)
    }

    /// 丢弃恢复标记（写入成功，或对账发现已无内容可补写时调用）
    static func discardPendingMarker(for target: URL) {
        try? FileManager.default.removeItem(at: pendingMarkerURL(for: target))
    }

    /// 写前落下恢复标记。标记只记录目标名（不落内容，避免明文/体积与隐私问题）：
    /// 补写内容由数据库权威内容重建（文件系统是权威源，数据库是索引），
    /// 复用现有 FileSyncService 对账，不新起 detached 写入
    private static func writePendingMarker(for target: URL) {
        let payload = Data((target.lastPathComponent + "\n").utf8)
        try? payload.write(to: pendingMarkerURL(for: target), options: .atomic)
    }
}

/// 镜像写入失败的上报错误
struct EntryMirrorStoreError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
