import Foundation
import CryptoKit
import Darwin
import os

enum BuiltInModelDownloader {
    private static let gate = CancellableGate()
    private static let logger = Logger(subsystem: "app.memozia", category: "BuiltInModel")

    static func verify(_ file: BuiltInQwenModel.File, at url: URL) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    static func verifyModel(at folder: URL) throws {
        for file in BuiltInQwenModel.files {
            guard try verify(file, at: folder.appendingPathComponent(file.name)) else {
                let ready = folder.appendingPathComponent(".ready")
                if FileManager.default.fileExists(atPath: ready.path) {
                    try FileManager.default.removeItem(at: ready)
                }
                throw BuiltInModelError.invalidDownload
            }
        }
    }

    /// Immutable revision + cross-process lock + atomic directory install prevent
    /// the app and a recovering worker from reading partially downloaded weights.
    static func download(
        source: WhisperModelSource,
        destination: URL = BuiltInQwenModel.folder,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await gate.run {
            let fm = FileManager.default
            let root = destination.deletingLastPathComponent()
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let lockFD = open(root.appendingPathComponent(".download.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockFD >= 0 else { throw BuiltInModelError.busy }
            defer { close(lockFD) }
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw BuiltInModelError.busy }
            defer { flock(lockFD, LOCK_UN) }
            if BuiltInQwenModel.isReady(at: destination) {
                try verifyModel(at: destination)
                onProgress(1)
                return
            }
            let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            guard (capacity ?? 0) >= 4_000_000_000 else { throw BuiltInModelError.insufficientSpace }
            let stage = root.appendingPathComponent(".\(BuiltInQwenModel.revision).download", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            var completed: Int64 = 0
            for file in BuiltInQwenModel.files {
                try Task.checkCancellation()
                let output = stage.appendingPathComponent(file.name)
                let done = completed
                if try !verify(file, at: output) {
                    let resume = stage.appendingPathComponent(file.name + "." + source.rawValue + ".resume")
                    let url = BuiltInQwenModel.downloadURL(for: file, source: source)
                    try EndpointPolicy.validate(url.absoluteString, allowInsecureLAN: false)
                    let progress = ModelFileDownloadProgress { bytes in
                        onProgress(Double(done + min(bytes, file.size)) / Double(BuiltInQwenModel.totalBytes))
                    }
                    do {
                        let result: (URL, URLResponse)
                        if let saved = try? Data(contentsOf: resume) {
                            result = try await session.download(resumeFrom: saved, delegate: progress)
                        } else {
                            result = try await session.download(for: URLRequest(url: url), delegate: progress)
                        }
                        defer { try? fm.removeItem(at: result.0) }
                        guard let response = result.1 as? HTTPURLResponse,
                              [200, 206].contains(response.statusCode),
                              try verify(file, at: result.0) else {
                            // A stale resume record must not make every retry fail identically.
                            if fm.fileExists(atPath: resume.path) { try fm.removeItem(at: resume) }
                            throw BuiltInModelError.invalidDownload
                        }
                        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                        try fm.moveItem(at: result.0, to: output)
                        if fm.fileExists(atPath: resume.path) { try fm.removeItem(at: resume) }
                    } catch {
                        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                            try data.write(to: resume, options: .atomic)
                        } else if !Task.isCancelled, fm.fileExists(atPath: resume.path) {
                            try fm.removeItem(at: resume)
                        }
                        if Task.isCancelled { throw CancellationError() }
                        throw error
                    }
                }
                completed += file.size
                onProgress(Double(completed) / Double(BuiltInQwenModel.totalBytes))
            }
            try Task.checkCancellation()
            try Data(BuiltInQwenModel.revision.utf8).write(to: stage.appendingPathComponent(".ready"), options: .atomic)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: stage)
            } else {
                try fm.moveItem(at: stage, to: destination)
            }
            logger.info("内置模型下载与校验完成")
        }
    }
}

/// URLSession owns this delegate for the download lifetime. Its only stored value
/// is a Sendable callback. The progress throttle is protected by an unfair lock.
private final class ModelFileDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    private let lastReport = OSAllocatedUnfairLock(initialState: Date.distantPast)
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let shouldReport = lastReport.withLock { last in
            let now = Date()
            guard now.timeIntervalSince(last) >= 0.1 else { return false }
            last = now
            return true
        }
        if shouldReport { report(totalBytesWritten) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
