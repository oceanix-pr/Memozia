import Foundation
import Observation

/// 声纹记录（每人一个 JSON 文件：姓名 + 声纹嵌入向量 + 元数据）
///
/// `modelId` 绑定生成该向量的嵌入模型：更换模型后向量空间不兼容，
/// 识别时会跳过 modelId 不匹配的声纹，避免错误标注。
struct Voiceprint: Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var embedding: [Float]
    var dim: Int
    var modelId: String
    var createdAt: Date
    var updatedAt: Date
    /// 生成该声纹时使用的有效音频片段数
    var sampleCount: Int
    /// 来源录音 ID（可追溯）
    var sourceRecordingIds: [String]
}

/// 声纹库文件夹（与 WhisperModelFolder / DiarizationModelFolder 同规则）
enum VoiceprintFolder {
    /// 默认路径：macOS 为 ~/Documents/Memozia/Voiceprints，
    /// iOS 为沙盒 Documents/Memozia/Voiceprints
    static var defaultPath: String {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        return base
            .appendingPathComponent("Memozia")
            .appendingPathComponent("Voiceprints")
            .path
    }
}

/// 声纹库存储与相似度计算
///
/// 全部为静态方法、无共享可变状态，可同时被 UI（主线程）与
/// 推理管线（后台并发域）安全调用。文件以 `<uuid>.json` 命名，
/// 重命名声纹不需要改文件名，避免重命名冲突。
enum VoiceprintStore {

    /// 嵌入模型标识：与 SpeakerDiarizationService 使用的 3D-Speaker eres2net 模型绑定
    static let modelId = "3dspeaker-eres2net-base-zh-16k"

    /// 识别阈值（余弦相似度）：低于该值视为未知说话人，保留"说话人 N"。
    /// 参考 sherpa-onnx 快速聚类默认阈值 0.5，宁可保守避免张冠李戴
    static let matchThreshold: Float = 0.5
    /// 第一名与第二名的相似度差需 ≥ 该值才采信，防止近似嗓音误判
    static let matchMargin: Float = 0.05
    /// 注册查重阈值：与已有声纹相似度 ≥ 该值视为同一人
    static let samePersonThreshold: Float = 0.65

    /// 扫描声纹库文件夹加载全部声纹（容错：单文件损坏仅跳过）
    static func loadAll(folder: String = VoiceprintFolder.defaultPath) -> [Voiceprint] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: folder),
            includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [Voiceprint] = []
        for url in urls where url.pathExtension == "json" {
            if Task.isCancelled { break }
            guard let data = try? Data(contentsOf: url),
                  let vp = try? decoder.decode(Voiceprint.self, from: data)
            else {
                FileSyncService.logWarning("声纹文件损坏已跳过: \(url.lastPathComponent)")
                continue
            }
            result.append(vp)
        }
        return result.sorted { $0.name < $1.name }
    }

    /// 保存声纹（覆盖同 id 文件，原子写入）
    static func save(_ voiceprint: Voiceprint, folder: String = VoiceprintFolder.defaultPath) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: folder)
            .appendingPathComponent("\(voiceprint.id.uuidString).json")
        try encoder.encode(voiceprint).write(to: url, options: .atomic)
    }

    /// 删除声纹文件（文件不存在时静默成功）
    static func delete(id: UUID, folder: String = VoiceprintFolder.defaultPath) {
        let url = URL(fileURLWithPath: folder)
            .appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    /// L2 归一化（归一化后余弦相似度 = 点积）
    static func l2Normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// 余弦相似度（维度不一致返回 -1 表示不可比）
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// 注册（或更新）声纹，带查重：
    /// - 与已有声纹相似且同名 → 更新该声纹（替换向量、累计来源）
    /// - 与已有声纹相似但不同名 → 抛错，避免同一人注册成两个身份
    /// - 无相似声纹 → 新建
    @discardableResult
    static func register(
        name: String,
        embedding: [Float],
        sampleCount: Int,
        recordingId: String,
        folder: String = VoiceprintFolder.defaultPath
    ) throws -> Voiceprint {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceprintError.emptyName
        }
        let normalized = l2Normalize(embedding)
        let existing = loadAll(folder: folder)

        if let best = existing.max(by: {
            cosineSimilarity($0.embedding, normalized) < cosineSimilarity($1.embedding, normalized)
        }) {
            let similarity = cosineSimilarity(best.embedding, normalized)
            if similarity >= samePersonThreshold {
                if best.name == trimmed {
                    // 同名同人：更新向量与元数据
                    var updated = best
                    updated.embedding = normalized
                    updated.dim = normalized.count
                    updated.updatedAt = Date()
                    updated.sampleCount = sampleCount
                    if !updated.sourceRecordingIds.contains(recordingId) {
                        updated.sourceRecordingIds.append(recordingId)
                    }
                    try save(updated, folder: folder)
                    return updated
                } else {
                    throw VoiceprintError.conflictWithExisting(
                        best.name, String(format: "%.2f", similarity)
                    )
                }
            }
        }

        let voiceprint = Voiceprint(
            id: UUID(),
            name: trimmed,
            embedding: normalized,
            dim: normalized.count,
            modelId: modelId,
            createdAt: Date(),
            updatedAt: Date(),
            sampleCount: sampleCount,
            sourceRecordingIds: [recordingId]
        )
        try save(voiceprint, folder: folder)
        return voiceprint
    }

    // MARK: - 同名声纹合并

    /// 同组声纹（同名 + 同 modelId + 同维度）的加权合并（纯计算，无 IO，便于单测）：
    /// - 向量按各条 sampleCount（至少 1）加权平均后 L2 归一化：每条本身已是各自样本的质心，
    ///   样本多的代表更稳定，权重更高；
    /// - id/createdAt 沿用最早一条（合并结果覆写该文件，身份连续）；updatedAt 取最新；
    ///   sampleCount 求和；sourceRecordingIds 按时间序合并去重（保留可追溯性）；
    /// - 组内不足 2 条、任一条向量维度与 dim 不符（损坏数据）→ 返回 nil 不合并。
    /// 不同 modelId 的向量空间不兼容，调用方必须按 (name, modelId, dim) 分组后逐组调用。
    static func mergedVoiceprint(from group: [Voiceprint]) -> Voiceprint? {
        guard group.count > 1, let first = group.first, !first.embedding.isEmpty else { return nil }
        let dim = first.dim
        guard dim > 0, group.allSatisfy({ $0.dim == dim && $0.embedding.count == dim && $0.modelId == first.modelId && $0.name == first.name }) else {
            return nil
        }

        var sum = [Float](repeating: 0, count: dim)
        var totalWeight: Float = 0
        for vp in group {
            let weight = Float(max(1, vp.sampleCount))
            for i in 0..<dim where vp.embedding[i] != 0 {
                sum[i] += vp.embedding[i] * weight
            }
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        let mean = sum.map { $0 / totalWeight }
        // l2Normalize 对全零向量原样返回，退化数据不会抛错也不会丢信息
        let embedding = l2Normalize(mean)

        let sorted = group.sorted { $0.createdAt < $1.createdAt }
        let oldest = sorted[0]
        var recordingIds: [String] = []
        for vp in sorted {
            for rid in vp.sourceRecordingIds where !recordingIds.contains(rid) {
                recordingIds.append(rid)
            }
        }
        return Voiceprint(
            id: oldest.id,
            name: oldest.name,
            embedding: embedding,
            dim: embedding.count,
            modelId: oldest.modelId,
            createdAt: oldest.createdAt,
            updatedAt: group.map(\.updatedAt).max() ?? Date(),
            sampleCount: group.reduce(0) { $0 + max(0, $1.sampleCount) },
            sourceRecordingIds: recordingIds
        )
    }

    /// 识别前把同名多条目合并为单条（纯计算，无 IO）。
    ///
    /// 同人跨场次注册相似度达不到查重阈值 `samePersonThreshold`（0.65）时会并存多条；
    /// 识别阶段若不合并，同一姓名会同时占据 top1 与 top2，把 top1−top2 压到
    /// `matchMargin` 以下，使该人**永远无法被识别**。而全局唯一性本就按姓名去重，
    /// 重复条目不可能被同时分配，因此对识别只有挤占 margin 的害处。
    ///
    /// 按 (name, modelId, dim) 分组（与 `mergeSameNameGroups` 同规则），组内用
    /// `mergedVoiceprint` 加权合并；单条目或组内不一致（维度/模型不同、数据损坏）
    /// 时原样保留。输出按 (name, id) 排序，保证结果确定。
    static func collapsingSameName(_ voiceprints: [Voiceprint]) -> [Voiceprint] {
        let groups = Dictionary(grouping: voiceprints) {
            "\($0.name)\u{1}\($0.modelId)\u{1}\($0.dim)"
        }
        var result: [Voiceprint] = []
        result.reserveCapacity(groups.count)
        for group in groups.values {
            let deterministic = group.sorted {
                ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
            }
            if deterministic.count > 1, let merged = mergedVoiceprint(from: deterministic) {
                result.append(merged)
            } else {
                result.append(contentsOf: deterministic)
            }
        }
        return result.sorted {
            $0.name != $1.name ? $0.name < $1.name : $0.id.uuidString < $1.id.uuidString
        }
    }

    /// 扫描声纹库，把每个「同名 + 同模型」多条目组合并为一条（先写合并结果再删余条，
    /// 写失败不丢原数据）。返回实际合并的组数。
    /// 典型产生场景：同人声音条件差异大（感冒/远距麦克风）注册相似度不达查重阈值 0.65，
    /// 按同名新建了多条；合并后的加权质心对全变体取中，识别命中更稳。
    @discardableResult
    static func mergeSameNameGroups(folder: String = VoiceprintFolder.defaultPath) throws -> Int {
        let groups = Dictionary(grouping: loadAll(folder: folder)) {
            "\($0.name)\u{1}\($0.modelId)\u{1}\($0.dim)"
        }
        var mergedCount = 0
        for group in groups.values where group.count > 1 {
            // 确定性输出序，保证同输入合并结果稳定
            let deterministic = group.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            guard let merged = mergedVoiceprint(from: deterministic) else {
                FileSyncService.logWarning("同名声纹合并跳过（向量维度不一致或数据损坏）: \(deterministic.first?.name ?? "?")")
                continue
            }
            try save(merged, folder: folder)
            for vp in deterministic where vp.id != merged.id {
                delete(id: vp.id, folder: folder)
            }
            mergedCount += 1
        }
        return mergedCount
    }
}

/// 声纹注册错误
enum VoiceprintError: LocalizedError {
    case emptyName
    case conflictWithExisting(String, String)
    case insufficientAudio
    /// 未取得声纹（敏感个人信息）的单独同意
    case consentRequired

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "姓名不能为空")
        case .conflictWithExisting(let name, let similarity):
            return String(format: String(localized: "该声纹与已注册的「%@」过于相似（相似度 %@），疑似同一人。如需更正请先在设置中删除对应声纹"), name, similarity)
        case .insufficientAudio:
            return String(localized: "该说话人的有效音频片段不足，无法生成可靠声纹")
        case .consentRequired:
            return String(localized: "尚未同意声纹处理。请先在「设置 → 关于 → 隐私政策」开启「声纹处理单独同意」。")
        }
    }
}

// MARK: - UI 侧声纹库视图模型

/// 声纹库 UI 服务（@Observable，供设置页管理界面使用）
///
/// 文件读写复用 VoiceprintStore 静态方法；识别管线直接读文件，
/// 与本服务无耦合（保存后调用 reload 刷新列表即可）。
@MainActor
@Observable
final class VoiceprintLibrary {
    static let shared = VoiceprintLibrary()

    private(set) var voiceprints: [Voiceprint] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    init() {
        reload()
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                VoiceprintStore.loadAll()
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.voiceprints = loaded
        }
    }

    func delete(_ voiceprint: Voiceprint) {
        VoiceprintStore.delete(id: voiceprint.id)
        reload()
    }

    /// 同名声纹合并（声纹库管理页手动触发）：返回实际合并的组数；写盘失败抛出由 UI 提示
    @discardableResult
    func mergeSameNames() throws -> Int {
        let merged = try VoiceprintStore.mergeSameNameGroups()
        reload()
        return merged
    }

    /// 当前库内可合并的同名组数（同名 + 同模型且条目 ≥ 2），供按钮显隐/禁用
    var mergeableGroupNameCount: Int {
        Dictionary(grouping: voiceprints) { "\($0.name)\u{1}\($0.modelId)\u{1}\($0.dim)" }
            .values
            .filter { $0.count > 1 }
            .count
    }

    func rename(_ voiceprint: Voiceprint, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = voiceprint
        updated.name = trimmed
        updated.updatedAt = Date()
        try? VoiceprintStore.save(updated)
        reload()
    }
}
