import Foundation
import Observation

/// One row of the Activity tab: something across chats, bots and rooms that needs the user or is running.
public struct ActivityItem: Identifiable, Hashable, Sendable {
    public enum Section: Int, Comparable, Sendable {
        case needsYou, working, background, done
        public static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Need: Hashable, Sendable {
        /// Answer with `ActivityStore.answer`.
        case request(ServerRequest)
        /// A room member's approval; answer with `ActivityStore.approve`.
        case room(RoomAction)
    }

    public enum Background: Hashable, Sendable {
        /// A /bg task, by the gateway's task id.
        case task(String)
        /// Delegated children still running.
        case subagents(Int)
    }

    public enum Kind: Hashable, Sendable {
        case needsYou(Need)
        /// When the turn started, if this app knows it.
        case working(startedAt: Date?)
        case background(Background)
        case done(unread: Date)

        public var section: Section {
            switch self {
            case .needsYou: .needsYou
            case .working: .working
            case .background: .background
            case .done: .done
            }
        }
    }

    /// Where tapping the row goes: a stored chat id, a bot name or a room id.
    public enum Target: Hashable, Sendable { case chat(String), bot(String), room(String) }

    public let id: String
    public var kind: Kind
    /// Nil for a live session this app can't place (another profile's chat).
    public var target: Target?
    public var title: String
    /// The question, the command or the latest message, on one line.
    public var detail: String
    /// Orders rows within a section, newest first.
    public var date: Date

    public var section: Section { kind.section }
}

/// A row of `session.active_list`: a live agent in the gateway process, any profile.
struct LiveSession: Hashable, Sendable {
    /// Runtime session id.
    var id: String
    /// Stored session id.
    var key: String
    var title: String
    var preview: String
    /// starting, working, waiting (a server request is open) or idle.
    var status: String
    var lastActive: Date

    static func parse(_ rows: JSON?) -> [LiveSession] {
        (rows?.array ?? []).compactMap { r in
            guard let id = r["id"]?.string else { return nil }
            return LiveSession(id: id, key: r["session_key"]?.string ?? "", title: r["title"]?.string ?? "",
                               preview: r["preview"]?.string ?? "", status: r["status"]?.string ?? "",
                               lastActive: Date(timeIntervalSince1970: r["last_active"]?.double ?? 0))
        }
    }
}

/// Everything the Activity tab is built from, read from the stores at one moment.
struct ActivitySnapshot {
    /// The chat open in the Chats tab.
    struct OpenChat {
        var stored: String?
        var runtime: String?
        var requests: [ServerRequest] = []
        var startedAt: Date?
        /// Pending /bg cards: task id, prompt, when sent.
        var tasks: [(id: String, prompt: String, at: Date)] = []
        var subagents = 0
    }

    var live: [LiveSession] = []
    var inbox: [ServerRequest] = []
    /// Open requests read with `session.events.since`.
    var fetched: [ServerRequest] = []
    var open = OpenChat()
    /// Chats tab titles by stored id.
    var chats: [String: String] = [:]
    var chatUnread: [String: Date] = [:]
    /// Bot name by its Bot Chat's stored id, and by the runtime id showing it.
    var botChats: [String: String] = [:]
    var botRuntimes: [String: String] = [:]
    var botLabels: [String: String] = [:]
    var botUnread: [String: Date] = [:]
    var rooms: [Room] = []
    var roomUnread: Set<String> = []
    var roomStatus: [String: (working: Bool, approvals: [RoomAction])] = [:]
}

enum ActivityFold {
    static func items(_ s: ActivitySnapshot) -> [ActivityItem] {
        let byRuntime = Dictionary(s.live.map { ($0.id, $0) }) { a, _ in a }

        func place(runtime: String) -> (ActivityItem.Target?, String) {
            let row = byRuntime[runtime]
            let key = row?.key ?? (runtime == s.open.runtime ? s.open.stored : nil) ?? ""
            if let title = s.chats[key] { return (.chat(key), title.nonEmpty ?? row?.title.nonEmpty ?? "Chat") }
            if key == s.open.stored, !key.isEmpty { return (.chat(key), row?.title.nonEmpty ?? "Chat") }
            if let bot = s.botChats[key] ?? s.botRuntimes[runtime] { return (.bot(bot), s.botLabels[bot] ?? bot) }
            return (nil, row?.title.nonEmpty ?? "Chat")
        }

        var out: [ActivityItem] = []
        var busy: Set<ActivityItem.Target> = []
        var asking: Set<String> = []
        var seen: Set<String> = []
        for r in s.open.requests + s.inbox + s.fetched where seen.insert(r.id).inserted {
            let (target, title) = place(runtime: r.sessionId)
            asking.insert(r.sessionId)
            if let target { busy.insert(target) }
            out.append(ActivityItem(id: "need-\(r.id)", kind: .needsYou(.request(r)), target: target, title: title,
                                    detail: question(r), date: byRuntime[r.sessionId]?.lastActive ?? .distantPast))
        }
        for room in s.rooms {
            for a in s.roomStatus[room.id]?.approvals ?? [] {
                busy.insert(.room(room.id))
                let what = a.approval["command"]?.string?.nonEmpty ?? a.approval["description"]?.string ?? ""
                out.append(ActivityItem(id: "need-\(a.id)", kind: .needsYou(.room(a)), target: .room(room.id), title: room.name,
                                        detail: oneLine(what), date: room.updatedAt))
            }
        }

        // A waiting row whose question never reached us still has an agent on it, so it counts as working.
        for row in s.live where ["starting", "working", "waiting"].contains(row.status) && !asking.contains(row.id) {
            let (target, title) = place(runtime: row.id)
            if let target { guard busy.insert(target).inserted else { continue } }
            out.append(ActivityItem(id: "work-\(row.id)", kind: .working(startedAt: row.id == s.open.runtime ? s.open.startedAt : nil),
                                    target: target, title: title, detail: oneLine(row.preview), date: row.lastActive))
        }
        for room in s.rooms where s.roomStatus[room.id]?.working == true && busy.insert(.room(room.id)).inserted {
            out.append(ActivityItem(id: "work-\(room.id)", kind: .working(startedAt: nil), target: .room(room.id), title: room.name,
                                    detail: "", date: room.updatedAt))
        }

        if let stored = s.open.stored {
            let title = s.chats[stored]?.nonEmpty ?? "Chat"
            for t in s.open.tasks {
                out.append(ActivityItem(id: "bg-\(t.id)", kind: .background(.task(t.id)), target: .chat(stored), title: title,
                                        detail: oneLine(t.prompt), date: t.at))
            }
            if s.open.subagents > 0 {
                out.append(ActivityItem(id: "subagents-\(stored)", kind: .background(.subagents(s.open.subagents)), target: .chat(stored),
                                        title: title, detail: "\(s.open.subagents) subagent\(s.open.subagents == 1 ? "" : "s") running",
                                        date: s.open.startedAt ?? .distantPast))
            }
        }

        for (id, at) in s.chatUnread where !busy.contains(.chat(id)) {
            out.append(ActivityItem(id: "done-\(id)", kind: .done(unread: at), target: .chat(id), title: s.chats[id]?.nonEmpty ?? "Chat",
                                    detail: "", date: at))
        }
        for (bot, at) in s.botUnread where !busy.contains(.bot(bot)) {
            out.append(ActivityItem(id: "done-bot-\(bot)", kind: .done(unread: at), target: .bot(bot), title: s.botLabels[bot] ?? bot,
                                    detail: "", date: at))
        }
        for room in s.rooms where s.roomUnread.contains(room.id) && !busy.contains(.room(room.id)) {
            out.append(ActivityItem(id: "done-room-\(room.id)", kind: .done(unread: room.updatedAt), target: .room(room.id),
                                    title: room.name, detail: "", date: room.updatedAt))
        }

        return out.sorted { a, b in
            a.section != b.section ? a.section < b.section : a.date != b.date ? a.date > b.date : a.id < b.id
        }
    }

    /// Parked prompts to drop: their session was checked and no longer lists them, or it isn't live at all.
    static func stale(inbox: [ServerRequest], open: [String: [ServerRequest]], live: Set<String>) -> Set<String> {
        Set(inbox.filter { r in
            if let listed = open[r.sessionId] { return !listed.contains { $0.id == r.id } }
            return !live.contains(r.sessionId)
        }.map(\.id))
    }

    static func question(_ r: ServerRequest) -> String {
        let p = r.params
        let text: String? = switch r.method {
        case "approval": p["command"]?.string?.nonEmpty ?? p["description"]?.string
        case "clarify": p["questions"]?.array?.first?["question"]?.string ?? p["question"]?.string
        case "sudo": p["command"]?.string
        default: p["prompt"]?.string?.nonEmpty ?? p["env_var"]?.string
        }
        return oneLine(text ?? "")
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// The Activity tab's state: what needs the user and what is running, across chats, bots and rooms.
@MainActor @Observable
public final class ActivityStore {
    public let gateway: Gateway
    /// Sorted Needs you, Working, Background, Done; newest first within each.
    public var items: [ActivityItem] { ActivityFold.items(snapshot) }
    public var needsYouCount: Int { items.filter { $0.section == .needsYou }.count }

    private(set) var live: [LiveSession] = []
    private(set) var fetched: [String: [ServerRequest]] = [:]
    @ObservationIgnored private weak var chats: ChatStore?
    @ObservationIgnored private weak var bots: BotStore?
    @ObservationIgnored private weak var groups: GroupStore?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false

    public init(gateway: Gateway, chats: ChatStore? = nil, bots: BotStore? = nil, groups: GroupStore? = nil) {
        self.gateway = gateway
        self.chats = chats
        self.bots = bots
        self.groups = groups
        gateway.listen(self, event: { [weak self] e in
            guard let self, e.type == "sessions.changed", self.poller != nil else { return }
            Task { await self.refresh() }
        }, connected: { [weak self] in
            guard let self, self.poller != nil else { return }
            Task { await self.refresh() }
        })
    }

    /// Polls every 3 s while the tab is on screen and every 30 s otherwise; call again when that changes.
    public func start(visible: Bool) {
        poller?.cancel()
        let pause: Duration = visible ? .seconds(3) : .seconds(30)
        poller = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.refresh()
                try? await Task.sleep(for: pause)
            }
        }
    }

    public func stop() {
        poller?.cancel()
        poller = nil
    }

    /// One poll: the live sessions, then the open requests of waiting ones this app doesn't hold.
    public func refresh() async {
        guard !refreshing, gateway.status == .online else { return }
        refreshing = true
        defer { refreshing = false }
        guard let r = try? await gateway.call("session.active_list") else { return }
        let rows = LiveSession.parse(r["sessions"])
        let parked = gateway.inbox
        var check = Set(parked.map(\.sessionId))
        let held = chats.map { c in Set(c.requests.map(\.sessionId)) } ?? []
        check.formUnion(rows.filter { $0.status == "waiting" && !held.contains($0.id) }.map(\.id))

        var open: [String: [ServerRequest]] = [:]
        for sid in check {
            // Only open_requests is wanted, so ask for events past any real seq.
            guard let e = try? await gateway.call("session.events.since", [
                "session_id": .string(sid), "last_seen": .number(Double(Int32.max)),
            ]) else { continue }
            open[sid] = (e["open_requests"]?.array ?? []).map {
                ServerRequest(rpcId: $0["id"] ?? .null, method: $0["method"]?.string ?? "", params: $0["params"] ?? .null)
            }.filter { ServerRequest.prompts.contains($0.method) }
        }
        live = rows
        fetched = open
        // Only prompts parked before the reads: a newer one may not have been listed yet.
        gateway.withdraw(ActivityFold.stale(inbox: parked, open: open, live: Set(rows.map(\.id))))
    }

    /// Answers through the chat that shows the prompt when it is open, else straight to the server.
    public func answer(_ request: ServerRequest, result: JSON) {
        if let chats, chats.requests.contains(where: { $0.id == request.id }) {
            chats.answer(request, result: result)
        } else {
            gateway.respond(request, result: result)
        }
        fetched = fetched.mapValues { $0.filter { $0.id != request.id } }
    }

    public func approve(_ action: RoomAction, in room: String, choice: String) async {
        await groups?.store(for: room).approve(action, choice: choice)
    }

    var snapshot: ActivitySnapshot {
        var s = ActivitySnapshot(live: live, inbox: gateway.inbox, fetched: fetched.values.flatMap { $0 })
        if let chats {
            s.chats = Dictionary(chats.sessions.map { ($0.id, $0.title) }) { a, _ in a }
            s.chatUnread = chats.unread
            s.open = .init(stored: chats.selectedId, runtime: chats.runtimeId, requests: chats.requests,
                           startedAt: chats.turnStartedAt, subagents: chats.subagents.active)
            s.open.tasks = chats.items.compactMap { i in
                guard let n = i.slash, n.background, n.pending, let id = n.taskId else { return nil }
                return (id, n.header, i.date ?? .distantPast)
            }
        }
        if let bots {
            s.botChats = Dictionary(bots.bots.compactMap { b in b.canonicalId.map { ($0, b.name) } }) { a, _ in a }
            s.botRuntimes = bots.runtimes
            s.botLabels = Dictionary(bots.bots.map { ($0.name, $0.label) }) { a, _ in a }
            s.botUnread = bots.unread
        }
        if let groups {
            s.rooms = groups.rooms
            s.roomUnread = Set(groups.rooms.filter(groups.unread).map(\.id))
            s.roomStatus = groups.stores.mapValues { ($0.working, $0.status.approvals) }
        }
        return s
    }
}
