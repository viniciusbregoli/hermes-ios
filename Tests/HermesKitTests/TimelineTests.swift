import Foundation
import Testing
@testable import HermesKit

private func at(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_000 + s) }

private func user(_ id: String, _ text: String = "go", _ t: Double? = 0) -> ChatItem {
    ChatItem(id: id, kind: .user, text: text, date: t.map(at))
}

private func reply(_ id: String, _ text: String, reasoning: String = "", streaming: Bool = false, _ t: Double? = nil) -> ChatItem {
    ChatItem(id: id, kind: .assistant, text: text, reasoning: reasoning, streaming: streaming, date: t.map(at))
}

private func tool(_ id: String, _ name: String, _ args: JSON = nil, result: JSON? = nil, diff: String? = nil,
                  running: Bool = false, _ t: Double? = nil) -> ChatItem {
    ChatItem(id: id, kind: .tool, tool: ToolCall(id: id, name: name, context: "", args: args, result: result,
                                                 diff: diff, running: running), date: t.map(at))
}

private func groups(_ rows: [TimelineRow]) -> [ActivityGroup] {
    rows.compactMap { if case .work(let g) = $0 { g } else { nil } }
}

struct TimelineTests {
    let todoTurn: [ChatItem] = [
        user("u1"),
        tool("t1", "tool_describe", ["names": ["todo_list"]], 1),
        tool("t2", "tool_call", ["calls": [["name": "todo_list", "arguments": ["todos": []]]]], 2),
        tool("t3", "terminal", ["command": "date"], 3),
        tool("t4", "todo_list", ["todos": []], 4),
        tool("t5", "terminal", ["command": "uname -s"], 5),
        reply("a1", "All done.", 64),
    ]

    @Test func settledTurnFoldsBehindOneRow() {
        let rows = Timeline.rows(todoTurn, running: false)
        #expect(rows.map(\.id) == ["u1", "fold-u1", "a1"])
        guard case .fold(let fold) = rows[1] else { Issue.record("no fold"); return }
        #expect(fold.label == "Worked for 1m 4s")
    }

    @Test func unfoldedTurnShowsOneGroupWithoutTodoBookkeeping() {
        let rows = Timeline.rows(todoTurn, running: false, expanded: ["u1"])
        #expect(rows.map(\.id) == ["u1", "fold-u1", "work-t3", "a1"])
        let g = groups(rows)[0]
        #expect(g.entries.map(\.id) == ["t3", "t5"])
        #expect(g.title == "Ran 2 commands" && g.icon == "terminal" && !g.live)
    }

    @Test func singleCallUsesItsPastTenseLabel() {
        let g = groups(Timeline.rows([tool("t", "terminal", ["command": "bash -lc 'cd /srv && FOO=1 uname -s'"])], running: false))
        #expect(g.map(\.title) == ["Ran uname"])
    }

    @Test func summaryNamesTopTwoActionsAndCountsTheRest() {
        let entries = [
            tool("1", "terminal", ["command": "ls"]), tool("2", "read_file", ["path": "/a/Foo.swift"]),
            tool("3", "terminal", ["command": "make"]), tool("4", "memory"), tool("5", "read_file", ["path": "/a/Bar.swift"]),
            tool("6", "terminal", ["command": "git status"]),
        ].map { WorkEntry(id: $0.id, tool: $0.tool) }
        #expect(Timeline.summary(entries).text == "Ran 3 commands, read 2 files, and performed 1 other action")
        let edits = [tool("1", "patch", ["path": "/a"]), tool("2", "patch", ["path": "/a"]), tool("3", "write_file", ["path": "/b"])]
        #expect(Timeline.summary(edits.map { WorkEntry(id: $0.id, tool: $0.tool) }).text == "Changed 2 files")
        #expect(Timeline.summary([WorkEntry(id: "r", thought: "hm")]).text == "Thought")
    }

    @Test func failedCallFlagsTheGroup() {
        let g = groups(Timeline.rows([tool("t", "terminal", ["command": "false"], result: ["exit_code": 1, "output": ""])], running: false))
        #expect(g.first?.failed == true)
    }

    @Test func liveGroupShowsPresentTenseAndThought() {
        let items = [user("u"), reply("a", "", reasoning: "**Checking the clock**\nThen more.", 1),
                     tool("t", "terminal", ["command": "date"], running: true, 2)]
        let rows = Timeline.rows(items, running: true)
        #expect(rows.map(\.id) == ["u", ActivityGroup.liveId])
        let g = groups(rows)[0]
        #expect(g.title == "Running date" && g.thought == "Checking the clock" && g.live && g.key == "work-a-thought")
    }

    @Test func runningTurnWithoutWorkShowsThinkingRow() {
        let rows = Timeline.rows([user("u")], running: true, status: nil)
        #expect(rows.map(\.id) == ["u", ActivityGroup.liveId])
        #expect(groups(rows)[0].title == "Thinking" && groups(rows)[0].entries.isEmpty)
        let streaming = Timeline.rows([user("u"), reply("a", "Hel", streaming: true)], running: true)
        #expect(streaming.map(\.id) == ["u", "a"])
    }

    @Test func failedAndStoppedTurns() {
        let failed = todoTurn + [ChatItem(id: "e", kind: .error, text: "boom")]
        #expect(!Timeline.rows(failed, running: false).contains { if case .fold = $0 { true } else { false } })
        let stopped = Timeline.rows(todoTurn, running: false, ends: ["u1": TurnEnd(at: at(12), stopped: true)])
        guard case .fold(let fold) = stopped[1] else { Issue.record("no fold"); return }
        #expect(fold.label == "You stopped after 12s")
    }

    @Test func middleRepliesFoldWithTheWork() {
        let items = [user("u"), reply("a1", "Let me look."), tool("t1", "read_file", ["path": "/x"]),
                     reply("a2", "Found it."), tool("t2", "terminal", ["command": "make"]), reply("a3", "Fixed.")]
        #expect(Timeline.rows(items, running: false).map(\.id) == ["u", "a1", "fold-u", "a3"])
    }

    @Test func editsAddAChangedFilesCard() {
        let diff = "  \u{250A} review diff\n\u{1B}[38;2;218;165;32ma//tmp/x.txt \u{2192} b//tmp/x.txt\u{1B}[0m\n\u{1B}[38;2;139;134;130m@@ -1,3 +1,3 @@\u{1B}[0m\n\u{1B}[38;2;184;134;11m First\u{1B}[0m\n\u{1B}[38;2;255;255;255;48;2;119;20;20m-Second\u{1B}[0m\n\u{1B}[38;2;255;255;255;48;2;19;87;20m+Updated\u{1B}[0m"
        let items = [user("u"), tool("t1", "write_file", ["path": "/tmp/x.txt"]), tool("t2", "patch", ["path": "/tmp/x.txt"], diff: diff),
                     reply("a", "Done.")]
        guard case .changes(let c)? = Timeline.rows(items, running: false).last else { Issue.record("no card"); return }
        #expect(c.files.map(\.path) == ["/tmp/x.txt"] && c.added == 1 && c.removed == 1)
        #expect(c.files[0].lines.first == "@@ -1,3 +1,3 @@" && c.files[0].name == "x.txt")
        #expect(Timeline.rows(items, running: true).allSatisfy { if case .changes = $0 { false } else { true } })
    }

    @Test func commandPrograms() {
        #expect(Timeline.commandProgram("bash -lc \"cd /tmp && FOO=1 make test\"") == "make")
        #expect(Timeline.commandProgram("sudo apt install jq") == "apt")
        #expect(Timeline.commandProgram("/usr/bin/git status") == "git")
        #expect(Timeline.commandProgram("if true; then ls; fi") == nil)
        #expect(Timeline.label(ToolCall(id: "", name: "terminal", context: "", args: ["command": "for f in *; do x; done"], running: false),
                               present: false) == "Ran command")
    }

    @Test func textHelpers() {
        #expect(Timeline.liveThoughtLine("I'll check the `file`. Then run it.") == "I'll check the file.")
        #expect(Timeline.liveThoughtLine("**Inspecting logs**\nThe rest") == "Inspecting logs")
        #expect([0.5, 4.2, 12, 64, 3600].map(Timeline.formatDuration) == ["500ms", "4.2s", "12s", "1m 4s", "1h"])
        #expect(Timeline.clock(0) == "0s" && Timeline.clock(64) == "1m 4s")
    }

    @Test func followLatch() {
        var f = true
        f = ScrollFollow.next(f, .scrolled(atEnd: false, dragging: false))
        #expect(f, "layout changes never break following")
        f = ScrollFollow.next(f, .dragBegan)
        #expect(!f)
        f = ScrollFollow.next(f, .dragEnded(atEnd: false))
        #expect(!f)
        f = ScrollFollow.next(f, .scrolled(atEnd: true, dragging: false))
        #expect(f, "momentum reaching the end re-arms it")
        #expect(ScrollFollow.next(false, .reset))
        #expect(!ScrollFollow.next(true, .disclosed(atEnd: false, dragging: false)), "opening a group above the end stops following")
        #expect(ScrollFollow.next(false, .disclosed(atEnd: true, dragging: false)))
    }

    @Test func draftsPerChat() {
        let defaults = UserDefaults(suiteName: "drafts-test")!
        defaults.removePersistentDomain(forName: "drafts-test")
        let key = Drafts.key(profile: nil, chat: "s1")
        Drafts.save("half a thought", for: key, in: defaults)
        #expect(Drafts.load(key, from: defaults) == "half a thought")
        #expect(Drafts.load(Drafts.key(profile: "bills", chat: "s1"), from: defaults) == "")
        Drafts.save("  ", for: key, in: defaults)
        #expect(Drafts.load(key, from: defaults) == "")
    }
}

@MainActor
struct TurnTrackingTests {
    @Test func historyCarriesTimesAndDiffs() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.apply(snapshot: ["session_id": "rt", "messages": [
            ["role": "user", "text": "edit", "row_id": 1, "timestamp": 100],
            ["role": "tool", "name": "patch", "tool_call_id": "c1", "args": ["path": "/x"], "timestamp": 101,
             "content": "{\"success\": false, \"error\": \"no match\"}",
             "display_metadata": ["tool_result_metadata": ["inline_diff": "a/x \u{2192} b/x\n+y"]]],
        ]])
        #expect(store.items[0].date == Date(timeIntervalSince1970: 100))
        #expect(store.items[1].tool?.diff == "a/x \u{2192} b/x\n+y")
        #expect(store.items[1].tool.map(Timeline.failed) == true)
    }

    @Test func finishedTurnRecordsItsEndAndUnread() {
        let gateway = Gateway(credentials: nil)
        let store = ChatStore(gateway: gateway, defaults: UserDefaults(suiteName: #function)!)
        store.apply(snapshot: ["session_id": "rt", "info": ["stored_session_id": "s1"],
                               "messages": [["role": "user", "text": "hi", "row_id": 1]]])
        var finished: [String] = []
        store.onTurnFinished = { _, reply in finished.append(reply) }
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt", payload: nil))
        #expect(store.turnStartedAt != nil)
        gateway.dispatch(GatewayEvent(type: "message.complete", sessionId: "rt", payload: ["text": "yo", "status": "interrupted"]))
        #expect(store.turnEnds["row-1"]?.stopped == true)
        #expect(store.turnStartedAt == nil && store.finishedTurns == 1)
        #expect(Set(store.unread.keys) == ["s1"] && finished == ["yo"])
        store.onScreen = true
        #expect(store.unread.isEmpty)
    }
}

struct ClipTests {
    @Test func shortOutputIsUntouched() {
        #expect(Timeline.clip("a\nb", limit: 10) == "a\nb")
        #expect(Timeline.clip("12345\n", limit: 5) == "12345\n")
    }

    @Test func cutsAtALineBoundaryAndCountsTheRest() {
        let text = (1...10).map(String.init).joined(separator: "\n")
        // The limit lands inside "5", so that line is dropped whole.
        #expect(Timeline.clip(text, limit: 8) == "1\n2\n3\n4\n\u{2026} 6 more lines")
        // A limit that lands on a line end keeps that line.
        #expect(Timeline.clip(text, limit: 9) == "1\n2\n3\n4\n5\n\u{2026} 5 more lines")
        #expect(Timeline.clip("1\n2\n3\n", limit: 2) == "1\n\u{2026} 2 more lines")
        #expect(Timeline.clip("1\n2\n3", limit: 4) == "1\n2\n\u{2026} 1 more line")
    }

    @Test func aSeqRunEndsOnAWholeNumber() {
        let text = (1...3000).map(String.init).joined(separator: "\n")
        let clipped = Timeline.clip(text)
        let lines = clipped.components(separatedBy: "\n")
        #expect(clipped.count < 4100)
        #expect(lines.dropLast().last.flatMap(Int.init) != nil)
        let shown = lines.count - 1
        #expect(lines.last == "\u{2026} \(3000 - shown) more lines")
    }

    @Test func aSingleHugeLineIsCutWhereItStands() {
        let clipped = Timeline.clip(String(repeating: "x", count: 50), limit: 20)
        #expect(clipped == String(repeating: "x", count: 20) + "\n\u{2026} 30 more characters")
    }
}
