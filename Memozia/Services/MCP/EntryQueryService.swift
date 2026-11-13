import Foundation
import SwiftData
import CryptoKit
import MCP

/// 只读查询入口。SwiftData 模型始终留在 MainActor，出参仅含 Sendable 的 MCP.Value。
@MainActor
final class EntryQueryService {
    private let context: ModelContext
    private let decrypt: (String?) throws -> String
    private let checkAccess: (MCPClientGrant) -> Bool
    private let scrub: (String) -> PIIScrubMapping
    private let verifyDiskIdentity: Bool
    private let resolveFolder: (String) -> URL
    nonisolated static let maxResponseBytes = 512 * 1024

    init(context: ModelContext,
         decrypt: @escaping (String?) throws -> String = EncryptionService.decryptForExternalAccess,
         checkAccess: @escaping (MCPClientGrant) -> Bool = { MCPAccessStore.shared.isCurrent($0) },
         verifyDiskIdentity: Bool = true,
         resolveFolder: @escaping (String) -> URL = AudioRecording.resolveFolderURL(forFolderName:),
         scrub: @escaping (String) -> PIIScrubMapping = { PIIScrubService.scrub($0).mapping }) {
        self.context = context
        self.decrypt = decrypt
        self.checkAccess = checkAccess
        self.scrub = scrub
        self.verifyDiskIdentity = verifyDiskIdentity
        self.resolveFolder = resolveFolder
    }

    func call(_ name: String, arguments: [String: Value], grant: MCPClientGrant) async throws -> Value {
        try authorize(grant)
        let result: Value
        switch name {
        case "list_entries", "search_entries": result = try await list(arguments, grant: grant, search: name == "search_entries")
        case "get_entry": result = try content(arguments, grant: grant)
        case "get_transcript": result = try transcript(arguments, grant: grant)
        case "get_todos": result = try await todos(arguments, grant: grant)
        default: throw MCPQueryError.invalidArguments
        }
        try await validateResultEntries(result, grant: grant)
        try Task.checkCancellation()
        try authorize(grant) // await 期间撤销授权或隐藏条目后不得发出旧响应
        // 正文在截取字符页之前脱敏，避免用 limit=1 重组跨页的敏感信息。
        let safe = grant.redact && name != "get_entry" ? redact(result) : result
        guard try JSONEncoder().encode(safe).count <= Self.maxResponseBytes else { throw MCPQueryError.responseTooLarge }
        return safe
    }

    private func validateResultEntries(_ value: Value, grant: MCPClientGrant) async throws {
        func ids(_ value: Value) -> [String] {
            switch value {
            case .object(let object):
                return object.flatMap { key, value in
                    if key == "entry_id", case .string(let id) = value { return [id] }
                    return ids(value)
                }
            case .array(let array): return array.flatMap(ids)
            default: return []
            }
        }
        let identifiers = Set(ids(value))
        if verifyDiskIdentity {
            let targets = try identifiers.map { id -> (UUID, URL) in
                let item = try entry(["entry_id": .string(id)], grant: grant)
                return (item.id, resolveFolder(item.folder))
            }
            try await Task.detached(priority: .utility) {
                for (id, folder) in targets {
                    guard try EntryIdentityStore.read(from: folder) == id else { throw MCPQueryError.readFailed }
                }
            }.value
        }
        for id in identifiers { _ = try entry(["entry_id": .string(id)], grant: grant) }
    }

    private func authorize(_ grant: MCPClientGrant) throws {
        guard checkAccess(grant) else { throw MCPQueryError.unauthorized }
    }

    private enum Entry {
        case recording(AudioRecording)
        case note(QuickNote)
        var id: UUID { switch self { case .recording(let r): r.id; case .note(let n): n.id } }
        var folder: String { switch self { case .recording(let r): r.folderName; case .note(let n): n.folderName } }
        var date: Date { switch self { case .recording(let r): r.createdAt; case .note(let n): n.createdAt } }
        var hidden: Bool { switch self { case .recording(let r): r.isHidden; case .note(let n): n.isHidden } }
        var title: String { switch self { case .recording(let r): r.fileName; case .note(let n): n.title } }
        var kind: String { switch self { case .recording(let r): r.hasVideoSource ? "video" : "recording"; case .note: "note" } }
        var metadata: [String: Value] {
            ["entry_id": .string(id.uuidString.lowercased()), "type": .string(kind), "title": .string(title),
             "created_at": .string(ISO8601DateFormatter().string(from: date)),
             "uri": .string("memozia://entries/\(id.uuidString.lowercased())/summary")]
        }
    }

    private func entry(_ args: [String: Value], grant: MCPClientGrant) throws -> Entry {
        guard case .string(let text)? = args["entry_id"], let id = UUID(uuidString: text) else { throw MCPQueryError.invalidArguments }
        var recordings = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        recordings.fetchLimit = 2
        var notes = FetchDescriptor<QuickNote>(predicate: #Predicate { $0.id == id })
        notes.fetchLimit = 2
        let candidates = try context.fetch(recordings).map(Entry.recording) + context.fetch(notes).map(Entry.note)
        guard candidates.count <= 1 else { throw MCPQueryError.readFailed }
        guard let entry = candidates.first, !entry.folder.isEmpty,
              grant.permits(id: entry.id, createdAt: entry.date, hidden: entry.hidden) else { throw MCPQueryError.notFound }
        return entry
    }

    private struct Cursor: Codable {
        let fingerprint: String
        let position: String
    }

    private func fingerprint(_ name: String, args: [String: Value], grant: MCPClientGrant, revision: String = "") throws -> String {
        var args = args
        args.removeValue(forKey: "cursor")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let policy = [grant.id.uuidString, grant.createdAt.description, grant.notBefore?.description ?? "", String(grant.redact),
                      grant.entryIDs?.map(\.uuidString).sorted().joined(separator: ",") ?? "*"]
        let data = try encoder.encode(Value.object(args)) + Data((policy.joined(separator: "|") + name + revision).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func position(_ args: [String: Value], fingerprint: String) throws -> String? {
        guard let value = args["cursor"] else { return nil }
        guard case .string(let text) = value, text.utf8.count <= 2048,
              let data = Data(base64Encoded: text), let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              cursor.fingerprint == fingerprint else { throw MCPQueryError.invalidCursor }
        return cursor.position
    }

    private func cursor(_ position: String, fingerprint: String) throws -> Value {
        .string(try JSONEncoder().encode(Cursor(fingerprint: fingerprint, position: position)).base64EncodedString())
    }

    private func integer(_ args: [String: Value], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard case .int(let number) = value, range.contains(number) else { throw MCPQueryError.invalidArguments }
        return number
    }

    private func date(_ value: Value?) throws -> Date? {
        guard let value else { return nil }
        guard case .string(let text) = value else { throw MCPQueryError.invalidArguments }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else { throw MCPQueryError.invalidArguments }
        return date
    }

    private func list(_ args: [String: Value], grant: MCPClientGrant, search: Bool) async throws -> Value {
        let limit = try integer(args, "limit", default: 20, range: 1...50)
        let since = max(try date(args["since"]) ?? .distantPast, grant.notBefore ?? .distantPast)
        let until = try date(args["until"]) ?? .distantFuture
        guard since <= until else { throw MCPQueryError.invalidArguments }
        var kind: String?
        if let value = args["type"] {
            guard case .string(let string) = value, ["recording", "video", "note"].contains(string) else { throw MCPQueryError.invalidArguments }
            kind = string
        }
        var query = ""
        if search {
            guard case .string(let string)? = args["query"] else { throw MCPQueryError.invalidArguments }
            query = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty, query.count <= 200 else { throw MCPQueryError.invalidArguments }
        }
        let fingerprint = try fingerprint(search ? "search" : "list", args: args, grant: grant)
        var before = try position(args, fingerprint: fingerprint) ?? "~"
        guard before.utf8.count <= 80 else { throw MCPQueryError.invalidCursor }
        var matches: [Value] = []
        var scanned = 0
        var exhausted = false
        let deadline = ContinuousClock.now + .seconds(8)
        while matches.count < limit, scanned < 500, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try authorize(grant)
            var recordings = FetchDescriptor<AudioRecording>(predicate: #Predicate {
                !$0.isHidden && $0.folderName != "" && $0.folderName < before && $0.createdAt >= since && $0.createdAt <= until
            }, sortBy: [SortDescriptor(\.folderName, order: .reverse)])
            recordings.fetchLimit = 32
            var notes = FetchDescriptor<QuickNote>(predicate: #Predicate {
                !$0.isHidden && $0.folderName != "" && $0.folderName < before && $0.createdAt >= since && $0.createdAt <= until
            }, sortBy: [SortDescriptor(\.folderName, order: .reverse)])
            notes.fetchLimit = 32
            let batch = (try context.fetch(recordings).map(Entry.recording) + context.fetch(notes).map(Entry.note))
                .sorted { $0.folder > $1.folder }.prefix(32)
            guard !batch.isEmpty else { exhausted = true; break }
            for item in batch {
                before = item.folder
                scanned += 1
                guard grant.permits(id: item.id, createdAt: item.date, hidden: item.hidden), kind == nil || kind == item.kind else { continue }
                var row = item.metadata
                if search {
                    guard let match = try await match(item, query: query, grant: grant, deadline: deadline) else { continue }
                    row["match"] = match
                }
                matches.append(.object(row))
                if matches.count == limit { break }
            }
            await Task.yield()
        }
        // 授权过滤再次执行：批间 yield 时用户可能隐藏/删除条目。
        for row in matches {
            guard case .object(let object) = row else { continue }
            _ = try entry(object, grant: grant)
        }
        return .object(["entries": .array(matches), "next_cursor": exhausted ? .null : try cursor(before, fingerprint: fingerprint),
                        "scan_complete": .bool(exhausted), "order": .string("entry_folder_desc")])
    }

    private func match(_ item: Entry, query: String, grant: MCPClientGrant, deadline: ContinuousClock.Instant) async throws -> Value? {
        func hit(_ text: String, field: String, start: Double? = nil, end: Double? = nil) -> Value? {
            guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let a = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
            let b = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
            var value: [String: Value] = ["field": .string(field), "text": .string(String(text[a..<b]))]
            if let start { value["start_seconds"] = .double(start) }
            if let end { value["end_seconds"] = .double(end) }
            return .object(value)
        }
        if let match = hit(item.title, field: "title") { return match }
        switch item {
        case .recording(let r):
            for (field, value) in [("summary", r.summary), ("visual", r.visualSummary)] {
                if let match = hit(try decrypt(value), field: field) { return match }
            }
            for (index, segment) in r.segments.sorted(by: { $0.startTime < $1.startTime }).enumerated() {
                if index.isMultiple(of: 64) {
                    await Task.yield()
                    try Task.checkCancellation()
                    try authorize(grant)
                    guard ContinuousClock.now < deadline else { throw MCPQueryError.busy }
                }
                if let match = hit(try decrypt(segment.text), field: "transcript", start: segment.startTime, end: segment.endTime) { return match }
            }
        case .note(let n):
            for (field, value) in [("text", n.textContent), ("summary", n.summaryText), ("ocr", n.ocrText)] {
                if let match = hit(try decrypt(value), field: field) { return match }
            }
        }
        return nil
    }

    private func content(_ args: [String: Value], grant: MCPClientGrant) throws -> Value {
        let item = try entry(args, grant: grant)
        let field: String
        if let value = args["field"] {
            guard case .string(let string) = value else { throw MCPQueryError.invalidArguments }
            field = string
        } else { field = "summary" }
        let value: String?
        switch (item, field) {
        case (.recording(let r), "summary"): value = r.summary
        case (.recording(let r), "visual"): value = r.visualSummary
        case (.note(let n), "summary"): value = n.summaryText
        case (.note(let n), "text"): value = n.textContent
        case (.note(let n), "ocr"): value = n.ocrText
        default: throw MCPQueryError.invalidArguments
        }
        let plain = try decrypt(value)
        var result = item.metadata
        result["field"] = .string(field)
        result["text"] = .string(plain)
        if grant.redact, case .object(let safe) = redact(.object(result)) { result = safe }
        let text = result["text"]?.stringValue ?? ""
        let fingerprint = try fingerprint("content", args: args, grant: grant, revision: (value ?? "") + text)
        let offset = Int(try position(args, fingerprint: fingerprint) ?? "0")
        guard let offset, offset >= 0, offset <= text.count else { throw MCPQueryError.invalidCursor }
        let limit = try integer(args, "limit", default: 8000, range: 1...16000)
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        result["text"] = .string(String(text[start..<end]))
        result["available"] = .bool(value != nil && !text.isEmpty)
        result["next_cursor"] = end == text.endIndex ? .null : try cursor(String(offset + text[start..<end].count), fingerprint: fingerprint)
        return .object(result)
    }

    private func transcript(_ args: [String: Value], grant: MCPClientGrant) throws -> Value {
        let item = try entry(args, grant: grant)
        guard case .recording(let recording) = item else { throw MCPQueryError.invalidArguments }
        func seconds(_ key: String, fallback: Double) throws -> Double {
            guard let value = args[key] else { return fallback }
            let number: Double
            switch value { case .double(let d): number = d; case .int(let i): number = Double(i); default: throw MCPQueryError.invalidArguments }
            guard number.isFinite, number >= 0 else { throw MCPQueryError.invalidArguments }
            return number
        }
        let start = try seconds("start_seconds", fallback: 0)
        let end = try seconds("end_seconds", fallback: .greatestFiniteMagnitude)
        guard start <= end else { throw MCPQueryError.invalidArguments }
        let segments = recording.segments.filter { $0.endTime >= start && $0.startTime <= end }.sorted {
            $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
        }
        let revision = segments.map { $0.id.uuidString + $0.text }.joined()
        let fingerprint = try fingerprint("transcript", args: args, grant: grant, revision: revision)
        guard let offset = Int(try position(args, fingerprint: fingerprint) ?? "0"), offset >= 0, offset <= segments.count else { throw MCPQueryError.invalidCursor }
        let limit = try integer(args, "limit", default: 50, range: 1...100)
        let page = segments.dropFirst(offset).prefix(limit)
        let rows = try page.map { segment -> Value in
            var row: [String: Value] = ["start_seconds": .double(segment.startTime), "end_seconds": .double(segment.endTime), "text": .string(try decrypt(segment.text))]
            if let speaker = segment.speaker { row["speaker"] = .string(speaker) }
            return .object(row)
        }
        var result = item.metadata
        result["segments"] = .array(rows)
        result["status"] = .string(recording.transcriptionStatus.rawValue)
        result["next_cursor"] = offset + page.count < segments.count ? try cursor(String(offset + page.count), fingerprint: fingerprint) : .null
        return .object(result)
    }

    private func todos(_ args: [String: Value], grant: MCPClientGrant) async throws -> Value {
        let item = try entry(args, grant: grant)
        let url = resolveFolder(item.folder).appendingPathComponent(TodoDocument.fileName)
        let document: Value = try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return .object(["available": .bool(false), "items": .array([])]) }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maxResponseBytes else { throw MCPQueryError.responseTooLarge }
            let text = try EncryptionService.decryptForExternalAccess(String(contentsOf: url, encoding: .utf8))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(TodoDocument.self, from: Data(text.utf8))
            let items: [Value] = document.items.map { todo in
                var row: [String: Value] = ["todo_id": .string(todo.id), "title": .string(todo.title),
                                             "status": .string(todo.status.rawValue), "priority": .string(todo.priority.rawValue)]
                if let notes = todo.notes { row["text"] = .string(notes) }
                if let due = todo.dueDate { row["due_date"] = .string(ISO8601DateFormatter().string(from: due)) }
                return .object(row)
            }
            return .object(["available": .bool(true), "items": .array(items)])
        }.value
        _ = try entry(args, grant: grant)
        return .object(["entry_id": .string(item.id.uuidString.lowercased()), "todos": document])
    }

    /// 一次响应共用一份映射，只改用户内容值；结构键、ID、URI 与游标不参与替换。
    private func redact(_ value: Value) -> Value {
        let fields: Set<String> = ["title", "text", "speaker"]
        func collect(_ value: Value) -> [String] {
            switch value {
            case .object(let object): return object.flatMap { key, value in
                if fields.contains(key), case .string(let text) = value { return [text] }
                return collect(value)
            }
            case .array(let array): return array.flatMap(collect)
            default: return []
            }
        }
        let pairs = scrub(collect(value).joined(separator: "\n")).pairs.sorted { $0.original.count > $1.original.count }
        func walk(_ value: Value, key: String = "") -> Value {
            switch value {
            case .string(let text) where fields.contains(key):
                return .string(pairs.reduce(text) { $0.replacingOccurrences(of: $1.original, with: $1.token) })
            case .object(let object): return .object(object.reduce(into: [:]) { $0[$1.key] = walk($1.value, key: $1.key) })
            case .array(let array): return .array(array.map { walk($0) })
            default: return value
            }
        }
        return walk(value)
    }
}
