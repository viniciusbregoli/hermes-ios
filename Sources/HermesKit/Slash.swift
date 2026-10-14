import Foundation

// Slash commands the way Hermes Desktop runs them (desktop app/session/hooks/use-prompt-actions/slash.ts,
// lib/desktop-slash-commands.ts, shared/src/slash.ts): a few commands map to this app's own controls,
// everything else goes to the gateway's `slash.exec` and comes back as text or a directive.

/// A composer line that invokes a command: "/" at position 0, a bare name, then whitespace or the end.
/// "/usr/local" (a second slash) and "/ words" (no name) are prose.
public struct SlashCommand: Equatable, Sendable {
    /// Lower-cased, without the slash.
    public let name: String
    /// The argument with the outer whitespace trimmed; interior kept verbatim.
    public let arg: String

    public init?(_ text: String) {
        guard text.range(of: #"^/[^\s/]+(\s|$)"#, options: .regularExpression) != nil else { return nil }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        self.name = name.lowercased()
        arg = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The composer holds a command being typed, its name or a one-line argument, so suggestions apply.
    public static func completes(_ text: String) -> Bool {
        text.range(of: #"^/[^\s/]*([ \t][^\n]*)?\z"#, options: .regularExpression) != nil
    }

    /// What `slash.exec` takes: the line without its slash.
    public var line: String { arg.isEmpty ? name : "\(name) \(arg)" }

    /// Where the command runs.
    public enum Action: Equatable, Sendable {
        case newChat, stop, yolo, reasoning, fast, title, btw, background, compress, commands
        /// Has no surface in this app; answered with a notice instead of running.
        case unavailable
        /// `slash.exec`, with the `command.dispatch` fallback.
        case exec
    }

    /// - Parameter botChat: the open chat is a bot's one Bot Chat, which never starts over.
    public func action(botChat: Bool = false) -> Action {
        if Self.unavailable.contains(name) { return .unavailable }
        let local = Self.local[name] ?? .exec
        // The desktop turns /new inside a Bot Chat into /compact.
        return local == .newChat && botChat ? .compress : local
    }

    /// Commands the desktop answers itself instead of sending them to the gateway.
    static let local: [String: Action] = [
        "new": .newChat, "reset": .newChat, "clear": .newChat, "stop": .stop, "yolo": .yolo,
        "reasoning": .reasoning, "fast": .fast, "title": .title, "btw": .btw, "bg": .background,
        "background": .background, "compress": .compress, "compact": .compress, "help": .commands, "commands": .commands]

    /// The desktop registry's commands with no desktop surface (desktop-slash-registry.json: terminal,
    /// messaging, settings, advanced and voice, minus /fast which has a pill here), plus desktop-only
    /// overlays this app has no equivalent of. Sent to the slash worker they would act on the gateway host.
    // ponytail: a static copy; read `commands.catalog`'s per-command `desktop` field if it drifts.
    static let unavailable: Set<String> = [
        "approve", "deny", "busy", "config", "copy", "cron", "exit", "footer", "gateway", "history", "image",
        "indicator", "paste", "platforms", "plugins", "quit", "redraw", "reload", "restart", "sb", "set-home",
        "sethome", "snap", "snapshot", "statusbar", "toolsets", "update", "verbose", "curator", "insights",
        "kanban", "reload-mcp", "reload-skills", "reload_mcp", "reload_skills", "login", "voice", "pets",
        "density", "details", "logs", "mouse",
        "branch", "fork", "profile", "skin", "pet", "hatch", "generate-pet", "journey", "learning",
        "memory-graph", "wake", "handoff", "browser", "resume", "sessions", "switch"]

    /// Runnable but kept out of suggestions: aliases of listed commands (`commands.catalog`'s `canon`),
    /// and /model (the model menu covers it).
    static let unlisted: Set<String> = [
        "model", "reset", "clear", "background", "compact", "commands", "bp", "codex_runtime", "compose", "ctx",
        "hb", "proactive", "q", "s", "suggest", "tasks", "ts", "upgrade", "v"]

    /// Whether `name` (with or without its slash) belongs in the suggestions and the commands sheet.
    public static func listed(_ name: String) -> Bool {
        let n = name.hasPrefix("/") ? String(name.dropFirst()).lowercased() : name.lowercased()
        return !unavailable.contains(n) && !unlisted.contains(n)
    }
}

/// One row of `complete.slash`.
public struct SlashSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { text }
    /// The whole composer line once picked ("/help", "/personality alice").
    public let text: String
    public let label: String
    public let detail: String
    public let isSkill: Bool

    /// Rows for `typed` from a `complete.slash` result. Argument rows carry only the argument, placed
    /// after `replace_from`; command rows the desktop keeps out of its palette are dropped unless typed in full.
    public static func parse(_ r: JSON, typed: String) -> [SlashSuggestion] {
        let from = r["replace_from"]?.int ?? 1
        let argStage = from > 1
        let prefix = String(String.UnicodeScalarView(typed.unicodeScalars.prefix(from)))
        let exact = typed.trimmingCharacters(in: .whitespaces).lowercased()
        var seen: Set<String> = []
        return (r["items"]?.array ?? []).compactMap { item in
            // An exact command match comes back with a trailing space ("usage ").
            guard let raw = item["text"]?.string?.trimmingCharacters(in: .whitespaces).nonEmpty else { return nil }
            let text = argStage ? prefix + raw : (raw.hasPrefix("/") ? raw : "/" + raw)
            guard argStage || SlashCommand.listed(text) || text.lowercased() == exact, seen.insert(text).inserted else { return nil }
            let display = item["display"]?.string?.nonEmpty ?? raw
            // Skill rows lead with a ⚡ glyph; the badge says it instead.
            let detail = (item["meta"]?.string ?? "").replacingOccurrences(of: "^\u{26A1}\\s*", with: "", options: .regularExpression)
            return SlashSuggestion(text: text, label: display, detail: detail,
                                   isSkill: item["kind"]?.string == "skill")
        }
    }
}

/// What `slash.exec` or `command.dispatch` answered (shared/src/slash.ts parseCommandDispatch).
public enum SlashDirective: Equatable, Sendable {
    case output(String, warning: String?)
    /// Submit `message` as the user's turn; the bubble shows `display` (a skill's body is for the model only).
    case send(message: String, display: String?, notice: String?)
    /// Put `message` in the composer (/undo).
    case prefill(String, notice: String?)
    /// Run `/target` with the same argument.
    case alias(String)

    public init(_ r: JSON, command: String) {
        func str(_ key: String) -> String? { r[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        let missing = Self.output("/\(command): empty message", warning: nil)
        switch r["type"]?.string {
        case "alias":
            self = str("target").map { SlashDirective.alias($0.hasPrefix("/") ? String($0.dropFirst()) : $0) } ?? missing
        case "prefill":
            self = r["message"]?.string.map { SlashDirective.prefill($0, notice: str("notice")) } ?? missing
        case "send", "skill":
            self = str("message").map { SlashDirective.send(message: $0, display: str("display"), notice: str("notice")) } ?? missing
        default:
            // exec / plugin, or slash.exec's plain shape.
            self = .output(r["output"]?.string?.nonEmpty ?? "/\(command): no output", warning: str("warning"))
        }
    }
}

/// The text of a command's output row, or of a /btw or /bg answer.
public struct SlashNote: Hashable, Sendable {
    /// "/usage" over an output; the question over a side answer.
    public var header: String
    public var warning: String?
    /// For /btw and /bg: the gateway's task id, whether it is a background task, and whether it is still running.
    public var taskId: String?
    public var background = false
    public var pending = false
}

/// `commands.catalog` grouped for browsing: the registry's categories, then skills by use.
public struct SlashCatalog: Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var id: String { command }
        public let command: String
        public let detail: String
        public let isSkill: Bool
    }

    public struct Section: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        public var entries: [Entry]
    }

    public var sections: [Section]

    public init(_ r: JSON) {
        func pairs(_ json: JSON?) -> [(String, String)] {
            (json?.array ?? []).compactMap { p in
                guard let c = p.array?.first?.string?.nonEmpty else { return nil }
                return (c.hasPrefix("/") ? c : "/" + c, p.array?.dropFirst().first?.string ?? "")
            }
        }
        var seen: Set<String> = []
        sections = (r["categories"]?.array ?? []).compactMap { c in
            let entries = pairs(c["pairs"]).filter { SlashCommand.listed($0.0) && seen.insert($0.0).inserted }
                .map { Entry(command: $0.0, detail: $0.1, isSkill: false) }
            return entries.isEmpty ? nil : Section(name: c["name"]?.string ?? "Commands", entries: entries)
        }
        // Skills only come in the flat list; the backend leaves them out of the categories.
        let skills = r["skills"]?.object ?? [:]
        let usage = { (c: String) in skills[c]?["usage"]?.int ?? 0 }
        let skillRows = pairs(r["pairs"]).filter { skills[$0.0] != nil && !seen.contains($0.0) }
            .sorted { (usage($1.0), $0.0) < (usage($0.0), $1.0) }
            .map { Entry(command: $0.0, detail: $0.1, isSkill: true) }
        if !skillRows.isEmpty { sections.append(Section(name: "Skills", entries: skillRows)) }
    }

    /// Sections whose entries match `query` by name or description.
    public func filtered(_ query: String) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sections }
        return sections.compactMap { s in
            var s = s
            s.entries = s.entries.filter { $0.command.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
            return s.entries.isEmpty ? nil : s
        }
    }
}
