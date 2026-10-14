import Foundation
import Testing
@testable import HermesKit

struct ArtifactsTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func values(_ messages: [JSON]) -> [String] {
        Artifacts.extract(messages, session: "s1", title: "Chat", fallback: t0).map(\.value)
    }

    @Test func assistantTagsImagesLinksURLsAndPaths() {
        let text = """
        Here is the chart:
        MEDIA:/tmp/chart.png
        ![plot](/home/u/plot.jpg) and [the data](/tmp/data.csv).
        Also https://example.com/report.pdf, saved to `/tmp/notes.md`.
        Plain https://example.com/page and /usr/bin/env stay out.
        """
        #expect(values([["role": "assistant", "content": .string(text)]])
            == ["/tmp/chart.png", "/home/u/plot.jpg", "/tmp/data.csv", "https://example.com/report.pdf", "/tmp/notes.md"])
    }

    @Test func explicitTagCountsWithoutKnownExtension() {
        #expect(values([["role": "assistant", "content": "MEDIA:/tmp/build.log.final"]]) == ["/tmp/build.log.final"])
        #expect(values([["role": "assistant", "content": "see /tmp/build.log.final"]]).isEmpty)
    }

    @Test func userMessagesAreNotArtifacts() {
        #expect(values([["role": "user", "content": "use /tmp/input.csv"]]).isEmpty)
    }

    @Test func toolPayloadKeysAndTags() {
        let messages: [JSON] = [
            // A producer tool's `path`, and a strong key on any tool.
            ["role": "tool", "tool_name": "image_generate", "content": #"{"success": true, "path": "/tmp/gen.webp"}"#],
            ["role": "tool", "tool_name": "browser", "content": #"{"screenshot_path": "/tmp/shot.png", "path": "/tmp/ignored.png"}"#],
            ["role": "tool", "tool_name": "terminal", "content": #"{"output": "wrote MEDIA:/tmp/out.csv"}"#],
            ["role": "tool", "tool_name": "terminal", "content": #"{"output": "ls /tmp/other.csv"}"#],
        ]
        #expect(values(messages) == ["/tmp/gen.webp", "/tmp/shot.png", "/tmp/out.csv"])
    }

    @Test func dedupWithinAChatKeepsFirstSightingAndItsDate() {
        let a = Artifacts.extract([
            ["role": "assistant", "content": "MEDIA:/tmp/a.png", "timestamp": 50],
            ["role": "assistant", "content": "again: /tmp/a.png", "timestamp": 90],
        ], session: "s1", title: "Chat", fallback: t0)
        #expect(a.count == 1)
        #expect(a[0].date == Date(timeIntervalSince1970: 50))
        #expect(a[0].kind == .image && a[0].name == "a.png")
        #expect(a[0].url?.absoluteString == "hermes-media:/tmp/a.png")
    }

    @Test func normalizeStripsQuotesPunctuationAndFileScheme() {
        #expect(Artifacts.normalize("\"/tmp/a.png\"") == "/tmp/a.png")
        #expect(Artifacts.normalize("/tmp/a.png).") == "/tmp/a.png")
        #expect(Artifacts.normalize("file:///tmp/a%20b.pdf") == "/tmp/a b.pdf")
    }

    @Test func pipDownloadsAreSkipped() {
        #expect(!Artifacts.accept("/home/u/.cache/pip/http/x.zip", explicit: false))
        #expect(!Artifacts.accept("https://files.pythonhosted.org/packages/ab/pkg-1.0.tar.gz", explicit: false))
    }

    @Test func mergeIsNewestFirstAndListsAFileOnceAcrossChats() {
        let old = Artifact(value: "/tmp/a.png", sessionId: "s1", sessionTitle: "First", date: Date(timeIntervalSince1970: 10))
        let branch = Artifact(value: "/tmp/a.png", sessionId: "s2", sessionTitle: "Branch", date: Date(timeIntervalSince1970: 30))
        let other = Artifact(value: "/tmp/b.csv", sessionId: "s1", sessionTitle: "First", date: Date(timeIntervalSince1970: 20))
        let merged = Artifacts.merge([[old, other], [branch]])
        #expect(merged.map(\.value) == ["/tmp/a.png", "/tmp/b.csv"])
        #expect(merged[0].sessionId == "s2")
        #expect(merged[1].kind == .file)
    }

    @Test func webArtifactsKeepTheirURL() {
        let a = Artifact(value: "https://x.com/img/cat.jpg?w=2", sessionId: "s", sessionTitle: "", date: t0)
        #expect(a.isWeb && a.kind == .image && a.name == "cat.jpg")
        #expect(a.url?.absoluteString == "https://x.com/img/cat.jpg?w=2")
    }
}
