import Foundation
import Testing
@testable import HermesKit

struct SubagentsTests {
    static func ev(_ id: String, _ extra: [String: JSON] = [:]) -> JSON {
        let base: [String: JSON] = ["subagent_id": .string(id), "goal": .string("goal \(id)"), "delegation_id": "d1", "parent_id": "root-agent"]
        return .object(base.merging(extra) { _, b in b })
    }

    @Test func eventsFoldIntoRows() {
        var r = SubagentRoster()
        r.expect(tier: "Light")
        r.apply("subagent.spawn_requested", Self.ev("a", ["status": "queued", "task_count": 2]))
        r.apply("subagent.start", Self.ev("a", ["model": "gpt-mini", "status": "running"]))
        r.apply("subagent.tool", Self.ev("a", ["tool_name": "terminal", "tool_preview": "ls  /etc", "tool_count": 1]))
        r.apply("subagent.tool", Self.ev("a", ["tool_name": "terminal", "tool_preview": "ls  /etc"]))
        var a = r.item("a")
        #expect(a?.status == .running && a?.model == "gpt-mini" && a?.taskCount == 2 && a?.toolCount == 1)
        #expect(a?.activity == ["terminal(ls /etc)"])
        #expect(a?.tier == "Light")
        #expect(r.active == 1)

        r.apply("subagent.complete", Self.ev("a", ["status": "weird", "summary": "done", "duration_seconds": 4.5,
                                                    "input_tokens": 1200, "output_tokens": 30]))
        a = r.item("a")
        #expect(a?.status == .failed && a?.summary == "done" && a?.duration == 4.5 && a?.acceptingSteer == false)
        // Terminal rows don't move again.
        r.apply("subagent.progress", Self.ev("a", ["status": "running"]))
        #expect(r.item("a")?.status == .failed)
        // The tier was for one delegation only.
        r.apply("subagent.start", Self.ev("b", ["delegation_id": "d2"]))
        #expect(r.item("b")?.tier == nil)
    }

    @Test func statusesNormalize() {
        #expect(Subagent.Status.parse("timeout", terminalEvent: false) == .failed)
        #expect(Subagent.Status.parse("cancelled", terminalEvent: false) == .interrupted)
        #expect(Subagent.Status.parse("queued", terminalEvent: false) == .queued)
        #expect(Subagent.Status.parse(nil, terminalEvent: false) == .running)
        #expect(Subagent.Status.parse("running", terminalEvent: true) == .failed)
        var r = SubagentRoster()
        r.apply("subagent.complete", Self.ev("t", ["status": "timeout", "duration_seconds": 61]))
        #expect(r.item("t")?.summary == "Timed out after 61s")
    }

    @Test func pruneRetiresFinishedRows() {
        var r = SubagentRoster()
        r.apply("subagent.start", Self.ev("a"))
        r.apply("subagent.start", Self.ev("b"))
        r.apply("subagent.complete", Self.ev("a", ["status": "completed"]))
        r.pruneFinished()
        #expect(r.items.map(\.id) == ["b"])
        // A late event or snapshot can't bring a pruned row back.
        r.apply("subagent.progress", Self.ev("a"))
        r.reconcile(["subagents": [Self.ev("a", ["status": "running"]), Self.ev("b", ["status": "running"])]])
        #expect(r.items.map(\.id) == ["b"])
    }

    @Test func snapshotReconciles() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var r = SubagentRoster()
        r.apply("subagent.start", Self.ev("young"), now: t0)
        r.apply("subagent.start", Self.ev("stale"), now: t0.addingTimeInterval(-60))
        r.apply("subagent.start", Self.ev("done"), now: t0)
        r.apply("subagent.complete", Self.ev("done", ["status": "completed"]))
        let v = r.version
        r.reconcile(["subagents": [
            ["subagent_id": "new", "goal": "fresh", "model": "m", "status": "running", "started_at": 1_800_000_000,
             "tool_count": 3, "last_tool": "read_file", "accepting_steer": true, "depth": 1, "delegation_id": "d9"],
        ]], now: t0)
        // A row the server never listed survives the spawn race, until it is clearly stale.
        #expect(r.items.map(\.id) == ["young", "done", "new"])
        let n = r.item("new")
        #expect(n?.startedAt == t0 && n?.toolCount == 3 && n?.activity == ["read_file"])
        #expect(r.version == v)
        // Re-reading the same snapshot doesn't stack activity.
        r.reconcile(["subagents": [["subagent_id": "new", "last_tool": "read_file"]]], now: t0)
        #expect(r.item("new")?.activity == ["read_file"])
    }

    @Test func listedChildThatVanishesHasEnded() {
        var r = SubagentRoster()
        r.reconcile(["subagents": [Self.ev("ok", ["status": "running"]), Self.ev("bad", ["status": "running", "task_index": 1])]])
        r.reconcile(["subagents": [], "delegations": [["delegation_id": "d1", "task_index": 1, "status": "failed", "error": "boom"]]])
        #expect(r.item("ok")?.status == .completed)
        #expect(r.item("bad")?.status == .failed && r.item("bad")?.summary == "boom")
        #expect(r.active == 0)
    }

    @Test func treeGroupsByDelegationAndNests() {
        var r = SubagentRoster()
        r.apply("subagent.start", Self.ev("a"))
        r.apply("subagent.start", Self.ev("x", ["delegation_id": "d2"]))
        r.apply("subagent.start", Self.ev("a1", ["parent_id": "a", "delegation_id": "d3", "depth": 2]))
        r.apply("subagent.start", Self.ev("b"))
        let tree = r.tree()
        #expect(tree.map(\.delegation) == ["d1", "d2"])
        #expect(tree[0].rows.map(\.item.id) == ["a", "a1", "b"])
        #expect(tree[0].rows.map(\.depth) == [0, 1, 0])
    }

    @Test func tierSuggestions() {
        #expect(DelegateTier.suggest(for: "List the files in /etc whose names start with 'host'") == .light)
        #expect(DelegateTier.suggest(for: "Summarize this README") == .light)
        #expect(DelegateTier.suggest(for: "Refactor the auth module and fix the token refresh") == .heavy)
        #expect(DelegateTier.suggest(for: "Debug why the build fails") == .heavy)
        #expect(DelegateTier.suggest(for: "Write a haiku about cats") == .standard)
        // "fixture" is not "fix", "listen" is not "list".
        #expect(DelegateTier.suggest(for: "tell me about the fixture we listen to") == .standard)
    }

    @Test func pricesParse() {
        #expect(ModelTiers.price("$0.25/Mtok") == 0.25)
        #expect(ModelTiers.price("free") == 0)
        #expect(ModelTiers.price("") == nil)
        #expect(ModelTiers.price(nil) == nil)
    }

    @Test func apiProvidersRankByPrice() {
        let options: JSON = ["providers": [
            ["slug": "other", "models": ["cheap"], "pricing": ["cheap": ["input": "$0.01/Mtok"]]],
            ["slug": "or", "models": ["a", "b", "c"],
             "pricing": ["a": ["input": "$3/Mtok"], "b": ["input": "$0.10/Mtok"], "c": ["input": "$15/Mtok"]]],
        ]]
        let t = ModelTiers.defaults(options: options, provider: "or", model: "a")
        #expect(t[.light] == TierModel(model: "cheap", provider: "other"))
        #expect(t[.heavy] == TierModel(model: "c", provider: "or"))
    }

    @Test func tiersByNameNearestTheChatModel() {
        let options: JSON = ["providers": [["slug": "openai-codex", "pricing": ["gpt-6.1-sol": ["input": ""]],
                                            "models": ["gpt-5-mini", "gpt-6.1-sol", "gpt-6.1-mini", "gpt-6.1-pro", "o9"]]]]
        let t = ModelTiers.defaults(options: options, provider: "openai-codex", model: "gpt-6.1-sol")
        #expect(t[.light]?.model == "gpt-6.1-mini")
        #expect(t[.heavy]?.model == "gpt-6.1-pro")
        let plain: JSON = ["providers": [["slug": "p", "models": ["alpha", "beta"]]]]
        #expect(ModelTiers.defaults(options: plain, provider: "p", model: "alpha").isEmpty)
    }

    @Test func subscriptionsBeatPayPerToken() {
        let openrouter: JSON = ["slug": "openrouter", "models": ["x/tiny-mini", "x/huge-pro"],
                                "pricing": ["x/tiny-mini": ["input": "$0.05/Mtok"], "x/huge-pro": ["input": "$30/Mtok"]]]
        let codex: JSON = ["slug": "openai-codex", "models": ["gpt-6.1-sol", "gpt-6-luna"]]
        let copilot: JSON = ["slug": "copilot", "models": ["claude-haiku-5.5", "claude-opus-4.8-fast", "claude-opus-5.5",
                                                           "gpt-5.4-mini-free-auto", "gpt-5.4-mini", "gpt-6.1-sol"]]
        var t = ModelTiers.defaults(options: ["providers": [openrouter, codex, copilot]], provider: "openai-codex", model: "gpt-6.1-sol")
        // Nearest the chat model, then the shorter name; the newest opus for heavy.
        #expect(t[.light] == TierModel(model: "gpt-5.4-mini", provider: "copilot"))
        #expect(t[.heavy] == TierModel(model: "claude-opus-5.5", provider: "copilot"))

        // Quota windows mark an unknown provider as a subscription, ahead of a later known one.
        let plan: JSON = ["slug": "my-plan", "usage": ["windows": []], "models": ["plan-flash"]]
        t = ModelTiers.defaults(options: ["providers": [openrouter, plan, copilot]], provider: "openrouter", model: "x/a")
        #expect(t[.light] == TierModel(model: "plan-flash", provider: "my-plan"))

        // No subscription has a heavy model, so the pay-per-token side supplies it, by price.
        let flat: JSON = ["slug": "zai", "models": ["glm-5-flash"]]
        t = ModelTiers.defaults(options: ["providers": [openrouter, flat, ["slug": "signed-out", "authenticated": false, "models": ["z-max"]]]],
                                provider: "zai", model: "glm-5")
        #expect(t[.light] == TierModel(model: "glm-5-flash", provider: "zai"))
        #expect(t[.heavy] == TierModel(model: "x/huge-pro", provider: "openrouter"))
        #expect(ModelTiers.isSubscription(["slug": "anthropic", "auth_type": "oauth_external"]))
        #expect(!ModelTiers.isSubscription(["slug": "openrouter"]))
    }

    static let config: JSON = [
        "delegation": ["model": "", "tiers": [
            "light": ["provider": "openai-codex", "model": "gpt-6-luna", "reasoning_effort": "low",
                      "fallback_providers": [["provider": "copilot", "model": "gpt-6-luna"],
                                             ["provider": "openrouter", "model": "openai/gpt-6-luna"]]],
            "standard": [:],
            "heavy": ["provider": "openai-codex", "model": "gpt-6-astra", "reasoning_effort": "high"],
        ]],
        "plugins": ["enabled": ["book-rag", "delegate-tiers"]],
    ]

    @Test func tierRoutesNeedThePlugin() {
        let routes = TierRoute.routes(in: Self.config)
        #expect(routes?[.light] == TierRoute(model: "gpt-6-luna", provider: "openai-codex", reasoningEffort: "low",
                                             fallbacks: [TierModel(model: "gpt-6-luna", provider: "copilot"),
                                                         TierModel(model: "openai/gpt-6-luna", provider: "openrouter")]))
        #expect(routes?[.standard] == TierRoute())
        #expect(routes?[.heavy]?.reasoningEffort == "high")
        // Tiers without the plugin enabled, or the plugin without tiers, mean the config-swap fallback.
        #expect(TierRoute.routes(in: ["delegation": Self.config["delegation"]!, "plugins": ["enabled": ["book-rag"]]]) == nil)
        #expect(TierRoute.routes(in: ["delegation": ["model": ""], "plugins": Self.config["plugins"]!]) == nil)
    }

    @Test func tierChangesKeepFallbacksUnlessTheProviderMoves() {
        let light = TierRoute.routes(in: Self.config)![.light]!
        #expect(light.change(to: TierModel(model: "gpt-6-nova", provider: "openai-codex")) == ["model": "gpt-6-nova", "provider": "openai-codex"])
        #expect(light.change(to: TierModel(model: "claude-haiku-5.5", provider: "copilot")) == [
            "model": "claude-haiku-5.5", "provider": "copilot",
            "fallback_providers": [["provider": "openai-codex", "model": "gpt-6-luna"], ["provider": "openrouter", "model": "openai/gpt-6-luna"]],
        ])
        #expect(light.change(to: TierModel(model: "", provider: "")) == ["model": "", "provider": "", "fallback_providers": []])
    }

    @Test func promptsNameTheTool() {
        #expect(DelegateTier.light.prompt("ls /etc", plugin: true)
            == "Use your delegate_tiered tool with tier \"light\" for this task, then report its result: ls /etc")
        #expect(DelegateTier.heavy.prompt("x", plugin: false).hasPrefix("Use your delegate_task tool"))
    }

    @Test func childrenGetTheirTierFromTheirModel() {
        var r = SubagentRoster()
        r.apply("subagent.start", Self.ev("early", ["model": "gpt-6-astra"]))
        r.label(TierRoute.routes(in: Self.config)!)
        #expect(r.item("early")?.tier == "Heavy")
        r.apply("subagent.start", Self.ev("a", ["delegation_id": "d2", "model": "gpt-6-luna"]))
        r.apply("subagent.start", Self.ev("b", ["delegation_id": "d3", "model": "openai/gpt-6-luna"]))
        r.apply("subagent.start", Self.ev("c", ["delegation_id": "d4", "model": "sol"]))
        #expect(r.item("a")?.tier == "Light" && r.item("b")?.tier == "Light" && r.item("c")?.tier == nil)
        // The tier the app asked for wins over the model's.
        r.expect(tier: "Standard")
        r.apply("subagent.start", Self.ev("d", ["delegation_id": "d5", "model": "gpt-6-luna"]))
        #expect(r.item("d")?.tier == "Standard")
    }

    @Test func planValues() {
        let current = DelegationValues(model: "", provider: "", reasoningEffort: "")
        let plan = DelegatePlan(tiers: [.light: TierRoute(model: "mini", provider: "codex", reasoningEffort: "low"),
                                        .heavy: TierRoute(model: "big", provider: "or")],
                                plugin: false, current: current, chatModel: "sol", chatProvider: "codex")
        #expect(plan.values(for: .light) == DelegationValues(model: "mini", provider: "", reasoningEffort: "low"))
        #expect(plan.values(for: .heavy) == DelegationValues(model: "big", provider: "or", reasoningEffort: ""))
        // Standard without a pick leaves the profile alone.
        #expect(plan.values(for: .standard) == current)
        #expect(plan.route(for: .standard).model == "" && plan.route(for: .light).model == "mini")
        let bare = DelegatePlan(tiers: [:], plugin: false, current: current, chatModel: "sol", chatProvider: "codex")
        #expect(bare.values(for: .light).reasoningEffort == "low" && bare.values(for: .light).model == "")
        // With the plugin an unset tier is the chat's model, whatever delegation.model says.
        let served = DelegatePlan(tiers: [:], plugin: true, current: DelegationValues(model: "old"), chatModel: "sol", chatProvider: "codex")
        #expect(served.route(for: .light) == TierRoute())
    }

    @Test func configRequestIsScopedAndAuthorized() throws {
        let c = Credentials(baseURL: URL(string: "https://h.example:8447")!, username: "u", accessToken: "tok", refreshToken: "r", provider: "basic")
        let r = DelegationValues.request(c, profile: "coder", method: "PUT")
        #expect(r.url?.absoluteString == "https://h.example:8447/api/config?profile=coder")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(DelegationValues.request(c, profile: "default", method: "GET").url?.query == nil)
        let body = JSON.object(["config": ["delegation": DelegationValues(model: "m", reasoningEffort: "low").json]])
        #expect(body["config"]?["delegation"]?["reasoning_effort"]?.string == "low")
    }
}

@MainActor
struct SubagentStoreTests {
    @Test func chatFoldsOnlyItsSessionAndPrunesAtTurns() {
        let gateway = Gateway(credentials: nil)
        let store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": []])
        gateway.dispatch(GatewayEvent(type: "subagent.start", sessionId: "rt1", payload: SubagentsTests.ev("a")))
        gateway.dispatch(GatewayEvent(type: "subagent.start", sessionId: "other", payload: SubagentsTests.ev("z")))
        #expect(store.subagents.items.map(\.id) == ["a"])
        gateway.dispatch(GatewayEvent(type: "subagent.complete", sessionId: "rt1", payload: SubagentsTests.ev("a", ["status": "completed"])))
        // An async delegation's report turns start without a user message and keep the finished row.
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt1", payload: nil))
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt1", payload: nil))
        #expect(store.subagents.items.count == 1)
        store.items.append(ChatItem(id: "u2", kind: .user, text: "next"))
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt1", payload: nil))
        #expect(store.subagents.isEmpty)
    }
}
