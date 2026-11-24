import Foundation
import Darwin
import os

/// Downloads, migration and deletion share one cancellable gate. The stable lock
/// files also coordinate with other processes and are never unlinked.
enum BuiltInModelStorage {
    static let gate = CancellableGate()
    private static let logger = Logger(subsystem: "app.memozia", category: "BuiltInModelStorage")

    static func prepare(
        destination: URL = BuiltInQwenModel.folder,
        legacy: URL? = BuiltInQwenModel.legacyFolder
    ) async throws {
        guard let legacy, destination.standardizedFileURL != legacy.standardizedFileURL,
              !BuiltInQwenModel.isReady(at: destination) else { return }
        try await gate.run {
            do {
                let fm = FileManager.default
                guard !BuiltInQwenModel.isReady(at: destination) else { return }
                let oldRoot = legacy.deletingLastPathComponent()
                guard fm.fileExists(atPath: oldRoot.path),
                      !(try payloads(in: oldRoot)).isEmpty else { return }
                let root = destination.deletingLastPathComponent()
                let locks = try lockRoots([root, oldRoot])
                defer { withExtendedLifetime(locks) {} }
                var migrated = false
                for source in try payloads(in: oldRoot) where !source.lastPathComponent.hasPrefix(".migrate-") {
                    try Task.checkCancellation()
                    let target = root.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                    // An existing destination wins. Keep the old copy rather than
                    // overwrite a newer installation or its resumable download.
                    guard !fm.fileExists(atPath: target.path) else { continue }
                    let staging = root.appendingPathComponent(".migrate-" + source.lastPathComponent, isDirectory: true)
                    if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                    // Publish only a complete copy, even across volumes. A failed
                    // or interrupted copy leaves the original available to retry.
                    try fm.copyItem(at: source, to: staging)
                    try Task.checkCancellation()
                    try fm.moveItem(at: staging, to: target)
                    try fm.removeItem(at: source)
                    migrated = true
                }
                if migrated { logger.info("内置模型目录迁移完成") }
            } catch {
                logger.error("内置模型目录迁移失败：\(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }

    static func remove(
        destination: URL = BuiltInQwenModel.folder,
        legacy: URL? = BuiltInQwenModel.legacyFolder
    ) async throws {
        try await gate.run {
            do {
                let roots = modelRoots(destination: destination, legacy: legacy)
                let locks = try lockRoots(roots)
                defer { withExtendedLifetime(locks) {} }
                for root in roots {
                    for payload in try payloads(in: root) {
                        try Task.checkCancellation()
                        try FileManager.default.removeItem(at: payload)
                    }
                }
                logger.info("内置模型文件及下载缓存已删除")
            } catch {
                logger.error("内置模型删除失败：\(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
    }

    static func hasFiles(
        destination: URL = BuiltInQwenModel.folder,
        legacy: URL? = BuiltInQwenModel.legacyFolder
    ) -> Bool {
        for root in modelRoots(destination: destination, legacy: legacy) {
            do {
                if !(try payloads(in: root)).isEmpty { return true }
            } catch {
                // Keep the delete action available; its throwing path reports
                // an inaccessible directory instead of claiming it is empty.
                return true
            }
        }
        return false
    }

    private static func modelRoots(destination: URL, legacy: URL?) -> [URL] {
        var roots = [destination.deletingLastPathComponent().standardizedFileURL]
        if let root = legacy?.deletingLastPathComponent().standardizedFileURL,
           root != roots[0], FileManager.default.fileExists(atPath: root.path) {
            roots.append(root)
        }
        return roots
    }

    private static func lockRoots(_ roots: [URL]) throws -> [BuiltInModelFileLock] {
        try roots.sorted { $0.path < $1.path }.map { try BuiltInModelFileLock(root: $0) }
    }

    private static func payloads(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            var name = $0.lastPathComponent
            if name.hasPrefix(".migrate-") { name.removeFirst(".migrate-".count) }
            if name.hasPrefix("."), name.hasSuffix(".download") {
                name = String(name.dropFirst().dropLast(".download".count))
            }
            return name.count == 40 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

/// Immutable descriptor ownership is Sendable. Readers retain a shared lock for
/// the entire loaded-model lifetime; filesystem mutations require an exclusive lock.
final class BuiltInModelFileLock: Sendable {
    private let descriptor: Int32

    init(root: URL, shared: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".download.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw BuiltInModelError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
