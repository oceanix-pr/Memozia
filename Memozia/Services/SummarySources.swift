import Foundation

/// Transcript context and playback-link cleanup for summaries.
enum SummarySources {
    static func markdown(from segments: [TranscriptMarkdownBuilder.SegmentData]) throws -> String {
        var blocks: [String] = []
        for segment in segments {
            try Task.checkCancellation()
            let text = try EncryptionService.decryptForExternalAccess(segment.encryptedText)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard segment.startTime.isFinite, segment.startTime >= 0 else { throw LLMError.parseError }
            let speaker = segment.speaker.map { " · " + $0 } ?? ""
            blocks.append("\(segment.timeRange)\(speaker)\n\(text)")
        }
        return blocks.joined(separator: "\n\n")
    }

    static func decryptedMarkdown(_ encryptedText: String?) -> String {
        removingSeekLinks(from: EncryptionService.decryptSafely(encryptedText))
    }

    static func removingSeekLinks(from markdown: String) -> String {
        guard markdown.range(of: "memozia://seek/", options: [.caseInsensitive, .literal]) != nil else {
            return markdown
        }

        // Preserve link labels. The stream may end before the closing parenthesis arrives.
        let unlinked = markdown.replacing(
            #/(?i)\[([^\[\]\r\n]*)\]\([ \t]*<?memozia://seek/[^\s)>]*>?(?:[ \t]+["'][^\r\n]*?["'])?[ \t]*(?:\)|\z)/#
        ) { match in
            match.1
        }
        // Format bare URLs and autolinks as plain times.
        return unlinked.replacing(
            #/(?i)<?memozia://seek/([+-]?(?:[0-9]+(?:\.[0-9]+)?(?:e[+-]?[0-9]+)?)?)>?/#
        ) { match in
            guard let seconds = Double(match.1), seconds.isFinite, seconds >= 0 else { return "" }
            return seconds.formattedAsDuration(fractionDigits: 1)
        }
    }
}
