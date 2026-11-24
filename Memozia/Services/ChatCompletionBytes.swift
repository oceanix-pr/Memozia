import Foundation

/// The network and native model paths share the existing response parsers.
/// Iteration stays in the caller's task, preserving cancellation and backpressure
/// for URLSession responses.
struct ChatCompletionBytes: AsyncSequence {
    typealias Element = UInt8
    let network: URLSession.AsyncBytes?
    let local: AsyncThrowingStream<UInt8, any Error>?

    init(network: URLSession.AsyncBytes) { self.network = network; self.local = nil }
    init(local: AsyncThrowingStream<UInt8, any Error>) { self.network = nil; self.local = local }

    struct AsyncIterator: AsyncIteratorProtocol {
        var network: URLSession.AsyncBytes.AsyncIterator?
        var local: AsyncThrowingStream<UInt8, any Error>.AsyncIterator?
        mutating func next() async throws -> UInt8? {
            try Task.checkCancellation()
            if network != nil { return try await network!.next() }
            return try await local?.next()
        }
    }
    func makeAsyncIterator() -> AsyncIterator {
        .init(network: network?.makeAsyncIterator(), local: local?.makeAsyncIterator())
    }

}
