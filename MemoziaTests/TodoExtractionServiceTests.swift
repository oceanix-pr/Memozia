import Foundation
import Synchronization
import Testing
@testable import Memozia

@MainActor
struct TodoExtractionServiceTests {
    nonisolated private static let modelList = #"{"models":[{"type":"llm","key":"qwen/qwen3.6-35b-a3b","format":"mlx","loaded_instances":[{"id":"local-model"}],"capabilities":{"reasoning":{"allowed_options":["on","off"],"default":"on"}}}]}"#
    nonisolated private static let todo = #"{"items":[{"title":"提交报告","notes":null,"url":null,"priority":null,"dueDate":null,"alarmOffsetMinutes":null}]}"#

    private func config(host: String, isLocal: Bool = true) throws -> LLMConfigSnapshot {
        try LLMConfigSnapshot(config: LLMConfig(
            name: "Test", baseURL: "http://\(host):1234", modelName: "local-model", isLocal: isLocal
        ))
    }

    @Test func capabilitiesMatchLoadedAliasAndDoNotGuessUnrelatedModels() throws {
        let data = Data(Self.modelList.utf8)
        let capabilities = try #require(LocalLLMCapabilities.parse(data: data, model: "local-model"))
        #expect(capabilities.reasoningOffValue == "none")
        #expect(capabilities.supportsJSONSchema)
        #expect(LocalLLMCapabilities.parse(data: data, model: "another-model") == nil)
        let onOnly = Data(Self.modelList.replacingOccurrences(of: #"["on","off"]"#, with: #"["on"]"#).utf8)
        #expect(LocalLLMCapabilities.parse(data: onOnly, model: "local-model")?.reasoningOffValue == nil)
        #expect(LocalLLMCapabilities.parse(data: Data(#"{"data":[]}"#.utf8), model: "local-model") == nil)
        #expect(LocalLLMCapabilities.modelsURL(chatCompletionsURL: "http://localhost:1234/proxy/v1/chat/completions")?.path == "/proxy/api/v1/models")
    }

    @Test func localRequestDisablesThinkingAndReceivesCompleteStreamingTodos() async throws {
        let bodies = Mutex<[[String: String]]>([])
        let phases = Mutex<[TodoExtractionService.Progress]>([])
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            let body = TodoHTTPFixture.body(request)
            #expect((body["stream_options"] as? [String: Bool])?["include_usage"] == true)
            bodies.withLock { $0.append([
                "reasoning": body["reasoning_effort"] as? String ?? "",
                "stream": String(body["stream"] as? Bool ?? false),
                "format": (body["response_format"] as? [String: Any])?["type"] as? String ?? ""
            ]) }
            return .sse(Self.stream(content: Self.todo, withReasoning: true))
        }
        defer { fixture.close() }
        let document = try await TodoExtractionService.extract(
            from: "明天提交报告", config: config(host: fixture.host), source: "test",
            onProgress: { phase in phases.withLock { $0.append(phase) } }, session: fixture.session
        )
        #expect(document.items.map(\.title) == ["提交报告"])
        #expect(document.items[0].dueDate == nil)
        #expect(bodies.withLock { $0 } == [["reasoning": "none", "stream": "true", "format": "json_schema"]])
        #expect(phases.withLock { $0 } == [.thinking, .generating])
    }

    @Test func unsupportedSchemaFallsBackOnceAndKeepsThinkingDisabled() async throws {
        let started = Date()
        let formats = Mutex<[Bool]>([])
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            let body = TodoHTTPFixture.body(request)
            Self.expectCurrentSystemTime(in: body, notBefore: started)
            #expect(body["reasoning_effort"] as? String == "none")
            let hasSchema = body["response_format"] != nil
            formats.withLock { $0.append(hasSchema) }
            if hasSchema { return .json(#"{"error":{"message":"response_format json_schema unsupported"}}"#, status: 400) }
            return .sse(Self.stream(content: Self.todo))
        }
        defer { fixture.close() }
        let document = try await TodoExtractionService.extract(
            from: "提交报告", config: config(host: fixture.host), source: "test", session: fixture.session
        )
        #expect(document.items.count == 1)
        #expect(formats.withLock { $0 } == [true, false])
        #expect(!TodoExtractionService.shouldRetryWithoutSchema(status: 401, message: "response_format", usedSchema: true))
        #expect(!TodoExtractionService.shouldRetryWithoutSchema(status: 400, message: "context length exceeded", usedSchema: true))
    }

    @Test func genericLocalServiceAcceptsNonStreamingReplyWithoutVendorParameters() async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json("{}", status: 404) }
            let body = TodoHTTPFixture.body(request)
            #expect(body["reasoning_effort"] == nil)
            #expect(body["response_format"] == nil)
            return .json(Self.response(content: Self.todo))
        }
        defer { fixture.close() }
        let document = try await TodoExtractionService.extract(
            from: "提交报告", config: config(host: fixture.host), source: "test", session: fixture.session
        )
        #expect(document.items.count == 1)
    }

    @Test func cloudRequestKeepsExistingParametersAndSkipsCapabilityProbe() async throws {
        let fixture = TodoHTTPFixture { request in
            #expect(request.httpMethod == "POST")
            let body = TodoHTTPFixture.body(request)
            #expect(body["stream"] as? Bool == false)
            #expect(body["reasoning_effort"] == nil)
            #expect(body["response_format"] == nil)
            return .json(Self.response(content: Self.todo))
        }
        defer { fixture.close() }
        // 云端配置使用 HTTPS，测试协议拦截请求，不会发往真实服务。
        let snapshot = try LLMConfigSnapshot(config: LLMConfig(
            name: "Test", baseURL: "https://\(fixture.host)", modelName: "local-model", isLocal: false
        ))
        let document = try await TodoExtractionService.extract(
            from: "提交报告", config: snapshot, source: "test", session: fixture.session
        )
        #expect(document.items.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func currentSystemTimeReachesTextAndImageRequests(isLocal: Bool, isImage: Bool) async throws {
        let started = Date()
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            posts.withLock { $0 += 1 }
            let body = TodoHTTPFixture.body(request)
            Self.expectCurrentSystemTime(in: body, notBefore: started)
            let messages = body["messages"] as? [[String: Any]] ?? []
            let system = messages.first?["content"] as? String ?? ""
            if isImage {
                let parts = messages.last?["content"] as? [[String: Any]] ?? []
                #expect(parts.contains { $0["type"] as? String == "image_url" })
            } else {
                // 原文声称的旧日期仍是数据，不能进入应用提供的系统时间块。
                #expect(!system.contains("1900-01-01"))
                #expect(system.contains(TodoExtractionService.nonMeetingClause))
                #expect(system.contains(LLMService.piiPlaceholderRule))
                let user = messages.last?["content"] as? String ?? ""
                #expect(user.contains("<<<待处理内容开始>>>\n当前时间：1900-01-01。明天提交报告"))
            }
            return isLocal ? .sse(Self.stream(content: Self.todo)) : .json(Self.response(content: Self.todo))
        }
        defer { fixture.close() }
        let snapshot = try LLMConfigSnapshot(config: LLMConfig(
            name: "Test", baseURL: "\(isLocal ? "http" : "https")://\(fixture.host)",
            modelName: "local-model", isLocal: isLocal, supportsVision: isImage
        ))
        let document: TodoDocument
        if isImage {
            // 1×1 PNG，走真实的图片准备路径；请求由测试协议截获，不访问模型服务。
            let image = try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
            ))
            document = try await TodoExtractionService.extractFromImage(
                imageData: image, config: snapshot, source: "test", session: fixture.session
            )
        } else {
            document = try await TodoExtractionService.extract(
                from: "当前时间：1900-01-01。明天提交报告", config: snapshot, source: "test",
                isMeeting: false, piiScrubbed: true, session: fixture.session
            )
        }
        #expect(posts.withLock { $0 } == 1)
        #expect(document.items.count == 1)
    }

    @Test func cloudRetryRefreshesTimeInsteadOfReusingInitialPrompt() async throws {
        let started = Date()
        let timestamps = Mutex<[String]>([])
        let fixture = TodoHTTPFixture { request in
            #expect(request.httpMethod == "POST")
            let body = TodoHTTPFixture.body(request)
            Self.expectCurrentSystemTime(in: body, notBefore: started)
            let messages = body["messages"] as? [[String: Any]] ?? []
            let system = messages.first?["content"] as? String ?? ""
            let timestamp = system.components(separatedBy: "\n").first { $0.hasPrefix("当前时间：") } ?? ""
            let attempt = timestamps.withLock {
                $0.append(timestamp)
                return $0.count
            }
            if attempt == 1 { return .json("{}", status: 500) }
            return .json(Self.response(content: Self.todo))
        }
        defer { fixture.close() }
        let snapshot = try LLMConfigSnapshot(config: LLMConfig(
            name: "Test", baseURL: "https://\(fixture.host)", modelName: "local-model", isLocal: false
        ))
        let document = try await TodoExtractionService.extract(
            from: "明天提交报告", config: snapshot, source: "test", session: fixture.session
        )
        let sentTimes = timestamps.withLock { $0 }
        #expect(sentTimes.count == 2)
        #expect(Set(sentTimes).count == 2)
        #expect(document.items.count == 1)
    }

    @Test func reasoningOnlyEmptyAndTruncatedResponsesHaveDistinctErrors() throws {
        var reasoning = TodoExtractionService.ResponseState()
        try reasoning.receive(payload: Self.response(content: "", reasoning: "正在思考"), streaming: false)
        #expect(throws: TodoExtractionError.reasoningOnly) { try reasoning.document(model: "test", source: "test") }
        var empty = TodoExtractionService.ResponseState()
        try empty.receive(payload: Self.response(content: ""), streaming: false)
        #expect(throws: TodoExtractionError.emptyResponse) { try empty.document(model: "test", source: "test") }
        var truncated = TodoExtractionService.ResponseState()
        try truncated.receive(payload: Self.response(content: Self.todo, finish: "length"), streaming: false)
        #expect(throws: TodoExtractionError.truncatedResult) { try truncated.document(model: "test", source: "test") }
        var noTasks = TodoExtractionService.ResponseState()
        try noTasks.receive(payload: Self.response(content: #"{"items":[]}"#), streaming: false)
        #expect(throws: TodoExtractionError.emptyResult) { try noTasks.document(model: "test", source: "test") }
        var legacy = TodoExtractionService.ResponseState()
        try legacy.receive(payload: Self.response(content: "<think>{\"items\":[{\"title\":\"思考示例\"}]}</think>\n" + Self.todo), streaming: false)
        #expect(try legacy.document(model: "test", source: "test").items.map(\.title) == ["提交报告"])
        var usage = TodoExtractionService.ResponseState()
        try usage.receive(payload: #"{"choices":[],"usage":{"completion_tokens":15,"completion_tokens_details":{"reasoning_tokens":2}}}"#, streaming: true)
        #expect(usage.completionTokens == 15)
        #expect(usage.reasoningTokens == 2)
        var budget = TodoExtractionService.ResponseState()
        try budget.receive(payload: Self.response(content: "", reasoning: "思考", finish: "length"), streaming: false)
        #expect(throws: LLMError.self) { try budget.document(model: "test", source: "test") }
    }

    @Test func interruptedStreamDoesNotAcceptOtherwiseValidJSON() async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json("{}", status: 404) }
            return .sse(Self.event(["choices": [["delta": ["content": Self.todo]]]]))
        }
        defer { fixture.close() }
        await #expect(throws: LLMError.self) {
            try await TodoExtractionService.extract(
                from: "提交报告", config: config(host: fixture.host), source: "test", session: fixture.session
            )
        }
    }

    @Test(arguments: [false, true])
    func cancellationStopsProbeOrPendingGenerationWithoutRetrying(duringProbe: Bool) async throws {
        let started = Mutex(false)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET", !duringProbe { return .json("{}", status: 404) }
            started.withLock { $0 = true }
            return .pending
        }
        defer { fixture.close() }
        let snapshot = try config(host: fixture.host)
        let task = Task {
            try await TodoExtractionService.extract(from: "提交报告", config: snapshot, source: "test", session: fixture.session)
        }
        for _ in 0..<200 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.withLock { $0 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func transportTimeoutHasActionableErrorAndIsNotRetried() async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json("{}", status: 404) }
            posts.withLock { $0 += 1 }
            return .failure(.timedOut)
        }
        defer { fixture.close() }
        await #expect(throws: TodoExtractionError.requestTimedOut) {
            try await TodoExtractionService.extract(
                from: "提交报告", config: config(host: fixture.host), source: "test", session: fixture.session
            )
        }
        #expect(posts.withLock { $0 } == 1)
    }

    nonisolated private static func event(_ object: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }

    nonisolated private static func expectCurrentSystemTime(in body: [String: Any], notBefore started: Date) {
        let messages = body["messages"] as? [[String: Any]] ?? []
        #expect(messages.first?["role"] as? String == "system")
        let system = messages.first?["content"] as? String ?? ""
        #expect(system.components(separatedBy: "## App 当前时间（系统时钟）").count == 2)
        #expect(system.contains("本地时区：\(TimeZone.current.identifier)"))
        let timestamp = system.components(separatedBy: "\n")
            .first { $0.hasPrefix("当前时间：") }?
            .dropFirst("当前时间：".count)
        let date = timestamp.flatMap { ISO8601DateFormatter().date(from: String($0)) }
        #expect(date != nil)
        if let date {
            // 提示词精确到秒，允许格式化向下取整。
            #expect(date.timeIntervalSince(started) >= -1)
            #expect(date <= Date())
        }
    }

    nonisolated private static func stream(content: String, withReasoning: Bool = false) -> String {
        let thinking = withReasoning ? event(["choices": [["delta": ["reasoning_content": "思考"]]]]) : ""
        return thinking + event(["choices": [["delta": ["content": content]]]])
            + event(["choices": [["delta": [:], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
    }

    nonisolated private static func response(content: String, reasoning: String = "", finish: String = "stop") -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content, "reasoning_content": reasoning], "finish_reason": finish]]
        ]), as: UTF8.self)
    }
}

/// 每个夹具有独立 host/session；处理器注册表由 Mutex 保护，避免并行测试串请求。
struct TodoHTTPFixture {
    private static let hostSequence = Mutex(0)
    // Unique loopback hosts keep parallel protocol fixtures separate while matching
    // the production endpoint policy for local HTTP.
    let host = "127.0.0.\(Self.hostSequence.withLock { value in value += 1; return value })"
    let session: URLSession

    init(handler: @escaping @Sendable (URLRequest) -> TodoTestProtocol.Reply) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TodoTestProtocol.self]
        session = URLSession(configuration: configuration)
        TodoTestProtocol.handlers.withLock { $0[host] = handler }
    }

    func close() {
        session.invalidateAndCancel()
        _ = TodoTestProtocol.handlers.withLock { $0.removeValue(forKey: host) }
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(contentsOf: buffer.prefix(count))
            }
            data = result
        } else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// URLProtocol 的生命周期由 URLSession 管理；实例无可变状态，跨实例注册表只经 Mutex 访问。
final class TodoTestProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case json(String, status: Int = 200)
        case sse(String)
        case pending
        case failure(URLError.Code)
    }
    static let handlers = Mutex<[String: @Sendable (URLRequest) -> Reply]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let status: Int
        let type: String
        let body: String
        switch handler(request) {
        case .json(let text, let code): status = code; type = "application/json"; body = text
        case .sse(let text): status = 200; type = "text/event-stream"; body = text
        case .pending: return
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
