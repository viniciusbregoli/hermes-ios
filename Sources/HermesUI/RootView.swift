import SwiftUI
import HermesKit

public struct RootView: View {
    @State private var store: ChatStore
    @State private var bots: BotStore
    @State private var tab = 0
    @State private var showSettings = false
    @AppStorage("theme") private var themeId = Palette.nous.id
    @AppStorage("appearance") private var appearance = Appearance.system
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
        _store = State(initialValue: store)
        _bots = State(initialValue: bots)
    }

    public var body: some View {
        let palette = Palette.named(themeId)
        let _ = (Theme.palette = palette)
        Group {
            if store.gateway.status == .signedOut {
                LoginView(gateway: store.gateway)
            } else {
                TabView(selection: $tab) {
                    MainView(store: store, bots: bots, showSettings: $showSettings)
                        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                        .tag(0)
                    BotsView(bots: bots, showSettings: $showSettings)
                        .tabItem { Label("Bots", systemImage: "person.2") }
                        .tag(1)
                }
                .background {
                    Button("Chats") { tab = 0 }.keyboardShortcut("1", modifiers: .command).hidden()
                    Button("Bots") { tab = 1 }.keyboardShortcut("2", modifiers: .command).hidden()
                }
            }
        }
        // Views read Theme statically, so a new id rebuilds them with the new palette.
        .id(themeId)
        .themed(palette, appearance)
        .sheet(isPresented: $showSettings) {
            SettingsView(gateway: store.gateway, themeId: $themeId, appearance: $appearance)
                .id(themeId).themed(palette, appearance)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { store.gateway.start() }
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
    let bots: BotStore
    @Binding var showSettings: Bool
    @State private var selection: String?

    static let newChat = "__new__"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.sessions) { s in
                    SessionRowView(session: s, unread: store.unread.contains(s.id)).tag(s.id)
                        .listRowBackground(Theme.sidebar)
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await store.delete(s.id) } }
                        }
                }
            }
            .overlay {
                if store.sessions.isEmpty, store.sessionsLoaded {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            .themedList()
            .refreshable { await store.refreshSessions() }
            .navigationTitle("Hermes")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                        .keyboardShortcut("n", modifiers: .command)
                        .help("New chat (⌘N)")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
            .safeAreaInset(edge: .bottom) { ConnectionBanner(gateway: store.gateway) }
        } detail: {
            if selection != nil {
                ChatView(store: store, bots: bots)
            } else {
                ContentUnavailableView("Pick a chat", systemImage: "bubble.left")
            }
        }
        // The split view's detail appears and disappears unreliably, so the selection says what is on screen.
        .onChange(of: selection, initial: true) { store.onScreen = selection != nil }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            let stored = id == Self.newChat ? nil : id
            if stored != nil, stored == store.selectedId, store.runtimeId != nil { return }
            Task { await store.open(stored) }
        }
        .alert("Hermes", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.alert ?? "")
        }
    }

    private func newChat() {
        if selection == Self.newChat { Task { await store.open(nil) } }
        selection = Self.newChat
    }
}

struct SessionRowView: View {
    let session: SessionRow
    var unread = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if unread { UnreadDot() }
                Text(session.title.nonEmpty ?? "Untitled")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(session.startedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            if !session.preview.isEmpty {
                Text(session.preview)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    ForEach(Palette.all) { p in
                        Button { themeId = p.id } label: {
                            HStack(spacing: 12) {
                                Swatch(palette: p)
                                Text(p.name).foregroundStyle(Theme.foreground)
                                if p.light == nil {
                                    Text("dark only").font(.caption2).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if p.id == themeId { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
                            }
                        }
                    }
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(Palette.named(themeId).light == nil)
                }
                .listRowBackground(Theme.sidebar)
                Section("Gateway") {
                    LabeledContent("Server", value: gateway.credentials?.baseURL.absoluteString ?? "")
                    LabeledContent("User", value: gateway.credentials?.username ?? "")
                    LabeledContent("Status", value: "\(gateway.status)")
                }
                .listRowBackground(Theme.sidebar)
                Button(role: .destructive) {
                    gateway.signOut()
                    dismiss()
                } label: {
                    Text("Sign out").foregroundStyle(Theme.destructive)
                }
                .listRowBackground(Theme.sidebar)
            }
            .themedList()
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
