import SwiftUI
#if os(macOS)
import AppKit
#else
/* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
import UIKit
*/
#endif

// MARK: - 文本编辑区查找/替换支持

/// 编辑模式 TextEditor 的查找（⌘F）与替换（⌘R）支持。
///
/// 能力：
/// - 全部匹配高亮（macOS/iOS 走 NSLayoutManager 临时属性；TextKit 2 无旧版
///   layoutManager 时自动降级为仅选中高亮）
/// - 上一个/下一个匹配导航（⌘G / ⇧⌘G），当前匹配以系统选中态高亮并滚动到可见
/// - 替换当前项 / 全部替换
///
/// 实现要点：SwiftUI TextEditor 不暴露底层平台视图，通过零尺寸锚点视图自省——
/// 锚点与 TextEditor 同层级根，自根向下深度优先找到唯一的编辑器实例
/// （macOS 过滤 isFieldEditor，避免误抓查找框的 field editor）。
struct TextEditorFindReplace: ViewModifier {

    enum Mode: Equatable {
        case find      // ⌘F：仅查找
        case replace   // ⌘R：查找 + 替换
    }

    /// 编辑草稿（计数/替换/高亮的直接目标）
    @Binding var text: String

    @State private var mode: Mode?
    @State private var searchText = ""
    /// 经过去抖后用于全文匹配的搜索词。
    @State private var effectiveSearchText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    /// 当前定位的匹配序号（在 matchRanges 中循环）
    @State private var currentIndex = 0
    @FocusState private var searchFieldFocused: Bool
    /// 底层编辑器弱引用（SwiftUI 可能重建视图，引用失效时重新自省）
    @State private var editorBox = EditorBox()

    /// 匹配结果的渲染期记忆（引用类型 + @State：跨 body 求值存活）
    @State private var matchMemo = FindReplaceMemo()
    @State private var highlightTask: Task<Void, Never>?

    /// 匹配的 NSRange 列表（UTF-16 偏移，与 NSTextView/UITextView 一致）
    ///
    /// 必须记忆：本属性被 `matchCount`（4 处 `.disabled(matchCount == 0)`）、
    /// `matchCountLabel`、`goToMatch`、`replaceCurrent`、`applyHighlights` 共同引用，
    /// 旧写法是无记忆的计算属性，且 `utf16Offset(in: text)` 每次都从串头扫描 →
    /// 一次 body 求值就把整篇文稿重复全文搜索好几遍（O(匹配数 × 文本长度) 的常数倍），
    /// 打开 200KB 转写稿的 ⌘F 即掉帧。
    private var matchRanges: [NSRange] {
        matchMemo.ranges(
            in: text,
            pattern: effectiveSearchText,
            caseSensitive: caseSensitive,
            key: FindReplaceMemo.key(
                text: text, pattern: effectiveSearchText, caseSensitive: caseSensitive
            )
        )
    }

    private var matchCount: Int { matchRanges.count }

    /// "x/y" 计数（无匹配时给文字提示）
    private var matchCountLabel: String {
        guard !effectiveSearchText.isEmpty else { return "" }
        if matchCount == 0 { return String(localized: "无匹配") }
        return "\(min(currentIndex + 1, matchCount))/\(matchCount)"
    }

    func body(content: Content) -> some View {
        // 查找条悬浮于编辑器上方（overlay 不占布局空间，编辑框高度不变，
        // 避免 ⌘R 展开更高查找条时 TextEditor 被压缩）；与 Xcode/浏览器一致，
        // 打开期间短暂遮挡首行，关闭即恢复
        content
            // 自省锚点：放在 TextEditor 背后，与其共享层级根
            .background(EditorAnchor(box: editorBox, text: text))
            .overlay(alignment: .top) {
                if let mode {
                    bar(mode)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
            .background(shortcutCarriers)
        .onChange(of: searchText) {
            scheduleHighlightRefresh(navigateToFirst: true)
        }
        .onChange(of: caseSensitive) {
            scheduleHighlightRefresh(navigateToFirst: true)
        }
        .onChange(of: text) {
            scheduleHighlightRefresh(navigateToFirst: false)
        }
        .onChange(of: mode) {
            // 关闭查找条时清除全部临时高亮
            highlightTask?.cancel()
            applyHighlights()
        }
    }

    // MARK: - 查找/替换条

    @ViewBuilder
    private func bar(_ mode: Mode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(String(localized: "查找"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 150)
                .focused($searchFieldFocused)
                .onSubmit { nextMatch() }

            Text(matchCountLabel)
                .font(.caption)
                .foregroundStyle(
                    searchText.isEmpty || matchCount > 0
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.orange)
                )
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .leading)

            // 大小写敏感开关
            Button {
                caseSensitive.toggle()
            } label: {
                Text("Aa")
                    .font(.caption)
                    .fontWeight(caseSensitive ? .bold : .regular)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(caseSensitive
                ? String(localized: "区分大小写：开")
                : String(localized: "区分大小写：关"))
            .accessibilityLabel(Text("区分大小写"))

            // 上一个/下一个匹配导航
            Button {
                prevMatch()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help(String(localized: "上一个匹配"))
            .accessibilityLabel(Text("上一个匹配"))

            Button {
                nextMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .help(String(localized: "下一个匹配"))
            .accessibilityLabel(Text("下一个匹配"))

            if mode == .replace {
                Divider().frame(height: 14)

                TextField(String(localized: "替换为"), text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 150)
                    .onSubmit { replaceCurrent() }

                Button(String(localized: "替换")) { replaceCurrent() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(matchCount == 0)
                    .help(String(localized: "替换当前匹配项"))

                Button(String(localized: "全部替换")) { replaceAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(matchCount == 0)
                    .help(String(localized: "替换全部匹配项"))
            }

            Spacer(minLength: 4)

            Button {
                close()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(String(localized: "关闭查找"))
            // .help 只提供鼠标 tooltip；补语义标签供 VoiceOver 使用
            .accessibilityLabel(Text("关闭查找"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
        .onAppear {
            // 打开后焦点进查找框，可直接输入
            searchFieldFocused = true
        }
    }

    /// 快捷键承载（零尺寸隐藏按钮）：编辑视图挂载期间 ⌘F/⌘R/⌘G/⇧⌘G 生效
    @ViewBuilder
    private var shortcutCarriers: some View {
        Group {
            Button("") { begin(.find) }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { begin(.replace) }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") { prevMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - 导航与替换

    private func begin(_ newMode: Mode) {
        withAnimation(.easeInOut(duration: 0.15)) {
            mode = newMode
        }
        searchFieldFocused = true
    }

    @MainActor
    private func close() {
        withAnimation(.easeInOut(duration: 0.15)) {
            mode = nil
        }
        // 清除高亮并放弃选中（选区保留会干扰继续编辑的位置预期）
        editorBox.selectAndScroll(to: NSRange(location: -1, length: 0), text: text)
    }

    /// 定位到指定匹配：更新序号、刷新高亮（当前项橙色区分）、
    /// 选中当前匹配并滚动到可见行
    @MainActor
    private func goToMatch(_ index: Int, wrap: Bool = true) {
        let ranges = matchRanges
        guard !ranges.isEmpty else { return }
        var idx = index
        if idx >= ranges.count { idx = wrap ? 0 : ranges.count - 1 }
        if idx < 0 { idx = wrap ? ranges.count - 1 : 0 }
        currentIndex = idx
        applyHighlights()
        editorBox.selectAndScroll(to: ranges[idx], text: text)
    }

    @MainActor
    private func nextMatch() {
        goToMatch(currentIndex + 1)
    }

    @MainActor
    private func prevMatch() {
        goToMatch(currentIndex - 1)
    }

    /// 替换当前定位的匹配项，随后自动定位到下一处（替换并查找的常见行为）
    @MainActor
    private func replaceCurrent() {
        let ranges = matchRanges
        guard !ranges.isEmpty else { return }
        let idx = min(currentIndex, ranges.count - 1)
        guard let swiftRange = Range(ranges[idx], in: text) else { return }
        text.replaceSubrange(swiftRange, with: replaceText)
        // 绑定写入后按新文本重算：同序号即被替换处的下一个匹配（无则回绕首项）
        Task { @MainActor in
            let newRanges = matchRanges
            guard !newRanges.isEmpty else { return }
            goToMatch(min(idx, newRanges.count - 1), wrap: false)
        }
    }

    @MainActor
    private func replaceAll() {
        guard !effectiveSearchText.isEmpty, matchCount > 0 else { return }
        if caseSensitive {
            text = text.replacingOccurrences(of: effectiveSearchText, with: replaceText)
        } else {
            text = text.replacingOccurrences(
                of: effectiveSearchText, with: replaceText,
                options: [.caseInsensitive], range: nil)
        }
    }

    // MARK: - 全量匹配高亮

    @MainActor
    private func scheduleHighlightRefresh(navigateToFirst: Bool) {
        highlightTask?.cancel()
        highlightTask = Task { @MainActor in
            // 连续输入时只在用户短暂停顿后全文搜索/重画，避免大文稿每个按键都 O(n)。
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            effectiveSearchText = searchText
            if navigateToFirst { currentIndex = 0 }
            applyHighlights()
            if navigateToFirst { goToMatch(0, wrap: false) }
        }
    }

    /// 用 layoutManager 临时属性高亮匹配：非当前匹配黄色、当前匹配橙色。
    /// 当前匹配不用系统选中态承载——非聚焦的 NSTextView 不渲染选中高亮，
    /// 临时属性颜色不受焦点影响，任何状态都可见。
    /// TextKit 2（无旧版 layoutManager）时自动降级为仅滚动定位；
    /// iOS 的 TextKit API 与 macOS 存在差异，统一降级为仅选中态高亮。
    @MainActor
    private func applyHighlights() {
        guard let editor = editorBox.resolveEditor(matching: text) else { return }
        #if os(macOS)
        let length = (editor.textStorage?.length ?? 0)
        guard length > 0, let layoutManager = editor.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: length)
        )
        guard mode != nil else { return }
        let ranges = matchRanges
        guard !ranges.isEmpty else { return }
        let current = min(currentIndex, ranges.count - 1)
        let yellow = Self.yellowHighlight
        let orange = Self.orangeHighlight
        for (i, range) in ranges.enumerated() {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: i == current ? orange : yellow,
                forCharacterRange: range
            )
        }
        #else
        // iOS：不写 NSLayoutManager 临时属性，当前匹配定位走系统选中态
        #endif
    }

    #if os(macOS)
    private static var yellowHighlight: NSColor {
        NSColor.systemYellow.withAlphaComponent(0.45)
    }
    private static var orangeHighlight: NSColor {
        NSColor.systemOrange.withAlphaComponent(0.65)
    }
    #else
    /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
    private static var yellowHighlight: UIColor {
        UIColor.systemYellow.withAlphaComponent(0.45)
    }
    private static var orangeHighlight: UIColor {
        UIColor.systemOrange.withAlphaComponent(0.65)
    }
    */
    #endif
}

// MARK: - 平台编辑器访问（自省）

/// 底层编辑器弱引用盒子：@State 持有；引用失效（SwiftUI 重建平台视图）时
/// 从锚点重新自省，保证导航/高亮始终作用于真实的编辑器实例
private final class EditorBox: @unchecked Sendable {
    #if os(macOS)
    typealias PlatformEditor = NSTextView
    typealias PlatformView = NSView
    #else
    /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
    typealias PlatformEditor = UITextView
    typealias PlatformView = UIView
    */
    #endif

    weak var textView: PlatformEditor?
    weak var anchorView: NSObject?

    /// 取有效编辑器：现有引用失效时从锚点重找（自愈）。
    /// expectedText 用于内容匹配——窗口内可能存在多个文本视图
    /// （查找框、标题编辑等），以"内容与编辑草稿一致"识别目标编辑器
    @MainActor
    func resolveEditor(matching expectedText: String) -> PlatformEditor? {
        #if os(macOS)
        if let tv = textView, tv.window != nil, tv.string == expectedText { return tv }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        if let tv = textView, tv.window != nil, tv.text == expectedText { return tv }
        */
        #endif
        #if os(macOS)
        guard let anchor = anchorView as? NSView else { return nil }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        guard let anchor = anchorView as? UIView else { return nil }
        */
        #endif
        let found = Self.findEditor(from: anchor, matching: expectedText)
        textView = found
        return found
    }

    /// 选中指定范围并滚动到可见；location < 0 表示仅取消选中
    @MainActor
    func selectAndScroll(to range: NSRange, text: String) {
        guard range.location >= 0, let editor = resolveEditor(matching: text) else {
            return
        }
        editor.selectedRange = range
        editor.scrollRangeToVisible(range)
    }

    /// 自锚点向上爬到最近的 hosting view 为止（不越过到窗口层级），
    /// 在该边界内收集全部候选文本视图，优先返回内容与草稿一致的那个
    /// （macOS 排除 field editor：查找框聚焦时的临时 NSTextView）
    @MainActor
    private static func findEditor(from anchor: PlatformView, matching expectedText: String) -> PlatformEditor? {
        var root: PlatformView = anchor
        while let superview = root.superview {
            root = superview
            #if os(macOS)
            // NSHostingView 是泛型类，无法直接 is 判断，按类型名前缀识别
            if String(describing: type(of: root)).hasPrefix("NSHostingView") { break }
            #else
            /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
            if String(describing: type(of: root)).hasPrefix("UIHostingView") { break }
            */
            #endif
        }
        var candidates: [PlatformEditor] = []
        dfs(root, into: &candidates)
        // 首选内容完全一致的；退而求其次取第一个（唯一 TextEditor 的常规情形）
        #if os(macOS)
        return candidates.first { $0.string == expectedText } ?? candidates.first
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        return candidates.first { $0.text == expectedText } ?? candidates.first
        */
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func dfs(_ view: NSView, into result: inout [NSTextView]) {
        if let editor = view as? NSTextView, !editor.isFieldEditor {
            result.append(editor)
        }
        for subview in view.subviews {
            dfs(subview, into: &result)
        }
    }
    #else
    /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
    @MainActor
    private static func dfs(_ view: UIView, into result: inout [UITextView]) {
        if let editor = view as? UITextView {
            result.append(editor)
        }
        for subview in view.subviews {
            dfs(subview, into: &result)
        }
    }
    */
    #endif
}

#if os(macOS)
/// 零尺寸自省锚点（置于 TextEditor 背后）：登记自身引用供 EditorBox 失效重找
private struct EditorAnchor: NSViewRepresentable {
    let box: EditorBox
    /// 编辑草稿的当前值（内容匹配识别目标编辑器）
    let text: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            box.anchorView = view
            _ = box.resolveEditor(matching: text)
        }
    }
}
#else
/* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
private struct EditorAnchor: UIViewRepresentable {
    let box: EditorBox
    let text: String

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            box.anchorView = view
            _ = box.resolveEditor(matching: text)
        }
    }
}
*/
#endif

extension View {
    /// 为编辑模式的 TextEditor 挂载查找/替换支持（⌘F 查找、⌘R 替换、
    /// ⌘G/⇧⌘G 上一个/下一个匹配；全部匹配高亮 + 替换当前项/全部替换）。
    /// 仅应作用于编辑视图（快捷键随视图挂载生效，退出编辑即失效）
    func textFindReplace(text: Binding<String>) -> some View {
        modifier(TextEditorFindReplace(text: text))
    }
}
// MARK: - 查找替换的匹配记忆

/// `FindReplaceModifier` 的匹配结果记忆：同一次 body 求值内多次访问只扫一遍。
///
/// key 同时纳入文本内容指纹与搜索条件：任一变化即失效（编辑草稿、切换大小写、
/// 换搜索词都会自然重算）。文本指纹用「长度 + 首尾各 64 UTF-16 码元」而非整串哈希，
/// 保证 key 计算本身不会退化成又一遍全文处理。
@MainActor
final class FindReplaceMemo {
    private var cachedKey = ""
    private var cachedRanges: [NSRange] = []

    static func key(text: String, pattern: String, caseSensitive: Bool) -> String {
        // 直接切 String.UTF16View（RandomAccessCollection，count 为 O(1)）：
        // `Array(text.utf16)` 要整串复制，会把 key 计算退化成又一遍全文处理；
        // 码元切片用 String(decoding:as:) 还原，`String(...)` 并无接收 [UInt16] 的初始化器
        let utf16 = text.utf16
        let head = String(decoding: utf16.prefix(64), as: UTF16.self)
        let tail = String(decoding: utf16.suffix(64), as: UTF16.self)
        return "\(utf16.count)|\(head)|\(tail)|\(pattern)|\(caseSensitive ? 1 : 0)"
    }

    func ranges(in text: String, pattern: String, caseSensitive: Bool, key: String) -> [NSRange] {
        guard !pattern.isEmpty else { return [] }
        if key == cachedKey { return cachedRanges }

        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var result: [NSRange] = []
        // 以 UTF-16 区间扫描：一次遍历得到偏移，避免每个匹配都
        // `utf16Offset(in:)` 从串头重扫（旧实现的主要开销）
        let haystack = text as NSString
        var searchFrom = 0
        while searchFrom < haystack.length {
            let found = haystack.range(
                of: pattern,
                options: options,
                range: NSRange(location: searchFrom, length: haystack.length - searchFrom)
            )
            guard found.location != NSNotFound else { break }
            result.append(found)
            // 零宽匹配防御：强制前进一格，避免死循环
            searchFrom = found.location + max(1, found.length)
        }

        cachedKey = key
        cachedRanges = result
        return result
    }
}
