import Foundation
import Testing

@testable import Memozia

/// 同名声纹合并（VoiceprintStore.mergedVoiceprint / mergeSameNameGroups）回归。
///
/// 钉住的行为契约：
/// - 同名 + 同模型的条目按 sampleCount 加权平均 → L2 归一化 → 质心方向正确；
/// - 跨模型/跨维度/单条目不合并（不同嵌入空间不可平均）；
/// - 落盘合并：先写合并结果再删余条；来源录音 ID 并集去重、时间戳沿用最早创建。
struct VoiceprintMergeTests {

    private func makeVoiceprint(
        name: String,
        embedding: [Float],
        sampleCount: Int,
        modelId: String = VoiceprintStore.modelId,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        recordingIds: [String] = []
    ) -> Voiceprint {
        Voiceprint(
            id: UUID(),
            name: name,
            embedding: VoiceprintStore.l2Normalize(embedding),
            dim: embedding.count,
            modelId: modelId,
            createdAt: createdAt,
            updatedAt: createdAt,
            sampleCount: sampleCount,
            sourceRecordingIds: recordingIds
        )
    }

    @Test("同名两条目加权质心：样本多者权高，方向为加权平均后归一化")
    func weightedCentroid() throws {
        // v1 = [1, 0]，v2 = [0, 1]，权重 1:3 → 均值方向 ≈ [0.25, 0.75] → 归一化 [0.316, 0.949]
        let v1 = makeVoiceprint(name: "张三", embedding: [1, 0], sampleCount: 1)
        let v2 = makeVoiceprint(name: "张三", embedding: [0, 1], sampleCount: 3)
        #expect(v1.createdAt <= v2.createdAt)

        let merged = try #require(VoiceprintStore.mergedVoiceprint(from: [v1, v2]))
        #expect(merged.name == "张三")
        #expect(merged.id == v1.id, "沿用最早一条的 id（覆写其文件，身份连续）")
        #expect(merged.createdAt == v1.createdAt)
        #expect(merged.sampleCount == 4)
        #expect(merged.dim == 2)
        #expect(merged.modelId == VoiceprintStore.modelId)
        let norm = Double(merged.embedding[0] * merged.embedding[0] + merged.embedding[1] * merged.embedding[1]).squareRoot()
        #expect(abs(norm - 1) < 1e-5, "合并结果必须保持归一化（点积=余弦的前提）")
        #expect(merged.embedding[1] > merged.embedding[0], "权重更大的 v2 方向应占优")
        // 加权均值 [0.25, 0.75]，‖·‖=√(0.0625+0.5625)=√0.625 → 归一化第一分量 = 0.25/√0.625
        #expect(abs(Double(merged.embedding[0]) - 0.25 / (0.625).squareRoot()) < 1e-4)
    }

    @Test("来源录音 ID 并集去重、按创建时间序合并")
    func recordingIdsUnion() throws {
        let older = makeVoiceprint(name: "李四", embedding: [1, 1], sampleCount: 2,
                                   createdAt: Date(timeIntervalSince1970: 100),
                                   recordingIds: ["A", "B"])
        let newer = makeVoiceprint(name: "李四", embedding: [1, -1], sampleCount: 1,
                                   createdAt: Date(timeIntervalSince1970: 200),
                                   recordingIds: ["B", "C"])
        let merged = try #require(VoiceprintStore.mergedVoiceprint(from: [newer, older]))
        #expect(merged.sourceRecordingIds == ["A", "B", "C"])
    }

    @Test("单条目、跨模型、维度不一致的组都不合并")
    func refusesInvalidGroups() {
        let a = makeVoiceprint(name: "王五", embedding: [1, 0, 0], sampleCount: 1)
        #expect(VoiceprintStore.mergedVoiceprint(from: [a]) == nil)

        let otherModel = makeVoiceprint(name: "王五", embedding: [0, 1, 0], sampleCount: 1, modelId: "legacy-model")
        #expect(VoiceprintStore.mergedVoiceprint(from: [a, otherModel]) == nil, "不同嵌入模型的向量空间不可平均")

        let dimMismatch = makeVoiceprint(name: "王五", embedding: [1, 0], sampleCount: 1)
        #expect(VoiceprintStore.mergedVoiceprint(from: [a, dimMismatch]) == nil)
    }

    @Test("mergeSameNameGroups 临时目录落盘：同名合并、异名保留、余条文件删除")
    func mergeWritesToDisk() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VoiceprintMergeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dir = folder.path

        let a1 = makeVoiceprint(name: "张三", embedding: [1, 0], sampleCount: 2, recordingIds: ["R1"])
        let a2 = makeVoiceprint(name: "张三", embedding: [0, 1], sampleCount: 1,
                               createdAt: Date(timeIntervalSince1970: 100), recordingIds: ["R2"])
        let b = makeVoiceprint(name: "李四", embedding: [1, 1], sampleCount: 1)
        for vp in [a1, a2, b] { try VoiceprintStore.save(vp, folder: dir) }

        let mergedGroups = try VoiceprintStore.mergeSameNameGroups(folder: dir)
        #expect(mergedGroups == 1)

        let after = VoiceprintStore.loadAll(folder: dir)
        #expect(after.count == 2, "两条张三归一，李四不动")
        let zhang = after.first { $0.name == "张三" }
        let zhangReplaced = a1.createdAt <= a2.createdAt ? a1 : a2
        #expect(zhang?.id == zhangReplaced.id)
        #expect(zhang?.sampleCount == 3)
        #expect(zhang?.sourceRecordingIds.count == 2)
        // 被归并的旧文件已删除（文件夹里只剩 2 个 json）
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(files.filter { $0.hasSuffix(".json") }.count == 2)
    }

    @Test("精修选段：短段过滤、每说话人按时长截断到 30、输出序确定")
    func embeddingSelectionCap() {
        func seg(_ speaker: Int, _ start: Double, _ duration: Double) -> DiarizationSegment {
            DiarizationSegment(start: start, end: start + duration, speaker: speaker)
        }
        var segments: [DiarizationSegment] = []
        // 说话人 0：35 个 2s 有效段 + 5 个 1s 短段（应全部被过滤）
        for i in 0..<35 { segments.append(seg(0, Double(i) * 10, 2)) }
        for i in 0..<5 { segments.append(seg(0, 1000 + Double(i) * 10, 1)) }
        // 说话人 2：1.5s 临界段（含边界保留）+ 1.49s 短段（过滤）
        segments.append(seg(2, 0, 1.5))
        segments.append(seg(2, 10, 1.49))

        let picked = SpeakerDiarizationService.embeddingSegmentsBySpeaker(segments)
        #expect(picked.map(\.speaker) == [0, 2], "说话人升序")
        #expect(picked[0].segments.count == 30, "35 段截断为最长 30 段")
        #expect(picked[0].segments.allSatisfy { $0.end - $0.start >= 2 })
        // 组内时长降序（全等时长时保持可预期的稳定截断即可）
        let durations = picked[0].segments.map { $0.end - $0.start }
        #expect(durations == durations.sorted(by: >))
        #expect(picked[1].segments.count == 1, "1.5s 临界保留、1.49s 过滤")
    }

    @Test("识别前同名条目折叠为单条：同名只留一个质心，异名不受影响")
    func collapsingSameNameFoldsDuplicates() throws {
        // 复现实测情形：同一人被注册成两条（跨场次相似度不达查重阈值 0.65）
        let he1 = makeVoiceprint(name: "何锋", embedding: [1, 0], sampleCount: 19,
                                 createdAt: Date(timeIntervalSince1970: 100))
        let he2 = makeVoiceprint(name: "何锋", embedding: [0, 1], sampleCount: 16,
                                 createdAt: Date(timeIntervalSince1970: 200))
        let other = makeVoiceprint(name: "振宁", embedding: [1, 1], sampleCount: 30)

        let collapsed = VoiceprintStore.collapsingSameName([he1, he2, other])
        #expect(collapsed.count == 2, "同名两条折叠为一条，异名独立保留")
        let he = try #require(collapsed.first { $0.name == "何锋" })
        #expect(he.sampleCount == 35)
        #expect(he.id == he1.id, "沿用最早一条 id，身份连续")
        // 折叠后同一姓名不可能再同时占据 top1/top2（这正是 margin 被挤占的根因）
        let names = collapsed.map(\.name)
        #expect(Set(names).count == names.count)

        // 单条目/空输入原样返回
        let single = VoiceprintStore.collapsingSameName([other])
        #expect(single.count == 1)
        #expect(single[0].id == other.id)
        #expect(VoiceprintStore.collapsingSameName([]).isEmpty)
    }

    @Test("注册选段与识别选段同源：同过滤、同取最长 30 段")
    func voiceprintRangesMatchesRecognitionSelection() {
        // 35 个 2s 有效段 + 5 个 1s 短段（短段应被过滤）
        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        for i in 0..<35 {
            ranges.append((start: Double(i) * 10, end: Double(i) * 10 + 2))
        }
        for i in 0..<5 {
            ranges.append((start: 1000 + Double(i) * 10, end: 1000 + Double(i) * 10 + 1))
        }

        let selected = SpeakerDiarizationService.voiceprintRanges(ranges)
        #expect(selected.count == 30, "截断为最长 30 段")
        #expect(selected.allSatisfy { $0.end - $0.start >= 1.5 }, "短段被过滤")

        // 与识别侧同源：同一输入经 embeddingSegmentsBySpeaker 得到同一集合
        let viaRecognition = SpeakerDiarizationService.embeddingSegmentsBySpeaker(
            ranges.map { DiarizationSegment(start: $0.start, end: $0.end, speaker: 0) }
        ).first?.segments.map { (start: $0.start, end: $0.end) } ?? []
        #expect(selected.map(\.start) == viaRecognition.map(\.start))

        // 全部过短 → 空，调用方据此抛 insufficientAudio
        #expect(SpeakerDiarizationService.voiceprintRanges([
            (start: 0, end: 0.5), (start: 1, end: 1.4),
        ]).isEmpty)
    }
}
