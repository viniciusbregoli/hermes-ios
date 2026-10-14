import Testing
@testable import HermesKit

@MainActor
struct SlashTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": [["role": "user", "text": "hi", "row_id": 1]]])
    }

    func emit(_ type: String, _ payload: JSON = nil) {
        gateway.dispatch(GatewayEvent(type: type, sessionId: "rt1", payload: payload))
    }

    @Test func parsesCommandLines() {
        let c = SlashCommand("/BTW  what is\n  this? ")
        #expect(c?.name == "btw" && c?.arg == "what is\n  this?")
        #expect(c?.line == "btw what is\n  this?")
        #expect(SlashCommand("/usage")?.line == "usage")
        #expect(SlashCommand("/usage ")?.arg == "")
        // A path, a bare slash and a slash mid-sentence are prose.
        for prose in ["/usr/local is full", "/", "/ words", "run /usage", ""] { #expect(SlashCommand(prose) == nil) }
        #expect(SlashCommand.completes("/") && SlashCommand.completes("/us") && SlashCommand.completes("/personality al"))
        #expect(!SlashCommand.completes("/usage\n") && !SlashCommand.completes("/usr/local") && !SlashCommand.completes("hi /x"))
    }

    @Test func routesLikeTheDesktop() {
        func action(_ text: String, botChat: Bool = false) -> SlashCommand.Action? { SlashCommand(text)?.action(botChat: botChat) }
        #expect(action("/new") == .newChat && action("/clear") == .newChat)
        #expect(action("/new", botChat: true) == .compress)
        #expect(action("/bg x") == .background && action("/background x") == .background)
        #expect(action("/compact") == .compress && action("/help") == .commands)
        #expect(action("/config") == .unavailable && action("/browser connect") == .unavailable)
        #expect(action("/usage") == .exec && action("/model") == .exec && action("/my-skill go") == .exec)
        #expect(SlashCommand.listed("/help") && SlashCommand.listed("fast"))
        #expect(!SlashCommand.listed("/model") && !SlashCommand.listed("/verbose") && !SlashCommand.listed("/reset"))
    }

    @Test func suggestionsHideTerminalCommandsAndPlaceArguments() {
        let commands: JSON = ["replace_from": 1, "items": [
            ["text": "/usage", "display": "/usage", "meta": "Token usage", "kind": "command"],
            ["text": "/verbose", "meta": "Tool progress"], ["text": "/reset", "meta": "alias"],
            ["text": "work", "meta": "\u{26A1} Do work", "kind": "skill"], ["text": "q", "meta": "alias"], ["text": "/usage", "meta": "dup"]]]
        let rows = SlashSuggestion.parse(commands, typed: "/u")
        #expect(rows.map(\.text) == ["/usage", "/work"])
        #expect(rows[0].detail == "Token usage" && !rows[0].isSkill && rows[1].isSkill && rows[1].detail == "Do work")
        // An alias typed in full still shows, so Return visibly runs something.
        #expect(SlashSuggestion.parse(commands, typed: "/reset").map(\.text) == ["/usage", "/reset", "/work"])

        let args: JSON = ["replace_from": 13, "items": [["text": "alice", "meta": "friendly"], ["text": "verbose"]]]
        #expect(SlashSuggestion.parse(args, typed: "/personality al").map(\.text) == ["/personality alice", "/personality verbose"])
    }

    @Test func readsDirectives() {
        #expect(SlashDirective(["output": "ok", "warning": "careful"], command: "usage") == .output("ok", warning: "careful"))
        #expect(SlashDirective(["type": "exec"], command: "x") == .output("/x: no output", warning: nil))
        #expect(SlashDirective(["type": "skill", "name": "work", "message": "[IMPORTANT: body]", "display": "/work now"], command: "work")
                == .send(message: "[IMPORTANT: body]", display: "/work now", notice: nil))
        #expect(SlashDirective(["type": "send", "message": "go", "notice": "Goal set"], command: "goal")
                == .send(message: "go", display: nil, notice: "Goal set"))
        #expect(SlashDirective(["type": "send"], command: "goal") == .output("/goal: empty message", warning: nil))
        #expect(SlashDirective(["type": "prefill", "message": "last"], command: "undo") == .prefill("last", notice: nil))
        #expect(SlashDirective(["type": "alias", "target": "/compress"], command: "c") == .alias("compress"))
    }

    @Test func catalogGroupsCommandsThenSkillsByUse() {
        let catalog = SlashCatalog([
            "pairs": [["/help", "Help"], ["/verbose", "Verbose"], ["/a-skill", "A"], ["/b-skill", "B"], ["/c-skill", "C"]],
            "categories": [["name": "Info", "pairs": [["/help", "Help"], ["/verbose", "Verbose"]]], ["name": "Empty", "pairs": [["/config", "c"]]]],
            "skills": ["/a-skill": ["usage": 0], "/b-skill": ["usage": 5], "/c-skill": ["usage": 0]],
        ])
        #expect(catalog.sections.map(\.name) == ["Info", "Skills"])
        #expect(catalog.sections[0].entries.map(\.command) == ["/help"])
        #expect(catalog.sections[1].entries.map(\.command) == ["/b-skill", "/a-skill", "/c-skill"])
        #expect(catalog.filtered("b").flatMap(\.entries).map(\.command) == ["/b-skill"])
        #expect(catalog.filtered("help").map(\.name) == ["Info"])
    }

    @Test func sideAnswersFillTheirCard() {
        store.items.append(ChatItem(id: "s1", kind: .side, slash: SlashNote(header: "why?", taskId: "btw_1", pending: true)))
        emit("btw.complete", ["task_id": "btw_1", "text": "Because.", "question": "why?"])
        #expect(store.items.last?.text == "Because." && store.items.last?.slash?.pending == false)
        // A task this chat no longer has a card for still shows up.
        emit("background.complete", ["task_id": "bg_9", "text": "ok"])
        #expect(store.items.last?.kind == .side && store.items.last?.slash?.background == true && store.items.count == 3)
    }

    @Test func localCommandsAnswerWithoutTheGateway() async {
        #expect(await store.runSlash("/new") == .newChat)
        #expect(await store.runSlash("/help") == .showCommands)
        #expect(await store.runSlash("hello") == .done)
        _ = await store.runSlash("/config")
        #expect(store.items.last?.kind == .notice && store.items.last?.slash?.header == "/config")
        _ = await store.runSlash("/btw")
        #expect(store.items.last?.text.hasPrefix("Usage: /btw") == true)
        _ = await store.runSlash("/stop")
        #expect(store.items.last?.text == "Nothing is running.")
        _ = await store.runSlash("/fast sideways")
        #expect(store.items.last?.text == "Usage: /fast [on|off]")
    }

    @Test func notesStayOutOfTheFold() {
        let items = [
            ChatItem(id: "u1", kind: .user, text: "go"),
            ChatItem(id: "t1", kind: .tool, tool: ToolCall(id: "t1", name: "terminal", context: "", running: false)),
            ChatItem(id: "n1", kind: .notice, text: "out", slash: SlashNote(header: "/usage")),
            ChatItem(id: "t2", kind: .tool, tool: ToolCall(id: "t2", name: "terminal", context: "", running: false)),
            ChatItem(id: "a1", kind: .assistant, text: "done"),
            ChatItem(id: "s1", kind: .side, text: "Because.", slash: SlashNote(header: "why?")),
        ]
        #expect(Timeline.rows(items, running: false).map(\.id) == ["u1", "fold-u1", "n1", "a1", "s1"])
    }
}
