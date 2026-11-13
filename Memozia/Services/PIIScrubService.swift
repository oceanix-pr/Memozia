import Foundation
import os.log

/// PII（个人/敏感信息）类别
enum PIICategory: String, Codable, CaseIterable, Sendable {
    case person, company, brand, location, account, password, phone, idcard, email, other

    var displayName: String {
        switch self {
        case .person:   return String(localized: "人员姓名")
        case .company:  return String(localized: "公司名")
        case .brand:    return String(localized: "品牌名")
        case .location: return String(localized: "国家/地区/城市")
        case .account:  return String(localized: "账号")
        case .password: return String(localized: "密码")
        case .phone:    return String(localized: "手机号")
        case .idcard:   return String(localized: "身份证号")
        case .email:    return String(localized: "邮箱")
        case .other:    return String(localized: "其他")
        }
    }

    /// 去标识化占位符前缀，如 [人名1]
    ///
    /// **有意不本地化**：占位符会随提示词发给模型并要求原样回显，`restore` 也按前缀
    /// 解析；提示词不随界面语言变化，若前缀本地化会导致提示词、模型输出与还原三者
    /// 语言口径不一致。界面展示的类别名请用 `displayName`。
    var tokenPrefix: String {
        switch self {
        case .person:   return "人名"
        case .company:  return "公司"
        case .brand:    return "品牌"
        case .location: return "地区"
        case .account:  return "账号"
        case .password: return "密码"
        case .phone:    return "电话"
        case .idcard:   return "证件"
        case .email:    return "邮箱"
        case .other:    return "其他"
        }
    }

    /// 词典文件标记用的固定类别名（不本地化，避免文件内容随系统语言变化）
    var markerName: String {
        switch self {
        case .person:   return "人员姓名"
        case .company:  return "公司名"
        case .brand:    return "品牌名"
        case .location: return "地区"
        case .account:  return "账号"
        case .password: return "密码"
        case .phone:    return "手机号"
        case .idcard:   return "身份证号"
        case .email:    return "邮箱"
        case .other:    return "其他"
        }
    }

    /// 由标记类别名反查（未知类别归入其他）
    static func fromMarkerName(_ name: String) -> PIICategory {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return allCases.first { $0.markerName == trimmed } ?? .other
    }
}

/// 一次去标识化产生的“占位符 → 原文”映射（Sendable，可跨并发域传递给还原环节）
struct PIIScrubMapping: Sendable {
    let pairs: [(token: String, original: String)]

    static let empty = PIIScrubMapping(pairs: [])

    var isEmpty: Bool { pairs.isEmpty }
}

/// PII 去标识化服务
///
/// 送入云端大模型前把敏感信息替换为占位符（如“张伟”→“[人名1]”、手机号→“[电话1]”），
/// 收到返回后再按映射还原。两层来源：
/// 1. 词典中带 `#去标识化:` 标记的条目（与转写纠正词条共库存储，见 TranscriptDictionaryService），
///    覆盖公司/品牌/姓名/地区/账号/密码等；
/// 2. 正则自动检测（手机号/身份证号/邮箱），无需词典即可生效。
/// 除声纹同步外均为无共享状态的静态方法，可在任意并发域调用。
enum PIIScrubService {

    // MARK: - 词典来源与声纹同步

    /// 把声纹库中的全部姓名写入去标识化词典（人员姓名类别，去重）。
    /// 仅在主线程调用（词典服务为 @MainActor）。
    /// - Returns: 新增条目数
    @MainActor
    static func syncFromVoiceprints() -> Int {
        let entries: [(text: String, category: PIICategory)] = VoiceprintStore.loadAll()
            .map { ($0.name.trimmingCharacters(in: .whitespacesAndNewlines), PIICategory.person) }
        return TranscriptDictionaryService.shared.addPIIEntries(entries)
    }

    // MARK: - 去标识化 / 还原

    /// 对文本做去标识化：先字典替换（长词优先），再正则检测手机号/身份证号/邮箱。
    /// 返回替换后的文本与映射关系（供还原使用）。
    static func scrub(_ text: String) -> (scrubbed: String, mapping: PIIScrubMapping) {
        guard !text.isEmpty else { return (text, .empty) }
        var result = text
        var pairs: [(token: String, original: String)] = []
        var counters: [PIICategory: Int] = [:]

        func makeToken(_ category: PIICategory) -> String {
            counters[category, default: 0] += 1
            return "[\(category.tokenPrefix)\(counters[category]!)]"
        }

        // 1. 词典中带 #去标识化 标记的条目：按长度降序替换，避免短词先替换破坏长词
        let entries = TranscriptDictionaryService.loadPIIEntriesFromDisk()
            .filter { $0.text.count >= 2 && !$0.text.contains("[") }
            .sorted { $0.text.count > $1.text.count }
        for entry in entries where result.contains(entry.text) {
            let token = makeToken(entry.category)
            result = result.replacingOccurrences(of: entry.text, with: token)
            pairs.append((token, entry.text))
        }

        // 2. 正则自动检测（在字典替换之后执行，避免重复替换）
        let patterns: [(pattern: String, category: PIICategory)] = [
            // 中国大陆手机号
            (#"(?<!\d)(1[3-9]\d{9})(?!\d)"#, .phone),
            // 18 位身份证号（末位可为 X/x）
            (#"(?<!\d)(\d{17}[\dXx])(?!\d)"#, .idcard),
            // 邮箱
            (#"([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#, .email),
        ]
        for item in patterns {
            guard let regex = cachedRegex(pattern: item.pattern) else { continue }
            let nsText = result as NSString
            let matches = regex.matches(
                in: result, range: NSRange(location: 0, length: nsText.length))
            guard !matches.isEmpty else { continue }
            let mutable = NSMutableString(string: result)
            // 从后往前替换，避免 range 偏移
            for match in matches.reversed() {
                let original = nsText.substring(with: match.range)
                let token = makeToken(item.category)
                mutable.replaceCharacters(in: match.range, with: token)
                pairs.append((token, original))
            }
            result = mutable as String
        }

        return (result, PIIScrubMapping(pairs: pairs))
    }

    // MARK: - 正则缓存

    /// NSRegularExpression 编译成本高，而流式总结每 100ms 就会触发一次还原。
    /// 旧实现每次为每个映射重新编译一条正则；正则对象本身线程安全，可全局复用。
    private static let regexCacheLock = NSLock()
    /// 访问由 regexCacheLock 串行化；NSRegularExpression 本身线程安全
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]

    private static func cachedRegex(pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        if let cached = regexCache[pattern] {
            regexCacheLock.unlock()
            return cached
        }
        regexCacheLock.unlock()
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCacheLock.lock()
        // 上限保护：占位符种类有限，正常远达不到；极端情况下整体清空重建
        if regexCache.count >= 512 { regexCache.removeAll(keepingCapacity: true) }
        regexCache[pattern] = regex
        regexCacheLock.unlock()
        return regex
    }

    /// 用去标识化时产生的映射把占位符还原为原文。
    ///
    /// 单遍实现：把全部占位符的宽松变体合并为一条正则，一次扫描完成替换。
    /// 旧实现是「每个映射：编译一条正则 + 全文替换一次」，成本 O(映射数 × 文本长度)，
    /// 流式总结每 100ms 调用一次会随词条数与文本长度增长迅速卡死主线程。
    ///
    /// 宽松变体兼容模型偶发输出（全角括号 ［人名1］、内嵌空格 [人名 1]、
    /// Markdown 转义 \\[人名1] 及单侧转义），转义反斜杠随匹配一并消费。
    static func restore(_ text: String, mapping: PIIScrubMapping) -> String {
        guard !mapping.isEmpty, !text.isEmpty else { return text }

        let (pattern, lookup) = combinedRestorePattern(for: mapping)
        guard !lookup.isEmpty, let regex = cachedRegex(pattern: pattern) else {
            // 正则构建失败等极端情况：退化为逐对精确替换（token 长度降序，
            // 防止 [人名1] 误伤 [人名10]）
            return exactRestoreFallback(text, mapping: mapping)
        }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        // 从后往前替换，避免 range 偏移；原文直接写入（不再经替换模板语法），
        // 顺带消除原文含 $ 或 \ 时被当作模板语法的隐患
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            guard let key = restoreLookupKey(matched), let original = lookup[key] else { continue }
            mutable.replaceCharacters(in: match.range, with: original)
        }
        return mutable as String
    }

    /// 合并还原正则 + 「匹配文本 → 原文」查找表。
    /// 查找键为去掉转义/括号/空白后的 “前缀+序号”，与 `parseToken` 结果一致。
    private static func combinedRestorePattern(
        for mapping: PIIScrubMapping
    ) -> (pattern: String, lookup: [String: String]) {
        var fragments: [String] = []
        var lookup: [String: String] = [:]
        for pair in mapping.pairs {
            guard let (prefix, number) = parseToken(pair.token) else { continue }
            fragments.append(flexibleTokenPattern(prefix: prefix, number: number))
            lookup[prefix + number] = pair.original
        }
        return (fragments.joined(separator: "|"), lookup)
    }

    /// 从宽松匹配到的文本还原出查找键：去掉转义反斜杠、半/全角方括号与空白。
    /// 每个片段的「编号」后必须以 `]`/`］` 收尾，故 `[人名1]` 不会误配 `[人名10]`。
    private static func restoreLookupKey(_ matched: String) -> String? {
        var key = matched
        key.removeAll { ch in
            ch == "\\" || ch == "[" || ch == "]" || ch == "［" || ch == "］" || ch.isWhitespace
        }
        return key.isEmpty ? nil : key
    }

    /// 兜底还原：逐对精确替换（仅在正则不可用时使用）
    private static func exactRestoreFallback(_ text: String, mapping: PIIScrubMapping) -> String {
        var result = text
        for pair in mapping.pairs.sorted(by: { $0.token.count > $1.token.count }) {
            result = result.replacingOccurrences(of: pair.token, with: pair.original)
        }
        return result
    }

    /// 还原并输出诊断日志（只记数量，不写原文内容）：
    /// mapping=映射条目数，matchedInRaw=模型输出中实际出现的标准占位符数。
    /// matchedInRaw 明显小于 mapping 说明模型丢弃或改写了占位符（总结会缺人名、
    /// 提示词规则未生效），而非客户端还原失败；matchedInRaw 正常但总结仍缺人名
    /// 则应检查变体兜底是否命中。
    static func restoreWithDiagnostics(_ text: String, mapping: PIIScrubMapping) -> String {
        guard !mapping.isEmpty, !text.isEmpty else { return text }
        let matchedInRaw = mapping.pairs.filter { text.contains($0.token) }.count
        let restored = restore(text, mapping: mapping)
        diagLogger.info(
            "mapping=\(mapping.pairs.count, privacy: .public) matchedInRaw=\(matchedInRaw, privacy: .public)")
        return restored
    }

    private static let diagLogger = Logger(subsystem: "app.memozia", category: "PIIRestore")

    /// 拆解 "[人名12]" → (prefix: "人名", number: "12")，非占位符格式返回 nil
    private static func parseToken(_ token: String) -> (prefix: String, number: String)? {
        guard token.hasPrefix("["), token.hasSuffix("]"), token.count > 2 else { return nil }
        let inner = token[token.index(after: token.startIndex)..<token.index(before: token.endIndex)]
        var splitIndex = inner.endIndex
        while splitIndex > inner.startIndex, inner[inner.index(before: splitIndex)].isNumber {
            splitIndex = inner.index(before: splitIndex)
        }
        guard splitIndex > inner.startIndex, splitIndex < inner.endIndex else { return nil }
        return (String(inner[..<splitIndex]), String(inner[splitIndex...]))
    }

    /// 占位符变体的宽松匹配：兼容 \\[ 转义、全角［］、括号内外空格。
    /// 注意正则转义层级：Swift 源码 "\\\\?" 才是正则的“可选字面反斜杠”
    private static func flexibleTokenPattern(prefix: String, number: String) -> String {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        return "\\\\?[\\[［]\\s*" + escapedPrefix + "\\s*" + number + "\\s*\\\\?[\\]］]"
    }

    /// 还原待办文档中的所有文本字段
    static func restore(_ document: TodoDocument, mapping: PIIScrubMapping) -> TodoDocument {
        guard !mapping.isEmpty else { return document }
        var restored = document
        restored.items = document.items.map { item in
            var copy = item
            copy.title = restore(item.title, mapping: mapping)
            copy.notes = item.notes.map { restore($0, mapping: mapping) }
            copy.evidenceQuote = item.evidenceQuote.map { restore($0, mapping: mapping) }
            copy.owner = item.owner.map { restore($0, mapping: mapping) }
            return copy
        }
        return restored
    }
}
