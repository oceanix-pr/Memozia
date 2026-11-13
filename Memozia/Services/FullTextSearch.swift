import Foundation
import Observation

/// Only encrypted values and scalar metadata cross the actor boundary.
enum FullTextSearch {
    struct Field: Sendable { let value: String; let seconds: Double? }
    struct Entry: Sendable { let folder: String; let title: String; let fields: [Field] }
    struct Hit: Sendable { let snippet: String; let seconds: Double? }
    struct Result: Sendable { var hits: [String: Hit] = [:]; var unreadable = 0 }

    static func find(_ query: String, in entries: [Entry]) throws -> Result {
        var result = Result()
        guard !query.isEmpty else { return result }
        for entry in entries {
            try Task.checkCancellation()
            var hit = match(query, in: entry.title, seconds: nil)
            for field in entry.fields {
                try Task.checkCancellation()
                do {
                    let plain = try EncryptionService.decryptForExternalAccess(field.value)
                    if let found = match(query, in: plain, seconds: field.seconds), hit == nil || (hit?.seconds == nil && found.seconds != nil) {
                        hit = found
                    }
                } catch { result.unreadable += 1 }
            }
            let todoURL = AudioRecording.resolveFolderURL(forFolderName: entry.folder).appendingPathComponent(TodoDocument.fileName)
            if FileManager.default.fileExists(atPath: todoURL.path) {
                do {
                    let metadata = try todoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                          let size = metadata.fileSize, size <= 4 * 1024 * 1024 else { throw LLMError.parseError }
                    let raw = try String(contentsOf: todoURL, encoding: .utf8)
                    let plain = try EncryptionService.decryptForExternalAccess(raw)
                    let document = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any]
                    guard let items = document?["items"] as? [[String: Any]] else { throw LLMError.parseError }
                    for item in items where hit == nil {
                        let text = [item["title"] as? String, item["notes"] as? String].compactMap { $0 }.joined(separator: "\n")
                        hit = match(query, in: text, seconds: nil)
                    }
                } catch { result.unreadable += 1 }
            }
            if let hit { result.hits[entry.folder] = hit }
        }
        return result
    }

    static func match(_ query: String, in text: String, seconds: Double?) -> Hit? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 65, limitedBy: text.endIndex) ?? text.endIndex
        return Hit(snippet: String(text[start..<end]).replacingOccurrences(of: "\n", with: " "), seconds: seconds)
    }
}

@MainActor @Observable
final class SourceNavigation {
    static let shared = SourceNavigation()
    struct Request: Equatable { let recordingID: UUID; let seconds: Double; let nonce = UUID() }
    var request: Request?

    static func seconds(from url: URL) -> Double? {
        guard url.scheme?.lowercased() == "memozia", url.host?.lowercased() == "seek",
              let seconds = Double(url.lastPathComponent), seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}
