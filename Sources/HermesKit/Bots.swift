import Foundation
import Observation

/// A bot is a Hermes profile (`default` plus every named one), as the desktop's Bot Mode shows them.
public struct Bot: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// Bot Mode title from `ui_meta["hermes-bots"]`; empty when the user never renamed it.
    public var title = ""
    public var displayName = ""
    public var pinned = false
    public var hidden = false
    public var hasAvatar = false
    /// The whole `ui_meta["hermes-bots"]` object; a write replaces it, so keys this app doesn't edit ride along.
    public var meta: JSON?
    /// Its compare-and-swap revision; nil when the gateway predates them.
    public var metaRevision: Int?
    /// Stored id of the canonical "Bot Chat", following compression to the lineage tip.
    public var canonicalId: String?
    public var preview = ""
    public var lastActive: Date?
    public var workerActive: Date?

    public static let defaultName = "default"
    public var isDefault: Bool { name == Self.defaultName }
    public var label: String { title.nonEmpty ?? displayName.nonEmpty ?? (isDefault ? "Hermes" : name) }
    public var handle: String { isDefault ? "hermes" : name }

    /// A kanban or tool worker heartbeats at least every 60 s; 150 s bridges one missed beat (desktop row-helpers.ts).
    public func working(at now: Date = Date()) -> Bool {
        workerActive.map { now.timeIntervalSince($0) < 150 } ?? false
    }

    init?(_ row: JSON) {
        guard let name = row["name"]?.string else { return nil }
        self.name = name
        let meta = row["ui_meta"]?["hermes-bots"]
        self.meta = meta
        metaRevision = row["ui_meta_revisions"].map { $0["hermes-bots"]?.int ?? 0 }
        title = meta?["title"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        pinned = meta?["pinned"]?.bool ?? false
        hidden = meta?["hidden"]?.bool ?? false
        displayName = row["display_name"]?.string ?? ""
        hasAvatar = row["has_avatar"]?.bool ?? false
        let canonical = row["canonical_session"], last = row["last_session"]
        canonicalId = canonical?["resolved_id"]?.string?.nonEmpty ?? canonical?["id"]?.string?.nonEmpty
        preview = Preview.clean(canonical?["preview"]?.string?.nonEmpty ?? last?["preview"]?.string ?? "")
        lastActive = [canonical?["last_active"]?.double, last?["last_active"]?.double].compactMap { $0 }.max()
            .map(Date.init(timeIntervalSince1970:))
        workerActive = row["worker_session"]?["last_active"]?.double.map(Date.init(timeIntervalSince1970:))
    }

    public init(name: String, title: String = "", pinned: Bool = false, lastActive: Date? = nil) {
        self.name = name
        self.title = title
        self.pinned = pinned
        self.lastActive = lastActive
    }

    /// The profile `step` places away from `name` in the roster, wrapping around (desktop profile.next / profile.prev).
    public static func cycle(_ roster: [Bot], from name: String, by step: Int) -> String? {
        guard !roster.isEmpty else { return nil }
        let at = roster.firstIndex { $0.name == name } ?? 0
        return roster[((at + step) % roster.count + roster.count) % roster.count].name
    }

    /// Hermes first, then pinned bots, then the most recently active; hidden bots are left out.
    public static func roster(_ result: JSON) -> [Bot] {
        (result["profiles"]?.array ?? []).compactMap(Bot.init).filter { !$0.hidden }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.pinned != b.pinned { return a.pinned }
            let ta = a.lastActive ?? .distantPast, tb = b.lastActive ?? .distantPast
            return ta != tb ? ta > tb : a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }
}

/// A bot-to-bot delivery. It arrives on the user role because the recipient's turn runs on it,
/// but the human didn't write it.
public struct AgentMessage: Hashable, Sendable {
    public let sender: String
    /// Sender's profile handle, when the delivery carries one.
    public let handle: String?
    public let body: String

    // Same pattern as the desktop's AGENT_MESSAGE_RE (thread/user-message.tsx).
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:Message from (?:🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\))?:\s*|\[Message from agent '([^']{1,64})'\]\s*)([\s\S]*)$"#)

    public static func parse(_ text: String) -> AgentMessage? {
        let ns = text as NSString
        guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let sender = (group(1) ?? group(3))?.trimmingCharacters(in: .whitespaces), !sender.isEmpty else { return nil }
        return AgentMessage(sender: sender, handle: group(2), body: group(4) ?? "")
    }
}

/// The Bots roster: profiles, their avatars and whether each one is busy.
@MainActor @Observable
public final class BotStore {
    public let gateway: Gateway
    public private(set) var bots: [Bot] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var avatars: [String: Data] = [:]
    /// Bots with a turn running in a chat this app has open.
    public private(set) var thinking: Set<String> = []
    /// Bots whose turn finished while their chat was off screen, with when; kept across launches.
    public private(set) var unread: [String: Date] = [:] {
        didSet { if unread != oldValue { defaults.set(unread, forKey: Self.unreadKey) } }
    }
    /// The bot whose chat is on screen with the app active; set by the chat view.
    public var visibleBot: String? {
        didSet { if let visibleBot { unread[visibleBot] = nil } }
    }
    /// Called when a bot's turn finishes while its chat is off screen, with the bot name and the reply.
    @ObservationIgnored public var onTurnFinished: ((_ bot: String, _ reply: String) -> Void)?

    @ObservationIgnored private(set) var runtimes: [String: String] = [:]
    /// Bot chats opened this launch, kept so their prompts and /bg tasks reach the Activity tab after the screen closes.
    @ObservationIgnored private(set) var chats: [String: ChatStore] = [:]
    @ObservationIgnored private var avatarRequests: Set<String> = []
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let defaults: UserDefaults
    static let unreadKey = "bots.unread"

    public init(gateway: Gateway, defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.defaults = defaults
        unread = defaults.dictionary(forKey: Self.unreadKey) as? [String: Date] ?? [:]
        gateway.listen(self, event: { [weak self] in self?.handle($0) },
                       connected: { [weak self] in Task { await self?.refresh() } })
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = Date() }
        do {
            bots = Bot.roster(try await gateway.call("profiles.list"))
            let listed = Set(bots.map(\.name))
            unread = unread.filter { listed.contains($0.key) }
            chats = chats.filter { listed.contains($0.key) }
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func bot(named name: String) -> Bot? { bots.first { $0.name == name } }

    /// The bot's chat store, kept for the session like a room's: a Bot Chat stays attached when its screen closes.
    public func chat(for name: String) -> ChatStore {
        if let chat = chats[name] { return chat }
        let chat = ChatStore(gateway: gateway, profile: name, defaults: defaults)
        chats[name] = chat
        return chat
    }

    /// The roster bot an agent message came from: by handle when it has one, else by its shown name.
    public func sender(of message: AgentMessage) -> Bot? {
        if let h = message.handle?.lowercased() { return bots.first { $0.handle == h || $0.name == h } }
        return bots.first { $0.label.caseInsensitiveCompare(message.sender) == .orderedSame }
    }

    public func loadAvatar(_ bot: Bot) async {
        guard bot.hasAvatar, avatars[bot.name] == nil, avatarRequests.insert(bot.name).inserted else { return }
        defer { avatarRequests.remove(bot.name) }
        guard let r = try? await gateway.call("profiles.get_asset", ["name": .string(bot.name), "asset": "avatar"]),
              r["found"]?.bool == true, let url = r["data"]?.string,
              let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...]))
        else { return }
        avatars[bot.name] = data
    }

    /// Shows a just-uploaded avatar (or none) without waiting for the next roster read.
    public func setAvatar(_ name: String, _ data: Data?) {
        avatars[name] = data
    }

    /// Tells the roster which runtime session shows a bot's chat, so its row can say "thinking".
    public func track(runtime: String?, bot: String, running: Bool) {
        runtimes = runtimes.filter { $0.value != bot }
        if let runtime { runtimes[runtime] = bot }
        if running { thinking.insert(bot) } else { thinking.remove(bot) }
    }

    /// Bots whose handle or label starts with `prefix`, for the composer's @ picker.
    public func mentionCandidates(_ prefix: String, excluding active: String) -> [Bot] {
        let p = prefix.lowercased()
        return bots.filter { $0.name != active && (p.isEmpty || $0.handle.hasPrefix(p) || $0.label.lowercased().hasPrefix(p)) }
    }

    nonisolated static let mentionNoteStart = "\n\n[@mentions resolved from the Bot Mode roster"

    public func mentionNote(for text: String, excluding active: String) -> String {
        Self.mentionNote(for: text, roster: bots, excluding: active)
    }

    /// The identification note the desktop appends when a message @-tags roster bots
    /// (plugins/hermes-bots/plugin.tsx); empty when nothing resolves.
    public static func mentionNote(for text: String, roster: [Bot], excluding active: String) -> String {
        var prose = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        prose = prose.replacingOccurrences(of: #"`[^`\n]*`"#, with: " ", options: .regularExpression)

        // A form two bots share is ambiguous and resolves to neither.
        var byForm: [String: Bot?] = [:]
        for bot in roster where bot.name != active {
            var forms: Set<String> = [bot.handle, bot.name.lowercased()]
            for friendly in [bot.title, bot.displayName] { forms.formUnion(mentionForms(friendly)) }
            for form in forms where !form.isEmpty {
                if let existing = byForm[form] { if existing?.name != bot.name { byForm[form] = .some(nil) } } else { byForm[form] = bot }
            }
        }

        var mentioned: [Bot] = []
        let regex = try! NSRegularExpression(pattern: #"(^|\s)@([a-z0-9][a-z0-9_-]*)"#, options: .caseInsensitive)
        let ns = prose as NSString
        for m in regex.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            guard let found = byForm[ns.substring(with: m.range(at: 2)).lowercased()], let bot = found,
                  !mentioned.contains(where: { $0.name == bot.name }) else { continue }
            mentioned.append(bot)
        }
        guard !mentioned.isEmpty else { return "" }

        let lines = mentioned.map { bot in
            "@\(bot.handle) = agent profile \"\(bot.name)\"" + (bot.title.isEmpty ? "" : " (\"\(bot.title)\")")
        }
        // Must match the desktop byte for byte, dashes included.
        return mentionNoteStart + " \u{2014} the user is referring to: " + lines.joined(separator: "; ")
            + ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool"
            + " (agents on other connected machines are reachable too \u{2014} the Desktop relays it); never forward the user\u{2019}s"
            + " text verbatim. If this session has no message_agent tool, agent messaging is unavailable here \u{2014} say so.]"
    }

    /// "Research Buddy" is taggable as @research-buddy and @researchbuddy; reserved words never are.
    static func mentionForms(_ value: String) -> Set<String> {
        let name = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return [] }
        let slug = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let collapsed = name.replacingOccurrences(of: "[^a-z0-9_-]+", with: "", options: .regularExpression)
        return Set([slug, collapsed]).filter {
            $0.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
                && !["all", "everyone", "user", "default", "hermes"].contains($0)
        }
    }

    private func handle(_ e: GatewayEvent) {
        switch e.type {
        case "sessions.changed" where Date().timeIntervalSince(lastRefresh) > 3:
            Task { await refresh() }
        case "message.start":
            if let bot = runtimes[e.sessionId] { thinking.insert(bot) }
        case "message.complete":
            guard let bot = runtimes[e.sessionId] else { return }
            thinking.remove(bot)
            if bot != visibleBot {
                unread[bot] = Date()
                let failed = e.payload["status"]?.string == "error"
                onTurnFinished?(bot, failed ? "The turn failed." : e.payload["text"]?.string?.nonEmpty ?? "Finished.")
            }
        default:
            break
        }
    }
}
