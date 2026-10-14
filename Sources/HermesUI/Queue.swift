import SwiftUI
import HermesKit

// The follow-up queue and steering, after T3 Code's ThreadQueueControl and the desktop's queue panel.

/// "2 queued" next to the working capsule; opens the queue.
struct QueueChip: View {
    let store: ChatStore
    let edit: (QueuedMessage) -> Void
    @State private var open = false

    var body: some View {
        if store.queuedCount > 0 {
            Button { open = true } label: {
                Label("\(store.queuedCount) queued", systemImage: store.queuePaused ? "pause.circle" : "list.number")
                    .font(.footnote)
                    .foregroundStyle(store.queuePaused ? Theme.muted : Theme.foreground)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Theme.sidebar, in: Capsule())
                    .overlay(Capsule().stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .keyboardShortcut("q", modifiers: [.command, .shift])
            .help("Queue (⇧⌘Q)")
            .sheet(isPresented: $open) {
                QueueSheet(store: store) { m in
                    open = false
                    edit(m)
                }
            }
        }
    }
}

struct QueueSheet: View {
    let store: ChatStore
    let edit: (QueuedMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !store.queue.isEmpty {
                    Section {
                        ForEach(Array(store.queue.enumerated()), id: \.element.id) { i, m in
                            row(m, at: i)
                        }
                    } header: {
                        Text(store.queuePaused ? "Paused after Stop" : "Sends when the turn ends")
                    } footer: {
                        Text("Tap to edit. Swipe left to remove\(store.running ? ", right to steer the running turn" : "").")
                    }
                    .listRowBackground(Theme.sidebar)
                }
                if !store.queued.isEmpty {
                    Section {
                        ForEach(store.queued) { item in
                            Label(item.text.nonEmpty ?? "Attachments", systemImage: "paperclip").lineLimit(4)
                        }
                    } header: {
                        Text("Queued on the server")
                    } footer: {
                        Text("Messages with attachments wait on the server, run first, and can't be changed from here.")
                    }
                    .listRowBackground(Theme.sidebar)
                }
            }
            .font(.callout)
            .themedList()
            .overlay {
                if store.queuedCount == 0 { Text("Nothing queued.").foregroundStyle(Theme.muted) }
            }
            .navigationTitle("Queue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if store.queuePaused, !store.running, !store.queue.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Resume") {
                            store.resumeQueue()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ m: QueuedMessage, at i: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(i + 1)").monospacedDigit().foregroundStyle(Theme.muted)
            Text(m.shown).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Menu { actions(m, at: i) } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 28, height: 24)
            }
            .accessibilityLabel("Actions")
        }
        .contentShape(Rectangle())
        .onTapGesture { if m.editable { edit(m) } }
        .contextMenu { actions(m, at: i) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.removeQueued(m.id) } label: { Label("Remove", systemImage: "trash") }
                .tint(Theme.destructive)
        }
        .swipeActions(edge: .leading) {
            if canSteer(m) {
                Button { steer(m, redirect: false) } label: { Label("Steer", systemImage: "arrow.turn.left.up") }
                    .tint(Theme.primary)
            }
        }
    }

    @ViewBuilder private func actions(_ m: QueuedMessage, at i: Int) -> some View {
        if m.editable { Button("Edit", systemImage: "pencil") { edit(m) } }
        if canSteer(m) {
            Button("Steer now", systemImage: "arrow.turn.left.up") { steer(m, redirect: false) }
            Button("Redirect", systemImage: "arrow.uturn.backward") { steer(m, redirect: true) }
        }
        if i > 0 { Button("Move up", systemImage: "arrow.up") { store.moveQueued(m.id, by: -1) } }
        if i < store.queue.count - 1 { Button("Move down", systemImage: "arrow.down") { store.moveQueued(m.id, by: 1) } }
        Button("Remove", systemImage: "trash", role: .destructive) { store.removeQueued(m.id) }
    }

    private func canSteer(_ m: QueuedMessage) -> Bool { store.running && m.editable }

    /// Closes the sheet so the steer's outcome shows over the composer.
    private func steer(_ m: QueuedMessage, redirect: Bool) {
        dismiss()
        Task { await store.steerQueued(m.id, redirect: redirect) }
    }
}

/// What became of the last steer or redirect, for a few seconds over the composer.
struct SteerToast: View {
    let store: ChatStore

    var body: some View {
        if let text = store.steerFeedback {
            Label(text, systemImage: "arrow.turn.left.up")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.sidebar, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .onTapGesture { store.steerFeedback = nil }
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.steerFeedback == text { store.steerFeedback = nil }
                }
                .transition(.opacity)
        }
    }
}

/// Steer now and Redirect, offered from the send button while a turn runs.
struct SteerAction {
    let run: (_ redirect: Bool) -> Void
}
