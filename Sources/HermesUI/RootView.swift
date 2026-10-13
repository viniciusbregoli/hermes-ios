import SwiftUI
import HermesKit

public struct RootView: View {
    @State private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        _store = State(initialValue: ChatStore(gateway: Gateway(credentials: Keychain.load())))
    }

    public var body: some View {
        Group {
            if store.gateway.status == .signedOut {
                LoginView(gateway: store.gateway)
            } else {
                MainView(store: store)
            }
        }
        .tint(Theme.primary)
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
            }
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
    @State private var selection: String?
    @State private var showSettings = false

    static let newChat = "__new__"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.sessions) { s in
                    SessionRowView(session: s).tag(s.id)
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await store.delete(s.id) } }
                        }
                }
            }
            .overlay {
                if store.sessions.isEmpty, store.gateway.status == .online {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
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
                ChatView(store: store)
            } else {
                ContentUnavailableView("Pick a chat", systemImage: "bubble.left")
            }
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            let stored = id == Self.newChat ? nil : id
            if stored != nil, stored == store.selectedId, store.runtimeId != nil { return }
            Task { await store.open(stored) }
        }
        .sheet(isPresented: $showSettings) { SettingsView(gateway: store.gateway) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
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
            .background(.bar)
        }
    }
}

struct SettingsView: View {
    let gateway: Gateway
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    LabeledContent("Server", value: gateway.credentials?.baseURL.absoluteString ?? "")
                    LabeledContent("User", value: gateway.credentials?.username ?? "")
                    LabeledContent("Status", value: "\(gateway.status)")
                }
                Button("Sign out", role: .destructive) {
                    gateway.signOut()
                    dismiss()
                }
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

extension View {
    func noAutocorrect() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
