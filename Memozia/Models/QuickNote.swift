import Foundation
import SwiftData

/// 快捷笔记数据模型
///
/// 与 AudioRecording 平级，用于"无录音"场景下的待办拆解。
/// 复用 ~/Documents/Memozia/yyyyMMddHHmmss/ 文件夹约定，
/// 通过 meta.json 的 itemType 字段区分类型。
@Model
final class QuickNote {
    var id: UUID
    var title: String
    /// 粘贴的文字内容（加密存储，复用 EncryptionService）
    var textContent: String?
    /// 文件夹内 source.png 的文件名（空表示无图片）
    var sourceImageFileName: String?
    /// 图片原件清理后仍保留图片条目身份；可选以兼容旧数据库迁移。
    var hasImageSource: Bool? = false
    /// OCR 结果或视觉模型提取的文字（加密存储）
    var ocrText: String?
    /// AI 总结（加密存储）
    var summaryText: String?
    /// 总结生成时间
    var summaryGeneratedAt: Date?
    /// 总结处理状态（供队列面板重启后恢复展示）。
    /// **必须为可选**：9.2.0 新增列，旧库轻量迁移后为 NULL，非可选访问器会强转崩溃；
    /// `nil` 视同 `.pending`。说明详见 `AudioRecording.summaryStatus`。
    var summaryStatus: ProcessingStatus? = ProcessingStatus.pending
    /// 待办拆解处理状态（可选，说明见 `summaryStatus`）
    var todoStatus: ProcessingStatus? = ProcessingStatus.pending
    /// 所属文件夹名（yyyyMMddHHmmss），与录音同格式
    var folderName: String
    var createdAt: Date
    var isHidden: Bool

    init(
        title: String,
        textContent: String? = nil,
        sourceImageFileName: String? = nil,
        ocrText: String? = nil,
        folderName: String
    ) {
        self.id = UUID()
        self.title = title
        self.textContent = textContent
        self.sourceImageFileName = sourceImageFileName
        self.hasImageSource = sourceImageFileName?.isEmpty == false
        self.ocrText = ocrText
        self.folderName = folderName
        self.createdAt = Date()
        self.isHidden = false
    }
}

// MARK: - 计算属性

extension QuickNote {

    /// 文件夹 URL（与 AudioRecording 共用 storageDirectory；月份目录优先、旧平铺结构兼容）
    var folderURL: URL {
        AudioRecording.resolveFolderURL(forFolderName: folderName)
    }

    /// 源图片 URL（如有）
    var sourceImageURL: URL? {
        guard let name = sourceImageFileName, !name.isEmpty else { return nil }
        return folderURL.appendingPathComponent(name)
    }

    /// meta.json URL
    var metaFileURL: URL {
        folderURL.appendingPathComponent("meta.json")
    }

    /// 解密后的文字内容
    var decryptedTextContent: String {
        EncryptionService.decryptSafely(textContent)
    }

    /// 解密后的 OCR 文本
    var decryptedOcrText: String {
        EncryptionService.decryptSafely(ocrText)
    }

    /// 解密后的总结文本
    var decryptedSummaryText: String {
        EncryptionService.decryptSafely(summaryText)
    }

    /// 总结文件 URL
    var summaryFileURL: URL {
        folderURL.appendingPathComponent(AudioRecording.summaryFileName)
    }

    /// 用于 LLM 拆解的合并文本（文字 + OCR 结果）
    var combinedTextForExtraction: String {
        var parts: [String] = []
        let text = decryptedTextContent
        if !text.isEmpty { parts.append(text) }
        let ocr = decryptedOcrText
        if !ocr.isEmpty { parts.append(ocr) }
        return parts.joined(separator: "\n\n")
    }

    /// 是否有图片
    var hasImage: Bool {
        sourceImageFileName != nil && !((sourceImageFileName ?? "").isEmpty)
    }

    var isImageNote: Bool {
        hasImageSource == true || hasImage
    }

    /// 保存 meta.json（含 itemType 字段）
    @discardableResult
    func saveMetaToFolder() -> Bool {
        guard !folderName.isEmpty else { return false }
        let meta: [String: Any] = [
            "title": title,
            "isHidden": isHidden,
            "itemType": "quicknote",
            "hasImageSource": isImageNote
        ]
        do {
            id = try EntryIdentityStore.write(meta, id: id, to: folderURL)
            return true
        } catch {
            PersistenceReporting.reportSaveFailure(
                EntryMetadataWriteError(folderName: folderName, reason: error.localizedDescription)
            )
            return false
        }
    }

    /// 保存标题到文件夹
    func saveTitleToFolder(_ newTitle: String) {
        guard !folderName.isEmpty else { return }
        title = newTitle
        saveMetaToFolder()
    }

    /// 从文件夹加载元数据（月份目录优先、旧平铺结构兼容）
    static func loadMetaFromFolder(folderName: String) -> (title: String?, isHidden: Bool, hasImageSource: Bool) {
        guard !folderName.isEmpty else { return (nil, false, false) }
        let metaURL = AudioRecording.resolveFolderURL(forFolderName: folderName)
            .appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path),
              let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, false, false)
        }
        let title = json["title"] as? String
        let isHidden = json["isHidden"] as? Bool ?? false
        return (title, isHidden, json["hasImageSource"] as? Bool ?? false)
    }

    /// 生成 yyyyMMddHHmmss 格式的文件夹名（与 AudioRecording 一致）
    static func folderName(from date: Date) -> String {
        AudioRecording.folderName(from: date)
    }

    /// 创建并返回该笔记专属的文件夹 URL
    static func createFolder(named folderName: String) -> URL {
        AudioRecording.createFolder(named: folderName)
    }
}

// MARK: - 列表项包装（用于侧边栏统一显示两种类型）

/// 侧边栏列表项（录音 或 快捷笔记）
enum ListItem: Identifiable, Hashable {
    case recording(AudioRecording)
    case quickNote(QuickNote)

    var id: String {
        switch self {
        case .recording(let r): return "recording-\(r.id.uuidString)"
        case .quickNote(let n): return "quicknote-\(n.id.uuidString)"
        }
    }

    /// 标题
    var title: String {
        switch self {
        case .recording(let r): return r.fileName
        case .quickNote(let n): return n.title
        }
    }

    /// 创建时间
    var createdAt: Date {
        switch self {
        case .recording(let r): return r.createdAt
        case .quickNote(let n): return n.createdAt
        }
    }

    /// 是否隐藏
    var isHidden: Bool {
        switch self {
        case .recording(let r): return r.isHidden
        case .quickNote(let n): return n.isHidden
        }
    }

    /// 文件夹名
    var folderName: String {
        switch self {
        case .recording(let r): return r.folderName
        case .quickNote(let n): return n.folderName
        }
    }

    /// 文件夹 URL
    var folderURL: URL {
        switch self {
        case .recording(let r): return r.folderURL
        case .quickNote(let n): return n.folderURL
        }
    }

    /// 列表图标名
    var listIconName: String {
        switch self {
        case .recording: return "waveform"
        case .quickNote: return "text.bubble.fill"
        }
    }
}
