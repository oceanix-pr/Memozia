import Foundation
import Testing
@testable import Memozia

@Suite(.serialized)
struct AppExperienceTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppExperienceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("全新用户默认普通模式")
    func newInstallDefaultsToStandard() {
        let defaults = makeDefaults()
        #expect(AppExperiencePreference.resolved(in: defaults) == .standard)
        #expect(defaults.string(forKey: AppExperiencePreference.defaultsKey) == AppExperience.standard.rawValue)
    }

    @Test("已完成旧版引导的用户迁移后保持专业模式")
    func existingInstallKeepsProExperience() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        #expect(AppExperiencePreference.resolved(in: defaults) == .pro)
    }

    @Test("显式保存的模式优先于迁移判断")
    func storedExperienceWins() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(AppExperience.standard.rawValue, forKey: AppExperiencePreference.defaultsKey)
        #expect(AppExperiencePreference.resolved(in: defaults) == .standard)
    }

    @Test("Pro STT 解析保持原配置完全不变")
    func proSTTResolutionIsIdentity() {
        let saved = STTConfig(
            mode: .cloud,
            modelPath: "/custom/model",
            apiKey: "secret",
            baseURL: "https://example.com/v1",
            language: "ja",
            enableSpeakerDiarization: false,
            diarizationModelPath: "/custom/diarization",
            enableVoiceprintRecognition: true,
            enableDictionaryCorrection: true
        )

        let resolved = EffectiveSettingsResolver.sttConfig(saved: saved, experience: .pro)
        #expect(resolved.mode == saved.mode)
        #expect(resolved.modelPath == saved.modelPath)
        #expect(resolved.apiKey == saved.apiKey)
        #expect(resolved.baseURL == saved.baseURL)
        #expect(resolved.language == saved.language)
        #expect(resolved.enableSpeakerDiarization == saved.enableSpeakerDiarization)
        #expect(resolved.diarizationModelPath == saved.diarizationModelPath)
        #expect(resolved.enableVoiceprintRecognition == saved.enableVoiceprintRecognition)
        #expect(resolved.enableDictionaryCorrection == saved.enableDictionaryCorrection)
    }

    @Test("普通模式 STT 使用可预测的本地安全配置（系统不支持系统语音识别时回退本地 Whisper）")
    func standardSTTResolutionUsesSafeDefaults() {
        let saved = STTConfig(
            mode: .cloud,
            modelPath: "/custom/model",
            apiKey: "secret",
            baseURL: "https://example.com/v1",
            language: "ja",
            enableSpeakerDiarization: false,
            diarizationModelPath: "/custom/diarization",
            enableVoiceprintRecognition: true,
            enableDictionaryCorrection: true
        )

        // 显式注入系统能力，避免测试结果随运行机器的 macOS 版本漂移
        let resolved = EffectiveSettingsResolver.sttConfig(
            saved: saved,
            experience: .standard,
            systemTranscriptionSupported: false
        )
        #expect(resolved.mode == .local)
        #expect(resolved.modelPath == WhisperModelFolder.defaultPath)
        #expect(resolved.apiKey.isEmpty)
        #expect(resolved.language == WhisperLanguage.auto.rawValue)
        #expect(resolved.enableSpeakerDiarization)
        #expect(!resolved.enableVoiceprintRecognition)
        #expect(!resolved.enableDictionaryCorrection)
    }

    @Test("普通模式在系统支持时默认使用系统语音识别并跟随系统语言")
    func standardSTTPrefersSystemTranscriptionWhenSupported() {
        let saved = STTConfig(
            mode: .cloud,
            apiKey: "secret",
            language: "ja",
            enableSpeakerDiarization: false,
            enableVoiceprintRecognition: true,
            enableDictionaryCorrection: true
        )

        let resolved = EffectiveSettingsResolver.sttConfig(
            saved: saved,
            experience: .standard,
            systemTranscriptionSupported: true
        )
        #expect(resolved.mode == .system)
        // 空语言 = 跟随系统语言：系统语音识别没有自动语种检测，也不给普通模式语言选择入口
        #expect(resolved.language.isEmpty)
        #expect(resolved.apiKey.isEmpty)
        #expect(resolved.enableSpeakerDiarization)
        #expect(!resolved.enableVoiceprintRecognition)
        #expect(!resolved.enableDictionaryCorrection)
    }

    @Test("Pro 模式可显式选择系统语音识别且不改写语言")
    func proSTTAllowsSystemTranscription() {
        let saved = STTConfig(mode: .system, apiKey: "", language: "en")

        let resolved = EffectiveSettingsResolver.sttConfig(saved: saved, experience: .pro)
        #expect(resolved.mode == .system)
        #expect(resolved.language == "en")
    }

    @Test("普通模式使用独立模型路径且不改写 Pro 配置")
    func standardSTTUsesIndependentModelPath() {
        let saved = STTConfig(
            mode: .cloud,
            modelPath: "/pro/custom-model",
            apiKey: "secret",
            baseURL: "https://example.com/v1",
            language: "ja"
        )

        let standard = EffectiveSettingsResolver.sttConfig(
            saved: saved,
            experience: .standard,
            standardModelPath: "/standard/managed-model"
        )
        let pro = EffectiveSettingsResolver.sttConfig(
            saved: saved,
            experience: .pro,
            standardModelPath: "/standard/managed-model"
        )

        #expect(standard.modelPath == "/standard/managed-model")
        #expect(pro.modelPath == "/pro/custom-model")
        #expect(pro.mode == .cloud)
        #expect(pro.apiKey == "secret")
    }

    @Test("普通模式录音场景映射不修改专业配置")
    func standardRecordingResolutionUsesSemanticMode() {
        let saved = RecordingConfig(
            source: .systemAudio,
            autoMuteDetection: false,
            appMuteDetection: true,
            startMuted: true
        )

        let online = EffectiveSettingsResolver.recordingConfig(
            saved: saved,
            standardMode: .onlineMeeting,
            experience: .standard
        )
        let inPerson = EffectiveSettingsResolver.recordingConfig(
            saved: saved,
            standardMode: .inPersonMeeting,
            experience: .standard
        )
        let pro = EffectiveSettingsResolver.recordingConfig(
            saved: saved,
            standardMode: .onlineMeeting,
            experience: .pro
        )

        #expect(online.source == .mixed)
        #expect(online.autoMuteDetection)
        #expect(!online.appMuteDetection)
        #expect(inPerson.source == .microphone)
        #expect(pro.source == .systemAudio)
        #expect(!pro.autoMuteDetection)
        #expect(pro.appMuteDetection)
        // 标准模式隐藏了静音策略开关，沿用专业模式留下的「开始时静音」会变成「以为在录其实没声」
        #expect(!online.startMuted)
        #expect(!inPerson.startMuted)
        #expect(pro.startMuted)
    }

    @Test("录音开始时静音偏好默认关闭且可往返读写")
    func microphoneStartMutePreferenceRoundTrip() {
        let defaults = makeDefaults()
        #expect(!MicrophoneStartMutePreference.isEnabled(in: defaults))

        MicrophoneStartMutePreference.set(true, in: defaults)
        #expect(MicrophoneStartMutePreference.isEnabled(in: defaults))

        MicrophoneStartMutePreference.set(false, in: defaults)
        #expect(!MicrophoneStartMutePreference.isEnabled(in: defaults))
    }

    @Test("静音命令：系统/会议软件静音不能在 App 内解除")
    func micMuteCommandBlocksForeignMuteSources() {
        // 未静音：任何来源下都能静音
        for source in [MuteSource.none, .local, .system, .app] {
            #expect(MicMuteCommand.canToggle(isMuted: false, source: source))
        }
        // 已静音：本地静音可解除，系统 / 会议软件静音必须去源头解除
        #expect(MicMuteCommand.canToggle(isMuted: true, source: .local))
        #expect(MicMuteCommand.canToggle(isMuted: true, source: .none))
        #expect(!MicMuteCommand.canToggle(isMuted: true, source: .system))
        #expect(!MicMuteCommand.canToggle(isMuted: true, source: .app))

        // 图标表达「这一步会做什么」：未静音时是划掉的麦克风
        #expect(MicMuteCommand.iconName(isMuted: false) == "mic.slash")
        #expect(MicMuteCommand.iconName(isMuted: true) == "mic.fill")

        // 来源文案区分系统 / 会议软件 / 本地（徽章与菜单栏状态项共用同一份）
        #expect(MicMuteCommand.sourceLabel(.system) != MicMuteCommand.sourceLabel(.app))
        #expect(MicMuteCommand.sourceLabel(.local) != MicMuteCommand.sourceLabel(.system))
        #expect(MicMuteCommand.sourceLabel(.local) == MicMuteCommand.sourceLabel(.none))
    }

    @Test("普通模式强制云端脱敏且 Pro 尊重保存值")
    func privacyPolicyCannotBeDisabledInStandardMode() {
        #expect(EffectiveSettingsResolver.piiScrubEnabled(savedValue: false, experience: .standard))
        #expect(!EffectiveSettingsResolver.piiScrubEnabled(savedValue: false, experience: .pro))
        #expect(EffectiveSettingsResolver.piiScrubEnabled(savedValue: true, experience: .pro))
    }

    @Test("画面页签仅专业模式可见")
    func visualTabIsProOnly() {
        // 普通模式：即使条目里留有历史画面产物，也不再展示画面页签
        #expect(
            RecordingDetailView.availableTabs(experience: .standard, hasVideoAttachment: true)
                == [.transcript, .summary]
        )
        #expect(
            RecordingDetailView.availableTabs(experience: .standard, hasVideoAttachment: false)
                == [.transcript, .summary]
        )

        // 专业模式：仍只有视频条目才展示画面页签
        #expect(
            RecordingDetailView.availableTabs(experience: .pro, hasVideoAttachment: true)
                == [.transcript, .visual, .summary]
        )
        #expect(
            RecordingDetailView.availableTabs(experience: .pro, hasVideoAttachment: false)
                == [.transcript, .summary]
        )
    }
}
