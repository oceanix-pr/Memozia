import AVFoundation
import Foundation
import Testing
@testable import Memozia

@Suite(.serialized)
struct WaveformAnalyzerTests {
    @Test
    func keepsWaveformColumnCountBounded() {
        #expect(WaveformAnalyzer.columnCount(forDuration: 0) == WaveformAnalyzer.minColumns)
        #expect(WaveformAnalyzer.columnCount(forDuration: 10) == WaveformAnalyzer.minColumns)
        #expect(WaveformAnalyzer.columnCount(forDuration: 10 * 60 * 60) == WaveformAnalyzer.maxColumns)
        #expect(WaveformAnalyzer.columnCount(forDuration: .infinity) == WaveformAnalyzer.minColumns)
    }

    @Test
    func downsamplePreservesShortSoundAndAbsoluteSilence() {
        let peaks = Array(repeating: Float.zero, count: 1000) + [0.5] + Array(repeating: Float.zero, count: 1000)
        let normalized = WaveformAnalyzer.normalize(peaks, limit: 10)
        #expect(normalized.count == 10)
        #expect(normalized.filter { $0 > 0 }.count == 1)
        #expect(normalized.contains(1))

        let silence = WaveformAnalyzer.normalize(Array(repeating: 0, count: 100), limit: 10)
        #expect(silence == Array(repeating: 0, count: 10))

        let faintNoise = WaveformAnalyzer.normalize(Array(repeating: 0.001, count: 100), limit: 10)
        #expect(faintNoise == Array(repeating: 0, count: 10))
    }

    @Test
    func decodesAlternatingSilenceAndToneWithoutWholeFileBuffering() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformAnalyzerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silence-and-tone.wav")
        let sampleRate = 16_000
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for isTone in [false, true, false, true] {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
                buffer.frameLength = buffer.frameCapacity
                let samples = try #require(buffer.floatChannelData)[0]
                for index in 0..<Int(buffer.frameLength) {
                    samples[index] = isTone ? 0.5 * sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) : 0
                }
                try file.write(from: buffer)
            }
        }

        let waveform = try #require(await WaveformAnalyzer.analyze(url: url, columns: 4))
        #expect(waveform.peaks.count == 4)
        #expect(waveform.peaks[0] <= WaveformAnalyzer.silenceThreshold)
        #expect(waveform.peaks[1] > 0.9)
        #expect(waveform.peaks[2] <= WaveformAnalyzer.silenceThreshold)
        #expect(waveform.peaks[3] > 0.9)
        #expect(!waveform.isAudible(0))
        #expect(waveform.isAudible(1))
        #expect(!waveform.isAudible(2))
        #expect(waveform.isAudible(3))
    }
}
