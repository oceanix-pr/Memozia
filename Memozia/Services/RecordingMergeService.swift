import AVFoundation
import Darwin
import Foundation
import Observation
import os.log

/// MainActor 上领取文件操作所有权；扫描、更新、退出与界面共用同一状态。
@MainActor @Observable
final class RecordingMergeActivity {
    static let shared = RecordingMergeActivity()
    var isRunning = false
}

/// 只接收值快照。暂存完整条目后原子交换目录，任何导出/镜像失败都不修改原件。
actor RecordingMergeService {
    struct Input: Sendable {
        let id: UUID
        let folderName: String
        let folderURL: URL
        let audioURL: URL
        let title: String
        let segments: [AudioRecording.TranscriptSnapshotItem]
        let summary: String?
        var isHidden = false
        var transcriptionComplete = false
    }

    struct Prepared: Sendable {
        let stagingURL: URL
        let destinationURL: URL
        let audioName: String
        let duration: Double
        let segments: [TranscriptMirrorItem]
        let encryptedTexts: [String]
        let encryptedSummary: String?
        let hasTodos: Bool
    }

    struct MergeError: LocalizedError {
        var errorDescription: String? { String(localized: "无法安全合并录音。请检查音频、条目文件和磁盘空间后重试。") }
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "RecordingMerge")
    static let historyName = ".merged-recording-ids.json"
    static let committedMediaName = ".recording-merge.json"

    struct CommittedMedia: Codable, Sendable {
        let audioName: String
        let duration: Double
        let transcriptionComplete: Bool
    }

    /// 目录已提交但索引尚未保存即崩溃时，由磁盘对账恢复正确的音频指针。
    nonisolated static func committedMedia(in folder: URL) -> CommittedMedia? {
        let url = folder.appendingPathComponent(committedMediaName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let media = try JSONDecoder().decode(CommittedMedia.self, from: Data(contentsOf: url))
            guard media.audioName == URL(fileURLWithPath: media.audioName).lastPathComponent,
                  media.audioName.hasPrefix("merged-"), media.audioName.hasSuffix(".m4a"),
                  media.duration.isFinite, media.duration > 0,
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent(media.audioName).path) else { throw MergeError() }
            return media
        } catch {
            logger.error("合并提交记录读取失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func prepare(_ inputs: [Input], destinationURL: URL? = nil) async throws -> Prepared {
        guard inputs.count >= 2, let latest = inputs.last else { throw MergeError() }
        let manager = FileManager.default
        // 同级隐藏目录不参与磁盘条目扫描，且保证交换在同一文件系统中完成。
        let destination = destinationURL ?? latest.folderURL
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".recording-merge-\(UUID())", isDirectory: true)
        var prepared = false
        defer { if !prepared { Self.removeStaging(staging) } }
        if latest.folderName.isEmpty {
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            let meta: [String: Any] = ["title": latest.title, "isHidden": latest.isHidden, "hasVideoSource": false]
            try JSONSerialization.data(withJSONObject: meta).write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        } else {
            try manager.copyItem(at: latest.folderURL, to: staging)
        }
        var history = Set<UUID>()
        for input in inputs where !input.folderName.isEmpty {
            let url = input.folderURL.appendingPathComponent(Self.historyName)
            if manager.fileExists(atPath: url.path) {
                history.formUnion(try JSONDecoder().decode([UUID].self, from: Data(contentsOf: url)))
            }
        }
        // 上次已合并但源文件删除失败时，禁止再次拼入同一份录音。
        guard history.isDisjoint(with: Set(inputs.map(\.id))) else { throw MergeError() }
        history.formUnion(inputs.dropLast().map(\.id))

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeError()
        }
        var cursor = CMTime.zero
        var segments: [TranscriptMirrorItem] = []
        var summaries: [String] = []
        var todos: [TodoItem] = []
        var hasTodos = false
        for input in inputs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: input.audioURL)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw MergeError() }
            let range = try await source.load(.timeRange)
            let seconds = range.duration.seconds
            guard seconds.isFinite, seconds > 0 else { throw MergeError() }
            try track.insertTimeRange(range, of: source, at: cursor)
            let offset = cursor.seconds
            for segment in input.segments {
                segments.append(TranscriptMirrorItem(
                    startTime: segment.startTime + offset, endTime: segment.endTime + offset,
                    speaker: segment.speaker, text: try Self.plaintext(segment.rawText)
                ))
            }
            if let raw = input.summary, !raw.isEmpty {
                summaries.append("## \(input.title)\n\n\(try Self.plaintext(raw))")
            }
            // 先加载所有待办；已有文件损坏时明确失败，不能把读失败当成无待办再删源目录。
            if !input.folderName.isEmpty, TodoDocument.exists(in: input.folderURL) {
                guard let document = TodoDocument.load(from: input.folderURL) else { throw MergeError() }
                hasTodos = true
                for var item in document.items {
                    if todos.contains(where: { $0.id == item.id }) { item.id = UUID().uuidString }
                    todos.append(item) // 保留提醒事项标识与写入状态，不删除或重新写入系统提醒事项。
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let audioName = "merged-\(UUID()).m4a"
        let audioURL = staging.appendingPathComponent(audioName)
        try await export(composition, to: audioURL, duration: cursor.seconds)
        let duration = try await AudioConverter.getDuration(of: audioURL)
        guard duration.isFinite, duration > 0, abs(duration - cursor.seconds) < 1 else { throw MergeError() }

        let mirrorKey = "merge-\(UUID())"
        let transcriptData = try JSONEncoder().encode(segments)
        guard let transcript = String(data: transcriptData, encoding: .utf8),
              await EntryMirrorStore.shared.writeNow(transcript, kind: .transcript, folderName: mirrorKey,
                                                    to: staging.appendingPathComponent(AudioRecording.transcriptFileName)) else {
            throw MergeError()
        }
        let summary = summaries.joined(separator: "\n\n---\n\n")
        if !summary.isEmpty {
            guard await EntryMirrorStore.shared.writeNow(summary, kind: .summary, folderName: mirrorKey,
                                                        to: staging.appendingPathComponent(AudioRecording.summaryFileName)) else {
                throw MergeError()
            }
        }
        if hasTodos { try TodoDocument(source: "summary", model: "", items: todos).save(to: staging) }
        try JSONEncoder().encode(Array(history)).write(to: staging.appendingPathComponent(Self.historyName), options: .atomic)
        let committed = CommittedMedia(audioName: audioName, duration: duration,
                                       transcriptionComplete: inputs.allSatisfy(\.transcriptionComplete))
        try JSONEncoder().encode(committed).write(to: staging.appendingPathComponent(Self.committedMediaName), options: .atomic)
        // 暂存目录只保留合并后的音频，避免磁盘恢复挑中旧音频。
        if !latest.folderName.isEmpty {
            try manager.removeItem(at: staging.appendingPathComponent(latest.audioURL.lastPathComponent))
        }
        let encryptedTexts = try segments.map { try EncryptionService.encrypt($0.text) }
        let encryptedSummary = summary.isEmpty ? nil : try EncryptionService.encrypt(summary)
        prepared = true
        return Prepared(stagingURL: staging, destinationURL: destination, audioName: audioName,
                        duration: duration, segments: segments, encryptedTexts: encryptedTexts,
                        encryptedSummary: encryptedSummary, hasTodos: hasTodos)
    }

    private static func plaintext(_ raw: String) throws -> String {
        guard !raw.isEmpty, Data(base64Encoded: raw) != nil else { return raw }
        return try EncryptionService.decrypt(raw)
    }

    private func export(_ composition: AVMutableComposition, to url: URL, duration: Double) async throws {
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw MergeError() }
        // 导出任务独占 session；外部仅调用线程安全的 cancelExport；错误经 LockedBox 交接。
        nonisolated(unsafe) let session = exporter
        let error = LockedBox<SentError?>(nil)
        let finished = await RacingWatchdog.race(
            name: "Recording merge export", timeout: FileSyncService.mergeExportTimeout(estimatedAudioDuration: duration),
            onTimeout: { session.cancelExport() }, onCancel: { session.cancelExport() }
        ) {
            do { try await session.export(to: url, as: .m4a) }
            catch let caught { error.value = SentError(caught) }
        }
        guard finished else { throw MergeError() }
        if let caught = error.value { throw caught.value }
        try Task.checkCancellation()
    }

    /// RENAME_SWAP 原子交换新旧完整条目；交换后的 staging 保留旧条目供数据库保存失败回滚。
    nonisolated static func swap(_ prepared: Prepared) throws {
        let result = prepared.stagingURL.path.withCString { source in
            prepared.destinationURL.path.withCString { destination in
                renamex_np(source, destination, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    nonisolated static func removeStaging(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { logger.error("合并暂存目录清理失败：\(error.localizedDescription, privacy: .public)") }
    }
}
