import Foundation
import NIOCore
import NIOHTTP1

/// Plugin-route entry point used by `AppHTTPHandler` for `/plugins/*`.
/// Owns the dispatch, static-file serving, dev-proxy, and response
/// writers that used to live as private methods on `HTTPHandler`.
struct AppPluginRouter: Sendable {
    let configuration: ServerConfiguration
    let apiKeyValidator: APIKeyValidator

    /// Entry. `path` is the request's already-normalized path
    /// (e.g. `/plugins/<id>/<subpath>`); `body` is the captured request
    /// body. Public-style auth is per-route inside this handler — the
    /// caller (AppHTTPHandler) does NOT run the global API-key gate.
    func handle(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        path: String,
        corsHeaders: [(String, String)],
        context: ChannelHandlerContext,
        startTime: Date,
        userAgent: String?,
        isLoopback: Bool
    ) {
        let method = head.method.rawValue

        // Parse: /plugins/<pluginId>/<subpath>
        let segments = path.dropFirst("/plugins/".count)
        guard let slashIdx = segments.firstIndex(of: "/") else {
            sendPluginError(
                context: context, head: head, status: .notFound,
                message: "Invalid plugin route", corsHeaders: corsHeaders,
                startTime: startTime, method: method, path: path, userAgent: userAgent
            )
            return
        }
        let pluginId = String(segments[..<slashIdx])
        let subpath = String(segments[slashIdx...])

        if pluginId.contains("..") || subpath.contains("..") {
            sendPluginError(
                context: context, head: head, status: .badRequest,
                message: "Invalid path", corsHeaders: corsHeaders,
                startTime: startTime, method: method, path: path, userAgent: userAgent
            )
            return
        }

        let loop = context.eventLoop
        let ctxBound = NIOLoopBound(context, eventLoop: loop)
        let bodyBuffer = body
        let uri = head.uri
        let headersDict = Dictionary(
            head.headers.map { ($0.name.lowercased(), $0.value) },
            uniquingKeysWith: { $1 }
        )
        let version = head.version

        // All plugin route access requires an agent context. Accept either
        // the X-Osaurus-Agent-Id header (preferred for SDK + tunnel callers)
        // or the osr_agent query parameter (for browser-launched web UIs
        // that cannot set custom headers on the top-level navigation).
        let queryAgent: String? = {
            guard let q = head.uri.split(separator: "?").dropFirst().first else { return nil }
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0] == "osr_agent" {
                    return kv[1].removingPercentEncoding ?? kv[1]
                }
            }
            return nil
        }()
        let agentIdStr = headersDict["x-osaurus-agent-id"] ?? queryAgent
        guard let agentIdStr, let agentUUID = UUID(uuidString: agentIdStr) else {
            sendPluginError(
                context: context, head: head, status: .unauthorized,
                message:
                    "Plugin routes require an agent context (X-Osaurus-Agent-Id header or osr_agent query parameter)",
                corsHeaders: corsHeaders,
                startTime: startTime, method: method, path: path, userAgent: userAgent
            )
            return
        }

        // Narrow MainActor scope: only the few lookups that need it run on
        // MainActor. Route matching, auth, JSON encoding, plugin invocation,
        // and response handling run off MainActor.
        let task = Task { [self] in
            let loaded = await MainActor.run {
                PluginManager.shared.loadedPlugin(for: pluginId)
            }
            guard let loaded else {
                return self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .notFound, message: "Plugin not found: \(pluginId)",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }

            let manifest = loaded.plugin.manifest

            if let webSpec = loaded.webConfig {
                let mountPrefix = webSpec.mount.hasPrefix("/") ? webSpec.mount : "/\(webSpec.mount)"
                if subpath.hasPrefix(mountPrefix) {
                    // Tunnel exposure gate: web UIs are loopback-only by
                    // default. Plugins must opt in via
                    // `capabilities.web.tunnel_exposed` for the static UI
                    // to be reachable over the tunnel. Return 404 (not 403)
                    // so the route's existence isn't advertised externally.
                    if !isLoopback && !webSpec.isTunnelExposed {
                        return self.sendPluginErrorFromTask(
                            loop: loop, ctxBound: ctxBound, version: version,
                            status: .notFound, message: "No matching route",
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }
                    if webSpec.auth == .owner && !self.isValidOwnerAuth(headers: headersDict) {
                        return self.sendPluginErrorFromTask(
                            loop: loop, ctxBound: ctxBound, version: version,
                            status: .unauthorized, message: "Authentication required",
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }

                    if let proxyURL = Self.loadDevProxyURL(for: pluginId) {
                        let relPath = String(subpath.dropFirst(mountPrefix.count))
                        let targetPath = relPath.isEmpty ? "/" : relPath
                        // Forward original method/headers/body so Vite HMR,
                        // plugin POST APIs, and any non-GET dev traffic
                        // works during plugin development.
                        let proxyBody: Data? = {
                            guard let buf = bodyBuffer, buf.readableBytes > 0 else { return nil }
                            return Data(buffer: buf)
                        }()
                        return await self.proxyToDevServer(
                            proxyBaseURL: proxyURL,
                            targetPath: targetPath,
                            pluginId: pluginId,
                            apiMount: webSpec.api_mount ?? "/api",
                            agentId: agentIdStr,
                            requestMethod: method,
                            requestHeaders: headersDict,
                            requestBody: proxyBody,
                            loop: loop, ctxBound: ctxBound, version: version,
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }

                    let relPath = String(subpath.dropFirst(mountPrefix.count))
                    let filePath: String
                    if relPath.isEmpty || relPath == "/" {
                        filePath = webSpec.entry
                    } else {
                        filePath = relPath.hasPrefix("/") ? String(relPath.dropFirst()) : relPath
                    }

                    let versionDir = URL(fileURLWithPath: loaded.plugin.bundlePath).deletingLastPathComponent()
                    let webDir = versionDir.appendingPathComponent(webSpec.static_dir, isDirectory: true)
                    let fileURL = webDir.appendingPathComponent(filePath)

                    // Prevent escaping the web directory.
                    let resolvedPath = fileURL.standardizedFileURL.path
                    let webDirPath = webDir.standardizedFileURL.path
                    guard resolvedPath.hasPrefix(webDirPath) else {
                        return self.sendPluginErrorFromTask(
                            loop: loop, ctxBound: ctxBound, version: version,
                            status: .forbidden, message: "Access denied",
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }

                    let apiMount = webSpec.api_mount ?? "/api"
                    if FileManager.default.fileExists(atPath: resolvedPath) {
                        return self.serveStaticFile(
                            loop: loop, ctxBound: ctxBound, version: version,
                            filePath: resolvedPath, pluginId: pluginId,
                            apiMount: apiMount, agentId: agentIdStr,
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }

                    // SPA fallback: serve entry for non-file paths.
                    let entryPath = webDir.appendingPathComponent(webSpec.entry).path
                    if FileManager.default.fileExists(atPath: entryPath) {
                        return self.serveStaticFile(
                            loop: loop, ctxBound: ctxBound, version: version,
                            filePath: entryPath, pluginId: pluginId,
                            apiMount: apiMount, agentId: agentIdStr,
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }

                    return self.sendPluginErrorFromTask(
                        loop: loop, ctxBound: ctxBound, version: version,
                        status: .notFound, message: "File not found",
                        corsHeaders: corsHeaders, startTime: startTime,
                        method: method, path: path, userAgent: userAgent
                    )
                }
            }

            // Dynamic route matching with path-parameter extraction.
            guard let routeMatch = manifest.matchRouteWithParams(method: method, subpath: subpath) else {
                return self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .notFound, message: "No matching route",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }
            let route = routeMatch.route

            // Tunnel exposure gate: dynamic routes are loopback-only by
            // default. Plugins must opt in via `tunnel_exposed: true` on
            // the route spec for it to be reachable over the tunnel.
            // 404 (not 403) so route existence isn't leaked.
            if !isLoopback && !route.isTunnelExposed {
                return self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .notFound, message: "No matching route",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }

            switch route.auth {
            case .owner:
                if !self.isValidOwnerAuth(headers: headersDict) {
                    return self.sendPluginErrorFromTask(
                        loop: loop, ctxBound: ctxBound, version: version,
                        status: .unauthorized, message: "Authentication required",
                        corsHeaders: corsHeaders, startTime: startTime,
                        method: method, path: path, userAgent: userAgent
                    )
                }
            case .none, .verify:
                if !PluginRateLimiter.shared.allow(pluginId: pluginId) {
                    return self.sendPluginErrorFromTask(
                        loop: loop, ctxBound: ctxBound, version: version,
                        status: .tooManyRequests, message: "Rate limit exceeded",
                        corsHeaders: corsHeaders, startTime: startTime,
                        method: method, path: path, userAgent: userAgent
                    )
                }
            }

            guard loaded.plugin.hasRouteHandler else {
                return self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .notImplemented,
                    message: "Plugin does not support route handling",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }

            let queryParams = OsaurusHTTPRequest.parseQueryParams(from: uri)

            var bodyString = ""
            var bodyEncoding = "utf8"
            if let buf = bodyBuffer, buf.readableBytes > 0 {
                var readBuf = buf
                if let str = readBuf.readString(length: readBuf.readableBytes) {
                    bodyString = str
                } else {
                    let data = Data(buffer: buf)
                    bodyString = data.base64EncodedString()
                    bodyEncoding = "base64"
                }
            }

            let serverPort = self.configuration.port
            let localBaseURL = "http://127.0.0.1:\(serverPort)"

            let tunnelURL = await InferenceServices.tunnelResolver.tunnelBaseURL(for: agentUUID)
            let agentAddress = await MainActor.run {
                AgentManager.shared.agent(for: agentUUID)?.agentAddress ?? ""
            }

            let baseURL = tunnelURL ?? localBaseURL
            let pluginURL = "\(baseURL)/plugins/\(pluginId)"

            let request = OsaurusHTTPRequest(
                route_id: route.id,
                method: method,
                path: subpath,
                query: queryParams,
                path_params: routeMatch.pathParams,
                headers: headersDict,
                body: bodyString,
                body_encoding: bodyEncoding,
                remote_addr: "",
                plugin_id: pluginId,
                osaurus: .init(
                    base_url: baseURL,
                    plugin_url: pluginURL,
                    agent_address: agentAddress
                )
            )

            let encoder = JSONEncoder()
            guard let requestData = try? encoder.encode(request),
                let requestJSON = String(data: requestData, encoding: .utf8)
            else {
                return self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .internalServerError, message: "Failed to encode request",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }

            do {
                let responseJSON = try await loaded.plugin.handleRoute(requestJSON: requestJSON, agentId: agentUUID)

                guard let responseData = responseJSON.data(using: .utf8),
                    let response = try? JSONDecoder().decode(OsaurusHTTPResponse.self, from: responseData)
                else {
                    return self.sendPluginErrorFromTask(
                        loop: loop, ctxBound: ctxBound, version: version,
                        status: .internalServerError, message: "Invalid plugin response",
                        corsHeaders: corsHeaders, startTime: startTime,
                        method: method, path: path, userAgent: userAgent
                    )
                }

                let httpStatus = HTTPResponseStatus(statusCode: response.status)
                var responseHeaders: [(String, String)] = corsHeaders
                if let hdrs = response.headers {
                    for (k, v) in hdrs {
                        responseHeaders.append((k, v))
                    }
                }

                var responseBody = ""
                if let body = response.body {
                    if response.body_encoding == "base64" {
                        if let decoded = Data(base64Encoded: body) {
                            self.sendBinaryPluginResponse(
                                loop: loop, ctxBound: ctxBound, version: version,
                                status: httpStatus, headers: responseHeaders,
                                body: decoded, startTime: startTime,
                                method: method, path: path, userAgent: userAgent
                            )
                            return
                        }
                        // Plugin claimed base64 but the body did not decode.
                        // Surface the corruption rather than silently sending
                        // raw bytes that binary clients can't detect.
                        return self.sendPluginErrorFromTask(
                            loop: loop, ctxBound: ctxBound, version: version,
                            status: .badGateway,
                            message:
                                "Plugin response declared body_encoding=base64 but the body is not valid base64.",
                            corsHeaders: corsHeaders, startTime: startTime,
                            method: method, path: path, userAgent: userAgent
                        )
                    }
                    responseBody = body
                }

                self.sendPluginResponse(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: httpStatus, headers: responseHeaders,
                    body: responseBody, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            } catch {
                self.sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .internalServerError,
                    message: "Plugin error: \(error.localizedDescription)",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
            }
        }
        _ = task
    }

    // MARK: - Telemetry

    private func logRequest(
        method: String, path: String, userAgent: String?,
        requestBody: String?, responseBody: String?,
        responseStatus: Int, startTime: Date
    ) {
        let durationMs = Date().timeIntervalSince(startTime) * 1000
        InferenceServices.telemetry.logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: requestBody, responseBody: responseBody,
            responseStatus: responseStatus, durationMs: durationMs,
            model: nil, tokensInput: nil, tokensOutput: nil,
            temperature: nil, maxTokens: nil,
            toolCalls: nil, finishReason: nil, errorMessage: nil
        )
    }

    // MARK: - Response writers

    private func sendPluginError(
        context: ChannelHandlerContext,
        head: HTTPRequestHead,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        var headers = [("Content-Type", "application/json; charset=utf-8")]
        headers.append(contentsOf: corsHeaders)
        let body = #"{"error":{"message":"\#(message)"}}"#
        HTTPHandler.sendResponse(
            context: context, version: head.version,
            status: status, headers: headers, body: body
        )
        logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: nil, responseBody: body,
            responseStatus: Int(status.code), startTime: startTime
        )
    }

    /// Core NIO response writer for plugin routes. All plugin response
    /// helpers funnel through this.
    private func writePluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        bodyWriter: @Sendable @escaping (ChannelHandlerContext) -> ByteBuffer
    ) {
        let block: @Sendable () -> Void = {
            let context = ctxBound.value
            guard context.channel.isActive else { return }
            var responseHead = HTTPResponseHead(version: version, status: status)
            var nioHeaders = HTTPHeaders()
            for (name, value) in headers { nioHeaders.add(name: name, value: value) }
            let buffer = bodyWriter(context)
            nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
            nioHeaders.add(name: "Connection", value: "close")
            responseHead.headers = nioHeaders
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                ctxBound.value.close(promise: nil)
            }
        }
        if loop.inEventLoop { block() } else { loop.execute(block) }
    }

    private func sendPluginErrorFromTask(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        message: String,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        let headers: [(String, String)] = [("Content-Type", "application/json; charset=utf-8")] + corsHeaders
        let body = #"{"error":{"message":"\#(message)"}}"#
        writePluginResponse(
            loop: loop, ctxBound: ctxBound, version: version,
            status: status, headers: headers
        ) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: nil, responseBody: body,
            responseStatus: Int(status.code), startTime: startTime
        )
    }

    private func sendPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: String,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(
            loop: loop, ctxBound: ctxBound, version: version,
            status: status, headers: headers
        ) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            return buffer
        }
        logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: nil, responseBody: body,
            responseStatus: Int(status.code), startTime: startTime
        )
    }

    private func sendBinaryPluginResponse(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: [(String, String)],
        body: Data,
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        writePluginResponse(
            loop: loop, ctxBound: ctxBound, version: version,
            status: status, headers: headers
        ) { ctx in
            var buffer = ctx.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            return buffer
        }
        logRequest(
            method: method, path: path, userAgent: userAgent,
            requestBody: nil, responseBody: nil,
            responseStatus: Int(status.code), startTime: startTime
        )
    }

    // MARK: - Static file serving

    private func serveStaticFile(
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        filePath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) {
        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            sendPluginErrorFromTask(
                loop: loop, ctxBound: ctxBound, version: version,
                status: .notFound, message: "File not found",
                corsHeaders: corsHeaders, startTime: startTime,
                method: method, path: path, userAgent: userAgent
            )
            return
        }

        let ext = (filePath as NSString).pathExtension
        let mimeType = MIMEType.forExtension(ext)
        var headers: [(String, String)] = corsHeaders
        headers.append(("Content-Type", mimeType))
        headers.append(("Cache-Control", "public, max-age=3600"))

        if ext == "html" || ext == "htm", var html = String(data: fileData, encoding: .utf8) {
            Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
            sendPluginResponse(
                loop: loop, ctxBound: ctxBound, version: version,
                status: .ok, headers: headers, body: html,
                startTime: startTime, method: method, path: path, userAgent: userAgent
            )
        } else {
            sendBinaryPluginResponse(
                loop: loop, ctxBound: ctxBound, version: version,
                status: .ok, headers: headers, body: fileData,
                startTime: startTime, method: method, path: path, userAgent: userAgent
            )
        }
    }

    // MARK: - Auth

    /// Validates a Bearer token from the Authorization header.
    /// Returns true if the token is a valid `osk-v1` access key.
    private func isValidOwnerAuth(headers: [String: String]) -> Bool {
        let authHeader = headers["authorization"] ?? ""
        let token = authHeader.hasPrefix("Bearer ") ? String(authHeader.dropFirst(7)) : ""
        if case .valid = apiKeyValidator.validate(rawKey: token) { return true }
        return false
    }

    // MARK: - HTML context injection

    /// Injects the `window.__osaurus` context object into an HTML string
    /// before `</head>`. Plugins can opt in to a custom API mount via
    /// `capabilities.web.api_mount` (e.g. `"/v2"`); the default `/api`
    /// is preserved when unset. `agentId` is propagated so the page's
    /// `fetch()` calls can attach `X-Osaurus-Agent-Id` without re-entering
    /// the URL bar.
    private static func injectOsaurusContext(
        into html: inout String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil
    ) {
        let normalizedApiMount: String = {
            let trimmed = apiMount.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return "/api" }
            return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        }()
        let agentField = agentId.map { #"agentId: "\#($0)","# } ?? ""
        let script = """
            <script>
            window.__osaurus = {
              pluginId: "\(pluginId)",
              baseUrl: "/plugins/\(pluginId)",
              apiUrl: "/plugins/\(pluginId)\(normalizedApiMount)",
              \(agentField)
              fetch: function(input, init) {
                init = init || {};
                init.headers = new Headers(init.headers || {});
                if (window.__osaurus.agentId && !init.headers.has("X-Osaurus-Agent-Id")) {
                  init.headers.set("X-Osaurus-Agent-Id", window.__osaurus.agentId);
                }
                return fetch(input, init);
              }
            };
            </script>
            """
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: "\n\(script)\n", at: headEnd.lowerBound)
        }
    }

    // MARK: - Dev proxy

    /// Loads the dev proxy URL for a plugin from dev-proxy.json.
    private static func loadDevProxyURL(for pluginId: String) -> String? {
        let configFile = OsaurusPaths.config().appendingPathComponent("dev-proxy.json")
        guard let data = try? Data(contentsOf: configFile),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let configPluginId = obj["plugin_id"] as? String,
            configPluginId == pluginId,
            let proxyURL = obj["web_proxy"] as? String
        else { return nil }
        return proxyURL
    }

    /// Proxies a web request to a local dev server for HMR support.
    private func proxyToDevServer(
        proxyBaseURL: String,
        targetPath: String,
        pluginId: String,
        apiMount: String = "/api",
        agentId: String? = nil,
        requestMethod: String,
        requestHeaders: [String: String],
        requestBody: Data?,
        loop: EventLoop,
        ctxBound: NIOLoopBound<ChannelHandlerContext>,
        version: HTTPVersion,
        corsHeaders: [(String, String)],
        startTime: Date,
        method: String,
        path: String,
        userAgent: String?
    ) async {
        let targetURL = proxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + targetPath
        guard let url = URL(string: targetURL) else {
            sendPluginErrorFromTask(
                loop: loop, ctxBound: ctxBound, version: version,
                status: .badGateway, message: "Invalid proxy URL",
                corsHeaders: corsHeaders, startTime: startTime,
                method: method, path: path, userAgent: userAgent
            )
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = requestMethod
        request.timeoutInterval = 10
        if let body = requestBody, !body.isEmpty {
            request.httpBody = body
        }
        // Drop hop-by-hop and host-management headers that URLSession
        // sets for us, plus the agent header (host-internal context, not
        // relevant to the dev server).
        let stripped: Set<String> = [
            "host", "content-length", "connection", "transfer-encoding",
            "x-osaurus-agent-id", "authorization",
        ]
        for (k, v) in requestHeaders where !stripped.contains(k.lowercased()) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                sendPluginErrorFromTask(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: .badGateway, message: "Invalid response from dev server",
                    corsHeaders: corsHeaders, startTime: startTime,
                    method: method, path: path, userAgent: userAgent
                )
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var headers: [(String, String)] = corsHeaders
            headers.append(("Content-Type", contentType))
            headers.append(("Access-Control-Allow-Origin", "*"))

            if contentType.contains("text/html"), var html = String(data: data, encoding: .utf8) {
                Self.injectOsaurusContext(into: &html, pluginId: pluginId, apiMount: apiMount, agentId: agentId)
                sendPluginResponse(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers, body: html,
                    startTime: startTime, method: method, path: path, userAgent: userAgent
                )
            } else {
                sendBinaryPluginResponse(
                    loop: loop, ctxBound: ctxBound, version: version,
                    status: HTTPResponseStatus(statusCode: httpResponse.statusCode),
                    headers: headers, body: data,
                    startTime: startTime, method: method, path: path, userAgent: userAgent
                )
            }
        } catch {
            sendPluginErrorFromTask(
                loop: loop, ctxBound: ctxBound, version: version,
                status: .badGateway,
                message: "Dev server unreachable: \(error.localizedDescription)",
                corsHeaders: corsHeaders, startTime: startTime,
                method: method, path: path, userAgent: userAgent
            )
        }
    }
}
