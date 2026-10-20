import SwiftUI
import HermesKit

public struct RootView: View {
    @State private var store: ChatStore
    @State private var bots: BotStore
    @State private var groups: GroupStore
    @State private var activity: ActivityStore
    @State private var tab = 0
    @State private var showSettings = false
    /// A chat to open in the Chats tab, asked for from outside it (the Artifacts screen in Settings).
    @State private var jump: String?
    @State private var botPath: [String] = []
    @State private var roomPath: [String] = []
    /// Whose chats the Chats tab lists, picked on its profile rail; kept across launches.
    @AppStorage("chatsProfile") private var chatsProfile = Bot.defaultName
    @AppStorage("theme") private var themeId = Palette.nous.id
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("showTouches") private var showTouches = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        let gateway = Gateway(credentials: Keychain.load())
        let store = ChatStore(gateway: gateway)
        let bots = BotStore(gateway: gateway)
        #if os(iOS)
        let notifier = Notifier.shared
        store.onTurnFinished = { title, reply in notifier.post(title: title, body: reply) }
        bots.onTurnFinished = { [weak bots] name, reply in notifier.post(title: bots?.bot(named: name)?.label ?? name, body: reply) }
        #endif
        let groups = GroupStore(gateway: gateway)
        _store = State(initialValue: store)
        _bots = State(initialValue: bots)
        _groups = State(initialValue: groups)
        _activity = State(initialValue: ActivityStore(gateway: gateway, chats: store, bots: bots, groups: groups))
    }

    public var body: some View {
        let palette = Palette.named(themeId)
        let _ = (Theme.palette = palette)
        Group {
            if store.gateway.status == .signedOut {
                LoginView(gateway: store.gateway)
            } else {
                TabView(selection: $tab) {
                    MainView(store: chatsStore, home: store, bots: bots, profile: $chatsProfile, showSettings: $showSettings, jump: $jump)
                        // A profile switch starts fresh (desktop selectProfile): no chat selected, no search.
                        .id(chatsProfile)
                        // A profile that left the roster (deleted or hidden) falls back to the default one.
                        .onChange(of: bots.bots.map(\.name), initial: true) { _, names in
                            if bots.loaded, !names.contains(chatsProfile) { chatsProfile = Bot.defaultName }
                        }
                        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                        .tag(0)
                    BotsView(bots: bots, showSettings: $showSettings, path: $botPath)
                        .tabItem { Label("Bots", systemImage: "person.2") }
                        .tag(1)
                    GroupsView(groups: groups, bots: bots, showSettings: $showSettings, path: $roomPath)
                        .tabItem { Label("Groups", systemImage: "person.3") }
                        .tag(2)
                    ActivityView(activity: activity, bots: bots, groups: groups, showSettings: $showSettings, open: open)
                        .tabItem { Label("Activity", systemImage: "bolt.horizontal.circle") }
                        .badge(activity.needsYouCount)
                        .tag(3)
                }
                // Polls fast while the tab is on screen, slowly otherwise so the badge stays current; stops on sign-out.
                .onChange(of: tab, initial: true) { activity.start(visible: tab == 3) }
                .onDisappear { activity.stop() }
                .background {
                    Button("Chats") { tab = 0 }.keyboardShortcut("1", modifiers: .command).hidden()
                    Button("Bots") { tab = 1 }.keyboardShortcut("2", modifiers: .command).hidden()
                    Button("Groups") { tab = 2 }.keyboardShortcut("3", modifiers: .command).hidden()
                    Button("Activity") { tab = 3 }.keyboardShortcut("4", modifiers: .command).hidden()
                }
            }
        }
        // Views read Theme statically, so a new id rebuilds them with the new palette.
        .id(themeId)
        .themed(palette, appearance)
        .sheet(isPresented: $showSettings) {
            SettingsView(gateway: store.gateway, themeId: $themeId, appearance: $appearance) { id in
                showSettings = false
                tab = 0
                chatsProfile = Bot.defaultName
                jump = id
            }
            .id(themeId).themed(palette, appearance)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.gateway.start() }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in BackgroundTurn.shared.update(away: phase != .active, running: turnRunning) }
        .onChange(of: turnRunning) { _, running in BackgroundTurn.shared.update(away: scenePhase != .active, running: running) }
        .onChange(of: showTouches, initial: true) { _, on in TouchIndicator.shared.setEnabled(on) }
        #endif
    }

    private var turnRunning: Bool { store.running || !bots.thinking.isEmpty }

    /// Another profile's chats live in its bot's store, so Activity, notifications and the Bots tab already follow them.
    private var chatsStore: ChatStore {
        chatsProfile == Bot.defaultName ? store : bots.chat(for: chatsProfile)
    }

    private func open(_ target: ActivityItem.Target) {
        switch target {
        case .chat(let id):
            tab = 0
            chatsProfile = Bot.defaultName
            jump = id
        case .bot(let name):
            tab = 1
            botPath = [name]
        case .room(let id):
            tab = 2
            roomPath = [id]
        }
    }
}

struct LoginView: View {
    let gateway: Gateway
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("username") private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://host.tailnet.ts.net:8447", text: $serverURL)
                        .noAutocorrect()
                    TextField("Username", text: $username)
                        .noAutocorrect()
                    SecureField("Password", text: $password)
                        .onSubmit { Task { await signIn() } }
                } header: {
                    Text("Hermes gateway")
                } footer: {
                    Text("The URL of `hermes dashboard` or `hermes serve` with password auth enabled.")
                }
                .listRowBackground(Theme.sidebar)
                if let error {
                    Text(error).foregroundStyle(Theme.destructive)
                }
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || serverURL.isEmpty || username.isEmpty || password.isEmpty)
                .keyboardShortcut(.defaultAction)
                .listRowBackground(Theme.sidebar)
            }
            .themedList()
            .navigationTitle("Hermes")
            // A stale error (such as "Invalid URL.") would otherwise outlive the edit that fixes it.
            .onChange(of: serverURL) { error = nil }
            .onChange(of: username) { error = nil }
            .onChange(of: password) { error = nil }
        }
    }

    private func signIn() async {
        var raw = serverURL.trimmingCharacters(in: .whitespaces)
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw) else { error = "Invalid URL."; return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            gateway.credentials = try await Auth.login(baseURL: url, username: username, password: password)
            password = ""
            gateway.start()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MainView: View {
    @Bindable var store: ChatStore
    /// The default profile's chats, for its group when the list is grouped by profile.
    let home: ChatStore
    let bots: BotStore
    @Binding var profile: String
    @Binding var showSettings: Bool
    @Binding var jump: String?
    @State private var selection: String?
    @State private var query = ""
    @State private var searching = false
    @State private var search = SearchState()
    @State private var renaming: SessionRow?
    @State private var showArchived = false
    @State private var showArtifacts = false
    @State private var screen: ScreenStore?
    /// Every profile's chats in collapsible groups, like the desktop's Grouping > Profile; the rail hides.
    @AppStorage("chatsGrouped") private var grouped = false

    static let newChat = "__new__"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResults(state: search, query: query) { SearchHitRow(hit: $0).tag($0.id) }
                } else {
                    if grouped {
                        ForEach(ProfileRail.profiles(bots)) { bot in
                            ProfileGroup(bot: bot, bots: bots, chats: bot.name == profile ? store : bot.isDefault ? home : bots.chat(for: bot.name),
                                         current: bot.name == profile) { open($0, in: bot.name) } currentRows: { rows($0) }
                        }
                    } else {
                        #if os(iOS)
                        // Like the desktop's Screen card under a profile in its sessions list.
                        if let screen { Section { ScreenCard(store: screen) } }
                        #endif
                        if !store.pinnedSessions.isEmpty {
                            Section("Pinned") { rows(store.pinnedSessions) }
                        }
                        Section {
                            rows(store.unpinnedSessions)
                        } header: {
                            if !store.pinnedSessions.isEmpty { Text("Chats") }
                        }
                    }
                    if store.sessionsLoaded { ArchivedEntry(shown: $showArchived) }
                }
            }
            .overlay {
                if !grouped, store.sessions.isEmpty, store.sessionsLoaded, query.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            .themedList()
            #if os(iOS)
            // Always shown: the default drawer hides above the first row until the list is pulled down.
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
            #else
            .searchable(text: $query, isPresented: $searching, prompt: "Search messages")
            #endif
            .searchFetch(store, query, into: $search)
            .refreshable {
                await store.refreshSessions()
                await screen?.refresh()
            }
            // On the list, which is always drawn: the card's own row is empty until the status arrives.
            .task(id: profile) {
                screen = ScreenStore(gateway: store.gateway, profile: profile)
                await screen?.refresh()
            }
            .renameAlert(store, $renaming)
            .sheet(isPresented: $showArchived) { ArchivedChats(store: store) { selection = $0 } }
            .sheet(isPresented: $showArtifacts) {
                NavigationStack {
                    // Artifacts come from the default profile, so their chats open there.
                    ArtifactsView(gateway: store.gateway) { id in
                        showArtifacts = false
                        profile = Bot.defaultName
                        jump = id
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showArtifacts = false }.keyboardShortcut(.cancelAction)
                        }
                    }
                }
            }
            .background {
                Button("Search") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
            }
            .navigationTitle(store.profile.flatMap { bots.bot(named: $0)?.label } ?? "Hermes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { grouped.toggle() } label: { Image(systemName: grouped ? "rectangle.stack.fill" : "rectangle.stack") }
                        .accessibilityLabel("Group by profile")
                        .accessibilityAddTraits(grouped ? .isSelected : [])
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .help("Group by profile (⇧⌘G)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New chat (⌘N)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showArtifacts = true } label: { Image(systemName: "photo.on.rectangle.angled") }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                        .accessibilityLabel("Artifacts")
                        .help("Artifacts (⇧⌘A)")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    if !grouped { ProfileRail(bots: bots, profile: $profile) }
                    ConnectionBanner(gateway: store.gateway)
                }
            }
            // A profile's store is made on first pick, after the connect that loads the default one.
            .task { if !store.sessionsLoaded { await store.refreshSessions() } }
        } detail: {
            if selection != nil {
                ChatView(store: store, bots: bots)
            } else {
                ContentUnavailableView("Pick a chat", systemImage: "bubble.left")
            }
        }
        // The split view's detail appears and disappears unreliably, so the selection says what is on screen.
        .onChange(of: selection, initial: true) { store.onScreen = selection != nil }
        // Leaving for another tab or profile takes the chat off screen, so its finished turn notifies.
        .onAppear { store.onScreen = selection != nil }
        .onDisappear {
            store.onScreen = false
            if let name = store.profile, bots.visibleBot == name { bots.visibleBot = nil }
        }
        // Initial too: a jump that switches profile lands in a new view, after the change.
        .onChange(of: jump, initial: true) { _, id in
            guard let id else { return }
            selection = id
            jump = nil
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            let stored = id == Self.newChat ? nil : id
            if stored != nil, stored == store.selectedId, store.runtimeId != nil || store.loading { return }
            Task { await store.open(stored) }
        }
        // A profile's turns reach the Bots roster, notifications and background time the way its Bot Chat's do.
        .onChange(of: store.runtimeId, initial: true) { trackBot() }
        .onChange(of: store.running) { trackBot() }
        .onChange(of: store.visible, initial: true) {
            guard let name = store.profile else { return }
            if store.visible { bots.visibleBot = name } else if bots.visibleBot == name { bots.visibleBot = nil }
        }
        // A branch opens from inside the chat; follow it so the list highlights the chat on screen.
        .onChange(of: store.selectedId) { _, id in
            if let id, selection != nil, selection != Self.newChat, selection != id { selection = id }
            // The open chat was deleted: nothing is on screen any more, so nothing stays selected.
            if id == nil, selection != Self.newChat { selection = nil }
        }
        .alert("Hermes", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
    }

    private func rows(_ sessions: [SessionRow]) -> some View {
        ForEach(sessions) { s in
            SessionRowView(session: s, unread: store.unread[s.id] != nil, live: store.live[s.id], preview: store.preview(of: s)).tag(s.id)
                .listRowBackground(Theme.sidebar)
                .sessionActions(store, s, renaming: $renaming)
        }
    }

    private func trackBot() {
        if let name = store.profile { bots.track(runtime: store.runtimeId, bot: name, running: store.running) }
    }

    /// A chat of another profile opens in that profile's view, as a jump from Artifacts does.
    private func open(_ id: String, in name: String) {
        profile = name
        jump = id
    }

    private func newChat() {
        if selection == Self.newChat { Task { await store.open(nil) } }
        selection = Self.newChat
    }
}

/// The desktop's profile rail at the sidebar foot: home for the default profile, then one chip per bot.
/// Picking one scopes the list to that profile's chats.
struct ProfileRail: View {
    let bots: BotStore
    @Binding var profile: String

    private var profiles: [Bot] { Self.profiles(bots) }

    /// A default profile hidden in Bot Mode still gets its home chip, so the rail can always return to it.
    static func profiles(_ bots: BotStore) -> [Bot] {
        bots.bots.contains { $0.isDefault } ? bots.bots : [Bot(name: Bot.defaultName)] + bots.bots
    }

    var body: some View {
        if profiles.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(profiles) { chip($0) }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Theme.sidebar)
            .overlay(alignment: .top) { Divider() }
            .background {
                Button("Default profile") { profile = Bot.defaultName }.keyboardShortcut("d", modifiers: .command).hidden()
                Button("Next profile") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift]).hidden()
                Button("Previous profile") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift]).hidden()
            }
        }
    }

    private func chip(_ bot: Bot) -> some View {
        let selected = bot.name == profile
        return Button { profile = bot.name } label: {
            Group {
                if bot.isDefault {
                    Image(systemName: "house")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Theme.primary : Theme.muted)
                        .frame(width: 32, height: 32)
                        .background(Theme.primary.opacity(selected ? 0.15 : 0.06), in: Circle())
                } else {
                    BotAvatar(bot: bot, bots: bots, size: 32).opacity(selected ? 1 : 0.6)
                }
            }
            .padding(3)
            .overlay(Circle().stroke(selected ? Theme.primary : .clear, lineWidth: 2))
            // 44 pt touch target around the 38 pt chip.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.label)
        .accessibilityHint("Shows this profile's chats")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(bot.isDefault ? "\(bot.label) (⌘D)" : bot.label)
    }

    private func step(_ by: Int) {
        if let next = Bot.cycle(profiles, from: profile, by: by) { profile = next }
    }
}

/// One profile's group in the grouped Chats list: a header that collapses it, its screen, then its chats.
struct ProfileGroup<Rows: View>: View {
    let bot: Bot
    let bots: BotStore
    let chats: ChatStore
    /// The profile on screen: its rows are the list's own, selectable and with their swipe actions.
    let current: Bool
    let open: (String) -> Void
    @ViewBuilder let currentRows: ([SessionRow]) -> Rows
    /// Collapsed profile names, one per line; groups start expanded.
    @AppStorage("chatsCollapsed") private var collapsed = ""
    @State private var screen: ScreenStore?
    /// Chats shown before "Show more", paged like the desktop's groups.
    @State private var limit = 5

    private var expanded: Bool { !collapsed.split(separator: "\n").contains { $0 == bot.name } }

    var body: some View {
        Section {
            if expanded {
                #if os(iOS)
                if let screen { ScreenCard(store: screen) }
                #endif
                let all = chats.pinnedSessions + chats.unpinnedSessions
                let shown = Array(all.prefix(limit))
                if current {
                    currentRows(shown)
                } else {
                    ForEach(shown) { s in
                        Button { open(s.id) } label: {
                            SessionRowView(session: s, unread: chats.unread[s.id] != nil, live: chats.live[s.id], preview: chats.preview(of: s))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.sidebar)
                    }
                }
                if all.count > limit {
                    Button("Show more (\(all.count - limit))") { limit += 5 }
                        .font(.caption)
                        .foregroundStyle(Theme.primary)
                        .listRowBackground(Theme.sidebar)
                }
            }
        } header: {
            header
                // On the header, which is always drawn: a collapsed group has no rows to hang this on.
                .task {
                    if !chats.sessionsLoaded { await chats.refreshSessions() }
                    let screen = ScreenStore(gateway: chats.gateway, profile: bot.name)
                    self.screen = screen
                    await screen.refresh()
                }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                var names = collapsed.split(separator: "\n").map(String.init).filter { $0 != bot.name }
                if expanded { names.append(bot.name) }
                collapsed = names.joined(separator: "\n")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if bot.isDefault {
                        Image(systemName: "house").frame(width: 22, height: 22)
                    } else {
                        BotAvatar(bot: bot, bots: bots, size: 22)
                    }
                    Text(bot.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.foreground)
                    if !chats.sessions.isEmpty {
                        Text("\(chats.sessions.count)").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(bot.label), \(expanded ? "expanded" : "collapsed")")
            .accessibilityHint("Shows or hides this profile's chats")
            Button { open(MainView.newChat) } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain)
                .accessibilityLabel("New chat with \(bot.label)")
        }
        .foregroundStyle(Theme.muted)
        .textCase(nil)
    }
}

struct SessionRowView: View {
    let session: SessionRow
    var unread = false
    var live: ChatLive?
    /// Replaces the first prompt when the latest reply is known.
    var preview: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 2) {
            // Accessibility sizes stack title, status and time, so the title gets the full row instead of three characters.
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                HStack(alignment: .firstTextBaseline) {
                    if unread { UnreadDot() }
                    Text(session.title.nonEmpty ?? "Untitled")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(stacked ? 3 : 1)
                }
                if let status = live?.status { StatusPill(status: Self.pill(status)) }
                if !stacked { Spacer() }
                time
            }
            if let preview = (preview ?? session.preview).nonEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var time: some View {
        // The server's clock can run a little ahead of the phone's, which would read "in 0 sec".
        Text(min(max(session.activity, live?.lastActive ?? .distantPast), Date().addingTimeInterval(-1)), format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .font(.caption2)
            .foregroundStyle(Theme.muted)
    }

    /// The Activity tab's pills for the same states: working in the accent, waiting in the alarm color of an approval.
    static func pill(_ status: ChatLive.Status) -> (label: String, tint: Color) {
        switch status {
        case .working: ("Working", Theme.primary)
        case .needsYou: ("Needs you", Theme.destructive)
        }
    }
}

/// A finished turn the user hasn't looked at yet.
struct UnreadDot: View {
    var body: some View {
        Circle().fill(Theme.primary).frame(width: 8, height: 8).accessibilityLabel("Unread")
    }
}

struct ConnectionBanner: View {
    let gateway: Gateway

    var body: some View {
        if gateway.status != .online {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(gateway.status == .connecting ? "Connecting…" : (gateway.lastError ?? "Offline, retrying…"))
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Theme.sidebar)
        }
    }
}

struct SettingsView: View {
    let gateway: Gateway
    @Binding var themeId: String
    @Binding var appearance: Appearance
    var openChat: (String) -> Void = { _ in }
    @AppStorage(ChatTextSize.key) private var textSize = ChatTextSize.standard
    @AppStorage("showTouches") private var showTouches = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var system
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    ForEach(Palette.all) { p in
                        Button { themeId = p.id } label: {
                            HStack(spacing: 12) {
                                Swatch(palette: p)
                                // Stacked, so a large text size doesn't squeeze the name beside "dark only".
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.name).foregroundStyle(Theme.foreground)
                                    if p.light == nil {
                                        Text("dark only").font(.caption2).foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                                if p.id == themeId { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
                            }
                        }
                        .accessibilityAddTraits(p.id == themeId ? .isSelected : [])
                    }
                    // A dark-only palette ignores the choice, so show what it renders instead of the stored preference.
                    let darkOnly = Palette.named(themeId).light == nil
                    Picker("Appearance", selection: darkOnly ? .constant(Appearance.dark) : $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(darkOnly)
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    HStack(spacing: 10) {
                        Text("A").font(.caption)
                        Slider(value: Binding(get: { Double(textSize) }, set: { textSize = ChatTextSize.clamped(Int($0.rounded())) }),
                               in: 0...Double(ChatTextSize.sizes.count - 1), step: 1)
                            .accessibilityLabel("Chat text size")
                            .accessibilityValue(ChatTextSize.label(textSize))
                        Text("A").font(.title2)
                    }
                    HStack {
                        Text("The quick brown fox").font(.body).dynamicTypeSize(ChatTextSize.effective(textSize, system: system))
                        Spacer()
                        Text(ChatTextSize.label(textSize)).font(.caption).foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Chat text size")
                } footer: {
                    Text("Relative to the system text size in Settings > Display & Brightness.")
                }
                .listRowBackground(Theme.sidebar)
                SubagentSettingsSection(gateway: gateway)
                ReadAloudSettingsSection()
                ApprovalsSettingsSection(gateway: gateway)
                Section {
                    NavigationLink { RoutinesView(gateway: gateway, profile: nil) } label: {
                        Label("Routines", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink { ArtifactsView(gateway: gateway, openChat: openChat) } label: {
                        Label("Artifacts", systemImage: "photo.on.rectangle.angled")
                    }
                }
                .listRowBackground(Theme.sidebar)
                Section {
                    Toggle("Show touches", isOn: $showTouches)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Draws a dot wherever you touch, so screen recordings show your taps.")
                }
                .listRowBackground(Theme.sidebar)
                Section("Gateway") {
                    LabeledContent("Server", value: gateway.credentials?.baseURL.absoluteString ?? "")
                    LabeledContent("User", value: gateway.credentials?.username ?? "")
                    LabeledContent("Status", value: "\(gateway.status)")
                }
                .listRowBackground(Theme.sidebar)
                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Text("Sign out").foregroundStyle(Theme.destructive)
                }
                .listRowBackground(Theme.sidebar)
            }
            .themedList()
            // An alert rather than a confirmationDialog: on the Form that one is a popover with no Cancel button.
            .alert("Sign out of \(gateway.credentials?.username ?? "Hermes")?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    gateway.signOut()
                    dismiss()
                }
            } message: {
                Text("You will need the server URL and your password to sign in again.")
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// Background, accent and user-bubble colors of a palette, shown in its own scheme.
struct Swatch: View {
    let palette: Palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let slots = (scheme == .dark || palette.light == nil) ? palette.dark : palette.light!
        HStack(spacing: 0) {
            ForEach(Array([slots.background, slots.primary, slots.userBubble, slots.foreground].enumerated()), id: \.offset) { _, hex in
                Rectangle().fill(Theme.dynamic(hex, hex))
            }
        }
        .frame(width: 56, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border, lineWidth: 0.5))
    }
}

extension View {
    func noAutocorrect() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
