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
/// `@unchecked Sendable`: the only mutable state is `state`, mutated
/// exclusively from `channelRead` which NIO confines to a single
/// event loop. Same pattern as `HTTPHandler`'s state wrapping.
final class AppHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
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
        case capturing(head: HTTPRequestHead, body: ByteBuffer?, startTime: Date)
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
                state = .capturing(head: head, body: nil, startTime: Date())
            } else {
                state = .passThroughBody
                context.fireChannelRead(data)
            }

        case .capturing(let head, var body, let startTime):
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
                state = .capturing(head: head, body: body, startTime: startTime)
            case .end:
                state = .idle
                dispatch(head: head, body: body, startTime: startTime, context: context)
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

    // MARK: - Telemetry

    private func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String? = nil,
        responseStatus: Int, startTime: Date,
        toolCalls: [ToolCallLog]? = nil,
        errorMessage: String? = nil
    ) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        InferenceServices.telemetry.logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: requestBody, responseBody: responseBody,
            responseStatus: responseStatus, durationMs: durationMs,
            model: nil, tokensInput: nil, tokensOutput: nil,
            temperature: nil, maxTokens: nil,
            toolCalls: toolCalls, finishReason: nil,
            errorMessage: errorMessage
        )
    }

    // MARK: - Dispatch

    private func dispatch(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        startTime: Date,
        context: ChannelHandlerContext
    ) {
        let path = Self.extractPath(from: head.uri)
        let loopback = isLoopback(context)
        let cors = computeCORSHeaders(head: head, isPreflight: false, isLoopback: loopback)
        let userAgent = head.headers.first(name: "User-Agent")

        if let authErr = authError(head: head, path: path, isLoopback: loopback) {
            var headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: cors)
            let errBody = #"{"error":{"message":"\#(authErr)","type":"authentication_error"}}"#
            HTTPHandler.sendResponse(
                context: context, version: head.version,
                status: .unauthorized, headers: headers, body: errBody
            )
            return
        }

        switch (head.method, path) {
        case (.POST, "/pair"):
            handlePair(
                head: head, body: body, cors: cors, context: context,
                startTime: startTime, userAgent: userAgent
            )
        default:
            var headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: cors)
            let bodyPreview = body.map { "\($0.readableBytes) bytes" } ?? "no body"
            let msg = #"{"error":"not_implemented","route":"\#(head.method) \#(path)","body":"\#(bodyPreview)"}"#
            HTTPHandler.sendResponse(
                context: context, version: head.version,
                status: .notImplemented, headers: headers, body: msg
            )
        }
    }

    // MARK: - /pair

    private struct PairRequest: Codable {
        let connectorAddress: String
        let agentId: String
        let nonce: String
        let signature: String
    }

    private struct PairResponse: Codable {
        let agentAddress: String
        let apiKey: String
        let isPermanent: Bool
    }

    /// POST /pair — unauthenticated endpoint for cryptographic Bonjour pairing.
    private func handlePair(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        cors: [(String, String)],
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let data: Data
        let requestBodyString: String?
        if var bodyCopy = body {
            let bytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
            data = Data(bytes)
            requestBodyString = String(decoding: data, as: UTF8.self)
        } else {
            data = Data()
            requestBodyString = nil
        }

        guard let req = try? JSONDecoder().decode(PairRequest.self, from: data) else {
            var headers = [("Content-Type", "application/json; charset=utf-8")]
            headers.append(contentsOf: cors)
            let body = #"{"error":"Invalid pairing request"}"#
            HTTPHandler.sendResponse(
                context: context, version: head.version,
                status: .badRequest, headers: headers, body: body
            )
            logRequest(
                method: "POST", path: "/pair", userAgent: userAgent,
                requestBody: requestBodyString, responseBody: body,
                responseStatus: 400, startTime: startTime
            )
            return
        }

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop = HTTPHandler.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        // Strip port from Host header (e.g. "device.local:1337" → "device.local")
        let pairingHost =
            (head.headers.first(name: "Host") ?? "unknown")
            .components(separatedBy: ":").first ?? "unknown"

        Task(priority: .userInitiated) { [self] in
            // 1. Verify the connector's signature over the nonce.
            let hexSig = req.signature.hasPrefix("0x") ? String(req.signature.dropFirst(2)) : req.signature
            guard let sigBytes = Data(hexEncoded: hexSig),
                let recovered = try? recoverAddress(
                    payload: Data(req.nonce.utf8),
                    signature: sigBytes,
                    domainPrefix: "Osaurus Signed Pairing"
                ),
                recovered == req.connectorAddress
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Signature verification failed"}"#
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .unauthorized, headers: headers, body: body
                    )
                    self.logRequest(
                        method: "POST", path: "/pair", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: body,
                        responseStatus: 401, startTime: logStartTime
                    )
                }
                return
            }

            // 2. Resolve the target agent.
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard let agentUUID = UUID(uuidString: req.agentId),
                let agent = agents.first(where: { $0.id == agentUUID && $0.bonjourEnabled }),
                let agentAddress = agent.agentAddress
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Agent not found or not available for pairing"}"#
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .notFound, headers: headers, body: body
                    )
                    self.logRequest(
                        method: "POST", path: "/pair", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: body,
                        responseStatus: 404, startTime: logStartTime
                    )
                }
                return
            }

            // 3. Show the approval popup on the advertiser's device.
            let approval = await PairingPromptService.requestApproval(
                connectorAddress: req.connectorAddress,
                agentName: agent.name
            )

            guard approval.approved else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Pairing denied"}"#
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .forbidden, headers: headers, body: body
                    )
                    self.logRequest(
                        method: "POST", path: "/pair", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: body,
                        responseStatus: 403, startTime: logStartTime
                    )
                }
                return
            }

            let isPermanent = approval.isPermanent

            // 4. Generate an agent-scoped osk-v1 API key. The token's `aud`
            //    is the agent's address, so it cannot be presented to other
            //    agents. Default 90-day expiry; `.never` only when the user
            //    explicitly opts in via the approval dialog. Generating
            //    triggers biometric auth to derive the agent key from the
            //    Master Key.
            let label = "Paired – \(pairingHost)"
            guard let agentIndex = agent.agentIndex else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Agent is missing a derived key index"}"#
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .internalServerError, headers: headers, body: body
                    )
                    self.logRequest(
                        method: "POST", path: "/pair", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: body,
                        responseStatus: 500, startTime: logStartTime
                    )
                }
                return
            }
            let expiration: AccessKeyExpiration = isPermanent ? .never : .days90
            guard
                let (fullKey, keyInfo) = try? APIKeyManager.shared.generate(
                    label: label, expiration: expiration, agentIndex: agentIndex
                )
            else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    let body = #"{"error":"Failed to generate access key"}"#
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .internalServerError, headers: headers, body: body
                    )
                    self.logRequest(
                        method: "POST", path: "/pair", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: body,
                        responseStatus: 500, startTime: logStartTime
                    )
                }
                return
            }

            // Temporary keys are revoked and removed from the key list on app exit.
            if !isPermanent {
                TemporaryPairedKeyStore.shared.register(keyId: keyInfo.id)
            }

            // 5. Return the agent's address, the generated API key, and the permanence flag.
            let response = PairResponse(agentAddress: agentAddress, apiKey: fullKey, isPermanent: isPermanent)
            let json =
                (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"error":"Encoding failed"}"#
            // Never log the freshly minted key. The wire response still
            // contains it; the request log gets a redacted copy with the
            // same shape so operators can see "this pairing happened" without
            // recovering the credential from the ring buffer.
            let redactedResponse = PairResponse(
                agentAddress: agentAddress, apiKey: "<redacted>", isPermanent: isPermanent
            )
            let redactedJson =
                (try? JSONEncoder().encode(redactedResponse)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"agentAddress":"<redacted>","apiKey":"<redacted>"}"#

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: .ok, headers: headers, body: json
                )
                self.logRequest(
                    method: "POST", path: "/pair", userAgent: logUserAgent,
                    requestBody: logRequestBody, responseBody: redactedJson,
                    responseStatus: 200, startTime: logStartTime
                )
            }
        }
    }
}
