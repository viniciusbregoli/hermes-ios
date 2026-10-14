import Foundation

// A chat's goal, loop and heartbeat, as the desktop's status cards show them (desktop store/session-control.ts,
// app/chat/composer/status-stack/session-control-*.tsx; gateway tui_gateway/methods_session_control.py).

/// `session.control.read`'s `control` snapshot. Each part is nil when it isn't set.
public struct SessionControl: Equatable, Sendable {
    public struct Goal: Equatable, Sendable {
        public enum Status: String, Sendable { case active, paused, done }
        public var title: String
        public var status: Status
        public var turnsUsed: Int
        /// 0 when the goal has no turn budget.
        public var maxTurns: Int
        public var subgoals: [String]
        public var pausedReason: String?
        /// The judge's last call: continue, done, blocked, wait or skipped.
        public var lastVerdict: String?
        public var lastReason: String?
        /// Parked until a time, a session or a process; `goal.unwait` lifts it.
        public var waiting: Bool

        /// What the card's header calls the goal's state.
        public var state: String {
            if lastVerdict == "blocked" { return "Blocked" }
            if waiting { return "Waiting" }
            return status.rawValue.capitalized
        }

        public var turns: String {
            if status == .done { return turnsUsed == 1 ? "1 turn" : "\(turnsUsed) turns" }
            if maxTurns > 0 { return "turn \(turnsUsed) of \(maxTurns)" }
            return turnsUsed > 0 ? "turn \(turnsUsed)" : ""
        }
    }

    public struct Loop: Equatable, Sendable {
        public enum Status: String, Sendable { case active, paused, done }
        public var prompt: String
        public var status: Status
        /// "interval" or "self_paced".
        public var mode: String
        public var intervalSeconds: Int
        public var ticksFired: Int
        /// 0 when the loop runs until stopped.
        public var maxTicks: Int
        public var nextDueAt: Date?
        /// An active goal holds the loop's wakeups until it finishes.
        public var deferredByGoal: Bool
        public var pausedReason: String?
    }

    public struct Heartbeat: Equatable, Sendable {
        public enum Status: String, Sendable { case active, paused }
        public var prompt: String
        public var status: Status
        public var intervalSeconds: Int
        public var fireCount: Int
    }

    public var goal: Goal?
    public var loop: Loop?
    public var heartbeat: Heartbeat?
    /// A hash of the visible state: equal revisions are equal snapshots.
    public var revision: String

    public var isEmpty: Bool { goal == nil && loop == nil && heartbeat == nil }

    /// Parts with a missing field or unknown status are dropped, like the desktop's strict parser.
    public init?(_ json: JSON?) {
        guard let json, json.object != nil else { return nil }
        revision = json["revision"]?.string ?? ""
        goal = json["goal"].flatMap(Self.parseGoal)
        loop = json["loop"].flatMap(Self.parseLoop)
        heartbeat = json["heartbeat"].flatMap(Self.parseHeartbeat)
    }

    private static func parseGoal(_ g: JSON) -> Goal? {
        guard let title = g["title"]?.string, let status = g["status"]?.string.flatMap(Goal.Status.init) else { return nil }
        return Goal(title: title, status: status, turnsUsed: g["turns_used"]?.int ?? 0, maxTurns: g["max_turns"]?.int ?? 0,
                    subgoals: g["subgoals"]?.array?.compactMap(\.string) ?? [], pausedReason: g["paused_reason"]?.string?.nonEmpty,
                    lastVerdict: g["last_verdict"]?.string, lastReason: g["last_reason"]?.string?.nonEmpty,
                    waiting: g["wait_barrier"]?.object != nil)
    }

    private static func parseLoop(_ l: JSON) -> Loop? {
        guard let prompt = l["prompt"]?.string, let status = l["status"]?.string.flatMap(Loop.Status.init) else { return nil }
        let due = l["next_due_at"]?.double ?? 0
        return Loop(prompt: prompt, status: status, mode: l["mode"]?.string ?? "interval", intervalSeconds: l["interval_seconds"]?.int ?? 0,
                    ticksFired: l["ticks_fired"]?.int ?? 0, maxTicks: l["max_ticks"]?.int ?? 0,
                    nextDueAt: due > 0 ? Date(timeIntervalSince1970: due) : nil, deferredByGoal: l["deferred_by_goal"]?.bool ?? false,
                    pausedReason: l["paused_reason"]?.string?.nonEmpty)
    }

    private static func parseHeartbeat(_ h: JSON) -> Heartbeat? {
        guard let prompt = h["prompt"]?.string, let status = h["status"]?.string.flatMap(Heartbeat.Status.init) else { return nil }
        return Heartbeat(prompt: prompt, status: status, intervalSeconds: h["interval_seconds"]?.int ?? 0, fireCount: h["fire_count"]?.int ?? 0)
    }

    /// "every 5m", "every 1h 30m".
    public static func interval(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        return "every " + (f.string(from: TimeInterval(seconds)) ?? "\(seconds)s")
    }
}

extension ChatStore {
    /// Slash commands whose success changes the control snapshot (the gateway's `_SESSION_CONTROL_SLASHES`).
    static let controlCommands: Set<String> = ["goal", "loop", "heartbeat", "subgoal"]

    public func refreshControl() async {
        guard let sid = runtimeId else { return }
        let seen = controlVersion
        guard let r = try? await gateway.call("session.control.read", ["session_id": .string(sid)]) else { return }
        applyControlRead(r["control"], seen: seen, session: sid)
    }

    /// A read only lands if no update arrived and the chat didn't change while it was in flight.
    func applyControlRead(_ json: JSON?, seen: Int, session: String) {
        guard seen == controlVersion, session == runtimeId, let c = SessionControl(json) else { return }
        applyControl(c)
    }

    /// Runs one `session.control` action; a goal resume answers with a turn to send, which queues if one is running.
    /// - Parameters:
    ///   - text: for subgoal.add.
    ///   - index: 1-based, for subgoal.remove.
    public func control(_ action: String, text: String? = nil, index: Int? = nil) async {
        do {
            let sid = try await ensureSession()
            var args: [String: JSON] = [:]
            if let text { args["text"] = .string(text) }
            if let index { args["index"] = .number(Double(index)) }
            var params: [String: JSON] = ["session_id": .string(sid), "action": .string(action)]
            if !args.isEmpty { params["args"] = .object(args) }
            let r = try await gateway.call("session.control", params)
            if let c = SessionControl(r["control"]), sid == runtimeId { applyControl(c) }
            if let dispatch = r["dispatch"], case .send(let message, let display, _) = SlashDirective(dispatch, command: action) {
                await send(message, display: display)
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    func foldControl(_ type: String, _ p: JSON) {
        guard type == "session.control.update", let c = SessionControl(p["control"]) else { return }
        applyControl(c)
    }

    private func applyControl(_ c: SessionControl) {
        controlVersion += 1
        control = c.isEmpty ? nil : c
    }
}
