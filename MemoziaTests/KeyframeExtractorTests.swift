import Testing
import Foundation
@testable import Memozia

/// 关键帧「跨时间窗判重」与「分段送帧」的回归测试。
///
/// 与 `MemoziaTests.swift` 里的关键帧用例分工：那边测单帧指纹、事件检测与名额数字，
/// 本文件只测本轮修复引入的两个不变式，避免同一事实两处维护：
///
/// 1. `selectRepresentativeTimes` 必须**跨窗口**判重。旧实现每窗各取一帧、窗口之间从不比较，
///    而 `sceneChangeTimes` 的锚点会随时间前移，于是同一段静止内容能在不同窗口各占一个名额：
///    实测一条 2h43m 的屏幕录制，32 个名额里 6 个是这种重复帧（最极端一对只差 62 秒、合并位差 1）。
///    现在淘汰的判据是「画面是否重复」，不再是旧的「时间是否隔够半个窗口」。
/// 2. `LLMService.visualChunks` 分段送帧。旧实现把任意时长的视频等间隔砍成 8 帧送模型，
///    实测 2h43m 的视频模型只看 8 帧（每 20 分钟一帧），抽帧侧的名额全部被那一步吞掉。
struct KeyframeExtractorTests {

    // MARK: - 合成签名工具

    private func sig(_ horizontal: UInt64 = 0, mean: UInt8 = 100) -> FrameSignature {
        FrameSignature(
            horizontal: horizontal,
            vertical: 0,
            blockMeans: [UInt8](repeating: mean, count: 9)
        )
    }

    /// 与 `base` 只改结构（64 bit 全翻）→ 合并位差 64，必然判为不同画面
    private func bitFlipped(from base: FrameSignature) -> FrameSignature {
        sig(base.horizontal ^ ~0 as UInt64, mean: meanOf(base))
    }

    private func meanOf(_ signature: FrameSignature) -> UInt8 { signature.blockMeans[0] }

    private func sceneEvents(_ pairs: [(TimeInterval, FrameSignature)]) -> [SceneEvent] {
        pairs.map { SceneEvent(time: $0.0, signature: $0.1) }
    }

    /// 四个两两都不属于同一画面的签名（结构位差或分块亮度差 > 阈值）
    private var mutuallyDistinctSignatures: [FrameSignature] {
        let a = sig()
        let b = sig(~0)
        let c = sig(0, mean: 180)
        let d = sig(~0, mean: 60)
        return [a, b, c, d]
    }

    // MARK: - 事件必须带出签名

    @Test func sceneChangeCarriesSignatureOfTheChangedFrame() {
        let a = sig()
        let b = bitFlipped(from: a)
        let result = KeyframeExtractor.sceneChangeTimes(from: [
            (time: 0, signature: a), (time: 10, signature: b),
        ])
        #expect(result.count == 2)
        // 只回传时间点会让下游无法跨窗判重，所以签名必须一路带出来
        #expect(result.last?.signature == b)
    }

    // MARK: - 跨时间窗判重

    @Test func representativeFramesRejectDuplicatesAcrossWindows() {
        let a = sig()
        let sameAt1500 = sig()                              // 与 t=50 完全同一画面
        let differentAt2500 = bitFlipped(from: a)           // 只改结构
        let differentAt2900 = sig(0, mean: 180)             // 只改局部亮度
        // 窗口 = 3000/3 = 1000 秒：t=50 与 t=1500 分属不同窗口，旧实现两帧都留
        let result = KeyframeExtractor.selectRepresentativeTimes(
            events: sceneEvents([
                (50, a), (1_500, sameAt1500), (2_500, differentAt2500), (2_900, differentAt2900),
            ]),
            duration: 3_000,
            limit: 3
        )
        // 重复帧被拒之后名额必须回填给真正不同的画面，而不是少给一帧
        #expect(result == [50, 2_500, 2_900])
    }

    @Test func representativeFramesKeepEveryEventWhenRoomAllows() {
        // 事件数没超出名额时不做跨窗判重：位置够用就没必要丢帧
        let a = sig()
        let result = KeyframeExtractor.selectRepresentativeTimes(
            events: sceneEvents([(50, a), (1_500, a), (2_500, bitFlipped(from: a))]),
            duration: 3_000,
            limit: 3
        )
        #expect(result == [50, 1_500, 2_500])
    }

    @Test func representativeFramesFillSlotsWithCloseButDistinctScenes() {
        // 四个窗口挤在 30 秒内：旧实现用 window/2 = 250 秒的时间间距当门，只能留 1 帧；
        // 现在只问画面是否重复，名额必须填满
        let signatures = mutuallyDistinctSignatures
        let clustered = sceneEvents([(100, signatures[0]), (110, signatures[1]),
                                     (120, signatures[2]), (130, signatures[3])])
        let result = KeyframeExtractor.selectRepresentativeTimes(
            events: clustered, duration: 1_000, limit: 2
        )
        #expect(result.count == 2)
        #expect(result == [100, 130])
        #expect(result[1] - result[0] < 250)
    }

    @Test func representativeFramesIgnoreNonFiniteTimes() {
        let signatures = mutuallyDistinctSignatures
        let result = KeyframeExtractor.selectRepresentativeTimes(
            events: sceneEvents([(.nan, signatures[0]), (5, signatures[1]), (60, signatures[2])]),
            duration: 100, limit: 2
        )
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.isFinite })
    }

    // MARK: - 超长视频的扫描量与稳定事件

    @Test func longVideoStaysWithinScanPointCap() {
        let duration: TimeInterval = 9_833      // 实测一条 2h43m 屏幕录制
        let interval = KeyframeExtractor.scanInterval(forDuration: duration)
        #expect(interval >= KeyframeExtractor.defaultScanInterval)
        let times = KeyframeExtractor.scanTimes(duration: duration, interval: interval)
        #expect(times.count <= KeyframeExtractor.maxScanPoints)
        // 时间点必须落在视频内部，避开首尾黑帧
        #expect((times.first ?? 0) > 0)
        #expect((times.last ?? duration) < duration)
        #expect(KeyframeExtractor.keyframeBudget(duration: duration) == 164)
    }

    @Test func significantEventsDropSilenceDuplicatesAndShortBounce() {
        let a = sig()
        let b = bitFlipped(from: a)
        let c = sig(0, mean: 180)
        let result = KeyframeExtractor.significantSceneEvents(from: sceneEvents([
            (0, a), (30, a), (60, a),       // 静默兜底，不重复保留
            (70, b), (72, a),               // A→B→A 且 B 只停 2 秒，视为过渡态
            (100, c), (140, a),             // 持续页面与稍后再次出现的 A 都保留
        ]))
        #expect(result.map(\.time) == [0, 100, 140])
    }

    @Test func timelineSafetySelectionKeepsLaterOccurrences() {
        let a = sig()
        let b = bitFlipped(from: a)
        let result = KeyframeExtractor.selectTimelineCoverageTimes(
            events: sceneEvents([(0, a), (10, b), (20, a), (30, b), (40, a)]),
            duration: 50,
            limit: 5
        )
        #expect(result == [0, 10, 20, 30, 40])
    }

    // MARK: - 送模型的分段

    private func frames(_ count: Int) -> [VideoKeyframe] {
        (0..<count).map { index in
            VideoKeyframe(time: Double(index) * 30, jpegData: Data([UInt8(index % 256)]))
        }
    }

    @Test func visualChunksDeliverEveryFrame() {
        let all = frames(64)
        let chunks = LLMService.visualChunks(
            from: all, perRequest: LLMService.maxFramesPerVisualRequest
        )
        #expect(chunks.count == 8)
        #expect(chunks.allSatisfy { $0.count <= LLMService.maxFramesPerVisualRequest })
        // 一帧都不许丢：分段取代了旧的“等间隔砍到 8 帧”
        #expect(chunks.joined().count == all.count)
        #expect(Set(chunks.joined().map { $0.time }) == Set(all.map { $0.time }))
        // 每段是一段连续时间，段与段之间不交错（模型才能按段写时间轴要点）
        for chunk in chunks {
            #expect(chunk == chunk.sorted { $0.time < $1.time })
        }
        // 段与段之间按时间不交错
        let segmentStarts = chunks.compactMap { $0.first?.time }
        #expect(segmentStarts == segmentStarts.sorted())
    }

    @Test func visualChunksDoNotDropFramesBeyondFormerRequestCap() {
        let chunks = LLMService.visualChunks(from: frames(200), perRequest: 8)
        #expect(chunks.count == 25)
        let delivered = chunks.joined()
        #expect(delivered.count == 200)
        #expect(chunks.allSatisfy { $0.count <= 8 })
        #expect(Set(delivered.map { $0.time }).count == delivered.count)   // 不重复送同一帧
    }

    @Test(arguments: [1, 7, 8, 9, 96, 200])
    func visualChunksNeverExceedPerRequestLimit(count: Int) {
        let chunks = LLMService.visualChunks(from: frames(count), perRequest: 8)
        #expect(!chunks.isEmpty)
        #expect(chunks.allSatisfy { $0.count >= 1 && $0.count <= 8 })
        #expect(chunks.count == (count + 7) / 8)
        #expect(chunks.joined().count == count)
    }

    @Test func visualChunksOnEmptyOrInvalidInput() {
        #expect(LLMService.visualChunks(from: [], perRequest: 8).isEmpty)
        #expect(LLMService.visualChunks(from: frames(8), perRequest: 0).isEmpty)
    }
}
