import Foundation
import SwiftData

/// 文件中的 entry_id 是对外引用的身份；数据库重建时恢复到模型的 id。
/// 元数据读改写在进程内串行，跨进程仍受 DatabaseOwnershipLock 保护。
enum EntryIdentityStore {
    private static let lock = NSLock()

    static func read(from folder: URL) throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return try identity(in: metadata(in: folder))
    }

    @discardableResult
    static func write(_ fields: [String: Any], id: UUID, to folder: URL, fillMissingOnly: Bool = false) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        var json = try metadata(in: folder)
        let canonicalID = try identity(in: json) ?? id
        json.merge(fields) { old, new in fillMissingOnly ? old : new }
        json["entry_id"] = canonicalID.uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        return canonicalID
    }

    private static func metadata(in folder: URL) throws -> [String: Any] {
        let url = folder.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let json = object as? [String: Any] else { throw IdentityError.invalidMetadata }
        return json
    }

    private static func identity(in json: [String: Any]) throws -> UUID? {
        guard let value = json["entry_id"] else { return nil }
        guard let value = value as? String, let id = UUID(uuidString: value) else {
            throw IdentityError.invalidMetadata
        }
        return id
    }

    /// 仅在用户启用 MCP、数据库持久化且启动对账完成后补齐旧条目。
    /// 磁盘 I/O 只携带 Sendable 快照；不把 ModelContext / @Model 带出 MainActor。
    @MainActor
    static func prepare(context: ModelContext, resolveFolder: (String) -> URL = AudioRecording.resolveFolderURL(forFolderName:)) async throws {
        let recordings = try context.fetch(FetchDescriptor<AudioRecording>())
        let notes = try context.fetch(FetchDescriptor<QuickNote>())
        struct Target: Sendable {
            let id: UUID
            let folder: URL
            let title: String
            let hidden: Bool
            let kind: String
            let hasVideoSource: Bool
        }
        let targets = recordings.filter { !$0.folderName.isEmpty }.map {
            Target(id: $0.id, folder: resolveFolder($0.folderName), title: $0.fileName, hidden: $0.isHidden, kind: "recording", hasVideoSource: $0.hasVideoSource)
        } + notes.filter { !$0.folderName.isEmpty }.map {
            Target(id: $0.id, folder: resolveFolder($0.folderName), title: $0.title, hidden: $0.isHidden, kind: "quicknote", hasVideoSource: false)
        }
        let worker = Task.detached(priority: .utility) {
            var result: [UUID: UUID] = [:]
            var identities = Set<UUID>()
            for target in targets {
                try Task.checkCancellation()
                // 旧 title.txt 条目不能只新建一个 entry_id，否则 meta.json 会遮住旧标题。
                // 只补缺字段，保留扫描期间由 UI 写入的较新标题/隐藏状态。
                let fields: [String: Any] = ["title": target.title, "isHidden": target.hidden,
                                             "itemType": target.kind, "hasVideoSource": target.hasVideoSource]
                let id = try write(fields, id: target.id, to: target.folder, fillMissingOnly: true)
                guard identities.insert(id).inserted else { throw IdentityError.duplicateIdentity }
                result[target.id] = id
            }
            return result
        }
        let restored = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        for recording in recordings {
            if let id = restored[recording.id], id != recording.id { recording.id = id }
        }
        for note in notes {
            if let id = restored[note.id], id != note.id { note.id = id }
        }
        if context.hasChanges { try context.save() }
    }

    enum IdentityError: Error { case invalidMetadata, duplicateIdentity }
}
