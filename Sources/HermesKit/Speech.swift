import Foundation

/// Read aloud: what to say for a reply, and the gateway's TTS (`POST /api/audio/speak`).
public enum Speech {
    /// Spoken form of a markdown reply, after the desktop's sanitizeTextForSpeech (lib/speech-text.ts):
    /// code, links' targets, URLs, delivered files, paths and emoji become silence; a table is announced by its header.
    public static func speakable(_ markdown: String) -> String {
        var s = tableHeaders(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        // Before code goes: "the list:" followed by a code block would otherwise end on a hanging colon.
        s = replace(#"(?m):[ \t]*$"#, in: s, with: ".")
        s = replace(#"```[\s\S]*?(?:```|$)"#, in: s, with: "")
        s = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: s, with: "")
        s = replace(#"\[([^\]]+)\]\([^)]+\)"#, in: s, with: "$1")
        s = replace(#"`([^`]+)`"#, in: s, with: "$1")
        s = replace(#"https?://\S+"#, in: s, with: "")
        s = replace(#"MEDIA:\S+?(?=[.,;:!?)\]]*(?:\s|$))"#, in: s, with: "")
        // Paths are read character by character, which sounds broken; drop them.
        s = replace(#"(?m)(^|\s)~?/\S+"#, in: s, with: "$1")
        s = replace(#"(?m)^#{1,6}\s+"#, in: s, with: "")
        s = replace(#"(?m)^\s*[-+*]\s+"#, in: s, with: "")
        s = replace(#"[*_~>#|]"#, in: s, with: "")
        // A paragraph break is a pause: keep its sentence's own punctuation, or end the sentence.
        s = replace(#"([.!?])[ \t]*\n{2,}"#, in: s, with: "$1 ")
        s = replace(#"\n{2,}"#, in: s, with: ". ")
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isEmoji($0) }))
        return replace(#"\s+"#, in: s, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The configured voice for `text`, as audio bytes. Throws when the gateway has no TTS provider set up.
    @MainActor public static func synthesize(_ text: String, via gateway: Gateway) async throws -> (data: Data, provider: String?) {
        let r = try await gateway.rest("POST", "api/audio/speak", body: ["text": .string(text)], timeout: 120)
        guard let data = audio(fromDataURL: r["data_url"]?.string ?? "") else { throw GatewayError.rpc(0, "No audio in the reply.") }
        return (data, r["provider"]?.string)
    }

    static func audio(fromDataURL url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// Replaces each table with its header row read as a list ("Model, Price."), so the body isn't read cell by cell.
    static func tableHeaders(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count, lines[i].contains("|"), isDelimiterRow(lines[i + 1]) {
                let header = cells(lines[i]).filter { !$0.isEmpty }.joined(separator: ", ")
                if !header.isEmpty { out.append(header + ".") }
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                continue
            }
            out.append(lines[i])
            i += 1
        }
        return out.joined(separator: "\n")
    }

    private static func cells(_ row: String) -> [String] {
        var r = row.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiterRow(_ line: String) -> Bool {
        let c = cells(line)
        return line.contains("|") && line.contains("-") && c.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
    }

    private static func isEmoji(_ u: Unicode.Scalar) -> Bool {
        // Digits and # are emoji too (keycap bases); only pictographs and their joiners are dropped.
        u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x238C) || u.value == 0xFE0F || u.value == 0x200D
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
