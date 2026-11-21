import Foundation
#if os(macOS)
import AppKit
#endif

/// The default mailbox comes from project.yml and can be overridden at build time.
enum MemoziaContact {
    static var email: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MemoziaContactEmail") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !value.contains(where: { $0.isWhitespace || "<>/?#".contains($0) }) else {
            return nil
        }
        return value
    }

    static func feedbackURL(to recipient: String, subject: String, body: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        // RFC 6068 uses CRLF for line breaks in the message body.
        let normalizedBody = body.replacingOccurrences(of: #"\r\n?|\n"#, with: "\r\n", options: .regularExpression)
        guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
              let encodedBody = normalizedBody.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "subject", value: encodedSubject),
            URLQueryItem(name: "body", value: encodedBody)
        ]
        return components.url
    }

    #if os(macOS)
    @MainActor
    static func mailApplications(
        handlersForURL: (URL) -> [URL] = NSWorkspace.shared.urlsForApplications(toOpen:)
    ) -> [URL] {
        let mailHandlers = handlersForURL(URL(string: "mailto:")!)
        // A browser can accept mailto without a configured webmail composer. Offer
        // mail-specific handlers first, preserving Launch Services' order in each group.
        let webHandlers = Set(handlersForURL(URL(string: "https://example.invalid")!))
        return mailHandlers.filter { !webHandlers.contains($0) } + mailHandlers.filter(webHandlers.contains)
    }
    #endif
}
