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
        case (.POST, "/pair-invite"):
            handlePairInvite(
                head: head, body: body, cors: cors, context: context,
                startTime: startTime, userAgent: userAgent
            )
        case (.POST, "/memory/ingest"):
            handleMemoryIngest(
                head: head, body: body, cors: cors, context: context,
                startTime: startTime, userAgent: userAgent
            )
        case (.GET, "/agents"):
            handleListAgents(
                head: head, cors: cors, context: context,
                startTime: startTime, userAgent: userAgent
            )
        case (.GET, let p) where p.hasPrefix("/agents/")
            && !p.dropFirst("/agents/".count).contains("/"):
            handleGetAgent(
                head: head, path: p, cors: cors, context: context,
                startTime: startTime, userAgent: userAgent
            )
        case (_, let p) where p.hasPrefix("/plugins/"):
            let router = AppPluginRouter(
                configuration: configuration, apiKeyValidator: apiKeyValidator
            )
            router.handle(
                head: head, body: body, path: p, corsHeaders: cors,
                context: context, startTime: startTime,
                userAgent: userAgent, isLoopback: loopback
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

    // MARK: - /pair-invite

    private struct PairInviteResponse: Codable {
        let agentAddress: String
        let agentName: String
        let agentDescription: String?
        let relayBaseURL: String
        let apiKey: String
    }

    /// POST /pair-invite — unauthenticated endpoint that swaps a signed
    /// `AgentInvite` for an `osk-v1` access key. The invite IS the auth:
    /// it's signed by the agent's per-agent child key, carries a
    /// single-use nonce that's recorded server-side, and has a hard
    /// expiry. Client posts the EXACT JSON body that was embedded in
    /// the deeplink's `pair` query parameter.
    private func handlePairInvite(
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

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: @Sendable (@escaping @Sendable () -> Void) -> Void
            = HTTPHandler.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString
        // Origin label for the issued-invite ledger (purely informational).
        let origin =
            (head.headers.first(name: "X-Forwarded-For")
            ?? head.headers.first(name: "Host"))?.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces)

        let reply: @Sendable (HTTPResponseStatus, String, Int) -> Void = { [self] status, body, code in
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: status, headers: headers, body: body
                )
                self.logRequest(
                    method: "POST", path: "/pair-invite", userAgent: logUserAgent,
                    requestBody: logRequestBody, responseBody: body,
                    responseStatus: code, startTime: logStartTime
                )
            }
        }

        guard let invite = try? JSONDecoder().decode(AgentInvite.self, from: data) else {
            reply(.badRequest, #"{"error":"Invalid invite payload"}"#, 400)
            return
        }
        guard invite.v == AgentInvite.currentVersion else {
            reply(.badRequest, #"{"error":"Unsupported invite version"}"#, 400)
            return
        }
        do {
            try invite.verifySignature()
        } catch {
            reply(.unauthorized, #"{"error":"Signature verification failed"}"#, 401)
            return
        }
        if invite.isExpired {
            reply(.gone, #"{"error":"Invite has expired"}"#, 410)
            return
        }

        Task(priority: .userInitiated) { [self] in
            // 1. Resolve a local agent that matches the invite address. The
            //    receiver only ever connects via the relay tunnel, so the
            //    address has to belong to an agent on THIS device.
            let agents = await MainActor.run { AgentManager.shared.agents }
            guard
                let agent = agents.first(where: { ($0.agentAddress?.lowercased() ?? "") == invite.addr.lowercased() }),
                let agentIndex = agent.agentIndex,
                let agentAddress = agent.agentAddress
            else {
                reply(.notFound, #"{"error":"Agent address not found on this server"}"#, 404)
                return
            }

            // 2. Verify + consume the nonce atomically so concurrent redemptions
            //    of the same invite cannot both succeed.
            let consume = await MainActor.run {
                AgentInviteStore.verifyAndConsume(nonce: invite.nonce, for: agent.id, from: origin)
            }
            switch consume {
            case .unknownNonce:
                // Signature checks out but no record of this nonce — could be
                // a replay against a different agent, an invite issued before
                // a wipe, or a mismatched device. Reject so a stolen URL can't
                // mint forever-keys against a fresh ledger.
                reply(.unauthorized, #"{"error":"Invite is not registered on this server"}"#, 401)
                return
            case .alreadyUsed:
                reply(.conflict, #"{"error":"Invite has already been redeemed"}"#, 409)
                return
            case .revoked:
                reply(.forbidden, #"{"error":"Invite was revoked"}"#, 403)
                return
            case .expired:
                reply(.gone, #"{"error":"Invite has expired"}"#, 410)
                return
            case .consumed:
                break
            }

            // 3. Mint an agent-scoped osk-v1 access key. Triggers biometric.
            //    1-year expiry matches the share-link UX: long enough that
            //    users don't get random disconnects, short enough that a
            //    forgotten leak self-resolves. Sender can revoke any time
            //    via the issued-invites list.
            let label = "Invite – \(invite.name) (\(invite.nonce.prefix(8)))"
            do {
                let (fullKey, keyInfo) = try APIKeyManager.shared.generate(
                    label: label, expiration: .year1, agentIndex: agentIndex
                )
                await MainActor.run {
                    AgentInviteStore.attachAccessKey(
                        nonce: invite.nonce, for: agent.id, accessKeyId: keyInfo.id
                    )
                }

                func responseBody(apiKey: String) -> String {
                    let body = PairInviteResponse(
                        agentAddress: agentAddress,
                        agentName: agent.name,
                        agentDescription: agent.description.isEmpty ? nil : agent.description,
                        relayBaseURL: invite.url,
                        apiKey: apiKey
                    )
                    return (try? JSONEncoder().encode(body))
                        .map { String(decoding: $0, as: UTF8.self) }
                        ?? #"{"error":"Encoding failed"}"#
                }

                let json = responseBody(apiKey: fullKey)
                // Redacted twin for the request log — the ring buffer powers
                // the in-app diagnostics panel and must never echo the key.
                let redactedJson = responseBody(apiKey: "<redacted>")
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .ok, headers: headers, body: json
                    )
                    self.logRequest(
                        method: "POST", path: "/pair-invite", userAgent: logUserAgent,
                        requestBody: logRequestBody, responseBody: redactedJson,
                        responseStatus: 200, startTime: logStartTime
                    )
                }
            } catch {
                // Roll the nonce back to active so a transient APIKeyManager
                // failure doesn't permanently brick the invite.
                await MainActor.run {
                    AgentInviteStore.rollbackConsume(nonce: invite.nonce, for: agent.id)
                }
                reply(.internalServerError, #"{"error":"Failed to mint access key"}"#, 500)
            }
        }
    }

    // MARK: - /memory/ingest

    private struct MemoryIngestRequest: Codable {
        let agent_id: String
        let conversation_id: String
        let turns: [MemoryIngestTurn]
        let session_date: String?
        let skip_extraction: Bool?
    }

    private struct MemoryIngestTurn: Codable {
        let user: String
        let assistant: String
        let date: String?
    }

    /// Bulk-ingest conversation turns into the memory system.
    private func handleMemoryIngest(
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

        guard let req = try? JSONDecoder().decode(MemoryIngestRequest.self, from: data) else {
            HTTPHandler.sendResponse(
                context: context, version: head.version,
                status: .badRequest,
                headers: [("Content-Type", "text/plain; charset=utf-8")],
                body: "Invalid request format. Expected {agent_id, conversation_id, turns: [{user, assistant}]}"
            )
            logRequest(
                method: "POST", path: "/memory/ingest", userAgent: userAgent,
                requestBody: requestBodyString,
                responseStatus: 400, startTime: startTime,
                errorMessage: "Invalid request format"
            )
            return
        }

        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: @Sendable (@escaping @Sendable () -> Void) -> Void
            = HTTPHandler.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent
        let logRequestBody = requestBodyString

        Task(priority: .userInitiated) { [self] in
            let db = InferenceServices.memory

            let skipExtraction = req.skip_extraction ?? false

            try? db.deleteTranscriptForConversation(req.conversation_id)

            for (i, turn) in req.turns.enumerated() {
                let turnDate = turn.date ?? req.session_date

                let pairs: [(role: String, content: String, index: Int)] = [
                    ("user", turn.user, i * 2),
                    ("assistant", turn.assistant, i * 2 + 1),
                ]
                for (role, content, chunkIndex) in pairs {
                    let tokens = TokenEstimator.estimate(content)
                    let storedTurn = TranscriptTurn(
                        conversationId: req.conversation_id,
                        chunkIndex: chunkIndex,
                        role: role,
                        content: content,
                        tokenCount: tokens,
                        agentId: req.agent_id
                    )
                    try? db.insertTranscriptTurn(
                        agentId: req.agent_id,
                        conversationId: req.conversation_id,
                        chunkIndex: chunkIndex,
                        role: role,
                        content: content,
                        tokenCount: tokens,
                        createdAt: turnDate
                    )
                    await MemorySearchService.shared.indexTranscriptTurn(storedTurn)
                }

                if !skipExtraction {
                    await MemoryService.shared.bufferTurn(
                        userMessage: turn.user,
                        assistantMessage: turn.assistant,
                        agentId: req.agent_id,
                        conversationId: req.conversation_id,
                        sessionDate: turnDate
                    )
                }
            }

            // Ingestion always implies "I'm done with this conversation
            // batch": flush distillation immediately so callers don't have
            // to wait for the debounce.
            if !skipExtraction {
                await MemoryService.shared.flushSession(
                    agentId: req.agent_id, conversationId: req.conversation_id
                )
            }

            let responseBody = "{\"status\":\"ok\",\"turns_ingested\":\(req.turns.count)}"
            let headers: [(String, String)] = [("Content-Type", "application/json")] + cors
            hop {
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: .ok, headers: headers, body: responseBody
                )
            }
            self.logRequest(
                method: "POST", path: "/memory/ingest", userAgent: logUserAgent,
                requestBody: logRequestBody, responseBody: responseBody,
                responseStatus: 200, startTime: logStartTime
            )
        }
    }

    // MARK: - /agents

    private struct AgentListItem: Codable {
        let id: String
        let name: String
        let description: String
        let default_model: String?
        let effective_model: String?
        let supports_thinking: Bool
        let supports_vision: Bool
        let is_built_in: Bool
        let memory_entry_count: Int
        let created_at: String
        let updated_at: String
    }

    private struct AgentListResponse: Codable {
        let agents: [AgentListItem]
    }

    /// GET /agents — list all agents with resolved model/capability info.
    private func handleListAgents(
        head: HTTPRequestHead,
        cors: [(String, String)],
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: @Sendable (@escaping @Sendable () -> Void) -> Void
            = HTTPHandler.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent

        Task(priority: .userInitiated) { [self] in
            let agents = await MainActor.run { AgentManager.shared.agents }

            let db = InferenceServices.memory
            var memoryCounts: [String: Int] = [:]
            if db.isOpen, let counts = try? db.agentIdsWithPinnedFacts() {
                for (agentId, count) in counts {
                    memoryCounts[agentId] = count
                }
            }

            let formatter = ISO8601DateFormatter()
            let effectiveModels = await MainActor.run {
                Dictionary(
                    uniqueKeysWithValues: agents.map {
                        ($0.id, AgentManager.shared.effectiveModel(for: $0.id))
                    }
                )
            }
            let modelsDir = InferenceServices.modelDirectory.effectiveModelsDirectory()
            let items = agents.map { agent in
                let modelId = effectiveModels[agent.id] ?? agent.defaultModel
                let supportsVision = modelId.map { VLMDetection.isVLM(modelId: $0, in: modelsDir) } ?? false
                let supportsThinking =
                    modelId.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption } != nil
                return AgentListItem(
                    id: agent.id.uuidString,
                    name: agent.name,
                    description: agent.description,
                    default_model: agent.defaultModel,
                    effective_model: modelId,
                    supports_thinking: supportsThinking,
                    supports_vision: supportsVision,
                    is_built_in: agent.isBuiltIn,
                    memory_entry_count: memoryCounts[agent.id.uuidString] ?? 0,
                    created_at: formatter.string(from: agent.createdAt),
                    updated_at: formatter.string(from: agent.updatedAt)
                )
            }

            let response = AgentListResponse(agents: items)
            let json =
                (try? JSONEncoder().encode(response)).map { String(decoding: $0, as: UTF8.self) }
                ?? #"{"agents":[]}"#

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: .ok, headers: headers, body: json
                )
            }
            self.logRequest(
                method: "GET", path: "/agents", userAgent: logUserAgent,
                requestBody: nil, responseBody: json,
                responseStatus: 200, startTime: logStartTime
            )
        }
    }

    /// GET /agents/{id} — return info for a single agent.
    private func handleGetAgent(
        head: HTTPRequestHead,
        path: String,
        cors: [(String, String)],
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?
    ) {
        let loop = context.eventLoop
        let ctx = NIOLoopBound(context, eventLoop: loop)
        let hop: @Sendable (@escaping @Sendable () -> Void) -> Void
            = HTTPHandler.makeHop(channel: context.channel, loop: loop)
        let logStartTime = startTime
        let logUserAgent = userAgent

        let components = path.split(separator: "/")
        guard components.count == 2, components[0] == "agents",
            let agentId = UUID(uuidString: String(components[1]))
        else {
            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: .badRequest, headers: headers,
                    body: #"{"error":"invalid_agent_id","message":"Invalid agent UUID in path"}"#
                )
            }
            return
        }

        Task(priority: .userInitiated) { [self] in
            guard let agent = await MainActor.run(body: { AgentManager.shared.agent(for: agentId) }) else {
                hop {
                    var headers = [("Content-Type", "application/json; charset=utf-8")]
                    headers.append(contentsOf: cors)
                    HTTPHandler.sendResponse(
                        context: ctx.value, version: head.version,
                        status: .notFound, headers: headers,
                        body: #"{"error":"agent_not_found","message":"No agent found for the given ID"}"#
                    )
                }
                return
            }

            let formatter = ISO8601DateFormatter()
            let effectiveModelId =
                await MainActor.run { AgentManager.shared.effectiveModel(for: agent.id) }
                ?? agent.defaultModel
            let modelsDir = InferenceServices.modelDirectory.effectiveModelsDirectory()
            let supportsVision = effectiveModelId.map { VLMDetection.isVLM(modelId: $0, in: modelsDir) } ?? false
            let supportsThinking =
                effectiveModelId.flatMap { ModelProfileRegistry.profile(for: $0)?.thinkingOption } != nil
            let item = AgentListItem(
                id: agent.id.uuidString,
                name: agent.name,
                description: agent.description,
                default_model: agent.defaultModel,
                effective_model: effectiveModelId,
                supports_thinking: supportsThinking,
                supports_vision: supportsVision,
                is_built_in: agent.isBuiltIn,
                memory_entry_count: 0,
                created_at: formatter.string(from: agent.createdAt),
                updated_at: formatter.string(from: agent.updatedAt)
            )
            let json =
                (try? JSONEncoder().encode(item)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"

            hop {
                var headers = [("Content-Type", "application/json; charset=utf-8")]
                headers.append(contentsOf: cors)
                HTTPHandler.sendResponse(
                    context: ctx.value, version: head.version,
                    status: .ok, headers: headers, body: json
                )
            }
            self.logRequest(
                method: "GET", path: path, userAgent: logUserAgent,
                requestBody: nil, responseBody: json,
                responseStatus: 200, startTime: logStartTime
            )
        }
    }
}
