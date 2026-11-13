import Foundation
import Observation
import os.log

/// 词典文件夹路径（Markdown 词典文件统一存放于此）
enum DictionaryFolder {
    /// 默认路径：macOS 为 ~/Documents/Memozia/Dictionary，
    /// iOS 为沙盒 Documents/Memozia/Dictionary（与 WhisperModelFolder 同规则）
    static var defaultPath: String {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        return base
            .appendingPathComponent("Memozia")
            .appendingPathComponent("Dictionary")
            .path
    }

    static var defaultURL: URL {
        URL(fileURLWithPath: defaultPath)
    }
}

/// 语音解析词典文件（Markdown）
struct DictionaryFile: Identifiable, Hashable {
    let url: URL
    let termCount: Int
    let modifiedAt: Date?

    var id: URL { url }
    var fileName: String { url.deletingPathExtension().lastPathComponent }
}

/// 词典目录扫描结果（纯数据，可在任意执行器产出）。
///
/// 刻意声明在**文件作用域**而不是词典服务的嵌套类型：`@MainActor` 类内的嵌套类型会继承
/// 该隔离，其成员初始化器就变成主 actor 专属，后台执行器里的 `scan(...)` 将无法构造它。
struct DictionaryScanResult: Sendable {
    var files: [DictionaryFile] = []
    var exactPairs: [(wrong: String, correct: String)] = []
    var pinyinTerms: [String] = []
}

/// 语音解析词典服务
///
/// 词典文件为 Markdown，存放于 ~/Documents/Memozia/Dictionary。
/// 支持三种纠正条目格式（每行一条）：
/// 1. `- 术语`            单列术语：转写后按拼音匹配自动纠正（无需知道错误写法）
/// 2. `| 错误词 | 正确词 |`  两列表格：先做精确替换，第二列同时参与拼音纠正
/// 3. `错误词 -> 正确词`    箭头行：同两列表格
///
/// 去标识化条目与纠正词条共库存储，用标记区分（便于程序读取，不参与转写纠正）：
/// `- 敏感词 #去标识化:类别`（类别：人员姓名/公司名/品牌名/地区/账号/密码/手机号/身份证号/邮箱/其他）
///
/// 拼音纠正原理：利用系统 CFStringTransform 把词典术语与转写文本逐字转为无声调拼音，
/// 读音相同的连续片段即替换为词典术语（如“语义识别”→“语音识别”），
/// 无需预先枚举所有错误写法。
@MainActor
@Observable
final class TranscriptDictionaryService {

    static let shared = TranscriptDictionaryService()

    private let logger = Logger(subsystem: "app.memozia", category: "TranscriptDictionary")

    /// correct() 快照与 reload()/save() 的并发保护：转写文本纠正已移到后台执行器，
    /// 取快照时可能与设置页的词典编辑并发触达可变集合（exactPairs/pinyinTerms）
    private let stateLock = NSLock()

    /// 去标识化条目行内标记前缀（后接类别名，如 `#去标识化:公司名`）
    nonisolated static let piiMarker = "#去标识化:"
    /// 去标识化条目默认存放文件名（与纠正词条同文件夹，用户可直接编辑）
    nonisolated static let piiFileName = "去标识化.md"

    /// 词典文件夹（固定为默认路径，与用户数据文件夹约定一致）
    let folderURL: URL = DictionaryFolder.defaultURL

    /// 当前加载的词典文件列表
    private(set) var files: [DictionaryFile] = []

    /// 精确替换对（错误词 → 正确词）
    private(set) var exactPairs: [(wrong: String, correct: String)] = []
    /// 参与拼音纠正的术语
    private(set) var pinyinTerms: [String] = []

    // 汉字→拼音缓存已提升到文件级的线程安全盒子（`PinyinCacheBox`）：
    // 纠正扫描不再跑在 MainActor 上，实例内的裸字典无法跨线程安全复用

    private init() {
        ensureFolderExists()
        // 首载必须同步完成：`correct()` 依赖词条快照，异步首载会让启动后第一次转写
        // 拿到空词典（词条静默不生效且难以复现）。后续刷新一律走 `reload()`（后台扫描）
        reloadSync()
    }

    // MARK: - 文件夹与文件管理

    /// 确保词典文件夹存在（不存在则创建，并写入示例词典）
    private func ensureFolderExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folderURL.path) {
            try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        // 首次创建时写入示例词典，方便用户理解格式
        let sample = folderURL.appendingPathComponent("示例词典.md")
        if !fm.fileExists(atPath: sample.path) {
            try? Self.sampleMarkdown.write(
                to: sample, atomically: true, encoding: .utf8
            )
        }
        // 旧版独立 JSON 声纹/PII 字典迁移到统一的 Markdown 词典（仅首次生效）
        Self.migrateLegacyPIIJSONIfNeeded()
    }

    /// 当前刷新的世代号：后台扫描并发完成时，只有最后一次的结果可以落位
    /// （否则"保存 A 文件"的旧扫描可能晚于"保存 B 文件"的扫描返回并把新结果覆盖掉）
    private var reloadGeneration = 0

    /// 重新扫描词典文件夹（**异步**：目录枚举与全量解析在后台执行器完成）。
    ///
    /// 旧实现是 MainActor 上的同步方法，且整段持有 `stateLock` 做磁盘 IO + 逐文件解析；
    /// 词典条目多时每次保存/删除词条都会卡一下主线程。改为后台扫描后 UI 的
    /// `files`/`totalTermCount` 稍晚一拍刷新（@Observable 会在结果落位时自动重算视图）。
    func reload() {
        ensureFolderExists()
        reloadGeneration += 1
        let generation = reloadGeneration
        let folder = folderURL
        // 外层用 `Task { @MainActor }`（工程既有的通行写法）：detached 闭包只捕获
        // Sendable 的 URL 与返回值、绝不捕获 self，扫描在后台执行器完成后回主 actor 落位
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                TranscriptDictionaryService.scan(folderURL: folder)
            }.value
            self.applyScan(result, generation: generation)
        }
    }

    /// 同步重载（仅供 init 首载使用；其余调用点请用 `reload()`）
    private func reloadSync() {
        applyScan(Self.scan(folderURL: folderURL), generation: reloadGeneration)
    }

    /// 落位扫描结果（统一在此加锁，避免与 `correct()` 的快照读取竞态）。
    /// 只接受最新世代的扫描：并发触发时旧结果后到会覆盖新结果
    private func applyScan(_ result: DictionaryScanResult, generation: Int) {
        guard generation == reloadGeneration else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        files = result.files
        exactPairs = result.exactPairs
        pinyinTerms = result.pinyinTerms
        // 词典内容变化后失效 PII 磁盘缓存，避免还原/去标识化用到过期条目
        Self.invalidatePIIDiskCache()
    }

    /// 目录枚举 + 解析：不触碰任何实例状态，因此可安全地在后台执行器运行
    nonisolated static func scan(folderURL: URL) -> DictionaryScanResult {
        let fm = FileManager.default
        var result = DictionaryScanResult()

        guard let urls = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return result
        }

        var seen = Set<String>()

        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = parse(content)
            let validTerms = parsed.terms.filter { isValidTerm($0) }
            let validPairs = parsed.pairs.filter { isValidTerm($0.correct) }

            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            result.files.append(DictionaryFile(url: url, termCount: countEntries(in: content), modifiedAt: date))

            result.exactPairs.append(contentsOf: validPairs)
            for term in validTerms where !seen.contains(term) {
                seen.insert(term)
                result.pinyinTerms.append(term)
            }
            // 表格第二列（正确词）也参与拼音纠正
            for pair in validPairs where !seen.contains(pair.correct) {
                seen.insert(pair.correct)
                result.pinyinTerms.append(pair.correct)
            }
        }

        result.files.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        result.pinyinTerms = result.pinyinTerms.filter { $0.count >= 2 && $0.count <= 30 }
        return result
    }

    /// 词典总条目数
    var totalTermCount: Int {
        files.reduce(0) { $0 + $1.termCount }
    }

    /// 读取词典文件内容
    func content(of file: DictionaryFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    /// 保存词典文件（覆盖写入），完成后重新加载
    func save(fileName: String, content: String) -> Bool {
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
        let url = folderURL.appendingPathComponent(safeName.hasSuffix(".md") ? safeName : safeName + ".md")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            reload()
            return true
        } catch {
            // 不能静默吞掉：用户会以为词条已保存，但转写纠正并不生效
            logger.error("词典保存失败 \(safeName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 删除词典文件，完成后重新加载
    func delete(_ file: DictionaryFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            // 删不掉时列表仍会刷新，若不记录日志会被误认为“删除成功”
            logger.error("词典删除失败 \(file.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        reload()
    }

    // MARK: - Markdown 解析

    /// 统计词典文件的有效条目总数（纠正词条 + 去标识化条目，供列表展示）
    nonisolated static func countEntries(in markdown: String) -> Int {
        let parsed = parse(markdown)
        let terms = parsed.terms.filter { isValidTerm($0) }
        let pairs = parsed.pairs.filter { isValidTerm($0.correct) }
        return terms.count + pairs.count + parsePIIEntries(markdown).count
    }

    /// 剥离 HTML 注释块（`<!-- ... -->`，可跨行）。
    /// 词典文件头部的格式说明写在注释里，不剥离会被误解析为条目（污染计数与纠正引擎）
    nonisolated static func stripHTMLComments(_ markdown: String) -> String {
        var result = markdown
        while let start = result.range(of: "<!--") {
            guard let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) else { break }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    /// 解析 Markdown 词典内容
    nonisolated static func parse(_ markdown: String)
        -> (terms: [String], pairs: [(wrong: String, correct: String)]) {
        var terms: [String] = []
        var pairs: [(wrong: String, correct: String)] = []

        for rawLine in stripHTMLComments(markdown).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // 去标识化条目不参与转写纠正（由 parsePIIEntries 单独解析）
            if line.contains(piiMarker) { continue }

            // 表格行：| 错误词 | 正确词 | 或 | 术语 |
            if line.hasPrefix("|"), line.hasSuffix("|") {
                let cells = line
                    .dropFirst().dropLast()
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("---") }
                if cells.count >= 2 {
                    pairs.append((cells[0], cells[cells.count - 1]))
                } else if cells.count == 1 {
                    terms.append(cells[0])
                }
                continue
            }

            // 列表项：- 术语 / - 错误词 -> 正确词
            var item = line
            if item.hasPrefix("- ") || item.hasPrefix("* ") {
                item = String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            // 箭头行：错误词 -> 正确词（支持 -> / → / ⇒）
            for arrow in ["->", "→", "=>", "⇒"] {
                if let range = item.range(of: arrow) {
                    let wrong = item[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                    let correct = item[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !wrong.isEmpty && !correct.isEmpty {
                        pairs.append((wrong, correct))
                        item = ""
                    }
                    break
                }
            }
            if item.isEmpty { continue }
            terms.append(item)
        }
        return (terms, pairs)
    }

    /// 术语有效性：长度合理且至少包含一个 CJK 字符
    nonisolated static func isValidTerm(_ term: String) -> Bool {
        guard !term.isEmpty, term.count <= 30 else { return false }
        return isHanString(term)
    }

    /// 是否包含 CJK 统一表意文字（含扩展 A 区）
    nonisolated static func isHanString(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHanScalar($0) }
    }

    /// 单个字符是否为汉字
    nonisolated static func isHanChar(_ char: Character) -> Bool {
        char.unicodeScalars.contains { isHanScalar($0) }
    }

    private nonisolated static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    // MARK: - 去标识化条目（与纠正词条共库，标记区分）

    /// 解析 Markdown 中的去标识化条目（`- 词语 #去标识化:类别`）
    nonisolated static func parsePIIEntries(_ markdown: String) -> [(text: String, category: PIICategory)] {
        var entries: [(text: String, category: PIICategory)] = []
        for rawLine in stripHTMLComments(markdown).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains(piiMarker) else { continue }
            let parts = line.components(separatedBy: piiMarker)
            var text = parts[0].trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("- ") || text.hasPrefix("* ") {
                text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            let category = PIICategory.fromMarkerName(parts.dropFirst().joined(separator: piiMarker))
            if text.count >= 2 { entries.append((text, category)) }
        }
        return entries
    }

    /// 从磁盘扫描全部词典文件中的去标识化条目（去重）。
    /// nonisolated：供 PIIScrubService 在任意并发域调用（如批量总结后台任务）
    /// PII 词典磁盘缓存：scrub() 每次云端请求都会调用 `loadPIIEntriesFromDisk`，
    /// 旧实现每次都重新枚举目录 + 逐文件解析。缓存最近一次结果，写入/重载时失效。
    /// 访问由 piiCacheLock 串行化；类型是 @MainActor，静态存储需显式标 nonisolated
    nonisolated private static let piiCacheLock = NSLock()
    nonisolated(unsafe) private static var piiCacheEntries: [(text: String, category: PIICategory)] = []
    nonisolated(unsafe) private static var piiCacheLoaded = false

    /// 使 PII 磁盘缓存失效（词典写入或重载后调用）
    nonisolated static func invalidatePIIDiskCache() {
        piiCacheLock.lock()
        piiCacheLoaded = false
        piiCacheEntries = []
        piiCacheLock.unlock()
    }

    /// 读取全部去标识化条目（带缓存，写入后经 `invalidatePIIDiskCache` 失效）
    nonisolated static func loadPIIEntriesFromDisk() -> [(text: String, category: PIICategory)] {
        piiCacheLock.lock()
        if piiCacheLoaded {
            let cached = piiCacheEntries
            piiCacheLock.unlock()
            return cached
        }
        piiCacheLock.unlock()

        let loaded = readPIIEntriesFromDisk()

        piiCacheLock.lock()
        piiCacheEntries = loaded
        piiCacheLoaded = true
        piiCacheLock.unlock()
        return loaded
    }

    /// 实际读盘实现（不做缓存）
    private nonisolated static func readPIIEntriesFromDisk() -> [(text: String, category: PIICategory)] {
        let folderURL = DictionaryFolder.defaultURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        var entries: [(text: String, category: PIICategory)] = []
        var seen = Set<String>()
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for entry in parsePIIEntries(content) where seen.insert(entry.text).inserted {
                entries.append(entry)
            }
        }
        return entries
    }

    /// 把去标识化条目追加写入 去标识化.md（与已有条目去重，含文件内与全库）。
    /// 返回实际新增条数。nonisolated 静态实现，供实例方法与旧版 JSON 迁移复用。
    @discardableResult
    nonisolated static func appendPIIEntriesToFile(
        _ entries: [(text: String, category: PIICategory)]
    ) -> Int {
        let valid = entries.filter { $0.text.count >= 2 && !$0.text.contains("[") && !$0.text.contains("#") }
        guard !valid.isEmpty else { return 0 }

        let folderURL = DictionaryFolder.defaultURL
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent(piiFileName)

        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing.isEmpty {
            existing = """
            # 去标识化词典

            <!-- 格式：- 词语 #去标识化:类别
                 这些词语在送云端大模型前会被替换为占位符（如 [人名1]），返回后自动还原。
                 带 #去标识化 标记的条目不参与转写纠正；普通纠正词条可写在其他词典文件。 -->

            """
        }

        var seen = Set(loadPIIEntriesFromDisk().map(\.text))
        var lines: [String] = []
        for entry in valid where seen.insert(entry.text).inserted {
            lines.append("- \(entry.text) \(piiMarker)\(entry.category.markerName)")
        }
        guard !lines.isEmpty else { return 0 }

        if !existing.hasSuffix("\n") { existing += "\n" }
        existing += lines.joined(separator: "\n") + "\n"
        do {
            try existing.write(to: url, atomically: true, encoding: .utf8)
            // 直接写文件（不经过 reload）：此处显式失效 PII 缓存
            Self.invalidatePIIDiskCache()
            return lines.count
        } catch {
            FileSyncService.logWarning("去标识化词典写入失败: \(error.localizedDescription)")
            return 0
        }
    }

    /// 追加去标识化条目并重新加载词典（UI 入口）
    @discardableResult
    func addPIIEntries(_ entries: [(text: String, category: PIICategory)]) -> Int {
        let added = Self.appendPIIEntriesToFile(entries)
        reload()
        return added
    }

    /// 旧版独立 JSON 字典（~/Documents/Memozia/PIIDictionary.json）一次性迁移到统一词典
    nonisolated static func migrateLegacyPIIJSONIfNeeded() {
        struct LegacyEntry: Codable {
            var text: String
            var category: PIICategory
        }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        let legacyURL = base.appendingPathComponent("Memozia").appendingPathComponent("PIIDictionary.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacyEntry].self, from: data)
        else { return }

        let migrated = legacy.map { ($0.text, $0.category) }
        let added = appendPIIEntriesToFile(migrated)
        FileSyncService.logWarning("旧版 PII 字典已迁移到统一词典（新增 \(added) 条），移除 JSON 文件")
        try? FileManager.default.removeItem(at: legacyURL)
    }

    // MARK: - 转写文本纠正

    /// 取词典纠正快照（主线程持锁读一次，返回不可变 Sendable 结构）
    private func correctionSnapshot() -> CorrectionSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        let pairs = exactPairs
            .filter { $0.wrong != $0.correct }
            .map { CorrectionSnapshot.Pair(wrong: $0.wrong, correct: $0.correct) }
        let terms = pinyinTerms.compactMap { term -> CorrectionSnapshot.Term? in
            let chars = Array(term)
            // 术语拼音在此一次性预算：旧实现在每个连续汉字片段内对每个术语重复
            // `Array(term)` + 逐字转拼音，是主线程扫描开销的主要来源
            guard chars.count >= 2 else { return nil }
            return CorrectionSnapshot.Term(
                text: term,
                chars: chars,
                pinyins: chars.map { Self.pinyin(of: $0) }
            )
        }
        return CorrectionSnapshot(pairs: pairs, terms: terms)
    }

    /// 对转写文本应用词典纠正：先精确替换，再拼音匹配替换
    ///
    /// 重活不在 MainActor 上：本方法只在主线程取一次不可变快照，
    /// O(文本长度 × 术语数) 的滑窗扫描交给后台执行器。旧写法是 @MainActor 方法，
    /// 调用点即使包在 `Task.detached` 里也会被调度回主线程执行（"移入后台"实际失效）。
    nonisolated func correct(_ text: String) async -> String {
        let snapshot = await correctionSnapshot()
        guard !text.isEmpty, !snapshot.isEmpty else { return text }
        return await Task.detached(priority: .userInitiated) {
            Self.apply(snapshot: snapshot, to: text)
        }.value
    }

    /// 纯函数纠正实现（可在任意线程执行，拼音缓存走线程安全盒子）
    nonisolated private static func apply(snapshot: CorrectionSnapshot, to text: String) -> String {
        var result = text
        // 1. 精确替换（错误词 → 正确词）
        for pair in snapshot.pairs {
            result = result.replacingOccurrences(of: pair.wrong, with: pair.correct)
        }
        // 2. 拼音匹配替换（只含正确词，自动纠正同音/近音误写）
        return applyPinyinCorrection(snapshot: snapshot, to: result)
    }

    /// 拼音匹配纠正：在连续汉字片段内滑窗比对无声调拼音，读音相同且写法不同的窗口替换为词典术语。
    /// 只在连续汉字片段内匹配，避免命中窗口跨越标点导致吞掉标点。
    nonisolated private static func applyPinyinCorrection(
        snapshot: CorrectionSnapshot,
        to text: String
    ) -> String {
        guard !snapshot.terms.isEmpty else { return text }

        let chars = Array(text)
        // 预计算每个汉字的拼音（缓存去重）
        var pinyins: [String] = []
        pinyins.reserveCapacity(chars.count)
        for char in chars {
            pinyins.append(isHanChar(char) ? pinyin(of: char) : "")
        }

        // 命中的替换（字符数组下标，end 不含）
        var replacements: [(start: Int, end: Int, term: String)] = []

        var index = 0
        while index < chars.count {
            // 跳过非汉字，定位一段连续汉字片段 [runStart, runEnd)
            guard isHanChar(chars[index]) else {
                index += 1
                continue
            }
            let runStart = index
            var runEnd = index
            while runEnd < chars.count && isHanChar(chars[runEnd]) {
                runEnd += 1
            }

            // 在片段内逐个术语滑窗匹配
            for term in snapshot.terms {
                let termCount = term.chars.count
                guard termCount <= runEnd - runStart else { continue }

                var start = runStart
                while start + termCount <= runEnd {
                    let windowPinyins = pinyins[start..<(start + termCount)]
                    if windowPinyins.elementsEqual(term.pinyins) {
                        // 原文窗口与术语完全相同则无需替换
                        if String(chars[start..<(start + termCount)]) != term.text {
                            replacements.append((start, start + termCount, term.text))
                        }
                        start += termCount
                    } else {
                        start += 1
                    }
                }
            }
            index = runEnd
        }

        guard !replacements.isEmpty else { return text }

        // 合并重叠命中（保留靠前者），重建字符串
        replacements.sort {
            $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end
        }
        var applied: [(start: Int, end: Int, term: String)] = []
        var cursor = -1
        for replacement in replacements where replacement.start >= cursor {
            applied.append(replacement)
            cursor = replacement.end
        }

        var resultChars: [Character] = []
        resultChars.reserveCapacity(chars.count)
        var position = 0
        for replacement in applied {
            resultChars.append(contentsOf: chars[position..<replacement.start])
            resultChars.append(contentsOf: replacement.term)
            position = replacement.end
        }
        resultChars.append(contentsOf: chars[position..<chars.count])
        return String(resultChars)
    }

    /// 单个汉字的无声调拼音（线程安全共享缓存：只作性能用途，跨录音/跨线程复用）
    nonisolated private static func pinyin(of char: Character) -> String {
        if let cached = pinyinCacheBox.get(char) { return cached }
        let value = rawPinyin(of: char)
        pinyinCacheBox.set(char, value)
        return value
    }


    /// CFStringTransform 转拼音并归一化：小写、去声调、去分隔符
    nonisolated static func rawPinyin(of char: Character) -> String {
        guard let mutable = CFStringCreateMutableCopy(nil, 0, String(char) as CFString) else {
            return ""
        }
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (mutable as String)
            .lowercased()
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "u:", with: "u")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "")
        return result
    }

    /// 示例词典内容
    nonisolated static let sampleMarkdown = """
    # 语音解析词典

    <!-- 每行一条。三种写法：
    1. - 术语            按拼音自动纠正（推荐，无需知道错误写法）
    2. | 错误词 | 正确词 |  精确替换
    3. 错误词 -> 正确词   精确替换
    -->

    ## 团队与产品术语
    - 语忆笔记
    - 灵犀引擎
    - 星辰大模型

    ## 常见误写纠正
    | 语义识别 | 语音识别 |
    | 边成协议 | 编码协议 |
    """
}

// MARK: - 词典纠正快照与共享拼音缓存

/// 词典纠正快照：不可变 + Sendable，主线程持锁读一次即可安全交给后台扫描
struct CorrectionSnapshot: Sendable {
    struct Pair: Sendable {
        let wrong: String
        let correct: String
    }

    /// 参与拼音纠正的术语（含预拆字符与预读拼音，避免滑窗内重复分配）
    struct Term: Sendable {
        let text: String
        let chars: [Character]
        let pinyins: [String]
    }

    let pairs: [Pair]
    let terms: [Term]

    var isEmpty: Bool { pairs.isEmpty && terms.isEmpty }
}

/// 汉字 → 无声调拼音的线程安全缓存盒。
/// 显式的 get/set 方法而非暴露字典：`box.value[c] = x` 会先整字典拷贝再写回，
/// 逐字插入时是二次方开销。
final class PinyinCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Character: String] = [:]

    func get(_ char: Character) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[char]
    }

    func set(_ char: Character, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        cache[char] = value
    }
}

/// 拼音缓存按字符键复用、与词典内容无关，进程级共享即可（跨录音、跨线程命中）
private let pinyinCacheBox = PinyinCacheBox()
