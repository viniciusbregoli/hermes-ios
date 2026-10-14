import Foundation

// The chat timeline as display rows, ported from T3 Code's mobile feed (apps/mobile/src/lib/threadActivity.ts
// and client-runtime/work-log/presentation.ts): tool calls and reasoning between two replies fold into one
// work group, settled turns fold behind "Worked for 1m 4s", and todo bookkeeping never shows.

/// What a tool call did, for its label, icon and the group summary.
public enum WorkAction: Sendable {
    case command, read, edit, codeSearch, webSearch, webRead, browser, delegate, other

    /// SF Symbol for rows and group headers.
    public var icon: String {
        switch self {
        case .command: "terminal"
        case .read: "eye"
        case .edit: "square.and.pencil"
        case .codeSearch, .webSearch: "magnifyingglass"
        case .webRead, .browser: "globe"
        case .delegate: "person.2"
        case .other: "hammer"
        }
    }

    /// Commands, edits and delegations say the most about a turn, so summaries name them first.
    var priority: Int {
        switch self {
        case .command, .edit, .delegate: 0
        case .other: 2
        default: 1
        }
    }

    func summary(_ n: Int) -> String {
        func plural(_ one: String, _ many: String) -> String { n == 1 ? one : many }
        switch self {
        case .command: return "Ran \(n) \(plural("command", "commands"))"
        case .read: return "Read \(n) \(plural("file", "files"))"
        case .edit: return "Changed \(n) \(plural("file", "files"))"
        case .codeSearch: return "Searched files \(n) \(plural("time", "times"))"
        case .webSearch: return "Searched the web \(n) \(plural("time", "times"))"
        case .webRead: return "Read \(n) \(plural("webpage", "webpages"))"
        case .browser: return "Used the browser \(n) \(plural("time", "times"))"
        case .delegate: return "Delegated \(n) \(plural("task", "tasks"))"
        case .other: return "Used \(n) \(plural("tool", "tools"))"
        }
    }
}

/// One tool call or reasoning block inside a work group.
public struct WorkEntry: Identifiable, Hashable, Sendable {
    public let id: String
    /// nil for a reasoning block.
    public var tool: ToolCall?
    public var thought = ""
    /// A tool still running or reasoning still streaming.
    public var live = false

    public var icon: String { tool.map { Timeline.action($0).icon } ?? "brain" }
    public var failed: Bool { tool.map(Timeline.failed) ?? false }
    public func label(present: Bool) -> String {
        tool.map { Timeline.label($0, present: present) } ?? (present ? "Thinking" : "Thought")
    }
}

/// Adjacent tool calls and reasoning, shown as one collapsible header.
public struct ActivityGroup: Identifiable, Hashable, Sendable {
    /// Row identity of the running turn's tail, so the live row stays put as calls come and go.
    public static let liveId = "work-live"
    public let id: String
    /// Expansion key: the first entry's id, stable across the live and settled states.
    public let key: String
    public var entries: [WorkEntry]
    public var title: String
    /// First sentence of the latest reasoning, shown dim above a live header.
    public var thought: String?
    public var icon: String
    public var live: Bool
    public var failed: Bool
}

/// Stands in for the work of a settled turn: "Worked for 1m 4s".
public struct TurnFold: Identifiable, Hashable, Sendable {
    public var id: String { "fold-\(turn)" }
    /// Id of the user message that started the turn.
    public let turn: String
    public var label: String
    public var expanded: Bool
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public var added = 0
    public var removed = 0
    /// Unified diff lines (no ANSI), empty when the server sent no preview.
    public var lines: [String] = []

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// Files a settled turn edited, as one card after its last reply.
public struct ChangeSet: Identifiable, Hashable, Sendable {
    public var id: String { "changes-\(turn)" }
    public let turn: String
    public var files: [FileChange]
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

public enum TimelineRow: Identifiable, Hashable, Sendable {
    /// User, agent and error items, and assistant replies with their reasoning moved into work groups.
    case item(ChatItem)
    case work(ActivityGroup)
    case fold(TurnFold)
    case changes(ChangeSet)

    public var id: String {
        switch self {
        case .item(let i): i.id
        case .work(let g): g.id
        case .fold(let f): f.id
        case .changes(let c): c.id
        }
    }
}

public enum Timeline {
    /// - Parameters:
    ///   - running: a turn is running; it is the last one.
    ///   - status: the server's status line ("Preparing terminal…"), shown on the live row.
    ///   - ends: live turn ends by the id of the message that started the turn.
    ///   - expanded: turns the user unfolded.
    public static func rows(_ items: [ChatItem], running: Bool, status: String? = nil,
                            ends: [String: TurnEnd] = [:], expanded: Set<String> = []) -> [TimelineRow] {
        var turns: [[ChatItem]] = []
        for item in items {
            if item.startsTurn || turns.isEmpty { turns.append([item]) } else { turns[turns.count - 1].append(item) }
        }
        var out: [TimelineRow] = []
        for (i, turn) in turns.enumerated() {
            let active = running && i == turns.count - 1
            out += rows(turn: turn, active: active, status: status, end: ends[turn[0].id], expanded: expanded.contains(turn[0].id))
        }
        if running, turns.isEmpty { out.append(.work(placeholder(status))) }
        return out
    }

    private static func rows(turn: [ChatItem], active: Bool, status: String?, end: TurnEnd?, expanded: Bool) -> [TimelineRow] {
        let anchored = turn[0].startsTurn
        var body: [TimelineRow] = []
        var pending: [WorkEntry] = []
        func flush(tail: Bool) {
            guard !pending.isEmpty else { return }
            body.append(.work(group(pending, live: active && (tail || pending.contains(where: \.live)), tail: tail, status: status)))
            pending = []
        }
        for item in anchored ? Array(turn.dropFirst()) : turn {
            switch item.kind {
            case .assistant:
                if !item.reasoning.isEmpty {
                    pending.append(WorkEntry(id: "\(item.id)-thought", thought: item.reasoning,
                                             live: active && item.streaming && item.text.isEmpty))
                }
                if !item.text.isEmpty {
                    flush(tail: false)
                    var reply = item
                    reply.reasoning = ""
                    body.append(.item(reply))
                }
            case .tool:
                if let tool = item.tool.flatMap(visible) {
                    pending.append(WorkEntry(id: item.id, tool: tool, live: active && tool.running))
                }
            default:
                flush(tail: false)
                body.append(.item(item))
            }
        }
        flush(tail: true)

        if active {
            let tail = body.last
            let streamingReply: Bool = if case .item(let i)? = tail { i.kind == .assistant && i.streaming } else { false }
            let liveGroup: Bool = if case .work(let g)? = tail { g.live } else { false }
            if !streamingReply && !liveGroup { body.append(.work(placeholder(status))) }
            return (anchored ? [.item(turn[0])] : []) + body
        }

        let changes = changeSet(turn)
        var out: [TimelineRow] = anchored ? [.item(turn[0])] : []
        if anchored, !turn.contains(where: { $0.kind == .error }), let fold = fold(turn, body: body, end: end, expanded: expanded) {
            out += fold
        } else {
            out += body
        }
        if let changes { out.append(.changes(changes)) }
        return out
    }

    /// The first and last replies stay, and slash notices; everything between them folds into one row, unless nothing but text would.
    private static func fold(_ turn: [ChatItem], body: [TimelineRow], end: TurnEnd?, expanded: Bool) -> [TimelineRow]? {
        func kind(_ i: Int) -> ChatItem.Kind? { if case .item(let item) = body[i] { item.kind } else { nil } }
        let replies = body.indices.filter { kind($0) == .assistant }
        let notes = body.indices.filter { kind($0) == .notice || kind($0) == .side }
        let kept = Set([replies.first, replies.last].compactMap { $0 } + notes)
        let hidden = body.indices.filter { !kept.contains($0) }
        guard let anchor = hidden.first, hidden.contains(where: { if case .work = body[$0] { true } else { false } }) else { return nil }
        let start = turn[0].date
        let finish = end?.at ?? turn.last(where: { $0.date != nil })?.date
        let duration = start.flatMap { s in finish.map { formatDuration(max(0, $0.timeIntervalSince(s))) } }
        let label = end?.stopped == true
            ? duration.map { "You stopped after \($0)" } ?? "You stopped this response"
            : duration.map { "Worked for \($0)" } ?? "Worked"
        var out = body
        let row = TimelineRow.fold(TurnFold(turn: turn[0].id, label: label, expanded: expanded))
        if !expanded { out = body.indices.filter { kept.contains($0) }.map { body[$0] } }
        out.insert(row, at: expanded ? anchor : kept.filter { $0 < anchor }.count)
        return out
    }

    private static func placeholder(_ status: String?) -> ActivityGroup {
        ActivityGroup(id: ActivityGroup.liveId, key: ActivityGroup.liveId, entries: [], title: status ?? "Thinking",
                  thought: nil, icon: "brain", live: true, failed: false)
    }

    private static func group(_ entries: [WorkEntry], live: Bool, tail: Bool, status: String?) -> ActivityGroup {
        let latest = entries.last!
        let key = "work-\(entries[0].id)"
        let tools = entries.filter { $0.tool != nil }
        let failed = tools.last?.failed ?? false
        let title: String
        let icon: String
        var thought: String?
        if live {
            icon = latest.icon
            thought = entries.last { $0.tool == nil && !$0.thought.isEmpty }.map { liveThoughtLine($0.thought) }
            if let status { title = status }
            else if latest.tool == nil { title = latest.live ? "Thinking" : "Thought" }
            // The trailing call keeps the present tense until the next one starts, unless it failed.
            else { title = latest.label(present: !latest.failed) }
        } else if entries.count == 1, let tool = latest.tool, action(tool) != .edit {
            title = latest.label(present: false)
            icon = latest.icon
        } else {
            let s = summary(entries)
            title = s.text
            icon = s.icon
        }
        return ActivityGroup(id: live && tail ? ActivityGroup.liveId : key, key: key, entries: entries, title: title,
                         thought: thought?.nonEmpty, icon: icon, live: live, failed: failed)
    }

    /// "Ran 3 commands, read 2 files, and performed 1 other action": the two highest-priority actions,
    /// then whatever is left as one count. Reasoning-only groups are "Thought".
    public static func summary(_ entries: [WorkEntry]) -> (text: String, icon: String) {
        let tools = entries.compactMap(\.tool)
        guard !tools.isEmpty else { return ("Thought", "brain") }
        var order: [WorkAction] = []
        var byAction: [WorkAction: [ToolCall]] = [:]
        for t in tools {
            let a = action(t)
            if byAction[a] == nil { order.append(a) }
            byAction[a, default: []].append(t)
        }
        func count(_ a: WorkAction) -> Int {
            let calls = byAction[a] ?? []
            guard a == .edit else { return calls.count }
            // Edits count files: several patches to one file are one changed file.
            let paths = calls.compactMap { path($0) }
            return Set(paths).count + calls.count - paths.count
        }
        let picked = order.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .prefix(2).sorted { $0.offset < $1.offset }.map(\.element)
        var labels = picked.map { $0.summary(count($0)) }
        let rest = tools.count - picked.reduce(0) { $0 + (byAction[$1]?.count ?? 0) }
        if rest > 0 { labels.append("Performed \(rest) other \(rest == 1 ? "action" : "actions")") }
        let parts = labels.enumerated().map { $0.offset == 0 ? $0.element : $0.element.prefix(1).lowercased() + $0.element.dropFirst() }
        let text = parts.count < 3 ? parts.joined(separator: " and ") : parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        return (text, picked.first?.icon ?? "hammer")
    }

    // MARK: - Tools

    /// Tools whose result lives elsewhere (the todo panel) or that only read the tool catalog.
    static let silentTools: Set<String> = ["todo", "todo_list", "tool_describe", "tool_search", "react_to_message"]

    /// The call as the timeline shows it: bridged calls unwrapped, bookkeeping dropped unless it failed.
    public static func visible(_ tool: ToolCall) -> ToolCall? {
        let t = unwrapped(tool)
        return silentTools.contains(t.name) && !failed(t) ? nil : t
    }

    /// `tool_call {calls: [{name, arguments}]}` is the Tool Search bridge running another tool; show that tool.
    static func unwrapped(_ tool: ToolCall) -> ToolCall {
        guard tool.name == "tool_call", let args = tool.args else { return tool }
        let calls = args["calls"]?.array ?? [args]
        let names = calls.compactMap { $0["name"]?.string }
        guard let first = names.first else { return tool }
        var t = tool
        if names.allSatisfy(silentTools.contains) {
            t.name = first
            return t
        }
        guard calls.count == 1 else { return tool }
        t.name = first
        let inner = calls[0]["arguments"] ?? calls[0]["args"]
        t.args = inner?.string.flatMap { try? JSON.parse(Data($0.utf8)) } ?? inner
        return t
    }

    public static func action(_ t: ToolCall) -> WorkAction {
        switch t.name {
        case "terminal", "execute_code", "process": .command
        case "read_file": .read
        case "write_file", "patch", "edit_file": .edit
        case "search_files", "list_files": .codeSearch
        case "web_search": .webSearch
        case "web_extract": .webRead
        case "delegate_task": .delegate
        case let n where n.hasPrefix("browser_"): .browser
        default: .other
        }
    }

    /// A failed call, by the same rules the gateway uses to keep it visible (tool_progress.py).
    public static func failed(_ t: ToolCall) -> Bool {
        guard let r = t.result else { return false }
        if r["success"]?.bool == false || r["ok"]?.bool == false { return true }
        if let e = r["error"]?.string, !e.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if let code = r["exit_code"]?.double, code != 0 { return true }
        return false
    }

    /// "Running uname" while it runs, "Ran uname" once done.
    public static func label(_ t: ToolCall, present p: Bool) -> String {
        let args = t.args
        func s(_ key: String) -> String? { args?[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        func verb(_ a: String, _ b: String) -> String { p ? a : b }
        func quoted(_ v: String?) -> String { v.map { " \u{201C}\($0)\u{201D}" } ?? "" }
        switch t.name {
        case "terminal", "process":
            let program = s("command").flatMap(commandProgram) ?? "command"
            return "\(verb("Running", "Ran")) \(program)"
        case "execute_code": return verb("Running code", "Ran code")
        case "read_file": return "\(verb("Reading", "Read")) \(path(t).map(basename) ?? "file")"
        case "write_file", "patch", "edit_file": return "\(verb("Editing", "Edited")) \(path(t).map(basename) ?? "file")"
        case "search_files": return verb("Searching", "Searched") + ((s("pattern") ?? s("query")).map { " for\(quoted($0))" } ?? " files")
        case "list_files": return verb("Listing files", "Listed files")
        case "web_search": return verb("Searching the web", "Searched the web") + ((s("query") ?? s("search_term")).map { " for\(quoted($0))" } ?? "")
        case "web_extract":
            let url = s("url") ?? args?["urls"]?.array?.first?.string
            return "\(verb("Reading", "Read")) \(url.flatMap { URL(string: $0)?.host } ?? "webpage")"
        case "browser_navigate":
            return "\(verb("Opening", "Opened")) \(s("url").flatMap { URL(string: $0)?.host } ?? "page")"
        case "browser_click": return verb("Clicking on the page", "Clicked on the page")
        case "browser_type", "browser_fill": return verb("Typing on the page", "Typed on the page")
        case "browser_snapshot": return verb("Reading the page", "Read the page")
        case "browser_take_screenshot": return verb("Taking a screenshot", "Took a screenshot")
        case "delegate_task": return verb("Delegating a task", "Delegated a task")
        case "skill_view": return "\(verb("Reading", "Read")) skill\(s("name").map { " \($0)" } ?? "")"
        case "skills_list": return verb("Listing skills", "Listed skills")
        case "skill_manage": return verb("Updating a skill", "Updated a skill")
        case "memory": return verb("Saving to memory", "Saved to memory")
        case "vision_analyze": return verb("Analyzing an image", "Analyzed an image")
        case "image_generate": return verb("Generating an image", "Generated an image")
        case "text_to_speech": return verb("Generating speech", "Generated speech")
        case "clarify": return verb("Asking a question", "Asked a question")
        case "cronjob": return verb("Scheduling a job", "Scheduled a job")
        case "session_search_recall": return verb("Searching past chats", "Searched past chats")
        case "todo", "todo_list": return verb("Updating todos", "Updated todos")
        case let n where n.hasPrefix("browser_"): return verb("Using the browser", "Used the browser")
        default: return "\(verb("Using", "Used")) \(t.name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    static func path(_ t: ToolCall) -> String? {
        (t.args?["path"] ?? t.args?["file"] ?? t.args?["filepath"])?.string?.nonEmpty
    }

    static func basename(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    // MARK: - Commands

    private static let wrappers: Set<String> = ["sudo", "env", "nohup", "time", "command", "exec", "builtin", "nice", "noglob", "nocorrect"]
    /// Setup steps (`cd x && make`): the label names the program after them.
    private static let setup: Set<String> = ["cd", "export", "set", "source", ".", "pushd", "popd", "unset", "local", "alias",
                                             "true", ":", "shopt", "setopt", "umask", "ulimit", "typeset", "declare", "readonly"]
    /// Shell syntax that has no useful program name; "Ran command" beats "Ran if".
    private static let control: Set<String> = ["if", "for", "while", "until", "case", "function", "select", "{", "[", "[[",
                                               "!", "then", "do", "else", "elif", "fi", "done", "esac", "test", "eval", "false"]

    /// The program a shell command runs, skipping `bash -lc` wrappers, env assignments, sudo and setup
    /// steps such as `cd dir &&`; nil when the command starts with shell syntax.
    // ponytail: splits on separators without honoring quotes; T3's commandLabel.ts has a full tokenizer if labels go wrong.
    public static func commandProgram(_ command: String) -> String? {
        var rest = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let script = shellScript(rest) { rest = script }
        let segments = rest.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments where !segment.isEmpty {
            var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            while let t = tokens.first, wrappers.contains(t) || t.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                tokens.removeFirst()
            }
            guard let first = tokens.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) else { continue }
            if setup.contains(first) { continue }
            if control.contains(first) || "<>(){}[;|&$`#!%@".contains(first.first ?? " ") || first.hasSuffix("()") { return nil }
            return basename(first).nonEmpty
        }
        return nil
    }

    /// The script of `bash -lc '...'` (any POSIX shell, `-c` among its flags), else nil.
    static func shellScript(_ command: String) -> String? {
        let pattern = #"^(?:\S*/)?(?:sh|bash|zsh|dash|ash|ksh|fish)\s+(?:-[A-Za-z]*\s+)*?-[A-Za-z]*c[A-Za-z]*\s+(['"])([\s\S]*)\1\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 2), in: command) else { return nil }
        return String(command[r])
    }

    // MARK: - Text

    /// The first sentence of a reasoning block, or its bold heading line, as plain text (T3 liveThoughtLine).
    public static func liveThoughtLine(_ markdown: String) -> String {
        var heading: String?
        if let r = markdown.range(of: #"^\s*\*\*[^*\r\n]+\*\*[ \t]*(\r?\n|$)"#, options: .regularExpression) {
            heading = String(markdown[r]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        }
        var text = heading ?? markdown
        for (pattern, template) in [(#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"(?m)^[ \t]*(?:#{1,6}|[-*+]|\d+\.)[ \t]+"#, ""),
                                    (#"`+|\*\*|~~"#, ""), (#"\s+"#, " ")] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if heading != nil { return text }
        if let end = text.range(of: #"[.?!]["'\u{201D}\u{2019})]?(?=\s)"#, options: .regularExpression) {
            return String(text[..<end.upperBound])
        }
        return text
    }

    /// "850ms", "4.2s", "12s", "1m 4s", "2h 5m" (T3 orchestrationTiming.formatDuration).
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        guard ms.isFinite, ms >= 0 else { return "0ms" }
        if ms < 1000 { return "\(max(1, Int(ms.rounded())))ms" }
        if ms < 10_000 {
            let tenths = (ms / 100).rounded() / 10
            return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
        }
        if ms < 60_000 { return "\(Int((ms / 1000).rounded()))s" }
        return clock(Int((ms / 1000).rounded()))
    }

    /// Whole seconds as "12s", "1m 4s", "1h 2m 3s", for the ticking working timer.
    public static func clock(_ total: Int) -> String {
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }

    // MARK: - Changed files

    /// Files a turn edited, with line counts from each edit's inline diff.
    static func changeSet(_ turn: [ChatItem]) -> ChangeSet? {
        var files: [FileChange] = []
        for item in turn {
            guard let t = item.tool.map(unwrapped), action(t) == .edit, !t.running, !failed(t) else { continue }
            var parsed = parseDiff(t.diff ?? "")
            if parsed.isEmpty, let p = path(t) { parsed = [FileChange(path: p)] }
            for f in parsed {
                if let i = files.firstIndex(where: { $0.path == f.path }) {
                    files[i].added += f.added
                    files[i].removed += f.removed
                    files[i].lines += f.lines
                } else {
                    files.append(f)
                }
            }
        }
        return files.isEmpty ? nil : ChangeSet(turn: turn[0].id, files: files)
    }

    /// Splits the gateway's inline diff (ANSI colored, "a/path → b/path" per file) into files.
    public static func parseDiff(_ inline: String) -> [FileChange] {
        let plain = inline.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        var files: [FileChange] = []
        for line in plain.components(separatedBy: "\n") {
            if let arrow = line.range(of: " \u{2192} b/"), line.hasPrefix("a/") {
                files.append(FileChange(path: String(line[arrow.upperBound...])))
                continue
            }
            guard !files.isEmpty, !line.hasPrefix("  \u{250A}") else { continue }
            if line.hasPrefix("+") && !line.hasPrefix("+++") { files[files.count - 1].added += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { files[files.count - 1].removed += 1 }
            files[files.count - 1].lines.append(line)
        }
        return files
    }
}

/// Whether the transcript keeps following new output (T3 thread-feed-live-follow.ts). Only the user's own
/// drags break it; programmatic scrolls and layout changes never do.
public enum ScrollFollow {
    public enum Event: Sendable {
        case reset, dragBegan
        /// The drag and its momentum are over.
        case dragEnded(atEnd: Bool)
        case scrolled(atEnd: Bool, dragging: Bool)
        /// Something the user expanded or collapsed finished resizing.
        case disclosed(atEnd: Bool, dragging: Bool)
    }

    public static func next(_ following: Bool, _ event: Event) -> Bool {
        switch event {
        case .reset: true
        case .dragBegan: false
        case .dragEnded(let atEnd): atEnd
        case .scrolled(let atEnd, let dragging): !dragging && (atEnd || following)
        case .disclosed(let atEnd, let dragging): !dragging && atEnd
        }
    }
}
