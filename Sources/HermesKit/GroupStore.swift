import Foundation
import Observation

/// The Groups tab: the gateway's hosted rooms, with a preview and an unread mark per room.
@MainActor @Observable
public final class GroupStore {
    public let gateway: Gateway
    public private(set) var rooms: [Room] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var marks: [String: RoomMark]

    @ObservationIgnored private var stores: [String: RoomStore] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshing = false

    public init(gateway: Gateway, defaults: UserDefaults = .standard) {
        self.gateway = gateway
        self.defaults = defaults
        marks = RoomMarks.load(from: defaults)
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await gateway.call("groups.list", ["limit": 100])
            rooms = (result["rooms"]?.array ?? []).compactMap(Room.init)
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        for room in rooms where room.latestSeq > (marks[room.id]?.cursor ?? 0) {
            await loadPreview(room)
        }
    }

    /// The room's store, kept for the session so reopening a room doesn't reread its log.
    public func store(for id: String) -> RoomStore {
        if let store = stores[id] { return store }
        let store = RoomStore(gateway: gateway, room: room(id) ?? Room(id: id, name: id, members: []), groups: self)
        stores[id] = store
        return store
    }

    public func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    public func unread(_ room: Room) -> Bool { marks[room.id]?.unread ?? false }

    /// Creates the room; `id` should stay the same across retries of one creation so the server dedupes it.
    public func create(id: String, name: String, bots: [Bot]) async throws -> Room {
        let members = RoomIds.members(for: bots)
        let result = try await gateway.call("groups.create", [
            "room_id": .string(id), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "members": .array(members.map(\.json)),
        ])
        guard let room = result["room"].flatMap({ Room($0) }) else { throw GatewayError.rpc(0, "The server sent no room.") }
        rooms.removeAll { $0.id == room.id }
        rooms.insert(room, at: 0)
        return room
    }

    public func disband(_ id: String) async throws {
        _ = try await gateway.call("groups.disband", ["room_id": .string(id)])
        rooms.removeAll { $0.id == id }
        stores[id] = nil
        marks[id] = nil
        RoomMarks.save(marks, to: defaults)
    }

    // MARK: - From room stores

    func update(_ room: Room) {
        guard let i = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        rooms[i] = room
    }

    func noted(_ events: [RoomEvent], in room: Room, read: Bool) {
        var mark = marks[room.id] ?? RoomMark()
        mark.note(events, room: room)
        if read { mark.read = max(mark.read, mark.cursor) }
        guard mark != marks[room.id] else { return }
        marks[room.id] = mark
        RoomMarks.save(marks, to: defaults)
    }

    func removed(_ id: String) {
        rooms.removeAll { $0.id == id }
    }

    private func loadPreview(_ room: Room) async {
        let page = 30
        guard let log = try? await gateway.call("groups.log", [
            "room_id": .string(room.id), "since_seq": .number(Double(max(0, room.latestSeq - page))), "limit": .number(Double(page)),
        ]) else { return }
        noted((log["events"]?.array ?? []).compactMap(RoomEvent.init), in: room, read: false)
    }
}

/// One open room: its log, the driver's status and the user's actions in it.
@MainActor @Observable
public final class RoomStore {
    /// Every message goes to one thread so each bot sees the whole conversation; the server scopes context
    /// and rounds per thread, and the app has no thread UI.
    public static let thread = "main"

    public let gateway: Gateway
    public private(set) var room: Room
    public private(set) var events: [RoomEvent] = []
    public private(set) var cursor = 0
    public private(set) var status = RoomStatus()
    public private(set) var loaded = false
    public private(set) var sending = false
    /// The room was disbanded or no longer exists on the server.
    public private(set) var gone = false
    public var alert: String?
    /// The room is on screen with the app active; read marks follow it.
    public var visible = false {
        didSet { if visible { groups?.noted([], in: room, read: true) } }
    }

    @ObservationIgnored weak var groups: GroupStore?
    @ObservationIgnored var sentAt: Date?
    @ObservationIgnored private var polling = false

    public init(gateway: Gateway, room: Room, groups: GroupStore? = nil) {
        self.gateway = gateway
        self.room = room
        self.groups = groups
    }

    /// Bots are replying or about to: the driver reports work, or it is alive and the newest message is still open.
    public var working: Bool {
        status.working || (status.running && !status.blocked && RoomDiscussion.pending(events) != nil)
    }

    public var nextPoll: Duration { RoomPolling.interval(working: working, sentAt: sentAt) }

    public var replying: RoomMember? { working ? RoomDiscussion.nextSpeaker(events, members: room.members) : nil }

    // MARK: - Reading

    /// Reads new log events and the driver status.
    public func poll() async {
        guard !polling, !gone else { return }
        polling = true
        defer { polling = false }
        await readLog()
        await readState()
    }

    private func readLog() async {
        // A page holds at most 500 events; a long room arrives over a few calls.
        for _ in 0..<20 {
            do {
                let page = try await gateway.call("groups.log", [
                    "room_id": .string(room.id), "since_seq": .number(Double(cursor)), "limit": 500,
                ])
                apply(page: page)
                if page["has_more"]?.bool != true { break }
            } catch GatewayError.rpc(4112, let message) {
                // The log restarted under the same id (cursor ahead), or the room is gone.
                if message.contains("ahead") {
                    events = []
                    cursor = 0
                } else {
                    gone = true
                    groups?.removed(room.id)
                }
                return
            } catch {
                return
            }
        }
        loaded = true
    }

    private func readState() async {
        guard let result = try? await gateway.call("groups.state", ["room_id": .string(room.id)]) else { return }
        if let r = result["room"].flatMap({ Room($0) }) {
            room = r
            groups?.update(r)
        }
        status = RoomStatus(result["driver_status"])
    }

    func apply(page: JSON) {
        let fresh = (page["events"]?.array ?? []).compactMap(RoomEvent.init).filter { $0.seq > cursor }
        events += fresh
        cursor = max(cursor, page["cursor"]?.int ?? cursor, fresh.last?.seq ?? 0)
        if !fresh.isEmpty { groups?.noted(fresh, in: room, read: visible) }
    }

    // MARK: - Actions

    public func send(_ text: String) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await gateway.call("groups.send", [
                "room_id": .string(room.id), "event_id": .string(RoomIds.event("mobile")),
                "payload": ["text": .string(body), "thread_id": .string(Self.thread)],
            ])
            sentAt = Date()
        } catch {
            alert = error.localizedDescription
        }
        await poll()
    }

    public func stop() async {
        // The stop fence is idempotent per cancel id, so each Stop needs its own or a later one would be a no-op.
        await act("groups.stop", ["cancel_id": .string(RoomIds.event("mobile-stop"))])
    }

    public func approve(_ action: RoomAction, choice: String) async {
        await act("groups.approve", [
            "member_id": .string(action.memberId), "task_id": .string(action.taskId),
            "execution_generation": .number(Double(action.executionGeneration)),
            "request_id": .string(action.requestId), "choice": .string(choice),
        ])
    }

    public func retry(_ taskId: String) async {
        sentAt = Date()
        await act("groups.retry", ["task_id": .string(taskId)])
    }

    public func rename(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != room.name else { return }
        await act("groups.rename", ["event_id": .string(RoomIds.event("rename")), "name": .string(trimmed)])
    }

    private func act(_ method: String, _ params: [String: JSON]) async {
        do {
            _ = try await gateway.call(method, params.merging(["room_id": .string(room.id)]) { a, _ in a })
        } catch {
            alert = error.localizedDescription
        }
        await poll()
    }
}
