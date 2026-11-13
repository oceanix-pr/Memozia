import SwiftUI

/// 轻量 Markdown 渲染视图，支持标题、列表、粗体、代码等常见格式
///
/// 性能设计：
/// - 可直接消费预解析的 `TranscriptBlock`（后台线程解析+缓存），
///   避免长转写稿在切换录音时于主线程重复解析
/// - 未传 `blocks` 时走 `MarkdownParseCache` 记忆解析：输入未变直接复用上一次结果，
///   不再每次 body 求值都重排整篇文本（见下方注释）
/// - 使用 LazyVStack 懒渲染，仅构建可视区域的块
struct MarkdownView: View {
    let markdown: String
    /// 预解析块（来自 TranscriptCache）；为 nil 时按 markdown 即时解析（带记忆）
    var blocks: [TranscriptBlock]? = nil
    /// 搜索高亮：大小写不敏感地高亮所有匹配片段（为空时不做任何处理）
    var highlightText: String = ""
    /// 高亮背景色（当前定位的匹配可用不同颜色区分）
    var highlightColor: Color = .yellow

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            let resolvedBlocks = blocks ?? MarkdownParseCache.shared.blocks(for: markdown)
            ForEach(resolvedBlocks.indices, id: \.self) { index in
                renderBlock(resolvedBlocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 块级渲染

    @ViewBuilder
    private func renderBlock(_ block: TranscriptBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)

        case .paragraph(let text):
            renderInlineText(text, font: .title3)
                .textSelection(.enabled)

        case .bulletItem(let text, let depth, let checked):
            HStack(alignment: .top, spacing: 6) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? "•")
                    .font(.title3)
                renderInlineText(text, font: .title3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth) * 16)

        case .numberedItem(let number, let text, let depth):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.title3)
                    .fixedSize(horizontal: true, vertical: false)
                renderInlineText(text, font: .title3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth) * 16)

        case .codeBlock(let text):
            Text(attributedInlineText(text, isCode: true))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let quotedBlocks):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
                AnyView(MarkdownView(markdown: "", blocks: quotedBlocks,
                                     highlightText: highlightText, highlightColor: highlightColor))
                    .foregroundStyle(.secondary)
            }

        case .table(let table):
            renderTable(table)

        case .divider:
            Divider()
        }
    }

    private func renderHeading(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        case 5: .headline
        default: .subheadline
        }
        return renderInlineText(text, font: font.bold())
            .textSelection(.enabled)
    }

    private func renderTable(_ table: MarkdownTable) -> some View {
        let widths: [CGFloat] = (0..<table.columnCount).map { column in
            let length = table.rows.map { $0[column].count }.max() ?? 0
            return min(280, max(120, CGFloat(length) * 9))
        }
        return ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            let alignment = tableAlignment(table.alignments[column])
                            renderInlineText(table.rows[row][column], font: row == 0 ? .headline : .body)
                                .textSelection(.enabled)
                                .multilineTextAlignment(table.alignments[column] == .center ? .center :
                                    (table.alignments[column] == .trailing ? .trailing : .leading))
                                .frame(width: widths[column], alignment: alignment)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(8)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(row == 0 ? Color.secondary.opacity(0.12) : Color.clear)
                                .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// 渲染行内格式（粗体、斜体、行内代码），并按需叠加搜索高亮
    private func renderInlineText(_ text: String, font: Font) -> some View {
        Text(attributedInlineText(text))
            .font(font)
    }

    /// 解析行内 Markdown，解析失败回退纯文本，再叠加搜索高亮。
    /// 结果按 (文本, 高亮词, 高亮色) 记忆：块级已有记忆，但行内 `AttributedString(markdown:)`
    /// 与高亮扫描此前在每次 body 求值时对每个可见块重跑，长文档滚动/播放进度刷新时会持续掉帧
    private func attributedInlineText(_ text: String, isCode: Bool = false) -> AttributedString {
        MarkdownInlineCache.shared.attributed(
            text: text,
            highlight: highlightText,
            color: highlightColor,
            isCode: isCode
        ) {
            var attributed: AttributedString
            if !isCode, let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                attributed = parsed
            } else {
                attributed = AttributedString(text)
            }
            highlightMatches(in: &attributed)
            return attributed
        }
    }

    /// 大小写不敏感高亮所有匹配片段：AttributedString 与 String 的字符索引一一对应，
    /// 先在纯文本上定位字符偏移，再映射回 AttributedString 的 Range 应用背景色
    private func highlightMatches(in attributed: inout AttributedString) {
        let needle = highlightText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let needleChars = Array(needle.lowercased())
        let hayChars = Array(String(attributed.characters).lowercased())
        guard !needleChars.isEmpty, hayChars.count >= needleChars.count else { return }

        var positions: [Range<Int>] = []
        var i = 0
        while i + needleChars.count <= hayChars.count {
            if hayChars[i..<(i + needleChars.count)].elementsEqual(needleChars) {
                positions.append(i..<(i + needleChars.count))
                i += needleChars.count // 不重叠匹配
            } else {
                i += 1
            }
        }
        guard !positions.isEmpty else { return }

        for range in positions.reversed() {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: range.upperBound)
            attributed[start..<end].backgroundColor = highlightColor.opacity(0.55)
        }
    }
}

// MARK: - Markdown 解析记忆

/// 多篇文本的有界 LRU 缓存，搜索结果中的多个 MarkdownView 不再互相挤掉唯一槽位。
/// 所有共享状态由 lock 保护，解析在锁外执行，不阻塞其他命中查询。
final class MarkdownParseMemo: @unchecked Sendable {
    private struct Slot {
        let blocks: [TranscriptBlock]
        let cost: Int
        var usedAt: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Slot] = [:]
    private var clock: UInt64 = 0
    private var totalCost = 0
    private let costLimit = 8 * 1024 * 1024

    func blocks(for markdown: String) -> [TranscriptBlock] {
        lock.lock()
        clock += 1
        if var slot = entries[markdown] {
            slot.usedAt = clock
            entries[markdown] = slot
            lock.unlock()
            return slot.blocks
        }
        lock.unlock()

        let blocks = TranscriptMarkdownBuilder.parseBlocks(markdown)
        let cost = markdown.utf8.count + blocks.reduce(0) { $0 + $1.contentByteCount }
        guard cost <= costLimit else { return blocks }
        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[markdown] { return existing.blocks }
        clock += 1
        entries[markdown] = Slot(blocks: blocks, cost: cost, usedAt: clock)
        totalCost += cost
        while entries.count > 32 || totalCost > costLimit {
            guard let oldest = entries.min(by: { $0.value.usedAt < $1.value.usedAt }) else { break }
            totalCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
        return blocks
    }

    func invalidate() {
        lock.lock()
        entries.removeAll()
        totalCost = 0
        lock.unlock()
    }
}

enum MarkdownParseCache {
    /// 进程级单例：MarkdownView 会被多个页面并发创建，记忆必须共享
    static let shared = MarkdownParseMemo()
}

/// 行内解析 + 高亮的记忆（进程级共享）。
///
/// `MarkdownView` 每次 body 求值都会对每个可见块重跑行内 `AttributedString(markdown:)`
/// 与逐字符高亮扫描（成本随文本长度增长），叠加播放进度/流式刷新时形成持续主线程负载。
/// 这里按 (文本, 高亮词, 高亮色) 缓存结果；超过容量上限时整体清空（可见块数量有限，
/// 不会长期膨胀）。
final class InlineTextMemo: @unchecked Sendable {
    private struct Key: Hashable {
        let text: String
        let highlight: String
        let color: Color
        let isCode: Bool
    }

    private let lock = NSLock()
    private var cache: [Key: AttributedString] = [:]
    private let capacity = 512

    func attributed(
        text: String,
        highlight: String,
        color: Color,
        isCode: Bool = false,
        build: () -> AttributedString
    ) -> AttributedString {
        let key = Key(text: text, highlight: highlight, color: color, isCode: isCode)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // 在锁外构建，避免解析期间阻塞其他块；并发重复构建结果一致，可接受
        let value = build()

        lock.lock()
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        lock.unlock()
        return value
    }
}

enum MarkdownInlineCache {
    /// 进程级单例：与块级解析记忆同理，需跨页面共享
    static let shared = InlineTextMemo()
}

/// 流式内容最多每 200ms 在后台解析一次；持续输出时也能显示格式，避免逐 token 主线程解析。
struct StreamingMarkdownView: View {
    let markdown: String
    @State private var latest = ""
    @State private var blocks: [TranscriptBlock] = []

    var body: some View {
        MarkdownView(markdown: "", blocks: blocks)
            .onChange(of: markdown) { _, value in latest = value }
            .task {
                latest = markdown
                var rendered: String?
                while !Task.isCancelled {
                    let snapshot = latest
                    if snapshot != rendered {
                        let parsing = Task.detached(priority: .userInitiated) {
                            TranscriptMarkdownBuilder.parseBlocks(snapshot, shouldCancel: { Task.isCancelled })
                        }
                        let parsed = await withTaskCancellationHandler {
                            await parsing.value
                        } onCancel: {
                            parsing.cancel()
                        }
                        guard !Task.isCancelled else { return }
                        blocks = parsed
                        rendered = snapshot
                    }
                    do { try await Task.sleep(for: .milliseconds(200)) }
                    catch { return }
                }
            }
    }
}

// MARK: - AI 生成内容免责声明

/// AI（LLM）生成内容的统一免责脚注。
///
/// 总结、待办、画面要点与图片笔记总结都由模型生成，可能出错或漏掉细节；
/// 把提示放在内容紧邻的位置，用户读到结果时就能看到，而不是只在隐私政策里声明。
/// 文案走 String Catalog，与隐私政策中那段更完整的说明保持同一口径。
struct AIContentDisclaimer: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.subheadline)
            Text("AI 可能出错，请自行核实重要信息。")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
