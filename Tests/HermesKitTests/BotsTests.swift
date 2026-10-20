import Foundation
import Testing
@testable import HermesKit

struct AgentMessageTests {
    @Test func parsesDeliveryWithHandle() {
        let m = AgentMessage.parse("Message from 🤖 Bills (@bills): rent is due\nsecond line")
        #expect(m == AgentMessage(sender: "Bills", handle: "bills", body: "rent is due\nsecond line"))
    }

    @Test func parsesRelayedHandleAndPlainSender() {
        #expect(AgentMessage.parse("Message from Inbox (@inbox@laptop): hi")?.handle == "inbox")
        let plain = AgentMessage.parse("Message from Research Buddy: done")
        #expect(plain?.sender == "Research Buddy" && plain?.handle == nil && plain?.body == "done")
    }

    @Test func parsesLegacyForm() {
        #expect(AgentMessage.parse("[Message from agent 'homelab'] disk is full") ==
                AgentMessage(sender: "homelab", handle: nil, body: "disk is full"))
    }

    @Test func ignoresOrdinaryText() {
        #expect(AgentMessage.parse("hello") == nil)
        #expect(AgentMessage.parse("A Message from Bills: no") == nil)
    }
}

struct RosterTests {
    static let result: JSON = ["profiles": [
        ["name": "research", "ui_meta": ["hermes-bots": ["title": "Research", "pinned": true]],
         "worker_session": ["last_active": 1000], "last_session": ["preview": "old", "last_active": 50]],
        ["name": "bills", "has_avatar": true, "ui_meta": ["hermes-bots": ["title": "Bills", "pinned": true]],
         "canonical_session": ["id": "s1", "resolved_id": "s2", "preview": "rent", "last_active": 200]],
        ["name": "scratch", "display_name": "Scratchpad"],
        ["name": "ghost", "ui_meta": ["hermes-bots": ["hidden": true]]],
        ["name": "default", "canonical_session": ["id": "d1", "last_active": 10]],
    ]]

    @Test func sortsHermesFirstThenPinnedByActivity() {
        let bots = Bot.roster(Self.result)
        #expect(bots.map(\.name) == ["default", "bills", "research", "scratch"])
        #expect(bots.map(\.label) == ["Hermes", "Bills", "Research", "Scratchpad"])
        #expect(bots[0].handle == "hermes" && bots[1].handle == "bills")
    }

    @Test func readsChatAndActivity() {
        let bots = Bot.roster(Self.result)
        #expect(bots[1].canonicalId == "s2" && bots[1].preview == "rent" && bots[1].hasAvatar)
        #expect(bots[2].canonicalId == nil && bots[2].preview == "old")
        #expect(bots[2].working(at: Date(timeIntervalSince1970: 1100)))
        #expect(!bots[2].working(at: Date(timeIntervalSince1970: 1200)))
    }

    @Test func cyclesThroughTheRosterBothWays() {
        let bots = Bot.roster(Self.result)
        #expect(Bot.cycle(bots, from: "default", by: 1) == "bills")
        #expect(Bot.cycle(bots, from: "scratch", by: 1) == "default")
        #expect(Bot.cycle(bots, from: "default", by: -1) == "scratch")
        // A profile that left the roster steps from the default one.
        #expect(Bot.cycle(bots, from: "gone", by: 1) == "bills")
        #expect(Bot.cycle([], from: "default", by: 1) == nil)
    }
}

@MainActor
struct MentionNoteTests {
    let roster = [Bot(name: "default"), Bot(name: "homelab", title: "Homelab"),
                  Bot(name: "research", title: "Research Buddy"), Bot(name: "bills", title: "Bills")]

    @Test func appendsDesktopNoteForRosterBots() {
        let note = BotStore.mentionNote(for: "ask @homelab and @hermes, cc @research-buddy", roster: roster, excluding: "bills")
        #expect(note == "\n\n[@mentions resolved from the Bot Mode roster \u{2014} the user is referring to: "
            + "@homelab = agent profile \"homelab\" (\"Homelab\"); @hermes = agent profile \"default\"; "
            + "@research = agent profile \"research\" (\"Research Buddy\"). If they want one of these agents contacted, "
            + "compose your own message and send it with your message_agent tool (agents on other connected machines are "
            + "reachable too \u{2014} the Desktop relays it); never forward the user\u{2019}s text verbatim. If this session "
            + "has no message_agent tool, agent messaging is unavailable here \u{2014} say so.]")
    }

    @Test func skipsActiveBotUnknownTagsEmailsAndCode() {
        #expect(BotStore.mentionNote(for: "@bills mail me@homelab.io, @nobody `@homelab`", roster: roster, excluding: "bills") == "")
    }
}
