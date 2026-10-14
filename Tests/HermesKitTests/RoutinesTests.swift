import Foundation
import Testing
@testable import HermesKit

struct ScheduleTests {
    @Test func describesCommonCronExpressions() {
        #expect(Schedule.describe("0 8 * * *") == "Every day at 08:00")
        #expect(Schedule.describe("30 18 * * *") == "Every day at 18:30")
        #expect(Schedule.describe("0 9 * * 1-5") == "Weekdays at 09:00")
        #expect(Schedule.describe("0 10 * * 0,6") == "Weekends at 10:00")
        #expect(Schedule.describe("0 9 * * 1") == "Mondays at 09:00")
        #expect(Schedule.describe("0 9 * * mon,wed,fri") == "Mon, Wed, Fri at 09:00")
        #expect(Schedule.describe("0 9 1 * *") == "Monthly on day 1 at 09:00")
        #expect(Schedule.describe("0 * * * *") == "Every hour")
        #expect(Schedule.describe("15 * * * *") == "Every hour at :15")
        #expect(Schedule.describe("*/15 * * * *") == "Every 15 minutes")
        #expect(Schedule.describe("0 */2 * * *") == "Every 2 hours")
        #expect(Schedule.describe("* * * * *") == "Every minute")
    }

    @Test func leavesUnusualCronRaw() {
        #expect(Schedule.describe("0 9 * 1 *") == nil)
        #expect(Schedule.describe("5,35 9 * * *") == nil)
        #expect(Schedule.describe("weekdays at 9am") == nil)
    }

    @Test func describesIntervalsAndOneShots() {
        #expect(Schedule.describe("every 30m") == "Every 30 minutes")
        #expect(Schedule.describe("every 60m") == "Every hour")
        #expect(Schedule.describe("every 120m") == "Every 2 hours")
        #expect(Schedule.describe("every 1440m") == "Every day")
        #expect(Schedule.describe("every 43200m") == "Every 30 days")
        #expect(Schedule.describe("every 2h") == "Every 2 hours")
        #expect(Schedule.describe("once at 2026-10-07 08:20") == "Once at 2026-10-07 08:20")
        #expect(Schedule.describe("every monday 9am") == nil)
    }

    @Test func presetsProduceServerSchedules() {
        #expect(Schedule.Preset.morning.schedule == "0 8 * * *")
        #expect(Schedule.Preset.hourly.schedule == "0 * * * *")
        #expect(Schedule.Preset.weekdays.schedule == "0 9 * * 1-5")
        #expect(Schedule.Preset.custom.schedule == nil)
        // Every preset reads back as its own label's words.
        #expect(Schedule.Preset.allCases.compactMap { $0.schedule.flatMap(Schedule.describe) }
                == ["Every day at 08:00", "Every hour", "Weekdays at 09:00"])
    }
}

struct RoutineParsingTests {
    /// A `cron.manage list` row (tools/cronjob_job_args.py _format_job).
    static let listRow: JSON = [
        "job_id": "6f5b7de21419", "name": "[bot:research] Morning digest", "prompt_preview": "Summarize...",
        "schedule": "0 8 * * *", "enabled": true, "state": "scheduled", "deliver": "origin",
        "next_run_at": "2026-10-14T08:00:00-03:00", "last_run_at": "2026-10-13T08:01:10.866118-03:00",
        "last_status": "error", "last_error": "RuntimeError: provider down", "model": nil,
    ]

    @Test func parsesManageRow() throws {
        let r = try #require(Routine.list(["jobs": [Self.listRow, ["name": "no id"]]]).first)
        #expect(r.id == "6f5b7de21419" && r.title == "Morning digest" && r.schedule == "0 8 * * *")
        #expect(r.prompt == "Summarize..." && r.deliver == "origin" && r.model == nil)
        #expect(r.enabled && !r.completed && r.failed && r.lastError == "RuntimeError: provider down")
        #expect(r.nextRun == Date(timeIntervalSince1970: 1_791_975_600))
        #expect(r.lastRun == Date(timeIntervalSince1970: 1_791_889_270))
    }

    @Test func parsesRestJob() throws {
        // GET /api/cron/jobs/{id}: `id`, a schedule object and the whole prompt.
        let r = try #require(Routine(["id": "a1", "prompt": .string(String(repeating: "x", count: 300)),
                                      "schedule": ["kind": "interval", "minutes": 30, "display": "every 30m"],
                                      "enabled": false, "last_status": "ok"]))
        #expect(r.schedule == "every 30m" && r.prompt.count == 300 && r.name == "a1")
        #expect(r.state == "paused" && !r.failed && r.deliver == "local")
    }

    @Test func deliveryFailureCountsAsFailed() throws {
        let r = try #require(Routine(["job_id": "j", "last_status": "delivery_failed", "last_delivery_error": "chat not found"]))
        #expect(r.failed && r.lastError == "chat not found")
    }

    @Test func parsesRunsAndScriptOnlyFires() {
        let runs = RoutineRun.list(["runs": [
            ["id": "cron_j_20261013_080110", "title": "Morning digest", "preview": "Here is", "started_at": 1_760_353_270,
             "is_active": false, "profile": "default"],
            ["title": "ok", "source": "cron_output", "started_at": 1_760_266_870],
        ]])
        #expect(runs.count == 2)
        #expect(runs[0].sessionId == "cron_j_20261013_080110" && runs[0].profile == "default")
        #expect(runs[1].sessionId == nil && runs[1].id == "run-1")
    }

    @Test func listsAndLabelsDeliveryTargets() {
        let targets = DeliveryTarget.list(["targets": [
            ["id": "local", "name": "Local (save only)", "home_target_set": true],
            ["id": "telegram", "name": "Telegram", "home_target_set": false],
        ]])
        #expect(targets.map(\.id) == ["local", "telegram"] && !targets[1].ready)
        #expect(DeliveryTarget.list([:]) == [.local])
        #expect(DeliveryTarget.label("telegram", targets: targets) == "Telegram")
        #expect(DeliveryTarget.label("telegram:8957600411") == "Telegram (8957600411)")
        #expect(DeliveryTarget.label("origin") == "Where it was created")
        #expect(DeliveryTarget.label("bot-chat:research") == "Bot Chat (research)")
    }
}

struct BotSettingsTests {
    static let describe: JSON = [
        "name": "research", "description": "Digs things up", "soul": "You are curious.",
        "model": ["provider": "openai-codex", "default": "gpt-6"],
        "skills": [["name": "arxiv", "enabled": true], ["name": "scrape", "enabled": false]],
        "toolsets": [["name": "web", "label": "Web", "enabled": true], ["name": "terminal", "enabled": false]],
        "toolsets_pinned": false,
        "mcp_servers": [["name": "github", "enabled": true, "transport": "http"]],
    ]

    static var bot: Bot {
        Bot(Self.row)!
    }

    static let row: JSON = [
        "name": "research", "ui_meta_revisions": ["hermes-bots": 4],
        "ui_meta": ["hermes-bots": ["title": "Research", "pinned": true, "color": "#ff0000", "chat": ["x": 1]]],
    ]

    @Test func readsMetaAndRevision() {
        #expect(Self.bot.metaRevision == 4 && Self.bot.meta?["color"] == "#ff0000")
        #expect(Bot(["name": "old"])?.metaRevision == nil)
        #expect(Bot(["name": "new", "ui_meta_revisions": [:]])?.metaRevision == 0)
    }

    @Test func draftReadsDescribe() {
        let d = BotDraft(bot: Self.bot, describe: Self.describe)
        #expect(d.title == "Research" && d.pinned && !d.hidden)
        #expect(d.description == "Digs things up" && d.soul == "You are curious.")
        #expect(d.provider == "openai-codex" && d.model == "gpt-6")
        #expect(d.disabledSkills == ["scrape"] && d.enabledToolsets == ["web"] && d.enabledMcp == ["github"])
    }

    @Test func configureSendsOnlyChangedSections() {
        let old = BotDraft(bot: Self.bot, describe: Self.describe)
        let toolsets = Capability.list(Self.describe["toolsets"])
        #expect(BotSettings.configureParams(from: old, to: old, toolsets: toolsets).isEmpty)

        var new = old
        new.description = "Digs things up (test)"
        new.title = "Researcher"
        #expect(BotSettings.configureParams(from: old, to: new, toolsets: toolsets) == ["description": "Digs things up (test)"])

        new = old
        new.model = "gpt-6-mini"
        new.disabledSkills = []
        #expect(BotSettings.configureParams(from: old, to: new, toolsets: toolsets)
                == ["model": "gpt-6-mini", "provider": "openai-codex", "disabled_skills": []])
    }

    @Test func toolsetPinIsClearedWhenEverythingIsOn() {
        let old = BotDraft(bot: Self.bot, describe: Self.describe)
        let toolsets = Capability.list(Self.describe["toolsets"])
        var new = old
        new.enabledToolsets = ["web", "terminal"]
        #expect(BotSettings.configureParams(from: old, to: new, toolsets: toolsets)["enabled_toolsets"] == [])
        new.enabledToolsets = ["terminal"]
        #expect(BotSettings.configureParams(from: old, to: new, toolsets: toolsets)["enabled_toolsets"] == ["terminal"])
    }

    @Test func metaWriteKeepsOtherKeysAndCarriesRevision() {
        var d = BotDraft(bot: Self.bot, describe: Self.describe)
        d.title = "  Researcher "
        d.hidden = true
        let p = BotSettings.metaParams(d, server: Self.bot.meta, revision: 4)
        #expect(p["ui_meta"] == ["hermes-bots": ["title": "Researcher", "pinned": true, "hidden": true, "color": "#ff0000"]])
        #expect(p["ui_meta_expected_revisions"] == ["hermes-bots": 4])

        d.title = ""
        let cleared = BotSettings.metaParams(d, server: nil, revision: nil)
        #expect(cleared["ui_meta"]?["hermes-bots"]?["title"] == nil)
        #expect(cleared["ui_meta_expected_revisions"] == nil)
    }

    @Test func reportsFailedSections() {
        #expect(BotSettings.failures(["ok": false, "applied": ["soul": true, "skills": false, "ui_meta_revisions": ["a": 1]]]) == ["skills"])
        #expect(BotSettings.failures(["ok": true, "applied": [:]]).isEmpty)
    }

    @Test func modelChoicesPutSubscriptionsFirst() {
        let options: JSON = ["providers": [
            ["slug": "openrouter", "name": "OpenRouter", "models": ["a/b"]],
            ["slug": "copilot", "name": "Copilot", "models": ["gpt-6"]],
            ["slug": "anthropic", "name": "Anthropic", "models": ["claude"], "authenticated": false],
            ["slug": "custom", "name": "Mine", "models": [["id": "m1"]], "auth_type": "oauth_external"],
            ["slug": "empty", "models": []],
        ]]
        let choices = BotSettings.modelChoices(options)
        #expect(choices.map(\.slug) == ["copilot", "custom", "openrouter"])
        #expect(choices[1].models == ["m1"])
    }
}
