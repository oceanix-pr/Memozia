import Foundation
import Testing

@testable import Memozia

/// `DiarizationSegmentationPlanner` 的确定性单测：时长/内存估算、阈值判定、
/// 分段切分（含重叠）、重叠区去重、跨段说话人身份合并、按总时长重编号。
///
/// 这些函数是长录音分段分离的纯计算核心，不依赖真实模型或真机音频；
/// 输入相同即输出相同，可在无模型环境下钉住行为，避免分段逻辑以后被悄然改坏。
struct DiarizationSegmentationTests {

    private func seg(_ start: Double, _ end: Double, _ speaker: Int) -> DiarizationSegment {
        DiarizationSegment(start: start, end: end, speaker: speaker)
    }

    // MARK: - 时长 / 内存估算

    @Test("内存估算 = 时长 × 采样率 × 4 字节")
    func testEstimatedSampleBytes() {
        #expect(
            DiarizationSegmentationPlanner.estimatedSampleBytes(
                duration: 60, sampleRate: 16_000) == 60 * 16_000 * 4
        )
        #expect(
            DiarizationSegmentationPlanner.estimatedSampleBytes(
                duration: 0, sampleRate: 16_000) == 0
        )
        #expect(
            DiarizationSegmentationPlanner.estimatedSampleBytes(
                duration: -5, sampleRate: 16_000) == 0
        )
    }

    // MARK: - 阈值判定

    @Test("阈值以内走整段，超过时长或内存阈值才分段")
    func testModeThreshold() {
        let policy = DiarizationSegmentationPlanner.Policy(
            maxDirectDuration: 30 * 60,
            maxDirectMemoryBytes: 256 * 1024 * 1024,
            segmentDuration: 8 * 60,
            segmentOverlap: 30
        )
        // 30 分钟整（阈值）仍为整段；略超即分段
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 30 * 60, sampleRate: 16_000, policy: policy) == .direct)
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 30 * 60 + 1, sampleRate: 16_000, policy: policy) == .segmented)
        // 1 小时 / 2 小时必定分段（本任务关注的长录音）
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 60 * 60, sampleRate: 16_000, policy: policy) == .segmented)
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 120 * 60, sampleRate: 16_000, policy: policy) == .segmented)
        // 0 / 负时长视为无内容，走整段（由音频读取阶段报错，而不是误判为需要分段）
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 0, sampleRate: 16_000, policy: policy) == .direct)
    }

    @Test("时长在阈值内但估算内存超阈值时仍进入分段（内存阈值独立生效）")
    func testModeMemoryThresholdTriggersSegmentation() {
        // 时长阈值放宽到 2 小时，内存阈值收紧到仅够 1 分钟
        let policy = DiarizationSegmentationPlanner.Policy(
            maxDirectDuration: 120 * 60,
            maxDirectMemoryBytes: 60 * 16_000 * 4,
            segmentDuration: 8 * 60,
            segmentOverlap: 30
        )
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 60, sampleRate: 16_000, policy: policy) == .direct)
        #expect(DiarizationSegmentationPlanner.mode(
            duration: 61, sampleRate: 16_000, policy: policy) == .segmented)
    }

    // MARK: - 分段切分

    @Test("20 分钟按 8 分钟分段、重叠 30 秒，末段夹到总时长")
    func testSegmentRangesWithOverlap() {
        let ranges = DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: 20 * 60, segmentDuration: 8 * 60, overlap: 30)
        #expect(ranges == [0..<(8 * 60), (450)..<(930), (900)..<(1200)])
        // 相邻区间必有重叠，且步长恒为正（不出现零长度/反序）
        for index in 1..<ranges.count {
            #expect(ranges[index].lowerBound > ranges[index - 1].lowerBound)
            #expect(ranges[index].lowerBound < ranges[index - 1].upperBound)
        }
    }

    @Test("时长不超过单段时只返回一个完整区间")
    func testSegmentRangesSingleChunk() {
        #expect(
            DiarizationSegmentationPlanner.segmentRanges(
                totalDuration: 5 * 60, segmentDuration: 8 * 60, overlap: 30) == [0..<(5 * 60)]
        )
        #expect(
            DiarizationSegmentationPlanner.segmentRanges(
                totalDuration: 8 * 60, segmentDuration: 8 * 60, overlap: 30) == [0..<(8 * 60)]
        )
    }

    @Test("重叠被夹到不超过半段，非法输入返回空")
    func testSegmentRangesClampAndInvalid() {
        // overlap 大于半段：夹到半段，步长仍为正
        let ranges = DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: 100, segmentDuration: 40, overlap: 999)
        #expect(ranges == [0..<40, 20..<60, 40..<80, 60..<100])
        #expect(DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: 0, segmentDuration: 8 * 60, overlap: 30).isEmpty)
        #expect(DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: 100, segmentDuration: 0, overlap: 30).isEmpty)
    }

    // MARK: - 重叠区去重

    @Test("完全被前段覆盖的片段被丢弃")
    func testMergeOverlappingDropsCovered() {
        let merged = DiarizationSegmentationPlanner.mergeOverlapping([
            seg(0, 10, 0), seg(2, 5, 1),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].start == 0 && merged[0].end == 10 && merged[0].speaker == 0)
    }

    @Test("部分重叠：前段标签优先，后段被裁到前段结束（时间戳不重复）")
    func testMergeOverlappingTrimsToPrevious() {
        let merged = DiarizationSegmentationPlanner.mergeOverlapping([
            seg(0, 10, 0), seg(8, 12, 1),
        ])
        #expect(merged.count == 2)
        #expect(merged[1].start == 10 && merged[1].end == 12 && merged[1].speaker == 1)
        // 结果区间严格连续、无重叠时间戳
        for index in 1..<merged.count {
            #expect(merged[index].start >= merged[index - 1].end)
        }
    }

    @Test("重叠且同说话人：裁剪后与后段合并为一段")
    func testMergeOverlappingSameSpeakerCoalesces() {
        let merged = DiarizationSegmentationPlanner.mergeOverlapping([
            seg(0, 10, 0), seg(8, 12, 0),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].start == 0 && merged[0].end == 12 && merged[0].speaker == 0)
    }

    @Test("相邻且同说话人的片段合并（跨段边界去重时间戳）")
    func testMergeOverlappingAdjacentSameSpeaker() {
        let merged = DiarizationSegmentationPlanner.mergeOverlapping([
            seg(0, 10, 0), seg(10, 15, 0), seg(15, 20, 1),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].start == 0 && merged[0].end == 15 && merged[0].speaker == 0)
        #expect(merged[1].speaker == 1)
    }

    @Test("乱序输入先按时间排序再处理")
    func testMergeOverlappingSortsInput() {
        let merged = DiarizationSegmentationPlanner.mergeOverlapping([
            seg(20, 30, 1), seg(0, 10, 0),
        ])
        #expect(merged.map(\.start) == [0, 20])
    }

    // MARK: - 跨段身份合并

    @Test("同段质心相同 → 跨段映射到同一全局编号")
    func testGlobalSpeakerMappingMatchesSameCentroid() {
        let mappings = DiarizationSegmentationPlanner.globalSpeakerMapping(
            chunkCentroids: [[0: [1, 0, 0]], [0: [1, 0, 0]]],
            matchThreshold: 0.55
        )
        #expect(mappings == [[0: 0], [0: 0]])
    }

    @Test("不同质心 → 分配新的全局编号；相似质心复用已有编号")
    func testGlobalSpeakerMappingAssignsAndReuses() {
        let mappings = DiarizationSegmentationPlanner.globalSpeakerMapping(
            chunkCentroids: [
                [0: [1, 0, 0], 1: [0, 1, 0]],
                [0: [0, 1, 0], 1: [0, 0, 1]],
            ],
            matchThreshold: 0.9
        )
        // 段 0：0→全局 0，1→全局 1
        #expect(mappings[0] == [0: 0, 1: 1])
        // 段 1 的 0 与全局 1 相同 → 复用；1 全新 → 全局 2
        #expect(mappings[1] == [0: 1, 1: 2])
    }

    @Test("相似度不足阈值即视为不同人（阈值边界确定性）")
    func testGlobalSpeakerMappingThresholdBoundary() {
        let near = [Float(1), Float(1), Float(0)]
        let mappings = DiarizationSegmentationPlanner.globalSpeakerMapping(
            chunkCentroids: [[0: [1, 0, 0]], [0: near]],
            matchThreshold: 0.9
        )
        // 余弦相似度 ≈ 0.707 < 0.9 → 新编号
        #expect(mappings[1][0] == 1)
    }

    @Test("空质心单独占编号，不影响可比值比对")
    func testGlobalSpeakerMappingEmptyCentroid() {
        let mappings = DiarizationSegmentationPlanner.globalSpeakerMapping(
            chunkCentroids: [[0: [1, 0, 0], 1: []], [0: [1, 0, 0]]],
            matchThreshold: 0.55
        )
        #expect(mappings[0][0] == 0)
        #expect(mappings[0][1] == 1)
        #expect(mappings[1][0] == 0)
    }

    // MARK: - 按总时长重编号

    @Test("按总时长降序重编号，0 = 说得最多")
    func testRenumberByTotalDuration() {
        let (segments, mapping) = DiarizationSegmentationPlanner.renumberByTotalDuration([
            seg(0, 1, 5),   // 说话人 5 共 1s
            seg(1, 6, 7),   // 说话人 7 共 5s
            seg(6, 20, 5),  // 说话人 5 再 +14s → 共 15s
        ])
        #expect(mapping == [5: 0, 7: 1])
        // 说话人 5（15s）新编号 0，说话人 7（5s）新编号 1
        #expect(segments.map(\.speaker) == [0, 1, 0])
    }

    @Test("时长相同按原编号升序，结果确定")
    func testRenumberStableForEqualDurations() {
        let (_, mapping) = DiarizationSegmentationPlanner.renumberByTotalDuration([
            seg(0, 5, 3), seg(5, 10, 1),
        ])
        #expect(mapping == [1: 0, 3: 1])
    }
}
