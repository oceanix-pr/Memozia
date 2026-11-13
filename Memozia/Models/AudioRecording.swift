import Foundation
import SwiftData

/// 转写状态枚举
enum TranscriptionStatus: String, Codable {
    case pending    // 等待转写
    case processing // 转写中
    case completed  // 已完成
    case failed     // 失败
}

/// 通用处理状态（总结 / 画面要点 / 待办拆解等；语义与 `TranscriptionStatus` 对齐）。
///
/// 这些任务的进度态过去只存在于 ViewModel 的瞬时属性里，进程重启即丢失，
/// 导致队列面板无法在重启后恢复展示「进行中 / 失败」。补上持久化状态后，
/// 启动时的 `resetStaleProcessingStates` 会把残留的 `.processing` 复位为 `.pending`。
enum ProcessingStatus: String, Codable {
    case pending    // 未开始
    case processing // 处理中
    case completed  // 已完成
    case failed     // 失败
}

/// 录音数据模型
@Model
final class AudioRecording {
    var id: UUID
    var fileName: String
    var fileExtension: String
    var duration: TimeInterval  // 秒
    var createdAt: Date
    var transcriptionStatus: TranscriptionStatus
    var errorMessage: String?
    /// 总结处理状态（供队列面板重启后恢复展示）。
    ///
    /// **必须为可选**：这三个字段是 9.2.0 新增列，旧库经 SwiftData 轻量迁移后为 NULL；
    /// 若声明为非可选，访问器会把 `Optional<Any>` 强转成 `ProcessingStatus` 而直接崩溃
    /// （`Could not cast value of type 'Swift.Optional<Any>' to 'Memozia.ProcessingStatus'`）。
    /// `nil` 视同 `.pending`（比较语义一致），新插入的条目写入 `.pending`。
    var summaryStatus: ProcessingStatus? = ProcessingStatus.pending
    /// 画面要点处理状态（可选，说明见 `summaryStatus`）
    var visualStatus: ProcessingStatus? = ProcessingStatus.pending
    /// 待办拆解处理状态（可选，说明见 `summaryStatus`）
    var todoStatus: ProcessingStatus? = ProcessingStatus.pending

    /// 转写片段
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.recording)
    var segments: [TranscriptSegment]
    /// 最近一次在数据库中修改转写的时间，用于与 transcript.json 双向对账。
    var transcriptModifiedAt: Date? = nil

    /// 生成的总结（Markdown 文本）
    var summary: String?
    var summaryGeneratedAt: Date?

    /// 「画面要点」：视频关键帧经多模态 LLM 产出的按时间轴画面记录（**加密存储**，与 summary 同策略）。
    /// 仅导入过原始视频的条目可能非空；纯录音条目始终为 nil
    var visualSummary: String?
    var visualSummaryGeneratedAt: Date?

    /// 会议/非会议总结模板持久化：true=会议，false=非会议，nil=未选定。
    /// 由总结页「会议总结/概要总结」双按钮写入；旧队列条目续跑与批量总结等
    /// 无按钮入口按文本分类兑底后回写；转写完成（内容变化）时清空重选。
    /// 无密钥/用户文本，明文存储
    var isMeeting: Bool?
    /// 模板选择依据：manual=用户双按钮选择 / transcript=转写文本分类兑底（旧队列条目、批量总结）
    var meetingJudgedBy: String?
    var meetingJudgedAt: Date?

    /// 音频文件在 App 容器中的存储文件名（UUID-based，防止冲突）
    var storedFileName: String

    /// 录音来源（导入的文件为 nil，本机录音记录来源）
    var recordingSource: String?

    /// 所属文件夹名（yyyyMMddHHmmss），空字符串表示旧数据存于根目录
    var folderName: String = ""

    /// 是否在列表中隐藏（不删除文件，仅不显示）
    var isHidden: Bool = false

    /// 原始视频附件文件名（导入视频时抽完音轨后同文件夹留存，`{base}_video.{ext}`；纯录音为 nil）
    var videoFileName: String?

    /// 是否带视频源（录屏 / 导入视频）。独立于 `videoFileName` 持久保存：
    /// 清理原视频后文件名必须置空（不让模型指向已不存在的文件），但「这是视频条目」这一
    /// 事实要留下，否则列表图标会退回录音图标
    var hasVideoSource: Bool = false

    /// 仅清理音频原件的时间；条目、转写与总结仍保留。可选以兼容旧数据库。
    var audioRemovedAt: Date? = nil

    init(
        fileName: String,
        fileExtension: String,
        duration: TimeInterval = 0,
        storedFileName: String,
        recordingSource: RecordingSource? = nil,
        folderName: String = "",
        videoFileName: String? = nil
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.duration = duration
        self.createdAt = Date()
        self.transcriptionStatus = .pending
        self.segments = []
        self.storedFileName = storedFileName
        self.recordingSource = recordingSource?.rawValue
        self.folderName = folderName
        self.videoFileName = videoFileName
        self.hasVideoSource = videoFileName != nil
    }
}

// MARK: - 计算属性（需放在 extension 中，避免 @Model 宏冲突）
extension AudioRecording {
    /// UserDefaults 中存储自定义数据文件夹路径的 Key
    static let storageDirectoryKey = "Memozia_storage_directory"

    /// 进程内临时存储目录覆盖（仅运行时验证脚本使用）的容器：
    /// Swift 6 下可变全局状态用 Box 包装，读写都由 storageDirLock 保护
    private static let storageDirLock = NSLock()
    private static let storageDirBox = StorageDirBox()

    private final class StorageDirBox: @unchecked Sendable {
        /// 仅运行时验证脚本使用的进程内覆盖；不写 UserDefaults，进程退出即失效
        var runtimeOverride: URL?
    }

    /// UserDefaults 中「待下次启动生效」的数据文件夹路径
    static let pendingStorageDirectoryKey = "Memozia_pending_storage_directory"

    /// 当前生效的数据文件夹（UserDefaults 中的 active；不含 pending，也不含会话冻结）
    static var activeStorageDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: storageDirectoryKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return defaultStorageDirectory
    }

    /// 已选择、待重启生效的数据文件夹（nil 表示没有待切换项）
    static var pendingStorageDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: pendingStorageDirectoryKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 记录一个「待下次启动生效」的数据文件夹；本进程运行期根目录保持不变
    static func setPendingStorageDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: pendingStorageDirectoryKey)
    }

    /// 放弃待生效的数据文件夹
    static func clearPendingStorageDirectory() {
        UserDefaults.standard.removeObject(forKey: pendingStorageDirectoryKey)
    }

    /// 启动时把「待生效」提升为「当前生效」
    static func promotePendingStorageDirectory() {
        guard let pending = pendingStorageDirectory else { return }
        UserDefaults.standard.set(pending.path, forKey: storageDirectoryKey)
        UserDefaults.standard.removeObject(forKey: pendingStorageDirectoryKey)
    }

    /// 默认存储目录：macOS 为 ~/Documents/Memozia/，iOS 为沙盒 Documents/Memozia/
    static var defaultStorageDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        // homeDirectoryForCurrentUser 在 iOS 不可用，用沙盒 Documents 目录
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        return base.appendingPathComponent("Memozia")
    }

    /// 音频文件存储目录（可配置，默认 ~/Documents/Memozia/）。
    ///
    /// 根目录在**首次访问时由 `StorageSession` 解析并冻结**，运行期不再改变：设置页选择
    /// 新目录只写 `pendingStorageDirectory`，重启后才提升为 active。这样锁、队列、条目路径
    /// 与文件权威源始终对应同一个根，避免出现「双根目录」。
    /// 非 App Sandbox（entitlements 未启用 sandbox），可直接写用户文稿目录。
    static var storageDirectory: URL {
        storageDirLock.lock()
        let runtimeOverride = storageDirBox.runtimeOverride
        storageDirLock.unlock()
        // 运行时验证脚本的进程内覆盖优先：只影响本进程，不写偏好、不与其他进程共享
        if let runtimeOverride { return runtimeOverride }
        return StorageSession.resolve().rootDirectory
    }

    /// 立即改变本进程的数据文件夹（持久化到 UserDefaults 并重设会话根）。
    ///
    /// - Important: 仅供测试与运行时验证脚本使用。生产路径不要用它——运行中改根会让
    ///   已在旧根下的锁、队列与旧条目的 `folderURL` 与新根脱节（「双根目录」）。
    ///   设置页应改用 `setPendingStorageDirectory` + 重启应用。
    static func setStorageDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: storageDirectoryKey)
        UserDefaults.standard.removeObject(forKey: pendingStorageDirectoryKey)
        StorageSession.forceRoot(url)
    }

    /// 立即重置为默认数据文件夹（同时清除待生效项）。仅测试/验证使用，理由同上。
    static func resetStorageDirectory() {
        UserDefaults.standard.removeObject(forKey: storageDirectoryKey)
        UserDefaults.standard.removeObject(forKey: pendingStorageDirectoryKey)
        StorageSession.forceRoot(defaultStorageDirectory)
    }

    /// 设置/清除**进程内**临时存储目录覆盖（仅运行时验证脚本使用）。
    /// 与 `setStorageDirectory` 的关键区别：不写 UserDefaults，因此不会影响同机正在运行的
    /// 其他 Memozia 实例，进程退出后自然失效；传 nil 即恢复按偏好解析。
    static func setRuntimeStorageOverride(_ url: URL?) {
        storageDirLock.lock()
        storageDirBox.runtimeOverride = url
        storageDirLock.unlock()
    }

    /// 生成 yyyyMMddHHmmss 格式的文件夹名（与文件名同格式）
    static func folderName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter.string(from: date)
    }

    /// 生成 yyyyMMddHHmmss 格式的文件名（与文件夹名同口径，避免非公历 locale 下分叉）
    static func fileName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter.string(from: date)
    }

    /// 生成 yyyy-MM 格式的月份文件夹名（存储目录第一级按月分组，如 2026-08）
    static func monthFolderName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.autoupdatingCurrent
        return formatter.string(from: date)
    }

    /// 由条目文件夹名（yyyyMMddHHmmss，可带 -N 唯一化后缀）推导月份文件夹名；无法推导返回 nil
    static func monthFolderName(fromFolderName folderName: String) -> String? {
        let timestamp = folderName.split(separator: "-").first.map(String.init) ?? folderName
        guard timestamp.count >= 6, timestamp.allSatisfy({ $0.isNumber }) else { return nil }
        return "\(timestamp.prefix(4))-\(timestamp.dropFirst(4).prefix(2))"
    }

    /// 解析条目文件夹 URL：优先月份目录（新结构 yyyy-MM/条目名），不存在时回退平铺目录（旧数据兼容）
    static func resolveFolderURL(forFolderName folderName: String) -> URL {
        guard !folderName.isEmpty else { return storageDirectory }
        if let month = monthFolderName(fromFolderName: folderName) {
            let monthly = storageDirectory
                .appendingPathComponent(month)
                .appendingPathComponent(folderName)
            if FileManager.default.fileExists(atPath: monthly.path) {
                return monthly
            }
        }
        return storageDirectory.appendingPathComponent(folderName)
    }

    /// 创建并返回该录音专属的文件夹 URL（新建统一归入当月月份目录）
    ///
    /// 注意：`withIntermediateDirectories: true` 对已存在目录同样返回成功，**不能**用来
    /// 分配新名字（并发创建会共用同一目录并互相覆盖文件）。新建条目请用 `createUniqueFolder(from:)`
    static func createFolder(named folderName: String) -> URL {
        let parent: URL
        if let month = monthFolderName(fromFolderName: folderName) {
            parent = storageDirectory.appendingPathComponent(month)
        } else {
            parent = storageDirectory
        }
        let dir = parent.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 唯一化重试上限：同一秒内并发新建超过这个数量说明磁盘状态异常，避免无界循环
    private static let uniqueFolderAttempts = 100

    /// 原子分配并创建唯一的 yyyyMMddHHmmss 文件夹，返回实际创建的文件夹名
    ///
    /// 同一秒内的多次创建（连续导入/连续录音/连续新建笔记）会得到相同的时间戳名。
    /// 旧实现是「先查后建」：`allocateUniqueFolderName` 判断不存在后，另一个调用方可能
    /// 在同一瞬间也判断为不存在，两者拿到同一个名字；而 `createFolder` 对已存在目录同样
    /// 返回成功 —— 于是两条记录共用一个文件夹、互相覆盖文件（静默数据丢失）。
    /// 这里改成以 mkdir 成败为准的原子循环：叶子目录用 `withIntermediateDirectories: false`
    /// 创建，已存在时按 `-N` 换名重试，只有真正独占创建成功才返回名字。
    /// - Returns: 本次独占创建的文件夹名；父目录不可写或重试上限内全部冲突时返回 nil
    @MainActor
    static func createUniqueFolder(from date: Date) -> String? {
        let base = folderName(from: date)
        let parent: URL
        if let month = monthFolderName(fromFolderName: base) {
            parent = storageDirectory.appendingPathComponent(month)
            // 月份目录本身可以复用，允许带中间目录创建
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            parent = storageDirectory
        }
        for attempt in 0..<uniqueFolderAttempts {
            let candidate = attempt == 0 ? base : "\(base)-\(attempt)"
            do {
                try FileManager.default.createDirectory(
                    at: parent.appendingPathComponent(candidate),
                    withIntermediateDirectories: false
                )
                return candidate
            } catch let error as NSError {
                // 只为「已存在」换名重试；其它错误（父目录不可写、磁盘满等）直接失败，
                // 不能像旧实现那样假装创建成功
                let alreadyExists = (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError)
                    || (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
                guard alreadyExists else { return nil }
            }
        }
        return nil
    }

    /// 该录音所属的文件夹 URL（月份目录优先，旧平铺结构兼容；空 folderName 时回退到根目录）
    var folderURL: URL {
        Self.resolveFolderURL(forFolderName: folderName)
    }

    /// 获取本地文件 URL
    var fileURL: URL {
        folderURL.appendingPathComponent(storedFileName)
    }

    /// 原始视频附件 URL（视频导入时留存）。文件可能被用户在 Finder 里删掉，
    /// 调用方需自行做存在性校验，不能把非 nil 等同于“文件一定在”
    var videoFileURL: URL? {
        guard let videoFileName, !videoFileName.isEmpty else { return nil }
        return folderURL.appendingPathComponent(videoFileName)
    }

    /// 转写记录文件 URL
    var transcriptFileURL: URL {
        folderURL.appendingPathComponent(Self.transcriptFileName)
    }

    /// 总结文件 URL
    var summaryFileURL: URL {
        folderURL.appendingPathComponent(Self.summaryFileName)
    }

    /// 画面要点文件 URL（加密镜像，与 summary.md 同一约定）
    var visualFileURL: URL {
        folderURL.appendingPathComponent(Self.visualFileName)
    }

    /// 关键帧存放子目录（`<folder>/frames/`）：抽出的帧落盘而非只内存驻留，
    /// 换模型重生时不必重抽，也方便用户自己核对。整个录音文件夹删除时随之清理
    var framesDirectoryURL: URL {
        folderURL.appendingPathComponent(AudioRecording.framesDirectoryName, isDirectory: true)
    }

    /// 画面分析分段检查点（加密文本）：请求被取消、应用退出或网络中断后，
    /// 相同模型与相同帧集再次分析时可从未完成分段继续，而不是重传已完成图片。
    var visualAnalysisCheckpointDirectoryURL: URL {
        folderURL.appendingPathComponent(
            AudioRecording.visualAnalysisCheckpointDirectoryName,
            isDirectory: true
        )
    }

    /// 关键帧存放子目录名（`<folder>/frames/`）：抽出的帧落盘而非只内存驻留，
    /// 换模型重生时不必重抽，也方便用户自己核对；整个录音文件夹删除时随之清理
    static let framesDirectoryName = "frames"
    static let visualAnalysisCheckpointDirectoryName = "visual-analysis-checkpoint"
    static let transcriptFileName = "transcript.json"
    static let summaryFileName = "summary.md"
    static let visualFileName = "visual.md"

    /// 单张关键帧的落盘文件名：`kf_四位序号_秒数s.jpg`（保留毫秒，1024 帧内字典序即时间序）
    static func frameFileName(index: Int, time: TimeInterval) -> String {
        let timestamp = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), time)
        return "kf_\(String(format: "%04d", index))_\(timestamp)s.jpg"
    }

    /// 画面链路的产物是否还在（关键帧或画面要点）。
    ///
    /// 「清理视频」后磁盘扫描再也推不回 `videoFileName`（它按文件名约定识别），
    /// 若页签可见性只看它，用户会以为关键帧和要点一起没了。产物才是这一页要展示的东西，
    /// 因此以产物为准。只做目录列举与存在判断，不读图片内容。
    var hasVisualArtifacts: Bool {
        AudioRecording.folderHasVisualArtifacts(folderURL: folderURL)
    }

    /// 指定文件夹里的画面产物是否还在（关键帧或画面要点）。
    /// 按 URL 判断，磁盘扫描在没有模型对象时也能用同一份判据。
    static func folderHasVisualArtifacts(folderURL: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: folderURL.appendingPathComponent(visualFileName).path) {
            return true
        }
        let frames = (try? manager.contentsOfDirectory(
            at: folderURL.appendingPathComponent(framesDirectoryName, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return frames.contains { $0.pathExtension.lowercased() == "jpg" }
    }

    /// 文件夹里是否还留着「这是视频条目（录屏 / 导入视频）」的证据：留存的原视频
    /// （`{base}_video.{ext}` 命名约定）或画面产物，二者有一即可。
    ///
    /// 「清理视频」删掉的只是原视频本身，帧与画面要点会留下，所以产物同样能证明条目
    /// 来自视频源。判据按文件夹给，供磁盘重扫与历史条目类型修复复用——`hasVideoSource`
    /// 是后加字段（迁移后旧行默认 false），且清理时若没写回 meta.json，只看该字段会让
    /// 已清理原视频的录屏退回「录音」图标。
    static func folderIndicatesVideoSource(folderURL: URL, files: [URL]) -> Bool {
        if folderHasVisualArtifacts(folderURL: folderURL) { return true }
        return AudioConverter.retainedVideoFileName(in: files) != nil
    }

    /// 元数据文件 URL（保存标题和隐藏状态）
    var metaFileURL: URL {
        folderURL.appendingPathComponent("meta.json")
    }

    /// 旧版标题文件 URL（向后兼容）
    var titleFileURL: URL {
        folderURL.appendingPathComponent("title.txt")
    }

    /// 将标题和隐藏状态保存到文件夹中的 meta.json
    @discardableResult
    func saveMetaToFolder() -> Bool {
        guard !folderName.isEmpty else { return false }
        let meta: [String: Any] = [
            "title": fileName,
            "isHidden": isHidden,
            "itemType": "recording",
            "hasVideoSource": isVideoRecording,
            "storedFileName": storedFileName,
            "fileExtension": fileExtension,
            "duration": duration,
            "audioRemovedAt": audioRemovedAt?.timeIntervalSince1970 as Any? ?? NSNull()
        ]
        do {
            id = try EntryIdentityStore.write(meta, id: id, to: folderURL)
            return true
        } catch {
            PersistenceReporting.reportSaveFailure(
                EntryMetadataWriteError(folderName: folderName, reason: error.localizedDescription)
            )
            return false
        }
    }

    /// 将标题保存到文件夹（兼容旧版 title.txt 和新版 meta.json）
    func saveTitleToFolder(_ title: String) {
        guard !folderName.isEmpty else { return }
        fileName = title
        saveMetaToFolder()
    }

    /// 从文件夹加载元数据（标题 + 隐藏状态 + 视频源标记），
    /// 兼容旧版 title.txt；月份目录优先、旧平铺结构兼容
    static func loadMetaFromFolder(folderName: String)
        -> (title: String?, isHidden: Bool, hasVideoSource: Bool) {
        guard !folderName.isEmpty else { return (nil, false, false) }
        let folderURL = resolveFolderURL(forFolderName: folderName)
        let metaURL = folderURL.appendingPathComponent("meta.json")
        // 优先读取 meta.json
        if FileManager.default.fileExists(atPath: metaURL.path),
           let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = json["title"] as? String
            let isHidden = json["isHidden"] as? Bool ?? false
            let hasVideoSource = json["hasVideoSource"] as? Bool ?? false
            return (title, isHidden, hasVideoSource)
        }
        // 回退到旧版 title.txt
        let titleURL = folderURL.appendingPathComponent("title.txt")
        if FileManager.default.fileExists(atPath: titleURL.path),
           let data = try? Data(contentsOf: titleURL),
           let title = String(data: data, encoding: .utf8) {
            return (title, false, false)
        }
        return (nil, false, false)
    }

    /// 从文件夹中的 title.txt 加载标题（向后兼容，内部使用 loadMetaFromFolder）
    static func loadTitleFromFolder(folderName: String) -> String? {
        loadMetaFromFolder(folderName: folderName).title
    }

    /// 完整转写文本（自动解密）
    var fullTranscript: String {
        segments
            .sorted { $0.startTime < $1.startTime }
            .map { $0.decryptedText }
            .joined(separator: "\n")
    }

    /// 转写内容的 Markdown 格式（带时间戳和发言人）
    /// 注意：编辑后的录音只保留单个片段，其 text 本身已是完整 Markdown，
    /// 不再重复添加时间段前缀，避免每次编辑累积重复内容。
    var transcriptMarkdown: String {
        Self.transcriptMarkdown(from: transcriptSnapshot)
    }

    /// 转写片段的纯值快照（Sendable）：让 Markdown 构建与导出可以放到后台线程，
    /// 避免在主线程对数千段逐段做 AES-GCM 解密
    struct TranscriptSnapshotItem: Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let speaker: String?
        /// 原始（可能加密的）文本；解密在后台执行
        let rawText: String
    }

    /// 主线程只做 SwiftData 快照（排序 + 取原始文本），不解密
    var transcriptSnapshot: [TranscriptSnapshotItem] {
        segments
            .sorted { $0.startTime < $1.startTime }
            .map {
                TranscriptSnapshotItem(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    speaker: $0.speaker,
                    rawText: $0.text
                )
            }
    }

    /// 由快照构建转写 Markdown（可在后台线程执行，输出与 `transcriptMarkdown` 一致）
    nonisolated static func transcriptMarkdown(from snapshot: [TranscriptSnapshotItem]) -> String {
        // 单个片段：直接返回其文本（可能是编辑后的完整 Markdown）
        if snapshot.count == 1 {
            return EncryptionService.decryptSafely(snapshot[0].rawText)
        }
        return snapshot
            .map { item in
                var line = "**\(item.startTime.formattedAsDuration(fractionDigits: 1)) - \(item.endTime.formattedAsDuration(fractionDigits: 1))**"
                if let speaker = item.speaker, !speaker.isEmpty {
                    line += " · **\(speaker)**"
                }
                line += "\n\n\(EncryptionService.decryptSafely(item.rawText))"
                return line
            }
            .joined(separator: "\n\n---\n\n")
    }

    /// 解密后的总结内容
    var decryptedSummary: String {
        EncryptionService.decryptSafely(summary)
    }

    /// 解密后的画面要点内容
    var decryptedVisualSummary: String {
        EncryptionService.decryptSafely(visualSummary)
    }

    /// 格式化的时长显示（支持超过 1 小时）
    var formattedDuration: String {
        duration.formattedAsDuration()
    }

    /// 是否按视频条目展示（录屏 / 导入视频）：清理原视频后仍为 true。
    /// `videoFileName` 作旧行兜底——`hasVideoSource` 是后加字段，迁移后旧行默认 false
    var isVideoRecording: Bool {
        hasVideoSource || videoFileName != nil
    }

    /// 条目类型：列表图标与类型文案的唯一判据，避免多处各判一次导致录屏/录音看起来一样。
    ///
    /// 录屏与导入视频不区分，统一按「录屏」展示：两者都带视频源，属同一类。
    enum MediaKind: Equatable {
        case audio
        case screenRecording

        /// 列表图标：波形 = 纯音频，显示器 = 录屏（含导入视频）。配色（录音红、录屏蓝）见 `RecordingListView`
        var iconName: String {
            switch self {
            case .audio:           return "waveform"
            case .screenRecording: return "display"
            }
        }
    }

    var mediaKind: MediaKind {
        isVideoRecording ? .screenRecording : .audio
    }

    /// 录音来源枚举（便于 UI 使用）
    var source: RecordingSource? {
        guard let raw = recordingSource else { return nil }
        return RecordingSource(rawValue: raw)
    }

    /// 是否为本机录音（区别于导入的文件）
    var isLocalRecording: Bool {
        recordingSource != nil
    }
}

struct EntryMetadataWriteError: LocalizedError {
    let folderName: String
    let reason: String
    /// 必须用 `%@` 占位而不是字符串插值：插值串不会进 String Catalog，
    /// 英文界面下会整条显示中文（`reason` 本身来自系统错误，已是本地化文本）
    var errorDescription: String? {
        String(format: String(localized: "条目元数据写入失败（%@）：%@"), folderName, reason)
    }
}
