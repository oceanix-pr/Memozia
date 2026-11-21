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

    #if os(macOS)
    @Test @MainActor func mailAppChoicesPreferMailClientsAndKeepWebmailAvailable() {
        let browser = URL(fileURLWithPath: "/Applications/Browser.app")
        let mail = URL(fileURLWithPath: "/Applications/Mail.app")
        let otherMail = URL(fileURLWithPath: "/Applications/OtherMail.app")
        let webOnly = URL(fileURLWithPath: "/Applications/WebOnly.app")

        func choices(_ mailHandlers: [URL]) -> [URL] {
            MemoziaContact.mailApplications { url in
                url.scheme == "mailto" ? mailHandlers : [webOnly, browser]
            }
        }

        #expect(choices([browser, otherMail, mail]) == [otherMail, mail, browser])
        #expect(choices([mail, otherMail]) == [mail, otherMail])
        #expect(choices([browser]) == [browser])
        #expect(choices([]).isEmpty)
    }
    #endif
}
