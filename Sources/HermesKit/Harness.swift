import Foundation

/// A transcript row the gateway wrote as the user (a finished process, a delegation result, a routine's
/// preamble). Hermes Desktop paints these as system notices instead of the user's bubble
/// (hydration.ts `isMachineNotice`, thread/content.ts `PROCESS_NOTIFICATION_RE`).
public struct SystemNote: Hashable, Sendable {
    public var title: String
    public var icon: String
    /// What a tap reveals; empty when the title says it all.
    public var detail: String
}

enum Harness {
    private static let process = "[IMPORTANT: Background process "
    private static let cron = "[IMPORTANT: You are running as a scheduled cron job"
    /// A routine that runs a skill opens with the skill's whole body, the cron rules inside it.
    private static let skill = try! NSRegularExpression(pattern: #"^\[IMPORTANT: The user has invoked the "([^"]+)" skill"#)
    private static let delegation = ["[ASYNC DELEGATION", "A background fan-out of ", "A background subagent you dispatched earlier"]
    /// A background-process wake that older gateways persisted untyped; it is scaffolding for the model.
    private static let heartbeat = #"^\[Background process \S+ heartbeat #\d+ "#

    /// Rows the user never needs to see.
    static func isHidden(_ text: String, kind: String?) -> Bool {
        kind == "hidden" || text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: heartbeat, options: .regularExpression) != nil
    }

    /// The note for a user-role row the gateway injected, by the `display_kind` it stamped or, for older rows, by its text.
    static func note(text raw: String, kind: String? = nil, metadata: JSON? = nil) -> SystemNote? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = metadata.flatMap { $0.string.flatMap { try? JSON.parse(Data($0.utf8)) } ?? $0 }
        let label = meta?["display_text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        switch kind {
        case "model_switch": return SystemNote(title: "Model changed", icon: "arrow.triangle.2.circlepath", detail: text)
        case "auto_continue": return SystemNote(title: "Resumed interrupted turn", icon: "arrow.clockwise", detail: text)
        case "personality_switch": return SystemNote(title: "Personality changed", icon: "theatermasks", detail: text)
        default: break
        }
        if kind == "async_delegation_complete" || delegation.contains(where: { text.hasPrefix($0) }) {
            let count = meta?["task_count"]?.int
            let title = label ?? count.map { "\($0) background \($0 == 1 ? "agent" : "agents") finished" } ?? "Delegated work finished"
            // The live transcript's path is a location on the gateway's machine, no use on the phone.
            var lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("Full live transcript") }
            if lines.first?.hasPrefix("[ASYNC DELEGATION") == true { lines.removeFirst() }
            return SystemNote(title: title, icon: "person.2", detail: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let m = skill.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let name = Range(m.range(at: 1), in: text) {
            let routine = text.contains("You are running as a scheduled cron job")
            let body = text.range(of: "]\n\n").map { String(text[$0.upperBound...]) } ?? ""
            return SystemNote(title: "\(routine ? "Routine run" : "Skill"): \(text[name])", icon: routine ? "clock.arrow.circlepath" : "sparkles", detail: body)
        }
        if text.hasPrefix(cron) {
            // The preamble is one bracketed paragraph of delivery rules; what follows it is the routine's own prompt.
            let prompt = text.range(of: "]\n\n").map { String(text[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            return SystemNote(title: "Routine run", icon: "clock.arrow.circlepath", detail: prompt ?? "")
        }
        if kind == "process_complete" || text.hasPrefix(process) {
            var body = text
            if body.hasPrefix("[IMPORTANT:") { body = String(body.dropFirst("[IMPORTANT:".count)) }
            if body.hasSuffix("]") { body.removeLast() }
            body = body.replacingOccurrences(of: #"__HERMES_CWD_\w+__"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let first = body.components(separatedBy: "\n").first ?? ""
            let done = first.contains("completed") || first.contains("exited")
            return SystemNote(title: label ?? (done ? "Background process finished" : "Background process update"),
                              icon: "terminal", detail: body)
        }
        return nil
    }
}
