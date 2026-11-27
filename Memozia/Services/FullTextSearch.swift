import Foundation
import Observation
import SwiftData

/// 查询上下文与解密文档留在索引内，调用方只接收命中摘要。
enum FullTextSearch {
    private struct Field: Sendable {
        let value: String
        let seconds: Double?
        var isSummary = false
    }
    private struct Entry: Sendable { let title: String; let fields: [Field] }
    struct Hit: Sendable { let snippet: String; let seconds: Double? }
    struct Result: Sendable { var hits: [String: Hit] = [:]; var unreadable = 0 }

    private struct Document {
        var fields: [Field]
        var unreadable = 0

        func hit(_ query: String) throws -> Hit? {
            var first: Hit?
            for field in fields {
                try Task.checkCancellation()
                if first != nil, field.seconds == nil { continue }
                guard let hit = FullTextSearch.match(query, in: field.value, seconds: field.seconds) else { continue }
                if hit.seconds != nil { return hit }
                first = hit
            }
            return first
        }
    }

    private static func prepare(_ entry: Entry, todoURL: URL) throws -> Document {
        var document = Document(fields: [Field(value: entry.title, seconds: nil)])
        for field in entry.fields {
            try Task.checkCancellation()
            do {
                let plain = try EncryptionService.decryptForExternalAccess(field.value)
                document.fields.append(Field(value: field.isSummary ? SummarySources.removingSeekLinks(from: plain) : plain,
                                             seconds: field.seconds))
            } catch { document.unreadable += 1 }
        }
        if FileManager.default.fileExists(atPath: todoURL.path) {
            do {
                let metadata = try todoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                      let size = metadata.fileSize, size <= 4 * 1024 * 1024 else { throw LLMError.parseError }
                let plain = try EncryptionService.decryptForExternalAccess(String(contentsOf: todoURL, encoding: .utf8))
                let json = try JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any]
                guard let items = json?["items"] as? [[String: Any]] else { throw LLMError.parseError }
                for item in items {
                    let text = [item["title"] as? String, item["notes"] as? String].compactMap { $0 }.joined(separator: "\n")
                    document.fields.append(Field(value: text, seconds: nil))
                }
            } catch { document.unreadable += 1 }
        }
        return document
    }

    /// 每个列表独立的内存索引。模型及其关系只在后台上下文访问，缓存按内容和待办文件版本失效。
    actor Index {
        private struct Version: Equatable {
            let id: UUID
            let transcriptDate: Date?
            let values: [String?]
            let todoDate: Date?
            let todoSize: Int?
        }
        private final class Cached {
            let version: Version
            let document: Document
            init(_ version: Version, _ document: Document) { self.version = version; self.document = document }
        }
        private let cache = NSCache<NSString, Cached>()
        init() { cache.totalCostLimit = 24 * 1024 * 1024 }

        func search(_ query: String, in container: ModelContainer, includeHidden: Bool) throws -> Result {
            let context = ModelContext(container)
            var result = Result()
            func visit(_ id: UUID, _ folder: String, date: Date?, values: [String?], entry: () -> Entry) throws {
                try Task.checkCancellation()
                let url = AudioRecording.resolveFolderURL(forFolderName: folder).appendingPathComponent(TodoDocument.fileName)
                let file = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let version = Version(id: id, transcriptDate: date, values: values, todoDate: file?.contentModificationDate, todoSize: file?.fileSize)
                let doc: Document
                if let saved = cache.object(forKey: folder as NSString), saved.version == version {
                    doc = saved.document
                } else {
                    doc = try FullTextSearch.prepare(entry(), todoURL: url)
                    if doc.unreadable == 0 {
                        let cost = doc.fields.reduce(0) { $0 + $1.value.utf8.count + 48 } + values.compactMap { $0?.utf8.count }.reduce(0, +)
                        cache.setObject(Cached(version, doc), forKey: folder as NSString, cost: cost)
                    }
                }
                result.hits[folder] = try doc.hit(query)
                result.unreadable += doc.unreadable
            }
            var recordings = FetchDescriptor<AudioRecording>()
            recordings.includePendingChanges = false
            for r in try context.fetch(recordings, batchSize: 64) {
                try Task.checkCancellation()
                guard includeHidden || !r.isHidden else { continue }
                try visit(r.id, r.folderName, date: r.transcriptModifiedAt, values: [r.fileName, r.summary, r.visualSummary]) {
                    var fields = r.segments.sorted { $0.startTime < $1.startTime }.map { Field(value: $0.text, seconds: $0.startTime) }
                    if let text = r.summary { fields.append(Field(value: text, seconds: nil, isSummary: true)) }
                    if let text = r.visualSummary { fields.append(Field(value: text, seconds: nil)) }
                    return Entry(title: r.fileName, fields: fields)
                }
            }
            var notes = FetchDescriptor<QuickNote>()
            notes.includePendingChanges = false
            for n in try context.fetch(notes, batchSize: 64) {
                try Task.checkCancellation()
                guard includeHidden || !n.isHidden else { continue }
                try visit(n.id, n.folderName, date: nil, values: [n.title, n.textContent, n.ocrText, n.summaryText]) {
                    var fields = [n.textContent, n.ocrText].compactMap { $0 }.map { Field(value: $0, seconds: nil) }
                    if let text = n.summaryText { fields.append(Field(value: text, seconds: nil, isSummary: true)) }
                    return Entry(title: n.title, fields: fields)
                }
            }
            return result
        }

        func invalidateTodo(folder: String?) {
            if let folder { cache.removeObject(forKey: folder as NSString) }
            else { cache.removeAllObjects() }
        }
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
