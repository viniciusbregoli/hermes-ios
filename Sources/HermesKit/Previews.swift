import Foundation

enum Preview {
    /// A session's preview as one plain line for a list row: no Markdown syntax, and a label instead of text the
    /// gateway injected as the user (a routine's preamble, a delegation result, the Delegate instruction).
    static func clean(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || Harness.isHidden(text, kind: nil) { return "" }
        if text.hasPrefix("Use your delegate_tiered tool") || text.hasPrefix("Use your delegate_task tool") { return "Delegated task" }
        if let note = Harness.note(text: text) { return note.title }
        // A preview is cut at a fixed length, so its last emphasis or code span can be left open; the parser keeps those marks.
        let plain = Markdown.parse(text).plainText.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        return plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What the gateway says about a live session, for the row of its chat in a list.
public struct ChatLive: Hashable, Sendable {
    public enum Status: Sendable {
        case working
        /// A server request (approval, question) is open.
        case needsYou
    }

    public var status: Status?
    public var lastActive: Date

    /// By stored session id; the most recently active one wins when a chat has several live sessions.
    static func rows(_ live: [LiveSession]) -> [String: ChatLive] {
        var out: [String: ChatLive] = [:]
        for row in live where !row.key.isEmpty {
            let status: Status? = switch row.status {
            case "starting", "working": .working
            case "waiting": .needsYou
            default: nil
            }
            if let old = out[row.key], old.lastActive >= row.lastActive { continue }
            out[row.key] = ChatLive(status: status, lastActive: row.lastActive)
        }
        return out
    }
}
