import Foundation

/// 界面与 PDF 共用的块结构。只携带值，可在后台解析并跨 actor 传递。
indirect enum TranscriptBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletItem(text: String, depth: Int = 0, checked: Bool? = nil)
    case numberedItem(number: Int, text: String, depth: Int = 0)
    case codeBlock(text: String)
    case quote(blocks: [TranscriptBlock])
    case table(MarkdownTable)
    case divider

    var contentByteCount: Int {
        switch self {
        case .heading(_, let text), .paragraph(let text), .bulletItem(let text, _, _),
             .numberedItem(_, let text, _), .codeBlock(let text):
            return text.utf8.count
        case .quote(let blocks):
            return blocks.reduce(0) { $0 + $1.contentByteCount }
        case .table(let table):
            return table.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count } }
        case .divider:
            return 0
        }
    }
}

struct MarkdownTable: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    /// 首行为表头；空单元格保留，所有行按表头列数补齐或截断。
    let rows: [[String]]
    let alignments: [Alignment]
    var columnCount: Int { alignments.count }
}

/// 转写、总结与 PDF 的统一块解析器。不访问数据库或 UI。
enum TranscriptMarkdownBuilder {
    /// 取消时返回空结果；只有流式后台任务传入取消检查，常规缓存解析始终完整执行。
    static func parseBlocks(_ markdown: String, shouldCancel: @Sendable () -> Bool = { false }) -> [TranscriptBlock] {
        parse(markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"), nesting: 0, shouldCancel: shouldCancel)
    }

    private static func parse(_ markdown: String, nesting: Int, shouldCancel: @Sendable () -> Bool) -> [TranscriptBlock] {
        // 限制引用递归深度，异常生成的内容也不会耗尽调用栈。
        guard nesting < 32 else { return [.paragraph(text: markdown)] }
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [TranscriptBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(text: joinLines(paragraph)))
                paragraph.removeAll(keepingCapacity: true)
            }
        }

        while index < lines.count {
            if shouldCancel() { return [] }
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = openingFence(raw) {
                flushParagraph()
                var code: [String] = []
                index += 1
                while index < lines.count {
                    if shouldCancel() { return [] }
                    let line = lines[index]
                    if closesFence(line, character: fence.character, count: fence.count) {
                        index += 1
                        break
                    }
                    // 只去掉开启围栏自身的缩进，其余代码空白属于原文。
                    let spaces = line.prefix(while: { $0 == " " }).count
                    code.append(String(line.dropFirst(min(spaces, fence.indent))))
                    index += 1
                }
                blocks.append(.codeBlock(text: code.joined(separator: "\n")))
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableCells(raw),
               let separators = tableCells(lines[index + 1]),
               header.count == separators.count,
               let alignments = tableAlignments(separators) {
                flushParagraph()
                var rows = [header]
                index += 2
                while index < lines.count, let cells = tableCells(lines[index]),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    if shouldCancel() { return [] }
                    rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(MarkdownTable(rows: rows, alignments: alignments)))
                continue
            }

            if let level = setextLevel(trimmed), !paragraph.isEmpty {
                blocks.append(.heading(level: level, text: joinLines(paragraph)))
                paragraph.removeAll(keepingCapacity: true)
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    if shouldCancel() { return [] }
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    var content = String(line.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    index += 1
                }
                blocks.append(.quote(blocks: parse(quoted.joined(separator: "\n"), nesting: nesting + 1, shouldCancel: shouldCancel)))
                continue
            }

            if let item = listItem(raw) {
                flushParagraph()
                blocks.append(item)
                index += 1
                // 缩进的普通续行归入当前列表项，保留嵌套列表/围栏供下一轮处理。
                var continuation: [String] = []
                while index < lines.count,
                      indentation(lines[index]) > indentation(raw),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      listItem(lines[index]) == nil,
                      openingFence(lines[index]) == nil {
                    continuation.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                if !continuation.isEmpty {
                    let extra = joinLines(continuation)
                    switch item {
                    case .bulletItem(let text, let depth, let checked):
                        blocks[blocks.count - 1] = .bulletItem(text: softJoin(text, extra), depth: depth, checked: checked)
                    case .numberedItem(let number, let text, let depth):
                        blocks[blocks.count - 1] = .numberedItem(number: number, text: softJoin(text, extra), depth: depth)
                    default: break
                    }
                }
                continue
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let count = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count) else { return nil }
        let rest = line.dropFirst(count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let prefix = text.dropLast(closing)
            if prefix.isEmpty || prefix.last == " " || prefix.last == "\t" {
                text = prefix.trimmingCharacters(in: .whitespaces)
            }
        }
        return (count, text)
    }

    private static func setextLevel(_ line: String) -> Int? {
        if !line.isEmpty && line.allSatisfy({ $0 == "=" }) { return 1 }
        if !line.isEmpty && line.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        return marks.count >= 3 && ["-", "*", "_"].contains(String(marks.prefix(1)))
            && marks.allSatisfy { $0 == marks.first }
    }

    private static func openingFence(_ line: String) -> (character: Character, count: Int, indent: Int)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let text = line.dropFirst(indent)
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let count = text.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        if first == "`" && text.dropFirst(count).contains("`") { return nil }
        return (first, count, indent)
    }

    private static func closesFence(_ line: String, character: Character, count: Int) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let text = line.dropFirst(indent)
        let marks = text.prefix(while: { $0 == character }).count
        return marks >= count && text.dropFirst(marks).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 外围竖线可省略；转义竖线属于单元格内容，而非列分隔符。
    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var hasPipe = false
        var endsWithDelimiter = false
        for character in text {
            if escaped {
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
                endsWithDelimiter = false
            } else if character == "\\" {
                escaped = true
                endsWithDelimiter = false
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                hasPipe = true
                endsWithDelimiter = true
            } else {
                cell.append(character)
                endsWithDelimiter = false
            }
        }
        if escaped { cell.append("\\") }
        guard hasPipe else { return nil }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("|") { cells.removeFirst() }
        if endsWithDelimiter { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(_ cells: [String]) -> [MarkdownTable.Alignment]? {
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            var marks = cell
            let leading = marks.hasPrefix(":")
            let trailing = marks.hasSuffix(":")
            if leading { marks.removeFirst() }
            if trailing && !marks.isEmpty { marks.removeLast() }
            guard !marks.isEmpty, marks.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(trailing ? (leading ? .center : .trailing) : .leading)
        }
        return result.isEmpty ? nil : result
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func listItem(_ line: String) -> TranscriptBlock? {
        let depth = min(16, indentation(line) / 2)
        let body = line.trimmingCharacters(in: .whitespaces)
        if let first = body.first, "-*+".contains(first),
           body.dropFirst().first == " " || body.dropFirst().first == "\t" {
            var text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if text.hasPrefix("[ ]") || text.hasPrefix("[x]") || text.hasPrefix("[X]") {
                let rest = text.dropFirst(3)
                if rest.isEmpty || rest.first == " " || rest.first == "\t" {
                    checked = !text.hasPrefix("[ ]")
                    text = rest.trimmingCharacters(in: .whitespaces)
                }
            }
            return .bulletItem(text: text, depth: depth, checked: checked)
        }
        let digits = body.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let first = rest.first, first == "." || first == ")",
              rest.dropFirst().first == " " || rest.dropFirst().first == "\t" else { return nil }
        return .numberedItem(number: number, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
    }

    private static func joinLines(_ lines: [String]) -> String {
        var result = ""
        var hardBreak = false
        for raw in lines {
            var text = raw.trimmingCharacters(in: .whitespaces)
            let escapedBreak = raw.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
            let nextHardBreak = raw.hasSuffix("  ") || escapedBreak
            if escapedBreak { text = String(text.dropLast()) }
            if result.isEmpty { result = text }
            else { result = hardBreak ? result + "\n" + text : softJoin(result, text) }
            hardBreak = nextHardBreak
        }
        return result
    }

    private static func softJoin(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return left + right }
        return left + (last.isCJKLike || first.isCJKLike ? "" : " ") + right
    }

    /// 片段渲染数据（解密前的最小信息，Sendable 可跨并发域传递）
    struct SegmentData: Sendable {
        let timeRange: String
        /// 片段起始秒数，用于生成点击播放链接（Memozia://seek/<startTime>）
        let startTime: TimeInterval
        let speaker: String?
        let encryptedText: String
    }

    /// 由片段数据解密并构建转写 Markdown（含解析后的块）。
    /// 与 AudioRecording.transcriptMarkdown 规则一致：
    /// 单片段直接返回其文本（编辑后整体即 Markdown），多片段带时间戳与发言人拼接。
    /// 返回的 markdown 为干净版本（时间行无链接），供复制/编辑使用；
    /// blocks 由带链接版本解析而来：时间行含 Memozia://seek/<秒> 链接，
    /// 渲染层复用 AttributedString 既有链接能力实现"点击时间行播放对应录音段"。
    /// 调用方须保证 segments 已按 startTime 升序传入（主线程侧排序，避免后台线程触碰 SwiftData 模型）。
    static func build(from segments: [SegmentData]) -> (markdown: String, blocks: [TranscriptBlock]) {
        if segments.count == 1, let only = segments.first {
            let text = EncryptionService.decryptSafely(only.encryptedText)
            return (text, parseBlocks(text))
        }
        var cleanParts: [String] = []
        var linkedParts: [String] = []
        cleanParts.reserveCapacity(segments.count)
        linkedParts.reserveCapacity(segments.count)
        for segment in segments {
            let text = EncryptionService.decryptSafely(segment.encryptedText)
            var cleanLine = "**\(segment.timeRange)**"
            var linkedLine = "[**\(segment.timeRange)**](Memozia://seek/\(segment.startTime))"
            if let speaker = segment.speaker, !speaker.isEmpty {
                cleanLine += " · **\(speaker)**"
                linkedLine += " · **\(speaker)**"
            }
            cleanLine += "\n\n\(text)"
            linkedLine += "\n\n\(text)"
            cleanParts.append(cleanLine)
            linkedParts.append(linkedLine)
        }
        let cleanMarkdown = cleanParts.joined(separator: "\n\n---\n\n")
        let linkedMarkdown = linkedParts.joined(separator: "\n\n---\n\n")
        return (cleanMarkdown, parseBlocks(linkedMarkdown))
    }
}

/// 转写渲染缓存条目
struct TranscriptCacheEntry: Sendable {
    let markdown: String
    let blocks: [TranscriptBlock]
}

/// 转写渲染缓存（按录音 ID 缓存"解密+拼接+解析"结果）
///
/// 切换列表条目时避免重复解密全部片段与重新解析长 Markdown；
/// 片段发生增删改的写路径须调用 invalidate 使其失效。
///
/// 容量控制：旧实现 `entries` 只增不减（仅显式 invalidate），且取值写成
/// `await store.entries[id]`——跨 actor 边界会先**拷贝整个字典**再取下标，
/// 每命中一次缓存就复制一次全部已缓存转写。现改为：actor 内按下标取值
/// + LRU 淘汰（按明文/块字节数计费，超限逐出最旧）。
enum TranscriptCache {

    private actor Store {
        /// 明文总缓存上限（约 64MB）：长会议转写单条可达几 MB，无上限时
        /// 浏览过的每条录音的整篇 markdown + 解析块会常驻内存
        static let totalCostLimit = 64 * 1024 * 1024
        /// 条目数上限（次要闸门）：避免大量小转写堆积成几百个字典项
        static let countLimit = 24

        private struct Slot {
            let entry: TranscriptCacheEntry
            let cost: Int
            var usedAt: UInt64
        }

        private var slots: [UUID: Slot] = [:]
        private var totalCost = 0
        private var clock: UInt64 = 0

        /// 按下标在 actor 内取值（不再把整字典拷给调用方）并刷新 LRU 时戳
        func entry(for id: UUID) -> TranscriptCacheEntry? {
            guard let slot = slots[id] else { return nil }
            clock += 1
            slots[id] = Slot(entry: slot.entry, cost: slot.cost, usedAt: clock)
            return slot.entry
        }

        func insert(_ entry: TranscriptCacheEntry, for id: UUID) {
            clock += 1
            let cost = Self.estimateCost(of: entry)
            if let old = slots.removeValue(forKey: id) {
                totalCost -= old.cost
            }
            slots[id] = Slot(entry: entry, cost: cost, usedAt: clock)
            totalCost += cost
            evictIfNeeded()
        }

        func remove(_ id: UUID) {
            guard let old = slots.removeValue(forKey: id) else { return }
            totalCost -= old.cost
        }

        /// 代价估算 = markdown 明文 + 各块文本的 UTF8 字节数（两者内容基本重叠，
        /// 块不另外计入会让上限虚高一倍）
        static func estimateCost(of entry: TranscriptCacheEntry) -> Int {
            let blockBytes = entry.blocks.reduce(0) { $0 + $1.contentByteCount }
            return entry.markdown.utf8.count + blockBytes + 64
        }

        private func evictIfNeeded() {
            // 至少保留一条：当前正在看的录音若被自己刚插入的条目逐出，会变成
            // “每次刷新都重建缓存”的更糟循环
            while slots.count > 1, slots.count > Self.countLimit || totalCost > Self.totalCostLimit {
                // 逐出最久未用；已无条目可逐时停手（单条超大也至少保留一条，
                // 否则当前正在看的录音会反复重建缓存）
                guard let oldest = slots.min(by: { $0.value.usedAt < $1.value.usedAt }) else { return }
                totalCost -= oldest.value.cost
                slots.removeValue(forKey: oldest.key)
            }
        }
    }

    private static let store = Store()

    static func entry(for recordingID: UUID) async -> TranscriptCacheEntry? {
        await store.entry(for: recordingID)
    }

    static func insert(entry: TranscriptCacheEntry, for recordingID: UUID) async {
        await store.insert(entry, for: recordingID)
    }

    /// 写路径失效入口（转写完成/片段编辑/撤销/声纹改名等）
    static func invalidate(recordingID: UUID) async {
        await store.remove(recordingID)
    }
}

private extension Character {
    var isCJKLike: Bool {
        unicodeScalars.contains {
            (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
                || (0xFF00...0xFFEF).contains($0.value)
        }
    }
}
