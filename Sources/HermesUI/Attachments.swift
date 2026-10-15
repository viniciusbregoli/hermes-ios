import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import HermesKit

// MARK: - Picking

/// Paperclip menu in the composer: photo library, camera (when the device has one), files and a pasted image.
struct AttachButton: View {
    let store: ChatStore
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var pickingFiles = false
    @State private var shooting = false

    var body: some View {
        Menu {
            Button { pickingPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { shooting = true } label: { Label("Camera", systemImage: "camera") }
            }
            #endif
            Button { pickingFiles = true } label: { Label("Files", systemImage: "folder") }
            #if os(iOS)
            // PasteButton reads the pasteboard without the system's paste prompt and disables itself when there is no image.
            PasteButton(supportedContentTypes: [.image]) { providers in
                Task { await store.attachPasted(await PasteboardImages.load(providers)) }
            }
            #endif
        } label: {
            Image(systemName: "paperclip")
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 10, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                for (i, item) in items.enumerated() {
                    // Loads the original bytes (HEIC included); ImageIO reads every format the library holds.
                    var jpeg: Data?
                    if let original = try? await item.loadTransferable(type: Data.self) { jpeg = await ImageFile.jpeg(original) }
                    add(jpeg, name: "photo-\(i + 1).jpg")
                }
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for url in urls { await addFile(url) } }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $shooting) {
            CameraPicker { photo in
                shooting = false
                guard let data = photo?.jpegData(compressionQuality: 0.9) else { return }
                Task { add(await ImageFile.jpeg(data), name: "camera.jpg") }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func add(_ jpeg: Data?, name: String) {
        guard let jpeg else { store.alert = "Couldn't read \(name)."; return }
        store.attach(Attachment(name: name, mime: "image/jpeg", data: jpeg))
    }

    private func addFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { store.alert = "Couldn't read \(url.lastPathComponent)."; return }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let jpeg = await ImageFile.jpeg(data) {
            add(jpeg, name: url.deletingPathExtension().lastPathComponent + ".jpg")
        } else {
            store.attach(Attachment(name: url.lastPathComponent, mime: type?.preferredMIMEType ?? "application/octet-stream", data: data))
        }
    }
}

extension View {
    /// Lets Paste in this text field stage images through `onImages`; plain text paste is unchanged.
    @ViewBuilder func pastesImages(_ onImages: (([Data]) -> Void)?) -> some View {
        #if os(iOS)
        if let onImages { background(ImagePasteHook(onImages: onImages)) } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Images on the system pasteboard, as the original bytes so PNG transparency survives to `Attachment.pasted`.
enum PasteboardImages {
    static func load(_ providers: [NSItemProvider] = UIPasteboard.general.itemProviders) async -> [Data] {
        var out: [Data] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data = await withCheckedContinuation { c in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in c.resume(returning: data) }
            }
            if let data { out.append(data) }
        }
        return out
    }
}

/// SwiftUI's TextField never offers Paste for an image (UITextView only enables it for text), and the
/// view is private, so this finds the text input under the modified view and gives it a subclass that does.
/// `onImages` runs for both the edit menu's Paste and a hardware Cmd+V; text paste is left to UIKit.
private struct ImagePasteHook: UIViewRepresentable {
    let onImages: ([Data]) -> Void

    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) { view.onImages = onImages; view.setNeedsLayout() }

    final class Finder: UIView {
        var onImages: (([Data]) -> Void)?
        private weak var target: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            if target == nil || target?.window == nil { target = textInput() }
            guard let target else { return }
            PasteHook.install(on: target) { [weak self] in self?.onImages?($0) }
        }

        /// The text input whose frame overlaps this one most; the TextField is what this view is the background of.
        private func textInput() -> UIView? {
            guard window != nil else { return nil }
            let mine = convert(bounds, to: nil)
            var best: (view: UIView, area: CGFloat)?
            var root: UIView? = self
            for _ in 0..<5 {
                root = root?.superview
                guard let root else { break }
                for candidate in Self.inputs(in: root) {
                    let hit = candidate.convert(candidate.bounds, to: nil).intersection(mine)
                    let area = hit.isNull ? 0 : hit.width * hit.height
                    if area > (best?.area ?? 0) { best = (candidate, area) }
                }
                if best != nil { break }
            }
            return best?.view
        }

        private static func inputs(in view: UIView) -> [UIView] {
            (view is UITextView || view is UITextField ? [view] : []) + view.subviews.flatMap(inputs(in:))
        }
    }
}

/// Swaps a text input's class for a dynamic subclass (what KVO does) that accepts Paste when the
/// pasteboard holds an image, and hands the images to the handler instead of pasting.
private enum PasteHook {
    private final class Box { var handler: ([Data]) -> Void; init(_ h: @escaping ([Data]) -> Void) { handler = h } }
    nonisolated(unsafe) private static var key = 0

    static func install(on view: UIView, handler: @escaping ([Data]) -> Void) {
        if let box = objc_getAssociatedObject(view, &key) as? Box { box.handler = handler; return }
        objc_setAssociatedObject(view, &key, Box(handler), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let base: AnyClass = type(of: view)
        let name = "HermesPaste_" + NSStringFromClass(base)
        object_setClass(view, NSClassFromString(name) ?? subclass(of: base, named: name))
    }

    private static func subclass(of base: AnyClass, named name: String) -> AnyClass {
        let sub = objc_allocateClassPair(base, name, 0)!
        let canSel = #selector(UIResponder.canPerformAction(_:withSender:))
        let pasteSel = #selector(UIResponder.paste(_:))
        typealias CanFn = @convention(c) (AnyObject, Selector, Selector, Any?) -> Bool
        typealias PasteFn = @convention(c) (AnyObject, Selector, Any?) -> Void
        let canSuper = unsafeBitCast(class_getMethodImplementation(base, canSel), to: CanFn.self)
        let pasteSuper = unsafeBitCast(class_getMethodImplementation(base, pasteSel), to: PasteFn.self)

        let can: @convention(block) (AnyObject, Selector, Any?) -> Bool = { me, action, sender in
            if action == pasteSel, objc_getAssociatedObject(me, &key) != nil, UIPasteboard.general.hasImages { return true }
            return canSuper(me, canSel, action, sender)
        }
        let paste: @convention(block) (AnyObject, Any?) -> Void = { me, sender in
            guard let box = objc_getAssociatedObject(me, &key) as? Box, UIPasteboard.general.hasImages else {
                return pasteSuper(me, pasteSel, sender)
            }
            Task { @MainActor in
                let images = await PasteboardImages.load()
                if !images.isEmpty { box.handler(images) }
            }
        }
        class_addMethod(sub, canSel, imp_implementationWithBlock(can), method_getTypeEncoding(class_getInstanceMethod(base, canSel)!))
        class_addMethod(sub, pasteSel, imp_implementationWithBlock(paste), method_getTypeEncoding(class_getInstanceMethod(base, pasteSel)!))
        objc_registerClassPair(sub)
        return sub
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
#endif

// MARK: - Composer chips

struct AttachmentChips: View {
    let store: ChatStore

    var body: some View {
        if !store.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.attachments) { a in
                        Chip(attachment: a) { store.retryAttachment(a.id) } remove: { Task { await store.removeAttachment(a.id) } }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
        }
    }

    struct Chip: View {
        let attachment: Attachment
        let retry: () -> Void
        let remove: () -> Void

        private var failure: String? { if case .failed(let m) = attachment.state { return m }; return nil }

        var body: some View {
            Group {
                if attachment.isImage {
                    Thumbnail(source: .data(attachment.data), size: 56)
                } else {
                    FileLabel(name: attachment.name).frame(height: 56)
                }
            }
            .overlay {
                if attachment.state == .uploading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background.opacity(0.5))
                } else if failure != nil {
                    Button(action: retry) {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                            .font(.title3)
                            .foregroundStyle(Theme.destructive)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.background.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry \(attachment.name): \(failure ?? "")")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(failure == nil ? Theme.border : Theme.destructive))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.background, Theme.foreground)
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(attachment.name)")
            }
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
    }
}

struct FileLabel: View {
    let name: String

    var body: some View {
        Label(name, systemImage: name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc")
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

// MARK: - User bubble

/// Thumbnails and file chips above a user message; tapping an image opens it full screen.
struct MessageAttachments: View {
    let item: ChatItem
    @State private var zoomed: ImageSource?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !item.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.images.enumerated()), id: \.offset) { _, source in
                        Button { zoomed = source } label: { Thumbnail(source: source, size: 120) }
                            .buttonStyle(.plain)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            .accessibilityLabel("Attached image")
                    }
                }
            }
            ForEach(item.files, id: \.self) { FileLabel(name: $0) }
        }
        #if os(iOS)
        .fullScreenCover(item: $zoomed) { AttachmentViewer(source: $0) }
        #else
        .sheet(item: $zoomed) { AttachmentViewer(source: $0) }
        #endif
    }
}

extension ImageSource: Identifiable {
    public var id: Self { self }
}

struct AttachmentViewer: View {
    let source: ImageSource
    @Environment(Gateway.self) private var gateway
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                #if os(iOS)
                ZoomableImage(image: UIImage(cgImage: image)).ignoresSafeArea()
                #else
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                #endif
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
            }
            .padding()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        #if os(iOS)
        .overlay(alignment: .bottom) { if let image { ImageActionsBar(image: UIImage(cgImage: image)) } }
        #endif
        .task { image = try? await Thumbnail.load(source, gateway, maxPixel: 4096) }
    }
}

/// A square thumbnail of an image from bytes we hold or from the gateway's disk.
struct Thumbnail: View {
    let source: ImageSource
    let size: CGFloat
    @Environment(Gateway.self) private var gateway
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Theme.muted)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.sidebar)
        .clipped()
        .task(id: source) {
            // 3x covers the densest screens.
            image = try? await Self.load(source, gateway, maxPixel: Int(size * 3))
            failed = image == nil
        }
    }

    static func load(_ source: ImageSource, _ gateway: Gateway, maxPixel: Int) async throws -> CGImage? {
        let data: Data
        switch source {
        case .data(let d): data = d
        case .path(let p):
            if let hit = cache.object(forKey: p as NSString) {
                data = hit as Data
            } else {
                data = try await gateway.download(path: p)
                cache.setObject(data as NSData, forKey: p as NSString, cost: data.count)
            }
        }
        return await Task.detached { ImageFile.cgImage(data, maxPixel: maxPixel) }.value
    }

    /// Downloaded bytes by gateway path, so scrolling back and opening full screen don't refetch.
    nonisolated(unsafe) static let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 64 << 20
        return c
    }()
}
