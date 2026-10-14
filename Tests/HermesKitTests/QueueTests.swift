import Foundation
import Testing
@testable import HermesKit

@MainActor
struct QueueTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": [["role": "user", "text": "hi", "row_id": 1]]])
    }

    func emit(_ type: String, _ payload: JSON = nil) {
        gateway.dispatch(GatewayEvent(type: type, sessionId: "rt1", payload: payload))
    }

    /// Starts a turn and queues `texts` behind it.
    func queue(_ texts: String...) async {
        emit("message.start")
        for t in texts { await store.send(t) }
    }

    @Test func sendButtonStates() {
        let idle = SendButton(draft: "hi", running: false, online: true, hasAttachments: false, attaching: false)
        #expect(idle.action == .send && idle.enabled && !idle.canSteer && idle.icon == "arrow.up")
        let busy = SendButton(draft: "hi", running: true, online: true, hasAttachments: false, attaching: false)
        #expect(busy.action == .queue && busy.enabled && busy.canSteer && busy.label == "Queue")
        // Attachments and commands can't ride a steer; they still queue.
        #expect(!SendButton(draft: "hi", running: true, online: true, hasAttachments: true, attaching: false).canSteer)
        #expect(!SendButton(draft: "/usage", running: true, online: true, hasAttachments: false, attaching: false).canSteer)
        #expect(!SendButton(draft: "  ", running: true, online: true, hasAttachments: false, attaching: false).enabled)
        #expect(!SendButton(draft: "hi", running: false, online: true, hasAttachments: true, attaching: true).enabled)
        #expect(!SendButton(draft: "hi", running: true, online: false, hasAttachments: false, attaching: false).enabled)
        let update = SendButton(draft: "hi", running: true, online: true, hasAttachments: false, attaching: false, editingQueued: true)
        #expect(update.action == .update && !update.canSteer && update.icon == "checkmark")
        #expect(!SendButton(draft: "", running: false, online: true, hasAttachments: true, attaching: false, editingQueued: true).enabled)
        // Editing a sent message rewinds, which stops the turn itself.
        #expect(SendButton(draft: "hi", running: true, online: true, hasAttachments: false, attaching: false, editingSent: true).action == .send)
    }

    @Test func busySendsQueueOnDevice() async {
        await queue("one", "two", "three")
        #expect(store.queue.map(\.text) == ["one", "two", "three"])
        #expect(store.items.map(\.text) == ["hi"])
        #expect(store.queuedCount == 3)
        #expect(store.queuedBubbles.map(\.text) == ["one", "two", "three"])

        store.editQueued(store.queue[1].id, text: " second ")
        store.moveQueued(store.queue[2].id, by: -5)
        #expect(store.queue.map(\.text) == ["three", "one", "second"])
        store.moveQueued(store.queue[0].id, by: 1)
        #expect(store.queue.map(\.text) == ["one", "three", "second"])
        store.removeQueued(store.queue[1].id)
        #expect(store.queue.map(\.text) == ["one", "second"])
        // Clearing the text drops the message.
        store.editQueued(store.queue[0].id, text: "")
        #expect(store.queue.map(\.text) == ["second"])
    }

    @Test func kickoffsAreNotEditable() async {
        emit("message.start")
        await store.send("Pursue the goal", display: "/goal resume")
        #expect(store.queue.first?.shown == "/goal resume" && store.queue.first?.editable == false)
        store.editQueued(store.queue[0].id, text: "other")
        #expect(store.queue.first?.text == "Pursue the goal")
    }

    @Test func turnEndSendsTheHead() async {
        await queue("one", "two")
        emit("message.complete", ["status": "complete"])
        #expect(store.queue.map(\.text) == ["two"])
    }

    @Test func serverQueueRunsFirst() async {
        await queue("mine")
        store.placeSubmitted(ChatItem(id: "s", kind: .user, text: "with photo"), status: "queued")
        emit("message.complete", ["status": "complete"])
        #expect(store.queue.map(\.text) == ["mine"])
        // The server drains its own message as the next turn; ours follows it.
        emit("message.start")
        #expect(store.queued.isEmpty && store.items.last?.text == "with photo")
        emit("message.complete", ["status": "complete"])
        #expect(store.queue.isEmpty)
    }

    @Test func stopPausesTheQueue() async {
        await queue("one")
        emit("message.complete", ["status": "interrupted"])
        #expect(store.queuePaused && store.queue.count == 1)
        store.resumeQueue()
        #expect(!store.queuePaused && store.queue.isEmpty)
    }

    @Test func editingHoldsTheQueue() async {
        await queue("one")
        store.queueEditing = store.queue[0].id
        emit("message.complete", ["status": "complete"])
        #expect(store.queue.count == 1)
        store.editQueued(store.queue[0].id, text: "one, edited")
        store.queueEditing = nil
        #expect(store.queue.isEmpty)
    }

    @Test func steerOutcomes() async {
        emit("message.start")
        store.placeSteered("also this", redirect: false, status: "queued", at: nil)
        let steered = store.items.last
        #expect(steered?.text == "also this" && store.notes[steered?.id ?? ""] == "Steered the running turn")
        #expect(store.steerFeedback?.hasPrefix("Steered") == true)

        store.placeSteered("instead", redirect: true, status: "redirected", at: nil)
        #expect(store.notes[store.items.last?.id ?? ""] == "Redirected the running turn")

        // Redirected while the turn was still being built: the server runs it next.
        store.placeSteered("early", redirect: true, status: "queued", at: nil)
        #expect(store.queued.map(\.text) == ["early"])

        // A refused steer keeps its words, back where they were in the queue.
        await store.send("a")
        await store.send("b")
        store.placeSteered("refused", redirect: false, status: "rejected", at: 1)
        #expect(store.queue.map(\.text) == ["a", "refused", "b"])
        #expect(store.steerFeedback?.contains("rejected") == true)
    }

    @Test func steerWithoutATurnQueuesInstead() async {
        await store.steer("late")
        #expect(store.steerFeedback?.hasPrefix("Couldn't steer") == true)
        // Idle, so the requeued message is sent right away.
        #expect(store.queue.isEmpty)
    }

    @Test func leavingTheChatClearsTheQueue() async {
        await queue("one")
        store.resetControls()
        #expect(store.queue.isEmpty && !store.queuePaused && store.queueEditing == nil)
    }
}
