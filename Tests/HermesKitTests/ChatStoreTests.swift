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

    @Test func selectingAnotherChatClearsTheOldOneAtOnce() {
        store.select("another")
        #expect(store.selectedId == "another")
        #expect(store.items.isEmpty && store.loading)
    }

    @Test func reopeningAChatWaitsForItsCloseBeforeResuming() async {
        var log: [String] = []
        gateway.stub = { method, params in
            let id = params["session_id"]?.string ?? ""
            if method == "session.close" {
                // A close slower than the resume that follows it.
                for _ in 0..<20 { await Task.yield() }
            }
            log.append("\(method) \(id)")
            return method == "session.resume" ? ["session_id": .string("rt-" + id), "messages": []] : nil
        }
        await store.open("a")
        await store.open("b")
        await store.open("a")
        let closed = log.firstIndex(of: "session.close rt-a"), resumed = log.lastIndex(of: "session.resume a")
        #expect(closed != nil && resumed != nil && closed! < resumed!)
    }

    @Test func aLoadOvertakenByAnotherChatLeavesItsStateAlone() async {
        var release: CheckedContinuation<Void, Never>?
        gateway.stub = { method, params in
            if method == "session.resume", params["session_id"] == "slow" {
                await withCheckedContinuation { release = $0 }
                throw GatewayError.offline
            }
            return nil
        }
        let slow = Task { await store.open("slow") }
        while release == nil { await Task.yield() }
        store.select("other")
        release?.resume()
        await slow.value
        #expect(store.loading)
        #expect(store.alert == nil)
    }

    @Test func leavingAClosingChatAgainStillWaitsForTheFirstClose() async {
        var log: [String] = []
        gateway.stub = { method, params in
            let id = params["session_id"]?.string ?? ""
            if method == "session.close" { for _ in 0..<20 { await Task.yield() } }
            log.append("\(method) \(id)")
            return method == "session.resume" ? ["session_id": .string("rt-" + id), "messages": []] : nil
        }
        await store.open("a")
        await store.open("b")
        // Back on A before it loads, then off it again: this leave has no session to close.
        store.select("a")
        store.select("b")
        await store.open("a")
        let closed = log.firstIndex(of: "session.close rt-a"), resumed = log.lastIndex(of: "session.resume a")
        #expect(closed != nil && resumed != nil && closed! < resumed!)
    }

    @Test func anEarlierLoadOfAReopenedChatLeavesTheNewOneAlone() async {
        var release: CheckedContinuation<Void, Never>?
        var resumes = 0
        gateway.stub = { method, _ in
            guard method == "session.resume" else { return nil }
            resumes += 1
            if resumes == 1 {
                await withCheckedContinuation { release = $0 }
                throw GatewayError.offline
            }
            return ["session_id": "rt-a2", "messages": []]
        }
        let first = Task { await store.open("a") }
        while release == nil { await Task.yield() }
        store.select("b")
        await store.open("a")
        release?.resume()
        await first.value
        #expect(store.alert == nil && !store.loading)
        #expect(store.selectedId == "a")
    }

    @Test func openingAnotherChatShowsItBeforeTheOldOneCloses() async {
        var seen: [String: String?] = [:]
        gateway.stub = { [store] method, _ in
            seen[method] = store.selectedId
            return method == "session.resume" ? ["session_id": "rt2", "messages": []] : nil
        }
        await store.open("another")
        for _ in 0..<200 where seen["session.close"] == nil { await Task.yield() }
        #expect(seen["session.close"] == "another")
        #expect(seen["session.resume"] == "another")
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

@MainActor
struct HarnessTextTests {
    static let process = "[IMPORTANT: Background process proc_2d1b0f9cd6e8 completed normally (exit code 0).\nCommand: sleep 15\nOutput: __HERMES_CWD_67bf9446c4ba__/home/munchkin__HERMES_CWD_67bf9446c4ba__\n]"
    static let cron = "[IMPORTANT: You are running as a scheduled cron job. DELIVERY: your reply is delivered. [SILENT] is a literal token.]\n\nReply with the word ok."
    static let delegation = "[ASYNC DELEGATION BATCH COMPLETE - deleg_9fe0d6c5]\nA background fan-out unit you dispatched earlier has finished.\nThere are **0 files** here.\nFull live transcript (complete tool/assistant trace): /home/munchkin/.hermes/cache/delegation/live/deleg_9fe0d6c5/task-0.log"

    func items(_ messages: [JSON]) -> [ChatItem] {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.apply(snapshot: ["session_id": "rt", "messages": .array(messages)])
        return store.items
    }

    @Test func aProcessNoticeIsASystemRowWithoutTheMarkers() throws {
        let items = items([["role": "user", "text": .string(Self.process), "row_id": 1], ["role": "assistant", "text": "stop", "row_id": 2]])
        #expect(items.map(\.kind) == [.system, .assistant])
        let note = try #require(items[0].system)
        #expect(note.title == "Background process finished")
        #expect(note.detail == "Background process proc_2d1b0f9cd6e8 completed normally (exit code 0).\nCommand: sleep 15\nOutput: /home/munchkin")
    }

    @Test func aDelegationResultHidesTheGatewayPath() throws {
        let note = try #require(Harness.note(text: Self.delegation))
        #expect(note.title == "Delegated work finished")
        #expect(note.detail.contains("**0 files**") && !note.detail.contains("/home/munchkin") && !note.detail.contains("ASYNC"))
        // The gateway's own label and task count win when it sends them.
        #expect(Harness.note(text: Self.delegation, kind: "async_delegation_complete", metadata: ["display_text": "2 agents done"])?.title == "2 agents done")
        // REST rows carry display_metadata as JSON text.
        #expect(Harness.note(text: "x", kind: "async_delegation_complete", metadata: .string(#"{"task_count": 3}"#))?.title == "3 background agents finished")
    }

    @Test func aRoutineRunKeepsOnlyItsPromptBehindTheNote() throws {
        let note = try #require(Harness.note(text: Self.cron))
        #expect(note.title == "Routine run" && note.detail == "Reply with the word ok.")
        #expect(items([["role": "user", "text": .string(Self.cron), "row_id": 1]]).first?.kind == .system)
    }

    @Test func aSkillRoutineShowsItsNameInsteadOfTheSkillBody() throws {
        let text = "[IMPORTANT: The user has invoked the \"bill-reminders\" skill, indicating they want you to follow its instructions. The full skill content is loaded below.]\n\n---\nname: bill-reminders\n---\nbody\n\n[IMPORTANT: You are running as a scheduled cron job. DELIVERY: x]\n\nthe job prompt"
        let note = try #require(Harness.note(text: text))
        #expect(note.title == "Routine run: bill-reminders" && note.detail.hasPrefix("---\nname:") && note.detail.hasSuffix("the job prompt"))
        #expect(Harness.note(text: "[IMPORTANT: The user has invoked the \"x\" skill, y]\n\nbody")?.title == "Skill: x")
    }

    @Test func hiddenRowsAndTypedNoticesFollowTheDisplayKind() throws {
        let rows: [JSON] = [
            ["role": "user", "text": "scaffolding", "display_kind": "hidden", "row_id": 1],
            ["role": "user", "text": "[Background process proc_1 heartbeat #2 still running]", "row_id": 2],
            ["role": "user", "text": "[System note: switched]", "display_kind": "model_switch", "row_id": 3],
            ["role": "user", "text": "typed by me", "row_id": 4],
        ]
        let shown = items(rows)
        #expect(shown.map(\.kind) == [.system, .user])
        #expect(shown[0].system?.title == "Model changed")
        #expect(shown[1].text == "typed by me")
    }

    @Test func plainUserTextIsNotANotice() {
        #expect(Harness.note(text: "[IMPORTANT: remember my password is hunter2]") == nil)
        #expect(Harness.note(text: "what is a background process?") == nil)
    }

    @Test func aNoticeStartsATurnSoItsReplyFoldsUnderIt() {
        let items = items([["role": "user", "text": .string(Self.process), "row_id": 1],
                           ["role": "tool", "name": "terminal", "context": "ls", "args": ["command": "ls"], "row_id": 2],
                           ["role": "assistant", "text": "done", "row_id": 3]])
        let rows = Timeline.rows(items, running: false)
        guard case .item(let first)? = rows.first else { Issue.record("no rows"); return }
        #expect(first.kind == .system)
        #expect(rows.count == 3 && rows.dropFirst().contains { if case .item(let i) = $0 { i.text == "done" } else { false } })
    }

    @Test func delegateBubbleShowsTheTaskNotTheInstruction() {
        let prompt = DelegateTier.light.prompt("count the files", plugin: true)
        #expect(DelegateTier.displayed(prompt) == "Delegate (Light): count the files")
        #expect(DelegateTier.displayed(DelegateTier.heavy.prompt("a\nb", plugin: false)) == "Delegate: a\nb")
        #expect(DelegateTier.displayed("Use your brain") == nil)
        #expect(items([["role": "user", "text": .string(prompt), "row_id": 1]]).first?.text == "Delegate (Light): count the files")
    }
}
