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
    /// `agent` is a message another bot delivered into this chat.
    public enum Kind: Sendable { case user, agent, assistant, tool, error }
    public let id: String
    public var kind: Kind
    public var text = ""
    public var reasoning = ""
    public var streaming = false
    public var tool: ToolCall?
    public var agent: AgentMessage?
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
    /// The profile (bot) this store talks to; nil is the gateway's own profile.
    public let profile: String?
    public private(set) var sessions: [SessionRow] = []
    /// False until the first session list arrives, so an empty list isn't mistaken for "no chats".
    public private(set) var sessionsLoaded = false
    /// Stored id of the open chat; nil means a new, unsent chat.
    public private(set) var selectedId: String?
    public private(set) var runtimeId: String?
    /// Stored id of the profile's "Bot Chat" once `openBotChat` found or made it.
    public private(set) var canonicalId: String?
    /// Shown as the Bot Chat's title instead of its stored one.
    public var botChatTitle: String?
    /// Why the Bot Chat couldn't be opened; the UI offers a retry instead of creating another one.
    public private(set) var botChatError: String?
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

    public init(gateway: Gateway, profile: String? = nil) {
        self.gateway = gateway
        self.profile = profile
        gateway.listen(self, event: { [weak self] in self?.handle($0) },
                       request: { [weak self] in self?.claim($0) ?? false },
                       connected: { [weak self] in self?.reconnected() })
    }

    public var title: String {
        guard let id = selectedId else { return "New chat" }
        if id == canonicalId, let botChatTitle { return botChatTitle }
        return sessions.first { $0.id == id }?.title.nonEmpty ?? "Chat"
    }

    // MARK: - Actions

    public func refreshSessions() async {
        guard let r = try? await gateway.call("session.list", scoped(["limit": 200])) else { return }
        sessionsLoaded = true
        sessions = (r["sessions"]?.array ?? []).compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return SessionRow(id: id, title: s["title"]?.string ?? "", preview: s["preview"]?.string ?? "",
                              startedAt: Date(timeIntervalSince1970: s["started_at"]?.double ?? 0),
                              messageCount: s["message_count"]?.int ?? 0)
        }
    }

    public func open(_ storedId: String?) async {
        do { try await load(storedId) } catch { alert = error.localizedDescription }
    }

    private func load(_ storedId: String?) async throws {
        // Re-opening the same chat (after a reconnect) keeps what's on screen until the resume lands,
        // so a failed resume doesn't blank the transcript.
        if storedId == nil || storedId != selectedId {
            await detach()
            selectedId = storedId
            items = []
            requests = []
            running = false
            statusText = nil
        }
        guard let storedId else { return }
        loading = true
        defer { loading = false }
        let snap = try await gateway.call("session.resume", scoped(["session_id": .string(storedId), "inline_images": false]))
        guard selectedId == storedId else { return }
        apply(snapshot: snap)
    }

    /// Opens the profile's one "Bot Chat" (desktop plugins/hermes-bots/canonical-chat.ts). It is created
    /// only when the server confirms none exists: a second one would fork the bot's history, so any
    /// doubt ends in `botChatError` and a retry instead.
    /// - Parameter known: the roster's `canonical_session` id (resolved_id first), if it has one.
    public func openBotChat(known: String?) async {
        botChatError = nil
        do {
            var id = known
            if id == nil { id = try await findBotChat(mustExist: false) }
            if id == nil { id = try await createBotChat() }
            canonicalId = id
            if selectedId != id || runtimeId == nil { try await load(id) }
        } catch {
            botChatError = error.localizedDescription
        }
    }

    private static let canonicalTitle = "Bot Chat"

    /// Title lookups follow compression, so `resolved_id` is the live tip of the chat.
    private func findBotChat(mustExist: Bool) async throws -> String? {
        let r = try await gateway.call("session.list", scoped(["title": .string(Self.canonicalTitle), "include_hidden": true, "limit": 200]))
        let row = (r["sessions"]?.array ?? []).first { s in
            let root = s["root_title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return root == Self.canonicalTitle || (root.isEmpty && s["title"]?.string?.trimmingCharacters(in: .whitespaces) == Self.canonicalTitle)
        }
        if let row, let id = row["resolved_id"]?.string?.nonEmpty ?? row["id"]?.string { return id }
        if mustExist { throw GatewayError.rpc(0, "Couldn't confirm this bot's Bot Chat, so no new one was started. Try again.") }
        return nil
    }

    private func createBotChat() async throws -> String? {
        await detach()
        let created = try await gateway.call("session.create", scoped([
            "title": .string(Self.canonicalTitle), "hidden": true, "follow_profile_config": true]))
        guard let sid = created["session_id"]?.string, let stored = created["stored_session_id"]?.string else {
            throw GatewayError.offline
        }
        do {
            // session.create is lazy; titling now persists the row so the next lookup finds it.
            _ = try await gateway.call("session.title", ["session_id": .string(sid), "title": .string(Self.canonicalTitle)])
        } catch GatewayError.rpc(4022, _) {
            // Another client took the title in the meantime: adopt its chat. Ours is empty and gets pruned.
            _ = try? await gateway.call("session.close", ["session_id": .string(sid)])
            return try await findBotChat(mustExist: true)
        }
        selectedId = stored
        runtimeId = sid
        items = []
        requests = []
        running = false
        statusText = nil
        applyInfo(created["info"])
        return stored
    }

    /// `note` is appended to what the agent receives but not shown (the @mention note).
    public func send(_ text: String, note: String = "") async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let sid = try await ensureSession()
            items.append(ChatItem(id: localId(), kind: .user, text: text))
            running = true
            _ = try await gateway.call("prompt.submit", ["session_id": .string(sid), "text": .string(text + note)])
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
            try await Self.deleteSession(storedId, profile: profile, via: gateway)
            sessions.removeAll { $0.id == storedId }
        } catch {
            alert = error.localizedDescription
        }
    }

    /// The server refuses deletes (4023) until a just-closed session finishes tearing down, so retry briefly.
    public static func deleteSession(_ storedId: String, profile: String? = nil, via gateway: Gateway) async throws {
        var params: [String: JSON] = ["session_id": .string(storedId)]
        if let profile { params["profile"] = .string(profile) }
        for attempt in 1... {
            do {
                _ = try await gateway.call("session.delete", params)
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
            let sid = try await ensureSession()
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

    /// The live session for the chat on screen: reattaches to the selected chat if its runtime
    /// was lost (failed reconnect), or creates one for a new chat.
    private func ensureSession() async throws -> String {
        if let sid = runtimeId { return sid }
        if let id = selectedId {
            apply(snapshot: try await gateway.call("session.resume", scoped(["session_id": .string(id), "inline_images": false])))
        } else {
            let created = try await gateway.call("session.create", scoped([:]))
            runtimeId = created["session_id"]?.string
            selectedId = created["stored_session_id"]?.string
            applyInfo(created["info"])
        }
        guard let sid = runtimeId else { throw GatewayError.offline }
        return sid
    }

    // MARK: - Server requests

    public func answer(_ request: ServerRequest, result: JSON) {
        gateway.respond(request, result: result)
        requests.removeAll { $0.id == request.id }
    }

    /// Takes the requests meant for the chat on screen; other stores get the rest.
    func claim(_ r: ServerRequest) -> Bool {
        guard let sid = runtimeId, r.sessionId == sid else { return false }
        receive(r)
        return true
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
        if selectedId == nil || (selectedId != canonicalId && !sessions.contains(where: { $0.id == selectedId })) {
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
            if let agent = AgentMessage.parse(text) {
                return ChatItem(id: "row-\(rowId)", kind: .agent, text: agent.body, agent: agent)
            }
            // The @mention note is for the agent; the user only typed what precedes it.
            let shown = text.range(of: BotStore.mentionNoteStart).map { String(text[..<$0.lowerBound]) } ?? text
            return ChatItem(id: "row-\(rowId)", kind: .user, text: shown)
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
    /// A Bot Chat stays open, like on the desktop: the bot may start a turn in it at any time.
    private func detach() async {
        guard let sid = runtimeId else { return }
        runtimeId = nil
        if !running, selectedId != canonicalId || canonicalId == nil {
            _ = try? await gateway.call("session.close", scoped(["session_id": .string(sid)]))
        }
    }

    /// Session methods take `profile` to reach another profile's database; runtime ids are already scoped.
    private func scoped(_ params: [String: JSON]) -> [String: JSON] {
        guard let profile else { return params }
        return params.merging(["profile": .string(profile)]) { a, _ in a }
    }

    private func localId() -> String {
        nextLocalId += 1
        return "local-\(nextLocalId)"
    }
}

public extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
