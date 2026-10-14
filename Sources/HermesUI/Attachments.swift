import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import HermesKit

// MARK: - Picking

/// Paperclip menu in the composer: photo library, camera (when the device has one) and files.
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
        } label: {
            Image(systemName: "paperclip")
                .frame(width: 34, height: 34)
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

#if os(iOS)
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

/// ImageIO decoding: reads HEIC/PNG/JPEG alike, applies EXIF orientation and never decodes the
/// full-size bitmap, which keeps a 48 MP photo from spiking memory.
enum ImageFile {
    static func cgImage(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// About 2048 px on the long edge, as JPEG: plenty for vision models and a few hundred KB to upload.
    static func jpeg(_ data: Data, maxPixel: Int = 2048) async -> Data? {
        await Task.detached {
            guard let image = cgImage(data, maxPixel: maxPixel) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }.value
    }
}

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
