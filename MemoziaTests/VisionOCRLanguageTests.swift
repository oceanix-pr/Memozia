import Foundation
import Testing
@testable import Memozia

/// Vision OCR 识别语言映射的纯函数测试（不依赖真实图片与系统推理）
struct VisionOCRLanguageTests {

    /// 与实现映射表一致的「系统支持语言」全集
    private let supported: Set<String> = [
        "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
        "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR",
        "ru-RU", "uk-UA", "ar-SA", "hi-IN", "th-TH", "vi-VT",
        "id-ID", "tr-TR", "nl-NL", "pl-PL", "sv-SE",
    ]

    private func plan(
        recording: String? = nil,
        app: String? = nil,
        system: [String] = [],
        supported: Set<String>? = nil,
        autoDetect: Bool = true
    ) -> VisionOCRService.LanguagePlan {
        VisionOCRService.languagePlan(
            recordingLanguage: recording,
            appLanguage: app,
            systemLanguages: system,
            supported: supported ?? self.supported,
            supportsAutomaticDetection: autoDetect
        )
    }

    // MARK: - 语言标记映射

    @Test("中文：简体/繁中/粤语映射到对应 Vision 语言")
    func chineseTags() {
        #expect(VisionOCRService.visionLanguageTag(for: "zh") == "zh-Hans")
        #expect(VisionOCRService.visionLanguageTag(for: "zh-Hans") == "zh-Hans")
        #expect(VisionOCRService.visionLanguageTag(for: "zh-Hant") == "zh-Hant")
        #expect(VisionOCRService.visionLanguageTag(for: "zh-Yue") == "zh-Hant")
        #expect(VisionOCRService.visionLanguageTag(for: "zh-TW") == "zh-Hant")
    }

    @Test("英日韩映射到各自的 Vision 语言标记")
    func englishJapaneseKoreanTags() {
        #expect(VisionOCRService.visionLanguageTag(for: "en") == "en-US")
        #expect(VisionOCRService.visionLanguageTag(for: "en-US") == "en-US")
        #expect(VisionOCRService.visionLanguageTag(for: "ja") == "ja-JP")
        #expect(VisionOCRService.visionLanguageTag(for: "ko") == "ko-KR")
    }

    @Test("带变音符号的欧洲语言映射正确")
    func europeanTags() {
        // 德语（ä/ö/ü/ß）、法语（é/à）、西班牙语（ñ）、葡萄牙语（ã）、波兰语（ą/ł）、土耳其语
        #expect(VisionOCRService.visionLanguageTag(for: "de") == "de-DE")
        #expect(VisionOCRService.visionLanguageTag(for: "fr") == "fr-FR")
        #expect(VisionOCRService.visionLanguageTag(for: "fr_FR") == "fr-FR")
        #expect(VisionOCRService.visionLanguageTag(for: "es") == "es-ES")
        #expect(VisionOCRService.visionLanguageTag(for: "pt") == "pt-BR")
        #expect(VisionOCRService.visionLanguageTag(for: "pl") == "pl-PL")
        #expect(VisionOCRService.visionLanguageTag(for: "tr") == "tr-TR")
    }

    @Test("自动检测与未知语言不产生候选")
    func unknownAndAuto() {
        #expect(VisionOCRService.visionLanguageTag(for: "") == nil)
        #expect(VisionOCRService.visionLanguageTag(for: "auto") == nil)
        #expect(VisionOCRService.visionLanguageTag(for: "xx") == nil)
    }

    // MARK: - 优先级

    @Test("优先使用当前录音选择的语言")
    func recordingLanguageWins() {
        let result = plan(recording: "zh")
        #expect(result.languages == ["zh-Hans"])
        #expect(result.automaticallyDetectsLanguage)
    }

    @Test("录音语言缺失时回退应用语言")
    func appLanguageFallback() {
        let result = plan(app: "ja")
        #expect(result.languages == ["ja-JP"])
    }

    @Test("录音与应用语言都缺失时回退系统语言")
    func systemLanguageFallback() {
        let result = plan(system: ["ko-KR"])
        #expect(result.languages == ["ko-KR"])
    }

    @Test("录音语言优先于应用语言与系统语言，并按优先级截断")
    func priorityOrderAndCap() {
        let result = plan(recording: "ja", app: "en", system: ["de-DE", "fr-FR"])
        #expect(result.languages == ["ja-JP", "en-US", "de-DE"])
        #expect(result.languages.count <= VisionOCRService.maxRecognitionLanguages)
    }

    @Test("重复语言去重后再限流")
    func deduplicatesCandidates() {
        let result = plan(recording: "en", app: "en", system: ["en-US", "ko-KR"])
        #expect(result.languages == ["en-US", "ko-KR"])
    }

    @Test("最多保留三种候选语言")
    func capsCandidateCount() {
        let result = plan(system: ["ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"])
        #expect(result.languages.count == VisionOCRService.maxRecognitionLanguages)
        #expect(result.languages == ["ja-JP", "ko-KR", "fr-FR"])
    }

    // MARK: - 回退

    @Test("所选语言不受支持时回退英文")
    func unsupportedFallsBackToEnglish() {
        // 粤语映射为 zh-Hant；这里构造一个不含 zh-Hant 的支持集，应回退英文
        let result = plan(recording: "zh-Yue", supported: ["en-US", "ja-JP"])
        #expect(result.languages == ["en-US"])
        #expect(!result.automaticallyDetectsLanguage)
    }

    @Test("英文也不受支持时退化为系统默认（空数组）")
    func unsupportedFallsBackToSystemDefault() {
        let result = plan(recording: "xx", supported: ["ja-JP"])
        #expect(result.languages.isEmpty)
        #expect(!result.automaticallyDetectsLanguage)
    }

    @Test("系统不支持自动检测时不启用 automaticallyDetectsLanguage")
    func automaticDetectionCanBeDisabled() {
        let result = plan(recording: "de", autoDetect: false)
        #expect(result.languages == ["de-DE"])
        #expect(!result.automaticallyDetectsLanguage)
    }

    @Test("纯函数映射可覆盖应用中全部 21 种界面前缀语言")
    func coversAllAppLanguages() {
        let codes = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it",
                     "pt", "ru", "ar", "hi", "th", "vi", "id", "tr", "nl", "pl", "uk", "sv"]
        for code in codes {
            let tag = VisionOCRService.visionLanguageTag(for: code)
            #expect(tag != nil, "缺失映射：\(code)")
            #expect(supported.contains(tag ?? ""), "映射未落在支持集内：\(code)")
        }
    }
}
