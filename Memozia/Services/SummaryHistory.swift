import Foundation

/// Immutable encrypted revisions avoid read/modify/write races between processes.
enum SummaryHistory {
    struct Revision: Codable, Identifiable, Sendable {
        let id: UUID
        let date: Date
        let text: String
    }
    static let directoryName = "summary-history"

    static func preserve(_ encryptedText: String?, in folder: URL) throws {
        guard let encryptedText, !encryptedText.isEmpty else { return }
        let text = try EncryptionService.decryptForExternalAccess(encryptedText)
        let revision = Revision(id: UUID(), date: Date(), text: text)
        let data = try JSONEncoder().encode(revision)
        let directory = folder.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try EncryptionService.encryptAndWrite(String(decoding: data, as: UTF8.self),
            to: directory.appendingPathComponent(revision.id.uuidString + ".json"))
    }

    static func load(in folder: URL) throws -> [Revision] {
        let directory = folder.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                try Task.checkCancellation()
                let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let size = metadata.fileSize, size <= 4 * 1024 * 1024 else { throw LLMError.parseError }
                let encrypted = try String(contentsOf: url, encoding: .utf8)
                let plain = try EncryptionService.decryptForExternalAccess(encrypted)
                return try JSONDecoder().decode(Revision.self, from: Data(plain.utf8))
            }.sorted { $0.date > $1.date }
    }
}
