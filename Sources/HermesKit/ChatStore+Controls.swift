import Foundation

public struct TodoItem: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed, cancelled }
    public let id: String
    public var content: String
    public var status: Status
    public var parent: String?

    /// Reads the list itself or a `{todos: [...]}` wrapper; rows without an id, text or known status are dropped.
    public static func parse(_ json: JSON?) -> [TodoItem]? {
        guard let json else { return nil }
        if let inner = json["todos"] { return parse(inner) }
        guard let rows = json.array else { return nil }
        return rows.compactMap { r in
            guard let id = (r["id"]?.string ?? r["id"]?.int.map(String.init))?.trimmingCharacters(in: .whitespaces).nonEmpty,
                  let content = r["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                  let status = r["status"]?.string.flatMap(Status.init) else { return nil }
            let parent = r["parent"]?.string?.nonEmpty
            return TodoItem(id: id, content: content, status: status, parent: parent == id ? nil : parent)
        }
    }

    /// Parents before their children, with nesting depth. Unknown or cyclic parents fall back to the top level.
    public static func tree(_ todos: [TodoItem]) -> [(item: TodoItem, depth: Int)] {
        let ids = Set(todos.map(\.id))
        var kids: [String: [TodoItem]] = [:]
        var roots: [TodoItem] = []
        for t in todos {
            if let p = t.parent, ids.contains(p) { kids[p, default: []].append(t) } else { roots.append(t) }
        }
        var out: [(item: TodoItem, depth: Int)] = []
        var seen: Set<String> = []
        func walk(_ t: TodoItem, _ depth: Int) {
            guard seen.insert(t.id).inserted else { return }
            out.append((t, depth))
            for k in kids[t.id] ?? [] { walk(k, depth + 1) }
        }
        roots.forEach { walk($0, 0) }
        for t in todos where !seen.contains(t.id) { walk(t, 0) }
        return out
    }
}

/// Token and context counters from `session.usage`, `message.complete.usage` and `session.info.usage`.
public struct Usage: Hashable, Sendable {
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var estimated = false
    public var input = 0, output = 0, total = 0, compressions = 0
    /// Input plus what came from the prompt cache; the server counts the cached part in `total` only.
    public var prompt = 0
    public var costUSD: Double?

    public init?(_ json: JSON?) {
        guard let o = json?.object, !o.isEmpty else { return nil }
        contextUsed = o["context_used"]?.int
        contextMax = o["context_max"]?.int
        contextPercent = o["context_percent"]?.int
        estimated = o["context_estimated"]?.bool ?? false
        input = o["input"]?.int ?? 0
        output = o["output"]?.int ?? 0
        total = o["total"]?.int ?? 0
        prompt = o["prompt"]?.int ?? 0
        compressions = o["compressions"]?.int ?? 0
        costUSD = o["cost_usd"]?.double
    }

    /// Prompt tokens served from or written to the cache, which `input` leaves out.
    public var cached: Int { max(0, prompt - input) }

    /// Context fill from 0 to 1, or nil before the model's window is known.
    public var fraction: Double? {
        if let p = contextPercent, contextMax ?? 0 > 0 { return min(1, max(0, Double(p) / 100)) }
        guard let used = contextUsed, let max = contextMax, max > 0 else { return nil }
        return min(1, Double(used) / Double(max))
    }
}

public struct ContextCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let tokens: Int
}

public struct ContextBreakdown: Sendable {
    public var categories: [ContextCategory]
    /// The breakdown's own context numbers, for when no usage tick has arrived yet.
    public var usage: Usage?
}

extension ChatStore {
    /// Hermes' reasoning levels in ascending order (shared/src/reasoning-effort.ts); "none" turns thinking off.
    public static let reasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    public var fastAvailable: Bool { fastUnsupportedModel != model }
    /// True when tool calls run without asking: this chat's YOLO or approvals turned off in the Hermes config.
    public var approvalsOff: Bool { yolo || approvalMode == "off" }

    // MARK: - Actions

    public func setReasoning(_ level: String) async {
        if let r = await configSet("reasoning", level) { reasoningEffort = r["value"]?.string ?? level }
    }

    public func setFast(_ on: Bool) async {
        do {
            let r = try await configSetThrowing("fast", on ? "fast" : "normal")
            fast = (r["value"]?.string ?? "normal") != "normal"
        } catch GatewayError.rpc(4002, _) {
            fastUnsupportedModel = model
        } catch {
            alert = error.localizedDescription
        }
    }

    public func setYolo(_ on: Bool) async {
        if let r = await configSet("yolo", on ? "1" : "0") { yolo = r["value"]?.string == "1" }
    }

    public func retry() async {
        guard let text = retryText else { return }
        await send(text)
    }

    public func contextBreakdown() async -> ContextBreakdown? {
        guard let sid = runtimeId,
              let r = try? await gateway.call("session.context_breakdown", ["session_id": .string(sid)]) else { return nil }
        let categories = (r["categories"]?.array ?? []).compactMap { c -> ContextCategory? in
            guard let id = c["id"]?.string else { return nil }
            return ContextCategory(id: id, label: c["label"]?.string ?? id, tokens: c["tokens"]?.int ?? 0)
        }
        return ContextBreakdown(categories: categories, usage: Usage(r))
    }

    /// Session-scoped config change; never sends `scope`, so the user's global settings stay untouched.
    private func configSet(_ key: String, _ value: String) async -> JSON? {
        do { return try await configSetThrowing(key, value) } catch {
            alert = error.localizedDescription
            return nil
        }
    }

    private func configSetThrowing(_ key: String, _ value: String) async throws -> JSON {
        let sid = try await ensureSession()
        return try await gateway.call("config.set", ["key": .string(key), "session_id": .string(sid), "value": .string(value)])
    }

    // MARK: - Folding

    func resetControls() {
        todos = []
        todoRevision = -1
        usage = nil
        queued = []
        queue = []
        queuePaused = false
        queueEditing = nil
        steerFeedback = nil
        control = nil
        controlVersion += 1
        pauseReasserts = nil
        notes = [:]
        retryText = nil
        reasoningEffort = ""
        fast = false
        yolo = false
        approvalMode = ""
        subagents = SubagentRoster()
    }

    /// Runs before the transcript folding in `handle`, for events of the open chat.
    func handleControls(_ type: String, _ p: JSON) {
        foldSubagents(type, p)
        foldSlash(type, p)
        foldControl(type, p)
        switch type {
        case "message.start":
            retryText = nil
            // The server runs queued messages in order, one turn each.
            if !queued.isEmpty {
                var next = queued.removeFirst()
                next.date = Date()
                items.append(next)
                turnStartedAt = Date()
            }
        case "todo.updated", "tool.complete":
            applyTodos(p["todos"], revision: p["revision"]?.int)
        case "session.usage":
            if let u = Usage(p["usage"]) { usage = u }
        case "message.complete":
            if let u = Usage(p["usage"]) { usage = u }
            if p["status"]?.string == "error", p["error_surface"]?["retryable"]?.bool == true {
                retryText = items.last { $0.kind == .user }?.text
            }
        default:
            break
        }
    }

    func applyControlInfo(_ info: JSON) {
        // Lazy sessions report a reduced info shape, so only overwrite what is present.
        if let r = info["reasoning_effort"]?.string { reasoningEffort = r }
        if let f = info["fast"]?.bool { fast = f }
        if let y = info["yolo"]?.bool { yolo = y }
        if let m = info["approval_mode"]?.string { approvalMode = m }
        if let u = Usage(info["usage"]) { usage = u }
    }

    /// Where a message sent to a busy session ended up, per `prompt.submit`'s status.
    func placeSubmitted(_ item: ChatItem, status: String?) {
        if status == "queued" {
            queued.append(item)
            return
        }
        items.append(item)
        if let note = Self.submitNote(status) { notes[item.id] = note }
    }

    /// `session.resume` extras: the running turn's partial reply, a queued message and the todo list,
    /// so a chat reopened mid-turn looks the way it did.
    func applySnapshotExtras(_ s: JSON) {
        queued = s["queued"]?["user"]?.string?.nonEmpty.map { [userItem(id: localId(), $0)] } ?? []
        todos = []
        todoRevision = -1
        if let state = s["todo_state"] { applyTodos(state["todos"], revision: state["revision"]?.int) }
        guard let f = s["inflight"] else { return }
        // The turn's user row is persisted at submit, so it is usually already the last user message.
        if let user = f["user"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let shown = userItem(id: localId(), user)
            let last = items.last { shown.kind == .system ? $0.startsTurn : $0.kind == .user }
            if last?.kind != shown.kind || last?.quotes != shown.quotes || last?.text.trimmingCharacters(in: .whitespacesAndNewlines) != shown.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                items.append(shown)
            }
        }
        if let text = f["assistant"]?.string?.nonEmpty {
            items.append(ChatItem(id: localId(), kind: .assistant, text: text, streaming: f["streaming"]?.bool ?? running))
        }
        if f["error"]?.string?.nonEmpty != nil {
            items.append(ChatItem(id: localId(), kind: .error, text: Self.turnErrorText(f)))
            if f["error_surface"]?["retryable"]?.bool == true { retryText = items.last { $0.kind == .user }?.text }
        }
    }

    private func applyTodos(_ json: JSON?, revision: Int?) {
        guard let list = TodoItem.parse(json) else { return }
        if let revision {
            guard revision >= todoRevision else { return }
            todoRevision = revision
        }
        todos = list
    }

    // MARK: - Labels

    public static func submitNote(_ status: String?) -> String? {
        switch status {
        case "steered": "Steered the running turn"
        case "redirected": "Redirected the running turn"
        default: nil
        }
    }

    /// The error row for a failed turn: the server's message, else its error code, plus when a limit lifts.
    public static func turnErrorText(_ p: JSON) -> String {
        let surface = p["error_surface"]
        var text = p["error"]?.string?.nonEmpty
            ?? surface?["code"]?.string?.nonEmpty.map { $0.replacingOccurrences(of: "_", with: " ").capitalizingFirst }
            ?? "The turn failed."
        if let t = surface?["resets_at"]?.double {
            text += " Resets at \(Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened))."
        }
        return text
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Gateway {
    /// Whether the Hermes config asks before risky tool calls in every chat (approvals.mode is not "off").
    public func approvalsRequired() async throws -> Bool {
        try await call("config.get", ["key": "approvals.mode"])["value"]?.string != "off"
    }

    /// Turns approvals on or off for every chat in the Hermes config (approvals.mode manual/off) and returns
    /// what the server stored. It re-sends session.info to the live sessions, so open chats follow.
    public func setApprovalsRequired(_ on: Bool) async throws -> Bool {
        let r = try await call("config.set", ["key": "yolo", "scope": "global", "value": .string(on ? "0" : "1")])
        return r["value"]?.string != "1"
    }
}
