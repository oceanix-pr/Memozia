import Foundation
import os.log

/// 本地 LLM 从单条转写中提取出的一条敏感信息
struct PIIExtractedEntry: Sendable, Equatable {
    let text: String
    let category: PIICategory
}

/// PII 扫描服务：调用**本地**大模型逐条分析转写记录，提取符合去标识化条件的敏感词
///
/// 安全约束：扫描只允许本地模型且端点为本机回环，避免把含敏感信息的
/// 原始转写发送到云端——这正是去标识化要防护的对象。
enum PIIScanService {

    private static let logger = Logger(subsystem: "app.memozia", category: "PIIScan")

    /// 单条转写送入 LLM 的最大字符数
    static let maxInputCharacters = 20_000

    /// 提取 system prompt：严格限定输出格式，便于解析
    private static let systemPrompt = """
    你是敏感信息识别助手。请从用户提供的会议转写文本中找出所有需要去标识化的敏感信息，包括：
    公司名、人员姓名、品牌名、国家名、地区名、城市名、账号、密码、手机号、身份证号、邮箱，以及其他明显敏感的专有名称。

    输出要求：
    - 每行一条，格式：类别|内容
    - 类别只能是：公司名、人员姓名、品牌名、地区、账号、密码、手机号、身份证号、邮箱、其他
    - 内容必须是原文中出现的完整词语，不要解释、不要编号、不要输出其他任何文字
    - 没有发现时只输出：无
    """

    /// 对单条转写文本执行敏感信息提取（非流式）
    /// - Throws: LLMError（URL 非法/请求失败/解析失败）；调用方通常按条目容错处理
    static func extract(
        from content: String,
        config: LLMConfigSnapshot
    ) async throws -> [PIIExtractedEntry] {
        guard config.isLocal else {
            // 防御：扫描绝不允许走云端模型
            throw LLMError.invalidURL
        }
        guard let url = URL(string: config.chatCompletionsURL), EndpointPolicy.trust(for: url) == .loopback else {
            throw LLMError.invalidURL
        }
        try LLMService.validateSecureURL(for: config)
        try Task.checkCancellation()

        let capped = content.count > maxInputCharacters
            ? String(content.prefix(maxInputCharacters))
            : content

        let requestBody: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": capped]
            ],
            "stream": false,
            "temperature": 0.0,
            "max_tokens": 65536
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentStr = message["content"] as? String else {
            logger.error("PII 扫描响应解析失败：无法找到 choices[0].message.content")
            throw LLMError.parseError
        }

        return parseEntries(from: contentStr)
    }

    /// 解析 LLM 返回的“类别|内容”行为结构化条目
    nonisolated static func parseEntries(from response: String) -> [PIIExtractedEntry] {
        var entries: [PIIExtractedEntry] = []
        var seen = Set<String>()

        for rawLine in response.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "无" { continue }
            // 去掉 markdown 列表/代码块残留
            if line.hasPrefix("```") { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            // 支持 类别|内容 / 类别：内容 / 类别:内容
            var categoryPart = ""
            var textPart = ""
            if let range = line.range(of: "|") {
                categoryPart = String(line[..<range.lowerBound])
                textPart = String(line[range.upperBound...])
            } else if let range = line.range(of: "：") {
                categoryPart = String(line[..<range.lowerBound])
                textPart = String(line[range.upperBound...])
            } else if let range = line.range(of: ":") {
                categoryPart = String(line[..<range.lowerBound])
                textPart = String(line[range.upperBound...])
            } else {
                continue
            }

            let text = textPart
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
            guard text.count >= 2, text.count <= 30,
                  !text.contains("["), !text.contains("|"),
                  seen.insert(text).inserted else { continue }

            entries.append(PIIExtractedEntry(
                text: text,
                category: categoryFromLLMLabel(categoryPart)
            ))
        }
        return entries
    }

    /// LLM 输出的类别标签 → PIICategory（关键词匹配，未知归入其他）
    private static func categoryFromLLMLabel(_ label: String) -> PIICategory {
        if label.contains("手机") || label.contains("电话") { return .phone }
        if label.contains("身份证") || label.contains("证件") { return .idcard }
        if label.contains("邮箱") || label.contains("邮件") { return .email }
        if label.contains("密码") { return .password }
        if label.contains("账号") || label.contains("账户") { return .account }
        if label.contains("公司") || label.contains("企业") { return .company }
        if label.contains("品牌") { return .brand }
        if label.contains("姓名") || label.contains("人员") || label.contains("人名") { return .person }
        if label.contains("国家") || label.contains("地区") || label.contains("城市") || label.contains("地点") { return .location }
        return .other
    }
}
