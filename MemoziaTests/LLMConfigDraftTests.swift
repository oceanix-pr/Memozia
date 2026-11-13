import Testing
import Foundation
@testable import Memozia

/// LLM 配置草稿与 Keychain 错误的确定性测试。
///
/// 这些测试不触碰真实钥匙串：草稿拷贝/校验是纯逻辑，Keychain 错误映射只依赖
/// OSStatus / NSError 输入，因此在任何机器上都可复现。
struct LLMConfigDraftTests {

    // MARK: - 草稿 ↔ 模型拷贝往返

    @Test func testDraftRoundTripFromConfig() {
        let config = LLMConfig(
            name: "OpenAI",
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o",
            isLocal: false,
            supportsVision: true
        )

        let draft = LLMConfigDraft(from: config)
        #expect(draft.name == "OpenAI")
        #expect(draft.baseURL == "https://api.openai.com")
        #expect(draft.modelName == "gpt-4o")
        #expect(draft.isLocal == false)
        #expect(draft.supportsVision == true)

        let target = LLMConfig(name: "占位", baseURL: "https://placeholder.example.com", modelName: "x")
        draft.apply(to: target)
        #expect(target.name == "OpenAI")
        #expect(target.baseURL == "https://api.openai.com")
        #expect(target.modelName == "gpt-4o")
        #expect(target.isLocal == false)
        #expect(target.supportsVision == true)
    }

    /// apply 不应改动模型身份：id 变了会导致 Keychain 里的 Key 失联
    @Test func testDraftApplyKeepsIdentity() {
        let config = LLMConfig(name: "A", baseURL: "https://a.example.com", modelName: "m")
        let originalID = config.id
        LLMConfigDraft(name: "B", baseURL: "https://b.example.com", modelName: "n", isLocal: true).apply(to: config)
        #expect(config.id == originalID)
    }

    /// 草稿携带身份：从已有配置拷贝时沿用其 id（Keychain 按 id 存取 Key）
    @Test func testDraftCarriesConfigIdentity() {
        let config = LLMConfig(name: "A", baseURL: "https://a.example.com", modelName: "m")
        #expect(LLMConfigDraft(from: config).id == config.id)
    }

    /// 每次新建草稿预分配独立身份：两份草稿不得撞 id
    @Test func testNewDraftIdentityIsDistinct() {
        #expect(LLMConfigDraft().id != LLMConfigDraft().id)
    }

    /// 核心回归：编辑草稿不得写穿到持久化模型（否则取消无法回滚）
    @Test func testDraftEditsDoNotMutateConfig() {
        let config = LLMConfig(
            name: "A",
            baseURL: "https://a.example.com",
            modelName: "model-a",
            isLocal: false,
            supportsVision: false
        )

        var draft = LLMConfigDraft(from: config)
        draft.name = "B"
        draft.baseURL = "https://b.example.com"
        draft.modelName = "model-b"
        draft.isLocal = true
        draft.supportsVision = true
        draft.apiKey = "secret"

        #expect(config.name == "A")
        #expect(config.baseURL == "https://a.example.com")
        #expect(config.modelName == "model-a")
        #expect(config.isLocal == false)
        #expect(config.supportsVision == false)
    }

    // MARK: - 保存前校验

    @Test func testValidateRejectsMissingFields() {
        #expect(throws: LLMConfigValidationError.emptyName) {
            try LLMConfigDraft(name: "   ", baseURL: "https://a.example.com", modelName: "m").validate()
        }
        #expect(throws: LLMConfigValidationError.emptyBaseURL) {
            try LLMConfigDraft(name: "A", baseURL: "  ", modelName: "m").validate()
        }
        #expect(throws: LLMConfigValidationError.emptyModelName) {
            try LLMConfigDraft(name: "A", baseURL: "https://a.example.com", modelName: "  ").validate()
        }
    }

    /// 云端配置的明文 HTTP 必须被拒：否则 API Key 与会议内容会明文上路
    @Test func testValidateRejectsInsecureCloudURL() {
        #expect(throws: LLMConfigValidationError.insecureURL) {
            try LLMConfigDraft(name: "A", baseURL: "http://api.example.com", modelName: "m", isLocal: false).validate()
        }
    }

    /// 无法解析或缺主机名的地址直接判无效
    @Test func testValidateRejectsInvalidURL() {
        #expect(throws: LLMConfigValidationError.invalidURL) {
            try LLMConfigDraft(name: "A", baseURL: "not a url at all", modelName: "m").validate()
        }
        #expect(throws: LLMConfigValidationError.invalidURL) {
            try LLMConfigDraft(name: "A", baseURL: "https://", modelName: "m").validate()
        }
    }

    /// 含空白字符的地址无法规范化（复用 LLMConfig.normalizedBaseURL），同样判无效
    @Test func testValidateRejectsURLWithWhitespace() {
        #expect(throws: LLMConfigValidationError.invalidURL) {
            try LLMConfigDraft(name: "A", baseURL: "https://api.example.com /v1", modelName: "m").validate()
        }
    }

    /// 回环兼容旧行为；局域网仍可用，但须独立授予明文传输许可。
    @Test func testValidateAllowsLocalPlainHTTP() throws {
        try LLMConfigDraft(name: "Ollama", baseURL: "http://localhost:11434", modelName: "llama3", isLocal: true).validate()
        var lan = LLMConfigDraft(name: "局域网", baseURL: "http://192.168.1.20:8000", modelName: "m", isLocal: true)
        #expect(throws: LLMConfigValidationError.insecureURL) { try lan.validate() }
        lan.allowInsecureLAN = true
        try lan.validate()
        // 回环地址即使未勾选本地模型也应放行
        try LLMConfigDraft(name: "回环", baseURL: "http://127.0.0.1:1234", modelName: "m", isLocal: false).validate()
    }

    // MARK: - Keychain 错误映射

    @Test func testKeychainErrorMappingFromOSStatus() {
        // 系统钥匙串不可用
        #expect(LLMKeychainError.from(osStatus: -25291) == .keychainUnavailable) // errSecNotAvailable
        #expect(LLMKeychainError.from(osStatus: -25307) == .keychainUnavailable) // errSecNoDefaultKeychain
        // 权限或用户拒绝
        #expect(LLMKeychainError.from(osStatus: -128) == .accessDenied)        // errSecUserCanceled
        #expect(LLMKeychainError.from(osStatus: -25293) == .accessDenied)      // errSecAuthFailed
        #expect(LLMKeychainError.from(osStatus: -25308) == .accessDenied)      // errSecInteractionNotAllowed
        #expect(LLMKeychainError.from(osStatus: -25243) == .accessDenied)      // errSecNoAccessForItem
        // 条目不存在
        #expect(LLMKeychainError.from(osStatus: -25300) == .itemNotFound)      // errSecItemNotFound
        // 编码失败（KeychainAccess 的 conversionError）
        #expect(LLMKeychainError.from(osStatus: -67594) == .encodingFailed)
        #expect(LLMKeychainError.from(osStatus: -26275) == .encodingFailed)    // errSecDecode
        // 其他 OSStatus 原样保留，便于排查
        #expect(LLMKeychainError.from(osStatus: -25299) == .osStatus(-25299))  // errSecDuplicateItem
    }

    @Test func testKeychainErrorMappingFromThrownError() {
        // KeychainAccess 抛 Status（rawValue 即 OSStatus），此处用 OSStatus 域 NSError 模拟同一归类
        let notFound = NSError(domain: NSOSStatusErrorDomain, code: -25300, userInfo: nil)
        #expect(LLMKeychainError.mapping(notFound) == .itemNotFound)

        let denied = NSError(domain: NSOSStatusErrorDomain, code: -128, userInfo: nil)
        #expect(LLMKeychainError.mapping(denied) == .accessDenied)

        // 已是 LLMKeychainError 时原样返回
        #expect(LLMKeychainError.mapping(LLMKeychainError.keychainUnavailable) == .keychainUnavailable)

        // 非 OSStatus 域的未知错误归入 osStatus
        let unknown = NSError(domain: "app.memozia.test", code: 42, userInfo: nil)
        guard case .osStatus = LLMKeychainError.mapping(unknown) else {
            Issue.record("未知域错误应归类为 osStatus")
            return
        }
    }
}
