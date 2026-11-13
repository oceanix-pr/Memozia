import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

/// Versioned, password-protected directory archive. Device keys and API keys are never exported.
/// Archive chunks are encrypted. Restored media uses its original representation in private staging.
enum PortableBackup {
    static let chunkSize = 1_048_576
    static let textLimit = 32 * chunkSize
    static let rounds: UInt32 = 600_000
    static let maximumFileBytes = 1_000_000 * chunkSize
    private static let textNames: Set<String> = ["transcript.json", "summary.md", "visual.md", "source.txt", "ocr.txt", "todos.json"]
    private static let extensions: Set<String> = ["json", "txt", "md", "m4a", "wav", "mp3", "mp4", "mov", "aac", "caf", "flac", "ogg", "png", "jpg", "jpeg", "heic", "webp", "vtt", "srt"]

    enum Failure: LocalizedError {
        case invalid, changed, limit, password, mirror
        var errorDescription: String? {
            switch self {
            case .invalid: String(localized: "备份格式无效、内容损坏或包含不安全路径。")
            case .changed: String(localized: "备份期间数据发生变化，请停止录音和处理任务后重试。")
            case .limit: String(localized: "备份超过安全处理上限，未完成的目录不会作为有效备份发布。")
            case .password: String(localized: "口令至少需要 12 个字符；恢复时请使用创建备份时的口令。")
            case .mirror: String(localized: "文件尚未安全落盘，备份或恢复已停止。原有数据未被覆盖。")
            }
        }
    }
    struct Header: Codable { let version: Int; let salt: Data; let iterations: UInt32 }
    struct ArchivedFile: Codable, Sendable {
        let path: String
        let chunks: [String]
        let bytes: Int
        let encryptedText: Bool
    }
    struct Manifest: Codable, Sendable { let version: Int; let created: Date; let files: [ArchivedFile]; let skipped: Int }
    struct Report: Sendable { let url: URL; let files: Int; let skipped: Int }
    private struct Stamp: Equatable { let path: String; let size: Int; let modified: Date }

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 12, password.utf8.count <= 4096, salt.count == 16 else { throw Failure.password }
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                    saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, 32)
            }
        }
        guard status == kCCSuccess else { throw Failure.invalid }
        return SymmetricKey(data: output)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (2...8).contains(parts.count), path.utf8.count < 2048,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains(":") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return false }
        let entryIndex = parts[0].range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil ? 1 : 0
        guard parts.count > entryIndex + 1 else { return false }
        return parts[entryIndex].range(of: #"^\d{12}(\d{2})?(-[1-9]\d*)?$"#, options: .regularExpression) != nil
    }

    private static func shouldEncryptText(_ path: String) -> Bool {
        textNames.contains(URL(fileURLWithPath: path).lastPathComponent) || path.contains("/" + SummaryHistory.directoryName + "/")
    }

    private static func regularData(at url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximum else { throw Failure.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw Failure.limit }
        return data
    }

    private static func inventory(_ root: URL) throws -> ([Stamp], Int) {
        let fm = FileManager.default
        var files: [Stamp] = []
        var skipped = 0
        var enumerationFailed = false
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.invalid }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true else { throw Failure.invalid }
            let itemPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else { throw Failure.invalid }
            let relative = String(itemPath.dropFirst(rootPath.count + 1))
            if values.isDirectory == true {
                let parts = relative.split(separator: "/")
                // Never traverse databases, model resources or other unrelated root folders.
                if parts.count == 1 && relative.range(of: #"^(\d{4}-\d{2}|\d{12}(\d{2})?(-[1-9]\d*)?)$"#, options: .regularExpression) == nil {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, isSafeRelativePath(relative),
                  extensions.contains(url.pathExtension.lowercased()) else {
                skipped += 1
                continue
            }
            guard let size = values.fileSize, let modified = values.contentModificationDate else { throw Failure.invalid }
            files.append(Stamp(path: relative, size: size, modified: modified))
            guard files.count <= 100_000 else { throw Failure.limit }
        }
        guard !enumerationFailed else { throw Failure.invalid }
        return (files.sorted { $0.path < $1.path }, skipped)
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
    }

    private static func requireSeparate(_ parent: URL, from root: URL) throws {
        let p = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let r = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard p != r, !p.hasPrefix(r + "/") else { throw Failure.invalid }
    }

    static func export(root: URL, to parent: URL, password: String) async throws -> Report {
        try requireSeparate(parent, from: root)
        let flush = await EntryMirrorStore.shared.flush()
        guard flush.isComplete else { throw Failure.mirror }
        let (before, skipped) = try inventory(root)
        guard !before.isEmpty else { throw Failure.invalid }
        var salt = Data(count: 16)
        let randomStatus = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw Failure.invalid }
        let key = try deriveKey(password: password, salt: salt)
        let id = UUID().uuidString
        let staging = parent.appendingPathComponent(".Memozia-backup-" + id, isDirectory: true)
        let final = parent.appendingPathComponent("Memozia-" + id + ".memoziabackup", isDirectory: true)
        try makePrivateDirectory(staging)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        var archived: [ArchivedFile] = []
        for file in before {
            try Task.checkCancellation()
            let source = root.appendingPathComponent(file.path)
            let encryptedText = shouldEncryptText(file.path)
            var chunks: [String] = []
            var bytes = 0
            func store(_ data: Data) throws {
                try Task.checkCancellation()
                guard chunks.count < 1_000_000, data.count <= maximumFileBytes - bytes else { throw Failure.limit }
                let name = UUID().uuidString + ".bin"
                let sealed = try AES.GCM.seal(data, using: key, authenticating: Data("\(file.path)#\(chunks.count)".utf8))
                guard let combined = sealed.combined else { throw Failure.invalid }
                try combined.write(to: staging.appendingPathComponent(name), options: .atomic)
                chunks.append(name); bytes += data.count
            }
            if encryptedText {
                let raw = try regularData(at: source, maximum: textLimit)
                guard let text = String(data: raw, encoding: .utf8) else { throw Failure.invalid }
                let plain: String
                if let combined = Data(base64Encoded: text), combined.count >= 28 {
                    plain = try EncryptionService.decrypt(text)
                } else { plain = text }
                let data = Data(plain.utf8)
                guard data.count <= textLimit else { throw Failure.limit }
                for offset in stride(from: 0, to: data.count, by: chunkSize) { try store(data.subdata(in: offset..<min(offset + chunkSize, data.count))) }
            } else {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                while true {
                    var data = Data()
                    while data.count < chunkSize, let next = try handle.read(upToCount: chunkSize - data.count), !next.isEmpty {
                        try Task.checkCancellation()
                        data.append(next)
                    }
                    if data.isEmpty { break }
                    try store(data)
                }
            }
            archived.append(ArchivedFile(path: file.path, chunks: chunks, bytes: bytes, encryptedText: encryptedText))
        }
        let (after, _) = try inventory(root)
        guard before == after else { throw Failure.changed }
        let manifest = Manifest(version: 1, created: Date(), files: archived, skipped: skipped)
        let manifestBytes = try JSONEncoder().encode(manifest)
        guard manifestBytes.count <= textLimit - 28 else { throw Failure.limit }
        let sealed = try AES.GCM.seal(manifestBytes, using: key, authenticating: Data("Memozia-backup-v1".utf8))
        guard let combined = sealed.combined else { throw Failure.invalid }
        try combined.write(to: staging.appendingPathComponent("manifest.bin"), options: .atomic)
        try JSONEncoder().encode(Header(version: 1, salt: salt, iterations: rounds)).write(to: staging.appendingPathComponent("header.json"), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: final)
        published = true
        return Report(url: final, files: archived.count, skipped: skipped)
    }

    static func restore(archive: URL, to parent: URL, password: String, activeRoot: URL) async throws -> Report {
        try requireSeparate(parent, from: activeRoot)
        let header = try JSONDecoder().decode(Header.self, from: regularData(at: archive.appendingPathComponent("header.json"), maximum: 4096))
        guard header.version == 1, header.iterations == rounds else { throw Failure.invalid }
        let key = try deriveKey(password: password, salt: header.salt)
        let manifestData = try regularData(at: archive.appendingPathComponent("manifest.bin"), maximum: textLimit)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: manifestData), using: key, authenticating: Data("Memozia-backup-v1".utf8))
        let manifest = try JSONDecoder().decode(Manifest.self, from: plain)
        guard manifest.version == 1, !manifest.files.isEmpty, manifest.files.count <= 100_000 else { throw Failure.invalid }
        var paths = Set<String>()
        var chunkNames = Set<String>()
        // Preflight every path and chunk before any restored file is created.
        for file in manifest.files {
            guard isSafeRelativePath(file.path), paths.insert(file.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  extensions.contains(URL(fileURLWithPath: file.path).pathExtension.lowercased()),
                  file.encryptedText == shouldEncryptText(file.path), (0...maximumFileBytes).contains(file.bytes),
                  file.chunks.count <= 1_000_000, !file.encryptedText || file.bytes <= textLimit else { throw Failure.invalid }
            guard file.chunks.count == (file.bytes + chunkSize - 1) / chunkSize else { throw Failure.invalid }
            for name in file.chunks {
                guard name.hasSuffix(".bin"), UUID(uuidString: String(name.dropLast(4))) != nil, chunkNames.insert(name).inserted else { throw Failure.invalid }
            }
        }
        let id = UUID().uuidString
        let staging = parent.appendingPathComponent(".Memozia-restore-" + id, isDirectory: true)
        let final = parent.appendingPathComponent("Memozia-restored-" + id, isDirectory: true)
        try makePrivateDirectory(staging)
        // This isolated store cannot coalesce writes with the live library's same-named entries.
        let mirrors = EntryMirrorStore()
        for file in manifest.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var textData = Data()
            var written = 0
            var handle: FileHandle?
            if !file.encryptedText {
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.invalid }
                handle = try FileHandle(forWritingTo: target)
            }
            defer { try? handle?.close() }
            for (index, name) in file.chunks.enumerated() {
                try Task.checkCancellation()
                let sealed = try regularData(at: archive.appendingPathComponent(name), maximum: chunkSize + 28)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Data("\(file.path)#\(index)".utf8))
                guard data.count == min(chunkSize, file.bytes - written) else { throw Failure.invalid }
                written += data.count
                if file.encryptedText { textData.append(data) } else { try handle?.write(contentsOf: data) }
            }
            guard written == file.bytes else { throw Failure.invalid }
            try handle?.synchronize()
            if file.encryptedText {
                guard var text = String(data: textData, encoding: .utf8) else { throw Failure.invalid }
                let name = target.lastPathComponent
                if name == "todos.json" { text = try removingExternalBindings(from: text) }
                let kind: EntryMirrorStore.Kind? = name == "transcript.json" ? .transcript : name == "summary.md" ? .summary : name == "visual.md" ? .visual : nil
                if let kind {
                    guard await mirrors.writeNow(text, kind: kind, folderName: target.deletingLastPathComponent().lastPathComponent, to: target) else { throw Failure.mirror }
                } else { try EncryptionService.encryptAndWrite(text, to: target) }
            }
        }
        let flushResult = await mirrors.flush()
        guard flushResult.isComplete else { throw Failure.mirror }
        try Task.checkCancellation()
        // Never merge into or replace a live library. Failed staging stays private (0700);
        // restored text uses this device's encryption; media keeps its original representation.
        try FileManager.default.moveItem(at: staging, to: final)
        return Report(url: final, files: manifest.files.count, skipped: manifest.skipped)
    }

    static func removingExternalBindings(from text: String) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = try decoder.decode(TodoDocument.self, from: Data(text.utf8))
        for index in document.items.indices {
            document.items[index].reminderIdentifier = nil
            document.items[index].targetListID = nil
            document.items[index].status = .pending
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }
}
