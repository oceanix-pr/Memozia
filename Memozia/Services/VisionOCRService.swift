import Foundation
@preconcurrency import Vision
#if os(macOS)
import AppKit
#else
/* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
import UIKit
*/
#endif
import os.log

/// 本地 OCR 服务：使用 Vision 框架识别图片中的文字
///
/// 当配置的 LLM 不支持视觉输入时，作为降级方案：
/// 先用 Vision 本地识别文字，再把文字喂给 LLM 拆解待办。
enum VisionOCRService {

    private static let logger = Logger(subsystem: "app.memozia", category: "VisionOCR")

    // MARK: - 识别语言解析

    /// 单次 OCR 的语言方案
    struct LanguagePlan: Equatable, Sendable {
        /// 传给 `VNRecognizeTextRequest.recognitionLanguages` 的语言标记
        let languages: [String]
        /// 是否启用系统自动语种检测（`automaticallyDetectsLanguage`）
        let automaticallyDetectsLanguage: Bool
    }

    /// 同时启用的候选语言上限：候选越多识别越慢、语言间误判也越多，
    /// 因此只取优先级最高的少数几种，而不是把支持的全部语言一次性启用
    static let maxRecognitionLanguages = 3

    /// `automaticallyDetectsLanguage` 需要 macOS 13+；工程最低 15.0，
    /// 这里保留能力探测以便单元测试可控
    static var supportsAutomaticLanguageDetection: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// 应用界面语言的偏好键，与 `MenuBarController.appLanguageDefaultsKey` 同源。
    /// 后者所在类为 @MainActor，OCR 在后台队列运行，无法直接读取，故在此重述同一字面量
    static let appLanguageDefaultsKey = "AppInterfaceLanguage"
    /// 转写语言（用户为当前录音选择的语言）的偏好键，与 `SettingsViewModel.Keys.whisperLanguage` 同源
    static let transcriptionLanguageDefaultsKey = "whisper_language"

    /// 语言主标签 → Vision 识别语言标记
    private static let visionTagByPrimarySubtag: [String: String] = [
        "en": "en-US", "ja": "ja-JP", "ko": "ko-KR",
        "fr": "fr-FR", "de": "de-DE", "es": "es-ES", "it": "it-IT",
        "pt": "pt-BR", "ru": "ru-RU", "uk": "uk-UA",
        "ar": "ar-SA", "hi": "hi-IN", "th": "th-TH", "vi": "vi-VT",
        "id": "id-ID", "tr": "tr-TR", "nl": "nl-NL", "pl": "pl-PL",
        "sv": "sv-SE",
    ]

    /// 把设置值 / 系统语言代码（zh、zh-Yue、zh-Hant、en-US、fr_FR …）映射为 Vision 识别语言标记；
    /// 无法识别或为「自动检测」（空串 / auto）时返回 nil
    static func visionLanguageTag(for code: String) -> String? {
        let normalized = code
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, normalized != "auto" else { return nil }
        if normalized.hasPrefix("zh") {
            // Vision OCR 没有独立的粤语模型：粤语/繁体统一用 zh-Hant，其余简体场景用 zh-Hans
            let traditionalHints = ["hant", "tw", "hk", "mo", "yue"]
            return traditionalHints.contains(where: normalized.contains) ? "zh-Hant" : "zh-Hans"
        }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return visionTagByPrimarySubtag[primary]
    }

    /// 纯函数：按「用户为当前录音选择的语言 → 应用语言 → 系统首选语言」优先级解析 OCR 识别语言。
    ///
    /// - Parameters:
    ///   - recordingLanguage: 用户为当前录音选择的转写语言
    ///   - appLanguage: 应用界面语言
    ///   - systemLanguages: 系统首选语言（`Locale.preferredLanguages`）
    ///   - supported: 系统 OCR 实际支持的语言；为空集表示「不做过滤」
    ///   - supportsAutomaticDetection: 是否启用系统自动语种检测
    /// - Returns: 去重、限流后的识别语言方案；全部不受支持时回退英文，再退化为系统默认（空数组）
    static func languagePlan(
        recordingLanguage: String?,
        appLanguage: String?,
        systemLanguages: [String],
        supported: Set<String>,
        supportsAutomaticDetection: Bool = VisionOCRService.supportsAutomaticLanguageDetection
    ) -> LanguagePlan {
        var candidates: [String] = []
        func append(_ code: String?) {
            guard let code, let tag = visionLanguageTag(for: code), !candidates.contains(tag) else { return }
            candidates.append(tag)
        }
        append(recordingLanguage)
        append(appLanguage)
        for language in systemLanguages { append(language) }

        let resolved = candidates.filter { supported.isEmpty || supported.contains($0) }
        guard !resolved.isEmpty else {
            let fallback = (supported.isEmpty || supported.contains("en-US")) ? ["en-US"] : []
            return LanguagePlan(languages: fallback, automaticallyDetectsLanguage: false)
        }
        return LanguagePlan(
            languages: Array(resolved.prefix(maxRecognitionLanguages)),
            automaticallyDetectsLanguage: supportsAutomaticDetection
        )
    }

    /// 系统 OCR 支持的识别语言（进程内缓存，避免逐帧识别时反复查询）。
    ///
    /// 用实例方法 `supportedRecognitionLanguages()`（macOS 12 起取代已废弃的类方法
    /// `supportedRecognitionLanguages(for:revision:)`）：查询口径取决于请求自身的
    /// 识别级别与 revision，因此显式对齐为 `.accurate` + 当前 revision。
    static let supportedRecognitionLanguages: Set<String> = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequest.currentRevision
        return (try? request.supportedRecognitionLanguages()).map(Set.init) ?? []
    }()

    /// 汇总本地偏好与系统语言，解析本次 OCR 的语言方案（含回退 debug 日志）
    static func resolveLanguagePlan(recordingLanguage: String?) -> LanguagePlan {
        let defaults = UserDefaults.standard
        let requested = recordingLanguage ?? defaults.string(forKey: transcriptionLanguageDefaultsKey)
        let appLanguage = defaults.string(forKey: appLanguageDefaultsKey)
        let plan = languagePlan(
            recordingLanguage: requested,
            appLanguage: appLanguage,
            systemLanguages: Locale.preferredLanguages,
            supported: supportedRecognitionLanguages)
        if plan.languages.isEmpty {
            logger.debug("OCR 无受支持的识别语言，交由系统默认处理")
        } else if let requested, !requested.isEmpty,
                  !plan.languages.contains(visionLanguageTag(for: requested) ?? "") {
            logger.debug("OCR 不支持所选语言 \(requested, privacy: .public)，回退 \(plan.languages.joined(separator: ","), privacy: .public)")
        }
        return plan
    }

    /// 识别图片中的文字
    /// - Parameters:
    ///   - imageData: PNG/JPEG 图片数据
    ///   - recordingLanguage: 用户为当前录音选择的语言；缺省时读取设置的转写语言
    /// - Returns: 识别出的纯文本
    static func recognizeText(from imageData: Data, recordingLanguage: String? = nil) async throws -> String {
        // 平台差异：macOS 用 NSImage，iOS 用 UIImage 取 CGImage
        #if os(macOS)
        guard let platformImage = NSImage(data: imageData),
              let cgImage = platformImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("无法从图片数据创建 CGImage")
            throw VisionOCRError.invalidImage
        }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        guard let platformImage = UIImage(data: imageData),
              let cgImage = platformImage.cgImage else {
            logger.error("无法从图片数据创建 CGImage")
            throw VisionOCRError.invalidImage
        }
        */
        #endif

        // 语言方案在进入并发闭包前解析（含偏好读取与支持列表探测），供后台队列使用
        let plan = resolveLanguagePlan(recordingLanguage: recordingLanguage)

        // 一次性结算盒：`perform` 是同步调用，请求回调通常已在 `perform` 内部跑完并
        // 恢复了续体，此时下方 catch 再 `resume` 一次就是双重恢复（EXC_BAD_INSTRUCTION）
        let box = OneShotThrowingBox<String>()

        // 看门狗：`handler.perform` 若挂起且回调不来，续体将永久悬挂、调用方一直 await。
        // 超时以错误结算，让调用方能返回并处理迟到结果。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.ocrTimeout * 1_000_000_000))
            // 已被结果/取消抢先结算时不再判定超时
            guard !Task.isCancelled else { return }
            _ = box.fail(VisionOCRError.timedOut)
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<String, any Error>) in
                // 先挂续体再启动请求，保证回调不可能早于登记
                box.attach(continuation)

                // VNImageRequestHandler 和 VNRecognizeTextRequest 非 Sendable，
                // 需在 @Sendable 闭包内部创建，避免跨线程捕获
                DispatchQueue.global(qos: .userInitiated).async {
                    let request = VNRecognizeTextRequest { request, error in
                        if let error = error {
                            logger.error("Vision OCR 失败：\(error.localizedDescription)")
                            _ = box.fail(error)
                            return
                        }

                        let observations = request.results as? [VNRecognizedTextObservation] ?? []
                        let text = observations.compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: "\n")

                        logger.info("Vision OCR 识别完成，共 \(text.count) 字符")
                        _ = box.succeed(text)
                    }

                    // 识别语言：按「当前录音语言 → 应用语言 → 系统语言」解析并限流；
                    // 系统支持时同时开启自动语种检测（补充识别优先级未覆盖的语言）
                    request.recognitionLevel = .accurate
                    // 空数组表示「无明确候选」，此时保持系统默认语言（不显式覆盖）
                    if !plan.languages.isEmpty {
                        request.recognitionLanguages = plan.languages
                    }
                    if #available(macOS 13.0, *) {
                        request.automaticallyDetectsLanguage = plan.automaticallyDetectsLanguage
                    }
                    request.usesLanguageCorrection = true

                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        logger.error("Vision 请求执行失败：\(error.localizedDescription)")
                        // 回调已交付时本次自动让位（fail 返回 false），不会二次恢复续体
                        _ = box.fail(error)
                    }
                }
            }
        } onCancel: {
            // 调用方取消：立即以错误结算悬挂的续体（perform 无法真正中断）
            _ = box.fail(CancellationError())
        }
    }

    /// OCR 看门狗超时（秒）：单张图片识别正常在秒级完成，60s 仅兜真正的挂起
    private static let ocrTimeout: TimeInterval = 60


    /// 从文件 URL 读取图片并识别文字
    static func recognizeText(from imageURL: URL) async throws -> String {
        let data = try Data(contentsOf: imageURL)
        return try await recognizeText(from: data)
    }
}

// MARK: - 错误类型

enum VisionOCRError: LocalizedError {
    case invalidImage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidImage: return String(localized: "无法解析图片数据")
        case .timedOut: return String(localized: "图片文字识别长时间无响应，已中止。")
        }
    }
}
