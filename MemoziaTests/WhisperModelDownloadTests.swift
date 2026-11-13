import Testing
import Foundation
@testable import Memozia

/// Whisper 模型下载相关纯逻辑回归
///
/// 重点锁住两处容易静默退化的地方：
/// 1. 档位名必须是 `argmaxinc/whisperkit-coreml` 的精确目录名——WhisperKit 用
///    glob `*<variant>/*` 搜索，档位名若是另一个档位目录名的后缀（如 "whisper-base"
///    之于 "openai_whisper-base"）会同时命中多个目录并抛 "Multiple models found"；
/// 2. 「已就绪」判定必须是三个 .mlmodelc 齐全——只看 AudioEncoder 会把
///    下载中断留下的半成品当成可用模型。
struct WhisperModelDownloadTests {

    private let requiredArtifacts = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

    // MARK: - 档位表

    @Test func catalogUsesExactRepositoryFolderNames() {
        let variants = WhisperModelOption.catalog.map(\.variant)
        #expect(variants.count == 6)
        #expect(Set(variants).count == variants.count, "档位名不得重复")
        for variant in variants {
            #expect(variant.hasPrefix("openai_whisper-"), "必须是仓库真实顶层目录名：\(variant)")
        }
    }

    @Test func noVariantIsSuffixOfAnother() {
        for outer in WhisperModelOption.catalog {
            for inner in WhisperModelOption.catalog where inner.variant != outer.variant {
                let suffix = inner.variant.lowercased().hasSuffix(outer.variant.lowercased())
                #expect(!suffix, "\(outer.variant) 是 \(inner.variant) 的后缀，glob 搜索会命中多个目录")
            }
        }
    }

    @Test func defaultVariantIsDownloadable() {
        #expect(WhisperModelOption.option(for: WhisperModelOption.defaultVariant) != nil)
        #expect(WhisperModelOption.option(for: "openai_whisper-small")?.displayName == "small")
        #expect(WhisperModelOption.option(for: "不存在的档位") == nil)
    }

    @Test func optionLabelPartsAreNonEmpty() {
        for option in WhisperModelOption.catalog {
            #expect(!option.displayName.isEmpty)
            #expect(!option.sizeText.isEmpty)
            #expect(option.approxSizeBytes > 0)
        }
    }

    // MARK: - 下载源

    @Test func sourceEndpointsAreDistinct() {
        #expect(WhisperModelSource.allCases.count == 2)
        #expect(WhisperModelSource.defaultValue == .hfMirror)
        #expect(WhisperModelSource.hfMirror.endpoint == "https://hf-mirror.com")
        #expect(WhisperModelSource.huggingFace.endpoint == "https://huggingface.co")
        for source in WhisperModelSource.allCases {
            #expect(!source.displayName.isEmpty)
        }
    }

    @Test func applyingSourceWritesHubEndpoint() {
        let original = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
        defer {
            if let original {
                setenv("HF_ENDPOINT", original, 1)
            } else {
                unsetenv("HF_ENDPOINT")
            }
        }
        for source in WhisperModelSource.allCases {
            source.applyAsHubEnvironment()
            #expect(ProcessInfo.processInfo.environment["HF_ENDPOINT"] == source.endpoint)
        }
    }

    @Test func unknownStoredSourceFallsBackToDefault() {
        let original = UserDefaults.standard.string(forKey: WhisperModelSourceStore.defaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: WhisperModelSourceStore.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: WhisperModelSourceStore.defaultsKey)
            }
        }
        UserDefaults.standard.set("不存在的源", forKey: WhisperModelSourceStore.defaultsKey)
        #expect(WhisperModelSourceStore.current == WhisperModelSource.defaultValue)

        UserDefaults.standard.set(WhisperModelSource.huggingFace.rawValue, forKey: WhisperModelSourceStore.defaultsKey)
        #expect(WhisperModelSourceStore.current == .huggingFace)
    }

    // MARK: - 就绪判定

    @Test func folderURLExpandsTildeAndAppendsVariant() throws {
        let option = try #require(WhisperModelOption.option(for: "openai_whisper-base"))
        let url = WhisperModelDownloader.modelFolderURL(option: option, modelRootPath: "~/Documents/Memozia/WhisperModel")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(!url.path.hasPrefix("~"))
        #expect(url.path == "\(home)/Documents/Memozia/WhisperModel/openai_whisper-base")
    }

    @Test func modelIsNotPresentInEmptyFolder() throws {
        let option = try #require(WhisperModelOption.option(for: "openai_whisper-tiny"))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(!WhisperModelDownloader.isModelPresent(option: option, modelRootPath: root.path))
        #expect(!WhisperModelDownloader.isModelPresent(option: option, modelRootPath: "/不存在的路径"))
    }

    @Test func modelRequiresAllThreeArtifacts() throws {
        let option = try #require(WhisperModelOption.option(for: "openai_whisper-base"))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = WhisperModelDownloader.modelFolderURL(option: option, modelRootPath: root.path)
        for artifact in requiredArtifacts.dropLast() {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent("\(artifact).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        // 缺 TextDecoder：半成品不得判定为已就绪
        #expect(!WhisperModelDownloader.isModelPresent(option: option, modelRootPath: root.path))

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("TextDecoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        #expect(WhisperModelDownloader.isModelPresent(option: option, modelRootPath: root.path))
    }

    @Test func presenceIsScopedToRequestedVariant() throws {
        let tiny = try #require(WhisperModelOption.option(for: "openai_whisper-tiny"))
        let base = try #require(WhisperModelOption.option(for: "openai_whisper-base"))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tinyFolder = WhisperModelDownloader.modelFolderURL(option: tiny, modelRootPath: root.path)
        for artifact in requiredArtifacts {
            try FileManager.default.createDirectory(
                at: tinyFolder.appendingPathComponent("\(artifact).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        #expect(WhisperModelDownloader.isModelPresent(option: tiny, modelRootPath: root.path))
        #expect(!WhisperModelDownloader.isModelPresent(option: base, modelRootPath: root.path))
    }

    // MARK: - 辅助

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-model-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
