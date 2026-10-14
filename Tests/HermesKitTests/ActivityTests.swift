import Foundation
import Testing
@testable import HermesKit

private func live(_ id: String, key: String, status: String, title: String = "", at: Double = 0) -> LiveSession {
    LiveSession(id: id, key: key, title: title, preview: "latest\nmore", status: status, lastActive: Date(timeIntervalSince1970: at))
}

private func prompt(_ id: String, session: String, method: String = "approval", _ params: [String: JSON] = ["command": "rm -rf /tmp/x"]) -> ServerRequest {
    ServerRequest(rpcId: .string(id), method: method, params: .object(params.merging(["session_id": .string(session)]) { a, _ in a }))
}

@MainActor
struct ActivityTests {
    @Test func sortsBySectionThenNewestFirst() {
        var s = ActivitySnapshot()
        s.live = [live("rt-a", key: "a", status: "waiting", at: 10), live("rt-b", key: "b", status: "working", at: 20),
                  live("rt-c", key: "c", status: "idle", at: 30)]
        s.inbox = [prompt("srq-1", session: "rt-a")]
        s.chats = ["a": "Deploy", "b": "Refactor", "c": "Idle", "d": "Old", "e": "Newer"]
        s.open = .init(stored: "b", runtime: "rt-b", startedAt: Date(timeIntervalSince1970: 15), subagents: 2)
        s.open.tasks = [("t1", "summarize logs", Date(timeIntervalSince1970: 5))]
        s.chatUnread = ["d": Date(timeIntervalSince1970: 1), "e": Date(timeIntervalSince1970: 2)]

        let items = ActivityFold.items(s)
        #expect(items.map(\.id) == ["need-srq-1", "work-rt-b", "subagents-b", "bg-t1", "done-e", "done-d"])
        #expect(items.map(\.section) == [.needsYou, .working, .background, .background, .done, .done])
        #expect(items[0].detail == "rm -rf /tmp/x" && items[0].title == "Deploy")
        #expect(items[1].kind == .working(startedAt: Date(timeIntervalSince1970: 15)) && items[1].detail == "latest")
        #expect(items[2].kind == .background(.subagents(2)) && items[3].detail == "summarize logs")
    }

    @Test func mapsSessionKeysToChatsAndBots() {
        var s = ActivitySnapshot()
        s.live = [live("rt-1", key: "chat-1", status: "working"), live("rt-2", key: "bot-chat", status: "working"),
                  live("rt-3", key: "elsewhere", status: "starting", title: "Other profile"),
                  live("rt-4", key: "untracked", status: "working")]
        s.chats = ["chat-1": "Groceries"]
        s.botChats = ["bot-chat": "research"]
        s.botRuntimes = ["rt-4": "homelab"]
        s.botLabels = ["research": "Research Buddy", "homelab": "Homelab"]

        let byId = Dictionary(uniqueKeysWithValues: ActivityFold.items(s).map { ($0.id, $0) })
        #expect(byId["work-rt-1"]?.target == .chat("chat-1") && byId["work-rt-1"]?.title == "Groceries")
        #expect(byId["work-rt-2"]?.target == .bot("research") && byId["work-rt-2"]?.title == "Research Buddy")
        #expect(byId["work-rt-3"]?.target == nil && byId["work-rt-3"]?.title == "Other profile")
        #expect(byId["work-rt-4"]?.target == .bot("homelab"))
    }

    @Test func waitingRowWithAParkedPromptNeedsYou() {
        var s = ActivitySnapshot()
        s.live = [live("rt-1", key: "chat-1", status: "waiting")]
        s.chats = ["chat-1": "Groceries"]
        s.inbox = [prompt("srq-1", session: "rt-1", method: "clarify", ["questions": [["qid": "q", "question": "Which store?"]]])]
        s.fetched = s.inbox

        let items = ActivityFold.items(s)
        #expect(items.count == 1)
        #expect(items[0].kind == .needsYou(.request(s.inbox[0])) && items[0].detail == "Which store?")
        #expect(items[0].target == .chat("chat-1"))
    }

    @Test func waitingRowWithoutItsPromptStaysWorking() {
        var s = ActivitySnapshot()
        s.live = [live("rt-1", key: "chat-1", status: "waiting")]
        #expect(ActivityFold.items(s).map(\.section) == [.working])
    }

    @Test func reconcileDropsPromptsTheServerNoLongerLists() {
        let gateway = Gateway(credentials: nil)
        let kept = prompt("srq-1", session: "rt-1"), answered = prompt("srq-2", session: "rt-1")
        let gone = prompt("srq-3", session: "rt-dead"), unchecked = prompt("srq-4", session: "rt-2")
        gateway.park([kept, answered, gone, unchecked])

        let stale = ActivityFold.stale(inbox: gateway.inbox, open: ["rt-1": [kept]], live: ["rt-1", "rt-2"])
        #expect(stale == ["srq-2", "srq-3"])
        gateway.withdraw(stale)
        #expect(gateway.inbox.map(\.id) == ["srq-1", "srq-4"])
    }

    @Test func unreadChatsBotsAndRoomsAreDoneUnlessBusy() {
        var s = ActivitySnapshot()
        s.live = [live("rt-1", key: "busy", status: "working")]
        s.chats = ["busy": "Busy", "quiet": "Quiet"]
        s.chatUnread = ["busy": Date(timeIntervalSince1970: 3), "quiet": Date(timeIntervalSince1970: 2)]
        s.botUnread = ["research": Date(timeIntervalSince1970: 1)]
        let room = Room(id: "r1", name: "Ops", members: [], updatedAt: Date(timeIntervalSince1970: 4))
        s.rooms = [room]
        s.roomUnread = ["r1"]

        let done = ActivityFold.items(s).filter { $0.section == .done }
        #expect(done.map(\.target) == [.room("r1"), .chat("quiet"), .bot("research")])
        #expect(done[1].kind == .done(unread: Date(timeIntervalSince1970: 2)))
    }

    @Test func roomApprovalsNeedYouAndWorkingRoomsAreWorking() {
        var s = ActivitySnapshot()
        let ops = Room(id: "r1", name: "Ops", members: []), lab = Room(id: "r2", name: "Lab", members: [])
        let action = RoomAction(kind: .approval, taskId: "t", requestId: "q", approval: ["command": "reboot"])
        s.rooms = [ops, lab]
        s.roomStatus = ["r1": (true, [action]), "r2": (true, [])]

        let items = ActivityFold.items(s)
        #expect(items.map(\.kind) == [.needsYou(.room(action)), .working(startedAt: nil)])
        #expect(items[0].detail == "reboot" && items[1].target == .room("r2"))
    }

    @Test func countsWhatNeedsYouAcrossTheOpenChatAndTheInbox() {
        let gateway = Gateway(credentials: nil)
        let chats = ChatStore(gateway: gateway, defaults: UserDefaults(suiteName: "ActivityTests")!)
        chats.apply(snapshot: ["session_id": "rt-open", "info": ["stored_session_id": "s1"], "open_requests": [
            ["id": "srq-1", "method": "approval", "params": ["session_id": "rt-open", "command": "ls"]],
        ]])
        gateway.park([prompt("srq-2", session: "rt-left", method: "sudo")])
        let activity = ActivityStore(gateway: gateway, chats: chats)

        #expect(activity.needsYouCount == 2)
        #expect(activity.items.first { $0.id == "need-srq-1" }?.target == .chat("s1"))
    }
}
