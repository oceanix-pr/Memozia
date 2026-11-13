import Foundation

/// No contact address is embedded in the public source snapshot. A release build may
/// supply MEMOZIA_CONTACT_EMAIL after the mailbox has been verified.
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
}
