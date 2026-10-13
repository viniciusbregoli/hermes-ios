import Foundation
import Observation

public struct SessionRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var preview: String
    public var startedAt: Date
    public var messageCount: Int
}

public struct ToolCall: Hashable, Sendable {
    public var id: String
    public var name: String
    public var context: String
    public var args: JSON?
    public var result: JSON?
    public var summary: String?
    public var diff: String?
    public var duration: Double?
    public var running: Bool
}

public struct ChatItem: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case user, assistant, tool, error }
    public let id: String
    public var kind: Kind
    public var text = ""
    public var reasoning = ""
    public var streaming = false
    public var tool: ToolCall?
}

public struct ModelProvider: Identifiable, Hashable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let models: [String]
}

/// App state for the chat UI. Turns gateway events into transcript items, the same way the
/// desktop renderer folds `message.*` / `tool.*` events into its thread.
@MainActor @Observable
public final class ChatStore {
    public let gateway: Gateway
    public private(set) var sessions: [SessionRow] = []
    /// Stored id of the open chat; nil means a new, unsent chat.
    public private(set) var selectedId: String?
    public private(set) var runtimeId: String?
    public private(set) var items: [ChatItem] = []
    public private(set) var loading = false
    public private(set) var running = false
    public private(set) var statusText: String?
    public private(set) var model = ""
    public private(set) var provider = ""
    public private(set) var providers: [ModelProvider] = []
    /// Approvals, clarify questions, sudo/secret prompts waiting for the user.
    public private(set) var requests: [ServerRequest] = []
    public var alert: String?

    @ObservationIgnored private var nextLocalId = 0

    public init(gateway: Gateway) {
        self.gateway = gateway
        gateway.onEvent = { [weak self] in self?.handle($0) }
        gateway.onRequest = { [weak self] in self?.receive($0) }
        gateway.onConnected = { [weak self] in self?.reconnected() }
    }

    public var title: String {
        guard let id = selectedId else { return "New chat" }
        return sessions.first { $0.id == id }?.title.nonEmpty ?? "Chat"
    }

    // MARK: - Actions

    public func refreshSessions() async {
        guard let r = try? await gateway.call("session.list", ["limit": 200]) else { return }
        sessions = (r["sessions"]?.array ?? []).compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return SessionRow(id: id, title: s["title"]?.string ?? "", preview: s["preview"]?.string ?? "",
                              startedAt: Date(timeIntervalSince1970: s["started_at"]?.double ?? 0),
                              messageCount: s["message_count"]?.int ?? 0)
        }
    }

    public func open(_ storedId: String?) async {
        await detach()
        selectedId = storedId
        items = []
        requests = []
        running = false
        statusText = nil
        guard let storedId else { return }
        loading = true
        defer { loading = false }
        do {
            let snap = try await gateway.call("session.resume", ["session_id": .string(storedId), "inline_images": false])
            guard selectedId == storedId else { return }
            apply(snapshot: snap)
        } catch {
            alert = error.localizedDescription
        }
    }

    public func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            if runtimeId == nil {
                let created = try await gateway.call("session.create")
                runtimeId = created["session_id"]?.string
                selectedId = created["stored_session_id"]?.string
                applyInfo(created["info"])
            }
            guard let sid = runtimeId else { return }
            items.append(ChatItem(id: localId(), kind: .user, text: text))
            running = true
            _ = try await gateway.call("prompt.submit", ["session_id": .string(sid), "text": .string(text)])
        } catch {
            running = false
            items.append(ChatItem(id: localId(), kind: .error, text: error.localizedDescription))
        }
    }

    public func interrupt() async {
        guard let sid = runtimeId else { return }
        _ = try? await gateway.call("session.interrupt", ["session_id": .string(sid)])
    }

    public func delete(_ storedId: String) async {
        if storedId == selectedId { await open(nil) }
        do {
            try await Self.deleteSession(storedId, via: gateway)
            sessions.removeAll { $0.id == storedId }
        } catch {
            alert = error.localizedDescription
        }
    }

    /// The server refuses deletes (4023) until a just-closed session finishes tearing down, so retry briefly.
    public static func deleteSession(_ storedId: String, via gateway: Gateway) async throws {
        for attempt in 1... {
            do {
                _ = try await gateway.call("session.delete", ["session_id": .string(storedId)])
                return
            } catch GatewayError.rpc(4023, _) where attempt < 6 {
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    public func loadModels() async {
        var params: [String: JSON] = [:]
        if let sid = runtimeId { params["session_id"] = .string(sid) }
        guard let r = try? await gateway.call("model.options", params) else { return }
        providers = (r["providers"]?.array ?? []).compactMap { p in
            guard let slug = p["slug"]?.string, let models = p["models"]?.array, !models.isEmpty,
                  p["authenticated"]?.bool != false else { return nil }
            return ModelProvider(slug: slug, name: p["name"]?.string ?? slug, models: models.compactMap(\.string))
        }
        if model.isEmpty { model = r["model"]?.string ?? "" }
        if provider.isEmpty { provider = r["provider"]?.string ?? "" }
    }

    /// Returns a confirmation message when the server wants the user to OK an expensive model;
    /// call again with `confirmed: true` to proceed.
    public func setModel(_ model: String, provider: String, confirmed: Bool = false) async -> String? {
        do {
            if runtimeId == nil {
                let created = try await gateway.call("session.create")
                runtimeId = created["session_id"]?.string
                selectedId = nil
            }
            guard let sid = runtimeId else { return nil }
            var params: [String: JSON] = ["session_id": .string(sid), "key": "model",
                                          "value": .string("\(model) --provider \(provider) --session")]
            if confirmed { params["confirm_expensive_model"] = true }
            let r = try await gateway.call("config.set", params)
            if r["confirm_required"]?.bool == true { return r["confirm_message"]?.string ?? "This model is expensive. Use it anyway?" }
            self.model = model
            self.provider = provider
            if let w = r["warning"]?.string, !w.isEmpty { alert = w }
        } catch {
            alert = error.localizedDescription
        }
        return nil
    }

    // MARK: - Server requests

    public func answer(_ request: ServerRequest, result: JSON) {
        gateway.respond(request, result: result)
        requests.removeAll { $0.id == request.id }
    }

    func receive(_ r: ServerRequest) {
        switch r.method {
        case "approval", "clarify", "sudo", "secret":
            requests.removeAll { $0.id == r.id }
            requests.append(r)
        default:
            // Desktop-only surfaces (previews, terminal reads, tours, vault UI).
            gateway.reject(r)
        }
    }

    // MARK: - Events

    private func handle(_ e: GatewayEvent) {
        let p = e.payload
        if e.sessionId.isEmpty {
            if e.type == "sessions.changed" { Task { await refreshSessions() } }
            return
        }
        guard e.sessionId == runtimeId else {
            if e.type == "session.title" { Task { await refreshSessions() } }
            return
        }
        switch e.type {
        case "message.start":
            running = true
            statusText = nil
        case "message.delta":
            appendAssistant(text: p["text"]?.string ?? "")
        case "reasoning.delta":
            appendAssistant(reasoning: p["text"]?.string ?? "")
        case "reasoning.available":
            // A whole block from a non-streaming provider; skip it if the deltas already arrived.
            if !(items.last.map { $0.kind == .assistant && $0.streaming && !$0.reasoning.isEmpty } ?? false) {
                appendAssistant(reasoning: p["text"]?.string ?? "")
            }
        // thinking.delta is the TUI's legacy spinner text ("( •_•)>⌐■-■ brainstorming..."); the desktop drops it too.
        case "message.interim":
            if p["already_streamed"]?.bool != true { appendAssistant(text: p["text"]?.string ?? "") }
            closeAssistant()
        case "tool.generating":
            statusText = "Preparing \(p["name"]?.string ?? "tool")…"
        case "tool.start":
            closeAssistant()
            statusText = nil
            let id = p["tool_id"]?.string ?? localId()
            items.append(ChatItem(id: "tool-\(id)", kind: .tool, tool: ToolCall(
                id: id, name: p["name"]?.string ?? "tool", context: p["context"]?.string ?? "",
                args: p["args"], running: true)))
        case "tool.complete":
            let id = p["tool_id"]?.string ?? ""
            if let i = items.lastIndex(where: { $0.tool?.id == id }) {
                items[i].tool?.running = false
                items[i].tool?.result = p["result"]
                items[i].tool?.summary = p["summary"]?.string
                items[i].tool?.diff = p["inline_diff"]?.string
                items[i].tool?.duration = p["duration_s"]?.double
            }
        case "status.update":
            statusText = p["text"]?.string?.nonEmpty
        case "message.complete":
            complete(p)
        case "error":
            items.append(ChatItem(id: localId(), kind: .error, text: p["message"]?.string ?? "Error"))
        case "session.info":
            applyInfo(p)
        case "session.title":
            if let t = p["title"]?.string, let id = selectedId, let i = sessions.firstIndex(where: { $0.id == id }) {
                sessions[i].title = t
            }
        case "approval.cancelled", "request.cancel":
            let id = p["request_id"]?.string ?? p["id"]?.string
            requests.removeAll { $0.id == id || $0.rpcId.string == id }
        default:
            break
        }
    }

    private func complete(_ p: JSON) {
        let text = p["text"]?.string ?? ""
        let turnStart = items.lastIndex { $0.kind == .user } ?? -1
        let streamed = items.indices.contains { $0 > turnStart && items[$0].kind == .assistant && !items[$0].text.isEmpty }
        if p["response_transformed"]?.bool == true, let i = items.lastIndex(where: { $0.kind == .assistant }), i > turnStart {
            items[i].text = text
        } else if !streamed, !text.isEmpty, p["response_previewed"]?.bool != true, p["response_reused"]?.bool != true {
            appendAssistant(text: text)
        }
        closeAssistant()
        if p["status"]?.string == "error" {
            let msg = p["error"]?.string ?? p["error_surface"]?["code"]?.string ?? "The turn failed."
            items.append(ChatItem(id: localId(), kind: .error, text: msg))
        }
        running = false
        statusText = nil
        if selectedId == nil || !sessions.contains(where: { $0.id == selectedId }) {
            Task { await refreshSessions() }
        }
    }

    private func appendAssistant(text: String = "", reasoning: String = "") {
        if let last = items.indices.last, items[last].kind == .assistant, items[last].streaming {
            items[last].text += text
            items[last].reasoning += reasoning
        } else {
            items.append(ChatItem(id: localId(), kind: .assistant, text: text, reasoning: reasoning, streaming: true))
        }
    }

    private func closeAssistant() {
        if let last = items.indices.last, items[last].kind == .assistant { items[last].streaming = false }
    }

    // MARK: - Snapshots

    func apply(snapshot s: JSON) {
        runtimeId = s["session_id"]?.string
        applyInfo(s["info"])
        running = s["running"]?.bool ?? false
        items = (s["messages"]?.array ?? []).compactMap(item(from:))
        for r in s["open_requests"]?.array ?? [] {
            receive(ServerRequest(rpcId: r["id"] ?? .null, method: r["method"]?.string ?? "", params: r["params"] ?? .null))
        }
    }

    private func item(from m: JSON) -> ChatItem? {
        let rowId = m["row_id"]?.int.map(String.init) ?? localId()
        let text = m["text"]?.string ?? m["content"]?.string ?? ""
        switch m["role"]?.string {
        case "user":
            return ChatItem(id: "row-\(rowId)", kind: .user, text: text)
        case "assistant":
            let reasoning = m["reasoning"]?.string ?? ""
            guard !text.isEmpty || !reasoning.isEmpty else { return nil }
            return ChatItem(id: "row-\(rowId)", kind: .assistant, text: text, reasoning: reasoning)
        case "tool":
            let id = m["tool_call_id"]?.string ?? rowId
            var args: JSON? = nil
            if let a = m["args"]?.object { args = .object(a) }
            return ChatItem(id: "row-\(rowId)", kind: .tool, tool: ToolCall(
                id: id, name: m["name"]?.string ?? "tool", context: m["context"]?.string ?? "",
                args: args, result: m["content"], running: false))
        default:
            return nil
        }
    }

    private func applyInfo(_ info: JSON?) {
        guard let info else { return }
        if let m = info["model"]?.string, !m.isEmpty { model = m }
        if let p = info["provider"]?.string, !p.isEmpty { provider = p }
        if let r = info["running"]?.bool { running = r }
        if let stored = info["stored_session_id"]?.string, selectedId == nil { selectedId = stored }
    }

    // MARK: - Lifecycle

    private func reconnected() {
        Task {
            await refreshSessions()
            // ponytail: re-resume reloads the whole transcript; session.events.since would replay
            // only the missed deltas if reconnects mid-stream become common.
            if let id = selectedId {
                runtimeId = nil
                await open(id)
            }
        }
    }

    /// Frees the server-side agent for the chat we are leaving, unless it is still working.
    private func detach() async {
        guard let sid = runtimeId else { return }
        runtimeId = nil
        if !running { _ = try? await gateway.call("session.close", ["session_id": .string(sid)]) }
    }

    private func localId() -> String {
        nextLocalId += 1
        return "local-\(nextLocalId)"
    }
}

public extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
