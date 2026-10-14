import Foundation
import Testing
@testable import HermesKit

struct SpeechTests {
    @Test func codeLinksAndMarkupAreNotRead() {
        let reply = """
        # Result

        Run this **now**:
        ```sh
        rm -rf build
        ```
        See [the docs](https://example.com/docs) and `make test`.
        - first
        - second
        """
        #expect(Speech.speakable(reply) == "Result. Run this now. See the docs and make test. first second")
    }

    @Test func filesURLsPathsAndEmojiAreSilent() {
        #expect(Speech.speakable("Done 🎉 MEDIA:/tmp/chart.png. Saved to /tmp/out.csv, see https://x.com/a") == "Done . Saved to see")
        #expect(Speech.speakable("![chart](/tmp/c.png) Here it is.") == "Here it is.")
    }

    @Test func tableIsAnnouncedByItsHeader() {
        let reply = "Prices:\n\n| Model | Price |\n|---|--:|\n| a | 1 |\n| b | 2 |\n\nCheapest is a."
        #expect(Speech.speakable(reply) == "Prices. Model, Price. Cheapest is a.")
    }

    @Test func dataURLDecodes() {
        #expect(Speech.audio(fromDataURL: "data:audio/mpeg;base64,aGk=") == Data("hi".utf8))
        #expect(Speech.audio(fromDataURL: "data:audio/mpeg,hi") == nil)
        #expect(Speech.audio(fromDataURL: "") == nil)
    }
}

struct ChatExportTests {
    @Test func turnsToolsAttachmentsAndMedia() {
        let items = [
            ChatItem(id: "1", kind: .user, text: "Make a chart", files: ["data.csv"]),
            ChatItem(id: "2", kind: .tool, tool: ToolCall(id: "t1", name: "terminal", context: "python plot.py\nmore", running: false)),
            ChatItem(id: "3", kind: .tool, tool: ToolCall(id: "t2", name: "write_file", context: "", running: false)),
            ChatItem(id: "4", kind: .assistant, text: "Here it is:\nMEDIA:/tmp/a b.png"),
            ChatItem(id: "5", kind: .error, text: "Rate limited"),
            ChatItem(id: "6", kind: .notice, text: "/model changed"),
        ]
        let md = ChatExport.markdown(title: "Charts", items: items)
        #expect(md.hasPrefix("# Charts\n\n_Exported "))
        #expect(md.contains("\n## You\n\nMake a chart\n\nAttached: `data.csv`\n"))
        #expect(md.contains("\n> - Used terminal: `python plot.py`\n> - Used write_file\n"))
        #expect(md.contains("\n## Hermes\n\nHere it is:\n\n\n[a b.png](/tmp/a%20b.png)\n"))
        #expect(md.contains("\n> Error: Rate limited\n"))
        #expect(!md.contains("/model changed"))
    }

    @Test func filenameIsASlug() {
        #expect(ChatExport.filename("Q3 Sales: Report!") == "q3-sales-report.md")
        #expect(ChatExport.filename("ação") == "a-o.md")
        #expect(ChatExport.filename("!!!") == "chat.md")
    }
}
