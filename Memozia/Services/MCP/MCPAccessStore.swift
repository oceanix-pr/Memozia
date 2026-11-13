import Foundation
import Observation
import CryptoKit
import KeychainAccess
import os.log

struct MCPClientGrant: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let notBefore: Date?
    let redact: Bool
    /// nil 表示日期范围内所有可见条目；为后续按条目授权保留，读路径始终执行此限制。
    var entryIDs: Set<UUID>? = nil

    func permits(id: UUID, createdAt: Date, hidden: Bool) -> Bool {
        !hidden && (notBefore.map { createdAt >= $0 } ?? true)
            && (entryIDs?.contains(id) ?? true)
    }
}

@MainActor
protocol MCPTokenVault {
    func read(_ id: UUID) throws -> String?
    func write(_ token: String, id: UUID) throws
    func remove(_ id: UUID) throws
}

@MainActor
private struct MCPKeychainVault: MCPTokenVault {
    private let keychain = Keychain(service: "app.memozia.mcp").accessibility(.afterFirstUnlock)
    func read(_ id: UUID) throws -> String? { try keychain.get(id.uuidString) }
    func write(_ token: String, id: UUID) throws { try keychain.set(token, key: id.uuidString) }
    func remove(_ id: UUID) throws { try keychain.remove(id.uuidString) }
}

/// UserDefaults 仅存授权范围；随机访问令牌只存 Keychain。
@MainActor
@Observable
final class MCPAccessStore {
    static let shared = MCPAccessStore()
    private(set) var enabled: Bool
    private(set) var grants: [MCPClientGrant]
    private(set) var port: Int
    private(set) var lastAccess: [UUID: Date] = [:]
    private let defaults: UserDefaults
    private let vault: any MCPTokenVault
    private let logger = Logger(subsystem: "app.memozia", category: "MCPAccess")
    private static let grantsKey = "Memozia_mcp_clients"

    init(defaults: UserDefaults = .standard, vault: (any MCPTokenVault)? = nil) {
        self.defaults = defaults
        self.vault = vault ?? MCPKeychainVault()
        enabled = defaults.bool(forKey: "Memozia_mcp_enabled")
        let savedPort = defaults.integer(forKey: "Memozia_mcp_port")
        port = (1024...65535).contains(savedPort) ? savedPort : 42817
        // 损坏的授权清单拒绝全部访问，绝不重建成宽权限授权。
        grants = []
        if let data = defaults.data(forKey: Self.grantsKey) {
            do { grants = try JSONDecoder().decode([MCPClientGrant].self, from: data) }
            catch { logger.error("MCP 授权清单读取失败，已拒绝全部客户端访问") }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "Memozia_mcp_enabled")
    }

    func setPort(_ value: Int) throws {
        guard !enabled, (1024...65535).contains(value) else { throw MCPQueryError.invalidArguments }
        port = value
        defaults.set(value, forKey: "Memozia_mcp_port")
    }

    func addClient(name: String, notBefore: Date?, redact: Bool) throws -> MCPClientGrant {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, grants.count < 16 else { throw MCPQueryError.invalidArguments }
        let grant = MCPClientGrant(id: UUID(), name: name, createdAt: Date(), notBefore: notBefore, redact: redact)
        let secret = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let token = "\(grant.id.uuidString.lowercased()).\(Data(secret).base64EncodedString())"
        try vault.write(token, id: grant.id)
        let updated = grants + [grant]
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: Self.grantsKey)
        grants = updated
        return grant
    }

    func revoke(_ id: UUID) throws {
        // 先撤销授权，再删凭据；即便 Keychain 删除失败，旧令牌也已经失效。
        let updated = grants.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.grantsKey)
        grants = updated
        lastAccess.removeValue(forKey: id)
        try vault.remove(id)
    }

    func authenticate(_ bearer: String?) throws -> MCPClientGrant {
        guard enabled, let bearer, bearer.hasPrefix("Bearer "), bearer.utf8.count < 256 else {
            throw MCPQueryError.unauthorized
        }
        let token = String(bearer.dropFirst(7))
        guard let idText = token.split(separator: ".", maxSplits: 1).first,
              let id = UUID(uuidString: String(idText)), let grant = grants.first(where: { $0.id == id }) else { throw MCPQueryError.unauthorized }
        let stored: String?
        do { stored = try vault.read(id) }
        catch {
            logger.error("MCP 客户端凭据读取失败，请检查钥匙串访问权限")
            throw MCPQueryError.credentialsUnavailable
        }
        guard let expected = stored else { throw MCPQueryError.unauthorized }
        let a = Array(SHA256.hash(data: Data(token.utf8)))
        let b = Array(SHA256.hash(data: Data(expected.utf8)))
        let difference = zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { throw MCPQueryError.unauthorized }
        return grant
    }

    func isCurrent(_ grant: MCPClientGrant) -> Bool {
        enabled && grants.contains(grant)
    }

    func recordAccess(_ grant: MCPClientGrant) {
        if isCurrent(grant) { lastAccess[grant.id] = Date() }
    }

    func configuration(for grant: MCPClientGrant) throws -> String {
        guard grants.contains(grant), let token = try vault.read(grant.id) else { throw MCPQueryError.unauthorized }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/memozia-mcp").path
        let config: [String: Any] = ["mcpServers": ["memozia": [
            "command": helper, "env": ["MEMOZIA_MCP_URL": endpoint, "MEMOZIA_MCP_TOKEN": token]
        ]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
}

enum MCPQueryError: String, Error, Sendable {
    case invalidArguments = "invalid_arguments"
    case invalidCursor = "invalid_cursor"
    case notFound = "not_found"
    case unauthorized
    case credentialsUnavailable = "credentials_unavailable"
    case notReady = "not_ready"
    case readFailed = "read_failed"
    case responseTooLarge = "response_too_large"
    case busy
}
