import Foundation
import SwiftData
import Security
import KeychainAccess

/// LLM 预设配置（支持云端 API / LM Studio / Ollama）
@Model
final class LLMConfig {
    var id: UUID
    var name: String          // 显示名称
    var baseURL: String       // API Base URL
    var modelName: String     // 模型名称
    var isLocal: Bool         // 是否为本地模型
    /// 是否支持视觉（图片）输入，用于快捷笔记图片直发 LLM
    var supportsVision: Bool = false
    /// Explicit cleartext RFC1918 LAN consent; old configurations must opt in again.
    var allowInsecureLAN: Bool = false
    var scrubLoopbackText: Bool = false

    init(
        name: String,
        baseURL: String,
        modelName: String,
        isLocal: Bool = false,
        supportsVision: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.modelName = modelName
        self.isLocal = isLocal
        self.supportsVision = supportsVision
    }
}

// MARK: - 计算属性（@Model 要求放在 extension 中）
extension LLMConfig {
    /// 完整的 Chat Completions API 端点 URL（安全构造，不 force unwrap）
    var chatCompletionsURL: URL? {
        Self.endpointURL(forBaseURL: baseURL, appending: "chat/completions")
    }

    // MARK: - 端点构造

    /// 规范化并校验 Base URL。返回去掉末尾 `/` 的字符串与解析后的组件；
    /// 不满足 http(s) + 有主机名即视为无效（与旧实现同一套校验）
    static func normalizedBaseURL(_ rawBaseURL: String) -> (base: String, components: URLComponents)? {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        var base = trimmed
        while base.hasSuffix("/") { base.removeLast() }
        return (base, components)
    }

    /// 由 Base URL 拼出 OpenAI 兼容端点。静态方法：设置页在不持有 SwiftData
    /// 实例（例如刚填好 API Key、尚未保存）时也要能推导端点。
    ///
    /// 拼接规则（各家端点路径不同，统一硬拼 `/v1` 会让一部分服务直接 404）：
    /// 1. Base URL 已写到 `/chat/completions`：替换叶子端点，不再重复拼接；
    /// 2. Base URL 不带路径（如 `https://api.openai.com`）：补 `/v1` 再拼叶子；
    /// 3. Base URL 自带版本路径（智谱 `.../api/paas/v4`、通义千问
    ///    `.../compatible-mode/v1`、Moonshot `.../v1`）：只拼叶子。
    static func endpointURL(forBaseURL rawBaseURL: String, appending leaf: String) -> URL? {
        guard let normalized = normalizedBaseURL(rawBaseURL) else { return nil }
        var base = normalized.base
        let chatLeaf = "/chat/completions"
        if base.hasSuffix(chatLeaf) {
            base = String(base.dropLast(chatLeaf.count))
        } else if normalized.components.path.isEmpty || normalized.components.path == "/" {
            base += "/v1"
        }
        return URL(string: "\(base)/\(leaf)")
    }

    /// 从 Keychain 读取此配置的 API Key。
    /// 只读便捷入口：读取失败（含系统不可用）与「没有 Key」对请求组包是一回事，
    /// 因此这里吞掉错误返回空串；需要区分失败原因时必须用 `LLMKeychainStore.readAPIKey(for:)`。
    var apiKey: String {
        (try? LLMKeychainStore.readAPIKey(for: id)) ?? ""
    }

    /// 将 API Key 写入 Keychain（空串表示清除）。错误由调用方处理，不静默吞掉
    func setAPIKey(_ key: String) throws {
        if key.isEmpty {
            try LLMKeychainStore.removeAPIKey(for: id)
        } else {
            try LLMKeychainStore.writeAPIKey(key, for: id)
        }
    }
}

// MARK: - Keychain 存取辅助

/// 钥匙串操作失败原因。`errorDescription` 只描述操作类别，绝不含 API Key 内容
enum LLMKeychainError: Error, LocalizedError, Equatable {
    /// 系统钥匙串不可用（无可用钥匙串、组件未就绪等）
    case keychainUnavailable
    /// 无权限或用户拒绝（认证失败、用户取消、需要交互但不可用等）
    case accessDenied
    /// 条目不存在
    case itemNotFound
    /// 值无法编码写入
    case encodingFailed
    /// 其他 OSStatus
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable:
            return String(localized: "系统钥匙串不可用，请稍后重试。")
        case .accessDenied:
            return String(localized: "无权限访问系统钥匙串，或操作被拒绝。")
        case .itemNotFound:
            return String(localized: "钥匙串中未找到对应的条目。")
        case .encodingFailed:
            return String(localized: "内容无法编码写入系统钥匙串。")
        case .osStatus(let status):
            return String(format: String(localized: "钥匙串操作失败（错误码 %d）。"), status)
        }
    }

    /// 由底层 OSStatus 归类。纯函数：不触碰钥匙串，便于确定性单测
    static func from(osStatus: OSStatus) -> LLMKeychainError {
        switch osStatus {
        case errSecNotAvailable, errSecNoSuchKeychain, errSecInvalidKeychain, errSecNoDefaultKeychain:
            return .keychainUnavailable
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed,
             errSecInteractionRequired, errSecMissingEntitlement, errSecNoAccessForItem:
            return .accessDenied
        case errSecItemNotFound:
            return .itemNotFound
        case errSecDecode, Status.conversionError.rawValue:
            return .encodingFailed
        default:
            return .osStatus(osStatus)
        }
    }

    /// 由抛出的底层错误归类。KeychainAccess 的失败均以 `Status`（rawValue 即 OSStatus）抛出，
    /// 少数路径抛 NSError（OSStatus 域），其余归入 `osStatus`
    static func mapping(_ error: Error) -> LLMKeychainError {
        if let keychainError = error as? LLMKeychainError {
            return keychainError
        }
        if let status = error as? Status {
            return from(osStatus: status.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return from(osStatus: OSStatus(nsError.code))
        }
        return .osStatus(OSStatus(nsError.code))
    }
}

enum LLMKeychainStore {
    private static let service = "app.memozia.llm-apikeys"

    private static var keychain: Keychain {
        Keychain(service: service).accessibility(.afterFirstUnlock)
    }

    /// 读取 Key。区分不了「没有 Key」与「读失败」的调用点（例如请求组包）
    /// 走 `LLMConfig.apiKey` 这一便利属性；写入/删除/编辑器保存/删除流程
    /// 必须用这里的 throwing 版本，不能把「写失败」伪装成成功。
    static func readAPIKey(for id: UUID) throws -> String? {
        do {
            return try keychain.get(id.uuidString)
        } catch {
            throw LLMKeychainError.mapping(error)
        }
    }

    static func writeAPIKey(_ key: String, for id: UUID) throws {
        do {
            try keychain.set(key, key: id.uuidString)
        } catch {
            throw LLMKeychainError.mapping(error)
        }
    }

    /// 删除：条目本就不存在视为成功（幂等），避免「已清除的 Key 再删一次」直接报错
    static func removeAPIKey(for id: UUID) throws {
        do {
            try keychain.remove(id.uuidString)
        } catch LLMKeychainError.itemNotFound {
            return
        } catch {
            throw LLMKeychainError.mapping(error)
        }
    }
}

// MARK: - 编辑草稿（不持久化）

/// LLM 配置的编辑草稿：与 SwiftData 模型解耦。
///
/// 编辑器只改草稿，取消即丢弃，数据库与 Keychain 都不会被「编辑一半」的状态污染；
/// 只有保存时才按「校验 → 写 Keychain → 更新/插入模型 → save」的顺序落盘。
/// API Key 不在模型里（模型只存 id，Key 按 id 存 Keychain），因此单独作为字段携带。
struct LLMConfigDraft: Equatable {
    var id: UUID
    var name: String
    var baseURL: String
    var modelName: String
    var isLocal: Bool
    var supportsVision: Bool
    var allowInsecureLAN: Bool = false
    var scrubLoopbackText: Bool = false
    var apiKey: String

    init(
        id: UUID = UUID(),
        name: String = "",
        baseURL: String = "",
        modelName: String = "",
        isLocal: Bool = false,
        supportsVision: Bool = false,
        apiKey: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelName = modelName
        self.isLocal = isLocal
        self.supportsVision = supportsVision
        self.apiKey = apiKey
    }

    /// 从已有配置拷贝（含 id 与 Keychain 中当前的 API Key）
    init(from config: LLMConfig) {
        self.init(
            id: config.id,
            name: config.name,
            baseURL: config.baseURL,
            modelName: config.modelName,
            isLocal: config.isLocal,
            supportsVision: config.supportsVision,
            apiKey: config.apiKey
        )
        allowInsecureLAN = config.allowInsecureLAN
        scrubLoopbackText = config.scrubLoopbackText
    }

    /// 把草稿内容写回模型。API Key 不在模型里，由调用方单独写 Keychain；
    /// 身份（`id`）不随草稿改动：Keychain 按 id 存取，改 id 会让已存 Key 失联
    func apply(to config: LLMConfig) {
        config.name = name
        config.baseURL = baseURL
        config.modelName = modelName
        config.isLocal = isLocal
        config.supportsVision = supportsVision
        config.allowInsecureLAN = allowInsecureLAN
        config.scrubLoopbackText = scrubLoopbackText
    }

    /// 保存前校验：名称/Base URL/模型名非空，端点沿用请求路径同一套安全校验
    /// （云端强制 HTTPS，本地模型/回环放行明文 HTTP）
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMConfigValidationError.emptyName
        }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            throw LLMConfigValidationError.emptyBaseURL
        }
        guard !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMConfigValidationError.emptyModelName
        }
        guard LLMConfig.normalizedBaseURL(trimmedBaseURL) != nil else {
            throw LLMConfigValidationError.invalidURL
        }
        do {
            try EndpointPolicy.validate(trimmedBaseURL, allowInsecureLAN: allowInsecureLAN)
        } catch LLMError.insecureURL {
            throw LLMConfigValidationError.insecureURL
        } catch {
            throw LLMConfigValidationError.invalidURL
        }
    }
}

/// 草稿保存前校验失败原因
enum LLMConfigValidationError: Error, LocalizedError, Equatable {
    case emptyName
    case emptyBaseURL
    case emptyModelName
    case invalidURL
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "请填写配置名称。")
        case .emptyBaseURL:
            return String(localized: "请填写 Base URL。")
        case .emptyModelName:
            return String(localized: "请填写模型名称。")
        case .invalidURL:
            return String(localized: "LLM API 地址无效，请在设置中检查 Base URL 配置")
        case .insecureURL:
            return String(localized: "API 地址不安全：公网服务必须使用 HTTPS；私有 IPv4 地址使用 HTTP 需要在模型配置中单独授权。")
        }
    }
}

// MARK: - 导入导出

/// 大模型配置的迁移负载（带版本号，便于将来演进）。
///
/// **含 API Key**（`Item.apiKey`）：因此 `transferPayload(from:)` 返回的是**明文**，
/// 调用方**必须**先经 `EncryptionService` 加密再落盘（与本地数据同一把设备密钥），
/// 绝不可直接写文件。读取侧保留对不含 `apiKey` 字段的兼容（旧明文导出文件），此时 Key 为空。
struct LLMConfigTransferFile: Codable, Sendable {
    struct Item: Codable, Sendable {
        var name: String
        var baseURL: String
        var modelName: String
        var isLocal: Bool
        var supportsVision: Bool
        /// 缺省即 nil：兼容不含此字段的旧文件
        var apiKey: String?
    }

    var version: Int
    var exportedAt: Date
    var configs: [Item]

    static let currentVersion = 1
}

extension LLMConfig {
    /// 单次导入的条数上限：迁移文件不该有成千上万条，超出部分按无效处理（防呆）
    private static let transferMaxItems = 200

    /// 导入结果，供界面给出准确反馈
    struct ImportOutcome: Sendable {
        var insertedCount: Int
        /// 与现有配置重复（Base URL + 模型标识相同）而跳过
        var skippedDuplicates: Int
        /// 缺字段或端点不安全而跳过
        var skippedInvalid: Int
    }

    /// 组装迁移负载（**明文，含 API Key**）：调用方必须先经 `EncryptionService` 加密再落盘
    static func transferPayload(from configs: [LLMConfig]) throws -> Data {
        let file = LLMConfigTransferFile(
            version: LLMConfigTransferFile.currentVersion,
            exportedAt: Date(),
            configs: configs.map {
                let apiKey = $0.apiKey
                return LLMConfigTransferFile.Item(
                    name: $0.name,
                    baseURL: $0.baseURL,
                    modelName: $0.modelName,
                    isLocal: $0.isLocal,
                    supportsVision: $0.supportsVision,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    /// 解析迁移负载：校验字段、按 Base URL + 模型标识去重，返回待插入的配置（未入库）
    /// 与它们的 API Key（按新配置 id 归档，由调用方写入 Keychain）。
    /// 端点安全沿用请求路径同一套校验：明文 HTTP 只放行本地模型（含回环与局域网），
    /// 避免导入一份「一用就报不安全」的配置
    static func decodeTransfer(
        _ data: Data,
        existing: [LLMConfig]
    ) throws -> (configs: [LLMConfig], apiKeys: [UUID: String], outcome: ImportOutcome) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(LLMConfigTransferFile.self, from: data)

        func key(baseURL: String, modelName: String) -> String {
            let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
            return (base + "|" + modelName).lowercased()
        }

        var seen = Set(existing.map { key(baseURL: $0.baseURL, modelName: $0.modelName) })
        var result: [LLMConfig] = []
        var apiKeys: [UUID: String] = [:]
        var duplicates = 0
        var invalid = max(0, file.configs.count - transferMaxItems)

        for item in file.configs.prefix(transferMaxItems) {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = item.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = item.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !baseURL.isEmpty, !modelName.isEmpty else {
                invalid += 1
                continue
            }
            // Imported files cannot silently grant cleartext LAN consent.
            guard (try? EndpointPolicy.validate(baseURL, allowInsecureLAN: false)) != nil else {
                invalid += 1
                continue
            }
            guard seen.insert(key(baseURL: baseURL, modelName: modelName)).inserted else {
                duplicates += 1
                continue
            }
            let config = LLMConfig(
                name: name,
                baseURL: baseURL,
                modelName: modelName,
                isLocal: item.isLocal,
                supportsVision: item.supportsVision
            )
            result.append(config)
            // Key 不在模型里（Keychain 按 id 存取），因此按新 id 一起归档
            if let apiKey = item.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
                apiKeys[config.id] = apiKey
            }
        }

        return (
            result,
            apiKeys,
            ImportOutcome(
                insertedCount: result.count,
                skippedDuplicates: duplicates,
                skippedInvalid: invalid
            )
        )
    }
}

// MARK: - 预设模板
extension LLMConfig {
    static func lmStudioTemplate() -> LLMConfig {
        LLMConfig(name: String(localized: "LM Studio 本地"), baseURL: "http://localhost:1234", modelName: "local-model", isLocal: true)
    }

    static func ollamaTemplate() -> LLMConfig {
        LLMConfig(name: String(localized: "Ollama 本地"), baseURL: "http://localhost:11434", modelName: "llama3", isLocal: true)
    }

    static func openAITemplate() -> LLMConfig {
        LLMConfig(name: "OpenAI GPT-4o", baseURL: "https://api.openai.com", modelName: "gpt-4o", isLocal: false, supportsVision: true)
    }

    static func customTemplate() -> LLMConfig {
        LLMConfig(name: "自定义 API", baseURL: "https://your-api.com", modelName: "model-name", isLocal: false)
    }
}
