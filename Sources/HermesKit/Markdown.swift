import Foundation

/// A markdown reply as a block tree, built from Foundation's parser (`PresentationIntent` runs).
/// Leaves (paragraph, heading, code, cell) keep their inline formatting as an AttributedString.
public struct MarkdownNode: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case document, paragraph, heading(Int), code(language: String?), rule
        case list(ordered: Bool), item(ordinal: Int), quote, alert(String)
        case table([PresentationIntent.TableColumn.Alignment]), headerRow, row, cell
        /// A paragraph made only of images or delivered files; `media` holds their URLs.
        case media
    }

    public var kind: Kind
    public var text = AttributedString()
    public var children: [MarkdownNode] = []
    /// Image and file URLs of a `.media` node (`https:` or `hermes-media:`).
    public var media: [URL] = []
    var identity = 0

    /// Text without markdown syntax, one block per line.
    public var plainText: String {
        switch kind {
        case .paragraph, .heading, .cell: return String(text.characters)
        case .code: return String(text.characters).trimmingCharacters(in: .newlines)
        case .rule: return "---"
        case .media: return media.map { Media.path(from: $0).map(Media.name(of:)) ?? $0.absoluteString }.joined(separator: "\n")
        case .row, .headerRow: return children.map(\.plainText).joined(separator: "\t")
        case .item(let n):
            let body = children.map { child -> String in
                guard case .list = child.kind else { return child.plainText }
                return child.plainText.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")
            }.joined(separator: "\n")
            return (n > 0 ? "\(n). " : "- ") + body
        default: return children.map(\.plainText).joined(separator: kind == .document ? "\n\n" : "\n")
        }
    }
}

public extension MarkdownNode {
    /// Where each top-level block sits in `plainText` (UTF-16 offsets), so a view can style the plain text by block.
    var blockRanges: [(kind: Kind, range: NSRange)] {
        guard kind == .document else { return [] }
        var at = 0
        return children.map { child in
            defer { at += child.plainText.utf16.count + 2 }
            return (child.kind, NSRange(location: at, length: child.plainText.utf16.count))
        }
    }

    /// The block that holds `offset` of `plainText`: its index among the top-level blocks, then, inside a list, the
    /// index of the item. A long list would otherwise be one block, too big to point at. nil when no block holds it.
    func blockPath(at offset: Int) -> [Int]? {
        let blocks = blockRanges
        guard let top = blocks.firstIndex(where: { offset >= $0.range.location && offset <= $0.range.location + $0.range.length }) else { return nil }
        guard case .list = blocks[top].kind else { return [top] }
        var at = blocks[top].range.location
        for (i, item) in children[top].children.enumerated() {
            let end = at + item.plainText.utf16.count
            if offset <= end { return [top, i] }
            at = end + 1
        }
        return [top]
    }
}

public enum Markdown {
    public static func parse(_ text: String) -> MarkdownNode {
        let source = Media.renderTags(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        func plain() -> MarkdownNode {
            var p = MarkdownNode(kind: .paragraph)
            p.text = AttributedString(text)
            return MarkdownNode(kind: .document, children: [p])
        }
        guard let parsed = try? AttributedString(markdown: source, options: options) else { return plain() }
        var root = MarkdownNode(kind: .document)
        for run in parsed.runs {
            // Components run innermost first; walk them from the document down.
            let path = (run.presentationIntent?.components ?? []).reversed()
            insert(AttributedString(parsed[run.range]), path: Array(path), into: &root)
        }
        // A bare list marker such as "4." parses to an empty list item, which would show nothing at all.
        if root.children.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain() }
        return finish(root)
    }

    private static func insert(_ text: AttributedString, path: [PresentationIntent.IntentType], into node: inout MarkdownNode) {
        guard let first = path.first else { node.text.append(text); return }
        if node.children.last?.identity != first.identity {
            node.children.append(MarkdownNode(kind: kind(first.kind), identity: first.identity))
        }
        insert(text, path: Array(path.dropFirst()), into: &node.children[node.children.count - 1])
    }

    private static func kind(_ k: PresentationIntent.Kind) -> MarkdownNode.Kind {
        switch k {
        case .header(let level): .heading(level)
        case .codeBlock(let lang): .code(language: lang?.nonEmpty)
        case .thematicBreak: .rule
        case .orderedList: .list(ordered: true)
        case .unorderedList: .list(ordered: false)
        case .listItem(let ordinal): .item(ordinal: ordinal)
        case .blockQuote: .quote
        case .table(let columns): .table(columns.map(\.alignment))
        case .tableHeaderRow: .headerRow
        case .tableRow: .row
        case .tableCell: .cell
        default: .paragraph
        }
    }

    /// Post-pass: GFM alerts, media-only paragraphs, gateway file links, and list markers.
    private static func finish(_ n: MarkdownNode, ordered: Bool = false) -> MarkdownNode {
        var n = n
        if case .item = n.kind, !ordered { n.kind = .item(ordinal: 0) }
        if case .list(let o) = n.kind {
            n.children = n.children.map { finish($0, ordered: o) }
        } else {
            n.children = n.children.map { finish($0) }
        }
        switch n.kind {
        case .quote: alert(&n)
        case .paragraph, .heading, .cell: links(&n)
        default: break
        }
        return n
    }

    /// `> [!NOTE]` as the first line of a quote turns it into a callout.
    private static func alert(_ n: inout MarkdownNode) {
        guard let first = n.children.first, first.kind == .paragraph else { return }
        let s = String(first.text.characters)
        guard let m = s.range(of: #"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*"#, options: [.regularExpression, .caseInsensitive])
        else { return }
        let type = s[m].trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2).dropLast().uppercased()
        n.kind = .alert(type)
        var rest = first.text
        rest.removeSubrange(rest.startIndex..<rest.index(rest.startIndex, offsetByCharacters: s.distance(from: s.startIndex, to: m.upperBound)))
        if rest.characters.isEmpty { n.children.removeFirst() } else { n.children[0].text = rest }
    }

    /// Gateway file paths become `hermes-media:` links; a paragraph holding only images or files
    /// becomes a `.media` block, and an image inside prose becomes a link to it.
    private static func links(_ n: inout MarkdownNode) {
        var media: [URL] = []
        var onlyMedia = true
        for run in n.text.runs {
            let target = run.imageURL ?? run.link
            if let url = target, let path = Media.path(from: url), url.scheme != Media.scheme {
                let rewritten = URL(string: Media.href(for: path))
                if run.imageURL != nil { n.text[run.range].imageURL = rewritten } else { n.text[run.range].link = rewritten }
            }
            let url = n.text[run.range].imageURL ?? n.text[run.range].link
            if let url, run.imageURL != nil || url.scheme == Media.scheme {
                media.append(url)
            } else if !String(n.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onlyMedia = false
            }
        }
        // Collapse consecutive runs of one media link (its label may hold several formatted runs).
        media = media.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        if n.kind == .paragraph, onlyMedia, !media.isEmpty {
            n.kind = .media
            n.media = media
            return
        }
        for run in n.text.runs where run.imageURL != nil {
            n.text[run.range].link = run.imageURL
            n.text[run.range].imageURL = nil
        }
    }

    /// While a reply streams, hold back a trailing fragment that would render as something else
    /// once complete: an unfinished `MEDIA:` line, or table rows before the delimiter row arrives.
    public static func stableStreamingText(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty,
           last.contains("MEDIA:") || last.hasPrefix("|") || last.hasPrefix("![") || last.hasPrefix("```") {
            lines.removeLast()
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // A lone row can't be a table yet; it would flash as a paragraph of pipes.
        let rows = lines.reversed().prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }.count
        if rows == 1 { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
