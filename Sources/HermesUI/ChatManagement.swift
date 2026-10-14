import SwiftUI
import UniformTypeIdentifiers
import HermesKit

// Chat list management (search, pins, archive, rename) and the per-message actions of a chat.

// MARK: - Row actions

extension View {
    /// Pin, archive, rename and delete on a chat row: swipes plus a long-press menu.
    func sessionActions(_ store: ChatStore, _ session: SessionRow, renaming: Binding<SessionRow?>) -> some View {
        modifier(SessionActions(store: store, session: session, renaming: renaming))
    }

    /// Asks for a new title for `session` while it is set.
    func renameAlert(_ store: ChatStore, _ session: Binding<SessionRow?>) -> some View {
        modifier(RenameAlert(store: store, session: session))
    }
}

struct SessionActions: ViewModifier {
    let store: ChatStore
    let session: SessionRow
    @Binding var renaming: SessionRow?
    @State private var deleting: SessionRow?

    func body(content: Content) -> some View {
        let pinned = store.pinned.contains(session.id)
        content
            .swipeActions(edge: .leading) {
                Button { pin(!pinned) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
                    .tint(Theme.primary)
            }
            .swipeActions(edge: .trailing) {
                Button { deleting = session } label: { Label("Delete", systemImage: "trash") }
                    .tint(Theme.destructive)
                Button { archive() } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(Theme.muted)
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renaming = session }
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { pin(!pinned) }
                Button("Archive", systemImage: "archivebox") { archive() }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
            }
            .confirmDelete($deleting) { id in Task { await store.delete(id) } }
    }

    private func pin(_ on: Bool) { Task { await store.setPinned(session.id, on) } }
    private func archive() { Task { await store.setArchived(session.id, true) } }
}

extension View {
    /// Asks before deleting `chat` while it is set; Cancel leaves the chat alone.
    func confirmDelete(_ chat: Binding<SessionRow?>, delete: @escaping (String) -> Void) -> some View {
        confirmationDialog("Delete \"\(chat.wrappedValue?.title.nonEmpty ?? "Untitled")\"?",
                           isPresented: Binding(get: { chat.wrappedValue != nil }, set: { if !$0 { chat.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: chat.wrappedValue) { row in
            Button("Delete", role: .destructive) { delete(row.id) }
        } message: { _ in
            Text("The chat and its messages are deleted from your Hermes server.")
        }
    }

    /// Shows a failure of `store` (a delete that was refused) from inside a sheet, where the root's alert can't appear.
    func storeAlert(_ store: ChatStore) -> some View {
        alert("Hermes", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
    }
}

struct RenameAlert: ViewModifier {
    let store: ChatStore
    @Binding var session: SessionRow?
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } })) {
                TextField("Title", text: $title)
                Button("Rename") {
                    if let id = session?.id { Task { await store.rename(id, to: title) } }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: session) { title = session?.title ?? "" }
    }
}

// MARK: - Search

/// The last full-text search and what it found.
struct SearchState {
    var hits: [SearchHit] = []
    /// The query `hits` answer, so "no results" isn't shown for one still being fetched.
    var searched = ""
    var error: String?
}

extension View {
    /// Runs the full-text search for `query` after a short pause in typing.
    func searchFetch(_ store: ChatStore, _ query: String, into state: Binding<SearchState>) -> some View {
        task(id: query) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let hits = try await store.search(query)
                if !Task.isCancelled { state.wrappedValue = SearchState(hits: hits, searched: query) }
            } catch {
                if !Task.isCancelled { state.wrappedValue.error = error.localizedDescription }
            }
        }
    }
}

struct SearchResults<Row: View>: View {
    let state: SearchState
    let query: String
    @ViewBuilder let row: (SearchHit) -> Row

    var body: some View {
        Section {
            ForEach(state.hits) { row($0) }
        } footer: {
            if let error = state.error {
                Text(error)
            } else if state.searched == query, state.hits.isEmpty {
                Text("No chats match \"\(query)\".")
            }
        }
        .listRowBackground(Theme.sidebar)
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.title.nonEmpty ?? "Untitled")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let date = hit.date {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
            Text(snippet)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var snippet: AttributedString {
        hit.runs.reduce(into: AttributedString()) { out, run in
            var part = AttributedString(run.text.replacingOccurrences(of: "\n", with: " "))
            if run.match {
                part.foregroundColor = Theme.foreground
                part.font = Font.caption.weight(.semibold)
            }
            out += part
        }
    }
}

// MARK: - Archived chats

/// Chats taken out of the list; swipe to bring one back or delete it, tap to read it.
struct ArchivedChats: View {
    let store: ChatStore
    let open: (String) -> Void
    @State private var rows: [SessionRow]?
    @State private var error: String?
    @State private var deleting: SessionRow?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(rows ?? []) { s in
                Button {
                    dismiss()
                    open(s.id)
                } label: {
                    SessionRowView(session: s).foregroundStyle(Theme.foreground)
                }
                .listRowBackground(Theme.sidebar)
                .swipeActions(edge: .leading) {
                    Button { unarchive(s.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                        .tint(Theme.primary)
                }
                .swipeActions(edge: .trailing) {
                    Button { deleting = s } label: { Label("Delete", systemImage: "trash") }
                        .tint(Theme.destructive)
                }
                .contextMenu {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive(s.id) }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = s }
                }
            }
            .confirmDelete($deleting) { delete($0) }
            .storeAlert(store)
            .overlay {
                if let error {
                    ContentUnavailableView("Couldn't load archived chats", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if rows == nil {
                    ProgressView()
                } else if rows?.isEmpty == true {
                    ContentUnavailableView("No archived chats", systemImage: "archivebox")
                }
            }
            .themedList()
            .navigationTitle("Archived")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        do {
            rows = try await store.archivedSessions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func unarchive(_ id: String) {
        rows?.removeAll { $0.id == id }
        Task { await store.setArchived(id, false) }
    }

    private func delete(_ id: String) {
        rows?.removeAll { $0.id == id }
        Task {
            if await !store.delete(id) { await load() }
        }
    }
}

/// The last row of a chat list, opening the archived chats.
struct ArchivedEntry: View {
    @Binding var shown: Bool

    var body: some View {
        Button { shown = true } label: {
            Label("Archived", systemImage: "archivebox").foregroundStyle(Theme.muted)
        }
        .listRowBackground(Theme.sidebar)
    }
}

// MARK: - Message actions

/// An extra entry in a message's long-press menu.
struct MessageAction: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let run: () -> Void
}

/// Above the composer while a sent message is being edited; Esc or the cross puts the old draft back.
struct EditBanner: View {
    var detail = "Sending replaces this message and everything after it."
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Editing").font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel editing")
            .help("Cancel editing (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

// MARK: - Export

/// The chat's toolbar menu: Export shares the conversation as a Markdown file.
struct ChatMenu: View {
    let store: ChatStore
    var assistant = "Hermes"

    var body: some View {
        Menu {
            ShareLink(item: ChatExportFile(title: store.title, items: store.items, assistant: assistant),
                      preview: SharePreview(store.title)) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(store.items.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Chat actions")
    }
}

/// Built when the share sheet asks for it, so the transcript isn't rendered on every redraw.
struct ChatExportFile: Transferable {
    let title: String
    let items: [ChatItem]
    let assistant: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdownText) { doc in
            let dir = FileManager.default.temporaryDirectory.appending(path: "hermes-export/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: ChatExport.filename(doc.title))
            try ChatExport.markdown(title: doc.title, items: doc.items, assistant: doc.assistant).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}
