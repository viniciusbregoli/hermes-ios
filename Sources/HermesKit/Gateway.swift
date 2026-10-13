import Foundation
import Observation

public struct GatewayEvent: Sendable {
    public let type: String
    /// Runtime session id; empty for global broadcasts.
    public let sessionId: String
    public let payload: JSON
}

/// A request the server sends us (approval, clarify, sudo, ...). Answer it with `Gateway.respond`.
public struct ServerRequest: Identifiable, Sendable {
    public let rpcId: JSON
    public let method: String
    public let params: JSON
    public var id: String { params["request_id"]?.string ?? rpcId.string ?? "" }
    public var sessionId: String { params["session_id"]?.string ?? "" }
}

public enum GatewayError: LocalizedError {
    case offline, disconnected, rpc(Int, String)

    public var code: Int? { if case .rpc(let c, _) = self { return c }; return nil }
    public var errorDescription: String? {
        switch self {
        case .offline: "Not connected to Hermes."
        case .disconnected: "Connection lost."
        case .rpc(_, let message): message
        }
    }
}

/// JSON-RPC 2.0 over the gateway WebSocket (`/api/ws`), the transport Hermes Desktop uses.
@MainActor @Observable
public final class Gateway {
    public enum Status: Equatable { case offline, connecting, online, signedOut }

    public private(set) var status: Status = .offline
    public private(set) var lastError: String?
    public var credentials: Credentials? {
        didSet { if credentials != oldValue { Keychain.save(credentials) } }
    }

    @ObservationIgnored public var onEvent: (GatewayEvent) -> Void = { _ in }
    @ObservationIgnored public var onRequest: (ServerRequest) -> Void = { _ in }
    /// Fires after every successful handshake, including reconnects.
    @ObservationIgnored public var onConnected: () -> Void = {}

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var pending: [String: CheckedContinuation<JSON, Error>] = [:]
    @ObservationIgnored private var counter = 0
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lastInbound = Date()
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var wanted = false

    public init(credentials: Credentials?) {
        self.credentials = credentials
        if credentials == nil { status = .signedOut }
    }

    /// Connect now if we are not already; safe to call on every foreground.
    public func start() {
        wanted = true
        guard status == .offline || status == .signedOut, credentials != nil else { return }
        attempt = 0
        Task { await connect() }
    }

    public func signOut() {
        wanted = false
        teardown(GatewayError.offline)
        credentials = nil
        status = .signedOut
    }

    public func call(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        guard let ws = socket, status == .online else { throw GatewayError.offline }
        counter += 1
        let id = "r\(counter)"
        let frame: JSON = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": .object(params)]
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(frame, on: ws) { [weak self] error in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    public func respond(_ request: ServerRequest, result: JSON) {
        guard let ws = socket else { return }
        send(["jsonrpc": "2.0", "id": request.rpcId, "result": result], on: ws) { _ in }
    }

    public func reject(_ request: ServerRequest, code: Int = 4404, message: String = "not shown on mobile") {
        guard let ws = socket else { return }
        send(["jsonrpc": "2.0", "id": request.rpcId, "error": ["code": .number(Double(code)), "message": .string(message)]], on: ws) { _ in }
    }

    // MARK: - Connection

    private func connect() async {
        guard var creds = credentials else { status = .signedOut; return }
        status = .connecting
        do {
            let ticket: String
            do {
                ticket = try await Auth.wsTicket(creds)
            } catch AuthError.expired {
                creds = try await Auth.refresh(creds)
                credentials = creds
                ticket = try await Auth.wsTicket(creds)
            }
            var comps = URLComponents(url: creds.baseURL.appending(path: "api/ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = comps.scheme == "http" ? "ws" : "wss"
            comps.queryItems = [.init(name: "ticket", value: ticket)]
            let ws = URLSession.shared.webSocketTask(with: comps.url!)
            ws.maximumMessageSize = 64 << 20
            socket = ws
            lastInbound = Date()
            ws.resume()
            Task { await receiveLoop(ws) }
            // The handshake finishes when `gateway.ready` arrives (see `handle`).
        } catch AuthError.expired {
            credentials = nil
            status = .signedOut
        } catch {
            lastError = error.localizedDescription
            status = .offline
            scheduleReconnect()
        }
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await ws.receive()
                guard ws === socket else { return }
                lastInbound = Date()
                switch message {
                case .string(let s): handle(Data(s.utf8))
                case .data(let d): handle(d)
                @unknown default: break
                }
            } catch {
                guard ws === socket else { return }
                lastError = error.localizedDescription
                teardown(GatewayError.disconnected)
                status = .offline
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let msg = try? JSON.parse(data) else { return }
        if let method = msg["method"]?.string {
            if let id = msg["id"], !id.isNull {
                onRequest(ServerRequest(rpcId: id, method: method, params: msg["params"] ?? .null))
            } else if method == "event", let p = msg["params"] {
                let event = GatewayEvent(type: p["type"]?.string ?? "", sessionId: p["session_id"]?.string ?? "",
                                         payload: p["payload"] ?? .null)
                if event.type == "gateway.ready" { handshake() } else { onEvent(event) }
            }
            return
        }
        guard let id = msg["id"]?.string, let cont = pending.removeValue(forKey: id) else { return }
        if let err = msg["error"] {
            cont.resume(throwing: GatewayError.rpc(err["code"]?.int ?? 0, err["message"]?.string ?? "error"))
        } else {
            cont.resume(returning: msg["result"] ?? .null)
        }
    }

    private func handshake() {
        status = .online
        attempt = 0
        lastError = nil
        // Without this the server auto-declines every approval/clarify meant for this socket.
        Task { _ = try? await call("client.capabilities", ["server_requests": true]) }
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                // Same budget as the desktop: no traffic for 45 s means the socket is dead.
                if Date().timeIntervalSince(self.lastInbound) > 45 {
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    return
                }
                Task { _ = try? await self.call("gateway.ping") }
            }
        }
        onConnected()
    }

    private func teardown(_ error: Error) {
        pingTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func scheduleReconnect() {
        guard wanted else { return }
        attempt += 1
        // Full-jitter exponential backoff, 300 ms base, 15 s cap (matches the desktop).
        let cap = min(15.0, 0.3 * pow(2, Double(attempt)))
        let delay = Double.random(in: 0...cap)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if wanted, status == .offline { await connect() }
        }
    }

    private func send(_ frame: JSON, on ws: URLSessionWebSocketTask, onError: @escaping @MainActor (Error) -> Void) {
        guard let data = try? frame.data() else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task { do { try await ws.send(.string(text)) } catch { onError(error) } }
    }
}
