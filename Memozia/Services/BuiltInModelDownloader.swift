import Foundation
import CryptoKit
import os

enum BuiltInModelDownloader {
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
        try await BuiltInModelStorage.prepare(destination: destination)
        try await BuiltInModelStorage.gate.run {
            let fm = FileManager.default
            let root = destination.deletingLastPathComponent()
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let lock = try BuiltInModelFileLock(root: root)
            defer { withExtendedLifetime(lock) {} }
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
            var completed: Int64 = 0
            for file in BuiltInQwenModel.files {
                try Task.checkCancellation()
                let output = stage.appendingPathComponent(file.name)
                let done = completed
                if try !verify(file, at: output) {
                    let resume = stage.appendingPathComponent(file.name + "." + source.rawValue + ".resume")
                    let url = BuiltInQwenModel.downloadURL(for: file, source: source)
                    try EndpointPolicy.validate(url.absoluteString, allowInsecureLAN: false)
                    let temporaryFile = stage.appendingPathComponent(".\(UUID().uuidString).partial")
                    defer { try? fm.removeItem(at: temporaryFile) }
                    do {
                        let response = try await ModelFileDownload.download(
                            from: url, resumeData: try? Data(contentsOf: resume),
                            to: temporaryFile, configuration: configuration
                        ) { bytes in
                            onProgress(Double(done + min(bytes, file.size)) / Double(BuiltInQwenModel.totalBytes))
                        }
                        try Task.checkCancellation()
                        guard let response = response as? HTTPURLResponse,
                              [200, 206].contains(response.statusCode),
                              try verify(file, at: temporaryFile) else {
                            // A stale resume record must not make every retry fail identically.
                            if fm.fileExists(atPath: resume.path) { try fm.removeItem(at: resume) }
                            throw BuiltInModelError.invalidDownload
                        }
                        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                        try fm.moveItem(at: temporaryFile, to: output)
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

/// Delegate-based download tasks deliver incremental progress; the async
/// URLSession.download conveniences do not deliver download delegate callbacks.
/// URLSession owns the delegate until completion. All mutable callback state is
/// protected by the lock; the delegate never retains the session or its task.
final class ModelFileDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URLResponse, any Error>?
        var outcome: Result<URLResponse, any Error>?
        var transferCompleted = false
        var awaitingResumeData = false
        var resumeData: Data?
        var settled = false
        var lastReport = Date.distantPast
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let destination: URL
    private let report: @Sendable (Int64) -> Void

    private init(destination: URL, report: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.report = report
    }

    static func download(
        from url: URL,
        resumeData: Data? = nil,
        to destination: URL,
        configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URLResponse {
        try Task.checkCancellation()
        let delegate = ModelFileDownload(destination: destination, report: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = if let resumeData {
            session.downloadTask(withResumeData: resumeData)
        } else {
            session.downloadTask(with: url)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.state.withLock { $0.continuation = continuation }
                // Cancellation can finish before the continuation is registered.
                delegate.deliverIfComplete()
                task.resume()
            }
        } onCancel: {
            delegate.cancel(task)
        }
    }

    private func cancel(_ task: URLSessionDownloadTask) {
        let shouldCancel = state.withLock { state in
            guard !state.settled else { return false }
            state.awaitingResumeData = true
            return true
        }
        guard shouldCancel else { return }
        task.cancel(byProducingResumeData: { data in
            self.state.withLock {
                $0.resumeData = data
                $0.awaitingResumeData = false
            }
            self.deliverIfComplete()
        })
    }

    private func deliverIfComplete() {
        let delivery = state.withLock { state -> (
            CheckedContinuation<URLResponse, any Error>, Result<URLResponse, any Error>
        )? in
            guard state.transferCompleted, !state.awaitingResumeData, !state.settled,
                  let continuation = state.continuation, var outcome = state.outcome else { return nil }
            state.settled = true
            state.continuation = nil
            state.outcome = nil
            if case .failure(let error) = outcome, let resumeData = state.resumeData {
                let original = error as NSError
                var info = original.userInfo
                info[NSURLSessionDownloadTaskResumeData] = resumeData
                outcome = .failure(NSError(domain: original.domain, code: original.code, userInfo: info))
            }
            return (continuation, outcome)
        }
        if let (continuation, outcome) = delivery { continuation.resume(with: outcome) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let shouldReport = state.withLock { state in
            let now = Date()
            guard now.timeIntervalSince(state.lastReport) >= 0.1 else { return false }
            state.lastReport = now
            return true
        }
        if shouldReport { report(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        report(fileOffset)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw BuiltInModelError.invalidDownload }
            // URLSession removes its temporary file when this callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock { $0.outcome = .success(response) }
        } catch {
            state.withLock { $0.outcome = .failure(error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        state.withLock { state in
            if let error { state.outcome = .failure(error) }
            else if state.outcome == nil { state.outcome = .failure(BuiltInModelError.invalidDownload) }
            state.transferCompleted = true
        }
        // Keep ownership until both the transfer and resume-data callback finish.
        deliverIfComplete()
    }
}
