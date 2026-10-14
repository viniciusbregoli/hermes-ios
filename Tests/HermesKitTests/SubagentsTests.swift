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
        var r = SubagentRoster()
        r.apply("subagent.start", Self.ev("gone"))
        r.apply("subagent.start", Self.ev("done"))
        r.apply("subagent.complete", Self.ev("done", ["status": "completed"]))
        let v = r.version
        r.reconcile(["subagents": [
            ["subagent_id": "new", "goal": "fresh", "model": "m", "status": "running", "started_at": 1_800_000_000,
             "tool_count": 3, "last_tool": "read_file", "accepting_steer": true, "depth": 1, "delegation_id": "d9"],
        ]])
        #expect(r.items.map(\.id) == ["done", "new"])
        let n = r.item("new")
        #expect(n?.startedAt == Date(timeIntervalSince1970: 1_800_000_000) && n?.toolCount == 3 && n?.activity == ["read_file"])
        #expect(r.version == v)
        // Re-reading the same snapshot doesn't stack activity.
        r.reconcile(["subagents": [["subagent_id": "new", "last_tool": "read_file"]]])
        #expect(r.item("new")?.activity == ["read_file"])
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

    @Test func tiersByPrice() {
        let options: JSON = ["providers": [
            ["slug": "other", "models": ["cheap"], "pricing": ["cheap": ["input": "$0.01/Mtok"]]],
            ["slug": "or", "models": ["a", "b", "c"],
             "pricing": ["a": ["input": "$3/Mtok"], "b": ["input": "$0.10/Mtok"], "c": ["input": "$15/Mtok"]]],
        ]]
        let t = ModelTiers.defaults(options: options, provider: "or", model: "a")
        #expect(t[.light] == TierModel(model: "b", provider: "or"))
        #expect(t[.heavy] == TierModel(model: "c", provider: "or"))
    }

    @Test func tiersByNameNearestTheChatModel() {
        let options: JSON = ["providers": [["slug": "openai-codex", "pricing": ["gpt-6.1-sol": ["input": ""]],
                                            "models": ["gpt-5-mini", "gpt-6.1-sol", "gpt-6.1-mini", "gpt-6.1-pro", "o9"]]]]
        let t = ModelTiers.defaults(options: options, provider: "openai-codex", model: "gpt-6.1-sol")
        #expect(t[.light]?.model == "gpt-6.1-mini")
        #expect(t[.heavy]?.model == "gpt-6.1-pro")
        #expect(ModelTiers.defaults(options: options, provider: "missing", model: "x").isEmpty)
        let plain: JSON = ["providers": [["slug": "p", "models": ["alpha", "beta"]]]]
        #expect(ModelTiers.defaults(options: plain, provider: "p", model: "alpha").isEmpty)
    }

    @Test func storedOverrides() {
        #expect(TierModel(stored: "openrouter|google/gemini-flash") == TierModel(model: "google/gemini-flash", provider: "openrouter"))
        #expect(TierModel(stored: "|") == .inherit)
        #expect(TierModel(stored: "") == nil)
        #expect(TierModel(model: "m", provider: "p").stored == "p|m")
    }

    @Test func planValues() {
        let current = DelegationValues(model: "", provider: "", reasoningEffort: "")
        let plan = DelegatePlan(tiers: [.light: TierModel(model: "mini", provider: "codex"), .heavy: TierModel(model: "big", provider: "or")],
                                current: current, chatModel: "sol", chatProvider: "codex")
        #expect(plan.values(for: .light) == DelegationValues(model: "mini", provider: "", reasoningEffort: "low"))
        #expect(plan.values(for: .heavy) == DelegationValues(model: "big", provider: "or", reasoningEffort: ""))
        // Standard without an override leaves the profile alone.
        #expect(plan.values(for: .standard) == current)
        #expect(plan.model(for: .standard) == "sol" && plan.model(for: .light) == "mini")
        let bare = DelegatePlan(tiers: [:], current: current, chatModel: "sol", chatProvider: "codex")
        #expect(bare.values(for: .light).reasoningEffort == "low" && bare.values(for: .light).model == "")
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
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt1", payload: nil))
        #expect(store.subagents.isEmpty)
    }
}
