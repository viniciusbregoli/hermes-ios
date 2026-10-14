import SwiftUI
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

    func body(content: Content) -> some View {
        let pinned = store.pinned.contains(session.id)
        content
            .swipeActions(edge: .leading) {
                Button { pin(!pinned) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
                    .tint(Theme.primary)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
                Button { archive() } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(Theme.muted)
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { renaming = session }
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") { pin(!pinned) }
                Button("Archive", systemImage: "archivebox") { archive() }
                Button("Delete", systemImage: "trash", role: .destructive) { delete() }
            }
    }

    private func pin(_ on: Bool) { Task { await store.setPinned(session.id, on) } }
    private func archive() { Task { await store.setArchived(session.id, true) } }
    private func delete() { Task { await store.delete(session.id) } }
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
                    Button(role: .destructive) { delete(s.id) } label: { Label("Delete", systemImage: "trash") }
                }
                .contextMenu {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { unarchive(s.id) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(s.id) }
                }
            }
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
        Task { await store.delete(id) }
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
