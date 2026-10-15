import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

@MainActor
struct QueuedAttachmentTests {
    @Test func queuedMessagesKeepTheirAttachments() {
        let gateway = Gateway(credentials: nil)
        let store = ChatStore(gateway: gateway)
        store.apply(snapshot: ["session_id": "rt1", "running": true, "messages": [],
                               "queued": ["user": "Look\n@image:/srv/q.png"]])
        #expect(store.queued.first?.text == "Look" && store.queued.first?.images == [.path("/srv/q.png")])

        store.placeSubmitted(ChatItem(id: "q2", kind: .user, images: [.data(Data([1]))]), status: "queued")
        gateway.dispatch(GatewayEvent(type: "message.start", sessionId: "rt1", payload: nil))
        #expect(store.items.last?.images == [.path("/srv/q.png")])
        #expect(store.queued.map(\.id) == ["q2"])
    }
}

@MainActor
struct PastedImageTests {
    /// A flat-colour PNG; `alpha` makes the left half transparent.
    static func png(width: Int = 64, height: Int = 32, alpha: Bool) -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func transparentPNGStaysPNG() async throws {
        let a = try #require(await Attachment.pasted(Self.png(alpha: true), index: 2))
        #expect(a.name == "pasted-2.png" && a.mime == "image/png" && a.isImage)
        #expect(ImageFile.hasAlpha(a.data))
    }

    @Test func opaqueImageBecomesJPEG() async throws {
        let a = try #require(await Attachment.pasted(Self.png(alpha: false), index: 1))
        #expect(a.name == "pasted-1.jpg" && a.mime == "image/jpeg")
        #expect(a.data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func bigImagesAreCappedAt2048() async throws {
        let a = try #require(await Attachment.pasted(Self.png(width: 4096, height: 1024, alpha: true), index: 1))
        let image = try #require(ImageFile.cgImage(a.data, maxPixel: 10_000))
        #expect(max(image.width, image.height) == 2048)
    }

    @Test func nonImageDataIsRejected() async {
        #expect(await Attachment.pasted(Data("hello".utf8), index: 1) == nil)
    }

    @Test func pastingSeveralImagesStagesOneChipEach() async {
        let store = ChatStore(gateway: Gateway(credentials: nil))
        await store.attachPasted([Self.png(alpha: true), Self.png(alpha: false), Data([1])])
        #expect(store.attachments.map(\.name) == ["pasted-1.png", "pasted-2.jpg"])
        #expect(store.alert != nil)
    }
}
