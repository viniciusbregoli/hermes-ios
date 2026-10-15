import Foundation

// Follow-ups typed while a turn runs, the way the desktop composer queue works (desktop store/composer-queue.ts,
// app/chat/composer/hooks/use-composer-queue.ts): the gateway has no RPC to list, edit or drop the prompts it
// queued itself, so text-only follow-ups stay on this device, editable, until the turn ends and the head is sent
// with `prompt.submit {queued: true}`. Messages with attachments go to the server queue (their files are already
// staged on the session) and show read-only.

/// A follow-up held on this device until the running turn ends.
public struct QueuedMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public var text: String
    /// The @mention note, sent but not shown.
    var note = ""
    public var quotes: [Quote] = []
    /// Shown instead of `text` (a skill or /goal kickoff); such messages are neither edited nor steered.
    public var display: String?

    public var shown: String { display ?? text }
    public var editable: Bool { display == nil }
    /// A steer delivers plain text, so a message with quotes is edited or sent with the queue but not steered.
    public var steerable: Bool { editable && quotes.isEmpty }
}

/// What the composer's send button does, after T3 Code's composerSendPresentation.ts.
public struct SendButton: Equatable, Sendable {
    public enum Action: Sendable { case send, queue, update }
    public let action: Action
    public let enabled: Bool
    /// Steer now and Redirect in the long-press menu: only a running turn can take them, and only as plain text.
    public let canSteer: Bool

    /// - Parameters:
    ///   - editingQueued: the composer holds a queued message being edited.
    ///   - editingSent: the composer holds a sent message being edited; its rewind stops the turn itself.
    ///   - hasQuotes: passages are quoted for this message, which can go out with no typed text but not as a steer.
    public init(draft: String, running: Bool, online: Bool, hasAttachments: Bool, attaching: Bool,
                editingQueued: Bool = false, editingSent: Bool = false, hasQuotes: Bool = false) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        action = editingQueued ? .update : running && !editingSent ? .queue : .send
        enabled = online && !attaching && (!text.isEmpty || hasQuotes || (hasAttachments && !editingQueued))
        canSteer = action == .queue && enabled && !hasAttachments && !hasQuotes && !text.isEmpty && SlashCommand(text) == nil
    }

    public var icon: String {
        switch action {
        case .send: "arrow.up"
        case .queue: "list.number"
        case .update: "checkmark"
        }
    }

    public var label: String {
        switch action {
        case .send: "Send"
        case .queue: "Queue"
        case .update: "Update queued message"
        }
    }
}

extension ChatStore {
    public var queuedCount: Int { queue.count + queued.count }

    /// Everything waiting for the turn to end, as dimmed bubbles: the server's queue runs first.
    public var queuedBubbles: [ChatItem] {
        queued + queue.map { ChatItem(id: $0.id, kind: .user, text: $0.shown, quotes: $0.quotes) }
    }

    // MARK: - Editing

    /// Replaces a queued message's text and, when `quotes` is given, its quotes. A message left with neither is dropped.
    public func editQueued(_ id: String, text: String, quotes: [Quote]? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].editable else { return }
        if let quotes { queue[i].quotes = Array(quotes.compactMap(\.normalized).prefix(Quote.maxCount)) }
        if text.isEmpty, queue[i].quotes.isEmpty { queue.remove(at: i) } else { queue[i].text = text }
    }

    /// Moves a queued message `by` places (negative is earlier), clamped to the queue.
    public func moveQueued(_ id: String, by offset: Int) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(0, i + offset), queue.count - 1)
        guard i != j else { return }
        queue.insert(queue.remove(at: i), at: j)
    }

    public func removeQueued(_ id: String) {
        queue.removeAll { $0.id == id }
    }

    /// Lifts the pause a Stop put on the queue and sends the head if the chat is idle.
    public func resumeQueue() {
        queuePaused = false
        drainQueue()
    }

    // MARK: - Steering

    /// Delivers `text` into the running turn: `session.steer` adds it to the next tool result without
    /// interrupting, `session.redirect` restarts the turn with it. Whatever the turn can't take is queued,
    /// so the words are never lost.
    /// - Parameter at: where a refused message goes back in the queue (its old place when it came from there).
    public func steer(_ text: String, redirect: Bool = false, at index: Int? = nil) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let status: String?
        do {
            guard let sid = runtimeId, running else { throw GatewayError.rpc(0, "the turn already ended") }
            let r = try await gateway.call(redirect ? "session.redirect" : "session.steer", ["session_id": .string(sid), "text": .string(text)])
            status = r["status"]?.string
        } catch {
            requeue(text, at: index, feedback: "Couldn't \(redirect ? "redirect" : "steer"): \(error.localizedDescription). Queued for the next turn.")
            return
        }
        placeSteered(text, redirect: redirect, status: status, at: index)
    }

    /// Steers with a queued message, taking it out of the queue unless the turn refuses it.
    public func steerQueued(_ id: String, redirect: Bool = false) async {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].steerable else { return }
        let entry = queue.remove(at: i)
        await steer(entry.text, redirect: redirect, at: i)
    }

    /// Where a steer or redirect ended up, per the RPC's status.
    func placeSteered(_ text: String, redirect: Bool, status: String?, at index: Int?) {
        let bubble = ChatItem(id: localId(), kind: .user, text: text, date: Date())
        switch (redirect, status) {
        case (false, "queued"):
            // An accepted steer; the RPC reuses "queued" for it.
            items.append(bubble)
            notes[bubble.id] = Self.submitNote("steered")
            steerFeedback = "Steered: the agent reads it after its current step."
        case (true, "redirected"):
            items.append(bubble)
            notes[bubble.id] = Self.submitNote("redirected")
            steerFeedback = "Redirected the running turn."
        case (true, "queued"):
            // The turn was still starting: the server made it the next turn instead.
            queued.append(bubble)
            steerFeedback = "The turn was still starting, so it runs next."
        default:
            requeue(text, at: index, feedback: "\(redirect ? "Redirect" : "Steer") rejected: the turn is finishing. Queued for the next turn.")
        }
    }

    private func requeue(_ text: String, at index: Int?, feedback: String) {
        queue.insert(QueuedMessage(id: localId(), text: text), at: min(index ?? queue.count, queue.count))
        steerFeedback = feedback
        drainQueue()
    }

    // MARK: - Draining

    /// Sends the head of the queue once the chat is idle. Prompts the server queued itself run first:
    /// it drains them on its own after the turn, one `message.start` each.
    func drainQueue() {
        guard !running, !queuePaused, queueEditing == nil, queued.isEmpty, runtimeId != nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        Task {
            // The failed message stays in the transcript with its error, like any send; the rest waits for Resume.
            if !(await submit(next.text, note: next.note, display: next.display, queued: true, ownAttachments: false, quotes: next.quotes)), !queue.isEmpty { queuePaused = true }
        }
    }

    /// Hands the queue to the server before leaving the chat, so a turn still running there gets its follow-ups.
    // ponytail: a queue paused by Stop is dropped on leaving; keep per-chat queues if that loses something wanted.
    func handOffQueue() async {
        let pending = queue
        queue = []
        guard running, !queuePaused, let sid = runtimeId else { return }
        for m in pending {
            _ = try? await gateway.call("prompt.submit", ["session_id": .string(sid), "text": .string(Quote.compose(m.quotes, with: m.text) + m.note), "queued": true])
        }
    }
}
