import Foundation
import Testing
@testable import Memozia

@MainActor
struct EntryLanguageTests {
    @Test func perEntryChoicesPersistIndependentlyAndKeepCorruptData() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = EntryLanguageOptions.file(in: folder)
        #expect(try EntryLanguageOptions.load(from: url) == EntryLanguageOptions())
        _ = try EntryLanguageOptions.update(at: url) { $0.spoken = .zhYue }
        _ = try EntryLanguageOptions.update(at: url) { $0.script = .simplified }
        _ = try EntryLanguageOptions.update(at: url) { $0.output = "de" }
        let stored = try EntryLanguageOptions.load(from: url)
        let config = stored.applying(to: STTConfig(mode: .system))
        #expect(config.language == "zh-Yue")
        #expect(config.effectiveScript == .simplified)
        #expect(stored.output == "de")
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: config.language) == "yue-HK")
        try Data([0xff]).write(to: url)
        #expect(throws: DecodingError.self) { try EntryLanguageOptions.update(at: url) { $0.output = "ar" } }
        #expect(try Data(contentsOf: url) == Data([0xff]))
    }

    @Test func newAndLegacyJobsRestoreTheApprovedLanguage() throws {
        let config = STTConfig(mode: .local, language: "zh", script: .traditional)
        let snapshot = STTConfigSnapshot(config: config)
        let entry = BackgroundTaskEntry(kind: .summary, folderName: "20261001153000",
                                       sttSnapshot: snapshot, outputLanguage: "ar", experience: .standard)
        let encoded = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(BackgroundTaskEntry.self, from: encoded)
        #expect(restored.outputLanguage == "ar")
        #expect(try restored.sttSnapshot?.restore(for: .worker).effectiveScript == .traditional)

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "outputLanguage")
        var stt = try #require(legacy["sttSnapshot"] as? [String: Any])
        stt.removeValue(forKey: "script")
        legacy["sttSnapshot"] = stt
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let oldEntry = try JSONDecoder().decode(BackgroundTaskEntry.self, from: data)
        #expect(oldEntry.outputLanguage == nil)
        #expect(try oldEntry.sttSnapshot?.restore(for: .worker).effectiveScript == .simplified)
    }

    @Test func legacyEntriesSharingTheStorageRootHaveIndependentPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        let first = EntryLanguageOptions.file(in: root, legacyID: firstID)
        let second = EntryLanguageOptions.file(in: root, legacyID: secondID)
        _ = try EntryLanguageOptions.update(at: first) { $0.output = "ar" }
        _ = try EntryLanguageOptions.update(at: second) { $0.output = "de" }
        #expect(try EntryLanguageOptions.load(from: first).output == "ar")
        #expect(try EntryLanguageOptions.load(from: second).output == "de")
        #expect(!FileManager.default.fileExists(atPath: EntryLanguageOptions.file(in: root).path))
        try EntryLanguageOptions.removeLegacyFile(in: root, id: firstID)
        try EntryLanguageOptions.removeLegacyFile(in: root, id: firstID)
        #expect(try EntryLanguageOptions.load(from: first) == EntryLanguageOptions())
        #expect(try EntryLanguageOptions.load(from: second).output == "de")
    }

    @Test func generatedTextHonorsOutputLanguageAndKeepsProtocolFields() throws {
        let selected = try LLMConfigSnapshot(config: .builtInQwen, outputLanguage: "de")
        for kind: PromptTemplateKind in [.meetingSummary, .overviewSummary, .videoOverview, .title, .todoExtraction, .screenshotSummary, .visualNotes] {
            #expect(selected.prompt(kind).contains("BCP 47 语言 de"))
        }
        #expect(selected.prompt(.todoExtraction).contains("JSON 字段名"))
        let automatic = try LLMConfigSnapshot(config: .builtInQwen)
        #expect(automatic.prompt(.meetingSummary).contains("主要语言"))
        #expect(!ContentLanguages.outputInstruction("invalid-user-instruction").contains("invalid-user-instruction"))
    }

    @Test func visualTextSharesOneRedactionMapWithTranscript() {
        let transcript = PIIScrubService.scrub("one@example.org")
        let screen = PIIScrubService.scrub("two@example.org", continuing: transcript.mapping)
        #expect(screen.scrubbed != transcript.scrubbed)
        #expect(PIIScrubService.restore(transcript.scrubbed, mapping: screen.mapping) == "one@example.org")
        #expect(PIIScrubService.restore(screen.scrubbed, mapping: screen.mapping) == "two@example.org")
    }

    @Test func mediaDisclosureFollowsEndpoint() {
        #expect(!LLMConfig.builtInQwen.sendsContentOffDevice)
        #expect(!LLMConfig.lmStudioTemplate().sendsContentOffDevice)
        let remote = LLMConfig(name: "LAN", baseURL: "https://192.168.1.12", modelName: "test", isLocal: true)
        #expect(remote.sendsContentOffDevice)
    }
}
