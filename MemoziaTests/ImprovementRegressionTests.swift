import Foundation
import CryptoKit
import Testing
@testable import Memozia

@Suite(.serialized)
struct ImprovementRegressionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Memozia-Improvements-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func endpointTrustRequiresSeparateLANConsent() throws {
        for raw in ["http://10.0.0.2/v1", "http://172.16.0.2/v1", "HTTP://192.168.1.20/v1"] {
            #expect(throws: (any Error).self) { try EndpointPolicy.validate(raw, allowInsecureLAN: false) }
            try EndpointPolicy.validate(raw, allowInsecureLAN: true)
        }
        for raw in ["http://example.com/v1", "http://nas.home.local/v1", "http://172.32.0.1/v1", "http://192.168.1.20.example.com/v1"] {
            #expect(throws: (any Error).self) { try EndpointPolicy.validate(raw, allowInsecureLAN: true) }
        }
        for raw in ["http://localhost/v1", "http://127.0.0.1/v1", "http://[::1]/v1", "https://example.com/v1"] {
            try EndpointPolicy.validate(raw, allowInsecureLAN: false)
        }
        for raw in ["ftp://localhost/v1", "https://user:password@example.com/v1", "https://example.com/v1#fragment"] {
            #expect(throws: (any Error).self) { try EndpointPolicy.validate(raw, allowInsecureLAN: true) }
        }
    }

    @MainActor @Test func textScrubbingDependsOnEndpointNotModelFlag() throws {
        let config = LLMConfig(name: "Test", baseURL: "http://192.168.1.20:8000", modelName: "m", isLocal: true)
        config.allowInsecureLAN = true
        #expect(try LLMConfigSnapshot(config: config).shouldScrubText)
        config.baseURL = "http://127.0.0.1:8000"
        #expect(try !LLMConfigSnapshot(config: config).shouldScrubText)
        config.scrubLoopbackText = true
        #expect(try LLMConfigSnapshot(config: config).shouldScrubText)
    }

    @MainActor @Test func piiScanningRejectsNonLoopbackBeforeSendingContent() async throws {
        for endpoint in ["http://192.168.1.20:8000", "https://example.com/v1"] {
            let config = LLMConfig(name: "Test", baseURL: endpoint, modelName: "m", isLocal: true)
            config.allowInsecureLAN = true
            let snapshot = try LLMConfigSnapshot(config: config)
            do {
                _ = try await PIIScanService.extract(from: "test content", config: snapshot)
                Issue.record("PII scanning must reject non-loopback endpoints")
            } catch LLMError.invalidURL { }
        }
    }

    @Test func chunkingPreservesEveryCharacterIncludingUnicodeAndTail() {
        let input = String(repeating: "👨‍👩‍👧‍👦会议纪要 e\u{301}\n", count: 100) + "最后的决定"
        let parts = SummaryChunking.chunks(input, limit: 37)
        #expect(parts.joined() == input)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.count <= 37 })
        #expect(parts.last?.hasSuffix("最后的决定") == true)
        #expect(SummaryChunking.chunks("").isEmpty)
    }

    private actor SeenParts {
        var parts: [String] = []
        func append(_ text: String) { parts.append(text) }
        func joined() -> String { parts.joined() }
    }

    @Test func reductionVisitsAllInputAndRefusesNonShrinkingOutput() async throws {
        let input = String(repeating: "原始输入", count: 100) + "尾段"
        let seen = SeenParts()
        let result = try await SummaryChunking.reduce(input, limit: 96) { part in
            await seen.append(part)
            return "摘要"
        }
        let visited = await seen.joined()
        #expect(visited == input)
        #expect(result.count <= 96)
        do {
            _ = try await SummaryChunking.reduce(input, limit: 96) { $0 }
            Issue.record("Non-shrinking model output must fail instead of dropping the tail")
        } catch LLMError.summaryReductionFailed { }
    }

    @Test func reductionHonorsCancellation() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await SummaryChunking.reduce(String(repeating: "x", count: 400), limit: 96) { _ in
                Issue.record("Cancelled work must not invoke the model")
                return "short"
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation error: \(error)") }
    }

    @Test func searchProducesTimeHitWithoutPersistingAnIndex() {
        let hit = FullTextSearch.match("cafe", in: "前文 Café 的会议结论\n后文", seconds: 42)
        #expect(hit?.seconds == 42)
        #expect(hit?.snippet.contains("Café") == true)
        #expect(hit?.snippet.contains("\n") == false)
        #expect(FullTextSearch.match("不存在", in: "会议", seconds: nil) == nil)
    }

    @Test func summarySourcesUseActualTimesAndStrictDecryption() throws {
        let encrypted = try EncryptionService.encrypt("这是原始发言")
        let segment = TranscriptMarkdownBuilder.SegmentData(timeRange: "00:12", startTime: 12.5, speaker: "发言人", encryptedText: encrypted)
        let markdown = try SummarySources.markdown(from: [segment])
        #expect(markdown == "[00:12](Memozia://seek/12.5) · 发言人\n这是原始发言")
        #expect(try SummarySources.markdown(from: []).isEmpty)
        let invalid = TranscriptMarkdownBuilder.SegmentData(timeRange: "?", startTime: .nan, speaker: nil, encryptedText: encrypted)
        #expect(throws: (any Error).self) { try SummarySources.markdown(from: [invalid]) }
        let corrupted = TranscriptMarkdownBuilder.SegmentData(timeRange: "00:00", startTime: 0, speaker: nil, encryptedText: Data(repeating: 0, count: 40).base64EncodedString())
        #expect(throws: (any Error).self) { try SummarySources.markdown(from: [corrupted]) }
    }

    @Test func evidenceMustExistInTheSameSourceBlock() throws {
        let content = "[00:10](Memozia://seek/10) 负责人小王提交报告\n\n[00:20](Memozia://seek/20) 会议结束"
        var candidate = TodoItem(title: "提交报告", evidenceQuote: "小王提交报告", sourceSeekURL: "Memozia://seek/10", owner: "小王", isUserConfirmed: true)
        let valid = TodoExtractionService.validateEvidence(candidate, in: content)
        #expect(valid.evidenceQuote == candidate.evidenceQuote)
        #expect(valid.sourceSeekURL == candidate.sourceSeekURL)
        #expect(!valid.isUserConfirmed)
        candidate.sourceSeekURL = "Memozia://seek/20"
        #expect(TodoExtractionService.validateEvidence(candidate, in: content).sourceSeekURL == nil)
        candidate.evidenceQuote = "原文中没有的说法"
        candidate.owner = "不存在的人"
        let invalid = TodoExtractionService.validateEvidence(candidate, in: content)
        #expect(invalid.evidenceQuote == nil && invalid.sourceSeekURL == nil && invalid.owner == nil)
        let legacy = try JSONDecoder().decode(TodoItem.self, from: Data(#"{"id":"old","title":"旧待办","priority":"none","status":"pending"}"#.utf8))
        #expect(!legacy.isUserConfirmed && legacy.evidenceQuote == nil)
    }

    @Test func restoredTodosDoNotClaimExternalSynchronization() throws {
        let document = TodoDocument(source: "test", model: "test", generatedAt: Date(), items: [
            TodoItem(title: "任务", reminderIdentifier: "old-device", status: .exported, targetListID: "old-list", evidenceQuote: "任务", isUserConfirmed: true)
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reset = try PortableBackup.removingExternalBindings(from: String(decoding: encoder.encode(document), as: UTF8.self))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TodoDocument.self, from: Data(reset.utf8))
        #expect(restored.items[0].status == .pending)
        #expect(restored.items[0].reminderIdentifier == nil && restored.items[0].targetListID == nil)
        #expect(restored.items[0].isUserConfirmed)
    }

    @Test func backupRejectsUnsafePaths() {
        for path in ["20260920090000/source.txt", "2026-09/20260920090000-2/summary.md", "202609200900/source.txt"] {
            #expect(PortableBackup.isSafeRelativePath(path))
        }
        for path in ["/20260920090000/source.txt", "../source.txt", "20260920090000/../source.txt", "20260920090000/a\\b.txt", "20260920090000/.hidden", "models/config.json"] {
            #expect(!PortableBackup.isSafeRelativePath(path))
        }
    }

    @Test func passwordKeyDerivationIsSaltedAndRejectsShortPasswords() throws {
        let salt = Data(repeating: 7, count: 16)
        let key = try PortableBackup.deriveKey(password: "long test password", salt: salt)
        let same = try PortableBackup.deriveKey(password: "long test password", salt: salt)
        #expect(key.withUnsafeBytes { Data($0) } == same.withUnsafeBytes { Data($0) })
        let sealed = try AES.GCM.seal(Data("test".utf8), using: key)
        let wrong = try PortableBackup.deriveKey(password: "different password", salt: salt)
        #expect(throws: (any Error).self) { try AES.GCM.open(sealed, using: wrong) }
        #expect(throws: (any Error).self) { try PortableBackup.deriveKey(password: "short", salt: salt) }
    }

    @Test func summaryHistoryRetainsEncryptedRevisions() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try SummaryHistory.preserve(EncryptionService.encrypt("人工修订"), in: folder)
        try SummaryHistory.preserve(EncryptionService.encrypt("上一份结果"), in: folder)
        let revisions = try SummaryHistory.load(in: folder)
        #expect(Set(revisions.map(\.text)) == ["人工修订", "上一份结果"])
        let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(SummaryHistory.directoryName), includingPropertiesForKeys: nil)
        for file in files {
            let raw = try String(contentsOf: file, encoding: .utf8)
            #expect(!raw.contains("人工修订") && !raw.contains("上一份结果"))
        }
    }

    @Test func portableBackupRoundTripIsIsolatedAndAuthenticated() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("library")
        let folderName = "20260920090000"
        let folder = root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.txt")
        try EncryptionService.encryptAndWrite("迁移验证内容", to: source)
        let original = try Data(contentsOf: source)
        let media = Data(repeating: 0xAB, count: PortableBackup.chunkSize + 73)
        try media.write(to: folder.appendingPathComponent("audio.m4a"))
        let password = "portable test password"
        let archive = try await PortableBackup.export(root: root, to: base, password: password)
        #expect(archive.files == 2)
        let recovered = try await PortableBackup.restore(archive: archive.url, to: base, password: password, activeRoot: root)
        #expect(recovered.url != root)
        let restoredFolder = recovered.url.appendingPathComponent(folderName)
        #expect(EncryptionService.decryptFileOrPlaintext(at: restoredFolder.appendingPathComponent("source.txt")) == "迁移验证内容")
        #expect(try Data(contentsOf: restoredFolder.appendingPathComponent("audio.m4a")) == media)
        #expect(try Data(contentsOf: source) == original)
        do {
            _ = try await PortableBackup.restore(archive: archive.url, to: base, password: "wrong test password", activeRoot: root)
            Issue.record("Wrong passwords must fail authentication")
        } catch { }
        let chunk = try #require(FileManager.default.contentsOfDirectory(at: archive.url, includingPropertiesForKeys: nil).first { $0.pathExtension == "bin" && $0.lastPathComponent != "manifest.bin" })
        try Data("corrupt".utf8).write(to: chunk)
        do {
            _ = try await PortableBackup.restore(archive: archive.url, to: base, password: password, activeRoot: root)
            Issue.record("Corrupt chunks must fail authentication")
        } catch { }
        #expect(try Data(contentsOf: source) == original)
    }
}
