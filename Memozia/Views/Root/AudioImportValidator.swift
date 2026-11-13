import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 媒体导入校验（RootView 与新建快捷笔记面板共用）
enum AudioImportValidator {
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav"]

    /// 可导入的视频容器：导入时由 RecordingViewModel.importAudio 抽出音轨 m4a 入库，
    /// 原始视频以 `{base}_video.{ext}` 同文件夹留存（转写/总结链路看到的仍是普通音频）
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static var allSupportedExtensions: Set<String> {
        supportedExtensions.union(videoExtensions)
    }

    /// fileImporter 使用的可选类型
    static var allowedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
            UTType(filenameExtension: "wav") ?? .audio,
            UTType(filenameExtension: "mp4") ?? .mpeg4Movie,
            UTType(filenameExtension: "mov") ?? .quickTimeMovie,
            UTType(filenameExtension: "m4v") ?? .mpeg4Movie
        ]
    }

    /// 校验 URL 是否为真实音频/视频文件（扩展名 + UTType 双重校验）
    static func isValidMediaFile(_ url: URL) -> Bool {
        // 扩展名校验
        guard allSupportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        // UTType 内容类型校验（macOS）
        #if os(macOS)
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            // 视频容器报 .mpeg4Movie/.quickTimeMovie（均从 .movie 派生），不能只放 .audio 通过
            return contentType.conforms(to: .audio) || contentType.conforms(to: .movie)
        }
        // 无法获取 contentType 时回退到扩展名校验（已通过）
        #endif
        return true
    }
}
