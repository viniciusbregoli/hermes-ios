import Foundation
import Testing
@testable import HermesKit

struct MediaTests {
    @Test func tagAloneOnItsLineBecomesItsOwnParagraph() {
        #expect(Media.renderTags("Here it is:\nMEDIA:/tmp/chart.png\nDone.")
            == "Here it is:\n\n\n[chart.png](hermes-media:/tmp/chart.png)\n\n\nDone.")
    }

    @Test func inlineTagsQuotesSpacesAndPunctuation() {
        #expect(Media.renderTags("open MEDIA:/tmp/a.pdf.") == "open [a.pdf](hermes-media:/tmp/a.pdf).")
        #expect(Media.renderTags("see `MEDIA:/tmp/AI Brain/report.pdf` now")
            == "see [report.pdf](hermes-media:/tmp/AI%20Brain/report.pdf) now")
        #expect(Media.renderTags("a MEDIA:'/tmp/stop!.md' b") == "a [stop!.md](hermes-media:/tmp/stop%21.md) b")
        #expect(Media.renderTags("x MEDIA:/a.png and MEDIA:/b.png")
            == "x [a.png](hermes-media:/a.png) and [b.png](hermes-media:/b.png)")
    }

    @Test func nonPathsStayProse() {
        #expect(Media.renderTags("MEDIA:... is a tag") == "MEDIA:... is a tag")
        #expect(Media.renderTags("no tags here") == "no tags here")
    }

    @Test func hrefRoundTripsThroughURL() throws {
        let path = "/tmp/a b(1)+#?.png"
        let url = try #require(URL(string: Media.href(for: path)))
        #expect(Media.path(from: url) == path)
        #expect(Media.path(from: URL(string: "file:///tmp/x.pdf")!) == "/tmp/x.pdf")
        #expect(Media.path(from: URL(string: "/home/u/report.md")!) == "/home/u/report.md")
        #expect(Media.path(from: URL(string: "https://example.com/a.png")!) == nil)
    }

    @Test func downloadURLEncodesThePath() {
        let url = Media.downloadURL(base: URL(string: "https://host:8447")!, path: "/tmp/a b+c&d.png")
        #expect(url.absoluteString == "https://host:8447/api/files/download?path=/tmp/a%20b%2Bc%26d.png")
    }

    @Test func kindsAndNames() {
        #expect(Media.kind(of: "/tmp/X.PNG") == .image)
        #expect(Media.kind(of: "/tmp/a.mp3") == .audio)
        #expect(Media.kind(of: "/tmp/a.pdf") == .file)
        #expect(Media.name(of: "/tmp/dir/a.pdf") == "a.pdf")
    }
}

struct MarkdownTests {
    func kinds(_ n: MarkdownNode) -> [MarkdownNode.Kind] { n.children.map(\.kind) }

    @Test func aBareListMarkerStaysVisibleText() {
        // "4." is how a model answers "what is 2 + 2?" now and then; it parses as an empty list item.
        for text in ["4.", "4)", "-", "  4.  "] {
            let doc = Markdown.parse(text)
            #expect(kinds(doc) == [.paragraph] && doc.plainText == text)
        }
        #expect(Markdown.parse("").children.isEmpty)
    }

    @Test func blocks() {
        let doc = Markdown.parse("""
        ## Title

        Some **bold** text.

        - a
          - b
        - c

        3. x
        4. y

        | A | B |
        |---|--:|
        | 1 | 2 |

        ---

        ```python
        print(1)
        ```
        """)
        #expect(kinds(doc) == [.heading(2), .paragraph, .list(ordered: false), .list(ordered: true),
                               .table([.left, .right]), .rule, .code(language: "python")])
        let bullets = doc.children[2]
        #expect(bullets.children.map(\.kind) == [.item(ordinal: 0), .item(ordinal: 0)])
        #expect(bullets.children[0].children.map(\.kind) == [.paragraph, .list(ordered: false)])
        #expect(doc.children[3].children.map(\.kind) == [.item(ordinal: 3), .item(ordinal: 4)])
        let table = doc.children[4]
        #expect(table.children.map(\.kind) == [.headerRow, .row])
        #expect(table.children[1].plainText == "1\t2")
        #expect(doc.children[6].plainText == "print(1)")
        #expect(bullets.plainText == "- a\n  - b\n- c")
    }

    @Test func alertsBecomeCallouts() {
        let doc = Markdown.parse("> [!WARNING]\n> Careful here\n\n> just a quote")
        #expect(kinds(doc) == [.alert("WARNING"), .quote])
        #expect(doc.children[0].plainText == "Careful here")
    }

    @Test func mediaParagraphs() {
        let doc = Markdown.parse("Chart:\nMEDIA:/tmp/c.png\n\n![logo](https://e.com/l.png)\n\nInline ![pic](https://e.com/p.png) here, [doc](/srv/r.pdf).")
        #expect(kinds(doc) == [.paragraph, .media, .media, .paragraph])
        #expect(doc.children[1].media == [URL(string: "hermes-media:/tmp/c.png")!])
        #expect(doc.children[2].media == [URL(string: "https://e.com/l.png")!])
        let links = doc.children[3].text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://e.com/p.png")!, URL(string: "hermes-media:/srv/r.pdf")!])
    }

    @Test func inlineCodeImagePathsShowTheImage() {
        let doc = Markdown.parse("Image file: `/home/u/out/chart.png`\n\n- also `~/a.jpg`\n\nScript: `/tmp/make.py`, example `/path/to/x.png`")
        #expect(kinds(doc) == [.paragraph, .media, .list(ordered: false), .paragraph])
        #expect(doc.children[0].plainText == "Image file: /home/u/out/chart.png")
        #expect(doc.children[1].media == [URL(string: "hermes-media:/home/u/out/chart.png")!])
        #expect(doc.children[2].children[0].children.map(\.kind) == [.paragraph, .media])

        let tagged = Markdown.parse("MEDIA:/tmp/c.png\n\nSaved to `/tmp/c.png`.\n\n```\n`/tmp/d.png`\n```")
        #expect(kinds(tagged) == [.media, .paragraph, .code(language: nil)])
    }

    @Test func unclosedFenceStaysCode() {
        let doc = Markdown.parse("Intro\n\n```swift\nlet a = 1")
        #expect(kinds(doc) == [.paragraph, .code(language: "swift")])
    }

    @Test func streamingHoldsBackFragments() {
        #expect(Markdown.stableStreamingText("Text\n\n| A | B |\n") == "Text\n")
        #expect(Markdown.stableStreamingText("Text\n\n| A | B |\n|--") == "Text\n")
        #expect(Markdown.stableStreamingText("| A | B |\n|---|---|\n| 1") == "| A | B |\n|---|---|")
        #expect(Markdown.stableStreamingText("Here:\nMEDIA:/tmp/ch") == "Here:")
        #expect(Markdown.stableStreamingText("Hello wor") == "Hello wor")
    }
}
