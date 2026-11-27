import Foundation

/// Processing choices travel with the entry, independently of the Mac's interface language.
struct EntryLanguageOptions: Codable, Equatable, Sendable {
    static let didChange = Notification.Name("entryLanguageOptionsDidChange")

    var spoken: WhisperLanguage?
    var script: TranscriptScript?
    var output: String = ""

    /// Old recordings without a dedicated folder share the storage root and need their own filename.
    static func file(in folder: URL, legacyID: UUID? = nil) -> URL {
        let name = legacyID.map { ".languages-\($0.uuidString).json" } ?? "languages.json"
        return folder.appendingPathComponent(name)
    }

    static func load(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    /// Read the latest choices before updating one field. A damaged file is never overwritten.
    @MainActor static func update(at url: URL, _ edit: (inout Self) -> Void) throws -> Self {
        var options = try load(from: url)
        edit(&options)
        try JSONEncoder().encode(options).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: didChange, object: url)
        return options
    }

    /// Legacy preferences sit beside the original audio and are removed when that entry is deleted.
    static func removeLegacyFile(in folder: URL, id: UUID) throws {
        do {
            try FileManager.default.removeItem(at: file(in: folder, legacyID: id))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    func applying(to config: STTConfig) -> STTConfig {
        var result = config
        if let spoken { result.language = spoken.rawValue }
        if let script { result.script = script }
        return result
    }
}

enum TranscriptScript: String, CaseIterable, Codable, Sendable {
    case original, simplified, traditional

    var name: String {
        switch self {
        case .original: String(localized: "保留原文")
        case .simplified: String(localized: "中文（简体）")
        case .traditional: String(localized: "中文（繁體）")
        }
    }
}

enum ContentLanguages {
    static let choices: [(code: String, nativeName: String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English"),
        ("ja", "日本語"), ("ko", "한국어"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"),
        ("uk", "Українська"), ("nl", "Nederlands"), ("pl", "Polski"), ("tr", "Türkçe"),
        ("ar", "العربية"), ("hi", "हिन्दी"), ("id", "Bahasa Indonesia"),
        ("sv", "Svenska"), ("th", "ไทย"), ("vi", "Tiếng Việt")
    ]

    static func outputInstruction(_ code: String) -> String {
        let target = choices.first { $0.code == code }?.code
        let language = target.map { "使用 BCP 47 语言 \($0) 输出" } ?? "使用原始录音或笔记内容的主要语言输出"
        return "\n\n本次输出语言：\(language)，包括标题、小标题及待办正文。模板中的中文小标题只是结构示例。保留原文引语、专有名词、JSON 字段名与枚举值。"
    }
}
