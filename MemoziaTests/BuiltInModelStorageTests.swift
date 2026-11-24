import Foundation
import Testing
@testable import Memozia

struct BuiltInModelStorageTests {
    private struct Fixture {
        let root: URL
        var destination: URL { root.appendingPathComponent("LLM/Qwen3.5-2B/" + BuiltInQwenModel.revision) }
        var legacy: URL { root.appendingPathComponent("legacy/Qwen3.5-2B/" + BuiltInQwenModel.revision) }
        var stage: URL {
            destination.deletingLastPathComponent().appendingPathComponent(".\(BuiltInQwenModel.revision).download")
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ text: String, to file: URL) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("内置模型默认保存到文稿目录的 Memozia/LLM 下")
    func defaultModelDirectory() {
        let expected = AudioRecording.defaultStorageDirectory
            .appendingPathComponent("LLM/Qwen3.5-2B/" + BuiltInQwenModel.revision)
        #expect(BuiltInQwenModel.folder.standardizedFileURL.path == expected.standardizedFileURL.path)
        #expect(BuiltInQwenModel.legacyFolder == nil) // Unit tests cannot touch the user's old model.
    }

    @Test("迁移旧模型及续传信息，保留邻近数据与锁文件")
    func migratesLegacyPayloads() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let legacyStage = f.legacy.deletingLastPathComponent()
            .appendingPathComponent(".\(BuiltInQwenModel.revision).download")
        try f.write("installed weights", to: f.legacy.appendingPathComponent("model.safetensors"))
        try f.write("resume record", to: legacyStage.appendingPathComponent("model.safetensors.huggingface.resume"))
        let unrelated = f.legacy.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try f.write("preserved", to: unrelated)

        try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)

        #expect(try String(contentsOf: f.destination.appendingPathComponent("model.safetensors"), encoding: .utf8) == "installed weights")
        #expect(try String(contentsOf: f.stage.appendingPathComponent("model.safetensors.huggingface.resume"), encoding: .utf8) == "resume record")
        #expect(!FileManager.default.fileExists(atPath: f.legacy.path))
        #expect(!FileManager.default.fileExists(atPath: legacyStage.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserved")
        #expect(FileManager.default.fileExists(atPath: f.legacy.deletingLastPathComponent().appendingPathComponent(".download.lock").path))
    }

    @Test("迁移不覆盖目标，重试能清理未完成的迁移副本")
    func migrationPreservesExistingDestinationAndRecovers() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.write("new", to: f.destination.appendingPathComponent("model.safetensors"))
        try f.write("old", to: f.legacy.appendingPathComponent("model.safetensors"))
        try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)
        #expect(try String(contentsOf: f.destination.appendingPathComponent("model.safetensors"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: f.legacy.appendingPathComponent("model.safetensors"), encoding: .utf8) == "old")

        try FileManager.default.removeItem(at: f.destination)
        let interrupted = f.destination.deletingLastPathComponent().appendingPathComponent(".migrate-" + BuiltInQwenModel.revision)
        try f.write("incomplete", to: interrupted.appendingPathComponent("model.safetensors"))
        try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)
        #expect(try String(contentsOf: f.destination.appendingPathComponent("model.safetensors"), encoding: .utf8) == "old")
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
    }

    @Test("迁移失败保留原件，修复目标后可以重试")
    func migrationFailurePreservesOriginal() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.write("old", to: f.legacy.appendingPathComponent("model.safetensors"))
        let root = f.destination.deletingLastPathComponent()
        try f.write("blocks directory creation", to: URL(fileURLWithPath: root.path))

        await #expect(throws: (any Error).self) {
            try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)
        }
        #expect(try String(contentsOf: f.legacy.appendingPathComponent("model.safetensors"), encoding: .utf8) == "old")
        try FileManager.default.removeItem(at: root)
        try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)
        #expect(try String(contentsOf: f.destination.appendingPathComponent("model.safetensors"), encoding: .utf8) == "old")
    }

    @Test("删除清理新旧模型及下载缓存，保留锁和其他文件")
    func removesOnlyModelPayloads() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.write("weights", to: f.destination.appendingPathComponent("model.safetensors"))
        try f.write("old weights", to: f.legacy.appendingPathComponent("model.safetensors"))
        try f.write("resume", to: f.stage.appendingPathComponent("model.safetensors.huggingface.resume"))
        let interrupted = f.destination.deletingLastPathComponent().appendingPathComponent(".migrate-" + BuiltInQwenModel.revision)
        try f.write("partial copy", to: interrupted.appendingPathComponent("model.safetensors"))
        let otherModel = f.root.appendingPathComponent("LLM/OtherModel/keep")
        try f.write("preserved", to: otherModel)
        #expect(BuiltInModelStorage.hasFiles(destination: f.destination, legacy: f.legacy))

        try await BuiltInModelStorage.remove(destination: f.destination, legacy: f.legacy)

        #expect(!BuiltInModelStorage.hasFiles(destination: f.destination, legacy: f.legacy))
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
        #expect(!FileManager.default.fileExists(atPath: f.stage.path))
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        #expect(try String(contentsOf: otherModel, encoding: .utf8) == "preserved")
        #expect(FileManager.default.fileExists(atPath: f.destination.deletingLastPathComponent().appendingPathComponent(".download.lock").path))
        try await BuiltInModelStorage.remove(destination: f.destination, legacy: f.legacy) // Idempotent retry.
    }

    @Test("模型读锁阻止删除，锁释放后可清理")
    func modelInUseCannotBeRemoved() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let weights = f.destination.appendingPathComponent("model.safetensors")
        try f.write("weights", to: weights)
        do {
            let reader = try BuiltInModelFileLock(root: f.destination.deletingLastPathComponent(), shared: true)
            defer { withExtendedLifetime(reader) {} }
            await #expect(throws: BuiltInModelError.self) {
                try await BuiltInModelStorage.remove(destination: f.destination, legacy: f.legacy)
            }
            #expect(try String(contentsOf: weights, encoding: .utf8) == "weights")
        }
        try await BuiltInModelStorage.remove(destination: f.destination, legacy: f.legacy)
        #expect(!FileManager.default.fileExists(atPath: weights.path))
    }

    @Test("旧目录下载锁被占用时不迁移文件")
    func legacyDownloadBlocksMigration() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.write("weights", to: f.legacy.appendingPathComponent("model.safetensors"))
        let download = try BuiltInModelFileLock(root: f.legacy.deletingLastPathComponent())
        defer { withExtendedLifetime(download) {} }
        await #expect(throws: BuiltInModelError.self) {
            try await BuiltInModelStorage.prepare(destination: f.destination, legacy: f.legacy)
        }
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
        #expect(try String(contentsOf: f.legacy.appendingPathComponent("model.safetensors"), encoding: .utf8) == "weights")
    }
}
