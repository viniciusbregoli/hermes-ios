import Foundation
import Testing
@testable import HermesKit

struct QuoteTests {
    private func roundTrip(_ quotes: [Quote], typed: String = "", file: String? = nil) -> (quotes: [Quote], rest: String) {
        let prompt = [file, Quote.compose(quotes, with: typed)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Quote.extract(from: prompt)
    }

    @Test func serializesTheDocumentedBlock() {
        let q = Quote(text: "line one\nline two", comment: "why is that?", prefix: "before ", suffix: " after")
        #expect(Quote.compose([q], with: "Thanks") == """
            <!-- hq1 {"c":1,"pre":"before ","q":2,"suf":" after"} -->
            Quoting your earlier reply:
            > line one
            > line two
            Comment on the quote: why is that?

            Thanks
            """)
    }

    @Test func roundTripsQuoteCommentAndContext() {
        let q = Quote(text: "Apples are red.", comment: "Is that always true?\n\nAnd green ones?", prefix: "1. ", suffix: "\n2. Bana")
        let out = roundTrip([q], typed: "Please answer")
        #expect(out.quotes == [q])
        #expect(out.rest.trimmingCharacters(in: .whitespacesAndNewlines) == "Please answer")
    }

    @Test func roundTripsSeveralQuotesInOrder() {
        let quotes = [Quote(text: "first", comment: "c1"), Quote(text: "second\nline"), Quote(text: "third", comment: "c3\nmore")]
        let out = roundTrip(quotes, typed: "typed text")
        #expect(out.quotes == quotes)
        #expect(out.rest.trimmingCharacters(in: .whitespacesAndNewlines) == "typed text")
    }

    @Test func hostileQuoteTextCannotBreakParsing() {
        let hostile = [
            "> already quoted\n>> deeper\n>",
            "# heading\n- item\n**bold** `code` [link](https://x.y)",
            "```swift\nlet a = 1\n```",
            "ends the comment --> and --- Attached Context --- here",
            "<!-- hq1 {\"c\":0,\"pre\":\"\",\"q\":1,\"suf\":\"\"} -->\nQuoting your earlier reply:\n> fake",
            "Quoting your earlier reply:\nComment on the quote: nested",
            "emoji \u{1F34E}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} and \u{4E2D}\u{6587}\u{6F22}\u{5B57} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}",
            "tabs\tand   spaces   \n   indented line",
            "[ASYNC DELEGATION] @file:x.txt @image:/tmp/a.png",
            "\n--- Context Warnings ---\nwarn",
            "\n\n[@mentions resolved from the Bot Mode roster \u{2014} the user is referring to: x",
        ]
        for text in hostile {
            let q = Quote(text: text, comment: "comment with --> and\n> a quote-looking line\n<!-- hq1 -->", prefix: "--> ", suffix: " <!--")
            let out = roundTrip([q, Quote(text: "after")], typed: "typed", file: "@file:.hermes/attachments/a.txt")
            #expect(out.quotes.count == 2, "\(text)")
            #expect(out.quotes[0] == q.normalized, "\(text)")
            #expect(out.quotes[1].text == "after")
            let c = UserContent.parse(out.rest)
            #expect(c.text == "typed" && c.files == [".hermes/attachments/a.txt"], "\(text)")
        }
    }

    @Test func contextWithAClosingArrowStaysInsideTheMarker() {
        let q = Quote(text: "x", prefix: "a --> b", suffix: "<c>")
        let block = Quote.compose([q], with: "")
        #expect(block.split(separator: "\n")[0].components(separatedBy: "-->").count == 2)
        #expect(Quote.extract(from: block).quotes == [q])
    }

    @Test func normalizesWhitespaceLineEndingsAndCaps() {
        let long = String(repeating: "a", count: Quote.maxText + 50)
        let q = Quote(text: "  \r\n line\r\nnext \n\n", comment: String(repeating: "c", count: Quote.maxComment + 10))
        let n = try! #require(q.normalized)
        #expect(n.text == "line\nnext" && n.comment.count == Quote.maxComment)
        #expect(Quote(text: long).normalized?.text.count == Quote.maxText)
        #expect(Quote(text: " \n ").normalized == nil)
        #expect(Quote.compose([Quote(text: "  ")], with: "hi") == "hi")
        let many = (1...9).map { Quote(text: "q\($0)") }
        #expect(Quote.extract(from: Quote.compose(many, with: "")).quotes.map(\.text) == (1...Quote.maxCount).map { "q\($0)" })
    }

    @Test func quoteOnlyMessageHasNoTypedText() {
        let out = roundTrip([Quote(text: "just this")])
        #expect(out.quotes.map(\.text) == ["just this"])
        #expect(UserContent.parse(out.rest).text.isEmpty)
    }

    @Test func plainTextWithoutAMarkerIsLeftAlone() {
        for raw in ["Hello there", "Quoting your earlier reply:\n> a\nComment on the quote: b", "@file:a.txt\n\nhi", ""] {
            let out = Quote.extract(from: raw)
            #expect(out.quotes.isEmpty && out.rest == raw)
        }
    }

    @Test func brokenOrMisplacedMarkersFallBackToThePlainText() {
        let good = Quote.compose([Quote(text: "a\nb", comment: "c")], with: "")
        let broken = [
            good.replacingOccurrences(of: "\"q\":2", with: "\"q\":3"),            // count too high
            good.replacingOccurrences(of: "\"q\":2", with: "\"q\":1"),            // line after the count is not a comment
            good.replacingOccurrences(of: "\"c\":1", with: "\"c\":2"),            // comment line missing
            String(good.dropLast(12)),                                            // truncated comment
            String(good.split(separator: "\n").prefix(3).joined(separator: "\n")), // truncated quote
            good.replacingOccurrences(of: "{", with: "{{"),                       // invalid JSON
            good.replacingOccurrences(of: "Quoting your earlier reply:", with: "Quoting"),
            "<!-- hq1 -->\nQuoting your earlier reply:\n> a",
            "typed first\n\n" + good,                                              // not at the start
        ]
        for raw in broken {
            let out = Quote.extract(from: raw)
            #expect(out.quotes.isEmpty && out.rest == raw, "\(raw)")
        }
    }

    @Test func aLaterBrokenBlockKeepsTheEarlierQuotes() {
        let good = Quote.compose([Quote(text: "one"), Quote(text: "two\nmore")], with: "")
        let raw = String(good.dropLast("\n> more".count)) + "\n\nand text"
        let out = Quote.extract(from: raw)
        #expect(out.quotes.map(\.text) == ["one"])
        #expect(out.rest.contains("> two") && out.rest.contains("and text"))
    }

    @Test func aMarkerTypedAfterTheQuotesIsPlainText() {
        let marker = "<!-- hq1 {\"c\":0,\"pre\":\"\",\"q\":1,\"suf\":\"\"} -->\nQuoting your earlier reply:\n> typed by hand"
        let out = roundTrip([Quote(text: "real")], typed: "I typed this:\n\n" + marker)
        #expect(out.quotes.map(\.text) == ["real"])
        #expect(out.rest.contains(marker))
    }

    // MARK: Selecting

    @Test func buildsQuotesFromARangeWithContext() throws {
        let plain = "Intro line.\n\n1. Apple: red and crisp.\n2. Banana: yellow and soft."
        let range = (plain as NSString).range(of: "Apple: red and crisp.")
        let q = try #require(Quote(in: plain, range: range, comment: "hm"))
        #expect(q.text == "Apple: red and crisp." && q.comment == "hm")
        #expect(q.prefix == "Intro line.\n\n1. ")
        #expect(q.suffix == "\n2. Banana: yellow and s" && q.suffix.count == Quote.contextLength)
        #expect(Quote(in: "a   b", range: NSRange(location: 1, length: 3)) == nil)
        let trimmed = try #require(Quote(in: "xx  hello  yy", range: NSRange(location: 2, length: 9)))
        #expect(trimmed.text == "hello" && trimmed.prefix == "xx  " && trimmed.suffix == "  yy")
        #expect(Quote(in: "abc", range: NSRange(location: 5, length: 2)) == nil)
    }

    @Test func aSelectionOverTheCapIsCutThereAndTheContextFollows() throws {
        let plain = String(repeating: "word ", count: 2_000)
        let q = try #require(Quote(in: plain, range: NSRange(location: 0, length: plain.utf16.count)))
        #expect(q.text.count == Quote.maxText - 1 && q.text.hasPrefix("word word"))
        #expect(q.prefix.isEmpty && q.suffix.hasPrefix(" word word") && q.suffix.count == Quote.contextLength)
    }

    // MARK: Source lookup

    private func items() -> [ChatItem] {
        [ChatItem(id: "u1", kind: .user, text: "list"),
         ChatItem(id: "a1", kind: .assistant, text: "1. **Apple**: red and crisp.\n2. **Banana**: yellow and soft."),
         ChatItem(id: "u2", kind: .user, text: "more"),
         ChatItem(id: "a2", kind: .assistant, text: "Again: Apple: red and crisp. Done."),
         ChatItem(id: "u3", kind: .user, text: "re")]
    }

    @Test func findsTheReplyByTextAndContext() throws {
        let a1 = Markdown.parse(items()[1].text).plainText
        let range = (a1 as NSString).range(of: "Banana: yellow and soft.")
        let q = try #require(Quote(in: a1, range: range))
        let hit = try #require(Quote.source(of: q, before: "u3", in: items()))
        #expect(hit.itemId == "a1" && hit.exact && hit.range == range)
    }

    @Test func contextPicksTheRightReplyWhenTwoShareTheText() throws {
        let a1 = Markdown.parse(items()[1].text).plainText
        let q = try #require(Quote(in: a1, range: (a1 as NSString).range(of: "Apple: red and crisp.")))
        // The nearest earlier reply holds the same words, but only a1 has the same surroundings.
        let hit = try #require(Quote.source(of: q, before: "u3", in: items()))
        #expect(hit.itemId == "a1" && hit.exact)
        // A message before a2 cannot see it.
        #expect(Quote.source(of: q, before: "u2", in: items())?.itemId == "a1")
    }

    @Test func fallsBackToTheTextAloneWhenTheContextChanged() throws {
        let q = Quote(text: "Banana: yellow and soft", prefix: "totally", suffix: "different")
        let hit = try #require(Quote.source(of: q, before: "u3", in: items()))
        #expect(hit.itemId == "a1" && !hit.exact)
        #expect((Markdown.parse(items()[1].text).plainText as NSString).substring(with: hit.range) == "Banana: yellow and soft")
    }

    @Test func reportsAMissingSourceInsteadOfGuessing() {
        #expect(Quote.source(of: Quote(text: "never said this"), before: "u3", in: items()) == nil)
        #expect(Quote.source(of: Quote(text: "Banana"), before: "u1", in: items()) == nil)
        #expect(Quote.source(of: Quote(text: "Banana"), before: "gone", in: items()) == nil)
        // A rewound chat that cut the reply.
        #expect(Quote.source(of: Quote(text: "Banana"), before: "u3", in: Array(items()[3...])) == nil)
    }

    @Test func matchesEmojiAndCJKByUTF16Offsets() throws {
        let text = "\u{1F34E} \u{82F9}\u{679C}\u{662F}\u{7EA2}\u{7684}\u{3002} \u{1F34C} done"
        let msgs = [ChatItem(id: "a", kind: .assistant, text: text), ChatItem(id: "u", kind: .user, text: "x")]
        let plain = Markdown.parse(text).plainText
        let range = (plain as NSString).range(of: "\u{82F9}\u{679C}\u{662F}\u{7EA2}\u{7684}\u{3002}")
        let q = try #require(Quote(in: plain, range: range))
        let hit = try #require(Quote.source(of: q, before: "u", in: msgs))
        #expect(hit.exact && hit.range == range)
    }

    // MARK: Reload

    @MainActor @Test func historyRowsParseTheirQuotesBack() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        let quote = Quote(text: "Banana: yellow", comment: "why yellow?", prefix: "2. ", suffix: " and soft.")
        let sent = "@file:.hermes/attachments/a.pdf\n\n" + Quote.compose([quote], with: "Explain") + "\n\n--- Attached Context ---\n\n@file:.hermes/attachments/a.pdf (3 tokens)"
        store.apply(snapshot: ["session_id": "rt1", "messages": [
            ["role": "user", "row_id": 1, "text": "plain question"],
            ["role": "assistant", "row_id": 2, "text": "2. Banana: yellow and soft."],
            ["role": "user", "row_id": 3, "text": .string(sent + BotStore.mentionNoteStart + " \u{2014} the user is referring to: x")],
        ]])
        #expect(store.items.map(\.id) == ["row-1", "row-2", "row-3"])
        #expect(store.items[0].quotes.isEmpty)
        #expect(store.items[2].text == "Explain" && store.items[2].files == ["a.pdf"])
        #expect(store.items[2].quotes == [quote])
        #expect(store.canEdit(store.items[2]))
        #expect(Quote.source(of: quote, before: "row-3", in: store.items)?.itemId == "row-2")
    }

    @MainActor @Test func restRowsParseTheirQuotesBackToo() throws {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        let item = try #require(store.item(from: ["role": "user", "row_id": 7, "content": .string(Quote.compose([Quote(text: "a\nb", comment: "c")], with: "hey")),
                                                  "timestamp": 1_700_000_000]))
        #expect(item.id == "row-7" && item.text == "hey" && item.quotes == [Quote(text: "a\nb", comment: "c")] && item.date != nil)
    }

    @MainActor @Test func aQuoteOnlyRowStaysAUserBubbleAndIsEditable() throws {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        let item = try #require(store.item(from: ["role": "user", "row_id": 4, "text": .string(Quote.compose([Quote(text: "only")], with: ""))]))
        #expect(item.kind == .user && item.text.isEmpty && item.quotes.map(\.text) == ["only"])
        #expect(store.canEdit(item))
        #expect(ChatStore.branchCount([item], through: item.id) == 1)
    }

    @MainActor @Test func queuedMessagesKeepTheirQuotes() async {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.running = true
        await store.send("follow up", quotes: [Quote(text: "q", comment: "c"), Quote(text: " ")])
        #expect(store.queue.count == 1 && store.queue[0].quotes == [Quote(text: "q", comment: "c")])
        #expect(store.queue[0].editable && !store.queue[0].steerable)
        #expect(store.queuedBubbles.last?.quotes.map(\.text) == ["q"])
        await store.send("", quotes: [Quote(text: "only quote")])
        #expect(store.queue.count == 2)
        await store.send("   ", quotes: [Quote(text: " ")])
        #expect(store.queue.count == 2)
    }

    @MainActor @Test func aQueuedMessageEditsItsTextAndQuotes() async {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.running = true
        await store.send("follow up", quotes: [Quote(text: "one"), Quote(text: "two")])
        let id = store.queue[0].id
        store.editQueued(id, text: " reworded ", quotes: [Quote(text: "two", comment: "why?")])
        #expect(store.queue[0].text == "reworded" && store.queue[0].quotes == [Quote(text: "two", comment: "why?")])
        // Without `quotes` the message keeps its own.
        store.editQueued(id, text: "again")
        #expect(store.queue[0].quotes.count == 1)
        // Quotes alone keep it; with neither it goes.
        store.editQueued(id, text: "")
        #expect(store.queue.count == 1 && store.queue[0].text.isEmpty)
        store.editQueued(id, text: "", quotes: [])
        #expect(store.queue.isEmpty)
    }

    @MainActor @Test func aQueuedMessageWithQuotesIsNotSteered() async {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.running = true
        await store.send("follow up", quotes: [Quote(text: "one")])
        await store.steerQueued(store.queue[0].id)
        #expect(store.queue.count == 1)
    }

    @Test func sendButtonTakesQuotesWithNoTypedText() {
        func button(_ draft: String, running: Bool = false, editingQueued: Bool = false, quotes: Bool = true) -> SendButton {
            SendButton(draft: draft, running: running, online: true, hasAttachments: false, attaching: false, editingQueued: editingQueued, hasQuotes: quotes)
        }
        #expect(button("").enabled && !button("", quotes: false).enabled)
        #expect(button("", editingQueued: true).enabled)
        // A steer delivers plain text, so quotes keep it a queued message.
        #expect(button("hi", running: true).enabled && !button("hi", running: true).canSteer)
        #expect(button("hi", running: true, quotes: false).canSteer)
    }

    // MARK: Pending quotes

    @Test func previewIsTheFirstWordsOnOneLine() {
        #expect(Quote(text: "Apples are red.").preview == "Apples are red.")
        #expect(Quote(text: "  line one\n\n  line   two ").preview == "line one line two")
        let long = Quote(text: String(repeating: "word ", count: 30)).preview
        #expect(long.hasSuffix("\u{2026}") && long.count <= Quote.previewLength + 1)
    }

    @MainActor @Test func pendingQuotesAreAddedRemovedAndTakenOnce() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        #expect(!store.addQuote(Quote(text: "  ")))
        #expect(store.addQuote(Quote(text: " one ", comment: "c")) && store.addQuote(Quote(text: "two")))
        #expect(store.pendingQuotes.map(\.text) == ["one", "two"])
        store.removeQuote(at: 5)
        store.removeQuote(at: 0)
        #expect(store.pendingQuotes.map(\.text) == ["two"])
        #expect(store.takeQuotes().map(\.text) == ["two"] && store.pendingQuotes.isEmpty && store.takeQuotes().isEmpty)
    }

    @MainActor @Test func aChipKeepsItsIdentityWhileItsCommentChangesAndNeighboursGo() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.addQuote(Quote(text: "one"))
        store.addQuote(Quote(text: "two"))
        let two = store.pendingQuotes[1].id
        store.setComment("why?", forQuote: two)
        store.removeQuote(at: 0)
        #expect(store.pendingQuotes.map(\.id) == [two] && store.pendingQuotes[0].comment == "why?")
        store.setComment(String(repeating: "c", count: Quote.maxComment + 5), forQuote: two)
        #expect(store.pendingQuotes[0].comment.count == Quote.maxComment)
        store.setComment("ignored", forQuote: UUID())
        #expect(Quote(text: "a") == Quote(text: "a") && Quote(text: "a").id != Quote(text: "a").id)
    }

    @MainActor @Test func replacingQuotesSwapsTheComposerContents() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.addQuote(Quote(text: "typed"))
        store.replaceQuotes((1...9).map { Quote(text: "q\($0)") })
        #expect(store.pendingQuotes.map(\.text) == (1...Quote.maxCount).map { "q\($0)" })
        store.replaceQuotes([])
        #expect(store.pendingQuotes.isEmpty)
    }

    @MainActor @Test func aMessageTakesAtMostSixPendingQuotes() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        for i in 1...Quote.maxCount { #expect(store.addQuote(Quote(text: "q\(i)"))) }
        #expect(!store.addQuote(Quote(text: "one too many")))
        store.quote("plain reply", range: NSRange(location: 0, length: 5))
        #expect(store.pendingQuotes.count == Quote.maxCount && store.alert != nil)
    }

    @MainActor @Test func quotingARangeKeepsItsContext() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.quote("One apple a day.", range: NSRange(location: 4, length: 5))
        #expect(store.pendingQuotes == [Quote(text: "apple", prefix: "One ", suffix: " a day.")])
    }

    @MainActor @Test func switchingChatsDropsPendingQuotes() async {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.addQuote(Quote(text: "left behind"))
        await store.open(nil)
        #expect(store.pendingQuotes.isEmpty)
    }

    @Test func blockRangesLocateEachTopLevelBlockInThePlainText() {
        let node = Markdown.parse("# Title\n\nSome **bold** text.\n\n```swift\nlet x = 1\n```\n\n- a\n- b\n\nEnd \u{1F34E}")
        let plain = node.plainText as NSString
        let blocks = node.blockRanges
        #expect(blocks.count == 5)
        #expect(blocks.map { plain.substring(with: $0.range) } == ["Title", "Some bold text.", "let x = 1", "- a\n- b", "End \u{1F34E}"])
        #expect(Markdown.parse("").blockRanges.isEmpty)
    }

    @Test func blockPathPointsAtTheBlockAndTheListItemInIt() {
        let node = Markdown.parse("Intro line.\n\n1. Apple: red.\n2. Banana: yellow\n   - nested\n3. Cherry: dark\n\nEnd \u{1F34E}")
        let plain = node.plainText as NSString
        func path(of s: String) -> [Int]? { node.blockPath(at: plain.range(of: s).location) }
        #expect(path(of: "Intro") == [0])
        #expect(path(of: "Apple") == [1, 0])
        #expect(path(of: "Banana") == [1, 1])
        #expect(path(of: "nested") == [1, 1])
        #expect(path(of: "Cherry") == [1, 2])
        #expect(path(of: "End") == [2])
        #expect(node.blockPath(at: plain.length + 10) == nil)
        #expect(Markdown.parse("").blockPath(at: 0) == nil)
    }

    @Test func aQuoteWithoutACommentHasNoCommentLine() {
        let block = Quote.compose([Quote(text: "Pacific")], with: "")
        #expect(block.hasSuffix("> Pacific") && !block.contains("Comment on the quote"))
        // The stored text is trimmed at its end, so it must parse the same after that.
        #expect(Quote.extract(from: block.trimmingCharacters(in: .whitespacesAndNewlines)).quotes == [Quote(text: "Pacific")])
    }

    @Test func aStoredEmptyCommentLineStillParses() {
        // What older builds sent for a quote with no comment, after the server trimmed the trailing space.
        let raw = "<!-- hq1 {\"c\":1,\"pre\":\"\",\"q\":1,\"suf\":\"\"} -->\nQuoting your earlier reply:\n> Pacific\nComment on the quote:"
        let out = Quote.extract(from: raw)
        #expect(out.quotes == [Quote(text: "Pacific")] && out.rest.isEmpty)
    }
}
