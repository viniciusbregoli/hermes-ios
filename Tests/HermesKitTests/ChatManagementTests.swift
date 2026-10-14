import Foundation
import Testing
@testable import HermesKit

@MainActor
struct ChatManagementTests {
    let gateway = Gateway(credentials: nil)
    let store: ChatStore
    static let creds = Credentials(baseURL: URL(string: "https://host.ts.net:8447")!, username: "u",
                                   accessToken: "tok", refreshToken: "ref", provider: "basic")

    init() {
        store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "messages": [
            ["role": "user", "text": "first", "row_id": 10],
            ["role": "assistant", "text": "one", "row_id": 11],
            ["role": "tool", "name": "terminal", "row_id": 12],
            ["role": "assistant", "text": "", "reasoning": "hm", "row_id": 13],
            ["role": "user", "text": "second", "row_id": 14],
            ["role": "assistant", "text": "two", "row_id": 15],
        ]])
    }

    @Test func searchRequestEncodesQueryAndCarriesBearer() {
        let r = Gateway.restRequest("GET", "api/sessions/search", query: ["q": "a&b c+d", "limit": "30", "profile": "ada"],
                                    body: nil, credentials: Self.creds)
        #expect(r.url?.absoluteString == "https://host.ts.net:8447/api/sessions/search?limit=30&profile=ada&q=a%26b%20c%2Bd")
        #expect(r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(r.httpBody == nil)
    }

    @Test func patchRequestSendsJSONBody() throws {
        let r = Gateway.restRequest("PATCH", "api/sessions/abc", query: [:], body: ["pinned": true, "profile": "ada"],
                                    credentials: Self.creds)
        #expect(r.url?.absoluteString == "https://host.ts.net:8447/api/sessions/abc")
        #expect(r.httpMethod == "PATCH")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSON.parse(try #require(r.httpBody))
        #expect(body["pinned"]?.bool == true && body["profile"]?.string == "ada")
    }

    @Test func searchHitsParseAndSplitMatches() {
        let hits = SearchHit.parse(["results": [
            ["session_id": "tip", "title": "Trip", "snippet": "book a >>>train<<< to >>>Lyon<<<", "session_started": 100],
            ["id": "byid", "snippet": "Session ID: byid", "last_active": 200],
            ["snippet": "no id"],
        ]])
        #expect(hits.map(\.id) == ["tip", "byid"])
        #expect(hits[0].date == Date(timeIntervalSince1970: 100))
        #expect(hits[0].runs.map { $0.text } == ["book a ", "train", " to ", "Lyon"])
        #expect(hits[0].runs.map { $0.match } == [false, true, false, true])
        #expect(hits[1].runs.map { $0.match } == [false])
        // An unclosed marker still highlights to the end instead of leaking `>>>`.
        #expect(SearchHit(id: "x", title: "", snippet: "a >>>b", date: nil).runs.map { $0.text } == ["a ", "b"])
    }

    @Test func toolPayloadSnippetsShrinkToTheMatchedWords() {
        let hits = SearchHit.parse(["results": [
            ["session_id": "a", "role": "tool", "snippet": #"{"id": "call_eRp7Y22", "output": ">>>ERP<<< ok"}"#],
            ["session_id": "b", "role": "assistant", "snippet": #"{"id": "call_1", "args": ">>>ERP<<<"}"#],
            ["session_id": "c", "role": "user", "snippet": "the >>>ERP<<< is down"],
            ["session_id": "d", "role": "tool", "snippet": #"{"x": 1}"#],
        ]])
        #expect(hits[0].runs.map { $0.text } == ["Tool output: ", "ERP"] && hits[0].runs.map { $0.match } == [false, true])
        #expect(hits[1].runs.map { $0.text } == ["Tool output: ", "ERP"])
        #expect(hits[2].runs.map { $0.text } == ["the ", "ERP", " is down"])
        #expect(hits[3].runs.map { $0.text } == ["Tool output"])
    }

    @Test func pinsComeFromTheRESTFlagAndSplitTheList() {
        store.pinned = ChatStore.pinnedIds(["sessions": [["id": "a", "pinned": true], ["id": "b", "pinned": false], ["id": "c"]]])
        #expect(store.pinned == ["a"])
        store.sessions = SessionRow.parse([["id": "b", "title": "B", "started_at": 1], ["id": "a", "title": "A", "message_count": 3]])
        #expect(store.pinnedSessions.map(\.id) == ["a"])
        #expect(store.unpinnedSessions.map(\.id) == ["b"])
        #expect(store.pinnedSessions[0].messageCount == 3)
    }

    @Test func archivedListDropsBackfilledPins() {
        let rows = ChatStore.archivedRows(["sessions": [["id": "old", "archived": true, "pinned": false],
                                                        ["id": "pin", "archived": false, "pinned": true]]])
        #expect(rows.map(\.id) == ["old"])
    }

    @Test func rewindParamsConfirmTheCut() {
        let p = ChatStore.rewindParams(session: "rt1", text: "again", row: 14, firstTurn: false, rebind: [10, 14])
        #expect(p["truncate_before_row_id"]?.int == 14)
        #expect(p["confirm_truncate"]?.bool == true)
        #expect(p["confirm_empty_truncate"] == nil)
        #expect(p["rebind_survivor_row_ids"] == [10, 14])
        // Rewinding the first message leaves an empty transcript, which the server only does when asked.
        let first = ChatStore.rewindParams(session: "rt1", text: "again", row: 10, firstTurn: true, rebind: [])
        #expect(first["confirm_empty_truncate"]?.bool == true)
        #expect(first["rebind_survivor_row_ids"] == nil)
    }

    @Test func rowIdsComeFromHistoryOrTheSubmitReply() {
        let history = store.items[0]
        #expect(store.rowId(of: history) == 10)
        let live = ChatItem(id: store.localId(), kind: .user, text: "live")
        store.items.append(live)
        #expect(store.rowId(of: live) == nil)
        #expect(!store.canEdit(live))
        store.bindRows(["status": "streaming", "user_row_id": 20], bubble: live.id)
        #expect(store.rowId(of: live) == 20)
        #expect(store.canEdit(live))
        // A rewind that renumbered the kept rows, and dropped one.
        store.bindRows(["survivor_row_id_map": ["10": 30, "14": nil]], bubble: "unused")
        #expect(store.rowId(of: history) == 30)
        #expect(store.rowId(of: store.items.first { $0.text == "second" }!) == nil)
    }

    @Test func retryOnlyOnTheLastReply() {
        let replies = store.items.filter { $0.kind == .assistant }
        #expect(store.canRegenerate(replies.last!))
        #expect(!store.canRegenerate(replies.first!))
        store.running = true
        #expect(!store.canRegenerate(replies.last!))
    }

    @Test func branchCountKeepsVisibleUserAndAssistantRows() {
        let ids = store.items.map(\.id)
        // Tool rows and reasoning-only replies aren't copied into a branch.
        #expect(ChatStore.branchCount(store.items, through: "row-11") == 2)
        #expect(ChatStore.branchCount(store.items, through: "row-14") == 3)
        #expect(ChatStore.branchCount(store.items, through: ids.last!) == 4)
        #expect(ChatStore.branchCount(store.items, through: "missing") == 0)
    }

    @Test func refusedDeleteBringsTheRowBackWhereItWas() async {
        let rows = ["a", "b", "c"].map { SessionRow(id: $0, title: $0, preview: "", startedAt: Date(), messageCount: 1) }
        store.sessions = rows
        // The gateway is offline, so the server call fails.
        let deleted = await store.delete("b")
        #expect(!deleted)
        #expect(store.sessions.map(\.id) == ["a", "b", "c"])
        #expect(store.alert != nil)
    }
}
