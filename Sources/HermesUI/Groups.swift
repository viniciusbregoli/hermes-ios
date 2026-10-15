import SwiftUI
import HermesKit

/// The Groups tab: rooms hosted on the gateway where several bots talk with the user.
struct GroupsView: View {
    let groups: GroupStore
    let bots: BotStore
    @Binding var showSettings: Bool
    @Binding var path: [String]
    @State private var creating = false
    @State private var disbanding: Room?
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            List(groups.rooms) { room in
                NavigationLink(value: room.id) { GroupRow(room: room, groups: groups, bots: bots) }
                    .listRowBackground(Theme.sidebar)
                    .swipeActions {
                        Button("Disband", role: .destructive) { disbanding = room }
                            .tint(Theme.destructive)
                    }
            }
            .overlay {
                if groups.rooms.isEmpty {
                    if groups.loaded {
                        ContentUnavailableView {
                            Label("No groups yet", systemImage: "person.3")
                        } description: {
                            Text("Put 2 to 6 of your bots in one room. Rooms run on your Hermes server, so the bots keep talking while the phone sleeps. Hermes Desktop doesn't show them.")
                        } actions: {
                            Button("New group") { creating = true }
                        }
                    } else if let error = groups.error, groups.gateway.status == .online {
                        ContentUnavailableView {
                            Label("Couldn't load groups", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await groups.refresh() } }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .themedList()
            .refreshable { await groups.refresh() }
            .navigationTitle("Groups")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New group (⌘N)")
                        .disabled(groups.gateway.status != .online)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { ConnectionBanner(gateway: groups.gateway) }
            // One list read each time the tab (or the app) comes back; open rooms poll on their own.
            .task(id: RefreshKey(online: groups.gateway.status == .online, active: scenePhase == .active)) {
                guard groups.gateway.status == .online, scenePhase == .active else { return }
                await groups.refresh()
            }
            .navigationDestination(for: String.self) { RoomView(store: groups.store(for: $0), groups: groups, bots: bots) }
            .sheet(isPresented: $creating) {
                CreateGroupSheet(groups: groups, bots: bots) { room in path = [room.id] }
            }
            .confirmationDialog("Disband \(disbanding?.name ?? "")?", isPresented: Binding(
                get: { disbanding != nil }, set: { if !$0 { disbanding = nil } }), titleVisibility: .visible, presenting: disbanding) { room in
                Button("Disband", role: .destructive) {
                    Task {
                        do { try await groups.disband(room.id) } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { _ in
                Text("The room and its history are deleted from your Hermes server. The bots themselves stay.")
            }
            .alert("Hermes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private struct RefreshKey: Equatable { let online: Bool; let active: Bool }
}

struct GroupRow: View {
    let room: Room
    let groups: GroupStore
    let bots: BotStore
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        HStack(spacing: 12) {
            StackedAvatars(members: room.members, bots: bots, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                // Accessibility sizes stack the name and time, so the name keeps its width.
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                layout {
                    HStack(alignment: .firstTextBaseline) {
                        if groups.unread(room) { UnreadDot() }
                        Text(room.name).font(.subheadline.weight(.medium)).lineLimit(stacked ? 3 : 1)
                    }
                    if !stacked { Spacer() }
                    Text(room.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        guard let mark = groups.marks[room.id], !mark.preview.isEmpty else {
            return room.members.map { "@\($0.handle)" }.joined(separator: " ")
        }
        let who = mark.speaker.map { profile in
            room.members.first { $0.profile == profile }.map(bots.label) ?? profile
        } ?? "You"
        return "\(who): \(MarkdownView.plainText(mark.preview))"
    }
}

/// Up to three member avatars overlapping, with a count for the rest.
struct StackedAvatars: View {
    let members: [RoomMember]
    let bots: BotStore
    var size: CGFloat = 28
    var ring = Theme.sidebar

    var body: some View {
        HStack(spacing: -size * 0.4) {
            ForEach(members.prefix(3)) { m in
                BotAvatar(bot: bots.bot(named: m.profile), bots: bots, fallbackName: bots.label(m), size: size)
                    .overlay(Circle().stroke(ring, lineWidth: 2))
            }
        }
        .frame(width: size * 2.2, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if members.count > 3 {
                Text("+\(members.count - 3)")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 3)
                    .background(Theme.primary, in: Capsule())
            }
        }
        .accessibilityElement()
        .accessibilityLabel(members.map(bots.label).joined(separator: ", "))
    }
}

extension BotStore {
    /// A member's name as the Bots tab shows it.
    func label(_ member: RoomMember) -> String {
        bot(named: member.profile)?.label ?? member.displayName.nonEmpty ?? member.handle
    }
}

// MARK: - New group

struct CreateGroupSheet: View {
    let groups: GroupStore
    let bots: BotStore
    let created: (Room) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    /// Bot names in the order they were picked, which is the room's speaking order.
    @State private var picked: [String] = []
    @State private var busy = false
    @State private var error: String?
    /// Kept across retries of the same group so a create whose answer was lost isn't made twice.
    @State private var roomId: String?
    @FocusState private var nameFocused: Bool

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (2...6).contains(picked.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                } footer: {
                    Text("The room runs on your Hermes server; Hermes Desktop doesn't show it.")
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    if !bots.loaded { ProgressView() }
                    ForEach(bots.bots) { bot in
                        let on = picked.contains(bot.name)
                        Button { toggle(bot.name) } label: {
                            HStack(spacing: 12) {
                                BotAvatar(bot: bot, bots: bots, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bot.label).foregroundStyle(Theme.foreground)
                                    Text("@\(bot.handle)").font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(on ? Theme.primary : Theme.muted)
                            }
                        }
                        .disabled(!on && picked.count >= 6)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                } header: {
                    Text("Bots")
                } footer: {
                    Text("With no @mention, every bot hears and may answer.")
                }
                .listRowBackground(Theme.sidebar)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).listRowBackground(Theme.sidebar)
                }
            }
            .themedList()
            .navigationTitle("New group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // Beside Create, so the 2 to 6 rule stays in view however far the bot list is scrolled.
                    VStack(spacing: 0) {
                        Text("New group").font(.headline)
                        Text("\(picked.count) \(picked.count == 1 ? "bot" : "bots") picked (2 to 6)")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .toolbarEnabled(valid)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Create (⌘↩)")
                    }
                }
            }
            .onChange(of: name) { roomId = nil }
            .onChange(of: picked) { roomId = nil }
            .task {
                nameFocused = true
                if !bots.loaded { await bots.refresh() }
            }
        }
    }

    private func toggle(_ bot: String) {
        if let i = picked.firstIndex(of: bot) { picked.remove(at: i) } else if picked.count < 6 { picked.append(bot) }
    }

    private func create() async {
        let id = roomId ?? RoomIds.room(name: name)
        roomId = id
        busy = true
        error = nil
        defer { busy = false }
        do {
            let room = try await groups.create(id: id, name: name, bots: picked.compactMap(bots.bot(named:)))
            dismiss()
            created(room)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Room

struct RoomView: View {
    let store: RoomStore
    let groups: GroupStore
    let bots: BotStore
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @State private var onScreen = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDisband = false
    /// Bumped to scroll to the end (see EndScroller).
    @State private var endRequests = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    private static let end = "room-end"

    var body: some View {
        let labels = Dictionary(bots.bots.map { ($0.name, $0.label) }) { a, _ in a }
        let rows = RoomTimeline.rows(store.events, room: store.room, labels: labels)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        RoomRowView(row: row, bots: bots, retryable: store.status.retryable) { id in Task { await store.retry(id) } }
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // Room for the floating working capsule.
                .padding(.bottom, store.working ? 40 : 0)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(EndScroller(requests: endRequests))
            .scrollDismissesKeyboard(.immediately)
            // The working capsule's inset changes the content height too, so follow both.
            .onChange(of: EndKey(last: rows.last?.id, working: store.working)) {
                Task { @MainActor in
                    // Let the new rows and inset lay out first, or the scroll stops short of them.
                    try? await Task.sleep(for: .milliseconds(100))
                    if #available(iOS 18, macOS 15, *) {
                        endRequests += 1
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                    }
                }
            }
            .overlay {
                if store.gone {
                    ContentUnavailableView("This group is gone", systemImage: "person.3",
                                           description: Text("It was disbanded or no longer exists on the server."))
                        .background(Theme.background)
                } else if !store.loaded {
                    if store.gateway.status == .online { ProgressView() }
                } else if rows.isEmpty {
                    EmptyRoom(room: store.room, bots: bots)
                }
            }
            .overlay(alignment: .bottom) {
                WorkingControls(running: store.working, startedAt: nil, showScrollToEnd: false, title: statusLine) {
                    Task { await store.stop() }
                } scrollToEnd: {}
            }
        }
        .background(Theme.background)
        .environment(\.credentials, store.gateway.credentials)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .chatTextSize()
        .navigationTitle(store.room.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    StackedAvatars(members: store.room.members, bots: bots, size: 22, ring: Theme.background)
                    Text(store.room.name).font(.headline).lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = store.room.name
                        renaming = true
                    }
                    Section("Members") {
                        ForEach(store.room.members) { m in Text("\(bots.label(m))  @\(m.handle)") }
                    }
                    Button("Disband", systemImage: "trash", role: .destructive) { confirmDisband = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(store.gone)
            }
        }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await store.rename(newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Disband \(store.room.name)?", isPresented: $confirmDisband, titleVisibility: .visible) {
            Button("Disband", role: .destructive) {
                Task {
                    do {
                        try await groups.disband(store.room.id)
                        dismiss()
                    } catch {
                        store.alert = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("The room and its history are deleted from your Hermes server. The bots themselves stay.")
        }
        .alert("Hermes", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
        // Polls only while the room is on screen with the app active; the store picks the pace.
        .task(id: PollKey(online: store.gateway.status == .online, active: scenePhase == .active)) {
            guard store.gateway.status == .online, scenePhase == .active else { return }
            let clock = ContinuousClock()
            var last: ContinuousClock.Instant?
            while !Task.isCancelled {
                if last.map({ clock.now - $0 >= store.nextPoll }) ?? true {
                    await store.poll()
                    last = clock.now
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear {
            onScreen = true
            draft = Drafts.load(draftKey)
        }
        .onDisappear {
            onScreen = false
            Drafts.save(draft, for: draftKey)
        }
        .onChange(of: onScreen && scenePhase == .active, initial: true) { _, visible in store.visible = visible }
    }

    private struct PollKey: Equatable { let online: Bool; let active: Bool }
    private struct EndKey: Equatable { let last: Int?; let working: Bool }

    private var draftKey: String { "group/\(store.room.id)" }

    private var statusLine: String {
        if !store.status.approvals.isEmpty { return "Waiting for your approval" }
        if let m = store.replying { return "\(bots.label(m)) is replying…" }
        return "The room is working…"
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 0) {
            ForEach(store.status.approvals) { action in
                RequestCard(request: approvalRequest(action)) { result in
                    let choice = result["choice"]?.string == "once" ? "once" : "deny"
                    Task { await store.approve(action, choice: choice) }
                }
            }
            let shown = Set(store.events.compactMap { $0.payload["task_id"]?.string })
            ForEach(store.status.actions.filter { $0.kind == .retry && !shown.contains($0.taskId) }) { action in
                HStack {
                    Label("A bot's turn stopped before it finished.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Retry") { Task { await store.retry(action.taskId) } }.font(.caption)
                }
                .padding(12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
            }
            if let query = MentionPicker.query(draft) {
                let q = query.lowercased()
                let members = store.room.members.filter { q.isEmpty || $0.handle.hasPrefix(q) || bots.label($0).lowercased().hasPrefix(q) }
                if !members.isEmpty {
                    MentionPicker(candidates: members.map { bots.bot(named: $0.profile) ?? Bot(name: $0.profile) }, bots: bots,
                                  handle: handle(of:)) { bot in
                        draft = MentionPicker.complete(draft, handle: handle(of: bot))
                    }
                }
            }
            Composer(draft: $draft, focused: $composerFocused, placeholder: "Message \(store.room.name)",
                     running: store.working, enabled: store.gateway.status == .online && !store.sending && !store.gone) {
                let text = draft
                draft = ""
                Drafts.save("", for: draftKey)
                Task { await store.send(text) }
            }
        }
        .background(Theme.background)
    }

    private func handle(of bot: Bot) -> String {
        store.room.members.first { $0.profile == bot.name }?.handle ?? bot.handle
    }

    /// The chat's approval card reads `description`, `command` and `choices`; the room's choices are only once and deny.
    private func approvalRequest(_ action: RoomAction) -> ServerRequest {
        var params = action.approval.object ?? [:]
        let who = store.room.member(action.memberId).map(bots.label) ?? "A bot"
        let what = params["description"]?.string?.nonEmpty
        params["description"] = .string("\(who) wants to run a command" + (what.map { ": \($0)" } ?? ""))
        params["choices"] = ["once", "deny"]
        return ServerRequest(rpcId: .string(action.id), method: "approval", params: .object(params))
    }
}

struct RoomRowView: View {
    let row: RoomRow
    let bots: BotStore
    let retryable: Set<String>
    let retry: (String) -> Void

    private static let avatar: CGFloat = 28

    var body: some View {
        switch row.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(row.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(row.text) } }
            }
        case .member:
            HStack(alignment: .top, spacing: 8) {
                if row.header {
                    BotAvatar(bot: row.member.flatMap { bots.bot(named: $0.profile) }, bots: bots, fallbackName: row.name, size: Self.avatar)
                } else {
                    Color.clear.frame(width: Self.avatar, height: 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if row.header {
                        Text(row.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                    }
                    MarkdownView(text: row.text)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(MarkdownView.plainText(row.text)) }
                            Button("Copy Markdown", systemImage: "text.document") { Clipboard.copy(row.text) }
                        }
                }
            }
            .padding(.top, row.header ? 4 : -6)
        case .passed, .cancelled:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .padding(.leading, Self.avatar + 8)
        case .failed, .deferred:
            HStack(spacing: 8) {
                Label(row.text, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(row.kind == .failed ? Theme.destructive : Theme.muted)
                if let id = row.taskId, retryable.contains(id) {
                    Button("Retry") { retry(id) }.font(.caption)
                }
            }
            .padding(.leading, Self.avatar + 8)
        case .notice:
            Text(row.text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity)
        }
    }
}

struct EmptyRoom: View {
    let room: Room
    let bots: BotStore

    var body: some View {
        VStack(spacing: 10) {
            StackedAvatars(members: room.members, bots: bots, size: 44, ring: Theme.background)
                .frame(width: 44 * 2.2)
            Text("Everyone in \(room.name) hears the room.").foregroundStyle(Theme.muted)
            Text("Start with @\(room.members.first?.handle ?? "name") to ask one bot.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
