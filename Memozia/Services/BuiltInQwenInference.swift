import Foundation
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Detached from SwiftData and the UI. The existing cancellable gate owns the
/// entire load / prefill / decode lifetime, including cancellation cleanup.
actor BuiltInQwenInference {
    static let shared = BuiltInQwenInference()
    private let gate = CancellableGate()
    private var container: MLXLMCommon.ModelContainer?
    private var loadedDirectory: URL?
    private var modelLock: BuiltInModelFileLock?
    private var unloadTask: Task<Void, Never>?

    struct Input: Sendable {
        let system: String
        let text: String
        let images: [Data]

        init(system: String, content: Any) throws {
            self.system = system
            if let text = content as? String {
                self.text = text
                self.images = []
                return
            }
            guard let parts = content as? [[String: Any]] else { throw LLMError.parseError }
            var text: [String] = []
            var images: [Data] = []
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    text.append(part["text"] as? String ?? "")
                case "image_url":
                    guard let value = part["image_url"] as? [String: Any],
                          let url = value["url"] as? String,
                          url.hasPrefix("data:image/"),
                          let comma = url.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
                        throw BuiltInModelError.invalidImage
                    }
                    images.append(data)
                default:
                    throw LLMError.parseError
                }
            }
            guard images.count <= 1 else { throw BuiltInModelError.contextTooLong }
            self.text = text.joined(separator: "\n")
            self.images = images
        }
    }

    struct Output: Sendable {
        let text: String
        let finishReason: String
    }

    func generate(
        input: Input, maxTokens: Int, temperature: Double,
        directory: URL = BuiltInQwenModel.folder,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> Output {
        try await gate.acquire()
        do {
            unloadTask?.cancel()
            unloadTask = nil
            try Task.checkCancellation()
            if container == nil || loadedDirectory != directory {
                unloadModel()
                let lock = try BuiltInModelFileLock(root: directory.deletingLastPathComponent(), shared: true)
                try BuiltInModelDownloader.verifyModel(at: directory)
                Memory.cacheLimit = 64 * 1024 * 1024
                container = try await VLMModelFactory.shared.loadContainer(
                    from: directory, using: BuiltInTokenizerLoader()
                )
                loadedDirectory = directory
                modelLock = lock
            }
            guard let container else { throw BuiltInModelError.notDownloaded }
            let budget = min(maxTokens, BuiltInQwenModel.outputTokens)
            let result = try await container.perform { context in
                try Task.checkCancellation()
                let images = try input.images.map { data -> UserInput.Image in
                    guard let image = CIImage(data: data) else { throw BuiltInModelError.invalidImage }
                    return .ciImage(image)
                }
                let user = UserInput(
                    chat: [.system(input.system), .user(input.text, images: images)],
                    processing: .init(resize: CGSize(width: 896, height: 896)),
                    additionalContext: ["enable_thinking": false]
                )
                let prepared = try await context.processor.prepare(input: user)
                try Task.checkCancellation()
                guard prepared.text.tokens.size + budget <= BuiltInQwenModel.contextTokens else {
                    throw BuiltInModelError.contextTooLong
                }
                let parameters = GenerateParameters(
                    maxTokens: budget, temperature: Float(temperature),
                    topP: 0.8, topK: 20, repetitionPenalty: 1.05
                )
                // Keep the model inside perform until the generation worker has
                // stopped. Returning early would let the next request reuse it.
                let iterator = try TokenIterator(input: prepared, model: context.model, parameters: parameters)
                let (stream, worker) = MLXLMCommon.generateTask(
                    promptTokenCount: prepared.text.tokens.size,
                    modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer,
                    iterator: iterator
                )
                return try await withTaskCancellationHandler {
                    var text = ""
                    var finishReason = "stop"
                    for await event in stream {
                        if Task.isCancelled {
                            worker.cancel()
                            break
                        }
                        switch event {
                        case .chunk(let chunk):
                            text += chunk
                            onToken(chunk)
                        case .info(let info):
                            if info.stopReason == .length { finishReason = "length" }
                        default:
                            break
                        }
                    }
                    await worker.value
                    try Task.checkCancellation()
                    return Output(text: text, finishReason: finishReason)
                } onCancel: {
                    worker.cancel()
                }
            }
            await gate.release()
            scheduleUnload()
            return result
        } catch {
            await gate.release()
            scheduleUnload()
            throw error
        }
    }

    /// Wait for generation to finish, then release mapped weights and keep the
    /// inference gate until deletion completes. Other processes are excluded by
    /// the same filesystem lock used for downloads and loaded model readers.
    func removeModel(
        directory: URL = BuiltInQwenModel.folder,
        legacy: URL? = BuiltInQwenModel.legacyFolder
    ) async throws {
        try await gate.acquire()
        unloadTask?.cancel()
        unloadTask = nil
        unloadModel()
        do {
            try await BuiltInModelStorage.remove(destination: directory, legacy: legacy)
            await gate.release()
        } catch {
            await gate.release()
            throw error
        }
    }

    private func unloadModel() {
        container = nil
        loadedDirectory = nil
        Memory.clearCache()
        modelLock = nil
    }

    private func scheduleUnload() {
        unloadTask = Task {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            guard !Task.isCancelled else { return }
            do { try await gate.acquire() }
            catch { return }
            if !Task.isCancelled {
                unloadModel()
            }
            await gate.release()
        }
    }
}

/// The MLX tokenizer protocol intentionally does not depend on a hub client.
/// This adapter uses the already locked swift-transformers tokenizer and reads
/// only the verified local directory, so inference never fetches extra files.
private struct BuiltInTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BuiltInTokenizer(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct BuiltInTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
