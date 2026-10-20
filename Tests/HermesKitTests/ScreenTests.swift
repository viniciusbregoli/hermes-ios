import Foundation
import Testing
@testable import HermesKit

@MainActor
struct ScreenTests {
    // Assigned in init, so the credentials never reach the keychain.
    let gateway = Gateway(credentials: Credentials(baseURL: URL(string: "https://bot.example.ts.net:8447")!, username: "u",
                                                   accessToken: "a", refreshToken: "r", provider: "basic"))

    static func status(holder: String = "agent", hash: JSON = nil, epoch: Int = 1, running: Bool = true) -> [String: JSON] {
        ["supported": true, "installed": true, "running": .bool(running), "missing": [], "display": ":20",
         "geometry": "1440x900", "profile_key": "/home/m/.hermes/profiles/bills",
         "lease": ["holder": .string(holder), "viewer_hash": hash, "since": 1, "epoch": .number(Double(epoch))]]
    }

    @Test func socketURLSwapsSchemeAndPathAndCarriesTheTicket() {
        let url = ScreenStore.socketURL(base: URL(string: "https://h.ts.net:8447")!, path: "/api/display/ws", ticket: "t k")
        #expect(url.absoluteString == "wss://h.ts.net:8447/api/display/ws?display_ticket=t%20k")
        #expect(ScreenStore.socketURL(base: URL(string: "http://127.0.0.1:9119")!, path: "/p", ticket: "t").scheme == "ws")
        #expect(ScreenStore.socketURL(base: URL(string: "https://h/hermes")!, path: "/api/display/ws", ticket: "t").path
                == "/hermes/api/display/ws")
    }

    @Test func viewerHashIsTheFirst12HexOfSha256() {
        #expect(ScreenStore.hash("abc") == "ba7816bf8f01")
    }

    @Test func takeOverActsForTheMintedViewerOfThatProfile() async throws {
        var seen: [(String, [String: JSON])] = []
        gateway.stub = { method, params in
            seen.append((method, params))
            switch method {
            case "display.observe":
                return .object(Self.status().merging(["viewer_id": "abc", "ticket": "tk", "path": "/api/display/ws"]) { a, _ in a })
            case "display.lease.acquire": return ["lease": ["holder": "human", "viewer_hash": "ba7816bf8f01", "epoch": 2]]
            default: return ["lease": ["holder": "agent", "epoch": 3]]
            }
        }
        let store = ScreenStore(gateway: gateway, profile: "bills")
        let url = try await store.observe()
        #expect(url.query == "display_ticket=tk")
        #expect(!store.iHold)
        await store.takeOver()
        #expect(seen[1].0 == "display.lease.acquire" && seen[1].1["viewer_id"] == "abc" && seen[1].1["profile"] == "bills")
        #expect(store.iHold && !store.otherHolds)
        await store.handBack()
        #expect(seen[2].1["viewer_id"] == "abc" && !store.iHold)
    }

    @Test func takeOverWithoutAViewerSaysSo() async {
        let store = ScreenStore(gateway: gateway, profile: nil)
        await store.takeOver()
        #expect(store.error != nil)
    }

    @Test func leaseEventsApplyOnlyToThisProfileAndNeverGoBack() async {
        gateway.stub = { _, _ in .object(Self.status(epoch: 5)) }
        let store = ScreenStore(gateway: gateway, profile: nil)
        await store.refresh()
        func lease(_ key: String, _ holder: String, _ epoch: Int) {
            gateway.dispatch(GatewayEvent(type: "display.lease", sessionId: "", payload:
                ["profile_key": .string(key), "lease": ["holder": .string(holder), "viewer_hash": "x", "epoch": .number(Double(epoch))]]))
        }
        lease("/home/m/.hermes", "human", 9)
        #expect(store.lease?.human == false)
        lease("/home/m/.hermes/profiles/bills", "human", 4)
        #expect(store.lease?.human == false)
        lease("/home/m/.hermes/profiles/bills", "human", 6)
        #expect(store.otherHolds)
    }

    @Test func summaryFollowsStatusAndLease() async {
        var reply = Self.status()
        gateway.stub = { _, _ in .object(reply) }
        let store = ScreenStore(gateway: gateway, profile: "bills")
        #expect(store.summary == nil)
        await store.refresh()
        #expect(store.summary == .live)
        reply = Self.status(holder: "human", hash: "x", epoch: 2)
        await store.refresh()
        #expect(store.summary == .other)
        reply = Self.status(epoch: 3, running: false)
        await store.refresh()
        #expect(store.summary == .off)
        reply["installed"] = false
        await store.refresh()
        #expect(store.summary == .missing)
        reply["supported"] = false
        await store.refresh()
        #expect(store.summary == nil)
    }

    @Test func aFailedFirstCheckStaysVisible() async {
        gateway.stub = { _, _ in throw GatewayError.disconnected }
        let store = ScreenStore(gateway: gateway, profile: nil)
        await store.refresh()
        #expect(store.summary == .failed)
    }

    @Test func defaultProfileIsSentByName() async {
        var profile: JSON?
        gateway.stub = { _, params in profile = params["profile"]; return .object(Self.status()) }
        await ScreenStore(gateway: gateway, profile: "default").refresh()
        #expect(profile == "default")
    }

    @Test func olderGatewayIsUnavailable() async {
        gateway.stub = { _, _ in throw GatewayError.rpc(-32601, "method not found") }
        let store = ScreenStore(gateway: gateway, profile: nil)
        await store.refresh()
        #expect(store.unavailable && store.error == nil)
    }
}
