import Foundation
import os.log

/// AI 待办拆解服务：把总结 / 文本 / OCR 文本拆解为结构化待办列表
///
/// 复用 LLMService 的网络请求与重试约定，但使用独立的 system prompt
/// 强制 LLM 返回严格 JSON。本地模型（LM Studio / Ollama）也走同一管线。
enum TodoExtractionService {

    private static let logger = Logger(subsystem: "app.memozia", category: "TodoExtraction")

    /// 网络重试次数（与 LLMService 一致）
    private static let maxRetries = 3

    enum Progress: Equatable, Sendable {
        case thinking, generating

        var text: String {
            switch self {
            case .thinking: String(localized: "AI 正在思考待办...")
            case .generating: String(localized: "AI 正在生成待办...")
            }
        }
    }

    /// 拆解待办（本地流式接收，但只在完整 JSON 校验通过后返回文档）
    /// - Parameters:
    ///   - content: 输入文本（总结 / 快捷笔记文字 / OCR 文本）
    ///   - config: LLM 配置快照
    ///   - source: 来源标识，用于持久化
    static func extract(
        from content: String,
        config: LLMConfigSnapshot,
        source: String,
        isMeeting: Bool? = nil,
        piiScrubbed: Bool = false,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        session: URLSession? = nil
    ) async throws -> TodoDocument {
        var items: [TodoItem] = []
        for part in SummaryChunking.chunks(content) {
            try Task.checkCancellation()
            do {
                var document = try await extractPart(from: part, config: config, source: source,
                    isMeeting: isMeeting, piiScrubbed: piiScrubbed, onProgress: onProgress, session: session)
                for index in document.items.indices {
                    document.items[index] = validateEvidence(document.items[index], in: part)
                }
                items.append(contentsOf: document.items)
            } catch TodoExtractionError.emptyResult { continue }
        }
        guard !items.isEmpty else { throw TodoExtractionError.emptyResult }
        return TodoDocument(source: source, model: config.modelName, generatedAt: Date(), items: items)
    }

    static func validateEvidence(_ candidate: TodoItem, in content: String) -> TodoItem {
        var item = candidate
        item.isUserConfirmed = false
        if let quote = item.evidenceQuote, !quote.isEmpty, content.contains(quote) {
            if let raw = item.sourceSeekURL,
               let url = URL(string: raw), url.scheme?.lowercased() == "memozia", url.host?.lowercased() == "seek",
               let seconds = Double(url.lastPathComponent), seconds.isFinite, seconds >= 0,
               content.components(separatedBy: "\n\n").contains(where: { $0.contains(raw) && $0.contains(quote) }) {
                // Keep the time link only when its quote is in the same supplied source block.
            }
            else { item.sourceSeekURL = nil }
        } else { item.evidenceQuote = nil; item.sourceSeekURL = nil }
        if let owner = item.owner, owner.isEmpty || !content.contains(owner) { item.owner = nil }
        return item
    }

    private static func extractPart(
        from content: String,
        config: LLMConfigSnapshot,
        source: String,
        isMeeting: Bool? = nil,
        piiScrubbed: Bool = false,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        session: URLSession? = nil
    ) async throws -> TodoDocument {
        guard let url = URL(string: config.chatCompletionsURL) else {
            throw LLMError.invalidURL
        }
        // 传输许可来自实际端点，而非模型标记。
        try LLMService.validateSecureURL(for: config)

        // Public entry point already partitions the entire input; do not truncate a part.
        let cappedContent = content

        // 提示词经 PromptTemplateStore 解析：用户可在「设置 → 提示词」自定义，未自定义时用内置默认
        let baseSystemPrompt = PromptTemplateStore.resolved(.todoExtraction) + "\n\nFor each item optionally include evidenceQuote (an exact quote from the input), sourceSeekURL (an existing Memozia://seek/ link adjacent to that quote), and owner (only explicitly named). Never fabricate evidence, links, owners or deadlines. All AI items require user review."
        // 已确认非会议（课程/讲座/演示）时追加内容类型条款，
        // 防止把知识要点硬包装成会议式行动项；未判定/会议维持原行为
        let basePrompt = isMeeting == false
            ? baseSystemPrompt + "\n\n" + nonMeetingClause
            : baseSystemPrompt

        let requestBody: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": piiScrubbed
                    ? basePrompt + "\n\n" + LLMService.piiPlaceholderRule
                    : basePrompt],
                ["role": "user", "content": userPrompt(content: cappedContent)]
            ],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 65536
        ]

        // 本地模型不重试
        if config.isLocal {
            return try await performRequest(url: url, config: config, body: requestBody, source: source,
                                            onProgress: onProgress, session: session)
        }

        // 云端 API 带重试
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                return try await performRequest(url: url, config: config, body: requestBody, source: source,
                                                onProgress: onProgress, session: session)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case LLMError.apiError(let statusCode, _) = error,
                   statusCode >= 400 && statusCode < 500 {
                    throw error
                }
                if attempt < maxRetries {
                    let delay = UInt64(attempt) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)   // 取消上抛：旧写法退避后仍重发剩余请求
                }
            }
        }
        throw lastError ?? LLMError.invalidResponse
    }

    /// 从图片拆解待办（多模态：图片直发支持视觉的 LLM）
    /// - Parameters:
    ///   - imageData: PNG 图片数据
    ///   - config: LLM 配置快照（需 supportsVision == true）
    ///   - source: 来源标识
    static func extractFromImage(
        imageData: Data,
        config: LLMConfigSnapshot,
        source: String,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        session: URLSession? = nil
    ) async throws -> TodoDocument {
        guard config.supportsVision else {
            // 不支持视觉：降级到 Vision OCR → 文本拆解
            logger.info("LLM 不支持视觉输入，降级到 Vision OCR")
            let ocrText = try await VisionOCRService.recognizeText(from: imageData)
            guard !ocrText.isEmpty else {
                throw TodoExtractionError.emptyResult
            }
            return try await extract(from: ocrText, config: config, source: source,
                                     onProgress: onProgress, session: session)
        }

        guard let url = URL(string: config.chatCompletionsURL) else {
            throw LLMError.invalidURL
        }
        // 图片同样服从独立端点策略，但不能宣称做了文本脱敏。
        try LLMService.validateSecureURL(for: config)

        // 图片准备（解码 + 降采样 + base64 + JSON 序列化）显式移到后台执行器：
        // 1) nonisolated async 函数在第一个挂起点之前**沿用调用方执行器**（这里通常是
        //    MainActor），旧写法等于把 4K 截图的整张 base64 编码压在主线程上；
        // 2) 旧版完全不做降采样，且原图 + base64 + dataURL 三份并存再被
        //    JSONSerialization 复制一份，批量拆解时几百 MB 级峰值内存。
        //    现在复用 LLMService 的 2048px JPEG 降采样（与总结路径同一实现）。
        let model = config.modelName
        let prompt = PromptTemplateStore.resolved(.todoExtraction)
        let bodyData = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let payload = LLMService.downsampleForLLM(imageData: imageData)
            let dataURL = "data:image/\(payload.format);base64,\(payload.data.base64EncodedString())"
            // OpenAI 多模态消息格式：content 为数组
            let requestBody: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": [
                        ["type": "text", "text": "请从以下图片中提取待办事项："],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]]
                ],
                "stream": false,
                "temperature": 0.3,
                "max_tokens": 65536
            ]
            return try JSONSerialization.data(withJSONObject: requestBody)
        }.value

        // 图片尚无可逐字校验的文本来源，不能接受模型编造的来源字段。
        var document = try await performRequest(url: url, config: config, bodyData: bodyData, source: source,
                                                onProgress: onProgress, session: session)
        for index in document.items.indices {
            document.items[index].evidenceQuote = nil
            document.items[index].sourceSeekURL = nil
            document.items[index].owner = nil
            document.items[index].isUserConfirmed = false
        }
        return document
    }

    // MARK: - 请求执行

    private static func performRequest(
        url: URL,
        config: LLMConfigSnapshot,
        body: [String: Any],
        source: String,
        onProgress: @escaping @Sendable (Progress) -> Void,
        session: URLSession?
    ) async throws -> TodoDocument {
        try await performRequest(
            url: url,
            config: config,
            bodyData: try JSONSerialization.data(withJSONObject: body),
            source: source,
            onProgress: onProgress,
            session: session
        )
    }

    /// 已序列化请求体入口：图片待办用它在后台完成解码/降采样/base64/序列化，
    /// 避免这段重活落在调用方（MainActor）的执行器上
    private static func performRequest(
        url: URL,
        config: LLMConfigSnapshot,
        bodyData: Data,
        source: String,
        onProgress: @escaping @Sendable (Progress) -> Void,
        session suppliedSession: URLSession?
    ) async throws -> TodoDocument {
        let session = suppliedSession ?? makeSession(isLocal: config.isLocal)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        return try await withTaskCancellationHandler {
            let capabilities = try await LocalLLMCapabilities.discover(config: config, session: session)
            guard var body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
                throw LLMError.parseError
            }
            if config.isLocal { body["stream"] = true }
            if let off = capabilities.reasoningOffValue { body["reasoning_effort"] = off }
            if capabilities.supportsJSONSchema {
                body["response_format"] = responseFormat
                body["stream_options"] = ["include_usage": true]
                if var messages = body["messages"] as? [[String: Any]],
                   let system = messages.first?["content"] as? String {
                    messages[0]["content"] = system + "\n结构化输出中，没有依据的可选字段填 null，不得编造值。"
                    body["messages"] = messages
                }
            }
            do {
                return try await sendRequest(url: url, config: config, body: body, source: source,
                                             session: session, onProgress: onProgress)
            } catch LLMError.apiError(let status, let message) where shouldRetryWithoutSchema(
                status: status, message: message, usedSchema: body["response_format"] != nil
            ) {
                // 只对明确拒绝格式参数的服务协商一次，保留已验证的关闭思考参数。
                logger.debug("本地服务拒绝 JSON Schema，移除格式参数重试一次")
                body.removeValue(forKey: "response_format")
                return try await sendRequest(url: url, config: config, body: body, source: source,
                                             session: session, onProgress: onProgress)
            }
        } onCancel: {
            // 每次生产调用独占 session，取消会中断等待响应头、流读取及能力探测。
            session.invalidateAndCancel()
        }
    }

    private static func makeSession(isLocal: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = isLocal ? 180 : 120
        // 流式思考不断到达时，空闲超时不会触发；资源超时保证整次请求仍有上限。
        configuration.timeoutIntervalForResource = isLocal ? 600 : 120
        return URLSession(configuration: configuration)
    }

    private static func sendRequest(
        url: URL, config: LLMConfigSnapshot, body: [String: Any], source: String,
        session: URLSession, onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TodoDocument {
        try Task.checkCancellation()
        // 在实际发送前统一补充系统时间，覆盖文字、OCR 与图片，也覆盖云端重试和
        // Schema 协商重试。放在自定义模板之后，避免模板中的示例日期充当「现在」。
        guard var messages = body["messages"] as? [[String: Any]],
              messages.first?["role"] as? String == "system",
              let prompt = messages.first?["content"] as? String else {
            throw LLMError.parseError
        }
        messages[0]["content"] = prompt + "\n\n" + CurrentTimeService.promptContext()
        var requestBody = body
        requestBody["messages"] = messages

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = config.isLocal ? 180 : 120
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        var state = ResponseState()
        let started = Date()
        do {
            if config.isLocal {
                let (bytes, response) = try await session.bytes(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
                guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
                if http.statusCode != 200 {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    throw LLMError.apiError(statusCode: http.statusCode, message: String(decoding: data, as: UTF8.self))
                }
                if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { state.sawDone = true; break }
                        let previousPhase = state.progress
                        try state.receive(payload: payload, streaming: true)
                        if let phase = state.progress, phase != previousPhase { onProgress(phase) }
                    }
                    // 断流不得把尚未结束的、恰好可解析的 JSON 当作完整结果落盘。
                    guard state.sawDone || state.finishReason != nil else { throw LLMError.invalidResponse }
                } else {
                    // 部分兼容服务忽略 stream=true，仍允许完整的 OpenAI JSON 响应。
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    try state.receive(payload: String(decoding: data, as: UTF8.self), streaming: false)
                }
            } else {
                let (data, response) = try await session.data(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
                guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
                guard http.statusCode == 200 else {
                    throw LLMError.apiError(statusCode: http.statusCode, message: String(decoding: data, as: UTF8.self))
                }
                try state.receive(payload: String(decoding: data, as: UTF8.self), streaming: false)
            }
            try Task.checkCancellation()
            let document = try state.document(model: config.modelName, source: source)
            logDiagnostics(state, elapsed: Date().timeIntervalSince(started))
            return document
        } catch {
            logDiagnostics(state, elapsed: Date().timeIntervalSince(started))
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw state.reasoningCharacters > 0 && state.text.isEmpty
                    ? TodoExtractionError.reasoningTimedOut : TodoExtractionError.requestTimedOut
            }
            throw error
        }
    }

    private static func logDiagnostics(_ state: ResponseState, elapsed: TimeInterval) {
        // 不记录用户文本、思考内容、API Key 或后端原始错误。
        logger.debug("待办请求诊断 elapsed=\(Int(elapsed), privacy: .public)s finish=\(state.finishReason ?? "nil", privacy: .public) textLength=\(state.text.count, privacy: .public) reasoningLength=\(state.reasoningCharacters, privacy: .public) completionTokens=\(state.completionTokens ?? -1, privacy: .public) reasoningTokens=\(state.reasoningTokens ?? -1, privacy: .public)")
    }

    static func shouldRetryWithoutSchema(status: Int, message: String, usedSchema: Bool) -> Bool {
        guard usedSchema, [400, 422, 501].contains(status) else { return false }
        let lower = message.lowercased()
        return ["response_format", "json_schema", "structured output", "json schema"].contains(where: lower.contains)
    }

    static var responseFormat: [String: Any] {
        let properties: [String: Any] = [
            "title": ["type": "string", "minLength": 1],
            "notes": ["type": ["string", "null"]],
            "url": ["type": ["string", "null"]],
            "priority": ["type": ["string", "null"], "enum": ["high", "medium", "low", NSNull()]],
            "dueDate": ["type": ["string", "null"]],
            "alarmOffsetMinutes": ["type": ["integer", "null"], "minimum": 1, "maximum": 43_200]
        ]
        return ["type": "json_schema", "json_schema": [
            "name": "todo_extraction", "strict": true,
            "schema": ["type": "object", "additionalProperties": false, "required": ["items"],
                       "properties": ["items": ["type": "array", "items": [
                        "type": "object", "additionalProperties": false,
                        "properties": properties, "required": properties.keys.sorted()
                       ]]]]
        ]]
    }

    /// 仅累计正文与思考长度，不缓存思考原文；流式与非流式共享归因规则。
    struct ResponseState {
        private var pieces: [String] = []
        private(set) var reasoningCharacters = 0
        private(set) var finishReason: String?
        private(set) var completionTokens: Int?
        private(set) var reasoningTokens: Int?
        private(set) var progress: Progress?
        var sawDone = false
        var text: String { pieces.joined() }

        mutating func receive(payload: String, streaming: Bool) throws {
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil else { throw LLMError.parseError }
            if let usage = json["usage"] as? [String: Any] {
                completionTokens = usage["completion_tokens"] as? Int
                reasoningTokens = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
            }
            guard let choices = json["choices"] as? [[String: Any]] else { throw LLMError.parseError }
            guard let choice = choices.first else {
                if streaming { return } // include_usage 的尾块可以不带 choice
                throw LLMError.parseError
            }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let message = choice[streaming ? "delta" : "message"] as? [String: Any] else {
                if streaming, finishReason != nil { return }
                throw LLMError.parseError
            }
            if let content = message["content"] as? String, !content.isEmpty {
                pieces.append(content)
                progress = .generating
            }
            let reasoning = message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
            reasoningCharacters += reasoning.count
            if progress == nil, !reasoning.isEmpty { progress = .thinking }
        }

        func document(model: String, source: String) throws -> TodoDocument {
            if finishReason == "length" {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reasoningCharacters > 0 {
                    throw LLMError.outputBudgetExhausted
                }
                throw TodoExtractionError.truncatedResult
            }
            guard finishReason == nil || finishReason == "stop" else { throw LLMError.invalidResponse }
            // 兼容把 <think> 放进正文的旧服务；绝不把思考中举例的 JSON 当作最终待办。
            var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var hadThinkingBlock = false
            while content.hasPrefix("<think>") {
                hadThinkingBlock = true
                guard let end = content.range(of: "</think>") else { throw TodoExtractionError.reasoningOnly }
                content = String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !content.isEmpty else {
                throw reasoningCharacters > 0 || hadThinkingBlock ? TodoExtractionError.reasoningOnly : TodoExtractionError.emptyResponse
            }
            return try parseTodoItems(from: content, model: model, source: source)
        }
    }

    // MARK: - JSON 解析

    /// 解析 LLM 返回的 JSON 文本为 TodoDocument
    /// 兼容多种格式：{"items":[...]} / {"todos":[...]} / [...]
    private static func parseTodoItems(
        from contentStr: String,
        model: String,
        source: String
    ) throws -> TodoDocument {
        // 移除可能的 markdown 代码块包裹（```json ... ``` 或 ``` ... ```）
        // 以及前后多余的解释文字，提取首个 JSON 对象/数组
        let cleaned = stripMarkdownCodeFence(contentStr)

        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            // 退一步：尝试从原始内容中提取首个 {...} 或 [...] 片段
            if let extracted = extractFirstJSON(from: contentStr),
               let extractedData = extracted.data(using: .utf8),
               let parsedFallback = try? JSONSerialization.jsonObject(with: extractedData) {
                return try buildTodoDocument(from: parsedFallback, model: model, source: source)
            }
            logger.error("LLM 返回内容不是合法待办 JSON，textLength=\(contentStr.count, privacy: .public)")
            throw TodoExtractionError.invalidJSON
        }

        return try buildTodoDocument(from: parsed, model: model, source: source)
    }

    /// 剥离 markdown 代码块围栏，保留代码块内部内容
    private static func stripMarkdownCodeFence(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            // 移除开头的 ```json / ```{ 等（到第一个换行）
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // 移除结尾的 ```
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// 从可能包含解释文字的字符串中提取首个 JSON 对象或数组
    private static func extractFirstJSON(from raw: String) -> String? {
        let chars = Array(raw)
        let startChars: [Character] = ["{", "["]
        for (index, ch) in chars.enumerated() where startChars.contains(ch) {
            let open = ch
            let close: Character = (open == "{") ? "}" : "]"
            var depth = 0
            var inString = false
            var escaped = false
            for j in index..<chars.count {
                let c = chars[j]
                if escaped {
                    escaped = false
                    continue
                }
                if c == "\\" {
                    escaped = true
                    continue
                }
                if c == "\"" {
                    inString.toggle()
                    continue
                }
                if inString { continue }
                if c == open { depth += 1 }
                else if c == close {
                    depth -= 1
                    if depth == 0 {
                        return String(chars[index...j])
                    }
                }
            }
        }
        return nil
    }

    /// 把解析后的 JSON 对象构造为 TodoDocument
    private static func buildTodoDocument(
        from parsed: Any,
        model: String,
        source: String
    ) throws -> TodoDocument {
        var rawItems: [[String: Any]] = []

        if let array = parsed as? [[String: Any]] {
            rawItems = array
        } else if let dict = parsed as? [String: Any] {
            if let arr = dict["items"] as? [[String: Any]] {
                rawItems = arr
            } else if let arr = dict["todos"] as? [[String: Any]] {
                rawItems = arr
            } else if let arr = dict["tasks"] as? [[String: Any]] {
                rawItems = arr
            } else if dict["title"] as? String != nil {
                // 单个待办对象
                rawItems = [dict]
            }
        }

        if rawItems.isEmpty {
            logger.warning("LLM 返回的待办列表为空")
            throw TodoExtractionError.emptyResult
        }

        let items: [TodoItem] = rawItems.compactMap { item in
            guard let title = (item["title"] as? String ?? item["task"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty else {
                return nil
            }
            let notes = item["notes"] as? String ?? item["note"] as? String ?? item["description"] as? String
            // 相关链接：优先 url，兼容模型可能返回的别名字段
            let urlString = (item["url"] as? String
                ?? item["link"] as? String
                ?? item["relatedUrl"] as? String
                ?? item["related_url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 优先级默认不设：仅当模型明确返回 high/medium/low 时采用
            let priority = (item["priority"] as? String)
                .flatMap { TodoPriority(rawValue: $0.lowercased()) } ?? .none
            let dueDate = parseDate(from: item["dueDate"] ?? item["due_date"] ?? item["deadline"])
            // 提前提醒分钟数：仅当模型明确返回且存在截止时间（提前量需要锚点）时采用，否则不设置
            let alarmOffsetMinutes = parseAlarmOffset(
                from: item["alarmOffsetMinutes"] ?? item["alarm_offset_minutes"]
                    ?? item["earlyReminderMinutes"] ?? item["early_reminder_minutes"],
                requiresDueDate: dueDate
            )

            return TodoItem(
                title: title,
                notes: notes,
                url: (urlString?.isEmpty == false) ? urlString : nil,
                dueDate: dueDate,
                alarmOffsetMinutes: alarmOffsetMinutes,
                priority: priority,
                status: .pending,
                evidenceQuote: item["evidenceQuote"] as? String,
                sourceSeekURL: item["sourceSeekURL"] as? String,
                owner: item["owner"] as? String
            )
        }

        guard !items.isEmpty else {
            throw TodoExtractionError.emptyResult
        }

        return TodoDocument(source: source, model: model, generatedAt: Date(), items: items)
    }

    /// ISO 8601 解析器复用容器：`ISO8601DateFormatter` / `DateFormatter` 构造极重，
    /// 旧实现每解析一条待办的日期就要新建 10 个实例（50 条待办 = 500 次构造），故提为 static 复用。
    ///
    /// 两者的并发承诺并不相同：`DateFormatter` 自 iOS 7 / macOS 10.9 起线程安全，SDK 亦标注为
    /// Sendable，可直接共享（见 plainDateFormatters）；`ISO8601DateFormatter` 在 SDK 中被显式标注为
    /// non-Sendable、头文件也未承诺线程安全，因此在此包一层锁：实例在 init 中构造完即冻结配置，
    /// `date(from:)` 串行访问——复用的性能收益与数据安全同时成立。
    private final class ISO8601DateParsers: @unchecked Sendable {
        private let lock = NSLock()
        private let formatters: [ISO8601DateFormatter]

        init(optionSets: [ISO8601DateFormatter.Options]) {
            formatters = optionSets.map { options in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                return formatter
            }
        }

        /// 依次尝试各配置，返回第一个解析成功的日期
        func date(from text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            for formatter in formatters {
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }

    /// `Options` 是 OptionSet：每个元素本身就是一组配置，不能声明成 `[[Options]]`
    private static let isoDateParsers = ISO8601DateParsers(optionSets: [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
    ])

    /// 复用的常见日期格式解析器（按优先级顺序尝试）
    private static let plainDateFormatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy.MM.dd",
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    /// 尝试解析多种日期格式（含带时区的 ISO 8601、常见中文环境下的日期时间写法）
    private static func parseDate(from value: Any?) -> Date? {
        guard let value = value else { return nil }
        if let date = value as? Date { return date }
        if let timestamp = value as? TimeInterval, timestamp > 0 {
            // 兼容毫秒/秒级时间戳
            return timestamp > 1e12 ? Date(timeIntervalSince1970: timestamp / 1000) : Date(timeIntervalSince1970: timestamp)
        }
        if let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            // 带时区/毫秒的 ISO 8601（如 2026-08-10T09:00:00Z、2026-08-10T09:00:00.000+08:00）
            if let d = isoDateParsers.date(from: str) { return d }
            for f in plainDateFormatters {
                if let d = f.date(from: str) { return d }
            }
        }
        return nil
    }

    /// 解析提前提醒分钟数：接受数字或数字字符串，有效范围 1 分钟～30 天（43_200 分钟）；
    /// 超范围、无法解析，或无截止时间（提前量没有锚点）时返回 nil
    private static func parseAlarmOffset(from value: Any?, requiresDueDate: Date?) -> Int? {
        guard requiresDueDate != nil else { return nil }
        let minutes: Int?
        switch value {
        case let n as NSNumber: minutes = n.intValue
        case let s as String: minutes = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: minutes = nil
        }
        guard let m = minutes, (1...43_200).contains(m) else { return nil }
        return m
    }

    // MARK: - Prompt

    /// 非会议内容的待办约束条款（追加在 systemPrompt 后，输出格式与安全要求沿用同一套）
    static let nonMeetingClause = """
    ## 内容类型特别说明
    本次内容已确认不是会议（可能是课程、讲座、培训演示等）：只提取其中明确提到的个人任务、练习或后续事项；
    禁止把知识点、章节或讨论要点包装成行动项，禁止虚构负责人与决议式表述；
    没有明确可执行事项时按格式返回空 items 数组。
    """

    /// 待办拆解内置提示词（保留给「恢复默认」对照）。
    /// 运行期实际使用 `PromptTemplateStore.resolved(.todoExtraction)`，可能被用户自定义覆盖。
    static var systemPrompt: String { PromptTemplateKind.todoExtraction.defaultText }

    private static func userPrompt(content: String) -> String {
        "请从以下内容中提取待办事项，并把其中提到的截止日期/时间解析为 dueDate：\n\n<<<待处理内容开始>>>\n\(content)\n<<<待处理内容结束>>>"
    }
}

// MARK: - 错误类型

enum TodoExtractionError: LocalizedError, Equatable {
    case invalidJSON
    case emptyResult
    case emptyResponse
    case reasoningOnly
    case truncatedResult
    case reasoningTimedOut
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidJSON:   return String(localized: "LLM 返回的内容无法解析为待办列表，请稍后重试或更换模型")
        case .emptyResult:   return String(localized: "未能从内容中提取到待办事项")
        case .emptyResponse: return String(localized: "模型返回了空正文，请检查模型设置后重试。")
        case .reasoningOnly: return String(localized: "模型只返回了思考内容，尚未生成待办。请在本地服务中关闭思考模式后重试。")
        case .truncatedResult: return String(localized: "待办输出已被截断，未保存不完整结果。请缩短输入或调整模型输出上限后重试。")
        case .reasoningTimedOut: return String(localized: "模型持续思考，待办生成已超时。请在本地服务中关闭思考模式后重试。")
        case .requestTimedOut: return String(localized: "待办生成超时，请检查模型服务或缩短输入后重试。")
        }
    }
}
