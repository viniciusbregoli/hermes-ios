import SwiftUI
import HermesKit

/// The Bots tab: every profile as a bot, each with its one forever "Bot Chat".
struct BotsView: View {
    let bots: BotStore
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            List(bots.bots) { bot in
                NavigationLink(value: bot.name) { BotRow(bot: bot, bots: bots) }
                    .listRowBackground(Theme.sidebar)
            }
            .overlay {
                if !bots.loaded {
                    if let error = bots.error, bots.gateway.status == .online {
                        ContentUnavailableView {
                            Label("Couldn't load bots", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try again") { Task { await bots.refresh() } }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .themedList()
            .refreshable { await bots.refresh() }
            .navigationTitle("Bots")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .safeAreaInset(edge: .bottom) { ConnectionBanner(gateway: bots.gateway) }
            // Polls only while the list is on screen; the desktop polls every 5 s, a phone needs less.
            .task(id: bots.gateway.status) {
                guard bots.gateway.status == .online else { return }
                while !Task.isCancelled {
                    await bots.refresh()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .navigationDestination(for: String.self) { BotChatScreen(bots: bots, name: $0) }
        }
    }
}

struct BotRow: View {
    let bot: Bot
    let bots: BotStore

    var body: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, bots: bots, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    if bots.unread.contains(bot.name) { UnreadDot() }
                    Text(bot.label).font(.subheadline.weight(.medium)).lineLimit(1)
                    BotActivity(bot: bot, bots: bots)
                    Spacer()
                    if let last = bot.lastActive {
                        Text(last, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Text(bot.preview.nonEmpty ?? "@\(bot.handle)")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// "thinking" while a turn runs in a chat this app has open, "working" while a background worker heartbeats.
struct BotActivity: View {
    let bot: Bot
    let bots: BotStore

    var body: some View {
        if bots.thinking.contains(bot.name) {
            Label("thinking", systemImage: "ellipsis")
                .font(.caption2)
                .foregroundStyle(Theme.primary)
                .labelStyle(.titleOnly)
        } else if bot.working() {
            HStack(spacing: 3) {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text("working").font(.caption2).foregroundStyle(Theme.success)
            }
        }
    }
}

struct BotAvatar: View {
    let bot: Bot?
    let bots: BotStore
    var fallbackName = ""
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Text(String((bot?.label ?? fallbackName).prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.primary.opacity(0.15))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: bot?.name) { if let bot { await bots.loadAvatar(bot) } }
        .accessibilityHidden(true)
    }

    private var image: Image? {
        guard let name = bot?.name, let data = bots.avatars[name] else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}

/// A bot's chat: its Bot Chat by default, or any of its other chats picked from the toolbar.
struct BotChatScreen: View {
    let bots: BotStore
    let name: String
    @State private var store: ChatStore
    @State private var showChats = false

    init(bots: BotStore, name: String) {
        self.bots = bots
        self.name = name
        _store = State(initialValue: ChatStore(gateway: bots.gateway, profile: name))
    }

    var body: some View {
        let bot = bots.bot(named: name)
        ChatView(store: store, bots: bots)
            .overlay {
                if let error = store.botChatError {
                    ContentUnavailableView {
                        Label("Couldn't open the Bot Chat", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await open() } }
                            .keyboardShortcut("r", modifiers: .command)
                    }
                    .background(Theme.background)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        BotAvatar(bot: bot, bots: bots, fallbackName: name, size: 24)
                        Text(store.title).font(.headline).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showChats = true } label: { Image(systemName: "list.bullet") }
                        .keyboardShortcut("l", modifiers: .command)
                        .help("Chats with \(bot?.label ?? name) (⌘L)")
                }
            }
            .sheet(isPresented: $showChats) {
                BotChatsSheet(store: store, label: bot?.label ?? name).themedList()
            }
            .task(id: bots.gateway.status) {
                store.botChatTitle = bot?.label
                // Opens on arrival, and again after a reconnect if the first try failed.
                if bots.gateway.status == .online, store.canonicalId == nil { await open() }
            }
            .onChange(of: store.runtimeId, initial: true) { bots.track(runtime: store.runtimeId, bot: name, running: store.running) }
            .onChange(of: store.running) { bots.track(runtime: store.runtimeId, bot: name, running: store.running) }
            .onChange(of: store.visible, initial: true) {
                if store.visible { bots.visibleBot = name } else if bots.visibleBot == name { bots.visibleBot = nil }
            }
            .onAppear { store.onScreen = true }
            .onDisappear {
                store.onScreen = false
                if bots.visibleBot == name { bots.visibleBot = nil }
            }
    }

    private func open() async {
        await store.openBotChat(known: bots.bot(named: name)?.canonicalId)
    }
}

/// The bot's other chats (and a way back to its Bot Chat or into a new one).
struct BotChatsSheet: View {
    let store: ChatStore
    let label: String
    @State private var query = ""
    @State private var search = SearchState()
    @State private var renaming: SessionRow?
    @State private var showArchived = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResults(state: search, query: query) { hit in
                        Button { pick(hit.id) } label: { SearchHitRow(hit: hit).foregroundStyle(Theme.foreground) }
                    }
                } else {
                    Section {
                        if let id = store.canonicalId {
                            row("Bot Chat", subtitle: "The one ongoing conversation", id: id, icon: "infinity")
                        }
                        Button { pick(nil) } label: {
                            Label("New chat with \(label)", systemImage: "square.and.pencil")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                    .listRowBackground(Theme.sidebar)
                    Section("Other chats") {
                        if store.sessionsLoaded, store.sessions.isEmpty {
                            Text("None yet").foregroundStyle(Theme.muted)
                        }
                        ForEach(store.pinnedSessions + store.unpinnedSessions) { s in
                            row(s.title.nonEmpty ?? "Untitled", subtitle: s.preview, id: s.id,
                                icon: store.pinned.contains(s.id) ? "pin" : nil)
                                .sessionActions(store, s, renaming: $renaming)
                        }
                    }
                    .listRowBackground(Theme.sidebar)
                    if store.sessionsLoaded { ArchivedEntry(shown: $showArchived) }
                }
            }
            .searchable(text: $query, prompt: "Search messages")
            .searchFetch(store, query, into: $search)
            .renameAlert(store, $renaming)
            .sheet(isPresented: $showArchived) { ArchivedChats(store: store) { pick($0) } }
            .overlay {
                if !store.sessionsLoaded { ProgressView() }
            }
            .themedList()
            .navigationTitle(label)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .task { await store.refreshSessions() }
        }
    }

    private func row(_ title: String, subtitle: String, id: String, icon: String?) -> some View {
        Button { pick(id) } label: {
            HStack {
                if let icon { Image(systemName: icon).foregroundStyle(Theme.primary) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.foreground).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                Spacer()
                if id == store.selectedId { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
            }
        }
    }

    private func pick(_ id: String?) {
        dismiss()
        Task { await store.open(id) }
    }
}

/// A message another bot delivered, shown as an attributed notice rather than as the user's bubble.
struct AgentNotice: View {
    let message: AgentMessage
    let bots: BotStore?

    var body: some View {
        let sender = bots?.sender(of: message)
        HStack(alignment: .top, spacing: 8) {
            if let bots { BotAvatar(bot: sender, bots: bots, fallbackName: message.sender, size: 22) }
            VStack(alignment: .leading, spacing: 4) {
                Text("From \(sender?.label ?? message.sender)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                MarkdownView(text: message.body)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
}

/// Bots matching the "@..." being typed; picking one completes the handle.
struct MentionPicker: View {
    let candidates: [Bot]
    let bots: BotStore
    /// The handle a chip shows; a group room may have handed a bot a different one.
    var handle: (Bot) -> String = { $0.handle }
    let pick: (Bot) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { i, bot in
                    let chip = Button { pick(bot) } label: {
                        HStack(spacing: 6) {
                            BotAvatar(bot: bot, bots: bots, size: 20)
                            Text("@\(handle(bot))").font(.callout)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                    // Tab completes the first match, like a shell.
                    if i == 0 { chip.keyboardShortcut(.tab, modifiers: []) } else { chip }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    /// The handle prefix after a trailing "@" in `draft`, or nil when the user isn't typing a mention.
    static func query(_ draft: String) -> String? {
        guard let r = draft.range(of: #"(^|\s)@[a-z0-9_-]*$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(draft[r].drop { $0 != "@" }.dropFirst())
    }

    static func complete(_ draft: String, with bot: Bot) -> String { complete(draft, handle: bot.handle) }

    static func complete(_ draft: String, handle: String) -> String {
        guard let q = query(draft) else { return draft }
        return String(draft.dropLast(q.count + 1)) + "@\(handle) "
    }
}
