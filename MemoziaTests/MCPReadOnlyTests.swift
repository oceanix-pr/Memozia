import Foundation
import SwiftData
import Testing
import MCP
@testable import Memozia

private extension Value {
    subscript(_ key: String) -> Value? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
}

@MainActor
private final class MemoryMCPVault: MCPTokenVault {
    var tokens: [UUID: String] = [:]
    var failRemoval = false
    var failReading = false
    func read(_ id: UUID) throws -> String? {
        if failReading { throw MCPQueryError.readFailed }
        return tokens[id]
    }
    func write(_ token: String, id: UUID) throws { tokens[id] = token }
    func remove(_ id: UUID) throws {
        if failRemoval { throw MCPQueryError.readFailed }
        tokens.removeValue(forKey: id)
    }
}

@MainActor
@Suite(.serialized)
struct MCPReadOnlyTests {
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let access: MCPAccessStore
        let vault: MemoryMCPVault
        let grant: MCPClientGrant
        let defaults: UserDefaults
        let suite: String
        func clean() { defaults.removePersistentDomain(forName: suite) }
        var query: EntryQueryService {
            EntryQueryService(context: context, decrypt: { $0 ?? "" }, checkAccess: { access.isCurrent($0) }, verifyDiskIdentity: false,
                              scrub: { text in
                PIIScrubMapping(pairs: text.contains("alice@example.com") ? [(token: "[邮箱1]", original: "alice@example.com")] : [])
            })
        }
        func note(_ title: String, text: String, folder: String, hidden: Bool = false, date: Date = Date()) -> QuickNote {
            let note = QuickNote(title: title, textContent: text, folderName: folder)
            note.isHidden = hidden
            note.createdAt = date
            context.insert(note)
            return note
        }
    }

    private func fixture(redact: Bool = false, since: Date? = nil) throws -> Fixture {
        let schema = Schema([AudioRecording.self, TranscriptSegment.self, QuickNote.self, LLMConfig.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let suite = "MemoziaMCPTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let vault = MemoryMCPVault()
        let access = MCPAccessStore(defaults: defaults, vault: vault)
        access.setEnabled(true)
        let grant = try access.addClient(name: "Test client", notBefore: since, redact: redact)
        return Fixture(container: container, context: container.mainContext, access: access, vault: vault, grant: grant, defaults: defaults, suite: suite)
    }

    @Test("MCP 默认关闭，凭据不进入偏好；撤销失败也不能继续访问")
    func credentialsAndRevocation() throws {
        let f = try fixture()
        defer { f.clean() }
        let token = try #require(f.vault.tokens[f.grant.id])
        #expect(try f.access.authenticate("Bearer " + token) == f.grant)
        #expect(!String(describing: f.defaults.dictionaryRepresentation()).contains(token))
        #expect(throws: MCPQueryError.unauthorized) { try f.access.authenticate("Bearer " + token + "x") }
        f.vault.failReading = true
        #expect(throws: MCPQueryError.credentialsUnavailable) { try f.access.authenticate("Bearer " + token) }
        f.vault.failReading = false
        f.vault.failRemoval = true
        #expect(throws: MCPQueryError.readFailed) { try f.access.revoke(f.grant.id) }
        #expect(throws: MCPQueryError.unauthorized) { try f.access.authenticate("Bearer " + token) }
        let blank = MCPAccessStore(defaults: UserDefaults(suiteName: "MemoziaMCPBlank-\(UUID().uuidString)")!, vault: f.vault)
        #expect(!blank.enabled)
    }

    @Test("全文命中正文，隐藏及日期范围外的内容在查询和资源读取中均不可见")
    func searchAndReadAuthorization() async throws {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let f = try fixture(since: since)
        defer { f.clean() }
        let note = f.note("Public meeting", text: "The launch date is Friday", folder: "20261030120000")
        let hidden = f.note("Hidden meeting", text: "launch secret", folder: "20261030120001", hidden: true)
        let old = f.note("Old meeting", text: "launch old", folder: "20200101000000", date: since.addingTimeInterval(-1))
        try f.context.save()
        let result = try await f.query.call("search_entries", arguments: ["query": "launch"], grant: f.grant)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(text.contains("launch date"))
        #expect(!text.contains("Hidden meeting"))
        #expect(!text.contains("Old meeting"))
        for id in [hidden.id, old.id, UUID()] {
            await #expect(throws: MCPQueryError.notFound) {
                try await f.query.call("get_entry", arguments: ["entry_id": .string(id.uuidString), "field": "text"], grant: f.grant)
            }
        }
        let uri = "memozia://entries/\(note.id.uuidString)/text"
        let args = try MCPReadOnlySchema.resourceArguments(uri)
        let resource = try await f.query.call("get_entry", arguments: args, grant: f.grant)
        #expect(String(decoding: try JSONEncoder().encode(resource), as: UTF8.self).contains("Friday"))
        #expect(throws: MCPQueryError.invalidArguments) { try MCPReadOnlySchema.resourceArguments("file:///etc/passwd") }
        #expect(throws: MCPQueryError.invalidArguments) { try MCPReadOnlySchema.resourceArguments(uri + "/../summary") }
    }

    @Test("列表和长文本可分页，游标不能跨请求使用")
    func pagination() async throws {
        let f = try fixture()
        defer { f.clean() }
        _ = f.note("First", text: "abcdef", folder: "20261030120001")
        let note = f.note("Second", text: "123456", folder: "20261030120002")
        try f.context.save()
        let query = f.query
        let first = try await query.call("list_entries", arguments: ["limit": 1], grant: f.grant)
        let cursor = try #require(first["next_cursor"])
        let second = try await query.call("list_entries", arguments: ["limit": 1, "cursor": cursor], grant: f.grant)
        #expect(first["entries"] != second["entries"])
        await #expect(throws: MCPQueryError.invalidCursor) {
            try await query.call("search_entries", arguments: ["query": "First", "cursor": cursor], grant: f.grant)
        }
        let page = try await query.call("get_entry", arguments: ["entry_id": .string(note.id.uuidString), "field": "text", "limit": 3], grant: f.grant)
        #expect(page["text"] == "123")
        let next = try #require(page["next_cursor"])
        let rest = try await query.call("get_entry", arguments: ["entry_id": .string(note.id.uuidString), "field": "text", "limit": 3, "cursor": next], grant: f.grant)
        #expect(rest["text"] == "456")
        #expect(rest["next_cursor"] == .null)
        note.textContent = "changed content"
        await #expect(throws: MCPQueryError.invalidCursor) {
            try await query.call("get_entry", arguments: ["entry_id": .string(note.id.uuidString), "field": "text", "limit": 3, "cursor": next], grant: f.grant)
        }
    }

    @Test("转写按时间过滤并保留证据；正文与标题共用响应脱敏映射")
    func transcriptAndRedaction() async throws {
        let f = try fixture(redact: true)
        defer { f.clean() }
        let r = AudioRecording(fileName: "mail alice@example.com", fileExtension: "m4a", storedFileName: "recording.m4a", folderName: "20261030120000")
        r.transcriptionStatus = .completed
        f.context.insert(r)
        let a = TranscriptSegment(startTime: 0, endTime: 5, speaker: "Alice", text: "earlier")
        let b = TranscriptSegment(startTime: 10, endTime: 15, speaker: "Alice", text: "Contact alice@example.com for launch")
        a.recording = r
        b.recording = r
        f.context.insert(a)
        f.context.insert(b)
        r.segments = [a, b]
        try f.context.save()
        let result = try await f.query.call("get_transcript", arguments: ["entry_id": .string(r.id.uuidString), "start_seconds": 9, "end_seconds": 20], grant: f.grant)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!text.contains("alice@example.com"))
        #expect(!text.contains("earlier"))
        #expect(text.contains("start_seconds"))
        #expect(text.contains("Alice"))
    }

    @Test("身份写入保留旧元数据；数据库重建可恢复同一个 ID；损坏元数据拒绝覆盖")
    func diskIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MemoziaIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let meta = folder.appendingPathComponent("meta.json")
        try Data("{\"title\":\"Legacy\",\"future_field\":true}".utf8).write(to: meta)
        let id = UUID()
        #expect(try EntryIdentityStore.write([:], id: id, to: folder) == id)
        #expect(try EntryIdentityStore.read(from: folder) == id)
        #expect(try EntryIdentityStore.write(["title": "Renamed"], id: UUID(), to: folder) == id)
        #expect(try EntryIdentityStore.write(["title": "Older", "itemType": "recording"], id: UUID(), to: folder, fillMissingOnly: true) == id)
        let text = try String(contentsOf: meta, encoding: .utf8)
        #expect(text.contains("future_field"))
        #expect(text.contains("Renamed"))
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: meta)
        #expect(throws: (any Error).self) { try EntryIdentityStore.write([:], id: UUID(), to: folder) }
        #expect(try Data(contentsOf: meta) == corrupt)
    }

    @Test("解密失败和未持久化身份不能作为空内容或成功结果返回")
    func failedReadsAreExplicit() async throws {
        let f = try fixture()
        defer { f.clean() }
        let note = f.note("Test", text: "body", folder: "20261030120000")
        try f.context.save()
        let query = EntryQueryService(context: f.context, decrypt: { _ in throw MCPQueryError.readFailed },
                                      checkAccess: { f.access.isCurrent($0) }, verifyDiskIdentity: false)
        await #expect(throws: MCPQueryError.readFailed) {
            try await query.call("get_entry", arguments: ["entry_id": .string(note.id.uuidString), "field": "text"], grant: f.grant)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("MemoziaMissingIdentity-\(UUID().uuidString)")
        let strict = EntryQueryService(context: f.context, decrypt: { $0 ?? "" }, checkAccess: { f.access.isCurrent($0) }, resolveFolder: { _ in missing })
        await #expect(throws: MCPQueryError.readFailed) {
            try await strict.call("get_entry", arguments: ["entry_id": .string(note.id.uuidString), "field": "text"], grant: f.grant)
        }
    }

    @Test("旧标题条目补齐身份后仍可恢复标题，重建模型继续使用磁盘 ID")
    func legacyIdentityPreparationAndRebuild() async throws {
        let f = try fixture()
        defer { f.clean() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MemoziaLegacyIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("Legacy title".utf8).write(to: folder.appendingPathComponent("title.txt"))
        let note = f.note("Legacy title", text: "body", folder: "20261030120000")
        let id = note.id
        try f.context.save()
        try await EntryIdentityStore.prepare(context: f.context, resolveFolder: { _ in folder })
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any]
        #expect(meta?["title"] as? String == "Legacy title")
        #expect(try EntryIdentityStore.read(from: folder) == id)
        f.context.delete(note)
        try f.context.save()
        let rebuilt = f.note("Legacy title", text: "body", folder: "20261030120000")
        #expect(rebuilt.id != id)
        try f.context.save()
        try await EntryIdentityStore.prepare(context: f.context, resolveFolder: { _ in folder })
        #expect(rebuilt.id == id)
    }

    @Test("短字符分页无法绕过正文脱敏")
    func redactBeforeTextPagination() async throws {
        let f = try fixture(redact: true)
        defer { f.clean() }
        let note = f.note("Contact", text: "alice@example.com", folder: "20261030120000")
        try f.context.save()
        let query = f.query
        var arguments: [String: Value] = ["entry_id": .string(note.id.uuidString), "field": "text", "limit": 1]
        var text = ""
        for _ in 0..<100 {
            let page = try await query.call("get_entry", arguments: arguments, grant: f.grant)
            text += page["text"]?.stringValue ?? ""
            guard let cursor = page["next_cursor"], cursor != .null else { break }
            arguments["cursor"] = cursor
        }
        #expect(!text.contains("alice"))
        #expect(!text.contains("example.com"))
        #expect(text.contains("邮箱"))
    }

    @Test("待办读取兼容旧明文，损坏文件明确失败，不导出提醒事项内部标识")
    func todoReadAndCorruption() async throws {
        let f = try fixture()
        defer { f.clean() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MemoziaMCPTodos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = f.note("Todo source", text: "body", folder: "20261030120000")
        try f.context.save()
        let query = EntryQueryService(context: f.context, decrypt: { $0 ?? "" }, checkAccess: { f.access.isCurrent($0) },
                                      verifyDiskIdentity: false, resolveFolder: { _ in folder })
        let args: [String: Value] = ["entry_id": .string(note.id.uuidString)]
        let missing = try await query.call("get_todos", arguments: args, grant: f.grant)
        #expect(missing["todos"]?["available"] == false)
        let todo = TodoItem(title: "Ship release", notes: "Friday", priority: .high, reminderIdentifier: "PRIVATE_EVENTKIT_ID")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = folder.appendingPathComponent(TodoDocument.fileName)
        try encoder.encode(TodoDocument(source: "quicknote", model: "test", items: [todo])).write(to: url, options: .atomic)
        let result = try await query.call("get_todos", arguments: args, grant: f.grant)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(text.contains("Ship release"))
        #expect(text.contains("priority"))
        #expect(!text.contains("PRIVATE_EVENTKIT_ID"))
        try Data("{broken".utf8).write(to: url, options: .atomic)
        await #expect(throws: (any Error).self) { try await query.call("get_todos", arguments: args, grant: f.grant) }
    }

    @Test("HTTP 认证、Origin、初始化与会话隔离；只注册五个只读工具")
    func protocolAndSessionIsolation() async throws {
        let f = try fixture()
        defer { f.clean() }
        let router = MCPReadOnlyServer(access: f.access, query: f.query, isReady: { true })
        let token = try #require(f.vault.tokens[f.grant.id])
        var headers = ["Host": "127.0.0.1:\(f.access.port)", "Authorization": "Bearer " + token,
                       "Content-Type": "application/json", "Accept": "application/json, text/event-stream"]
        let initBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}".utf8)
        let initialized = await router.handle(HTTPRequest(method: "POST", headers: headers, body: initBody, path: "/mcp"))
        #expect(initialized.status == 200)
        let session = try #require(initialized.headers["Mcp-Session-Id"])
        headers["Mcp-Session-Id"] = session
        headers["Mcp-Protocol-Version"] = "2025-11-25"
        let list = Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}".utf8)
        let reply = await router.handle(HTTPRequest(method: "POST", headers: headers, body: list, path: "/mcp"))
        let value = try JSONDecoder().decode(Value.self, from: reply.body)
        #expect(value["result"]?["tools"]?.arrayValue?.count == 5)
        #expect(!String(decoding: reply.body, as: UTF8.self).contains("delete_entry"))
        #expect(await router.handle(HTTPRequest(method: "GET", headers: headers, path: "/mcp")).status == 405)
        headers["Origin"] = "https://evil.example"
        #expect(await router.handle(HTTPRequest(method: "POST", headers: headers, body: list, path: "/mcp")).status == 403)
        headers.removeValue(forKey: "Origin")
        headers.removeValue(forKey: "Mcp-Session-Id")
        for _ in 0..<5 {
            let reconnect = await router.handle(HTTPRequest(method: "POST", headers: headers, body: initBody, path: "/mcp"))
            #expect(reconnect.status == 200)
        }
        headers["Mcp-Session-Id"] = session
        #expect(await router.handle(HTTPRequest(method: "POST", headers: headers, body: list, path: "/mcp")).status == 404)
        let second = try f.access.addClient(name: "Other", notBefore: nil, redact: false)
        headers["Authorization"] = "Bearer " + (try #require(f.vault.tokens[second.id]))
        #expect(await router.handle(HTTPRequest(method: "POST", headers: headers, body: list, path: "/mcp")).status == 404)
        try f.access.revoke(second.id)
        #expect(await router.handle(HTTPRequest(method: "POST", headers: headers, body: list, path: "/mcp")).status == 401)
        await router.stop()
    }

    @Test("真实回环 HTTP 与随应用分发的 stdio helper 可以完成查询")
    func loopbackAndBundledHelper() async throws {
        let f = try fixture()
        defer { f.clean() }
        _ = f.note("Release planning", text: "The launch is Friday", folder: "20261030120000")
        try f.context.save()
        let router = MCPReadOnlyServer(access: f.access, query: f.query, isReady: { true })
        let listener = MCPLoopbackListener()
        let port = try await listener.start(port: 0) { request in await router.handle(request) }
        f.access.setEnabled(false)
        try f.access.setPort(port)
        f.access.setEnabled(true)
        let token = try #require(f.vault.tokens[f.grant.id])
        let client = Client(name: "HTTP integration test", version: "1", configuration: .strict)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let modifier: @Sendable (URLRequest) -> URLRequest = { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        }
        let http = HTTPClientTransport(endpoint: URL(string: f.access.endpoint)!, configuration: config, streaming: false, requestModifier: modifier)
        do {
            try await client.connect(transport: http)
            #expect(try await client.listTools().tools.count == 5)
            await client.disconnect()

            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/memozia-mcp")
            var env = ProcessInfo.processInfo.environment
            // helper 是普通 CLI，不能继承测试宿主的注入环境和 runner 会话。
            // 否则 testmanagerd 可能把子进程误接为同一测试运行器。
            for key in Array(env.keys) where key.hasPrefix("XCTest") || key.hasPrefix("XCInject") || key == "DYLD_INSERT_LIBRARIES" {
                env.removeValue(forKey: key)
            }
            env["MEMOZIA_MCP_URL"] = f.access.endpoint
            env["MEMOZIA_MCP_TOKEN"] = token
            process.environment = env
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            let bridge = Client(name: "stdio integration test", version: "1", configuration: .strict)
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                if process.isRunning { process.terminate() }
                await bridge.disconnect()
            }
            defer { watchdog.cancel() }
            let stdio = StdioTransport(input: .init(rawValue: output.fileHandleForReading.fileDescriptor),
                                       output: .init(rawValue: input.fileHandleForWriting.fileDescriptor))
            try await bridge.connect(transport: stdio)
            #expect(try await bridge.listTools().tools.count == 5)
            let result = try await bridge.callTool(name: "search_entries", arguments: ["query": "launch"])
            #expect(result.isError != true)
            let text = result.content.compactMap { content -> String? in
                if case .text(let text, _, _) = content { return text }
                return nil
            }.joined()
            #expect(text.contains("Friday"))
            await bridge.disconnect()
            await router.stop()
            try await listener.stop()
        } catch {
            await client.disconnect()
            await router.stop()
            try await listener.stop()
            throw error
        }
    }
}
