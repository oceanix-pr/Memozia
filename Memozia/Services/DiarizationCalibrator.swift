import Foundation
import SherpaOnnxShared

/// 说话人分离聚类阈值校准工具（开发调试用）
///
/// 以 `--calibrate-diarization <音频路径> [阈值列表,逗号分隔]` 启动应用时执行：
/// 对同一音频以不同聚类阈值运行离线说话人分离，打印各阈值下的说话人数与
/// 每人发言时长，用于校准 clustering threshold，随后直接退出（不启动 UI）。
/// 未带参数时为无操作空返回，对正常启动零开销。
enum DiarizationCalibrator {

    static let launchFlag = "--calibrate-diarization"

    /// 启动参数命中时执行校准并 exit(0)；未命中直接返回
    /// 第二个参数为 "centroid" 时改跑质心重聚类实验（诊断过度分裂问题）
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flagIndex = args.firstIndex(of: launchFlag) else { return }
        let rest = Array(args.dropFirst(flagIndex + 1))
        guard let audioPath = rest.first else {
            print("用法: --calibrate-diarization <音频路径> [阈值列表|centroid] [模型文件夹]")
            ProcessLimits.exitSkippingStaticDestructors(1)
        }
        if rest.count >= 2 && rest[1] == "refine" {
            // 端到端验证：运行正式管线的分离 + 簇后处理，输出最终说话人数与时长
            let modelPath = rest.count >= 3 ? rest[2] : DiarizationModelFolder.defaultPath
            let sem = DispatchSemaphore(value: 0)
            let url = URL(fileURLWithPath: audioPath)
            Task {
                do {
                    let (segments, centroids) = try await SpeakerDiarizationService.shared.diarizeWithSamples(
                        audioURL: url, modelPath: modelPath
                    )
                    var durations: [Int: TimeInterval] = [:]
                    for seg in segments { durations[seg.speaker, default: 0] += seg.end - seg.start }
                    print("最终说话人数: \(durations.count)（质心数 \(centroids.count)）")
                    for (s, d) in durations.sorted(by: { $0.value > $1.value }) {
                        print(String(format: "  说话人 %d = %.1fs", s + 1, d))
                    }
                } catch {
                    print("分离失败: \(error.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
        if rest.count >= 2 && rest[1].hasPrefix("centroid") {
            // centroid 或 centroid:<初始阈值>
            let initialThreshold: Float
            if let value = rest[1].split(separator: ":").dropFirst().first, let parsed = Float(value) {
                initialThreshold = parsed
            } else {
                initialThreshold = 0.5
            }
            let modelPath = rest.count >= 3 ? rest[2] : DiarizationModelFolder.defaultPath
            runCentroidExperiment(audioPath: audioPath, modelPath: modelPath, initialThreshold: initialThreshold)
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
        let thresholds: [Float]
        if rest.count >= 2 {
            thresholds = rest[1].split(separator: ",").compactMap { Float($0) }
        } else {
            thresholds = stride(from: Float(0.30), through: Float(0.60), by: 0.02).map { $0 }
        }
        let modelPath = rest.count >= 3 ? rest[2] : DiarizationModelFolder.defaultPath

        print("校准开始：音频=\(audioPath) 模型=\(modelPath)")
        print("阈值\t说话人数\t各说话人时长(秒)")

        let audioURL = URL(fileURLWithPath: audioPath)
        var cachedSamples: [Float]?

        for threshold in thresholds {
            let folder = URL(fileURLWithPath: modelPath)
            var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                    pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                        model: folder.appendingPathComponent(SpeakerDiarizationService.segmentationFileName).path,
                        // 与正式管线保持一致（取当前精细度档位），校准结果才能直接套用
                        windowShiftRatio: DiarizationPrecision.resolved.windowShiftRatio
                    ),
                    numThreads: 4
                ),
                embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                    model: folder.appendingPathComponent(SpeakerDiarizationService.embeddingFileName).path,
                    numThreads: 4
                ),
                clustering: sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: threshold)
            )
            let diarization = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)

            let samples: [Float]
            if let cached = cachedSamples {
                samples = cached
            } else {
                do {
                    samples = try SpeakerDiarizationService.loadMonoSamples(
                        audioURL: audioURL, sampleRate: diarization.sampleRate
                    )
                } catch {
                    print("音频加载失败: \(error.localizedDescription)")
                    ProcessLimits.exitSkippingStaticDestructors(1)
                }
                cachedSamples = samples
            }

            let result = diarization.process(samples: samples)

            var durations: [Int: Double] = [:]
            for seg in result {
                durations[seg.speaker, default: 0] += TimeInterval(seg.end - seg.start)
            }
            let sorted = durations.sorted { $0.value > $1.value }
            let detail = sorted.map { String(format: "S%d=%.1f", $0.key + 1, $0.value) }.joined(separator: " ")
            print(String(format: "%.2f\t%d\t%@", threshold, durations.count, detail))
            fflush(stdout)
        }
        print("校准完成")
        ProcessLimits.exitSkippingStaticDestructors(0)
    }

    // MARK: - 质心重聚类实验

    /// 诊断过度分裂：先按默认阈值聚类，再逐段提取嵌入，
    /// 输出初始簇间相似度矩阵，并实验"按质心重分配 + 小簇并入最近大簇"后的说话人数
    private static func runCentroidExperiment(audioPath: String, modelPath: String, initialThreshold: Float) {
        let audioURL = URL(fileURLWithPath: audioPath)
        let folder = URL(fileURLWithPath: modelPath)
        print("初始聚类阈值: \(initialThreshold)")

        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: folder.appendingPathComponent(SpeakerDiarizationService.segmentationFileName).path,
                    // 与正式管线保持一致（取当前精细度档位）
                    windowShiftRatio: DiarizationPrecision.resolved.windowShiftRatio
                ),
                numThreads: 4
            ),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: folder.appendingPathComponent(SpeakerDiarizationService.embeddingFileName).path,
                numThreads: 4
            ),
            clustering: sherpaOnnxFastClusteringConfig(numClusters: -1, threshold: initialThreshold)
        )
        let diarization = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)

        let samples: [Float]
        do {
            samples = try SpeakerDiarizationService.loadMonoSamples(
                audioURL: audioURL, sampleRate: diarization.sampleRate
            )
        } catch {
            print("音频加载失败: \(error.localizedDescription)")
            ProcessLimits.exitSkippingStaticDestructors(1)
        }

        let result = diarization.process(samples: samples)
        let sampleRate = diarization.sampleRate

        // 逐段提取嵌入（过滤 <1.5s 的短片段）
        guard let extractor = try? SpeakerDiarizationService.makeEmbeddingExtractor(modelPath: modelPath) else {
            print("嵌入模型加载失败")
            ProcessLimits.exitSkippingStaticDestructors(1)
        }
        var embeddings: [(speaker: Int, start: Float, end: Float, embedding: [Float])] = []
        for seg in result where seg.end - seg.start >= 1.5 {
            let startIdx = max(0, Int(seg.start * Float(sampleRate)))
            let endIdx = min(samples.count, Int(seg.end * Float(sampleRate)))
            guard startIdx < endIdx else { continue }
            let slice = Array(samples[startIdx..<endIdx])
            let emb = SpeakerDiarizationService.computeEmbedding(of: slice, extractor: extractor)
            guard !emb.isEmpty else { continue }
            embeddings.append((Int(seg.speaker), seg.start, seg.end, VoiceprintStore.l2Normalize(emb)))
        }
        print("有效片段数: \(embeddings.count) / \(result.count)")

        // 初始簇时长加权质心
        var clusterSum: [Int: [Float]] = [:]
        var clusterWeight: [Int: Double] = [:]
        for item in embeddings {
            let w = Double(item.end - item.start)
            if clusterSum[item.speaker] == nil {
                clusterSum[item.speaker] = item.embedding.map { $0 * Float(w) }
            } else {
                for i in clusterSum[item.speaker]!.indices {
                    clusterSum[item.speaker]![i] += item.embedding[i] * Float(w)
                }
            }
            clusterWeight[item.speaker, default: 0] += w
        }
        var centroid: [Int: [Float]] = [:]
        for (speaker, sum) in clusterSum {
            let w = Float(clusterWeight[speaker]!)
            centroid[speaker] = VoiceprintStore.l2Normalize(sum.map { $0 / w })
        }

        // 初始簇间相似度矩阵（诊断：真实同人簇的相似度越高越好合并）
        let speakers = centroid.keys.sorted()
        var header = "簇时长"
        for s in speakers { header += String(format: "\tS%d(%.0fs)", s + 1, clusterWeight[s]!) }
        print(header)
        for a in speakers {
            var line = String(format: "S%d", a + 1)
            for b in speakers {
                line += String(format: "\t%.3f", VoiceprintStore.cosineSimilarity(centroid[a]!, centroid[b]!))
            }
            print(line)
        }

        // 实验 1：按质心重分配（全部片段归到最近质心）
        var reassignedDuration: [Int: Double] = [:]
        for item in embeddings {
            var best = item.speaker
            var bestScore: Float = -1
            for (speaker, c) in centroid {
                let score = VoiceprintStore.cosineSimilarity(item.embedding, c)
                if score > bestScore {
                    bestScore = score
                    best = speaker
                }
            }
            reassignedDuration[best, default: 0] += Double(item.end - item.start)
        }
        print("重分配后（簇数不变，时长重新分布）:")
        for (s, d) in reassignedDuration.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  S%d = %.1fs", s + 1, d))
        }

        // 实验 2：小簇并入最近大簇（总时长占比 < 8% 视为小簇）
        let totalDuration = clusterWeight.values.reduce(0, +)
        let bigSpeakers = speakers.filter { (clusterWeight[$0] ?? 0) >= totalDuration * 0.08 }
        var mergedAssignment: [Int: Int] = [:]
        for s in speakers {
            if bigSpeakers.contains(s) {
                mergedAssignment[s] = s
            } else {
                var best = s
                var bestScore: Float = -1
                for b in bigSpeakers {
                    let score = VoiceprintStore.cosineSimilarity(centroid[s]!, centroid[b]!)
                    if score > bestScore {
                        bestScore = score
                        best = b
                    }
                }
                mergedAssignment[s] = best
                print(String(format: "小簇 S%d(%.1fs) 并入 S%d（相似度 %.3f）", s + 1, clusterWeight[s]!, best + 1, bestScore))
            }
        }
        var mergedDuration: [Int: Double] = [:]
        for item in embeddings {
            // 小簇先重分配到最近大簇质心，再按重分配后的簇归并
            let target = mergedAssignment[item.speaker] ?? item.speaker
            mergedDuration[target, default: 0] += Double(item.end - item.start)
        }
        print("小簇合并后说话人数: \(mergedDuration.count)")
        for (s, d) in mergedDuration.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  S%d = %.1fs", s + 1, d))
        }
    }
}
