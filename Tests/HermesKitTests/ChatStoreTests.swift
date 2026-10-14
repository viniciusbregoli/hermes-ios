import Testing
@testable import HermesKit

@MainActor
struct ChatStoreTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: [
            "session_id": "rt1",
            "running": false,
            "messages": [
                ["role": "user", "text": "hi", "row_id": 1],
                ["role": "assistant", "text": "hello", "reasoning": "greet", "row_id": 2],
                ["role": "tool", "name": "terminal", "context": "ls", "tool_call_id": "c0", "args": ["command": "ls"], "row_id": 3],
                ["role": "system", "text": "ignored"],
            ],
        ])
    }

    func emit(_ type: String, _ payload: JSON = nil, session: String = "rt1") {
        gateway.dispatch(GatewayEvent(type: type, sessionId: session, payload: payload))
    }

    @Test func snapshotMapsTranscript() {
        #expect(store.items.map(\.kind) == [.user, .assistant, .tool])
        #expect(store.items[1].reasoning == "greet")
        #expect(store.items[2].tool?.context == "ls")
        #expect(store.items[2].tool?.running == false)
    }

    @Test func streamedTurnInterleavesTextAndTools() {
        emit("message.start")
        emit("reasoning.delta", ["text": "plan"])
        emit("thinking.delta", ["text": "( •_•)>⌐■-■ brainstorming..."])
        emit("message.delta", ["text": "Run"])
        emit("message.delta", ["text": "ning"])
        emit("tool.start", ["tool_id": "c1", "name": "terminal", "context": "make"])
        #expect(store.items.last?.tool?.running == true)
        emit("tool.complete", ["tool_id": "c1", "name": "terminal", "summary": "exit 0", "duration_s": 1.5])
        emit("message.delta", ["text": "Done."])
        emit("message.delta", ["text": "ignored"], session: "other")
        emit("message.complete", ["text": "Running\nDone.", "status": "complete"])

        let turn = Array(store.items.dropFirst(3))
        #expect(turn.map(\.kind) == [.assistant, .tool, .assistant])
        #expect(turn[0].text == "Running" && turn[0].reasoning == "plan")
        #expect(turn[1].tool?.summary == "exit 0" && turn[1].tool?.running == false)
        #expect(turn[2].text == "Done.")
        #expect(turn.allSatisfy { !$0.streaming })
        #expect(store.running == false)
    }

    @Test func completeWithoutDeltasShowsFinalText() {
        store.apply(snapshot: ["session_id": "rt1", "messages": [["role": "user", "text": "again"]]])
        emit("message.start")
        emit("message.complete", ["text": "Answer", "status": "complete"])
        #expect(store.items.last?.kind == .assistant)
        #expect(store.items.last?.text == "Answer")
    }

    @Test func failedTurnAddsError() {
        emit("message.start")
        emit("message.complete", ["text": "", "status": "error", "error": "rate limited"])
        #expect(store.items.last?.kind == .error)
        #expect(store.items.last?.text == "rate limited")
    }

    @Test func approvalQueuedThenWithdrawn() {
        gateway.dispatch(ServerRequest(rpcId: "srq-1", method: "approval",
                                       params: ["session_id": "rt1", "request_id": "a1", "command": "rm x"]))
        gateway.dispatch(ServerRequest(rpcId: "srq-2", method: "preview.open", params: ["session_id": "rt1"]))
        gateway.dispatch(ServerRequest(rpcId: "srq-3", method: "approval", params: ["session_id": "other", "request_id": "a3"]))
        #expect(store.requests.map(\.id) == ["a1"])
        emit("approval.cancelled", ["request_id": "a1"])
        #expect(store.requests.isEmpty)
    }
}

@MainActor
struct GatewayRoutingTests {
    @Test func requestsGoToTheStoreShowingTheirSession() {
        let gateway = Gateway(credentials: nil)
        let a = ChatStore(gateway: gateway)
        let b = ChatStore(gateway: gateway)
        a.apply(snapshot: ["session_id": "rt-a"])
        b.apply(snapshot: ["session_id": "rt-b"])
        gateway.dispatch(ServerRequest(rpcId: "1", method: "approval", params: ["session_id": "rt-b", "request_id": "x"]))
        #expect(a.requests.isEmpty)
        #expect(b.requests.map(\.id) == ["x"])
    }

    @Test func releasedStoresStopListening() {
        let gateway = Gateway(credentials: nil)
        var store: ChatStore? = ChatStore(gateway: gateway)
        store?.apply(snapshot: ["session_id": "rt"])
        weak let weakStore = store
        store = nil
        #expect(weakStore == nil)
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt", payload: nil))
    }
}

@MainActor
struct InboxTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1"])
        gateway.dispatch(ServerRequest(rpcId: "srq-1", method: "approval", params: ["session_id": "rt-left", "request_id": "a1"]))
    }

    @Test func unclaimedPromptWaitsInTheInbox() {
        gateway.dispatch(ServerRequest(rpcId: "srq-2", method: "preview.open", params: ["session_id": "rt-left"]))
        #expect(store.requests.isEmpty)
        #expect(gateway.inbox.map(\.id) == ["a1"])
    }

    @Test func withdrawnPromptLeavesTheInbox() {
        gateway.dispatch(ServerRequest(rpcId: "srq-3", method: "clarify", params: ["session_id": "rt-left"]))
        gateway.dispatch(GatewayEvent(type: "request.cancel", sessionId: "rt-left", payload: ["id": "srq-1", "method": "approval", "reason": "timeout"]))
        #expect(gateway.inbox.map(\.id) == ["srq-3"])
        gateway.dispatch(GatewayEvent(type: "request.cancel", sessionId: "rt-left", payload: ["id": "srq-3", "method": "clarify", "reason": "answered"]))
        #expect(gateway.inbox.isEmpty)
    }

    @Test func attachingTheChatShowsItsPrompts() {
        store.apply(snapshot: ["session_id": "rt-left", "open_requests": [
            ["id": "srq-1", "method": "approval", "params": ["session_id": "rt-left", "request_id": "a1"]],
        ]])
        #expect(store.requests.map(\.id) == ["a1"])
        #expect(gateway.inbox.isEmpty)
    }

    @Test func leavingARunningChatKeepsItsPrompts() async {
        store.apply(snapshot: ["session_id": "rt-left", "running": true])
        #expect(store.requests.map(\.id) == ["a1"])
        await store.open("another")
        #expect(store.requests.isEmpty)
        #expect(gateway.inbox.map(\.id) == ["a1"])
    }
}

@MainActor
struct BotHistoryTests {
    @Test func agentDeliveriesAndMentionNotesInHistory() {
        let store = ChatStore(gateway: Gateway(credentials: nil), profile: "bills")
        let mention = "ask @inbox" + BotStore.mentionNote(for: "ask @inbox", roster: [Bot(name: "inbox")], excluding: "bills")
        store.apply(snapshot: ["session_id": "rt", "messages": [
            ["role": "user", "text": "Message from 🤖 Inbox (@inbox): invoice arrived", "row_id": 1],
            ["role": "user", "text": .string(mention), "row_id": 2],
            ["role": "assistant", "text": "", "row_id": 3],
        ]])
        #expect(store.items.map(\.kind) == [.agent, .user])
        #expect(store.items[0].agent?.handle == "inbox" && store.items[0].text == "invoice arrived")
        #expect(store.items[1].text == "ask @inbox")
    }

    @Test func liveDeliveryShowsTheMessageThatOpenedIt() {
        let gateway = Gateway(credentials: nil)
        let store = ChatStore(gateway: gateway, profile: "research")
        let history: [JSON] = [["role": "user", "text": "hi", "row_id": 1], ["role": "assistant", "text": "hello", "row_id": 2]]
        store.apply(snapshot: ["session_id": "rt", "messages": .array(history)])
        func emit(_ type: String, _ payload: JSON = nil) { gateway.dispatch(GatewayEvent(type: type, sessionId: "rt", payload: payload)) }

        emit("message.start")
        emit("message.delta", ["text": "On it."])
        // Not written yet when the turn starts: nothing to add, and the later try still runs.
        store.placeOpener(from: history, final: false)
        #expect(store.items.map(\.kind) == [.user, .assistant, .assistant])
        #expect(store.openerAt == 2)

        emit("message.complete", ["text": "On it.", "status": "complete"])
        let delivered = history + [["role": "user", "text": "Message from 🤖 Hermes (@hermes): ping", "row_id": 3],
                                   ["role": "assistant", "text": "On it.", "row_id": 4]]
        store.placeOpener(from: delivered, final: true)
        #expect(store.items.map(\.kind) == [.user, .assistant, .agent, .assistant])
        #expect(store.items[2].id == "row-3" && store.items[2].agent?.handle == "hermes")
        #expect(store.turnEnds["row-3"] != nil && store.turnEnds["row-1"] == nil)
        #expect(store.openerAt == nil)

        // Shown already: by row id, or as the message this app just sent.
        #expect(store.missingOpener(in: delivered, before: 3) == nil)
        emit("message.start")
        #expect(store.openerAt == 4)
        store.openerAt = nil
        store.items.append(ChatItem(id: "local-9", kind: .user, text: "thanks"))
        #expect(store.missingOpener(in: delivered + [["role": "user", "text": "thanks", "row_id": 5]], before: 5) == nil)
    }
}
