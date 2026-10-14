import Foundation

/// A chat as a Markdown document for sharing.
public enum ChatExport {
    public static func markdown(title: String, items: [ChatItem], assistant: String = "Hermes", exported: Date = Date()) -> String {
        var out = "# \(title)\n\n_Exported \(exported.formatted(date: .abbreviated, time: .shortened))_\n"
        var tools: [String] = []
        func flushTools() {
            guard !tools.isEmpty else { return }
            out += "\n" + tools.map { "> - \($0)" }.joined(separator: "\n") + "\n"
            tools = []
        }
        for item in items {
            if item.kind == .tool, let tool = item.tool {
                tools.append(toolNote(tool))
                continue
            }
            flushTools()
            switch item.kind {
            case .user:
                var body = [item.text.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
                body += item.files.map { "Attached: `\($0)`" }
                if !item.images.isEmpty { body.append("Attached: \(item.images.count) image\(item.images.count == 1 ? "" : "s")") }
                out += "\n## You\n\n" + body.joined(separator: "\n\n") + "\n"
            case .agent:
                out += "\n## \(item.agent?.sender ?? "Agent")\n\n\(item.text)\n"
            case .assistant where !item.text.isEmpty:
                out += "\n## \(assistant)\n\n\(links(item.text).trimmingCharacters(in: .whitespacesAndNewlines))\n"
            case .error:
                out += "\n> Error: \(item.text)\n"
            default:
                break
            }
        }
        flushTools()
        return out
    }

    /// `MEDIA:` tags as links to the file's path on the gateway machine.
    static func links(_ text: String) -> String {
        Media.renderTags(text).replacingOccurrences(of: "](\(Media.scheme):", with: "](")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    static func toolNote(_ tool: ToolCall) -> String {
        let detail = (tool.summary?.nonEmpty ?? tool.context).split(separator: "\n").first.map(String.init) ?? ""
        let short = detail.count > 100 ? String(detail.prefix(99)) + "…" : detail
        return short.isEmpty ? "Used \(tool.name)" : "Used \(tool.name): `\(short.replacingOccurrences(of: "`", with: "'"))`"
    }

    /// `my-chat-title.md`, like the desktop's session export names.
    public static func filename(_ title: String) -> String {
        let slug = title.lowercased().replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(48)).nonEmpty.map { $0 + ".md" } ?? "chat.md"
    }
}
