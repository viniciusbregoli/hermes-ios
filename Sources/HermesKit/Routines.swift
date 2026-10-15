import Foundation
import Observation

/// A cron job ("routine"), as `cron.manage list` and the dashboard's `/api/cron/jobs` report it.
public struct Routine: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    /// `schedule_display`: a cron expression, "every 30m", "once at 2026-10-07 08:20" or the phrase the user typed.
    public var schedule: String
    /// The first 100 characters from the list; the whole prompt once the detail fetched the job.
    public var prompt: String
    public var enabled: Bool
    /// "scheduled", "paused", "completed" or "running".
    public var state: String
    public var nextRun: Date?
    public var lastRun: Date?
    public var lastStatus: String?
    public var lastError: String?
    public var deliver: String
    public var model: String?

    init?(_ row: JSON) {
        guard let id = (row["job_id"] ?? row["id"])?.string else { return nil }
        self.id = id
        name = row["name"]?.string?.nonEmpty ?? id
        schedule = row["schedule_display"]?.string ?? row["schedule"]?.string ?? row["schedule"]?["display"]?.string ?? ""
        prompt = row["prompt"]?.string ?? row["prompt_preview"]?.string ?? ""
        enabled = row["enabled"]?.bool ?? true
        state = row["state"]?.string ?? (enabled ? "scheduled" : "paused")
        nextRun = Self.date(row["next_run_at"])
        lastRun = Self.date(row["last_run_at"])
        lastStatus = row["last_status"]?.string
        lastError = row["last_error"]?.string?.nonEmpty ?? row["last_delivery_error"]?.string?.nonEmpty
            ?? row["last_fire_error"]?.string?.nonEmpty
        deliver = row["deliver"]?.string?.nonEmpty ?? "local"
        model = row["model"]?.string?.nonEmpty
    }

    public init(id: String, name: String, schedule: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.schedule = schedule
        prompt = ""
        self.enabled = enabled
        state = enabled ? "scheduled" : "paused"
        deliver = "local"
    }

    /// The last run failed (or its output never reached the target).
    public var failed: Bool {
        guard let s = lastStatus else { return false }
        return !["ok", "delivery_queued", "running"].contains(s)
    }

    public var completed: Bool { state == "completed" }

    /// The name without the "[bot:<profile>] " tag the desktop's Bot Routines put in front.
    public var title: String {
        name.replacingOccurrences(of: #"^\[bot:[a-z0-9][a-z0-9_-]*\]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .nonEmpty ?? name
    }

    public static func list(_ result: JSON) -> [Routine] {
        (result["jobs"]?.array ?? []).compactMap(Routine.init)
    }

    /// Python's `isoformat()` ("2026-10-13T08:01:10.866118-03:00"), or epoch seconds.
    static func date(_ value: JSON?) -> Date? {
        if let t = value?.double { return Date(timeIntervalSince1970: t) }
        guard let raw = value?.string?.nonEmpty else { return nil }
        // ISO8601DateFormatter takes at most milliseconds; the minute matters here, not the fraction.
        let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: trimmed)
    }
}

/// One run of a routine: an ordinary session (`cron_<job>_<time>`), or a script-only fire with no session.
public struct RoutineRun: Identifiable, Hashable, Sendable {
    public let id: String
    /// Stored session id; nil for a script-only fire.
    public let sessionId: String?
    public let title: String
    public let preview: String
    public let startedAt: Date?
    public let active: Bool
    /// The profile whose database holds the session.
    public let profile: String?

    init(_ row: JSON, index: Int) {
        sessionId = row["source"]?.string == "cron_output" ? nil : row["id"]?.string?.nonEmpty
        id = sessionId ?? "run-\(index)"
        title = row["title"]?.string ?? ""
        preview = row["preview"]?.string ?? ""
        startedAt = row["started_at"]?.double.map(Date.init(timeIntervalSince1970:))
        active = row["is_active"]?.bool ?? false
        profile = row["profile"]?.string?.nonEmpty
    }

    public static func list(_ result: JSON) -> [RoutineRun] {
        (result["runs"]?.array ?? []).enumerated().map { RoutineRun($1, index: $0) }
    }
}

/// Where a routine's output goes (`GET /api/cron/delivery-targets`).
public struct DeliveryTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// False for a platform with no home channel configured, so delivering there would fail.
    public let ready: Bool

    public init(id: String, name: String, ready: Bool = true) {
        self.id = id
        self.name = name
        self.ready = ready
    }

    public static let local = DeliveryTarget(id: "local", name: "Local (save only)")

    public static func list(_ result: JSON) -> [DeliveryTarget] {
        let targets = (result["targets"]?.array ?? []).compactMap { t -> DeliveryTarget? in
            guard let id = t["id"]?.string else { return nil }
            return DeliveryTarget(id: id, name: t["name"]?.string ?? id, ready: t["home_target_set"]?.bool ?? true)
        }
        return targets.isEmpty ? [.local] : targets
    }

    /// Words for a stored `deliver` value ("origin", "telegram:8957600411", "local").
    public static func label(_ deliver: String, targets: [DeliveryTarget] = []) -> String {
        if let t = targets.first(where: { $0.id == deliver }) { return t.name }
        switch deliver {
        case "", "local": return "Local (save only)"
        case "origin": return "Where it was created"
        default:
            let parts = deliver.split(separator: ":", maxSplits: 1).map(String.init)
            let platform = parts[0] == "bot-chat" ? "Bot Chat" : parts[0].capitalized
            return parts.count > 1 ? "\(platform) (\(parts[1]))" : platform
        }
    }
}

// MARK: - Schedules

public enum Schedule {
    /// Starting points for a new routine; `.custom` takes whatever the user types.
    public enum Preset: String, CaseIterable, Identifiable, Sendable {
        case morning, hourly, weekdays, custom

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .morning: "Every morning at 8"
            case .hourly: "Every hour"
            case .weekdays: "Weekdays at 9"
            case .custom: "Custom"
            }
        }

        /// The schedule string the server parses; nil for custom.
        public var schedule: String? {
            switch self {
            case .morning: "0 8 * * *"
            case .hourly: "0 * * * *"
            case .weekdays: "0 9 * * 1-5"
            case .custom: nil
            }
        }
    }

    /// Words for a schedule ("Every day at 08:00"), or nil when the raw form is already the clearest one.
    public static func describe(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let lower = s.lowercased()
        if lower.hasPrefix("every "), let minutes = intervalMinutes(String(lower.dropFirst(6))) {
            return every(minutes)
        }
        if lower.hasPrefix("once ") { return "Once " + s.dropFirst(5) }
        let fields = s.split(separator: " ").map(String.init)
        if fields.count == 5 { return cron(fields) }
        return nil
    }

    /// "30m" → 30, "2h" → 120, "1d" → 1440 (cron/jobs.py parse_duration).
    static func intervalMinutes(_ s: String) -> Int? {
        guard let m = s.range(of: #"^(\d*)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$"#, options: .regularExpression)
        else { return nil }
        let text = String(s[m])
        let digits = text.prefix { $0.isNumber }
        let value = Int(digits) ?? 1
        switch text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).first {
        case "h": return value * 60
        case "d": return value * 1440
        default: return value
        }
    }

    static func every(_ minutes: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "Every \(word)" : "Every \(n) \(word)s" }
        if minutes > 0, minutes % 1440 == 0 { return unit(minutes / 1440, "day") }
        if minutes > 0, minutes % 60 == 0 { return unit(minutes / 60, "hour") }
        return unit(minutes, "minute")
    }

    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func cron(_ f: [String]) -> String? {
        let (minute, hour, dom, month, dow) = (f[0], f[1], f[2], f[3], f[4])
        if month != "*" { return inMonths(month, minute: minute, hour: hour, dom: dom, dow: dow) }
        if minute == "*", hour == "*", dom == "*", dow == "*" { return "Every minute" }
        if let n = step(minute), hour == "*", dom == "*", dow == "*" { return every(n) }
        if let m = Int(minute), hour == "*", dom == "*", dow == "*" {
            return m == 0 ? "Every hour" : "Every hour at :\(pad(m))"
        }
        if minute == "0", let n = step(hour), dom == "*", dow == "*" { return every(n * 60) }
        guard let m = Int(minute), let h = Int(hour), m < 60, h < 24 else { return nil }
        let time = "\(pad(h)):\(pad(m))"
        if dom == "*", dow == "*" { return "Every day at \(time)" }
        if dom == "*", let days = days(dow) { return "\(days) at \(time)" }
        if let d = Int(dom), dow == "*" { return "Monthly on day \(d) at \(time)" }
        return nil
    }

    /// A cron with a month: "At 04:00 on January 1", "Every day in June at 09:00", "Mondays in January at 09:00".
    /// Only a fixed time of day is described; the stepped and hourly forms keep their raw text.
    static func inMonths(_ month: String, minute: String, hour: String, dom: String, dow: String) -> String? {
        guard let months = monthNames(month), let m = Int(minute), let h = Int(hour), m < 60, h < 24 else { return nil }
        let time = "\(pad(h)):\(pad(m))"
        let list = months.joined(separator: ", ")
        if dom == "*", dow == "*" { return "Every day in \(list) at \(time)" }
        if dom == "*", let days = days(dow) { return "\(days) in \(list) at \(time)" }
        guard let d = Int(dom), (1...31).contains(d), dow == "*" else { return nil }
        return months.count == 1 ? "At \(time) on \(list) \(d)" : "At \(time) on day \(d) of \(list)"
    }

    static let monthList = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// "1", "jan", "1,7" and "6-8" → month names, in calendar order; nil for anything else (steps, out of range).
    static func monthNames(_ field: String) -> [String]? {
        func month(_ s: String) -> Int? {
            if let n = Int(s) { return (1...12).contains(n) ? n : nil }
            return s.count >= 3 ? monthList.firstIndex { $0.lowercased().hasPrefix(s) }.map { $0 + 1 } : nil
        }
        var set: Set<Int> = []
        for part in field.lowercased().split(separator: ",") {
            let bounds = part.split(separator: "-").map(String.init)
            guard (1...2).contains(bounds.count), let a = month(bounds[0]) else { return nil }
            if bounds.count == 2 {
                guard let b = month(bounds[1]), a <= b else { return nil }
                set.formUnion(a...b)
            } else {
                set.insert(a)
            }
        }
        return set.isEmpty ? nil : set.sorted().map { monthList[$0 - 1] }
    }

    /// "*/15" → 15.
    static func step(_ field: String) -> Int? {
        guard field.hasPrefix("*/"), let n = Int(field.dropFirst(2)), n > 0 else { return nil }
        return n
    }

    static func days(_ field: String) -> String? {
        var set: [Int] = []
        for part in field.lowercased().split(separator: ",") {
            let bounds = part.split(separator: "-").map(String.init)
            guard let a = day(bounds[0]) else { return nil }
            if bounds.count == 2 {
                guard let b = day(bounds[1]), a <= b else { return nil }
                set.append(contentsOf: a...b)
            } else {
                set.append(a)
            }
        }
        let days = Set(set.map { $0 % 7 })
        if days == [1, 2, 3, 4, 5] { return "Weekdays" }
        if days == [0, 6] { return "Weekends" }
        if days.count == 7 { return "Every day" }
        let sorted = days.sorted { ($0 + 6) % 7 < ($1 + 6) % 7 }
        if sorted.count == 1 { return dayNames[sorted[0]] + "s" }
        return sorted.map { String(dayNames[$0].prefix(3)) }.joined(separator: ", ")
    }

    static func day(_ s: String) -> Int? {
        if let n = Int(s), (0...7).contains(n) { return n }
        return dayNames.firstIndex { $0.lowercased().hasPrefix(s) && s.count >= 3 }
    }

    static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

// MARK: - Store

/// The routines in one cron store: the server's own (`profile` nil) or a bot's.
/// List, add, pause, resume and remove go over `cron.manage`; the rest only exists in the dashboard's REST API.
@MainActor @Observable
public final class RoutineStore {
    public let gateway: Gateway
    public let profile: String?
    public private(set) var routines: [Routine] = []
    public private(set) var loaded = false
    public private(set) var error: String?

    public init(gateway: Gateway, profile: String?) {
        self.gateway = gateway
        self.profile = profile == "default" ? nil : profile
        gateway.listen(self, event: { [weak self] e in
            if e.type == "cron.changed" { Task { await self?.refresh() } }
        }, connected: { [weak self] in Task { await self?.refresh() } })
    }

    public func refresh() async {
        do {
            routines = Routine.list(try await manage("list", ["include_disabled": true]))
            loaded = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func routine(_ id: String) -> Routine? { routines.first { $0.id == id } }

    /// A bot's routine is tagged like the desktop's Bot Routines name it, so its pane recognizes the job.
    public func storedName(_ title: String) -> String {
        profile.map { "[bot:\($0)] \(title)" } ?? title
    }

    public func setEnabled(_ id: String, _ on: Bool) async throws {
        _ = try await manage(on ? "resume" : "pause", ["name": .string(id)])
        await refresh()
    }

    public func remove(_ id: String) async throws {
        _ = try await manage("remove", ["name": .string(id)])
        routines.removeAll { $0.id == id }
    }

    public func create(name: String, schedule: String, prompt: String, deliver: String) async throws {
        _ = try await manage("add", ["name": .string(storedName(name)), "schedule": .string(schedule), "prompt": .string(prompt),
                                     "deliver": .string(deliver)])
        await refresh()
    }

    /// The whole job, prompt included (the list only carries a preview).
    public func fetch(_ id: String) async throws -> Routine {
        guard let r = Routine(try await rest("GET", "jobs/\(id)")) else { throw GatewayError.rpc(0, "Routine not found.") }
        return r
    }

    /// Runs the job now and returns once the run finished; the server holds the request open meanwhile.
    public func run(_ id: String) async throws {
        _ = try await rest("POST", "jobs/\(id)/trigger", timeout: 600)
        await refresh()
    }

    /// Sends only the fields in `updates` (name, schedule, prompt, deliver).
    public func update(_ id: String, _ updates: [String: JSON]) async throws {
        guard !updates.isEmpty else { return }
        _ = try await rest("PUT", "jobs/\(id)", body: ["updates": .object(updates)])
        await refresh()
    }

    public func runs(_ id: String) async throws -> [RoutineRun] {
        RoutineRun.list(try await rest("GET", "jobs/\(id)/runs"))
    }

    public func deliveryTargets() async throws -> [DeliveryTarget] {
        DeliveryTarget.list(try await rest("GET", "delivery-targets"))
    }

    /// `cron.manage` answers tool failures as a result with `success: false`, not as an RPC error.
    private func manage(_ action: String, _ params: [String: JSON]) async throws -> JSON {
        var p = params
        p["action"] = .string(action)
        if let profile { p["profile"] = .string(profile) }
        let r = try await gateway.call("cron.manage", p)
        if r["success"]?.bool == false { throw GatewayError.rpc(0, r["error"]?.string ?? "The routine change failed.") }
        return r
    }

    private func rest(_ method: String, _ path: String, body: [String: JSON]? = nil, timeout: TimeInterval = 60) async throws -> JSON {
        try await gateway.rest(method, "api/cron/\(path)", query: profile.map { ["profile": $0] } ?? [:], body: body, timeout: timeout)
    }
}
