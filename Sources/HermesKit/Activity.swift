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
        /// A room member's approval (`ActivityStore.approve`) or a turn to retry (`ActivityStore.retry`).
        case room(RoomAction)
    }

    public enum Background: Hashable, Sendable {
        /// A /bg task, by the gateway's task id.
        case task(String)
        /// Delegated children still running.
        case subagents(Int)
        /// A shell process the agent started in the background; stop it with `ActivityStore.kill(process:)`.
        case process(BackgroundProcess)
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

/// A background shell process of a live session, from `process.list`.
/// Running ones are listed until they exit; exited ones stay for `exitedWindow` so the exit code can be seen.
public struct BackgroundProcess: Hashable, Sendable {
    public static let exitedWindow: TimeInterval = 300

    /// The gateway's process id.
    public let id: String
    /// Runtime id of the session that owns it.
    public let sessionId: String
    public var command: String
    public var cwd: String
    public var running: Bool
    /// Derived from the uptime at the last poll, so the UI can show a live uptime.
    public var startedAt: Date
    /// Set once it exited (nil while running, or if the server doesn't know when).
    public var exitedAt: Date?
    public var exitCode: Int?
    /// The last few thousand characters of its output.
    public var outputTail: String

    func shown(at now: Date) -> Bool {
        running || exitedAt.map { now.timeIntervalSince($0) < Self.exitedWindow } ?? false
    }

    /// Processes started on a pty write color codes, which would show as stray brackets.
    static func stripEscapes(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    static func parse(_ rows: JSON?, session: String, now: Date) -> [BackgroundProcess] {
        (rows?.array ?? []).compactMap { r in
            guard let id = r["session_id"]?.string else { return nil }
            let exited = r["exited_at"]?.double ?? 0
            return BackgroundProcess(id: id, sessionId: session, command: r["command"]?.string ?? "", cwd: r["cwd"]?.string ?? "",
                                     running: r["status"]?.string == "running",
                                     startedAt: now.addingTimeInterval(-(r["uptime_seconds"]?.double ?? 0)),
                                     exitedAt: exited > 0 ? Date(timeIntervalSince1970: exited) : nil, exitCode: r["exit_code"]?.int,
                                     outputTail: stripEscapes(r["output_tail"]?.string ?? r["output_preview"]?.string ?? ""))
        }
    }

    /// `process.list` for each session, at most `limit` at a time. A session whose call fails is left out.
    static func fetch(_ sessions: [String], limit: Int = 4, now: Date = Date(),
                      list: @escaping @Sendable (String) async throws -> JSON) async -> [String: [BackgroundProcess]] {
        let found = await gather(sessions, limit: limit, list)
        return Dictionary(uniqueKeysWithValues: found.map { ($0.key, parse($0.value["processes"], session: $0.key, now: now)) })
    }
}

/// Calls `read` for each key, at most `limit` at a time. A key whose call fails is left out.
func gather(_ keys: [String], limit: Int = 4, _ read: @escaping @Sendable (String) async throws -> JSON) async -> [String: JSON] {
    await withTaskGroup(of: (String, JSON?).self) { group in
        var queue = keys.makeIterator()
        for _ in 0..<limit {
            guard let key = queue.next() else { break }
            group.addTask { (key, try? await read(key)) }
        }
        var out: [String: JSON] = [:]
        for await (key, r) in group {
            if let r { out[key] = r }
            if let key = queue.next() { group.addTask { (key, try? await read(key)) } }
        }
        return out
    }
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
    /// A chat store this app holds: the Chats tab's open chat, or a bot's chat.
    struct OpenChat {
        var stored: String?
        var runtime: String?
        var requests: [ServerRequest] = []
        var startedAt: Date?
        /// Pending /bg cards: task id, prompt, when sent.
        var tasks: [(id: String, prompt: String, at: Date)] = []
        /// Only chats this app is attached to: `subagent.list` answers 4001 for any other session.
        var subagents = 0
    }

    var live: [LiveSession] = []
    var inbox: [ServerRequest] = []
    /// Open requests read with `session.events.since`.
    var fetched: [ServerRequest] = []
    var open = OpenChat()
    /// Bot chats opened this launch, by bot name.
    var botOpen: [String: OpenChat] = [:]
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
    var roomStatus: [String: (working: Bool, actions: [RoomAction])] = [:]
    var processes: [BackgroundProcess] = []
    var now = Date()
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
        let bots = s.botOpen.sorted { $0.key < $1.key }
        for r in s.open.requests + bots.flatMap(\.value.requests) + s.inbox + s.fetched where seen.insert(r.id).inserted {
            let (target, title) = place(runtime: r.sessionId)
            asking.insert(r.sessionId)
            if let target { busy.insert(target) }
            out.append(ActivityItem(id: "need-\(r.id)", kind: .needsYou(.request(r)), target: target, title: title,
                                    detail: question(r), date: byRuntime[r.sessionId]?.lastActive ?? .distantPast))
        }
        for room in s.rooms {
            for a in s.roomStatus[room.id]?.actions ?? [] {
                busy.insert(.room(room.id))
                let what = a.kind == .retry ? "A reply didn't finish; retry it"
                    : a.approval["command"]?.string?.nonEmpty ?? a.approval["description"]?.string ?? ""
                out.append(ActivityItem(id: "need-\(a.id)", kind: .needsYou(.room(a)), target: .room(room.id), title: room.name,
                                        detail: oneLine(what), date: room.updatedAt))
            }
        }

        var started: [String: Date] = [:]
        for o in [s.open] + bots.map(\.value) { if let rt = o.runtime, let at = o.startedAt { started[rt] = at } }
        // A waiting row whose question never reached us still has an agent on it, so it counts as working.
        for row in s.live where ["starting", "working", "waiting"].contains(row.status) && !asking.contains(row.id) {
            let (target, title) = place(runtime: row.id)
            if let target { guard busy.insert(target).inserted else { continue } }
            out.append(ActivityItem(id: "work-\(row.id)", kind: .working(startedAt: started[row.id]),
                                    target: target, title: title, detail: oneLine(row.preview), date: row.lastActive))
        }
        for room in s.rooms where s.roomStatus[room.id]?.working == true && busy.insert(.room(room.id)).inserted {
            out.append(ActivityItem(id: "work-\(room.id)", kind: .working(startedAt: nil), target: .room(room.id), title: room.name,
                                    detail: "", date: room.updatedAt))
        }

        func background(_ o: ActivitySnapshot.OpenChat, key: String, target: ActivityItem.Target, title: String) {
            for t in o.tasks {
                out.append(ActivityItem(id: "bg-\(t.id)", kind: .background(.task(t.id)), target: target, title: title,
                                        detail: oneLine(t.prompt), date: t.at))
            }
            if o.subagents > 0 {
                out.append(ActivityItem(id: "subagents-\(key)", kind: .background(.subagents(o.subagents)), target: target,
                                        title: title, detail: "\(o.subagents) subagent\(o.subagents == 1 ? "" : "s") running",
                                        date: o.startedAt ?? .distantPast))
            }
        }
        if let stored = s.open.stored {
            background(s.open, key: stored, target: .chat(stored), title: s.chats[stored]?.nonEmpty ?? "Chat")
        }
        for (bot, o) in bots {
            background(o, key: "bot-\(bot)", target: .bot(bot), title: s.botLabels[bot] ?? bot)
        }

        for p in s.processes where p.shown(at: s.now) {
            let (target, title) = place(runtime: p.sessionId)
            out.append(ActivityItem(id: "proc-\(p.id)", kind: .background(.process(p)), target: target, title: title,
                                    detail: oneLine(p.command), date: p.exitedAt ?? p.startedAt))
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

    var live: [LiveSession] = []
    private(set) var fetched: [String: [ServerRequest]] = [:]
    /// By runtime session id.
    private(set) var processes: [String: [BackgroundProcess]] = [:]
    /// The RPCs this store sends besides polling prompts; tests replace it.
    @ObservationIgnored lazy var call: @Sendable (String, [String: JSON]) async throws -> JSON = { [gateway] in
        try await gateway.call($0, $1)
    }
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
            let process = e.type == "terminal.close" || (e.type == "status.update" && e.payload["kind"]?.string == "process")
            guard let self, e.type == "sessions.changed" || process, self.poller != nil else { return }
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
        let claimed = Set(held.flatMap { $0.requests.map(\.sessionId) })
        check.formUnion(rows.filter { $0.status == "waiting" && !claimed.contains($0.id) }.map(\.id))

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

        // process.list waits for the session's agent, so only ask sessions likely to have processes.
        let now = Date()
        let watched = rows.filter { row in
            ["starting", "working", "waiting"].contains(row.status) || now.timeIntervalSince(row.lastActive) < 600
                || processes[row.id]?.contains { $0.shown(at: now) } == true
        }.map(\.id)
        let call = call
        var found = await BackgroundProcess.fetch(watched, now: now) { try await call("process.list", ["session_id": .string($0)]) }
        // A failed read keeps the last list of a session that is still live.
        for sid in watched where found[sid] == nil { found[sid] = processes[sid] }
        processes = found

        await groups?.refresh()
        await refreshRooms(now: now)
    }

    /// `groups.state` for rooms active in the last 10 minutes or last seen working or waiting on the user,
    /// at most 4 at a time. A room on screen polls itself.
    func refreshRooms(now: Date = Date()) async {
        guard let groups else { return }
        let watched = groups.rooms.filter { room in
            let store = groups.stores[room.id]
            guard store?.visible != true else { return false }
            return now.timeIntervalSince(room.updatedAt) < 600 || store.map { $0.working || !$0.status.actions.isEmpty } == true
        }.map(\.id)
        let call = call
        let states = await gather(watched) { try await call("groups.state", ["room_id": .string($0)]) }
        for (id, state) in states { groups.store(for: id).apply(state: state) }
    }

    /// Kills one background process (`process.kill`; never `process.stop`, which kills them all).
    public func kill(process: BackgroundProcess) async throws {
        _ = try await call("process.kill", ["session_id": .string(process.sessionId), "process_id": .string(process.id)])
        await refresh()
    }

    /// Stops the turn of a Working chat or bot chat row with `session.interrupt`, as the chat's stop button does.
    public func interrupt(_ item: ActivityItem) async {
        guard case .working = item.kind, let row = live.first(where: { "work-\($0.id)" == item.id }) else { return }
        _ = try? await call("session.interrupt", ["session_id": .string(row.id)])
        await refresh()
    }

    /// Answers through the chat that shows the prompt when it is open, else straight to the server.
    public func answer(_ request: ServerRequest, result: JSON) {
        if let chat = held.first(where: { $0.requests.contains { $0.id == request.id } }) {
            chat.answer(request, result: result)
        } else {
            gateway.respond(request, result: result)
        }
        fetched = fetched.mapValues { $0.filter { $0.id != request.id } }
    }

    public func approve(_ action: RoomAction, in room: String, choice: String) async {
        await groups?.store(for: room).approve(action, choice: choice)
    }

    /// Reruns a room turn that didn't finish (a `.retry` action).
    public func retry(_ action: RoomAction, in room: String) async {
        await groups?.store(for: room).retry(action.taskId)
    }

    /// The chat stores that hold their session's prompts: the Chats tab's and every bot chat opened this launch.
    private var held: [ChatStore] {
        [chats].compactMap { $0 } + (bots?.chats.sorted { $0.key < $1.key }.map(\.value) ?? [])
    }

    private static func open(_ c: ChatStore) -> ActivitySnapshot.OpenChat {
        var o = ActivitySnapshot.OpenChat(stored: c.selectedId, runtime: c.runtimeId, requests: c.requests,
                                          startedAt: c.turnStartedAt, subagents: c.subagents.active)
        o.tasks = c.items.compactMap { i in
            guard let n = i.slash, n.background, n.pending, let id = n.taskId else { return nil }
            return (id, n.header, i.date ?? .distantPast)
        }
        return o
    }

    var snapshot: ActivitySnapshot {
        var s = ActivitySnapshot(live: live, inbox: gateway.inbox, fetched: fetched.values.flatMap { $0 })
        s.processes = processes.values.flatMap { $0 }
        if let chats {
            s.chats = Dictionary(chats.sessions.map { ($0.id, $0.title) }) { a, _ in a }
            s.chatUnread = chats.unread
            s.open = Self.open(chats)
        }
        if let bots {
            s.botChats = Dictionary(bots.bots.compactMap { b in b.canonicalId.map { ($0, b.name) } }) { a, _ in a }
            s.botRuntimes = bots.runtimes
            s.botLabels = Dictionary(bots.bots.map { ($0.name, $0.label) }) { a, _ in a }
            s.botUnread = bots.unread
            for (name, c) in bots.chats {
                s.botOpen[name] = Self.open(c)
                if let rt = c.runtimeId { s.botRuntimes[rt] = name }
            }
        }
        if let groups {
            s.rooms = groups.rooms
            s.roomUnread = Set(groups.rooms.filter(groups.unread).map(\.id))
            s.roomStatus = groups.stores.mapValues { ($0.working, $0.status.actions) }
        }
        return s
    }
}
