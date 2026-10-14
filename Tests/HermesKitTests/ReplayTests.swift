import Testing
@testable import HermesKit

@MainActor
struct ReplayTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": [["role": "user", "text": "count", "row_id": 1]]])
    }

    func emit(_ type: String, _ payload: JSON = nil, seq: Int) {
        gateway.dispatch(GatewayEvent(type: type, sessionId: "rt1", payload: payload, seq: seq))
    }

    func frame(_ type: String, _ payload: JSON = nil, seq: Int) -> JSON {
        ["type": .string(type), "session_id": "rt1", "payload": payload, "seq": .number(Double(seq))]
    }

    @Test func replaysOnlyWithASameEpochWatermark() {
        #expect(ChatStore.canReplay(runtimeId: "rt1", lastSeq: 4, seenEpoch: "e1", epoch: "e1"))
        #expect(!ChatStore.canReplay(runtimeId: "rt1", lastSeq: 4, seenEpoch: "e1", epoch: "e2"))
        #expect(!ChatStore.canReplay(runtimeId: "rt1", lastSeq: 0, seenEpoch: "e1", epoch: "e1"))
        #expect(!ChatStore.canReplay(runtimeId: "rt1", lastSeq: 4, seenEpoch: nil, epoch: nil))
        #expect(!ChatStore.canReplay(runtimeId: nil, lastSeq: 4, seenEpoch: "e1", epoch: "e1"))
    }

    @Test func liveDuplicatesAreDropped() {
        emit("message.start", seq: 1)
        emit("message.delta", ["text": "1\n"], seq: 2)
        emit("message.delta", ["text": "1\n"], seq: 2)
        emit("message.delta", ["text": "late"], seq: 1)
        #expect(store.items.last?.text == "1\n")
        #expect(store.lastSeq == 2)
    }

    @Test func gapAndParkedEventsRunOnceInOrder() {
        emit("message.start", seq: 1)
        emit("message.delta", ["text": "1\n"], seq: 2)
        store.seqEpoch = "e1"
        // Reconnecting: live frames on the new socket wait for the replay.
        store.held = []
        emit("message.delta", ["text": "4\n"], seq: 5)
        emit("message.delta", ["text": "3\n"], seq: 4)
        #expect(store.items.last?.text == "1\n")

        let ok = store.applyReplay([
            "epoch": "e1", "truncated": false,
            "events": [frame("message.delta", ["text": "2\n"], seq: 3), frame("message.delta", ["text": "3\n"], seq: 4)],
            "open_requests": [["id": "srq-1", "method": "approval", "params": ["session_id": "rt1", "request_id": "a1"]]],
        ])
        #expect(ok)
        #expect(store.held == nil)
        #expect(store.items.last?.text == "1\n2\n3\n4\n")
        #expect(store.requests.map(\.id) == ["a1"])
        #expect(store.lastSeq == 5)

        emit("message.complete", ["text": "1\n2\n3\n4\n", "status": "complete"], seq: 6)
        #expect(store.items.filter { $0.kind == .assistant }.count == 1)
        #expect(store.running == false)
    }

    @Test func holesFallBackToAReload() {
        emit("message.start", seq: 1)
        store.seqEpoch = "e1"
        store.held = []
        #expect(!store.applyReplay(["epoch": "e1", "truncated": true, "events": []]))
        #expect(!store.applyReplay(["epoch": "e2", "truncated": false, "events": []]))
    }

    @Test func aNewRuntimeStartsANewWatermark() {
        emit("message.start", seq: 7)
        store.apply(snapshot: ["session_id": "rt2"])
        #expect(store.lastSeq == 0)
    }
}
