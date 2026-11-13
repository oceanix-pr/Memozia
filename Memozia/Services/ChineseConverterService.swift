import Foundation

/// 中文繁简转换服务（基于 OpenCC 字典）
///
/// 使用内置的 OpenCC 字典文件进行繁简转换，支持词组级转换。
/// - 简体中文：繁转简（TSCharacters.txt + TSPhrases.txt）
/// - 繁体中文：简转繁（STCharacters.txt + STPhrases.txt）
/// - 其他语言：原样返回
///
/// 转换算法：先按词组字典做最长匹配替换，再按字符字典替换剩余单字。
actor ChineseConverterService {

    /// 共享单例（线程安全）
    static let shared = ChineseConverterService()

    // MARK: - 类型

    /// 转换方向
    private enum Direction {
        /// 繁转简（简体中文目标）
        case traditionalToSimplified
        /// 简转繁（繁体中文目标）
        case simplifiedToTraditional
    }

    // MARK: - 状态

    /// 已加载的转换器缓存
    private var tsConverter: ChineseDictConverter?
    private var stConverter: ChineseDictConverter?

    private init() {}

    // MARK: - 公开接口

    /// 将文本转换为目标语言变体
    /// - Parameters:
    ///   - text: 原始文本
    ///   - language: 目标语言代码（对应 `WhisperLanguage.rawValue`）
    /// - Returns: 转换后的文本；若无需转换或加载失败则返回原文
    func convert(_ text: String, to language: String) -> String {
        guard !text.isEmpty else { return text }

        let direction: Direction
        switch language {
        case WhisperLanguage.zh.rawValue:
            direction = .traditionalToSimplified
        case WhisperLanguage.zhYue.rawValue:
            direction = .simplifiedToTraditional
        default:
            return text
        }

        do {
            let converter = try getOrCreateConverter(for: direction)
            return converter.convert(text)
        } catch {
            print("[ChineseConverter] 转换失败: \(error.localizedDescription)，返回原文")
            return text
        }
    }

    // MARK: - 内部

    private func getOrCreateConverter(for direction: Direction) throws -> ChineseDictConverter {
        switch direction {
        case .traditionalToSimplified:
            if let converter = tsConverter {
                return converter
            }
            let converter = try ChineseDictConverter.load(
                phrasesFile: "TSPhrases",
                charactersFile: "TSCharacters",
                fileExtension: "txt"
            )
            tsConverter = converter
            return converter
        case .simplifiedToTraditional:
            if let converter = stConverter {
                return converter
            }
            let converter = try ChineseDictConverter.load(
                phrasesFile: "STPhrases",
                charactersFile: "STCharacters",
                fileExtension: "txt"
            )
            stConverter = converter
            return converter
        }
    }
}

// MARK: - 字典转换器

/// 基于字典的中文转换器
///
/// 加载 OpenCC 字典文件（TSV 格式：`key\tvalue`），构建映射表后做最长前缀匹配替换。
private final class ChineseDictConverter {

    /// 词组映射表（最长匹配优先）
    private let phrases: [String: String]

    /// 单字映射表
    private let characters: [String: String]

    /// 按首字符分组的词组 key，每组内按长度降序排列，用于快速最长匹配
    private let phrasesByFirstChar: [Character: [String]]

    private init(phrases: [String: String], characters: [String: String]) {
        self.phrases = phrases
        self.characters = characters
        // 按首字符分组，组内按长度降序
        var grouped: [Character: [String]] = [:]
        for key in phrases.keys {
            guard let first = key.first else { continue }
            grouped[first, default: []].append(key)
        }
        for (ch, keys) in grouped {
            grouped[ch] = keys.sorted { $0.count > $1.count }
        }
        self.phrasesByFirstChar = grouped
    }

    /// 从 Bundle 加载字典文件
    static func load(
        phrasesFile: String,
        charactersFile: String,
        fileExtension: String
    ) throws -> ChineseDictConverter {
        let phrases = try loadDictionary(name: phrasesFile, ext: fileExtension)
        let characters = try loadDictionary(name: charactersFile, ext: fileExtension)
        return ChineseDictConverter(phrases: phrases, characters: characters)
    }

    /// 加载单个字典文件为映射表
    private static func loadDictionary(name: String, ext: String) throws -> [String: String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw NSError(
                domain: "ChineseConverter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "找不到字典文件 \(name).\(ext)"]
            )
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        var mapping: [String: String] = [:]

        content.enumerateLines { line, _ in
            // 跳过空行和注释行
            guard !line.isEmpty, !line.hasPrefix("#") else { return }
            // 格式：key\tvalue (value 可能多个，用空格分隔，取第一个)
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let key = String(parts[0])
            // 多个候选值用空格分隔，取第一个
            let value = String(parts[1]).split(separator: " ").first.map(String.init) ?? String(parts[1])
            if !key.isEmpty {
                mapping[key] = value
            }
        }

        return mapping
    }

    /// 转换文本：先做词组级最长匹配，再做字符级替换
    func convert(_ text: String) -> String {
        guard !phrases.isEmpty || !characters.isEmpty else { return text }

        // 第一步：词组级最长匹配替换
        let afterPhrases = replacePhrases(in: text)
        // 第二步：字符级替换
        let afterCharacters = replaceCharacters(in: afterPhrases)
        return afterCharacters
    }

    /// 词组级最长匹配替换
    private func replacePhrases(in text: String) -> String {
        guard !phrasesByFirstChar.isEmpty else { return text }

        let chars = Array(text)
        var result = ""
        result.reserveCapacity(text.count)
        var i = 0

        while i < chars.count {
            let currentChar = chars[i]
            var matched = false

            // 只检查以当前字符开头的词组
            if let candidates = phrasesByFirstChar[currentChar] {
                for key in candidates {
                    let keyChars = Array(key)
                    let keyLen = keyChars.count
                    guard i + keyLen <= chars.count else { continue }

                    // 首字符已匹配，检查剩余部分
                    var allMatch = true
                    for j in 1..<keyLen {
                        if chars[i + j] != keyChars[j] {
                            allMatch = false
                            break
                        }
                    }

                    if allMatch {
                        if let value = phrases[key] {
                            result.append(value)
                            i += keyLen
                            matched = true
                            break
                        }
                    }
                }
            }

            if !matched {
                result.append(currentChar)
                i += 1
            }
        }

        return result
    }

    /// 字符级替换
    private func replaceCharacters(in text: String) -> String {
        guard !characters.isEmpty else { return text }
        return String(text.map { char -> Character in
            // 取替换字符串的首字符；多字候选取第一个
            if let replacement = characters[String(char)], let first = replacement.first {
                return first
            }
            return char
        })
    }
}
