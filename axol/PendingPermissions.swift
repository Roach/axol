import Foundation
import Network

/// In-flight permission requests waiting on a user decision. Claude Code's
/// PermissionRequest hook is an HTTP POST whose *response body* carries the
/// Allow/Deny decision — so we hold the NWConnection open from Server.handle
/// until the user clicks a bubble button, then write the CC-shaped JSON
/// response and close.
///
/// MVP scope: Allow/Deny only, no "Always" / updatedPermissions, no session
/// tracking, no timeout.
final class PendingPermissions {
    static let shared = PendingPermissions()

    private var pending: [String: NWConnection] = [:]
    private let lock = NSLock()

    func register(requestId: String, connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        pending[requestId] = connection
    }

    /// Writes the Claude Code permission response and closes the connection.
    /// No-op if the id has already been resolved (double-click, abort race).
    func resolve(requestId: String, behavior: String) {
        lock.lock()
        let conn = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let conn = conn else { return }

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": behavior]
            ]
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: application/json\r\n" +
                     "Content-Length: \(body.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var data = header.data(using: .utf8) ?? Data()
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Connection died before the user answered — discard the entry so a
    /// later click is a silent no-op rather than a send on a dead socket.
    func discard(requestId: String) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: requestId)
    }
}
