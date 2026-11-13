import Foundation
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

/// NIO 解析 HTTP；没有自制 HTTP/JSON-RPC 解析器。监听地址固定为 IPv4 回环。
actor MCPLoopbackListener {
    private var group: MultiThreadedEventLoopGroup?
    private var channel: (any Channel)?

    func start(port: Int, handler: @escaping @Sendable (HTTPRequest) async -> MCPHTTPReply) async throws -> Int {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false).flatMapThrowing {
                        // 初始化及 future 回调均在此 channel 的 event loop 上执行；
                        // handler 留在该 loop 内，无需也不应声明为 Sendable。
                        try channel.pipeline.syncOperations.addHandlers(
                            IdleStateHandler(readTimeout: .seconds(15)), MCPHTTPHandler(handler: handler))
                    }
                }.bind(host: "127.0.0.1", port: port).get()
            self.channel = channel
            return channel.localAddress?.port ?? port
        } catch {
            try await group.shutdownGracefully()
            self.group = nil
            throw error
        }
    }

    func stop() async throws {
        let channel = channel
        let group = group
        self.channel = nil
        self.group = nil
        try await channel?.close()
        try await group?.shutdownGracefully()
    }
}

/// 此 handler 的可变状态只由 NIO 的同一 event loop 访问。异步任务仅捕获 Sendable
/// Channel 和请求快照，不把 ChannelHandlerContext / handler 跨线程传递。
private final class MCPHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private let handler: @Sendable (HTTPRequest) async -> MCPHTTPReply
    private var head: HTTPRequestHead?
    private var body = Data()
    private var dispatched = false
    private var task: Task<Void, Never>?

    init(handler: @escaping @Sendable (HTTPRequest) async -> MCPHTTPReply) { self.handler = handler }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !dispatched else { context.close(promise: nil); return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard self.head == nil else { context.close(promise: nil); return }
            self.head = head
        case .body(var buffer):
            guard body.count + buffer.readableBytes <= 65536 else {
                dispatch(.error(413, "request_too_large"), channel: context.channel)
                return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head else { context.close(promise: nil); return }
            // 同名敏感 header 禁止重复，避免代理/认证层对同一请求产生不同解释。
            var headers: [String: String] = [:]
            for header in head.headers {
                let name = header.name.lowercased()
                guard headers[name] == nil else { dispatch(.error(400, "duplicate_header"), channel: context.channel); return }
                headers[name] = header.value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers, body: body, path: head.uri)
            let channel = context.channel
            let handler = handler
            dispatched = true
            task = Task {
                let reply = await handler(request)
                await Self.write(reply, channel: channel)
            }
        }
    }

    private func dispatch(_ reply: MCPHTTPReply, channel: any Channel) {
        dispatched = true
        task = Task { await Self.write(reply, channel: channel) }
    }

    private static func write(_ reply: MCPHTTPReply, channel: any Channel) async {
        var headers = HTTPHeaders(reply.headers.map { ($0.key, $0.value) })
        headers.replaceOrAdd(name: "Content-Length", value: String(reply.body.count))
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        headers.replaceOrAdd(name: "Connection", value: "close")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: reply.status), headers: headers)
        do {
            try await channel.writeAndFlush(HTTPServerResponsePart.head(head))
            var buffer = channel.allocator.buffer(capacity: reply.body.count)
            buffer.writeBytes(reply.body)
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
            try await channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            try await channel.close()
        } catch {
            // 对端取消或断线：关闭 channel，由 channelInactive 把取消传到查询/SDK。
            channel.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) { task?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { task?.cancel(); context.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { task?.cancel(); context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
}
