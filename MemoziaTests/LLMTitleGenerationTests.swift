import Foundation
import Synchronization
import Testing
@testable import Memozia

@MainActor
struct LLMTitleGenerationTests {
    nonisolated private static let modelList = #"{"models":[{"type":"llm","key":"test-model","format":"mlx","capabilities":{"reasoning":{"allowed_options":["off","on"],"default":"on"}}}]}"#

    private func config(host: String, isLocal: Bool = true) throws -> LLMConfigSnapshot {
        try LLMConfigSnapshot(config: LLMConfig(
            name: "Title test", baseURL: "\(isLocal ? "http" : "https")://\(host)",
            modelName: "test-model", isLocal: isLocal
        ))
    }

    // 复用待办测试的 OpenAI 兼容 HTTP 夹具，所有离线请求均由 URLProtocol 截获。
    @Test func localTitleDisablesSupportedThinkingAndUsesStreaming() async throws {
        let probes = Mutex(0)
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" {
                probes.withLock { $0 += 1 }
                return .json(Self.modelList)
            }
            posts.withLock { $0 += 1 }
            let body = TodoHTTPFixture.body(request)
            #expect(body["stream"] as? Bool == true)
            #expect(body["reasoning_effort"] as? String == "none")
            #expect(request.timeoutInterval == 180)
            return .sse(Self.stream(content: "“17:30 项目进度”\n其他说明", reasoning: "不应写入标题的思考"))
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "讨论项目进度与下周计划", config: config(host: fixture.host), session: fixture.session
        )
        #expect(title == "项目进度")
        #expect(probes.withLock { $0 } == 1)
        #expect(posts.withLock { $0 } == 1)
    }

    @Test func reasoningCannotBeDisabledUnlessModelDeclaresSupport() async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" {
                return .json(Self.modelList.replacingOccurrences(of: #"["off","on"]"#, with: #"["on"]"#))
            }
            let body = TodoHTTPFixture.body(request)
            #expect(body["reasoning_effort"] == nil)
            #expect(body["max_tokens"] as? Int == 65_536)
            return .sse(Self.stream(content: "项目进度", reasoning: "继续思考"))
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
        )
        #expect(title == "项目进度")
    }

    @Test(arguments: ["项目进度", "<think>内部推理\n不要当作标题</think>\n项目进度"])
    func genericLocalServiceAcceptsNonStreamingResponse(content: String) async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json("{}", status: 404) }
            let body = TodoHTTPFixture.body(request)
            #expect(body["stream"] as? Bool == true)
            #expect(body["reasoning_effort"] == nil)
            return .json(Self.response(content: content))
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
        )
        #expect(title == "项目进度")
    }

    @Test func cloudTitleKeepsExistingRequestAndSkipsProbe() async throws {
        let fixture = TodoHTTPFixture { request in
            #expect(request.httpMethod == "POST")
            let body = TodoHTTPFixture.body(request)
            #expect(body["stream"] as? Bool == false)
            #expect(body["reasoning_effort"] == nil)
            #expect(body["max_tokens"] as? Int == 65_536)
            #expect(request.timeoutInterval == 60)
            let messages = body["messages"] as? [[String: String]]
            #expect(messages?.last?["content"]?.count == 8_000)
            return .json(Self.response(content: "这是一个超过十个字的完整标题"))
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: String(repeating: "文", count: 9_000), config: config(host: fixture.host, isLocal: false),
            session: fixture.session
        )
        #expect(title == String("这是一个超过十个字的完整标题".prefix(10)))
    }

    @Test func onlyTrulyEmptyResponsesRetryOnceWithoutRepeatingProbe() async throws {
        let probes = Mutex(0)
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" {
                probes.withLock { $0 += 1 }
                return .json(Self.modelList)
            }
            let attempt = posts.withLock { $0 += 1; return $0 }
            return .sse(Self.stream(content: attempt == 1 ? " \n" : "项目进度"))
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
        )
        #expect(title == "项目进度")
        #expect(posts.withLock { $0 } == 2)
        #expect(probes.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func reasoningOnlyResponsesFailWithoutRetryOrSavingThinking(streaming: Bool) async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            posts.withLock { $0 += 1 }
            return streaming
                ? .sse(Self.stream(content: "", reasoning: "只有思考"))
                : .json(Self.response(content: "<think>只有思考</think>"))
        }
        defer { fixture.close() }
        do {
            _ = try await LLMService.generateTitle(
                from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
            )
            Issue.record("不应把只有思考的响应保存成标题")
        } catch LLMError.invalidResponse {} catch { Issue.record("意外错误：\(error)") }
        #expect(posts.withLock { $0 } == 1)
    }

    @Test(arguments: ["", "尚未完成的标题"])
    func budgetExhaustionDoesNotRetryOrAcceptTruncatedTitle(content: String) async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            posts.withLock { $0 += 1 }
            return .sse(Self.stream(content: content, reasoning: "思考", finish: "length"))
        }
        defer { fixture.close() }
        do {
            _ = try await LLMService.generateTitle(
                from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
            )
            Issue.record("预算耗尽时不应返回标题")
        } catch LLMError.outputBudgetExhausted { #expect(content.isEmpty) }
        catch LLMError.invalidResponse { #expect(!content.isEmpty) }
        catch { Issue.record("意外错误：\(error)") }
        #expect(posts.withLock { $0 } == 1)
    }

    @Test func interruptedStreamDoesNotReturnPartialTitle() async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            return .sse(Self.event(["choices": [["delta": ["content": "半个标题"]]]]))
        }
        defer { fixture.close() }
        do {
            _ = try await LLMService.generateTitle(
                from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
            )
            Issue.record("断流时不应返回未完成的标题")
        } catch LLMError.invalidResponse {} catch { Issue.record("意外错误：\(error)") }
    }

    @Test func timeoutIsNotRetried() async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" { return .json(Self.modelList) }
            posts.withLock { $0 += 1 }
            return .failure(.timedOut)
        }
        defer { fixture.close() }
        do {
            _ = try await LLMService.generateTitle(
                from: "讨论项目进度", config: config(host: fixture.host), session: fixture.session
            )
            Issue.record("应返回超时错误")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        #expect(posts.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func cancellationStopsProbeOrInference(duringProbe: Bool) async throws {
        let started = Mutex(false)
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET", !duringProbe { return .json(Self.modelList) }
            started.withLock { $0 = true }
            return .pending
        }
        defer { fixture.close() }
        let snapshot = try config(host: fixture.host)
        let task = Task {
            try await LLMService.generateTitle(from: "讨论项目进度", config: snapshot, session: fixture.session)
        }
        // 仅等待夹具收到请求；超时后仍取消任务，防止失败用例遗留挂起连接。
        for _ in 0..<200 {
            if started.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(started.withLock { $0 })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_LOCAL_TITLE"] == "1"))
    func liveLocalModelGeneratesTitle() async throws {
        // 显式启用才访问指定本地服务；仅发送合成文本，不读取用户录音或笔记。
        let environment = ProcessInfo.processInfo.environment
        let baseURL = try #require(environment["MEMOZIA_LOCAL_TITLE_URL"])
        let model = try #require(environment["MEMOZIA_LOCAL_TITLE_MODEL"])
        let snapshot = try LLMConfigSnapshot(config: LLMConfig(
            name: "Local title smoke test", baseURL: baseURL, modelName: model, isLocal: true
        ))
        let started = Date()
        let title = try await LLMService.generateTitle(
            from: "会议讨论项目进度、测试安排和下周交付计划。", config: snapshot
        )
        #expect(!title.isEmpty)
        #expect(title.count <= 10)
        #expect(!title.contains("<think>"))
        print("Local title smoke: elapsed=\(Date().timeIntervalSince(started))s titleLength=\(title.count)")
    }

    nonisolated private static func event(_ object: [String: Any]) -> String {
        // SSE 允许 data: 后无空格，覆盖兼容服务的合法格式。
        "data:" + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }

    nonisolated private static func stream(content: String, reasoning: String = "", finish: String = "stop") -> String {
        event(["choices": [["delta": ["reasoning_content": reasoning]]]])
            + event(["choices": [["delta": ["content": content]]]])
            + event(["choices": [["delta": [:], "finish_reason": finish]]]) + "data:[DONE]\n\n"
    }

    nonisolated private static func response(content: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ]), as: UTF8.self)
    }
}
