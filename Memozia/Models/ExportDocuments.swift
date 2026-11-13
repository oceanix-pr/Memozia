import SwiftUI
import UniformTypeIdentifiers

/// 纯文本文档，用于导出转写内容
struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .utf8PlainText] }
    static var writableContentTypes: [UTType] { [.plainText, .utf8PlainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 已排版好的 PDF 字节，用于右键「导出为 .pdf」。
///
/// 排版在点菜单时于后台线程完成（见 `MarkdownPDFRenderer`），这里只携带结果：
/// `fileWrapper` 在保存面板确认后同步调用，把渲染塞进这一步会让失败
/// 晚于用户选完路径才暴露，也无法区分“用户取消”与“排版异常”。
struct MarkdownPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        // 应用不提供 PDF 导入（`readableContentTypes` 只为满足 FileDocument 协议），
        // 真走到这一步就明确报错，不静默给出一份读不懂的文档
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadUnknown)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 大模型配置迁移文档（JSON）。
///
/// 只承载已序列化好的字节：序列化在点「导出配置…」时完成，
/// 失败要早于用户选完保存路径才暴露（与 PDF 导出同一理由）。
struct LLMConfigExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadUnknown)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Markdown 文档，用于导出总结内容
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText]
    }
    static var writableContentTypes: [UTType] {
        [UTType(filenameExtension: "md") ?? .plainText]
    }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
