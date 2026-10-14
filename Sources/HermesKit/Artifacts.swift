import Foundation
import Observation

/// An image or file the agent produced, found by scanning a chat's transcript.
/// Mirrors the desktop's Artifacts page (app/artifacts/artifact-utils.ts), minus plain web links.
public struct Artifact: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Sendable { case image, file }

    /// A path on the gateway machine, or an http(s) URL.
    public let value: String
    public let sessionId: String
    public var sessionTitle: String
    public let date: Date

    public var id: String { value }
    public var name: String { Media.name(of: path) }
    public var kind: Kind { Media.kind(of: path) == .image ? .image : .file }
    public var isWeb: Bool { value.hasPrefix("http://") || value.hasPrefix("https://") }
    /// What the renderer opens: the web URL, or a `hermes-media:` link to the gateway file.
    public var url: URL? { isWeb ? URL(string: value) : URL(string: Media.href(for: value)) }

    private var path: String { isWeb ? (URL(string: value)?.path ?? value) : value }
}

public enum Artifacts {
    /// The artifacts of one transcript, first sighting of each value kept.
    public static func extract(_ messages: [JSON], session: String, title: String, fallback: Date) -> [Artifact] {
        var out: [Artifact] = []
        var seen = Set<String>()
        for m in messages {
            let date = m["timestamp"]?.double.map(Date.init(timeIntervalSince1970:)) ?? fallback
            for (raw, explicit) in candidates(in: m) {
                let value = normalize(raw)
                guard accept(value, explicit: explicit), seen.insert(value).inserted else { continue }
                out.append(Artifact(value: value, sessionId: session, sessionTitle: title, date: date))
            }
        }
        return out
    }

    /// Newest first; a file seen in several chats (a branch copies its history) is listed once, under the newest.
    public static func merge(_ lists: [[Artifact]]) -> [Artifact] {
        var seen = Set<String>()
        return lists.joined().sorted { $0.date > $1.date }.filter { seen.insert($0.value).inserted }
    }

    // MARK: - Candidates

    /// Raw values plus whether each was an explicit delivery (a `MEDIA:` tag), which counts even without a known extension.
    static func candidates(in m: JSON) -> [(String, Bool)] {
        let text = m["content"]?.string ?? m["text"]?.string ?? ""
        switch m["role"]?.string {
        case "assistant":
            return fromText(text)
        case "tool":
            let tool = (m["tool_name"] ?? m["name"])?.string?.lowercased() ?? ""
            let producer = tool.range(of: producerTool, options: [.regularExpression, .caseInsensitive]) != nil
            var out = tags(in: text)
            let payload = m["content"].flatMap { c -> JSON? in c.string == nil ? c : try? JSON.parse(Data(text.utf8)) }
            if let payload {
                strings(in: payload, keys: []) { value, keys in
                    guard keys.contains(where: { matches($0, strongKey) || (producer && matches($0, producerKey)) }) else { return }
                    out += tags(in: value)
                    out.append((value, false))
                }
            }
            return out
        default:
            return []
        }
    }

    static func fromText(_ text: String) -> [(String, Bool)] {
        var out = tags(in: text)
        for re in [markdownTarget, webURL, barePath] {
            out += matches(re, in: text).map { ($0, false) }
        }
        return out
    }

    /// `MEDIA:` tags, read through the same grammar the renderer uses so both agree on what a tag is.
    static func tags(in text: String) -> [(String, Bool)] {
        guard text.contains("MEDIA:") else { return [] }
        return matches(mediaLink, in: Media.renderTags(text)).compactMap { href in
            URL(string: href).flatMap(Media.path(from:)).map { ($0, true) }
        }
    }

    private static func strings(in json: JSON, keys: [String], _ visit: (String, [String]) -> Void) {
        switch json {
        case .string(let s): visit(s, keys)
        case .array(let a): a.forEach { strings(in: $0, keys: keys, visit) }
        case .object(let o): o.forEach { strings(in: $1, keys: keys + [$0], visit) }
        default: break
        }
    }

    // MARK: - Filtering

    static func normalize(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let q = v.first, "\"'`".contains(q), v.count > 1, v.last == q { v = String(v.dropFirst().dropLast()) }
        while let c = v.last, "`*),.;:]\"'".contains(c) { v.removeLast() }
        if v.hasPrefix("file://") { v = URL(string: v)?.path ?? v }
        return v
    }

    static func accept(_ v: String, explicit: Bool) -> Bool {
        let web = v.hasPrefix("http://") || v.hasPrefix("https://")
        guard web || v.hasPrefix("/") || v.hasPrefix("~/") else { return false }
        // pip's own downloads and cache, not session output (desktop #52972).
        if v.contains("/.cache/pip/") || v.contains("/packages/") && web { return false }
        if explicit && !web { return true }
        let path = web ? (URL(string: v)?.path ?? "") : v
        guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return false }
        return knownExts.contains(path[path.index(after: dot)...].lowercased())
    }

    static let knownExts = Set(Media.deliveryExts + ["heic"])

    // MARK: - Patterns

    private static let mediaLink = try! NSRegularExpression(pattern: #"\]\((\#(Media.scheme):[^)\s]+)\)"#)
    /// The target of a markdown image or link.
    private static let markdownTarget = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
    private static let webURL = try! NSRegularExpression(pattern: #"(https?://[^\s<>"')`]+)"#)
    private static let barePath = try! NSRegularExpression(pattern: #"(?:^|[\s("'`])((?:/|~/)[^\s"'`<>]+)"#)

    // Tools that make files, and the payload keys that name what they made (desktop ARTIFACT_PRODUCER_TOOL_RE and friends).
    private static let producerTool = #"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)"#
    private static let strongKey = #"^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$"#
    private static let producerKey = #"^(?:artifacts?|attachments?|downloads?|(?:artifact|attachment|download|audio|image|video|media)_(?:file|image|path|url)|audio|image|video|media|file_path|local_path|path)$"#

    private static func matches(_ key: String, _ pattern: String) -> Bool {
        key.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func matches(_ re: NSRegularExpression, in text: String) -> [String] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

/// The Artifacts gallery: scans the most recent chats over REST, reusing each chat's earlier scan
/// while its message count is unchanged. The index is kept on disk so the gallery opens filled.
@MainActor @Observable
public final class ArtifactStore {
    public private(set) var items: [Artifact] = []
    public private(set) var loading = false
    /// Chats that couldn't be read in the last scan.
    public private(set) var skipped = 0
    public private(set) var error: String?

    public let gateway: Gateway
    let limit: Int

    struct Entry: Codable { var count: Int; var artifacts: [Artifact] }
    @ObservationIgnored private var index: [String: Entry]?

    public init(gateway: Gateway, limit: Int = 50) {
        self.gateway = gateway
        self.limit = limit
    }

    public func refresh() async {
        if index == nil {
            index = loadIndex()
            items = Artifacts.merge(index!.values.map(\.artifacts))
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            // The list caps `limit` at 100.
            let list = try await gateway.rest("GET", "api/sessions", query: ["limit": "\(min(limit, 100))", "order": "recent"])
            var next: [String: Entry] = [:]
            var failed = 0
            let rows = list["sessions"]?.array ?? []
            // A few transcripts at a time: enough to fill the gallery quickly without flooding the gateway.
            for start in stride(from: 0, to: rows.count, by: 4) {
                await withTaskGroup(of: (String, Entry?).self) { group in
                    for row in rows[start..<min(start + 4, rows.count)] {
                        guard let id = row["id"]?.string else { continue }
                        group.addTask { @MainActor in (id, await self.entry(for: row, id: id)) }
                    }
                    for await (id, entry) in group {
                        if let entry { next[id] = entry } else { failed += 1 }
                    }
                }
                items = Artifacts.merge((index ?? [:]).merging(next) { $1 }.values.map(\.artifacts))
            }
            index = next
            items = Artifacts.merge(next.values.map(\.artifacts))
            skipped = failed
            error = nil
            saveIndex(next)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func entry(for row: JSON, id: String) async -> Entry? {
        let title = row["title"]?.string?.nonEmpty ?? row["preview"]?.string?.nonEmpty ?? "Untitled"
        let count = row["message_count"]?.int ?? -1
        if var cached = index?[id], count >= 0, cached.count == count {
            // A rename doesn't change the count; keep the label current anyway.
            for i in cached.artifacts.indices { cached.artifacts[i].sessionTitle = title }
            return cached
        }
        // ponytail: the default page is the latest 500 messages; page with offset if longer chats hide older files.
        guard let r = try? await gateway.rest("GET", "api/sessions/\(id)/messages", query: ["inline_images": "false"]) else {
            return nil
        }
        let fallback = Date(timeIntervalSince1970: (row["last_active"] ?? row["started_at"])?.double ?? 0)
        return Entry(count: count, artifacts: Artifacts.extract(r["messages"]?.array ?? [], session: id, title: title, fallback: fallback))
    }

    private var indexURL: URL {
        let host = gateway.credentials?.baseURL.host() ?? "none"
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "artifacts-\(host).json")
    }

    private func loadIndex() -> [String: Entry] {
        (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: indexURL))) ?? [:]
    }

    private func saveIndex(_ index: [String: Entry]) {
        try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
}
