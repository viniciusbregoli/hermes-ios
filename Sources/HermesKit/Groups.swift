import Foundation

// Group chats hosted by the gateway (`groups.*`). The server runs every member's turn, so a room
// keeps talking while the phone sleeps; the app only reads the room log and posts into it.
// Hermes Desktop runs its own client-side group chats and does not show these rooms.

/// One bot in a room, frozen when the room was created.
public struct RoomMember: Identifiable, Hashable, Sendable {
    public var id: String { memberId }
    public let memberId: String
    public let profile: String
    public let handle: String
    public var displayName: String

    public init(memberId: String, profile: String, handle: String, displayName: String = "") {
        self.memberId = memberId
        self.profile = profile
        self.handle = handle
        self.displayName = displayName
    }

    init?(_ json: JSON) {
        guard let id = json["member_id"]?.string, let profile = json["profile"]?.string else { return nil }
        self.init(memberId: id, profile: profile, handle: json["handle"]?.string ?? profile,
                  displayName: json["display_name"]?.string ?? "")
    }

    /// The `groups.create` member shape; the server rejects any other key.
    var json: JSON {
        var o: [String: JSON] = ["member_id": .string(memberId), "profile": .string(profile), "handle": .string(handle)]
        if !displayName.isEmpty { o["display_name"] = .string(displayName) }
        return .object(o)
    }
}

public struct Room: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var members: [RoomMember]
    /// Sequence number of the newest log event, control events included.
    public var latestSeq: Int
    public var updatedAt: Date

    public init(id: String, name: String, members: [RoomMember], latestSeq: Int = 0, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.members = members
        self.latestSeq = latestSeq
        self.updatedAt = updatedAt
    }

    init?(_ json: JSON) {
        guard let id = json["room_id"]?.string else { return nil }
        self.init(id: id, name: json["name"]?.string ?? id,
                  members: (json["members"]?.array ?? []).compactMap(RoomMember.init),
                  latestSeq: json["latest_seq"]?.int ?? 0,
                  updatedAt: Date(timeIntervalSince1970: json["updated_at"]?.double ?? 0))
    }

    public func member(_ id: String?) -> RoomMember? { members.first { $0.memberId == id } }
}

/// One entry of the room log (`groups.log`).
public struct RoomEvent: Identifiable, Hashable, Sendable {
    public var id: Int { seq }
    public let seq: Int
    public let eventId: String
    public let kind: String
    public let actor: JSON
    public let payload: JSON
    public let at: Date

    public init(seq: Int, kind: String, eventId: String = "", actor: JSON = nil, payload: JSON = nil, at: Date = .distantPast) {
        self.seq = seq
        self.eventId = eventId
        self.kind = kind
        self.actor = actor
        self.payload = payload
        self.at = at
    }

    init?(_ json: JSON) {
        guard let seq = json["seq"]?.int, let kind = json["kind"]?.string else { return nil }
        self.init(seq: seq, kind: kind, eventId: json["event_id"]?.string ?? "", actor: json["actor"] ?? .null,
                  payload: json["payload"] ?? .null, at: Date(timeIntervalSince1970: json["created_at"]?.double ?? 0))
    }

    public var text: String { payload["text"]?.string ?? "" }
    public var memberId: String? { payload["member_id"]?.string ?? (actor["kind"]?.string == "member" ? actor["id"]?.string : nil) }
    var round: Int { payload["round_index"]?.int ?? 0 }
    var discussionId: String? { payload["discussion_event_id"]?.string }
    var taskId: String? { payload["task_id"]?.string }
    var isTerminal: Bool { ["turn.settled", "turn.failed", "turn.cancelled", "turn.deferred"].contains(kind) }
}

/// Something the room driver needs from the user: an approval, or a retry of a turn that didn't finish.
public struct RoomAction: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case approval, retry }
    public let kind: Kind
    public let taskId: String
    public let memberId: String
    public let executionGeneration: Int
    public let requestId: String
    /// `command`, `description` and `choices` of an approval, as the chat's approval card reads them.
    public let approval: JSON
    public var id: String { "\(kind)-\(taskId)-\(requestId)" }

    public init(kind: Kind, taskId: String, memberId: String = "", executionGeneration: Int = 0,
                requestId: String = "", approval: JSON = nil) {
        self.kind = kind
        self.taskId = taskId
        self.memberId = memberId
        self.executionGeneration = executionGeneration
        self.requestId = requestId
        self.approval = approval
    }

    init?(_ json: JSON) {
        guard let task = json["task_id"]?.string else { return nil }
        switch json["kind"]?.string {
        case "approval":
            guard let request = json["request_id"]?.string else { return nil }
            self.init(kind: .approval, taskId: task, memberId: json["member_id"]?.string ?? "",
                      executionGeneration: json["execution_generation"]?.int ?? 0, requestId: request,
                      approval: json["approval"] ?? .null)
        case "retry":
            self.init(kind: .retry, taskId: task)
        default:
            return nil
        }
    }
}

/// `driver_status` from `groups.state`.
public struct RoomStatus: Hashable, Sendable {
    /// The server's room worker is alive.
    public var running = false
    /// A member turn is queued or running.
    public var working = false
    /// The room waits on a stop or on an uncertain turn the user has to retry.
    public var blocked = false
    public var actions: [RoomAction] = []

    public init(running: Bool = false, working: Bool = false, blocked: Bool = false, actions: [RoomAction] = []) {
        self.running = running
        self.working = working
        self.blocked = blocked
        self.actions = actions
    }

    init(_ json: JSON?) {
        guard let json else { return }
        running = json["running"]?.bool ?? false
        working = json["working"]?.bool ?? false
        blocked = json["blocked"]?.bool ?? false
        actions = (json["pending_actions"]?.array ?? []).compactMap(RoomAction.init)
    }

    public var approvals: [RoomAction] { actions.filter { $0.kind == .approval } }
    public var retryable: Set<String> { Set(actions.filter { $0.kind == .retry }.map(\.taskId)) }
}

/// A transcript line built from the room log.
public struct RoomRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case user, member
        /// A member chose to stay silent ("(pass)").
        case passed
        /// A member's turn that ended without a reply; `taskId` says which, for Retry.
        case failed, cancelled, deferred
        /// Room-level notes: stopped, renamed, round limit reached.
        case notice
    }

    public var id: Int { seq }
    public let seq: Int
    public let kind: Kind
    public var text: String
    public var member: RoomMember?
    /// The member's shown name, or empty for the user and room notices.
    public var name = ""
    public var taskId: String?
    public var at: Date
    /// First of consecutive messages from the same member; the view draws the avatar and name only here.
    public var header = true
}

public enum RoomTimeline {
    /// Builds the transcript. `labels` maps a profile to its roster name (the Bots tab title).
    public static func rows(_ events: [RoomEvent], room: Room, labels: [String: String] = [:]) -> [RoomRow] {
        func name(_ member: RoomMember?, _ event: RoomEvent) -> String {
            guard let member else { return event.actor["display_name"]?.string ?? event.memberId ?? "A bot" }
            return labels[member.profile]?.nonEmpty ?? member.displayName.nonEmpty ?? member.handle
        }
        var rows: [RoomRow] = []
        for e in events {
            let member = room.member(e.memberId)
            func line(_ kind: RoomRow.Kind, _ text: String) -> RoomRow {
                RoomRow(seq: e.seq, kind: kind, text: text, member: member, name: name(member, e), taskId: e.taskId, at: e.at)
            }
            switch e.kind {
            case "message.user":
                rows.append(RoomRow(seq: e.seq, kind: .user, text: e.text, at: e.at))
            case "message.member":
                var row = line(.member, e.text)
                if let last = rows.last, last.kind == .member, last.member?.memberId == member?.memberId { row.header = false }
                rows.append(row)
            case "turn.settled" where e.payload["passed"]?.bool == true:
                rows.append(line(.passed, "\(name(member, e)) passed"))
            case "turn.failed":
                let error = e.payload["error"]?.string?.nonEmpty ?? "unknown error"
                rows.append(line(.failed, "\(name(member, e)) couldn't reply: \(error)"))
            case "turn.cancelled":
                let superseded = e.payload["reason"]?.string == "superseded_by_newer_user_event"
                rows.append(line(.cancelled, superseded ? "\(name(member, e)) stopped for your newer message" : "\(name(member, e)) was stopped"))
            case "turn.deferred":
                rows.append(line(.deferred, "\(name(member, e)) is unavailable right now"))
            case "room.activity" where e.payload["status"]?.string == "bounded":
                rows.append(RoomRow(seq: e.seq, kind: .notice,
                                    text: "The bots reached the room's limit of \(RoomDiscussion.maxRounds) rounds or \(RoomDiscussion.maxMessages) replies",
                                    at: e.at))
            case "room.stop_requested":
                rows.append(RoomRow(seq: e.seq, kind: .notice, text: "You stopped the room", at: e.at))
            case "room.renamed":
                rows.append(RoomRow(seq: e.seq, kind: .notice, text: "Renamed to \u{201C}\(e.payload["name"]?.string ?? "")\u{201D}", at: e.at))
            case "room.disbanded":
                rows.append(RoomRow(seq: e.seq, kind: .notice, text: "Disbanded", at: e.at))
            default:
                // turn.settled with a reply (the message carries it), settled rounds, authority bookkeeping.
                break
            }
        }
        return rows
    }
}

/// The client's view of the server's discussion policy (gateway/hosted_room_discussion.py), used only to
/// say who is replying; the server decides who actually speaks.
public enum RoomDiscussion {
    public static let maxRounds = 3
    public static let maxMessages = 10
    private static let mention = try! NSRegularExpression(pattern: "@([A-Za-z0-9][A-Za-z0-9._:-]*)", options: .caseInsensitive)

    /// Members a text @-mentions; with `everyoneByDefault`, no mention (or @all, @everyone) means every member.
    public static func addressed(_ text: String, members: [RoomMember], everyoneByDefault: Bool = true) -> [RoomMember] {
        let ns = text as NSString
        var handles: Set<String> = []
        var everyone = false
        for m in mention.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let h = ns.substring(with: m.range(at: 1)).lowercased()
            if h == "all" || h == "everyone" { everyone = true } else { handles.insert(h) }
        }
        let named = members.filter { handles.contains($0.handle.lowercased()) }
        if everyone || (everyoneByDefault && named.isEmpty) { return members }
        return named
    }

    /// The newest user message whose discussion is still open: not stopped and not settled or bounded.
    public static func pending(_ events: [RoomEvent]) -> RoomEvent? {
        let stopped = events.last { $0.kind == "room.stop_requested" }?.seq ?? 0
        let done = Set(events.filter { $0.kind == "room.activity" }.compactMap(\.discussionId))
        guard let last = events.last(where: { $0.kind == "message.user" }), last.seq > stopped, !done.contains(last.eventId) else { return nil }
        return last
    }

    /// The member whose turn the server runs next for the open discussion, replaying its round order:
    /// round 0 is whoever the user addressed, later rounds only members another bot @-cited since they last spoke.
    public static func nextSpeaker(_ events: [RoomEvent], members: [RoomMember]) -> RoomMember? {
        guard let discussion = pending(events) else { return nil }
        let replies = events.filter { $0.kind == "message.member" && $0.seq > discussion.seq && $0.discussionId == discussion.eventId }
        guard replies.count < maxMessages else { return nil }
        let terminals = events.filter(\.isTerminal)
        let finished = Set(terminals.filter { $0.discussionId == discussion.eventId }.map { "\($0.round)/\($0.memberId ?? "")" })
        // A member only takes a turn when there is something it hasn't seen yet.
        var watermark: [String: Int] = [:]
        for t in terminals { watermark[t.memberId ?? ""] = max(watermark[t.memberId ?? ""] ?? 0, t.payload["seen_through_seq"]?.int ?? 0) }
        let messages = events.filter { $0.kind == "message.user" || $0.kind == "message.member" }
        let seen = messages.last?.seq ?? 0
        func due(_ m: RoomMember) -> Bool {
            let mark = watermark[m.memberId] ?? 0
            return messages.contains { $0.seq > mark && $0.seq <= seen }
        }
        for round in 0..<maxRounds {
            let responders = round == 0 ? addressed(discussion.text, members: members) : cited(replies, members: members)
            let shift = responders.isEmpty ? 0 : round % responders.count
            let order = Array(responders[shift...]) + Array(responders[..<shift])
            if let next = order.first(where: { !finished.contains("\(round)/\($0.memberId)") && due($0) }) { return next }
            if !replies.contains(where: { $0.round == round }) { return nil }
        }
        return nil
    }

    /// Members a bot @-cited and who haven't spoken since.
    static func cited(_ replies: [RoomEvent], members: [RoomMember]) -> [RoomMember] {
        var citedAt: [String: Int] = [:], spokeAt: [String: Int] = [:]
        for reply in replies {
            let speaker = reply.memberId ?? ""
            spokeAt[speaker] = reply.seq
            for m in addressed(reply.text, members: members, everyoneByDefault: false) where m.memberId != speaker {
                citedAt[m.memberId] = reply.seq
            }
        }
        return members.filter { m in citedAt[m.memberId].map { (spokeAt[m.memberId] ?? 0) <= $0 } ?? false }
    }
}

/// How often an open room reads its log. There is no push for rooms, so the app polls.
public enum RoomPolling {
    public static let active: Duration = .seconds(1)
    public static let idle: Duration = .seconds(10)
    /// The driver may take a moment to report work after a send; poll fast through that gap.
    static let sendGrace: TimeInterval = 8

    public static func interval(working: Bool, sentAt: Date?, now: Date = Date()) -> Duration {
        if working { return active }
        if let sentAt, now.timeIntervalSince(sentAt) < sendGrace { return active }
        return idle
    }
}

/// Room, member and event ids in the shape the server accepts (`^[A-Za-z0-9][A-Za-z0-9._:-]*$`, at most 128 characters).
public enum RoomIds {
    static let reserved: Set<String> = ["all", "everyone"]

    /// Lowercase letters, digits, `_` and `-` (what the composer's @ picker matches), trimmed; empty when nothing is left.
    static func slug(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    /// A new room's id; disbanded ids stay retired forever, so it carries a random suffix.
    public static func room(name: String, suffix: String = String(UUID().uuidString.prefix(8)).lowercased()) -> String {
        let base = String(slug(name).prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return "m-" + (base.isEmpty ? "" : base + "-") + suffix
    }

    /// Members for the picked bots, handled as the Bot Chat @ picker names them (Hermes is @hermes).
    /// Handles stay unique and never take the reserved @all or @everyone.
    public static func members(for bots: [Bot]) -> [RoomMember] {
        var handles: Set<String> = reserved, ids: Set<String> = []
        func unique(_ base: String, _ used: inout Set<String>, fallback: String) -> String {
            let root = base.isEmpty ? fallback : base
            var candidate = root, n = 2
            while used.contains(candidate) { candidate = "\(root)-\(n)"; n += 1 }
            used.insert(candidate)
            return candidate
        }
        return bots.map { bot in
            RoomMember(memberId: unique(slug(bot.name), &ids, fallback: "member"),
                       profile: bot.name,
                       handle: unique(slug(bot.handle), &handles, fallback: "bot"),
                       displayName: bot.label)
        }
    }

    /// A client retry key for one send or rename.
    public static func event(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.lowercased())" }
}

/// What the Groups list remembers per room across launches.
public struct RoomMark: Codable, Hashable, Sendable {
    /// Log sequence the preview below was read through.
    public var cursor = 0
    /// Last log sequence the user has seen in the room.
    public var read = 0
    /// Sequence of the newest bot reply, which is what makes a room unread.
    public var replySeq = 0
    /// The newest message: its speaker's profile (nil for the user) and text.
    public var speaker: String?
    public var preview = ""

    public init() {}

    public var unread: Bool { replySeq > read }

    /// Folds a log page (oldest first) into the preview.
    mutating func note(_ events: [RoomEvent], room: Room) {
        for e in events {
            cursor = max(cursor, e.seq)
            switch e.kind {
            case "message.user":
                speaker = nil
                preview = e.text
            case "message.member":
                speaker = room.member(e.memberId)?.profile ?? e.actor["profile"]?.string
                preview = e.text
                replySeq = max(replySeq, e.seq)
            default:
                break
            }
        }
    }
}

public enum RoomMarks {
    static let key = "groups.marks"

    public static func load(from defaults: UserDefaults = .standard) -> [String: RoomMark] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: RoomMark].self, from: data)) ?? [:]
    }

    public static func save(_ marks: [String: RoomMark], to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(marks), forKey: key)
    }
}
