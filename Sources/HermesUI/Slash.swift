import SwiftUI
import HermesKit

// Slash commands in the composer (HermesKit/Slash.swift runs them): live suggestions above the
// composer, the commands sheet, and the transcript rows their output lands in.

/// Suggestion state shared by the list, the composer's arrow keys and the commands button.
@MainActor @Observable
final class SlashMenu {
    var items: [SlashSuggestion] = []
    var selection = 0
    /// Esc hides the list until the draft changes.
    var dismissed: String?
    var showCatalog = false

    func isOpen(_ draft: String) -> Bool {
        !items.isEmpty && dismissed != draft && SlashCommand.completes(draft)
    }

    var selected: SlashSuggestion? { items.indices.contains(selection) ? items[selection] : items.first }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + step + items.count) % items.count
    }
}

/// Up to about eight suggestions above the composer while the draft is a command. Tap or Tab inserts
/// one; Return runs the typed command, or inserts the highlighted one when it is not what was typed.
struct SlashPicker: View {
    let store: ChatStore
    let menu: SlashMenu
    @Binding var draft: String
    let run: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if menu.isOpen(draft) {
                // Read here, not inside the reader's closure, or new suggestions don't redraw the rows.
                let items = menu.items, selection = menu.selection
                ScrollViewReader { proxy in
                    CappedScroll(maxHeight: 8 * 38) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                let row = Button { insert(item) } label: { SlashRow(item: item, selected: i == selection) }
                                    .buttonStyle(.plain)
                                if i == selection { row.keyboardShortcut(.tab, modifiers: []) } else { row }
                            }
                        }
                    }
                    .onChange(of: selection) { if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) } }
                }
                .background(Theme.background)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                Button("Close suggestions") { menu.dismissed = draft }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: draft) {
            // Debounced; a newer draft cancels this task, so a stale answer is dropped.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var rows: [SlashSuggestion] = []
            if SlashCommand.completes(draft), store.gateway.status == .online { rows = await store.slashSuggestions(draft) }
            guard !Task.isCancelled else { return }
            menu.items = rows
            menu.selection = 0
        }
        .onChange(of: draft) { old, new in
            // A multi-line field takes Return as a newline; on a command line it means run (or complete).
            guard new == old + "\n", SlashCommand.completes(old) else { return }
            let typed = old.trimmingCharacters(in: .whitespaces).lowercased()
            if menu.isOpen(old), let pick = menu.selected, pick.text.lowercased() != typed {
                insert(pick)
            } else {
                draft = old
                run(old)
            }
        }
    }

    private func insert(_ item: SlashSuggestion) {
        draft = item.text + " "
    }
}

private struct SlashRow: View {
    let item: SlashSuggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.label).font(Theme.mono).lineLimit(1).layoutPriority(1)
            if item.isSkill { SkillBadge() }
            Text(item.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(minHeight: 38)
        .background(selected ? Theme.primary.opacity(0.12) : .clear)
        .contentShape(Rectangle())
    }
}

private struct SkillBadge: View {
    var body: some View {
        Text("skill")
            .font(.caption2)
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(Theme.primary.opacity(0.5)))
    }
}

/// Arrow keys move the highlighted suggestion; apply it to the view that holds the composer.
struct SlashKeys: ViewModifier {
    let menu: SlashMenu
    let draft: String

    func body(content: Content) -> some View {
        content.onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard menu.isOpen(draft) else { return .ignored }
            menu.move(press.key == .upArrow ? -1 : 1)
            return .handled
        }
    }
}

// MARK: - Commands sheet

struct CommandsButton: View {
    let store: ChatStore
    @Binding var draft: String
    @Environment(SlashMenu.self) private var menu

    var body: some View {
        @Bindable var menu = menu
        Button { menu.showCatalog = true } label: { Image(systemName: "slash.circle") }
            .buttonStyle(Pill(active: false))
            .accessibilityLabel("Commands")
            .keyboardShortcut("k", modifiers: .command)
            .help("Commands (⌘K)")
            .sheet(isPresented: $menu.showCatalog) {
                CommandsSheet(store: store) { draft = $0 + " " }
            }
    }
}

/// The catalog grouped by category, searchable; picking an entry puts it in the composer.
struct CommandsSheet: View {
    let store: ChatStore
    let pick: (String) -> Void
    @State private var catalog: SlashCatalog?
    @State private var error: String?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(catalog?.filtered(query) ?? []) { section in
                    Section(section.name) {
                        ForEach(section.entries) { entry in
                            Button {
                                pick(entry.command)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.command).font(Theme.mono).foregroundStyle(Theme.foreground)
                                        if entry.isSkill { SkillBadge() }
                                    }
                                    if !entry.detail.isEmpty {
                                        Text(entry.detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                    .listRowBackground(Theme.sidebar)
                }
            }
            .themedList()
            .overlay {
                if let error {
                    ContentUnavailableView("Couldn't load commands", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if catalog == nil {
                    ProgressView()
                } else if catalog?.filtered(query).isEmpty == true {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search commands")
            .navigationTitle("Commands")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .task {
            do { catalog = try await store.slashCatalog() } catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Transcript rows

/// A command's output under a dim "/command" header, or a /btw or /bg card.
struct SlashNoteView: View {
    let item: ChatItem

    var body: some View {
        if let note = item.slash {
            if item.kind == .side { side(note) } else { output(note) }
        }
    }

    private func output(_ note: SlashNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.header).font(Theme.monoSmall).foregroundStyle(Theme.muted)
            if let warning = note.warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.muted)
            }
            if item.text.contains("\n") {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(item.text).font(Theme.mono).fixedSize(horizontal: true, vertical: false)
                }
            } else {
                // A one-line notice (usage hints, "Loop set...") wraps instead of running off the edge.
                Text(item.text).font(Theme.mono)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sidebar, in: RoundedRectangle(cornerRadius: Theme.radius))
        .contextMenu { Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(item.text) } }
    }

    private func side(_ note: SlashNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(note.background ? "Background task" : "Side question",
                  systemImage: note.background ? "clock.arrow.circlepath" : "bubble.left.and.text.bubble.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            if !note.header.isEmpty {
                Text(note.header).font(.callout).foregroundStyle(Theme.muted)
            }
            if note.pending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(note.background ? "Working…" : "Answering…").foregroundStyle(Theme.muted).shimmer(true)
                }
                .font(.footnote)
            } else {
                MarkdownView(text: item.text)
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(MarkdownView.plainText(item.text)) } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
}
