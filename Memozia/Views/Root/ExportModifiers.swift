import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 导出相关修饰符（拆分以避免类型检查超时）
struct ExportModifiers: ViewModifier {
    @Binding var showTranscriptExporter: Bool
    let exportTranscriptDoc: MarkdownDocument?
    @Binding var showTranscriptPDFExporter: Bool
    let exportTranscriptPDFDoc: MarkdownPDFDocument?
    @Binding var showSummaryExporter: Bool
    let exportSummaryDoc: MarkdownDocument?
    @Binding var showSummaryPDFExporter: Bool
    let exportSummaryPDFDoc: MarkdownPDFDocument?
    /// 导出默认文件名基名：录音/录屏用文件名，快捷笔记（图片/文字）用标题
    let exportBaseName: String

    /// 基名为空时退回「录音」，与旧行为一致
    private var baseName: String {
        exportBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "录音")
            : exportBaseName
    }

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $showTranscriptExporter,
                document: exportTranscriptDoc,
                contentType: UTType(filenameExtension: "md") ?? .plainText,
                defaultFilename: "\(baseName)_\(String(localized: "转写"))"
            ) { _ in }
            .fileExporter(
                isPresented: $showSummaryExporter,
                document: exportSummaryDoc,
                contentType: UTType(filenameExtension: "md") ?? .plainText,
                defaultFilename: "\(baseName)_\(String(localized: "总结"))"
            ) { _ in }
            .fileExporter(
                isPresented: $showTranscriptPDFExporter,
                document: exportTranscriptPDFDoc,
                contentType: .pdf,
                defaultFilename: "\(baseName)_\(String(localized: "转写"))"
            ) { _ in }
            .fileExporter(
                isPresented: $showSummaryPDFExporter,
                document: exportSummaryPDFDoc,
                contentType: .pdf,
                defaultFilename: "\(baseName)_\(String(localized: "总结"))"
            ) { _ in }
    }
}
