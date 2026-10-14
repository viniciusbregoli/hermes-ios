import Foundation
import Testing
@testable import HermesKit

@MainActor
struct ControlsTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": [["role": "user", "text": "hi", "row_id": 1]]])
    }

    func emit(_ type: String, _ payload: JSON = nil) {
        gateway.dispatch(GatewayEvent(type: type, sessionId: "rt1", payload: payload))
    }

    static func todo(_ id: String, _ status: String, parent: String? = nil) -> JSON {
        var o: [String: JSON] = ["id": .string(id), "content": .string("step \(id)"), "status": .string(status)]
        if let parent { o["parent"] = .string(parent) }
        return .object(o)
    }

    @Test func todosFoldByRevision() {
        emit("todo.updated", ["revision": 2, "todos": [Self.todo("1", "completed"), Self.todo("2", "in_progress")]])
        #expect(store.todos.map(\.status) == [.completed, .inProgress])
        // A stale snapshot (lower revision) must not roll the list back.
        emit("tool.complete", ["tool_id": "t", "revision": 1, "todos": [Self.todo("1", "in_progress")]])
        #expect(store.todos.count == 2)
        emit("tool.complete", ["tool_id": "t", "revision": 3, "todos": [Self.todo("1", "completed"), Self.todo("2", "completed")]])
        #expect(store.todos.allSatisfy { $0.status == .completed })
        // Tools other than the todo tool carry no list and leave it alone.
        emit("tool.complete", ["tool_id": "x", "result": ["output": "ok"]])
        #expect(store.todos.count == 2)
    }

    @Test func todoParsingDropsBadRowsAndNests() {
        let list = TodoItem.parse(["todos": [Self.todo("a", "pending"), Self.todo("b", "pending", parent: "a"),
                                             ["id": "c", "content": "x", "status": "weird"], ["id": "", "content": "y", "status": "pending"],
                                             Self.todo("d", "cancelled", parent: "missing"), Self.todo("e", "pending", parent: "e")]])
        #expect(list?.map(\.id) == ["a", "b", "d", "e"])
        #expect(list?.last?.parent == nil)
        let tree = TodoItem.tree(list ?? [])
        #expect(tree.map(\.item.id) == ["a", "b", "d", "e"])
        #expect(tree.map(\.depth) == [0, 1, 0, 0])
        #expect(TodoItem.parse(nil) == nil)
    }

    @Test func usageFromTicksAndCompletion() {
        emit("session.usage", ["usage": ["context_used": 23_000, "context_max": 500_000, "context_percent": 5,
                                         "input": 19_000, "output": 21, "total": 23_009, "compressions": 0]])
        #expect(store.usage?.contextUsed == 23_000)
        #expect(store.usage?.fraction == 0.05)
        emit("message.complete", ["status": "complete", "usage": ["context_used": 24_219, "context_max": 500_000, "cost_usd": 0.12]])
        #expect(store.usage?.contextUsed == 24_219)
        #expect(store.usage?.costUSD == 0.12)
        #expect(store.usage?.fraction == 24_219.0 / 500_000)
        #expect(Usage(["model": "x"])?.fraction == nil)
        #expect(Usage([:]) == nil)
    }

    @Test func infoSetsControlsOnlyWhenPresent() {
        emit("session.info", ["reasoning_effort": "high", "fast": true, "yolo": true, "approval_mode": "manual"])
        #expect(store.reasoningEffort == "high" && store.fast && store.yolo && store.approvalsOff)
        // The lazy shape omits these keys; they must survive.
        emit("session.info", ["model": "m", "lazy": true])
        #expect(store.reasoningEffort == "high" && store.fast)
        emit("session.info", ["yolo": false, "approval_mode": "off"])
        #expect(store.approvalsOff)
    }

    @Test func resumeExtrasRebuildRunningTurn() {
        store.apply(snapshot: [
            "session_id": "rt1", "running": true,
            "messages": [["role": "user", "text": "do it", "row_id": 1]],
            "inflight": ["user": "do it", "assistant": "Working on", "streaming": true],
            "queued": ["user": "and then this"],
            "todo_state": ["revision": 4, "todos": [Self.todo("1", "in_progress")]],
        ])
        #expect(store.items.map(\.kind) == [.user, .assistant])
        #expect(store.items[1].text == "Working on" && store.items[1].streaming)
        #expect(store.queued.map(\.text) == ["and then this"])
        #expect(store.todos.first?.status == .inProgress)

        // Deltas keep extending the projected bubble; the queued message becomes the next turn.
        emit("message.delta", ["text": " it"])
        #expect(store.items[1].text == "Working on it")
        emit("message.complete", ["status": "complete"])
        emit("message.start")
        #expect(store.queued.isEmpty)
        #expect(store.items.last?.kind == .user && store.items.last?.text == "and then this")
    }

    @Test func resumeAddsUnpersistedInflightUser() {
        store.apply(snapshot: ["session_id": "rt1", "running": true, "messages": [["role": "user", "text": "old"]],
                               "inflight": ["user": "new", "streaming": true]])
        #expect(store.items.map(\.text) == ["old", "new"])
    }

    @Test func busySubmitPlacement() {
        store.placeSubmitted(ChatItem(id: "q1", kind: .user, text: "later"), status: "queued")
        #expect(store.queued.map(\.text) == ["later"])
        store.placeSubmitted(ChatItem(id: "s1", kind: .user, text: "actually"), status: "steered")
        let steered = store.items.last
        #expect(steered?.text == "actually" && store.notes[steered?.id ?? ""] == "Steered the running turn")
        #expect(ChatStore.submitNote("redirected") == "Redirected the running turn")
        #expect(ChatStore.submitNote("streaming") == nil)
    }

    @Test func retryableErrorOffersRetry() {
        emit("message.start")
        emit("message.complete", ["status": "error", "error_surface": ["layer": "provider", "code": "rate_limited", "retryable": true]])
        #expect(store.items.last?.text == "Rate limited")
        #expect(store.retryText == "hi")
        emit("message.start")
        #expect(store.retryText == nil)

        emit("message.complete", ["status": "error", "error": "bad key", "error_surface": ["layer": "auth", "code": "x", "retryable": false]])
        #expect(store.items.last?.text == "bad key")
        #expect(store.retryText == nil)
    }

    @Test func errorTextMentionsReset() {
        let text = ChatStore.turnErrorText(["error": "Usage limit reached.", "error_surface": ["code": "c", "retryable": true, "resets_at": 1_800_000_000]])
        #expect(text.hasPrefix("Usage limit reached. Resets at "))
        #expect(ChatStore.turnErrorText([:]) == "The turn failed.")
    }
}
