import CoreGraphics
import CoreText
import Foundation

/// 把 Markdown 文本排版成分页 PDF（默认 A4），供右键「导出 → .pdf」与单测共用。
///
/// 为什么自己排版，而不是把 SwiftUI 视图截图或交给 WebKit：
/// - `ImageRenderer` 一次只出一张画布，长转写（数万字）会被截断；
/// - `WKWebView.createPDF` 要求视图已挂进窗口、必须回主线程异步等待，而 `fileExporter`
///   只在 `FileDocument.fileWrapper` 里同步要一段 `Data`，套不进这个回调；
/// - 纯 CoreText 排版是同步纯函数，可离线单测，中英日韩靠字形回退自动处理，不引新依赖。
///
/// 块结构与界面共用 `TranscriptMarkdownBuilder`；表格独立排版单元格、边框与跨页表头。
/// `~~删除线~~` 目前只去标记不画线（CoreText 无删除线属性）。
enum MarkdownPDFRenderer {

    // MARK: - 错误

    enum RenderError: LocalizedError {
        case consumerUnavailable
        case contextUnavailable

        var errorDescription: String? {
            switch self {
            case .consumerUnavailable:
                return String(localized: "无法创建 PDF 导出通道，请重试或检查磁盘空间。")
            case .contextUnavailable:
                return String(localized: "无法创建 PDF 画布，请重试。")
            }
        }
    }

    // MARK: - 排版参数

    struct Configuration {
        /// A4 纵向（pt）
        var pageWidth: CGFloat = 595
        var pageHeight: CGFloat = 842
        var marginLeading: CGFloat = 56
        var marginTrailing: CGFloat = 56
        var marginTop: CGFloat = 56
        /// 正文下边界，页码画在这片留白里
        var marginBottom: CGFloat = 64
        var bodyFontSize: CGFloat = 11
        var showsPageNumbers: Bool = true
        /// 首页标题 + PDF 元数据 Title，一般传条目名
        var title: String?

        init() {}

        var contentWidth: CGFloat {
            max(1, pageWidth - marginLeading - marginTrailing)
        }

        var contentHeight: CGFloat {
            max(1, pageHeight - marginTop - marginBottom)
        }

        /// 正文区域。PDF 上下文原点左下，`minY` 即正文下沿（其下是页脚带）
        var contentRect: CGRect {
            CGRect(x: marginLeading, y: marginBottom, width: contentWidth, height: contentHeight)
        }
    }

    // MARK: - 入口

    /// 渲染为 PDF 数据。内容为空时也产出一页，保证导出文件永远可打开。
    static func render(markdown: String, configuration: Configuration = Configuration()) throws -> Data {
        guard configuration.pageWidth.isFinite, configuration.pageHeight.isFinite,
              configuration.bodyFontSize.isFinite, configuration.bodyFontSize > 0,
              configuration.contentWidth.isFinite, configuration.contentHeight.isFinite,
              configuration.contentHeight >= configuration.bodyFontSize * 3 + 24 else {
            throw RenderError.contextUnavailable
        }
        let pages = layout(markdown: markdown, configuration: configuration)

        let sink = NSMutableData()
        guard let consumer = CGDataConsumer(data: sink as CFMutableData) else {
            throw RenderError.consumerUnavailable
        }
        var mediaBox = CGRect(x: 0, y: 0, width: configuration.pageWidth, height: configuration.pageHeight)

        var metadata: [String: Any] = ["Creator": "Memozia"]
        if let title = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            metadata["Title"] = title
        }
        // 文档元数据只能在创建 PDF 上下文时通过 auxiliaryInfo 传入，beginPage 之后再设无效
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw RenderError.contextUnavailable
        }

        for (index, commands) in pages.enumerated() {
            context.beginPage(mediaBox: &mediaBox)
            for command in commands {
                switch command {
                case .text(let setter, let range, let rect):
                    let frame = CTFramesetterCreateFrame(setter, range, CGPath(rect: rect, transform: nil), nil)
                    CTFrameDraw(frame, context)
                case .cell(let rect, let isHeader):
                    context.setFillColor(gray(isHeader ? 0.94 : 1))
                    context.fill(rect)
                    context.setStrokeColor(gray(0.75))
                    context.setLineWidth(0.5)
                    context.stroke(rect)
                }
            }
            if configuration.showsPageNumbers, pages.count > 1 {
                drawPageNumber(index + 1, total: pages.count, configuration: configuration, context: context)
            }
            context.endPage()
        }
        context.closePDF()
        return sink as Data
    }

    /// 单测与预览入口：只产出排版好的富文本，不落 PDF
    static func attributedString(
        from markdown: String,
        configuration: Configuration = Configuration()
    ) -> NSAttributedString {
        let typography = Typography(bodySize: configuration.bodyFontSize, contentWidth: configuration.contentWidth)
        let output = NSMutableAttributedString()

        if let title = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            output.append(NSAttributedString(string: title + "\n", attributes: typography.attributes(
                font: typography.titleFont, color: typography.ink, paragraph: typography.titleParagraph
            )))
        }

        for block in blocks(from: markdown) {
            append(block, to: output, typography: typography, configuration: configuration)
        }
        return output
    }

    // 界面、预解析缓存与 PDF 只使用这一套语法规则。
    typealias Block = TranscriptBlock

    static func blocks(from markdown: String) -> [Block] {
        TranscriptMarkdownBuilder.parseBlocks(markdown)
    }

    // MARK: - 块 → 富文本

    private static func append(
        _ block: Block,
        to output: NSMutableAttributedString,
        typography: Typography,
        configuration: Configuration
    ) {
        switch block {
        case .heading(let level, let text):
            appendInline(text, to: output, font: typography.headingFont(level), color: typography.ink,
                         paragraph: typography.headingParagraph(level), typography: typography)

        case .paragraph(let text):
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: typography.bodyParagraph, typography: typography)

        case .bulletItem(let text, let depth, let checked):
            let paragraph = typography.listParagraph(depth)
            let marker = checked.map { $0 ? "☑  " : "☐  " } ?? (depth.isMultiple(of: 2) ? "•  " : "◦  ")
            output.append(NSAttributedString(string: marker, attributes: typography.attributes(
                font: typography.bodyFont, color: typography.secondary, paragraph: paragraph
            )))
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: paragraph, typography: typography)

        case .numberedItem(let number, let text, let depth):
            let paragraph = typography.listParagraph(depth)
            output.append(NSAttributedString(string: "\(number).  ", attributes: typography.attributes(
                font: typography.bodyFont, color: typography.secondary, paragraph: paragraph
            )))
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: paragraph, typography: typography)

        case .quote(let children):
            for child in children { append(child, to: output, typography: typography, configuration: configuration) }

        case .codeBlock(let text):
            output.append(NSAttributedString(string: text + "\n", attributes: [
                keyFont: typography.monoFont,
                keyForeground: typography.secondary,
                keyParagraph: typography.codeParagraph,
                keyBackground: typography.codeBackground
            ]))

        case .table(let table):
            // 富文本检查入口保留空单元格的位置；实际 PDF 使用下方逐单元格布局。
            for (rowIndex, row) in table.rows.enumerated() {
                appendInline(row.joined(separator: "\t"), to: output,
                             font: rowIndex == 0 ? typography.strongBody : typography.bodyFont,
                             color: typography.ink,
                             paragraph: typography.tableParagraph(isHeader: rowIndex == 0), typography: typography)
            }

        case .divider:
            // 分隔线用 box-drawing 字符拼：实际绘制会发生字体替换（量到的 advance 偏小），
            // 按整宽拼会多出一小截换行。取约 1/3 宽并居中，当作有意为之的短分隔线
            let advance = glyphAdvance(of: "─", font: typography.bodyFont)
            let count = advance > 0
                ? max(12, min(80, Int(configuration.contentWidth * 0.36 / advance)))
                : 20
            output.append(NSAttributedString(string: String(repeating: "─", count: count) + "\n", attributes: [
                keyFont: typography.bodyFont,
                keyForeground: typography.faint,
                keyParagraph: typography.ruleParagraph
            ]))
        }
    }

    // MARK: - 行内标记

    /// 块级入口：解析行内标记并补段落结束符。
    /// 换行只在块这一层加，递归调用 `appendInlineContent` 不能再加，
    /// 否则 `**粗体**：正文` 会在粗体后被断成两行。
    private static func appendInline(
        _ text: String,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        appendInlineContent(text, to: output, font: font, color: color, paragraph: paragraph, typography: typography)
        output.append(NSAttributedString(string: "\n", attributes: typography.attributes(
            font: font, color: color, paragraph: paragraph
        )))
    }

    /// 支持 `**粗体**`、`__粗体__`、`*斜体*`、`` `代码` ``、`~~删除线~~`（去标记不画线）、
    /// `[文字](链接)`、`![替代文字](链接)`。
    /// 找不到闭合标记时按原文输出，避免会议文本里一个裸 `*` 把后面整段吞成斜体。
    private static func appendInlineContent(
        _ text: String,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        var rest = Substring(text)
        while !rest.isEmpty {
            if let link = matchLink(in: rest) {
                appendPlain(rest[..<link.range.lowerBound], to: output, font: font, color: color,
                            paragraph: paragraph, typography: typography)
                let label = String(link.label)
                output.append(NSAttributedString(string: label.isEmpty ? " " : label, attributes: typography.attributes(
                    font: font,
                    color: link.isImage ? typography.secondary : typography.accent,
                    paragraph: paragraph,
                    underline: link.isImage ? nil : true
                )))
                // 链接文字与 URL 不同时补一段灰色 URL，否则导出后链接信息就丢了
                if !link.isImage, !link.url.isEmpty, link.url != label {
                    appendPlain(Substring(" (\(link.url))"), to: output, font: font,
                                color: typography.faint, paragraph: paragraph, typography: typography)
                }
                rest = Substring(rest[link.range.upperBound...])
                continue
            }

            guard let mark = nextMark(in: rest) else {
                appendPlain(rest, to: output, font: font, color: color, paragraph: paragraph, typography: typography)
                return
            }

            appendPlain(rest[..<mark.range.lowerBound], to: output, font: font, color: color,
                        paragraph: paragraph, typography: typography)
            let after = Substring(rest[mark.range.upperBound...])
            guard let closing = after.range(of: mark.token, options: [],
                                            range: after.startIndex..<after.endIndex, locale: nil),
                  closing.lowerBound != after.startIndex else {
                // 无闭合标记：原样输出该标记，继续处理后面的内容
                appendPlain(Substring(mark.token), to: output, font: font, color: color,
                            paragraph: paragraph, typography: typography)
                rest = after
                continue
            }
            let inner = String(after[..<closing.lowerBound])
            switch mark.kind {
            case .code:
                output.append(NSAttributedString(string: inner, attributes: [
                    keyFont: typography.monoFont,
                    keyForeground: typography.secondary,
                    keyParagraph: paragraph,
                    keyBackground: typography.codeBackground
                ]))
            case .bold, .boldAlt:
                appendInlineContent(inner, to: output, font: typography.boldish(font), color: color,
                                    paragraph: paragraph, typography: typography)
            case .italic, .italicAlt:
                appendInlineContent(inner, to: output, font: typography.italicize(font), color: color,
                                    paragraph: paragraph, typography: typography)
            case .strike:
                appendInlineContent(inner, to: output, font: font, color: typography.secondary,
                                    paragraph: paragraph, typography: typography)
            }
            rest = Substring(after[closing.upperBound...])
        }
    }

    private static func appendPlain(
        _ slice: Substring,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        guard !slice.isEmpty else { return }
        output.append(NSAttributedString(string: String(slice), attributes: typography.attributes(
            font: font, color: color, paragraph: paragraph
        )))
    }

    private enum InlineMark: String, CaseIterable {
        case bold = "**"
        case boldAlt = "__"
        case italic = "*"
        case italicAlt = "_"
        case code = "`"
        case strike = "~~"

        var token: String { rawValue }

        /// 紧贴 ASCII 字母/数字时按原文处理，保护 `snake_case`、`__init__`、`10*5`；
        /// 中日韩字符相邻不算「单词粘连」，`*强调*` 这类要照常生效
        var requiresWordBoundaryGuard: Bool {
            switch self {
            case .italic, .italicAlt, .boldAlt: return true
            case .bold, .code, .strike: return false
            }
        }
    }

    /// 取最先出现的标记；同位置长标记优先（`**` 先于 `*`）
    private static func nextMark(in text: Substring) -> (kind: InlineMark, token: String, range: Range<Substring.Index>)? {
        var best: (kind: InlineMark, token: String, range: Range<Substring.Index>)?
        for mark in InlineMark.allCases {
            var searchFrom = text.startIndex
            while let range = text.range(of: mark.token, options: [], range: searchFrom..<text.endIndex, locale: nil) {
                let blocked = mark.requiresWordBoundaryGuard
                    && (isASCIIWordCharacter(before: range.lowerBound, in: text)
                        || isASCIIWordCharacter(after: range.upperBound, in: text))
                if !blocked {
                    let beatsCurrent: Bool
                    if let current = best {
                        beatsCurrent = range.lowerBound < current.range.lowerBound
                            || (range.lowerBound == current.range.lowerBound && mark.token.count > current.token.count)
                    } else {
                        beatsCurrent = true
                    }
                    if beatsCurrent { best = (mark, mark.token, range) }
                    break
                }
                let next = text.index(after: range.lowerBound)
                if next >= text.endIndex { break }
                searchFrom = next
            }
        }
        return best
    }

    private static func isASCIIWordCharacter(before index: Substring.Index, in text: Substring) -> Bool {
        guard index != text.startIndex else { return false }
        return isASCIIWord(text[text.index(before: index)])
    }

    private static func isASCIIWordCharacter(after index: Substring.Index, in text: Substring) -> Bool {
        guard index < text.endIndex else { return false }
        return isASCIIWord(text[index])
    }

    private static func isASCIIWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// `[文字](URL)`；前缀 `!` 视为图片，只保留替代文字
    private static func matchLink(in text: Substring) -> (label: Substring, url: String, range: Range<Substring.Index>, isImage: Bool)? {
        var searchFrom = text.startIndex
        while let bracket = text.range(of: "[", options: [], range: searchFrom..<text.endIndex, locale: nil)?.lowerBound {
            let isImage = bracket != text.startIndex && text[text.index(before: bracket)] == "!"
            let labelStart = text.index(after: bracket)
            guard let closeBracket = text.range(of: "]", options: [], range: labelStart..<text.endIndex, locale: nil)?.lowerBound else {
                searchFrom = text.index(after: bracket)
                continue
            }
            let parenStart = text.index(after: closeBracket)
            guard parenStart < text.endIndex, text[parenStart] == "(",
                  let closeParen = text.range(of: ")", options: [], range: parenStart..<text.endIndex, locale: nil)?.upperBound else {
                searchFrom = text.index(after: bracket)
                continue
            }
            let rawLabel = text[labelStart..<closeBracket]
            let url = String(text[text.index(after: parenStart)..<text.index(before: closeParen)])
                .trimmingCharacters(in: .whitespaces)
            // 图片的 `!` 一并纳入 range，输出时不留下孤立感叹号
            let start = isImage ? text.index(before: bracket) : bracket
            return (rawLabel.isEmpty ? Substring(" ") : rawLabel, url, start..<closeParen, isImage)
        }
        return nil
    }

    // MARK: - 分页

    private enum DrawCommand {
        case text(CTFramesetter, CFRange, CGRect)
        case cell(CGRect, isHeader: Bool)
    }

    /// 先排版后绘制，页码能得到准确总页数。普通文本、引用和表格共享同一页游标。
    private static func layout(markdown: String, configuration: Configuration) -> [[DrawCommand]] {
        let content = configuration.contentRect
        let typography = Typography(bodySize: configuration.bodyFontSize, contentWidth: content.width)
        var pages: [[DrawCommand]] = [[]]
        var y = content.maxY
        var pending = NSMutableAttributedString()

        func newPage() {
            pages.append([])
            y = content.maxY
        }

        func placeText(_ attributed: NSAttributedString, inset: CGFloat = 0) {
            guard attributed.length > 0 else { return }
            let setter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            var location = 0
            while location < attributed.length {
                let available = y - content.minY
                if available < configuration.bodyFontSize * 2, !pages[pages.count - 1].isEmpty {
                    newPage()
                    continue
                }
                let rect = CGRect(x: content.minX + inset, y: content.minY,
                                  width: max(1, content.width - inset), height: max(1, available))
                let frame = CTFramesetterCreateFrame(setter, CFRangeMake(location, 0), CGPath(rect: rect, transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    // 极窄配置也要推进；字形兜底用独立行，不让长不可断词导致循环停滞。
                    let length = (attributed.string as NSString).rangeOfComposedCharacterSequence(at: location).length
                    let fragment = attributed.attributedSubstring(from: NSRange(location: location, length: length))
                    let line = CTLineCreateWithAttributedString(fragment)
                    let width = max(rect.width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 1)
                    let fallback = CGRect(x: rect.minX, y: y - configuration.bodyFontSize * 2,
                                          width: width, height: configuration.bodyFontSize * 2)
                    let fragmentSetter = CTFramesetterCreateWithAttributedString(fragment)
                    pages[pages.count - 1].append(.text(fragmentSetter, CFRangeMake(0, length), fallback))
                    location += length
                    y -= configuration.bodyFontSize * 2
                    continue
                }
                let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, visible, nil,
                    CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
                let height = min(available, ceil(size.height) + 1)
                let placed = CGRect(x: rect.minX, y: y - height, width: rect.width, height: height)
                pages[pages.count - 1].append(.text(setter, visible, placed))
                y -= height
                location += visible.length
                if location < attributed.length { newPage() }
            }
        }

        func flushText() {
            placeText(pending)
            pending = NSMutableAttributedString()
        }

        func placeTable(_ table: MarkdownTable, inset: CGFloat) {
            guard table.columnCount > 0, !table.rows.isEmpty else { return }
            let columnWidth = max(1, (content.width - inset) / CGFloat(table.columnCount))
            let padding = min(6, columnWidth / 8)
            let cellWidth = max(1, columnWidth - padding * 2)
            let minimumHeight = max(16, configuration.bodyFontSize * 1.5 + padding * 2)

            func prepare(_ row: [String], isHeader: Bool) -> [(NSAttributedString, CTFramesetter, CGFloat)] {
                row.enumerated().map { column, text in
                    let alignment: CTTextAlignment = switch table.alignments[column] {
                    case .leading: .left
                    case .center: .center
                    case .trailing: .right
                    }
                    let paragraph = makeParagraphStyle(alignment: alignment, lineSpacing: 2, tailIndent: cellWidth)
                    let value = NSMutableAttributedString()
                    appendInlineContent(text.isEmpty ? " " : text, to: value,
                                        font: isHeader ? typography.strongBody : typography.bodyFont,
                                        color: typography.ink, paragraph: paragraph, typography: typography)
                    let setter = CTFramesetterCreateWithAttributedString(value)
                    let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), nil,
                        CGSize(width: cellWidth, height: .greatestFiniteMagnitude), nil)
                    return (value, setter, max(minimumHeight, ceil(size.height) + padding * 2 + 1))
                }
            }

            let header = prepare(table.rows[0], isHeader: true)
            let headerHeight = header.map { $0.2 }.max() ?? minimumHeight
            // 巨大表头本身需要分页时不重复，避免表头占满每页而正文无法推进。
            let repeatsHeader = headerHeight < content.height / 3

            func drawFragment(_ cells: [(NSAttributedString, CTFramesetter, CGFloat)],
                              locations: inout [Int], height: CGFloat, isHeader: Bool) {
                for column in cells.indices {
                    let rect = CGRect(x: content.minX + inset + CGFloat(column) * columnWidth,
                                      y: y - height, width: columnWidth, height: height)
                    pages[pages.count - 1].append(.cell(rect, isHeader: isHeader))
                    let (text, setter, _) = cells[column]
                    guard locations[column] < text.length else { continue }
                    let inner = rect.insetBy(dx: padding, dy: padding)
                    let frame = CTFramesetterCreateFrame(setter, CFRangeMake(locations[column], 0),
                                                        CGPath(rect: inner, transform: nil), nil)
                    let range = CTFrameGetVisibleStringRange(frame)
                    if range.length > 0 {
                        pages[pages.count - 1].append(.text(setter, range, inner))
                        locations[column] += range.length
                    } else {
                        // 超窄列也保留字符；不能把排不下误当成该格已完成。
                        let length = (text.string as NSString).rangeOfComposedCharacterSequence(at: locations[column]).length
                        let fragment = text.attributedSubstring(from: NSRange(location: locations[column], length: length))
                        let line = CTLineCreateWithAttributedString(fragment)
                        let width = max(inner.width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 1)
                        let fallback = CGRect(x: inner.minX, y: inner.minY, width: width, height: inner.height)
                        pages[pages.count - 1].append(.text(CTFramesetterCreateWithAttributedString(fragment),
                                                          CFRangeMake(0, length), fallback))
                        locations[column] += length
                    }
                }
                y -= height
            }

            // 表头至少与第一条数据一起出现，避免页尾只剩一个孤立表头。
            let firstRowHeight = table.rows.count > 1
                ? prepare(table.rows[1], isHeader: false).map { $0.2 }.max() ?? minimumHeight : 0
            let firstFragment = firstRowHeight <= content.height - headerHeight ? firstRowHeight : minimumHeight
            let startHeight = headerHeight + firstFragment
            if startHeight <= content.height, y - content.minY < startHeight,
               !pages[pages.count - 1].isEmpty { newPage() }

            for (rowIndex, row) in table.rows.enumerated() {
                let cells = rowIndex == 0 ? header : prepare(row, isHeader: false)
                let desired = cells.map { $0.2 }.max() ?? minimumHeight
                let fullHeight = content.height - (repeatsHeader && rowIndex > 0 ? headerHeight : 0)
                let needsFreshPage = desired <= fullHeight && y - content.minY < desired
                    || y - content.minY < minimumHeight
                if needsFreshPage {
                    if !pages[pages.count - 1].isEmpty { newPage() }
                    if rowIndex > 0 && repeatsHeader {
                        var offsets = Array(repeating: 0, count: header.count)
                        drawFragment(header, locations: &offsets, height: headerHeight, isHeader: true)
                    }
                }
                var offsets = Array(repeating: 0, count: cells.count)
                while cells.indices.contains(where: { offsets[$0] < cells[$0].0.length }) {
                    if y - content.minY < minimumHeight {
                        newPage()
                        if rowIndex > 0 && repeatsHeader {
                            var headerOffsets = Array(repeating: 0, count: header.count)
                            drawFragment(header, locations: &headerOffsets, height: headerHeight, isHeader: true)
                        }
                    }
                    // 续页按剩余文本测量，短单元格结束后保持空白，不再重复其内容。
                    let remainingHeight = cells.indices.map { column -> CGFloat in
                        guard offsets[column] < cells[column].0.length else { return minimumHeight }
                        let size = CTFramesetterSuggestFrameSizeWithConstraints(cells[column].1,
                            CFRangeMake(offsets[column], cells[column].0.length - offsets[column]), nil,
                            CGSize(width: cellWidth, height: .greatestFiniteMagnitude), nil)
                        return max(minimumHeight, ceil(size.height) + padding * 2 + 1)
                    }.max() ?? minimumHeight
                    drawFragment(cells, locations: &offsets,
                                 height: min(remainingHeight, max(minimumHeight, y - content.minY)), isHeader: rowIndex == 0)
                }
            }
            y -= 8
        }

        func placeBlocks(_ blocks: [Block], inset: CGFloat = 0) {
            for block in blocks {
                switch block {
                case .table(let table):
                    flushText()
                    placeTable(table, inset: inset)
                case .quote(let children):
                    flushText()
                    placeBlocks(children, inset: min(inset + 14, content.width / 2))
                default:
                    if inset == 0 {
                        append(block, to: pending, typography: typography, configuration: configuration)
                    } else {
                        let value = NSMutableAttributedString()
                        let quoteTypography = Typography(bodySize: configuration.bodyFontSize, contentWidth: max(1, content.width - inset))
                        append(block, to: value, typography: quoteTypography, configuration: configuration)
                        placeText(value, inset: inset)
                    }
                }
            }
        }

        if let title = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            pending.append(NSAttributedString(string: title + "\n", attributes: typography.attributes(
                font: typography.titleFont, color: typography.ink, paragraph: typography.titleParagraph)))
        }
        placeBlocks(blocks(from: markdown))
        flushText()
        return pages
    }

    private static func drawPageNumber(
        _ page: Int,
        total: Int,
        configuration: Configuration,
        context: CGContext
    ) {
        let typography = Typography(bodySize: configuration.bodyFontSize, contentWidth: configuration.contentWidth)
        // 页码走本地化（含 RTL 语言），不再用 "\(page) / \(total)" 的西方数字硬拼接
        let pageText = String(format: String(localized: "第 %lld 页，共 %lld 页"), page, total)
        let attributed = NSAttributedString(string: pageText, attributes: typography.attributes(
            font: typography.footerFont, color: typography.faint, paragraph: typography.footerParagraph
        ))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let rect = CGRect(x: configuration.marginLeading, y: 28, width: configuration.contentWidth, height: 16)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    // MARK: - 字体 / 颜色 / 段落样式

    private static let keyFont = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let keyForeground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let keyParagraph = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let keyUnderline = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    private static let keyBackground = NSAttributedString.Key(kCTBackgroundColorAttributeName as String)

    private static func uiFont(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func gray(_ white: CGFloat, _ blueBoost: CGFloat = 0) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [white, white, white + blueBoost, 1])
            ?? CGColor(gray: white, alpha: 1)
    }

    private static func glyphAdvance(of character: String.Element, font: CTFont) -> CGFloat {
        var utf16 = Array(String(character).utf16)
        var glyph = CGGlyph(0)
        let matched = utf16.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return CTFontGetGlyphsForCharacters(font, base, &glyph, 1)
        }
        guard matched else { return 0 }
        var advance = CGSize.zero
        let maxAdvance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return max(maxAdvance, advance.width)
    }

    /// 一套排版尺寸与颜色：字号全部相对 bodySize，改一处即可整体缩放；
    /// 段落样式的 `tailIndent` 取正文宽度，否则 CoreText 的居中/右对齐会退化到左边缘
    struct Typography {
        let bodySize: CGFloat

        let ink: CGColor
        let secondary: CGColor
        let faint: CGColor
        let accent: CGColor
        let codeBackground: CGColor

        let bodyFont: CTFont
        let strongBody: CTFont
        let monoFont: CTFont
        let titleFont: CTFont
        let footerFont: CTFont
        let titleParagraph: CTParagraphStyle
        let bodyParagraph: CTParagraphStyle
        let quoteParagraph: CTParagraphStyle
        let codeParagraph: CTParagraphStyle
        let ruleParagraph: CTParagraphStyle
        let footerParagraph: CTParagraphStyle

        private let headingFonts: [CTFont]
        private let headingParagraphs: [CTParagraphStyle]
        private let listParagraphs: [CTParagraphStyle]
        private let tableHeaderParagraph: CTParagraphStyle
        private let tableBodyParagraph: CTParagraphStyle

        init(bodySize: CGFloat, contentWidth: CGFloat) {
            self.bodySize = bodySize

            func style(
                alignment: CTTextAlignment = .left,
                spacingBefore: CGFloat = 0,
                spacingAfter: CGFloat = 0,
                lineSpacing: CGFloat = 0,
                firstLineHeadIndent: CGFloat = 0,
                headIndent: CGFloat = 0
            ) -> CTParagraphStyle {
                MarkdownPDFRenderer.makeParagraphStyle(
                    alignment: alignment,
                    spacingBefore: spacingBefore,
                    spacingAfter: spacingAfter,
                    lineSpacing: lineSpacing,
                    firstLineHeadIndent: firstLineHeadIndent,
                    headIndent: headIndent,
                    tailIndent: contentWidth
                )
            }

            ink = MarkdownPDFRenderer.gray(0.10, 0.02)
            secondary = MarkdownPDFRenderer.gray(0.37, 0.02)
            faint = MarkdownPDFRenderer.gray(0.58)
            accent = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.13, 0.36, 0.78, 1])
                ?? MarkdownPDFRenderer.gray(0.35)
            codeBackground = MarkdownPDFRenderer.gray(0.94)

            let base = MarkdownPDFRenderer.uiFont(size: bodySize)
            bodyFont = base
            strongBody = MarkdownPDFRenderer.boldTrait(base, size: bodySize)
            titleFont = MarkdownPDFRenderer.boldTrait(base, size: bodySize + 7)
            footerFont = MarkdownPDFRenderer.uiFont(size: max(6, bodySize - 2))
            monoFont = CTFontCreateWithName("Menlo" as CFString, max(6, bodySize - 0.5), nil)
            headingFonts = (1...6).map { level in
                MarkdownPDFRenderer.boldTrait(base, size: MarkdownPDFRenderer.headingSize(bodySize, level))
            }

            titleParagraph = style(spacingAfter: 10, lineSpacing: 2)
            headingParagraphs = (1...6).map { level in
                style(spacingBefore: level <= 2 ? 16 : 12, spacingAfter: 5, lineSpacing: 2)
            }
            bodyParagraph = style(spacingAfter: 9, lineSpacing: 4)
            quoteParagraph = style(spacingAfter: 9, lineSpacing: 3, firstLineHeadIndent: 14, headIndent: 14)
            codeParagraph = style(spacingBefore: 4, spacingAfter: 10, firstLineHeadIndent: 14, headIndent: 14)
            ruleParagraph = style(alignment: .center, spacingBefore: 8, spacingAfter: 8)
            footerParagraph = style(alignment: .center)
            listParagraphs = (0...4).map { depth in
                style(spacingAfter: 4, lineSpacing: 3, headIndent: 14 + CGFloat(depth) * 14)
            }
            tableHeaderParagraph = style(spacingBefore: 4, spacingAfter: 3, lineSpacing: 2, headIndent: 6)
            tableBodyParagraph = style(spacingAfter: 3, lineSpacing: 2, headIndent: 6)
        }

        func headingFont(_ level: Int) -> CTFont {
            headingFonts[level - 1 < 0 ? 0 : min(headingFonts.count - 1, level - 1)]
        }

        func headingParagraph(_ level: Int) -> CTParagraphStyle {
            headingParagraphs[level - 1 < 0 ? 0 : min(headingParagraphs.count - 1, level - 1)]
        }

        func listParagraph(_ depth: Int) -> CTParagraphStyle {
            listParagraphs[max(0, min(listParagraphs.count - 1, depth))]
        }

        func tableParagraph(isHeader: Bool) -> CTParagraphStyle {
            isHeader ? tableHeaderParagraph : tableBodyParagraph
        }

        /// 标题等本身已是粗体的位置不重复加粗，只提升字重
        func boldish(_ font: CTFont) -> CTFont {
            MarkdownPDFRenderer.boldTrait(font, size: CTFontGetSize(font))
        }

        func italicize(_ font: CTFont) -> CTFont {
            MarkdownPDFRenderer.italicTrait(font, size: CTFontGetSize(font))
        }

        func attributes(
            font: CTFont,
            color: CGColor,
            paragraph: CTParagraphStyle,
            underline: Bool? = nil
        ) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                MarkdownPDFRenderer.keyFont: font,
                MarkdownPDFRenderer.keyForeground: color,
                MarkdownPDFRenderer.keyParagraph: paragraph
            ]
            if underline == true {
                attributes[MarkdownPDFRenderer.keyUnderline] = CTUnderlineStyle.single.rawValue
            }
            return attributes
        }
    }

    private static func headingSize(_ body: CGFloat, _ level: Int) -> CGFloat {
        switch level {
        case 1: return body + 5
        case 2: return body + 3
        case 3: return body + 1.5
        case 4: return body + 0.5
        default: return body
        }
    }

    private static func boldTrait(_ font: CTFont, size: CGFloat) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold)
            ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? font
    }

    private static func italicTrait(_ font: CTFont, size: CGFloat) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) ?? font
    }

    /// `CTParagraphStyleCreate` 只在创建那一刻读取设置值，
    /// 因此用一块临时缓冲承载 7 个字段，创建完成后立即释放。
    /// 行距用 `lineSpacingAdjustment`：macOS SDK 已把旧的 `lineSpacing` 标为不可用。
    private static func makeParagraphStyle(
        alignment: CTTextAlignment = .natural,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        tailIndent: CGFloat = 0
    ) -> CTParagraphStyle {
        let fieldSize = MemoryLayout<CGFloat>.stride
        let block = UnsafeMutableRawPointer.allocate(
            byteCount: fieldSize * 7 + 1,
            alignment: MemoryLayout<CGFloat>.alignment
        )
        defer { block.deallocate() }

        // CTTextAlignment 在 SDK 里是 uint8_t：写成 Int32 时 valueSize 与类型不符，
        // CTParagraphStyleCreate 会直接丢弃该设置（居中页码会退化成左对齐）
        block.storeBytes(of: UInt8(alignment.rawValue), as: UInt8.self)
        block.storeBytes(of: lineSpacing, toByteOffset: fieldSize, as: CGFloat.self)
        block.storeBytes(of: spacingBefore, toByteOffset: fieldSize * 2, as: CGFloat.self)
        block.storeBytes(of: spacingAfter, toByteOffset: fieldSize * 3, as: CGFloat.self)
        block.storeBytes(of: firstLineHeadIndent, toByteOffset: fieldSize * 4, as: CGFloat.self)
        block.storeBytes(of: headIndent, toByteOffset: fieldSize * 5, as: CGFloat.self)
        block.storeBytes(of: tailIndent, toByteOffset: fieldSize * 6, as: CGFloat.self)
        // 基准书写方向：RTL 语言（阿拉伯语等）下正文按右到左排版。
        // 显式设置它，配合默认的 .natural 对齐，导出的 PDF 不会恒为左对齐
        block.storeBytes(
            of: isRightToLeft ? CTWritingDirection.rightToLeft.rawValue
                              : CTWritingDirection.leftToRight.rawValue,
            toByteOffset: fieldSize * 7, as: Int8.self
        )

        let settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<UInt8>.size, value: block),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: fieldSize, value: block.advanced(by: fieldSize)),
            CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: fieldSize, value: block.advanced(by: fieldSize * 2)),
            CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: fieldSize, value: block.advanced(by: fieldSize * 3)),
            CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 4)),
            CTParagraphStyleSetting(spec: .headIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 5)),
            CTParagraphStyleSetting(spec: .tailIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 6)),
            CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<Int8>.size, value: block.advanced(by: fieldSize * 7))
        ]
        return CTParagraphStyleCreate(settings, settings.count)
    }

    /// 当前界面语言是否为 RTL（用于 PDF 导出基准书写方向）
    private static var isRightToLeft: Bool {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        return ["ar", "he", "fa", "ur", "yi"].contains(code)
    }
}
