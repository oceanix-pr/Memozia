import Foundation

/// 与阅读/PDF 共用块解析器；不改写原笔记，也不调用 LLM。
enum SpeechTextPreparer {
    static func prepare(_ markdown: String, shouldCancel: @Sendable () -> Bool = { false }) -> String {
        spokenBlocks(TranscriptMarkdownBuilder.parseBlocks(markdown, shouldCancel: shouldCancel))
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func spokenBlocks(_ blocks: [TranscriptBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .heading(_, let text), .paragraph(let text), .bulletItem(let text, _, _),
                 .numberedItem(_, let text, _):
                return [inlineText(text)]
            case .quote(let nested): return spokenBlocks(nested)
            case .table(let table):
                guard let header = table.rows.first else { return [] }
                if table.rows.count == 1 { return [header.map(inlineText).joined(separator: "；")] }
                return table.rows.dropFirst().map { row in
                    row.enumerated().compactMap { index, cell -> String? in
                        let value = inlineText(cell)
                        guard !value.isEmpty else { return nil }
                        let key = index < header.count ? inlineText(header[index]) : ""
                        return key.isEmpty ? value : "\(key)：\(value)"
                    }.joined(separator: "；")
                }
            case .codeBlock, .divider: return []
            }
        }
    }

    private static func inlineText(_ text: String) -> String {
        let withoutImages = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^\n]*?\)"#, with: "", options: .regularExpression)
        let plain: String
        if let attributed = try? AttributedString(markdown: withoutImages,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            plain = String(attributed.characters)
        } else {
            plain = withoutImages
        }
        return plain.replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按句末优先切块；无标点长文本按 Character 切分，避免截断 emoji/组合字符。
    /// 分块边界不丢字、不重字，空白留在各块内供系统自然停顿。
    static func chunks(_ text: String, limit: Int = 400) -> [String] {
        let characters = Array(text)
        let limit = max(1, limit)
        let punctuation: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";", "\n"]
        var result: [String] = []
        var start = 0
        while start < characters.count {
            var end = min(start + limit, characters.count)
            if end < characters.count,
               let boundary = (start..<end).last(where: { punctuation.contains(characters[$0]) }),
               boundary >= start + limit / 2 {
                end = boundary + 1
            }
            result.append(String(characters[start..<end]))
            start = end
        }
        return result
    }
}
