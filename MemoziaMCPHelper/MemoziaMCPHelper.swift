import Foundation
import Darwin
import MCP

/// 只连接用户设置的本机服务；不打开数据库、不读取加密密钥、不加载模型。
@main
struct MemoziaMCPHelper {
    static func main() async {
        do { try await run() }
        catch {
            // stderr 不输出错误对象：第三方网络错误有时会携带请求或凭据。
            FileHandle.standardError.write(Data("Memozia MCP: connection failed. Open Memozia, enable MCP and check the client configuration.\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["MEMOZIA_MCP_URL"], let url = URL(string: address),
              url.scheme == "http", url.host == "127.0.0.1", url.path == "/mcp",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let port = url.port, (1024...65535).contains(port),
              let token = env["MEMOZIA_MCP_TOKEN"], !token.isEmpty,
              token.utf8.count < 256, !token.contains(where: { $0.isNewline }) else {
            throw HelperError.invalidConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let transport = HTTPClientTransport(endpoint: url, configuration: configuration, streaming: false, requestModifier: { request in
            var request = request
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            return request
        })
        let client = Client(name: "memozia-mcp", version: "1.0.0", configuration: .strict)
        try await client.connect(transport: transport)
        let server = Server(name: "Memozia", version: "1.0.0", capabilities: .init(resources: .init(), tools: .init()), configuration: .strict)
        await forward(ListTools.self, from: server, to: client)
        await forward(CallTool.self, from: server, to: client)
        await forward(ListResources.self, from: server, to: client)
        await forward(ListResourceTemplates.self, from: server, to: client)
        await forward(ReadResource.self, from: server, to: client)
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
        if let sessionID = await transport.sessionID {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            let cleanupConfig = URLSessionConfiguration.ephemeral
            cleanupConfig.timeoutIntervalForRequest = 2
            cleanupConfig.timeoutIntervalForResource = 2
            let cleanup = URLSession(configuration: cleanupConfig)
            do { _ = try await cleanup.data(for: request) }
            catch {
                FileHandle.standardError.write(Data("Memozia MCP: session cleanup deferred to the app.\n".utf8))
            }
            cleanup.invalidateAndCancel()
        }
        await client.disconnect()
    }

    private static func forward<M: MCP.Method>(_ method: M.Type, from server: Server, to client: Client) async {
        await server.withMethodHandler(method) { params in
            let request = M.request(params)
            let context = try await client.send(request)
            return try await withTaskCancellationHandler {
                try await context.value
            } onCancel: {
                Task { try? await client.cancelRequest(request.id) }
            }
        }
    }

    private enum HelperError: Error { case invalidConfiguration }
}
