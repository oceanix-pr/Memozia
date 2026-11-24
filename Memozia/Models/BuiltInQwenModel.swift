import Foundation

/// The built-in model has an identity independent of editable API configurations.
enum BuiltInQwenModel {
    static let id = UUID(uuidString: "49D77A4F-2473-4D89-AD27-8BDA49CB3502")!
    static let baseURL = "memozia-builtin://qwen3.5-2b"
    static let repository = "mlx-community/Qwen3.5-2B-4bit"
    static let revision = "674aaa7240b91e8012fcad5d791b7dfe5ba90207"
    static let contextTokens = 8_192
    static let outputTokens = 2_048

    struct File: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    // Both download sources must deliver these exact, pinned model bytes.
    static let files: [File] = [
        .init(name: "chat_template.jinja", size: 7755, sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"),
        .init(name: "config.json", size: 3113, sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"),
        .init(name: "model.safetensors", size: 1722271785, sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"),
        .init(name: "model.safetensors.index.json", size: 81722, sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"),
        .init(name: "preprocessor_config.json", size: 390, sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"),
        .init(name: "processor_config.json", size: 1300, sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"),
        .init(name: "tokenizer.json", size: 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
        .init(name: "tokenizer_config.json", size: 1139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
        .init(name: "video_preprocessor_config.json", size: 385, sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"),
        .init(name: "vocab.json", size: 6722759, sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"),
    ]

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static var folder: URL {
        #if DEBUG
        if AppRuntime.isRunningTests,
           ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_BUILTIN_QWEN"] == "1",
           let path = ProcessInfo.processInfo.environment["MEMOZIA_BUILTIN_TEST_FOLDER"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return AudioRecording.defaultStorageDirectory
            .appendingPathComponent("LLM/Qwen3.5-2B/" + revision, isDirectory: true)
    }

    static var legacyFolder: URL? {
        // Tests must never migrate or delete the user's installed model.
        guard !AppRuntime.isRunningTests, !AppRuntime.isUITesting else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memozia/BuiltInModels/Qwen3.5-2B/" + revision, isDirectory: true)
    }

    static func isReady(at directory: URL = folder) -> Bool {
        guard (try? String(contentsOf: directory.appendingPathComponent(".ready"), encoding: .utf8)) == revision else {
            return false
        }
        return files.allSatisfy { file in
            let size = try? directory.appendingPathComponent(file.name).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == file.size
        }
    }

    static func source(for localization: String) -> WhisperModelSource {
        let language = Locale.Language(identifier: localization)
        return language.languageCode?.identifier == "zh" && language.script?.identifier == "Hans"
            ? .hfMirror : .huggingFace
    }

    static var defaultSource: WhisperModelSource {
        source(for: Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func downloadURL(for file: File, source: WhisperModelSource) -> URL {
        URL(string: "\(source.endpoint)/\(repository)/resolve/\(revision)/\(file.name)")!
    }
}

extension LLMConfig {
    @MainActor static let builtInQwen: LLMConfig = {
        let config = LLMConfig(
            name: String(localized: "内置 Qwen3.5-2B"),
            baseURL: BuiltInQwenModel.baseURL,
            modelName: BuiltInQwenModel.repository,
            isLocal: true,
            supportsVision: true
        )
        config.id = BuiltInQwenModel.id
        return config
    }()

    var isBuiltIn: Bool {
        baseURL == BuiltInQwenModel.baseURL && modelName == BuiltInQwenModel.repository
    }
}

enum BuiltInModelError: LocalizedError {
    case notDownloaded
    case busy
    case invalidDownload
    case insufficientSpace
    case contextTooLong
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .notDownloaded: String(localized: "请先下载内置 Qwen3.5-2B 模型。")
        case .busy: String(localized: "内置模型正在下载或使用中，请稍后重试。")
        case .invalidDownload: String(localized: "内置模型校验失败，请重新下载。")
        case .insufficientSpace: String(localized: "磁盘可用空间不足，下载内置模型需要至少 4 GB。")
        case .contextTooLong: String(localized: "内容超过内置模型的处理长度，请缩短内容或选择更大的模型。")
        case .invalidImage: String(localized: "内置模型无法读取这张图片，请重新选择图片。")
        }
    }
}
