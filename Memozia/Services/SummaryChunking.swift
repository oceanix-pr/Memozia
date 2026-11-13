import Foundation

/// Bounded, sequential map/reduce. No prefix truncation and no plaintext checkpoints.
enum SummaryChunking {
    // Conservative character budget, not a claim of exact tokenization for every model.
    static let inputBudget = 24_000

    static func chunks(_ text: String, limit: Int = inputBudget) -> [String] {
        precondition(limit > 0)
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex {
                let half = text.index(start, offsetBy: limit / 2)
                if let newline = text[half..<end].lastIndex(of: "\n") {
                    end = text.index(after: newline)
                }
            }
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    static func reduce(
        _ text: String,
        limit: Int = inputBudget,
        summarize: @Sendable (String) async throws -> String
    ) async throws -> String {
        var current = text
        for _ in 0..<8 {
            try Task.checkCancellation()
            if current.count <= limit { return current }
            let parts = chunks(current, limit: limit)
            var summaries: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let summary = try await summarize(part)
                guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LLMError.parseError
                }
                summaries.append("[\(index + 1)/\(parts.count)]\n\(summary)")
            }
            let reduced = summaries.joined(separator: "\n\n")
            // Fail visibly rather than looping forever or dropping late decisions.
            guard reduced.count < current.count else { throw LLMError.summaryReductionFailed }
            current = reduced
        }
        if current.count <= limit { return current }
        throw LLMError.summaryReductionFailed
    }
}
