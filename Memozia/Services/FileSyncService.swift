import Foundation
import SwiftData
import AVFoundation
import os.log

/// 文件同步服务：启动时扫描 ~/Documents/Memozia/ 子文件夹，自动加载录音到数据库
///
/// 性能优化（P0-1/P0-2/P1-4）：
/// - 异步并发扫描新文件夹（TaskGroup），不阻塞主线程
/// - 字典 O(1) 查找已入库条目，消除 O(n²) fetchRecording
/// - 已入库条目跳过 loadTranscriptIfNeeded/loadSummaryIfNeeded，避免无意义 I/O
/// - 音频时长异步获取
enum FileSyncService {

    private static let logger = Logger(subsystem: "app.memozia", category: "FileSync")

    /// 合并互斥标记文件名：录音文件夹内存在此文件时表示“合并/恢复进行中”，
    /// 扫描必须跳过该文件夹，避免误判为崩溃遗留而介入（曾发生扫描删掉正在导出的
    /// 半成品最终文件、与实时合并争抢分片导致全部失败）
    static let mergeMarkerName = ".merging"

    /// `.merging` 标记的载荷（PID 化标记）：判定标记是否仍然拦截扫描，
    /// 以写标记进程是否存活为准，消除旧版纯 mtime 方案最长 30 分钟的盲区
    struct MergeMarkerPayload: Codable {
        let pid: Int32
        let startedAt: Date
    }

    /// 写入 PID 化合并标记（内容：写标记进程 PID + 开始时间）
    static func writeMergeMarker(at folderURL: URL) {
        let url = folderURL.appendingPathComponent(mergeMarkerName)
        let payload = MergeMarkerPayload(pid: ProcessInfo.processInfo.processIdentifier, startedAt: Date())
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    static func removeMergeMarker(at folderURL: URL) {
        try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(mergeMarkerName))
    }

    /// 标记是否仍然“活跃”（对应合并大概率仍在进行，扫描/恢复须让行）：
    /// - JSON 标记：写标记进程存活 → 活跃；进程已死 → 立即过期。
    ///   开始时间早于当前时间超过 24h（时钟回拨/异常）视为遗留，避免永久卡死
    /// - 旧版 0 字节/无法解析：回退 mtime < 30 分钟规则
    static func mergeMarkerHoldsRecovery(at folderURL: URL) -> Bool {
        let url = folderURL.appendingPathComponent(mergeMarkerName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let payload = try? JSONDecoder().decode(MergeMarkerPayload.self, from: data)
        else {
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
            return Date().timeIntervalSince(mtime) < 1800
        }
        guard payload.startedAt <= Date(), Date().timeIntervalSince(payload.startedAt) < 86_400 else { return false }
        if kill(payload.pid, 0) == 0 { return true }
        return errno == EPERM // 进程存在但属其它用户：保守视为存活
    }

    /// 合并/恢复导出的超时上限（秒）：挂起检测用，远大于正常导出耗时
    /// （2.2 小时素材实测恢复导出约 35 秒）。基础 10 分钟 + 每小时素材 7.5 分钟，上限 1 小时
    static func mergeExportTimeout(estimatedAudioDuration: TimeInterval) -> TimeInterval {
        min(600 + estimatedAudioDuration / 8, 3600)
    }

    /// 停录收尾中「离线参考回声消除」阶段的超时上限（秒）。
    ///
    /// 独立于导出超时：该阶段在合并导出之前运行，旧实现没有独立预算，一旦某片
    /// 的延迟估计/滤波卡住，整个停录就无限期无反馈。这里给足正常耗时余量
    /// （逐片流式滤波，实测约数倍实时），同时用看门狗兜住挂起。
    /// 基础 5 分钟 + 每小时素材 10 分钟，上限 30 分钟。
    static func echoReductionTimeout(estimatedAudioDuration: TimeInterval) -> TimeInterval {
        min(300 + estimatedAudioDuration / 6, 1800)
    }

    /// 扫描互斥：同一时间只允许一个 syncFromDisk 运行（本方法 @MainActor，无需加锁）。
    /// 防止启动扫描与手动刷新重叠时，两轮扫描对同一文件夹并发恢复互相踩踏
    @MainActor
    private static var isScanning = false

    @MainActor
    static var hasResourcesPreventingUpdate: Bool { isScanning }

    /// 本次运行已探测过时长的损坏条目文件夹（duration<=0）：
    /// AVURLAsset 探测开销大，文件确实损坏时每轮刷新重试只会空转；
    /// 仅 MainActor 的 syncFromDisk 访问，无需加锁
    @MainActor
    private static var durationProbeAttempted: Set<String> = []

    /// 本次运行已检查过条目类型的文件夹（`hasVideoSource` 为 false 的行）：
    /// 纯录音条目永远查不出视频证据，不做记忆就会每轮刷新把全库文件夹重新列举一遍；
    /// 仅 MainActor 的 syncFromDisk 访问，无需加锁
    @MainActor
    private static var videoFlagRepairAttempted: Set<String> = []

    /// 供外部调用的警告日志
    static func logWarning(_ message: String) {
        logger.warning("\(message)")
    }

    // MARK: - 同步结果（供刷新/启动同步后的用户反馈）

    /// 单条崩溃恢复成功的录音信息
    struct RecoveredRecordingInfo: Sendable {
        let folderName: String
        let displayName: String
        let duration: TimeInterval
    }

    /// syncFromDisk 完整结果：新增条目 + 崩溃恢复详情（供刷新后的用户反馈）
    struct SyncResult: Sendable {
        let newCount: Int
        let saveFailed: Bool
        /// 本次扫描中自动恢复成功的崩溃遗留录音
        let recovered: [RecoveredRecordingInfo]
        /// 恢复失败（分片已保留，需手动处理）的文件夹显示名
        let recoveryFailedNames: [String]
        /// 因疑似仍在录制（分片 mtime 新鲜）而跳过恢复的文件夹数
        let stillRecordingCount: Int

        static let empty = SyncResult(
            newCount: 0, saveFailed: false,
            recovered: [], recoveryFailedNames: [], stillRecordingCount: 0
        )
    }

    /// 崩溃恢复结果（区分“无需恢复 / 疑似仍在录制 / 失败”，供调用方准确反馈）
    enum RecoveryOutcome: Sendable {
        case recovered(URL)
        case nothingToDo
        case stillRecording
        case failed

        /// 恢复出的最终文件 URL（非 recovered 状态为 nil）
        var recoveredURL: URL? {
            if case .recovered(let url) = self { return url }
            return nil
        }
    }

    /// 扫描并发窗口（同时在跑的文件夹扫描数）：每个扫描占 1~2 个 AVURLAsset，
    /// 恢复路径还会占一个导出会话；4 足以吃满磁盘队列又不会堆叠文件句柄
    private static let scanConcurrency = 4

    /// 扫描任务领取游标：actor 保证索引递增无竞争。
    /// 用工人式领取而非按数量预分片，避免单个慢文件夹拖住其后的整批任务
    private actor ScanCursor {
        private var index = 0
        private let total: Int
        init(total: Int) { self.total = total }
        func next() -> Int? {
            defer { index += 1 }
            return index < total ? index : nil
        }
    }

    /// 单文件夹扫描产出：入库条目 + 崩溃恢复过程信息
    struct FolderScanOutcome: Sendable {
        var folderName = ""
        var result: FolderScanResult?
        var recovered: RecoveredRecordingInfo?
        var recoveryFailed = false
        var stillRecording = false
    }

    /// 条目镜像的探测目标（只带 URL，不含内容；可跨 actor 传递）
    struct RecordingMirrorTarget: Sendable {
        let folderName: String
        let transcriptURL: URL
        let summaryURL: URL
        let visualURL: URL

        /// 由 folderName 解析目标（`resolveFolderURL` 含一次 `fileExists`）。
        /// 批量构建目标一律走这里、并在后台线程调用：每条目只解析一次 folderURL，
        /// 避免 10k 条目 × 3 个 URL 在主线程堆积数万次系统调用。
        static func forFolder(named folderName: String) -> RecordingMirrorTarget {
            let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)
            return RecordingMirrorTarget(
                folderName: folderName,
                transcriptURL: folderURL.appendingPathComponent(AudioRecording.transcriptFileName),
                summaryURL: folderURL.appendingPathComponent(AudioRecording.summaryFileName),
                visualURL: folderURL.appendingPathComponent(AudioRecording.visualFileName)
            )
        }
    }

    /// 条目镜像的磁盘状态快照。
    ///
    /// `*PendingMarker` 一并在这里探测：恢复标记原本在对账循环里逐条同步 `stat`
    /// （每条 3 次 + 笔记 1 次），在 MainActor 上形成 4N 次系统调用；改由后台批处理一次完成。
    struct RecordingMirrorDiskState: Sendable {
        let transcriptExists: Bool
        let transcriptDate: Date?
        let transcriptPendingMarker: Bool
        let summaryExists: Bool
        let summaryDate: Date?
        let summaryPendingMarker: Bool
        let visualExists: Bool
        let visualDate: Date?
        let visualPendingMarker: Bool
        var committedMerge: RecordingMergeService.CommittedMedia? = nil
    }

    struct NoteMirrorTarget: Sendable {
        let folderName: String
        let summaryURL: URL

        /// 由 folderName 解析目标；语义同 `RecordingMirrorTarget.forFolder(named:)`
        static func forFolder(named folderName: String) -> NoteMirrorTarget {
            let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)
            return NoteMirrorTarget(
                folderName: folderName,
                summaryURL: folderURL.appendingPathComponent(AudioRecording.summaryFileName)
            )
        }
    }

    struct NoteMirrorDiskState: Sendable {
        let exists: Bool
        let date: Date?
        let pendingMarker: Bool
    }

    /// 探测单个录音条目的镜像磁盘状态（纯文件系统读取，供后台批处理与单测）
    static func probe(_ target: RecordingMirrorTarget) -> RecordingMirrorDiskState {
        RecordingMirrorDiskState(
            transcriptExists: FileManager.default.fileExists(atPath: target.transcriptURL.path),
            transcriptDate: modificationDate(of: target.transcriptURL),
            transcriptPendingMarker: EntryMirrorStore.hasPendingMarker(for: target.transcriptURL),
            summaryExists: FileManager.default.fileExists(atPath: target.summaryURL.path),
            summaryDate: modificationDate(of: target.summaryURL),
            summaryPendingMarker: EntryMirrorStore.hasPendingMarker(for: target.summaryURL),
            visualExists: FileManager.default.fileExists(atPath: target.visualURL.path),
            visualDate: modificationDate(of: target.visualURL),
            visualPendingMarker: EntryMirrorStore.hasPendingMarker(for: target.visualURL),
            committedMerge: RecordingMergeService.committedMedia(in: target.transcriptURL.deletingLastPathComponent())
        )
    }

    /// 探测单个快捷笔记条目的镜像磁盘状态
    static func probe(_ target: NoteMirrorTarget) -> NoteMirrorDiskState {
        NoteMirrorDiskState(
            exists: FileManager.default.fileExists(atPath: target.summaryURL.path),
            date: modificationDate(of: target.summaryURL),
            pendingMarker: EntryMirrorStore.hasPendingMarker(for: target.summaryURL)
        )
    }

    /// 修复循环的让出节奏（每 N 条 `Task.yield()` 一次）。
    ///
    /// 修复循环本身是纯内存遍历、不触发系统调用：实测（10k 条目、持久容器）整段仅 ~70ms
    /// 且无 ≥50ms 单块，故这里的让出只是公平性兜底，不是主线程阻塞的主要来源。
    private static let repairYieldCadence = 20

    /// 候选新目录过滤（逐目录 `fileExists` + `isDir`）的让出节奏。由 `filter` 改为显式循环
    /// 只为在 10k 次同步 stat 间插入让出点（语义等价）。
    private static let newDirFilterYieldCadence = 64

    /// 扫描 Memozia 目录下的子文件夹，将未入库的录音/快捷笔记自动加载到数据库
    /// - Parameter context: SwiftData 上下文（MainActor 隔离，确保线程安全）
    /// - Returns: 同步结果：新增条目数 + 崩溃恢复详情（供刷新/启动同步后的用户反馈）
    @discardableResult
    @MainActor
    static func syncFromDisk(context: ModelContext, excludeFolderNames: Set<String> = []) async -> SyncResult {
        // 扫描互斥：已有扫描在运行时直接跳过本次调用（下轮刷新/重启会补上）
        guard !isScanning, !AppUpdateService.shared.isPreparingToInstall,
              !RecordingMergeActivity.shared.isRunning, !MediaCleanupService.shared.isRunning else {
            logger.info("磁盘同步已在进行中，跳过本次调用")
            return .empty
        }
        isScanning = true
        defer { isScanning = false }

        let storageDir = AudioRecording.storageDirectory

        // 顶层与月份目录枚举可能命中掉线的网络盘/外置盘，不能在 MainActor 同步执行。
        guard let subDirs = await Task.detached(priority: .utility, operation: {
            discoverEntryDirectories(at: storageDir)
        }).value else {
            logger.info("Memozia 目录为空或不存在，跳过同步")
            return .empty
        }

        // P0-2: 构建字典实现 O(1) 查找，替代逐个 fetchRecording 的 O(n²) 查询。
        // 读库失败（nil）时宁可跳过本轮同步：把「读失败」当「库里没有条目」会让
        // 磁盘对账把所有已入库条目误判为新目录而重复插入。
        //
        // E1 空库快速通道：全新库/首次启动时数据库没有任何条目，全表物化与随后的对账、
        // 镜像修复循环都必然为空；先用 fetchCount 探一次，命中即跳过两次全表 fetch。
        // 计数失败或计数 > 0 时回退完整流程（保守，不改变对账语义）。
        //
        // 说明（E1 未覆盖部分）：对账循环需要逐条读取并就地修复模型字段（时长、视频标记、
        // 镜像），因此不能简单对本次 fetch 加 fetchLimit（会漏掉条目 → 误判为新目录 → 重复
        // 插入）。把这份全表物化整体移到后台 ModelContext / ModelActor 需要跨上下文合并与
        // 插入路径的一致改造，无法在无运行时验证的情况下安全完成，故本轮保守保留在主线程
        // （详见 docs/TECH_DEBT.md）。
        let existingRecordings: [String: AudioRecording]
        let existingQuickNotes: [String: QuickNote]
        if isEmptyDatabase(context: context) {
            existingRecordings = [:]
            existingQuickNotes = [:]
        } else {
            guard let recordings = await fetchExistingRecordingsDict(context: context),
                  let notes = await fetchExistingQuickNotesDict(context: context) else {
                return .empty
            }
            existingRecordings = recordings
            existingQuickNotes = notes
        }
        let allExistingFolders = Set(existingRecordings.keys)
            .union(existingQuickNotes.keys)

        // 修复历史损坏条目：曾以 duration=0 入库的录音（文件当时损坏），
        // 若文件已被恢复/修复则重新读取时长更新数据库。
        // 每个文件夹本次运行只探测一次：探测走 AVURLAsset 开销较大，
        // 文件确实损坏时反复重试只会每轮刷新都空转
        var repairedDuration = false
        for recording in existingRecordings.values where recording.duration <= 0 {
            let folderName = recording.folderName
            guard !durationProbeAttempted.contains(folderName) else { continue }
            durationProbeAttempted.insert(folderName)
            let duration = await getAudioDuration(at: recording.fileURL)
            if duration > 0 {
                recording.duration = duration
                repairedDuration = true
                logger.info("已修复历史条目时长: \(folderName) → \(duration)s")
            }
        }
        if repairedDuration {
            PersistenceReporting.saveOrReport { try context.save() }
        }

        // 修复历史条目类型（`hasVideoSource` 为 false 的行）：该字段是后加字段，
        // 迁移后旧行默认 false；且「清理视频」过去不写回 meta.json，于是这两类
        // 「录屏 / 导入视频」条目在列表里退回了「录音」图标。按磁盘证据补一次：
        // 留存原视频，或画面产物（frames/、visual.md 只有视频链路会生成）。
        // 只列举目录、不读文件内容，且每个文件夹本次运行只查一次。
        var repairedVideoFlag = false
        for recording in existingRecordings.values where !recording.hasVideoSource {
            let folderName = recording.folderName
            guard !folderName.isEmpty else { continue }
            guard !videoFlagRepairAttempted.contains(folderName) else { continue }
            videoFlagRepairAttempted.insert(folderName)
            let folderURL = recording.folderURL
            let indicatesVideoSource = await Task.detached(priority: .utility) {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                return AudioRecording.folderIndicatesVideoSource(folderURL: folderURL, files: files)
            }.value
            guard indicatesVideoSource else {
                continue
            }
            recording.hasVideoSource = true
            // 同步写回 meta.json：文件是权威源，别让下一次库重建再丢一次
            recording.saveMetaToFolder()
            repairedVideoFlag = true
            logger.info("已修复历史条目类型（视频条目）: \(folderName)")
        }
        if repairedVideoFlag {
            PersistenceReporting.saveOrReport { try context.save() }
        }

        // 权威镜像的增量修复（P1-7）：已入库条目不再「完全跳过」，而是双向对齐缺口
        // - 库里有内容、磁盘镜像缺失：补写镜像。镜像写入此前是 fire-and-forget，
        //   进程在写入前退出/被系统终止就会留下这种状态，而旧逻辑跳过已入库条目，
        //   下次启动也不会补，等于永久丢一份镜像
        // - 库为空、磁盘镜像存在：从磁盘补回库（保存失败或库重建后的恢复）
        // 两个方向都只「补缺失」、不覆盖已有内容；正常条目只多一次 stat。
        // 所有 stat 批量移出 MainActor；网络盘/外置盘抖动时不冻结列表交互。
        // 只把 folderName 字符串带出 MainActor；目标 URL 的解析（含 `fileExists`）与 stat
        // 全部在后台完成。此前在主线程 `.map` 构建目标：每条录音要解析 3 个 URL、
        // 每个 URL 都会对月份目录做一次 `fileExists`，10k 条目 ≈ 4 万次系统调用叠成
        // 一次数百毫秒的主线程阻塞（实测 ~415ms，为次轮最大单块）。
        let recordingFolderNames = existingRecordings.values.map(\.folderName)
        let noteFolderNames = existingQuickNotes.values.map(\.folderName)
        let (recordingMirrorStates, noteMirrorStates) = await Task.detached(priority: .utility) {
            var recordings: [String: RecordingMirrorDiskState] = [:]
            recordings.reserveCapacity(recordingFolderNames.count)
            for folderName in recordingFolderNames where !folderName.isEmpty {
                recordings[folderName] = probe(RecordingMirrorTarget.forFolder(named: folderName))
            }
            var notes: [String: NoteMirrorDiskState] = [:]
            notes.reserveCapacity(noteFolderNames.count)
            for folderName in noteFolderNames where !folderName.isEmpty {
                notes[folderName] = probe(NoteMirrorTarget.forFolder(named: folderName))
            }
            return (recordings, notes)
        }.value

        var repairedMirrors = 0
        var restoredDatabaseFromMirrors = false
        for (reconcileIndex, recording) in existingRecordings.values.enumerated() {
            if reconcileIndex > 0, reconcileIndex.isMultiple(of: Self.repairYieldCadence) {
                await Task.yield()
            }
            let folderName = recording.folderName
            guard !folderName.isEmpty else { continue }
            guard let mirrorState = recordingMirrorStates[folderName] else { continue }

            if let media = mirrorState.committedMerge, recording.storedFileName != media.audioName {
                recording.storedFileName = media.audioName
                recording.fileExtension = "m4a"
                recording.duration = media.duration
                recording.transcriptionStatus = media.transcriptionComplete ? .completed : .pending
                restoredDatabaseFromMirrors = true
                // 完整目录已原子提交：此时磁盘镜像是权威源，不能被普通的 1 秒时间容差
                // 跳过，也不能让旧索引重新补写覆盖刚合并的内容。
                let transcriptLoaded = await loadTranscriptIfNeeded(for: recording, context: context, replaceExisting: true)
                if transcriptLoaded {
                    recording.transcriptionStatus = media.transcriptionComplete ? .completed : .pending
                }
                _ = await loadSummaryIfNeeded(for: recording, context: context, replaceExisting: true)
            }

            let transcriptMirrorExists = mirrorState.transcriptExists
            let transcriptFileDate = mirrorState.transcriptDate
            let databaseTranscriptIsNewer = recording.transcriptModifiedAt.map { databaseDate in
                transcriptFileDate.map { databaseDate.timeIntervalSince($0) > 1 } ?? true
            } ?? false
            // 「库里有转写」改用标量 transcriptModifiedAt 判断：写入/恢复转写的两条路径
            //（saveTranscriptToFolder / loadTranscriptIfNeeded）都会写该字段，与「有片段」等价。
            // 旧写法用 `recording.segments.isEmpty` 作为分支条件，会对每条录音触发一次关系
            // fault（额外 SQL + 实例化全部片段），在对账循环里形成 N+1
            let databaseHasTranscript = recording.transcriptModifiedAt != nil
            // 恢复标记：该目标上次写入可能被强杀中断，无论磁盘镜像是否存在都强制按库补写一次
            // （标记已由后台批处理探测，避免在 MainActor 上逐条 stat）
            let transcriptRepairForced = mirrorState.transcriptPendingMarker
            var transcriptRepaired = false
            if databaseHasTranscript,
               (transcriptRepairForced || !transcriptMirrorExists || databaseTranscriptIsNewer),
               !recording.segments.isEmpty {
                let items = recording.segments.sorted { $0.startTime < $1.startTime }.map {
                    TranscriptMirrorItem(
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        speaker: ($0.speaker?.isEmpty == false) ? $0.speaker : nil,
                        text: $0.decryptedText
                    )
                }
                EntryMirrorStore.shared.submitTranscript(
                    items, folderName: folderName, to: recording.transcriptFileURL
                )
                repairedMirrors += 1
                transcriptRepaired = true
            } else if transcriptMirrorExists, !databaseHasTranscript {
                restoredDatabaseFromMirrors = await loadTranscriptIfNeeded(
                    for: recording, context: context
                ) || restoredDatabaseFromMirrors
            } else if let transcriptFileDate,
                      let databaseDate = recording.transcriptModifiedAt,
                      transcriptFileDate.timeIntervalSince(databaseDate) > 1 {
                restoredDatabaseFromMirrors = await loadTranscriptIfNeeded(
                    for: recording, context: context, replaceExisting: true
                ) || restoredDatabaseFromMirrors
            }
            // 标记残留但已无内容可补写（转写被清空/删除）：清掉标记，避免永久滞留
            if transcriptRepairForced, !transcriptRepaired {
                EntryMirrorStore.discardPendingMarker(for: recording.transcriptFileURL)
            }

            let summaryMirrorExists = mirrorState.summaryExists
            let summaryFileDate = mirrorState.summaryDate
            let databaseSummaryIsNewer = recording.summaryGeneratedAt.map { databaseDate in
                summaryFileDate.map { databaseDate.timeIntervalSince($0) > 1 } ?? true
            } ?? false
            let summaryRepairForced = mirrorState.summaryPendingMarker
            if summaryRepairForced || !summaryMirrorExists || databaseSummaryIsNewer {
                let plain = recording.decryptedSummary
                if !plain.isEmpty {
                    EntryMirrorStore.shared.submit(
                        plain, kind: .summary, folderName: folderName, to: recording.summaryFileURL
                    )
                    repairedMirrors += 1
                } else if summaryRepairForced {
                    EntryMirrorStore.discardPendingMarker(for: recording.summaryFileURL)
                }
            } else if recording.summary?.isEmpty ?? true
                        || fileIsNewer(summaryFileDate, than: recording.summaryGeneratedAt) {
                restoredDatabaseFromMirrors = await loadSummaryIfNeeded(
                    for: recording,
                    context: context,
                    replaceExisting: !(recording.summary?.isEmpty ?? true)
                ) || restoredDatabaseFromMirrors
            }

            let visualMirrorExists = mirrorState.visualExists
            let visualFileDate = mirrorState.visualDate
            let databaseVisualIsNewer = recording.visualSummaryGeneratedAt.map { databaseDate in
                visualFileDate.map { databaseDate.timeIntervalSince($0) > 1 } ?? true
            } ?? false
            let visualRepairForced = mirrorState.visualPendingMarker
            if visualRepairForced || !visualMirrorExists || databaseVisualIsNewer {
                let plain = recording.decryptedVisualSummary
                if !plain.isEmpty {
                    EntryMirrorStore.shared.submit(
                        plain, kind: .visual, folderName: folderName, to: recording.visualFileURL
                    )
                    repairedMirrors += 1
                } else if visualRepairForced {
                    EntryMirrorStore.discardPendingMarker(for: recording.visualFileURL)
                }
            } else if recording.visualSummary?.isEmpty ?? true
                        || fileIsNewer(visualFileDate, than: recording.visualSummaryGeneratedAt) {
                restoredDatabaseFromMirrors = await loadVisualSummaryIfNeeded(
                    for: recording,
                    context: context,
                    replaceExisting: !(recording.visualSummary?.isEmpty ?? true)
                ) || restoredDatabaseFromMirrors
            }
        }

        for (reconcileIndex, note) in existingQuickNotes.values.enumerated() {
            if reconcileIndex > 0, reconcileIndex.isMultiple(of: Self.repairYieldCadence) {
                await Task.yield()
            }
            let folderName = note.folderName
            guard !folderName.isEmpty else { continue }
            guard let mirrorState = noteMirrorStates[folderName] else { continue }
            let exists = mirrorState.exists
            let fileDate = mirrorState.date
            let databaseIsNewer = note.summaryGeneratedAt.map { databaseDate in
                fileDate.map { databaseDate.timeIntervalSince($0) > 1 } ?? true
            } ?? false
            let noteRepairForced = mirrorState.pendingMarker
            if noteRepairForced || !exists || databaseIsNewer {
                let plain = note.decryptedSummaryText
                if !plain.isEmpty {
                    EntryMirrorStore.shared.submit(
                        plain, kind: .summary, folderName: folderName, to: note.summaryFileURL
                    )
                    repairedMirrors += 1
                } else if noteRepairForced {
                    EntryMirrorStore.discardPendingMarker(for: note.summaryFileURL)
                }
            } else if note.summaryText?.isEmpty ?? true
                        || fileIsNewer(fileDate, than: note.summaryGeneratedAt) {
                let prepared = await loadEncryptedMirrorFile(at: note.summaryFileURL)
                if let value = prepared.encrypted ?? prepared.plain {
                    note.summaryText = value
                    note.summaryGeneratedAt = fileDate ?? Date()
                    restoredDatabaseFromMirrors = true
                }
            }
        }
        if shouldSaveMirrorReconciliation(
            repairedDiskMirrorCount: repairedMirrors,
            restoredDatabaseFromMirrors: restoredDatabaseFromMirrors
        ) {
            if repairedMirrors > 0 {
                logger.info("已按数据库补写 \(repairedMirrors) 个缺失的条目镜像")
            }
            if restoredDatabaseFromMirrors {
                logger.info("已从磁盘镜像恢复数据库内容并显式保存")
            }
            PersistenceReporting.saveOrReport { try context.save() }
        }

        // P1-4: 已入库条目完全跳过，不再调用 loadTranscriptIfNeeded/loadSummaryIfNeeded
        // 逐目录 `fileExists` + `isDir` 是同步 I/O：10k 条目下若不做让出会形成一次数百毫秒的主线程阻塞，
        // 故由 `filter` 改为带让出节奏的显式循环（语义等价）。
        var newDirs: [URL] = []
        newDirs.reserveCapacity(subDirs.count)
        for (index, dir) in subDirs.enumerated() {
            if index > 0, index.isMultiple(of: Self.newDirFilterYieldCadence) { await Task.yield() }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard !allExistingFolders.contains(dir.lastPathComponent),
                  !excludeFolderNames.contains(dir.lastPathComponent) else {
                continue
            }
            newDirs.append(dir)
        }

        guard !newDirs.isEmpty else {
            logger.info("无新条目需要同步")
            return .empty
        }

        logger.info("发现 \(newDirs.count) 个新文件夹，开始限并发扫描（窗口 \(Self.scanConcurrency)）")

        // P0-1: 并发阶段——文件 I/O（读 meta.json、获取音频时长、崩溃恢复），不触碰 ModelContext
        // 并发上限：每个扫描会开 1~2 个 AVURLAsset，崩溃恢复还会额外跑 AVAssetExportSession 导出；
        // 无上限 fan-out 在大库首轮扫描会瞬时耗尽文件句柄与解码线程（项目已为此抬过 RLIMIT、
        // 加过保存重试），并放大“探测读不出”进而误删完好数据
        let scanOutcomes: [FolderScanOutcome] = await withTaskGroup(of: [FolderScanOutcome].self) { group in
            let cursor = ScanCursor(total: newDirs.count)
            let dirs = newDirs
            let workerCount = min(Self.scanConcurrency, dirs.count)
            for _ in 0..<workerCount {
                group.addTask {
                    var batch: [FolderScanOutcome] = []
                    while let index = await cursor.next() {
                        if Task.isCancelled { break }
                        batch.append(await scanNewFolder(dir: dirs[index]))
                    }
                    return batch
                }
            }
            var results: [FolderScanOutcome] = []
            for await batch in group {
                results.append(contentsOf: batch)
            }
            return results
        }
        let scanResults = scanOutcomes.compactMap(\.result)

        // 顺序阶段——ModelContext 非线程安全，插入操作必须串行
        var newCount = 0
        var metadataSaveFailed = false
        // 插入前二次检查的已占用集合：以扫描开始时的快照为起点，每插入一条就登记
        // 批量二次检查：把「候选文件夹名里哪些已入库」压缩成按批的少数查询。
        // 取到的是循环开始时刻的快照；循环内本轮自己插入的占用由 occupiedFolderNames 跟进。
        // （原先逐条 `fetchCount`：10k 条目约 2 万次查询，是首轮主线程阻塞的主因）
        var candidateFolderNames: Set<String> = []
        for result in scanResults {
            switch result {
            case .recording(let data): if !data.folderName.isEmpty { candidateFolderNames.insert(data.folderName) }
            case .quickNote(let data): if !data.folderName.isEmpty { candidateFolderNames.insert(data.folderName) }
            }
        }
        let persistedAtStart = persistedFolderNames(among: candidateFolderNames, context: context)

        var occupiedFolderNames = allExistingFolders
        for (scanIndex, result) in scanResults.enumerated() {
            // 每条目含三次镜像加载尝试（可能触发懒加载 fault）：按批让出，
            // 避免首轮大库插入形成一段长阻塞
            if scanIndex > 0, scanIndex.isMultiple(of: 20) { await Task.yield() }
            switch result {
            case .recording(let data):
                let folderName = data.folderName
                // 扫描阶段并发且耗时，期间用户导入/手动刷新可能已把同一文件夹插入数据库；
                // 只凭扫描开始时的快照会插出重复条目（同一文件夹两份记录），故插入前再确认一次
                guard !occupiedFolderNames.contains(folderName),
                      !persistedAtStart.contains(folderName) else {
                    logger.info("跳过重复条目（本轮已插入或扫描期间已入库）: \(folderName)")
                    continue
                }
                occupiedFolderNames.insert(folderName)
                let recording = AudioRecording(
                    fileName: data.title
                        ?? makeDisplayName(folderName: data.folderName, fileName: data.storedFileName),
                    fileExtension: data.fileExtension,
                    duration: data.duration,
                    storedFileName: data.storedFileName,
                    folderName: data.folderName,
                    videoFileName: data.videoFileName
                )
                recording.createdAt = data.createdAt
                if let entryID = data.entryID { recording.id = entryID }
                recording.isHidden = data.isHidden
                // 兜底：meta.json 尚未带 hasVideoSource 的旧文件夹，只要磁盘上仍有视频就补上，
                // 之后即便用户清理原视频，条目类型也不会退回「录音」
                recording.hasVideoSource = data.hasVideoSource || recording.hasVideoSource
                recording.audioRemovedAt = data.audioRemovedAt
                if data.entryID == nil, !recording.saveMetaToFolder() { metadataSaveFailed = true }
                // 先插入再加载镜像：加载路径的提交前校验会按 id 确认条目仍存在，
                // 未插入的新条目会被误判为“已删除”
                context.insert(recording)
                await loadTranscriptIfNeeded(for: recording, context: context)
                await loadSummaryIfNeeded(for: recording, context: context)
                await loadVisualSummaryIfNeeded(for: recording, context: context)
                newCount += 1
                logger.info("从磁盘加载录音: \(data.folderName)/\(data.storedFileName)")

            case .quickNote(let data):
                let folderName = data.folderName
                guard !occupiedFolderNames.contains(folderName),
                      !persistedAtStart.contains(folderName) else {
                    logger.info("跳过重复条目（本轮已插入或扫描期间已入库）: \(folderName)")
                    continue
                }
                occupiedFolderNames.insert(folderName)
                let note = QuickNote(
                    title: data.title,
                    textContent: data.encryptedText,
                    sourceImageFileName: data.imageFileName,
                    ocrText: data.encryptedOcrText,
                    folderName: data.folderName
                )
                note.createdAt = data.createdAt
                if let entryID = data.entryID { note.id = entryID }
                note.isHidden = data.isHidden
                note.hasImageSource = data.hasImageSource
                if data.entryID == nil, !note.saveMetaToFolder() { metadataSaveFailed = true }
                let preparedSummary = await loadEncryptedMirrorFile(at: note.summaryFileURL)
                note.summaryText = preparedSummary.encrypted ?? preparedSummary.plain
                context.insert(note)
                newCount += 1
                logger.info("从磁盘加载快捷笔记: \(data.folderName)")
            }
        }

        var saveFailed = metadataSaveFailed
        if newCount > 0 {
            do {
                try context.save()
                logger.info("同步完成，新加载 \(newCount) 个条目")
            } catch {
                saveFailed = true
                logger.error("同步后保存数据库失败: \(error.localizedDescription)")
            }
        }

        // 汇总崩溃恢复详情，供 UI 层在刷新/启动同步后向用户反馈
        let recovered = scanOutcomes.compactMap(\.recovered)
        let recoveryFailedNames = scanOutcomes
            .filter(\.recoveryFailed)
            .map { makeDisplayName(folderName: $0.folderName, fileName: $0.folderName) }
        let stillRecordingCount = scanOutcomes.filter(\.stillRecording).count

        return SyncResult(
            newCount: newCount,
            saveFailed: saveFailed,
            recovered: recovered,
            recoveryFailedNames: recoveryFailedNames,
            stillRecordingCount: stillRecordingCount
        )
    }

    /// 插入前二次检查（**批量**）：候选文件夹名中哪些已被数据库占用。
    ///
    /// 扫描阶段会并发读取磁盘（可能持续数十秒），期间用户导入、手动刷新等路径可能已经把
    /// 同一文件夹插入数据库；只凭扫描开始时的文件夹快照会插出重复条目（同一文件夹两份记录）。
    ///
    /// 与原先的逐条 `fetchCount`（每条 2 次查询，10k 条目 ≈ 2 万次查询，是首轮主线程阻塞的主因）
    /// 语义等价，但改为**按候选集分批查询**：分块是为了不超 SQLite 的绑定参数上限；
    /// 只取回匹配行（通常为空），不物化全库模型。
    /// - Note: internal 以便单测直接验证（CLI 场景里 `newDirs` 已排除已入库文件夹，走不到这条跳过分支）
    @MainActor
    static func persistedFolderNames(
        among candidates: Set<String>,
        context: ModelContext
    ) -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let all = Array(candidates)
        let batchSize = 500
        var persisted: Set<String> = []
        var start = 0
        while start < all.count {
            let batch = Array(all[start..<min(start + batchSize, all.count)])
            let recordingDescriptor = FetchDescriptor<AudioRecording>(
                predicate: #Predicate { batch.contains($0.folderName) }
            )
            if let recordings = try? context.fetch(recordingDescriptor) {
                for recording in recordings where !recording.folderName.isEmpty {
                    persisted.insert(recording.folderName)
                }
            }
            let noteDescriptor = FetchDescriptor<QuickNote>(
                predicate: #Predicate { batch.contains($0.folderName) }
            )
            if let notes = try? context.fetch(noteDescriptor) {
                for note in notes where !note.folderName.isEmpty {
                    persisted.insert(note.folderName)
                }
            }
            start += batchSize
        }
        return persisted
    }

    // MARK: - 目录结构

    /// 是否为月份目录名（yyyy-MM）：新存储结构的第一级分组目录。
    /// 注意与带 -N 后缀的条目文件夹名区分（后者时间戳部分为 14 位数字）
    private static func isMonthFolderName(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return false }
        return name.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// 镜像双向对账只要任一方向产生变更都必须显式提交 ModelContext。
    /// 独立成纯函数，防止以后再次只统计“数据库 → 磁盘”而漏掉恢复路径。
    static func shouldSaveMirrorReconciliation(
        repairedDiskMirrorCount: Int,
        restoredDatabaseFromMirrors: Bool
    ) -> Bool {
        repairedDiskMirrorCount > 0 || restoredDatabaseFromMirrors
    }

    /// 在后台执行器展开存储目录（月份归档 + 旧版平铺兼容），避免启动任务阻塞主线程。
    /// internal：供 RuntimeVerification 的 --verify-filesync 统计发现到的条目目录数
    static func discoverEntryDirectories(at storageDir: URL) -> [URL]? {
        guard let topLevelDirs = try? FileManager.default.contentsOfDirectory(
            at: storageDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var result: [URL] = []
        for dir in topLevelDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            if isMonthFolderName(dir.lastPathComponent) {
                let inner = (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                result.append(contentsOf: inner)
            } else {
                result.append(dir)
            }
        }
        return result
    }

    // MARK: - 并发文件夹扫描（不触碰 ModelContext）

    /// 扫描新文件夹，返回结构化数据 + 崩溃恢复过程信息（供刷新结果反馈）
    private static func scanNewFolder(dir: URL) async -> FolderScanOutcome {
        var outcome = FolderScanOutcome()
        let folderName = dir.lastPathComponent
        outcome.folderName = folderName

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return outcome }

        // 合并互斥：该文件夹正在停止合并/崩溃恢复，本轮跳过（下轮扫描再处理）。
        // PID 化标记：以写标记进程是否存活为准（进程已死立即过期，消除 30 分钟盲区）；
        // 旧版 0 字节标记回退 mtime >30 分钟规则
        if mergeMarkerHoldsRecovery(at: dir) {
            logger.info("\(folderName) 处于合并锁定期，本轮扫描跳过")
            return outcome
        }
        logger.info("\(folderName) 的合并标记已过期（进程已死或超时），清除后按正常流程处理")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(mergeMarkerName))

        let itemType = readItemType(from: dir)
        let retainedAudio = retainedAudioMetadata(in: dir)

        let audioExtensions = Set(["m4a", "mp3", "wav"])
        let audioFile = files.first { file in
            let ext = file.pathExtension.lowercased()
            let name = file.lastPathComponent
            return audioExtensions.contains(ext)
                && !name.contains("_mic_tmp")
                && !name.contains("_sys_tmp")
        }

        // B-1: 录音崩溃/中断恢复——两种场景：
        // 1) 没有最终音频文件但有 _mic_tmp/_sys_tmp 分片（录音中崩溃/退出）：
        //    把可播放分片拼接/合并恢复为最终文件
        // 2) 最终文件存在但不可播放（合并导出被中断，容器未 finalize）：
        //    删除损坏文件后用分片重新拼接/合并
        var recovery: RecoveryOutcome?
        if let audioFile {
            switch await probeAudio(at: audioFile) {
            case .playable:
                recovery = nil
            case .unreadable(let reason):
                // 探测本身失败（I/O 压力/句柄耗尽/网络盘不可达）：**绝不删除**，本轮跳过下轮重试
                logger.warning("最终文件无法探测（非损坏判定），本轮跳过不删除: \(audioFile.lastPathComponent) - \(reason)")
                return outcome
            case .corrupt(let reason):
                // 写保护：文件近期仍在变化（2 分钟内）时视为“正在写入”，
                // 不删不恢复，避免删掉正在导出的半成品（标记机制的兜底防线）
                let fileMtime = ((try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.modificationDate]) as? Date) ?? .distantPast
                if Date().timeIntervalSince(fileMtime) < 120 {
                    logger.warning("最终文件不可播放但仍在写入中，本轮跳过: \(audioFile.lastPathComponent)")
                    return outcome
                }
                // 无分片可重建时保留原文件：删了就没有任何东西可恢复，
                // 用户还可拿 ffmpeg 等专业工具修；有分片才走“删损坏 + 重建”
                let hasRecoverySegments = files.contains { name in
                    let n = name.lastPathComponent
                    return n.contains("_mic_tmp") || n.contains("_sys_tmp")
                }
                guard hasRecoverySegments else {
                    logger.warning("最终文件确定损坏（\(reason)）但无可用分片，保留原文件供手动修复: \(audioFile.lastPathComponent)")
                    outcome.recoveryFailed = true
                    return outcome
                }
                logger.warning("最终录音文件不可播放（\(reason)），尝试从临时分片恢复: \(audioFile.lastPathComponent)")
                do {
                    try FileManager.default.removeItem(at: audioFile)
                } catch {
                    // 删除失败则无法写回同名最终文件：本轮跳过，下轮重试（不记为恢复失败以免误报）
                    logger.error("删除损坏最终文件失败，本轮不恢复: \(audioFile.lastPathComponent) - \(error.localizedDescription)")
                    return outcome
                }
                recovery = await recoverCrashedRecording(from: dir, files: files)
            }
        } else if retainedAudio?.audioRemovedAt == nil {
            recovery = await recoverCrashedRecording(from: dir, files: files)
        }

        // 恢复过程信息归类（成功详情在拿到最终时长后填充）
        if let recovery {
            switch recovery {
            case .failed:
                outcome.recoveryFailed = true
            case .stillRecording:
                outcome.stillRecording = true
            case .recovered, .nothingToDo:
                break
            }
        }

        // 路由：明确是 quicknote，或无音频文件（含恢复失败）但有 source.txt → 快捷笔记
        let effectiveAudioFile = audioFile ?? recovery?.recoveredURL
        if itemType == "quicknote" || (itemType != "recording" && effectiveAudioFile == nil && hasQuickNoteContent(files: files)) {
            outcome.result = scanQuickNote(folderName: folderName, files: files)
            return outcome
        }

        // 默认：录音
        guard effectiveAudioFile != nil || retainedAudio != nil else { return outcome }

        let createdAt = parseDate(from: folderName) ?? Date()
        let storedFileName = effectiveAudioFile?.lastPathComponent ?? retainedAudio!.storedFileName
        let fileExt = effectiveAudioFile?.pathExtension.lowercased() ?? retainedAudio!.fileExtension

        // 视频导入时留存的原始视频：按文件名约定识别（`{base}_video.{ext}`），
        // 与 QuickNote 的 source.png 同一范式，不从 meta.json 推字段。
        // 上面的音频扩展名集合不含视频后缀，因此它不会被当成“最终音频文件”参与损坏探测/删除
        let videoFileName = AudioConverter.retainedVideoFileName(in: files)

        // P0-1: 异步获取音频时长，不阻塞
        let duration: TimeInterval
        if let audioURL = effectiveAudioFile { duration = await getAudioDuration(at: audioURL) }
        else { duration = retainedAudio?.duration ?? 0 }

        // 崩溃恢复成功：填充恢复详情（含最终时长），供刷新结果横幅展示
        if recovery?.recoveredURL != nil {
            outcome.recovered = RecoveredRecordingInfo(
                folderName: folderName,
                displayName: makeDisplayName(folderName: folderName, fileName: folderName),
                duration: duration
            )
        }

        let meta = AudioRecording.loadMetaFromFolder(folderName: folderName)

        // 条目类型：meta.json 为准；老文件夹没有该字段时按磁盘证据补（留存原视频或画面产物），
        // 否则数据库重建后「已清理原视频的录屏」会被当纯录音，列表图标退回波形
        let hasVideoSource = meta.hasVideoSource
            || videoFileName != nil
            || AudioRecording.folderHasVisualArtifacts(folderURL: dir)

        outcome.result = .recording(FolderScanResult.RecordingData(
            folderName: folderName,
            createdAt: createdAt,
            storedFileName: storedFileName,
            fileExtension: fileExt,
            duration: duration,
            title: meta.title,
            isHidden: meta.isHidden,
            videoFileName: videoFileName,
            hasVideoSource: hasVideoSource,
            audioRemovedAt: effectiveAudioFile == nil
                ? retainedAudio?.audioRemovedAt.map(Date.init(timeIntervalSince1970:)) ?? Date() : nil,
            entryID: readEntryIdentity(in: dir)
        ))
        return outcome
    }

    /// 扫描快捷笔记文件夹
    /// G-1: 支持加密的 source.txt，向后兼容明文文件
    private static func scanQuickNote(folderName: String, files: [URL]) -> FolderScanResult? {
        var textContent: String?
        let sourceTxtURL = files.first { $0.lastPathComponent.lowercased() == "source.txt" }
        if let url = sourceTxtURL {
            // G-1: 尝试解密，解密失败则视为明文（向后兼容）
            textContent = EncryptionService.decryptFileOrPlaintext(at: url)
        }

        var imageFileName: String?
        let sourcePngURL = files.first { $0.lastPathComponent.lowercased() == "source.png" }
        if let url = sourcePngURL {
            imageFileName = url.lastPathComponent
        }

        let createdAt = parseDate(from: folderName) ?? Date()
        let meta = QuickNote.loadMetaFromFolder(folderName: folderName)
        let hasImageSource = meta.hasImageSource || imageFileName != nil
        guard textContent != nil || hasImageSource else { return nil }
        let title = meta.title ?? makeQuickNoteDisplayName(folderName: folderName, hasImage: hasImageSource)

        let ocrURL = AudioRecording.resolveFolderURL(forFolderName: folderName).appendingPathComponent("ocr.txt")
        let ocrText = EncryptionService.decryptFileOrPlaintext(at: ocrURL)
        var encryptedOcrText: String?
        if let ocrText {
            do { encryptedOcrText = try EncryptionService.encrypt(ocrText) }
            catch {
                EncryptionService.reportEncryptionFailure(error, context: "磁盘对账图片 OCR")
                encryptedOcrText = ocrText
            }
        }

        var encryptedText: String?
        if let text = textContent {
            // 旧的 `try?` 会把加密失败静默降级为明文：这里改为显式捕获并走统一上报
            // （日志每个调用点都记，用户提示每启动最多一次），与其余加密回退点同口径
            do {
                encryptedText = try EncryptionService.encrypt(text)
            } catch {
                EncryptionService.reportEncryptionFailure(error, context: "磁盘对账快捷笔记文字")
                encryptedText = text
            }
        }

        return .quickNote(FolderScanResult.QuickNoteData(
            folderName: folderName,
            createdAt: createdAt,
            title: title,
            encryptedText: encryptedText,
            imageFileName: imageFileName,
            isHidden: meta.isHidden,
            hasImageSource: hasImageSource,
            encryptedOcrText: encryptedOcrText,
            entryID: readEntryIdentity(in: AudioRecording.resolveFolderURL(forFolderName: folderName))
        ))
    }

    private static func readEntryIdentity(in folder: URL) -> UUID? {
        do { return try EntryIdentityStore.read(from: folder) }
        catch {
            logger.error("条目身份元数据读取失败：\(error.localizedDescription)")
            PersistenceReporting.reportSaveFailure(EntryMetadataWriteError(
                folderName: folder.lastPathComponent, reason: error.localizedDescription
            ))
            return nil
        }
    }

    /// 清理音频前保存的元数据允许无音频条目重建；不把遗留分片重新恢复成已清理的音频。
    private struct RetainedAudioMetadata: Decodable {
        let storedFileName: String
        let fileExtension: String
        let duration: TimeInterval
        let audioRemovedAt: Double?
    }

    private static func retainedAudioMetadata(in folder: URL) -> RetainedAudioMetadata? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode(RetainedAudioMetadata.self, from: data),
              !meta.storedFileName.isEmpty,
              URL(fileURLWithPath: meta.storedFileName).lastPathComponent == meta.storedFileName,
              ["m4a", "mp3", "wav"].contains(meta.fileExtension.lowercased()),
              meta.duration.isFinite, meta.duration >= 0 else { return nil }
        return meta
    }

    // MARK: - 异步音频时长

    /// AVURLAsset 探测前的廉价预检：文件不存在或 0 字节必然解析失败。
    /// 直接跳过，避免向 AVURLAsset 喂无效文件触发 CoreMedia 控制台错误
    /// （“URLAsset signalled err=-12170” 等框架内部日志）
    private static func isNonEmptyFile(at url: URL) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return false
        }
        return size > 0
    }

    // MARK: - PCM 分片容器头修补（崩溃恢复）

    /// 停录后先在独立副本修补，校验通过才交给合并；原始素材始终不变。
    /// 调用方负责在导出完成后清理返回的副本，且必须确认采集已经停止。
    static func repairedPCMContainerCopy(at url: URL) async -> URL? {
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "caf" else { return nil }
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent(".capture_repaired_\(UUID()).\(ext)")
        var accepted = false
        defer {
            if !accepted, FileManager.default.fileExists(atPath: copy.path) {
                do { try FileManager.default.removeItem(at: copy) }
                catch { logger.error("清理未通过校验的音频修复副本失败: \(error.localizedDescription)") }
            }
        }
        do { try FileManager.default.copyItem(at: url, to: copy) }
        catch {
            logger.error("创建音频修复副本失败: \(error.localizedDescription)")
            return nil
        }
        guard repairPCMContainerHeader(at: copy), await isAudioPlayable(at: copy) else {
            logger.warning("音频分片自动修复后仍未通过校验，保留原始分片")
            return nil
        }
        accepted = true
        logger.info("音频分片容器已自动修复并通过校验")
        return copy
    }

    /// 修补崩溃截断的 PCM 分片（.wav/.caf）容器头部。
    /// PCM 分片头部在文件开头、音频数据线性追加，异常退出仅导致头部 size 字段
    /// 过期（正常关闭时才回写最终值）；按实际文件长度重算并回写后即可正常读取：
    /// - WAV：RIFF 总长（偏移 4，LE32）+ data 块长度（LE32）
    /// - CAF：data 块长度（8 字节大端）
    /// - Returns: 是否修补成功（非 PCM 分片返回 false）
    private static func repairPCMContainerHeader(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "caf" else { return false }
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 44,
              let handle = FileHandle(forUpdatingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        // 该 SDK 中 read(upToCount:) 返回非可选 Data（读到 EOF 返回空 Data）
        guard let header = try? handle.read(upToCount: 4096), header.count >= 12 else {
            return false
        }
        if ext == "wav" {
            return patchWAVHeader(header, fileSize: size, handle: handle)
        } else {
            return patchCAFHeader(header, fileSize: size, handle: handle)
        }
    }

    /// 修补 WAV 头：逐 chunk 定位 data 块，回写 RIFF 总长与 data 长度（均小端）
    private static func patchWAVHeader(_ header: Data, fileSize: Int, handle: FileHandle) -> Bool {
        func le32(_ d: Data, _ o: Int) -> Int {
            Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
                | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24
        }
        guard header.subdata(in: 0..<4) == Data("RIFF".utf8),
              header.subdata(in: 8..<12) == Data("WAVE".utf8),
              fileSize - 8 <= Int(UInt32.max) else { return false }
        var offset = 12
        while offset + 8 <= header.count {
            let chunkID = header.subdata(in: offset..<(offset + 4))
            let chunkSize = le32(header, offset + 4)
            if chunkID == Data("data".utf8) {
                let dataStart = offset + 8
                guard fileSize >= dataStart else { return false }
                do {
                    try handle.seek(toOffset: 4)
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Data($0) })
                    try handle.seek(toOffset: UInt64(offset + 4))
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt32(fileSize - dataStart).littleEndian) { Data($0) })
                    return true
                } catch {
                    return false
                }
            }
            // RIFF chunk 按 2 字节对齐；size 为占位 0 时仍前进 8 字节，循环可终止
            offset += 8 + chunkSize + (chunkSize & 1)
        }
        return false
    }

    /// 修补 CAF 头：逐 chunk 定位 data 块，回写块长度（8 字节大端）
    private static func patchCAFHeader(_ header: Data, fileSize: Int, handle: FileHandle) -> Bool {
        func be64(_ d: Data, _ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(d[d.startIndex + o + i])
            }
            return v
        }
        guard header.subdata(in: 0..<4) == Data("caff".utf8) else { return false }
        var offset = 8
        while offset + 12 <= header.count {
            let chunkType = header.subdata(in: offset..<(offset + 4))
            let chunkSize = be64(header, offset + 4)
            if chunkType == Data("data".utf8) {
                let dataStart = offset + 12
                guard fileSize >= dataStart else { return false }
                do {
                    try handle.seek(toOffset: UInt64(offset + 4))
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt64(fileSize - dataStart).bigEndian) { Data($0) })
                    return true
                } catch {
                    return false
                }
            }
            // 前置 chunk 声称的长度超过文件总长 → 头部已损坏，放弃
            guard chunkSize <= UInt64(fileSize) else { return false }
            offset += 12 + Int(chunkSize)
        }
        return false
    }

    /// 异步获取音频时长（P0-1: 不阻塞主线程）
    /// 使用 AVURLAsset 加载元数据，比创建 AVAudioPlayer 开销小得多
    private static func getAudioDuration(at url: URL) async -> TimeInterval {
        guard isNonEmptyFile(at: url) else { return 0 }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }

    /// 音频可播放性探测结果
    ///
    /// 必须区分「确定损坏」与「读不出来」：只有 `.corrupt` 才允许删除文件。
    /// 旧实现把 `try? await asset.load(...)` 的任何失败（I/O 错误、句柄耗尽、
    /// 网络盘慢/掉线、并发抢占）一律归为“不可播放”，与真损坏不可区分，
    /// 叠加无上限并发扫描后存在**删掉完好原始录音**的风险。
    enum AudioProbe: Sendable {
        /// 容器完整、时长 >0 且有音轨
        case playable
        /// 确定损坏：空文件/纯容器壳/时长为 0/无音轨（可删后从分片重建）
        case corrupt(reason: String)
        /// 无法判定：探测本身出错（**不得删除**，本轮跳过下轮重试）
        case unreadable(reason: String)

        var isPlayable: Bool { if case .playable = self { return true }; return false }
    }

    /// 校验音频文件是否可播放（崩溃恢复的 m4a 可能缺 moov atom 而损坏）
    /// 非破坏性调用点（选分片/验证导出结果）用此入口；**删除文件前必须用 `probeAudio`**
    private static func isAudioPlayable(at url: URL) async -> Bool {
        await probeAudio(at: url).isPlayable
    }

    /// 三态探测：区分可播放 / 确定损坏 / 读不出来（见 `AudioProbe` 注释）
    private static func probeAudio(at url: URL) async -> AudioProbe {
        // 尺寸探测失败（权限/卷不可达）不等于“空文件”：必须归为 unreadable。
        // （`isNonEmptyFile` 对 stat 失败也返回 false，直接复用会把读不出来的完好文件当成损坏并删除）
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            return .unreadable(reason: "无法读取文件大小（权限或卷不可达）")
        }
        guard size > 0 else { return .corrupt(reason: "文件为空") }
        // 小的 AAC/PCM 也可能包含有效声音，文件字节数不能代替音轨和时长验证。
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            return .unreadable(reason: "时长读取失败: \(error.localizedDescription)")
        }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite else { return .unreadable(reason: "时长非有限值") }
        guard seconds > 0 else { return .corrupt(reason: "时长为 0") }
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return .unreadable(reason: "音轨枚举失败: \(error.localizedDescription)")
        }
        return tracks.isEmpty ? .corrupt(reason: "无音轨") : .playable
    }

    // MARK: - 字典查找（P0-2: O(1) 替代 O(n²) fetchRecording）

    /// 数据库是否为空（既无录音也无快捷笔记）。
    ///
    /// 用 `fetchCount` 探测：只返回匹配行数，不物化任何模型。计数失败（读库异常）
    /// 返回 false，让调用方走完整流程——把「读不出来」当「空库」会让磁盘对账把所有
    /// 文件夹当新条目重复插入。
    private static func isEmptyDatabase(context: ModelContext) -> Bool {
        guard let recordingCount = try? context.fetchCount(FetchDescriptor<AudioRecording>()),
              let noteCount = try? context.fetchCount(FetchDescriptor<QuickNote>()) else {
            return false
        }
        return recordingCount == 0 && noteCount == 0
    }

    /// 全表取数的分页大小。10k 条目下单次 `context.fetch` 会形成一段 ~200ms 的同步阻塞
    /// （`Task.yield()` 切不开 `fetch` 调用本身），故按 `folderName` 做 keyset 分页，
    /// 每页之间让出，把单块降到每页物化的量级；条目集合与顺序无关，语义等价。
    /// - Note: internal 以便单测用 `fetchPageSize + 1` 条验证跨页边界。
    static let fetchPageSize = 1000

    /// 获取已入库录音的 folderName → AudioRecording 字典；读库失败返回 nil
    /// （调用方据此跳过本轮同步，而不是把读失败当成「库里没有条目」）
    /// - Note: internal 以便单测验证跨页边界；生产入口是 `syncFromDisk`。
    @MainActor
    static func fetchExistingRecordingsDict(context: ModelContext) async -> [String: AudioRecording]? {
        var dict: [String: AudioRecording] = [:]
        var nextCursor = ""
        while true {
            let cursor = nextCursor
            var descriptor = FetchDescriptor<AudioRecording>(
                predicate: #Predicate { $0.folderName > cursor },
                sortBy: [SortDescriptor(\.folderName)]
            )
            descriptor.fetchLimit = Self.fetchPageSize
            let page: [AudioRecording]
            do {
                page = try context.fetch(descriptor)
            } catch {
                logger.error("读取已入库录音失败，本轮跳过磁盘同步以避免重复插入")
                return nil
            }
            if page.isEmpty { break }
            for recording in page where !recording.folderName.isEmpty {
                dict[recording.folderName] = recording
            }
            guard page.count == Self.fetchPageSize else { break }
            nextCursor = page[page.count - 1].folderName
            await Task.yield()
        }
        return dict
    }

    /// 获取已入库快捷笔记的 folderName → QuickNote 字典；读库失败返回 nil
    @MainActor
    private static func fetchExistingQuickNotesDict(context: ModelContext) async -> [String: QuickNote]? {
        var dict: [String: QuickNote] = [:]
        var nextCursor = ""
        while true {
            let cursor = nextCursor
            var descriptor = FetchDescriptor<QuickNote>(
                predicate: #Predicate { $0.folderName > cursor },
                sortBy: [SortDescriptor(\.folderName)]
            )
            descriptor.fetchLimit = Self.fetchPageSize
            let page: [QuickNote]
            do {
                page = try context.fetch(descriptor)
            } catch {
                logger.error("读取已入库快捷笔记失败，本轮跳过磁盘同步以避免重复插入")
                return nil
            }
            if page.isEmpty { break }
            for note in page where !note.folderName.isEmpty {
                dict[note.folderName] = note
            }
            guard page.count == Self.fetchPageSize else { break }
            nextCursor = page[page.count - 1].folderName
            await Task.yield()
        }
        return dict
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func fileIsNewer(_ fileDate: Date?, than databaseDate: Date?) -> Bool {
        guard let fileDate, let databaseDate else { return false }
        return fileDate.timeIntervalSince(databaseDate) > 1
    }

    // MARK: - 辅助方法

    /// 守护进程分片恢复入口：目录含崩溃遗留分片时执行恢复（跳过新鲜度检查——
    /// 主应用刚退出时分片 mtime 必然新鲜；worker 由握手协议保证独占运行，无并发录音）。
    /// 入库留给主应用下次启动的 syncFromDisk（幂等），不能在此全盘扫描
    static func recoverCrashedSegmentsIfPresent(in dir: URL) async -> URL? {
        // 合并互斥：标记仍活跃（写标记进程存活）的文件夹不介入，
        // 避免与垂死/挂起主应用的导出争抢分片与最终文件（历史事故同款竞态）
        if mergeMarkerHoldsRecovery(at: dir) { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        guard files.contains(where: {
            $0.lastPathComponent.contains("_mic_tmp")
                || $0.lastPathComponent.contains("_sys_tmp")
        }) else { return nil }
        return await recoverCrashedRecording(from: dir, files: files, skipFreshnessCheck: true).recoveredURL
    }

    /// B-1: 录音崩溃/中断恢复（分片滚动录音）
    /// 检测文件夹中的 `_mic_tmp_%04d.caf` / `_sys_tmp_%04d.wav` 分片（意外退出遗留）并主动恢复：
    /// 分片为崩溃安全的 PCM 容器，先修补头部 size 再校验可播放性，
    /// 1) 两条声轨均有可播放分片：各自顺序拼接后叠加混音（恢复完整录音），
    ///    成功后清理全部临时分片（含未被消费的不可播放空壳，如无 data 块的零帧 CAF）
    /// 2) 仅一条轨有可播放分片：拼接该轨作为最终文件（mic 优先，其次 sys）
    /// 3) 均不可播放（仅旧版 AAC 分片缺 moov atom，mdat 裸帧无边界无法重建）：保留文件并记录日志
    /// 兼容旧版单文件命名（`_mic_tmp.m4a` 无序号）。恢复后校验可播放性：仍不可播放则不入库
    /// - Returns: 恢复结果（成功 / 无需恢复 / 疑似仍在录制 / 失败），供调用方区分反馈文案
    /// - Parameter skipFreshnessCheck: 跳过“最新分片 2 分钟内仍在写则视为录音进行中”防护——
    ///   守护进程场景主应用刚退出，分片 mtime 必然新鲜但录音确已结束，须跳过
    static func recoverCrashedRecording(
        from dir: URL,
        files: [URL],
        skipFreshnessCheck: Bool = false
    ) async -> RecoveryOutcome {
        let micTmpURLs = files
            .filter { $0.lastPathComponent.contains("_mic_tmp") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sysTmpURLs = files
            .filter { $0.lastPathComponent.contains("_sys_tmp") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !micTmpURLs.isEmpty || !sysTmpURLs.isEmpty else { return .nothingToDo }

        // 最终文件名：从任一分片名去掉 _mic_tmp/_sys_tmp 与 _NNNN 序号后缀（兼容旧版无序号命名）
        let sampleName = (micTmpURLs.first ?? sysTmpURLs.first)!.lastPathComponent
        let finalName = deriveFinalName(fromSegmentName: sampleName)
        let finalURL = dir.appendingPathComponent(finalName)

        // 新鲜度防护：最新分片 2 分钟内仍在变化说明录音可能仍在进行（PCM 分片修补
        // 头部后即可播放，误消费正在写入的活跃分片会造成数据丢失），本轮跳过
        let newestMtime = (micTmpURLs + sysTmpURLs)
            .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
            .max() ?? .distantPast
        if !skipFreshnessCheck, Date().timeIntervalSince(newestMtime) < 120 {
            logger.info("临时分片近期仍在写入（疑似录音进行中），本轮跳过崩溃恢复: \(finalName)")
            return .stillRecording
        }

        // 合并互斥：恢复期间写入 PID 化标记，阻止并行的扫描/刷新介入同一文件夹（defer 保证任何路径都移除）
        writeMergeMarker(at: dir)
        defer { removeMergeMarker(at: dir) }

        logger.warning("检测到意外退出遗留的录音分片（mic=\(micTmpURLs.count) sys=\(sysTmpURLs.count)），尝试恢复为 \(finalName)")

        // PCM 分片（.caf/.wav）异常退出时头部 size 为过期值：按实际文件长度修补后即可播放
        var patchedCount = 0
        for url in micTmpURLs + sysTmpURLs where repairPCMContainerHeader(at: url) {
            patchedCount += 1
        }
        if patchedCount > 0 {
            logger.info("已修补 \(patchedCount) 个 PCM 分片的容器头")
        }

        // 过滤可播放分片（不可播放的：静音期空段 / 旧版 AAC 未 finalize 的最后一片）
        var micOK: [URL] = []
        for url in micTmpURLs where await isAudioPlayable(at: url) { micOK.append(url) }
        var sysOK: [URL] = []
        for url in sysTmpURLs where await isAudioPlayable(at: url) { sysOK.append(url) }
        let skipped = (micTmpURLs.count - micOK.count) + (sysTmpURLs.count - sysOK.count)
        if skipped > 0 {
            logger.warning("跳过 \(skipped) 个不可播放分片")
        }

        // 不可读不等于空壳；降级时原片全部留存，且记录到条目报告。
        var preserveOriginals: Bool
        do {
            _ = try RecordingSegmentTimeline.load(in: dir) // 损坏的新时间轴不能回退成无缺口的旧拼接。
            var report = try RecordingCaptureReportStore.load(in: dir) ?? RecordingCaptureReport()
            preserveOriginals = skipped > 0 || report.hasWarning || report.retainedOriginals == true
            if skipped > 0 {
                if !report.issues.contains(.audioDegraded) { report.issues.append(.audioDegraded) }
                report.skippedSegments = (micTmpURLs + sysTmpURLs).filter { !micOK.contains($0) && !sysOK.contains($0) }.map(\.lastPathComponent)
            }
            if preserveOriginals { report.retainedOriginals = true }
            try RecordingCaptureReportStore.save(report, in: dir)
        } catch {
            logger.error("恢复采集证据读写失败，保留全部分片: \(error.localizedDescription)")
            return .failed
        }

        // 场景 1：两轨均有可播放分片 → 拼接后叠加混音
        if !micOK.isEmpty, !sysOK.isEmpty {
            logger.info("两条声轨均有可播放分片，尝试拼接并混音")
            if await recoverMerge(micSegments: micOK, sysSegments: sysOK, outputURL: finalURL) {
                // 完整无告警才清理；降级/未知文件保留供后续修复。
                let shellCount = micTmpURLs.count + sysTmpURLs.count - micOK.count - sysOK.count
                if !preserveOriginals { removeRecoveryTemporaries(micTmpURLs + sysTmpURLs) }
                if shellCount > 0 {
                    logger.warning("已保留 \(shellCount) 个未合入分片供修复")
                }
                logger.info("✅ 恢复合并成功: \(finalName)")
                return .recovered(finalURL)
            }
            logger.warning("恢复合并失败，回退为仅拼接麦克风分片")
            preserveOriginals = true
            do {
                var report = try RecordingCaptureReportStore.load(in: dir) ?? RecordingCaptureReport()
                if !report.issues.contains(.audioDegraded) { report.issues.append(.audioDegraded) }
                report.retainedOriginals = true
                try RecordingCaptureReportStore.save(report, in: dir)
            } catch {
                logger.error("保存恢复降级证据失败，保留全部原片: \(error.localizedDescription)")
                return .failed
            }
        }

        // 场景 2：仅一轨可播放 → 拼接该轨作为最终文件（mic 优先，其次 sys）
        let salvageSegments = !micOK.isEmpty ? micOK : sysOK
        guard !salvageSegments.isEmpty else {
            // 场景 3：所有分片均不可播放——仅旧版 AAC 分片会走到这里
            // （moov 采样表只在关闭时写入，崩溃后 mdat 裸帧无边界标记，App 内无法重建）；
            // PCM 分片修补头部后必可播放。保留文件供专业工具尝试，不产生幽灵条目
            logger.error("所有分片均不可播放（旧版 AAC 分片缺 moov atom），无法在应用内恢复: \(finalName)。文件已保留，可用 ffmpeg 等专业工具尝试修复。")

            // 空壳自动清理：全部分片为无数据容器（<8KB，如静音期遗留的零帧 CAF/WAV）
            // 且目录无 meta/转写等产出时，删除空壳；目录已空则整体移除，
            // 避免每轮扫描对同一空壳目录反复空转（20260910182408 案例）。
            // 返回 nothingToDo：非真实恢复失败，不触发用户告警
            let allShells = (micTmpURLs + sysTmpURLs).allSatisfy { url in
                // 只有成功解码并确认零帧才是空壳；文件小或读取失败都不能作为删除证据。
                (try? AVAudioFile(forReading: url).length) == 0
            }
            if allShells {
                removeRecoveryTemporaries(micTmpURLs + sysTmpURLs)
                let meaningful = ["meta.json", "transcript.json", "summary.md", "source.txt", "source.png",
                                  RecordingCaptureReportStore.fileName, RecordingSegmentTimeline.fileName]
                // 读目录失败不得当成「目录为空」：那会误删仍含有效产出的目录。
                // 只有确实读到目录内容、且其中没有有效产出时才清理空壳目录
                if let remaining = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ), !remaining.contains(where: { meaningful.contains($0.lastPathComponent.lowercased()) }) {
                    try? FileManager.default.removeItem(at: dir)
                    logger.warning("空壳录音目录已清理: \(dir.lastPathComponent)")
                }
                return .nothingToDo
            }
            return .failed
        }
        if micOK.isEmpty {
            logger.info("麦克风分片不可用，改用可播放的系统音频分片恢复")
        }

        // 旧版 m4a 单分片直接改名（零开销）；PCM 分片与多分片经导出拼接为 m4a
        let concatSucceeded: Bool
        if salvageSegments.count == 1, salvageSegments[0].pathExtension.lowercased() == "m4a",
           !preserveOriginals, !FileManager.default.fileExists(atPath: dir.appendingPathComponent(RecordingSegmentTimeline.fileName).path) {
            concatSucceeded = (try? moveSegment(salvageSegments[0], to: finalURL)) != nil
        } else {
            concatSucceeded = await concatSegments(salvageSegments, to: finalURL)
        }
        guard concatSucceeded else {
            logger.error("崩溃录音恢复失败（拼接/改名失败）: \(finalName)，分片已保留")
            return .failed
        }
        logger.info("✅ 崩溃录音恢复成功: \(finalName)（\(salvageSegments.count) 片）")

        // 单轨回退不能删除未合入的另一轨；有降级证据时保留所有素材。
        if !preserveOriginals {
            removeRecoveryTemporaries(salvageSegments)
        }

        // 校验恢复出的最终文件确认可播放（容器未 finalize 的文件无法读取时长/音轨）
        if await !isAudioPlayable(at: finalURL) {
            logger.error("恢复的录音文件仍不可播放，已保留在磁盘但不入库: \(finalName)")
            return .failed
        }

        return .recovered(finalURL)
    }

    /// 从分片文件名推导最终文件名：去掉 _mic_tmp/_sys_tmp 标记与 _NNNN 序号，
    /// 扩展名统一为 .m4a（最终文件由导出生成，分片本身是 caf/wav/m4a）
    /// 兼容旧版无序号命名（20260817123456_mic_tmp.m4a → 20260817123456.m4a）
    private static func deriveFinalName(fromSegmentName name: String) -> String {
        var result = name
            .replacingOccurrences(of: "_mic_tmp", with: "")
            .replacingOccurrences(of: "_sys_tmp", with: "")
        if let regex = try? NSRegularExpression(pattern: "_\\d{4}(?=\\.[^.]+$)") {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return (result as NSString).deletingPathExtension + ".m4a"
    }

    /// 删除恢复过程中的临时分片（已消费分片与不可播放空壳一并清理）
    private static func removeRecoveryTemporaries(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 移动分片到目标位置（覆盖已存在的目标文件）
    private static func moveSegment(_ src: URL, to dst: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.moveItem(at: src, to: dst)
        return dst
    }

    /// 顺序拼接多个分片为单个 m4a（AVMutableComposition 逐段插入 + 导出）
    /// - Returns: 拼接成功且输出可播放返回 true
    private static func concatSegments(_ segments: [URL], to outputURL: URL) async -> Bool {
        var temporaryFiles: [URL] = []
        defer { removeRecoveryTemporaries(temporaryFiles) }
        do {
            let composition = AVMutableComposition()
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let totalSeconds = try await appendSegments(segments, to: track, temporaryFiles: &temporaryFiles)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return false
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try await exportWithWatchdog(exporter, outputURL: outputURL, estimatedAudioDuration: totalSeconds)
            return await isAudioPlayable(at: outputURL)
        } catch {
            logger.error("分片拼接失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 导出挂起看门狗：AVAssetExportSession 偶发永久挂起（20260910 会议事故实证：
    /// 合并卡死、.merging 标记无法释放、半成品残留且无任何用户可见反馈）。
    /// 超时后抛错，由调用方走失败清理路径（defer 释放标记、保留分片供下轮恢复）
    private static func exportWithWatchdog(
        _ exporter: AVAssetExportSession,
        outputURL: URL,
        estimatedAudioDuration: TimeInterval
    ) async throws {
        // AVAssetExportSession 非 Sendable：session 仅由导出任务独占操作，
        // 错误留在 LockedBox 内交接，不跨 Task 边界传递
        nonisolated(unsafe) let session = exporter
        let errorBox = LockedBox<SentError?>(nil)
        // 旧实现用 withThrowingTaskGroup 竞跑：结构化并发的 group 离开作用域前
        // 必须 join 所有子任务，而挂起的导出恰恰不响应协作取消——看门狗到点也走不出来。
        // RacingWatchdog 的定时任务是可取消的 Task.sleep，因此超时能真正脱离。
        let finished = await RacingWatchdog.race(
            name: "崩溃恢复导出 \(outputURL.lastPathComponent)",
            timeout: mergeExportTimeout(estimatedAudioDuration: estimatedAudioDuration),
            onTimeout: {
                // 超时后必须尽力中止导出：否则该导出可能继续往 outputURL 写，
                // 而调用方此后可能已删除/重建同一路径。cancelExport() 在 macOS 27
                // 被标记弃用但仍可用，故无条件调用（仅一条弃用警告）
                session.cancelExport()
            }
        ) {
            do {
                try await session.export(to: outputURL, as: .m4a)
            } catch {
                errorBox.value = SentError(error)
            }
        }
        guard finished else {
            if Task.isCancelled { throw CancellationError() }
            throw MergeExportTimeoutError()
        }
        if let exportError = errorBox.value {
            throw exportError.value
        }
    }

    /// 导出超时（供日志语义区分于普通取消）
    private struct MergeExportTimeoutError: Error {}

    /// 把分片按顺序追加到合成轨道（游标逐段后移），返回追加后的总时长（秒）
    @discardableResult
    private static func appendSegments(_ urls: [URL], to track: AVMutableCompositionTrack?, temporaryFiles: inout [URL]) async throws -> TimeInterval {
        let timeline = try urls.first.flatMap { try RecordingSegmentTimeline.load(in: $0.deletingLastPathComponent()) }
        return try await RecordingSegmentTimeline.append(urls, to: track, timeline: timeline, temporaryFiles: &temporaryFiles)
    }

    /// 恢复路径下的重新合并：两条声轨各自分片拼接后叠加混音导出为最终文件。
    /// 与录音停止时的实时合并逻辑一致，但独立实现（恢复路径不依赖录音服务状态）
    private static func recoverMerge(micSegments: [URL], sysSegments: [URL], outputURL: URL) async -> Bool {
        var temporaryFiles: [URL] = []
        defer { removeRecoveryTemporaries(temporaryFiles) }
        do {
            let composition = AVMutableComposition()

            let micTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let micSeconds = try await appendSegments(micSegments, to: micTrack, temporaryFiles: &temporaryFiles)

            // 系统音频轨与麦克风同时开始（叠加混音）
            let sysTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let sysSeconds = try await appendSegments(sysSegments, to: sysTrack, temporaryFiles: &temporaryFiles)

            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                return false
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try await exportWithWatchdog(
                exporter,
                outputURL: outputURL,
                estimatedAudioDuration: max(micSeconds, sysSeconds)
            )
            return await isAudioPlayable(at: outputURL)
        } catch {
            logger.error("恢复合并失败: \(error.localizedDescription)")
            return false
        }
    }

    /// 读取 meta.json 中的 itemType 字段
    private static func readItemType(from folderURL: URL) -> String? {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["itemType"] as? String
    }

    /// 判断文件夹是否包含快捷笔记内容（source.txt 或 source.png）
    private static func hasQuickNoteContent(files: [URL]) -> Bool {
        files.contains { file in
            let name = file.lastPathComponent.lowercased()
            return name == "source.txt" || name == "source.png"
        }
    }

    /// 条目是否仍存在于给定上下文（对账异步等待期间用户可能已删除条目）。
    /// 用按 id 的 fetch 判定：同一上下文内被 `delete` 的条目不会再被 fetch 到。
    @MainActor
    private static func entryStillExists(_ recording: AudioRecording, context: ModelContext) -> Bool {
        let id = recording.id
        let descriptor = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        guard let matches = try? context.fetch(descriptor) else { return false }
        return !matches.isEmpty
    }

    /// 如果文件夹中有 transcript.json 但数据库中没有转写片段，则加载
    /// G-1: 支持加密文件格式，向后兼容明文文件。
    /// 解密/解析/逐段重加密移入后台任务（数千段时主线程 AES 运算会卡启动），
    /// MainActor 只负责插入 SwiftData 模型
    /// MainActor 隔离：内部 detached 解密后回主线程再操作 ModelContext（非线程安全），
    /// 调用方 syncFromDisk 亦在主线程，不产生实际调度切换
    @MainActor
    @discardableResult
    private static func loadTranscriptIfNeeded(
        for recording: AudioRecording,
        context: ModelContext,
        replaceExisting: Bool = false
    ) async -> Bool {
        guard replaceExisting || recording.segments.isEmpty else { return false }

        let url = recording.transcriptFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        // 读取前记录条目版本：下面的读盘/解密是 await，期间用户可能编辑、重新转写或删除条目
        let versionBefore = TranscriptEntryVersion(recording: recording)

        let prepared: [PreparedTranscriptSegment]? = await Task.detached(priority: .userInitiated) { () -> [PreparedTranscriptSegment]? in
            guard let fileContent = EncryptionService.decryptFileOrPlaintext(at: url),
                  let data = fileContent.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return nil }
            var out: [PreparedTranscriptSegment] = []
            out.reserveCapacity(jsonArray.count)
            for item in jsonArray {
                let text = item["text"] as? String ?? ""
                var encrypted = text
                if !text.isEmpty, let e = try? EncryptionService.encrypt(text) {
                    encrypted = e
                }
                // 加密失败时保留明文（与主线程原逻辑一致的降级）
                out.append(PreparedTranscriptSegment(
                    startTime: item["startTime"] as? TimeInterval ?? 0,
                    endTime: item["endTime"] as? TimeInterval ?? 0,
                    speaker: item["speaker"] as? String,
                    text: encrypted
                ))
            }
            return out
        }.value

        guard let prepared else {
            logger.warning("转写文件解析失败: \(url.lastPathComponent)")
            return false
        }

        // 提交前重新校验：条目仍存在，且期间未发生编辑/重转写；否则丢弃本次结果，
        // 绝不用等待期间已过期的快照覆盖用户编辑（MainActor 只保证串行，不保证数据未变）
        guard entryStillExists(recording, context: context),
              TranscriptEntryVersion(recording: recording) == versionBefore else {
            logger.info("对账期间条目已变化，丢弃本次转写加载: \(url.lastPathComponent)")
            return false
        }

        if replaceExisting {
            for segment in recording.segments { context.delete(segment) }
            recording.segments.removeAll()
        }

        for item in prepared {
            let segment = TranscriptSegment(
                startTime: item.startTime,
                endTime: item.endTime,
                speaker: item.speaker,
                text: item.text
            )
            segment.recording = recording
            context.insert(segment)
        }
        recording.transcriptionStatus = .completed
        recording.transcriptModifiedAt = modificationDate(of: url) ?? Date()
        return true
    }

    /// 如果文件夹中有 summary.md 但数据库中没有总结，则加载
    /// G-1: 支持加密文件格式，向后兼容明文文件
    ///
    /// 整文件读盘 + 解密 + 再加密放到后台执行器：同文件的转写加载路径
    /// （`loadTranscriptIfNeeded`）早已后台化，这里曾是漏改的一处——它跑在
    /// `syncFromDisk` 的 MainActor 串行插入循环里，大库首轮同步会按条目数线性卡住启动。
    @MainActor
    @discardableResult
    private static func loadSummaryIfNeeded(
        for recording: AudioRecording,
        context: ModelContext,
        replaceExisting: Bool = false
    ) async -> Bool {
        guard replaceExisting || recording.summary == nil || recording.summary?.isEmpty == true else {
            return false
        }

        let url = recording.summaryFileURL
        // 读取前记录版本：下面的读盘/解密是 await，期间用户可能编辑总结、重新生成或删除条目
        let versionBefore = TextMirrorEntryVersion(
            generatedAt: recording.summaryGeneratedAt, content: recording.summary
        )

        let prepared = await loadEncryptedMirrorFile(at: url)
        if prepared.encrypted == nil, prepared.plain == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                logger.warning("总结文件解析失败: \(url.lastPathComponent)")
            }
            return false
        }

        // 提交前重新校验：条目仍存在且期间未变化，否则丢弃本次结果（不覆盖用户编辑）
        guard entryStillExists(recording, context: context),
              TextMirrorEntryVersion(
                generatedAt: recording.summaryGeneratedAt, content: recording.summary
              ) == versionBefore else {
            logger.info("对账期间条目已变化，丢弃本次总结加载: \(url.lastPathComponent)")
            return false
        }

        if let encrypted = prepared.encrypted {
            recording.summary = encrypted
        } else {
            recording.summary = prepared.plain
        }
        recording.summaryGeneratedAt = modificationDate(of: url) ?? Date()
        return true
    }

    /// 载入画面要点镜像（visual.md，加密）：仅对导入过原始视频的条目有意义，
    /// 旧条目无此文件则直接返回，不影响现有字段。
    /// 与 `loadSummaryIfNeeded` 同样标 `@MainActor`：它会写 SwiftData 模型字段，
    /// 不标则从 MainActor 扫描循环传 `recording`（非 Sendable）会被判为跨隔离传递风险
    @MainActor
    @discardableResult
    private static func loadVisualSummaryIfNeeded(
        for recording: AudioRecording,
        context: ModelContext,
        replaceExisting: Bool = false
    ) async -> Bool {
        guard replaceExisting || recording.visualSummary == nil
                || recording.visualSummary?.isEmpty == true else { return false }

        let url = recording.visualFileURL
        let versionBefore = TextMirrorEntryVersion(
            generatedAt: recording.visualSummaryGeneratedAt, content: recording.visualSummary
        )

        let prepared = await loadEncryptedMirrorFile(at: url)
        guard prepared.encrypted != nil || prepared.plain != nil else { return false }

        // 提交前重新校验：条目仍存在且期间未变化，否则丢弃本次结果
        guard entryStillExists(recording, context: context),
              TextMirrorEntryVersion(
                generatedAt: recording.visualSummaryGeneratedAt, content: recording.visualSummary
              ) == versionBefore else {
            logger.info("对账期间条目已变化，丢弃本次画面要点加载: \(url.lastPathComponent)")
            return false
        }

        if let encrypted = prepared.encrypted {
            recording.visualSummary = encrypted
        } else {
            recording.visualSummary = prepared.plain
        }
        recording.visualSummaryGeneratedAt = modificationDate(of: url) ?? Date()
        logger.info("从磁盘载入画面要点: \(recording.folderName)/\(url.lastPathComponent)")
        return true
    }

    /// 从「加密镜像文件」读回文本并准备库内存储值（总结与画面要点共用）。
    /// 返回值全为 Sendable（String?），不把 SwiftData 模型带进后台闭包；
    /// 解密失败时视为明文（向后兼容旧版明文文件），加密失败时仍然明文写入不丢内容
    private static func loadEncryptedMirrorFile(
        at url: URL
    ) async -> (encrypted: String?, plain: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }

        return await Task.detached(priority: .userInitiated) {
            guard let text = EncryptionService.decryptFileOrPlaintext(at: url), !text.isEmpty else {
                return (nil, nil)
            }
            do {
                return (try EncryptionService.encrypt(text), text)
            } catch {
                // 加密失败由 EncryptionService 统一留痕；此处仍写入明文保证可读，不丢内容
                return (nil, text)
            }
        }.value
    }

    /// 从文件夹名解析 Date（兼容 yyyyMMddHHmm 和 yyyyMMddHHmmss 两种格式）
    /// 文件夹名可能带唯一化后缀（如 20260810120000-1），先去除 "-" 及之后部分
    private static func parseDate(from folderName: String) -> Date? {
        let timestamp = folderName.split(separator: "-").first.map(String.init) ?? folderName
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        if timestamp.count == 14 {
            formatter.dateFormat = "yyyyMMddHHmmss"
        } else if timestamp.count == 12 {
            formatter.dateFormat = "yyyyMMddHHmm"
        } else {
            return nil
        }
        return formatter.date(from: timestamp)
    }

    /// 生成显示名称
    private static func makeDisplayName(folderName: String, fileName: String) -> String {
        if let date = parseDate(from: folderName) {
            return String(format: String(localized: "会议录音 %@"), date.formatted(date: .abbreviated, time: .shortened))
        }
        return (fileName as NSString).deletingPathExtension
    }

    /// 生成快捷笔记默认显示名
    private static func makeQuickNoteDisplayName(folderName: String, hasImage: Bool) -> String {
        if let date = parseDate(from: folderName) {
            let prefix = hasImage ? String(localized: "图片笔记") : String(localized: "文字笔记")
            return String(format: String(localized: "%@ %@"), prefix, date.formatted(date: .abbreviated, time: .shortened))
        }
        return String(localized: "快捷笔记")
    }
}

// MARK: - 扫描结果（Sendable，用于并发阶段，不触碰 ModelContext）

/// 转写文件的后台预处理产出（Sendable）：解密/重加密在后台完成后，
/// 仅携带插入 SwiftData 模型所需的最小字段回主线程
struct PreparedTranscriptSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let text: String
}

/// 磁盘对账期间的转写条目版本快照：异步读盘/解密前后比对。
///
/// `MainActor` 只保证模型访问串行，不能阻止 `await` 前后用户已编辑、重新转写或删除条目；
/// 提交前版本不一致就丢弃本次结果，避免用旧快照覆盖期间发生的编辑。
struct TranscriptEntryVersion: Equatable {
    let segmentCount: Int
    let modifiedAt: Date?
    let status: TranscriptionStatus

    @MainActor
    init(recording: AudioRecording) {
        segmentCount = recording.segments.count
        modifiedAt = recording.transcriptModifiedAt
        status = recording.transcriptionStatus
    }
}

/// 总结/画面要点条目的版本快照（生成时间 + 是否已有内容），用途同上
struct TextMirrorEntryVersion: Equatable {
    let generatedAt: Date?
    let hasContent: Bool

    @MainActor
    init(generatedAt: Date?, content: String?) {
        self.generatedAt = generatedAt
        self.hasContent = !(content?.isEmpty ?? true)
    }
}

enum FolderScanResult: Sendable {
    struct RecordingData: Sendable {
        let folderName: String
        let createdAt: Date
        let storedFileName: String
        let fileExtension: String
        let duration: TimeInterval
        let title: String?
        let isHidden: Bool
        let videoFileName: String?
        /// 条目是否为视频条目（录屏/导入视频）：来自 meta.json，清理原视频后仍保留，
        /// 用于列表图标/类型文案不因删除视频文件而退回「录音」
        let hasVideoSource: Bool
        var audioRemovedAt: Date? = nil
        var entryID: UUID? = nil
    }

    struct QuickNoteData: Sendable {
        let folderName: String
        let createdAt: Date
        let title: String
        let encryptedText: String?
        let imageFileName: String?
        let isHidden: Bool
        var hasImageSource: Bool = false
        var encryptedOcrText: String? = nil
        var entryID: UUID? = nil
    }

    case recording(RecordingData)
    case quickNote(QuickNoteData)
}
