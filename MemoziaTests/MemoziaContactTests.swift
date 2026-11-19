import Foundation
import Testing
@testable import Memozia

struct MemoziaContactTests {
    @Test func feedbackURLPreservesDraftFields() throws {
        let recipient = "feedback@example.com"
        let subject = "[Memozia 反馈] 录音 & 转写?"
        let body = "第一行\n保留 +、&、=、?、#、%。\r\nreply+mac@example.com"
        let url = try #require(MemoziaContact.feedbackURL(to: recipient, subject: subject, body: body))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "mailto")
        #expect(components.path == recipient)
        #expect(components.fragment == nil)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(components.queryItems == [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: "第一行\r\n保留 +、&、=、?、#、%。\r\nreply+mac@example.com")
        ])
    }
}
