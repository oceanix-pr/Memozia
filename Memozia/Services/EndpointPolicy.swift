import Foundation

/// Transport trust is based on the endpoint, never on the model's billing/local flag.
enum EndpointPolicy {
    enum Trust: Equatable, Sendable { case loopback, privateNetwork, remote }

    /// Never forward API keys or user content to a redirected endpoint.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        static let shared = RedirectGuard()

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func trust(for url: URL) -> Trust {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return .loopback }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }) {
            let bytes = octets.compactMap { Int($0) }
            if bytes[0] == 127 { return .loopback }
            if bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) {
                return .privateNetwork
            }
        }
        // Only literal RFC1918 addresses are eligible for cleartext LAN consent.
        // Host names are not inferred private: DNS may resolve them outside the LAN.
        return .remote
    }

    static func validate(_ raw: String, allowInsecureLAN: Bool) throws {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.fragment == nil, scheme == "https" || scheme == "http" else {
            throw LLMError.invalidURL
        }
        if scheme == "https" { return }
        switch trust(for: url) {
        case .loopback: return
        case .privateNetwork where allowInsecureLAN: return
        default: throw LLMError.insecureURL
        }
    }
}
