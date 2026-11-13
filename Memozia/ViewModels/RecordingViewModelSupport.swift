import Foundation
enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case insufficientDiskSpace(freeBytes: Int64, requiredBytes: Int64)
    /// 条目文件夹创建失败（父目录不可写/磁盘满/同秒重名冲突超上限）
    case folderCreationFailed
    case metadataWriteFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return String(format: String(localized: "不支持的文件格式：.%@"), ext)
        case .folderCreationFailed: return String(localized: "创建导入文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。")
        case .metadataWriteFailed: return String(localized: "导入条目的元数据写入失败")
        case .insufficientDiskSpace(let freeBytes, let requiredBytes):
            // 与 ScreenRecordingQuality.estimatedSizeLabel 同口径：显式传 locale，
            // 让小数分隔符跟随语言（否则德/法/俄等语言里恒显示 "."）
            return String(
                format: String(localized: "磁盘可用空间不足：可用 %.1fGB，导入视频至少需要 %.1fGB（原片副本 + 音轨与余量）"),
                locale: Locale.current,
                Double(freeBytes) / 1_073_741_824,
                Double(requiredBytes) / 1_073_741_824
            )
        }
    }
}

enum TranscriptionInputError: LocalizedError {
    case audioFileMissing
    case audioUnreadable
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .audioFileMissing:
            return String(localized: "音频文件不存在，可能已被移动或删除")
        case .audioUnreadable:
            return String(localized: "音频文件损坏或无有效内容，无法转写。请尝试重新录制或重新导入")
        case .missingAPIKey:
            return String(localized: "云端转写需要 API Key，请先在「设置 → 语音转写」中配置")
        }
    }
}
