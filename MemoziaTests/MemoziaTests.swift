import Testing
import Foundation
import AVFoundation
@testable import Memozia

/// Memozia 基础单元测试
struct MemoziaTests {

    // MARK: - TimeInterval 格式化测试

    @Test func testFormattedDurationUnderOneHour() {
        let duration: TimeInterval = 3125 // 52 minutes 5 seconds
        #expect(duration.formattedAsDuration() == "52:05")
    }

    @Test func testFormattedDurationOverOneHour() {
        let duration: TimeInterval = 3661 // 1 hour 1 minute 1 second
        #expect(duration.formattedAsDuration() == "1:01:01")
    }

    @Test func testFormattedDurationZero() {
        let duration: TimeInterval = 0
        #expect(duration.formattedAsDuration() == "0:00")
    }

    @Test func testFormattedDurationForceHours() {
        let duration: TimeInterval = 65 // 1 minute 5 seconds
        #expect(duration.formattedAsDuration(forceHours: true) == "0:01:05")
    }

    @Test func testFormattedDurationFractionDigits() {
        // 转写时间戳使用 0.1 秒精度；同时验证毫秒（3 位）也成立
        let duration: TimeInterval = 5.1234
        #expect(duration.formattedAsDuration(fractionDigits: 1) == "0:05.1")
        #expect(duration.formattedAsDuration(fractionDigits: 3) == "0:05.123")
    }

    @Test func testFormattedDurationFractionRoundsUpAcrossSecond() {
        // 四舍五入到 0.1 秒应进位到整秒，而不是显示 59.9
        let duration: TimeInterval = 59.97
        #expect(duration.formattedAsDuration(fractionDigits: 1) == "1:00.0")
    }

    @Test func testFormattedDurationFractionWithHours() {
        let duration: TimeInterval = 3661.46
        #expect(duration.formattedAsDuration(fractionDigits: 1) == "1:01:01.5")
    }

    // MARK: - TranscriptionStatus 测试

    @Test func testTranscriptionStatusRawValues() {
        #expect(TranscriptionStatus.pending.rawValue == "pending")
        #expect(TranscriptionStatus.processing.rawValue == "processing")
        #expect(TranscriptionStatus.completed.rawValue == "completed")
        #expect(TranscriptionStatus.failed.rawValue == "failed")
    }

    @Test func testTranscriptionStatusCodable() throws {
        let status = TranscriptionStatus.completed
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(TranscriptionStatus.self, from: data)
        #expect(decoded == .completed)
    }

    // MARK: - STTConfig 测试

    @Test func testSTTConfigDefaults() {
        let config = STTConfig()
        #expect(config.mode == .local)
        #expect(config.modelPath == WhisperModelFolder.defaultPath)
        #expect(config.apiKey == "")
        #expect(config.baseURL == "https://api.openai.com/v1")
        #expect(config.language == "")
    }

    @Test func testSTTConfigSendable() {
        let config = STTConfig(mode: .cloud, apiKey: "test-key")
        // STTConfig is Sendable, can be passed across isolation boundaries
        let copied = config
        #expect(copied.mode == .cloud)
        #expect(copied.apiKey == "test-key")
    }

    // MARK: - LLMConfigSnapshot 测试

    @Test func testLLMConfigSnapshotValidURL() throws {
        let config = LLMConfig(
            name: "Test",
            baseURL: "https://api.openai.com",
            modelName: "gpt-4o"
        )
        let snapshot = try LLMConfigSnapshot(config: config)
        #expect(snapshot.chatCompletionsURL == "https://api.openai.com/v1/chat/completions")
        #expect(snapshot.modelName == "gpt-4o")
    }

    @Test func testLLMConfigSnapshotInvalidURL() {
        let config = LLMConfig(
            name: "Test",
            baseURL: "not a valid url at all!!!",
            modelName: "model"
        )
        #expect(throws: LLMError.self) {
            _ = try LLMConfigSnapshot(config: config)
        }
    }

    @Test func testLLMConfigSnapshotTrailingSlash() throws {
        let config = LLMConfig(
            name: "Test",
            baseURL: "https://api.example.com/",
            modelName: "model"
        )
        let snapshot = try LLMConfigSnapshot(config: config)
        #expect(snapshot.chatCompletionsURL == "https://api.example.com/v1/chat/completions")
    }

    // MARK: - LLM SSE 分片解析（正文 / 思考文本 / 结束原因）

    @Test func testParseChunkFieldsContentOnly() {
        let fields = LLMService.parseChunkFields(
            #"{"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}"#)
        #expect(fields?.content == "你好")
        #expect(fields?.reasoning == nil)
        #expect(fields?.finishReason == nil)
    }

    @Test func testParseChunkFieldsReasoningContentNotDiscarded() {
        // 推理型模型的思考块：没有 content，旧实现会在解析 content 时整块丢弃
        let fields = LLMService.parseChunkFields(
            #"{"choices":[{"delta":{"reasoning_content":"先看转写"},"finish_reason":null}]}"#)
        #expect(fields?.content == nil)
        #expect(fields?.reasoning == "先看转写")
    }

    @Test func testParseChunkFieldsReasoningAlias() {
        let fields = LLMService.parseChunkFields(
            #"{"choices":[{"delta":{"reasoning":"thinking"},"finish_reason":null}]}"#)
        #expect(fields?.reasoning == "thinking")
    }

    @Test func testParseChunkFieldsFinishReasonLengthWithoutContent() {
        // 预算耗尽的结束块：只有 finish_reason，正文为空——必须能被读到才能归因
        let fields = LLMService.parseChunkFields(
            #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        #expect(fields?.content == nil)
        #expect(fields?.finishReason == "length")
    }

    @Test func testParseChunkFieldsFinishReasonWithoutDelta() {
        let fields = LLMService.parseChunkFields(#"{"choices":[{"finish_reason":"stop"}]}"#)
        #expect(fields?.finishReason == "stop")
        #expect(fields?.content == nil)
    }

    @Test func testParseChunkFieldsInvalidPayload() {
        #expect(LLMService.parseChunkFields("not json") == nil)
        #expect(LLMService.parseChunkFields(#"{"choices":[]}"#) == nil)
    }

    // MARK: - 转写 / 说话人区分合并为单条进度条

    /// 可手动推进的测试时钟（估计器的 `now` 注入点）
    private final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// 固定基线：3600s 音频 → 转写估算 900s、分离估算 180s（便于手算期望值）
    private func makeEstimator(
        audioSeconds: Double = 3600,
        diarizationEnabled: Bool = true,
        transcriptionRTF: Double = 0.25,
        diarizationRTF: Double = 0.05,
        clock: TestClock
    ) -> TranscriptionProgressEstimator {
        TranscriptionProgressEstimator(
            audioSeconds: audioSeconds,
            diarizationEnabled: diarizationEnabled,
            profile: TranscriptionRTFProfile(
                transcriptionRTF: transcriptionRTF,
                diarizationRTF: diarizationRTF,
                isCalibrated: true
            ),
            now: { clock.now }
        )
    }

    @Test func testEstimatorTranscriptionOwnsWholeBarWithoutDiarization() {
        // 未开启说话人区分：转写独占整条进度，不能只走到一半就结束
        let clock = TestClock()
        var estimator = makeEstimator(diarizationEnabled: false, clock: clock)
        estimator.begin(.transcription)
        estimator.reportFraction(0.4)
        #expect(abs(estimator.progress() - 0.4) < 0.0001)
        estimator.finish(.transcription)
        #expect(abs(estimator.progress() - 1) < 0.0001)
    }

    @Test func testEstimatorSnapsToTranscriptionShareAtStageBoundary() {
        // 转写段结束即钉在 900 / (900 + 180) = 83.3%，估算误差不跨段累积
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(900)
        estimator.finish(.transcription)
        #expect(abs(estimator.progress() - 900.0 / 1080.0) < 0.001)
    }

    @Test func testEstimatorCreepsThroughDiarizationWithoutCallback() {
        // 分离没有进度回调：推进到估算耗时时应走完该段的 90%（线性段上限）
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(900)
        estimator.finish(.transcription)
        estimator.begin(.diarization)
        clock.advance(180)
        let expected = (900.0 + 0.9 * 180.0) / 1080.0
        #expect(abs(estimator.progress() - expected) < 0.001)
    }

    @Test func testEstimatorCreepDeceleratesAndNeverReachesHundredPercent() {
        // 远超估算时仍在推进（不静止），但永不显示 100%（避免“100% 了还在跑”）
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(900)
        estimator.finish(.transcription)
        estimator.begin(.diarization)
        clock.advance(180 * 10)
        let progress = estimator.progress()
        #expect(progress < 1)
        #expect(progress > 0.95)
    }

    @Test func testEstimatorCompletesWhenDiarizationAborts() {
        // 分离被跳过/失败也要收口到 100%，否则进度条永远停在半程
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(900)
        estimator.finish(.transcription)
        estimator.abort(.diarization)
        #expect(estimator.progress() == 1)
    }

    @Test func testLiveEstimateRaisesTranscriptionEstimateWhenSlowerThanExpected() {
        // 实测速率远慢于基线：转写总耗时估算被上调（钳制在 4 倍以内）
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(900)
        estimator.reportFraction(0.1)   // 900s 只跑完 10% ⇒ 推算总耗时 9000s
        let durations = estimator.estimatedDurations()
        #expect(durations.transcription > 900)
        #expect(durations.transcription <= 900 * 4 + 0.001)
    }

    @Test func testLiveEstimateNeverShrinksBelowInitialGuess() {
        // 只允许上调：下调会造成同段内进度回退，猜高的那次由基线表在下次运行修正
        let clock = TestClock()
        var estimator = makeEstimator(clock: clock)
        estimator.begin(.transcription)
        clock.advance(90)
        estimator.reportFraction(0.5)   // 推算总耗时 180s，快于基线 900s
        #expect(estimator.estimatedDurations().transcription == 900)
    }

    @Test func testCreepFillShape() {
        #expect(TranscriptionProgressEstimator.creepFill(ratio: 0) == 0)
        #expect(abs(TranscriptionProgressEstimator.creepFill(ratio: 1) - 0.9) < 0.0001)
        #expect(TranscriptionProgressEstimator.creepFill(ratio: 2) > 0.9)
        // 渐近上限是 0.97（双精度下大比值正好落到该值），关键是永远到不了 1
        #expect(TranscriptionProgressEstimator.creepFill(ratio: 100) <= 0.97)
        #expect(TranscriptionProgressEstimator.creepFill(ratio: 100) < 1)
    }

    @Test func testRTFTableBootstrapsThenSmooths() {
        var table = TranscriptionRTFTable()
        let key = "local:whisper-large-v3"
        table.record(key: key, transcriptionSeconds: 300, diarizationSeconds: 60, audioSeconds: 1000)
        // 首个样本直接采用实测值（bootstrap）：0.3 / 0.06
        #expect(abs(table.profile(for: key).transcriptionRTF - 0.3) < 0.0001)
        #expect(abs(table.profile(for: key).diarizationRTF - 0.06) < 0.0001)
        // 第二个样本按 EMA（0.3 权重）：0.3*0.7 + 0.5*0.3 = 0.36
        table.record(key: key, transcriptionSeconds: 500, diarizationSeconds: nil, audioSeconds: 1000)
        #expect(abs(table.profile(for: key).transcriptionRTF - 0.36) < 0.0001)
        // 分离未参与时不得污染分离基线
        #expect(abs(table.profile(for: key).diarizationRTF - 0.06) < 0.0001)
    }

    @Test func testRTFTableFallsBackToUncalibratedPlaceholder() {
        let profile = TranscriptionRTFTable().profile(for: "local:never-ran")
        #expect(profile.transcriptionRTF == TranscriptionRTFTable.uncalibratedTranscriptionRTF)
        #expect(profile.diarizationRTF == TranscriptionRTFTable.uncalibratedDiarizationRTF)
        #expect(profile.isCalibrated == false)
    }

    @Test func testRTFStoreKeySeparatesModelTiers() {
        // 档位之间 RTF 可差数倍，键必须把模型目录名带上
        let large = TranscriptionRTFStore.transcriptionKey(
            mode: .local, modelPath: "/models/whisper-large-v3")
        let tiny = TranscriptionRTFStore.transcriptionKey(
            mode: .local, modelPath: "/models/whisper-tiny")
        #expect(large != tiny)
        #expect(large.contains("whisper-large-v3"))
        #expect(TranscriptionRTFStore.transcriptionKey(mode: .cloud, modelPath: "") == "cloud")
    }

    @Test func testMergedStagePrefersPipelineInFlight() {
        // 转写进行中时不能显示分离行的「等待文字转写完成…」，否则与进度条位置自相矛盾
        let stage = RecordingViewModel.mergedStageText(
            transcription: ProcessingProgressStatus(phase: .running, fraction: 0.2, detail: "正在识别"),
            diarization: ProcessingProgressStatus(phase: .preparing, detail: "等待文字转写完成…"),
            mergeStage: ""
        )
        #expect(stage == "正在识别")
    }

    @Test func testMergedStageFallsBackToMergeStage() {
        let stage = RecordingViewModel.mergedStageText(
            transcription: ProcessingProgressStatus(phase: .completed, fraction: 1, detail: "已完成"),
            diarization: ProcessingProgressStatus(phase: .completed, fraction: 1, detail: "已完成"),
            mergeStage: "正在合并并保存…"
        )
        #expect(stage == "正在合并并保存…")
    }

    // MARK: - TranscriptionResult 测试

    @Test func testTranscriptionResultSendable() {
        let result = TranscriptionResult(text: "Hello", startTime: 0.0, endTime: 1.5)
        let copied = result
        #expect(copied.text == "Hello")
        #expect(copied.startTime == 0.0)
        #expect(copied.endTime == 1.5)
    }

    // MARK: - AudioConverter 格式支持测试

    @Test func testSupportedExtensions() {
        #expect(AudioConverter.supportedExtensions.contains("m4a"))
        #expect(AudioConverter.supportedExtensions.contains("mp3"))
        #expect(AudioConverter.supportedExtensions.contains("wav"))
        #expect(!AudioConverter.supportedExtensions.contains("aac"))
        #expect(!AudioConverter.supportedExtensions.contains("flac"))
    }

    // MARK: - 视频导入（抽音轨进既有链路，原始视频同文件夹留存）

    @Test func testVideoExtensionsDoNotOverlapAudio() {
        #expect(AudioConverter.videoExtensions.isDisjoint(with: AudioConverter.supportedExtensions))
        for ext in ["mp4", "mov", "m4v"] {
            #expect(AudioConverter.videoExtensions.contains(ext))
        }
        // 磁盘扫描靠“音频扩展名集合”认最终录音，MKV/AVI 等未验证容器不得混进来
        #expect(!AudioConverter.videoExtensions.contains("mkv"))
        #expect(!AudioConverter.videoExtensions.contains("avi"))
    }

    /// 往返一致性：导入写出的留存名必须能被磁盘扫描重新识别（文件即权威源）
    @Test func testRetainedVideoNameRoundTrip() {
        let name = AudioConverter.retainedVideoName(base: "20260914120000", ext: "mp4")
        #expect(name == "20260914120000_video.mp4")
        #expect(AudioConverter.retainedVideoFileName(in: [URL(fileURLWithPath: "/x/\(name)")]) == name)
    }

    /// 失败/无关路径：普通命名视频与录音分片不得被误判为视频附件
    @Test func testRetainedVideoFileNameIgnoresOthers() {
        #expect(AudioConverter.retainedVideoFileName(in: [URL(fileURLWithPath: "/x/movie.mp4")]) == nil)
        #expect(AudioConverter.retainedVideoFileName(in: [
            URL(fileURLWithPath: "/x/20260914_mic_tmp_0001.caf")
        ]) == nil)
        #expect(AudioConverter.retainedVideoFileName(in: []) == nil)
    }

    // MARK: - Whisper 语言测试

    @Test func testWhisperLanguagesAreDisplayable() {
        let languages = WhisperLanguage.allCases
        #expect(languages.count >= 20)
        #expect(Set(languages.map(\.id)).count == languages.count)
        for language in languages {
            #expect(!language.displayName.isEmpty)
        }
    }

    // MARK: - LLMPreset 测试

    @Test func testLLMPresetProperties() {
        for preset in LLMPreset.allCases {
            #expect(!preset.displayName.isEmpty)
            #expect(!preset.icon.isEmpty)
            #expect(!preset.description.isEmpty)
        }
    }

    // MARK: - 错误类型测试

    // MARK: - 端点安全性校验（模型类型不授予明文传输许可）

    /// 校验是否放行（true = 允许发起请求）
    private func endpointAllowed(_ url: String, isLocalModel: Bool) -> Bool {
        do {
            try LLMService.validateSecureURL(url, isLocalModel: isLocalModel)
            return true
        } catch {
            return false
        }
    }

    /// 勾选本地模型不能代替端点传输授权；LAN 显式授权见 EndpointPolicy 回归用例。
    @Test func testLocalFlagDoesNotGrantTransportConsent() {
        #expect(!endpointAllowed("http://192.168.1.20:11434/v1", isLocalModel: true))
        #expect(!endpointAllowed("http://nas.home.local:1234/v1", isLocalModel: true))
        #expect(!endpointAllowed("HTTP://192.168.1.20:11434/v1", isLocalModel: true))
    }

    /// 未独立授权的 LAN HTTP、公网 HTTP、非 http/https 均不能用本地标记绕过。
    @Test func testCloudModelStillRejectsPlainHTTPOffLoopback() {
        #expect(!endpointAllowed("http://192.168.1.20:11434/v1", isLocalModel: false))
        #expect(!endpointAllowed("http://nas.home.local:1234/v1", isLocalModel: false))
        #expect(!endpointAllowed("ftp://192.168.1.20:11434/v1", isLocalModel: true))
        // 解不出端点地址的输入不得默认放行
        #expect(!endpointAllowed("192.168.1.20:11434/v1", isLocalModel: true))
        #expect(!endpointAllowed("", isLocalModel: true))
    }

    /// https 永远可用；回环 http 保持旧行为（未勾本地模型也放行）
    @Test func testHTTPSAndLoopbackHTTPUnchanged() {
        #expect(endpointAllowed("https://api.openai.com/v1", isLocalModel: false))
        #expect(endpointAllowed("HTTPS://API.OpenAI.COM/v1", isLocalModel: false))
        #expect(endpointAllowed("http://localhost:1234/v1", isLocalModel: false))
        #expect(endpointAllowed("http://127.0.0.1:11434/v1", isLocalModel: false))
        #expect(endpointAllowed("http://[::1]:11434/v1", isLocalModel: false))
    }

    // MARK: - 关键帧抽取（纯函数部分：高频扫描、画面变化、代表帧）

    /// 默认每 0.5 秒扫描一次，且所有时间点都在视频内部。
    @Test func testScanTimesUsesSubsecondInterval() {
        let times = KeyframeExtractor.scanTimes(duration: 2)
        #expect(times == [0.25, 0.75, 1.25, 1.75])
        #expect(zip(times, times.dropFirst()).allSatisfy { pair in
            pair.1 - pair.0 <= 0.5
        })
    }

    /// 不足一个采样间隔的短视频仍会在中点扫描一次。
    @Test func testScanTimesHandlesShortVideo() {
        #expect(KeyframeExtractor.scanTimes(duration: 0.2) == [0.1])
    }

    /// 边界：非法时长或间隔不得产生候选点（避免后续除零或死循环）。
    @Test func testScanTimesDegenerateInputs() {
        #expect(KeyframeExtractor.scanTimes(duration: 0).isEmpty)
        #expect(KeyframeExtractor.scanTimes(duration: -5).isEmpty)
        #expect(KeyframeExtractor.scanTimes(duration: 10, interval: 0).isEmpty)
        #expect(KeyframeExtractor.scanTimes(duration: .infinity).isEmpty)
    }

    // MARK: - 关键帧测试辅助

    /// 直接构造签名：分块均值默认全 128，让用例只控制某一路特征
    private func signature(
        horizontal: UInt64,
        vertical: UInt64 = 0,
        blocks: [UInt8]? = nil
    ) -> FrameSignature {
        FrameSignature(
            horizontal: horizontal,
            vertical: vertical,
            blockMeans: blocks ?? [UInt8](repeating: 128, count: 9)
        )
    }

    private func flatLuminance(side: Int, value: UInt8) -> [UInt8] {
        [UInt8](repeating: value, count: side * side)
    }

    /// 9×8 网格：每行左→右递增（可选奇数行整体提亮）。
    /// 左右哈希恒为全 1，只有上下方向发生变化——正是旧版单一水平 dHash 看不见的垂直滚动。
    private func rampGrid(lightenOddRows: Bool) -> [UInt8] {
        var grid = [UInt8](repeating: 0, count: 9 * 8)
        for row in 0..<8 {
            for column in 0..<9 {
                let offset: Int = (lightenOddRows && row % 2 == 1) ? 10 : 0
                grid[row * 9 + column] = UInt8(column * 28 + offset)
            }
        }
        return grid
    }

    // MARK: - 画面变化事件

    /// 静止画面被折叠，明显变化被保留（关掉最小间隔与静默兜底，单独验证判重本身）
    @Test func testSceneChangesFoldStaticFrames() {
        let samples: [(time: TimeInterval, signature: FrameSignature)] = [
            (0.25, signature(horizontal: 0)),
            (0.75, signature(horizontal: 0b11)),
            (1.25, signature(horizontal: .max, vertical: .max)),
            (1.75, signature(horizontal: .max ^ 0b1, vertical: .max ^ 0b10)),
            (2.25, signature(horizontal: 0))
        ]
        let changes = KeyframeExtractor.sceneChangeTimes(
            from: samples, minEventInterval: 0, maxSilenceInterval: .infinity
        )
        #expect(changes.map(\.time) == [0.25, 1.25, 2.25])
    }

    /// 抖动被最小事件间隔抑制，真转场靠硬切阈值立即保留（否则快速翻页会被吞）
    @Test func testSceneChangesSuppressJitterAndHonorHardCut() {
        let samples: [(time: TimeInterval, signature: FrameSignature)] = [
            (0, signature(horizontal: 0)),
            (0.5, signature(horizontal: (1 << 16) - 1)),   // 16 bit 抖动：变了但不够密
            (1.0, signature(horizontal: (1 << 20) - 1)),   // 20 bit 抖动：仍未到硬切
            (4.0, signature(horizontal: (1 << 20) - 1)),   // 超过最小间隔 → 记事件
            (4.5, signature(horizontal: .max))             // 位差 44 ≥ 26 → 硬切立即记
        ]
        let changes = KeyframeExtractor.sceneChangeTimes(
            from: samples, maxSilenceInterval: .infinity
        )
        #expect(changes.map(\.time) == [0, 4.0, 4.5])
    }

    /// 缓慢渐变（每步只差 2 bit，永远不超阈值）仍能靠最长静默兜底持续输出代表点
    @Test func testSceneChangesFallbackOnLongSilence() {
        let samples: [(time: TimeInterval, signature: FrameSignature)] = [
            (0, signature(horizontal: 0b11)),
            (40, signature(horizontal: 0b1111)),
            (80, signature(horizontal: 0b111111)),
            (120, signature(horizontal: 0b11111111))
        ]
        let changes = KeyframeExtractor.sceneChangeTimes(from: samples)
        #expect(changes.map(\.time) == [0, 40, 80, 120])
    }

    // MARK: - 代表帧名额分配（长视频丢帧的回归位置）

    /// 长视频回归：演示段（10 分钟里 61 个事件）不得吃掉全部名额，
    /// 静止但信息量高的幻灯片必须各自拿到窗口。
    /// 旧实现按事件序号等间隔取样，这里会把 1800/3600/5400s 三个静止页全部挤掉。
    @Test func testRepresentativeSelectionCoversTimeline() {
        let duration: TimeInterval = 7200   // 2 小时
        let stillPageTimes: [TimeInterval] = [60, 1800, 3600, 5400, 7200]
        let demoTimes = stride(from: 600.0, through: 1200.0, by: 10).map { $0 }
        // 静止页彼此画面不同（块均值两两差 30 > 阈值）；演示段 61 个事件同一画面
        var events: [SceneEvent] = stillPageTimes.enumerated().map { index, time in
            SceneEvent(time: time, signature: signature(
                horizontal: 0,
                blocks: [UInt8](repeating: UInt8(40 + index * 30), count: 9)
            ))
        }
        let demoSignature = signature(horizontal: 0, blocks: [UInt8](repeating: 200, count: 9))
        events += demoTimes.map { SceneEvent(time: $0, signature: demoSignature) }

        let picked = KeyframeExtractor.selectRepresentativeTimes(
            events: events, duration: duration, limit: 8
        )

        // 每个静止页都拿到名额
        #expect(Set(picked).isSuperset(of: Set(stillPageTimes)))
        // 高频变化段最多占 2 个名额
        #expect(picked.filter { (590...1210).contains($0) }.count <= 2)
        #expect(picked == picked.sorted())
        // 新不变式：入选帧两两不属于同一画面。旧版用「至少隔半个窗口」当门，
        // 实测会让同一段静止内容在不同窗口各占一帧（32 个名额里 6 个重复），现在改成按画面判重
        var signatureByTime: [TimeInterval: FrameSignature] = [:]
        for event in events { signatureByTime[event.time] = event.signature }
        for (offset, earlier) in picked.enumerated() {
            for later in picked.dropFirst(offset + 1) {
                guard let lhs = signatureByTime[earlier], let rhs = signatureByTime[later] else {
                    Issue.record("入选时间点必须能回查到签名")
                    continue
                }
                #expect(!KeyframeExtractor.isSameScene(lhs, asReferenceTo: rhs))
            }
        }
        // 回填轮找不到不同画面时宁可不填满：5 个静止页 + 1 个演示段代表，而不是凑 8 帧重复画面
        #expect(picked == [60, 1_200, 1_800, 3_600, 5_400, 7_200])
    }

    /// 事件数不足名额时原样返回（短视频不为凑数去抽重复画面）；需淘汰时按画面不重复优先
    @Test func testRepresentativeSelectionPassesThroughSparseEvents() {
        let sparse: [SceneEvent] = [
            SceneEvent(time: 1, signature: signature(horizontal: 0)),
            SceneEvent(time: 2, signature: signature(horizontal: .max)),
            SceneEvent(time: 3, signature: signature(
                horizontal: 0,
                blocks: [UInt8](repeating: 250, count: 9)
            ))
        ]
        #expect(KeyframeExtractor.selectRepresentativeTimes(events: sparse, duration: 10, limit: 8) == [1, 2, 3])
        #expect(KeyframeExtractor.selectRepresentativeTimes(events: sparse, duration: 10, limit: 2) == [1, 3])
        #expect(KeyframeExtractor.selectRepresentativeTimes(events: [], duration: 10, limit: 8).isEmpty)
        #expect(KeyframeExtractor.selectRepresentativeTimes(events: sparse, duration: 10, limit: 0).isEmpty)
    }

    /// 显式预算仍按时长自适应并有安全上限；默认抽帧链路不再用它压缩稳定重大变化。
    @Test func testKeyframeBudgetScalesWithDuration() {
        #expect(KeyframeExtractor.keyframeBudget(duration: 60) == 8)
        #expect(KeyframeExtractor.keyframeBudget(duration: 1800) == 30)
        #expect(KeyframeExtractor.keyframeBudget(duration: 3600) == 60)
        #expect(KeyframeExtractor.keyframeBudget(duration: 9_833) == 164)
        #expect(KeyframeExtractor.keyframeBudget(duration: 20_000) == 334)
        #expect(KeyframeExtractor.keyframeBudget(duration: 40_000) == 667)
        #expect(KeyframeExtractor.keyframeBudget(duration: 80_000) == 1_024)
        #expect(KeyframeExtractor.keyframeBudget(duration: 0) == 8)
        #expect(KeyframeExtractor.keyframeBudget(duration: .nan) == 8)
        #expect(KeyframeExtractor.keyframeBudget(duration: .infinity) == 8)
    }

    /// 扫描间隔随时长放宽，短视频保留 0.5s 抓短暂画面
    @Test func testScanIntervalAdaptsToDuration() {
        #expect(KeyframeExtractor.scanInterval(forDuration: 1800) == 0.5)
        #expect(KeyframeExtractor.scanInterval(forDuration: 7200) == 0.72)
        #expect(KeyframeExtractor.scanInterval(forDuration: 36000) == 3.6)
        #expect(KeyframeExtractor.scanInterval(forDuration: 0) == 0.5)
    }

    // MARK: - 帧判重（两路差值哈希 + 分块亮度）

    @Test func testColorChangeIsNotFoldedWhenStructureAndLuminanceMatch() {
        let red = FrameSignature(
            horizontal: 0,
            vertical: 0,
            blockMeans: [UInt8](repeating: 128, count: 9),
            colorBlockMeans: [UInt8](repeating: 40, count: 27)
        )
        var changedColor = [UInt8](repeating: 40, count: 27)
        changedColor[2] = 100
        let blue = FrameSignature(
            horizontal: 0,
            vertical: 0,
            blockMeans: [UInt8](repeating: 128, count: 9),
            colorBlockMeans: changedColor
        )
        #expect(!KeyframeExtractor.isSameScene(red, asReferenceTo: blue))
    }

    @Test func testDetailHashSeesSmallChangesMissedByCoarseHash() {
        let base = FrameSignature(
            horizontal: 0,
            vertical: 0,
            blockMeans: [UInt8](repeating: 128, count: 9),
            detailHorizontal: [0, 0, 0, 0],
            detailVertical: [0, 0, 0, 0]
        )
        let changed = FrameSignature(
            horizontal: 0,
            vertical: 0,
            blockMeans: [UInt8](repeating: 128, count: 9),
            detailHorizontal: [(1 << 25) - 1, 0, 0, 0],
            detailVertical: [0, 0, 0, 0]
        )
        #expect(!KeyframeExtractor.isSameScene(base, asReferenceTo: changed))
    }

    /// 垂直滚动：左右哈希完全相同（旧版必丢），靠上下路拉回来
    @Test func testVerticalScrollIsNotFolded() {
        let base = rampGrid(lightenOddRows: false)
        let scrolled = rampGrid(lightenOddRows: true)
        guard let baseGrid = KeyframeExtractor.dHash(fromLuminance: base),
              let scrolledGrid = KeyframeExtractor.dHash(fromLuminance: scrolled),
              let baseMeans = KeyframeExtractor.blockMeans(fromLuminance: base, width: 9, height: 8, blocksPerSide: 1),
              let scrolledMeans = KeyframeExtractor.blockMeans(fromLuminance: scrolled, width: 9, height: 8, blocksPerSide: 1)
        else {
            Issue.record("网格应能算出哈希与分块均值")
            return
        }
        let old = signature(horizontal: baseGrid, blocks: baseMeans)
        let scrolledSignature = signature(horizontal: scrolledGrid, vertical: KeyframeExtractor.vHash(fromLuminance: scrolled) ?? 0, blocks: scrolledMeans)

        // 旧指纹完全看不见这个变化（这就是当时垂直滚动丢帧的原因）
        #expect(KeyframeExtractor.hammingDistance(old.horizontal, scrolledSignature.horizontal) == 0)
        // 上下路补上 36 bit 位差，分块亮度再补一好 → 不再被归入同一画面
        #expect(KeyframeExtractor.bitDistance(old, scrolledSignature) == 36)
        #expect(KeyframeExtractor.isSameScene(scrolledSignature, asReferenceTo: old) == false)
    }

    /// 平场退化：纯色/黑场/白场的差值哈希全是 0，只能由分块亮度门区分
    @Test func testFlatColorSwapIsNotFolded() {
        let dark = flatLuminance(side: 24, value: 30)
        let light = flatLuminance(side: 24, value: 240)
        guard let darkBlocks = KeyframeExtractor.blockMeans(fromLuminance: dark, width: 24, height: 24),
              let lightBlocks = KeyframeExtractor.blockMeans(fromLuminance: light, width: 24, height: 24)
        else {
            Issue.record("24×24 应能均分成 3×3 块")
            return
        }
        let a = signature(horizontal: 0, blocks: darkBlocks)
        let b = signature(horizontal: 0, blocks: lightBlocks)
        // 已知失效：结构哈希完全无法区分两个平场画面
        #expect(KeyframeExtractor.bitDistance(a, b) == 0)
        #expect(KeyframeExtractor.maxBlockDelta(a, b) == 210)
        #expect(KeyframeExtractor.isSameScene(b, asReferenceTo: a) == false)
        // 同一平场反复扫描则必须判重，否则静止页会每帧一个事件
        #expect(KeyframeExtractor.isSameScene(a, asReferenceTo: a))
    }

    /// 局部小窗变化（右下角共享画面、进度条、时间码）：整体结构不变，仍能被块均值抓住
    @Test func testLocalWindowChangeIsNotFolded() {
        var bottomRightChanged = flatLuminance(side: 24, value: 100)
        for row in 16..<24 {
            for column in 16..<24 {
                bottomRightChanged[row * 24 + column] = 200
            }
        }
        let blocksA = KeyframeExtractor.blockMeans(fromLuminance: flatLuminance(side: 24, value: 100), width: 24, height: 24) ?? []
        let blocksB = KeyframeExtractor.blockMeans(fromLuminance: bottomRightChanged, width: 24, height: 24) ?? []
        #expect(blocksA.count == 9)
        let uniform = signature(horizontal: 0, blocks: blocksA)
        let windowChanged = signature(horizontal: 0, blocks: blocksB)
        // 结构位差为 0（旧指纹必判重），靠分块亮度门拉回来
        #expect(KeyframeExtractor.bitDistance(uniform, windowChanged) == 0)
        #expect(KeyframeExtractor.maxBlockDelta(uniform, windowChanged) > KeyframeExtractor.blockDeltaThreshold)
        #expect(KeyframeExtractor.isSameScene(windowChanged, asReferenceTo: uniform) == false)
        // 同一画面反复扫描必须判重，否则静止页会每帧一个事件
        #expect(KeyframeExtractor.isSameScene(windowChanged, asReferenceTo: windowChanged) == true)
    }

    /// dHash：平坦图为 0；逐行递增每行 8 位全置；距离与双门判重符合预期
    @Test func testDHashStabilityAndSensitivity() {
        let flat = [UInt8](repeating: 128, count: 9 * 8)
        guard let base = KeyframeExtractor.dHash(fromLuminance: flat) else {
            Issue.record("平坦图应能算出哈希")
            return
        }
        #expect(base == 0)

        var gradient = flat
        for row in 0..<8 {
            for column in 0..<9 {
                gradient[row * 9 + column] = UInt8(column * 20)
            }
        }
        guard let asc = KeyframeExtractor.dHash(fromLuminance: gradient) else {
            Issue.record("渐变图应能算出哈希")
            return
        }
        #expect(asc == UInt64.max)
        #expect(KeyframeExtractor.hammingDistance(base, asc) == 64)

        let ascSignature = signature(horizontal: asc)
        let baseSignature = signature(horizontal: base)
        #expect(KeyframeExtractor.isSameScene(ascSignature, asReferenceTo: baseSignature) == false)
        #expect(KeyframeExtractor.isSameScene(ascSignature, asReferenceTo: ascSignature) == true)
        // 容忍细微噪声：位差在阈值内且无分块亮度变化即视为同一画面
        #expect(KeyframeExtractor.isSameScene(signature(horizontal: asc ^ 0b11), asReferenceTo: ascSignature))
        // 长度不符直接拒算，不返回“看起来对”的错值
        #expect(KeyframeExtractor.dHash(fromLuminance: [UInt8](repeating: 0, count: 10)) == nil)
        #expect(KeyframeExtractor.vHash(fromLuminance: [UInt8](repeating: 0, count: 10)) == nil)
        // 不能整除的网格不猜均值
        #expect(KeyframeExtractor.blockMeans(
            fromLuminance: [UInt8](repeating: 9, count: 25), width: 5, height: 5, blocksPerSide: 3
        ) == nil)
    }

    /// 帧在时间上成簇时，降采样仍须按时间铺开（按下标等分会全落在簇里）并保留首尾
    @Test func testEvenlySpacedPrefersTimeCoverageOverIndex() {
        var frames: [VideoKeyframe] = (0..<20).map {
            VideoKeyframe(time: Double($0) * 0.1, jpegData: Data([UInt8($0)]))
        }
        frames.append(VideoKeyframe(time: 3600, jpegData: Data([255])))
        let picked = LLMService.evenlySpaced(frames, limit: 8)
        #expect(picked.count == 8)
        #expect(picked.first?.time == 0)
        #expect(picked.last?.time == 3600)
        // 结尾那帧不靠序号、只靠时间目标点也能入选，同时末尾区段不会完全没代表
        #expect(picked.filter { $0.time > 3000 }.count >= 1)
    }

    /// 多图上限：按时间等分降采样必须保留首尾（否则开头与结尾的画面永远不进模型）
    @Test func testEvenlySpacedKeepsFirstAndLast() {
        let frames = (0..<20).map { VideoKeyframe(time: Double($0) * 10, jpegData: Data([UInt8($0)])) }
        let picked = LLMService.evenlySpaced(frames, limit: 8)
        #expect(picked.count == 8)
        #expect(picked.first?.time == 0)
        #expect(picked.last?.time == 190)
        #expect(zip(picked, picked.dropFirst()).allSatisfy { pair in pair.0.time < pair.1.time })
        // 未超限原样返回；limit 非法或无帧都给空
        #expect(LLMService.evenlySpaced(frames, limit: 40).count == 20)
        #expect(LLMService.evenlySpaced(frames, limit: 0).isEmpty)
        #expect(LLMService.evenlySpaced([], limit: 8).isEmpty)
    }

    /// 会议分类器回答解析：明确说「否/no」才判非会议，无法判断的保守视为会议
    /// （与批量总结等无按钮入口的文本 detectMeeting 同一解析语义）
    @Test func testInterpretMeetingAnswer() {
        #expect(LLMService.interpretMeetingAnswer("是"))
        #expect(LLMService.interpretMeetingAnswer(" 是 "))
        #expect(LLMService.interpretMeetingAnswer("yes"))
        #expect(!LLMService.interpretMeetingAnswer("否"))
        #expect(!LLMService.interpretMeetingAnswer(" NO"))
        // 空输出/答非所问保守回退会议模板，避免误伤真实会议
        #expect(LLMService.interpretMeetingAnswer(""))
        #expect(LLMService.interpretMeetingAnswer("这段内容难以判断"))
    }

    /// 帧落盘命名：字典序即时间序，不同时间点不重名
    @Test func testFrameFileNameIsTimeOrdered() {
        let early = AudioRecording.frameFileName(index: 1, time: 200.4)
        let later = AudioRecording.frameFileName(index: 2, time: 400.9)
        #expect(early == "kf_0001_200.400s.jpg")
        #expect(later == "kf_0002_400.900s.jpg")
        #expect([later, early].sorted() == [early, later])
    }

    @Test func testErrorDescriptions() {
        #expect(AudioConverterError.noAudioTrack.errorDescription != nil)
        #expect(AudioConverterError.exportTimeout.errorDescription != nil)
        #expect(KeyframeError.unreadableVideo.errorDescription != nil)
        #expect(KeyframeError.noKeyframe.errorDescription != nil)
        #expect(LLMError.noVisualFrames.errorDescription != nil)
        #expect(LLMError.invalidURL.errorDescription != nil)
        #expect(WhisperLocalError.modelNotLoaded.errorDescription != nil)
        #expect(WhisperAPIError.invalidURL.errorDescription != nil)
        #expect(ImportError.unsupportedFormat("xyz").errorDescription != nil)
        #expect(ImportError.insufficientDiskSpace(freeBytes: 1 << 30, requiredBytes: 2 << 30).errorDescription != nil)
    }

    // MARK: - 导出文档测试

    @Test func testPlainTextDocumentInit() {
        let doc = PlainTextDocument(text: "Hello, World!")
        #expect(doc.text == "Hello, World!")
        #expect(PlainTextDocument.writableContentTypes.contains { $0.conforms(to: .plainText) })
    }

    @Test func testMarkdownDocumentInit() {
        let markdown = "## Title\n\n- Item 1\n- Item 2"
        let doc = MarkdownDocument(text: markdown)
        #expect(doc.text == markdown)
        #expect(MarkdownDocument.writableContentTypes.first?.preferredFilenameExtension == "md")
    }

    // MARK: - LLMService 系统提示词测试

    @Test func testSystemPromptNotEmpty() {
        #expect(!LLMService.systemPrompt.isEmpty)
        #expect(LLMService.systemPrompt.contains("会议"))
        #expect(LLMService.systemPrompt.contains("Markdown"))
    }

    @Test func testSystemPromptContainsRequiredSections() {
        let prompt = LLMService.systemPrompt
        #expect(prompt.contains("## 会议主题"))
        #expect(prompt.contains("## 参会人员"))
        #expect(prompt.contains("## 决议与行动项"))
    }

    // MARK: - TimeInterval 边界测试

    @Test func testFormattedDurationNegativeValues() {
        // 负数是时钟校正时可能出现的输入，显示为 0。
        let duration: TimeInterval = -5
        #expect(duration.formattedAsDuration() == "0:00")
    }

    @Test func testFormattedDurationNonFiniteValuesDoNotCrash() {
        #expect(TimeInterval.nan.formattedAsDuration() == "0:00")
        #expect(TimeInterval.infinity.formattedAsDuration() == "0:00")
    }

    @Test func testFormattedDurationLargeValues() {
        let duration: TimeInterval = 86400 // 24 hours
        #expect(duration.formattedAsDuration() == "24:00:00")
    }

    @Test func testFormattedDurationExactlyOneHour() {
        let duration: TimeInterval = 3600
        #expect(duration.formattedAsDuration() == "1:00:00")
    }

    // MARK: - LLMConfig 预设模板测试

    @Test func testLLMConfigTemplates() {
        let lmStudio = LLMConfig.lmStudioTemplate()
        #expect(lmStudio.isLocal == true)
        #expect(lmStudio.baseURL.contains("localhost"))

        let ollama = LLMConfig.ollamaTemplate()
        #expect(ollama.isLocal == true)
        #expect(ollama.baseURL.contains("11434"))

        let openAI = LLMConfig.openAITemplate()
        #expect(openAI.isLocal == false)
        #expect(openAI.baseURL.contains("openai"))

        let custom = LLMConfig.customTemplate()
        #expect(custom.isLocal == false)
    }

    // MARK: - 端点拼接规则（各家 OpenAI 兼容端点路径不同）

    private func chatEndpoint(_ baseURL: String) -> String? {
        LLMConfig.endpointURL(forBaseURL: baseURL, appending: "chat/completions")?.absoluteString
    }

    @Test func testEndpointWithoutPathGetsV1() {
        #expect(chatEndpoint("https://api.openai.com") == "https://api.openai.com/v1/chat/completions")
        #expect(chatEndpoint("https://api.deepseek.com/") == "https://api.deepseek.com/v1/chat/completions")
        #expect(chatEndpoint("http://localhost:11434") == "http://localhost:11434/v1/chat/completions")
    }

    /// 带版本路径的端点不能再插一层 /v1，否则 GLM / 通义千问会直接 404
    @Test func testEndpointWithVersionPathIsNotDoubled() {
        #expect(chatEndpoint("https://open.bigmodel.cn/api/paas/v4")
                == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(chatEndpoint("https://dashscope.aliyuncs.com/compatible-mode/v1")
                == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(chatEndpoint("https://api.moonshot.cn/v1")
                == "https://api.moonshot.cn/v1/chat/completions")
    }

    /// 已经写到叶子端点的 Base URL 应当替换而不是拼接
    @Test func testEndpointAlreadyCompleteIsNotDoubled() {
        #expect(chatEndpoint("https://api.openai.com/v1/chat/completions")
                == "https://api.openai.com/v1/chat/completions")
    }

    @Test func testEveryPresetEndpointIsSane() {
        for preset in LLMPreset.allCases {
            let url = LLMConfig.endpointURL(forBaseURL: preset.baseURL, appending: "chat/completions")
            #expect(url != nil, "\(preset.rawValue) 的端点无法构造")
            guard let url else { continue }
            #expect(url.absoluteString.hasSuffix("/chat/completions"))
            #expect(!url.absoluteString.contains("/v1/v1"))
        }
    }

    // MARK: - 服务商元数据

    @Test func testPresetMetadataIsComplete() {
        for preset in LLMPreset.allCases {
            #expect(!preset.baseURL.isEmpty, "\(preset.rawValue) 缺少 Base URL")
            #expect(!preset.defaultModel.isEmpty, "\(preset.rawValue) 缺少默认模型")
            if preset != .custom {
                #expect(!preset.suggestedModels.isEmpty, "\(preset.rawValue) 缺少建议模型清单")
            }
        }
        // 本地服务必须标成 isLocal：否则明文 HTTP 与「是否需要 API Key」都会判错
        #expect(LLMPreset.ollama.isLocal)
        #expect(LLMPreset.lmStudio.isLocal)
        #expect(!LLMPreset.ollama.requiresAPIKey)
        #expect(LLMPreset.deepSeek.requiresAPIKey)
    }

    @Test func testPresetMatchingBaseURL() {
        #expect(LLMPreset.matching(baseURL: "https://api.openai.com/") == .openAI)
        #expect(LLMPreset.matching(baseURL: "https://open.bigmodel.cn/api/paas/v4") == .glm)
        #expect(LLMPreset.matching(baseURL: "http://localhost:11434") == .ollama)
        // 用户改过端点就反查不到，此时只能手动输入，不猜服务商
        #expect(LLMPreset.matching(baseURL: "https://my-gateway.example.com/v2") == nil)
    }

    // MARK: - STTMode 显示名称测试

    @Test func testSTTModeDisplayNames() {
        for mode in STTMode.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }
}

/// 设备切换后的麦克风分片格式回归：不依赖真实会议软件或输入设备。
struct MicCaptureFormatTests {
    private func writeSilentSegment(to url: URL, format: AVAudioFormat) throws {
        let settings = try #require(MicCaptureService.fileSettings(for: format))
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(frames))
            }
        }
        try file.write(from: buffer)
    }

    @Test func inputFormatChangeNeedsNewSegment() throws {
        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let same = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))

        #expect(!MicCaptureService.requiresNewSegment(from: mono, to: same))
        #expect(MicCaptureService.requiresNewSegment(from: mono, to: stereo))
        #expect(MicCaptureService.requiresNewSegment(from: stereo, to: mono))
    }

    @Test func stereoInputCanBeWrittenToItsOwnSegment() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let settings = try #require(MicCaptureService.fileSettings(for: input))
        #expect(settings[AVNumberOfChannelsKey] as? Int == 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaMicFormat-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: input.commonFormat, interleaved: input.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 128))
        buffer.frameLength = 128
        try file.write(from: buffer)
        #expect(file.length == 128)
    }

    @Test func changedInputFormatsMergeIntoOneRecording() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaMicMerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let first = directory.appendingPathComponent("sample_mic_tmp_0001.caf")
        let second = directory.appendingPathComponent("sample_mic_tmp_0002.caf")
        let output = directory.appendingPathComponent("sample.m4a")
        try writeSilentSegment(to: first, format: mono)
        try writeSilentSegment(to: second, format: stereo)

        let captured = CapturedSegments(micURLs: [first, second], sysURLs: [],
                                        finalURL: output, micFormatChanged: true)
        let merged = await MeetingRecorderService.shared.mergeCapturedSegments(captured)
        #expect(merged == output)
        let file = try AVAudioFile(forReading: output)
        #expect(Double(file.length) / file.fileFormat.sampleRate > 0.15)
    }
}

// MARK: - 全局热键

/// 录音热键（默认 ⌃⌘R，冲突时回退 ⇧⌃⌘R）的默认值与回退规则。
/// 只断言纯函数与常量，不触发真实注册——`GlobalHotkeyManager.shared` 会向系统注册热键
struct GlobalHotkeyTests {

    @Test("录音热键默认 ⌃⌘R，备选组合是它再加 Shift")
    func recordingHotkeyDefaults() {
        let defaultKey = GlobalHotkeyManager.recordingDefaultKeyCode
        let defaultMods = GlobalHotkeyManager.recordingDefaultModifiers
        let fallbackKey = GlobalHotkeyManager.recordingFallbackKeyCode
        let fallbackMods = GlobalHotkeyManager.recordingFallbackModifiers

        #expect(
            HotkeyFormatter.displayString(keyCode: defaultKey, carbonModifiers: defaultMods) == "⌃⌘R",
            "默认录音热键必须是 ⌃⌘R"
        )
        // 备选组合 = 默认组合 + ⇧（同键位、修饰键是默认的超集）
        #expect(fallbackKey == defaultKey)
        #expect(fallbackMods != defaultMods)
        #expect(
            fallbackMods & defaultMods == defaultMods,
            "备选组合必须包含默认组合的全部修饰键，只额外多了 Shift"
        )
        #expect(
            HotkeyFormatter.displayString(keyCode: fallbackKey, carbonModifiers: fallbackMods) == "⌃⇧⌘R",
            "⇧⌃⌘R 的显示串按现有符号顺序渲染为 ⌃⇧⌘R"
        )
    }

    @Test("仅当仍使用默认组合时才自动回退录音热键")
    func recordingHotkeyFallbackOnlyForDefaultCombination() {
        let resolved = GlobalHotkeyManager.recordingFallbackCombination(
            keyCode: GlobalHotkeyManager.recordingDefaultKeyCode,
            carbonModifiers: GlobalHotkeyManager.recordingDefaultModifiers
        )
        #expect(resolved?.keyCode == GlobalHotkeyManager.recordingFallbackKeyCode)
        #expect(resolved?.carbonModifiers == GlobalHotkeyManager.recordingFallbackModifiers)

        // 已经是备选组合（即用户/上一次解析留下的非默认值）不得再次回退，
        // 否则用户显式改过的组合会被悄悄换成别的
        #expect(GlobalHotkeyManager.recordingFallbackCombination(
            keyCode: GlobalHotkeyManager.recordingFallbackKeyCode,
            carbonModifiers: GlobalHotkeyManager.recordingFallbackModifiers
        ) == nil)
    }
}
