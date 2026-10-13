import Foundation

/// A photo or file picked in the composer. Images are staged with `image.attach_bytes`, which
/// queues them on the live session for the next `prompt.submit`; other files (PDFs included, as
/// on the desktop) go through `file.attach`, which returns an `@file:` ref for the prompt text.
public struct Attachment: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable { case uploading, ready, failed(String) }

    public let id = UUID()
    public let name: String
    public let mime: String
    /// What gets uploaded: a downscaled JPEG for photos, the raw bytes for files.
    public let data: Data
    public internal(set) var state: State = .uploading
    /// Runtime session the upload landed on; a different live session means it must be re-staged.
    var sessionId: String?
    /// Gateway path of a staged image, the key `image.detach` takes.
    var path: String?
    var refText: String?

    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }

    public var isImage: Bool { mime.hasPrefix("image/") }

    /// Matches the server's 25 MB `image.attach_bytes` cap; also keeps file uploads to one sane frame.
    public static let maxBytes = 25 * 1024 * 1024

    func request(session: String) -> (method: String, params: [String: JSON]) {
        let b64 = data.base64EncodedString()
        if isImage {
            return ("image.attach_bytes", ["session_id": .string(session), "content_base64": .string(b64), "filename": .string(name)])
        }
        return ("file.attach", ["session_id": .string(session), "name": .string(name), "data_url": .string("data:\(mime);base64,\(b64)")])
    }

    /// The desktop's submit text (submit.ts buildContextText): `@file:` refs, a blank line, then
    /// what the user typed; an image with no text gets a default question.
    static func promptText(_ typed: String, _ sent: [Attachment]) -> String {
        let refs = sent.compactMap(\.refText).joined(separator: "\n")
        let text = [refs, typed].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if text.isEmpty, sent.contains(where: \.isImage) { return defaultImagePrompt }
        return text
    }

    static let defaultImagePrompt = "What do you see in this image?"
}

/// An image shown in a user bubble: bytes we just sent, or a path on the gateway's disk.
public enum ImageSource: Hashable, Sendable {
    case data(Data)
    case path(String)
}

public struct UserContent: Equatable {
    public var text: String
    public var images: [String] = []
    public var files: [String] = []
}

public extension UserContent {
    /// Splits a transcript user row into what the user typed and its attachments. The gateway
    /// projects a vision turn as "caption\n\n@image:<path>" lines (or "[Image attached at: <path>]"
    /// hints plus an "[image]" placeholder when it can't), and file turns carry "@file:<path>" lines
    /// before the text. Stored rows also carry the model-facing file expansion after an
    /// "--- Attached Context ---" line, which the desktop cuts off (lib/chat-messages/hydration.ts).
    static func parse(_ raw: String) -> UserContent {
        var out = UserContent(text: "")
        var kept: [Substring] = []
        var visible = Substring(raw)
        for marker in ["--- Context Warnings ---", "--- Attached Context ---"] {
            if visible.hasPrefix(marker) { visible = "" }
            if let r = visible.range(of: "\n" + marker) { visible = visible[..<r.lowerBound] }
        }
        for line in visible.split(separator: "\n", omittingEmptySubsequences: false) {
            if let v = refValue(line, "@image:") {
                out.images.append(v)
            } else if let v = refValue(line, "@file:") {
                out.files.append(v)
            } else if line.hasPrefix("[Image attached at: "), line.hasSuffix("]") {
                out.images.append(String(line.dropFirst("[Image attached at: ".count).dropLast()))
            } else if line == "[image]" || line == "[screenshot]" {
                continue
            } else {
                kept.append(line)
            }
        }
        out.text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.images.isEmpty, out.text == Attachment.defaultImagePrompt { out.text = "" }
        return out
    }

    /// A whole-line `@kind:value` ref; the value may be wrapped in backticks or quotes when it has spaces.
    private static func refValue(_ line: Substring, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let v = line.dropFirst(prefix.count)
        if let q = v.first, "`\"'".contains(q), v.count >= 2, v.last == q { return String(v.dropFirst().dropLast()) }
        return v.isEmpty || v.contains(" ") ? nil : String(v)
    }
}

// MARK: - Composer attachments

extension ChatStore {
    /// A user bubble from transcript text, with its attachment refs pulled out as thumbnails and chips.
    func userItem(id: String, _ text: String) -> ChatItem {
        let c = UserContent.parse(text)
        return ChatItem(id: id, kind: .user, text: c.text, images: c.images.map { .path($0) },
                        files: c.files.map { ($0 as NSString).lastPathComponent })
    }

    /// Adds a picked item and stages it right away, so the send itself stays fast.
    public func attach(_ a: Attachment) {
        attachments.append(a)
        Task { await upload(a.id) }
    }

    public func retryAttachment(_ id: UUID) {
        guard let i = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[i].state = .uploading
        Task { await upload(id) }
    }

    public func removeAttachment(_ id: UUID) async {
        guard let a = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        // Staged images stay queued server-side and would ride along with the next prompt.
        if let path = a.path, let sid = a.sessionId, sid == runtimeId {
            _ = try? await gateway.call("image.detach", ["session_id": .string(sid), "path": .string(path)])
        }
    }

    /// True while a chip is uploading or failed: sending then would silently drop it.
    public var attachmentsPending: Bool { attachments.contains { $0.state != .ready } }

    func upload(_ id: UUID) async {
        guard let a = attachments.first(where: { $0.id == id }) else { return }
        do {
            guard a.data.count <= Attachment.maxBytes else { throw GatewayError.rpc(4018, "Too large (25 MB max).") }
            let staged = try await stage(a, on: try await ensureSession())
            if let i = attachments.firstIndex(where: { $0.id == id }) {
                attachments[i] = staged
            } else if let path = staged.path, let sid = staged.sessionId {
                // Removed mid-upload: drop what we just queued.
                _ = try? await gateway.call("image.detach", ["session_id": .string(sid), "path": .string(path)])
            }
        } catch {
            if let i = attachments.firstIndex(where: { $0.id == id }) { attachments[i].state = .failed(error.localizedDescription) }
        }
    }

    private func stage(_ a: Attachment, on sid: String) async throws -> Attachment {
        let (method, params) = a.request(session: sid)
        let r = try await gateway.call(method, params)
        guard r["attached"]?.bool == true else {
            throw GatewayError.rpc(0, r["message"]?.string ?? "Could not attach \(a.name).")
        }
        var out = a
        out.state = .ready
        out.sessionId = sid
        out.path = r["path"]?.string
        out.refText = r["ref_text"]?.string
        if !a.isImage && out.refText == nil { throw GatewayError.rpc(0, "Could not attach \(a.name).") }
        return out
    }

    /// Takes the composer's attachments for a send, re-staging any that landed on a runtime
    /// session we have since lost (reconnect, resume).
    func takeAttachments(for sid: String) async throws -> [Attachment] {
        var sent: [Attachment] = []
        for a in attachments { sent.append(a.sessionId == sid ? a : try await stage(a, on: sid)) }
        attachments = []
        return sent
    }
}

// MARK: - Gateway files

extension Gateway {
    /// Raw bytes of a file on the gateway host, e.g. an image a past turn attached. The desktop
    /// reads these through the same authenticated FS API instead of resuming with inline images.
    public func download(path: String) async throws -> Data {
        guard var creds = credentials else { throw GatewayError.offline }
        for attempt in 0..<2 {
            var comps = URLComponents(url: creds.baseURL.appending(path: "api/fs/download"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [.init(name: "path", value: path)]
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, attempt == 0 {
                creds = try await Auth.refresh(creds)
                credentials = creds
                continue
            }
            guard (200..<300).contains(status) else { throw AuthError.server(status, String(decoding: data.prefix(200), as: UTF8.self)) }
            return data
        }
        throw AuthError.expired
    }
}
