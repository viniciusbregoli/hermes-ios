import SwiftUI
import HermesKit

/// The Activity tab: what needs the user and what is running across chats, bots and rooms.
struct ActivityView: View {
    let activity: ActivityStore
    let bots: BotStore
    let groups: GroupStore
    @Binding var showSettings: Bool
    /// Switches to the tab that shows the target and opens it there.
    let open: (ActivityItem.Target) -> Void
    @State private var answering: ServerRequest?
    @State private var killing: BackgroundProcess?
    @State private var expanded: Set<String> = []
    @State private var error: String?

    private static let titles: [ActivityItem.Section: String] = [
        .needsYou: "Needs you", .working: "Working", .background: "Background", .done: "Done",
    ]

    var body: some View {
        let items = activity.items
        let sections = Dictionary(grouping: items, by: \.section).sorted { $0.key < $1.key }
        NavigationStack {
            List {
                ForEach(sections, id: \.key) { section, rows in
                    Section(Self.titles[section] ?? "Other") {
                        ForEach(rows) { row($0).listRowBackground(Theme.sidebar) }
                    }
                }
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing needs you", systemImage: "checkmark.circle")
                    } description: {
                        Text("Approvals, running turns and background commands from your chats, bots and groups show up here.")
                    }
                }
            }
            .themedList()
            .refreshable { await activity.refresh() }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .background {
                Button("Refresh") { Task { await activity.refresh() } }.keyboardShortcut("r", modifiers: .command).hidden()
            }
            .safeAreaInset(edge: .bottom) { ConnectionBanner(gateway: activity.gateway) }
            .sheet(item: $answering) { request in
                NavigationStack {
                    ScrollView {
                        RequestCard(request: request) { result in
                            activity.answer(request, result: result)
                            answering = nil
                        }
                    }
                    .background(Theme.background)
                    .navigationTitle(request.method == "clarify" ? "Question" : "Needs you")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { answering = nil } }
                    }
                }
                .chatTextSize()
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Kill this process?", isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                                titleVisibility: .visible, presenting: killing) { process in
                Button("Kill", role: .destructive) {
                    Task {
                        do { try await activity.kill(process: process) } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { process in
                Text(process.command)
            }
            .alert("Hermes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func row(_ item: ActivityItem) -> some View {
        let process: BackgroundProcess? = if case .background(.process(let p)) = item.kind { p } else { nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                avatar(item.target)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        trailing(item).font(.caption2).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        StatusPill(status: Self.status(item))
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(process == nil ? .caption : Theme.mono)
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let target = item.target { open(target) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(item.target == nil ? [] : .isButton)
            actions(item)
            if let process, expanded.contains(item.id) {
                ScrollView {
                    Text(process.outputTail.nonEmpty ?? "No output yet.")
                        .font(Theme.monoSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if case .working = item.kind, !Self.isRoom(item.target) {
                Button("Stop") { Task { await activity.interrupt(item) } }.tint(Theme.destructive)
            }
            if let process, process.running {
                Button("Kill") { killing = process }.tint(Theme.destructive)
            }
        }
    }

    @ViewBuilder private func actions(_ item: ActivityItem) -> some View {
        switch item.kind {
        case .needsYou(.request(let r)) where r.method == "approval":
            let choices = r.params["choices"]?.array?.compactMap(\.string) ?? ["once", "deny"]
            HStack {
                Button { activity.answer(r, result: ["choice": "once"]) } label: { Text("Once").foregroundStyle(Theme.onPrimary) }
                    .buttonStyle(.borderedProminent)
                if choices.contains("session") {
                    Button("Session") { activity.answer(r, result: ["choice": "session"]) }.buttonStyle(.bordered)
                }
                Spacer()
                Button("Deny", role: .destructive) { activity.answer(r, result: ["choice": "deny"]) }.buttonStyle(.bordered)
            }
            .controlSize(.large)
        case .needsYou(.request(let r)):
            Button("Answer…") { answering = r }.buttonStyle(.bordered).controlSize(.large)
        case .needsYou(.room(let action)):
            if case .room(let room) = item.target {
                HStack {
                    if action.kind == .retry {
                        Button("Retry") { Task { await activity.retry(action, in: room) } }.buttonStyle(.bordered)
                    } else {
                        Button { Task { await activity.approve(action, in: room, choice: "once") } } label: {
                            Text("Once").foregroundStyle(Theme.onPrimary)
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Deny", role: .destructive) { Task { await activity.approve(action, in: room, choice: "deny") } }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
        case .background(.process):
            let open = expanded.contains(item.id)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { if open { expanded.remove(item.id) } else { expanded.insert(item.id) } }
            } label: {
                Label(open ? "Hide output" : "Show output", systemImage: "chevron.right").labelStyle(ChevronLabel(open: open))
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func trailing(_ item: ActivityItem) -> some View {
        switch item.kind {
        case .working(let started?): Text(started, style: .timer)
        case .background(.process(let p)) where p.running: Text(p.startedAt, style: .timer)
        case .background(.process(let p)): Text(p.exitCode.map { "exit \($0)" } ?? "exited")
        case .done(let at): Text(min(at, Date()), format: .relative(presentation: .numeric, unitsStyle: .narrow))
        default: EmptyView()
        }
    }

    @ViewBuilder private func avatar(_ target: ActivityItem.Target?) -> some View {
        switch target {
        case .bot(let name): BotAvatar(bot: bots.bot(named: name), bots: bots, fallbackName: name, size: 36)
        case .room: Self.icon("person.3.fill")
        default: Self.icon("bubble.left.and.bubble.right.fill")
        }
    }

    private static func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(Theme.primary)
            .frame(width: 36, height: 36)
            .background(Theme.primary.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    private static func isRoom(_ target: ActivityItem.Target?) -> Bool {
        if case .room = target { true } else { false }
    }

    /// T3's sidebar states on this palette: approval and failures take the alarm color (T3 uses amber and red),
    /// input and working the accent (indigo and sky), background work stays muted and an unread finish is green.
    static func status(_ item: ActivityItem) -> (label: String, tint: Color) {
        switch item.kind {
        case .needsYou(.request(let r)) where r.method == "approval": ("Approval", Theme.destructive)
        case .needsYou(.request): ("Input", Theme.primary)
        case .needsYou(.room(let a)) where a.kind == .retry: ("Stopped", Theme.destructive)
        case .needsYou: ("Approval", Theme.destructive)
        case .working: ("Working", Theme.primary)
        case .background(.process(let p)) where p.running: ("Running", Theme.muted)
        case .background(.process(let p)) where p.exitCode == 0: ("Exited", Theme.success)
        case .background(.process): ("Failed", Theme.destructive)
        case .background(.subagents): ("Subagents", Theme.muted)
        case .background: ("Background", Theme.muted)
        case .done: ("Done", Theme.success)
        }
    }
}

struct StatusPill: View {
    let status: (label: String, tint: Color)

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.15), in: Capsule())
    }
}

/// A disclosure chevron that turns when open, before the title.
private struct ChevronLabel: LabelStyle {
    let open: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small).rotationEffect(.degrees(open ? 90 : 0))
            configuration.title
        }
    }
}
