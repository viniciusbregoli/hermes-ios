import Foundation
import Testing
@testable import HermesKit

struct AttachmentTests {
    var image = Attachment(name: "photo.jpg", mime: "image/jpeg", data: Data([1, 2, 3]))
    var file = Attachment(name: "notes.txt", mime: "text/plain", data: Data("hi".utf8))

    @Test func imagesUploadAsBytesAndFilesAsDataURLs() {
        let (m1, p1) = image.request(session: "rt1")
        #expect(m1 == "image.attach_bytes")
        #expect(p1["content_base64"] == "AQID" && p1["filename"] == "photo.jpg" && p1["session_id"] == "rt1")
        let (m2, p2) = file.request(session: "rt1")
        #expect(m2 == "file.attach")
        #expect(p2["data_url"] == "data:text/plain;base64,aGk=" && p2["name"] == "notes.txt")
    }

    @Test func promptTextFollowsDesktopRules() {
        var file = file
        file.refText = "@file:.hermes/attachments/notes.txt"
        var other = file
        other.refText = "@file:`a b.pdf`"
        #expect(Attachment.promptText("Summarize", [file, other]) == "@file:.hermes/attachments/notes.txt\n@file:`a b.pdf`\n\nSummarize")
        #expect(Attachment.promptText("", [file]) == "@file:.hermes/attachments/notes.txt")
        #expect(Attachment.promptText("", [image]) == "What do you see in this image?")
        #expect(Attachment.promptText("Look", [image]) == "Look")
        #expect(Attachment.promptText("plain", []) == "plain")
    }

    @Test func parsesImageRefsOutOfUserRows() {
        // Live shape from a vision-tool model on the deployed gateway.
        let c = UserContent.parse("Describe this\n@image:/home/u/.hermes/images/upload_1.png\n[screenshot]")
        #expect(c == UserContent(text: "Describe this", images: ["/home/u/.hermes/images/upload_1.png"]))
        let quoted = UserContent.parse("Hi\n\n@image:`/tmp/my photo.png`")
        #expect(quoted.images == ["/tmp/my photo.png"] && quoted.text == "Hi")
        let hint = UserContent.parse("What do you see in this image?\n\n[Image attached at: /tmp/x.png]\n[image]")
        #expect(hint == UserContent(text: "", images: ["/tmp/x.png"]))
    }

    @Test func parsesFileRefsAndDropsAttachedContext() {
        let raw = "@file:.hermes/attachments/groceries.txt\n\nWhat is in it?\n\n--- Attached Context ---\n\n📄 @file:.hermes/attachments/groceries.txt (17 tokens)\n```\n- 3 apples\n```"
        #expect(UserContent.parse(raw) == UserContent(text: "What is in it?", files: [".hermes/attachments/groceries.txt"]))
        // An @file mention inside prose is the user's text, not an attachment.
        #expect(UserContent.parse("see @file:a.txt please").files.isEmpty)
    }

    @MainActor @Test func transcriptUserRowsCarryAttachments() {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        store.apply(snapshot: ["session_id": "rt1", "messages": [
            ["role": "user", "row_id": 1, "text": "@file:.hermes/attachments/a.pdf\n\nRead\n@image:/srv/i.png"],
        ]])
        #expect(store.items.first?.text == "Read")
        #expect(store.items.first?.images == [.path("/srv/i.png")])
        #expect(store.items.first?.files == ["a.pdf"])
    }
}
