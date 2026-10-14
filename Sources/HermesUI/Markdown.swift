import SwiftUI
import HermesKit
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(UIKit)
import UIKit
import Photos
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension EnvironmentValues {
    /// Gateway credentials for fetching files the agent delivers.
    @Entry var credentials: Credentials?
    /// Shows an image full screen or downloads a file into QuickLook.
    @Entry var openMedia = OpenMedia { _ in }
}

struct OpenMedia {
    let action: @MainActor (URL) async -> Void
    @MainActor func callAsFunction(_ url: URL) async { await action(url) }
}

/// A full markdown reply: blocks, tables, code, callouts, images and delivered files.
struct MarkdownView: View {
    let text: String
    var streaming = false

    var body: some View {
        BlockView(node: Self.parse(streaming ? Markdown.stableStreamingText(text) : text))
            .foregroundStyle(Theme.foreground)
            // Opaque, so the long-press preview doesn't show the transcript through the text.
            .background(Theme.background)
            .modifier(MediaPresenter())
    }

    // Every delta re-renders the reply and the transcript recycles rows on scroll; each text parses once.
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()
    final class Box { let node: MarkdownNode; init(_ n: MarkdownNode) { node = n } }

    static func parse(_ text: String) -> MarkdownNode {
        if let hit = cache.object(forKey: text as NSString) { return hit.node }
        let node = Markdown.parse(text)
        cache.setObject(Box(node), forKey: text as NSString)
        return node
    }

    static func plainText(_ text: String) -> String { parse(text).plainText }
}

struct BlockView: View {
    let node: MarkdownNode

    var body: some View {
        switch node.kind {
        case .document:
            children(spacing: 10)
        case .paragraph:
            Text(Self.styled(node.text)).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level):
            Text(Self.styled(node.text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : level == 3 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 6 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language):
            CodeBlock(code: String(node.text.characters).trimmingCharacters(in: .newlines), language: language)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        case .list:
            children(spacing: 4)
        case .item(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal > 0 ? "\(ordinal)." : "•").monospacedDigit().foregroundStyle(Theme.muted)
                children(spacing: 4)
            }
        case .quote:
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(width: 3)
                children(spacing: 8).foregroundStyle(Theme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .alert(let type):
            Callout(type: type) { children(spacing: 6) }
        case .table:
            TableBlock(node: node)
        case .media:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(node.media, id: \.self) { MediaBlock(url: $0) }
            }
        case .headerRow, .row, .cell:
            EmptyView()
        }
    }

    private func children(spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { BlockView(node: $1) }
        }
    }

    /// Inline code gets a tinted background; bold, italics, strikethrough and links come from the parser.
    static func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            // A tint of the text color reads on every palette and inside bubbles; Matrix's sidebar is
            // almost its background.
            text[run.range].backgroundColor = Theme.foreground.opacity(0.14)
        }
        return text
    }
}

struct Callout<Content: View>: View {
    let type: String
    @ViewBuilder let content: Content

    var body: some View {
        let (icon, color): (String, Color) = switch type {
        case "TIP": ("lightbulb", Theme.success)
        case "WARNING": ("exclamationmark.triangle", Theme.destructive)
        case "CAUTION": ("exclamationmark.octagon", Theme.destructive)
        case "IMPORTANT": ("exclamationmark.bubble", Theme.primary)
        default: ("info.circle", Theme.primary)
        }
        VStack(alignment: .leading, spacing: 6) {
            Label(type.capitalized, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(Theme.monoSmall)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    resetCopied?.cancel()
                    resetCopied = Task {
                        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(Theme.mono).fixedSize().padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

struct TableBlock: View {
    let node: MarkdownNode

    var body: some View {
        let alignments: [PresentationIntent.TableColumn.Alignment] = if case .table(let a) = node.kind { a } else { [] }
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { r, row in
                    if r > 0 { Rectangle().fill(Theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        ForEach(Array(row.children.enumerated()), id: \.offset) { c, cell in
                            let align = c < alignments.count ? alignments[c] : .left
                            cellView(cell, header: row.kind == .headerRow, align: align)
                                .gridColumnAlignment(align == .right ? .trailing : align == .center ? .center : .leading)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .padding(1)
        }
    }

    private func cellView(_ cell: MarkdownNode, header: Bool, align: PresentationIntent.TableColumn.Alignment) -> some View {
        // ponytail: long cells wrap at a fixed width; measure columns if tables of prose look cramped.
        Text(BlockView.styled(cell.text))
            .font(header ? .subheadline.weight(.semibold) : .subheadline)
            .multilineTextAlignment(align == .right ? .trailing : align == .center ? .center : .leading)
            .frame(width: cell.text.characters.count > 32 ? 220 : nil, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(header ? Theme.sidebar : .clear)
    }
}

// MARK: - Media

/// An image (inline, tap to zoom) or a delivered file (card that opens in QuickLook).
struct MediaBlock: View {
    let url: URL
    @Environment(\.openMedia) private var openMedia
    @State private var opening = false

    var body: some View {
        if let path = Media.path(from: url), Media.kind(of: path) != .image {
            Button {
                Task { opening = true; await openMedia(url); opening = false }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: Self.icon(path)).font(.title3).foregroundStyle(Theme.primary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Media.name(of: path)).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(MediaLoader.size(of: url) ?? "Tap to open").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    if opening { ProgressView().controlSize(.small) }
                }
                .padding(10)
                .frame(maxWidth: 360, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            RemoteImage(url: url).onTapGesture { Task { await openMedia(url) } }
        }
    }

    static func icon(_ path: String) -> String {
        switch Media.kind(of: path) {
        case .video: return "film"
        case .audio: return "waveform"
        default:
            switch path.split(separator: ".").last?.lowercased() {
            case "pdf": return "doc.richtext"
            case "zip", "tar", "gz", "tgz", "7z", "rar": return "doc.zipper"
            case "csv", "tsv", "xlsx", "xls", "ods": return "tablecells"
            default: return "doc"
            }
        }
    }
}

struct RemoteImage: View {
    let url: URL
    @Environment(\.credentials) private var credentials
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(image.size.width, 480), maxHeight: 360, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    #if os(iOS)
                    .imageContextMenu(image)
                    #endif
            } else if failed {
                Label("Couldn't load \(Media.path(from: url).map(Media.name(of:)) ?? url.lastPathComponent)", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
            } else {
                RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.sidebar)
                    .frame(width: 220, height: 160)
                    .overlay { ProgressView() }
            }
        }
        .task(id: url) {
            image = MediaLoader.cachedImage(url)
            guard image == nil else { return }
            do { image = try await MediaLoader.image(url, credentials) } catch { failed = true }
        }
    }
}

enum MediaLoader {
    nonisolated(unsafe) static let images = NSCache<NSURL, PlatformImage>()
    @MainActor static var sizes: [URL: String] = [:]

    static func request(_ url: URL, _ credentials: Credentials?) throws -> URLRequest {
        guard let path = Media.path(from: url) else { return URLRequest(url: url) }
        guard let credentials else { throw URLError(.userAuthenticationRequired) }
        return Media.request(path: path, credentials: credentials)
    }

    static func cachedImage(_ url: URL) -> PlatformImage? { images.object(forKey: url as NSURL) }

    static func image(_ url: URL, _ credentials: Credentials?) async throws -> PlatformImage {
        let (data, resp) = try await Media.session.data(for: try request(url, credentials))
        guard (resp as? HTTPURLResponse)?.statusCode ?? 200 < 300, let image = PlatformImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        images.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Downloads into a temp folder under the file's own name, so QuickLook and Share show it.
    @MainActor static func file(_ url: URL, _ credentials: Credentials?) async throws -> URL {
        let path = Media.path(from: url) ?? url.path
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "hermes-media/\(String(UInt(bitPattern: url.absoluteString.hashValue), radix: 36))")
        let dest = dir.appending(path: Media.name(of: path))
        if !FileManager.default.fileExists(atPath: dest.path) {
            let (tmp, resp) = try await Media.session.download(for: try request(url, credentials))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            guard status < 300 else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The server answered \(status)."]) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        if let bytes = try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64 {
            sizes[url] = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return dest
    }

    @MainActor static func size(of url: URL) -> String? { sizes[url] }
}

/// Opens media links from anywhere in a reply: images full screen, files in QuickLook.
struct MediaPresenter: ViewModifier {
    @Environment(\.credentials) private var credentials
    @State private var zoomed: ZoomTarget?
    @State private var file: URL?
    @State private var error: String?

    struct ZoomTarget: Identifiable { let url: URL; var id: URL { url } }

    func body(content: Content) -> some View {
        content
            .environment(\.openMedia, OpenMedia(action: open))
            .environment(\.openURL, OpenURLAction { url in
                guard Media.path(from: url) != nil else { return .systemAction }
                Task { await open(url) }
                return .handled
            })
            .coverOrSheet(item: $zoomed) { ImageViewer(url: $0.url) }
            #if canImport(QuickLook)
            .quickLookPreview($file)
            #endif
            .alert("Couldn't open the file", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    @MainActor private func open(_ url: URL) async {
        let path = Media.path(from: url)
        if path == nil || Media.kind(of: path!) == .image {
            zoomed = ZoomTarget(url: url)
            return
        }
        do { file = try await MediaLoader.file(url, credentials) } catch { self.error = error.localizedDescription }
    }
}

struct ImageViewer: View {
    let url: URL
    @Environment(\.credentials) private var credentials
    @Environment(\.dismiss) private var dismiss
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            if let image {
                #if os(iOS)
                ZoomableImage(image: image).ignoresSafeArea()
                #else
                Image(platformImage: image).resizable().scaledToFit()
                #endif
            } else if failed {
                Label("Couldn't load the image", systemImage: "photo").foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                    .background(Theme.sidebar.opacity(0.85), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding()
        }
        #if os(iOS)
        .overlay(alignment: .bottom) { if let image { ImageActionsBar(image: image) } }
        #endif
        .task {
            image = MediaLoader.cachedImage(url)
            if image == nil { do { image = try await MediaLoader.image(url, credentials) } catch { failed = true } }
        }
    }
}

#if os(iOS)
/// UIScrollView gives pinch zoom with panning and bounce for free; double tap toggles 1x / 3x.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.delegate = context.coordinator
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.view = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var view: UIView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll = g.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: view)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
#endif

#if os(iOS)
enum ImageExport {
    static func copy(_ image: UIImage) { UIPasteboard.general.image = image }

    /// Returns nil when saved, otherwise a message for the user. Add-only access is enough and
    /// never shows the rest of the library to the app.
    static func saveToPhotos(_ image: UIImage) async -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return "Allow Hermes to add photos in Settings > Privacy & Security > Photos."
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Copy and Save to Photos for a full-screen image, with ⌘C / ⌘S.
struct ImageActionsBar: View {
    let image: UIImage
    @State private var note: String?
    @State private var hideNote: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            Button { ImageExport.copy(image); show(nil, success: "Copied") } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            Button { Task { show(await ImageExport.saveToPhotos(image), success: "Saved to Photos") } } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .font(.callout.weight(.medium))
        .buttonStyle(.bordered)
        .tint(Theme.foreground)
        .padding(8)
        .background(Theme.sidebar.opacity(0.85), in: Capsule())
        .overlay(alignment: .top) {
            if let note {
                Text(note).font(.caption).foregroundStyle(Theme.foreground)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.sidebar, in: Capsule())
                    .offset(y: -40)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 24)
    }

    private func show(_ failure: String?, success: String) {
        withAnimation { note = failure ?? success }
        UINotificationFeedbackGenerator().notificationOccurred(failure == nil ? .success : .error)
        // A newer note restarts the clock instead of being cleared by the older one's.
        hideNote?.cancel()
        hideNote = Task {
            do { try await Task.sleep(for: .seconds(failure == nil ? 1.5 : 4)) } catch { return }
            withAnimation { note = nil }
        }
    }
}

/// Long-press Copy Image / Save to Photos on an inline image.
struct ImageContextMenu: ViewModifier {
    let image: UIImage
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { ImageExport.copy(image) } label: { Label("Copy Image", systemImage: "doc.on.doc") }
                Button { Task { error = await ImageExport.saveToPhotos(image) } } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
            }
            .alert("Couldn't save the image", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }
}

extension View {
    func imageContextMenu(_ image: UIImage) -> some View { modifier(ImageContextMenu(image: image)) }
}
#endif

// MARK: - Platform helpers

enum Clipboard {
    static func copy(_ s: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    @ViewBuilder
    func coverOrSheet<Item: Identifiable, V: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> V) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}
