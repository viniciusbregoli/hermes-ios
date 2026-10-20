import CryptoKit
import Foundation
import Observation

/// Who drives a bot's screen (`display.lease`). `epoch` moves on every real transition, so an older
/// snapshot that arrives late can be told apart from the current one.
public struct ScreenLease: Equatable, Sendable {
    public let human: Bool
    /// First 12 hex of sha256(viewer id) of the holding viewer; the raw id never leaves the gateway.
    public let viewerHash: String?
    public let epoch: Int

    init?(_ json: JSON?) {
        guard let json, let holder = json["holder"]?.string else { return nil }
        human = holder == "human"
        viewerHash = json["viewer_hash"]?.string
        epoch = json["epoch"]?.int ?? 0
    }
}

/// `display.status`: a bot's headless desktop on the gateway host (Bot Screen).
public struct ScreenStatus: Equatable, Sendable {
    public let supported: Bool
    public let installed: Bool
    public let running: Bool
    public let missing: [String]
    public let display: String?
    public let geometry: String
    public let installCommand: String?
    /// Why `display.start` would refuse now (host memory).
    public let blocker: String?
    let profileKey: String

    init(_ json: JSON) {
        supported = json["supported"]?.bool ?? false
        installed = json["installed"]?.bool ?? false
        running = json["running"]?.bool ?? false
        missing = json["missing"]?.array?.compactMap(\.string) ?? []
        display = json["display"]?.string
        geometry = json["geometry"]?.string ?? ""
        installCommand = json["install_command"]?.string?.nonEmpty
        blocker = json["blocker"]?.string?.nonEmpty
        profileKey = json["profile_key"]?.string ?? ""
    }
}

/// A bot's screen and its takeover lease, the way Hermes Desktop's Screen pane drives them: `display.observe`
/// mints a single-use ticket for the RFB stream, `display.lease.acquire` / `release` are Take over / Hand back.
@MainActor @Observable
public final class ScreenStore {
    public let gateway: Gateway
    public let profile: String?
    public private(set) var status: ScreenStatus?
    public private(set) var lease: ScreenLease?
    /// The bot's Hermes has no `display.*` methods.
    public private(set) var unavailable = false
    public var error: String?
    /// The viewer id `display.observe` minted for this connection, and its lease hash.
    private var viewer: (id: String, hash: String)?

    public init(gateway: Gateway, profile: String?) {
        self.gateway = gateway
        self.profile = profile == "default" ? nil : profile
        gateway.listen(self, event: { [weak self] e in self?.handle(e) },
                       // Minted ids belong to the connection that minted them; a new one starts over.
                       connected: { [weak self] in self?.viewer = nil; Task { await self?.refresh() } })
    }

    /// I took over and still hold control.
    public var iHold: Bool { lease?.human == true && viewer != nil && lease?.viewerHash == viewer?.hash }
    /// A human holds control from another viewer (or from this app before a reconnect).
    public var otherHolds: Bool { lease?.human == true && !iHold }

    public func refresh() async {
        do {
            apply(try await call("display.status"))
            error = nil
        } catch GatewayError.rpc(-32601, _) {
            unavailable = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func start() async {
        do { apply(try await call("display.start")) } catch { self.error = error.localizedDescription }
    }

    /// A fresh `wss://` URL for the RFB stream. The ticket is single-use and expires in 30 s, so mint one per dial.
    public func observe() async throws -> URL {
        let result = try await call("display.observe", viewer.map { ["viewer_id": .string($0.id)] } ?? [:])
        guard let id = result["viewer_id"]?.string, let ticket = result["ticket"]?.string,
              let base = gateway.credentials?.baseURL else { throw GatewayError.offline }
        viewer = (id, Self.hash(id))
        apply(result)
        return Self.socketURL(base: base, path: result["path"]?.string ?? "/api/display/ws", ticket: ticket)
    }

    public func takeOver() async {
        guard let viewer else { return }
        await lease("display.lease.acquire", ["viewer_id": .string(viewer.id)])
    }

    /// `force` frees a lease this app can no longer name (another viewer's, or ours from before a reconnect).
    public func handBack(force: Bool = false) async {
        if force {
            await lease("display.lease.release", ["force": true])
        } else if let viewer {
            await lease("display.lease.release", ["viewer_id": .string(viewer.id)])
        }
    }

    private func lease(_ method: String, _ params: [String: JSON]) async {
        do {
            if let lease = ScreenLease(try await call(method, params)["lease"]) { apply(lease) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func call(_ method: String, _ params: [String: JSON] = [:]) async throws -> JSON {
        try await gateway.call(method, params.merging(["profile": .string(profile ?? "default")]) { a, _ in a })
    }

    func handle(_ e: GatewayEvent) {
        // Every profile's screen broadcasts to every client; the profile key says whose this is.
        guard e.type.hasPrefix("display."), let key = status?.profileKey,
              e.payload["profile_key"]?.string == key else { return }
        switch e.type {
        case "display.lease": if let lease = ScreenLease(e.payload["lease"]) { apply(lease) }
        case "display.status": apply(e.payload)
        default: break
        }
    }

    private func apply(_ json: JSON) {
        status = ScreenStatus(json)
        if let lease = ScreenLease(json["lease"]) { apply(lease) }
    }

    private func apply(_ next: ScreenLease) {
        // A status reply overtaken by a lease event describes the past.
        if let lease, next.epoch < lease.epoch { return }
        lease = next
    }

    static func hash(_ viewerId: String) -> String {
        SHA256.hash(data: Data(viewerId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    static func socketURL(base: URL, path: String, ticket: String) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = path
        parts.queryItems = [URLQueryItem(name: "display_ticket", value: ticket)]
        return parts.url!
    }
}
