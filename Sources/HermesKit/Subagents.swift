import Foundation

/// One delegated child, folded from `subagent.*` events and `subagent.list` snapshots
/// (desktop store/subagents.ts).
public struct Subagent: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case queued, running, completed, failed, interrupted

        public var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }

        /// A `subagent.complete` is terminal by definition, so an unknown status there is a failure,
        /// never a row left spinning.
        static func parse(_ raw: String?, terminalEvent: Bool) -> Status {
            switch raw {
            case "completed": return .completed
            case "failed", "timeout", "error": return .failed
            case "interrupted", "cancelled", "canceled": return .interrupted
            default: return terminalEvent ? .failed : raw == "queued" ? .queued : .running
            }
        }
    }

    public let id: String
    public var parentId: String?
    public var delegationId: String?
    public var childSessionId: String?
    public var depth = 0
    public var goal = ""
    public var model = ""
    public var status = Status.running
    public var taskIndex = 0
    public var taskCount = 1
    public var toolCount = 0
    public var lastTool: String?
    public var startedAt: Date
    public var duration: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var summary: String?
    /// Recent tool calls and progress lines, oldest first.
    public var activity: [String] = []
    public var acceptingSteer = true
    /// The Delegate tier that asked for this child ("Light"), when this app started it.
    public var tier: String?
    /// A `subagent.list` snapshot has shown it, so a later snapshot without it means it ended.
    var listed = false

    static let maxActivity = 24

    mutating func merge(_ p: JSON, event: String) {
        if let v = p["goal"]?.string?.nonEmpty { goal = v }
        if let v = p["parent_id"]?.string?.nonEmpty { parentId = v }
        if let v = p["delegation_id"]?.string?.nonEmpty { delegationId = v }
        if let v = p["child_session_id"]?.string?.nonEmpty { childSessionId = v }
        if let v = p["model"]?.string?.nonEmpty { model = v }
        if let v = p["depth"]?.int { depth = v }
        if let v = p["task_index"]?.int { taskIndex = v }
        if let v = p["task_count"]?.int { taskCount = v }
        if let v = p["tool_count"]?.int { toolCount = v }
        if let v = p["input_tokens"]?.int { inputTokens = v }
        if let v = p["output_tokens"]?.int { outputTokens = v }
        if let v = p["duration_seconds"]?.double { duration = v }
        if let v = p["accepting_steer"]?.bool { acceptingSteer = v }
        status = Status.parse(p["status"]?.string, terminalEvent: event == "subagent.complete")

        for t in p["output_tail"]?.array ?? [] {
            if let line = Self.toolLine(t["tool"]?.string, t["preview"]?.string) { log(line) }
        }
        if let tool = p["tool_name"]?.string?.nonEmpty {
            lastTool = tool
            if let line = Self.toolLine(tool, p["tool_preview"]?.string ?? p["text"]?.string) { log(line) }
        } else if event == "subagent.progress" || event == "subagent.thinking", let text = Self.compact(p["text"]?.string) {
            log(text)
        }
        if status.isTerminal {
            acceptingSteer = false
            if let s = p["summary"]?.string?.nonEmpty {
                summary = s
            } else if p["status"]?.string == "timeout" {
                summary = "Timed out after \(Int(duration ?? 0))s"
            }
        }
    }

    private mutating func log(_ line: String) {
        guard activity.last != line else { return }
        activity.append(line)
        if activity.count > Self.maxActivity { activity.removeFirst(activity.count - Self.maxActivity) }
    }

    static func toolLine(_ tool: String?, _ preview: String?) -> String? {
        guard let tool = tool?.nonEmpty else { return compact(preview) }
        return compact(preview, max: 96).map { "\(tool)(\($0))" } ?? tool
    }

    static func compact(_ text: String?, max: Int = 220) -> String? {
        guard let line = text?.split(whereSeparator: \.isWhitespace).joined(separator: " ").nonEmpty else { return nil }
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}

/// The open chat's children. Live events are authoritative; `subagent.list` fills in what a
/// reconnect or a closed screen missed.
public struct SubagentRoster: Hashable, Sendable {
    public private(set) var items: [Subagent] = []
    /// Finished ids already pruned from the screen, so a late event or snapshot can't bring them back.
    private var retired: Set<String> = []
    /// Bumped by every event; a snapshot requested before an event landed is stale and dropped.
    public private(set) var version = 0
    /// Label for the next delegation to start, set when this app asked for one.
    private var expectedTier: String?
    private var tiers: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var active: Int { items.filter { !$0.status.isTerminal }.count }
    public func item(_ id: String) -> Subagent? { items.first { $0.id == id } }

    public mutating func expect(tier: String) { expectedTier = tier }

    public mutating func apply(_ type: String, _ p: JSON, now: Date = Date()) {
        guard type.hasPrefix("subagent."), type != "subagent.text" else { return }
        version += 1
        let id = Self.id(of: p)
        guard !retired.contains(id) else { return }
        let index = items.firstIndex { $0.id == id }
        if let index, items[index].status.isTerminal { return }
        var s = index.map { items[$0] } ?? Subagent(id: id, startedAt: now)
        s.merge(p, event: type)
        if s.tier == nil, let d = s.delegationId {
            if tiers[d] == nil, let t = expectedTier {
                tiers[d] = t
                expectedTier = nil
            }
            s.tier = tiers[d]
        }
        if let index { items[index] = s } else { items.append(s) }
    }

    /// Folds a `subagent.list` result. The server forgets a child once it ends (failures stay listed under
    /// `delegations`), and an async child's last events can miss this chat, so a live row the server listed
    /// before and no longer does has finished. A row it never listed only goes once it is clearly stale.
    public mutating func reconcile(_ snapshot: JSON, now: Date = Date()) {
        let rows = snapshot["subagents"]?.array ?? []
        let failed = snapshot["delegations"]?.array ?? []
        let ids = Set(rows.compactMap { $0["subagent_id"]?.string })
        items.removeAll { !$0.status.isTerminal && !ids.contains($0.id) && !$0.listed && now.timeIntervalSince($0.startedAt) > 30 }
        for i in items.indices where !items[i].status.isTerminal && !ids.contains(items[i].id) && items[i].listed {
            let failure = failed.first {
                $0["delegation_id"]?.string == items[i].delegationId && ($0["task_index"]?.int ?? 0) == items[i].taskIndex
            }
            items[i].status = failure == nil ? .completed : .failed
            items[i].acceptingSteer = false
            if let error = failure?["error"]?.string?.nonEmpty { items[i].summary = error }
        }
        for r in rows {
            guard let id = r["subagent_id"]?.string, !retired.contains(id) else { continue }
            let index = items.firstIndex { $0.id == id }
            if let index, items[index].status.isTerminal { continue }
            let started = r["started_at"]?.double.map(Date.init(timeIntervalSince1970:))
            var s = index.map { items[$0] } ?? Subagent(id: id, startedAt: started ?? Date())
            s.merge(r, event: "subagent.list")
            if let started { s.startedAt = started }
            s.listed = true
            // The roster reports the last tool started, not one in flight: seed an empty row only.
            if let tool = r["last_tool"]?.string?.nonEmpty {
                s.lastTool = tool
                if s.activity.isEmpty { s.activity = [tool] }
            }
            if s.tier == nil, let d = s.delegationId { s.tier = tiers[d] }
            if let index { items[index] = s } else { items.append(s) }
        }
    }

    /// When the user starts a new turn, the finished rows go; children still running stay.
    public mutating func pruneFinished() {
        for s in items where s.status.isTerminal { retired.insert(s.id) }
        items.removeAll { $0.status.isTerminal }
    }

    /// Rows grouped by the top-level delegation they belong to, each child under its parent with its depth.
    public func tree() -> [(delegation: String, rows: [(item: Subagent, depth: Int)])] {
        let ids = Set(items.map(\.id))
        var kids: [String: [Subagent]] = [:]
        var roots: [Subagent] = []
        for s in items {
            if let p = s.parentId, ids.contains(p), p != s.id { kids[p, default: []].append(s) } else { roots.append(s) }
        }
        var groups: [(delegation: String, rows: [(item: Subagent, depth: Int)])] = []
        var seen: Set<String> = []
        func walk(_ s: Subagent, _ depth: Int, into rows: inout [(item: Subagent, depth: Int)]) {
            guard seen.insert(s.id).inserted else { return }
            rows.append((s, depth))
            for k in kids[s.id] ?? [] { walk(k, depth + 1, into: &rows) }
        }
        for root in roots {
            let key = root.delegationId ?? root.id
            var rows: [(item: Subagent, depth: Int)] = []
            walk(root, 0, into: &rows)
            if let i = groups.firstIndex(where: { $0.delegation == key }) { groups[i].rows += rows } else { groups.append((key, rows)) }
        }
        return groups
    }

    static func id(of p: JSON) -> String {
        p["subagent_id"]?.string?.nonEmpty
            ?? "\(p["parent_id"]?.string?.nonEmpty ?? "root"):\(p["task_index"]?.int ?? 0):\(p["goal"]?.string ?? "")"
    }
}

// MARK: - Model tiers

/// How heavy a model a delegated task gets. Hermes has no per-task model argument: the tier
/// becomes the profile's `delegation.*` config for as long as the child takes to spawn.
public enum DelegateTier: String, CaseIterable, Identifiable, Sendable {
    case light, standard, heavy
    public var id: String { rawValue }
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    static let heavyWords = ["refactor", "design", "debug", "analyze", "analyse", "analysis", "architect", "implement",
                             "write code", "fix", "investigate", "optimize", "optimise", "migrate", "review", "build",
                             "rewrite", "prove", "diagnose"]
    static let lightWords = ["list", "find", "search", "look up", "lookup", "summarize", "summarise", "summary", "count",
                             "check", "show", "fetch", "grep", "read", "what is", "where is", "translate"]

    /// Heavy work words win; otherwise a short lookup, listing or summary is light; anything else is standard.
    // ponytail: keyword heuristic, fine for picking a default the user sees before confirming;
    // an llm.oneshot classifier would be the upgrade if the guesses annoy.
    public static func suggest(for task: String) -> DelegateTier {
        let text = task.lowercased()
        // Whole words with common endings, so "fixed" counts and "fixture" or "listen" don't.
        func has(_ words: [String]) -> Bool {
            text.range(of: #"\b(?:"# + words.joined(separator: "|") + #")(?:s|es|ed|d|ing|ging)?\b"#, options: .regularExpression) != nil
        }
        if has(heavyWords) { return .heavy }
        if has(lightWords), text.split(whereSeparator: \.isWhitespace).count <= 40 { return .light }
        return .standard
    }
}

/// A model for a tier. An empty `model` inherits the chat's model.
public struct TierModel: Hashable, Sendable {
    public var model: String
    public var provider: String
    public init(model: String, provider: String) { self.model = model; self.provider = provider }
    public static let inherit = TierModel(model: "", provider: "")

    /// Settings override, stored as "provider|model"; "|" means inherit, missing means automatic.
    public init?(stored: String) {
        guard let bar = stored.firstIndex(of: "|") else { return nil }
        provider = String(stored[..<bar])
        model = String(stored[stored.index(after: bar)...])
    }

    public var stored: String { "\(provider)|\(model)" }
    public static func overrideKey(_ tier: DelegateTier) -> String { "subagents.tier.\(tier.rawValue)" }
}

public enum ModelTiers {
    static let lightTokens: Set<String> = ["mini", "nano", "flash", "haiku", "lite", "small", "tiny", "micro"]
    static let heavyTokens: Set<String> = ["pro", "max", "opus", "ultra", "large"]
    /// Flat-rate providers for servers whose rows carry no usage windows or auth type.
    static let subscriptionSlugs: Set<String> = ["openai-codex", "copilot", "copilot-acp", "zai", "nous", "kimi-coding"]

    /// "$0.25/Mtok" → 0.25, "free" → 0, unknown ("") → nil.
    static func price(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased().nonEmpty else { return nil }
        if raw == "free" { return 0 }
        let number = raw.drop { !$0.isNumber && $0 != "." }.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    /// A flat-rate account (a ChatGPT/Codex or Copilot subscription, a coding plan): the server reports quota
    /// windows (`usage`) only for those, OAuth sign-ins are subscriptions, and a few slugs are known ones.
    static func isSubscription(_ row: JSON) -> Bool {
        if let usage = row["usage"], !usage.isNull { return true }
        if row["auth_type"]?.string?.contains("oauth") == true { return true }
        return subscriptionSlugs.contains(row["slug"]?.string ?? "")
    }

    /// Light and Heavy come from signed-in subscription providers first, the chat's own provider ahead of
    /// the others, picked by name (mini/flash/haiku... vs pro/max/opus...) since per-token price means
    /// nothing on a flat rate. Only when no subscription offers one does a pay-per-token provider get the
    /// tier: the cheapest or most expensive model by input price, else by name. Missing when nothing fits.
    public static func defaults(options: JSON, provider: String, model: String) -> [DelegateTier: TierModel] {
        let rows = (options["providers"]?.array ?? [])
            .filter { $0["authenticated"]?.bool != false && !($0["models"]?.array ?? []).isEmpty }
            .enumerated().sorted { a, b in
                let ca = a.element["slug"]?.string == provider, cb = b.element["slug"]?.string == provider
                return ca != cb ? ca : a.offset < b.offset
            }.map(\.element)
        let subscriptions = rows.filter(isSubscription), apis = rows.filter { !isSubscription($0) }
        var out: [DelegateTier: TierModel] = [:]
        for (tier, tokens) in [(DelegateTier.light, lightTokens), (.heavy, heavyTokens)] {
            out[tier] = subscriptions.lazy.compactMap { byName($0, tokens, near: model) }.first
                ?? byPrice(apis, cheapest: tier == .light)
                ?? apis.lazy.compactMap { byName($0, tokens, near: model) }.first
        }
        return out
    }

    /// The row's model whose name carries one of `tokens`: closest to the chat model by shared prefix,
    /// then the newest version, then the shortest name.
    static func byName(_ row: JSON, _ tokens: Set<String>, near model: String) -> TierModel? {
        let models = row["models"]?.array?.compactMap(\.string) ?? []
        let best = models.filter { !tokens.isDisjoint(with: Self.tokens($0)) }.enumerated().max { a, b in
            let ka = (commonPrefix(a.element, model), version(a.element)), kb = (commonPrefix(b.element, model), version(b.element))
            if ka != kb { return ka < kb }
            return a.element.count != b.element.count ? a.element.count > b.element.count : a.offset > b.offset
        }?.element
        return best.map { TierModel(model: $0, provider: row["slug"]?.string ?? "") }
    }

    /// The cheapest or dearest priced model across pay-per-token rows; nil unless at least two prices differ.
    static func byPrice(_ rows: [JSON], cheapest: Bool) -> TierModel? {
        let priced = rows.flatMap { row in
            (row["models"]?.array?.compactMap(\.string) ?? []).compactMap { m in
                price(row["pricing"]?[m]?["input"]?.string).map { (TierModel(model: m, provider: row["slug"]?.string ?? ""), $0) }
            }
        }
        guard Set(priced.map(\.1)).count >= 2 else { return nil }
        // Stable picks: the first model at the extreme price.
        return (cheapest ? priced.min { $0.1 < $1.1 } : priced.max { $0.1 < $1.1 })?.0
    }

    static func tokens(_ model: String) -> Set<String> {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return Set(name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// The first version number in a model name ("claude-opus-4.8-fast" → 4.8), 0 when there is none.
    static func version(_ model: String) -> Double {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return name.range(of: #"\d+(\.\d+)?"#, options: .regularExpression).flatMap { Double(name[$0]) } ?? 0
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
}

// MARK: - Delegation config (dashboard REST)

/// The profile's `delegation.*` keys that pick a child's model. `config.set` refuses them (4002),
/// so they go through the dashboard's `GET/PUT /api/config`, which deep-merges a sparse body.
public struct DelegationValues: Hashable, Sendable {
    public var model = ""
    public var provider = ""
    public var reasoningEffort = ""

    public init(model: String = "", provider: String = "", reasoningEffort: String = "") {
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
    }

    init(_ j: JSON?) {
        model = j?["model"]?.string ?? ""
        provider = j?["provider"]?.string ?? ""
        reasoningEffort = j?["reasoning_effort"]?.string ?? ""
    }

    var json: JSON { ["model": .string(model), "provider": .string(provider), "reasoning_effort": .string(reasoningEffort)] }

    public static func get(_ c: Credentials, profile: String?) async throws -> DelegationValues {
        DelegationValues(try await send(request(c, profile: profile, method: "GET"))["delegation"])
    }

    public static func put(_ v: DelegationValues, _ c: Credentials, profile: String?) async throws {
        var r = request(c, profile: profile, method: "PUT")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSON.object(["config": ["delegation": v.json]]).data()
        _ = try await send(r)
    }

    static func request(_ c: Credentials, profile: String?, method: String) -> URLRequest {
        var comps = URLComponents(url: c.baseURL.appending(path: "api/config"), resolvingAgainstBaseURL: false)!
        if let profile, profile != "default" { comps.queryItems = [.init(name: "profile", value: profile)] }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("Bearer \(c.accessToken)", forHTTPHeaderField: "Authorization")
        return r
    }

    static func send(_ r: URLRequest) async throws -> JSON {
        let (data, resp) = try await Auth.noRedirects.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return (try? JSON.parse(data)) ?? .null
        case 401: throw AuthError.expired
        default: throw AuthError.server(status, String(decoding: data, as: UTF8.self))
        }
    }
}

/// What the Delegate sheet offers: the concrete model behind each tier.
public struct DelegatePlan: Sendable {
    public var tiers: [DelegateTier: TierModel]
    /// The profile's delegation config before this app touches it.
    public var current: DelegationValues
    public var chatModel: String
    public var chatProvider: String

    /// The model a tier's children run, with the chat model filled in for "inherit".
    public func model(for tier: DelegateTier) -> String {
        if let m = tiers[tier] { return m.model.nonEmpty ?? chatModel }
        return current.model.nonEmpty ?? chatModel
    }

    /// The config a tier needs. Standard with no override leaves the profile's config alone;
    /// Light also turns reasoning down. A provider is pinned only when it differs from the chat's.
    public func values(for tier: DelegateTier) -> DelegationValues {
        guard let m = tiers[tier] else {
            return tier == .light ? DelegationValues(model: current.model, provider: current.provider, reasoningEffort: "low") : current
        }
        return DelegationValues(model: m.model, provider: m.provider == chatProvider ? "" : m.provider,
                                reasoningEffort: tier == .light ? "low" : "")
    }
}

// MARK: - Chat actions

/// A delegation config this app changed and must put back.
struct PendingDelegation {
    let token = UUID()
    let previous: DelegationValues
    let profile: String?
}

extension ChatStore {
    /// Runs before the other control folding: subagent events, and the turn boundaries that end a pending delegation.
    func foldSubagents(_ type: String, _ p: JSON) {
        switch type {
        case "message.start":
            // Only a turn the user started: an async delegation reports back in turns of its own
            // (two message.start in a row), and those must not hide the child that just finished.
            if items.last?.kind == .user || !queued.isEmpty { subagents.pruneFinished() }
        case "message.complete":
            // The turn ended without spawning (or after); either way the temporary model is done.
            Task { await restoreDelegation() }
        case "subagent.start":
            subagents.apply(type, p)
            Task { await restoreDelegation() }
        default:
            subagents.apply(type, p)
        }
    }

    public func refreshSubagents() async {
        guard let sid = runtimeId else { return }
        let before = subagents.version
        guard let r = try? await gateway.call("subagent.list", ["session_id": .string(sid)]),
              sid == runtimeId, subagents.version == before else { return }
        subagents.reconcile(r)
    }

    /// The last 16 KB of a live child's transcript; nil once it has none.
    public func subagentTail(_ id: String) async -> String? {
        guard let sid = runtimeId,
              let r = try? await gateway.call("subagent.tail", ["session_id": .string(sid), "subagent_id": .string(id)]),
              r["available"]?.bool == true else { return nil }
        return r["text"]?.string
    }

    /// True when the child accepted the message ("queued" means accepted, not yet read).
    public func steerSubagent(_ id: String, text: String) async throws -> Bool {
        guard let sid = runtimeId else { throw GatewayError.offline }
        let r = try await gateway.call("subagent.steer", ["session_id": .string(sid), "subagent_id": .string(id), "text": .string(text)])
        return r["status"]?.string == "queued"
    }

    /// False when the child had already finished.
    public func stopSubagent(_ id: String) async throws -> Bool {
        guard let sid = runtimeId else { throw GatewayError.offline }
        return try await gateway.call("subagent.interrupt", ["session_id": .string(sid), "subagent_id": .string(id)])["found"]?.bool ?? false
    }

    /// The tiers for the Delegate sheet: Settings overrides first, then models picked from the chat's provider.
    public func delegatePlan(overrides: UserDefaults = .standard) async throws -> DelegatePlan {
        guard let creds = gateway.credentials else { throw GatewayError.offline }
        let profile = self.profile
        var params: [String: JSON] = [:]
        if let sid = runtimeId { params["session_id"] = .string(sid) }
        if let profile { params["profile"] = .string(profile) }
        let request = params
        async let options = gateway.call("model.options", request)
        async let config = DelegationValues.get(creds, profile: profile)
        let opts = try await options
        let chatProvider = provider.nonEmpty ?? opts["provider"]?.string ?? ""
        let chatModel = model.nonEmpty ?? opts["model"]?.string ?? ""
        let fetched = try await config
        let current = pendingDelegation?.previous ?? fetched
        var tiers = ModelTiers.defaults(options: opts, provider: chatProvider, model: chatModel)
        tiers[.standard] = nil
        for tier in DelegateTier.allCases {
            if let o = overrides.string(forKey: TierModel.overrideKey(tier)).flatMap(TierModel.init(stored:)) { tiers[tier] = o }
        }
        return DelegatePlan(tiers: tiers, current: current, chatModel: chatModel, chatProvider: chatProvider)
    }

    /// Points the profile's delegation config at the tier's model, asks the agent to delegate the task,
    /// and puts the config back once the child starts (or the turn ends, fails, or two minutes pass).
    // ponytail: delegation.model is per profile, not per call, so any other delegation in this profile
    // that spawns inside that window (another chat, a cron job) also gets the temporary model. A
    // server-side per-call model argument on delegate_task is the real fix.
    public func delegate(_ task: String, tier: DelegateTier, plan: DelegatePlan) async {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        let next = plan.values(for: tier)
        if next != plan.current {
            guard let creds = gateway.credentials else { return }
            do {
                try await DelegationValues.put(next, creds, profile: profile)
            } catch {
                alert = "Couldn't set the subagent model: \(error.localizedDescription)"
                return
            }
            // A second delegation before the first restored keeps the original values as the baseline.
            let pending = PendingDelegation(previous: pendingDelegation?.previous ?? plan.current, profile: profile)
            pendingDelegation = pending
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                await self?.restoreDelegation(only: pending.token)
            }
        }
        subagents.expect(tier: tier.label)
        await send("Use your delegate_task tool to hand this task to a subagent, then report its result: \(task)")
        if !running { await restoreDelegation() }
    }

    func restoreDelegation(only token: UUID? = nil) async {
        guard let pending = pendingDelegation, token == nil || token == pending.token else { return }
        pendingDelegation = nil
        guard let creds = gateway.credentials else { return }
        do {
            try await DelegationValues.put(pending.previous, creds, profile: pending.profile)
        } catch {
            alert = "Couldn't restore the subagent model (\(pending.previous.model.nonEmpty ?? "inherit")): \(error.localizedDescription)"
        }
    }
}
