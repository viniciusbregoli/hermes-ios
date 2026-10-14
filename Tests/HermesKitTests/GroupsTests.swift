import Foundation
import Testing
@testable import HermesKit

private let hermes = RoomMember(memberId: "default", profile: "default", handle: "hermes", displayName: "Hermes")
private let librarian = RoomMember(memberId: "librarian", profile: "librarian", handle: "librarian")
private let homelab = RoomMember(memberId: "homelab", profile: "homelab", handle: "homelab")
private let room = Room(id: "m-test-1", name: "Test", members: [hermes, librarian, homelab])

private func user(_ seq: Int, _ text: String) -> RoomEvent {
    RoomEvent(seq: seq, kind: "message.user", eventId: "user:\(seq)", actor: ["kind": "user", "id": "desktop"],
              payload: ["text": .string(text), "thread_id": "main"])
}

private func reply(_ seq: Int, _ member: RoomMember, _ text: String, round: Int = 0, discussion: Int) -> RoomEvent {
    RoomEvent(seq: seq, kind: "message.member", eventId: "dmessage:\(seq)",
              actor: ["kind": "member", "id": .string(member.memberId), "profile": .string(member.profile)],
              payload: ["text": .string(text), "member_id": .string(member.memberId), "round_index": .number(Double(round)),
                        "discussion_event_id": .string("user:\(discussion)"), "task_id": .string("dtask:\(seq)"), "thread_id": "main"])
}

private func terminal(_ seq: Int, _ kind: String, _ member: RoomMember, round: Int = 0, discussion: Int,
                      extra: [String: JSON] = [:]) -> RoomEvent {
    var payload: [String: JSON] = ["member_id": .string(member.memberId), "round_index": .number(Double(round)),
                                   "discussion_event_id": .string("user:\(discussion)"), "task_id": .string("dtask:t\(seq)"),
                                   "thread_id": "main"]
    payload.merge(extra) { _, b in b }
    return RoomEvent(seq: seq, kind: kind, actor: ["kind": "gateway", "id": "gw"], payload: .object(payload))
}

private func settled(_ seq: Int, _ member: RoomMember, round: Int = 0, discussion: Int, passed: Bool = false, seen: Int = 0) -> RoomEvent {
    terminal(seq, "turn.settled", member, round: round, discussion: discussion,
             extra: ["passed": .bool(passed), "seen_through_seq": .number(Double(seen))])
}

struct RoomParsingTests {
    @Test func parsesListRowsAndLogEvents() {
        let r = Room(["room_id": "r1", "name": "Ops", "latest_seq": 7, "updated_at": 100,
                      "members": [["member_id": "default", "profile": "default", "handle": "hermes", "display_name": "Hermes"]]])
        #expect(r?.name == "Ops" && r?.latestSeq == 7 && r?.members.first?.handle == "hermes")
        let e = RoomEvent(["seq": 3, "event_id": "user:abc", "kind": "message.user", "created_at": 5,
                           "actor": ["kind": "user"], "payload": ["text": "hi", "thread_id": "main"]])
        #expect(e?.eventId == "user:abc" && e?.text == "hi" && e?.at == Date(timeIntervalSince1970: 5))
    }

    @Test func readsDriverStatusActions() {
        let status = RoomStatus(["running": true, "working": true, "blocked": false, "pending_actions": [
            ["kind": "retry", "task_id": "dtask:1"],
            ["kind": "approval", "member_id": "homelab", "task_id": "dtask:2", "execution_generation": 3, "request_id": "req",
             "approval": ["command": "rm -rf /tmp/x", "description": "delete", "choices": ["once", "deny"]]],
            ["kind": "something-new", "task_id": "x"],
        ]])
        #expect(status.working && status.running)
        #expect(status.retryable == ["dtask:1"])
        #expect(status.approvals.map(\.memberId) == ["homelab"])
        #expect(status.approvals.first?.executionGeneration == 3)
        #expect(status.approvals.first?.approval["command"]?.string == "rm -rf /tmp/x")
    }
}

struct RoomTimelineTests {
    @Test func foldsMessagesPassesAndFailures() {
        let events = [
            user(1, "hi all"),
            reply(2, hermes, "hello", discussion: 1), settled(3, hermes, discussion: 1),
            reply(4, hermes, "and more", discussion: 1),
            settled(5, librarian, discussion: 1, passed: true),
            terminal(6, "turn.failed", homelab, discussion: 1, extra: ["error": "timeout"]),
            RoomEvent(seq: 7, kind: "room.activity", payload: ["status": "settled", "discussion_event_id": "user:1"]),
            RoomEvent(seq: 8, kind: "room.renamed", payload: ["name": "Ops"]),
        ]
        let rows = RoomTimeline.rows(events, room: room, labels: ["librarian": "Librarian"])
        #expect(rows.map(\.kind) == [.user, .member, .member, .passed, .failed, .notice])
        #expect(rows[1].name == "Hermes" && rows[1].header && !rows[2].header)
        #expect(rows[3].text == "Librarian passed")
        #expect(rows[4].text == "homelab couldn't reply: timeout" && rows[4].taskId == "dtask:t6")
        #expect(rows[5].text == "Renamed to \u{201C}Ops\u{201D}")
    }

    @Test func notesStopsSupersededTurnsAndLimits() {
        let rows = RoomTimeline.rows([
            terminal(1, "turn.cancelled", librarian, discussion: 0, extra: ["reason": "superseded_by_newer_user_event"]),
            RoomEvent(seq: 2, kind: "room.stop_requested", payload: ["cancel_id": "x"]),
            RoomEvent(seq: 3, kind: "room.activity", payload: ["status": "bounded"]),
        ], room: room)
        #expect(rows.map(\.kind) == [.cancelled, .notice, .notice])
        #expect(rows[0].text == "librarian stopped for your newer message")
        #expect(rows[1].text == "Stopped")
    }
}

struct RoomDiscussionTests {
    @Test func addressesMentionsOrEveryone() {
        #expect(RoomDiscussion.addressed("@hermes say hi", members: room.members) == [hermes])
        #expect(RoomDiscussion.addressed("hello", members: room.members) == room.members)
        #expect(RoomDiscussion.addressed("@everyone and @hermes", members: room.members) == room.members)
        #expect(RoomDiscussion.addressed("@nobody", members: room.members) == room.members)
        #expect(RoomDiscussion.addressed("hello", members: room.members, everyoneByDefault: false).isEmpty)
    }

    @Test func openDiscussionEndsOnSettleOrStop() {
        #expect(RoomDiscussion.pending([user(1, "hi")])?.seq == 1)
        let settledRoom = [user(1, "hi"), RoomEvent(seq: 2, kind: "room.activity", payload: ["status": "settled", "discussion_event_id": "user:1"])]
        #expect(RoomDiscussion.pending(settledRoom) == nil)
        #expect(RoomDiscussion.pending([user(1, "hi"), RoomEvent(seq: 2, kind: "room.stop_requested")]) == nil)
        #expect(RoomDiscussion.pending([user(1, "hi"), RoomEvent(seq: 2, kind: "room.stop_requested"), user(3, "again")])?.seq == 3)
    }

    @Test func nextSpeakerFollowsRoundOrder() {
        var events = [user(1, "hello")]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == hermes)
        events += [reply(2, hermes, "hi", discussion: 1), settled(3, hermes, discussion: 1, seen: 1)]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == librarian)
        events += [reply(4, librarian, "@homelab what do you think?", discussion: 1), settled(5, librarian, discussion: 1, seen: 2)]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == homelab)
        // Homelab already saw the citation in its own first-round turn, so there is no second round.
        events += [settled(6, homelab, discussion: 1, passed: true, seen: 4)]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == nil)
    }

    @Test func citedMemberGetsALaterRound() {
        var events = [user(1, "@hermes hi"), reply(2, hermes, "@librarian thoughts?", discussion: 1), settled(3, hermes, discussion: 1, seen: 1)]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == librarian)
        events += [settled(4, librarian, round: 1, discussion: 1, passed: true, seen: 2)]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == nil)
    }

    @Test func mentionLimitsTheFirstRound() {
        let events = [user(1, "@librarian one word")]
        #expect(RoomDiscussion.nextSpeaker(events, members: room.members) == librarian)
        #expect(RoomDiscussion.nextSpeaker(events + [settled(2, librarian, discussion: 1, passed: true)], members: room.members) == nil)
    }
}

struct RoomPollingTests {
    @Test func pollsFastWhileWorkingOrJustAfterSending() {
        let now = Date()
        #expect(RoomPolling.interval(working: true, sentAt: nil, now: now) == .seconds(1))
        #expect(RoomPolling.interval(working: false, sentAt: now.addingTimeInterval(-2), now: now) == .seconds(1))
        #expect(RoomPolling.interval(working: false, sentAt: now.addingTimeInterval(-60), now: now) == .seconds(10))
        #expect(RoomPolling.interval(working: false, sentAt: nil, now: now) == .seconds(10))
    }
}

struct RoomIdsTests {
    @Test func roomIdIsValidAndSuffixed() {
        let id = RoomIds.room(name: "Hermes Mobile: Test!", suffix: "ab12cd34")
        #expect(id == "m-hermes-mobile-test-ab12cd34")
        #expect(id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil)
        #expect(RoomIds.room(name: "???", suffix: "x1") == "m-x1")
        #expect(RoomIds.room(name: String(repeating: "a", count: 300)).count <= 128)
    }

    @Test func membersUseRosterHandlesAndStayUnique() {
        let bots = [Bot(name: "default"), Bot(name: "librarian", title: "Librarian"), Bot(name: "all"), Bot(name: "hermes")]
        let members = RoomIds.members(for: bots)
        #expect(members.map(\.handle) == ["hermes", "librarian", "all-2", "hermes-2"])
        #expect(members.map(\.memberId) == ["default", "librarian", "all", "hermes"])
        #expect(members[0].displayName == "Hermes" && members[1].displayName == "Librarian")
        #expect(members[1].json == ["member_id": "librarian", "profile": "librarian", "handle": "librarian", "display_name": "Librarian"])
    }
}

struct RoomMarkTests {
    @Test func previewAndUnreadFollowReplies() {
        var mark = RoomMark()
        mark.note([user(1, "hi"), reply(2, hermes, "hello", discussion: 1), settled(3, hermes, discussion: 1)], room: room)
        #expect(mark.cursor == 3 && mark.replySeq == 2 && mark.speaker == "default" && mark.preview == "hello")
        #expect(mark.unread)
        mark.read = mark.cursor
        mark.note([user(4, "thanks")], room: room)
        #expect(!mark.unread && mark.speaker == nil && mark.preview == "thanks")
    }

    @Test func marksRoundTripThroughDefaults() {
        let defaults = UserDefaults(suiteName: "groups-test-\(UUID().uuidString)")!
        var mark = RoomMark()
        mark.read = 4
        mark.preview = "hey"
        RoomMarks.save(["r1": mark], to: defaults)
        #expect(RoomMarks.load(from: defaults) == ["r1": mark])
    }
}

@MainActor
struct RoomStoreTests {
    @Test func appliesLogPagesOnceAndTracksWork() {
        let store = RoomStore(gateway: Gateway(credentials: nil), room: room)
        let page: JSON = ["cursor": 2, "has_more": false, "events": [
            ["seq": 1, "event_id": "user:1", "kind": "message.user", "payload": ["text": "hi", "thread_id": "main"]],
            ["seq": 2, "event_id": "dmessage:2", "kind": "message.member", "actor": ["kind": "member", "id": "default"],
             "payload": ["text": "hello", "member_id": "default", "round_index": 0, "discussion_event_id": "user:1"]],
        ]]
        store.apply(page: page)
        store.apply(page: page)
        #expect(store.events.map(\.seq) == [1, 2] && store.cursor == 2)
        // No driver status yet: an open discussion alone doesn't count as work.
        #expect(!store.working)
    }
}
