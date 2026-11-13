import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Memozia

/// `MarkdownPDFRenderer` 的排版回归测试。
///
/// 这些用例对应首轮实现时真实踩到的问题，改动排版时优先看它们是否还成立：
///
/// 1. **产物必须是可打开的多页 PDF**：CoreText 分页靠 `CTFrameGetVisibleStringRange` 推进，
///    写错一步就会产出 0 页或死循环，而这类问题在 UI 上只表现为「导出了个空文件」。
/// 2. **代码块不能丢首行**：围栏扫描里 `index += 1` 与取行顺序一旦写反，
///    第一行代码会被跳过、闭合的 ``` 反被当成正文。
/// 3. **行内标记不能吞掉换行**：递归解析若在每层都补 `\n`，`**已确认**：正文` 会被断成两行。
/// 4. **`*` / `_` 的相邻判定只看 ASCII**：中日韩相邻时按单词粘连处理会让 `*强调*` 全部失效。
struct MarkdownPDFRendererTests {

    // MARK: - 辅助

    private func configuration(title: String? = nil) -> MarkdownPDFRenderer.Configuration {
        var configuration = MarkdownPDFRenderer.Configuration()
        configuration.title = title
        return configuration
    }

    private func pdfPageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { return -1 }
        return pdf.numberOfPages
    }

    private func lines(_ markdown: String, title: String? = nil) -> [String] {
        MarkdownPDFRenderer.attributedString(from: markdown, configuration: configuration(title: title))
            .string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: - PDF 产物

    @Test func testRenderProducesOpenablePDF() throws {
        let data = try MarkdownPDFRenderer.render(
            markdown: "# 会议总结\n\n- 第一项\n- 第二项",
            configuration: configuration(title: "测试录音")
        )
        #expect(data.count > 1024)
        #expect(String(data: data.prefix(5), encoding: .ascii) == "%PDF-")
        #expect(pdfPageCount(data) == 1)
    }

    @Test func testEmptyContentStillProducesOnePage() throws {
        let data = try MarkdownPDFRenderer.render(markdown: "   \n\n   ", configuration: configuration())
        #expect(!data.isEmpty)
        #expect(pdfPageCount(data) == 1)
    }

    @Test func testLongTranscriptPaginatesAndStaysSingleDocument() throws {
        var markdown = ""
        for index in 0..<300 {
            markdown += "**00:\(String(format: "%02d", index % 60)):00 · 发言人\(index % 3)**\n\n"
            markdown += "第 \(index) 段会议内容，讨论导出格式、排版细节与中英混排的分页边界情况。\n\n---\n\n"
        }
        let data = try MarkdownPDFRenderer.render(markdown: markdown, configuration: configuration(title: "长会议"))
        let pages = pdfPageCount(data)
        #expect(pages > 3)
        // 分页推进必须覆盖全文：页数过少说明有内容被丢掉，过多说明每页没排满
        #expect(pages < 60)
    }

    /// 单个超长不可断词会占满整页并让可见长度归零，必须有步长兜底而不是卡死或产出空文档
    @Test func testUnbreakableTokenDoesNotStallLayout() throws {
        let token = String(repeating: "a", count: 20_000)
        let data = try MarkdownPDFRenderer.render(markdown: "开头\n\n\(token)\n\n结尾", configuration: configuration())
        #expect(pdfPageCount(data) >= 2)
    }

    // MARK: - 块级解析

    @Test func testBlockKindsAreRecognized() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        # 一级标题
        ## 二级标题

        普通段落。

        - 无序项
        1. 有序项
        > 引用
        ---
        """)
        #expect(blocks.contains(.heading(level: 1, text: "一级标题")))
        #expect(blocks.contains(.heading(level: 2, text: "二级标题")))
        #expect(blocks.contains(.paragraph(text: "普通段落。")))
        #expect(blocks.contains(.bulletItem(text: "无序项")))
        #expect(blocks.contains(.numberedItem(number: 1, text: "有序项")))
        #expect(blocks.contains(.quote(blocks: [.paragraph(text: "引用")])))
        #expect(blocks.contains(.divider))
    }

    /// 围栏代码块：首行不能丢、闭合 ``` 不能进正文、缩进要原样保留
    @Test func testFencedCodeKeepsEveryLineAndIndentation() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        ```swift
        let data = try render(markdown: text)
            print("缩进保留")
        ```
        """)
        #expect(blocks == [.codeBlock(text: "let data = try render(markdown: text)\n    print(\"缩进保留\")")])
    }

    @Test func testTableSeparatorRowIsDroppedButHeaderKept() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        | 项目 | 内容 |
        |---|---|
        | 时间 | 10:00 |
        """)
        #expect(blocks == [.table(MarkdownTable(rows: [["项目", "内容"], ["时间", "10:00"]],
                                                    alignments: [.leading, .leading]))])
    }

    @Test func testTaskListMarkersBecomeCheckBoxes() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        - [x] 已完成
        - [ ] 待办
        """)
        #expect(blocks.contains(.bulletItem(text: "已完成", checked: true)))
        #expect(blocks.contains(.bulletItem(text: "待办", checked: false)))
    }

    // MARK: - 行内标记

    @Test func testInlineMarksAreConsumedWithoutResidue() {
        let text = lines("**粗体**、*斜体*、`代码`、~~删除线~~").joined(separator: "\n")
        #expect(!text.contains("**"))
        #expect(!text.contains("~~"))
        #expect(!text.contains("`"))
        // 粗体后的正文必须留在同一行：递归解析里多补一个 \n 就会在这里断行
        #expect(text.contains("粗体、斜体、代码、删除线"))
    }

    /// 相邻判定只看 ASCII：`snake_case`、`10*5` 保持原样，而中文里的 `*强调*` 要生效
    @Test func testEmphasisGuardsOnlyASCIIWordBoundaries() {
        let protected = lines("注意 snake_case_name 与 10*5=50 不要被打断").joined(separator: "")
        #expect(protected.contains("snake_case_name"))
        #expect(protected.contains("10*5=50"))

        let cjk = lines("这里是*重点*内容").joined(separator: "")
        #expect(cjk == "这里是重点内容")
    }

    @Test func testLinkKeepsURLWhenLabelDiffers() {
        let text = lines("参考 [导出需求](https://example.com/req) 说明").joined(separator: "")
        #expect(text.contains("导出需求"))
        #expect(text.contains("https://example.com/req"))
        #expect(!text.contains("["))
    }

    @Test func testUnbalancedMarkerFallsBackToLiteralText() {
        // 只有一个裸 * 时不能把后面整段吞掉
        let text = lines("占比 50* 以上，后面还有很长的正文内容").joined(separator: "")
        #expect(text.contains("以上，后面还有很长的正文内容"))
    }

    /// 分隔线按整宽拼会因字体替换多出一小截换行，实测要求每条 rule 只占一行且长度一致
    @Test func testHorizontalRuleStaysOnOneLine() {
        let content = lines("---\n\n正文\n\n---")
        let ruleLines = content.filter { $0.contains("─") }
        #expect(ruleLines.count == 2)
        let dashCounts = Set(ruleLines.map { $0.filter { $0 == "─" }.count })
        #expect(dashCounts.count == 1)
    }

    // MARK: - 段落合并

    @Test func testSoftLineJoinDoesNotInsertSpaceBetweenCJK() {
        let text = lines("今天讨论\n排期问题").joined(separator: "")
        #expect(text == "今天讨论排期问题")

        let latin = lines("discuss the\nschedule issue").joined(separator: "")
        #expect(latin == "discuss the schedule issue")
    }

    @Test func testTitleIsRenderedOnceAtTop() {
        let content = lines("# 正文标题\n\n内容", title: "录音条目名")
        #expect(content.first == "录音条目名")
        #expect(content.contains("正文标题"))
    }
}

/// 共同语法的回归用例：界面缓存与 PDF 必须消费同一份结构。
struct MarkdownBlockParserTests {
    @Test func tableKeepsEmptyCellsEscapesAndAlignment() {
        let source = "项目 | 内容 | 备注\n:--- | :---: | ---:\nA\\|B | | C"
        let expected: [TranscriptBlock] = [.table(MarkdownTable(
            rows: [["项目", "内容", "备注"], ["A|B", "", "C"]],
            alignments: [.leading, .center, .trailing]))]
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == expected)
        #expect(MarkdownPDFRenderer.blocks(from: source) == expected)
        let text = MarkdownPDFRenderer.attributedString(from: source).string
        #expect(text.contains("A|B\t\tC"))
    }

    @Test func tableRequiresMatchingDelimiterAndNormalizesRowWidths() {
        #expect(TranscriptMarkdownBuilder.parseBlocks("a | b\n普通内容") == [.paragraph(text: "a | b普通内容")])
        let source = "| A | B |\n| --- | --- |\n| only |\n| one | two | extra |"
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == [.table(MarkdownTable(
            rows: [["A", "B"], ["only", ""], ["one", "two"]], alignments: [.leading, .leading]))])
        let invalid = "| A | B |\n| --- |"
        #expect(!TranscriptMarkdownBuilder.parseBlocks(invalid).contains { if case .table = $0 { true } else { false } })
    }

    @Test func cancelledParsingDoesNotPublishPartialBlocks() {
        let source = String(repeating: "| A | B |\n| --- | --- |\n| x | y |\n\n", count: 1_000)
        #expect(TranscriptMarkdownBuilder.parseBlocks(source, shouldCancel: { true }).isEmpty)
    }

    @Test func headingsUseSixLevelsAndRequireWhitespace() {
        let source = "#### **四级**\n##### 五级\n###### 六级 ###\n#无空格\n####### 七级"
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == [
            .heading(level: 4, text: "**四级**"), .heading(level: 5, text: "五级"),
            .heading(level: 6, text: "六级"), .paragraph(text: "#无空格####### 七级")])
        #expect(TranscriptMarkdownBuilder.parseBlocks("标题\n===") == [.heading(level: 1, text: "标题")])
        #expect(TranscriptMarkdownBuilder.parseBlocks("标题\n---") == [.heading(level: 2, text: "标题")])
    }

    @Test func fencesMatchTypeLengthAndClosingSuffix() {
        let source = "  ````markdown\n  ```swift\n    let x = 1\n  ```\n  ````\n~~~\nbody\n~~~ trailing\n~~~"
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == [
            .codeBlock(text: "```swift\n  let x = 1\n```"), .codeBlock(text: "body\n~~~ trailing")])
        #expect(TranscriptMarkdownBuilder.parseBlocks("```\nunfinished") == [.codeBlock(text: "unfinished")])
    }

    @Test func listsKeepDepthTasksAndContinuation() {
        let source = "- 父项\n  + [x] 子项\n    续行\n  2) 第二项\n+ [ ] 未完成\n- [x]ordinary"
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == [
            .bulletItem(text: "父项"), .bulletItem(text: "子项续行", depth: 1, checked: true),
            .numberedItem(number: 2, text: "第二项", depth: 1),
            .bulletItem(text: "未完成", checked: false), .bulletItem(text: "[x]ordinary")])
    }

    @Test func quotesContainParagraphsNestedQuotesAndTables() {
        let source = "> 第一行\n> 第二行\n>\n>> 嵌套\n>\n> A | B\n> --- | ---\n> x | y"
        #expect(TranscriptMarkdownBuilder.parseBlocks(source) == [.quote(blocks: [
            .paragraph(text: "第一行第二行"), .quote(blocks: [.paragraph(text: "嵌套")]),
            .table(MarkdownTable(rows: [["A", "B"], ["x", "y"]], alignments: [.leading, .leading]))])])
    }

    @Test func paragraphsNormalizeNewlinesAndKeepExplicitBreaks() {
        #expect(TranscriptMarkdownBuilder.parseBlocks("今天讨论\r\n排期\r\n\r\ndiscuss the\r\nschedule") == [
            .paragraph(text: "今天讨论排期"), .paragraph(text: "discuss the schedule")])
        #expect(TranscriptMarkdownBuilder.parseBlocks("第一行  \n第二行\\\n第三行") == [
            .paragraph(text: "第一行\n第二行\n第三行")])
    }

    @Test func tablePDFRepeatsHeaderAndKeepsLastRow() throws {
        let rows = (0..<100).map { "| ROW\($0) | 内容 \($0) |" }.joined(separator: "\n")
        let data = try MarkdownPDFRenderer.render(markdown: "| HEADER | VALUE |\n| --- | --- |\n" + rows)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount > 1)
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            #expect(text.contains("HEADER"))
        }
        let text = (document.string ?? "").filter { !$0.isWhitespace }
        for index in 0..<100 { #expect(text.contains("ROW\(index)")) }
    }

    @Test func tableHeaderStaysWithFirstDataRowAtPageBoundary() throws {
        var configuration = MarkdownPDFRenderer.Configuration()
        configuration.pageHeight = 260
        for count in 0..<8 {
            let source = String(repeating: "前文内容。\n\n", count: count)
                + "| HEADER | VALUE |\n| --- | --- |\n| ROWEND | CONTENT |"
            let data = try MarkdownPDFRenderer.render(markdown: source, configuration: configuration)
            let document = try #require(PDFDocument(data: data))
            for index in 0..<document.pageCount {
                let text = document.page(at: index)?.string ?? ""
                if text.contains("HEADER") { #expect(text.contains("ROWEND")) }
            }
        }
    }

    @Test func oversizedTableCellContinuesAcrossPagesWithoutRepeatingShortCell() throws {
        let longText = (0..<800).map { "TOKEN\($0)" }.joined(separator: " ")
        let source = "开头\n\n| HEADER | VALUE |\n| --- | --- |\n| ONCEONLY | \(longText) |\n\n结尾"
        let data = try MarkdownPDFRenderer.render(markdown: source)
        let document = try #require(PDFDocument(data: data))
        let text = document.string ?? ""
        #expect(document.pageCount > 2)
        let compact = text.filter { !$0.isWhitespace }
        for index in 0..<800 { #expect(compact.contains("TOKEN\(index)")) }
        #expect(text.contains("结尾"))
        #expect(text.components(separatedBy: "ONCEONLY").count == 2)
    }
}
