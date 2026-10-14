import Foundation

// Chat list management (search, pins, archive, rename) and message actions (edit and resend, retry, branch).
// Search, pins, renames and the archived list live on the dashboard's REST routes
// (hermes_cli/web_routers/sessions.py); archive, rewind and branch go over the gateway socket.

// MARK: - REST

extension Gateway {
    /// A dashboard REST call (`/api/...`) with the bearer token; an expired token is refreshed once.
    public func rest(_ method: String = "GET", _ path: String, query: [String: String] = [:],
                     body: [String: JSON]? = nil, timeout: TimeInterval = 60) async throws -> JSON {
        guard let c = credentials else { throw GatewayError.offline }
        do {
            var r = Self.restRequest(method, path, query: query, body: body, credentials: c)
            r.timeoutInterval = timeout
            return try await Self.send(r)
        } catch AuthError.expired {
            // ponytail: two calls expiring together refresh twice; single-flight the refresh if that ever bites.
            let fresh = try await Auth.refresh(c)
            credentials = fresh
            var r = Self.restRequest(method, path, query: query, body: body, credentials: fresh)
            r.timeoutInterval = timeout
            return try await Self.send(r)
        }
    }

    static func restRequest(_ method: String, _ path: String, query: [String: String], body: [String: JSON]?,
                            credentials c: Credentials) -> URLRequest {
        // Same strict encoding as Media.downloadURL: URLComponents would leave `+` and `&` alone.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var comps = URLComponents(url: c.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.percentEncodedQuery = query.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&")
        }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("Bearer \(c.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSON.object(body).data()
        }
        return r
    }

    private static func send(_ request: URLRequest) async throws -> JSON {
        // No redirects, so the bearer token can't be carried to another host.
        let (data, resp) = try await Auth.noRedirects.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return (try? JSON.parse(data)) ?? .null
        case 401: throw AuthError.expired
        default:
            let detail = (try? JSON.parse(data))?["detail"]?.string
            throw GatewayError.rpc(status, detail ?? "Server error \(status)")
        }
    }
}

// MARK: - Rows and search hits

extension SessionRow {
    /// Rows of `session.list` and of the REST list, which share these fields.
    static func parse(_ rows: JSON?) -> [SessionRow] {
        (rows?.array ?? []).compactMap { s in
            guard let id = s["id"]?.string else { return nil }
            return SessionRow(id: id, title: s["title"]?.string ?? "", preview: s["preview"]?.string ?? "",
                              startedAt: Date(timeIntervalSince1970: s["started_at"]?.double ?? 0),
                              messageCount: s["message_count"]?.int ?? 0)
        }
    }
}

/// A chat matching a full-text search, with the message excerpt that matched.
public struct SearchHit: Identifiable, Hashable, Sendable {
    /// Stored id of the conversation's live tip, so opening it continues where it is now.
    public let id: String
    public var title: String
    /// sqlite `snippet()` text; matches sit between `>>>` and `<<<`.
    public var snippet: String
    public var date: Date?

    static func parse(_ json: JSON) -> [SearchHit] {
        (json["results"]?.array ?? []).compactMap { r in
            guard let id = (r["session_id"] ?? r["id"])?.string else { return nil }
            let t = (r["last_active"] ?? r["session_started"] ?? r["started_at"])?.double
            return SearchHit(id: id, title: r["title"]?.string ?? "", snippet: r["snippet"]?.string ?? "",
                             date: t.map(Date.init(timeIntervalSince1970:)))
        }
    }

    /// The snippet as plain and matched runs, markers removed.
    public var runs: [(text: String, match: Bool)] {
        var out: [(text: String, match: Bool)] = []
        var rest = Substring(snippet)
        while let open = rest.range(of: ">>>") {
            if open.lowerBound > rest.startIndex { out.append((String(rest[..<open.lowerBound]), false)) }
            rest = rest[open.upperBound...]
            let close = rest.range(of: "<<<")
            out.append((String(rest[..<(close?.lowerBound ?? rest.endIndex)]), true))
            rest = close.map { rest[$0.upperBound...] } ?? ""
        }
        if !rest.isEmpty { out.append((String(rest), false)) }
        return out
    }
}

// MARK: - Chat list

extension ChatStore {
    public var pinnedSessions: [SessionRow] { sessions.filter { pinned.contains($0.id) } }
    public var unpinnedSessions: [SessionRow] { sessions.filter { !pinned.contains($0.id) } }

    /// Full-text search over every message (and titles, and ids) of this profile's chats.
    public func search(_ query: String) async throws -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return SearchHit.parse(try await gateway.rest("GET", "api/sessions/search", query: restScoped(["q": q, "limit": "30"])))
    }

    /// `limit=1` keeps the recency page to one row; the server back-fills every pinned row past it.
    func refreshPins() async {
        guard let r = try? await gateway.rest("GET", "api/sessions", query: restScoped(["limit": "1", "order": "recent"])) else { return }
        pinned = Self.pinnedIds(r)
    }

    static func pinnedIds(_ list: JSON) -> Set<String> {
        Set((list["sessions"]?.array ?? []).compactMap { $0["pinned"]?.bool == true ? $0["id"]?.string : nil })
    }

    /// Pinning also exempts the chat from the server's auto-archive sweep.
    public func setPinned(_ id: String, _ on: Bool) async {
        let before = pinned
        if on { pinned.insert(id) } else { pinned.remove(id) }
        do {
            _ = try await gateway.rest("PATCH", "api/sessions/\(id)", body: bodyScoped(["pinned": .bool(on)]))
        } catch {
            pinned = before
            alert = error.localizedDescription
        }
    }

    public func rename(_ id: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let r = try await gateway.rest("PATCH", "api/sessions/\(id)", body: bodyScoped(["title": .string(title)]))
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].title = r["title"]?.string ?? title }
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Archived chats keep their messages but leave the list; they come back with `archived: false`.
    public func setArchived(_ id: String, _ archived: Bool) async {
        do {
            _ = try await gateway.call("session.archive", scoped(["session_id": .string(id), "archived": .bool(archived)]))
            if archived { sessions.removeAll { $0.id == id } } else { await refreshSessions() }
        } catch {
            alert = error.localizedDescription
        }
    }

    public func archivedSessions() async throws -> [SessionRow] {
        Self.archivedRows(try await gateway.rest("GET", "api/sessions",
                                                 query: restScoped(["archived": "only", "limit": "100", "order": "recent"])))
    }

    /// The list back-fills pinned chats into every page, `archived=only` included, so keep only the archived rows.
    static func archivedRows(_ list: JSON) -> [SessionRow] {
        SessionRow.parse(.array((list["sessions"]?.array ?? []).filter { $0["archived"]?.bool == true }))
    }

    private func restScoped(_ query: [String: String]) -> [String: String] {
        guard let profile else { return query }
        return query.merging(["profile": profile]) { a, _ in a }
    }

    /// The PATCH handler reads the owning profile from the body; without it the write lands on the default profile.
    private func bodyScoped(_ body: [String: JSON]) -> [String: JSON] {
        guard let profile else { return body }
        return body.merging(["profile": .string(profile)]) { a, _ in a }
    }
}

// MARK: - Message actions

extension ChatStore {
    /// The durable row id of a message, which a rewind needs to address it.
    public func rowId(of item: ChatItem) -> Int? {
        if let mapped = rowIds[item.id] { return mapped }
        return item.id.hasPrefix("row-") ? Int(item.id.dropFirst(4)) : nil
    }

    public func canEdit(_ item: ChatItem) -> Bool {
        item.kind == .user && !item.text.isEmpty && rowId(of: item) != nil
    }

    /// Only the last reply of the chat can be regenerated, and only once its turn is over.
    public func canRegenerate(_ item: ChatItem) -> Bool {
        guard !running, item.kind == .assistant, item.id == items.last(where: { $0.kind == .assistant })?.id,
              let user = items.last(where: { $0.kind == .user }) else { return false }
        return canEdit(user)
    }

    public func canBranch(_ item: ChatItem) -> Bool {
        !running && Self.branchCount(items, through: item.id) > 0
    }

    /// Edit and resend: the server drops `item` and everything after it, then answers `text` in its place.
    public func rewind(_ item: ChatItem, to text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let row = rowId(of: item) else { return }
        do {
            let sid = try await ensureSession()
            if running { try await stopTurn() }
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            let firstTurn = !items[..<index].contains { $0.kind == .user || $0.kind == .agent }
            let params = Self.rewindParams(session: sid, text: text, row: row, firstTurn: firstTurn,
                                           rebind: items.compactMap(rowId(of:)))
            // Cut before the call: the turn's first events can arrive ahead of its response.
            let before = items
            let bubble = ChatItem(id: localId(), kind: .user, text: text, date: Date())
            items = Array(items[..<index]) + [bubble]
            running = true
            turnStartedAt = Date()
            retryText = nil
            do {
                let r = try await submitRewind(params)
                bindRows(r, bubble: bubble.id)
            } catch {
                items = before
                running = false
                turnStartedAt = nil
                throw error
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Retry: runs the last user message again, replacing the reply it got.
    public func regenerate() async {
        guard let user = items.last(where: { $0.kind == .user }) else { return }
        await rewind(user, to: user.text)
    }

    /// Forks the chat into a new one holding the messages up to `item`, and opens it.
    public func branch(at item: ChatItem) async {
        let count = Self.branchCount(items, through: item.id)
        guard count > 0, !running else { return }
        do {
            let sid = try await ensureSession()
            let r = try await gateway.call("session.branch", [
                "session_id": .string(sid), "count": .number(Double(count)),
                // Lets the server hand back the same child if this request is retried.
                "idempotency_key": .string(UUID().uuidString)])
            guard let stored = r["stored_session_id"]?.string else { throw GatewayError.offline }
            await refreshSessions()
            await open(stored)
        } catch {
            alert = error.localizedDescription
        }
    }

    /// `prompt.submit` truncation: drop the user turn at `row` and everything after it. `confirm_truncate` says this
    /// submit really is a rewind; cutting the first turn empties the transcript, which needs its own opt-in.
    static func rewindParams(session: String, text: String, row: Int, firstTurn: Bool, rebind: [Int]) -> [String: JSON] {
        var p: [String: JSON] = ["session_id": .string(session), "text": .string(text),
                                 "confirm_truncate": true, "truncate_before_row_id": .number(Double(row))]
        if firstTurn { p["confirm_empty_truncate"] = true }
        if !rebind.isEmpty { p["rebind_survivor_row_ids"] = .array(rebind.map { .number(Double($0)) }) }
        return p
    }

    /// How many messages a branch through `id` keeps, counted the way the server copies them:
    /// user and assistant rows with visible text (methods_session._visible_branch_history).
    static func branchCount(_ items: [ChatItem], through id: String) -> Int {
        guard let end = items.firstIndex(where: { $0.id == id }) else { return 0 }
        return items[...end].filter {
            [ChatItem.Kind.user, .agent, .assistant].contains($0.kind) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// Records the new user message's row id and the ids a rewind gave the rows it kept.
    func bindRows(_ r: JSON, bubble: String) {
        if let id = r["user_row_id"]?.int { rowIds[bubble] = id }
        guard let map = r["survivor_row_id_map"]?.object else { return }
        for item in items {
            guard let old = rowId(of: item), let new = map[String(old)] else { continue }
            // A null entry means the row was dropped; keep that as an explicit nil.
            rowIds[item.id] = .some(new.int)
        }
    }

    /// Stops the running turn and waits for it to settle, since a rewind is refused while one runs.
    private func stopTurn() async throws {
        await interrupt()
        for _ in 0..<50 where running { try await Task.sleep(for: .milliseconds(100)) }
    }

    /// A turn can still be winding down after the interrupt; the server answers 4009 until it has.
    private func submitRewind(_ params: [String: JSON]) async throws -> JSON {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await gateway.call("prompt.submit", params)
            } catch GatewayError.rpc(4009, _) where attempt < 10 {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
