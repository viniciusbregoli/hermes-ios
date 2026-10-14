import Foundation
import Testing
@testable import HermesKit

private func live(_ id: String, key: String, status: String, preview: String = "", at: Double = 100) -> LiveSession {
    LiveSession(id: id, key: key, title: "", preview: preview, status: status, lastActive: Date(timeIntervalSince1970: at))
}

@MainActor
struct StatusAndUnreadTests {
    func store() -> (ChatStore, ActivityStore) {
        let gateway = Gateway(credentials: nil)
        let chats = ChatStore(gateway: gateway, defaults: UserDefaults(suiteName: "StatusAndUnreadTests.\(UUID())")!)
        chats.applySessions(["sessions": [["id": "a"], ["id": "b"]]])
        return (chats, ActivityStore(gateway: gateway, chats: chats))
    }

    @Test func aChatThatFinishesWhileAnotherIsOpenBecomesUnread() {
        let (chats, activity) = store()
        chats.apply(snapshot: ["session_id": "rt-a", "info": ["stored_session_id": "a"]])
        activity.trackFinished([live("rt-a", key: "a", status: "idle"), live("rt-b", key: "b", status: "working")])
        #expect(chats.unread.isEmpty)

        activity.trackFinished([live("rt-a", key: "a", status: "idle"), live("rt-b", key: "b", status: "idle", at: 250)])
        #expect(chats.unread == ["b": Date(timeIntervalSince1970: 250)])
        #expect(ActivityFold.items({ var s = ActivitySnapshot(); s.chats = ["b": "B"]; s.chatUnread = chats.unread; return s }()).map(\.section) == [.done])

        // Opening the chat clears the mark.
        let (reopened, _) = store()
        reopened.unread = chats.unread
        reopened.apply(snapshot: ["session_id": "rt-b", "info": ["stored_session_id": "b"]])
        reopened.onScreen = true
        #expect(reopened.unread.isEmpty)
    }

    @Test func theOpenChatAndChatsSeenToFinishAreLeftAlone() {
        let (chats, activity) = store()
        chats.apply(snapshot: ["session_id": "rt-a", "info": ["stored_session_id": "a"]])
        activity.trackFinished([live("rt-a", key: "a", status: "working")])
        activity.trackFinished([live("rt-a", key: "a", status: "idle")])
        #expect(chats.unread.isEmpty, "the open chat marks itself from its own event stream")

        chats.watchedEnds["b"] = Date(timeIntervalSince1970: 200)
        chats.markFinished("b", at: Date(timeIntervalSince1970: 198))
        #expect(chats.unread.isEmpty, "the user watched it end")
        chats.markFinished("b", at: Date(timeIntervalSince1970: 300))
        #expect(chats.unread.keys.contains("b"))
    }

    @Test func onlyBusyToIdleCountsAsFinished() {
        let before = ["rt-1": "working", "rt-2": "idle", "rt-3": "waiting", "rt-4": "starting", "rt-5": "working"]
        let now = [live("rt-1", key: "a", status: "idle"), live("rt-2", key: "b", status: "idle"), live("rt-3", key: "c", status: "working"),
                   live("rt-4", key: "d", status: "idle"), live("rt-6", key: "e", status: "idle"), live("rt-7", key: "", status: "idle")]
        #expect(ActivityFold.finished(before: before, now: now).map(\.id) == ["rt-1", "rt-4"])
    }

    @Test func rowStatusMapsLiveSessions() {
        let rows = ChatLive.rows([
            live("rt-1", key: "work", status: "working", preview: "**bold** reply"),
            live("rt-2", key: "start", status: "starting"),
            live("rt-3", key: "ask", status: "waiting"),
            live("rt-4", key: "idle", status: "idle", preview: "done"),
            live("rt-5", key: "work", status: "idle", preview: "older", at: 50),
            live("rt-6", key: "", status: "working"),
        ])
        #expect(rows["work"]?.status == .working && rows["work"]?.lastActive == Date(timeIntervalSince1970: 100))
        #expect(rows["start"]?.status == .working && rows["ask"]?.status == .needsYou)
        #expect(rows["idle"]?.status == nil)
        #expect(rows.count == 4)
    }

    @Test func liveRowsAreCleanedAndHandedToTheChatStores() {
        let parsed = LiveSession.parse([["id": "rt", "session_key": "a", "status": "working",
                                         "preview": "[ASYNC DELEGATION BATCH COMPLETE - deleg_1] A background fan-out", "last_active": 5]])
        #expect(parsed.first?.preview == "Delegated work finished")
        let (chats, activity) = store()
        activity.trackFinished(parsed)
        #expect(chats.live["a"]?.status == .working)
    }

    @Test func rowsShowTheLatestReplyOnceSeen() {
        let (chats, activity) = store()
        let row = SessionRow(id: "a", title: "A", preview: "first prompt", startedAt: Date(), messageCount: 2)
        #expect(chats.preview(of: row) == "first prompt")
        activity.trackFinished([live("rt", key: "a", status: "working", preview: "stale")])
        #expect(chats.preview(of: row) == "first prompt", "a working row's message may still be the prompt")
        activity.trackFinished([live("rt", key: "a", status: "idle", preview: "the answer")])
        #expect(chats.preview(of: row) == "the answer")
        // The chat leaves the live list; the reply stays.
        activity.trackFinished([])
        #expect(chats.preview(of: row) == "the answer")

        chats.apply(snapshot: ["session_id": "rt-b", "info": ["stored_session_id": "b"]])
        chats.gateway.dispatch(GatewayEvent(type: "message.complete", sessionId: "rt-b", payload: ["text": "**Done** here", "status": "complete"]))
        #expect(chats.replies["b"] == "Done here")
    }

    @Test func previewsLoseMarkdownAndHarnessText() {
        #expect(Preview.clean("**use Proton Pass CLI** to `read` the [docs](https://x.y)\n\n- one\n- two") == "use Proton Pass CLI to read the docs - one - two")
        #expect(Preview.clean("[IMPORTANT: You are running as a scheduled cron job. DELIVERY: your reply") == "Routine run")
        #expect(Preview.clean("Use your delegate_tiered tool with tier \"light\" for this task, then report") == "Delegated task")
        #expect(Preview.clean("Use your delegate_task tool to hand this task to a subagent, then report its result: x") == "Delegated task")
        #expect(Preview.clean("[Background process proc_1 heartbeat #2 still running]") == "")
        #expect(Preview.clean("  plain text \n") == "plain text")
        #expect(Preview.clean("**Done: the automation now labels `mail") == "Done: the automation now labels mail")
    }

    @Test func rowsCarryLastActivityAndCleanPreviews() {
        let rows = SessionRow.parse([["id": "a", "preview": "**hi** there", "started_at": 100, "last_active": 900],
                                     ["id": "b", "started_at": 100], ["id": "c", "started_at": 500, "last_active": 200]])
        #expect(rows[0].preview == "hi there" && rows[0].activity == Date(timeIntervalSince1970: 900))
        #expect(rows[1].activity == Date(timeIntervalSince1970: 100))
        #expect(rows[2].activity == Date(timeIntervalSince1970: 500))
        #expect(ChatStore.lastActive(["sessions": [["id": "a", "last_active": 9], ["id": "a", "last_active": 1], ["id": "b"]]]) == ["a": Date(timeIntervalSince1970: 9)])
    }

    @Test func aFinishedTurnBumpsTheRowsActivity() {
        let (chats, _) = store()
        chats.apply(snapshot: ["session_id": "rt-a", "info": ["stored_session_id": "a"]])
        #expect(chats.sessions.first { $0.id == "a" }?.lastActive == nil)
        chats.gateway.dispatch(GatewayEvent(type: "message.complete", sessionId: "rt-a", payload: ["text": "ok", "status": "complete"]))
        #expect(chats.sessions.first { $0.id == "a" }?.lastActive != nil)
    }
}
