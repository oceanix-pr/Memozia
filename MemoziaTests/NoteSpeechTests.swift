import AVFoundation
import Foundation
import Testing
@testable import Memozia

struct NoteSpeechTests {
    @Test("语音入口仅支持简繁中文；跟随系统只看第一首选语言", arguments: [
        ("zh-Hans", ["en-US"], true),
        ("zh-Hant", ["ja-JP"], true),
        ("en", ["zh-Hans-CN"], false),
        ("ja", ["zh-Hant-TW"], false),
        ("", ["zh-Hans-CN", "en-US"], true),
        ("", ["zh-Hant-TW", "en-US"], true),
        ("", ["zh-CN"], true),
        ("", ["zh-TW"], true),
        ("", ["zh-HK"], true),
        ("", ["en-US", "zh-Hans-CN"], false),
        ("", ["ja-JP", "zh-Hant-TW"], false),
        ("", [], false),
        ("zh-Latn", ["zh-Hans-CN"], false)
    ])
    func interfaceLanguageGate(_ selected: String, _ system: [String], _ expected: Bool) {
        #expect(NoteSpeechAvailability.isSupported(interfaceLanguage: selected, systemLanguages: system) == expected)
    }

    @Test("朗读清理保留正文、链接名、列表和引用，不朗读围栏与图片地址")
    func readableMarkdown() {
        let text = SpeechTextPreparer.prepare("""
        # 计划

        **确认** [文档](https://example.com/private)
        - [x] 第一步
        > 引用内容

        ```swift
        let secret = "should not be spoken"
        ```
        ![截图](https://example.com/image.png)
        """)
        #expect(text.contains("计划"))
        #expect(text.contains("确认 文档"))
        #expect(text.contains("第一步"))
        #expect(text.contains("引用内容"))
        #expect(!text.contains("https://"))
        #expect(!text.contains("should not be spoken"))
        #expect(!text.contains("截图"))
        #expect(!text.contains("**"))
        #expect(!text.contains("[x]"))
    }

    @Test("表格按表头解释每个单元格，不朗读 Markdown 分隔线")
    func tableMeaning() {
        let text = SpeechTextPreparer.prepare("""
        | 项目 | 金额 |
        | --- | ---: |
        | 预算 | 100 元 |
        | 实支 | 80 元 |
        """)
        #expect(text == "项目：预算；金额：100 元\n\n项目：实支；金额：80 元")
    }

    @Test("分段不丢字、不重字，组合字符完整，长无标点文字也会推进")
    func losslessChunks() {
        let text = "开头。\n\n" + String(repeating: "家👨‍👩‍👧‍👦e\u{301}文字", count: 250) + "结束！"
        let chunks = SpeechTextPreparer.chunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 400 })
        #expect(SpeechTextPreparer.chunks("").isEmpty)
        #expect(SpeechTextPreparer.chunks("abc", limit: 0).joined() == "abc")
    }

    @Test("长文优先在句末断开")
    func sentenceBoundary() {
        let text = String(repeating: "甲", count: 250) + "。" + String(repeating: "乙", count: 300)
        let chunks = SpeechTextPreparer.chunks(text)
        #expect(chunks.first?.last == "。")
        #expect(chunks.joined() == text)
    }

    @Test("回调写入后关闭 WAV，并忽略取消后或前一块的迟到回调")
    func audioSinkLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speech.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        pcm.frameLength = 240
        pcm.floatChannelData![0].initialize(repeating: 0.1, count: 240)
        let end = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        let sink = SpeechAudioSink(url: url)
        let first = UUID(), second = UUID()
        let completions = LockedBox(0)
        sink.beginChunk(first)
        let firstCallback = sink.callback(for: first) { _ in completions.value += 1 }
        firstCallback(pcm)
        firstCallback(end)
        sink.beginChunk(second)
        firstCallback(pcm) // 前一块的 PCM 不得混入后一个块。
        let secondCallback = sink.callback(for: second) { _ in completions.value += 1 }
        secondCallback(pcm)
        sink.close()
        secondCallback(pcm)
        secondCallback(end)
        #expect(completions.value == 1)
        #expect(sink.frameCount == 480)
        #expect(try AVAudioFile(forReading: url).length == 480)
    }

    @Test("系统直接结束而未产出 PCM 时明确失败")
    func emptyAudioFails() throws {
        let sink = SpeechAudioSink(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav"))
        defer { sink.close() }
        let id = UUID()
        sink.beginChunk(id)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let end = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        let failed = LockedBox(false)
        sink.callback(for: id) { result in
            if case .failure = result { failed.value = true }
        }(end)
        #expect(failed.value)
        #expect(sink.frameCount == 0)
    }

    @Test("22.05 kHz 系统音色可编码为 M4A，不强设不兼容码率")
    func encodeSystemSampleRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speech.wav")
        let pcmFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 22_050))
        pcm.frameLength = 22_050
        pcm.floatChannelData![0].initialize(repeating: 0.1, count: 22_050)
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: pcmFormat.settings)
        try file?.write(from: pcm)
        file = nil
        let result = try await SpeechAudioEncoder().encode(wavURL: url, format: .m4a)
        let audio = try AVAudioFile(forReading: result)
        #expect(audio.length > 0)
        #expect(CMFormatDescriptionGetMediaSubType(audio.fileFormat.formatDescription) == kAudioFormatMPEG4AAC)
        #expect(audio.processingFormat.sampleRate == 22_050)
    }
}
