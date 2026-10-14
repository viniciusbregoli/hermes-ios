import Foundation
import Testing
@testable import HermesKit

@MainActor
struct GoalsTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": []])
    }

    func emit(_ type: String, _ payload: JSON = nil) {
        gateway.dispatch(GatewayEvent(type: type, sessionId: "rt1", payload: payload))
    }

    static func snapshot(goal: JSON = nil, loop: JSON = nil, heartbeat: JSON = nil, revision: String = "r1") -> JSON {
        ["goal": goal, "loop": loop, "heartbeat": heartbeat, "revision": .string(revision), "updated_at": 1_700_000_000]
    }

    static let goal: JSON = [
        "title": "Ship the release", "status": "active", "turns_used": 2, "max_turns": 20,
        "contract": ["outcome": "", "verification": "", "constraints": "", "boundaries": "", "stop_when": ""],
        "subgoals": ["tests pass", "notes written"], "gates": [], "last_verdict": "continue", "last_reason": "two steps left",
    ]

    @Test func parsesEverySection() throws {
        let c = try #require(SessionControl(Self.snapshot(
            goal: Self.goal,
            loop: ["prompt": "check CI", "status": "paused", "mode": "interval", "interval_seconds": 300, "current_delay": 300,
                   "times": 0, "until": "", "max_ticks": 5, "ticks_fired": 2, "created_at": 1, "last_fired_at": 2,
                   "next_due_at": 1_700_000_300, "awaiting_response": false, "deferred_by_goal": true, "paused_reason": "user"],
            heartbeat: ["prompt": "ping", "status": "active", "interval_seconds": 3600, "created_at": 1, "last_fired_at": 0, "fire_count": 1])))
        #expect(c.goal?.title == "Ship the release" && c.goal?.subgoals == ["tests pass", "notes written"])
        #expect(c.goal?.state == "Active" && c.goal?.turns == "turn 2 of 20" && c.goal?.lastReason == "two steps left")
        #expect(c.loop?.status == .paused && c.loop?.maxTicks == 5 && c.loop?.deferredByGoal == true)
        #expect(c.loop?.nextDueAt == Date(timeIntervalSince1970: 1_700_000_300))
        #expect(c.heartbeat?.fireCount == 1 && c.heartbeat?.status == .active)
        #expect(SessionControl.interval(300) == "every 5m")
        #expect(SessionControl.interval(0) == "")
    }

    @Test func goalStateLabels() throws {
        var g = Self.goal.object ?? [:]
        g["status"] = "done"
        g["turns_used"] = 3
        #expect(SessionControl(Self.snapshot(goal: .object(g)))?.goal?.turns == "3 turns")
        g["status"] = "active"
        g["wait_barrier"] = ["type": "until", "until_at": 1, "reason": ""]
        #expect(SessionControl(Self.snapshot(goal: .object(g)))?.goal?.state == "Waiting")
        g["last_verdict"] = "blocked"
        #expect(SessionControl(Self.snapshot(goal: .object(g)))?.goal?.state == "Blocked")
        g["max_turns"] = 0
        g["turns_used"] = 0
        #expect(SessionControl(Self.snapshot(goal: .object(g)))?.goal?.turns == "")
    }

    @Test func dropsMalformedParts() {
        let c = SessionControl(Self.snapshot(goal: ["title": "x", "status": "cleared"], heartbeat: ["status": "active"]))
        #expect(c?.goal == nil && c?.heartbeat == nil && c?.isEmpty == true)
        #expect(SessionControl(nil) == nil)
        #expect(SessionControl("text") == nil)
    }

    @Test func updatesFoldAndEmptySnapshotsClear() {
        emit("session.control.update", ["control": Self.snapshot(goal: Self.goal)])
        #expect(store.control?.goal?.title == "Ship the release")
        var paused = Self.goal.object ?? [:]
        paused["status"] = "paused"
        emit("session.control.update", ["control": Self.snapshot(goal: .object(paused), revision: "r2")])
        #expect(store.control?.goal?.status == .paused)
        emit("session.control.update", ["control": Self.snapshot(revision: "")])
        #expect(store.control == nil)
        // Another chat's update is not ours.
        gateway.dispatch(GatewayEvent(type: "session.control.update", sessionId: "other", payload: ["control": Self.snapshot(goal: Self.goal)]))
        #expect(store.control == nil)
    }

    @Test func staleReadsDontRollBack() {
        let seen = store.controlVersion
        emit("session.control.update", ["control": Self.snapshot(goal: Self.goal, revision: "new")])
        // A read that started before the update answers with what was there before it.
        store.applyControlRead(Self.snapshot(revision: ""), seen: seen, session: "rt1")
        #expect(store.control?.goal != nil)
        // A read for a chat we already left is dropped too.
        store.applyControlRead(Self.snapshot(revision: ""), seen: store.controlVersion, session: "gone")
        #expect(store.control?.goal != nil)
        store.applyControlRead(Self.snapshot(revision: ""), seen: store.controlVersion, session: "rt1")
        #expect(store.control == nil)
    }

    @Test func resetClearsControl() {
        emit("session.control.update", ["control": Self.snapshot(goal: Self.goal)])
        store.resetControls()
        #expect(store.control == nil)
    }
}
