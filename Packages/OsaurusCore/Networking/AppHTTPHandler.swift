import Foundation
import NIOCore
import NIOHTTP1

/// NIO `ChannelInboundHandler` for Mac-app-only HTTP routes that touch
/// app singletons not present in the engine package
/// (`AgentManager`, `AgentInviteStore`, `APIKeyManager`,
/// `MemoryService`/`MemorySearchService`, plugin proxy plumbing).
///
/// Sits BEFORE the engine `HTTPHandler` in the NIO pipeline. Buffers
/// `HTTPRequestPart` events for a single request; at `.end`, if the
/// path matches one of the relocated routes, dispatches inline and
/// writes the response. Otherwise forwards every buffered part via
/// `context.fireChannelRead` so the engine handler sees the request
/// untouched.
///
/// Owned by `ServerController`; never installed by the standalone CLI.
final class AppHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart

    private let configuration: ServerConfiguration
    private let apiKeyValidator: APIKeyValidator
    private let trustLoopback: Bool

    init(
        configuration: ServerConfiguration,
        apiKeyValidator: APIKeyValidator,
        trustLoopback: Bool
    ) {
        self.configuration = configuration
        self.apiKeyValidator = apiKeyValidator
        self.trustLoopback = trustLoopback
    }

    // MARK: - State

    private enum State {
        case idle
        case capturing(head: HTTPRequestHead, body: ByteBuffer?)
        case passThroughBody
    }

    private var state: State = .idle

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch state {
        case .idle:
            guard case .head(let head) = part else {
                context.fireChannelRead(data)
                return
            }
            if Self.shouldHandle(method: head.method, uri: head.uri) {
                state = .capturing(head: head, body: nil)
            } else {
                state = .passThroughBody
                context.fireChannelRead(data)
            }

        case .capturing(let head, var body):
            switch part {
            case .head:
                state = .idle
                context.fireChannelRead(data)
            case .body(let buf):
                if body == nil {
                    body = buf
                } else {
                    body!.writeImmutableBuffer(buf)
                }
                state = .capturing(head: head, body: body)
            case .end:
                state = .idle
                dispatch(head: head, body: body, context: context)
            }

        case .passThroughBody:
            context.fireChannelRead(data)
            if case .end = part {
                state = .idle
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Path matching

    /// Paths handled by this stage. Anything else falls through to the
    /// engine handler.
    static func shouldHandle(method: HTTPMethod, uri: String) -> Bool {
        let path = Self.extractPath(from: uri)
        switch (method, path) {
        case (.POST, "/pair"),
             (.POST, "/pair-invite"),
             (.POST, "/memory/ingest"),
             (.GET, "/agents"):
            return true
        default:
            break
        }
        if method == .GET && path.hasPrefix("/agents/") {
            // /agents/{id} only — /agents/{id}/run, /dispatch, etc. stay
            // engine-side; those use the abstracted AgentProvider seam.
            let rest = path.dropFirst("/agents/".count)
            if !rest.contains("/") { return true }
        }
        if path.hasPrefix("/plugins/") {
            return true
        }
        return false
    }

    private static func extractPath(from uri: String) -> String {
        if let q = uri.firstIndex(of: "?") {
            return String(uri[..<q])
        }
        return uri
    }

    // MARK: - Auth + CORS

    /// Paths that skip the global API-key auth gate. Mirrors
    /// `HTTPHandler`'s `publicPaths` set + plugin-route convention
    /// (`/plugins/*` does per-route auth inside the relocated body).
    private static let publicPaths: Set<String> = ["/pair", "/pair-invite"]

    private func isLoopback(_ context: ChannelHandlerContext) -> Bool {
        trustLoopback && (context.channel.remoteAddress?.isLoopback ?? false)
    }

    private func authError(
        head: HTTPRequestHead, path: String, isLoopback: Bool
    ) -> String? {
        if Self.publicPaths.contains(path) { return nil }
        if path.hasPrefix("/plugins/") { return nil }  // per-route auth
        if isLoopback { return nil }

        let authHeader = head.headers.first(name: "Authorization") ?? ""
        let token = authHeader.hasPrefix("Bearer ")
            ? String(authHeader.dropFirst(7))
            : ""

        if !apiKeyValidator.hasKeys {
            return "No access keys configured. Create one in Osaurus settings."
        }
        switch apiKeyValidator.validate(rawKey: token) {
        case .valid: return nil
        case .expired: return "Access key has expired"
        case .revoked: return "Access key has been revoked"
        case .invalid(let reason): return "Invalid access key: \(reason)"
        }
    }

    private func computeCORSHeaders(
        head: HTTPRequestHead, isPreflight: Bool, isLoopback: Bool
    ) -> [(String, String)] {
        let origin = head.headers.first(name: "Origin")
        var headers: [(String, String)] = []

        let allowsAny = isLoopback || configuration.allowedOrigins.contains("*")
        if allowsAny {
            headers.append(("Access-Control-Allow-Origin", "*"))
        } else if let origin,
            !origin.contains("\r"), !origin.contains("\n"),
            configuration.allowedOrigins.contains(origin)
        {
            headers.append(("Access-Control-Allow-Origin", origin))
            headers.append(("Vary", "Origin"))
        } else {
            return []
        }

        if isPreflight {
            let reqMethod = head.headers.first(name: "Access-Control-Request-Method")
            headers.append((
                "Access-Control-Allow-Methods",
                Self.sanitizeTokenList(reqMethod ?? "GET, POST, OPTIONS, HEAD")
            ))
            let reqHeaders = head.headers.first(name: "Access-Control-Request-Headers")
            headers.append((
                "Access-Control-Allow-Headers",
                Self.sanitizeTokenList(reqHeaders ?? "Content-Type, Authorization")
            ))
            headers.append(("Access-Control-Max-Age", "600"))
        }
        return headers
    }

    private static func sanitizeTokenList(_ value: String) -> String {
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~ ,")
        var result = String()
        result.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x61 ... 0x7A:
                result.unicodeScalars.append(scalar)
            default:
                let ch = Character(scalar)
                if allowedPunctuation.contains(ch) { result.append(ch) }
            }
        }
        return result.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // MARK: - Dispatch

    /// Route the captured request to a relocated endpoint handler.
    private func dispatch(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        context: ChannelHandlerContext
    ) {
        let path = Self.extractPath(from: head.uri)
        let loopback = isLoopback(context)
        var cors = computeCORSHeaders(head: head, isPreflight: false, isLoopback: loopback)

        if let authErr = authError(head: head, path: path, isLoopback: loopback) {
            var headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: cors)
            let body = #"{"error":{"message":"\#(authErr)","type":"authentication_error"}}"#
            HTTPHandler.sendResponse(
                context: context, version: head.version,
                status: .unauthorized, headers: headers, body: body
            )
            return
        }

        cors.insert(("Content-Type", "application/json; charset=utf-8"), at: 0)
        let bodyPreview = body.map { "\($0.readableBytes) bytes" } ?? "no body"
        let msg = #"{"error":"not_implemented","route":"\#(head.method) \#(path)","body":"\#(bodyPreview)"}"#
        HTTPHandler.sendResponse(
            context: context, version: head.version,
            status: .notImplemented, headers: cors, body: msg
        )
    }
}
