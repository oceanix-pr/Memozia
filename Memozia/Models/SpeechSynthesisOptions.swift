import AVFoundation
import AudioToolbox
import Foundation

enum NoteSpeechAvailability {
    /// 直接读取系统全局语言，避免应用 AppleLanguages 覆盖或 Locale 缓存
    /// 把「跟随系统」误判成用户此前显式选择的应用语言。
    static var systemPreferredLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            as? [String] ?? []
    }

    static func isSupported(interfaceLanguage: String, systemLanguages: [String]) -> Bool {
        let selected = interfaceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = selected.isEmpty ? systemLanguages.first ?? "" : selected
        let language = Locale.Language(identifier: effective)
        guard language.languageCode?.identifier == "zh" else { return false }
        let script = language.script?.identifier
        return script == nil || script == "Hans" || script == "Hant"
    }
}

enum SpeechAudioFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav, mp3
    var id: String { rawValue }
    var label: String { rawValue == "m4a" ? "M4A (AAC)" : rawValue.uppercased() }

    /// 解码能力不代表编码能力；只在系统安装了 MP3 编码器时开放该出口。
    static var supportsMP3Encoding: Bool {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var formats = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = formats.withUnsafeMutableBytes {
            AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr && formats.contains(kAudioFormatMPEGLayer3)
    }
}

/// 系统音色的值快照；不跨 actor 传递 AVSpeechSynthesisVoice。
struct SpeechVoiceOption: Identifiable, Sendable {
    let id: String
    let name: String
    let language: String
    let gender: AVSpeechSynthesisVoiceGender
    let quality: Int

    @MainActor static func installed() -> [Self] {
        AVSpeechSynthesisVoice.speechVoices().map {
            Self(id: $0.identifier, name: $0.name, language: $0.language,
                 gender: $0.gender, quality: $0.quality.rawValue)
        }.sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.id < $1.id
        }
    }

    var displayName: String {
        switch gender {
        case .male: return name + " · " + String(localized: "男声")
        case .female: return name + " · " + String(localized: "女声")
        default: return name
        }
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "zh-CN": return String(localized: "普通话")
        case "zh-TW": return String(localized: "台湾国语")
        case "zh-HK", "yue-HK": return String(localized: "粤语（香港）")
        default: return Locale.current.localizedString(forIdentifier: code) ?? code
        }
    }
}

struct SpeechNoteInput: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let body: String
    let summary: String
}

enum SpeechSynthesisError: LocalizedError {
    case emptyText, voiceUnavailable, noAudio, incompatibleAudio, timedOut, mp3Unavailable, busy

    var errorDescription: String? {
        switch self {
        case .emptyText: return String(localized: "没有可朗读的文字，请选择其他内容。")
        case .voiceUnavailable: return String(localized: "所选系统音色不可用，请刷新音色或在系统设置中下载。")
        case .noAudio: return String(localized: "系统未生成有效语音，请尝试其他音色。")
        case .incompatibleAudio: return String(localized: "系统音色返回了不兼容的音频格式，请尝试其他音色。")
        case .timedOut: return String(localized: "系统语音合成超时，请尝试其他音色或缩短文字。")
        case .mp3Unavailable: return String(localized: "此 Mac 没有原生 MP3 编码器，请选择 WAV 或 M4A。")
        case .busy: return String(localized: "语音合成正在进行，请先取消当前任务。")
        }
    }
}
