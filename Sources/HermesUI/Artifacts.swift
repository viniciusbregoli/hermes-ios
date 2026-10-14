import SwiftUI
import HermesKit

/// Every image and file the agent produced in the recent chats, like the desktop's Artifacts page.
struct ArtifactsView: View {
    let gateway: Gateway
    /// Opens a source chat; the presenter decides how (select it in the list, switch tabs).
    let openChat: (String) -> Void
    @State private var store: ArtifactStore
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", images = "Images", files = "Files"
        var id: Self { self }
    }

    init(gateway: Gateway, openChat: @escaping (String) -> Void) {
        self.gateway = gateway
        self.openChat = openChat
        _store = State(initialValue: ArtifactStore(gateway: gateway))
    }

    var body: some View {
        let images = filter == .files ? [] : store.items.filter { $0.kind == .image }
        let files = filter == .images ? [] : store.items.filter { $0.kind == .file }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if !images.isEmpty {
                    if filter == .all { header("Images", images.count) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], alignment: .leading, spacing: 14) {
                        ForEach(images) { ArtifactImageCell(artifact: $0, openChat: openChat) }
                    }
                }
                if !files.isEmpty {
                    if filter == .all { header("Files", files.count) }
                    LazyVStack(spacing: 0) {
                        ForEach(files) { a in
                            ArtifactFileRow(artifact: a, openChat: openChat)
                            if a.id != files.last?.id { Divider().overlay(Theme.border) }
                        }
                    }
                }
                if store.skipped > 0 {
                    Text("\(store.skipped) chat\(store.skipped == 1 ? "" : "s") couldn't be read.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding()
        }
        .overlay {
            if images.isEmpty, files.isEmpty {
                if store.loading {
                    ProgressView("Scanning recent chats…")
                } else if let error = store.error {
                    ContentUnavailableView("Couldn't load artifacts", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ContentUnavailableView("No \(filter == .all ? "artifacts" : filter.rawValue.lowercased()) yet",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text("Images and files Hermes makes in your recent chats show up here."))
                }
            }
        }
        .background(Theme.background)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .navigationTitle("Artifacts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Rescan (⌘R)")
                }
            }
        }
        .modifier(MediaPresenter())
        .environment(\.credentials, gateway.credentials)
    }

    private func header(_ title: String, _ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text("\(count)").font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

/// "Chat title · date" under an artifact.
private struct ArtifactSource: View {
    let artifact: Artifact

    var body: some View {
        Text("\(artifact.sessionTitle) · \(artifact.date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
    }
}

private struct ArtifactMenu: ViewModifier {
    let artifact: Artifact
    let openChat: (String) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open chat", systemImage: "bubble.left") { openChat(artifact.sessionId) }
            Button(artifact.isWeb ? "Copy link" : "Copy path", systemImage: "doc.on.doc") { Clipboard.copy(artifact.value) }
        }
    }
}

struct ArtifactImageCell: View {
    let artifact: Artifact
    let openChat: (String) -> Void
    @Environment(\.openMedia) private var openMedia
    @Environment(\.credentials) private var credentials
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Button {
            if let url = artifact.url { Task { await openMedia(url) } }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Theme.sidebar
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(platformImage: image).resizable().scaledToFill()
                        } else if failed {
                            Image(systemName: "photo").foregroundStyle(Theme.muted)
                        } else {
                            ProgressView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                Text(artifact.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                ArtifactSource(artifact: artifact)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ArtifactMenu(artifact: artifact, openChat: openChat))
        .task(id: artifact.value) {
            guard let url = artifact.url else { failed = true; return }
            image = MediaLoader.cachedImage(url)
            guard image == nil else { return }
            do { image = try await MediaLoader.image(url, credentials) } catch { failed = true }
        }
    }
}

struct ArtifactFileRow: View {
    let artifact: Artifact
    let openChat: (String) -> Void
    @Environment(\.openMedia) private var openMedia
    @Environment(\.openURL) private var openURL
    @State private var opening = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let url = artifact.url else { return }
                // A web file opens in the browser; a gateway file downloads into QuickLook.
                if artifact.isWeb { openURL(url); return }
                Task { opening = true; await openMedia(url); opening = false }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: MediaBlock.icon(artifact.name)).font(.title3).foregroundStyle(Theme.primary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artifact.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        ArtifactSource(artifact: artifact)
                    }
                    Spacer(minLength: 4)
                    if opening { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { openChat(artifact.sessionId) } label: {
                Image(systemName: "bubble.left").frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("Open chat")
        }
        .padding(.vertical, 8)
        .modifier(ArtifactMenu(artifact: artifact, openChat: openChat))
    }
}
