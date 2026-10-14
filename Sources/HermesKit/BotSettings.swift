import Foundation

/// What the Bot settings screen edits: the `ui_meta["hermes-bots"]` look plus the `profiles.describe` snapshot.
public struct BotDraft: Equatable, Sendable {
    public var title = ""
    public var pinned = false
    public var hidden = false
    public var description = ""
    public var soul = ""
    public var provider = ""
    public var model = ""
    public var disabledSkills: Set<String> = []
    public var enabledToolsets: Set<String> = []
    public var enabledMcp: Set<String> = []

    public init() {}

    public init(bot: Bot, describe d: JSON) {
        title = bot.title
        pinned = bot.pinned
        hidden = bot.hidden
        description = d["description"]?.string ?? ""
        soul = d["soul"]?.string ?? ""
        provider = d["model"]?["provider"]?.string ?? ""
        model = d["model"]?["default"]?.string ?? ""
        disabledSkills = Set(Capability.list(d["skills"]).filter { !$0.enabled }.map(\.name))
        enabledToolsets = Set(Capability.list(d["toolsets"]).filter(\.enabled).map(\.name))
        enabledMcp = Set(Capability.list(d["mcp_servers"]).filter(\.enabled).map(\.name))
    }

    func lookChanged(_ other: BotDraft) -> Bool {
        other.title != title || other.pinned != pinned || other.hidden != hidden
    }
}

/// A skill, toolset or MCP server row from `profiles.describe`.
public struct Capability: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let label: String
    public let detail: String
    public let enabled: Bool

    public static func list(_ rows: JSON?) -> [Capability] {
        (rows?.array ?? []).compactMap { r in
            guard let name = r["name"]?.string else { return nil }
            return Capability(name: name, label: r["label"]?.string?.nonEmpty ?? name,
                              detail: r["description"]?.string ?? r["transport"]?.string ?? "",
                              enabled: r["enabled"]?.bool ?? true)
        }
    }
}

public enum BotSettings {
    /// The `profiles.configure` sections that changed, except `ui_meta` (written on its own, see `metaParams`).
    /// Empty when nothing but the look changed.
    public static func configureParams(from old: BotDraft, to new: BotDraft, toolsets: [Capability]) -> [String: JSON] {
        var p: [String: JSON] = [:]
        if new.description != old.description { p["description"] = .string(new.description) }
        if new.soul != old.soul { p["soul"] = .string(new.soul) }
        // The server pins a model only with both halves.
        if (new.model != old.model || new.provider != old.provider), !new.model.isEmpty, !new.provider.isEmpty {
            p["model"] = .string(new.model)
            p["provider"] = .string(new.provider)
        }
        if new.disabledSkills != old.disabledSkills { p["disabled_skills"] = .array(new.disabledSkills.sorted().map(JSON.string)) }
        if new.enabledToolsets != old.enabledToolsets {
            // Like the desktop: everything (or nothing) on clears the pin so the platform default applies again.
            let all = Set(toolsets.map(\.name))
            let pin = new.enabledToolsets == all || new.enabledToolsets.isEmpty ? [] : new.enabledToolsets.sorted()
            p["enabled_toolsets"] = .array(pin.map(JSON.string))
        }
        if new.enabledMcp != old.enabledMcp { p["enabled_mcp_servers"] = .array(new.enabledMcp.sorted().map(JSON.string)) }
        return p
    }

    /// A compare-and-swap write of the bot's `hermes-bots` look. The server replaces the whole object,
    /// so it starts from the server's copy; an empty title removes the key.
    public static func metaParams(_ draft: BotDraft, server meta: JSON?, revision: Int?) -> [String: JSON] {
        var object = meta?.object ?? [:]
        object["chat"] = nil
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        object["title"] = title.isEmpty ? nil : .string(title)
        object["pinned"] = .bool(draft.pinned)
        object["hidden"] = .bool(draft.hidden)
        var p: [String: JSON] = ["ui_meta": ["hermes-bots": .object(object)]]
        if let revision { p["ui_meta_expected_revisions"] = ["hermes-bots": .number(Double(revision))] }
        return p
    }

    /// The sections `applied` reports as not written; `ui_meta` conflicts are handled by the caller.
    public static func failures(_ result: JSON) -> [String] {
        (result["applied"]?.object ?? [:]).compactMap { key, value in value == .bool(false) ? key : nil }.sorted()
    }

    /// Signed-in providers with models, subscriptions (ChatGPT, Copilot, coding plans) ahead of pay-per-token ones.
    public static func modelChoices(_ options: JSON) -> [ModelProvider] {
        let rows = (options["providers"]?.array ?? [])
            .filter { $0["authenticated"]?.bool != false && !($0["models"]?.array ?? []).isEmpty }
        let ordered = rows.filter(ModelTiers.isSubscription) + rows.filter { !ModelTiers.isSubscription($0) }
        return ordered.compactMap { p in
            guard let slug = p["slug"]?.string else { return nil }
            let models = (p["models"]?.array ?? []).compactMap { $0.string ?? $0["id"]?.string }
            return ModelProvider(slug: slug, name: p["name"]?.string ?? slug, models: models)
        }
    }

    /// A square PNG/JPEG data URL is what `profiles.set_asset` wants; this wraps the encoded bytes.
    public static func dataURL(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

/// Saves a bot's settings: the look with compare-and-swap, then the other sections in one call.
@MainActor
public struct BotSettingsSaver {
    public let gateway: Gateway
    public let name: String

    public init(gateway: Gateway, name: String) {
        self.gateway = gateway
        self.name = name
    }

    public func describe() async throws -> JSON {
        try await gateway.call("profiles.describe", ["name": .string(name)])
    }

    public func modelOptions() async throws -> JSON {
        try await gateway.call("model.options", ["profile": .string(name)])
    }

    /// Returns the server's confirmation text when the new model needs the user's OK; nothing for the model
    /// was written then, and `confirmModel` finishes the job.
    public func save(from old: BotDraft, to new: BotDraft, toolsets: [Capability]) async throws -> String? {
        if old.lookChanged(new) { try await saveMeta(new) }
        let params = BotSettings.configureParams(from: old, to: new, toolsets: toolsets)
        guard !params.isEmpty else { return nil }
        let r = try await gateway.call("profiles.configure", params.merging(["name": .string(name)]) { a, _ in a })
        let failed = BotSettings.failures(r)
        if !failed.isEmpty { throw GatewayError.rpc(0, "Couldn't save \(failed.joined(separator: ", ")).") }
        if r["confirm_required"]?.bool == true { return r["confirm_message"]?.string ?? "This model needs confirmation." }
        return nil
    }

    public func confirmModel(_ model: String, provider: String) async throws {
        let r = try await gateway.call("profiles.configure", ["name": .string(name), "model": .string(model),
                                                              "provider": .string(provider), "confirm_expensive_model": true])
        if r["confirm_required"]?.bool == true || r["applied"]?["model"]?.bool != true {
            throw GatewayError.rpc(0, "The model wasn't changed.")
        }
    }

    public func setAvatar(_ dataURL: String?) async throws {
        var p: [String: JSON] = ["name": .string(name), "asset": "avatar"]
        if let dataURL { p["data"] = .string(dataURL) } else { p["clear"] = true }
        _ = try await gateway.call("profiles.set_asset", p)
    }

    /// The bot's roster row read fresh, hidden or not (the roster drops hidden bots).
    public func bot() async throws -> Bot {
        let list = try await gateway.call("profiles.list", ["include_sessions": false])
        guard let bot = list["profiles"]?.array?.lazy.compactMap(Bot.init).first(where: { $0.name == name }) else {
            throw GatewayError.rpc(0, "Bot not found.")
        }
        return bot
    }

    /// Re-reads the server's copy before each try, so another client's edit to keys we don't touch survives.
    private func saveMeta(_ draft: BotDraft) async throws {
        for _ in 0..<3 {
            let bot = try await bot()
            let params = BotSettings.metaParams(draft, server: bot.meta, revision: bot.metaRevision)
            let r = try await gateway.call("profiles.configure", params.merging(["name": .string(name)]) { a, _ in a })
            if r["applied"]?["ui_meta"]?.bool == true { return }
            if r["applied"]?["ui_meta_conflicts"] == nil { break }
        }
        throw GatewayError.rpc(0, "Couldn't save the title and pins.")
    }
}
