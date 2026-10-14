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
    /// `agent` is a message another bot delivered into this chat; `notice` a slash command's output
    /// and `side` a /btw or /bg answer, both local to this app.
    public enum Kind: Sendable { case user, agent, assistant, tool, error, notice, side }
    public let id: String
    public var kind: Kind
    public var text = ""
    public var reasoning = ""
    public var streaming = false
    public var tool: ToolCall?
    public var agent: AgentMessage?
    /// Attachments on a user message.
    public var images: [ImageSource] = []
    public var files: [String] = []
    /// When the item was written (transcript timestamp) or arrived live; times turns.
    public var date: Date?
    public var slash: SlashNote?
}

/// When a live turn ended and whether the user stopped it.
public struct TurnEnd: Hashable, Sendable {
    public var at: Date
    public var stopped: Bool
    public init(at: Date, stopped: Bool) { self.at = at; self.stopped = stopped }
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
    public internal(set) var sessions: [SessionRow] = []
    /// Stored ids of pinned chats, mirrored from the server's `pinned` flag.
    public internal(set) var pinned: Set<String> = []
    /// False until the first session list arrives, so an empty list isn't mistaken for "no chats".
    public private(set) var sessionsLoaded = false
    /// Stored id of the open chat; nil means a new, unsent chat.
    public private(set) var selectedId: String?
    public private(set) var runtimeId: String? {
        didSet { if runtimeId != oldValue { lastSeq = 0 } }
    }
    /// Stored id of the profile's "Bot Chat" once `openBotChat` found or made it.
    public private(set) var canonicalId: String?
    /// Shown as the Bot Chat's title instead of its stored one.
    public var botChatTitle: String?
    /// Why the Bot Chat couldn't be opened; the UI offers a retry instead of creating another one.
    public private(set) var botChatError: String?
    public internal(set) var items: [ChatItem] = []
    public private(set) var loading = false
    /// Set by `show`: a transcript to read, with no session behind it.
    public private(set) var readOnly = false
    @ObservationIgnored private var shownTitle = ""
    public internal(set) var running = false
    public private(set) var statusText: String?
    public private(set) var model = ""
    public private(set) var provider = ""
    public private(set) var providers: [ModelProvider] = []
    /// Approvals, clarify questions, sudo/secret prompts waiting for the user.
    public private(set) var requests: [ServerRequest] = []
    public var alert: String?
    /// Photos and files picked in the composer for the next message.
    public internal(set) var attachments: [Attachment] = []
    /// When the running turn started, for the working timer.
    public internal(set) var turnStartedAt: Date?
    /// How live turns ended, by the id of the message that started each one.
    public internal(set) var turnEnds: [String: TurnEnd] = [:]
    /// Counts turns that finished without an error, so the open chat can answer with a haptic.
    public internal(set) var finishedTurns = 0
    /// The chat is the screen being shown; set by the navigation that owns it.
    public var onScreen = false { didSet { markRead() } }
    public var appActive = true { didSet { markRead() } }
    public var visible: Bool { onScreen && appActive }
    /// Chats whose turn finished while they were off screen, with when; kept across launches.
    public internal(set) var unread: [String: Date] = [:] {
        didSet { if profile == nil, unread != oldValue { defaults.set(unread, forKey: Self.unreadKey) } }
    }
    /// Called when a turn finishes while the chat is off screen, with the chat title and the reply.
    @ObservationIgnored public var onTurnFinished: ((_ title: String, _ reply: String) -> Void)?

    // Per-chat controls and live status; folded in ChatStore+Controls.swift.
    public internal(set) var todos: [TodoItem] = []
    @ObservationIgnored var todoRevision = -1
    public internal(set) var usage: Usage?
    /// Messages the server queued to run after the current turn.
    public internal(set) var queued: [ChatItem] = []
    /// Follow-ups held on this device until the running turn ends; see Queue.swift.
    public internal(set) var queue: [QueuedMessage] = []
    /// Set when the user stopped a turn: the queue waits for `resumeQueue` instead of sending.
    public internal(set) var queuePaused = false
    /// The queued message the composer is editing; the queue holds until the edit ends.
    public var queueEditing: String? { didSet { if queueEditing == nil { drainQueue() } } }
    /// What became of the last steer or redirect, shown briefly over the composer.
    public var steerFeedback: String?
    /// Short labels under user messages that steered or redirected a running turn, by item id.
    public internal(set) var notes: [String: String] = [:]
    /// The user message to resend when the last turn failed with a retryable error.
    public internal(set) var retryText: String?
    public internal(set) var reasoningEffort = ""
    public internal(set) var fast = false
    /// The model that answered 4002 to fast mode; fast is hidden while it stays selected.
    public internal(set) var fastUnsupportedModel: String?
    public internal(set) var yolo = false
    public internal(set) var approvalMode = ""
    /// Delegated children of the open chat; folded in Subagents.swift.
    public internal(set) var subagents = SubagentRoster()
    @ObservationIgnored var pendingDelegation: PendingDelegation?
    @ObservationIgnored var tierLabelsLoaded = false

    /// Durable row ids of live user messages (from prompt.submit), and history rows a rewind renumbered;
    /// nil means the row is gone. Transcript rows carry theirs in the item id. See `rowId(of:)`.
    var rowIds: [String: Int?] = [:]
    /// Highest event seq handled for `runtimeId`, and the gateway epoch it counts in.
    @ObservationIgnored var lastSeq = 0
    @ObservationIgnored var seqEpoch: String?
    /// The open chat's live events, parked while a reconnect replay is in flight so they run after the gap.
    @ObservationIgnored var held: [GatewayEvent]?
    /// Where a turn this app didn't send begins in `items`, until the row that opened it is shown.
    @ObservationIgnored var openerAt: Int?

    @ObservationIgnored private var nextLocalId = 0
    @ObservationIgnored private let defaults: UserDefaults
    static let unreadKey = "chats.unread"

    public init(gateway: Gateway, profile: String? = nil, defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.profile = profile
        self.defaults = defaults
        // Only the Chats list shows dots; a bot's chats would overwrite its marks with their empty ones.
        if profile == nil { unread = defaults.dictionary(forKey: Self.unreadKey) as? [String: Date] ?? [:] }
        gateway.listen(self, event: { [weak self] in self?.handle($0) },
                       request: { [weak self] in self?.claim($0) ?? false },
                       connected: { [weak self] in self?.reconnected() })
    }

    public var title: String {
        if readOnly { return shownTitle }
        guard let id = selectedId else { return "New chat" }
        if id == canonicalId, let botChatTitle { return botChatTitle }
        return sessions.first { $0.id == id }?.title.nonEmpty ?? "Chat"
    }

    // MARK: - Actions

    private func markRead() {
        if visible, let id = selectedId { unread[id] = nil }
    }

    public func refreshSessions() async {
        guard let r = try? await gateway.call("session.list", scoped(["limit": 200])) else { return }
        applySessions(r)
        await refreshPins()
    }

    func applySessions(_ r: JSON) {
        sessionsLoaded = true
        sessions = SessionRow.parse(r["sessions"])
        let listed = Set(sessions.map(\.id))
        unread = unread.filter { listed.contains($0.key) }
    }

    public func open(_ storedId: String?) async {
        do { try await load(storedId) } catch { alert = error.localizedDescription }
    }

    /// Shows a stored chat's transcript without attaching an agent to it, so nothing can be sent (a routine's run).
    public func show(_ storedId: String, title: String) async {
        readOnly = true
        shownTitle = title
        selectedId = storedId
        loading = true
        defer { loading = false }
        do {
            // session.history needs a live session, so the stored transcript comes from the dashboard's REST read.
            var query = ["inline_images": "false"]
            if let profile { query["profile"] = profile }
            let messages = try await gateway.rest("GET", "api/sessions/\(storedId)/messages", query: query)["messages"]?.array ?? []
            items = messages.compactMap { m in
                // REST rows name their tool `tool_name`; the gateway's transcript calls it `name`.
                guard var o = m.object else { return nil }
                if o["name"] == nil, let tool = o["tool_name"] { o["name"] = tool }
                return item(from: .object(o))
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    private func load(_ storedId: String?) async throws {
        // Re-opening the same chat (after a reconnect) keeps what's on screen until the resume lands,
        // so a failed resume doesn't blank the transcript.
        if storedId == nil || storedId != selectedId {
            await handOffQueue()
            await detach()
            selectedId = storedId
            items = []
            requests = []
            attachments = []
            running = false
            statusText = nil
            turnStartedAt = nil
            turnEnds = [:]
            rowIds = [:]
            openerAt = nil
            resetControls()
        }
        guard let storedId else { return }
        unread[storedId] = nil
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

    /// `note` is appended to what the agent receives but not shown (the @mention note);
    /// `display` replaces the text in the bubble (a skill command's invocation instead of its body).
    /// While a turn runs, a text-only message is queued on this device instead (Queue.swift).
    public func send(_ text: String, note: String = "", display: String? = nil) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !attachmentsPending else { return }
        if running, attachments.isEmpty {
            queue.append(QueuedMessage(id: localId(), text: text, note: note, display: display))
            return
        }
        await submit(text, note: note, display: display, queued: running)
    }

    /// - Parameter queued: asks a busy server to queue the message rather than steer or redirect with it.
    /// - Returns: false when the message didn't reach the server.
    @discardableResult
    func submit(_ text: String, note: String, display: String?, queued: Bool) async -> Bool {
        var sent: [Attachment] = []
        do {
            let sid = try await ensureSession()
            sent = try await takeAttachments(for: sid)
            let bubble = ChatItem(id: localId(), kind: .user, text: display ?? text, images: sent.filter(\.isImage).map { .data($0.data) },
                                  files: sent.filter { !$0.isImage }.map(\.name), date: Date())
            // A busy session decides where the message goes (queue, steer, redirect), so wait for its answer.
            let busy = running
            if !busy {
                items.append(bubble)
                turnStartedAt = Date()
            }
            running = true
            retryText = nil
            var params: [String: JSON] = ["session_id": .string(sid), "text": .string(Attachment.promptText(text, sent) + note)]
            if queued { params["queued"] = true }
            let r = try await gateway.call("prompt.submit", params)
            let status = r["status"]?.string
            if busy {
                placeSubmitted(bubble, status: status)
            } else if status == "queued" {
                // The server started a turn of its own between our idle check and the submit.
                items.removeAll { $0.id == bubble.id }
                placeSubmitted(bubble, status: status)
            }
            bindRows(r, bubble: bubble.id)
            return true
        } catch {
            running = false
            // Still staged on the server, so a retry sends them with the same refs.
            if attachments.isEmpty { attachments = sent }
            turnStartedAt = nil
            items.append(ChatItem(id: localId(), kind: .error, text: error.localizedDescription, date: Date()))
            return false
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
    func ensureSession() async throws -> String {
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
        if e.sessionId == runtimeId, let seq = e.seq {
            if held != nil { held?.append(e); return }
            // Replayed and live copies of one event share a seq; the second is a duplicate.
            guard seq > lastSeq else { return }
            lastSeq = seq
            seqEpoch = gateway.replayEpoch
        }
        // Started while idle with nothing queued: a bot delivery or another server-side turn.
        let external = e.type == "message.start" && e.sessionId == runtimeId && !running && queued.isEmpty
        let p = e.payload
        if e.sessionId == runtimeId { handleControls(e.type, p) }
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
            if turnStartedAt == nil { turnStartedAt = Date() }
            if external {
                openerAt = items.count
                Task { await showOpener(final: false) }
            }
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
                args: p["args"], running: true), date: Date()))
        case "tool.complete":
            let id = p["tool_id"]?.string ?? ""
            if let i = items.lastIndex(where: { $0.tool?.id == id }) {
                items[i].tool?.running = false
                items[i].tool?.result = p["result"]
                items[i].tool?.summary = p["summary"]?.string
                items[i].tool?.diff = p["inline_diff"]?.string
                items[i].tool?.duration = p["duration_s"]?.double
                if let args = p["args"], args.object?.isEmpty == false { items[i].tool?.args = args }
            }
        case "status.update":
            statusText = p["text"]?.string?.nonEmpty
        case "message.complete":
            complete(p)
        case "error":
            items.append(ChatItem(id: localId(), kind: .error, text: p["message"]?.string ?? "Error", date: Date()))
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
        let status = p["status"]?.string
        if status == "error" {
            items.append(ChatItem(id: localId(), kind: .error, text: Self.turnErrorText(p), date: Date()))
        }
        if let start = items.last(where: { $0.kind == .user || $0.kind == .agent }) {
            turnEnds[start.id] = TurnEnd(at: Date(), stopped: status == "interrupted")
        }
        if openerAt != nil { Task { await showOpener(final: true) } }
        running = false
        statusText = nil
        turnStartedAt = nil
        if status != "error" { finishedTurns += 1 }
        if !visible {
            if let id = selectedId, profile == nil { unread[id] = Date() }
            let reply = items.last { $0.kind == .assistant }?.text ?? ""
            onTurnFinished?(title, status == "error" ? "The turn failed." : reply.nonEmpty ?? "Finished.")
        }
        if selectedId == nil || (selectedId != canonicalId && !sessions.contains(where: { $0.id == selectedId })) {
            Task { await refreshSessions() }
        }
        if status == "interrupted", !queue.isEmpty { queuePaused = true }
        drainQueue()
    }

    /// The server streams the reply to a turn it started (a bot delivery runs on the user role) but not
    /// the message that opened it, so read it from the transcript. Tried at the start and, in case the row
    /// wasn't written yet, again at the end.
    private func showOpener(final: Bool) async {
        guard let sid = runtimeId,
              let r = try? await gateway.call("session.history", ["session_id": .string(sid)]),
              runtimeId == sid else { return }
        placeOpener(from: r["messages"]?.array ?? [], final: final)
    }

    func placeOpener(from messages: [JSON], final: Bool) {
        guard let at = openerAt.map({ min($0, items.count) }) else { return }
        guard let item = missingOpener(in: messages, before: at) else {
            if final { openerAt = nil }
            return
        }
        // A turn that already ended filed its end under the previous turn's opener.
        if !running, let previous = items[..<at].last(where: { $0.kind == .user || $0.kind == .agent }),
           let end = turnEnds.removeValue(forKey: previous.id) {
            turnEnds[item.id] = end
        }
        items.insert(item, at: at)
        openerAt = nil
    }

    /// The transcript's last user-role row, unless the chat already shows it: by row id, or as the
    /// message this app sent just before `index`.
    func missingOpener(in messages: [JSON], before index: Int) -> ChatItem? {
        guard let row = messages.last(where: { $0["role"]?.string == "user" }), let rowId = row["row_id"]?.int,
              !items.contains(where: { self.rowId(of: $0) == rowId }), let item = item(from: row) else { return nil }
        let shown = items.prefix(index).last { $0.kind == .user || $0.kind == .agent }
        if let shown, shown.id.hasPrefix("local-"), shown.text == item.text { return nil }
        return item
    }

    private func appendAssistant(text: String = "", reasoning: String = "") {
        if let last = items.indices.last, items[last].kind == .assistant, items[last].streaming {
            items[last].text += text
            items[last].reasoning += reasoning
        } else {
            items.append(ChatItem(id: localId(), kind: .assistant, text: text, reasoning: reasoning, streaming: true, date: Date()))
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
        turnStartedAt = running ? (s["turn_started_at"] ?? s["info"]?["turn_started_at"])?.double.map(Date.init(timeIntervalSince1970:)) : nil
        items = (s["messages"]?.array ?? []).compactMap(item(from:))
        openerAt = nil
        for r in s["open_requests"]?.array ?? [] {
            receive(ServerRequest(rpcId: r["id"] ?? .null, method: r["method"]?.string ?? "", params: r["params"] ?? .null))
        }
        applySnapshotExtras(s)
    }

    func item(from m: JSON) -> ChatItem? {
        var item = transcriptItem(m)
        item?.date = m["timestamp"]?.double.map(Date.init(timeIntervalSince1970:))
        return item
    }

    private func transcriptItem(_ m: JSON) -> ChatItem? {
        let rowId = m["row_id"]?.int.map(String.init) ?? localId()
        let text = m["text"]?.string ?? m["content"]?.string ?? ""
        switch m["role"]?.string {
        case "user":
            if let agent = AgentMessage.parse(text) {
                return ChatItem(id: "row-\(rowId)", kind: .agent, text: agent.body, agent: agent)
            }
            // The @mention note is for the agent; the user only typed what precedes it.
            let shown = text.range(of: BotStore.mentionNoteStart).map { String(text[..<$0.lowerBound]) } ?? text
            return userItem(id: "row-\(rowId)", shown)
        case "assistant":
            let reasoning = m["reasoning"]?.string ?? ""
            guard !text.isEmpty || !reasoning.isEmpty else { return nil }
            return ChatItem(id: "row-\(rowId)", kind: .assistant, text: text, reasoning: reasoning)
        case "tool":
            let id = m["tool_call_id"]?.string ?? rowId
            var args: JSON? = nil
            if let a = m["args"]?.object { args = .object(a) }
            // Edit results come back as the tool's JSON text; parse it so failures and paths read like live ones.
            let result = m["content"].map { c in c.string.flatMap { try? JSON.parse(Data($0.utf8)) } ?? c }
            return ChatItem(id: "row-\(rowId)", kind: .tool, tool: ToolCall(
                id: id, name: m["name"]?.string ?? "tool", context: m["context"]?.string ?? "",
                args: args, result: result,
                diff: m["display_metadata"]?["tool_result_metadata"]?["inline_diff"]?.string, running: false))
        default:
            return nil
        }
    }

    private func applyInfo(_ info: JSON?) {
        guard let info else { return }
        applyControlInfo(info)
        if let m = info["model"]?.string, !m.isEmpty { model = m }
        if let p = info["provider"]?.string, !p.isEmpty { provider = p }
        if let r = info["running"]?.bool { running = r }
        if running, turnStartedAt == nil, let t = info["turn_started_at"]?.double { turnStartedAt = Date(timeIntervalSince1970: t) }
        if let stored = info["stored_session_id"]?.string, selectedId == nil { selectedId = stored }
    }

    // MARK: - Lifecycle

    private func reconnected() {
        let replay = Self.canReplay(runtimeId: runtimeId, lastSeq: lastSeq, seenEpoch: seqEpoch, epoch: gateway.replayEpoch)
        // Park from the start: nothing for this session may advance the watermark ahead of the gap.
        if replay { held = [] }
        Task {
            await refreshSessions()
            guard let id = selectedId, !readOnly else { held = nil; return }
            if replay, await replayMissed() { return }
            held = nil
            runtimeId = nil
            await open(id)
        }
    }

    /// Whether a reconnect can replay the open chat's missed events instead of reloading it: the chat
    /// has a live session that saw events, and the server process (its seq numbering) is the same one.
    static func canReplay(runtimeId: String?, lastSeq: Int, seenEpoch: String?, epoch: String?) -> Bool {
        runtimeId != nil && lastSeq > 0 && seenEpoch != nil && seenEpoch == epoch
    }

    /// Rebinds the open chat's live session to the new socket, then runs only the events it missed.
    private func replayMissed() async -> Bool {
        guard let sid = runtimeId else { return false }
        do {
            // Until rebound, the server sends this session's events nowhere.
            _ = try await gateway.call("session.activate", ["session_id": .string(sid), "omit_messages": true])
            let r = try await gateway.call("session.events.since", ["session_id": .string(sid), "last_seen": .number(Double(lastSeq))])
            return runtimeId == sid && applyReplay(r)
        } catch {
            return false
        }
    }

    /// Folds a `session.events.since` answer and the live events parked meanwhile, in seq order.
    /// False when the replay has a hole (window passed, server restarted) and the chat must reload.
    func applyReplay(_ r: JSON) -> Bool {
        if r["truncated"]?.bool == true { return false }
        if let epoch = r["epoch"]?.string, epoch != seqEpoch { return false }
        let events = (r["events"]?.array ?? []).map(GatewayEvent.init(params:)) + (held ?? [])
        held = nil
        for e in events.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) { handle(e) }
        // The ring can't carry a question still waiting for an answer, so they come separately.
        for q in r["open_requests"]?.array ?? [] {
            receive(ServerRequest(rpcId: q["id"] ?? .null, method: q["method"]?.string ?? "", params: q["params"] ?? .null))
        }
        return true
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
    func scoped(_ params: [String: JSON]) -> [String: JSON] {
        guard let profile else { return params }
        return params.merging(["profile": .string(profile)]) { a, _ in a }
    }

    func localId() -> String {
        nextLocalId += 1
        return "local-\(nextLocalId)"
    }
}

public extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
