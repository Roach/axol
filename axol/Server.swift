import Cocoa
import Network

/// HTTP listener bound to 127.0.0.1. Accepts loopback-only connections —
/// remote connect attempts are dropped by `isLoopback`. One connection per
/// POST; parses headers + body, decodes JSON, and hands the payload to
/// `onEvent` on the main queue. Always replies `204 No Content` regardless
/// of what the caller sent; the adapter/validator pipeline decides whether
/// an event actually surfaces as a bubble.
final class AxolServer {
    private var listener: NWListener?
    private let onEvent: ([String: Any]) -> Void
    /// Invoked for POST /permission. The connection is handed over held-open
    /// — the handler is responsible for eventually resolving it via
    /// PendingPermissions.resolve (or discard) so the request line doesn't
    /// leak. Called on the server queue; the handler should hop to main.
    private let onPermission: ((String, [String: Any], NWConnection) -> Void)?
    private let queue = DispatchQueue(label: "axol.server")

    init(onEvent: @escaping ([String: Any]) -> Void,
         onPermission: ((String, [String: Any], NWConnection) -> Void)? = nil) {
        self.onEvent = onEvent
        self.onPermission = onPermission
    }

    func start(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self else { conn.cancel(); return }
                if Self.isLoopback(conn) {
                    self.handle(conn)
                } else {
                    conn.cancel()
                }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("axol: listener failed: \(String(describing: err))")
                }
            }
            l.start(queue: queue)
            listener = l
            NSLog("axol: listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("axol: could not start server on port \(port): \(error)")
        }
    }

    private static func isLoopback(_ conn: NWConnection) -> Bool {
        if case let .hostPort(host: host, port: _) = conn.endpoint {
            switch host {
            case .ipv4(let addr): return addr == .loopback
            case .ipv6(let addr): return addr == .loopback
            default: return false
            }
        }
        return false
    }

    /// Cap on how much we'll buffer per connection before giving up. Real
    /// callers (adapters, webhook bodies) fit comfortably under 100 KB; 1 MB
    /// is generous headroom that still bounds worst-case memory when a
    /// malicious or broken client slow-drips a request that never terminates.
    private static let maxRequestBytes = 1_000_000

    private func handle(_ conn: NWConnection) {
        var buffer = Data()
        conn.start(queue: queue)
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data, !data.isEmpty { buffer.append(data) }
                if buffer.count > Self.maxRequestBytes {
                    conn.cancel()
                    return
                }
                if let parsed = Self.parseHTTP(buffer) {
                    if var json = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: Any] {
                        if let pidStr = parsed.headers["x-claude-pid"], let pid = Int(pidStr) {
                            json["claude_pid"] = pid
                        }
                        if parsed.path == "/permission", let onPermission = self.onPermission {
                            let requestId = (json["request_id"] as? String) ?? UUID().uuidString
                            let reqJson = json
                            DispatchQueue.main.async { onPermission(requestId, reqJson, conn) }
                            // Keep a sentinel read running so peer-close fires
                            // — Claude Code still prompts in-terminal in
                            // parallel with the PermissionRequest hook, and
                            // when the user answers in CC it kills the hook
                            // subprocess, closing curl's socket. Without an
                            // active read, NWConnection won't surface that
                            // close and the Axol bubble would stay up. On
                            // peer EOF / error we cancel, which fires the
                            // existing stateUpdateHandler → dismissPermissionBubble.
                            Self.watchForPeerClose(conn)
                            return  // connection stays open until resolve/discard
                        }
                        DispatchQueue.main.async { self.onEvent(json) }
                    }
                    let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    /// Keep an idle receive posted on a held-open permission connection so
    /// the kernel surfaces peer EOF as a receive callback — without it,
    /// NWConnection sits in `.ready` even after curl closes, and the bubble
    /// only dismisses when the user clicks Allow/Deny. Any bytes, error, or
    /// isComplete=true all mean "drop the connection" — there's no valid
    /// follow-up traffic on a single-shot POST.
    private static func watchForPeerClose(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            conn.cancel()
        }
    }

    private static func parseHTTP(_ data: Data) -> (headers: [String: String], body: Data, path: String)? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: 0..<r.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        var contentLength = 0
        var path = ""
        let lines = headerStr.components(separatedBy: "\r\n")
        if let first = lines.first {
            // Request line: METHOD SP PATH SP HTTP/1.x
            let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count >= 2 {
                path = parts[1]
                if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            }
        }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                headers[k] = v
                if k == "content-length" { contentLength = Int(v) ?? 0 }
            }
        }
        // Reject absurd or negative Content-Length outright — stops a
        // declared 9GB body from pinning the reader indefinitely.
        guard contentLength >= 0, contentLength <= maxRequestBytes else { return nil }
        let bodyStart = r.upperBound
        if data.count - bodyStart < contentLength { return nil }
        return (headers, data.subdata(in: bodyStart..<(bodyStart + contentLength)), path)
    }
}

/// NSWindow subclass that can take keyboard focus but never becomes the
/// application's "main" window — keeps Axol out of the active-window
/// chain so she doesn't steal focus from the terminal or editor the user
/// was just in.
class AxolWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
