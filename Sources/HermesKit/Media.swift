import Foundation

/// Files the agent delivers in a reply: `MEDIA:/path` tags and links to paths on the gateway machine.
/// The grammar mirrors the desktop (lib/chat-messages/parts.ts) so both clients agree on what is a tag.
public enum Media {
    public enum Kind: Sendable { case image, video, audio, file }

    /// Links to gateway files are rewritten to this scheme so the renderer can tell them from web links.
    public static let scheme = "hermes-media"

    // Mirrors MEDIA_DELIVERY_EXTS in the gateway (gateway/platforms/base.py).
    static let deliveryExts = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv",
                               "webm", "3gp", "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc",
                               "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods", "csv", "tsv", "json", "xml",
                               "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip", "tar",
                               "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm"]

    static let tagRegex: NSRegularExpression = {
        // Longest first so `tar` never wins over a longer extension that starts the same way.
        let exts = deliveryExts.sorted { $0.count > $1.count }.joined(separator: "|")
        // A path anchor, interior spaces allowed, ending on a known extension; else a bare word.
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + exts + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let bare = #"[^\s`"]+"#
        let value = #"`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + "|" + bare
        // Group 1: leading text on the line; 2: the value; 3: trailing text on the line.
        return try! NSRegularExpression(pattern: #"([^\n]*?)[`"']?MEDIA:\s*("# + value + #")[`"']?([^\n]*)"#)
    }()

    /// Replaces `MEDIA:` tags with markdown links to `hermes-media:` URLs. A tag alone on its line
    /// becomes its own paragraph, so the renderer can show it as a block (an image or a file card).
    public static func renderTags(_ text: String) -> String {
        guard text.contains("MEDIA:") else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let lead = ns.substring(with: m.range(at: 1))
            let trail = ns.substring(with: m.range(at: 3))
            var (path, punctuation) = unquote(ns.substring(with: m.range(at: 2)))
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            guard isPlausiblePath(path) else { out += ns.substring(with: m.range); continue }
            path = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
            let link = "[\(escape(name(of: path)))](\(href(for: path)))\(punctuation)"
            let alone = lead.trimmingCharacters(in: .whitespaces).isEmpty && trail.trimmingCharacters(in: .whitespaces).isEmpty
            out += alone ? "\n\n\(link)\n\n" : lead + link + renderTags(trail)
        }
        out += ns.substring(from: last)
        return out
    }

    /// The path inside a captured value, plus sentence punctuation that trailed a bare path in prose.
    static func unquote(_ raw: String) -> (path: String, punctuation: String) {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if let q = v.first, "\"'`".contains(q), v.count > 1, v.last == q { return (String(v.dropFirst().dropLast()), "") }
        var path = v.last == "`" || v.last == "\"" ? String(v.dropLast()) : v
        var punctuation = ""
        while let c = path.last, ".,;:!?".contains(c), isPlausiblePath(String(path.dropLast())) {
            punctuation.insert(path.removeLast(), at: punctuation.startIndex)
        }
        return (path, punctuation)
    }

    /// A path separator, or a dot followed by more name (`report.md`, `.env`); not a bare word or `...`.
    static func isPlausiblePath(_ s: String) -> Bool {
        s.contains("/") || s.contains("\\") || s.range(of: #"\.[^.]"#, options: .regularExpression) != nil
    }

    static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    public static func href(for path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return "\(scheme):" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    /// The gateway path behind a link: a `hermes-media:` URL, a `file://` URL, or a bare absolute path.
    public static func path(from url: URL) -> String? {
        if url.scheme == scheme { return String(url.absoluteString.dropFirst(scheme.count + 1)).removingPercentEncoding }
        if url.isFileURL { return url.path }
        if url.scheme == nil, isFilePath(url.relativeString) { return url.relativeString.removingPercentEncoding }
        return nil
    }

    public static func isFilePath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("file:")
    }

    /// `GET /api/files/download?path=...`, authorized with the bearer token.
    public static func downloadURL(base: URL, path: String) -> URL {
        // URLComponents leaves `+` and `&` alone in queries; encode everything outside unreserved.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        var comps = URLComponents(url: base.appending(path: "api/files/download"), resolvingAgainstBaseURL: false)!
        comps.percentEncodedQuery = "path=" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
        return comps.url!
    }

    public static func name(of path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    public static func kind(of path: String) -> Kind {
        switch (path.split(separator: ".").last.map { $0.lowercased() } ?? "") {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic": .image
        case "mp4", "mov", "avi", "mkv", "webm", "3gp": .video
        case "mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac": .audio
        default: .file
        }
    }
}
