import Foundation
import Testing
@testable import HermesKit

@MainActor
struct UnreadTests {
    func freshDefaults(_ name: String) -> UserDefaults {
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    @Test func chatMarksSurviveARelaunchUntilTheChatIsGone() {
        let defaults = freshDefaults("UnreadTests.chats")
        let gateway = Gateway(credentials: nil)
        let store = ChatStore(gateway: gateway, defaults: defaults)
        store.apply(snapshot: ["session_id": "rt", "info": ["stored_session_id": "s1"]])
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt", payload: nil))
        gateway.dispatch(GatewayEvent(type: "message.complete", sessionId: "rt", payload: ["text": "done", "status": "complete"]))

        let relaunched = ChatStore(gateway: Gateway(credentials: nil), defaults: defaults)
        #expect(Set(relaunched.unread.keys) == ["s1"])
        #expect(ChatStore(gateway: gateway, profile: "research", defaults: defaults).unread.isEmpty)

        relaunched.applySessions(["sessions": [["id": "s1"], ["id": "s2"]]])
        #expect(Set(ChatStore(gateway: gateway, defaults: defaults).unread.keys) == ["s1"])
        relaunched.applySessions(["sessions": [["id": "s2"]]])
        #expect(ChatStore(gateway: gateway, defaults: defaults).unread.isEmpty)
    }

    @Test func botMarksSurviveARelaunch() {
        let defaults = freshDefaults("UnreadTests.bots")
        let gateway = Gateway(credentials: nil)
        let bots = BotStore(gateway: gateway, defaults: defaults)
        bots.track(runtime: "rt", bot: "research", running: true)
        gateway.dispatch(GatewayEvent(type: "message.complete", sessionId: "rt", payload: ["text": "done"]))
        #expect(Set(BotStore(gateway: gateway, defaults: defaults).unread.keys) == ["research"])

        bots.visibleBot = "research"
        #expect(BotStore(gateway: gateway, defaults: defaults).unread.isEmpty)
    }
}
