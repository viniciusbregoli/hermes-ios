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
        gateway.onEvent(GatewayEvent(type: type, sessionId: session, payload: payload))
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
        store.receive(ServerRequest(rpcId: "srq-1", method: "approval",
                                    params: ["session_id": "rt1", "request_id": "a1", "command": "rm x"]))
        store.receive(ServerRequest(rpcId: "srq-2", method: "preview.open", params: [:]))
        #expect(store.requests.map(\.id) == ["a1"])
        emit("approval.cancelled", ["request_id": "a1"])
        #expect(store.requests.isEmpty)
    }
}
