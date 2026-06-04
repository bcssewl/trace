import Foundation
import Network

/// A minimal one-shot loopback listener for the OAuth redirect (BAS-37): binds
/// `127.0.0.1:<port>`, waits for `GET /auth/callback?code&state`, returns a
/// close-window page, and yields the code+state. No embedded WebView, no helper
/// process — the system browser drives the flow and redirects here. Auto-stops.
public actor OAuthCallbackListener {
    public struct Callback: Sendable, Equatable {
        public let code: String
        public let state: String
    }

    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Callback, Error>?

    public init(port: UInt16 = CodexAuth.callbackPort) {
        self.port = port
    }

    /// Suspends until the redirect arrives (or `timeout` elapses / a bind error),
    /// then stops the listener.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> Callback {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Callback, Error>) in
            self.continuation = cont
            do {
                try startListener()
            } catch {
                finish(.failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutIfPending()
            }
        }
    }

    /// Cancels a pending wait (e.g. the user closed the sign-in sheet).
    public func stop() {
        finish(.failure(CancellationError()))
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TraceError.configInvalid(field: "port", reason: "invalid loopback port \(port)")
        }
        // Bind the port via `NWListener(using:on:)` ONLY — do NOT pin
        // `requiredLocalEndpoint` to `.ipv4(.loopback)`. OpenAI's fixed redirect is
        // `http://localhost:1455/...`, and macOS resolves `localhost` to `::1` (IPv6)
        // first; an IPv4-only listener never sees that connection → the browser gets
        // ERR_CONNECTION_REFUSED at the callback. Binding the port without a host
        // restriction listens on both 127.0.0.1 and ::1, so either resolution
        // connects. (Also removes the redundant double-port-set that logged
        // "cannot override to 1455".) The callback is still a single-use, state-
        // validated `code` over loopback, so accepting v6 loopback too is safe.
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw TraceError.networkFailed(
                provider: "codex-oauth",
                statusCode: nil,
                reason:
                    "Couldn't bind 127.0.0.1:\(port) — is another sign-in in progress? (\(error.localizedDescription))"
            )
        }
        let queue = DispatchQueue(label: "OAuthCallbackListener.\(port)")
        listener.newConnectionHandler = { connection in
            Task { [weak self] in await self?.serve(connection, queue: queue) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection, queue: DispatchQueue) async {
        connection.start(queue: queue)
        let data = await Self.receiveRequest(connection)
        let firstLine =
            String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .first
            .map(String.init) ?? ""
        if let callback = Self.parseCallback(requestLine: firstLine) {
            // Resume the waiter FIRST: a timeout firing while the (awaited) page
            // send is suspended must not win the race and report a spurious
            // timeout for a sign-in that actually succeeded. The page send is a
            // best-effort courtesy after the result is delivered.
            finish(.success(callback))
            await Self.send(
                Self.page(title: "Signed in", message: "You can close this window and return to Trace."), on: connection
            )
            connection.cancel()
        } else {
            // Ignore stray requests (favicon, etc.) and keep waiting.
            await Self.send(
                Self.page(title: "Not found", message: "Waiting for the sign-in redirect…", status: "404 Not Found"),
                on: connection)
            connection.cancel()
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        listener?.cancel()
        listener = nil
        cont.resume(with: result)
    }

    private func timeoutIfPending() {
        guard continuation != nil else { return }
        finish(
            .failure(TraceError.networkFailed(provider: "codex-oauth", statusCode: nil, reason: "Sign-in timed out")))
    }

    /// Parses the request line `GET /auth/callback?code=…&state=… HTTP/1.1` into
    /// the code + state.
    ///
    /// Pure + static for unit testing.
    public static func parseCallback(requestLine: String) -> Callback? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let pathAndQuery = String(parts[1])
        guard pathAndQuery.hasPrefix("/auth/callback?"),
            let comps = URLComponents(string: "http://127.0.0.1\(pathAndQuery)"),
            let code = comps.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
            let state = comps.queryItems?.first(where: { $0.name == "state" })?.value, !state.isEmpty
        else { return nil }
        return Callback(code: code, state: state)
    }

    /// A single read suffices: the OAuth redirect is a tiny `GET` whose request
    /// line + headers arrive in the first packet, and we only need the first line.
    ///
    /// (One receive also keeps the completion closure free of a captured mutable
    /// buffer, so it stays Sendable-clean.)
    private static func receiveRequest(_ connection: NWConnection) async -> Data {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, _, _ in
                continuation.resume(returning: chunk ?? Data())
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private static func page(title: String, message: String, status: String = "200 OK") -> Data {
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>\
            <style>body{font-family:-apple-system,system-ui;background:#0b0b0b;color:#eee;\
            display:flex;align-items:center;justify-content:center;height:100vh;margin:0}\
            .c{text-align:center}h1{font-size:18px;margin:0 0 8px}p{color:#aaa;margin:0}</style></head>\
            <body><div class="c"><h1>\(title)</h1><p>\(message)</p></div></body></html>
            """
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var out = Data(header.utf8)
        out.append(body)
        return out
    }
}
