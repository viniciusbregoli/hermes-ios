import SwiftUI
import HermesKit

// Per-chat controls and live status, mirroring the desktop composer pills and status bar.

// MARK: - Composer controls

/// Reasoning effort, fast mode and approvals for the open chat, in a row above the composer.
struct ControlsRow: View {
    let store: ChatStore
    @Binding var draft: String

    var body: some View {
        // Each pill is padded out to a 44 pt target, so the row spacing stays small to keep Approvals whole.
        HStack(spacing: 4) {
            ReasoningMenu(store: store)
            if store.fastAvailable {
                Button { Task { await store.setFast(!store.fast) } } label: {
                    Label("Fast", systemImage: store.fast ? "hare.fill" : "hare")
                }
                .buttonStyle(Pill(active: store.fast))
            }
            DelegateButton(store: store, draft: $draft)
            CommandsButton(store: store, draft: $draft)
            Spacer(minLength: 0)
            ApprovalsMenu(store: store)
        }
        .font(.caption)
        // The pills share one line; above the default size they truncate to "...".
        .dynamicTypeSize(...DynamicTypeSize.large)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .disabled(store.gateway.status != .online)
    }
}

struct ReasoningMenu: View {
    let store: ChatStore

    var body: some View {
        Menu {
            Section("Reasoning effort") {
                ForEach(["none"] + ChatStore.reasoningEfforts, id: \.self) { level in
                    Button { Task { await store.setReasoning(level) } } label: {
                        if level == store.reasoningEffort { Label(Self.label(level), systemImage: "checkmark") } else { Text(Self.label(level)) }
                    }
                }
            }
        } label: {
            Label(store.reasoningEffort.isEmpty ? "Effort" : Self.label(store.reasoningEffort), systemImage: "brain")
        }
        .buttonStyle(Pill(active: false))
    }

    static func label(_ level: String) -> String {
        switch level {
        case "none": "Off"
        case "xhigh": "X-High"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}

struct ApprovalsMenu: View {
    let store: ChatStore

    var body: some View {
        let globalOff = store.approvalMode == "off"
        Menu {
            Section(globalOff ? "Approvals: off for all chats" : "Approvals: on for all chats") {
                Toggle("Require approvals in all chats", isOn: Binding(get: { !globalOff }, set: { on in
                    Task { await store.setApprovalsRequired(on) }
                }))
            }
            // info.yolo already includes the global mode, so the per-chat switch changes nothing while it is off.
            Toggle("Skip approvals in this chat", isOn: Binding(get: { store.yolo }, set: { on in Task { await store.setYolo(on) } }))
                .disabled(globalOff)
        } label: {
            if store.approvalsOff {
                Label("YOLO", systemImage: "bolt.fill").foregroundStyle(Theme.destructive)
            } else {
                Label("Approvals", systemImage: "checkmark.shield").foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(Pill(active: store.approvalsOff, tint: Theme.destructive))
        .accessibilityLabel(store.approvalsOff ? "Approvals off" : "Approvals on")
    }
}

struct Pill: ButtonStyle {
    let active: Bool
    var tint = Theme.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(active ? tint : Theme.muted)
            .background(active ? tint.opacity(0.15) : .clear, in: Capsule())
            .overlay(Capsule().stroke(active ? tint.opacity(0.5) : Theme.border))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .tapTarget()
    }
}

// MARK: - Todos

/// "Todos 2/3" above the composer: open while the turn runs, folded into "Previous todos" once it ends.
struct TodosPanel: View {
    let store: ChatStore
    @State private var open = true

    var body: some View {
        let todos = store.todos
        if !todos.isEmpty {
            let done = todos.filter { $0.status == .completed }.count
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                        Text("\(store.running ? "Todos" : "Previous todos") \(done)/\(todos.count)")
                        if !open, store.running, todos.contains(where: { $0.status == .inProgress }) {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    let rows = VStack(alignment: .leading, spacing: 4) {
                        ForEach(TodoItem.tree(todos), id: \.item.id) { row in
                            TodoRow(todo: row.item, live: store.running).padding(.leading, CGFloat(row.depth) * 16)
                        }
                    }
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollView { rows }.frame(maxHeight: 160)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
            .onChange(of: store.running, initial: true) { _, running in open = running }
        }
    }
}

struct TodoRow: View {
    let todo: TodoItem
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch todo.status {
                case .inProgress where live: ProgressView().controlSize(.mini)
                case .inProgress: Image(systemName: "circle.dotted").foregroundStyle(Theme.primary)
                case .pending: Image(systemName: "circle").foregroundStyle(Theme.muted)
                case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 14)
            Text(todo.content)
                .strikethrough(todo.status == .cancelled)
                .foregroundStyle(todo.status == .completed || todo.status == .cancelled ? Theme.muted : Theme.foreground)
        }
        .font(.footnote)
    }
}

// MARK: - Transcript extras

/// Messages waiting for the running turn to finish, drawn as dimmed user bubbles.
struct QueuedBubbles: View {
    let store: ChatStore

    var body: some View {
        ForEach(store.queuedBubbles) { item in
            VStack(alignment: .trailing, spacing: 2) {
                if !item.images.isEmpty || !item.files.isEmpty { MessageAttachments(item: item).opacity(0.6) }
                if !item.text.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    Text(item.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.userBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, style: StrokeStyle(dash: [4, 3])))
                }
                }
                Label("Queued", systemImage: "clock").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Under a transcript item: the steered/redirected note, or Retry on the last failed turn.
struct ItemFooter: View {
    let store: ChatStore
    let item: ChatItem

    var body: some View {
        if let note = store.notes[item.id] {
            HStack {
                Spacer()
                Label(note, systemImage: "arrow.turn.down.right").font(.caption2).foregroundStyle(Theme.muted)
            }
        } else if item.kind == .error, store.retryText != nil, item.id == store.items.last?.id, !store.running {
            Button { Task { await store.retry() } } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .font(.caption)
            .buttonStyle(Pill(active: true))
        }
    }
}

// MARK: - Context meter

/// Context-window fill as a ring in the nav bar; tap for the breakdown.
struct ContextMeter: View {
    let store: ChatStore
    @State private var showDetails = false

    var body: some View {
        if let usage = store.usage, let fraction = usage.fraction {
            Button { showDetails = true } label: {
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(fraction > 0.85 ? Theme.destructive : Theme.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 18, height: 18)
                .animation(.easeOut, value: fraction)
            }
            .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent full")
            .sheet(isPresented: $showDetails) { ContextSheet(store: store) }
        }
    }
}

struct ContextSheet: View {
    let store: ChatStore
    @State private var breakdown: ContextBreakdown?
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let usage = store.usage ?? breakdown?.usage
        let approx = usage?.estimated == true ? "~" : ""
        NavigationStack {
            List {
                if let usage {
                    Section {
                        Row("Used", "\(approx)\(Self.compact(usage.contextUsed ?? 0)) of \(Self.compact(usage.contextMax ?? 0)) tokens")
                        Row("Full", "\(approx)\(Int(((usage.fraction ?? 0) * 100).rounded()))%")
                        Row("Compressions", "\(usage.compressions)")
                    }
                    .listRowBackground(Theme.sidebar)
                }
                Section("Breakdown") {
                    if let categories = breakdown?.categories, !categories.isEmpty {
                        let total = max(1, categories.reduce(0) { $0 + $1.tokens })
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(Array(categories.enumerated()), id: \.element.id) { i, c in
                                    Self.color(i).frame(width: geo.size.width * CGFloat(c.tokens) / CGFloat(total))
                                }
                            }
                        }
                        .frame(height: 8)
                        .clipShape(Capsule())
                        ForEach(Array(categories.enumerated()), id: \.element.id) { i, c in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(Self.color(i)).frame(width: 8, height: 8)
                                Text(c.label).foregroundStyle(Theme.muted)
                                Spacer()
                                Text("~\(Self.compact(c.tokens))").monospacedDigit()
                            }
                        }
                    } else {
                        Text(loading ? "Loading…" : "No breakdown yet.").foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Theme.sidebar)
                if let usage {
                    Section("This session") {
                        Row("Input", Self.compact(usage.input))
                        Row("Output", Self.compact(usage.output))
                        Row("Total", Self.compact(usage.total))
                        if let cost = usage.costUSD { Row("Cost", cost.formatted(.currency(code: "USD"))) }
                    }
                    .listRowBackground(Theme.sidebar)
                }
            }
            .font(.callout)
            .themedList()
            .navigationTitle("Context")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task {
            breakdown = await store.contextBreakdown()
            loading = false
        }
    }

    struct Row: View {
        let title: String
        let value: String
        init(_ title: String, _ value: String) { self.title = title; self.value = value }

        var body: some View {
            HStack {
                Text(title).foregroundStyle(Theme.muted)
                Spacer()
                Text(value).monospacedDigit()
            }
        }
    }

    /// The server's category colors are desktop CSS variables, so pick from the palette by position.
    static func color(_ i: Int) -> Color {
        [Theme.primary, Theme.success, Theme.destructive, Theme.muted, Theme.foreground][i % 5]
    }

    static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}
