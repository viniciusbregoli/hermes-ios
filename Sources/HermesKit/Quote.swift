import Foundation

/// A passage the user picked from an assistant reply and sends back with a comment.
///
/// `prompt.submit` has no display field, so the transcript holds exactly what the model saw and one text
/// serves both: a hidden marker plus a readable block, put before the typed text and parsed back out when
/// the row is reloaded (like the @mention note, which is appended and stripped).
///
///     <!-- hq1 {"c":1,"pre":"...","q":2,"suf":"..."} -->
///     Quoting your earlier reply:
///     > line one
///     > line two
///     Comment on the quote: why is that?
///
/// `q` counts the `> ` lines and `c` the comment lines, so parsing never depends on what the quoted text says.
public struct Quote: Hashable, Identifiable, Sendable {
    public static let maxText = 4_000
    public static let maxComment = 2_000
    public static let maxCount = 6
    /// Characters of the reply kept on each side of the quote, to find it again.
    public static let contextLength = 24

    /// Keeps a chip the same chip while its comment is edited or another one is removed. Quotes with the same
    /// words are equal whatever their ids.
    public let id = UUID()
    public var text: String
    public var comment: String
    /// What came right before and after the quote in the reply's plain text.
    public var prefix: String
    public var suffix: String

    public init(text: String, comment: String = "", prefix: String = "", suffix: String = "") {
        self.text = text
        self.comment = comment
        self.prefix = prefix
        self.suffix = suffix
    }

    public static func == (a: Quote, b: Quote) -> Bool {
        a.text == b.text && a.comment == b.comment && a.prefix == b.prefix && a.suffix == b.suffix
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(comment)
        hasher.combine(prefix)
        hasher.combine(suffix)
    }

    /// The quote for `range` of `source` (a reply's plain text), with its surrounding context. Text beyond
    /// `maxText` is cut, and the context is taken from where the cut falls. nil when nothing but whitespace is selected.
    public init?(in source: String, range: NSRange, comment: String = "") {
        guard let r = Range(range, in: source) else { return nil }
        var lower = r.lowerBound
        var upper = source.index(lower, offsetBy: Self.maxText, limitedBy: r.upperBound) ?? r.upperBound
        while lower < upper, source[lower].isWhitespace { lower = source.index(after: lower) }
        while lower < upper, source[source.index(before: upper)].isWhitespace { upper = source.index(before: upper) }
        guard lower < upper else { return nil }
        self.init(text: String(source[lower..<upper]), comment: comment,
                  prefix: String(source[..<lower].suffix(Self.contextLength)),
                  suffix: String(source[upper...].prefix(Self.contextLength)))
    }

    /// One line for a chip or an indicator: the quote's first words.
    public var preview: String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > Self.previewLength ? String(flat.prefix(Self.previewLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}" : flat
    }
    static let previewLength = 48

    /// The quote as it is sent: line endings unified, edges trimmed, caps applied. nil when no text is left.
    var normalized: Quote? {
        let text = Self.clean(text, cap: Self.maxText)
        guard !text.isEmpty else { return nil }
        return Quote(text: text, comment: Self.clean(comment, cap: Self.maxComment),
                     prefix: String(Self.lines(prefix).suffix(Self.contextLength)),
                     suffix: String(Self.lines(suffix).prefix(Self.contextLength)))
    }

    private static func lines(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }

    private static func clean(_ s: String, cap: Int) -> String {
        String(lines(s).trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
    }
}

// MARK: - Serialize

extension Quote {
    static let markerStart = "<!-- hq1 "
    static let markerEnd = " -->"
    static let header = "Quoting your earlier reply:"
    static let commentLead = "Comment on the quote: "

    private struct Marker: Codable {
        var pre: String
        var suf: String
        var q: Int
        var c: Int
    }

    /// The text a prompt carries for `quotes` followed by what the user typed. Quotes with no text are dropped
    /// and only the first `maxCount` are kept.
    public static func compose(_ quotes: [Quote], with typed: String) -> String {
        let blocks = quotes.compactMap(\.normalized).prefix(maxCount).map(\.block)
        return (blocks + [typed].filter { !$0.isEmpty }).joined(separator: "\n\n")
    }

    /// `normalized` must hold; `compose` is the entry point.
    private var block: String {
        let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }
        let note = comment.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Marker(pre: prefix, suf: suffix, q: quoted.count, c: note.count))) ?? Data("{}".utf8)
        // A ">" in the context must not close the HTML comment early; it is valid JSON either way.
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: ">", with: "\\u003e")
        var lines = [Self.markerStart + json + Self.markerEnd, Self.header] + quoted
        if !note.isEmpty { lines += [Self.commentLead + note[0]] + note.dropFirst() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Parse

extension Quote {
    /// Splits the quote blocks out of a stored user text. The blocks must come first, after any attachment refs
    /// and with nothing between them; a marker anywhere else, or a block that does not add up, is ordinary text
    /// and the input comes back untouched.
    public static func extract(from raw: String) -> (quotes: [Quote], rest: String) {
        guard raw.contains(markerStart) else { return ([], raw) }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { $0.hasPrefix(markerStart) }),
              lines[..<first].allSatisfy({ $0.allSatisfy(\.isWhitespace) || isRef($0) }) else { return ([], raw) }
        var quotes: [Quote] = []
        var end = first
        var at = first
        while at < lines.count {
            while at < lines.count, quotes.count > 0, lines[at].allSatisfy(\.isWhitespace) { at += 1 }
            guard at < lines.count, let (quote, next) = parseBlock(lines, at: at) else { break }
            quotes.append(quote)
            at = next
            end = next
        }
        guard !quotes.isEmpty else { return ([], raw) }
        return (quotes, (lines[..<first] + lines[end...]).joined(separator: "\n"))
    }

    private static func isRef(_ line: Substring) -> Bool {
        ["@file:", "@image:", "[Image attached at: "].contains { line.hasPrefix($0) } || line == "[image]"
    }

    private static func parseBlock(_ lines: [Substring], at i: Int) -> (Quote, Int)? {
        var marker = lines[i].trimmingCharacters(in: .whitespaces)
        guard marker.hasPrefix(markerStart), marker.hasSuffix(markerEnd), marker.count >= markerStart.count + markerEnd.count else { return nil }
        marker = String(marker.dropFirst(markerStart.count).dropLast(markerEnd.count))
        guard let m = try? JSONDecoder().decode(Marker.self, from: Data(marker.utf8)), m.q > 0, m.c >= 0,
              m.q <= lines.count, m.c <= lines.count, i + 2 + m.q + m.c <= lines.count,
              lines[i + 1] == header else { return nil }
        var quoted: [String] = []
        for line in lines[(i + 2)..<(i + 2 + m.q)] {
            if line.hasPrefix("> ") { quoted.append(String(line.dropFirst(2))) } else if line == ">" { quoted.append("") } else { return nil }
        }
        var note: [String] = []
        if m.c > 0 {
            let comment = lines[(i + 2 + m.q)..<(i + 2 + m.q + m.c)]
            guard comment.first?.hasPrefix(commentLead) == true else { return nil }
            note = [String(comment.first!.dropFirst(commentLead.count))] + comment.dropFirst().map(String.init)
        }
        return (Quote(text: quoted.joined(separator: "\n"), comment: note.joined(separator: "\n"), prefix: m.pre, suffix: m.suf), i + 2 + m.q + m.c)
    }
}

// MARK: - Source

/// Where a quote came from in the transcript: the reply and the span of its plain text.
public struct QuoteSource: Equatable, Sendable {
    public var itemId: String
    /// UTF-16 range in `Markdown.parse(item.text).plainText`.
    public var range: NSRange
    /// True when the text and its surrounding context matched; false when only the text did, so the reply
    /// may have changed or the same words may sit elsewhere in it.
    public var exact: Bool
}

extension Quote {
    /// The span of `plain` this quote covers, by its text plus context, else by its text alone.
    func find(in plain: String) -> (range: NSRange, exact: Bool)? {
        if let r = plain.range(of: prefix + text + suffix, options: .literal) {
            let whole = NSRange(r, in: plain)
            return (NSRange(location: whole.location + prefix.utf16.count, length: text.utf16.count), true)
        }
        guard let r = plain.range(of: text, options: .literal) else { return nil }
        return (NSRange(r, in: plain), false)
    }

    /// Finds the reply a quote in the message `id` was taken from: the nearest earlier assistant reply that
    /// holds the quote with its context, else the nearest one that holds the text. Replies are matched by
    /// text because row ids change on a rewind and live ids are replaced by stored ones.
    /// nil when no earlier reply holds it (the reply was cut or rewritten): the quote itself is still readable.
    public static func source(of quote: Quote, before id: String, in items: [ChatItem]) -> QuoteSource? {
        guard let at = items.firstIndex(where: { $0.id == id }) else { return nil }
        var textOnly: QuoteSource?
        for item in items[..<at].reversed() where item.kind == .assistant {
            guard let hit = quote.find(in: Markdown.parse(item.text).plainText) else { continue }
            let source = QuoteSource(itemId: item.id, range: hit.range, exact: hit.exact)
            if hit.exact { return source }
            textOnly = textOnly ?? source
        }
        return textOnly
    }
}

// MARK: - Pending quotes

extension ChatStore {
    /// Adds a quote to the next message. false when the message already holds `Quote.maxCount` or the quote is empty.
    @discardableResult
    public func addQuote(_ quote: Quote) -> Bool {
        guard pendingQuotes.count < Quote.maxCount, let quote = quote.normalized else { return false }
        pendingQuotes.append(quote)
        return true
    }

    /// Quotes `range` of a reply's plain text; says why in `alert` when the message cannot take another quote.
    public func quote(_ plain: String, range: NSRange) {
        guard pendingQuotes.count < Quote.maxCount else { alert = "A message can quote up to \(Quote.maxCount) passages."; return }
        guard let quote = Quote(in: plain, range: range) else { return }
        addQuote(quote)
    }

    /// Puts `quotes` in the composer in place of the pending ones, as when a message is opened for editing.
    public func replaceQuotes(_ quotes: [Quote]) {
        pendingQuotes = Array(quotes.prefix(Quote.maxCount))
    }

    /// Sets the comment of a pending quote, cut to `Quote.maxComment`.
    public func setComment(_ comment: String, forQuote id: Quote.ID) {
        guard let i = pendingQuotes.firstIndex(where: { $0.id == id }) else { return }
        pendingQuotes[i].comment = String(comment.prefix(Quote.maxComment))
    }

    public func removeQuote(at index: Int) {
        guard pendingQuotes.indices.contains(index) else { return }
        pendingQuotes.remove(at: index)
    }

    /// The pending quotes for a send; the composer is left empty.
    public func takeQuotes() -> [Quote] {
        defer { pendingQuotes = [] }
        return pendingQuotes
    }
}
